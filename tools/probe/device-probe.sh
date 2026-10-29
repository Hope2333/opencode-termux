#!/data/data/com.termux/files/usr/bin/bash
# tools/probe/device-probe.sh — installed ON the Android device by probe-version.sh.
#
#   device-probe.sh <v1|v2> <version> <deb-path> [wait-seconds] [port]
#
# Prints `key=value` lines consumed by scripts/lib/probe-lib.sh:probe_verdict,
# plus a human-readable tail of the captured frame. Everything it touches is
# reverted: the deb is deleted, tmux killed, the probe server killed by exact PID
# (never `pkill -f` with a path — that once took sshd down with it).
set -u
KIND="$1"; V="$2"; DEB="$3"; WAIT="${4:-30}"; PORT="${5:-48780}"
P=/data/data/com.termux/files/usr
T="$P/tmp"
BIN="$P/bin/opencode"; [ "$KIND" = v1 ] && BIN="$P/bin/opencode1"

# --- install ---------------------------------------------------------------
if dpkg -i "$DEB" >"$T/probe-install.log" 2>&1; then
	echo "install=ok"
else
	echo "install=fail"
	# surface the reason (usually a file conflict with the other generation)
	grep -iE 'overwrite|conflict|error' "$T/probe-install.log" 2>/dev/null | head -3 | sed 's/^/  ! /'
	exit 0
fi

GOT="$("$BIN" --version 2>&1 | head -1)"
echo "version=$GOT"
case "$KIND" in
v1) echo "expected=$V" ;;
*) echo "expected=opencode v$V" ;;
esac

# --- serve -----------------------------------------------------------------
(nohup "$BIN" serve --port "$PORT" >/dev/null 2>&1 &)
sleep 12
echo "serve=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"

self=$$; ppid=$PPID
for d in /proc/[0-9]*; do
	pid=${d#/proc/}
	[ "$pid" = "$self" ] && continue
	[ "$pid" = "$ppid" ] && continue
	cl=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
	case "$cl" in *"serve --port $PORT"*) kill -9 "$pid" 2>/dev/null ;; esac
done

# --- TUI -------------------------------------------------------------------
tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s probe -x 120 -y 30 "$BIN" 2>/dev/null
sleep "$WAIT"
tmux capture-pane -p -t probe >"$T/probe-before.txt" 2>/dev/null
echo "tui_bytes=$(wc -c <"$T/probe-before.txt" | tr -d ' ')"

tmux send-keys -t probe "probe-$V" 2>/dev/null
sleep 5
tmux capture-pane -p -t probe >"$T/probe-after.txt" 2>/dev/null
echo "typed_diff=$(diff "$T/probe-before.txt" "$T/probe-after.txt" 2>/dev/null | grep -c '^[<>]')"
echo "echoed=$(grep -c "probe-$V" "$T/probe-after.txt" 2>/dev/null)"

sleep 15
echo "alive15=$(tmux has-session -t probe 2>/dev/null && echo YES || echo NO)"
echo "crash=$(grep -ciE 'panic|segmentation|SIGSEGV|SIGSYS' "$T/probe-after.txt" 2>/dev/null)"
echo "degrade=$(grep -c '降级' "$T/probe-after.txt" 2>/dev/null)"

sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1bP[^\x1b]*\x1b\\//g' "$T/probe-after.txt" 2>/dev/null |
	grep -vE '^[[:space:]]*$' | head -4 | sed 's/^/  | /'

tmux kill-server 2>/dev/null
rm -f "$T/probe-before.txt" "$T/probe-after.txt" "$T/probe-install.log" "$DEB"
exit 0
