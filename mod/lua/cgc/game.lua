-- Networked Galactic Conquest: patches the stock ifs_freeform_* screens so each
-- player commands one faction on their own machine.
--
-- Sync model: whoever owns the current turn plays it with the normal screens.
-- When the turn ends, or a battle starts, that machine sends a snapshot of the
-- whole campaign state; the other machine applies it. The other machine waits
-- in ifs_cgc_wait (replacing the AI turn screen) and reacts to messages:
--   turn    {state}            opponent finished a turn
--   battle  {state}            opponent attacked; follow the battle screens
--   attack / undo {state}      attacker confirmed / backed out of the attack
--   mode    {mission}          defender's chosen game mode
--   card    {team, slot}       a side's bonus card (slot 0 = none)
--   launch  {mission}          host started the battle server (client joins)
--   result  {winner}           host's battle result
--   quit                       the other player left

local function U(text)
	return ScriptCB_tounicode(text)
end

local main = ifs_freeform_main

-- snapshots ---------------------------------------------------------------------

local MAIN_FIELDS = {
	"planetTeam", "planetFleet", "teamResources", "lastSelected", "lastFleet",
	"turnNumber", "playerTeam", "activeBonus", "recentPlanets", "planetResources",
	"battleResources", "winnerTeam", "fleetBattle", "launchMission", "planetNext",
	"planetSelected", "teamVictory",
}

function CGC.Snapshot()
	local s = {}
	for _, f in ipairs(MAIN_FIELDS) do
		s[f] = CGC.Copy(main[f])
	end
	s.unitOwned = CGC.Copy(ifs_purchase_unit_owned)
	s.techCards = CGC.Copy(ifs_purchase_tech_cards)
	s.techUsing = CGC.Copy(ifs_purchase_tech_using)
	s.fleetMove = {
		turnNumber = ifs_freeform_fleet.turnNumber,
		planetStart = ifs_freeform_fleet.planetStart,
		planetNext = ifs_freeform_fleet.planetNext,
	}
	return s
end

-- Recreate fleet models from planetFleet (same as ifs_freeform_main.Enter).
function CGC.RebuildFleets()
	for _, list in pairs(main.fleetPtr) do
		for _, fleet in pairs(list) do
			DeleteEntity(fleet)
		end
	end
	main.fleetPtr = { [1] = {}, [2] = {} }
	for planet, team in pairs(main.planetFleet) do
		if team == 0 then
			main.fleetPtr[1][planet] = CreateEntity(main.fleetClass[1], main.modelMatrix[planet][1])
			main.fleetPtr[2][planet] = CreateEntity(main.fleetClass[2], main.modelMatrix[planet][2])
		else
			main.fleetPtr[team][planet] = CreateEntity(main.fleetClass[team], main.modelMatrix[planet][team])
		end
	end
end

function CGC.ApplySnapshot(s)
	local selected = s.planetSelected
	for _, f in ipairs(MAIN_FIELDS) do
		main[f] = s[f]
	end
	ifs_purchase_unit_owned = s.unitOwned
	ifs_purchase_tech_cards = s.techCards
	ifs_purchase_tech_using = s.techUsing
	ifs_freeform_fleet.turnNumber = s.fleetMove.turnNumber
	ifs_freeform_fleet.planetStart = s.fleetMove.planetStart
	ifs_freeform_fleet.planetNext = s.fleetMove.planetNext
	CGC.RebuildFleets()
	main:SetActiveTeam(main.playerTeam)
	-- force the camera onto the snapshot's planet
	main.planetSelected = nil
	if selected then
		main:SelectPlanet(nil, selected)
	end
end

-- the opponent's side never gets a controller -------------------------------------

local controllers = ifs_freeform_controllers
ifs_freeform_controllers = function(this, teamList)
	controllers(this, teamList)
	if CGC.session and CGC.session.myTeam then
		local mine = CGC.session.myTeam
		this.controllerTeam = { [0] = mine }
		this.controllerPlayer = { [0] = 0 }
		this.teamController = { [mine] = 0 }
		this.startController = 0
	end
