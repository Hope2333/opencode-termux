#!/usr/bin/env bash
# napi-android.sh — restore android-arm64 optional native bindings.
#
# WHY
#   The B-line build deliberately runs `bun install --os=linux --cpu=arm64` for
#   the glibc platform packages (pty / watcher / opentui). Bun re-resolves the
#   WHOLE tree on any `bun install <pkg>` and therefore prunes every
#   android-only optionalDependency on the way. Native JS tooling that ships
#   per-platform `.node` binaries then dies at load time:
#       Cannot find native binding      (@tailwindcss/oxide)
#       Cannot find module 'lightningcss-android-arm64'
#       Cannot find module '@rolldown/binding-android-arm64'   (vite 8)
#   For v2.2.2+ that aborts the web-ui dist pre-build, which aborts the build
#   (same failure class as #22 / #42: a silent-ish dependency gap shipping a
#   broken artifact).
#
# WHAT
#   Parse bun.lock for entries tagged `{ "os": "android", "cpu": "arm64" }`,
#   fetch those exact tarballs straight from the npm registry (no dependency
#   resolution, so neither a slow resolver nor a stale lock can block us) and
#   unpack them into $NM/<pkg>. Node-style upward resolution walks out of any
#   nested bun-store package up to the project `node_modules`, so one copy at
#   the root satisfies every nested store instance.
#
#   Idempotent: already-present packages are skipped, tarballs are cached in
#   $cache so a re-build does not re-download, and only missing/partial files
#   are fetched. Failures are warnings — the caller's artifact gate stays the
#   real judge.

# napi_android_entries <bun.lock>  →  "<name>\t<version>" lines (deduped)
napi_android_entries() {
  python3 - "$1" <<'PY'
import re, sys

pat = re.compile(
    r'\s*"([^"]+)": \["([^"]+)", "", \{ "os": "android", "cpu": "arm64" \}'
)
seen = set()
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        m = pat.match(line)
        if not m:
            continue
        name, _, ver = m.group(2).rpartition("@")
        if not name or not ver or (name, ver) in seen:
            continue
        seen.add((name, ver))
        print(f"{name}\t{ver}")
PY
}

# ensure_napi_android <bun.lock> <node_modules_dir> [cache_dir] [parallel]
ensure_napi_android() {
  local lock="$1" nm="$2" cache="${3:-}" parallel="${4:-3}"
  [[ -f "$lock" && -d "$nm" ]] || return 0
  [[ -n "$cache" ]] || cache="$nm/.napi-android-cache"
  mkdir -p "$cache"

  local name ver tarball url attempt
  local pending=()
  while IFS=$'\t' read -r name ver; do
    [[ -n "$name" ]] || continue
    # Already unpacked (previous build or the rare case bun kept it)?
    if [[ -f "$nm/$name/package.json" ]] && ls "$nm/$name"/*.node >/dev/null 2>&1; then
      continue
    fi
    pending+=("$name"$'\t'"$ver")
  done < <(napi_android_entries "$lock")

  [[ ${#pending[@]} -gt 0 ]] || return 0
  echo "==> napi: restoring ${#pending[@]} android-arm64 binding(s) pruned by --os=linux installs"

  local running=0
  for entry in "${pending[@]}"; do
    name="${entry%%$'\t'*}"
    ver="${entry##*$'\t'}"
    tarball="$cache/${name//\//+}@$ver.tgz"
    if [[ ! -s "$tarball" ]]; then
      url="https://registry.npmjs.org/$name/-/${name##*/}-$ver.tgz"
      (
        for attempt in 1 2 3; do
          if curl -fsSL --connect-timeout 20 --max-time 420 "$url" -o "$tarball.part" 2>/dev/null \
             && gzip -t "$tarball.part" 2>/dev/null; then
            mv "$tarball.part" "$tarball"
            exit 0
          fi
          rm -f "$tarball.part"
          sleep $((attempt * 2))
        done
        exit 1
      ) &
      running=$((running + 1))
      if [[ $running -ge $parallel ]]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      fi
    fi
  done
  wait 2>/dev/null || true

  local failed=0
  for entry in "${pending[@]}"; do
    name="${entry%%$'\t'*}"
    ver="${entry##*$'\t'}"
    tarball="$cache/${name//\//+}@$ver.tgz"
    if [[ ! -s "$tarball" ]]; then
      echo "WARN: napi: $name@$ver unavailable (registry fetch failed) — web-ui build may fail" >&2
      failed=$((failed + 1))
      continue
    fi
    mkdir -p "$nm/$name"
    if ! tar xzf "$tarball" -C "$nm/$name" --strip-components=1 2>/dev/null; then
      echo "WARN: napi: $name@$ver tarball unreadable" >&2
      failed=$((failed + 1))
    fi
  done
  echo "    napi: restored $(( ${#pending[@]} - failed )) package(s), ${failed} unavailable"
  [[ $failed -eq 0 ]]
}
