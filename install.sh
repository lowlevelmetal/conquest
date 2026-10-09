#!/usr/bin/env bash
# Install or remove the online Galactic Conquest mod.
#   ./install.sh [game_dir]            install
#   ./install.sh --uninstall [game_dir]
set -euo pipefail

uninstall=0
if [ "${1:-}" = "--uninstall" ]; then uninstall=1; shift; fi
game="${1:-$HOME/.local/share/Steam/steamapps/common/Battle}"
here="$(cd "$(dirname "$0")" && pwd)"
dll_path="$game/dle_crashpad.dll"
orig="$game/dle_crashpad_orig.dll"

if [ ! -f "$game/Battlefront2.dll" ]; then
	echo "Battlefront Classic Collection not found in: $game" >&2
	echo "Pass the game folder as an argument." >&2
	exit 1
fi

# what dle_crashpad.dll is: missing, loader (ours), other (Aspyr's); an
# unreadable file is not guessed at
dll_kind() {
	if [ ! -e "$dll_path" ]; then
		echo missing
	elif [ ! -r "$dll_path" ]; then
		echo "Cannot read $dll_path. Close the game, then try again." >&2
		exit 1
	elif grep -qa -e OnlineGalacticConquestLoader -e dle_crashpad_orig "$dll_path"; then
		echo loader
	else
		echo other
	fi
}

if [ $uninstall = 1 ]; then
	kind="$(dll_kind)"
	verify=0
	if [ -f "$orig" ]; then
		if [ "$kind" = other ]; then
			# a game update already put Aspyr's DLL back; the backup is stale
			rm -f "$orig"
		else
			mv -f "$orig" "$dll_path"
		fi
	elif [ "$kind" = loader ]; then
		# no backup to put back: remove the loader; Steam restores Aspyr's DLL
		rm -f "$dll_path"
		verify=1
	fi
	rm -rf "$game/conquest"
	rm -f "$game/conquest.log"
	echo "Removed."
	if [ $verify = 1 ]; then
		echo "Before playing, let Steam restore one game file: right-click the game in Steam,"
		echo "choose Properties > Installed Files, then Verify integrity of game files."
	fi
	exit 0
fi

dll="$here/native/build/dle_crashpad.dll"
[ -f "$dll" ] || make -C "$here/native" >/dev/null

kind="$(dll_kind)"
# replace the scripts wholesale so files a newer version dropped go too
rm -rf "$game/conquest/lua"
mkdir -p "$game/conquest"
cp -r "$here/mod/." "$game/conquest/"
# The game cannot start without a dle_crashpad.dll: write the loader in full
# first, and move Aspyr's DLL aside only once it can be replaced. If the
# current DLL is Aspyr's (first install, or Steam restored it after an
# update) it becomes the backup the loader forwards to.
cp "$dll" "$dll_path.new"
if [ "$kind" = other ]; then
	mv -f "$dll_path" "$orig"
fi
if ! mv -f "$dll_path.new" "$dll_path"; then
	[ "$kind" = other ] && mv -f "$orig" "$dll_path"
	rm -f "$dll_path.new"
	echo "Could not write $dll_path" >&2
	exit 1
fi
echo "Installed to $game"
