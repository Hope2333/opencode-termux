#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"

[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
  echo "Error: missing staged runtime"
  exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
  echo "Error: missing staged launcher"
  exit 1
}

cd "$ROOT_DIR/packaging/pacman"
TMP_MAKEPKG_CONF="$ROOT_DIR/packaging/pacman/.makepkg-opencode.conf"
cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >> "$TMP_MAKEPKG_CONF"
STAGED_PREFIX="$STAGED_PREFIX" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm
rm -f "$TMP_MAKEPKG_CONF"

echo "Pacman package created under: $ROOT_DIR/packaging/pacman"
