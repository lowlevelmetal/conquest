-- Starting a battle between the two players.
--
-- The mod host always runs the battle server, using the engine's own UDP
-- transport ("lan" connect type, port 3658). The client joins it by IP: the
-- engine's LAN discovery is tunnelled over the mod link (native shim), so the
-- engine finds the host at <host IP>:3658 and connects with its normal
-- handshake. A password made for each battle keeps strangers out.
--
-- Finding the host goes over the mod link, so it works even when the host's
-- UDP 3658 cannot be reached; the engine's own join then fails. The client
-- can then try again, or let the host play the battle alone and wait for
-- the result (ifs_cgc_result). It can always leave with Back.

local main = ifs_freeform_main

local JOIN_RETRY = 15     -- seconds before re-sending the join query
local JOIN_GIVE_UP = 45   -- seconds to find the host's battle once it is up

local function U(text)
	return ScriptCB_tounicode(text)
end

local function eraOf(mission)
	local _, _, era = string.find(mission or "", "^%a%a%a%d(%a)")
	return era or "c"
end

-- 48 bits from the system's secure generator (the engine allows 15 characters)
local function newPassword()
	local hex = ConquestNet_RandomHex(12)
	if not hex then
		hex = string.format("%06x%06x", math.random(0, 16777215), math.random(0, 16777215))
	end
	return "gc" .. hex
end

function CGC.LaunchBattle()
	local s = CGC.session
	s.battle = { mission = main.launchMission, planet = main.planetSelected, attacker = main.playerTeam }
	if s.role == "host" then
		s.password = newPassword()
	end
	CGC.SaveSession()
	ConquestNet_SetValue("cgc_stash", nil)
	-- the battle is set up: anything left over from setting it up is stale
	CGC.Poll()
	local keep = {}
	for _, msg in ipairs(CGC.mailbox) do
		local kind = msg.kind
		if kind ~= "battle" and kind ~= "attack" and kind ~= "undo" and kind ~= "mode" and kind ~= "card" then
			table.insert(keep, msg)
		else
			CGC.Log("dropped a leftover " .. kind .. " message")
		end
	end
	CGC.mailbox = keep
	CGC.Log("battle " .. tostring(s.battle.mission) .. " at " .. tostring(s.battle.planet))
	main:SaveState()
	main:SaveMissionSetup()
	ScriptCB_PushScreen("ifs_cgc_launch")
end

