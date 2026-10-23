#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-bionic.sh — v2 Native B-line builder (android-bun source compile).
#
# Compiles the opencode v2 source tree with the android (bionic) Bun into a
# zero-glibc native ELF, then normalizes the product to the packaging contract
# names so the v1 native/compressed package scripts can be reused verbatim:
#
#   artifacts/build/<ver>/opencode-native-revived      (deb-native/pacman-native)
#   artifacts/build/<ver>/opencode-native-revived-upx  (deb-compressed/pacman-compressed)
#
# Command chain, in order:
#   1. opentui runtime check   — the grafted bionic libopentui.so in the .bun
#      store must export the 9 v2 FFI symbols + pthread_tryjoin_np stanza;
#      rebuild via tools/transplant/build-libopentui.sh when missing.
#   2. platform patch          — tools/build-bionic/apply-platform-patch.sh
#      (idempotent; forces process.platform="linux" so the loader picks the
#      bionic linux-arm64 libopentui.so).
#   3. bundler compile         — bun script/build.ts --target=opencode-linux-arm64
#      (android bun; openat2_shim LD_PRELOAD for install-only paths; no shim
#      needed at runtime).
#   4. normalize               — copy dist output to contract names + write
#      build.json (sha256 + provenance).
#
# Environment:
#   VER                version tag for the build (default: 2.0.0)
#   V2_SRC             v2 monorepo root (contains packages/cli/script/build.ts)
#                      default: $HOME/develop/opencode-src/opencode-<VER> or
#                      $(TMPDIR)/v2probe/opencode-src/opencode-<VER>
#   ANDROID_BUN        android bun binary (default: artifacts/transplant/android-bun/bun-1.4.0/bun)
#                      Fixes #23 for the B line: bun-1.4.2 segfaults at 0x40 on
#                      Android/bionic; pin 1.4.0 like the A line bind-target.
#   OPENAT2_SHIM       openat2/fchmodat2 LD_PRELOAD shim (default: tools/transplant/toolchain/openat2_shim.so)
#   OPENTUI_REBUILD    1 = force rebuild of the bionic libopentui.so (default 0 = only when broken)
#   OPENCODE_VERSION   version string embedded in the binary (default: VER)
#   BUILD_ROOT         output root (default: artifacts/build)
#   UPX                set to 1 to also produce the -upx variant
#   UPX_OPTS           upx flags (default: --best)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VER="${VER:-2.0.0}"

# Unit-testable guards (docs-reorg-maint E1a): store/pkgs/file assertions live in
# a sourced library so they can be tested without a full compilation.
# shellcheck source=scripts/lib/build-guards.sh
source "$ROOT_DIR/scripts/lib/build-guards.sh"

# ── 依赖钉版（push261013 todo 12：issue #35「build-bionic 仍钉 0.1.13/0.5.10」）──
# 归因结论: family-v2-native → build-native → 本脚本是 v2 native 的出厂 B-line 编译链
# （Makefile:836），钉版直接进出厂包，故必须跟上上游逐版漂移。
# 表在 scripts/lib/build-pins.sh（可单测）；未知 VER 硬失败——旧的 `*` 回落
# 0.5.14 会把 2.1.x 源码和新 opentui 静默错配（docs-reorg-maint E1c）。
# PTY_VER / OPENTUI_VER 环境变量仍可覆盖（调试用）。
# shellcheck source=scripts/lib/build-pins.sh
source "$ROOT_DIR/scripts/lib/build-pins.sh"
_pins="$(resolve_dep_pins "$VER")" || exit 1
eval "$_pins"
echo "==> dep pins for VER=$VER: pty=$PTY_VER opentui=$OPENTUI_VER"

# ── resolve v2 source tree ─────────────────────────────────────────────
if [[ -n "${V2_SRC:-}" ]]; then
  SRC_DIR="$V2_SRC"
else
  for cand in \
    "$HOME/develop/opencode-src/opencode-$VER" \
    "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2probe/opencode-src/opencode-$VER"; do
    if [[ -d "$cand/packages/cli" ]]; then SRC_DIR="$cand"; break; fi
  done
