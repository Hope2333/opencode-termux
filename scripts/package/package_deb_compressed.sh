#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode1-compressed DEB (UPX-packed variant of the v1 native line).
#
# V2-era ruling: v1 family uses the opencode1* name and installs
# bin/opencode1 + lib/opencode1 so v1 AND v2 (mainline) can coexist.
# Provides: opencode1 (= version); Conflicts only with other v1 families.
# Deliberately no Replaces vs v2: compressed variant is an alternative.
#
# Control is generated from the heredoc below (B1 lesson: the packing/deb*/
# DEBIAN/control template files are orphans; the script heredoc is the true
# source). packing/deb-compressed/DEBIAN/control is a reference copy only.
#
# Input: the UPX-packed ELF produced by T3
#   artifacts/transplant/<ver>/opencode-native-revived-upx
# placed bin-direct at usr/bin/opencode (no wrapper, zero glibc deps).

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
COMPRESSED_BIN="${OPENCODE_COMPRESSED_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-revived-upx}"
[[ -x "$COMPRESSED_BIN" ]] || {
	echo "Error: missing compressed runtime $COMPRESSED_BIN (waiting on T3 upx output)" >&2
	exit 1
}

DEB_ROOT="$ROOT_DIR/packing/dpkg-compressed/work"
OUT_DIR="$ROOT_DIR/packing/dpkg-compressed"
OUT_FILE="$OUT_DIR/opencode1-compressed_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

[[ -f "$ROOT_DIR/scripts/opencode1-launcher.sh" ]] || {
	echo "Error: scripts/opencode1-launcher.sh missing (v1 launcher source)" >&2; exit 1; }
# v12.1 layered: UPX runtime under lib/opencode1/runtime/ + XDG-isolating
# launcher (shim stays lib/opencode1/ — launcher LD covers both roots)
install -D -m755 "$COMPRESSED_BIN" "$DEB_ROOT$PREFIX/lib/opencode1/runtime/opencode"
install -D -m755 "$ROOT_DIR/scripts/opencode1-launcher.sh" "$DEB_ROOT$PREFIX/bin/opencode1"

# crhandler shim (REQUIRED, unconditional): the compressed input is always the
# hardened native runtime whose DT_NEEDED libopencode-crhandler.so resolves via
# DT_RUNPATH $ORIGIN/../lib/opencode. UPX compression hides the DT_NEEDED string
# from grep, so detection-by-grep is impossible — the shim ships unconditionally.
SHIM_SO="${OPENCODE_CRHANDLER_SO:-}"
[[ -n "$SHIM_SO" && -f "$SHIM_SO" ]] || {
	echo "FATAL: OPENCODE_CRHANDLER_SO unset or missing — the compressed family always ships libopencode-crhandler.so" >&2
	exit 1
}
install -D -m755 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/opencode1/libopencode-crhandler.so"

# Field order matters (B1 lesson): Conflicts MUST precede Description or it
# gets swallowed into the description text (illegal field order).
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode1-compressed
Version: $VERSION${DEB_REV:-}
Section: utils
Priority: optional
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Depends:
Provides: opencode1 (= $VERSION)
Replaces: opencode-compressed (<< 2.0.0)
Conflicts: opencode1, opencode1-wrapper, opencode1-wrapper-standalone
Description: OpenCode1 compressed variant (v1 family, UPX-packed bionic runtime)
 v1-family UPX-packed variant of the native bionic ELF. Zero glibc
 dependencies, Android API >= 28, bin-direct (no wrapper). Coexists with
 v2 opencode (mainline) and other opencode1 variants; no Replaces by
 design - installing this variant never silently displaces a provider.
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
# v1 compressed (opencode1) install hook — auto-migrate pre-v2-era config once.
CFG_DIR="$(printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode")"
echo "OpenCode1 compressed variant installed (UPX-packed v1 bionic runtime; coexists with v2 opencode)"
echo "Run: opencode1 --version"
if [ -e "$CFG_DIR" ] && [ ! -e "${CFG_DIR}1" ] && command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
  echo "Detected pre-v2-era opencode config; migrating to ${CFG_DIR}1 ..."
  migrate-to-opencode1.sh isolate >/dev/null 2>&1 && echo "Migrated: v1 config now under *opencode1 dirs." || echo "Migration skipped (already isolated or no v1 data)."
else
  echo "No legacy v1 config found (or already isolated); nothing to migrate."
fi
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
# v12.0: ship the migration helper the postinst branch calls (compressed is v1-only)
install -m755 "$ROOT_DIR/scripts/migrate-to-opencode1.sh" "$DEB_ROOT$PREFIX/bin/migrate-to-opencode1.sh"
echo "Packaged migrate-to-opencode1.sh (v1 migration helper)"

# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
dpkg-deb --build -Zgzip -z6 "$DEB_ROOT" "$OUT_FILE"
echo "Compressed DEB package created: $OUT_FILE"

# crhandler guard (unconditional): the deb MUST contain the shim.
dpkg-deb -c "$OUT_FILE" | grep -q "lib/opencode1/libopencode-crhandler.so" || {
	echo "FATAL: deb does not ship libopencode1/libopencode-crhandler.so" >&2
	exit 1
}
echo "crhandler guard: OK (shim shipped)"
