-- Autotest: play an online Galactic Conquest campaign between two instances.
--   cgc_play host <scenario> <team> <turns> [battle]
--   cgc_play join <ip> <turns> [battle]
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

if ConquestNet_Context == "mission" then
	-- the host ends each battle quickly so the campaign can continue
	if role == "host" then
		table.insert(ConquestNet_PostLoad, function()
			log("autotest: forcing victory for team 1 in 30s")
			local timer = CreateTimer("autotest_victory")
			SetTimerValue(timer, 30)
			StartTimer(timer)
			OnTimerElapse(function()
				MissionVictory(1)
			end, timer)
		end)
	end
	return
end
local wantBattle = args[table.getn(args)] == "battle"
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
		return enter(this, bFwd)
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

local turnsDone = tonumber(ConquestNet_GetValue("autotest_turns")) or 0
local acted = {}

local function chooseMove(team)
	local fallback
	for start, owner in pairs(main.planetFleet) do
		if owner == team then
			for _, dest in ipairs(main.planetDestination[start]) do
				if ifs_freeform_fleet:IsValidMove(team, start, dest) then
					local fight = main.planetTeam[dest] == 3 - team or main.planetFleet[dest] == 3 - team
					if fight == wantBattle then
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

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen then
		return
	end
	since = since + 0.5

	if not CGC.session and not ConquestNet_GetValue("autotest_started") then
		ConquestNet_SetValue("autotest_started", "1")
		if role == "host" then
			log("autotest: hosting " .. args[2] .. " as team " .. args[3])
			ifs_movietrans_PushScreen(ifs_cgc)
			ifs_cgc.CurButton = "host_" .. args[2] .. "_" .. args[3]
			ifs_cgc:Input_Accept()
		else
			log("autotest: joining " .. args[2])
			ifs_movietrans_PushScreen(ifs_cgc)
			ConquestNet_JoinFor = args[2]
			CGC.session = { role = "client", host = args[2] }
			CGC.SaveSession()
			ifs_movietrans_PushScreen(ifs_cgc_status)
		end
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
		local start, dest = chooseMove(main.playerTeam)
		log("autotest: move " .. tostring(start) .. " -> " .. tostring(dest) .. " | " .. digest())
		if start then
			ifs_freeform_fleet:AttemptMove(main.playerTeam, start, dest)
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
		log("autotest: skipping bonus card for team " .. tostring(main.playerTeam))
		ifs_freeform_battle_card:SetSelected(nil)
		ifs_freeform_battle_card:AcceptBonus()
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
