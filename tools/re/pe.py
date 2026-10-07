"""Helpers for locating code in Battlefront2.dll (x64 PE) with pefile + capstone."""
import struct, sys, functools
import pefile, capstone

DLL = '/mnt/games1/SteamLibrary/steamapps/common/Battle/Battlefront2.dll'

class Image:
    def __init__(self, path=DLL):
        self.pe = pefile.PE(path, fast_load=True)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.data = self.pe.get_memory_mapped_image()
        text = next(s for s in self.pe.sections if s.Name.rstrip(b'\0') == b'.text')
        self.text_rva, self.text_size = text.VirtualAddress, text.Misc_VirtualSize
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.md.detail = False

    def find_string(self, s):
        """RVAs of NUL-terminated occurrences of s."""
        needle = s.encode() + b'\0'
        out, i = [], self.data.find(needle)
        while i >= 0:
            if i == 0 or self.data[i-1] == 0:
                out.append(i)
            i = self.data.find(needle, i + 1)
        return out

    @functools.cached_property
    def riprefs(self):
        """Map target RVA -> list of instruction RVAs using RIP-relative disp32 (lea/mov)."""
        refs = {}
        d, start, end = self.data, self.text_rva, self.text_rva + self.text_size
        # scan for REX.W 8D /r (lea r64, [rip+disp32]) and 48/4C 8B (mov) patterns with modrm mod=00 rm=101
        for i in range(start, end - 7):
            b0, b1, b2 = d[i], d[i+1], d[i+2]
            if b0 in (0x48, 0x4C) and b1 in (0x8D, 0x8B) and (b2 & 0xC7) == 0x05:
                disp = struct.unpack_from('<i', d, i + 3)[0]
                tgt = i + 7 + disp
                refs.setdefault(tgt, []).append(i)
        return refs

    def dis(self, rva, n=30):
        code = self.data[rva:rva + n * 15]
        out = []
        for ins in self.md.disasm(code, rva):
            out.append(ins)
            if len(out) >= n:
                break
        return out

def show(img, rva, n=30, mark=None):
    for ins in img.dis(rva, n):
        tag = ' <==' if ins.address == mark else ''
        print(f'  {ins.address:08x}: {ins.mnemonic:6s} {ins.op_str}{tag}')

def cstr(img, va):
    rva = va - img.base
    if not (0 <= rva < len(img.data)):
        return None
    s = img.data[rva:rva + 64].split(b'\0')[0]
    return s.decode('latin1') if s and all(32 <= c < 127 for c in s) else None

def reg_table(img, entry_rva):
    """Walk a luaL_reg array containing entry_rva back to its start, return [(rva, name, fn_rva)]."""
    p = entry_rva
    while cstr(img, struct.unpack_from('<Q', img.data, p - 16)[0]):
        p -= 16
    out = []
    while True:
        n, f = struct.unpack_from('<QQ', img.data, p)
        name = cstr(img, n)
        if not name:
            break
        out.append((p, name, f - img.base))
        p += 16
    return out

def scriptcb(img, name):
    """RVA of the C function registered under a ScriptCB_* name (any reg table)."""
    needle = name.encode() + b'\0'
    i = img.data.find(needle)
    while i >= 0:
        va = img.base + i
        j = img.data.find(struct.pack('<Q', va))
        while j >= 0:
            fn = struct.unpack_from('<Q', img.data, j + 8)[0] - img.base
            if img.text_rva <= fn < img.text_rva + img.text_size:
                return fn
            j = img.data.find(struct.pack('<Q', va), j + 1)
        i = img.data.find(needle, i + 1)
    return None
