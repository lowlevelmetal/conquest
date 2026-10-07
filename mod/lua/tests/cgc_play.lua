-- Autotest: play an online Galactic Conquest campaign between two instances.
--   cgc_play host <scenario> <team> <turns> [battle]
--   cgc_play join <ip> <turns> [battle]
-- Both sides start from the main menu and use the real menus and lobby.
-- "rejoin" (join side) leaves the lobby once and joins again.
-- On its own turns the driver moves a fleet (to a peaceful planet unless
-- "battle" is given), skips bonus cards, picks the first battle mode and ends
-- the turn. It logs a digest of the campaign state after each turn so both
-- logs can be compared for desyncs.

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
	-- the host ends each battle quickly so the campaign can continue; the
	-- attacker wins, so captured planets show the team numbering is right
	if role == "host" then
		local raw = ConquestNet_GetValue("cgc_session")
		local session = raw and CGC.Deserialize(raw)
		local winner = session and session.battle and session.battle.attacker or 1
		table.insert(ConquestNet_PostLoad, function()
			log("autotest: forcing victory for attacker team " .. winner .. " in 30s")
			local timer = CreateTimer("autotest_victory")
			SetTimerValue(timer, 30)
			StartTimer(timer)
			OnTimerElapse(function()
				MissionVictory(winner)
			end, timer)
		end)
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

-- ask tools/watch_shots.sh for one screenshot per label
local function shot(label)
	if not ConquestNet_GetValue("shot_" .. label) then
		ConquestNet_SetValue("shot_" .. label, "1")
		log("tour: shot " .. label)
		return true
	end
end

local turnsDone = tonumber(ConquestNet_GetValue("autotest_turns")) or 0
local acted = {}

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
			return true
		end
		-- give both lobbies a moment on screen, as a player would
		lobbyTime = this.peer and lobbyTime + 1 or 0
		if lobbyTime == 2 then
			shot("lobby")
		end
		if lobbyTime < 5 then
			return nil
		end
		log("autotest: launching with " .. tostring(this.peer.name))
		this.CurButton = "launch"
		this:Input_Accept()
		return true
	end,
}

local menuScreen, menuWait, menuDone
local function driveMenus()
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

	if current == "fleet" and mine and not acted[key] then
		acted[key] = true
		if turnsDone >= turnsWanted then
			log("autotest: done after " .. turnsDone .. " turns: " .. digest())
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
	elseif current == "result" and since > 4 and not acted[key] then
		acted[key] = true
		log("autotest: accepting result | " .. digest())
		ifs_freeform_result.CurButton = "_accept"
		ifs_freeform_result:Input_Accept(-1)
	elseif current == "wait" and since > 1 and not acted[key] then
		acted[key] = true
		log("autotest: waiting | " .. digest())
	end
end
