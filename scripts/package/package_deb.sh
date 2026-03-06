#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
ARCH_DEB="${ARCH_DEB:-$(dpkg --print-architecture 2>/dev/null || echo aarch64)}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found"
	exit 1
}
[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing staged runtime"
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher"
	exit 1
}

VERSION="${VERSION:-$($STAGED_PREFIX/lib/opencode/runtime/opencode --version 2>/dev/null || echo 0.0.0)}"
DEB_ROOT="$ROOT_DIR/packaging/dpkg/work"
OUT_DIR="$ROOT_DIR/packaging/dpkg"
OUT_FILE="$OUT_DIR/opencode_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Description: OpenCode CLI for Termux
Depends: glibc, openssl-glibc, bash, ncurses
Suggests: glibc-runner
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode for Termux installed"
echo "Run: opencode --version"
echo "Optional fallback compatibility tools: pkg install glibc-runner"
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
