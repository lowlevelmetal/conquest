-- Shell-side entry point: online Galactic Conquest menus and campaign logic.

local log = ConquestNet_Log

local function load(file)
	local ok, err = ConquestNet_RunFile(file)
	if not ok then
		log("shell: " .. file .. " failed: " .. tostring(err))
	end
	return ok
end

-- the per-frame tick is only for battles
ConquestNet_EnableTick(0)

load("lua/cgc/serialize.lua")
load("lua/cgc/link.lua")
load("lua/cgc/menu.lua")
load("lua/cgc/game.lua")
load("lua/cgc/launch.lua")

-- resume a session across the shell restart that follows each battle
local session = CGC.LoadSession()
if session then
	if not session.started then
		CGC.EndSession("shell restarted during the lobby")
	elseif session.battle then
		log("shell: returning from an online battle")
		CGC.AfterBattleCleanup()
	end
end

-- one tick for the whole shell: watch the link while a campaign runs
local watchTimer = 0
local baseUpdate = gIFShellScreenTemplate_fnUpdate
gIFShellScreenTemplate_fnUpdate = function(this, fDt)
	baseUpdate(this, fDt)
	watchTimer = watchTimer + fDt
	if watchTimer >= 0.5 then
		watchTimer = 0
		CGC.WatchLink()
	end
end

-- the main menu is the point where automated tests may start; remember it
-- across shell restarts (after a battle the shell goes straight back to GC)
ConquestNet_MainMenuSeen = ConquestNet_GetValue("main_menu_seen") ~= nil
local mainEnter = ifs_main.Enter
ifs_main.Enter = function(this, bFwd)
	ConquestNet_MainMenuSeen = true
	ConquestNet_SetValue("main_menu_seen", "1")
	return mainEnter(this, bFwd)
end

-- while testing, log every screen change so stalls can be diagnosed from the log
local instance = ConquestNet_Instance()
if ConquestNet_ReadFile(instance ~= "" and ("autotest." .. instance .. ".txt") or "autotest.txt") then
	local function screenName(screen)
		if type(screen) == "string" then
			return screen
		end
		for k, v in pairs(_G) do
			if v == screen then
				return k
			end
		end
		return tostring(screen)
	end
	local push, setScreen, movietrans = ScriptCB_PushScreen, ScriptCB_SetIFScreen, ifs_movietrans_PushScreen
	ScriptCB_PushScreen = function(s) log("screen: push " .. screenName(s)) return push(s) end
	ScriptCB_SetIFScreen = function(s) log("screen: set " .. screenName(s)) return setScreen(s) end
	ifs_movietrans_PushScreen = function(s) log("screen: movietrans " .. screenName(s)) return movietrans(s) end
	-- and anything that leaves the shell
	local function trace(name)
		local fn = _G[name]
		if fn then
			_G[name] = function(a, b, c)
				log("exit-trace: " .. name .. "(" .. tostring(a) .. ") " .. debug.traceback())
				return fn(a, b, c)
			end
		end
	end
	trace("ScriptCB_QuitToWindows")
	trace("ScriptCB_QuitToLauncher")
	trace("ScriptCB_QuitToShell")
	trace("SetState")
	trace("ScriptCB_PopScreen")
end

-- development autotests (not shipped in the player package)
if ConquestNet_ReadFile("lua/autotest.lua") then
	ConquestNet_RunFile("lua/autotest.lua")
end
