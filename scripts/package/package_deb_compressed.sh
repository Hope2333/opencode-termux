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
# placed bin-direct at usr/bin/<family> (no wrapper, zero glibc deps).
#
# Family parameter (OCOMP_FAMILY): opencode1 (default, v1 family) or opencode
# (v2 compressed family). The v2 family renames the identity to
# opencode-compressed, occupies usr/bin/opencode + lib/opencode, provides/
# conflicts the virtual name opencode=<ver> (same v2 slot as the native
# mainline: mutually exclusive), and drops the v1-only XDG migration. Both
# families can be built from this one script (two-family coexistence).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAMILY="${OCOMP_FAMILY:-opencode1}"
case "$FAMILY" in
	opencode1 | opencode) ;;
	*) echo "Error: OCOMP_FAMILY must be 'opencode1' or 'opencode' (got: $FAMILY)" >&2; exit 1 ;;
esac
PKG_NAME="${FAMILY}-compressed"
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
OUT_FILE="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

[[ -f "$ROOT_DIR/scripts/${FAMILY}-launcher.sh" ]] || {
	echo "Error: scripts/${FAMILY}-launcher.sh missing (${FAMILY} launcher source)" >&2; exit 1; }
# Layered: UPX runtime under lib/<family>/runtime/ + launcher at bin/<family>
# (shim stays lib/<family>/ — launcher LD covers both roots)
install -D -m755 "$COMPRESSED_BIN" "$DEB_ROOT$PREFIX/lib/$FAMILY/runtime/opencode"
install -D -m755 "$ROOT_DIR/scripts/${FAMILY}-launcher.sh" "$DEB_ROOT$PREFIX/bin/$FAMILY"

# crhandler shim (REQUIRED, unconditional): the compressed input is always the
# hardened native runtime whose DT_NEEDED libopencode-crhandler.so resolves via
# DT_RUNPATH $ORIGIN/../lib/opencode. UPX compression hides the DT_NEEDED string
# from grep, so detection-by-grep is impossible — the shim ships unconditionally.
SHIM_SO="${OPENCODE_CRHANDLER_SO:-}"
[[ -n "$SHIM_SO" && -f "$SHIM_SO" ]] || {
	echo "FATAL: OPENCODE_CRHANDLER_SO unset or missing — the compressed family always ships libopencode-crhandler.so" >&2
	exit 1
}
install -D -m755 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/$FAMILY/libopencode-crhandler.so"

# pty splice assets (OPTIONAL, backward compatible): patched musl librust_pty +
# bionic shim built by tools/bun-pty-splice/build-splice.sh. When present they
# ship under lib/<family>/pty/ and the launcher injects BUN_PTY_LIB (see
# scripts/*-launcher.sh); when absent the package is built exactly as
# before and nothing in the runtime/launcher path changes.
PTY_SPLICE_DIR="${OPENCODE_PTY_SPLICE_DIR:-$ROOT_DIR/tools/bun-pty-splice/dist}"
if [[ -f "$PTY_SPLICE_DIR/librust_pty_arm64_musl_patched.so" && -f "$PTY_SPLICE_DIR/shim.so" ]]; then
	install -D -m755 "$PTY_SPLICE_DIR/librust_pty_arm64_musl_patched.so" \
		"$DEB_ROOT$PREFIX/lib/$FAMILY/pty/librust_pty_arm64_musl_patched.so"
	install -D -m755 "$PTY_SPLICE_DIR/shim.so" "$DEB_ROOT$PREFIX/lib/$FAMILY/pty/shim.so"
	echo "Packaged pty splice assets (BUN_PTY_LIB) from $PTY_SPLICE_DIR"
	else
		echo "pty splice assets not found under $PTY_SPLICE_DIR — shipping without (launcher degrades gracefully)"
fi

# epoll compat shim (OPTIONAL, backward compatible, v1 family ONLY — the v2
# family output stays byte-identical): bionic LD_PRELOAD shim translating
# epoll_pwait2(441) -> epoll_pwait for pre-#32490 bun builds (v1.4.0
# 34cbb9a40). Fixes the TUI crash on kernels < 5.1 (oscar 3.18.140). Built
# by tools/epoll-shim/build-android.sh; the launcher injects LD_PRELOAD only
# when the asset exists.
EPOLL_SHIM="${OPENCODE_EPOLL_SHIM_SO:-$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so}"
if [[ "$FAMILY" == "opencode1" && -f "$EPOLL_SHIM" ]]; then
	install -D -m755 "$EPOLL_SHIM" "$DEB_ROOT$PREFIX/lib/$FAMILY/libepoll-compat.so"
	echo "Packaged epoll compat shim (LD_PRELOAD) from $EPOLL_SHIM"
else
	echo "epoll compat shim not shipped (v2 family or asset missing at $EPOLL_SHIM)"
