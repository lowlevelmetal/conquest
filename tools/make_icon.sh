#!/usr/bin/env bash
# Draw the setup program's icon (a ringed planet) into native/setup/conquest.ico.
# Needs ImageMagick 7. Every size is stored as PNG to keep the file small.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# planet lit from the upper left, ring tilted across it
magick -size 420x420 radial-gradient:'#b5e2ff-#06204f' -crop 256x256+112+112 +repage \
	\( -size 256x256 xc:black -fill white -draw "circle 128,128 128,44" \) \
	-alpha off -compose CopyOpacity -composite planet.png
ring() {
	magick -size 256x256 xc:none -fill none -stroke '#f5c542' -strokewidth 13 \
		-draw "ellipse 128,128 112,28 $1" -distort SRT -22 "$2"
}
ring "180,360" back.png
ring "0,180" front.png
magick back.png planet.png -compose over -composite front.png -compose over -composite 256.png
for s in 16 24 32 48 64 128; do
	magick 256.png -resize ${s}x${s} $s.png
done

python3 - "$here/native/setup/conquest.ico" 16 24 32 48 64 128 256 <<'PY'
import struct, sys
out, sizes = sys.argv[1], [int(s) for s in sys.argv[2:]]
images = [open(f"{s}.png", "rb").read() for s in sizes]
data = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, png in zip(sizes, images):
    data += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open(out, "wb").write(data + b"".join(images))
PY
echo "$here/native/setup/conquest.ico"
