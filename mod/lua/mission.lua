-- Battle-side entry point. For now: record how missions end for the smoke test.

local log = ConquestNet_Log

log("mission: rules=" .. tostring(ScriptCB_GetGameRules and ScriptCB_GetGameRules()) ..
	" innet=" .. tostring(ScriptCB_InNetGame and ScriptCB_InNetGame()) ..
	" host=" .. tostring(ScriptCB_GetAmHost and ScriptCB_GetAmHost()))

if MissionVictory then
	local victory = MissionVictory
	MissionVictory = function(team)
		log("mission: MissionVictory(" .. tostring(team) .. ")")
		return victory(team)
	end
else
	log("mission: MissionVictory not defined yet")
end

ConquestNet_RunFile("lua/autotest.lua")
