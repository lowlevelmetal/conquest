"""Python peer for net_test.exe: checks framing, echo, heartbeats and large frames."""
import socket, struct, sys, time

def send(s, data, channel=0):
    data = bytes([channel]) + data
    s.sendall(struct.pack('>I', len(data)) + data)

def recv_frame(s):
    hdr = b''
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            raise EOFError
        hdr += chunk
    n = struct.unpack('>I', hdr)[0]
    data = b''
    while len(data) < n:
        data += s.recv(n - len(data))
    return data

def recv_payload(s, heartbeats):
    while True:
        f = recv_frame(s)
        if f:
            assert f[0] == 0, f[:8]   # Lua channel
            return f[1:]
        heartbeats[0] += 1

def exercise(s):
    hb = [0]
    for msg in [b'hello', b'second message', 'unicode é'.encode(), b'x' * 3000]:
        send(s, msg)
        got = recv_payload(s, hb)
        assert got == b'echo:' + msg, (got[:40], msg[:40])
    # several frames in one TCP write
    s.sendall(b''.join(struct.pack('>I', len(m) + 1) + b'\0' + m for m in [b'a', b'bb', b'ccc']))
    assert [recv_payload(s, hb) for _ in range(3)] == [b'echo:a', b'echo:bb', b'echo:ccc']
    # idle long enough to see heartbeats
    s.settimeout(10)
    t = time.time()
    while time.time() - t < 5:
        assert recv_frame(s) == b''
        hb[0] += 1
    assert hb[0] >= 2, hb
    send(s, b'quit')
    print('peer: all checks passed, heartbeats seen:', hb[0])

mode, port = sys.argv[1], int(sys.argv[2])
if mode == 'client':
    for _ in range(100):
        try:
            s = socket.create_connection(('127.0.0.1', port), timeout=10); break
        except OSError:
            time.sleep(0.1)
    exercise(s)
else:
    ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(('127.0.0.1', port)); ls.listen(1); ls.settimeout(30)
    s, _ = ls.accept(); s.settimeout(10)
    exercise(s)
