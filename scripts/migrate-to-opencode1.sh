#!/usr/bin/env bash
# migrate-to-opencode1.sh — v1 (opencode) → opencode1 data migration helper
#
# The opencode1* packages are mutually exclusive with v2 `opencode` packages
# (Breaks/Conflicts/Replaces). This script handles the DATA side of the rename:
#   backup   timestamped tarball of v1 data/config/cache/state
#   isolate  move/reshape data into the NESTED opencode1 layout + auto-patch plugins
#   patch    re-run only the plugin path patch (after plugin updates)
#   restore  restore the newest (or given) backup
#   status   show which dirs exist and which mode fits your install
#
# Layout after `isolate` (v12.1 nested — what the packaged launcher resolves):
#   The opencode1 launcher exports XDG_*_HOME=<root>/opencode1 and the v1
#   runtime appends its hardcoded `opencode/` segment itself, so it reads:
#     ~/.config/opencode        → ~/.config/opencode1/opencode
#     ~/.local/share/opencode   → ~/.local/share/opencode1/opencode
#     ~/.cache/opencode         → ~/.cache/opencode1/opencode
#     ~/.local/state/opencode   → ~/.local/state/opencode1/opencode
#   Flat <root>/opencode1 dirs left by the pre-v12.1 script are re-nested
#   automatically (idempotent). Plain <root>/opencode is moved ONLY when the
#   nested target is still empty AND no v2 opencode package is installed
#   (otherwise those dirs belong to live v2 — never steal them).
#
# Plugins hardcoding ~/.config/opencode are auto-patched (grep-discovery over
# the opencode1 config/cache trees — no hardcoded file list; re-run `patch`
# after plugin updates). Verify with live fds, not declarations.

set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

CFG1="${CFG}1"; DATA1="${DATA}1"; CACHE1="${CACHE}1"; STATE1="${STATE}1"
BACKUP_ROOT="${OPENCODE_MIGRATE_BACKUP:-$HOME/.local/share/opencode1-migrations}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

have_src() { [ -e "$CFG" ] || [ -e "$DATA" ] || [ -e "$CACHE" ] || [ -e "$STATE" ]; }

src_dirs() {
  local d
  for d in "$CFG" "$DATA" "$CACHE" "$STATE"; do
    [ -e "$d" ] && printf '%s\n' "$d"
  done
}

# Plain <root>/opencode is live v2 data when a v2 opencode package is installed.
# v2_installed => never move plain dirs (isolate still re-nests flat opencode1).
v2_installed() {
  if command -v pacman >/dev/null 2>&1; then
    pacman -Qi opencode 2>/dev/null | grep -qE '^Version[[:space:]]*:[[:space:]]*2\.'
  elif command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' opencode 2>/dev/null | grep -qE '^2\.'
  else
    return 1
  fi
}

cmd_status() {
  local d
  for d in "$CFG" "$CFG1" "$CFG1/opencode" "$DATA" "$DATA1" "$DATA1/opencode" \
           "$CACHE" "$CACHE1" "$STATE" "$STATE1"; do
    if [ -e "$d" ]; then
      printf '  [x] %s  (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else
      printf '  [ ] %s\n' "$d"
    fi
  done
  if pkg list-installed 2>/dev/null | grep -qE '^opencode1'; then
    note "opencode1* package installed"
  fi
  if pkg list-installed 2>/dev/null | grep -qE '^opencode/'; then
    ver="$(pkg show opencode 2>/dev/null | sed -n 's/^Version: //p' | head -1)"
    case "$ver" in
      1.*) note "installed opencode $ver is a v1 build (package will be renamed opencode1*)" ;;
      2.*) note "installed opencode $ver is v2 — plain dirs belong to v2, isolate will not move them" ;;
    esac
  fi
}

cmd_backup() {
  have_src || die "no v1 data dirs found under $CFG / $DATA / $CACHE / $STATE"
  mkdir -p "$BACKUP_ROOT"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_ROOT/v1-backup-$ts.tar.gz"
  # shellcheck disable=SC2046
  tar czf "$out" -C / --ignore-failed-read $(src_dirs | sed 's|^/||') 2>/dev/null \
    || tar czf "$out" -C / --ignore-failed-read $(src_dirs | sed 's|^/||')
  note "backup written: $out ($(du -sh "$out" | cut -f1))"
  echo "$out"
}

newest_backup() {
  ls -1t "$BACKUP_ROOT"/v1-backup-*.tar.gz 2>/dev/null | head -1 || true
}

