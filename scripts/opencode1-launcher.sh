#!/data/data/com.termux/files/usr/bin/bash
# opencode1 launcher — dual-generation data isolation (v12.1).
#
# Why: the v1 runtime hardcodes the plain `opencode/` roots (live-fd verified;
# OPENCODE_CONFIG_DIR and friends are enumerated but NOT consumed). The four
# XDG_*_HOME exports re-root every path under an `opencode1/` isolation prefix;
# the runtime then appends its own `opencode/` suffix, landing in the NESTED
# layout migrate-to-opencode1.sh isolate maintains: <root>/opencode1/opencode/.
# v2 keeps the plain roots untouched — the two generations never share a dir.
#
# LD_LIBRARY_PATH covers DT_RUNPATH $ORIGIN/../lib/opencode after the runtime
# moves under lib/opencode1/runtime/; compressed additionally ships its shim in
# lib/opencode1/ — both roots are listed so every package layout resolves
# (absent dirs are harmless: the dynamic linker just skips them).
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/opencode1"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/opencode1"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/opencode1"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/opencode1"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode1:$P/lib/opencode1/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# service-port split (readiness fix, evidence: tools/opencode-readiness-fix/):
# both v2 generations default the managed service port to 0xc0de=49374, but the
# XDG isolation keeps their registration files apart — a plain-generation daemon
# squatting 49374 is invisible to this generation's discovery, so every
# `serve --service` contender dies of EADDRINUSE and the TUI handshake stalls
# until ensure()'s 120s deadline ("Timed out waiting for the background
# service"). Bootstrap a per-generation port (49376) in this generation's
# service config: absent file -> write one; existing file without a "port" key
# -> inject one (opencode writes pretty JSON whose first line is always "{").
# Best-effort: any failure falls back to the stock default port.
CFG_DIR="${XDG_CONFIG_HOME}/opencode"
CFG_FILE="${CFG_DIR}/service.json"
if [ ! -f "$CFG_FILE" ]; then
	mkdir -p "$CFG_DIR" 2>/dev/null || true
	printf '{"port": 49376}\n' > "$CFG_FILE" 2>/dev/null || true
elif ! grep -q '"port"' "$CFG_FILE" 2>/dev/null; then
	sed -i '1s/^{$/{\n  "port": 49376,/' "$CFG_FILE" 2>/dev/null || true
fi

# pty splice (optional asset, backward compatible): when the compressed package
# ships the patched musl librust_pty (bun-pty 0.4.11 splice — see
# tools/bun-pty-splice/ and docs/20-packaging/24-compressed-line-contract.md), point bun-pty's
# BUN_PTY_LIB probe at it so the runtime dlopens the bionic-compatible build
# instead of failing on the inlined asset. Its DT_NEEDED shim.so resolves via
# the pty dir added to LD_LIBRARY_PATH above. Old packages without the asset
# are unaffected (no export).
if [ -f "$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so"
fi

# epoll compat shim (optional asset, backward compatible): pre-#32490 bun
# builds (v1.4.0 34cbb9a40, as shipped in 1.18.32-4) call epoll_pwait2
# (syscall 441, kernel >= 5.1) via libc::syscall and crash on older kernels
# (oscar 3.18.140: TUI SIGSEGV ~4.4s, see task-v1rebuild.txt). The shim
# translates 441 -> epoll_pwait with a timespec->ms conversion. Injected via
# LD_PRELOAD ONLY when the package shipped the asset; packages built before
# the asset are unaffected (no export).
if [ -f "$P/lib/opencode1/libepoll-compat.so" ]; then
	export LD_PRELOAD="$P/lib/opencode1/libepoll-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# runtime probe order: layered (native/compressed v12.1 layout) first, then the
# wrapper line's original staged layout. Sibling Conflicts (opencode1 vs
# opencode1-wrapper) guarantee at most one candidate exists per install.
for _rt in "$P/lib/opencode1/runtime/opencode" "$P/lib/opencode/runtime/opencode"; do
	if [ -x "$_rt" ]; then
		exec "$_rt" "$@"
	fi
done
echo "opencode1: runtime not found under $P/lib/opencode1/runtime or $P/lib/opencode/runtime" >&2
exit 127
