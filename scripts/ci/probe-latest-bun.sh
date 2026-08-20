#!/usr/bin/env bash
# probe-latest-bun.sh — Probe the latest official android Bun release.
#
# Modes:
#   (default)  dry-run: query GitHub API, compare against bun-bind.json,
#              print CHANGELOG hint + staged diff, do NOT write.
#   --offline  skip network; print "沿用 bun-bind.json" hint; exit 0.
#   --apply    probe, then write the new target into bun-bind.json (persist).
#
# Output always includes the current latest tag (or the bound target when
# offline) so CI/agents can assert on it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIND_JSON="$REPO_ROOT/tools/transplant/config/bun-bind.json"
API_URL="https://api.github.com/repos/oven-sh/bun/releases/latest"
ASSET_NAME="bun-linux-aarch64-android.zip"

MODE="${1:-dry-run}"

# --- helpers ---------------------------------------------------------------
die() { echo "probe-latest-bun: ERROR: $*" >&2; exit 1; }

read_target() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"])' "$BIND_JSON"
}

write_target() {
    local ver="$1"
    python3 - "$BIND_JSON" "$ver" <<'PY'
import json, sys
path, ver = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["target"] = ver
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
}

# --- offline ---------------------------------------------------------------
if [[ "$MODE" == "--offline" ]]; then
    target="$(read_target)"
    echo "沿用 bun-bind.json (offline): target=$target"
    echo "latest_tag=$target"
    exit 0
fi

# --- network probe ---------------------------------------------------------
echo "probe-latest-bun: querying $API_URL"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL --max-time 30 "$API_URL" -o "$tmp" 2>/dev/null; then
    die "GitHub API unreachable (network restricted?) — use --offline to skip"
fi

latest_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$tmp")"
latest_ver="${latest_tag#bun-v}"

# asset presence assertion: refuse to bind a release without the android zip
if ! python3 - "$tmp" "$ASSET_NAME" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
asset = sys.argv[2]
names = [a["name"] for a in data.get("assets", [])]
if asset not in names:
    sys.exit(1)
PY
then
    die "latest release $latest_tag does NOT contain $ASSET_NAME — do not bind"
fi

bound="$(read_target)"
echo "latest_tag=$latest_tag"
echo "latest_ver=$latest_ver"
echo "bound_target=$bound"

if [[ "$latest_ver" == "$bound" ]]; then
    echo "probe-latest-bun: already at latest ($bound) — no change"
    exit 0
fi

echo "CHANGELOG: official android Bun $bound -> $latest_ver (asset $ASSET_NAME present)"
echo "staged diff (not written):"
diff -u <(echo "$bound") <(echo "$latest_ver") || true

if [[ "$MODE" == "--apply" ]]; then
    write_target "$latest_ver"
    echo "applied: bun-bind.json target=$latest_ver"
fi
exit 0
