#!/usr/bin/env bash
# Launch a separate copy of BF2 through Proton for local multi-instance tests.
#   tools/run_instance.sh <instance-name> [winsock-trace-file]
# The instance name selects conquest.<name>.log and conquest/autotest.<name>.txt.
set -u
game=/mnt/games1/SteamLibrary/steamapps/common/Battle
proton="/mnt/games1/SteamLibrary/steamapps/common/Proton - Experimental/proton"
# Each copy gets its own Wine prefix (and so its own wineserver): two copies
# sharing a prefix, or a copy next to a Steam-launched game, take each other
# down when one of them exits.
compat=/mnt/games1/SteamLibrary/steamapps/compatdata
export STEAM_COMPAT_DATA_PATH="$compat/2446550-$1"
if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
	cp -a "$compat/2446550" "$STEAM_COMPAT_DATA_PATH"
fi
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export SteamAppId=2446550 SteamGameId=2446550 CONQUEST_INSTANCE="$1"
cd "$game"
# CONQUEST_DEBUG_GPU=1 shows vkd3d-proton (D3D12) warnings and Wine errors
if [ "${CONQUEST_DEBUG_GPU:-}" = 1 ]; then
	export VKD3D_DEBUG=warn WINEDEBUG=err+all
fi
if [ -n "${2:-}" ]; then
	WINEDEBUG=+winsock "$proton" run ./Battlefront.exe -bf2 2>&1 \
		| grep --line-buffered -i -E "bind|connect|sendto|WSASendTo|WSAConnect|listen|getsockname" > "$2"
else
	"$proton" run ./Battlefront.exe -bf2 >"$game/conquest.$1.stderr" 2>&1
	echo "game exited with status $?" >>"$game/conquest.$1.stderr"
fi
