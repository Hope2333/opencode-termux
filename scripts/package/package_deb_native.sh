#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-native DEB provider (transplant revival line).
#
# This package provides the `opencode` command from the native Android
# runtime (artifacts/transplant/<ver>/opencode-native-revived). It is an
# ALTERNATIVE provider to the default-recommended glibc wrapper package
# (`opencode`): installing it replaces the glibc line via Conflicts/Replaces.
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 28
#   - headless only: `run` / `serve` work; TUI is broken (bun:ffi dlopen)

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
OUT_FILE="$OUT_DIR/opencode-native_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

install -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/bin/opencode"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode-native
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Depends:
Conflicts: opencode
Replaces: opencode
Provides: opencode
Description: OpenCode AI coding assistant for Termux (native Android line, EXPERIMENTAL)
 Alternative provider of the opencode command. Zero glibc runtime deps
 (pure Bionic), requires Android API >= 28. Headless only: run/serve work,
 TUI is broken. The default recommended provider is the glibc wrapper
 package "opencode" (full TUI); installing this package replaces it.
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode Native for Termux installed (EXPERIMENTAL)"
echo "Run: opencode --version"
echo "Scope: headless only (run/serve). TUI is broken on this line."
echo "Requires Android API >= 28; zero glibc runtime deps."
echo "Default recommended alternative: package 'opencode' (glibc wrapper line)."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "Native DEB package created: $OUT_FILE"
