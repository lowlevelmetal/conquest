#!/usr/bin/env bash
# Launch a separate copy of BF2 through Proton for local multi-instance tests.
#   tools/run_instance.sh <instance-name> [winsock-trace-file]
# The instance name selects conquest.<name>.log and conquest/autotest.<name>.txt.
set -u
game=/mnt/games1/SteamLibrary/steamapps/common/Battle
proton="/mnt/games1/SteamLibrary/steamapps/common/Proton - Experimental/proton"
export STEAM_COMPAT_DATA_PATH=/mnt/games1/SteamLibrary/steamapps/compatdata/2446550
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
