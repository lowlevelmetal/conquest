-- Starting a battle between the two players.
--
-- The mod host always runs the battle server, using the engine's own UDP
-- transport ("lan" connect type, port 3658). The client joins it by IP: the
-- engine's LAN discovery is tunnelled over the mod link (native shim), so the
-- engine finds the host at <host IP>:3658 and connects with its normal
-- handshake. A per-session password keeps strangers on the host's LAN out.

local main = ifs_freeform_main

local JOIN_RETRY = 15     -- seconds before re-sending the join query
local JOIN_GIVE_UP = 120

local function eraOf(mission)
	local _, _, era = string.find(mission or "", "^%a%a%a%d(%a)")
	return era or "c"
end

function CGC.LaunchBattle()
	local s = CGC.session
	s.battle = { mission = main.launchMission, planet = main.planetSelected, attacker = main.playerTeam }
	if not s.password then
		s.password = string.format("gc%06d", math.random(0, 999999))
	end
	CGC.SaveSession()
	ConquestNet_SetValue("cgc_winner", nil)
	CGC.Log("battle " .. tostring(s.battle.mission) .. " at " .. tostring(s.battle.planet))
	main:SaveState()
	main:SaveMissionSetup()
	ScriptCB_PushScreen("ifs_cgc_launch")
end

local function hostSteps(this)
	local s = CGC.session
	return {
		function()
			gOnlineServiceStr = "LAN"
			ScriptCB_SetConnectType("lan")
			ScriptCB_SetNetLoginName(CGC.LoginName())
			ScriptCB_OpenNetShell(1)
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

ifs_cgc_launch = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = nil,
	bNohelptext_accept = 1,
	bNohelptext_back = 1,
	bNohelptext_backPC = 1,

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
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
		this.warned = nil
	end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		main:UpdateZoom()
		main:DrawPlanetIcons()
		main:DrawFleetIcons(main.planetSelected, nil)

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
				ifs_movietrans_PushScreen(ifs_mp_lobby_quick)
				return
			end
			local now = ConquestNet_Time()
			if now - this.joinStarted > JOIN_GIVE_UP and not this.warned then
				-- keep trying (the host may still be loading) but say what is wrong
				this.warned = true
				IFText_fnSetString(this.info.caption, "ifs.mp.joinerrors.noconnect")
				CGC.Log("join is taking too long; is UDP 3658 forwarded to the host?")
			end
			if now - this.lastQuery > JOIN_RETRY then
				this.lastQuery = now
				CGC.Log("retrying join")
				ScriptCB_BeginJoinIP(CGC.session.host, CGC.session.password)
			end
		end
	end,

	Input_Accept = function(this) end,
	Input_Back = function(this) end,
}
ifs_freeform_AddCommonElements(ifs_cgc_launch)
AddIFScreen(ifs_cgc_launch, "ifs_cgc_launch")

-- after a battle the shell restarts; leave the engine's net session behind
function CGC.AfterBattleCleanup()
	ScriptCB_CancelLogin()
	ScriptCB_CloseNetShell(1)
	ScriptCB_SetInNetGame(nil)
end
