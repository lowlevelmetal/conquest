-- Autotest: find the CGC-TEST online session in the session list, join it with
-- the password, and report what happens in the battle and back in the shell.

local log = ConquestNet_Log
local stage = ConquestNet_GetValue("autotest_stage")
local GAME, PASSWORD = "CGC-TEST", "conquest"

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
	ConquestNet_AutotestQuit = 20
	return
end

if stage then
	return
end

local phase, started = "setup", nil

local function finish(why)
	log("autotest: " .. why)
	logError(why)
	phase = "finished"
	setStage("done")
	-- stay open: in local two-instance tests, quitting tears down the shared wineserver
end

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen or phase == "finished" or phase == "launched" then
		return
	end
	if phase == "setup" then
		ScriptCB_SetGameRules("mp")
		ScriptCB_SetConnectType("wan")
		ScriptCB_SetNetLoginName(ScriptCB_GetCurrentProfileNetName())
		ScriptCB_OpenNetShell(1)
		logError("setup")
		phase = "list"
		return
	end
	if phase == "list" then
		ScriptCB_BeginSessionList()
		logError("BeginSessionList")
		started = ConquestNet_Time()
		phase = "search"
		return
	end
	if phase == "search" then
		ScriptCB_UpdateSessionList()
		local names = {}
		for i, s in ipairs(mpsessionlist_listbox_contents) do
			-- namestr is a plain string here (ScriptCB_ununicode would truncate it)
			local name = tostring(s.namestr)
			table.insert(names, name)
			if name == GAME then
				log("autotest: found " .. GAME .. " at row " .. i .. " locked=" .. tostring(s.bLocked))
				mpsessionlist_listbox_layout.SelectedIdx = i
				ScriptCB_BeginJoin(PASSWORD)
				logError("BeginJoin")
				setStage("joining")
				phase = "join"
				started = ConquestNet_Time()
				return
			end
		end
		log("autotest: sessions (" .. table.getn(names) .. "): " .. table.concat(names, ", "))
		if ConquestNet_Time() - started > 60 then
			finish("session not found")
		elseif math.mod(math.floor(ConquestNet_Time() - started), 10) == 0 then
			ScriptCB_BeginSessionList()
		end
		return
	end
	if phase == "join" then
		ScriptCB_UpdateJoin()
		local done = ScriptCB_IsJoinDone()
		log("autotest: join done=" .. tostring(done))
		if done == 1 then
			phase = "launched"
			ScriptCB_LaunchJoin()
			ifs_movietrans_PushScreen(ifs_mp_lobby_quick)
		elseif done == -1 or ConquestNet_Time() - started > 60 then
			finish("join failed")
		end
	end
end
