#!/data/data/com.termux/files/usr/bin/bash
# probe-latest-opencode.sh — detect upstream opencode drift against the local pin table.
#
# Why /tags and not /releases: upstream publishes GitHub *Releases* for the v1
# line only; v2 tags (v2.0.18 … v2.1.x) exist as tags and never as releases.
# A release-only probe reports a stale v1 forever and silently misses every v2
# bump (docs-reorg-maint E4).
#
# Modes:
#   --check        (default) print the table; exit 1 on drift, 0 in sync, 2 probe error
#   --dry-run      like --check, plus print the issue that WOULD be created
#   --create-issue create a tracking issue on drift (dedupe by open-issue title)
#   --offline      no network; print local pins only; exit 0
#
# Exit codes: 0 sync/created/offline · 1 drift (check/dry-run) · 2 probe failure

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_SCRIPT="$REPO_ROOT/scripts/build-bionic.sh"
UPSTREAM="sst/opencode"
MODE="${1:---check}"
ISSUE_TITLE_MARK="upstream opencode drift detected"

usage() {
  sed -n '1,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}
case "$MODE" in
  --check|--dry-run|--create-issue|--offline) ;;
  -h|--help) usage ;;
  *) echo "unknown mode: $MODE (use --check|--dry-run|--create-issue|--offline)" >&2; exit 2 ;;
esac

die() { echo "probe: ERROR: $*" >&2; exit 2; }

# --- local pins -------------------------------------------------------------
# Parsed (not sourced) so probing never triggers a build.
read_local() {
  python3 - "$PIN_SCRIPT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

pty = re.search(r'PTY_VER="\$\{PTY_VER:-([^}]+)\}"', src)
if not pty:
    sys.exit("probe: PTY_VER default not found in pin script")
print("LOCAL_PTY=%r" % pty.group(1))

m = re.search(r'case "\$VER" in\n(.*?)\nesac', src, re.S)
if not m:
    sys.exit("probe: VER case table not found in pin script")
entries, fallback = {}, None
for line in m.group(1).splitlines():
    hit = re.match(r'\s*([^)]+)\)\s*OPENTUI_VER="\$\{OPENTUI_VER:-([^}]+)\}"', line)
    if not hit:
        continue
    pats, val = hit.group(1).strip(), hit.group(2)
    for p in pats.split('|'):
        p = p.strip()
        if p == '*':
            fallback = val
        else:
            entries[p] = val
if fallback is None:
    sys.exit("probe: no '*' fallback in VER case table")
print("LOCAL_FALLBACK=%r" % fallback)
for ver, val in entries.items():
    print("LOCAL_ENTRY_%s=%r" % (ver.replace('.', '_'), val))
PY
}

# --- upstream -----------------------------------------------------------------
TAGS_JSON() { gh api "repos/$UPSTREAM/tags?per_page=100" --paginate --jq '.[].name' 2>/dev/null; }
fetch_pkg() { # fetch_pkg <path> <ref>
  gh api "repos/$UPSTREAM/contents/$1?ref=$2" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

# --- output -------------------------------------------------------------------
print_table() { # <up_v2> <up_v1> <up_pty> <up_opentui> <local_pty> <local_entry> <local_fallback>
  printf '%-26s %s\n' "upstream latest v2:" "$1"
  printf '%-26s %s\n' "upstream latest v1:" "$2"
  printf '%-26s %s\n' "upstream pty:"       "$3"
  printf '%-26s %s\n' "upstream opentui:"   "$4 (at $1)"
  printf '%-26s %s\n' "local pty pin:"      "$5"
  if [[ "$6" == "NONE" ]]; then
    printf '%-26s %s\n' "local opentui ($1):" "NO ENTRY (falls back to $7)"
  else
    printf '%-26s %s\n' "local opentui ($1):" "$6"
  fi
}

write_issue_body() { # <file> <table> <reasons>
  {
    printf 'Upstream probe (%s) detected drift between `%s` and the local pin table.\n\n' "$(date -u +%Y-%m-%d)" "$UPSTREAM"
    printf '## Probe result\n\n```\n%s\n```\n\n' "$2"
    printf '## Drift\n\n'
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      printf -- '- %s\n' "$r"
    done <<EOF
$3
EOF
    printf '\n## Next step\n\n'
    printf '1. Update `scripts/build-bionic.sh` pin table (`PTY_VER` default and the `VER` case entry for the new tag).\n'
    printf '2. Read the values from the upstream tag itself (`packages/cli/package.json` for pty, root `package.json` -> `workspaces.catalog` for opentui) — never from this issue text, it goes stale.\n'
    printf '3. Watch for breaking bumps: a pty minor (0.2.x -> 0.3.x) or an opentui minor changes the store layout, and the pty splice / libopentui graft may need a matching change. Run the build on the new tag before releasing.\n'
    printf '\nThis issue is created by `.github/workflows/probe-upstream.yml`.\n'
  } >"$1"
}

# --- probe --------------------------------------------------------------------
if [[ "$MODE" == "--offline" ]]; then
  eval "$(read_local)"
  echo "offline: local pty=$LOCAL_PTY, fallback opentui=$LOCAL_FALLBACK"
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

tags="$(TAGS_JSON)" || die "cannot list upstream tags"
[[ -n "$tags" ]] || die "upstream tag list is empty"

UP_V2="$(printf '%s\n' "$tags" | grep -E '^v2\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
UP_V1="$(printf '%s\n' "$tags" | grep -E '^v1\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
[[ -n "$UP_V2" ]] || die "no v2 tag found upstream"
[[ -n "$UP_V1" ]] || UP_V1="(none)"

UP_PTY="$(fetch_pkg packages/cli/package.json "$UP_V2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dependencies",{}).get("@opencode-ai/pty",""))' 2>/dev/null)"
UP_OPENTUI="$(fetch_pkg package.json "$UP_V2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("workspaces",{}).get("catalog",{}).get("@opentui/core",""))' 2>/dev/null)"
[[ -n "$UP_PTY" && -n "$UP_OPENTUI" ]] || die "cannot read upstream pins at $UP_V2"

