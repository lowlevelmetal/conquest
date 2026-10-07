#!/usr/bin/env bash
# Screenshot the game window of a local test instance (X11/XWayland).
#   tools/shoot.sh <instance-name> <out.png>
# The window is matched by _NET_WM_PID against the Battlefront.exe process
# started with CONQUEST_INSTANCE=<instance-name> (see tools/run_instance.sh).
set -u
want="$1" out="$2"

pids=()
for p in $(pgrep -f '[B]attlefront.exe'); do
	if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "CONQUEST_INSTANCE=$want"; then
		pids+=("$p")
	fi
done
[ ${#pids[@]} -gt 0 ] || { echo "no running instance '$want'" >&2; exit 1; }

for w in $(xprop -root _NET_CLIENT_LIST | sed 's/.*# //; s/,//g'); do
	xprop -id "$w" WM_CLASS 2>/dev/null | grep -q steam_app_2446550 || continue
	pid=$(xprop -id "$w" _NET_WM_PID 2>/dev/null | sed -n 's/.* = //p')
	for p in "${pids[@]}"; do
		if [ "$pid" = "$p" ]; then
			# only visible pixels can be read back; run_pair.sh places the
			# copies side by side so neither covers the other
			exec magick import -window "$w" "$out"
		fi
	done
done
echo "no window for instance '$want'" >&2
exit 1
