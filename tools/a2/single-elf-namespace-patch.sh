#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# single-elf-namespace-patch.sh — bake the opencode1 isolation namespace into
# the v1 runtime at build time, so bin/opencode1 can be the payload itself and
# the bash launcher (scripts/opencode1-launcher.sh) becomes unnecessary.
#
# Single-ELF namespace bake. XDG-ignoring (A+) is the DEFAULT for the v1 line.
#
#   ./tools/a2/single-elf-namespace-patch.sh                  # DEFAULT: namespace + ignore XDG_*
#   ./tools/a2/single-elf-namespace-patch.sh --no-ignore-xdg  # escape hatch: namespace only
#
# Both modes are idempotent and keep a .bak.
#
# WHY --ignore-xdg is now the default (was a draft, OFF as of b567e1a):
#   v1 on this device is not a general-purpose CLI — it is the OLD-environment
#   compatibility line, coexisting with v2 and reachable from any container or
#   shell that exports XDG_*_HOME. Multi-container XDG leakage is precisely the
#   hazard that line exists to prevent: a stray XDG_DATA_HOME in the caller's
#   env re-roots the whole runtime (MEASURED, task-26) and silently writes v1
#   state into another generation's tree. Structural isolation is worth more
#   here than XDG standard semantics, so we trade the latter for the former.
#   The cost is honest and bounded: a user who deliberately redirects v1's
#   data/cache/config/state via XDG_* gets those settings ignored. Users who
#   want the old env-driven behavior have --no-ignore-xdg.
#   TMPDIR is NOT part of this trade: os.tmpdir() still honors it, unchanged.
#   See docs/single-elf-v1.md §5 (A11) and §9.3/§9.4.
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
# binary in namespace-only mode. That is PARITY with the live wrapper, which
# uses the same `${XDG_DATA_HOME:-$HOME/.local/share}/opencode1` form — NOT a
# regression, but also NOT "env immunity". Hence A+/--ignore-xdg is now the
# default: it is the only variant that actually closes the root.
#
# Run BEFORE build-v1.sh. Not applied by any packaging script yet — the
# single-ELF packaging change is deliberately staged behind the assertions in
# docs/single-elf-v1.md §5.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-1.18.32}"
NAMESPACE="${OPENCODE1_NAMESPACE:-opencode1}"
GLOBAL_TS="$V1_SRC/packages/core/src/global.ts"
TEST_TS="$V1_SRC/packages/core/test/global.test.ts"
PRELOAD_TS="$V1_SRC/packages/opencode/test/preload.ts"

IGNORE_XDG=1
for arg in "$@"; do
	case "$arg" in
	--ignore-xdg) IGNORE_XDG=1 ;;
	--no-ignore-xdg) IGNORE_XDG=0 ;;
	-h | --help)
		sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "ERR: unknown argument '$arg' (expected --no-ignore-xdg)" >&2
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

# Already patched? Only short-circuit when the TEST files carry their marker
# too — otherwise a run that died between the two steps would leave the test
# assertions unfixed and every later re-run would skip straight past them.
TEST_MARKER="// single-elf-patch: namespace=$NAMESPACE ignore-xdg=$IGNORE_XDG tests"
if grep -qxF "$MARKER" "$GLOBAL_TS" &&
	grep -qxF "$TEST_MARKER" "$TEST_TS" &&
	{ [ "$IGNORE_XDG" -eq 0 ] || grep -qxF "$TEST_MARKER" "$PRELOAD_TS"; }; then
	echo "OK (already patched): mode=$([ "$IGNORE_XDG" -eq 1 ] && echo 'A+ / ignore-xdg (default)' || echo '--no-ignore-xdg') namespace='$NAMESPACE'"
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

# Phase-scoped idempotency: the global.ts edit runs only when its marker is
# absent. Independent of the test phase below, so a run interrupted between the
# two phases repairs itself on the next invocation instead of hard-failing on
# "expected line not found" against an already-patched file.
if grep -qxF "$MARKER" "$GLOBAL_TS"; then
	echo "    global.ts already patched (marker present) — skipping edit phase"
else
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
print("    patched %d line(s) in global.ts" % len(edits))
PY
fi

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

# --- test-side fixes (same patch, same trip) ---------------------------------
# Two test files encode assumptions the bake invalidates. Both are patched here
# rather than by hand because $V1_SRC can be re-extracted at any time; a manual
# edit would silently vanish on the next clean build.
#
# 1. packages/core/test/global.test.ts:9
#      expect(Global.Path.tmp).toBe(path.join(os.tmpdir(), "opencode"))
#    tmp = path.join(os.tmpdir(), app) and app is now "opencode1/opencode", so
#    the expectation must be join(os.tmpdir(), "opencode1/opencode"). Both `os`
#    and `path` stay used, so no import churn.
#
# 2. packages/opencode/test/preload.ts
#    The preload isolates the suite by exporting XDG_*_HOME at import time
#    (its own header comment says so). Under A+ those exports are no longer
#    read, so TWO things must change or the suite writes into the real $HOME:
#      - :34-37  XDG exports become inert; keep them (harmless, and they still
#                serve any unpatched consumer) but ADD a HOME export so the
#                patched `home` derivation lands in the same sandbox.
#      - :53     the cache version file (written to stop global/index.ts from
#                clearing the cache) moves from XDG_CACHE_HOME/opencode to
#                $HOME/.cache/opencode1/opencode — miss it and the suite
#                silently re-clears the global cache on every run.
#    This is a test-harness concern only; it does not affect the shipped
#    artifact, but it is a real-home-write hazard, so it is fixed here.
TEST_EDITS=(
	'expect(Global.Path.tmp).toBe(path.join(os.tmpdir(), "opencode"))|expect(Global.Path.tmp).toBe(path.join(os.tmpdir(), "'"$NAMESPACE"'/opencode"))'
)

