-- Battle-side entry point.
--
-- Mission scripts define ScriptPostLoad after setup_teams loads, and the
-- engine registers mission functions such as MissionVictory late, so mod code
-- that needs them registers a callback in ConquestNet_PostLoad instead.

ConquestNet_PostLoad = {}

setmetatable(getfenv(0), { __newindex = function(t, k, v)
	if k == "ScriptPostLoad" and type(v) == "function" then
		local postLoad = v
		v = function()
			postLoad()
			for _, fn in ipairs(ConquestNet_PostLoad) do
				local ok, err = pcall(fn)
				if not ok then
					ConquestNet_Log("mission: post-load hook failed: " .. tostring(err))
				end
			end
		end
	end
	rawset(t, k, v)
end })

local ok, err = ConquestNet_RunFile("lua/cgc/battle.lua")
if not ok then
	ConquestNet_Log("mission: cgc/battle.lua failed: " .. tostring(err))
end

-- development autotests (not shipped in the player package)
if ConquestNet_ReadFile("lua/autotest.lua") then
	ConquestNet_RunFile("lua/autotest.lua")
end