fi
[[ -n "${SRC_DIR:-}" && -f "$SRC_DIR/packages/cli/script/build.ts" ]] || {
  echo "==> v2 source tree not found for $VER, downloading from GitHub..." >&2
  DL_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src"
  mkdir -p "$DL_DIR"
  EXTRACT_DIR="$DL_DIR/opencode-${VER}"
  if [[ ! -f "$EXTRACT_DIR/packages/cli/script/build.ts" ]]; then
    TGZ="$DL_DIR/opencode-${VER}-src.tar.gz"
    if [[ ! -f "$TGZ" ]]; then
      curl -fsSL "https://codeload.github.com/anomalyco/opencode/tar.gz/v${VER}" -o "$TGZ" || {
        echo "Error: failed to download source for v${VER} from GitHub" >&2
        exit 1
      }
    fi
    mkdir -p "$EXTRACT_DIR"
    tar xzf "$TGZ" -C "$EXTRACT_DIR" --strip-components=1 2>/dev/null || {
      echo "Error: failed to extract source tarball" >&2
      exit 1
    }
  fi
  [[ -f "$EXTRACT_DIR/packages/cli/script/build.ts" ]] || {
    echo "Error: extracted source has no packages/cli/script/build.ts" >&2
    exit 1
  }
  SRC_DIR="$EXTRACT_DIR"
}

# Fixes #23 (B line): default to bun-1.4.0 — 1.4.2 panics "Segmentation fault
# at address 0x40" on Android/bionic during TUI startup (EXIT 139, reproduced).
# Same pin as tools/transplant/config/bun-bind.json target; override via env ANDROID_BUN.
ANDROID_BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.0/bun}"
OPENAT2_SHIM="${OPENAT2_SHIM:-$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/artifacts/build}"
OUT_DIR="$BUILD_ROOT/$VER"
OPENCODE_VERSION="${OPENCODE_VERSION:-$VER}"
ULW_PATCH="$ROOT_DIR/tools/build-bionic/apply-platform-patch.sh"

[[ -x "$ANDROID_BUN" ]] || { echo "Error: ANDROID_BUN not found: $ANDROID_BUN" >&2; exit 1; }
[[ -f "$OPENAT2_SHIM" ]] || { echo "Error: OPENAT2_SHIM not found: $OPENAT2_SHIM (build via tools/transplant/toolchain/)" >&2; exit 1; }

echo "==> build-bionic VER=$VER"
echo "    src = $SRC_DIR"
echo "    bun = $ANDROID_BUN"

# ── 1. opentui bionic runtime check ────────────────────────────────────
STORE="$SRC_DIR/node_modules/.bun"
# ── 0.5 install dependencies (required for store/opentui check) ────────
echo "==> installing dependencies (bun install --force --ignore-scripts + shim)..."
cd "$SRC_DIR/packages/cli"
install_ok=0
for attempt in 1 2 3 4 5; do
  if LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts 2>&1 | tail -3; then
    install_ok=1
    break
  fi
  echo "    WARN: bun install attempt $attempt failed (transient TLS/network?), retrying in $((attempt * 5))s..." >&2
  sleep $((attempt * 5))
done
if [[ $install_ok -ne 1 ]]; then
  # E1a: continuing with an empty store only produced an unusable binary later.
  # Offline builds stay supported when the store is already populated.
  if is_store_populated "$STORE"; then
    echo "WARN: bun install failed after 5 attempts; store already populated (offline mode)" >&2
  else
    echo "Error: bun install failed after 5 attempts and store is empty — cannot build" >&2
    exit 1
  fi
fi
cd "$ROOT_DIR"
cd "$ROOT_DIR"

