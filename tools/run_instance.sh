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
if [ -n "${2:-}" ]; then
	WINEDEBUG=+winsock "$proton" run ./Battlefront.exe -bf2 2>&1 \
		| grep --line-buffered -i -E "bind|connect|sendto|WSASendTo|WSAConnect|listen|getsockname" > "$2"
else
	"$proton" run ./Battlefront.exe -bf2 >/dev/null 2>&1
fi
