#!/data/data/com.termux/files/usr/bin/bash
# build-guards.sh — unit-testable guards for the v2 native build chain (B line).
#
# Sourced by scripts/build-bionic.sh. Every function is pure with respect to the
# repo: it reads the given paths, prints one actionable line on failure, and
# returns non-zero. Callers decide whether that is fatal.
#
# Why this file exists: the build used to swallow three failure classes
# (best-effort markers and "WARN ... continuing") so a broken store or a missing
# platform package silently produced an unusable binary. Guard logic lives here so
# it can be unit-tested without running a 25-minute compilation (E1a).

# is_store_populated <store>
# True when the bun store directory exists and has at least one entry.
is_store_populated() {
  local store="$1"
  [[ -d "$store" ]] || return 1
  [[ -n "$(find "$store" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

# require_pkg_installed <store> <src_dir> <pkg_name>
# Passes when <pkg_name>/package.json is found anywhere in the store, or in
# <src_dir>/node_modules. Store layout varies (platform-suffixed keys), hence
# the path search instead of an exact key.
require_pkg_installed() {
  local store="$1" src="$2" name="$3"
  if find "$store" -path "*/node_modules/$name/package.json" -type f -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ -f "$src/node_modules/$name/package.json" ]]; then
    return 0
  fi
  printf 'Error: mandatory platform package missing after install: %s\n' "$name" >&2
  return 1
}

# require_file <path> <what>
require_file() {
  local path="$1" what="$2"
  if [[ ! -f "$path" ]]; then
    printf 'Error: %s missing: %s\n' "$what" "$path" >&2
    return 1
  fi
}