# ── plugin auto-patch (grep-discovery) ──────────────────────────────────────
# Discovery: grep -rl over the opencode1 config/cache trees (where plugins
# live); NO hardcoded file list. Application: python rewrites the plain-root
# references to the nested layout, idempotent (already-nested never matches).
# Sessions/transcripts (DATA1) and locks (STATE1) are NOT scanned — history
# text must never be rewritten; their path PATTERNS are still patched inside
# the plugin files we do scan.
patch_plugins() {
  local scan=() r
  for r in "$CFG1" "$CACHE1"; do
    [ -d "$r" ] && scan+=("$r")
  done
  if [ "${#scan[@]}" -eq 0 ]; then
    note "plugin patch: no opencode1 config/cache tree yet (run isolate first)"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { note "plugin patch: python3 missing, skipped"; return 0; }
  local files
  files="$(grep -rl --include='*.js' --include='*.mjs' --include='*.cjs' \
              --include='*.ts' --include='*.json' \
              -e '.config/opencode' -e '.local/share/opencode' \
              -e '.cache/opencode' -e '.local/state/opencode' \
              -e "'.config', 'opencode'" -e "'.local/share', 'opencode'" \
              "${scan[@]}" 2>/dev/null || true)"
  if [ -z "$files" ]; then
    note "plugin patch: no plain-root references found (nothing to do)"
    return 0
  fi
  python3 - "$files" <<'PY' || return 1
import re, sys
files = [f for f in sys.argv[1].split('\n') if f]
RULES = [
    # slash form: .config/opencode -> .config/opencode1/opencode (skip if already nested)
    (re.compile(r'(?<![\w.])(\.config|\.local/share|\.cache|\.local/state)/opencode(?!1)'), r'\1/opencode1/opencode'),
    # path.join form: '.config', 'opencode' -> '.config', 'opencode1', 'opencode'
    (re.compile(r"(['\"])\.config\1\s*,\s*(['\"])opencode\2"), r"\1.config\1, \1opencode1\1, \2opencode\2"),
    (re.compile(r"(['\"])\.local/share\1\s*,\s*(['\"])opencode\2"), r"\1.local/share\1, \1opencode1\1, \2opencode\2"),
    (re.compile(r"(['\"])\.cache\1\s*,\s*(['\"])opencode\2"), r"\1.cache\1, \1opencode1\1, \2opencode\2"),
    (re.compile(r"(['\"])\.local/state\1\s*,\s*(['\"])opencode\2"), r"\1.local/state\1, \1opencode1\1, \2opencode\2"),
]
patched = 0
changed_files = []
for path in files:
    try:
        with open(path, 'r', encoding='utf-8', errors='strict') as f:
            src = f.read()
    except Exception:
        continue
    out, hits = src, 0
    for rx, rep in RULES:
        out, n = rx.subn(rep, out)
        hits += n
    if hits and out != src:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(out)
        patched += hits
        changed_files.append(path)
print(f"==> plugin patch: {patched} reference(s) in {len(changed_files)} file(s)")
for p in changed_files:
    print(f"    patched {p}")
PY
  # verification: nothing un-nested may remain (idempotency proof)
  local left
  left="$(grep -rl --include='*.js' --include='*.mjs' --include='*.cjs' \
            --include='*.ts' --include='*.json' \
            -e '.config/opencode' -e '.local/share/opencode' -e '.cache/opencode' \
            -e '.local/state/opencode' "${scan[@]}" 2>/dev/null \
          | xargs -r grep -lE '\.config/opencode([^1]|$)|\.local/share/opencode([^1]|$)' 2>/dev/null || true)"
  if [ -n "$left" ]; then
    echo "    WARN: plain-root refs remain in:" >&2
    echo "$left" | sed 's/^/      /' >&2
    return 1
  fi
  note "plugin patch verified: 0 un-nested references remain"
}

# The 1.18.32 binary embeds the plain ~/.config/opencode/autopilot.db path
# (XDG injection does not reach embedded literals — live-fd verified). Redirect
# the plain location to the nested copy so autopilot history stays one library:
# nested v1 history wins; a plain copy that accumulated activity while the old
# build kept opening it is preserved aside, never deleted.
link_autopilot_shims() {
  local plain="${CFG}/autopilot.db" nested="${CFG1}/opencode/autopilot.db"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  [ -e "$plain" ] || [ -h "$plain" ] || return 0
  [ -d "$CFG1/opencode" ] || return 0
  if [ -h "$plain" ]; then
    case "$(readlink "$plain" 2>/dev/null || true)" in
      "$nested") note "autopilot shim already in place"; return 0 ;;
      *) rm -f "$plain" ;;
    esac
  fi
  if [ -f "$nested" ]; then
    mv "$plain" "${plain}.pre-isolate-${ts}"
    note "plain autopilot.db preserved aside (.pre-isolate-${ts}; nested v1 history wins)"
  else
    mkdir -p "$CFG1/opencode"
    mv "$plain" "$nested"
    note "moved plain autopilot.db -> nested"
  fi
  local suf
  for suf in -wal -shm; do
    if [ -f "$plain$suf" ]; then
      mv "$plain$suf" "${plain}$suf.pre-isolate-${ts}"
      note "stale $suf preserved aside"
    fi
  done
  ln -s "$nested" "$plain"
  note "shim: $plain -> $nested"
}

