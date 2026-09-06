#!/usr/bin/env bash
# push-stage.sh — Build gh release create command (dry-run by default)
# Usage: push-stage.sh TAG=Push260905 BATCH=prebatch[,compressed,push260905]
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
    echo "Usage: push-stage.sh TAG=PushYYMMDD BATCH=prebatch[,compressed,push260905]"
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

if echo "$BATCH" | grep -q "push260905"; then
    echo "Collecting push260905 assets..."
    for i in $(seq 15 27); do
        v="1.18.$i"
        for f in \
            "$REPO/packing/dpkg/opencode-glibc_${v}_aarch64.deb" \
            "$REPO/packing/dpkg-native/opencode_${v}_aarch64.deb" \
            "$REPO/packing/pacman/opencode-${v}-1-aarch64.pkg.tar.xz" \
            "$REPO/packing/pacman/opencode-glibc-${v}-1-aarch64.pkg.tar.xz"; do
            if [ ! -f "$f" ]; then
                echo "ERROR: missing expected file: $f" >&2
                exit 1
            fi
            ASSETS+=("$f") && echo "  $(basename "$f")"
        done
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
if echo "$BATCH" | grep -q "push260905"; then
    SUMS_FILE="$REPO/packing/SHA256SUMS.txt"
    SUMS_BASENAME="SHA256SUMS.txt"
    echo "Regenerating SHA256SUMS.txt..."
    (cd "$REPO/packing" && for f in "${ASSETS[@]}"; do sha256sum "$f" | sed 's|.*/||'; done > SHA256SUMS.txt.tmp && mv SHA256SUMS.txt.tmp SHA256SUMS.txt)
    ASSETS+=("$SUMS_FILE")
    echo "  $SUMS_BASENAME"
else
    SUMS_FILE="$REPO/packing/SHA256SUMS-prebatch.txt"
    SUMS_BASENAME="SHA256SUMS-prebatch.txt"
    if [ -f "$SUMS_FILE" ]; then
        ASSETS+=("$SUMS_FILE")
        echo "  $SUMS_BASENAME"
    fi
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

Supersedes Push260903 (demoted old batch). Compressed family assets arrive via the UPX fleet pipeline.

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
