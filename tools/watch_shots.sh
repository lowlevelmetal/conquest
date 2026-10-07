#!/usr/bin/env bash
# Capture a screenshot whenever an instance's log says "tour: shot <label>".
#   tools/watch_shots.sh <instance-name> <out-dir>
# Exits when the instance's log reports the game quitting.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
game=/mnt/games1/SteamLibrary/steamapps/common/Battle
inst="$1" dir="$2"
log="$game/conquest.$inst.log"
mkdir -p "$dir"
for _ in $(seq 1 60); do [ -f "$log" ] && break; sleep 1; done
tail -n +1 -F "$log" 2>/dev/null | sed -u 's/\r$//' | while read -r line; do
	case "$line" in
	*"tour: shot "*)
		label=${line##*tour: shot }
		"$here/shoot.sh" "$inst" "$dir/$inst-$label.png" && echo "captured $inst-$label"
		;;
	*"autotest: quitting game"*|*"process exiting"*)
		echo "instance $inst finished"
		pkill -P $$ tail
		exit 0
		;;
	esac
done
