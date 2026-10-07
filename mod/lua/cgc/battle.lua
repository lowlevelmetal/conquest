-- Battle-side half of online Galactic Conquest (runs in the mission's Lua state).
--
-- The host tells the client when its server is ready and who won. On victory
-- the client leaves first, then the host: a client left connected to a
-- server that has vanished can crash. ConquestNet_Tick is called by the
-- native layer every frame the engine services its sockets.

ConquestNet_RunFile("lua/cgc/serialize.lua")

local raw = ConquestNet_GetValue("cgc_session")
local session = raw and CGC.Deserialize(raw)
if not (session and session.started and session.battle) then
	return
end

local HOST_WAIT = 8   -- seconds the host waits for the client to leave

local function log(text)
	ConquestNet_Log("cgc battle: " .. text)
end

local function send(msg)
	ConquestNet_Send(CGC.Serialize(msg))
end

-- the native tick must stop before this Lua state is torn down
local function leaveBattle()
	ConquestNet_EnableTick(0)
	ScriptCB_QuitToShell()
end

-- next message of a kind from the other player (others are dropped)
local function receive(kind)
	while true do
		local s = ConquestNet_Recv()
		if not s then
			return nil
		end
		local msg = CGC.Deserialize(s)
		if type(msg) == "table" and msg.kind == kind then
			return msg
		end
		log("ignored " .. tostring(type(msg) == "table" and msg.kind))
	end
end

log("battle " .. tostring(session.battle.mission) .. " as " .. tostring(session.role))

-- Put each player on their own faction: the engine joins the team named by
-- ifs_sideselect<N>.CurButton when the player confirms (or by itself once the
-- side-select timer allows), so preselect it when the screen appears. The
-- in-game screens load after setup_teams, so hook their script load.
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

ConquestNet_EnableTick(1)

if session.role ~= "host" then
	local leaving = false
	ConquestNet_Tick = function()
		if leaving then
			return
		end
		local msg = receive("result")
		if msg then
			leaving = true
			log("host reports winner " .. tostring(msg.winner) .. "; leaving")
			ConquestNet_SetValue("cgc_winner", tostring(msg.winner))
			send({ kind = "left" })
			leaveBattle()
		end
	end
	return
end

local quitAt = nil
ConquestNet_Tick = function()
	if quitAt and (receive("left") or ConquestNet_Time() >= quitAt) then
		quitAt = nil
		log("returning to the galaxy")
		leaveBattle()
	end
end

table.insert(ConquestNet_PostLoad, function()
	-- the server is up now: tell the client to join (joining while the host is
	-- still loading stalls the client's handshake)
	send({ kind = "launch", mission = session.battle.mission, password = session.password })
	log("server ready; client told to join")

	-- the engine registers MissionVictory late; wrap it once the mission has loaded
	local victory = MissionVictory
	MissionVictory = function(team)
		log("winner " .. tostring(team))
		ConquestNet_SetValue("cgc_winner", tostring(team))
		send({ kind = "result", winner = team })
		victory(team)
		quitAt = ConquestNet_Time() + HOST_WAIT
	end
end)
