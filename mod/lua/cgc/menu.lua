-- Menus for online Galactic Conquest: Multiplayer -> Galactic Conquest.
--   ifs_cgc           Host Lobby, or Join Lobby with the stock "IP :" box
--   ifs_cgc_scenario  host: Select Scenario (Clone Wars / Galactic Civil War)
--   ifs_cgc_sides     host: Please select a side.
--   ifs_cgc_lobby     both players, until the host launches the campaign
-- Each screen copies the stock screen it stands in for (ifs_mp_main's Join IP
-- box, ifs_freeform_pickscenario, ifs_freeform_sides, ifs_mp_lobby) and uses
-- the game's own localized strings wherever the game has one.
--
-- The Galactic Conquest button itself is added to the Multiplayer menu's
-- layout in boot.lua, before that screen builds its buttons.
--
-- Lobby messages: the joining player sends hello {protocol, version, name};
-- the host answers setup {scenario, hostTeam, name, udp} or refuse {reason};
-- ping/pong measure latency; udp {ok} reports the battle-port check; start
-- launches the campaign; bye leaves the lobby.
--
-- The host's port stays open while the lobby is up (native net.c): a
-- connection becomes the player once it sends its first message, which must
-- be hello. Anyone else connecting meanwhile is refused as full.

local function U(text)
	return ScriptCB_tounicode(text)
end

local HELLO_TIMEOUT = 5   -- seconds from a connection's first message to its hello
local PING_INTERVAL = 2

local function teamColor(team)
	if team == 1 then
		return 32, 96, 255
	end
	return 255, 32, 32
end

-- shared by the four screens: an Update that also gives the shell's tick
-- (link watch, autotests) a chance to run
local function update(this, fDt)
	gIFShellScreenTemplate_fnUpdate(this, fDt)
end

local function showPopupOk(key, fnDone)
	Popup_Ok.fnDone = fnDone or function() end
	Popup_Ok:fnActivate(1)
	gPopup_fnSetTitleStr(Popup_Ok, key)
end

local function showPopupOkText(ustr, fnDone)
	Popup_Ok.fnDone = fnDone or function() end
	Popup_Ok:fnActivate(1)
	gPopup_fnSetTitleUStr(Popup_Ok, ustr)
end

-- a clickable button in the bottom-right corner, mirroring the shell's Back button
local function rightCornerButton(tag, key)
	local width = 150
	local button = NewPCIFButton {
		ScreenRelativeX = 1.0,
		ScreenRelativeY = 1.0,
		y = -15,
		x = -width * 0.5,
		btnw = width,
		btnh = 25,
		font = "gamefont_medium",
		bg_tail = 20,
		tag = tag,
	}
	RoundIFButtonLabel_fnSetString(button, key)
	return button
end

-- Galactic Conquest: Host Lobby / Join Lobby ----------------------------------------

ifs_cgc_vbutton_layout = {
	xWidth = 400,
	width = 400,
	xSpacing = 10,
	ySpacing = 5,
	font = gMenuButtonFont,
	buttonlist = {
		{ tag = "host", string = "ifs.mplobby.host_title" },
		{ tag = "join", string = "common.join" },
	},
	title = "ifs.sp.meta",
}

local function showJoinBox(this, vis)
	this.bJoinBoxVis = vis
	IFObj_fnSetVis(this.JoinIPBox, vis)
	IFObj_fnSetVis(this.JoinIPBtn, vis)
	local edit = this.JoinIPBox.ipedit
	if vis then
		IFEditbox_fnSetString(edit, ScriptCB_GetProfileJoinIP() or "")
		edit.bKeepsFocus = 1
		gCurEditbox = edit
		IFEditbox_fnHilight(edit, 1)
	elseif gCurEditbox == edit then
		IFEditbox_fnHilight(edit, nil)
		gCurEditbox = nil
	end
end

-- joining: connect, then wait for the host's setup behind the stock busy popup
local join = {}

