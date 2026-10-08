#!/usr/bin/env bash
# Build the release files into native/build/release/:
#   OnlineGalacticConquest-Setup-<version>.exe   Windows setup (mod built in)
#   OnlineGalacticConquest-<version>.zip         setup, manual installers, mod files
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^#define CONQUEST_VERSION "\(.*\)"/\1/p' "$here/native/version.h")"
make -s -C "$here/native" >/dev/null
out="$here/native/build/release"
rm -rf "$out"
mkdir -p "$out"
setup="$out/OnlineGalacticConquest-Setup-$version.exe"
cp "$here/native/build/OnlineGalacticConquest-Setup.exe" "$setup"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
pkg="$stage/OnlineGalacticConquest"
mkdir -p "$pkg/conquest"
cp "$here/native/build/dle_crashpad.dll" "$here/install.sh" "$here/dist/install.bat" \
	"$here/dist/uninstall.bat" "$here/dist/README.txt" "$pkg/"
cp "$setup" "$pkg/OnlineGalacticConquest-Setup.exe"
# player build: no test scripts
cp -r "$here/mod/." "$pkg/conquest/"
rm -rf "$pkg/conquest/lua/tests" "$pkg/conquest/lua/autotest.lua"
echo "$version" > "$pkg/conquest/version.txt"
# install.sh expects mod/ next to it in the repo; the package keeps conquest/ instead
sed -i 's|cp -r "$here/mod/." "$game/conquest/"|cp -r "$here/conquest/." "$game/conquest/"|; s|dll="$here/native/build/dle_crashpad.dll"|dll="$here/dle_crashpad.dll"|; s|\[ -f "$dll" \] \|\| make -C "$here/native" >/dev/null||' "$pkg/install.sh"
zip="$out/OnlineGalacticConquest-$version.zip"
(cd "$stage" && python3 -c "
import os, zipfile
with zipfile.ZipFile('$zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('OnlineGalacticConquest'):
        for f in sorted(files):
            path = os.path.join(root, f)
            info = zipfile.ZipInfo.from_file(path)
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, 'rb') as data:
                z.writestr(info, data.read())
")
ls -1 "$out"/*
