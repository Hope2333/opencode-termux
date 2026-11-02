#!/data/data/com.termux/files/usr/bin/bash
# npm-fetch.sh — install a single npm package without running `bun install`.
#
# WHY
#   Every `bun install <pkg> --os=linux --cpu=arm64` in build-bionic.sh
#   re-resolves and rewrites the WHOLE dependency tree:
#     * it needs the npm registry resolver (the slowest, flakiest part of the
#       build — a stalled resolve burns the full PLATFORM_INSTALL_TIMEOUT), and
#     * it prunes every android-only optionalDependency, which then breaks the
#       vite/rolldown web-ui build (see scripts/lib/napi-android.sh).
#   The build only ever needs *one* glibc platform package at a time
#   (pty / watcher / opentui-core); fetching that tarball from the registry and
#   unpacking it into the bun store layout is seconds of work, not minutes of
#   resolution, and leaves the rest of the tree untouched.
#
# WHAT
#   install_pkg_direct <name>[@<version>] [<node_modules_dir>] [<cache_dir>]
#     * resolves the tarball URL from the packument when the version is not
#       pinned to an exact string,
#     * caches the tarball (re-used across builds and versions),
#     * unpacks into BOTH layouts the build asserts on:
#         $nm/<name>                                        (node resolution)
#         $nm/.bun/<name with / -> +>@<ver>/node_modules/<name>   (store key)
#   Returns non-zero when the package could not be fetched, so callers can fall
#   back to `bun install`.

# Registry base. Default is the canonical npm registry; set NPM_REGISTRY (e.g.
# https://registry.npmmirror.com) when the direct link is throttled — a 1700
# package resolve went from "fails after hours" to 5 minutes on the mirror.
npm_registry_base() {
  printf '%s' "${NPM_REGISTRY:-https://registry.npmjs.org}"
}

npm_fetch_cache_default() {
  printf '%s' "${NPM_TARBALL_CACHE:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src/.npm-tarball-cache}"
}

# npm_registry_version <name> <range-or-version>  → exact version (best effort)
npm_registry_version() {
  local name="$1" want="$2"
  local esc="${name//\//%2f}"
  curl -fsSL --connect-timeout 20 --max-time 120 "$(npm_registry_base)/$esc" 2>/dev/null \
    | python3 -c '
import json, sys
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
vs = d.get("versions") or {}
if want in vs:
    print(want); sys.exit(0)
tags = d.get("dist-tags") or {}
if want in ("latest", "^", ""):
    print(tags["latest"]); sys.exit(0)
# exact-ish fallbacks: strip leading ^/~/= and match prefix
base = want.lstrip("^~=")
def key(v):
    return [int(p) if p.isdigit() else p for p in v.split(".")]
cands = [v for v in vs if v == base or v.startswith(base + ".")]
if cands:
    try:
        print(sorted(cands, key=key)[-1])
    except Exception:
        print(sorted(cands)[-1])
    sys.exit(0)
sys.exit(1)
' "$want"
}

# npm_tarball <name> <version> [cache]  → echoes the cached .tgz path
npm_tarball() {
  local name="$1" ver="$2" cache="${3:-$(npm_fetch_cache_default)}"
  local tarball url attempt
  mkdir -p "$cache"
  tarball="$cache/${name//\//+}@$ver.tgz"
  [[ -s "$tarball" ]] && { printf '%s\n' "$tarball"; return 0; }
  url="$(npm_registry_base)/$name/-/${name##*/}-$ver.tgz"
  for attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 20 --max-time 420 "$url" -o "$tarball.part" 2>/dev/null \
       && gzip -t "$tarball.part" 2>/dev/null; then
      mv "$tarball.part" "$tarball"
      printf '%s\n' "$tarball"
      return 0
    fi
    rm -f "$tarball.part"
    sleep $((attempt * 2))
  done
  return 1
}

# install_pkg_direct <name>[@<version>] [<node_modules_dir>] [<cache_dir>]
install_pkg_direct() {
  local spec="$1" nm="${2:-}" cache="${3:-$(npm_fetch_cache_default)}"
  local name ver tarball store

  case "$spec" in
    @*/*@*) name="${spec%@*}"; ver="${spec##*@}" ;;
    @*)     name="$spec";       ver="latest" ;;
    *@*)    name="${spec%@*}";  ver="${spec##*@}" ;;
    *)      name="$spec";       ver="latest" ;;
  esac
  [[ -n "$nm" ]] || nm="$PWD/node_modules"
  [[ -d "$nm" ]] || return 1

  if [[ "$ver" == "latest" || "$ver" == ^* || "$ver" == "~"* ]]; then
    ver="$(npm_registry_version "$name" "$ver")" || return 1
  fi

  tarball="$(npm_tarball "$name" "$ver" "$cache")" || return 1

  # node-resolution layout
  if [[ ! -f "$nm/$name/package.json" ]]; then
    mkdir -p "$nm/$name"
    tar xzf "$tarball" -C "$nm/$name" --strip-components=1 2>/dev/null || return 1
  fi
  # bun isolated-store layout (the build asserts on store keys)
  store="$nm/.bun/${name//\//+}@$ver/node_modules/$name"
  if [[ ! -f "$store/package.json" ]]; then
    mkdir -p "$store"
    tar xzf "$tarball" -C "$store" --strip-components=1 2>/dev/null || return 1
  fi
  printf '%s\n' "$ver"
}
