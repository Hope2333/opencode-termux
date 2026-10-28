#!/data/data/com.termux/files/usr/bin/bash
# upload-from-state.sh — upload packaged artifacts described by packing/build-state.json.
#
# Why: the batch uploader used to glob `packing/**` and re-upload everything with
# --clobber. That re-sends 70 MB files whose digest never changed, and it can
# upload a file that a later step replaced with a different build. The state
# file (written by scripts/build-hygiene.sh:write_build_state) records exactly
# what was built, with its sha256, so this tool uploads only that.
#
# Contract:
#   - reads  <state>/builds/<ver>:<variant>:<rel> -> {pac:{path,sha256}, deb:{...}}
#   - for each asset: if the release already has the same name AND the same
#     sha256 digest, SKIP; otherwise upload (with --clobber).
#   - --dry-run prints the decision for every asset and changes nothing.
#
# Usage:
#   tools/upload-from-state.sh --tag Push261026 [--state packing/build-state.json]
#                              [--repo Hope2333/opencode-termux] [--dry-run] [--only deb|pac]
#
# Exit: 0 = every considered asset was uploaded or already up to date;
#       1 = at least one upload failed / state file missing / bad args.

set -uo pipefail

TAG=""
STATE="packing/build-state.json"
REPO="${REPO_SLUG:-Hope2333/opencode-termux}"
DRY=0
ONLY=""

die() { echo "Error: $*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Usage: upload-from-state.sh --tag TAG [options]

  --tag TAG        release tag to upload into (required, never created here)
  --state PATH     build state file (default: packing/build-state.json)
  --repo SLUG      owner/repo (default: $REPO_SLUG or Hope2333/opencode-termux)
  --only deb|pac   restrict to one artifact kind
  --dry-run, -n    print decisions, upload nothing
  -h, --help       this text
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--tag) TAG="${2:-}"; shift 2 ;;
		--state) STATE="${2:-}"; shift 2 ;;
		--repo) REPO="${2:-}"; shift 2 ;;
		--only) ONLY="${2:-}"; shift 2 ;;
		--dry-run|-n) DRY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

[ -n "$TAG" ] || { usage >&2; die "--tag is required"; }
[ -f "$STATE" ] || die "state file not found: $STATE"
case "$ONLY" in ""|deb|pac) ;; *) die "--only must be deb or pac" ;; esac

# asset list: name <TAB> path <TAB> sha256
ASSETS="$(python3 - "$STATE" "$ONLY" <<'PY'
import json, os, sys
state_p, only = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(state_p))
except Exception as exc:
    print("Error: cannot parse %s: %s" % (state_p, exc), file=sys.stderr)
    sys.exit(1)
builds = data.get("builds") or {}
if not builds:
    print("Error: %s has no builds" % state_p, file=sys.stderr)
    sys.exit(1)
rows = []
for key in sorted(builds):
    entry = builds[key] or {}
    for kind in ("deb", "pac"):
        if only and kind != only:
            continue
        item = entry.get(kind)
        if not item:
            continue
        path, sha = item.get("path"), item.get("sha256")
        if not path or not sha:
            continue
        if not os.path.exists(path):
            print("WARN: %s: %s missing on disk, skipped" % (key, path), file=sys.stderr)
            continue
        rows.append((os.path.basename(path), path, sha))
if not rows:
    print("Error: no uploadable assets in %s" % state_p, file=sys.stderr)
    sys.exit(1)
for name, path, sha in rows:
    sys.stdout.write("%s\t%s\t%s\n" % (name, path, sha))
PY
)" || exit 1

# existing release assets: name <TAB> digest (sha256:...)
# Capture directly — never write through /tmp (not writable on this host).
EXISTING="$(gh release view "$TAG" --repo "$REPO" --json assets \
	--jq '.assets[] | .name + "\t" + (.digest // "")' 2>/dev/null || true)"

have_digest() { # name
	printf '%s\n' "$EXISTING" | awk -F'\t' -v n="$1" '$1==n {print $2; exit}'
}

up=0 skip=0 fail=0
while IFS=$'\t' read -r name path sha; do
	[ -n "$name" ] || continue
	want="sha256:$sha"
	cur="$(have_digest "$name")"
	if [ "$cur" = "$want" ]; then
		echo "SKIP   $name (digest match)"
		skip=$((skip + 1))
		continue
	fi
	if [ "$DRY" = 1 ]; then
		if [ -n "$cur" ]; then
			echo "UPLOAD $name (digest differs: ${cur} -> $want) [dry-run]"
		else
			echo "UPLOAD $name (not on release) [dry-run]"
		fi
		up=$((up + 1))
		continue
	fi
	echo "UPLOAD $name ($path)"
	if gh release upload "$TAG" "$path" --repo "$REPO" --clobber; then
		up=$((up + 1))
	else
		echo "FAILED $name" >&2
		fail=$((fail + 1))
	fi
done <<<"$ASSETS"

echo "----"
echo "uploaded-or-would: $up  skipped(up-to-date): $skip  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
