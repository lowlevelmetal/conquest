"""Parser for SWBF2 Lua 5.0 binary chunks (32-bit, float lua_Number)."""
import struct

class Reader:
    def __init__(self, b): self.b, self.p = b, 0
    def byte(self): v = self.b[self.p]; self.p += 1; return v
    def int(self): v = struct.unpack_from('<i', self.b, self.p)[0]; self.p += 4; return v
    def num(self): v = struct.unpack_from('<f', self.b, self.p)[0]; self.p += 4; return v
    def str(self):
        n = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4
        if n == 0: return None
        s = self.b[self.p:self.p+n-1]; self.p += n
        return s.decode('latin1')

class Proto:
    pass

def read_function(r):
    f = Proto()
    f.source = r.str()
    f.linedefined = r.int()
    f.nups = r.byte(); f.numparams = r.byte(); f.is_vararg = r.byte(); f.maxstacksize = r.byte()
    f.lineinfo = [r.int() for _ in range(r.int())]
    f.locvars = []
    for _ in range(r.int()):
        f.locvars.append((r.str(), r.int(), r.int()))
    f.upvalues = [r.str() for _ in range(r.int())]
    f.k = []
    for _ in range(r.int()):
        t = r.byte()
        if t == 3: f.k.append(r.num())
        elif t == 4: f.k.append(r.str())
        elif t == 0: f.k.append(None)
        else: raise ValueError(f'bad const type {t}')
    f.p = [read_function(r) for _ in range(r.int())]
    f.code = [struct.unpack_from('<I', r.b, r.p + 4*i)[0] for i in range(r.int())]
    r.p += 4 * len(f.code)
    return f

def load(b):
    r = Reader(b)
    assert b[:5] == b'\x1bLuaP', b[:5]
    r.p = 18
    return read_function(r)

OPNAMES = ["MOVE","LOADK","LOADBOOL","LOADNIL","GETUPVAL","GETGLOBAL","GETTABLE","SETGLOBAL",
 "SETUPVAL","SETTABLE","NEWTABLE","SELF","ADD","SUB","MUL","DIV","POW","UNM","NOT","CONCAT",
 "JMP","EQ","LT","LE","TEST","CALL","TAILCALL","RETURN","FORLOOP","TFORLOOP","TFORPREP",
 "SETLIST","SETLISTO","CLOSE","CLOSURE"]

def decode(i):
    op = i & 0x3f
    c = (i >> 6) & 0x1ff
    b = (i >> 15) & 0x1ff
    a = (i >> 24) & 0xff
    bx = (i >> 6) & 0x3ffff
    return op, a, b, c, bx, bx - 131071
