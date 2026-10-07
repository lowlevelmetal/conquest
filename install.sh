#!/usr/bin/env bash
# Install or remove the online Galactic Conquest mod.
#   ./install.sh [game_dir]            install
#   ./install.sh --uninstall [game_dir]
set -euo pipefail

uninstall=0
if [ "${1:-}" = "--uninstall" ]; then uninstall=1; shift; fi
game="${1:-$HOME/.local/share/Steam/steamapps/common/Battle}"
here="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$game/Battlefront2.dll" ]; then
	echo "Battlefront Classic Collection not found in: $game" >&2
	echo "Pass the game folder as an argument." >&2
	exit 1
fi

if [ $uninstall = 1 ]; then
	if [ -f "$game/dle_crashpad_orig.dll" ]; then
		mv -f "$game/dle_crashpad_orig.dll" "$game/dle_crashpad.dll"
	fi
	rm -rf "$game/conquest"
	rm -f "$game/conquest.log"
	echo "Removed. (Steam > Verify integrity also restores the original files.)"
	exit 0
fi

dll="$here/native/build/dle_crashpad.dll"
[ -f "$dll" ] || make -C "$here/native" >/dev/null

# keep Aspyr's crash reporter as the forwarding target; if the current DLL is
# Aspyr's (first install, or Steam restored it after an update) it becomes the backup
if ! grep -q "dle_crashpad_orig" "$game/dle_crashpad.dll"; then
	mv -f "$game/dle_crashpad.dll" "$game/dle_crashpad_orig.dll"
fi
cp "$dll" "$game/dle_crashpad.dll"
mkdir -p "$game/conquest"
cp -r "$here/mod/." "$game/conquest/"
echo "Installed to $game"
