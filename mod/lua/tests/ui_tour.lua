-- Autotest: walk through screens and log "tour: shot <label>" at each stop so
-- tools/watch_shots.sh can screenshot the window.
--   ui_tour <tour name>

if ConquestNet_Context ~= "shell" then
	return
end

local log = ConquestNet_Log

local function press(screen, tag)
	return function()
		screen.CurButton = tag
		screen:Input_Accept()
	end
end

local tours = {
	-- stock screens, for reference
	vanilla = {
		{ 2, press(ifs_main, "mp"), "mp" },
		{ 3, press(ifs_mp, "lan"), "mp_lan" },
		{ 3, press(ifs_mp_main, "joinip"), "mp_joinip" },
		{ 2, function() ScriptCB_PopScreen() end },
		{ 2, function() ScriptCB_PopScreen() end },
		{ 2, function() ifs_movietrans_PushScreen(ifs_freeform_pickscenario) end, "pickscenario" },
	},
	-- the galaxy as an online campaign shows it (no second player needed until
	-- the turn ends)
	galaxy = {
		{ 2, function()
			CGC.session = { role = "host", scenario = "cw", myTeam = 2, myName = "tour", peerName = "friend" }
			CGC.StartGame()
		end },
		{ 8, function() end, "galaxy_wait" },
	},
	-- online Galactic Conquest screens a single copy can reach
	cgc = {
		{ 4, press(ifs_main, "mp"), "mp" },
		{ 4, press(ifs_mp, "cgc"), "cgc" },
		{ 2, press(ifs_cgc, "join"), "joinbox" },
		{ 4, function()
			-- nobody is hosting here: the join must fail with the stock message
			IFEditbox_fnSetString(ifs_cgc.JoinIPBox.ipedit, "127.0.0.1")
			ifs_cgc.CurButton = "ok"
			ifs_cgc:Input_Accept()
		end, "join_failed" },
		{ 1, function() Popup_Ok:fnActivate(nil) end },
		{ 4, press(ifs_cgc, "host"), "scenario" },
		{ 4, press(ifs_cgc_scenario, "gcw"), "sides" },
		{ 2, function() ifs_cgc_sides:SetSide(2) end, "sides_right" },
		{ 5, function() ifs_cgc_sides.CurButton = nil; ifs_cgc_sides:Input_Accept() end, "lobby_alone" },
		{ 2, function() ifs_cgc_lobby:Input_Back() end, "lobby_leave" },
		{ 4, function() Popup_YesNo:fnActivate(nil); Popup_YesNo.fnDone(true) end, "after_leave" },
		{ 4, function() end, "after_leave_later" },
	},
}

local steps = tours[ConquestNet_AutotestArgs] or {}
local index, wait = 0, 0

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen then
		return
	end
	wait = wait - 0.5
	if wait > 0 then
		return
	end
	local step = steps[index]
	if step and step[3] and not step.shot then
		-- give tools/watch_shots.sh a moment before the next action
		step.shot = true
		log("tour: shot " .. step[3])
		wait = 1
		return
	end
	index = index + 1
	step = steps[index]
	if not step then
		log("tour: done")
		ConquestNet_AutotestQuit = 2
		return
	end
	local ok, err = pcall(step[2])
	if not ok then
		log("tour: step " .. index .. " failed: " .. tostring(err))
	end
	wait = step[1]
end
