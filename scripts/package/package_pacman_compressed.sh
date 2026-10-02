#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode1-compressed pacman provider (UPX-packed native variant).
#
# V2-era ruling: v1 family carries the opencode1* name (install binary
# bin/opencode1 + lib/opencode1) so v1 AND v2 can coexist; "opencode"
# belongs to v2 mainline. This package provides the versioned virtual name
# opencode1=<ver> and conflicts only with other v1 families
# (opencode1-native / opencode1-wrapper); no replaces=() vs v2 (variant).
#
# D1 ruling: three mutually exclusive providers — opencode (native mainline),
# opencode-wrapper (glibc appendix), opencode-compressed. This package provides
# the versioned virtual name opencode=<ver> and conflicts with BOTH other
# families; no replaces=() (variant, not upgrade).
#
# Input: the UPX-packed ELF produced by T3
#   artifacts/transplant/<ver>/opencode-native-revived-upx
#
# Family parameter (OCOMP_FAMILY): opencode1 (default, v1 family) or opencode
# (v2 compressed family). The v2 family renames the identity to
# opencode-compressed, occupies usr/bin/opencode + usr/lib/opencode, and
# provides/conflicts the virtual name opencode=<ver> (same v2 slot as the
# native mainline: mutually exclusive). Family-specific fields are rewritten
# into the temp PKGBUILD only for the v2 family, so the default (v1) output
# stays byte-identical (two-family coexistence).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAMILY="${OCOMP_FAMILY:-opencode1}"
case "$FAMILY" in
	opencode1 | opencode) ;;
	*) echo "Error: OCOMP_FAMILY must be 'opencode1' or 'opencode' (got: $FAMILY)" >&2; exit 1 ;;
esac
PKG_NAME="${FAMILY}-compressed"
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
COMPRESSED_BIN="${OPENCODE_COMPRESSED_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-revived-upx}"
[[ -x "$COMPRESSED_BIN" ]] || {
	echo "Error: missing compressed runtime $COMPRESSED_BIN (waiting on T3 upx output)" >&2
	exit 1
}
# Normalize to an absolute path BEFORE cd-ing into packing/pacman: makepkg's
# package() resolves OPENCODE_COMPRESSED_BIN from the makepkg cwd, so a
# relative path would fail there (T5 real-build finding).
COMPRESSED_BIN="$(readlink -f "$COMPRESSED_BIN")"

# Same T5-class fix for the crhandler shim: package() resolves it from the
# makepkg cwd, so a relative path would fail there.
OPENCODE_CRHANDLER_SO="$(readlink -f "${OPENCODE_CRHANDLER_SO:?OPENCODE_CRHANDLER_SO must point to libopencode-crhandler.so}")"

# pty splice assets (OPTIONAL, backward compatible): pass the splice dir to
# package() only when both files exist; otherwise PKGBUILD ships without and
# the launcher degrades gracefully (no BUN_PTY_LIB injection).
PTY_SPLICE_DIR="${OPENCODE_PTY_SPLICE_DIR:-$ROOT_DIR/tools/bun-pty-splice/dist}"
if [[ -f "$PTY_SPLICE_DIR/librust_pty_arm64_musl_patched.so" && -f "$PTY_SPLICE_DIR/shim.so" ]]; then
	OPENCODE_PTY_SPLICE_DIR="$(readlink -f "$PTY_SPLICE_DIR")"
	export OPENCODE_PTY_SPLICE_DIR
	echo "pty splice assets: shipping from $OPENCODE_PTY_SPLICE_DIR"
else
	unset OPENCODE_PTY_SPLICE_DIR || true
	echo "pty splice assets not found under $PTY_SPLICE_DIR — shipping without (launcher degrades gracefully)"
fi

# epoll compat shim (OPTIONAL, backward compatible, v1 family ONLY — v2
# output stays byte-identical): pass the shim path to package() only when it
# exists; otherwise PKGBUILD ships without and the launcher skips the
# LD_PRELOAD block. Built by tools/epoll-shim/build-android.sh.
EPOLL_SHIM="${OPENCODE_EPOLL_SHIM_SO:-$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so}"
if [[ "$FAMILY" == "opencode1" && -f "$EPOLL_SHIM" ]]; then
	OPENCODE_EPOLL_SHIM_SO="$(readlink -f "$EPOLL_SHIM")"
	export OPENCODE_EPOLL_SHIM_SO
	echo "epoll compat shim: shipping from $OPENCODE_EPOLL_SHIM_SO"
