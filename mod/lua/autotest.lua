-- Development autotests: if conquest/autotest.txt names a test, run
-- lua/tests/<name>.lua in this Lua state. In the shell, tests get a tick from
-- every screen update and may request a quit to Windows when finished.

local instance = ConquestNet_Instance()
local name = ConquestNet_ReadFile(instance ~= "" and ("autotest." .. instance .. ".txt") or "autotest.txt")
if not name then
	return
end
-- "<test> [args]"
local _, _, testName, args = string.find(name, "^%s*(%S+)%s*(.-)%s*$")
if not testName then
	return
end
name = testName
ConquestNet_AutotestArgs = args

ConquestNet_Log("autotest: running " .. name .. " in " .. tostring(ConquestNet_Context))
ConquestNet_RunFile("lua/tests/" .. name .. ".lua")

if ConquestNet_Context ~= "shell" then
	return
end

-- Screens that wait for a human: track when each is showing so the tick can
-- press through them (title screen, then the profile picker).
local showing = {}
local function watch(screen, key)
	local enter, exit = screen.Enter, screen.Exit
	screen.Enter = function(this, bFwd)
		enter(this, bFwd)
		showing[key] = 0
	end
	screen.Exit = function(this, bFwd)
		showing[key] = nil
		if exit then
			return exit(this, bFwd)
		end
	end
end
watch(ifs_start, "title")
watch(ifs_login, "profiles")

local function pressThroughMenus(dt)
	for key, t in pairs(showing) do
		showing[key] = t + dt
	end
	if showing.title and showing.title > 1 then
		showing.title = nil
		ConquestNet_Log("autotest: accepting title screen")
		ifs_start:Input_Accept()
		return true
	end
	if showing.profiles and showing.profiles > 2 and not ifs_login.bNoInputs then
		local idx = ifs_login_listbox_layout.SelectedIdx or 1
		local entry = ifs_login_listbox_contents[idx]
		if entry and entry.showstr then
			showing.profiles = nil
			ConquestNet_Log("autotest: loading profile " .. tostring(ScriptCB_ununicode(entry.showstr)))
			ifs_login_StartLoadProfile(entry.showstr, nil)
			return true
		end
	end
	return false
end

local START_DELAY = 3
local TICK = 0.5
local elapsed, nextTick = 0, START_DELAY
local baseUpdate = gIFShellScreenTemplate_fnUpdate

gIFShellScreenTemplate_fnUpdate = function(this, fDt)
	baseUpdate(this, fDt)
	elapsed = elapsed + fDt
	if elapsed < nextTick then
		return
	end
	nextTick = elapsed + TICK
	if pressThroughMenus(TICK) then
		return
	end
	if ConquestNet_AutotestQuit then
		ConquestNet_AutotestQuit = ConquestNet_AutotestQuit - TICK
		if ConquestNet_AutotestQuit <= 0 then
			ConquestNet_Log("autotest: quitting game")
			ConquestNet_AutotestQuit = nil
			ScriptCB_QuitToWindows()
		end
	elseif ConquestNet_AutotestTick then
		local ok, err = pcall(ConquestNet_AutotestTick)
		if not ok then
			ConquestNet_Log("autotest: tick failed: " .. tostring(err))
			ConquestNet_AutotestTick = nil
		end
	end
end