# ── 0.6 install platform-specific packages one-by-one (rc2, #20) ──
# A single 404 (e.g. @opentui/solid-linux-arm64 has no npm package) aborted the whole
# batch in RC1, so @opentui/core-linux-arm64 (which carries libopentui.so) was never
# installed and the glibc store lib got bundled. Install each target separately:
# mandatory targets hard-fail, optional (musl/solid) warn-and-continue.
echo "==> installing platform packages one-by-one (pty, watcher, core, fonts)..."
cd "$SRC_DIR/packages/cli"
for pkg in "@opencode-ai/pty-linux-arm64-gnu@$PTY_VER" "@parcel/watcher-linux-arm64-glibc@2.5.1" "@opentui/core-linux-arm64@$OPENTUI_VER"; do
  pkg_ok=0
  for attempt in 1 2 3 4 5; do
    if LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" 2>&1 | tail -2; then
      pkg_ok=1
      break
    fi
    echo "    WARN: $pkg attempt $attempt failed (transient TLS/network?), retrying in $((attempt * 5))s..." >&2
    sleep $((attempt * 5))
  done
  [[ $pkg_ok -eq 1 ]] || { echo "Error: mandatory platform package failed after 5 attempts: $pkg" >&2; exit 1; }
  echo "    ^ $pkg"
done
for pkg in "@opentui/core-linux-arm64-musl@$OPENTUI_VER" "@opentui/solid-linux-arm64@$OPENTUI_VER"; do
  if LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" >/dev/null 2>&1; then
    echo "    OK  $pkg"
  else
    echo "    WARN (non-fatal): $pkg unavailable"
  fi
done
cd "$ROOT_DIR"
NEEDED_SYMS=(cancelKittyImageTransport editBufferSetTabWidth getBufferWidthMethod \
  getKittyImageTransport imageCreateFromPixels imageUpdatePixels pollKittyImageTransport \
  processKittyImageReply setKittyImageTransport pthread_tryjoin_np)

# ── rc2 (#20): ALWAYS deploy verified bionic .so to EVERY candidate store key ──
# bun may keep the store under SRC_DIR/node_modules/.bun OR
# SRC_DIR/packages/cli/node_modules/.bun; deploy to every @opentui+core-linux-arm64@ /
# @opentui+core@ key found so a later build.ts resolution can never pick up a glibc lib.
# TLSDESC-shim build (fix-tlsdesc-pipeline): the old opentui-bionic/ base is
# shim-less (028eaf46) and crashes TUI init on bionic 9 hosts.
BUILTIN="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.so"
if [[ ! -f "$BUILTIN" ]]; then
  echo "Error: bionic libopentui.so not found at $BUILTIN — refusing to bundle glibc store lib (issue #20)" >&2
  echo "       build it first: bash tools/transplant/build-libopentui.sh" >&2
  exit 1
fi
if readelf -d "$BUILTIN" 2>/dev/null | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]'; then
  echo "Error: $BUILTIN itself is glibc-linked (NEEDED libc.so.6 & co) — refusing to deploy a broken lib" >&2
  exit 1
fi
GLIBC_SO_KEYS=()
for st in "$STORE" "$SRC_DIR/node_modules/.bun" "$SRC_DIR/packages/cli/node_modules/.bun"; do
  [[ -d "$st" ]] || continue
  while IFS= read -r key; do
    GLIBC_SO_KEYS+=("$key")
    cp -p "$BUILTIN" "$key/libopentui.so"
    echo "    deployed bionic libopentui.so -> $key"
  done < <(ls -d "$st"/@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64 2>/dev/null; ls -d "$st"/@opentui+core@*/node_modules/@opentui/core 2>/dev/null)