local function joinCheck()
	-- a refusal arrives just before the host closes the connection
	local refused = CGC.Take("refuse")
	if refused then
		join.error = refused.reason == "full" and "ifs.mp.joinerrors.full" or "ifs.onlinelobby.wrongver"
		return -1
	end
	local state = ConquestNet_Status()
	if state == "error" or state == "closed" then
		join.error = join.error or "ifs.mp.joinerrors.noconnect"
		return -1
	end
	if state ~= "connected" then
		return 0
	end
	if not join.helloSent then
		join.helloSent = true
		CGC.Send("hello", { protocol = CGC.PROTOCOL, version = ConquestNet_Version(), name = CGC.PlayerName() })
	end
	local setup = CGC.Take("setup")
	if setup then
		local s = CGC.session
		s.scenario = setup.scenario
		s.myTeam = 3 - setup.hostTeam
		s.peerName = CGC.CleanName(setup.name)
		s.udpCheck = setup.udp and true or nil
		CGC.SaveSession()
		return 1
	end
	return 0
end

-- Popup_Busy polls this every frame and may sit on an outcome for its
-- minimum display time, so a result, once reached, keeps being reported
local function joinCheckDone()
	if not join.result then
		local result = joinCheck()
		if result == 0 then
			return 0
		end
		join.result = result
	end
	return join.result
end

local function joinSuccess()
	Popup_Busy:fnActivate(nil)
	CGC.Log("joined the lobby of " .. tostring(CGC.session.peerName))
	ifs_movietrans_PushScreen(ifs_cgc_lobby)
end

local function joinFail()
	Popup_Busy:fnActivate(nil)
	CGC.EndSession("join failed")
	showPopupOk(join.error or "ifs.mp.joinerrors.noconnect")
end

local function joinCancel()
	CGC.EndSession("join cancelled")
end

local function beginJoin(this)
	local address = string.gsub(IFEditbox_fnGetString(this.JoinIPBox.ipedit) or "", "%s", "")
	if address == "" then
		ifelm_shellscreen_fnPlaySound("shell_menu_error")
		return
	end
	showJoinBox(this, nil)
	ScriptCB_SetProfileJoinIP(address)

	CGC.session = { role = "client", host = address, myName = CGC.PlayerName() }
	CGC.mailbox = {}
	CGC.SaveSession()
	join = {}
	local ok, err = ConquestNet_Connect(address, CGC.PORT)
	if not ok then
		CGC.Log("connect failed: " .. tostring(err))
		join.error = "ifs.mp.joinerrors.noconnect"
	end

	Popup_Busy.fnCheckDone = joinCheckDone
	Popup_Busy.fnOnSuccess = joinSuccess
	Popup_Busy.fnOnFail = joinFail
	Popup_Busy.fnOnCancel = joinCancel
	Popup_Busy.bNoCancel = nil
	Popup_Busy.fTimeout = 15
	-- a refused connection fails at once; let the popup open properly first
	Popup_Busy.fMinTimeout = 1
	IFText_fnSetString(Popup_Busy.title, "common.mp.joining")
	Popup_Busy:fnActivate(1)
end

ifs_cgc = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = "shell_sub_left",
	bAcceptIsSelect = 1,

	buttons = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = gDefaultButtonScreenRelativeY,
	},

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		this.CurButton = ShowHideVerticalButtons(this.buttons, ifs_cgc_vbutton_layout)
		RoundIFButtonLabel_fnSetUString(this.buttons.join, U("Join Lobby"))
		SetCurButton(this.CurButton)
		showJoinBox(this, nil)
	end,

	Exit = function(this, bFwd)
		showJoinBox(this, nil)
	end,

	Update = update,

	Input_Accept = function(this)
		if gShellScreen_fnDefaultInputAccept(this) then
			return
		end
		ifelm_shellscreen_fnPlaySound(this.acceptSound)
		if this.CurButton == "host" then
			showJoinBox(this, nil)
			ifs_movietrans_PushScreen(ifs_cgc_scenario)
		elseif this.CurButton == "join" or this.CurButton == "ok" then
			if this.bJoinBoxVis then
				beginJoin(this)
			else
				showJoinBox(this, 1)
			end
		end
	end,

	-- typing goes to the IP box while it is open (as in the stock Join IP box)
	Input_KeyDown = function(this, key)
		if not gCurEditbox then
			return
		end
		if key == 10 or key == 13 then
			beginJoin(this)
		elseif key ~= 9 then
			IFEditbox_fnAddChar(gCurEditbox, key)
		end
	end,

	Input_Back = function(this)
		if this.bJoinBoxVis then
			showJoinBox(this, nil)
			return
		end
		ScriptCB_PopScreen()
	end,
}

