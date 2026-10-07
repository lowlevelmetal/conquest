-- Autotest: study the stock UI from the running game.
-- Translates every key in conquest/study_keys.txt with the game's own
-- localization and writes study_strings.txt; dumps the structure of a few
-- stock screens to study_screens.txt.

if ConquestNet_Context ~= "shell" then
	return
end

local function describe(t, depth, prefix, out, seen)
	if depth > 3 or seen[t] then
		return
	end
	seen[t] = true
	local keys = {}
	for k, _ in pairs(t) do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = t[k] or t[tonumber(k)]
		local kind = type(v)
		if kind == "table" then
			table.insert(out, prefix .. k .. " = {")
			describe(v, depth + 1, prefix .. "  ", out, seen)
			table.insert(out, prefix .. "}")
		elseif kind == "number" or kind == "string" or kind == "boolean" then
			table.insert(out, prefix .. k .. " = " .. tostring(v))
		else
			table.insert(out, prefix .. k .. " : " .. kind)
		end
	end
end

local done = false
ConquestNet_AutotestTick = function()
	if done or not ConquestNet_MainMenuSeen then
		return
	end
	done = true

	local keys = ConquestNet_ReadFile("study_keys.txt") or ""
	local out = {}
	for key in string.gfind(keys, "[^\n]+") do
		local ok, u = pcall(ScriptCB_getlocalizestr, key)
		local text = ok and u and ScriptCB_ununicode(u) or "?"
		table.insert(out, key .. "\t" .. string.gsub(text, "\n", "\\n"))
	end
	ConquestNet_WriteFile("study_strings.txt", table.concat(out, "\n"))
	ConquestNet_Log("study: translated " .. table.getn(out) .. " keys")

	local screens = {}
	for _, name in ipairs({ "ifs_mp_lobby", "ifs_mp_lobby_quick", "ifs_freeform_sides", "Popup_Busy",
	                         "Popup_YesNo", "ifs_mp_main", "ifs_freeform_pickscenario", "ifs_sp_campaign",
	                         "ifs_mp_vbutton_layout", "ifs_sp_campaign_vbutton_layout", "ifs_freeform_customsetup" }) do
		local t = _G[name]
		table.insert(screens, "== " .. name .. " (" .. type(t) .. ")")
		if type(t) == "table" then
			describe(t, 0, "", screens, {})
		end
	end
	ConquestNet_WriteFile("study_screens.txt", table.concat(screens, "\n"))
	ConquestNet_Log("study: dumped screens")

	-- which stock UI helpers exist in this build
	for _, name in ipairs({ "ifs_mp_lobby_Listbox_CreateItem", "ifs_mp_lobby_Listbox_PopulateItem", "NewEditbox",
	                         "NewClickableIFButton", "NewPCIFButton", "NewButtonWindow", "ListManager_fnInitList",
	                         "Popup_YesNo", "Popup_Ok", "Popup_Busy", "gPopup_fnSetTitleStr", "gHelptext_fnMoveIcon",
	                         "ScriptCB_GetIPAddr", "ScriptCB_GetCurrentProfileNetName", "ScriptCB_GetProfileName",
	                         "gIFShellScreenTemplate_fnMoveClickableButton", "IFEditbox_fnHilight", "NewHelptext",
	                         "ifs_freeform_sides", "ifs_freeform_main" }) do
		ConquestNet_Log("study: " .. name .. " = " .. type(_G[name]))
	end
	local ok, ip = pcall(ScriptCB_GetIPAddr)
	ConquestNet_Log("study: GetIPAddr -> " .. tostring(ok) .. " " .. tostring(ip))
	ConquestNet_AutotestQuit = 30 -- time to grab a screenshot
end
