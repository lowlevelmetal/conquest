-- Autotest: join a direct-connect host by IP (arg, default 127.0.0.1), log the
-- battle, and report the shell state after the host ends the match.

local log = ConquestNet_Log
local stage = ConquestNet_GetValue("autotest_stage")
-- args: "<ip> [connect type] [tunnel]"; "tunnel" discovers the host through the mod
-- link on TCP port 24600 instead of LAN broadcast
local _, _, ip, connectArg, tunnelArg = string.find(ConquestNet_AutotestArgs or "", "^(%S*)%s*(%S*)%s*(%S*)")
if not ip or ip == "" then
	ip = "127.0.0.1"
end
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
		if tunnelArg == "tunnel" then
			log("autotest: connecting mod link " .. tostring(ConquestNet_Connect(ip, 24600)))
		end
	end,
	function()
		if tunnelArg == "tunnel" then
			local state, detail = ConquestNet_Status()
			log("autotest: mod link " .. state .. " (" .. detail .. ")")
			if state ~= "connected" then
				ConquestNet_AutotestStep = ConquestNet_AutotestStep - 1   -- retry this step
				return
			end
			ConquestNet_SetTunnel(1)
		end
	end,
	function()
		ScriptCB_SetGameRules("mp")
		gOnlineServiceStr = CONNECT == "lan" and "LAN" or "Direct"
		ScriptCB_SetConnectType(CONNECT)
		log("autotest: connect type " .. CONNECT)
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
	end
end