do
	local this = ifs_cgc
	local boxW, boxH = 375, 40
	this.JoinIPBox = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.75,
		iptitle = NewIFText {
			string = "common.mp.joinip_prompt",
			font = "gamefont_small",
			textw = 250,
			x = -260 - boxW * 0.5,
			y = -12,
			halign = "right",
			nocreatebackground = 1,
		},
		ipedit = NewEditbox {
			width = boxW,
			height = boxH,
			font = "gamefont_medium",
			MaxLen = boxW - 30,
			MaxChars = 64,
		},
	}
	this.JoinIPBtn = rightCornerButton("ok", "common.ok")
end

ifs_cgc.CurButton = AddVerticalButtons(ifs_cgc.buttons, ifs_cgc_vbutton_layout)
AddIFScreen(ifs_cgc, "ifs_cgc")

-- host: Select Scenario --------------------------------------------------------------

ifs_cgc_scenario_vbutton_layout = {
	xWidth = 400,
	width = 400,
	xSpacing = 10,
	ySpacing = 5,
	font = gMenuButtonFont,
	buttonlist = {
		{ tag = "cw", string = "common.era.cw" },
		{ tag = "gcw", string = "common.era.gcw" },
	},
	title = "ifs.meta.Configs.title",
}

ifs_cgc_scenario = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = "shell_sub_left",
	bAcceptIsSelect = 1,

	buttons = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = gDefaultButtonScreenRelativeY,
	},

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		this.CurButton = ShowHideVerticalButtons(this.buttons, ifs_cgc_scenario_vbutton_layout)
		SetCurButton(this.CurButton)
	end,

	Update = update,

	Input_Accept = function(this)
		if gShellScreen_fnDefaultInputAccept(this) then
			return
		end
		if CGC.SCENARIOS[this.CurButton or ""] then
			ifelm_shellscreen_fnPlaySound(this.acceptSound)
			ifs_cgc_sides.scenario = this.CurButton
			ifs_movietrans_PushScreen(ifs_cgc_sides)
		end
	end,

	Input_Back = function(this)
		ScriptCB_PopScreen()
	end,
}

ifs_cgc_scenario.CurButton = AddVerticalButtons(ifs_cgc_scenario.buttons, ifs_cgc_scenario_vbutton_layout)
AddIFScreen(ifs_cgc_scenario, "ifs_cgc_scenario")

-- host: Please select a side. (laid out like ifs_freeform_sides) --------------------

