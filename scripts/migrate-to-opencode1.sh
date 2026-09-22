#!/usr/bin/env bash
# migrate-to-opencode1.sh — v1 (opencode) → opencode1 data migration helper
#
# The opencode1* packages are mutually exclusive with v2 `opencode` packages
# (Breaks/Conflicts/Replaces). This script handles the DATA side of the rename:
#   backup   timestamped tarball of v1 data/config/cache/state
#   isolate  move v1 data dirs into opencode1-named dirs (coexistence layout)
#   restore  restore the newest (or given) backup
#   status   show which dirs exist and which mode fits your install
#
# Layout after `isolate` (per docs/migration-v1-to-v2.md + MIGRATION-EXPERIENCE):
#   ~/.config/opencode   → ~/.config/opencode1
#   ~/.local/share/opencode → ~/.local/share/opencode1
#   ~/.cache/opencode    → ~/.cache/opencode1
#   ~/.local/state/opencode → ~/.local/state/opencode1   (if present)
#
# Plugins that hardcode ~/.config/opencode (e.g. autopilot, opencode-acp,
# browser) are NOT rewritten here; `isolate` prints the patch checklist.

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

dst_occupied() {
  local d
  for d in "$CFG1" "$DATA1" "$CACHE1" "$STATE1"; do
    [ -e "$d" ] && { note "destination already exists: $d"; return 0; }
  done
  return 1
}

cmd_status() {
  local d
  for d in "$CFG" "$CFG1" "$DATA" "$DATA1" "$CACHE" "$CACHE1" "$STATE" "$STATE1"; do
    if [ -e "$d" ]; then
      printf '  [x] %s  (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else
      printf '  [ ] %s\n' "$d"
    fi
  done
  if pkg list-installed 2>/dev/null | grep -qE '^opencode1'; then
    note "opencode1* package installed"
  elif pkg list-installed 2>/dev/null | grep -qE '^opencode/'; then
    note "old opencode (v1) package installed — run: $0 backup && $0 isolate after installing opencode1*"
  fi
  if pkg list-installed 2>/dev/null | grep -qE '^opencode/'; then
    ver="$(pkg show opencode 2>/dev/null | sed -n 's/^Version: //p' | head -1)"
    case "$ver" in
      1.*) note "installed opencode $ver is a v1 build (package will be renamed opencode1*)" ;;
      2.*) note "installed opencode $ver is v2 — v1 data migration only needed for old sessions" ;;
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

cmd_isolate() {
  have_src || die "no v1 data dirs to isolate"
  if dst_occupied; then
    die "opencode1 data dirs already present — refusing to overwrite (restore or move them aside first)"
  fi
  local src dst moved=0
  for src in "$CFG" "$DATA" "$CACHE" "$STATE"; do
    [ -e "$src" ] || continue
    dst="${src}1"
    mv "$src" "$dst"
    note "moved $src -> $dst"
    moved=$((moved + 1))
  done
  [ "$moved" -gt 0 ] || die "nothing moved"
  cat <<'CHECKLIST'

── plugin path patch checklist (manual, idempotent) ──
These plugins are known to hardcode ~/.config/opencode; after `isolate`
verify each and re-run after plugin updates:
  - autopilot        (13 path references)
  - opencode-acp
  - browser plugin
Verify with live fds, not declarations:  ls -l /proc/$(pgrep -n opencode)/fd
Full playbook: MIGRATION-EXPERIENCE.md on the maintenance host / docs/migration-v1-to-v2.md
Re-run this script any time; it refuses to clobber existing opencode1 dirs.
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
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

main() {
  case "${1:-}" in
    backup)  cmd_backup ;;
    isolate) cmd_isolate ;;
    restore) cmd_restore "${2:-}" ;;
    status)  cmd_status ;;
    -h|--help|help) usage 0 ;;
    *) usage 1 ;;
  esac
}

main "$@"