patch_test_file() {
	local f="$1" marker="$2"
	shift 2
	local -a edits=("$@")
	local -a todo=()
	local pair orig patched

	[[ -f "$f" ]] || {
		echo "ERR: $f missing — cannot fix its assertions" >&2
		exit 1
	}
	if grep -qxF "$marker" "$f"; then
		echo "    test skip (already patched): ${f#$V1_SRC/}"
		return 0
	fi
	for pair in "${edits[@]}"; do
		orig="${pair%%|*}"
		patched="${pair#*|}"
		if grep -qF "$patched" "$f"; then
			continue # already in patched shape (no-op edit)
		fi
		grep -qF "$orig" "$f" || {
			echo "ERR: $f does not carry the expected text:" >&2
			echo "     $orig" >&2
			echo "     Upstream layout changed — re-derive before patching." >&2
			exit 1
		}
		todo+=("$pair")
	done
	if [ ${#todo[@]} -eq 0 ]; then
		echo "    test skip (no-op edits needed): ${f#$V1_SRC/}"
		return 0
	fi

	[[ -f "$f.single-elf.bak" ]] || cp -p "$f" "$f.single-elf.bak"
	python3 - "$f" "$marker" "${todo[@]}" <<'PY'
import io, sys
path, marker = sys.argv[1], sys.argv[2]
edits = [tuple(a.split("|", 1)) for a in sys.argv[3:]]
with io.open(path, encoding="utf-8") as fh:
    lines = fh.readlines()
for orig, patched in edits:
    hits = [i for i, l in enumerate(lines) if orig in l]
    if len(hits) != 1:
        sys.exit("ERR: expected exactly 1 line containing %r, found %d" % (orig, len(hits)))
    # In-place substring replace preserves the line's leading indentation,
    # which a whole-line assignment would drop.
    lines[hits[0]] = lines[hits[0]].replace(orig, patched, 1)
if marker not in [l.rstrip("\n") for l in lines]:
    lines.insert(0, marker + "\n")
with io.open(path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
print("    patched %d line(s) in %s" % (len(edits), path.rsplit("/", 1)[-1]))
PY
	for pair in "${todo[@]}"; do
		patched="${pair#*|}"
		grep -qF "$patched" "$f" || {
			echo "ERR: post-patch verify failed in $f for: $patched" >&2
			exit 1
		}
	done
}

TEST_MARKER="// single-elf-patch: namespace=$NAMESPACE ignore-xdg=$IGNORE_XDG tests"
patch_test_file "$TEST_TS" "$TEST_MARKER" "${TEST_EDITS[@]}"
if [ "$IGNORE_XDG" -eq 1 ]; then
	# :53 moves the cache version file (written to stop global/index.ts from
	# clearing the cache) from XDG_CACHE_HOME/opencode to the HOME-derived
	# location; miss it and the suite silently re-clears the global cache.
	# :46 additionally exports HOME (same line, chained assignment) so the
	# patched `home` derivation resolves into the same sandbox. Both run
	# before the first src/ import at :90, which is what makes them effective.
	patch_test_file "$PRELOAD_TS" "$TEST_MARKER" \
		'const cacheDir = path.join(dir, "cache", "opencode")|const cacheDir = path.join(dir, "home", ".cache", "'"$NAMESPACE"'", "opencode")' \
		'process.env["OPENCODE_TEST_HOME"] = testHome|process.env["HOME"] = process.env["OPENCODE_TEST_HOME"] = testHome'
fi

echo "OK: namespace '$NAMESPACE' baked into ${GLOBAL_TS#$V1_SRC/} (backup: ${BAK##*/})"
if [ "$IGNORE_XDG" -eq 1 ]; then
	echo "OK: A+ applied (DEFAULT) — roots derive from \$HOME only, XDG_*_HOME no longer consumed"
	echo "OK: test assertions realigned (${TEST_TS#$V1_SRC/}, ${PRELOAD_TS#$V1_SRC/})"
	echo "BEHAVIOR CHANGE: tmp root is now os.tmpdir()/$NAMESPACE/opencode (was os.tmpdir()/opencode) — cross-generation tmp sharing is closed; TMPDIR itself still honored"
else
	echo "OK: --no-ignore-xdg escape hatch — namespace baked, XDG_*_HOME still consumed (parity with the live wrapper)"
fi
echo "NOTE: rebuild the runtime before packaging; assertions A1-A11 live in docs/single-elf-v1.md §5"