ifs_cgc_sides = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = "shell_sub_left",

	SetSide = function(this, team)
		if team ~= this.side then
			ifelm_shellscreen_fnPlaySound(this.selectSound)
		end
		this.side = team
		IFObj_fnSetPos(this.players[0], this.players.side_x[team], 0)
		for t = 1, 2 do
			IFObj_fnSetAlpha(this["team" .. t].icon, t == team and 0.6 or 0.25)
		end
	end,

	SetReady = function(this, ready)
		this.ready = ready
		if ready then
			IFObj_fnSetColor(this.players[0], teamColor(this.side))
		else
			IFObj_fnSetColor(this.players[0], 240, 240, 240)
		end
	end,

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		for team = 1, 2 do
			local code = CGC.SCENARIOS[this.scenario].sides[team]
			local column = this["team" .. team]
			IFText_fnSetUString(column.text, CGC.TeamName(this.scenario, team))
			IFImage_fnSetTexture(column.icon, "seal_" .. code)
			IFObj_fnSetColor(column.icon, teamColor(team))
		end
		IFText_fnSetUString(this.players[0], CGC.LoginName())
		this.displayTimer = nil
		this:SetReady(nil)
		this:SetSide(this.side or 1)
	end,

	-- the mouse picks the side under the cursor (each half carries a tag)
	UpdateUI = function(this)
		if this.ready then
			return
		end
		if this.CurButton == "team1" then
			this:SetSide(1)
		elseif this.CurButton == "team2" then
			this:SetSide(2)
		end
	end,

	Input_Accept = function(this)
		if gShellScreen_fnDefaultInputAccept(this) then
			return
		end
		if this.ready then
			return
		end
		ifelm_shellscreen_fnPlaySound(this.acceptSound)
		this:UpdateUI()
		this:SetReady(1)
		this.displayTimer = 1.0
	end,

	Input_Back = function(this)
		ifelm_shellscreen_fnPlaySound(this.cancelSound)
		if this.ready then
			this.displayTimer = nil
			this:SetReady(nil)
			return
		end
		ScriptCB_PopScreen()
	end,

	Input_GeneralLeft = function(this)
		if not this.ready then
			this:SetSide(1)
		end
	end,

	Input_GeneralRight = function(this)
		if not this.ready then
			this:SetSide(2)
		end
	end,

	Input_GeneralUp = function(this) end,
	Input_GeneralDown = function(this) end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		if this.displayTimer then
			this.displayTimer = this.displayTimer - fDt
			if this.displayTimer < 0 then
				this.displayTimer = nil
				ifs_cgc_lobby.hostScenario = this.scenario
				ifs_cgc_lobby.hostTeam = this.side
				ifs_movietrans_PushScreen(ifs_cgc_lobby)
			end
		end
	end,
}

do
	local this = ifs_cgc_sides
	local w, h = ScriptCB_GetSafeScreenInfo()
	local screenW, screenH, _, widescreen = ScriptCB_GetScreenInfo()
	local sideW = w * 0.5

	this.shade = NewIFImage {
		ScreenRelativeX = 0,
		ScreenRelativeY = 0,
		UseSafezone = 0,
		ZPos = 255,
		texture = "blank_icon",
		ColorR = 0, ColorG = 0, ColorB = 0, alpha = 0.5,
		localpos_l = 0,
		localpos_t = 0,
		localpos_r = screenW * widescreen,
		localpos_b = screenH,
		inert = 1,
	}

	this.title = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.0,
		text = NewIFText {
			font = "gamefont_large",
			string = "ifs.freeform.picksides",
			textw = w,
			x = -w * 0.5,
			y = h * 0.12,
			halign = "hcenter",
			valign = "top",
			nocreatebackground = 1,
		},
	}

	local function column(relX, x0)
		return NewIFContainer {
			ScreenRelativeX = relX,
			ScreenRelativeY = 0.3,
			text = NewIFText {
				font = "gamefont_large",
				textw = sideW,
				x = x0,
				halign = "hcenter",
				valign = "vcenter",
				nocreatebackground = 1,
			},
			icon = NewIFImage {
				ZPos = 200,
				alpha = 0.25,
				localpos_l = x0 + sideW * 0.5 - 64,
				localpos_t = -64,
				localpos_r = x0 + sideW * 0.5 + 64,
				localpos_b = 64,
				inert = 1,
			},
		}
	end
	this.team1 = column(0.0, 0)
	this.team2 = column(1.0, -sideW)

	-- invisible mouse targets over each half
	local function hotspot(relX, x0, tag)
		return NewIFImage {
			ScreenRelativeX = relX,
			ScreenRelativeY = 0.3,
			texture = "blank_icon",
			alpha = 0,
			localpos_l = x0,
			localpos_t = -h * 0.15,
			localpos_r = x0 + sideW,
			localpos_b = h * 0.3,
			tag = tag,
		}
	end
	this.hit1 = hotspot(0.0, 0, "team1")
	this.hit2 = hotspot(1.0, -sideW, "team2")

	this.players = NewIFContainer {
		ScreenRelativeX = 0.0,
		ScreenRelativeY = 0.5,
		side_x = { [1] = 0, [2] = sideW },
		[0] = NewIFText {
			font = "gamefont_medium",
			textw = sideW,
			halign = "hcenter",
			valign = "vcenter",
			nocreatebackground = 1,
		},
	}
