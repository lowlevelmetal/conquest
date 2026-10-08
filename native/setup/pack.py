#!/usr/bin/env python3
"""Build the setup program's payload: the files it writes into the game folder.

    pack.py <out> <dle_crashpad.dll> <mod dir> <README.txt>

Format: b"CGC1", then per file a little-endian u16 path length, the UTF-8
path relative to the game folder ('/' separators), a u32 size and the bytes.
Test scripts stay out, as in the release zip.
"""
import os
import struct
import sys

SKIP = {"lua/tests", "lua/autotest.lua"}


def mod_files(mod_dir):
    for root, dirs, files in os.walk(mod_dir):
        rel_root = os.path.relpath(root, mod_dir).replace(os.sep, "/")
        rel_root = "" if rel_root == "." else rel_root + "/"
        dirs[:] = sorted(d for d in dirs if rel_root + d not in SKIP)
        for name in sorted(files):
            rel = rel_root + name
            if rel not in SKIP:
                yield "conquest/" + rel, os.path.join(root, name)


def main():
    out, dll, mod_dir, readme = sys.argv[1:5]
    entries = [("dle_crashpad.dll", open(dll, "rb").read())]
    entries += [(rel, open(path, "rb").read()) for rel, path in mod_files(mod_dir)]
    # opened in Notepad from the setup program
    text = open(readme, "rb").read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    entries.append(("conquest/README.txt", text))

    blob = bytearray(b"CGC1")
    for rel, data in entries:
        name = rel.encode("utf-8")
        blob += struct.pack("<H", len(name)) + name + struct.pack("<I", len(data)) + data
    with open(out, "wb") as f:
        f.write(blob)


if __name__ == "__main__":
    main()