end

function CGC.StartGame()
	local s = CGC.session
	CGC.Log("starting " .. s.scenario .. " as team " .. s.myTeam)
	s.started = true
	CGC.SaveSession()
	ConquestNet_SetTunnel(1)
	ScriptCB_ClearMetagameState()
	ScriptCB_SetQuitPlayer(1)
	_G["ifs_freeform_start_" .. s.scenario](main)
	ifs_movietrans_PushScreen(main)
end

-- ifs_freeform_main -------------------------------------------------------------------

local mainEnter = main.Enter
main.Enter = function(this, bFwd)
	if not CGC.Active() then
		return mainEnter(this, bFwd)
	end
	if bFwd and not ScriptCB_IsMetagameStateSaved() then
		-- new campaign: team 1 always moves first on both machines
		local saved = this.controllerTeam[this.startController]
		this.controllerTeam[this.startController] = 1
		mainEnter(this, bFwd)
		this.controllerTeam[this.startController] = saved
		return
	end
	mainEnter(this, bFwd)
	if bFwd and CGC.session.battle then
		CGC.Log("back from battle at " .. tostring(CGC.session.battle.planet))
		CGC.session.battle = nil
		CGC.SaveSession()
	end
end

local nextTurn = main.NextTurn
main.NextTurn = function(this)
	if CGC.Active() and CGC.IsLocalTeam(this.playerTeam) then
		CGC.Send("turn", { state = CGC.Snapshot() })
	end
	return nextTurn(this)
end

-- online games prompt to save only when asked (pause menu quit/save)
local promptSave = main.PromptSave
main.PromptSave = function(this, force)
	if CGC.Active() and not force then
		this.requestSave = nil
	end
	return promptSave(this, force)
end

-- the client never runs the battle's mission logic; the host tells it who won
local lastBattleVictory = ScriptCB_GetLastBattleVictory
ScriptCB_GetLastBattleVictory = function()
	local battleInfo = CGC.Active() and CGC.session.role == "client" and CGC.session.battle
	if battleInfo then
		-- the stock code asks more than once (LoadState, then Enter); keep the
		-- answer until Enter has applied it and cleared session.battle
		if not battleInfo.winner then
			-- normally the battle script already received the host's result
			battleInfo.winner = tonumber(ConquestNet_GetValue("cgc_winner"))
			ConquestNet_SetValue("cgc_winner", nil)
		end
		if not battleInfo.winner then
			-- otherwise it is on its way: the link thread keeps receiving while we wait
			local msg = CGC.Take("result")
			local deadline = ConquestNet_Time() + 10
			while not msg and not CGC.LinkLost() and ConquestNet_Time() < deadline do
				msg = CGC.Take("result")
			end
			battleInfo.winner = msg and msg.winner
			CGC.SaveSession()
			CGC.Log("battle winner from host: " .. tostring(battleInfo.winner))
		end
		return battleInfo.winner or 0
	end
	return lastBattleVictory()
end

-- the opponent's turn: wait for their messages ------------------------------------------

local pushScreen = ScriptCB_PushScreen
ScriptCB_PushScreen = function(name)
	if CGC.Active() and name == "ifs_freeform_ai" then
		name = "ifs_cgc_wait"
	end
	return pushScreen(name)
end

local function opponentFaction()
	local s = CGC.session
	return ScriptCB_ununicode(CGC.TeamName(s.scenario, 3 - s.myTeam))
end

-- the other player as shown in messages: their name, else their faction
local function opponentName()
	local name = CGC.session.peerName
	if name and name ~= "" then
		return name
	end
	return opponentFaction()
end

