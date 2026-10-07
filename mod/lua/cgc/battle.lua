-- Battle-side half of online Galactic Conquest (runs in the mission's Lua state).
-- The host reports the winner to the client over the mod link, then both
-- return to the Galactic Conquest map.

ConquestNet_RunFile("lua/cgc/serialize.lua")

local raw = ConquestNet_GetValue("cgc_session")
local session = raw and CGC.Deserialize(raw)
if not (session and session.started and session.battle) then
	return
end

local function log(text)
	ConquestNet_Log("cgc battle: " .. text)
end
log("battle " .. tostring(session.battle.mission) .. " as " .. tostring(session.role))

if session.role ~= "host" then
	-- the client leaves when the host's server ends the match
	return
end

-- the engine registers MissionVictory late; wrap it once the mission has loaded
table.insert(ConquestNet_PostLoad, function()
	local victory = MissionVictory
	MissionVictory = function(team)
		log("winner " .. tostring(team))
		ConquestNet_SetValue("cgc_winner", tostring(team))
		ConquestNet_Send(CGC.Serialize({ kind = "result", winner = team }))
		victory(team)
		ScriptCB_QuitToShell()
	end
end)
