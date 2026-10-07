#!/usr/bin/env bash
# Run a two-instance autotest on this machine.
#   tools/run_pair.sh "<host test args>" "<client test args>"
# e.g. tools/run_pair.sh "cgc_play host cw 1 4 battle" "cgc_play join 192.168.1.141 4 battle"
# Logs: <game>/conquest.host.log and <game>/conquest.client.log
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
game=/mnt/games1/SteamLibrary/steamapps/common/Battle

pkill -f '[B]attlefront.exe'
for _ in $(seq 1 20); do pgrep -f '[B]attlefront.exe' >/dev/null || break; sleep 1; done
make -s -C "$here/native" >/dev/null
"$here/install.sh" "$game" >/dev/null
echo "$1" > "$game/conquest/autotest.host.txt"
echo "$2" > "$game/conquest/autotest.client.txt"
rm -f "$game/conquest.host.log" "$game/conquest.client.log"

"$here/tools/run_instance.sh" host &
for _ in $(seq 1 90); do grep -q "net: listening" "$game/conquest.host.log" 2>/dev/null && break; sleep 1; done
"$here/tools/run_instance.sh" client &
echo "started host and client"
wait