-- leave the engine's net session behind (after a battle, or a join given up),
-- with any error it left (such as "the host has left" from a battle's end)
function CGC.AfterBattleCleanup()
	ScriptCB_CancelLogin()
	ScriptCB_CloseNetShell(1)
	ScriptCB_SetInNetGame(nil)
	ScriptCB_ClearError()
end

local function hostSteps(this)
	local s = CGC.session
	return {
		function()
			gOnlineServiceStr = "LAN"
			ScriptCB_SetConnectType("lan")
			ScriptCB_SetNetLoginName(CGC.LoginName())
			ScriptCB_OpenNetShell(1)
			this.netOpen = true
		end,
		function()
			ScriptCB_SetMissionNames({ { Map = s.battle.mission, Side = 1, SideChar = eraOf(s.battle.mission) } }, nil)
			ScriptCB_SetAmHost(1)
			ScriptCB_SetGameName("Galactic Conquest")
			ScriptCB_SetGameRules("mp")
		end,
		function()
			local p = ScriptCB_GetNetGameDefaults()
			p.PasswordStr = s.password
			p.bAutoAssignTeams = false
			p.iWarmUp = 20
			ScriptCB_SetNetGameDefaults(p)
			ScriptCB_SetDedicated(nil)
			ScriptCB_SetCanSwitchSides(1)
			ScriptCB_BeginLobby()
		end,
		function()
			-- the battle script sends "launch" once the map has loaded (cgc/battle.lua)
			this.launching = true
		end,
	}
end

local function clientSteps(this)
	local s = CGC.session
	return {
		function()
			-- wait for the host's server
			local msg = CGC.Take("launch")
			if not msg then
				return "wait"
			end
			s.password = msg.password
			CGC.SaveSession()
			IFText_fnSetString(this.info.caption, "common.mp.joining")
		end,
		function()
			ScriptCB_SetGameRules("mp")
			gOnlineServiceStr = "LAN"
			ScriptCB_SetConnectType("lan")
			ScriptCB_SetNetLoginName(CGC.LoginName())
			ScriptCB_OpenNetShell(1)
			this.netOpen = true
		end,
		function()
			this.joinStarted = ConquestNet_Time()
			this.lastQuery = this.joinStarted
			ScriptCB_SetAmHost(nil)
			ScriptCB_SetDedicated(nil)
			ScriptCB_BeginJoinIP(s.host, s.password)
			this.joining = true
		end,
	}
end

local function opponentName()
	local name = CGC.session.peerName
	return (name and name ~= "") and name or "The host"
end

-- client: the host's battle went on without us; wait for its result
local function waitForResult(this, why)
	CGC.Log("not in this battle: " .. why)
	this.joining = nil
	this.gaveUp = true
	if this.netOpen then
		this.netOpen = nil
		CGC.AfterBattleCleanup()
	end
	ifs_cgc_result.restart = true
	ScriptCB_PushScreen("ifs_cgc_result")
end

-- client: the engine could not join the host's battle
local function joinFailed(this)
	CGC.Log("could not join the host's battle; is UDP " .. CGC.BATTLE_PORT .. " forwarded to the host?")
	this.joining = nil
	this.prompt = true
	if this.netOpen then
		this.netOpen = nil
		CGC.AfterBattleCleanup()
	end
	Popup_YesNo.CurButton = "yes"
	Popup_YesNo.fnDone = function(again)
		this.prompt = nil
		if again then
			CGC.Log("trying to join again")
			IFObj_fnSetVis(this.info.text, nil)
			IFText_fnSetString(this.info.caption, "common.mp.joining")
			this.steps = clientSteps(this)
			this.step = 2   -- the host's battle is already up
		else
			waitForResult(this, "the player let the host play alone")
		end
	end
	-- the question in the popup, the explanation in the wide panel under it
	IFText_fnSetUString(this.info.caption, U("Could not join " .. opponentName() .. "'s battle"))
	IFText_fnSetUString(this.info.text, U("UDP port " .. CGC.BATTLE_PORT .. " must be forwarded to " ..
		opponentName() .. "'s PC for battles. If you choose No, " .. opponentName() ..
		" plays this battle without you and the campaign goes on."))
	IFObj_fnSetVis(this.info.text, 1)
	Popup_YesNo:fnActivate(1)
	gPopup_fnSetTitleUStr(Popup_YesNo, U("Could not join " .. opponentName() .. "'s battle. Try again?"))
end

-- either player: the other one left or the link went down
local function linkLost(this, quit)
	CGC.Log(quit and "the other player left the campaign" or "lost the connection to the other player")
	this.failed = true
	this.joining = nil
	this.launching = nil
	if this.netOpen then
		this.netOpen = nil
		CGC.AfterBattleCleanup()
	end
	Popup_Ok.fnDone = function()
		CGC.LeaveCampaign(quit and "opponent left" or "connection lost")
	end
	Popup_Ok:fnActivate(1)
	if CGC.session.role == "client" then
		-- the stock messages for a host that quit or dropped
		gPopup_fnSetTitleStr(Popup_Ok, quit and "ifs.mp.joinerrors.hostquit" or "ifs.mp.joinerrors.connectlost")
	else
		local name = CGC.session.peerName or "The other player"
		gPopup_fnSetTitleUStr(Popup_Ok, U(name .. (quit and " left the campaign." or " lost the connection.")))
	end
end

ifs_cgc_launch = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = nil,
	bNohelptext_accept = 1,
	bNohelptext_back = 1,
	bNohelptext_backPC = 1,

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		if not bFwd then
			if this.joinPushed then
				-- the engine's join screen gave up and came back here
				this.joinPushed = nil
				if CGC.Peek("end") or CGC.Peek("result") then
					waitForResult(this, "the host's battle is already over")
				else
					joinFailed(this)
				end
			end
			return
		end
		ifs_freeform_SetButtonVis(this, "accept", nil)
		ifs_freeform_SetButtonVis(this, "back", nil)
		ifs_freeform_SetButtonVis(this, "misc", nil)
		ifs_freeform_SetButtonVis(this, "help", nil)
		IFText_fnSetString(this.title.text, "common.launching")
		local host = CGC.session.role == "host"
		-- the client shows the stock wording for each stage of joining a host
		IFObj_fnSetVis(this.info, (not host) and 1 or nil)
		IFObj_fnSetVis(this.info.text, nil)
		IFText_fnSetString(this.info.caption, "common.waitforhost")
		this.steps = host and hostSteps(this) or clientSteps(this)
		this.step = 1
		this.launching = nil
		this.joining = nil
		this.joinPushed = nil
		this.netOpen = nil
		this.warned = nil
		this.failed = nil
		this.prompt = nil
		this.gaveUp = nil
	end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		main:UpdateZoom()
		main:DrawPlanetIcons()
		main:DrawFleetIcons(main.planetSelected, nil)
		if this.failed or this.prompt or this.gaveUp or not CGC.Active() then
			return
		end

		local host = CGC.session.role == "host"
		if not host then
			-- the battle ended without us (the host could not load it, or left)
			local over = CGC.Take("result") or CGC.Take("end")
			if over then
				if over.kind == "result" then
					table.insert(CGC.mailbox, over)
				end
				return waitForResult(this, "the host's battle is already over")
			end
		end
		local quit = CGC.Peek("quit")
		if quit or CGC.LinkLost() then
			return linkLost(this, quit)
		end

		if this.steps[this.step] then
			if this.steps[this.step]() ~= "wait" then
				this.step = this.step + 1
			end
			return
		end

		if this.launching then
			ScriptCB_UpdateLobby(nil)
			ScriptCB_LaunchLobby()
		elseif this.joining then
			ScriptCB_UpdateQuickmatch()
			if ScriptCB_IsQuickmatchDone() == 1 then
				this.joining = nil
				CGC.Log("found the host's battle; joining")
				-- LaunchQuickmatch re-stores the join password from its argument
				ScriptCB_LaunchQuickmatch(CGC.session.password)
				ifs_missionselect.bForMP = 1
				this.joinPushed = true
				ifs_movietrans_PushScreen(ifs_mp_lobby_quick)
				return
			end
			local now = ConquestNet_Time()
			if now - this.joinStarted > JOIN_GIVE_UP then
				return joinFailed(this)
			end
			if now - this.joinStarted > JOIN_RETRY and not this.warned then
				-- keep trying (the host may still be loading) but say what is wrong
				this.warned = true
				IFText_fnSetString(this.info.caption, "ifs.mp.joinerrors.noconnect")
			end
			if now - this.lastQuery > JOIN_RETRY then
				this.lastQuery = now
				CGC.Log("retrying join")
				ScriptCB_BeginJoinIP(CGC.session.host, CGC.session.password)
			end
		end
	end,

	Input_Accept = function(this) end,

	-- an engine error box was closed (the default would pop this screen)
	fnPostError = function(this, bUserHitYes, level, message)
		CGC.Log("engine network error on the launch screen (level " .. tostring(level) .. ")")
		if CGC.Active() and CGC.session.role == "client" and not (this.failed or this.prompt or this.gaveUp) then
			joinFailed(this)
		end
	end,

	-- the client can give up waiting for the host; the host's battle is already launching
	Input_Back = function(this)
		if this.failed or this.prompt or this.gaveUp or not CGC.Active() or CGC.session.role == "host" then
			return
		end
		this.prompt = true
		Popup_YesNo.CurButton = "no"
		Popup_YesNo.fnDone = function(yes)
			this.prompt = nil
			if yes then
				this.failed = true
				this.joining = nil
				if this.netOpen then
					this.netOpen = nil
					CGC.AfterBattleCleanup()
				end
				CGC.LeaveCampaign("left while joining a battle")
			end
		end
		Popup_YesNo:fnActivate(1)
		gPopup_fnSetTitleStr(Popup_YesNo, "ifs.onlinelobby.leavesession")
	end,
}
ifs_freeform_AddCommonElements(ifs_cgc_launch)
AddIFScreen(ifs_cgc_launch, "ifs_cgc_launch")

