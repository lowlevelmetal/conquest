-- Menus for online Galactic Conquest: Multiplayer -> Galactic Conquest.
--   ifs_cgc         host (pick era and side) or join by IP
--   ifs_cgc_status  waiting for / connecting to the other player, then starts
--
-- The Galactic Conquest button itself is added to the Multiplayer menu's
-- layout in boot.lua, before that screen builds its buttons.

local function U(text)
	return ScriptCB_tounicode(text)
end

CGC.SCENARIOS = {
	cw  = { name = "Clone Wars", teams = { [1] = "Republic", [2] = "CIS" } },
	gcw = { name = "Galactic Civil War", teams = { [1] = "Rebel Alliance", [2] = "Galactic Empire" } },
}

ifs_cgc_vbutton_layout = {
	xWidth = 500,
	width = 500,
	ySpacing = 5,
	font = gMenuButtonFont,
	buttonlist = {
		{ tag = "host_cw_1", string = "ifs.sp.meta" },
		{ tag = "host_cw_2", string = "ifs.sp.meta" },
		{ tag = "host_gcw_1", string = "ifs.sp.meta" },
		{ tag = "host_gcw_2", string = "ifs.sp.meta" },
		{ tag = "join", string = "ifs.sp.meta" },
	},
	title = "ifs.sp.meta",
}

local buttonText = {
	host_cw_1 = "Host Clone Wars as the Republic",
	host_cw_2 = "Host Clone Wars as the CIS",
	host_gcw_1 = "Host Civil War as the Rebel Alliance",
	host_gcw_2 = "Host Civil War as the Empire",
	join = "Join a game by IP address",
}

local function startHost(scenario, team)
	CGC.session = { role = "host", scenario = scenario, myTeam = team }
	CGC.SaveSession()
	ifs_movietrans_PushScreen(ifs_cgc_status)
end

local function startJoin(ip)
	CGC.session = { role = "client", host = ip }
	CGC.SaveSession()
	ScriptCB_SetProfileJoinIP(ip)
	ifs_movietrans_PushScreen(ifs_cgc_status)
end

local function askForAddress()
	ifs_vkeyboard.CurString = U(ScriptCB_GetProfileJoinIP() or "")
	ifs_vkeyboard.bCursorOnAccept = 1
	IFText_fnSetUString(ifs_vkeyboard.title, U("Host IP address"))
	vkeyboard_specs.fnDone = function()
		local ip = ScriptCB_ununicode(ifs_vkeyboard.CurString)
		ScriptCB_PopScreen()
		ip = string.gsub(ip, "%s", "")
		if ip ~= "" then
			startJoin(ip)
		end
	end
	vkeyboard_specs.fnIsOk = function()
		return 1, ""
	end
	vkeyboard_specs.bUseBG = true
	vkeyboard_specs.MaxLen = 64
	ifs_movietrans_PushScreen(ifs_vkeyboard)
end

ifs_cgc = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = "shell_sub_left",
	bDimBackground = 1,
	buttons = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = gDefaultButtonScreenRelativeY,
	},

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		this.CurButton = ShowHideVerticalButtons(this.buttons, ifs_cgc_vbutton_layout)
		for tag, text in pairs(buttonText) do
			RoundIFButtonLabel_fnSetUString(this.buttons[tag], U(text))
		end
		IFText_fnSetUString(this.buttons._titlebar_, U("Online Galactic Conquest"))
		SetCurButton(this.CurButton)
	end,

	Input_Accept = function(this)
		if gShellScreen_fnDefaultInputAccept(this) then
			return
		end
		ifelm_shellscreen_fnPlaySound(this.acceptSound)
		local _, _, scenario, team = string.find(this.CurButton or "", "^host_(%a+)_(%d)$")
		if scenario then
			startHost(scenario, tonumber(team))
		elseif this.CurButton == "join" then
			askForAddress()
		end
	end,

	Input_Back = function(this)
		ScriptCB_PopScreen()
	end,
}

ifs_cgc.CurButton = AddVerticalButtons(ifs_cgc.buttons, ifs_cgc_vbutton_layout)
AddIFScreen(ifs_cgc, "ifs_cgc")

-- status / handshake ------------------------------------------------------------

local function setStatus(this, text)
	IFText_fnSetUString(this.message.text, U(text))
end