-- The galaxy's player panel shows the profile name of a locally controlled
-- team (as in hot-seat Versus) and the faction name otherwise. Show the other
-- player's name for their team by handing the stock code that name in place
-- of the faction's.
local updatePlayerText = main.UpdatePlayerText
main.UpdatePlayerText = function(this, player)
	if not CGC.Active() or this.joystick then
		return updatePlayerText(this, player)
	end
	local teamName = this.teamName[this.playerTeam]
	this.teamName[this.playerTeam] = opponentName()
	local ok, err = pcall(updatePlayerText, this, player)
	this.teamName[this.playerTeam] = teamName
	if not ok then
		error(err)
	end
end

ifs_cgc_wait = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = nil,
	bNohelptext_accept = 1,
	bNohelptext_back = 1,
	bNohelptext_backPC = 1,

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		main:SetZoom(1)
		ifs_freeform_SetButtonVis(this, "accept", nil)
		ifs_freeform_SetButtonVis(this, "back", nil)
		ifs_freeform_SetButtonVis(this, "misc", nil)
		ifs_freeform_SetButtonVis(this, "help", nil)
		IFText_fnSetUString(this.title.text, U("Waiting for " .. opponentName()))
		IFObj_fnSetVis(this.info, true)
		IFText_fnSetUString(this.info.caption, U(opponentName() .. " (" .. opponentFaction() .. ") is taking their turn."))
		IFObj_fnSetVis(this.info.text, nil)
		main:UpdatePlayerText(this.player)
	end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		main:UpdateZoom()
		main:DrawLanes(nil, nil)
		main:DrawPlanetIcons()
		main:DrawFleetIcons(main.planetSelected, nil)

		local msg = CGC.Take("turn", "battle")
		if not msg then
			return
		end
		CGC.ApplySnapshot(msg.state)
		if msg.kind == "turn" then
			main:NextTurn()
		else
			CGC.battleRemote = true
			ScriptCB_PushScreen("ifs_freeform_battle")
		end
	end,

	Input_Accept = function(this) end,
	Input_Back = function(this) end,
	Input_Start = function(this)
		ScriptCB_PushScreen("ifs_freeform_menu")
	end,
}
ifs_freeform_AddCommonElements(ifs_cgc_wait)
AddIFScreen(ifs_cgc_wait, "ifs_cgc_wait")

-- battle screen: the attacker confirms or backs out ------------------------------------

local function attackerIsLocal()
	return CGC.IsLocalTeam(main.playerTeam)
end

local battle = ifs_freeform_battle
local battleEnter, battleUpdate = battle.Enter, battle.Update
local battleAccept, battleBack = battle.Input_Accept, battle.Input_Back

battle.Enter = function(this, bFwd)
	battleEnter(this, bFwd)
	if not CGC.Active() then
		return
	end
	if attackerIsLocal() then
		if bFwd then
			CGC.Send("battle", { state = CGC.Snapshot() })
			CGC.battleAnnounced = true
		end
	else
		ifs_freeform_SetButtonVis(this, "accept", nil)
		ifs_freeform_SetButtonVis(this, "back", nil)
		IFText_fnSetUString(this.title.text, U(opponentName() .. " is attacking"))
		IFObj_fnSetVis(this.title, 1)
	end
end

battle.Update = function(this, fDt)
	battleUpdate(this, fDt)
	if not CGC.Active() or attackerIsLocal() then
		return
	end
	local msg = CGC.Take("attack", "undo")
	if msg and msg.kind == "attack" then
		ScriptCB_PushScreen("ifs_freeform_battle_mode")
	elseif msg then
		CGC.ApplySnapshot(msg.state)
		CGC.battleRemote = nil
		ScriptCB_PopScreen()
	end
end

battle.Input_Accept = function(this, joystick)
	if CGC.Active() and not attackerIsLocal() then
		return
	end
	return battleAccept(this, joystick)
end

battle.Input_Back = function(this, joystick)
	if CGC.Active() and not attackerIsLocal() then
		return
	end
	return battleBack(this, joystick)
