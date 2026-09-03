#!/usr/bin/env bash
# push-stage.sh — Build gh release create command (dry-run by default)
# Usage: push-stage.sh TAG=Push260903 BATCH=prebatch[,compressed]
# Set PUSH=1 to actually execute upload
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${TMPDIR:-/tmp}/oc-release"

# Parse args
TAG=""; BATCH="prebatch"; PUSH_MODE=0
for arg in "$@"; do
    case "$arg" in
        TAG=*) TAG="${arg#TAG=}" ;;
        BATCH=*) BATCH="${arg#BATCH=}" ;;
        PUSH=1) PUSH_MODE=1 ;;
    esac
done

if [ -z "$TAG" ]; then
    echo "Usage: push-stage.sh TAG=PushYYMMDD BATCH=prebatch[,compressed]"
    exit 1
fi

REPO_SLUG="Hope2333/opencode-termux"
echo "=== push-stage TAG=$TAG BATCH=$BATCH ==="
echo ""

# Collect assets
ASSETS=()
if echo "$BATCH" | grep -q "prebatch"; then
    echo "Collecting prebatch assets..."
    for f in "$REPO/packing/dpkg/opencode-glibc_"*.deb \
             "$REPO/packing/pacman/opencode-glibc-"*.pkg.* \
             "$REPO/packing/dpkg-native/opencode_"*.deb \
             "$REPO/packing/pacman/opencode-"*.pkg.*; do
        [ -f "$f" ] && ASSETS+=("$f") && echo "  $(basename "$f")"
    done
fi

if echo "$BATCH" | grep -q "compressed"; then
    echo "Collecting compressed assets..."
    for f in "$REPO/packing/dpkg-compressed/opencode-compressed_"*.deb \
             "$REPO/packing/pacman/opencode-compressed-"*.pkg.*; do
        [ -f "$f" ] && ASSETS+=("$f") && echo "  $(basename "$f")"
    done
fi

# SHA256SUMS
SUMS="$REPO/packing/SHA256SUMS-prebatch.txt"
if [ -f "$SUMS" ]; then
    ASSETS+=("$SUMS")
    echo "  SHA256SUMS-prebatch.txt"
fi

echo ""
echo "Total assets: ${#ASSETS[@]}"
echo ""

# Build command
CMD="gh release create $TAG --repo $REPO_SLUG --prerelease --title \"$TAG\""
CMD="$CMD --notes-file <(echo 'Release $TAG — OpenCode for Termux')"
for asset in "${ASSETS[@]}"; do
    CMD="$CMD $asset"
done
CMD="$CMD --clobber"

echo "Dry-run command:"
echo "  $CMD"
echo ""

if [ "$PUSH_MODE" -eq 1 ]; then
    echo "PUSH=1: Executing upload..."
    mkdir -p "$RELEASE_DIR"

    # Create release if not exists
    if ! gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        echo "Creating release $TAG..."
        NOTES=$(cat <<EOF
OpenCode for Termux — $TAG

## Families
- **opencode**: Native bionic mainline (stable since 27/28). Zero glibc deps.
- **opencode-glibc**: Glibc wrapper (appendix, renamed).
- **opencode-compressed**: UPX-compressed variant.
- **opencode-glibc-standalone**: Single-version rollback (coexists with opencode).

## Installation
See docs/dual-track-install.md
EOF
)
        gh release create "$TAG" --repo "$REPO_SLUG" --prerelease \
            --title "$TAG" --notes "$NOTES" || { echo "Error: release create failed"; exit 1; }
    fi

    # Upload assets
    upload_failed=0
    for asset in "${ASSETS[@]}"; do
        echo "Uploading $(basename "$asset")..."
        if ! gh release upload "$TAG" "$asset" --repo "$REPO_SLUG" --clobber 2>&1; then
            upload_failed=1
        fi
    done

    if [ "$upload_failed" -ne 0 ]; then
        echo "Error: one or more uploads failed"
        exit 1
    fi
    echo "=== Done: https://github.com/$REPO_SLUG/releases/tag/$TAG ==="
else
    echo "Dry-run only. Set PUSH=1 to execute."
fi