local function teamNames(scenario, myTeam)
	local s = CGC.SCENARIOS[scenario]
	return s.teams[myTeam], s.teams[3 - myTeam]
end

ifs_cgc_status = NewIFShellScreen {
	nologo = 1,
	movieIntro = nil,
	movieBackground = "shell_sub_left",
	bDimBackground = 1,

	message = NewIFContainer {
		ScreenRelativeX = 0.5,
		ScreenRelativeY = 0.45,
		text = NewIFText {
			font = "gamefont_medium",
			textw = 600,
			texth = 300,
			x = -300,
			y = -150,
			halign = "hcenter",
			valign = "vcenter",
			nocreatebackground = 1,
		},
	},

	Enter = function(this, bFwd)
		gIFShellScreenTemplate_fnEnter(this, bFwd)
		if not bFwd then
			-- returning from a finished game: nothing to resume here
			ScriptCB_PopScreen()
			return
		end
		local s = CGC.session
		this.phase = nil
		this.timer = 0
		local ok, err
		if s.role == "host" then
			ok, err = ConquestNet_Host(CGC.PORT)
			this.phase = "listen"
		else
			ok, err = ConquestNet_Connect(s.host, CGC.PORT)
			this.phase = "connect"
		end
		if not ok then
			this.phase = "failed"
			setStatus(this, "Could not start: " .. tostring(err) .. "\n\nPress back to return.")
		else
			this:Refresh()
		end
	end,

	Refresh = function(this)
		local s = CGC.session
		if this.phase == "listen" then
			local mine = teamNames(s.scenario, s.myTeam)
			setStatus(this, "Hosting " .. CGC.SCENARIOS[s.scenario].name .. " as the " .. mine .. ".\n\n" ..
				"Waiting for the other player to join.\n\n" ..
				"Your address: " .. ConquestNet_LocalAddresses() .. "\n" ..
				"(over the internet, forward TCP " .. CGC.PORT .. " and UDP 3658 to this PC)\n\n" ..
				"Press back to cancel.")
		elseif this.phase == "connect" then
			setStatus(this, "Connecting to " .. s.host .. " ...\n\nPress back to cancel.")
		elseif this.phase == "handshake" then
			setStatus(this, "Connected. Setting up the galaxy ...")
		end
	end,

	Update = function(this, fDt)
		gIFShellScreenTemplate_fnUpdate(this, fDt)
		local s = CGC.session
		if not s or this.phase == "failed" or this.phase == "started" then
			return
		end
		this.timer = this.timer + fDt

		local state, detail = ConquestNet_Status()
		if state == "error" or (state == "closed" and this.phase ~= "listen") then
			this.phase = "failed"
			setStatus(this, "Connection failed: " .. tostring(detail) .. "\n\nPress back to return.")
			return
		end

		if this.phase == "listen" or this.phase == "connect" then
			if state == "connected" then
				this.phase = "handshake"
				this:Refresh()
				if s.role == "client" then
					CGC.Send("hello", { protocol = CGC.PROTOCOL, version = ConquestNet_Version() })
				end
			end
			return
		end

		if this.phase == "handshake" then
			if s.role == "host" then
				local hello = CGC.Take("hello")
				if hello then
					if hello.protocol ~= CGC.PROTOCOL then
						CGC.Send("refuse", { reason = "version mismatch" })
						this.phase = "failed"
						setStatus(this, "The other player has a different version of the mod.\n\nPress back to return.")
						return
					end
					CGC.Send("setup", { scenario = s.scenario, hostTeam = s.myTeam })
				end
				if CGC.Take("ready") then
					this.phase = "started"
					CGC.StartGame()
				end
			else
				local refused = CGC.Take("refuse")
				if refused then
					this.phase = "failed"
					setStatus(this, "The host refused the connection: " .. tostring(refused.reason) .. "\n\nPress back to return.")
					return
				end
				local setup = CGC.Take("setup")
				if setup then
					s.scenario = setup.scenario
					s.myTeam = 3 - setup.hostTeam
					CGC.SaveSession()
					CGC.Send("ready")
					this.phase = "started"
					CGC.StartGame()
				end
			end
		end
	end,

	Input_Accept = function(this)
	end,

	Input_Back = function(this)
		if this.phase ~= "started" then
			CGC.EndSession("cancelled in lobby")
			ScriptCB_PopScreen()
		end
	end,
}

AddIFScreen(ifs_cgc_status, "ifs_cgc_status")

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