-- The engine's join screen gives up (timeout or Cancel) by popping back to the
-- multiplayer menus, which would leave the campaign behind. During an online
-- campaign it goes back to ifs_cgc_launch instead.
local quickCancel = ifs_mp_lobby_quick_fnOnCancel
ifs_mp_lobby_quick_fnOnCancel = function()
	if not (CGC.Active() and CGC.session.battle) then
		return quickCancel()
	end
	Popup_Busy:fnActivate(nil)
	ScriptCB_SetInNetGame(nil)
	ScriptCB_PopScreen()
end

-- The engine shows its network errors in Popup_Error over whatever screen is
-- up, and that screen gets no updates until the box is closed.
--  * A battle's end leaves such errors behind ("the host has left"). In an
--    online campaign they are stale, as the mod's own link says whether the
--    other player is there, so on the campaign's screens the box is closed at
--    once, skipping the screen's post-error handling (its default leaves it).
--  * While the client joins a battle, an error means the join failed: the box
--    closes and the launch screen offers to try again.
local errorActivate = Popup_Error.fnActivate
Popup_Error.fnActivate = function(this, level)
	errorActivate(this, level)
	if not (level and level >= 4 and level <= 12 and CGC.Active()) then
		return
	end
	local screen = gCurScreenTable
	if screen == ifs_mp_lobby_quick or screen == ifs_cgc_launch then
		if CGC.session.role == "client" and CGC.session.battle then
			CGC.Log("the engine could not join the battle (level " .. tostring(level) .. ")")
			this.cgcAction = "join failed"
		end
	else
		CGC.Log("closing a stale engine network error (level " .. tostring(level) .. ")")
		this.cgcAction = "close"
	end
end

local errorUpdate = Popup_Error.Update
Popup_Error.Update = function(this, fDt)
	errorUpdate(this, fDt)
	local action = this.cgcAction
	if not action then
		return
	end
	this.cgcAction = nil
	ScriptCB_CloseErrorBox(true)
	ScriptCB_ClearError()
	if action == "join failed" then
		if gCurScreenTable == ifs_mp_lobby_quick then
			-- back to the launch screen, which offers to try again
			Popup_Busy:fnActivate(nil)
			ScriptCB_SetInNetGame(nil)
			ScriptCB_PopScreen()
		elseif gCurScreenTable == ifs_cgc_launch then
			ifs_cgc_launch:fnPostError(true, 6)
		end
	end
end
