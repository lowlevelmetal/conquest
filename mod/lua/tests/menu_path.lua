-- Autotest: walk Main menu -> Multiplayer -> Galactic Conquest like a player,
-- logging the buttons each screen shows.

if ConquestNet_Context ~= "shell" then
	return
end

local log = ConquestNet_Log
local step = 0

local function buttons(layout)
	local tags = {}
	for _, b in ipairs(layout.buttonlist) do
		table.insert(tags, b.tag)
	end
	return table.concat(tags, ",")
end

local function onEnter(screen, name, fn)
	local enter = screen.Enter
	screen.Enter = function(this, bFwd)
		enter(this, bFwd)
		log("autotest: entered " .. name)
		if fn then
			fn(this)
		end
	end
end

onEnter(ifs_mp, "ifs_mp", function(this)
	log("autotest: multiplayer buttons " .. buttons(ifs_mp_vbutton_layout) ..
		" cgc hidden=" .. tostring(this.buttons.cgc and this.buttons.cgc.hidden))
	ConquestNet_MenuStep = "pick_cgc"
end)
onEnter(ifs_cgc, "ifs_cgc", function(this)
	log("autotest: galactic conquest menu reached; CurButton=" .. tostring(this.CurButton))
end)

ConquestNet_AutotestTick = function()
	if not ConquestNet_MainMenuSeen then
		return
	end
	step = step + 1
	if step == 2 then
		log("autotest: choosing Multiplayer")
		ifs_main.CurButton = "mp"
		ifs_main:Input_Accept()
	elseif ConquestNet_MenuStep == "pick_cgc" then
		ConquestNet_MenuStep = nil
		log("autotest: choosing Galactic Conquest")
		ifs_mp.CurButton = "cgc"
		ifs_mp:Input_Accept()
	end
end
