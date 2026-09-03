#!/usr/bin/env bash
# sha-stage.sh — Regenerate SHA256SUMS-prebatch.txt from packing/
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUMS_FILE="$REPO/packing/SHA256SUMS-prebatch.txt"

echo "Regenerating SHA256SUMS-prebatch.txt..."
> "$SUMS_FILE"

# Glibc packages
for f in "$REPO/packing/dpkg/opencode-glibc_"*.deb \
         "$REPO/packing/pacman/opencode-glibc-"*.pkg.*; do
    [ -f "$f" ] && sha256sum "$f" >> "$SUMS_FILE"
done

# Native packages
for f in "$REPO/packing/dpkg-native/opencode_"*.deb \
         "$REPO/packing/pacman/opencode-"*.pkg.*; do
    [ -f "$f" ] && sha256sum "$f" >> "$SUMS_FILE"
done

# Standalone packages (if present)
for f in "$REPO/packing/dpkg-standalone/opencode-glibc-standalone_"*.deb \
         "$REPO/packing/pacman/opencode-glibc-standalone-"*.pkg.*; do
    [ -f "$f" ] && sha256sum "$f" >> "$SUMS_FILE"
done

ENTRIES=$(wc -l < "$SUMS_FILE")
echo "SHA256SUMS-prebatch.txt: $ENTRIES entries"
cat "$SUMS_FILE"
