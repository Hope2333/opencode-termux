#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode DEB provider (transplant revival line, native mainline).
#
# This package IS the plain `opencode` name (inherited by the native mainline
# per the 27/28 package-rename decision). Built from
# artifacts/transplant/<ver>/opencode-native-revived; conflicts with the glibc
# appendix package (opencode-glibc) and the compressed transitional package
# (opencode-compressed): installing one replaces the other.
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 28
#   - full TUI via bionic libopentui.so (W10a deep smoke 5/5); zero glibc runtime deps

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found" >&2
	exit 1
}
if [[ -z "${ARCH_DEB:-}" ]]; then
	ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo aarch64)"
fi

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
NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
[[ -x "$NATIVE_BIN" ]] || {
	echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
	exit 1
}

DEB_ROOT="$ROOT_DIR/packing/dpkg-native/work"
OUT_DIR="$ROOT_DIR/packing/dpkg-native"
OUT_FILE="$OUT_DIR/opencode_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

install -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/bin/opencode"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Depends:
Conflicts: opencode-glibc, opencode-compressed
Description: OpenCode native bionic mainline (stable since 27/28). Full TUI via bionic libopentui.so (W10a deep smoke 5/5). Zero glibc dependencies.
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode Native for Termux installed (stable mainline since 27/28)"
echo "Run: opencode --version"
echo "Scope: full TUI via bionic libopentui.so (W10a deep smoke 5/5). Zero glibc runtime deps."
echo "Requires Android API >= 28; zero glibc runtime deps."
echo "The glibc wrapper line is now the appendix (renamed opencode-glibc); native is the stable mainline."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "Native DEB package created: $OUT_FILE"
