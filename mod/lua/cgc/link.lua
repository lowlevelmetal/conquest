-- Message link between the two players, on top of the native TCP connection.
-- Messages are tables with a `kind` field. Received messages wait in a mailbox
-- until a screen takes them, so nothing is lost if it arrives early.
--
-- The session record (who is host, which team is local, ...) is kept in the
-- native value store because the shell's Lua state is rebuilt after battles.

CGC = CGC or {}

CGC.PORT = 24600
CGC.BATTLE_PORT = 3658   -- the engine's UDP game port when hosting
CGC.PROTOCOL = 3
CGC.mailbox = CGC.mailbox or {}

local MAILBOX_MAX = 64   -- messages no screen has taken yet
local LOG_PER_SECOND = 20

-- the two sides of each scenario, in team order (team 1 moves first)
CGC.SCENARIOS = {
	cw = { era = "common.era.cw", sides = { "rep", "cis" } },
	gcw = { era = "common.era.gcw", sides = { "all", "imp" } },
}

-- localized faction name, e.g. "Republic"
function CGC.TeamName(scenario, team)
	return ScriptCB_getlocalizestr("common.sides." .. CGC.SCENARIOS[scenario].sides[team] .. ".name")
end

-- the name this player goes by online (unicode); separate local test copies
-- share one profile, so they use their instance names
function CGC.LoginName()
	local instance = ConquestNet_Instance()
	if instance ~= "" then
		return ScriptCB_tounicode(instance)
	end
	return ScriptCB_GetCurrentProfileNetName()
end

function CGC.PlayerName()
	return ScriptCB_ununicode(CGC.LoginName())
end

function CGC.Log(text)
	ConquestNet_Log("cgc: " .. text)
end

-- Run fn, logging an error instead of losing it: the game drops errors
-- raised in screen updates without a word. Each place logs its first error.
local tryLogged = {}
function CGC.Try(what, fn)
	local ok, err = pcall(fn)
	if not ok and not tryLogged[what] then
		tryLogged[what] = true
		CGC.Log(what .. " failed: " .. tostring(err))
	end
	return ok
end

-- A player name from the network, safe to show: no control characters, short.
function CGC.CleanName(name)
	if type(name) ~= "string" then
		return ""
	end
	return string.sub(string.gsub(name, "%c", ""), 1, 32)
end

-- What each message may carry. Anything else from the other player is
-- dropped before a screen sees it. The campaign snapshot check is added by
-- game.lua (CGC.CheckSnapshot).
local function isText(v, max)
	return v == nil or (type(v) == "string" and string.len(v) <= max)
end

local function isTeam(v)
	return v == 1 or v == 2
end

local function isInteger(v, lo, hi)
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

-- a mission name such as "tat2g_con"
function CGC.IsMission(v)
	return type(v) == "string" and string.len(v) <= 32 and string.find(v, "^[%w_]+$") ~= nil
end

local function snapshot(m)
	return type(m.state) == "table" and (not CGC.CheckSnapshot or CGC.CheckSnapshot(m.state))
end

local function always()
	return true
end

local CHECKS = {
	hello = function(m) return type(m.protocol) == "number" and isText(m.version, 16) and isText(m.name, 64) end,
	setup = function(m) return CGC.SCENARIOS[m.scenario or ""] ~= nil and isTeam(m.hostTeam) and isText(m.name, 64) end,
	refuse = function(m) return isText(m.reason, 16) end,
	ping = function(m) return type(m.t) == "number" end,
	pong = function(m) return type(m.t) == "number" end,
	udp = function(m) return type(m.ok) == "boolean" end,
	start = always,
	bye = always,
	turn = snapshot,
	battle = snapshot,
	undo = snapshot,
	attack = always,
	mode = function(m) return CGC.IsMission(m.mission) end,
	card = function(m) return isTeam(m.team) and isInteger(m.slot, 0, 64) end,
	launch = function(m) return CGC.IsMission(m.mission) and isText(m.password, 16) and m.password ~= nil end,
	-- the battle is over (sent from the battle, so the client leaves it)
	["end"] = always,
	left = always,
	-- the winner as the host's game reports it (ScriptCB_GetLastBattleVictory)
	result = function(m) return isInteger(m.winner, -8, 8) end,
	quit = always,
}

