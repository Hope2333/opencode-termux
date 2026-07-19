#!/data/data/com.termux/files/usr/bin/bash
# scripts/launcher.sh — OpenCode launcher for Termux
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_RUNTIME="$SELF_DIR/../lib/opencode/runtime/opencode"

cleanup_tty_full() {
	if [ -t 1 ]; then
		printf '\033[?1049l\033[?25h\033[0m' >/dev/tty 2>/dev/null || true
	fi
	if command -v stty >/dev/null 2>&1; then stty sane 2>/dev/null || true; fi
	if command -v tput >/dev/null 2>&1; then tput rmcup >/dev/null 2>&1 || true; fi
}

cleanup_tty_soft() {
	if command -v stty >/dev/null 2>&1; then stty sane 2>/dev/null || true; fi
	if [ -t 1 ]; then
		printf '\033[?25h\033[0m' >/dev/tty 2>/dev/null || true
	fi
}

cleanup_state_locks() {
	local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
	if [ -d "$state_dir" ]; then
		find "$state_dir" -maxdepth 1 -type f -name '*.lock' -delete 2>/dev/null || true
	fi
}

trap 'cleanup_tty_full; exit 130' INT TERM HUP QUIT
cleanup_state_locks
: "${OPENCODE_DISABLE_DEFAULT_PLUGINS:=1}"
export OPENCODE_DISABLE_DEFAULT_PLUGINS

if [[ ! -x "$OPENCODE_RUNTIME" ]]; then
	echo "opencode: runtime not found" >&2
	exit 1
fi

if "$OPENCODE_RUNTIME" "$@"; then
	rc=0
else
	rc=$?
fi
if [ "$rc" -eq 0 ]; then
	cleanup_tty_soft
else
	cleanup_tty_full
fi
exit "$rc"