eval "$(read_local)" || die "cannot parse local pin table"
UP_VER="${UP_V2#v}"
ENTRY_VAR="LOCAL_ENTRY_$(printf '%s' "$UP_VER" | tr '.' '_')"
LOCAL_ENTRY="${!ENTRY_VAR:-NONE}"

TABLE="$(print_table "$UP_V2" "$UP_V1" "$UP_PTY" "$UP_OPENTUI" "$LOCAL_PTY" "$LOCAL_ENTRY" "$LOCAL_FALLBACK")"
echo "$TABLE"

reasons=""
if [[ "$UP_PTY" != "$LOCAL_PTY" ]]; then
  reasons+="pty pin: upstream $UP_PTY vs local $LOCAL_PTY"$'\n'
fi
if [[ "$LOCAL_ENTRY" == "NONE" ]]; then
  reasons+="pin table has no entry for $UP_VER (silently falls back to opentui $LOCAL_FALLBACK)"$'\n'
elif [[ "$LOCAL_ENTRY" != "$UP_OPENTUI" ]]; then
  reasons+="opentui pin for $UP_VER: upstream $UP_OPENTUI vs local $LOCAL_ENTRY"$'\n'
fi

if [[ -z "$reasons" ]]; then
  echo "RESULT: in sync with $UP_V2"
  exit 0
fi

echo "RESULT: DRIFT"
printf '%s' "$reasons" | sed 's/^/  - /'

case "$MODE" in
  --check)
    exit 1
    ;;
  --dry-run)
    ISSUE_FILE="$(mktemp)"
    write_issue_body "$ISSUE_FILE" "$TABLE" "$reasons"
    echo "--- issue that would be created ---"
    echo "TITLE: chore: $ISSUE_TITLE_MARK ($UP_V2)"
    cat "$ISSUE_FILE"
    rm -f "$ISSUE_FILE"
    exit 1
    ;;
  --create-issue)
    existing="$(gh issue list --state open --search "$ISSUE_TITLE_MARK in:title" --json number,title --jq '.[0].number // empty' 2>/dev/null)"
    if [[ -n "$existing" ]]; then
      echo "issue #$existing already open for this drift; not creating a duplicate"
      exit 0
    fi
    ISSUE_FILE="$(mktemp)"
    write_issue_body "$ISSUE_FILE" "$TABLE" "$reasons"
    gh issue create --title "chore: $ISSUE_TITLE_MARK ($UP_V2)" --body-file "$ISSUE_FILE" >/dev/null || { rm -f "$ISSUE_FILE"; die "gh issue create failed"; }
    rm -f "$ISSUE_FILE"
    echo "created tracking issue for $UP_V2"
    exit 0
    ;;
esac
