#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"

[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing staged runtime"
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher"
	exit 1
}

VERSION="${VERSION:-$($STAGED_PREFIX/lib/opencode/runtime/opencode --version 2>/dev/null || true)}"
[[ -n "$VERSION" ]] || {
	echo "Error: unable to determine version from staged runtime"
	exit 1
}

cd "$ROOT_DIR/packaging/pacman"
rm -rf "$ROOT_DIR/packaging/pacman/pkg" "$ROOT_DIR/packaging/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packaging/pacman/.makepkg-opencode.conf"
TMP_PKGBUILD="$ROOT_DIR/packaging/pacman/.PKGBUILD.opencode.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packaging/pacman/PKGBUILD" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

STAGED_PREFIX="$STAGED_PREFIX" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Pacman package created under: $ROOT_DIR/packaging/pacman"
