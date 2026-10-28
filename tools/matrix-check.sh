#!/data/data/com.termux/files/usr/bin/bash
# matrix-check.sh — validate build/matrix/pins.sh against the upstream tags.
#
# What it guarantees:
#   1. schema: every registered version resolves to 4 fields, its lib name is
#      either `tlsdesc`, `opentui-<ver>` or `missing`, and its FFI profile has a
#      non-empty symbol set.
#   2. drift: for each registered version, pty/opentui must equal the values in
#      the upstream tag (root package.json workspaces.catalog for opentui,
#      packages/cli/package.json dependencies for pty).
#   3. deliberate upgrades: a field may differ from upstream ONLY when
#      build/matrix/overrides.tsv carries `ver<TAB>field<TAB>value<TAB>reason`
#      whose value matches what the matrix declares. An override that is no
#      longer needed (matrix value == upstream) is itself an error, so stale
#      exceptions cannot pile up.
#
# Usage:
#   tools/matrix-check.sh                 # all registered versions
#   tools/matrix-check.sh 2.1.4 2.0.32    # subset
#   tools/matrix-check.sh --refresh       # ignore the tag cache
#
# Exit: 0 = every version OK; 1 = at least one drift/schema/override problem.
# Network failures are hard errors (never silently "skipped").

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/build-pins.sh"

UPSTREAM_REPO="${UPSTREAM_REPO:-sst/opencode}"
CACHE_DIR="${MATRIX_CACHE:-$HOME/.cache/matrix-check}"
OVERRIDES="$REPO_ROOT/build/matrix/overrides.tsv"
REFRESH=0
declare -a WANT=()

for arg in "$@"; do
	case "$arg" in
		--refresh) REFRESH=1 ;;
		-h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "Error: unknown flag $arg" >&2; exit 1 ;;
		*) WANT+=("$arg") ;;
	esac
done

mkdir -p "$CACHE_DIR"
problems=0
checked=0

field_from_upstream() { # ver field
	local ver="$1" field="$2" cache
	cache="$CACHE_DIR/$ver.json"
	if [[ "$REFRESH" = 1 || ! -s "$cache" ]]; then
		if ! gh api "repos/$UPSTREAM_REPO/contents/package.json?ref=v$ver" --jq '.content' 2>/dev/null |
			base64 -d > "$cache.$$" 2>/dev/null; then
			rm -f "$cache.$$"
			echo "Error: cannot read upstream tag v$ver (network or missing tag)" >&2
			return 2
		fi
		mv "$cache.$$" "$cache"
	fi
	python3 - "$cache" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(2)
cat = (d.get("workspaces") or {}).get("catalog") or {}
if field == "opentui":
    print(cat.get("@opentui/core", ""))
elif field == "effect":
    print(cat.get("effect", ""))
elif field == "pty":
    # v2 declares it in packages/cli; the root cache cannot answer this.
    print("")
else:
    print("")
PY
}

field_from_upstream_cli() { # ver -> pty version
	local ver="$1" cache
	cache="$CACHE_DIR/$ver.cli.json"
	if [[ "$REFRESH" = 1 || ! -s "$cache" ]]; then
		if ! gh api "repos/$UPSTREAM_REPO/contents/packages/cli/package.json?ref=v$ver" --jq '.content' 2>/dev/null |
			base64 -d > "$cache.$$" 2>/dev/null; then
			rm -f "$cache.$$"
			return 2
		fi
		mv "$cache.$$" "$cache"
	fi
	python3 - "$cache" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
print((d.get("dependencies") or {}).get("@opencode-ai/pty", ""))
PY
}

override_value() { # ver field
	[[ -f "$OVERRIDES" ]] || return 1
	awk -F'\t' -v v="$1" -v f="$2" '$1==v && $2==f {print $3; exit}' "$OVERRIDES"
}

override_reason() { # ver field
	awk -F'\t' -v v="$1" -v f="$2" '$1==v && $2==f {print $4; exit}' "$OVERRIDES"
}

