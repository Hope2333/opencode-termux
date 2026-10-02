#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher — v2 compressed family (opencode-compressed).
#
# Derived from scripts/opencode1-launcher.sh (v1 family) with two v2-era
# removals:
# - No XDG re-root: the v2 compressed variant is the SAME generation as the
#   v2 native mainline, so it shares the plain roots (~/.config/opencode).
#   The XDG_*_HOME isolation is a cross-generation (v1-vs-v2) measure only.
# - No per-generation service-port injection: with same-generation mutual
#   exclusion (Conflicts: opencode) there is at most one v2 provider
#   installed, so the stock default port 49374 is correct. The 49376
#   port-split is a cross-generation coexistence measure, not needed here.
#
# Kept from the v1 launcher:
# - LD_LIBRARY_PATH covering the layered runtime (lib/opencode/runtime/) and
#   the shim root (lib/opencode/): the UPX stub maps segments under
#   /memfd:upx where DT_RUNPATH $ORIGIN resolution dies, so the dynamic
#   linker needs the explicit path to libopencode-crhandler.so.
# - BUN_PTY_LIB injection (optional asset, backward compatible): when the
#   package ships the patched musl librust_pty (bun-pty 0.4.11 splice — see
#   tools/bun-pty-splice/ and docs/compressed-line.md), point bun-pty's
#   probe at it. Absent asset = no export, graceful degradation.
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ -f "$P/lib/opencode/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode/pty/librust_pty_arm64_musl_patched.so"
fi

RT="$P/lib/opencode/runtime/opencode"
if [ -x "$RT" ]; then
	exec "$RT" "$@"
fi
echo "opencode: runtime not found under $P/lib/opencode/runtime" >&2
exit 127