done
if [[ ${#GLIBC_SO_KEYS[@]} -eq 0 ]]; then
  echo "Error: no @opentui core store key found under any candidate store — cannot verify TUI linkage" >&2
  exit 1
fi
TUI_SO="${GLIBC_SO_KEYS[0]}/libopentui.so"

# ── rc2 (#20): verify deployed lib is bionic, not glibc (DT_NEEDED scan) ──
if readelf -d "$TUI_SO" 2>/dev/null | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]'; then
  echo "Error: deployed libopentui.so is glibc-linked (NEEDED libc.so.6 & co) — cannot dlopen on bionic" >&2
  echo "       deploy the bionic build: make libopentui" >&2
  exit 1
fi

# ── Verify FFI symbols ──
TUI_OK=0
if [[ -n "$TUI_SO" && -f "$TUI_SO" ]]; then
  TUI_SYMS="$(nm -D "$TUI_SO" 2>/dev/null)" || TUI_SYMS=""
  missing=0
  for s in "${NEEDED_SYMS[@]}"; do
    grep -qw "$s" <<< "$TUI_SYMS" || { echo "    missing symbol: $s"; missing=1; }
  done
  [[ $missing -eq 0 ]] && TUI_OK=1
fi

if [[ "$TUI_OK" -eq 1 && "${OPENTUI_REBUILD:-0}" != "1" ]]; then
  echo "    opentui bionic runtime OK: $TUI_SO"
elif [[ "${OPENTUI_REBUILD:-0}" == "1" ]]; then
  echo "==> rebuilding bionic libopentui.so (OPENTUI_REBUILD=1)"
  bash "$ROOT_DIR/tools/transplant/build-libopentui.sh"
  TUI_DIR="$(dirname "$TUI_SO")"
  mkdir -p "$TUI_DIR"
  cp -f "$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.so" "$TUI_DIR/libopentui.so"
else
  echo "==> opentui bionic runtime stale/broken; refusing auto-rebuild (patch drift risk)"
  echo "    TUI_SO=$TUI_SO missing FFI symbols — graft a verified .so then re-run"
  echo "    (build: make libopentui  OR manual zig build per docs/tui-common-fix.md)"
  exit 1
fi

# ── 1b. install linux platform packages (android bun reports platform=android) ──
echo "==> installing linux platform packages (pty, watcher)..."
cd "$SRC_DIR"
for pkg in "@opencode-ai/pty@$PTY_VER" "@parcel/watcher-linux-arm64-glibc@2.5.1"; do
  pkg_name="${pkg%%@*}"
  pkg_short="${pkg_name##*/}"
  # Check if already installed in store (any platform variant)
  if ls "$STORE"/${pkg_name//\//+}@*/node_modules/$pkg_name/package.json &>/dev/null; then
    echo "    $pkg_short already in store"
  else
    echo "    installing $pkg..."
    if ! LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" 2>&1 | tail -1; then
      echo "Error: platform package install failed: $pkg" >&2
      exit 1
    fi
  fi
  # E1a: the install above used to be best-effort. Assert the package actually
  # landed — a missing pty/watcher silently broke the bundle.
  require_pkg_installed "$STORE" "$SRC_DIR" "$pkg_name" || exit 1
  # Ensure platform-specific binary is in node_modules (store may use platform-agnostic key)
  PTY_BIN="$(find "$STORE" -path "*/$pkg_name/bin/opencode-pty" -type f 2>/dev/null | head -n1)"
  if [[ -z "$PTY_BIN" ]]; then
    # Fallback: try platform-specific store key
    PTY_BIN="$(find "$STORE" -path "*/${pkg_name}-linux-arm64-gnu/bin/opencode-pty" -type f 2>/dev/null | head -n1)"
  fi
  if [[ -n "$PTY_BIN" ]]; then
    # Create symlink in node_modules/@opencode-ai/pty-linux-arm64-gnu/bin/ if missing
    DEST_DIR="$SRC_DIR/node_modules/${pkg_name}-linux-arm64-gnu/bin"
    if [[ ! -f "$DEST_DIR/opencode-pty" && -n "$PTY_BIN" ]]; then
      mkdir -p "$DEST_DIR"
      # E1a: a failed copy used to be swallowed; assert the helper really landed.
      if ! cp -p "$PTY_BIN" "$DEST_DIR/opencode-pty" 2>/dev/null; then
        echo "Error: pty helper copy failed: $PTY_BIN -> $DEST_DIR/opencode-pty" >&2
        exit 1
      fi
      require_file "$DEST_DIR/opencode-pty" "pty helper" || exit 1
    fi
  fi
done
cd "$ROOT_DIR"

# ── 1c. (issue #27 / RFC discussions/29) PTY helper variant ──
# PTY_VARIANT=musl (default, RC4/B2): the embedded @opencode-ai/pty-linux-arm64-gnu
#   asset is glibc-linked (NEEDED libpthread.so.0 / libdl.so.2 / libutil.so.1) —
#   bun FFI extraction + exec of it fails on Android/bionic in fragile environments.
#   Overwrite every -gnu copy (node_modules + store) with the FULLY STATIC musl
#   binary of the same version.
# PTY_VARIANT=gnu (RC5/B1, maintainer ruling): keep the upstream -gnu asset as-is
#   — runtime-stable in the vast majority of environments incl. zero-glibc
#   (MT-manager verified); accepted trade-off per RFC discussions/29.
PTY_VARIANT="${PTY_VARIANT:-musl}"
case "$PTY_VARIANT" in
  musl)
    echo "==> installing musl PTY helper (issue #27: gnu variant cannot run on bionic)..."
    if LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "@opencode-ai/pty-linux-arm64-musl@$PTY_VER" 2>&1 | tail -1; then :; fi
    PTY_MUSL_BIN="$(find "$STORE" "$SRC_DIR/node_modules" -path '*pty-linux-arm64-musl/bin/opencode-pty' -type f 2>/dev/null | head -n1)"
    if [[ -z "$PTY_MUSL_BIN" ]] || ! file "$PTY_MUSL_BIN" | grep -q 'statically linked'; then
      echo "Error: static musl opencode-pty not found/valid — bionic PTY would be broken (issue #27)" >&2
      exit 1
    fi
    PTY_REPLACED=0
    while IFS= read -r g; do
      cp -f "$PTY_MUSL_BIN" "$g"
      PTY_REPLACED=$((PTY_REPLACED + 1))
      echo "    static musl pty -> $g"
    done < <(find "$STORE" "$SRC_DIR/node_modules" -path '*pty-linux-arm64-gnu/bin/opencode-pty' -type f 2>/dev/null)
    if [[ $PTY_REPLACED -lt 1 ]]; then
      echo "Error: no -gnu pty copy found to replace (issue #27)" >&2
      exit 1
    fi
    PTY_ASSET="$PTY_MUSL_BIN"
    ;;
  gnu)
    echo "==> PTY_VARIANT=gnu: keeping upstream gnu pty asset as-is (B1 continuation, RFC discussions/29)"
    PTY_GNU_N="$(find "$STORE" "$SRC_DIR/node_modules" -path '*pty-linux-arm64-gnu/bin/opencode-pty' -type f 2>/dev/null | wc -l)"
    if [[ $PTY_GNU_N -lt 1 ]]; then
      echo "Error: no -gnu pty asset found (PTY_VARIANT=gnu)" >&2
      exit 1
    fi
    PTY_ASSET="$(find "$STORE" "$SRC_DIR/node_modules" -path '*pty-linux-arm64-gnu/bin/opencode-pty' -type f 2>/dev/null | head -n1)"
    ;;
  *)
    echo "Error: PTY_VARIANT must be musl|gnu (got: $PTY_VARIANT)" >&2
    exit 1
    ;;