-- frequent messages that would flood the log
local QUIET = { ping = true, pong = true }

-- at most LOG_PER_SECOND received messages are logged each second
local logWindow, logged, unlogged = 0, 0, 0
local function logReceived(text)
	local now = ConquestNet_Time()
	if now - logWindow >= 1 then
		if unlogged > 0 then
			CGC.Log(unlogged .. " more messages not logged")
		end
		logWindow, logged, unlogged = now, 0, 0
	end
	if logged < LOG_PER_SECOND then
		logged = logged + 1
		CGC.Log(text)
	else
		unlogged = unlogged + 1
	end
end

function CGC.Send(kind, fields)
	local msg = fields or {}
	msg.kind = kind
	if not QUIET[kind] then
		CGC.Log("send " .. kind)
	end
	return ConquestNet_Send(CGC.Serialize(msg))
end

-- a message from the other player goes to the mailbox if it checks out
local function accept(msg, err)
	local check = type(msg) == "table" and type(msg.kind) == "string" and CHECKS[msg.kind]
	if check and check(msg) then
		if not QUIET[msg.kind] then
			logReceived("recv " .. msg.kind)
		end
		table.insert(CGC.mailbox, msg)
		if table.getn(CGC.mailbox) > MAILBOX_MAX then
			local old = table.remove(CGC.mailbox, 1)
			logReceived("mailbox full; dropped " .. tostring(old.kind))
		end
	elseif type(msg) == "table" then
		logReceived("dropped invalid message " .. string.sub(tostring(msg.kind), 1, 32))
	else
		logReceived("dropped malformed message: " .. tostring(err))
	end
end

-- Move everything the native link has received into the mailbox.
function CGC.Poll()
	while true do
		local s = ConquestNet_Recv()
		if not s then
			break
		end
		accept(CGC.Deserialize(s))
	end
end

-- Messages the battle kept for the galaxy (cgc/battle.lua) go to the mailbox.
function CGC.Unstash()
	local raw = ConquestNet_GetValue("cgc_stash")
	ConquestNet_SetValue("cgc_stash", nil)
	local list = raw and CGC.Deserialize(raw)
	if type(list) == "table" then
		for _, msg in ipairs(list) do
			accept(msg)
		end
	end
end

-- The oldest message of a kind, left in the mailbox.
function CGC.Peek(kind)
	CGC.Poll()
	for _, msg in ipairs(CGC.mailbox) do
		if msg.kind == kind then
			return msg
		end
	end
	return nil
end

-- Remove and return the oldest message of a kind (or of any listed kind).
function CGC.Take(...)
	CGC.Poll()
	for i, msg in ipairs(CGC.mailbox) do
		for j = 1, arg.n do
			if msg.kind == arg[j] then
				table.remove(CGC.mailbox, i)
				return msg
			end
		end
	end
	return nil
end

function CGC.LinkUp()
	local state = ConquestNet_Status()
	return state == "connected"
end

-- Peer disconnected or the link failed after being established.
function CGC.LinkLost()
	local state = ConquestNet_Status()
	return state == "closed" or state == "error"
end

-- session persistence ---------------------------------------------------------

function CGC.SaveSession()
	ConquestNet_SetValue("cgc_session", CGC.session and CGC.Serialize(CGC.session) or nil)
end

function CGC.LoadSession()
	local s = ConquestNet_GetValue("cgc_session")
	CGC.session = s and CGC.Deserialize(s) or nil
	return CGC.session
end

function CGC.EndSession(reason)
	CGC.Log("session ended: " .. tostring(reason))
	ConquestNet_SetTunnel(0)
	ConquestNet_EchoUdp(nil)
	ConquestNet_ProbeUdp(nil)
	-- anything just sent (quit, bye) still goes out
	ConquestNet_Close()
	CGC.session = nil
	CGC.mailbox = {}
	CGC.SaveSession()
end

function CGC.Active()
	return CGC.session ~= nil and CGC.session.started
end

function CGC.IsLocalTeam(team)
	return CGC.session and CGC.session.myTeam == team
end
