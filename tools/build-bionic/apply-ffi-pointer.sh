#!/data/data/com.termux/files/usr/bin/bash
# apply-ffi-pointer.sh — Android tagged-pointer fix for the bundled @opentui/core.
#
# Usage: apply-ffi-pointer.sh <@opentui/core dir>
#
# Runs tools/build-bionic/patch-ffi-pointer.py over every chunk that carries the
# POINTER_UNSAFE constant. Rationale (issues #43/#45/#46): on Android 11+ Scudo
# tags heap pointers in the top byte, the value exceeds 2^53-1, and opentui's
# toSafeNumberPointer() throws "Pointer exceeds integer range" inside
# createContext — the TUI never starts.
#
# Exit codes: 0 = at least one chunk patched or already patched; 1 = drift /
# no chunk found (fail loud: a silently unpatched build would ship the crash).
set -uo pipefail
BASE="${1:-}"
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "usage: $0 <@opentui/core dir>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fixed=0
seen=0
for c in "$BASE"/chunk-bun-*.js "$BASE"/chunk-node-*.js; do
	[ -f "$c" ] || continue
	grep -qF 'POINTER_UNSAFE' "$c" || continue
	seen=$((seen + 1))
	python3 "$HERE/patch-ffi-pointer.py" "$c" || exit 1
	fixed=$((fixed + 1))
done

if [ "$seen" -eq 0 ]; then
	echo "Error: no chunk carries POINTER_UNSAFE under $BASE — FFI layout drifted, refusing to ship an unpatched bundle" >&2
	exit 1
fi
echo "ffi pointer patch: $fixed chunk(s) handled"
exit 0
