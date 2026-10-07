"""Minimal reader/writer for SWBF2 ucfb (.lvl / .script) containers."""
import struct, sys

def read_chunks(buf, off, end):
    """Yield (tag, data_start, size) for each chunk in buf[off:end]."""
    while off + 8 <= end:
        tag = buf[off:off+4].decode('latin1')
        size = struct.unpack_from('<I', buf, off+4)[0]
        yield tag, off+8, size
        off += 8 + size
        off = (off + 3) & ~3  # chunks are 4-byte aligned

def scripts(buf):
    """Return list of (name, info, body_bytes, chunk_offset) for each scr_ chunk."""
    assert buf[:4] == b'ucfb'
    total = struct.unpack_from('<I', buf, 4)[0]
    out = []
    for tag, start, size in read_chunks(buf, 8, 8 + total):
        if tag != 'scr_':
            continue
        name = info = body = None
        for t2, s2, z2 in read_chunks(buf, start, start + size):
            if t2 == 'NAME':
                name = buf[s2:s2+z2].rstrip(b'\0').decode('latin1')
            elif t2 == 'INFO':
                info = buf[s2:s2+z2]
            elif t2 == 'BODY':
                body = buf[s2:s2+z2]
        out.append((name, info, body, start - 8))
    return out

def top_level(buf):
    total = struct.unpack_from('<I', buf, 4)[0]
    return list(read_chunks(buf, 8, 8 + total))

if __name__ == '__main__':
    data = open(sys.argv[1], 'rb').read()
    if len(sys.argv) > 2 and sys.argv[2] == '--all':
        from collections import Counter
        print(Counter(t for t, _, _ in top_level(data)))
    for name, info, body, off in scripts(data):
        print(f'{off:10d} {len(body):8d} {name}')
