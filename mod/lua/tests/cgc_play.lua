-- Autotest: play an online Galactic Conquest campaign between two instances.
--   cgc_play host <scenario> <team> <turns> [battle]
--   cgc_play join <ip> <turns> [battle]
-- Both sides start from the main menu and use the real menus and lobby.
-- "rejoin" (join side) leaves the lobby once and joins again.
-- On its own turns the driver moves a fleet (to a peaceful planet unless
-- "battle" is given), skips bonus cards, picks the first battle mode and ends
-- the turn. It logs a digest of the campaign state after each turn so both
-- logs can be compared for desyncs.
-- How the host ends each battle, after 30 s ("long": 100 s): the attacker
-- wins (default), "defeat" (the defender runs out of reinforcements:
-- MissionDefeat), "tie" (MissionVictory({1,2})) or "quitbattle" (the host
-- quits from its pause menu).
-- "giveup" (join side): when the battle can't be joined, let the host play it
-- alone. "holdleave" (join side): hold the lobby's Leave prompt open for 10 s
-- while the host launches, then stay. "endgame" (host side): after the turns,
-- show the campaign's end screen and leave through it. "pausemenu": on the
-- first own turn, open the pause menu, log which buttons show, and close it.
-- "backout" (join side): press Back on the battle launch screen and leave.
-- "vanish" (host side): the game exits while launching the first battle;
-- "vanishbattle": during it. "leavebattle" (join side): quit each battle
-- (as from the pause menu) after 50 s, leaving the host to finish it.
-- "spawn" (either side): pick the preselected unit and spawn as a soldier in
-- each battle, as a player pressing Spawn (the engine takes CurButton "_ok"
-- on the unit screen as that press). "defenderwins" (host side): the
-- defender wins each battle. "slowresult": stay 15 s on battle results.

local log = ConquestNet_Log
local args = {}
for word in string.gfind(ConquestNet_AutotestArgs or "", "%S+") do
	table.insert(args, word)
end

local role = args[1]
local flags = {}
for _, a in ipairs(args) do
	flags[a] = true
end

