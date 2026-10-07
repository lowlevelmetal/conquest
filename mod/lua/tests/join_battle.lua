-- Autotest: join a direct-connect host by IP (arg, default 127.0.0.1), log the
-- battle, and report the shell state after the host ends the match.

local log = ConquestNet_Log
local stage = ConquestNet_GetValue("autotest_stage")
local ip = ConquestNet_AutotestArgs
if not ip or ip == "" then
	ip = "127.0.0.1"
end

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
	log("autotest: client mission loading, stage=" .. tostring(stage) ..
		" rules=" .. tostring(ScriptCB_GetGameRules()) ..
		" innet=" .. tostring(ScriptCB_InNetGame()) .. " host=" .. tostring(ScriptCB_GetAmHost()))
	setStage("in_battle")
	return
end

if stage == "in_battle" or stage == "joining" then
	log("autotest: client back in shell from stage " .. stage)
	for _, name in ipairs({ "ScriptCB_GetLastBattleVictory", "ScriptCB_InNetGame", "ScriptCB_NetWasClient",
	                        "ScriptCB_GetAmHost", "ScriptCB_GetConnectType" }) do
		local ok, a, b = pcall(_G[name])
		log(string.format("autotest: %s -> %s %s", name, tostring(a), tostring(b)))
	end
	logError("on return")
	setStage("done")
	ConquestNet_AutotestQuit = 10
	return
end

if stage then
	return
end

local started, deadline
local steps = {
	function()
		ScriptCB_SetGameRules("mp")
		gOnlineServiceStr = "Direct"
		ScriptCB_SetConnectType("direct")
		ScriptCB_SetNetLoginName(ScriptCB_tounicode("ConquestClient"))
		ScriptCB_OpenNetShell(1)
	end,
	function()
		ScriptCB_SetProfileJoinIP(ip)
		ScriptCB_SetAmHost(nil)
		ScriptCB_SetDedicated(nil)
		log("autotest: BeginJoinIP " .. ip)
		ScriptCB_BeginJoinIP(ip, "")
		setStage("joining")
		started = ConquestNet_Time()
	end,
}

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen or ConquestNet_JoinFinished then
		return
	end
	local i = (ConquestNet_AutotestStep or 0) + 1
	if steps[i] then
		ConquestNet_AutotestStep = i
		log("autotest: join step " .. i)
		steps[i]()
		logError("step " .. i)
		return
	end
	ScriptCB_UpdateQuickmatch()
	local done = ScriptCB_IsQuickmatchDone()
	log("autotest: quickmatch done=" .. tostring(done))
	if done == 1 then
		ConquestNet_JoinFinished = true
		log("autotest: joined; launching")
		ScriptCB_LaunchQuickmatch()
		ifs_missionselect.bForMP = 1
		ifs_movietrans_PushScreen(ifs_mp_lobby_quick)
	elseif done == -1 or ConquestNet_Time() - started > 30 then
		ConquestNet_JoinFinished = true
		logError("join failed")
		setStage("done")
		ConquestNet_AutotestQuit = 3
	end
end