check_version() {
	local ver="$1" row pty opentui lib ffi effect up_ot up_pty up_effect ov rc
	if ! row="$(matrix_pins_for "$ver")"; then
		echo "DRIFT  $ver: not registered in build/matrix/pins.sh"
		return 1
	fi
	read -r pty opentui lib ffi effect <<<"$row"

	# schema
	case "$lib" in
		tlsdesc|missing|opentui-*) ;;
		*) echo "SCHEMA $ver: bad lib field '$lib'"; return 1 ;;
	esac
	if ! matrix_ffi_syms "$ffi" >/dev/null; then
		echo "SCHEMA $ver: unknown ffi profile '$ffi'"
		return 1
	fi

	# upstream diff
	up_ot="$(field_from_upstream "$ver" opentui)" || { echo "NETERR $ver: upstream opentui unavailable"; return 1; }
	if [[ -z "$up_ot" ]]; then
		echo "MISSING $ver: upstream tag v$ver has no @opentui/core (tag missing?)"
		return 1
	fi

	rc=0
	if [[ "$up_ot" != "$opentui" ]]; then
		ov="$(override_value "$ver" opentui || true)"
		if [[ -n "$ov" && "$ov" = "$opentui" ]]; then
			echo "OK-OVERRIDE $ver opentui=$opentui (upstream $up_ot; $(override_reason "$ver" opentui))"
		else
			echo "DRIFT  $ver opentui: matrix=$opentui upstream=$up_ot"
			rc=1
		fi
	elif [[ -n "$(override_value "$ver" opentui || true)" ]]; then
		echo "STALE-OVERRIDE $ver opentui: override present but matrix already matches upstream"
		rc=1
	fi

	if up_pty="$(field_from_upstream_cli "$ver")" && [[ -n "$up_pty" ]]; then
		if [[ "$up_pty" != "$pty" ]]; then
			ov="$(override_value "$ver" pty || true)"
			if [[ -n "$ov" && "$ov" = "$pty" ]]; then
				echo "OK-OVERRIDE $ver pty=$pty (upstream $up_pty; $(override_reason "$ver" pty))"
			else
				echo "DRIFT  $ver pty: matrix=$pty upstream=$up_pty"
				rc=1
			fi
		elif [[ -n "$(override_value "$ver" pty || true)" ]]; then
			echo "STALE-OVERRIDE $ver pty: override present but matrix already matches upstream"
			rc=1
		fi
	fi

	case "$effect" in
		-|""|[0-9]*) ;;
		*) echo "SCHEMA $ver: bad effect field '$effect'"; return 1 ;;
	esac
	if [[ "$effect" != "-" && -n "$effect" ]]; then
		up_effect="$(field_from_upstream "$ver" effect)" || { echo "NETERR $ver: upstream effect unavailable"; return 1; }
		if [[ -n "$up_effect" && "$up_effect" != "$effect" ]]; then
			ov="$(override_value "$ver" effect || true)"
			if [[ -n "$ov" && "$ov" = "$effect" ]]; then
				echo "OK-OVERRIDE $ver effect=$effect (upstream $up_effect; $(override_reason "$ver" effect))"
			else
				echo "DRIFT  $ver effect: matrix=$effect upstream=$up_effect"
				rc=1
			fi
		elif [[ -n "$up_effect" && -n "$(override_value "$ver" effect || true)" ]]; then
			echo "STALE-OVERRIDE $ver effect: override present but matrix already matches upstream"
			rc=1
		fi
	fi

	[[ $rc -eq 0 ]] && echo "OK      $ver pty=$pty opentui=$opentui lib=$lib ffi=$ffi effect=$effect"
	return $rc
}

if [[ ${#WANT[@]} -gt 0 ]]; then
	VERSIONS=("${WANT[@]}")
else
	mapfile -t VERSIONS < <(matrix_versions)
fi

for ver in "${VERSIONS[@]}"; do
	checked=$((checked + 1))
	if ! check_version "$ver"; then
		problems=$((problems + 1))
	fi
done

echo "----"
echo "matrix-check: $checked version(s), $problems problem(s)"
[[ $problems -eq 0 ]] || exit 1
exit 0
