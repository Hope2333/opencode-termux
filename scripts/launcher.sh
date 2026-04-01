#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_CLI="$SELF_DIR/../lib/opencode/packages/opencode/bin/opencode"
OPENCODE_RUNTIME="$SELF_DIR/../lib/opencode/runtime/opencode"
STATX_SHIM="$SELF_DIR/../lib/opencode/lib/libstatx-shim.so"

# Preload statx shim to avoid seccomp-blocked statx() syscall on Android.
# glibc's stat()/fstatat() internally use direct syscall(statx) instructions;
# Android seccomp blocks this (SIGSYS → SIGSEGV). The shim installs a SIGSYS
# handler that returns -ENOSYS, triggering glibc's fallback to fstatat.
# Can be disabled with OPENCODE_DISABLE_STATX_SHIM=1.
apply_statx_shim() {
    if [[ "${OPENCODE_DISABLE_STATX_SHIM:-0}" == "1" ]]; then
        return
    fi
    if [[ -f "$STATX_SHIM" ]]; then
        export LD_PRELOAD="${STATX_SHIM}${LD_PRELOAD:+:$LD_PRELOAD}"
    fi
}

cleanup_tty_full() {
	if [ -t 1 ]; then
		printf '\033[?1049l\033[?25h\033[0m' >/dev/tty 2>/dev/null || true
	fi
	command -v stty >/dev/null 2>&1 && stty sane 2>/dev/null || true
	command -v tput >/dev/null 2>&1 && tput rmcup >/dev/null 2>&1 || true
}

cleanup_tty_soft() {
	command -v stty >/dev/null 2>&1 && stty sane 2>/dev/null || true
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

cleanup_broken_cached_modules() {
	local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
	local mod_dir="$cache_root/node_modules/opencode-anthropic-auth"
	if [ -d "$mod_dir" ] && [ ! -f "$mod_dir/package.json" ]; then
		rm -rf "$cache_root/node_modules" 2>/dev/null || true
	fi
}

ensure_stdio_tty() {
	if [ -t 0 ] && [ -t 1 ] && [ -w /dev/tty ]; then
		exec </dev/tty >/dev/tty 2>/dev/tty
	fi
}

trap 'cleanup_tty_full; exit 130' INT TERM HUP QUIT
ensure_stdio_tty
cleanup_state_locks
cleanup_broken_cached_modules
: "${OPENCODE_DISABLE_DEFAULT_PLUGINS:=1}"
export OPENCODE_DISABLE_DEFAULT_PLUGINS
apply_statx_shim

if [[ -x "$OPENCODE_RUNTIME" ]]; then
	"$OPENCODE_RUNTIME" "$@"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		cleanup_tty_soft
	else
		cleanup_tty_full
	fi
	exit $rc
fi

"$OPENCODE_CLI" "$@"
rc=$?
if [ "$rc" -eq 0 ]; then
	cleanup_tty_soft
else
	cleanup_tty_full
fi
exit $rc
