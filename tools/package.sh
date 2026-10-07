#!/usr/bin/env bash
# Build the release zip: native/build/conquest-mod.zip
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$here/native" >/dev/null
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/conquest-mod/conquest"
cp "$here/native/build/dle_crashpad.dll" "$here/install.sh" "$here/dist/install.bat" \
	"$here/dist/uninstall.bat" "$here/dist/README.txt" "$stage/conquest-mod/"
# player build: no test scripts
cp -r "$here/mod/." "$stage/conquest-mod/conquest/"
rm -rf "$stage/conquest-mod/conquest/lua/tests" "$stage/conquest-mod/conquest/lua/autotest.lua"
# install.sh expects mod/ next to it in the repo; the package keeps conquest/ instead
sed -i 's|cp -r "$here/mod/." "$game/conquest/"|cp -r "$here/conquest/." "$game/conquest/"|; s|dll="$here/native/build/dle_crashpad.dll"|dll="$here/dle_crashpad.dll"|; s|\[ -f "$dll" \] \|\| make -C "$here/native" >/dev/null||' "$stage/conquest-mod/install.sh"
out="$here/native/build/conquest-mod.zip"
rm -f "$out"
(cd "$stage" && python3 -c "
import os, zipfile
with zipfile.ZipFile('$out', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('conquest-mod'):
        for f in files:
            z.write(os.path.join(root, f))
")
echo "$out"
