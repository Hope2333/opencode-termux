#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${VERSION:-${1:-1.2.10}}"
ARCH="${ARCH:-aarch64}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

STAGED_DIR="${STAGED_DIR:-$ROOT_DIR/runtime}"
DEB_ROOT="$ROOT_DIR/packaging/dpkg/work"
OUT_DIR="$ROOT_DIR/packaging/dpkg"
OUT_FILE="$OUT_DIR/opencode_${VERSION}_${ARCH}.deb"

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found"
	exit 1
}
mkdir -p "$OUT_DIR"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN"
mkdir -p "$DEB_ROOT$PREFIX/bin"
mkdir -p "$DEB_ROOT$PREFIX/lib/opencode-termux"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

if [[ ! -d "$STAGED_DIR" ]] || [[ -z "$(ls -A "$STAGED_DIR" 2>/dev/null)" ]]; then
	echo "Error: OpenCode runtime not found in $STAGED_DIR"
	echo "Note: OpenCode requires NDK binary for Termux."
	echo "GitHub releases only provide glibc version."
	exit 1
fi

OPENCODE_BIN=""
for name in opencode code; do
	if [[ -f "$STAGED_DIR/$name" ]]; then
		OPENCODE_BIN="$STAGED_DIR/$name"
		break
	fi
done

if [[ -z "$OPENCODE_BIN" ]]; then
	echo "Error: OpenCode binary not found in $STAGED_DIR"
	ls -la "$STAGED_DIR"
	exit 1
fi

echo "Packaging OpenCode DEB v$VERSION"

install -m755 "$OPENCODE_BIN" "$DEB_ROOT$PREFIX/lib/opencode-termux/opencode"

if [[ -d "$STAGED_DIR/node_modules" ]]; then
	cp -r "$STAGED_DIR/node_modules" "$DEB_ROOT$PREFIX/lib/opencode-termux/"
fi

cat >"$DEB_ROOT$PREFIX/bin/opencode" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
exec "$PREFIX/lib/opencode-termux/opencode" "$@"
LAUNCHER
chmod 755 "$DEB_ROOT$PREFIX/bin/opencode"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode
Version: $VERSION
Architecture: $ARCH
Maintainer: Hope2333
Section: utils
Priority: optional
Description: OpenCode CLI for Termux (AI coding assistant)
Depends: nodejs, bash, ncurses
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode for Termux installed!"
echo "Usage: opencode --version"
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