end

-- backing out of an attack undoes the fleet move on the fleet screen
local fleetEnter = ifs_freeform_fleet.Enter
ifs_freeform_fleet.Enter = function(this, bFwd)
	fleetEnter(this, bFwd)
	if CGC.Active() and not bFwd and CGC.battleAnnounced then
		CGC.battleAnnounced = nil
		CGC.Send("undo", { state = CGC.Snapshot() })
	end
end

-- battle mode: the defender chooses ----------------------------------------------------

local function defenderIsLocal()
	-- during mode/card selection playerTeam may be switched; the attacker owns the turn
	return CGC.IsLocalTeam(3 - CGC.attacker)
end

local mode = ifs_freeform_battle_mode
local modeEnter, modeUpdate, modeAccept = mode.Enter, mode.Update, mode.Input_Accept

mode.Enter = function(this, bFwd)
	if CGC.Active() and bFwd then
		CGC.attacker = main.playerTeam
		if attackerIsLocal() then
			CGC.Send("attack")
		end
	end
	this.cgcWaiting = CGC.Active() and not defenderIsLocal()
	-- the stock screen never clears this; a stale value restores the wrong side on Exit
	this.originalTeam = nil
	modeEnter(this, bFwd)
	if this.cgcWaiting then
		IFObj_fnSetVis(this.buttons, nil)
		ifs_freeform_SetButtonVis(this, "accept", nil)
		IFObj_fnSetVis(this.title, 1)
		IFText_fnSetUString(this.title.text, U(opponentName() .. " is choosing the battle type"))
	end
end

-- record the mission the defender actually picked
local setLaunchMission = main.SetLaunchMission
main.SetLaunchMission = function(this, mission)
	setLaunchMission(this, mission)
	CGC.pickedMission = this.launchMission
end

mode.Input_Accept = function(this, joystick)
	if this.cgcWaiting then
		return
	end
	CGC.pickedMission = nil
	modeAccept(this, joystick)
	if CGC.Active() and CGC.pickedMission then
		CGC.Send("mode", { mission = CGC.pickedMission })
		CGC.pickedMission = nil
	end
end

mode.Update = function(this, fDt)
	modeUpdate(this, fDt)
	if not this.cgcWaiting then
		return
	end
	local msg = CGC.Take("mode")
	if msg then
		this.cgcWaiting = nil
		main:SetLaunchMission(msg.mission)
		ScriptCB_PushScreen("ifs_freeform_battle_card")
	end
end

-- bonus cards: each side picks on its own machine ------------------------------------------

local card = ifs_freeform_battle_card
local cardEnter, cardUpdate, cardAccept = card.Enter, card.Update, card.AcceptBonus
local cardNext = card.Next

card.Enter = function(this, bFwd)
	if not CGC.Active() then
		return cardEnter(this, bFwd)
	end
	this.cgcRemoteTeam = nil
	if CGC.IsLocalTeam(main.playerTeam) then
		return cardEnter(this, bFwd)
	end
	-- show the opponent's cards as a human would see them, but wait for their pick
	this.cgcRemoteTeam = main.playerTeam
	local joystick = main.joystick
	main.joystick = 0
	cardEnter(this, bFwd)
	main.joystick = joystick
	ifs_freeform_SetButtonVis(this, "accept", nil)
	ifs_freeform_SetButtonVis(this, "misc", nil)
	IFText_fnSetUString(this.title.text, U(opponentName() .. " is choosing a bonus"))
end

card.AcceptBonus = function(this)
	if CGC.Active() and not this.cgcRemoteTeam then
		local item = this.selected and this.useActive[this.selected]
		CGC.Send("card", { team = main.playerTeam, slot = item and item.slot or 0 })
	end
	return cardAccept(this)
end