if ConquestNet_Context == "mission" then
	-- the host ends each battle quickly so the campaign can continue; by
	-- default the attacker wins, so captured planets show the team numbering
	-- is right
	if role == "host" then
		local raw = ConquestNet_GetValue("cgc_session")
		local session = raw and CGC.Deserialize(raw)
		local winner = session and session.battle and session.battle.attacker or 1
		table.insert(ConquestNet_PostLoad, function()
			if flags.defenderwins then
				winner = 3 - winner
			end
			local how = (flags.defeat and "defeat of team " .. (3 - winner)) or (flags.tie and "a tie")
				or (flags.quitbattle and "the host quitting") or (flags.vanishbattle and "the host's game exiting")
				or ("victory for team " .. winner)
			-- "long": past the joining player's 60 s join timeout
			local after = flags.long and 100 or 30
			log("autotest: ending the battle with " .. how .. " in " .. after .. "s")
			local timer = CreateTimer("autotest_victory")
			SetTimerValue(timer, after)
			StartTimer(timer)
			OnTimerElapse(function()
				if flags.defeat then
					MissionDefeat(3 - winner)
				elseif flags.tie then
					MissionVictory({ 1, 2 })
				elseif flags.quitbattle then
					ScriptCB_QuitToShell()
				elseif flags.vanishbattle then
					log("autotest: the host's game exits")
					ScriptCB_QuitToWindows()
				else
					MissionVictory(winner)
				end
			end, timer)
		end)
	end
	if flags.spawn then
		-- one more step in the battle's per-frame tick: confirm the side and
		-- spawn as a player does, by pressing Enter (the engine reads the
		-- screen's CurButton when the accept key is held: a team on the side
		-- screen, "_ok" for Spawn on the unit screen)
		local battleTick = ConquestNet_Tick
		local lastScreen, pressAt, presses, humansAtUnitScreen, sideShotAt
		local lastHumans, nextCount = -1, 0
		local function screenName(screen)
			for k, v in pairs(_G) do
				if v == screen and type(k) == "string" and string.find(k, "^ifs_") then
					return k
				end
			end
			return tostring(screen)
		end
		-- players (not bots) whose soldier is on the field
		local function humansAlive()
			local n = 0
			for i = 0, 127 do
				local ok, human = pcall(IsCharacterHuman, i)
				if ok and human then
					local ok2, unit = pcall(GetCharacterUnit, i)
					if ok2 and unit then
						n = n + 1
					end
				end
			end
			return n
		end
		ConquestNet_Tick = function()
			if battleTick then
				battleTick()
			end
			if not ConquestNet_Tick then
				return   -- the battle script is leaving
			end
			local now = ConquestNet_Time()
			if now >= nextCount then
				nextCount = now + 1
				local humans = humansAlive()
				if humans ~= lastHumans then
					lastHumans = humans
					log("autotest: players on the field: " .. humans)
					if humans == 2 then
						local n = (tonumber(ConquestNet_GetValue("autotest_spawns")) or 0) + 1
						ConquestNet_SetValue("autotest_spawns", tostring(n))
						log("tour: shot spawned" .. n)
					end
				end
			end
			local screen = gCurScreenTable
			local name = screen and screenName(screen) or ""
			if screen ~= lastScreen then
				lastScreen = screen
				log("autotest: battle screen " .. name)
				pressAt, presses = now + 2, 0
				humansAtUnitScreen = lastHumans
				if string.find(name, "^ifs_sideselect") and screen.buttons then
					-- which choices the player has (dimmed ones can't be picked)
					local states = {}
					for _, tag in ipairs({ "team1", "team2", "auto", "spec" }) do
						local b = screen.buttons[tag]
						table.insert(states, tag .. "=" .. (not b and "none" or b.hidden and "hidden"
							or b.bDimmed and "dimmed" or "open"))
					end
					log("autotest: side buttons " .. table.concat(states, " ") .. ", selected " .. tostring(screen.CurButton))
					-- a screenshot once the menu has settled, then the press
					sideShotAt, pressAt = now + 4, now + 6
				end
			end
			if sideShotAt and now >= sideShotAt then
				sideShotAt = nil
				log("tour: shot sides_" .. role)
			end
			local onSides = string.find(name, "^ifs_sideselect")
			local onMap = string.find(name, "^ifs_mapselect")
			local onUnits = string.find(name, "^ifs_charselect")
			-- still on a spawn screen once the soldier is out: stop pressing
			if (onUnits or onMap) and lastHumans > humansAtUnitScreen then
				return
			end
			if (onSides or onMap or onUnits) and pressAt and now >= pressAt and presses < 6 then
				pressAt, presses = now + 2, presses + 1
				-- the unit screen's Spawn button; on the map, the spawn point
				-- as chosen first, then Spawn
				if onUnits or (onMap and presses > 2) then
					screen.CurButton = "_ok"
				end
				log("autotest: pressing Enter on " .. name .. " (CurButton " .. tostring(screen.CurButton) .. ")")
				ConquestNet_TestPress(40, 13)   -- SDL_SCANCODE_RETURN, SDLK_RETURN
			end
		end
	end
	if flags.leavebattle and role ~= "host" then
		-- mission timers only run on the host's server: use the battle's tick
		local battleTick = ConquestNet_Tick
		local quitAt = ConquestNet_Time() + 50
		log("autotest: leaving the battle in 50s")
		ConquestNet_Tick = function()
			if battleTick then
				battleTick()
			end
			if quitAt and ConquestNet_Tick and ConquestNet_Time() >= quitAt then
				quitAt = nil
				log("autotest: quitting the battle")
				ScriptCB_QuitToShell()
			end
		end
	end
	return
end
local wantBattle = flags.battle
local turnsWanted = tonumber(role == "host" and args[4] or args[3]) or 2
local main = ifs_freeform_main

local function digest()
	local parts = {}
	local planets = {}
	for planet, _ in pairs(main.planetTeam or {}) do
		table.insert(planets, planet)
	end
	table.sort(planets)
	for _, planet in ipairs(planets) do
		table.insert(parts, planet .. "=" .. tostring(main.planetTeam[planet]) .. "/" .. tostring(main.planetFleet[planet]))
	end
	return string.format("turn %s active %s res %s/%s %s", tostring(main.turnNumber), tostring(main.playerTeam),
		tostring(main.teamResources and main.teamResources[1]), tostring(main.teamResources and main.teamResources[2]),
		table.concat(parts, " "))
end

-- which screen is showing, and for how long
local current, since = nil, 0
local function watch(screen, name)
	local enter = screen.Enter
	screen.Enter = function(this, bFwd)
		current, since = name, 0
		log("autotest: screen " .. name .. (bFwd and "" or " (back)"))
		enter(this, bFwd)
		log("autotest: screen " .. name .. " entered")
	end
end
watch(ifs_freeform_fleet, "fleet")
watch(ifs_freeform_summary, "summary")
watch(ifs_freeform_battle, "battle")
watch(ifs_freeform_battle_mode, "mode")
watch(ifs_freeform_battle_card, "card")
watch(ifs_freeform_result, "result")
watch(ifs_freeform_end, "end")
watch(ifs_cgc_wait, "wait")
watch(ifs_cgc_launch, "launch")
watch(ifs_cgc_result, "result_wait")

-- ask tools/watch_shots.sh for one screenshot per label
local function shot(label)
	if not ConquestNet_GetValue("shot_" .. label) then
		ConquestNet_SetValue("shot_" .. label, "1")
		log("tour: shot " .. label)
		return true
	end
end

-- The pause menu keeps the screen update it was created with, so the tick
-- (hooked into gIFShellScreenTemplate_fnUpdate) would stop while it is open
if flags.pausemenu then
	ifs_freeform_menu.Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
	end
end

local turnsDone = tonumber(ConquestNet_GetValue("autotest_turns")) or 0
local acted = {}
local pauseStage, pauseAt = ConquestNet_GetValue("autotest_paused") and "done", 0

local function isFight(team, planet)
	return main.planetTeam[planet] == 3 - team or main.planetFleet[planet] == 3 - team or main.planetFleet[planet] == 0
end

-- first step on the shortest lane path from start to the nearest enemy
local function stepTowardEnemy(team, start)
	local cameFrom = { [start] = start }
	local queue = { start }
	local head = 1
	while queue[head] do
		local planet = queue[head]
		head = head + 1
		for _, dest in ipairs(main.planetDestination[planet]) do
			if not cameFrom[dest] and main.planetFleet[dest] ~= team then
				cameFrom[dest] = planet
				if isFight(team, dest) then
					while cameFrom[dest] ~= start do
						dest = cameFrom[dest]
					end
					return dest
				end
				table.insert(queue, dest)
			end
		end
	end
end

local function chooseMove(team)
	local fallback
	for start, owner in pairs(main.planetFleet) do
		if owner == team then
			if wantBattle then
				local step = stepTowardEnemy(team, start)
				if step and ifs_freeform_fleet:IsValidMove(team, start, step) then
					return start, step
				end
			end
			for _, dest in ipairs(main.planetDestination[start]) do
				if ifs_freeform_fleet:IsValidMove(team, start, dest) then
					if not wantBattle and not isFight(team, dest) then
						return start, dest
					end
					fallback = fallback or { start, dest }
				end
			end
		end
	end
	if fallback then
		return fallback[1], fallback[2]
	end
end

-- Go through Multiplayer > Galactic Conquest like a player: one action per
-- screen once its transition has finished (an action returning nil retries).
local lobbyTime = 0
local menuActions = {
	[ifs_main] = function(this)
		log("autotest: choosing Multiplayer")
		this.CurButton = "mp"
		this:Input_Accept()
		return true
	end,
	[ifs_mp] = function(this)
		log("autotest: choosing Galactic Conquest")
		this.CurButton = "cgc"
		this:Input_Accept()
		return true
	end,
	[ifs_cgc] = function(this)
		if role == "host" then
			log("autotest: Host Lobby")
			this.CurButton = "host"
			this:Input_Accept()
			return true
		end
		if not this.bJoinBoxVis then
			log("autotest: Join Lobby")
			this.CurButton = "join"
			this:Input_Accept()
			return nil
		end
		IFEditbox_fnSetString(this.JoinIPBox.ipedit, args[2])
		if shot("joinbox") then
			return nil
		end
		log("autotest: joining " .. args[2])
		this.CurButton = "ok"
		this:Input_Accept()
		return true
	end,
	[ifs_cgc_scenario] = function(this)
		log("autotest: scenario " .. args[2])
		this.CurButton = args[2]
		this:Input_Accept()
		return true
	end,
	[ifs_cgc_sides] = function(this)
		log("autotest: side " .. args[3])
		this:SetSide(tonumber(args[3]))
		this.CurButton = nil
		this:Input_Accept()
		return true
	end,
	[ifs_cgc_lobby] = function(this)
		if role ~= "host" then
			shot("lobby")
			-- "rejoin": leave the lobby once, as a player changing their mind
			if flags.rejoin and not ConquestNet_GetValue("autotest_left_lobby") then
				ConquestNet_SetValue("autotest_left_lobby", "1")
				log("autotest: leaving the lobby to join again")
				this:Input_Back()
				Popup_YesNo:fnActivate(nil)
				Popup_YesNo.fnDone(true)
			end
			-- "holdleave": the Leave prompt is open while the host launches
			if flags.holdleave and not ConquestNet_GetValue("autotest_held_leave") then
				ConquestNet_SetValue("autotest_held_leave", "1")
				log("autotest: opening the Leave prompt")
				this:Input_Back()
				ConquestNet_AutotestCloseLeaveAt = ConquestNet_Time() + 10
			end
			return true
		end
		-- give both lobbies a moment on screen, as a player would
		lobbyTime = this.peer and lobbyTime + 1 or 0
		if lobbyTime == 2 then
			shot("lobby")
		end
		-- and wait for the battle-port check, as a player reading the lobby would
		if lobbyTime < 5 or (this.udp == "probing" and lobbyTime < 15) then
			return nil
		end
		if this.udp then
			shot("lobby_udp_" .. this.udp)
		end
		log("autotest: launching with " .. tostring(this.peer.name))
		this.CurButton = "launch"
		this:Input_Accept()
		return true
	end,
}

local menuScreen, menuWait, menuDone
local function driveMenus()
	if ConquestNet_AutotestCloseLeaveAt and ConquestNet_Time() >= ConquestNet_AutotestCloseLeaveAt then
		ConquestNet_AutotestCloseLeaveAt = nil
		log("autotest: staying in the lobby (Leave prompt: No)")
		Popup_YesNo:fnActivate(nil)
		Popup_YesNo.fnDone(false)
		return
	end
	local screen = gCurScreenTable
	if screen ~= menuScreen then
		menuScreen, menuWait, menuDone = screen, 2, nil
	end
	if menuDone or ScriptCB_IsPopupOpen() then
		return
	end
	menuWait = menuWait - 0.5
	if menuWait > 0 then
		return
	end
	menuWait = 1
	local action = menuActions[screen]
	if action then
		-- a screenshot of each menu first (the lobby takes its own)
		local name
		for key, value in pairs({ main = ifs_main, mp = ifs_mp, cgc = ifs_cgc, scenario = ifs_cgc_scenario, sides = ifs_cgc_sides }) do
			if value == screen then
				name = key
			end
		end
		if name and shot(role .. "_" .. name) then
			return
		end
		menuDone = action(screen)
	end
end

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen then
		return
	end
	since = since + 0.5

	if not CGC.Active() then
		if not ConquestNet_GetValue("autotest_started") then
			driveMenus()
		end
		return
	end
	ConquestNet_SetValue("autotest_started", "1")
	if current == "launch" and flags.backout and ifs_cgc_launch.step and not acted.backout then
		acted.backout = true
		log("autotest: leaving the campaign from the launch screen")
		ifs_cgc_launch:Input_Back()
		Popup_YesNo:fnActivate(nil)
		Popup_YesNo.fnDone(true)
		return
	end
	if current == "launch" and flags.vanish and role == "host" then
		log("autotest: the host's game exits")
		ScriptCB_QuitToWindows()
		return
	end
	if since >= 2.5 and current then
		shot(current)
	end
	if since < 2 then
		return
	end
	if not CGC.Active() or since < 2 then
		return
	end
	local mine = CGC.IsLocalTeam(main.playerTeam)
	local key = tostring(main.turnNumber) .. current

	if flags.pausemenu and current == "fleet" and mine and not pauseStage then
		pauseStage, pauseAt = "open", since
		ConquestNet_SetValue("autotest_paused", "1")
		log("autotest: opening the pause menu")
		ScriptCB_PushScreen("ifs_freeform_menu")
		return
	end
	if pauseStage == "open" or pauseStage == "close" then
		if since - pauseAt < 2 then
			return
		end
		if pauseStage == "open" then
			local shown = {}
			for _, item in ipairs(ifsfreeformmenu_vbutton_layout.buttonlist) do
				local button = ifs_freeform_menu.buttons[item.tag]
				if button and not button.hidden then
					table.insert(shown, item.tag)
				end
			end
			log("autotest: pause menu shows " .. table.concat(shown, ","))
			shot("pausemenu")
			pauseStage, pauseAt = "close", since
		else
			pauseStage = "done"
			log("autotest: closing the pause menu")
			ScriptCB_PopScreen()
		end
		return
	end
	if current == "launch" and ifs_cgc_launch.prompt and flags.giveup and not acted["giveup" .. key] then
		-- a moment on screen first, for the screenshot
		acted["wait" .. key] = (acted["wait" .. key] or 0) + 1
		if acted["wait" .. key] == 1 then
			shot("joinfail")
		end
		if acted["wait" .. key] < 4 then
			return
		end
		acted["giveup" .. key] = true
		log("autotest: cannot join the battle; letting the host play it")
		Popup_YesNo:fnActivate(nil)
		Popup_YesNo.fnDone(false)
		return
	end
	if current == "fleet" and mine and not acted[key] then
		acted[key] = true
		if turnsDone >= turnsWanted then
			log("autotest: done after " .. turnsDone .. " turns: " .. digest())
			if flags.endgame then
				log("autotest: ending the campaign through the end screen")
				main.teamVictory = main.playerTeam
				ScriptCB_PushScreen("ifs_freeform_end")
			end
			return
		end
		-- buy and equip a bonus card when affordable (stock AI purchase code)
		local team = main.playerTeam
		local using = ifs_purchase_tech_using[team]
		if not flags.nocards and not ConquestNet_GetValue("autotest_card" .. team) and main.teamResources[team] >= 40 then
			ConquestNet_SetValue("autotest_card" .. team, "1")
			ifs_freeform_ai:PurchaseTech(team, 1)
			ifs_freeform_ai:PurchaseTech(team, 1)
			log("autotest: bought and equipped " .. tostring(ifs_purchase_tech_table[1].name) ..
				" slots " .. table.concat(using, ","))
		end
		local start, dest = chooseMove(main.playerTeam)
		log("autotest: move " .. tostring(start) .. " -> " .. tostring(dest) .. " | " .. digest())
		if start then
			ifs_freeform_fleet:AttemptMove(main.playerTeam, start, dest)
		else
			-- no fleet to move: end the turn, as the player would from the summary
			ScriptCB_PushScreen("ifs_freeform_summary")
		end
	elseif current == "summary" and mine and not acted[key] then
		acted[key] = true
		turnsDone = turnsDone + 1
		ConquestNet_SetValue("autotest_turns", tostring(turnsDone))
		log("autotest: ending turn " .. turnsDone .. " | " .. digest())
		main:NextTurn()
	elseif current == "battle" and mine and not acted[key] then
		acted[key] = true
		log("autotest: attacking | " .. digest())
		ifs_freeform_battle.CurButton = "_accept"
		ifs_freeform_battle:Input_Accept(-1)
	elseif current == "mode" and not ifs_freeform_battle_mode.cgcWaiting and not acted[key] then
		acted[key] = true
		log("autotest: picking mode " .. tostring(ifs_freeform_battle_mode.CurButton))
		ifs_freeform_battle_mode:Input_Accept()
	elseif current == "card" and not ifs_freeform_battle_card.cgcRemoteTeam and not ifs_freeform_battle_card.displayTimer
		and not acted[key .. tostring(main.playerTeam)] then
		acted[key .. tostring(main.playerTeam)] = true
		local card = ifs_freeform_battle_card
		local pick = nil
		for i, item in ipairs(card.useActive) do
			if not pick and item.weight > 0 then
				pick = i
			end
		end
		log("autotest: team " .. tostring(main.playerTeam) .. " plays card " .. tostring(pick and card.useActive[pick].name))
		card.selected = nil
		if pick then
			card:SetSelected(pick)
		end
		card:AcceptBonus()
	elseif current == "result" and since > (flags.slowresult and 15 or 4) and not acted[key] then
		acted[key] = true
		log("autotest: accepting result | " .. digest())
		ifs_freeform_result.CurButton = "_accept"
		ifs_freeform_result:Input_Accept(-1)
	elseif current == "end" and since > 4 and not acted[key] then
		acted[key] = true
		log("autotest: leaving the end screen")
		ifs_freeform_end:Input_Accept()
	elseif current == "wait" and since > 1 and not acted[key] then
		acted[key] = true
		log("autotest: waiting | " .. digest())
	end
end
