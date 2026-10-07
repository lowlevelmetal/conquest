-- Runs once in every game Lua state (the shell and each battle), before the
-- first ScriptCB_DoFile. Dispatches the rest of the mod once the scripts it
-- patches have loaded.

local function run(file)
	local ok, err = ConquestNet_RunFile(file)
	if not ok then
		ConquestNet_Log("boot: " .. file .. " failed: " .. tostring(err))
	end
end

-- Add "Galactic Conquest" to the Multiplayer menu. That screen builds its
-- buttons while its script loads, so the entry must go into the layout as the
-- buttons are created, not afterwards.
local menuHooked = false
local function hookMultiplayerMenu()
	if menuHooked or not AddVerticalButtons then
		return
	end
	menuHooked = true
	local addVerticalButtons = AddVerticalButtons
	AddVerticalButtons = function(dest, layout)
		if layout and layout == ifs_mp_vbutton_layout and not layout.cgcAdded then
			layout.cgcAdded = true
			table.insert(layout.buttonlist, { tag = "cgc", string = "ifs.sp.meta" })
		end
		return addVerticalButtons(dest, layout)
	end
end

local loadOrder = {}

function ConquestNet_AfterDoFile(name)
	table.insert(loadOrder, name)
	hookMultiplayerMenu()
	if name == "ifs_achievements_test" then
		-- last script loaded by shell_interface, just before it shows the first screen
		ConquestNet_Context = "shell"
		ConquestNet_Log("boot: shell ready after " .. table.getn(loadOrder) .. " scripts")
		run("lua/shell.lua")
	elseif name == "setup_teams" then
		-- every mission script loads setup_teams before defining ScriptInit
		ConquestNet_Context = "mission"
		ConquestNet_Log("boot: mission scripts loading")
		run("lua/mission.lua")
	end
end

ConquestNet_Log("boot: Lua state started, ConquestNet " .. ConquestNet_Version())
