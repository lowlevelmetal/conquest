"""Decompile SWBF2 (MAXSTACK=128) Lua 5.0 bytecode with unluac.

The game's VM encodes RK constant operands starting at 128; stock Lua 5.0
(and unluac) expect 250. Rewrite those operands, then hand off to unluac.
"""
import struct, subprocess, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from lua50chunk import Reader

RK_B = {9, 12, 13, 14, 15, 16, 21, 22, 23}          # SETTABLE, ADD..POW, EQ, LT, LE
RK_C = {6, 9, 11, 12, 13, 14, 15, 16, 21, 22, 23}   # GETTABLE, SETTABLE, SELF, ADD..POW, EQ, LT, LE

def fix_code(buf, start, n):
    for i in range(n):
        off = start + 4 * i
        ins = struct.unpack_from('<I', buf, off)[0]
        op = ins & 0x3f
        c = (ins >> 6) & 0x1ff
        b = (ins >> 15) & 0x1ff
        if op in RK_C and c >= 128: c += 122
        if op in RK_B and b >= 128: b += 122
        ins = (ins & ~((0x1ff << 6) | (0x1ff << 15))) | (c << 6) | (b << 15)
        struct.pack_into('<I', buf, off, ins)

def walk(buf, r):
    r.str(); r.int(); r.p += 4
    n = r.int(); r.p += 4 * n                 # lineinfo
    for _ in range(r.int()): r.str(); r.int(); r.int()
    for _ in range(r.int()): r.str()
    for _ in range(r.int()):
        t = r.byte()
        if t == 3: r.p += 4
        elif t == 4: r.str()
    for _ in range(r.int()): walk(buf, r)
    n = r.int()
    fix_code(buf, r.p, n)
    r.p += 4 * n

def to_standard(data):
    buf = bytearray(data)
    r = Reader(buf); r.p = 18
    walk(buf, r)
    return bytes(buf)

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    tmp = dst + '.std.luac'
    open(tmp, 'wb').write(to_standard(open(src, 'rb').read()))
    jar = os.path.join(os.path.dirname(__file__), 'unluac.jar')
    with open(dst, 'w') as out:
        res = subprocess.run(['java', '-jar', jar, tmp], stdout=out, stderr=subprocess.PIPE, text=True)
    os.remove(tmp)
    if res.returncode:
        print(f'FAILED {src}: {res.stderr.splitlines()[-1] if res.stderr else ""}')