end

AddIFScreen(ifs_cgc_sides, "ifs_cgc_sides")

-- lobby (laid out like ifs_mp_lobby) --------------------------------------------------

local lobbyRows = {}

local function lobbyCreateItem(layout)
	local item = NewIFContainer { x = layout.x - 0.5 * layout.width, y = layout.y }
	local border = 10
	local pingW = layout.width * 0.15
	local teamW = layout.width * 0.3
	local pingX = layout.width - pingW
	local teamX = pingX - teamW
	local font = "gamefont_tiny"
	item.namefield = NewIFText {
		x = border, y = -6, textw = teamX - border,
		halign = "left", font = font, nocreatebackground = 1, inert_all = 1,
	}
	item.teamfield = NewIFText {
		x = teamX, y = -6, textw = teamW,
		halign = "left", font = font, nocreatebackground = 1, inert_all = 1,
	}
	item.pingfield = NewIFText {
		x = pingX, y = -6, textw = pingW,
		halign = "left", font = font, nocreatebackground = 1, inert_all = 1,
	}
	return item
end

local function lobbyPopulateItem(dest, data, bSelected, r, g, b, alpha)
	if data then
		IFText_fnSetUString(dest.namefield, data.name)
		IFObj_fnSetColor(dest.namefield, r, g, b)
		IFObj_fnSetAlpha(dest.namefield, alpha)
		IFText_fnSetUString(dest.teamfield, data.team)
		IFObj_fnSetColor(dest.teamfield, teamColor(data.teamNumber))
		IFText_fnSetString(dest.pingfield, data.ping or "")
		IFObj_fnSetColor(dest.pingfield, r, g, b)
		IFObj_fnSetAlpha(dest.pingfield, alpha)
	end
	IFObj_fnSetVis(dest, data)
end

ifs_cgc_lobby_layout = {
	showcount = 6,
	yHeight = 26,
	ySpacing = 0,
	width = 430,
	x = 0,
	slider = nil,
	CreateFn = lobbyCreateItem,
	PopulateFn = lobbyPopulateItem,
}

local function fillLobby(this)
	local s = CGC.session
	lobbyRows = {}
	if s and s.scenario then
		local host = s.role == "host"
		local hostTeam = host and s.myTeam or 3 - s.myTeam
		table.insert(lobbyRows, {
			name = host and CGC.LoginName() or U(s.peerName or ""),
			team = CGC.TeamName(s.scenario, hostTeam),
			teamNumber = hostTeam,
			ping = (not host) and this.ping and string.format("%d", this.ping) or nil,
		})
		if not host or this.peer then
			table.insert(lobbyRows, {
				name = host and U(this.peer.name or "") or CGC.LoginName(),
				team = CGC.TeamName(s.scenario, 3 - hostTeam),
				teamNumber = 3 - hostTeam,
				ping = host and this.ping and string.format("%d", this.ping) or nil,
			})
		end
	end
	ifs_cgc_lobby_layout.SelectedIdx = nil
	ifs_cgc_lobby_layout.CursorIdx = nil
	ListManager_fnFillContents(this.listbox, lobbyRows, ifs_cgc_lobby_layout)

	local host = s and s.role == "host"
	IFObj_fnSetVis(this.status, (host and not this.peer) and 1 or nil)
	IFObj_fnSetVis(this.LaunchBtn, (host and this.peer) and 1 or nil)