cmd_isolate() {
  local moved=0 nested=0
  local root root1
  # 1) re-nest flat <root>/opencode1 (pre-v12.1 layout) — always safe: only
  #    opencode1's own data moves under its own root.
  for root in "$CFG" "$DATA" "$CACHE" "$STATE"; do
    root1="${root}1"
    [ -d "$root1" ] || continue
    [ -d "$root1/opencode" ] && continue
    shopt -s dotglob nullglob
    mkdir -p "$root1/opencode"
    local entry
    for entry in "$root1"/*; do
      [ "$(basename "$entry")" = "opencode" ] && continue
      mv "$entry" "$root1/opencode/"
      nested=$((nested + 1))
    done
    shopt -u dotglob nullglob
    note "re-nested flat $root1 -> $root1/opencode"
  done
  # 2) move plain <root>/opencode -> nested, only when target still empty
  if v2_installed && [ "${OPENCODE_MIGRATE_TAKE_PLAIN:-0}" != "1" ]; then
    note "v2 opencode package installed — plain dirs belong to live v2, not moving (set OPENCODE_MIGRATE_TAKE_PLAIN=1 to force)"
  else
    for root in "$CFG" "$DATA" "$CACHE" "$STATE"; do
      root1="${root}1"
      [ -e "$root" ] || continue
      [ -d "$root1/opencode" ] && continue
      mkdir -p "$root1"
      mv "$root" "$root1/opencode"
      note "moved $root -> $root1/opencode"
      moved=$((moved + 1))
    done
  fi
  # 3) auto-patch plugins (grep-discovery) whenever any nested root exists
  local have_nested=0 d
  for d in "$CFG1/opencode" "$DATA1/opencode" "$CACHE1/opencode" "$STATE1/opencode"; do
    [ -e "$d" ] && have_nested=1
  done
  local patched_ok=1
  if [ "$have_nested" = 1 ]; then
    link_autopilot_shims
    patch_plugins || patched_ok=0
  fi
  [ "$moved" -gt 0 ] || [ "$nested" -gt 0 ] || [ "$patched_ok" = 1 ] || \
    die "nothing to migrate"
  [ "$moved" -gt 0 ] || [ "$nested" -gt 0 ] || {
    # only patch ran and it changed something (or nothing left) — exit cleanly
    [ "$patched_ok" = 1 ] && return 0 || die "plugin patch reported warnings"
  }
  cat <<'CHECKLIST'

── opencode1 data isolation (v12.1 nested layout) ──
Runtime now reads <root>/opencode1/opencode (launcher XDG root + runtime suffix).
Plugins with hardcoded plain paths were auto-patched (grep-discovery over the
opencode1 config/cache trees). Re-run after every plugin update:
  migrate-to-opencode1.sh patch
Verify with live fds, not declarations:
  ls -l /proc/$(pgrep -n opencode1)/fd
Full playbook: MIGRATION-EXPERIENCE.md / docs/migration-v1-to-v2.md
This script is idempotent; it never clobbers the nested target.
CHECKLIST
}

cmd_restore() {
  local arc="${1:-$(newest_backup)}"
  [ -n "$arc" ] || die "no backup found in $BACKUP_ROOT (pass a tarball path)"
  [ -f "$arc" ] || die "backup not found: $arc"
  local d
  for d in "$CFG1" "$DATA1" "$CACHE1" "$STATE1"; do
    [ -e "$d" ] && die "refusing to restore over existing $d — move it aside first"
  done
  tar xzf "$arc" -C /
  note "restored $arc"
}

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

main() {
  case "${1:-}" in
    backup)  cmd_backup ;;
    isolate) cmd_isolate ;;
    patch)   patch_plugins ;;
    restore) cmd_restore "${2:-}" ;;
    status)  cmd_status ;;
    -h|--help|help) usage 0 ;;
    *) usage 1 ;;
  esac
}

main "$@"