esac
# E5: record the exact pty asset we installed. The compiler embeds the asset's
# sha256; the post-compile assertion below fails the build when the binary
# carries any other pty variant (RC4's stale-asset class).
[[ -n "${PTY_ASSET:-}" && -f "$PTY_ASSET" ]] || { echo "Error: pty asset unresolved (variant=$PTY_VARIANT)" >&2; exit 1; }
PTY_SHA="$(sha256sum "$PTY_ASSET" | cut -d' ' -f1)"
mkdir -p "$BUILD_ROOT/$VER"
printf 'variant=%s\nversion=%s\nsha256=%s\n' "$PTY_VARIANT" "$PTY_VER" "$PTY_SHA" >"$BUILD_ROOT/$VER/pty-sha256.txt"
echo "    pty asset: $PTY_VARIANT $PTY_VER sha256=${PTY_SHA:0:12}… ($(basename "$PTY_ASSET"))"
cd "$SRC_DIR/packages/cli"

# ── 2. platform patch (idempotent) ─────────────────────────────────────
CHUNK="$(ls -d "$STORE"/@opentui+core@*/ 2>/dev/null | head -n1)" \
  || { echo "Error: @opentui core store key not found under $STORE" >&2; exit 1; }
: "${CHUNK:?Error: @opentui+core store chunk not found — run 'bun install --force --ignore-scripts' in $SRC_DIR}"
"$ULW_PATCH" "${CHUNK%/}"