end

-- the battle-port check, shown under the player list
local function showNotice(this)
	local s = CGC.session
	local text = ""
	if this.udp == "probing" then
		text = "Checking the connection for battles ..."
	elseif this.udp == "failed" then
		if s.role == "host" then
			text = (this.peer and this.peer.name or "The other player") .. " cannot reach this PC on UDP port " ..
				CGC.BATTLE_PORT .. ", so battles will not start. Forward UDP " .. CGC.BATTLE_PORT ..
				" to this PC, or join a virtual LAN."
		else
			text = "This PC cannot reach " .. tostring(s.peerName) .. " on UDP port " .. CGC.BATTLE_PORT ..
				", so battles will not start. The host must forward UDP " .. CGC.BATTLE_PORT ..
				" to their PC, or you can join a virtual LAN."
		end
	end
	IFText_fnSetUString(this.notice, U(text))
	IFObj_fnSetVis(this.notice, text ~= "" and 1 or nil)
end

local function openLobby(this)
	this.peer = nil
	this.ping = nil
	this.connectedAt = nil
	this.udp = nil
	CGC.mailbox = {}
	fillLobby(this)
	local ok, err = ConquestNet_Host(CGC.PORT)
	if not ok then
		CGC.Log("cannot host: " .. tostring(err))
		this.failed = true
		showPopupOkText(U("Could not open the lobby: " .. tostring(err)), function()
			CGC.EndSession("host failed")
			ScriptCB_PopScreen()
		end)
		return
	end
	-- answer the joining player's battle-port check while the lobby is open
	this.udpEcho = ConquestNet_EchoUdp(CGC.BATTLE_PORT) and true or nil
	fillLobby(this)
	showNotice(this)
end

