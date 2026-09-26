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
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode1${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
