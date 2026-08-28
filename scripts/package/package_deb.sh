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
OUT_FILE="$OUT_DIR/opencode-glibc_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode-glibc
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Replaces: opencode
Breaks: opencode (<< $VERSION)
Conflicts: opencode
Description: OpenCode AI coding assistant for Termux (glibc appendix, renamed opencode-glibc)
 Alternative provider: opencode-native (stable mainline since 27/28, full TUI).
Depends: bash, ncurses
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode for Termux installed"
echo "Run: opencode --version"
echo "Runtime: glibc (bun-termux-loader wrapped)"
echo "Provider: glibc appendix (renamed opencode-glibc); alternative: opencode-native (stable mainline since 27/28)"
HOOK_RUNNER="/data/data/com.termux/files/usr/lib/opencode/tools/run-system-skills.sh"
if [[ -x "$HOOK_RUNNER" ]]; then
  OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 "$HOOK_RUNNER" post_install || true
fi
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

cat >"$DEB_ROOT/DEBIAN/prerm" <<'PRERM'
#!/data/data/com.termux/files/usr/bin/bash
set -e
HOOK_RUNNER="/data/data/com.termux/files/usr/lib/opencode/tools/run-system-skills.sh"
if [[ -x "$HOOK_RUNNER" ]]; then
  OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 "$HOOK_RUNNER" pre_remove || true
fi
exit 0
PRERM
chmod 755 "$DEB_ROOT/DEBIAN/prerm"

cat >"$DEB_ROOT/DEBIAN/postrm" <<'POSTRM'
#!/data/data/com.termux/files/usr/bin/bash
set -e
HOOK_RUNNER="/data/data/com.termux/files/usr/lib/opencode/tools/run-system-skills.sh"
if [[ -x "$HOOK_RUNNER" ]]; then
  OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 "$HOOK_RUNNER" post_remove || true
fi
exit 0
POSTRM
chmod 755 "$DEB_ROOT/DEBIAN/postrm"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
