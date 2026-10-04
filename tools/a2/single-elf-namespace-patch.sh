#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# single-elf-namespace-patch.sh — bake the opencode1 isolation namespace into
# the v1 runtime at build time, so bin/opencode1 can be the payload itself and
# the bash launcher (scripts/opencode1-launcher.sh) becomes unnecessary.
#
# Single-ELF namespace bake, with an optional XDG-ignoring variant.
#
#   ./tools/a2/single-elf-namespace-patch.sh                  # default: namespace only
#   ./tools/a2/single-elf-namespace-patch.sh --ignore-xdg     # A+ draft: also ignore XDG_*
#
# Both modes are idempotent and keep a .bak. --ignore-xdg is a DRAFT and is
# OFF by default — enabling it is a release decision, not a build decision.
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
# MEASURED (task-26, .omo/evidence/a2-v1-effect-rebuild/task-26-xdg-boundary.txt):
# baking `app` fixes the SUFFIX but NOT the ROOT. xdg-basedir@5.1.0 reads env
# unconditionally (index.js:7-16), so a decoy XDG_DATA_HOME still re-roots the
# binary in both modes. That is PARITY with the live wrapper, which uses the
# same `${XDG_DATA_HOME:-$HOME/.local/share}/opencode1` form — NOT a regression,
# but also NOT "env immunity". --ignore-xdg is the only variant that closes it.
#
# Run BEFORE build-v1.sh. Not applied by any packaging script yet — the
# single-ELF packaging change is deliberately staged behind the assertions in
# docs/single-elf-v1.md §5.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-1.18.32}"
NAMESPACE="${OPENCODE1_NAMESPACE:-opencode1}"
GLOBAL_TS="$V1_SRC/packages/core/src/global.ts"

IGNORE_XDG=0
for arg in "$@"; do
	case "$arg" in
	--ignore-xdg) IGNORE_XDG=1 ;;
	-h | --help)
		sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "ERR: unknown argument '$arg' (expected --ignore-xdg)" >&2
		exit 2
		;;
	esac
done

# --- exact source lines we assert on (upstream 1.18.32 layout) ---------------
ORIG_IMPORT='import { xdgData, xdgCache, xdgConfig, xdgState } from "xdg-basedir"'
ORIG_LINE='const app = "opencode"'
ORIG_DERIV_DATA='const data = path.join(xdgData!, app)'
ORIG_DERIV_CACHE='const cache = path.join(xdgCache!, app)'
ORIG_DERIV_CONFIG='const config = path.join(xdgConfig!, app)'
ORIG_DERIV_STATE='const state = path.join(xdgState!, app)'

# --- patched forms ------------------------------------------------------------
MARKER="// single-elf-patch: namespace=$NAMESPACE ignore-xdg=$IGNORE_XDG"
BAK="$GLOBAL_TS.single-elf.bak"
PATCHED_LINE="const app = \"$NAMESPACE/opencode\""

[[ -f "$GLOBAL_TS" ]] || {
	echo "ERR: $GLOBAL_TS missing — set V1_SRC" >&2
	exit 1
}

if grep -qxF "$MARKER" "$GLOBAL_TS"; then
	echo "OK (already patched): mode=$([ "$IGNORE_XDG" -eq 1 ] && echo '--ignore-xdg' || echo default) namespace='$NAMESPACE'"
	exit 0
fi

# Namespace bake is common to both modes.
EDITS=("$ORIG_LINE|$PATCHED_LINE")

if [ "$IGNORE_XDG" -eq 1 ]; then
	# Drop the xdg-basedir import and re-derive the four roots from HOME only.
	# The `!` assertions go away with the nullable xdg* exports, so the values
	# are plain strings — Global.Path's declared types (data: string) still hold.
	#
	# `home` takes over the import line's slot (L3). ESM hoists imports, so `os`
	# is already bound there; verified executable under bun. Keeping it in L3
	# rather than L11 means each root keeps its own source slot and the edit
	# list stays strictly 1:1, so the "exactly 1 hit" guard stays meaningful.
	#
	# TMPDIR is deliberately NOT neutralized: global.ts:15 already uses
	# os.tmpdir(), which is the XDG-independent knob, and overriding it would
	# change behavior beyond the stated scope. See docs/single-elf-v1.md §9.
	EDITS=(
		"$ORIG_LINE|$PATCHED_LINE"
		"$ORIG_IMPORT|const home = process.env.HOME ?? os.homedir()"
		"$ORIG_DERIV_DATA|const data = path.join(home, '.local', 'share', app)"
		"$ORIG_DERIV_CACHE|const cache = path.join(home, '.cache', app)"
		"$ORIG_DERIV_CONFIG|const config = path.join(home, '.config', app)"
		"$ORIG_DERIV_STATE|const state = path.join(home, '.local', 'state', app)"
	)
fi

for pair in "${EDITS[@]}"; do
	orig="${pair%%|*}"
	grep -qxF "$orig" "$GLOBAL_TS" || {
		echo "ERR: global.ts does not carry the expected line:" >&2
		echo "     $orig" >&2
		echo "     Upstream layout changed — re-derive the injection point before patching." >&2
		exit 1
	}
done

[[ -f "$BAK" ]] || cp -p "$GLOBAL_TS" "$BAK"

python3 - "$GLOBAL_TS" "$MARKER" "${EDITS[@]}" <<'PY'
import io, sys
path, marker = sys.argv[1], sys.argv[2]
edits = [tuple(a.split("|", 1)) for a in sys.argv[3:]]
with io.open(path, encoding="utf-8") as fh:
    lines = fh.readlines()
for orig, patched in edits:
    hits = [i for i, l in enumerate(lines) if l.rstrip("\n") == orig]
    if len(hits) != 1:
        sys.exit("ERR: expected exactly 1 %r line, found %d" % (orig, len(hits)))
    lines[hits[0]] = patched + "\n"
# Standalone marker on its own line, so idempotency never has to infer intent
# from the patched text itself. Anchor it to the `app` literal.
app_idx = [i for i, l in enumerate(lines) if l.startswith("const app = ")]
if len(app_idx) != 1:
    sys.exit("ERR: cannot anchor marker, found %d `const app` lines" % len(app_idx))
if marker not in [l.rstrip("\n") for l in lines]:
    lines.insert(app_idx[0], marker + "\n")
with io.open(path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
print("patched %d lines" % len(edits))
PY

# Post-verify: every replacement landed, and no upstream import survives.
for pair in "${EDITS[@]}"; do
	patched="${pair#*|}"
	grep -qxF "$patched" "$GLOBAL_TS" || {
		echo "ERR: post-patch verify failed for: $patched" >&2
		exit 1
	}
done
if [ "$IGNORE_XDG" -eq 1 ] && grep -q 'from "xdg-basedir"' "$GLOBAL_TS"; then
	echo "ERR: xdg-basedir import survived --ignore-xdg patch" >&2
	exit 1
fi

echo "OK: namespace '$NAMESPACE' baked into ${GLOBAL_TS#$V1_SRC/} (backup: ${BAK##*/})"
[ "$IGNORE_XDG" -eq 1 ] && echo "OK: --ignore-xdg applied — roots derive from \$HOME only, XDG_*_HOME no longer consumed"
echo "NOTE: rebuild the runtime before packaging; assertions A1-A11 live in docs/single-elf-v1.md §5"
echo "NOTE: packages/core/test/global.test.ts:9 asserts tmp == os.tmpdir()/opencode — update it before rebuilding"
