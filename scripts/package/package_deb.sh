#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"

command -v dpkg >/dev/null 2>&1 || {
	echo "Error: dpkg not found" >&2
	exit 1
}
command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found" >&2
	exit 1
}
if [[ -z "${ARCH_DEB:-}" ]]; then
	ARCH_DEB="$(dpkg --print-architecture)"
fi
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing staged runtime" >&2
	exit 1
}

# Version: use explicit VERSION if set, else read from the staged runtime.
if [[ -z "${VERSION:-}" ]]; then
	if ! VERSION="$("$STAGED_PREFIX/lib/opencode/runtime/opencode" --version)"; then
		echo "Error: staged runtime version check failed" >&2
		exit 1
	fi
fi
[[ -n "$VERSION" ]] || {
	echo "Error: staged runtime returned an empty version" >&2
	exit 1
}
DEB_ROOT="$ROOT_DIR/packing/dpkg/work"
OUT_DIR="$ROOT_DIR/packing/dpkg"
OUT_FILE="$OUT_DIR/opencode1-wrapper_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
install -D -m755 "$STAGED_PREFIX/bin/opencode" "$DEB_ROOT$PREFIX/bin/opencode1"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode1-wrapper
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Breaks: opencode-wrapper (<< $VERSION), opencode1-glibc (<< $VERSION)
Conflicts: opencode (<< 2.0.0), opencode1-native, opencode1-compressed, opencode1-glibc
Replaces: opencode-wrapper (<< 2.0.0), opencode-glibc (<< 2.0.0), opencode1-glibc
Description: OpenCode AI coding assistant for Termux (v1 wrapper; installs as opencode1 alongside v2 opencode)
 Alternative provider: opencode1-native (stable mainline since 27/28, full TUI).
Depends: bash, ncurses
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
