#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"

[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing OpenCode runtime"
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher"
	exit 1
}

# Version: use explicit VERSION if set, else read from runtime
if [[ -z "${VERSION:-}" && -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]]; then
	if ! VERSION="$("$STAGED_PREFIX/lib/opencode/runtime/opencode" --version)"; then
		echo "Error: staged runtime version check failed" >&2
		exit 1
	fi
fi
[[ -n "$VERSION" ]] || {
	echo "Error: unable to determine version" >&2
	exit 1
}

cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.opencode.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packing/pacman/PKGBUILD" "$TMP_PKGBUILD"
sed -i "s/^_pkgver=.*/_pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

# Runtime form: bun-elf (loader-wrapped) vs node-js (v2 GA). Inject depends.
RUNTIME_FORM="bun-elf"
if [[ -f "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] && ! file "$STAGED_PREFIX/lib/opencode/runtime/opencode" | grep -q 'ELF'; then
	RUNTIME_FORM="node-js"
fi
RUNTIME_DEPENDS="('glibc' 'openssl-glibc' 'bash' 'ncurses')"
if [[ "$RUNTIME_FORM" == "node-js" ]]; then
	RUNTIME_DEPENDS="('nodejs' 'bash')"
fi
sed -i "s/^depends=()/depends=$RUNTIME_DEPENDS/" "$TMP_PKGBUILD"


STAGED_PREFIX="$STAGED_PREFIX" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Pacman package created under: $ROOT_DIR/packing/pacman"