-- drop the current player or connection (if any) and wait for the next
local function nextPlayer(this)
	this.peer = nil
	this.ping = nil
	this.connectedAt = nil
	this.udp = nil
	CGC.mailbox = {}
	if not ConquestNet_AcceptNext() then
		-- the port closed under us: open it again (shows an error if it can't)
		openLobby(this)
		return
	end
	fillLobby(this)
	showNotice(this)
end

local function leaveLobby(this, reason)
	if CGC.LinkUp() then
		CGC.Send("bye")
	end
	CGC.EndSession(reason)
	ScriptCB_PopScreen()
end

local function hostUpdate(this)
	local state = ConquestNet_Status()
	if this.peer then
		if CGC.Take("bye") or CGC.LinkLost() then
			CGC.Log("player left the lobby: " .. tostring(this.peer.name))
			nextPlayer(this)
			return
		end
		local udp = CGC.Take("udp")
		if udp then
			this.udp = udp.ok and "ok" or "failed"
			showNotice(this)
		end
		return
	end
	if state == "error" or state == "closed" then
		-- a connection that gave up (or was dropped) before saying hello
		nextPlayer(this)
		return
	end
	if state ~= "connected" then
		return
	end
	this.connectedAt = this.connectedAt or ConquestNet_Time()
	local hello = CGC.Take("hello")
	if not hello then
		-- a player's first message is hello; anything else is not a player
		if table.getn(CGC.mailbox) > 0 or ConquestNet_Time() - this.connectedAt > HELLO_TIMEOUT then
			CGC.Log("connection without hello; listening again")
			nextPlayer(this)
		end
		return
	end
	local name = CGC.CleanName(hello.name)
	if hello.protocol ~= CGC.PROTOCOL or hello.version ~= ConquestNet_Version() then
		CGC.Log("refusing " .. name .. ": version " .. tostring(hello.version) .. ", protocol " .. tostring(hello.protocol))
		-- the refusal still goes out after the connection is dropped
		CGC.Send("refuse", { reason = "version" })
		nextPlayer(this)
		return
	end
	local s = CGC.session
	this.peer = { name = name }
	CGC.Log(name .. " joined the lobby")
	CGC.Send("setup", { scenario = s.scenario, hostTeam = s.myTeam, name = s.myName, udp = this.udpEcho })
	if this.udpEcho then
		this.udp = "probing"
	end
	ifelm_shellscreen_fnPlaySound("shell_select_change")
	SetCurButton("launch")
	fillLobby(this)
	showNotice(this)
end

local function clientUpdate(this)
	if CGC.Take("start") then
		CGC.Log("host launched the campaign")
		this.started = true
		ConquestNet_ProbeUdp(nil)
		CGC.StartGame()
		return
	end
	if CGC.Take("bye") or CGC.LinkLost() then
		this.failed = true
		CGC.EndSession("host left the lobby")
		showPopupOk("ifs.mp.joinerrors.hostquit", function()
			ScriptCB_PopScreen()
		end)
		return
	end
	if this.udp == "probing" then
		local result = ConquestNet_ProbeResult()
		if result == "ok" or result == "failed" then
			this.udp = result
			CGC.Log("battle port check: " .. result)
			CGC.Send("udp", { ok = result == "ok" })
			showNotice(this)
		end
	end
end

local function launch(this)
	local s = CGC.session
	s.peerName = this.peer.name
	CGC.SaveSession()
	CGC.Send("start")
	this.started = true
	ConquestNet_EchoUdp(nil)
	CGC.StartGame()
end

ifs_cgc_lobby = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = nil,
	bg_texture = "iface_bgmeta_space",
	bDimBackdrop = 1,

	title = NewIFText {
		font = "gamefont_large",
		y = 0,
		textw = 460,
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0,
		nocreatebackground = 1,
	},

	ServerName = NewIFText {
		font = "gamefont_small",
		textw = 460,
		halign = "left",
		ScreenRelativeX = 0,
		ScreenRelativeY = 1.0,
		y = -90,
		x = 25,
		nocreatebackground = 1,
	},

	IPAddr = NewIFText {
		font = "gamefont_small",
		textw = 460,
		halign = "right",
		ScreenRelativeX = 1.0,
		ScreenRelativeY = 1.0,
		y = -90,
		x = -460,
		nocreatebackground = 1,
	},

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		if not bFwd then
			-- back from a finished campaign: the lobby is over
			ScriptCB_PopScreen()
			return
		end
		this.failed = nil
		this.started = nil
		this.leaving = nil
		this.peer = nil
		this.ping = nil
		this.pingAt = 0
		this.udp = nil
		this.udpEcho = nil

		local s
		if this.hostScenario then
			s = { role = "host", scenario = this.hostScenario, myTeam = this.hostTeam, myName = CGC.PlayerName() }
			this.hostScenario = nil
			CGC.session = s
			CGC.SaveSession()
		else
			s = CGC.session
		end
		local host = s.role == "host"
		IFText_fnSetUString(this.status, U("Waiting for players ..."))
		IFText_fnSetString(this.title, host and "ifs.mplobby.host_title" or "ifs.mplobby.client_title")
		IFText_fnSetUString(this.ServerName, U(ScriptCB_ununicode(ScriptCB_getlocalizestr("ifs.sp.meta")) .. ": " ..
			ScriptCB_ununicode(ScriptCB_getlocalizestr(CGC.SCENARIOS[s.scenario].era))))
		IFText_fnSetString(this.IPAddr, "IP: " .. (host and ConquestNet_LocalAddresses() or s.host))
		if host then
			openLobby(this)
		else
			if s.udpCheck and ConquestNet_ProbeUdp(s.host, CGC.BATTLE_PORT) then
				this.udp = "probing"
			end
			fillLobby(this)
			showNotice(this)
		end
	end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		-- nothing happens behind the Leave prompt; messages wait until it closes
		if this.failed or this.started or this.leaving or not CGC.session then
			return
		end
		if CGC.session.role == "host" then
			hostUpdate(this)
		else
			clientUpdate(this)
		end
		if this.failed or this.started or not CGC.LinkUp() then
			return
		end
		-- latency for the Ping column
		local now = ConquestNet_Time()
		local ping = CGC.Take("ping")
		while ping do
			CGC.Send("pong", { t = ping.t })
			ping = CGC.Take("ping")
		end
		local pong = CGC.Take("pong")
		if pong then
			this.ping = math.floor((now - pong.t) * 1000 + 0.5)
			fillLobby(this)
		end
		if now >= this.pingAt then
			this.pingAt = now + PING_INTERVAL
			CGC.Send("ping", { t = now })
		end
	end,

	Input_Accept = function(this)
		if gShellScreen_fnDefaultInputAccept(this) then
			return
		end
		if this.CurButton == "launch" and this.peer and not this.started then
			ifelm_shellscreen_fnPlaySound(this.acceptSound)
			launch(this)
		end
	end,

	Input_Back = function(this)
		if this.failed or this.started then
			return
		end
		ifelm_shellscreen_fnPlaySound(this.exitSound)
		local host = CGC.session and CGC.session.role == "host"
		this.leaving = true
		Popup_YesNo.CurButton = "no"
		Popup_YesNo.fnDone = function(yes)
			this.leaving = nil
			if yes then
				leaveLobby(this, host and "host closed the lobby" or "left the lobby")
			end
		end
		Popup_YesNo:fnActivate(1)
		gPopup_fnSetTitleStr(Popup_YesNo, host and "ifs.onlinelobby.cancelsession" or "ifs.onlinelobby.leavesession")
	end,

	Input_GeneralUp = function(this) end,
	Input_GeneralDown = function(this) end,
}

