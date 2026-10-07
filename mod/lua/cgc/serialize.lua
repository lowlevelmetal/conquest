-- Serialize plain Lua data (nil, booleans, numbers, strings, nested tables) to
-- a Lua table-constructor string and back. Used for messages between players.
-- Lua 5.0: no '#', no '%' operator, string.gfind instead of gmatch.

CGC = CGC or {}

local function serializeValue(v, out)
	local t = type(v)
	if t == "nil" then
		table.insert(out, "nil")
	elseif t == "boolean" then
		table.insert(out, v and "true" or "false")
	elseif t == "number" then
		-- %.9g round-trips the game's single-precision floats
		table.insert(out, string.format("%.9g", v))
	elseif t == "string" then
		table.insert(out, string.format("%q", v))
	elseif t == "table" then
		table.insert(out, "{")
		for k, val in pairs(v) do
			local kt = type(k)
			if kt == "string" or kt == "number" or kt == "boolean" then
				table.insert(out, "[")
				serializeValue(k, out)
				table.insert(out, "]=")
				serializeValue(val, out)
				table.insert(out, ",")
			end
		end
		table.insert(out, "}")
	else
		-- functions, userdata: not transferable
		table.insert(out, "nil")
	end
end

function CGC.Serialize(v)
	local out = {}
	serializeValue(v, out)
	return table.concat(out)
end

-- Parse data produced by CGC.Serialize. The chunk runs with an empty
-- environment, so it can only build tables, never call game functions.
function CGC.Deserialize(s)
	local chunk, err = loadstring("return " .. s, "=message")
	if not chunk then
		return nil, err
	end
	setfenv(chunk, {})
	local ok, value = pcall(chunk)
	if not ok then
		return nil, value
	end
	return value
end

-- Deep copy (snapshots must not alias the live game tables)
function CGC.Copy(v)
	if type(v) ~= "table" then
		return v
	end
	local c = {}
	for k, val in pairs(v) do
		c[k] = CGC.Copy(val)
	end
	return c
end
