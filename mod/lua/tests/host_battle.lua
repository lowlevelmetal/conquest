-- Autotest: host a direct-connect server for one GC battle map, force a quick
-- victory in the battle, quit back to the shell, and log what the shell sees.
-- Progress is kept in ConquestNet values because each phase is a new Lua state.

local log = ConquestNet_Log
local stage = ConquestNet_GetValue("autotest_stage")
local MAP = "cor1c_con"
-- args: "<hold seconds> [connect type] [tunnel]"; "lan" selects the engine's own UDP
-- transport, "tunnel" also serves LAN discovery to a mod peer over TCP port 24600
local _, _, holdArg, connectArg, tunnelArg = string.find(ConquestNet_AutotestArgs or "", "^(%S*)%s*(%S*)%s*(%S*)")
local CONNECT = (connectArg and connectArg ~= "") and connectArg or "direct"

local function setStage(s)
	ConquestNet_SetValue("autotest_stage", s)
	log("autotest: stage -> " .. s)
end

local function logError(where)
	local level, msg = ScriptCB_GetError()
	if level and level > 0 then
		log("autotest: " .. where .. " error level " .. tostring(level) .. " " .. tostring(msg))
	end
end

if ConquestNet_Context == "mission" then
	if stage ~= "launching" then
		return
	end
	setStage("in_battle")
	log("autotest: battle rules=" .. tostring(ScriptCB_GetGameRules()) ..
		" innet=" .. tostring(ScriptCB_InNetGame()) .. " host=" .. tostring(ScriptCB_GetAmHost()))

	-- log the rest of this state's script loads (end-of-match screens etc.)
	local afterDoFile = ConquestNet_AfterDoFile
	ConquestNet_AfterDoFile = function(name)
		log("autotest: mission DoFile " .. name)
		afterDoFile(name)
	end

	-- mission scripts define ScriptPostLoad after setup_teams loads; wrap it on definition
	setmetatable(getfenv(0), { __newindex = function(t, k, v)
		if k == "ScriptPostLoad" and type(v) == "function" then
			local orig = v
			v = function()
				orig()
				-- the engine registers MissionVictory after setup_teams, so wrap it here
				local victory = MissionVictory
				MissionVictory = function(team)
					log("autotest: MissionVictory(" .. tostring(team) .. ") -> quitting to shell")
					ConquestNet_SetValue("battle_winner", tostring(team))
					victory(team)
					setStage("returning")
					ScriptCB_QuitToShell()
				end
				local hold = tonumber(holdArg) or 10
				log("autotest: ScriptPostLoad ran; forcing victory in " .. hold .. "s")
				local t1 = CreateTimer("conquest_victory")
				SetTimerValue(t1, hold)
				StartTimer(t1)
				OnTimerElapse(function()
					MissionVictory(1)
				end, t1)
			end
		end
		rawset(t, k, v)
	end })
	return
end

-- shell
if stage == "returning" or stage == "in_battle" or stage == "launching" then
	log("autotest: back in shell from stage " .. stage)
	local function q(name)
		local f = _G[name]
		local ok, a, b = pcall(f)
		log(string.format("autotest: %s -> %s %s", name, tostring(a), tostring(b)))
	end
	q("ScriptCB_GetLastBattleVictory")
	q("ScriptCB_InNetGame")
	q("ScriptCB_NetWasHost")
	q("ScriptCB_NetWasClient")
	q("ScriptCB_GetAmHost")
	q("ScriptCB_IsMetagameStateSaved")
	q("ScriptCB_GetConnectType")
	log("autotest: stored winner " .. tostring(ConquestNet_GetValue("battle_winner")))
	local push = ScriptCB_PushScreen
	ScriptCB_PushScreen = function(name)
		log("autotest: shell pushes " .. tostring(name))
		return push(name)
	end
	logError("on return")
	ScriptCB_CancelLogin()
	ScriptCB_CloseNetShell(1)
	ScriptCB_SetInNetGame(nil)
	setStage("done")
	ConquestNet_AutotestQuit = 5
	return
end

if stage then
	return
end

-- first shell load: host once the main menu is up
local steps = {
	function()
		if tunnelArg == "tunnel" then
			log("autotest: mod server " .. tostring(ConquestNet_Host(24600)))
			ConquestNet_SetTunnel(1)
		end
		gOnlineServiceStr = CONNECT == "lan" and "LAN" or "Direct"
		ScriptCB_SetConnectType(CONNECT)
		log("autotest: connect type " .. CONNECT)
		ScriptCB_SetNetLoginName(ScriptCB_tounicode("ConquestHost"))
		ScriptCB_OpenNetShell(1)
	end,
	function()
		ScriptCB_SetMissionNames({ { Map = MAP, Side = 1, SideChar = "c" } }, nil)
		ScriptCB_SetAmHost(1)
		ScriptCB_SetGameName(ScriptCB_tounicode("Conquest test"))
		ScriptCB_SetGameRules("mp")
	end,
	function()
		local p = ScriptCB_GetNetGameDefaults()
		p.iWarmUp = 0
		ScriptCB_SetNetGameDefaults(p)
		ScriptCB_SetDedicated(nil)
		ScriptCB_SetCanSwitchSides(1)
		ScriptCB_BeginLobby()
		setStage("launching")
	end,
}

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen then
		return
	end
	local i = (ConquestNet_AutotestStep or 0) + 1
	if steps[i] then
		ConquestNet_AutotestStep = i
		log("autotest: host step " .. i)
		steps[i]()
		logError("step " .. i)
	else
		ScriptCB_UpdateLobby(nil)
		ScriptCB_LaunchLobby()
		logError("launch")
	end
end