card.Update = function(this, fDt)
	cardUpdate(this, fDt)
	if not this.cgcRemoteTeam or this.displayTimer then
		return
	end
	local msg = CGC.Take("card")
	if msg then
		local index = nil
		for i, item in ipairs(this.useActive) do
			if item.slot == msg.slot then
				index = i
			end
		end
		this.selected = nil
		if index then
			this:SetSelected(index)
		end
		this.cgcRemoteTeam = nil
		cardAccept(this)
	end
end

local function blockWhileRemote(name)
	local orig = card[name]
	card[name] = function(this, joystick)
		if this.cgcRemoteTeam then
			return
		end
		if orig then
			return orig(this, joystick)
		end
	end
end
blockWhileRemote("Input_Accept")
blockWhileRemote("Input_Misc")
blockWhileRemote("Input_GeneralLeft")
blockWhileRemote("Input_GeneralRight")

card.Next = function(this)
	if not (CGC.Active() and this.defending) then
		return cardNext(this)
	end
	-- both sides have chosen: same bookkeeping as the stock code, then the
	-- online battle launch instead of ScriptCB_EnterMission
	this.defending = nil
	main:SetActiveTeam(3 - main.playerTeam)
	CGC.LaunchBattle()
end

-- Bonus cards take effect in the battle simulation, which only the host runs.
-- The client keeps the card bookkeeping (activeBonus, spent cards) in sync but
-- must not arm engine bonuses: they are never consumed by its battle, and the
-- leftover engine state crashed the client's renderer after the battle.
local activateBonus = ActivateBonus
ActivateBonus = function(team, bonus)
	if CGC.Active() and CGC.session.role == "client" then
		CGC.Log("bonus " .. tostring(bonus) .. " for team " .. tostring(team) .. " applies on the host")
		return
	end
	return activateBonus(team, bonus)
end

-- results ---------------------------------------------------------------------------------

local resultAccept = ifs_freeform_result.Input_Accept
ifs_freeform_result.Input_Accept = function(this, joystick)
	if CGC.Active() and not CGC.IsLocalTeam(main.playerTeam) then
		-- the attacker decides what happens next; wait for them
		ScriptCB_PopScreen()
		ScriptCB_PushScreen("ifs_cgc_wait")
		return
	end
	return resultAccept(this, joystick)
end

-- leaving -----------------------------------------------------------------------------------

function CGC.LeaveCampaign(reason)
	CGC.Log("leaving campaign: " .. tostring(reason))
	if CGC.LinkUp() then
		CGC.Send("quit")
	end
	CGC.EndSession(reason)
	ScriptCB_ClearCampaignState()
	ScriptCB_ClearMetagameState()
	ScriptCB_ClearMissionSetup()
	ScriptCB_SetGameRules("instantaction")
	SetState("shell")
end

local menuEnter = ifs_freeform_menu.Enter
ifs_freeform_menu.Enter = function(this, bFwd)
	if CGC.Active() and not bFwd and this.QuitRequested then
		if CGC.LinkUp() then
			CGC.Send("quit")
		end
		CGC.EndSession("quit from menu")
	end
	return menuEnter(this, bFwd)
end

-- watch the link while a campaign is running
local lostShown = false
function CGC.WatchLink()
	if not CGC.Active() or lostShown or CGC.session.battle then
		return
	end
	local quit = CGC.Take("quit")
	if quit or CGC.LinkLost() then
		lostShown = true
		Popup_Ok.fnDone = function()
			CGC.LeaveCampaign("opponent left")
		end
		Popup_Ok:fnActivate(1)
		if CGC.session.role == "client" then
			-- the stock messages for a host that quit or dropped
			gPopup_fnSetTitleStr(Popup_Ok, quit and "ifs.mp.joinerrors.hostquit" or "ifs.mp.joinerrors.connectlost")
		else
			gPopup_fnSetTitleUStr(Popup_Ok, U(opponentName() .. (quit and " left the campaign." or " lost the connection.")))
		end
	end
end
