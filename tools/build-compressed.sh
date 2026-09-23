#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-compressed.sh — Build compressed packages from pre-built UPX assets.
#
# UPX assets (upx.xz) are produced by human on cloud/cross-node build infra
# and uploaded to GitHub release assets. This script downloads them, decompresses,
# and builds compressed deb + pacman packages locally.
#
# Usage:
#   ./tools/build-compressed.sh <version> [--push-tag <tag>] [--no-upload] [--dry-run]
#
# Examples:
#   ./tools/build-compressed.sh 1.18.28
#   ./tools/build-compressed.sh 1.18.28 --push-tag Push260906
#   ./tools/build-compressed.sh 1.18.28 --dry-run   # build only, no upload
#
# Environment:
#   PUSH_TAG           Override push tag (default: auto-detect)
#   TRANSPLANT_ROOT    Override transplant dir (default: artifacts/transplant)
#   REPO               GitHub repo (default: Hope2333/opencode-termux)

VERSION="${1:-}"
[[ -z "$VERSION" ]] && {
    echo "Usage: $0 <version> [--push-tag <tag>] [--no-upload] [--dry-run]" >&2
    echo "" >&2
    echo "Build compressed packages from pre-built UPX assets on GitHub." >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 1.18.28" >&2
    echo "  $0 1.18.28 --push-tag Push260906" >&2
    exit 1
}

# Parse flags
PUSH_TAG="${PUSH_TAG:-}"
NO_UPLOAD=false
DRY_RUN=false
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push-tag) PUSH_TAG="$2"; shift 2 ;;
        --no-upload) NO_UPLOAD=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"
REPO="${REPO:-Hope2333/opencode-termux}"
VERSION_DIR="$TRANSPLANT_ROOT/$VERSION"

mkdir -p "$VERSION_DIR"

