#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_deb_standalone.sh — build the opencode-glibc-standalone DEB
# Pure-addition standalone package: frozen single version for rollback only.
# Coexists with `opencode` (native) and `opencode-glibc` (no Conflicts on the
# literal name `opencode`). Uses an independent work dir and control template.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix-standalone}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
CONTROL_TEMPLATE="$ROOT_DIR/packing/deb-standalone/DEBIAN/control"

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
# Standalone staged prefix must use the independent lib prefix.
[[ -x "$STAGED_PREFIX/lib/opencode-glibc/runtime/opencode" ]] || {
	echo "Error: missing standalone staged runtime" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode-glibc" ]] || {
	echo "Error: missing standalone staged launcher" >&2
	exit 1
}

# Version: use explicit VERSION if set, else read from the staged runtime.
if [[ -z "${VERSION:-}" ]]; then
	if ! VERSION="$("$STAGED_PREFIX/lib/opencode-glibc/runtime/opencode" --version)"; then
		echo "Error: staged runtime version check failed" >&2
		exit 1
	fi
fi
[[ -n "$VERSION" ]] || {
	echo "Error: staged runtime returned an empty version" >&2
	exit 1
}

DEB_ROOT="$ROOT_DIR/packing/dpkg-standalone/work"
OUT_DIR="$ROOT_DIR/packing/dpkg-standalone"
OUT_FILE="$OUT_DIR/opencode-glibc-standalone_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

# Ensure the standalone launcher is present (source of truth at repo bin/).
mkdir -p "$DEB_ROOT$PREFIX/bin"
cp "$ROOT_DIR/bin/opencode-glibc" "$DEB_ROOT$PREFIX/bin/opencode-glibc"
chmod 755 "$DEB_ROOT$PREFIX/bin/opencode-glibc"

# Render control from template, substituting version/architecture.
sed -e "s/\${OPENCODE_VERSION}/$VERSION/g" \
    -e "s/\${ARCHITECTURE}/$ARCH_DEB/g" \
    "$CONTROL_TEMPLATE" >"$DEB_ROOT/DEBIAN/control"
chmod 644 "$DEB_ROOT/DEBIAN/control"

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
