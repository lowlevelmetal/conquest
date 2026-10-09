-- Battle-side half of online Galactic Conquest (runs in the mission's Lua state).
--
-- The host tells the client when its server is ready ("launch") and when the
-- battle is over ("end"), however it ended: a side won (MissionVictory), a
-- side lost (MissionDefeat, e.g. out of reinforcements), a tie, or the host
-- left the battle. The client leaves first, then the host: a client left
-- connected to a server that has vanished can crash. Who won is not decided
-- here: back in the galaxy the host sends what its game recorded (shell.lua),
-- so both campaigns apply the same result.
--
-- Messages for the galaxy that arrive during the battle are kept for the
-- shell (CGC.Unstash in link.lua). ConquestNet_Tick is called by the native
-- layer every frame the engine services its sockets.

ConquestNet_RunFile("lua/cgc/serialize.lua")

local raw = ConquestNet_GetValue("cgc_session")
local session = raw and CGC.Deserialize(raw)
if not (session and session.started and session.battle) then
	return
end

local HOST_WAIT = 8   -- seconds the host waits for the client to leave
local host = session.role == "host"

local function log(text)
	ConquestNet_Log("cgc battle: " .. text)
end

local function send(kind)
	ConquestNet_Send(CGC.Serialize({ kind = kind }))
end

local function linkLost()
	local state = ConquestNet_Status()
	return state == "closed" or state == "error"
end

-- messages the galaxy needs (the host's result, a quit) wait in a value
local function stash(msg)
	local list = CGC.Deserialize(ConquestNet_GetValue("cgc_stash") or "{}") or {}
	table.insert(list, msg)
	ConquestNet_SetValue("cgc_stash", CGC.Serialize(list))
end

-- next message from the other player, if any
local function receive()
	local s = ConquestNet_Recv()
	if not s then
		return nil
	end
	local msg = CGC.Deserialize(s)
	if type(msg) ~= "table" or type(msg.kind) ~= "string" then
		log("ignored a malformed message")
		return {}
	end
	return msg
end

log("battle " .. tostring(session.battle.mission) .. " as " .. tostring(session.role))

-- Put each player on their own faction: the engine joins the team named by
-- ifs_sideselect<N>.CurButton when the player confirms, so preselect it when
-- the screen appears. The in-game screens load after setup_teams, so hook
-- their script load.
local myTag = "team" .. tostring(session.myTeam)
local afterDoFile = ConquestNet_AfterDoFile
ConquestNet_AfterDoFile = function(name)
	afterDoFile(name)
	if name ~= "ifs_sideselect" then
		return
	end
	for i = 1, 4 do
		local screen = _G["ifs_sideselect" .. i]
		if screen and screen.Enter then
			local enter = screen.Enter
			screen.Enter = function(this, bFwd)
				enter(this, bFwd)
				local button = this.buttons and this.buttons[myTag]
				if button and not button.hidden then
					this.CurButton = myTag
					SetCurButton(myTag)
					log("side select: preselected " .. myTag)
				end
			end
		end
	end
end

-- Every way out of the battle that goes through a script (our own leaving,
-- the pause menu's Quit, the end-of-match screens) turns the native tick off
-- first, and the host tells the client the battle is over.
local ended = false
local leaving = false
local loaded = false   -- ScriptPostLoad has run; quitting earlier is ignored

local function battleOver(why)
	if host and not ended then
		ended = true
		log("battle over (" .. why .. "); client told to leave")
		send("end")
	end
end

local quitToShell = ScriptCB_QuitToShell
local function leaveBattle(why)
	if leaving then
		return
	end
	leaving = true
	battleOver(why)
	ConquestNet_EnableTick(0)
	ConquestNet_Tick = nil
	if not loaded then
		log("returning to the galaxy once the battle has loaded (" .. why .. ")")
		return
	end
	log("returning to the galaxy (" .. why .. ")")
	quitToShell()
end

local function wrapExit(name, redirect)
	local fn = _G[name]
	if not fn then
		return
	end
	_G[name] = function(a, b, c)
		if redirect then
			-- no map rotation in an online campaign: always back to the galaxy
			return leaveBattle(name)
		end
		battleOver(name)
		leaving = true
		ConquestNet_EnableTick(0)
		ConquestNet_Tick = nil
		return fn(a, b, c)
	end
end
wrapExit("ScriptCB_QuitToShell")
wrapExit("ScriptCB_QuitToWindows")
wrapExit("ScriptCB_RestartMission")
wrapExit("ScriptCB_QuitFromStats", true)

-- leaving before the battle has loaded happens once it has
table.insert(ConquestNet_PostLoad, function()
	loaded = true
	if leaving then
		log("returning to the galaxy (left while loading)")
		quitToShell()
	end
end)

ConquestNet_EnableTick(1)

if not host then
	ConquestNet_Tick = function()
		if leaving then
			return
		end
		local msg = receive()
		while msg do
			if msg.kind == "end" then
				log("host says the battle is over; leaving")
				send("left")
				return leaveBattle("battle over")
			elseif msg.kind == "result" or msg.kind == "quit" then
				-- the host is already back in the galaxy (or gone)
				stash(msg)
				send("left")
				return leaveBattle("host left the battle")
			elseif msg.kind then
				stash(msg)
			end
			msg = receive()
		end
		if linkLost() then
			return leaveBattle("lost the connection to the host")
		end
	end
	return
end

local quitAt = nil
ConquestNet_Tick = function()
	if leaving then
		return
	end
	local msg = receive()
	while msg do
		if msg.kind == "left" then
			if quitAt then
				return leaveBattle("client left")
			end
			-- the client left early (its pause menu): the battle goes on
			log("the other player left the battle")
		elseif msg.kind == "quit" then
			stash(msg)
			return leaveBattle("the other player left the campaign")
		elseif msg.kind then
			stash(msg)
		end
		msg = receive()
	end
	if linkLost() then
		return leaveBattle("lost the connection to the other player")
	end
	if quitAt and ConquestNet_Time() >= quitAt then
		return leaveBattle("client did not answer")
	end
end

table.insert(ConquestNet_PostLoad, function()
	if leaving then
		return
	end
	-- the server is up now: tell the client to join (joining while the host is
	-- still loading stalls the client's handshake)
	ConquestNet_Send(CGC.Serialize({ kind = "launch", mission = session.battle.mission, password = session.password }))
	log("server ready; client told to join")

	-- The engine registers these late; wrap them once the mission has loaded.
	-- A battle ends with MissionVictory(team), MissionVictory({1,2}) for a tie,
	-- or MissionDefeat(team) when a side runs out of reinforcements.
	local function onEnd(name, fn)
		if not fn then
			return fn
		end
		return function(team)
			log(name .. "(" .. (type(team) == "table" and "tie" or tostring(team)) .. ")")
			battleOver(name)
			quitAt = quitAt or ConquestNet_Time() + HOST_WAIT
			return fn(team)
		end
	end
	MissionVictory = onEnd("MissionVictory", MissionVictory)
	MissionDefeat = onEnd("MissionDefeat", MissionDefeat)
end)