do
	local this = ifs_cgc_lobby
	local w, h = ScriptCB_GetSafeScreenInfo()
	local layout = ifs_cgc_lobby_layout
	layout.width = w - 50
	local rowH = layout.yHeight + layout.ySpacing

	this.listbox = NewButtonWindow {
		ZPos = 200,
		x = 0,
		y = -20,
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.5,
		width = layout.width + 50,
		height = layout.showcount * rowH + 30,
	}
	ListManager_fnInitList(this.listbox, layout)

	this.columnheaders = lobbyCreateItem {
		width = layout.width,
		height = layout.yHeight,
		x = 0,
		y = 0,
	}
	this.columnheaders.ScreenRelativeX = 0.5
	this.columnheaders.ScreenRelativeY = 0.5
	this.columnheaders.y = this.listbox.y - this.listbox.height * 0.49 - 30
	IFText_fnSetString(this.columnheaders.namefield, "ifs.MPLobby.name_header")
	IFText_fnSetString(this.columnheaders.teamfield, "ifs.MPLobby.team_header")
	IFText_fnSetString(this.columnheaders.pingfield, "ifs.MPLobby.ping_header")

	this.status = NewIFText {
		font = "gamefont_small",
		textw = w,
		x = -w * 0.5,
		y = this.listbox.y + this.listbox.height * 0.5 + 10,
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.5,
		halign = "hcenter",
		nocreatebackground = 1,
	}

	this.notice = NewIFText {
		font = "gamefont_small",
		textw = w - 50,
		texth = 60,
		x = -(w - 50) * 0.5,
		y = this.status.y + 24,
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.5,
		halign = "hcenter",
		valign = "top",
		nocreatebackground = 1,
	}

	this.LaunchBtn = rightCornerButton("launch", "common.mp.launch")
end

AddIFScreen(ifs_cgc_lobby, "ifs_cgc_lobby")

-- Multiplayer menu hook -------------------------------------------------------------

local mpAccept = ifs_mp.Input_Accept
ifs_mp.Input_Accept = function(this, joystick)
	if this.CurButton == "cgc" then
		ifelm_shellscreen_fnPlaySound(this.acceptSound)
		ifs_movietrans_PushScreen(ifs_cgc)
		return
	end
	return mpAccept(this, joystick)
end
