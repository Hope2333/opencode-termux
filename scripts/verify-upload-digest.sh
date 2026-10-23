#!/data/data/com.termux/files/usr/bin/bash
# verify-upload-digest.sh — compare a local SHA256SUMS manifest against the
# assets actually present on a GitHub release (name + size + digest).
#
# Usage: verify-upload-digest.sh <TAG> [MANIFEST] [REPO]
#   MANIFEST defaults to $TMPDIR/oc-release-<TAG>/SHA256SUMS.txt when present.
#   No manifest → prints SKIP and exits 0 (best-effort hook after uploads).
#
# Exit: 0 all OK (or skipped) · 1 any MISS/SIZE_MISMATCH/SHA_MISMATCH · 2 usage/API error
# Migrated out of .omo/evidence (docs-reorg-maint E5): session evidence is not a tool.

set -uo pipefail

TAG="${1:-}"
MANIFEST="${2:-}"
REPO="${3:-Hope2333/opencode-termux}"
[[ -n "$TAG" ]] || { echo "usage: verify-upload-digest.sh <TAG> [manifest] [repo]" >&2; exit 2; }

if [[ -z "$MANIFEST" ]]; then
  for cand in "${TMPDIR:-$HOME/tmp}/oc-release-$TAG/SHA256SUMS.txt" "$HOME/tmp/oc-release-$TAG/SHA256SUMS.txt"; do
    [[ -f "$cand" ]] && { MANIFEST="$cand"; break; }
  done
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "SKIP: no local manifest for $TAG (pass MANIFEST=/path/SHA256SUMS.txt)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REL="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.id' 2>/dev/null)"
[[ -n "$REL" ]] || { echo "Error: cannot resolve release $TAG in $REPO" >&2; exit 2; }

: >"$TMP/assets.tsv"
page=1
while :; do
  body="$(gh api "repos/$REPO/releases/$REL/assets?per_page=100&page=$page" 2>/dev/null)" || { echo "Error: assets API failed (page $page)" >&2; exit 2; }
  n="$(printf '%s' "$body" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  printf '%s' "$body" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    print("\t".join([a.get("name",""), str(a.get("size",-1)), a.get("digest") or ""]))
' >>"$TMP/assets.tsv"
  [[ "$n" -lt 100 ]] && break
  page=$((page+1)); [[ $page -gt 10 ]] && break
done

python3 - "$MANIFEST" "$TMP/assets.tsv" <<'PY'
import os, sys

manifest, assets_tsv = sys.argv[1], sys.argv[2]
amap = {}
for line in open(assets_tsv):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3:
        amap[parts[0]] = {"size": int(parts[1]), "digest": parts[2]}

ok = bad = 0
lines = ["=== UPLOAD DIGEST VERIFY ==="]
for line in open(manifest):
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    sha, path = parts[0], parts[1].strip().lstrip("*")
    name = os.path.basename(path)
    try:
        size = os.path.getsize(path)
    except OSError:
        lines.append(f"MISS_LOCAL {name}"); bad += 1; continue
    a = amap.get(name)
    if not a:
        lines.append(f"MISS_REMOTE {name}"); bad += 1; continue
    if a["size"] != size:
        lines.append(f"SIZE_MISMATCH {name} local={size} remote={a['size']}"); bad += 1; continue
    d = a["digest"]
    if d.startswith("sha256:"):
        if d[7:] == sha:
            lines.append(f"OK {name} size+sha"); ok += 1
        else:
            lines.append(f"SHA_MISMATCH {name}"); bad += 1
    else:
        lines.append(f"OK {name} size(digest=NA)"); ok += 1

lines.append(f"VERIFY_OK={ok} VERIFY_BAD={bad}")
print("\n".join(lines))
sys.exit(0 if bad == 0 and ok > 0 else 1)
PY
