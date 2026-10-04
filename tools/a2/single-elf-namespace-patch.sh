#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# single-elf-namespace-patch.sh — bake the opencode1 isolation namespace into
# the v1 runtime at build time, so bin/opencode1 can be the payload itself and
# the bash launcher (scripts/opencode1-launcher.sh) becomes unnecessary.
#
# Why this is the only injection point:
#   packages/core/src/global.ts:10  `const app = "opencode"`
#   packages/core/src/global.ts:11-15  data/cache/config/state/tmp all join(app)
#   packages/core/src/global.ts:3  the ONLY `from "xdg-basedir"` import in
#   packages/*/src — one literal, five derived roots, zero other writers
#   (grep -rn 'from "xdg-basedir"' packages/*/src/ -> 1 hit)
#
# `app` is a `const` with no env override: Flag enumerates OPENCODE_CONFIG_DIR
# but that only replaces `config` in make() (global.ts:64); nothing can rename
# `app`. Hence a build-time text replacement is the only way to make the
# namespace a property of the artifact rather than of the caller's env.
#
# Path algebra (path.join normalizes both sides to the same bytes):
#   launcher:  join($HOME/.local/share/opencode1, "opencode")
#   patched:   join($HOME/.local/share, "opencode1/opencode")
#   => $HOME/.local/share/opencode1/opencode   (identical)
#
# Idempotent: skips when `app` already carries the namespace.
# Run BEFORE build-v1.sh. Not applied by any packaging script yet — the
# single-ELF packaging change is deliberately staged behind the assertions in
# docs/single-elf-v1.md §5.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-1.18.32}"
NAMESPACE="${OPENCODE1_NAMESPACE:-opencode1}"
GLOBAL_TS="$V1_SRC/packages/core/src/global.ts"
ORIG_LINE='const app = "opencode"'
PATCHED_LINE="const app = \"$NAMESPACE/opencode\""

[[ -f "$GLOBAL_TS" ]] || { echo "ERR: $GLOBAL_TS missing — set V1_SRC" >&2; exit 1; }

if grep -qxF "$PATCHED_LINE" "$GLOBAL_TS"; then
	echo "OK (already patched): $NAMESPACE baked into global.ts"
	exit 0
fi

if ! grep -qxF "$ORIG_LINE" "$GLOBAL_TS"; then
	echo "ERR: global.ts does not carry the expected 'const app = \"opencode\"' line." >&2
	echo "     Upstream layout changed — re-derive the injection point before patching." >&2
	exit 1
fi

BAK="$GLOBAL_TS.single-elf.bak"
[[ -f "$BAK" ]] || cp -p "$GLOBAL_TS" "$BAK"

python3 - "$GLOBAL_TS" "$ORIG_LINE" "$PATCHED_LINE" <<'PY'
import io, sys
path, orig, patched = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, encoding="utf-8") as fh:
    lines = fh.readlines()
hits = [i for i, l in enumerate(lines) if l.rstrip("\n") == orig]
if len(hits) != 1:
    sys.exit("ERR: expected exactly 1 %r line, found %d" % (orig, len(hits)))
lines[hits[0]] = patched + "\n"
with io.open(path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
print("patched line %d: %s" % (hits[0] + 1, patched))
PY

grep -qxF "$PATCHED_LINE" "$GLOBAL_TS" || { echo "ERR: post-patch verify failed" >&2; exit 1; }
echo "OK: namespace '$NAMESPACE' baked into ${GLOBAL_TS#$V1_SRC/} (backup: ${BAK##*/})"
echo "NOTE: rebuild the runtime before packaging; assertions A1-A10 live in docs/single-elf-v1.md §5"
