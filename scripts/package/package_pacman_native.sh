#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-native pacman provider (transplant revival line).
#
# Provides the `opencode` command from artifacts/transplant/<ver>/opencode-native-revived.
# Stable mainline provider; conflicts with the glibc appendix package (`opencode-glibc`);
# conflicts with it (installing one replaces the other).
# Native constraints: zero glibc deps, Android API >= 28, full TUI (stable mainline since 27/28).

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
# task-tui-common-fix: prefer opencode-native-tui (post-TUI-swap product,
# seccomp-hardened) with revived as fallback; OPENCODE_NATIVE_BIN still wins.
NATIVE_BIN="${OPENCODE_NATIVE_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-tui}"
[[ -x "$NATIVE_BIN" ]] || NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
[[ -x "$NATIVE_BIN" ]] || {
	echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
	exit 1
}

cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode-native.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.opencode-native.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packing/pacman/PKGBUILD.native" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

OPENCODE_NATIVE_BIN="$NATIVE_BIN" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Native pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/opencode-${VERSION}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
if [[ -n "$BUILT_PKG" ]]; then
    DATA_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^data/.*/(bin|lib)/' | head -1 || true)
    if [[ -n "$DATA_PAYLOAD" ]]; then
        echo "FATAL: regression guard triggered — found data/ payload path: $DATA_PAYLOAD" >&2
        echo "Ensure PKGBUILD stages to \$pkgdir/usr/ (relative), not \$pkgdir\$prefix." >&2
        exit 1
    fi
    echo "Regression guard: OK (no data/ payload paths)"
fi
