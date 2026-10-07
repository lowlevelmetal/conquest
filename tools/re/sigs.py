"""Generate wildcarded byte signatures for the game's Lua API functions and check uniqueness."""
import re, sys
from pe import *

API = {
    'lua_gettop':       0x383ff0,
    'lua_settop':       0x3849d0,
    'lua_pushvalue':    0x384640,
    'lua_type':         0x384ce0,
    'lua_tostring':     0x384bf0,
    'lua_tonumber':     0x384b40,
    'lua_pushnil':      0x384570,
    'lua_pushnumber':   0x384580,
    'lua_pushlstring':  0x384500,
    'lua_pushstring':   0x3845a0,
    'lua_pushcclosure': 0x3843e0,
    'lua_gettable':     0x383fb0,
    'lua_settable':     0x3849a0,
    'lua_newtable':     0x384230,
    'lua_strlen':       0x384ac0,
    'luaL_loadbuffer':  0x385860,
    'lua_pcall':        0x384350,
    'lua_pushboolean':  0x3843c0,
}

def signature(img, rva, length):
    """Bytes of the function prologue with rel32/RIP-disp32 operands wildcarded (None)."""
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64); md.detail = True
    sig = []
    for ins in md.disasm(img.data[rva:rva + length + 16], rva):
        b = list(ins.bytes)
        wild = set()
        if ins.mnemonic in ('call', 'jmp') or ins.mnemonic.startswith('j'):
            if len(b) >= 5 and b[0] in (0xE8, 0xE9) or (len(b) >= 6 and b[0] == 0x0F):
                wild = set(range(len(b) - 4, len(b)))
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
                off = ins.disp_offset
                wild |= set(range(off, off + 4))
        sig += [None if i in wild else v for i, v in enumerate(b)]
        if len(sig) >= length:
            break
    return sig[:length]

def matches(img, sig):
    pat = b''.join(b'.' if v is None else re.escape(bytes([v])) for v in sig)
    text = img.data[img.text_rva:img.text_rva + img.text_size]
    return [m.start() + img.text_rva for m in re.finditer(pat, text, re.S)]

if __name__ == '__main__':
    img = Image()
    for name, rva in API.items():
        for length in (16, 24, 32, 40, 48, 64):
            sig = signature(img, rva, length)
            hits = matches(img, sig)
            if hits == [rva]:
                break
        s = ' '.join('??' if v is None else f'{v:02X}' for v in sig)
        print(f'{name:18s} {rva:#08x} len={length:2d} unique={hits == [rva]} hits={len(hits)}  {s}')