fi

# Field order matters (B1 lesson): Conflicts MUST precede Description or it
# gets swallowed into the description text (illegal field order).
if [[ "$FAMILY" == "opencode1" ]]; then
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
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
else
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION${DEB_REV:-}
Section: utils
Priority: optional
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Depends:
Provides: opencode (= $VERSION)
Conflicts: opencode, opencode-wrapper, opencode-wrapper-standalone
Description: OpenCode compressed variant (v2 family, UPX-packed bionic runtime)
 v2-family UPX-packed variant of the native bionic ELF. Zero glibc
 dependencies, Android API >= 28, bin-direct (no wrapper). Occupies the
 v2 slot (bin/opencode + lib/opencode, shared plain XDG roots as the same
 generation) and is mutually exclusive with the v2 native mainline; no
 Replaces by design - installing this variant never silently displaces
 a provider's user data.
EOF
fi

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

if [[ "$FAMILY" == "opencode1" ]]; then
cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
# v1 compressed (opencode1) install hook — auto-migrate pre-v2-era config once.
CFG_DIR="$(printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode")"
echo "OpenCode1 compressed variant installed (UPX-packed v1 bionic runtime; coexists with v2 opencode)"
echo "Run: opencode1 --version"
echo "Runtime is UPX-packed: invoke via the opencode1 launcher only (direct runtime exec cannot resolve libs under memfd)."
# Feature detection FIRST (v12.2): `check` prints the detected state and
# exits 0 when every skip condition is met (already isolated / no v1-era
# data / plugins clean) — only then does isolate run, and unsilenced so the
# operator sees detected-state and every action taken. No blind migration.
if [ -e "$CFG_DIR" ] && command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
  if migrate-to-opencode1.sh check; then
    echo "Feature check: nothing to migrate — skipped (already isolated / no v1-era data / plugins clean)."
  elif migrate-to-opencode1.sh isolate; then
    echo "Migrated: v1 config now under *opencode1 dirs (see detected-state above)."
  else
    echo "Migration not completed (see detected-state above); data left untouched."
  fi
else
  echo "No legacy v1 config found (or migrate helper absent); nothing to migrate."
fi
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
# v12.0: ship the migration helper the postinst branch calls (compressed is v1-only)
install -m755 "$ROOT_DIR/scripts/migrate-to-opencode1.sh" "$DEB_ROOT$PREFIX/bin/migrate-to-opencode1.sh"
echo "Packaged migrate-to-opencode1.sh (v1 migration helper)"
else
cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
# v2 compressed (opencode-compressed) install hook — same generation as the
# v2 native mainline: plain XDG roots, no config migration, no re-rooting.
echo "OpenCode compressed variant installed (UPX-packed v2 bionic runtime; mutually exclusive with the v2 native mainline)"
echo "Run: opencode --version"
echo "Runtime is UPX-packed: invoke via the opencode launcher only (direct runtime exec cannot resolve libs under memfd)."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
fi

# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
dpkg-deb --build -Zgzip -z6 "$DEB_ROOT" "$OUT_FILE"
echo "Compressed DEB package created: $OUT_FILE"

# crhandler guard (unconditional): the deb MUST contain the shim.
# NOTE: grep without -q (redirect instead) — grep -q exits on first match and
# SIGPIPEs dpkg-deb's tar mid-listing, which under pipefail fails the guard
# spuriously (enumeration-order dependent race).
dpkg-deb -c "$OUT_FILE" | grep "lib/$FAMILY/libopencode-crhandler.so" >/dev/null || {
	echo "FATAL: deb does not ship lib/$FAMILY/libopencode-crhandler.so" >&2
	exit 1
}
echo "crhandler guard: OK (shim shipped)"

# launcher guard (unconditional): the launcher is the ONLY supported entry —
# the UPX stub maps segments under /memfd:upx where DT_RUNPATH $ORIGIN
# resolution dies, so a direct runtime exec cannot find libopencode-crhandler.so.
dpkg-deb -c "$OUT_FILE" | grep -E "bin/${FAMILY}\$" >/dev/null || {
	echo "FATAL: deb does not ship the bin/$FAMILY launcher (launcher-only contract)" >&2
	exit 1
}
echo "launcher guard: OK (bin/$FAMILY shipped)"

# epoll shim guard (conditional, v1 family): asserted only when the shim
# asset exists at build time (same optional contract the launcher injects by).
if [[ "$FAMILY" == "opencode1" && -f "$EPOLL_SHIM" ]]; then
	dpkg-deb -c "$OUT_FILE" | grep "lib/$FAMILY/libepoll-compat.so" >/dev/null || {
		echo "FATAL: deb does not ship lib/$FAMILY/libepoll-compat.so" >&2
		exit 1
	}
	echo "epoll shim guard: OK (shim shipped)"
fi
