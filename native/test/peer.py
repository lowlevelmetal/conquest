"""Checks net.c through net_test.exe (run under Wine on Linux):
framing, echo, heartbeats, the host's pending/peer/full handling, dropping a
peer, flood and oversized-frame limits, port conflicts and sending queued
messages on close.

  python3 peer.py [path/to/net_test.exe]
"""
import os, socket, struct, subprocess, sys, time

EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'build', 'net_test.exe')
RUNNER = [] if os.name == 'nt' else ['wine']
FULL = b'{["kind"]="refuse",["reason"]="full",}'


def start(*args):
    env = dict(os.environ, WINEDEBUG='-all')
    return subprocess.Popen(RUNNER + [EXE] + [str(a) for a in args], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, text=True)


def send(s, data, channel=0):
    data = bytes([channel]) + data
    s.sendall(struct.pack('>I', len(data)) + data)


def recv_exact(s, n):
    data = b''
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def recv_frame(s):
    n = struct.unpack('>I', recv_exact(s, 4))[0]
    return recv_exact(s, n)


def recv_payload(s, heartbeats=None):
    while True:
        f = recv_frame(s)
        if f:
            assert f[0] == 0, f[:8]   # Lua channel
            return f[1:]
        if heartbeats is not None:
            heartbeats[0] += 1


def expect_eof(s, timeout=8):
    s.settimeout(timeout)
    try:
        while True:
            f = recv_frame(s)
            assert not f, ('expected the connection to close, got', f[:40])
    except (EOFError, ConnectionResetError):
        return


def connect(port, tries=100):
    for _ in range(tries):
        try:
            s = socket.create_connection(('127.0.0.1', port), timeout=10)
            s.settimeout(10)
            return s
        except OSError:
            time.sleep(0.1)
    raise RuntimeError('cannot connect to port %d' % port)


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
    t = time.time()
    while time.time() - t < 5:
        assert recv_frame(s) == b''
        hb[0] += 1
    assert hb[0] >= 2, hb


def check(name, fn):
    t = time.time()
    fn()
    print('ok   %-55s %.1fs' % (name, time.time() - t))


def host_session():
    port = 24681
    p = start('host', port)
    try:
        silent = connect(port)                      # a connection that never says anything
        s1 = connect(port)
        check('silent connection does not take the peer slot', lambda: exercise(s1))
        s2 = connect(port)
        def refused():
            send(s2, b'hi')
            assert recv_payload(s2) == FULL
            expect_eof(s2)
        check('second player is refused as full', refused)
        def drop():
            send(s1, b'cmd:next')
            expect_eof(s1)
        check('accept next drops the current peer', drop)
        s3 = connect(port)
        def next_peer():
            send(s3, b'x')
            assert recv_payload(s3) == b'echo:x'
        check('the next player becomes the peer', next_peer)
        def flood():
            send(s3, b'cmd:pause')
            for i in range(1100):
                send(s3, b'm%d' % i)
            expect_eof(s3, 10)
        check('a flood of messages drops the peer', flood)
        s4 = connect(port)
        def closed_refuses():
            send(s4, b'y')
            assert recv_payload(s4) == FULL
            expect_eof(s4)
        check('until the game takes the next player, newcomers are refused', closed_refuses)
        silent.close()
    finally:
        p.kill()
        p.wait()


def host_close_and_rehost():
    port = 24682
    p = start('host', port)
    s = connect(port)
    def bye():
        send(s, b'cmd:quit')
        assert recv_payload(s) == b'bye'
        expect_eof(s)
    check('closing still sends the queued message', bye)
    p.wait(10)
    s.close()
    p = start('host', port)
    try:
        s = connect(port)
        def rehost():
            send(s, b'again')
            assert recv_payload(s) == b'echo:again'
        check('the port can be hosted again right away', rehost)
        def oversized():
            s.sendall(struct.pack('>I', 2 << 20) + b'\0' * 64)
            expect_eof(s)
        check('an oversized frame drops the peer', oversized)
    finally:
        p.kill()
        p.wait()


def port_in_use():
    port = 24683
    ls = socket.socket()
    ls.bind(('0.0.0.0', port))
    ls.listen(1)
    try:
        p = start('host', port)
        out = p.communicate(timeout=30)[0]
        assert p.returncode == 1 and 'in use' in out, out
    finally:
        ls.close()


def client_session():
    port = 24684
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(('127.0.0.1', port))
    ls.listen(1)
    ls.settimeout(30)
    p = start('client', '127.0.0.1', port)
    try:
        s, _ = ls.accept()
        s.settimeout(10)
        check('client: framing, echo and heartbeats', lambda: exercise(s))
        def bye():
            send(s, b'cmd:quit')
            assert recv_payload(s) == b'bye'
            expect_eof(s)
        check('client: closing still sends the queued message', bye)
    finally:
        p.kill()
        p.wait()
        ls.close()


check('a port in use is reported when hosting starts', port_in_use)
host_session()
host_close_and_rehost()
client_session()
print('peer: all checks passed')