else
	unset OPENCODE_EPOLL_SHIM_SO || true
	echo "epoll compat shim not shipped (v2 family or asset missing at $EPOLL_SHIM)"
fi


cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode1-compressed.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.opencode1-compressed.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"
# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
printf "\nPKGEXT='.pkg.tar.gz'\n" >>"$TMP_MAKEPKG_CONF"
cp "$ROOT_DIR/packing/pacman/PKGBUILD.compressed" "$TMP_PKGBUILD"
# pkgname is family-derived for both families (opencode1-compressed by default).
sed -i "s/^pkgname=.*/pkgname=$PKG_NAME/" "$TMP_PKGBUILD"
if [[ "$FAMILY" == "opencode" ]]; then
	# v2 compressed family identity: provides/conflicts the v2 virtual name,
	# occupies bin/opencode + lib/opencode, ships the v2 launcher. These seds
	# are applied ONLY for the v2 family so the v1 template stays untouched.
	sed -i "s/^provides=.*/provides=(\"opencode=\$pkgver\")/" "$TMP_PKGBUILD"
	sed -i "s/^conflicts=.*/conflicts=('opencode' 'opencode-wrapper' 'opencode-wrapper-standalone')/" "$TMP_PKGBUILD"
	sed -i "s/^replaces=.*/replaces=()/" "$TMP_PKGBUILD"
	sed -i "s|scripts/opencode1-launcher.sh|scripts/opencode-launcher.sh|" "$TMP_PKGBUILD"
	sed -i "s|usr/lib/opencode1|usr/lib/opencode|g" "$TMP_PKGBUILD"
	sed -i "s|usr/bin/opencode1|usr/bin/opencode|g" "$TMP_PKGBUILD"
	sed -i "s/OpenCode1 compressed/OpenCode compressed/g" "$TMP_PKGBUILD"
	sed -i "s/opencode1 --version/opencode --version/g" "$TMP_PKGBUILD"
fi
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

OPENCODE_COMPRESSED_BIN="$COMPRESSED_BIN" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Compressed pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/"$PKG_NAME-"$VERSION"-"$PKGREL"-*.pkg.* 2>/dev/null || true)
if [[ -n "$BUILT_PKG" ]]; then
    DATA_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^data/' | head -1 || true)
    if [[ -n "$DATA_PAYLOAD" ]]; then
        echo "FATAL: regression guard triggered — found data/ payload path: $DATA_PAYLOAD" >&2
        echo "Ensure PKGBUILD stages to \$pkgdir/usr/ (relative), not \$pkgdir\$prefix." >&2
        exit 1
    fi
    echo "Regression guard: OK (no data/ payload paths)"
fi

# launcher guard (unconditional): the launcher is the ONLY supported entry —
# the UPX stub maps segments under /memfd:upx where DT_RUNPATH $ORIGIN
# resolution dies, so a direct runtime exec cannot find libopencode-crhandler.so.
if [[ -n "$BUILT_PKG" ]]; then
    # grep -q would SIGPIPE bsdtar mid-listing under pipefail (race, order
    # dependent) — consume full listing with a redirect instead.
    if ! bsdtar -tf "$BUILT_PKG" | grep -E "usr/bin/${FAMILY}\$" >/dev/null; then
        echo "FATAL: package does not ship the usr/bin/$FAMILY launcher (launcher-only contract)" >&2
        exit 1
    fi
    echo "launcher guard: OK (usr/bin/$FAMILY shipped)"
fi

# crhandler guard (unconditional): the package MUST contain the shim.
if [[ -n "$BUILT_PKG" ]]; then
    if ! bsdtar -tf "$BUILT_PKG" | grep -E 'usr/lib/(opencode|opencode1)/libopencode-crhandler.so' >/dev/null; then
        echo "FATAL: package does not ship libopencode-crhandler.so" >&2
        exit 1
    fi
    echo "crhandler guard: OK (shim shipped)"
fi

# epoll shim guard (conditional, v1 family): asserted only when the shim
# asset exists at build time (same optional contract the launcher injects by).
if [[ -n "$BUILT_PKG" && "$FAMILY" == "opencode1" && -f "${OPENCODE_EPOLL_SHIM_SO:-/nonexistent}" ]]; then
    if ! bsdtar -tf "$BUILT_PKG" | grep -E 'usr/lib/opencode1/libepoll-compat.so' >/dev/null; then
        echo "FATAL: package does not ship libepoll-compat.so" >&2
        exit 1
    fi
    echo "epoll shim guard: OK (shim shipped)"
fi
