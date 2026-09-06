#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-compressed pacman provider (UPX-packed native variant).
#
# D1 ruling: three mutually exclusive providers — opencode (native mainline),
# opencode-glibc (glibc appendix), opencode-compressed. This package provides
# the versioned virtual name opencode=<ver> and conflicts with BOTH other
# families; no replaces=() (variant, not upgrade).
#
# Input: the UPX-packed ELF produced by T3
#   artifacts/transplant/<ver>/opencode-native-revived-upx

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

command -v makepkg >/dev/null 2>&1 || {
	echo "Error: makepkg not found" >&2
	exit 1
}

# Version: explicit VERSION wins, else resolve the single transplant build.
if [[ -z "${VERSION:-}" ]]; then
	shopt -s nullglob
	_builds=("$TRANSPLANT_ROOT"/*)
	shopt -u nullglob
	if [[ ${#_builds[@]} -eq 0 ]]; then
		echo "Error: no transplant builds under $TRANSPLANT_ROOT (run: make transplant VER=<x>)" >&2
		exit 1
	fi
	if [[ ${#_builds[@]} -gt 1 ]]; then
		echo "Error: multiple transplant builds found; set VERSION=<x> explicitly:" >&2
		printf '  %s\n' "${_builds[@]}" >&2
		exit 1
	fi
	VERSION="$(basename "${_builds[0]}")"
fi
COMPRESSED_BIN="${OPENCODE_COMPRESSED_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-revived-upx}"
[[ -x "$COMPRESSED_BIN" ]] || {
	echo "Error: missing compressed runtime $COMPRESSED_BIN (waiting on T3 upx output)" >&2
	exit 1
}
# Normalize to an absolute path BEFORE cd-ing into packing/pacman: makepkg's
# package() resolves OPENCODE_COMPRESSED_BIN from the makepkg cwd, so a
# relative path would fail there (T5 real-build finding).
COMPRESSED_BIN="$(readlink -f "$COMPRESSED_BIN")"

cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode-compressed.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.opencode-compressed.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"
# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
printf "\nPKGEXT='.pkg.tar.gz'\n" >>"$TMP_MAKEPKG_CONF"
cp "$ROOT_DIR/packing/pacman/PKGBUILD.compressed" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

OPENCODE_COMPRESSED_BIN="$COMPRESSED_BIN" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Compressed pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/"opencode-compressed-"$VERSION"-"$PKGREL"-*.pkg.* 2>/dev/null || true)
if [[ -n "$BUILT_PKG" ]]; then
    DATA_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^data/' | head -1 || true)
    if [[ -n "$DATA_PAYLOAD" ]]; then
        echo "FATAL: regression guard triggered — found data/ payload path: $DATA_PAYLOAD" >&2
        echo "Ensure PKGBUILD stages to \$pkgdir/usr/ (relative), not \$pkgdir\$prefix." >&2
        exit 1
    fi
    echo "Regression guard: OK (no data/ payload paths)"
fi

# crhandler guard (unconditional): the package MUST contain the shim.
if [[ -n "$BUILT_PKG" ]]; then
    if ! bsdtar -tf "$BUILT_PKG" | grep -q 'usr/lib/opencode/libopencode-crhandler.so'; then
        echo "FATAL: package does not ship libopencode-crhandler.so" >&2
        exit 1
    fi
    echo "crhandler guard: OK (shim shipped)"
fi
