-- Message link between the two players, on top of the native TCP connection.
-- Messages are tables with a `kind` field. Received messages wait in a mailbox
-- until a screen takes them, so nothing is lost if it arrives early.
--
-- The session record (who is host, which team is local, ...) is kept in the
-- native value store because the shell's Lua state is rebuilt after battles.

CGC = CGC or {}

CGC.PORT = 24600
CGC.PROTOCOL = 1
CGC.mailbox = CGC.mailbox or {}

function CGC.Log(text)
	ConquestNet_Log("cgc: " .. text)
end

function CGC.Send(kind, fields)
	local msg = fields or {}
	msg.kind = kind
	CGC.Log("send " .. kind)
	return ConquestNet_Send(CGC.Serialize(msg))
end

-- Move everything the native link has received into the mailbox.
function CGC.Poll()
	while true do
		local s = ConquestNet_Recv()
		if not s then
			break
		end
		local msg, err = CGC.Deserialize(s)
		if type(msg) == "table" and msg.kind then
			CGC.Log("recv " .. msg.kind)
			table.insert(CGC.mailbox, msg)
		else
			CGC.Log("dropped malformed message: " .. tostring(err))
		end
	end
end

-- Remove and return the oldest message of a kind (or of any listed kind).
function CGC.Take(...)
	CGC.Poll()
	for i, msg in ipairs(CGC.mailbox) do
		for j = 1, arg.n do
			if msg.kind == arg[j] then
				table.remove(CGC.mailbox, i)
				return msg
			end
		end
	end
	return nil
end

function CGC.LinkUp()
	local state = ConquestNet_Status()
	return state == "connected"
end

-- Peer disconnected or the link failed after being established.
function CGC.LinkLost()
	local state = ConquestNet_Status()
	return state == "closed" or state == "error"
end

-- session persistence ---------------------------------------------------------

function CGC.SaveSession()
	ConquestNet_SetValue("cgc_session", CGC.session and CGC.Serialize(CGC.session) or nil)
end

function CGC.LoadSession()
	local s = ConquestNet_GetValue("cgc_session")
	CGC.session = s and CGC.Deserialize(s) or nil
	return CGC.session
end

function CGC.EndSession(reason)
	CGC.Log("session ended: " .. tostring(reason))
	ConquestNet_SetTunnel(0)
	ConquestNet_Close()
	CGC.session = nil
	CGC.mailbox = {}
	CGC.SaveSession()
end

function CGC.Active()
	return CGC.session ~= nil and CGC.session.started
end

function CGC.IsLocalTeam(team)
	return CGC.session and CGC.session.myTeam == team
end
