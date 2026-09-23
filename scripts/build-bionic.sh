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
#   ANDROID_BUN        android bun binary (default: artifacts/transplant/android-bun/bun-1.4.2/bun)
#   OPENAT2_SHIM       openat2/fchmodat2 LD_PRELOAD shim (default: tools/transplant/toolchain/openat2_shim.so)
#   OPENTUI_REBUILD    1 = force rebuild of the bionic libopentui.so (default 0 = only when broken)
#   OPENCODE_VERSION   version string embedded in the binary (default: VER)
#   BUILD_ROOT         output root (default: artifacts/build)
#   UPX                set to 1 to also produce the -upx variant
#   UPX_OPTS           upx flags (default: --best)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VER="${VER:-2.0.0}"

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

ANDROID_BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.2/bun}"
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
  echo "WARN: bun install failed after 5 attempts; continuing without store" >&2
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
for pkg in "@opencode-ai/pty-linux-arm64-gnu@0.1.13" "@parcel/watcher-linux-arm64-glibc@2.5.1" "@opentui/core-linux-arm64@0.5.10"; do
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
for pkg in "@opentui/core-linux-arm64-musl@0.5.10" "@opentui/solid-linux-arm64@0.5.10"; do
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
BUILTIN="$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so"
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
  TUI_SYMS="$(nm -D "$TUI_SO" 2>/dev/null || true)"
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
  cp -f "$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so" "$TUI_DIR/libopentui.so"
else
  echo "==> opentui bionic runtime stale/broken; refusing auto-rebuild (patch drift risk)"
  echo "    TUI_SO=$TUI_SO missing FFI symbols — graft a verified .so then re-run"
  echo "    (build: make libopentui  OR manual zig build per docs/tui-common-fix.md)"
  exit 1
fi

# ── 1b. install linux platform packages (android bun reports platform=android) ──
echo "==> installing linux platform packages (pty, watcher)..."
cd "$SRC_DIR"
for pkg in "@opencode-ai/pty@0.1.13" "@parcel/watcher-linux-arm64-glibc@2.5.1"; do
  pkg_name="${pkg%%@*}"
  pkg_short="${pkg_name##*/}"
  # Check if already installed in store (any platform variant)
  if ls "$STORE"/${pkg_name//\//+}@*/node_modules/$pkg_name/package.json &>/dev/null; then
    echo "    $pkg_short already in store"
  else
    echo "    installing $pkg..."
    LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" 2>&1 | tail -1 || true
  fi
  # Ensure platform-specific binary is in node_modules (store may use platform-agnostic key)
  PTY_BIN="$(find "$STORE" -path "*/$pkg_name/bin/opencode-pty" -type f 2>/dev/null | head -n1 || true)"
  if [[ -z "$PTY_BIN" ]]; then
    # Fallback: try platform-specific store key
    PTY_BIN="$(find "$STORE" -path "*/${pkg_name}-linux-arm64-gnu/bin/opencode-pty" -type f 2>/dev/null | head -n1 || true)"
  fi
  if [[ -n "$PTY_BIN" ]]; then
    # Create symlink in node_modules/@opencode-ai/pty-linux-arm64-gnu/bin/ if missing
    DEST_DIR="$SRC_DIR/node_modules/${pkg_name}-linux-arm64-gnu/bin"
    if [[ ! -f "$DEST_DIR/opencode-pty" && -n "$PTY_BIN" ]]; then
      mkdir -p "$DEST_DIR"
      cp -p "$PTY_BIN" "$DEST_DIR/opencode-pty" 2>/dev/null || true
    fi
  fi
done
cd "$SRC_DIR/packages/cli"

# ── 2. platform patch (idempotent) ─────────────────────────────────────
CHUNK="$(ls -d "$STORE"/@opentui+core@*/ 2>/dev/null | head -n1 || true)"
: "${CHUNK:?Error: @opentui+core store chunk not found — run 'bun install --force --ignore-scripts' in $SRC_DIR}"
"$ULW_PATCH" "${CHUNK%/}"

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
echo "==> compiling (android bun, target=opencode-linux-arm64)"
LD_PRELOAD="$OPENAT2_SHIM" OPENCODE_VERSION="$OPENCODE_VERSION" \
  "$ANDROID_BUN" script/build.ts --target=opencode-linux-arm64 --skip-install --skip-web-ui
DIST_BIN="$SRC_DIR/packages/cli/dist/cli-linux-arm64/bin/opencode"
[[ -x "$DIST_BIN" ]] || { echo "Error: build output missing: $DIST_BIN" >&2; exit 1; }

# ── 4. normalize to packaging contract names ───────────────────────────
mkdir -p "$OUT_DIR"
mv -f "$DIST_BIN" "$OUT_DIR/opencode-native-revived"
sha256sum "$OUT_DIR/opencode-native-revived" | awk '{print $1}' > "$OUT_DIR/build.sha256"
echo "==> normalized: $OUT_DIR/opencode-native-revived ($(stat -c%s "$OUT_DIR/opencode-native-revived") B)"
echo "    sha256: $(cat "$OUT_DIR/build.sha256")"

# ── 4b. cleanup node_modules (save disk for batch builds) ──
echo "==> cleaning source tree node_modules to save disk..."
rm -rf "$SRC_DIR/node_modules" 2>/dev/null || true
rm -rf "$SRC_DIR/packages/cli/node_modules" 2>/dev/null || true

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