# ─── Helper: find any existing UPX binary in the version dir ───
find_upx_binary() {
    local dir="$1"
    # Standard names first
    for name in "opencode-native-revived-upx" "opencode-native-${VERSION}-upx"; do
        if [[ -x "$dir/$name" ]] && [[ ! -L "$dir/$name" || -x "$dir/$name" ]]; then
            echo "$dir/$name"
            return 0
        fi
    done
    # Fallback: any *-upx binary (not .xz, not .xz-*)
    local found
    found=$(find "$dir" -maxdepth 1 -name "opencode-native-*-upx" \
        -not -name "*.xz" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    return 1
}

# ─── Step 1: Check if UPX binary already exists locally ───
UPX_BIN="$VERSION_DIR/opencode-native-revived-upx"
EXISTING_UPX=$(find_upx_binary "$VERSION_DIR" 2>/dev/null || true)

if [[ -n "$EXISTING_UPX" ]]; then
    echo "==> Found existing UPX binary: $EXISTING_UPX"
    if [[ "$EXISTING_UPX" != "$UPX_BIN" ]]; then
        echo "    Symlink: $(basename "$EXISTING_UPX") → opencode-native-revived-upx"
        ln -sfn "$(basename "$EXISTING_UPX")" "$UPX_BIN"
    fi
fi

# ─── Step 2: Decompress local upx.xz if present ───
if [[ ! -x "$UPX_BIN" ]]; then
    UPX_XZ="$VERSION_DIR/opencode-native-${VERSION}-upx.xz"
    if [[ -f "$UPX_XZ" ]]; then
        echo "==> Found local upx.xz, decompressing..."
        xz -dk --force "$UPX_XZ" 2>/dev/null || true  # ignore if output exists
        EXISTING_UPX=$(find_upx_binary "$VERSION_DIR" 2>/dev/null || true)
        if [[ -n "$EXISTING_UPX" && "$EXISTING_UPX" != "$UPX_BIN" ]]; then
            ln -sfn "$(basename "$EXISTING_UPX")" "$UPX_BIN"
        fi
    fi
fi

# ─── Step 3: Download from GitHub if still missing ───
if [[ ! -x "$UPX_BIN" ]]; then
    # Auto-detect push tag
    if [[ -z "$PUSH_TAG" ]]; then
        echo "==> Auto-detecting push tag for $VERSION..."
        PUSH_TAG=$(GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release list --repo "$REPO" \
            --json tagName --jq '.[].tagName' 2>/dev/null \
            | grep '^Push' | sort -V | tail -1 || true)
        [[ -z "$PUSH_TAG" ]] && PUSH_TAG="Push$(date +%y%m%d)"
        echo "    Detected: $PUSH_TAG"
    fi

    ASSET_NAME="opencode-native-${VERSION}-upx.xz"
    echo "==> Downloading $ASSET_NAME from $PUSH_TAG..."
    GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release download "$PUSH_TAG" \
        --repo "$REPO" -p "$ASSET_NAME" -D "$VERSION_DIR" || {
        echo "Error: Failed to download $ASSET_NAME from $PUSH_TAG" >&2
        echo "Available UPX assets:" >&2
        GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release view "$PUSH_TAG" --repo "$REPO" \
            --json assets --jq '.assets[].name' 2>/dev/null | grep "upx" || true
        exit 1
    }

    echo "==> Decompressing..."
    xz -dk --force "$VERSION_DIR/$ASSET_NAME" 2>/dev/null || true
    EXISTING_UPX=$(find_upx_binary "$VERSION_DIR" 2>/dev/null || true)
    if [[ -n "$EXISTING_UPX" && "$EXISTING_UPX" != "$UPX_BIN" ]]; then
        ln -sfn "$(basename "$EXISTING_UPX")" "$UPX_BIN"
    fi
fi

# Verify we have the binary
if [[ ! -x "$UPX_BIN" ]]; then
    echo "Error: Could not find or create $UPX_BIN" >&2
    echo "Contents of $VERSION_DIR:" >&2
    ls -la "$VERSION_DIR" 2>/dev/null || true
    exit 1
fi

UPX_SIZE=$(du -h "$UPX_BIN" | cut -f1)
echo "==> UPX binary ready: $UPX_BIN ($UPX_SIZE)"

# ─── Step 4: Locate crhandler .so ───
if [[ -z "${OPENCODE_CRHANDLER_SO:-}" || ! -f "${OPENCODE_CRHANDLER_SO:-}" ]]; then
    for candidate in \
        "$VERSION_DIR/libopencode-crhandler.so" \
        "$VERSION_DIR/opencode-native-tui.strip.so"; do
        if [[ -f "$candidate" ]]; then
            OPENCODE_CRHANDLER_SO="$candidate"
            break
        fi
    done
fi

if [[ -z "${OPENCODE_CRHANDLER_SO:-}" || ! -f "$OPENCODE_CRHANDLER_SO" ]]; then
    echo "Error: libopencode-crhandler.so not found in $VERSION_DIR" >&2
    ls -la "$VERSION_DIR" 2>/dev/null || true
    exit 1
fi
echo "==> crhandler: $OPENCODE_CRHANDLER_SO"

# ─── Step 5: Build packages ───
echo ""
echo "==> Building compressed deb..."
OPENCODE_COMPRESSED_BIN="$UPX_BIN" \
OPENCODE_CRHANDLER_SO="$OPENCODE_CRHANDLER_SO" \
VERSION="$VERSION" \
    bash "$ROOT_DIR/scripts/package/package_deb_compressed.sh"

echo ""
echo "==> Building compressed pacman..."
OPENCODE_COMPRESSED_BIN="$UPX_BIN" \
OPENCODE_CRHANDLER_SO="$OPENCODE_CRHANDLER_SO" \
VERSION="$VERSION" \
    bash "$ROOT_DIR/scripts/package/package_pacman_compressed.sh"

# ─── Step 6: Report output ───
echo ""
echo "==> Built packages:"
DEB_OUT="$ROOT_DIR/packing/dpkg-compressed/opencode-compressed_${VERSION}_aarch64.deb"
PKG_OUT=$(ls "$ROOT_DIR/packing/pacman/"opencode-compressed-"${VERSION}"-*.pkg.* 2>/dev/null | head -1 || true)

if [[ -f "$DEB_OUT" ]]; then
    echo "    DEB:    $DEB_OUT ($(du -h "$DEB_OUT" | cut -f1))"
else
    echo "    DEB:    NOT FOUND" >&2
fi
if [[ -n "$PKG_OUT" && -f "$PKG_OUT" ]]; then
    echo "    Pacman: $PKG_OUT ($(du -h "$PKG_OUT" | cut -f1))"
else
    echo "    Pacman: NOT FOUND" >&2
fi

# ─── Step 7: Upload ───
if [[ "$DRY_RUN" == true || "$NO_UPLOAD" == true ]]; then
    echo ""
    echo "==> Upload skipped (--dry-run or --no-upload)"
    exit 0
fi

if [[ -z "$PUSH_TAG" ]]; then
    echo ""
    echo "==> No push tag specified; skipping upload"
    exit 0
fi

echo ""
echo "==> Uploading to $PUSH_TAG..."
UPLOAD_FILES=()
[[ -f "$DEB_OUT" ]] && UPLOAD_FILES+=("$DEB_OUT")
[[ -n "$PKG_OUT" && -f "$PKG_OUT" ]] && UPLOAD_FILES+=("$PKG_OUT")

if [[ ${#UPLOAD_FILES[@]} -eq 0 ]]; then
    echo "Error: No packages to upload" >&2
    exit 1
fi

for f in "${UPLOAD_FILES[@]}"; do
    echo "    Uploading $(basename "$f")..."
    GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release upload "$PUSH_TAG" \
        --repo "$REPO" "$f" --clobber
done

echo ""
echo "==> Done! Uploaded ${#UPLOAD_FILES[@]} files to $PUSH_TAG"
