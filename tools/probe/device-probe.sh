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
# The server log is kept (not /dev/null) because the API password is printed
# there and the pty probe below needs it.
SERVE_LOG="$T/probe-serve.log"
: >"$SERVE_LOG"
(nohup "$BIN" serve --port "$PORT" >"$SERVE_LOG" 2>&1 &)
SERVE_CODE=000
for _ in $(seq 1 30); do
	SERVE_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
	[ "$SERVE_CODE" = 200 ] && break
	sleep 1
done
echo "serve=$SERVE_CODE"

# --- pty (bionic dlopen gate) ----------------------------------------------
# A TUI frame does NOT prove terminals work: on bionic the embedded
# librust_pty is glibc-linked, so POST /api/pty dies with ERR_DLOPEN_FAILED
# while serve and the TUI look perfectly healthy (Push261103 shipped that).
# This is the only check that catches it, so it is mandatory.
PW="$(sed -n 's/^server password //p' "$SERVE_LOG" 2>/dev/null | head -1)"
PTY_CODE=000
PTY_BODY=""
if [ -n "$PW" ]; then
	_resp="$(curl -s -u "opencode:$PW" -X POST -H 'content-type: application/json' \
		-d '{}' -w '\n%{http_code}' "http://127.0.0.1:$PORT/api/pty" 2>/dev/null)"
	PTY_CODE="$(printf '%s' "$_resp" | tail -1)"
	PTY_BODY="$(printf '%s' "$_resp" | sed '$d' | head -c 400)"
fi
case "$PTY_CODE" in
200|201) echo "pty=ok" ;;
*)
	# The API body is often generic; the real cause (e.g. ERR_DLOPEN_FAILED) is
	# only in the server log — take it from there when the body has none.
	_why="$(printf '%s' "$PTY_BODY" | grep -o 'ERR_[A-Z_]*' | head -1)"
	if [ -z "$_why" ]; then
		_why="$(tail -40 "$SERVE_LOG" 2>/dev/null | grep -o 'ERR_[A-Z_]*' | head -1)"
	fi
	echo "pty=fail:${_why:-http-$PTY_CODE}"
	[ -n "$PTY_BODY" ] && printf '%s\n' "$PTY_BODY" | head -c 200 | sed 's/^/  pty! /'
	;;
esac

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