# ── bun pin (#23): upstream packageManager gate wants ^1.4.2, but bun 1.4.2
# segfaults on Android/bionic TUI (0x40). Rewrite package.json so the build
# script's semver gate (packages/script/src/index.ts ^range) accepts our
# pinned bun-1.4.0 — the bundled runtime is what crashes, so building with
# 1.4.0 ships a non-crashing binary. Idempotent; re-applied after every
# source re-extract.
PM_PKG="$SRC_DIR/package.json"
if grep -q '"packageManager": "bun@' "$PM_PKG"; then
  sed -i -E 's/"packageManager": "bun@[0-9]+\.[0-9]+\.[0-9]+"/"packageManager": "bun@1.4.0"/' "$PM_PKG"
fi
grep -q '"packageManager": "bun@1.4.0"' "$PM_PKG" || {
  echo "Error: packageManager pin to bun@1.4.0 failed ($PM_PKG)" >&2; exit 1; }
echo "==> bun pin: package.json packageManager -> bun@1.4.0 (upstream gate accept)"

# ── rc2b (#20): re-deploy + sweep AFTER the last bun install, pre-embed ──
# 1b's `bun install --force` re-extracts pristine glibc store contents and
# reverts the bionic graft made in the rc2 block above, so re-apply it here —
# the last moment before build.ts embeds the .so. Then hard-gate EVERY copy.
echo "==> rc2b: re-deploying bionic libopentui.so (post-1b, pre-embed)..."
mapfile -t SO_TARGETS < <(find "$SRC_DIR/node_modules" "$SRC_DIR/packages/cli/node_modules" \
  -name libopentui.so 2>/dev/null | sort -u)
