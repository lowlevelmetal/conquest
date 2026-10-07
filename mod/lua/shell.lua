-- Shell-side entry point. For now: environment diagnostics for the smoke test.

local log = ConquestNet_Log

local function describe(name, value)
	log(string.format("diag: %s = %s (%s)", name, tostring(value), type(value)))
end

local function try(name, fn)
	local ok, a, b = pcall(fn)
	if ok then
		log(string.format("diag: %s -> %s, %s", name, tostring(a), tostring(b)))
	else
		log(string.format("diag: %s raised %s", name, tostring(a)))
	end
end

describe("gPlatformStr", gPlatformStr)
describe("gOnlineServiceStr", gOnlineServiceStr)
describe("io", io)
describe("os", os)
describe("loadstring", loadstring)
describe("ifs_freeform_main", ifs_freeform_main)
describe("ifs_main", ifs_main)
describe("ifs_mp_autonet", ifs_mp_autonet)
try("ScriptCB_IsLocalMultiplayerAvailable", function() return ScriptCB_IsLocalMultiplayerAvailable() end)
try("ScriptCB_GetIPAddr", function() return ScriptCB_GetIPAddr() end)
try("ScriptCB_GetConnectType", function() return ScriptCB_GetConnectType() end)
try("ScriptCB_IsMetagameStateSaved", function() return ScriptCB_IsMetagameStateSaved() end)
try("ConquestNet_LocalAddresses", function() return ConquestNet_LocalAddresses() end)
try("loadstring round trip", function() return loadstring("return 40 + 2")() end)

-- confirm screen patching works: log when the main menu is entered
local mainEnter = ifs_main.Enter
ifs_main.Enter = function(this, bFwd)
	log("diag: ifs_main.Enter bFwd=" .. tostring(bFwd))
	ConquestNet_MainMenuSeen = true
	return mainEnter(this, bFwd)
end

ConquestNet_RunFile("lua/autotest.lua")

-- debug: log every screen change so stalls can be diagnosed from the log
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
