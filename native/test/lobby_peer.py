"""Pokes a real host's Galactic Conquest lobby (a test copy at the main menu
running "cgc_play host ..." autotest) the way strangers and old versions would.

  python3 lobby_peer.py <host ip> <mod version>

Checks: a silent connection and a connection sending something other than
hello don't keep the real player out; an old protocol and another mod version
are refused; a valid hello gets the lobby; a second player is refused as full.
"""
import socket, struct, sys, time

HOST, VERSION = sys.argv[1], sys.argv[2]
PORT = 24600


def lua(fields):
    """Serialize a flat dict as the mod does (CGC.Serialize)."""
    out = []
    for k, v in fields.items():
        if isinstance(v, bool):
            val = 'true' if v else 'false'
        elif isinstance(v, (int, float)):
            val = repr(v)
        else:
            val = '"%s"' % v
        out.append('["%s"]=%s,' % (k, val))
    return ('{' + ''.join(out) + '}').encode()


def send(s, payload):
    data = b'\0' + payload
    s.sendall(struct.pack('>I', len(data)) + data)


def recv_msg(s, timeout=10):
    """Next non-heartbeat payload, or None if the connection closed."""
    s.settimeout(timeout)
    try:
        while True:
            hdr = b''
            while len(hdr) < 4:
                chunk = s.recv(4 - len(hdr))
                if not chunk:
                    return None
                hdr += chunk
            n = struct.unpack('>I', hdr)[0]
            data = b''
            while len(data) < n:
                chunk = s.recv(n - len(data))
                if not chunk:
                    return None
                data += chunk
            if data:
                return data[1:]
    except (ConnectionResetError, socket.timeout):
        return None


def connect():
    for _ in range(300):
        try:
            return socket.create_connection((HOST, PORT), timeout=5)
        except OSError:
            time.sleep(1)
    raise RuntimeError('host lobby never opened')


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else ': ' + str(detail)))
    if not cond:
        sys.exit(1)


hello = {'kind': 'hello', 'protocol': 3, 'version': VERSION, 'name': 'Probe'}

silent = connect()                                   # never says anything
garbage = connect()
send(garbage, lua({'kind': 'start'}))                # not a hello
check('a connection whose first message is not hello is dropped', recv_msg(garbage) is None)

old = connect()
send(old, lua(dict(hello, protocol=2)))
reply = recv_msg(old)
check('an old protocol is refused', reply and b'"refuse"' in reply and b'"version"' in reply, reply)
check('...and disconnected', recv_msg(old) is None)

other = connect()
send(other, lua(dict(hello, version='0.0.9')))
reply = recv_msg(other)
check('another mod version is refused', reply and b'"refuse"' in reply and b'"version"' in reply, reply)

player = connect()
send(player, lua(hello))
reply = recv_msg(player)
check('a valid player gets the lobby despite the silent connection', reply and b'"setup"' in reply, reply)

second = connect()
send(second, lua(dict(hello, name='Second')))
reply = recv_msg(second)
check('a second player is refused as full', reply and b'"full"' in reply, reply)

send(player, lua({'kind': 'bye'}))
player.close()
time.sleep(2)
again = connect()
send(again, lua(dict(hello, name='Again')))
reply = recv_msg(again)
check('after the player leaves, the next one gets the lobby', reply and b'"setup"' in reply, reply)
silent.close()
print('lobby: all checks passed')