if [[ ${#SO_TARGETS[@]} -eq 0 ]]; then
  echo "Error: no libopentui.so under node_modules — unexpected store layout (issue #20)" >&2
  exit 1
fi
for so in "${SO_TARGETS[@]}"; do
  cp -p "$BUILTIN" "$so"
  echo "    re-deployed -> $so"
done
rc2b_bad=0
for so in "${SO_TARGETS[@]}"; do
  if readelf -d "$so" 2>/dev/null | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]'; then
    echo "Error: $so still glibc-linked after re-deploy (issue #20)" >&2
    rc2b_bad=1
  fi
done
[[ $rc2b_bad -eq 0 ]] || exit 1
echo "    rc2b sweep OK: ${#SO_TARGETS[@]} libopentui.so all bionic"

# ── 3. bundler compile ─────────────────────────────────────────────────
cd "$SRC_DIR/packages/cli"
# ── 2z. web-ui prepare (#22 serve 404 fix — idempotent; was manual-only) ──
#  buildAppArchive(skipBuild=true) returned "{}" => binary shipped WITHOUT web
#  assets => serve 404 after login. Fix: (a) patch app-assets.ts so skipBuild
#  skips the vite RUN but still collects prebuilt dist; (b) pre-build app dist.
#  #42: upstream changed the guard's return value (v2.0.27+: `return
#  AppArchive.encode([])`), so the old exact-string anchor silently mismatched
#  and the whole patch block was skipped => empty-archive binaries again. New
#  anchor matches the guard STATEMENT (not its return literal) and a missing
#  anchor is a hard error, never a silent skip. Post-compile we also assert
#  the artifact actually contains web assets.
APP_TS="$SRC_DIR/packages/cli/script/app-assets.ts"
APP_DIR="$SRC_DIR/packages/app"
if [[ -f "$APP_TS" ]] && grep -qE 'if \(options\?\.skipBuild\) return' "$APP_TS"; then
  echo "==> web-ui: patching app-assets.ts (#22 skipBuild collects prebuilt dist)"
  python3 - "$APP_TS" <<'PY_PATCH'
import re, sys
f = sys.argv[1]
src = open(f).read()
# delete the skipBuild guard line regardless of its return literal (#42)
src, n_guard = re.subn(r'[ \t]*if \(options\?\.skipBuild\) return[^\n]*\n', '', src, count=1)
if n_guard != 1:
    sys.exit(f"app-assets anchor drift: skipBuild guard hits = {n_guard}, expected 1")
old_run = 'await $`bun run build`'
if src.count(old_run) != 1:
    sys.exit(f"app-assets anchor drift: build call hits = {src.count(old_run)}, expected 1")
src = src.replace(old_run, 'if (!options?.skipBuild) await $`bun run build`', 1)
open(f, 'w').write(src)
print("    app-assets.ts patched (skipBuild -> collect-only)")
PY_PATCH
else
  echo "Error: app-assets.ts skipBuild guard not found — anchor drifted upstream; refusing to build an empty-archive binary (#22 regression, issue #42)" >&2
  exit 1
fi
DIST_CACHE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src/.app-dist-cache/$VER"
# Three-state dist resolution (per-version cache survives clean-version, which
# only removes v2src/opencode-$VER — the sibling .app-dist-cache is kept):
if [[ ! -f "$APP_DIR/dist/index.html" && -f "$DIST_CACHE/index.html" ]]; then
  echo "==> web-ui: restoring dist from per-version cache ($DIST_CACHE)"
  mkdir -p "$APP_DIR/dist"
  cp -a "$DIST_CACHE/." "$APP_DIR/dist/"
fi
if [[ ! -f "$APP_DIR/dist/index.html" ]]; then
  echo "==> web-ui: pre-building packages/app dist (vite)"
  # bionic-node quirk: vite prints "built in Xs" then HANGS (zero io, no socket)
  # — kill at 240s and let the artifact gate (below) be the pass/fail judge.
  if ! timeout 240 bash -c 'cd "$1" && OPENCODE_CHANNEL=latest VITE_OPENCODE_SERVER_MODE=origin "$2" run build' _ "$APP_DIR" "$ANDROID_BUN"; then
    echo "    WARN: vite non-zero or timeout-killed (known bionic hang); judging by artifacts..."
  fi
  [[ -f "$APP_DIR/dist/index.html" ]] || { echo "Error: web-ui dist pre-build produced no dist/index.html" >&2; exit 1; }
  mkdir -p "$DIST_CACHE"
  cp -a "$APP_DIR/dist/." "$DIST_CACHE/"
  echo "    dist ready: $(du -sh "$APP_DIR/dist" | cut -f1); cached -> $DIST_CACHE"
else
  echo "==> web-ui: dist ready ($(du -sh "$APP_DIR/dist" | cut -f1)), skip vite"
fi

echo "==> compiling (android bun, target=opencode-linux-arm64)"
LD_PRELOAD="$OPENAT2_SHIM" OPENCODE_VERSION="$OPENCODE_VERSION" \
  "$ANDROID_BUN" script/build.ts --target=opencode-linux-arm64 --skip-install --skip-web-ui
DIST_BIN="$SRC_DIR/packages/cli/dist/cli-linux-arm64/bin/opencode"
[[ -x "$DIST_BIN" ]] || { echo "Error: build output missing: $DIST_BIN" >&2; exit 1; }
# Hard assertion: the artifact must actually carry web UI assets (#22/#42).
if ! strings -a "$DIST_BIN" | grep -q '/_assets/'; then
  echo "Error: web UI assets missing from artifact (#22 regression, issue #42)" >&2
  exit 1
fi
echo "    web-ui assets present in artifact"

# Hard assertion: the artifact must embed the pty asset we installed (E5).
# Prevents the RC4 class where a build picked up a stale pty variant.
PTY_META="$BUILD_ROOT/$VER/pty-sha256.txt"
[[ -f "$PTY_META" ]] || { echo "Error: pty metadata missing: $PTY_META (cannot verify pty variant)" >&2; exit 1; }
PTY_EXPECT="$(sed -n 's/^sha256=//p' "$PTY_META" | head -n1)"
[[ -n "$PTY_EXPECT" ]] || { echo "Error: sha256 missing in $PTY_META" >&2; exit 1; }
if ! strings -a "$DIST_BIN" | grep -q "$PTY_EXPECT"; then
  echo "Error: embedded pty asset mismatch — expected sha256 $PTY_EXPECT (from $PTY_META), binary carries another variant" >&2
  echo "       rebuild with a clean tree (stale pty asset class, docs/runbooks/release-runbook.md §2)" >&2
  exit 1
fi
echo "    pty embed OK (${PTY_EXPECT:0:12}…)"

# ── 4. normalize to packaging contract names ───────────────────────────
mkdir -p "$OUT_DIR"
mv -f "$DIST_BIN" "$OUT_DIR/opencode-native-revived"
sha256sum "$OUT_DIR/opencode-native-revived" | awk '{print $1}' > "$OUT_DIR/build.sha256"
echo "==> normalized: $OUT_DIR/opencode-native-revived ($(stat -c%s "$OUT_DIR/opencode-native-revived") B)"
echo "    sha256: $(cat "$OUT_DIR/build.sha256")"

# ── 4b. cleanup node_modules (save disk for batch builds) ──
echo "==> cleaning source tree node_modules to save disk..."
rm -rf "$SRC_DIR/node_modules" 2>/dev/null || echo "WARN: could not clean $SRC_DIR/node_modules" >&2
rm -rf "$SRC_DIR/packages/cli/node_modules" 2>/dev/null || echo "WARN: could not clean $SRC_DIR/packages/cli/node_modules" >&2

# ── 5. optional UPX variant ────────────────────────────────────────────
if [[ "${UPX:-0}" == "1" ]]; then
  if command -v upx >/dev/null 2>&1; then
    echo "==> UPX compressing (${UPX_OPTS:---best})"
    cp -p "$OUT_DIR/opencode-native-revived" "$OUT_DIR/opencode-native-revived-upx"
    upx ${UPX_OPTS:---best} --no-color "$OUT_DIR/opencode-native-revived-upx"
    sha256sum "$OUT_DIR/opencode-native-revived-upx" | awk '{print $1}' > "$OUT_DIR/build-upx.sha256"
    echo "    upx: $(stat -c%s "$OUT_DIR/opencode-native-revived-upx") B"
  else
    echo "WARN: upx not found; -upx variant skipped (set UPX=0 or install upx)" >&2
  fi
fi

# ── 6. provenance ──────────────────────────────────────────────────────
python3 - "$OUT_DIR" "$VER" "$SRC_DIR" "$ANDROID_BUN" << 'PYEOF'
import json, hashlib, os, sys
out_dir, ver, src, bun = sys.argv[1:5]
rec = {
  "version": ver,
  "kind": "native-b-line",
  "source": src,
  "android_bun": bun,
  "note": "compiled on android bun (bionic); TUI via grafted bionic libopentui.so; headless-channel reserve (A+/A-line) documented separately",
}
for name in ("opencode-native-revived", "opencode-native-revived-upx"):
    p = os.path.join(out_dir, name)
    if os.path.isfile(p):
        rec[name] = {
            "size": os.path.getsize(p),
            "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
        }
with open(os.path.join(out_dir, "build.json"), "w") as f:
    json.dump(rec, f, indent=2, ensure_ascii=False)
print("    wrote build.json")
PYEOF
echo "==> build-bionic done: $OUT_DIR"