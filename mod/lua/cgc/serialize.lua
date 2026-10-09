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
		if v ~= v or v == 1 / 0 or v == -1 / 0 then
			-- nan and infinities have no literal
			table.insert(out, "nil")
		else
			-- %.9g round-trips the game's single-precision floats
			table.insert(out, string.format("%.9g", v))
		end
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

-- Parse data produced by CGC.Serialize. Messages come from the network, so
-- this reads them as data only (never runs them) and caps size and nesting.

local MAX_INPUT = 1048576
local MAX_DEPTH = 32

-- escapes written by %q, plus the common ones
local ESCAPES = {
	["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n",
	n = "\n", r = "\r", t = "\t", a = "\a", b = "\b", f = "\f", v = "\v",
}

local function fail(why, pos)
	error(why .. " at " .. tostring(pos), 0)
end

local function skipSpace(s, pos)
	local _, e = string.find(s, "^%s*", pos)
	return e + 1
end

local function parseString(s, pos)
	local parts = {}
	local i = pos + 1
	while true do
		local j = string.find(s, '["\\]', i)
		if not j then
			fail("unterminated string", pos)
		end
		table.insert(parts, string.sub(s, i, j - 1))
		if string.sub(s, j, j) == '"' then
			return table.concat(parts), j + 1
		end
		local c = string.sub(s, j + 1, j + 1)
		if ESCAPES[c] then
			table.insert(parts, ESCAPES[c])
			i = j + 2
		else
			local _, e, digits = string.find(s, "^(%d%d?%d?)", j + 1)
			if not digits or tonumber(digits) > 255 then
				fail("bad escape", j)
			end
			table.insert(parts, string.char(tonumber(digits)))
			i = e + 1
		end
	end
end

local parseValue

local function parseTable(s, pos, depth)
	if depth > MAX_DEPTH then
		fail("nested too deeply", pos)
	end
	local t = {}
	pos = skipSpace(s, pos + 1)
	while string.sub(s, pos, pos) ~= "}" do
		if string.sub(s, pos, pos) ~= "[" then
			fail("expected '['", pos)
		end
		local key
		key, pos = parseValue(s, skipSpace(s, pos + 1), depth + 1)
		local kt = type(key)
		if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
			fail("bad key", pos)
		end
		local _, e = string.find(s, "^%s*%]%s*=", pos)
		if not e then
			fail("expected ']='", pos)
		end
		local value
		value, pos = parseValue(s, skipSpace(s, e + 1), depth + 1)
		t[key] = value
		pos = skipSpace(s, pos)
		local c = string.sub(s, pos, pos)
		if c == "," or c == ";" then
			pos = skipSpace(s, pos + 1)
		elseif c ~= "}" then
			fail("expected ',' or '}'", pos)
		end
	end
	return t, pos + 1
end

function parseValue(s, pos, depth)
	local c = string.sub(s, pos, pos)
	if c == "{" then
		return parseTable(s, pos, depth)
	elseif c == '"' then
		return parseString(s, pos)
	end
	local _, e, word = string.find(s, "^(%a+)", pos)
	if word == "nil" then
		return nil, e + 1
	elseif word == "true" then
		return true, e + 1
	elseif word == "false" then
		return false, e + 1
	elseif word then
		fail("unexpected '" .. word .. "'", pos)
	end
	local number
	_, e, number = string.find(s, "^(%-?[%d%.]+[eE]?[%+%-]?%d*)", pos)
	number = number and tonumber(number)
	if not number then
		fail("unexpected '" .. c .. "'", pos)
	end
	return number, e + 1
end

function CGC.Deserialize(s)
	if type(s) ~= "string" then
		return nil, "not a string"
	end
	if string.len(s) > MAX_INPUT then
		return nil, "too long"
	end
	local ok, value, pos = pcall(parseValue, s, skipSpace(s, 1), 1)
	if not ok then
		return nil, value
	end
	if skipSpace(s, pos) <= string.len(s) then
		return nil, "trailing data at " .. pos
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
