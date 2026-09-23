#!/data/data/com.termux/files/usr/bin/bash
# package_wrapper_v2.sh — v2 wrapper family (opencode-wrapper) deb + pacman packer.
#
# Fixes the bg-era dual bug:
#   (1) payload leaked to $PREFIX/tmp/v2wrapper-stage/<ver>/... (not on PATH);
#   (2) all 13 versions wrapped the same 2.0.0 glibc source (input resolution
#       now lives in Makefile wrapper-native; this script PACKS the wrap output
#       after an exact-version gate).
#
# Control/PKGBUILD fields follow the archived verbatim decision artifacts:
#   $EV/old-wrapper-deb-control.txt
#   $EV/old-wrapper-pkginfo.txt
#
# Usage: package_wrapper_v2.sh <VER>   e.g. package_wrapper_v2.sh 2.0.5
set -euo pipefail

VER="${1:-${VERSION:-}}"
[ -n "$VER" ] || { echo "Usage: $0 <VER>   e.g. $0 2.0.5" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
EV="${EV:-$HOME/.omo/evidence/opencode-v2-port/rc2-rebuild}"
CTRL_TMPL="$EV/old-wrapper-deb-control.txt"
[ -f "$CTRL_TMPL" ] || { echo "FATAL: control template missing: $CTRL_TMPL" >&2; exit 1; }

WRAP="$ROOT/artifacts/wrapper/$VER/opencode-wrapper-$VER"
OUT_DEB="$ROOT/packing/dpkg/opencode-wrapper_${VER}_aarch64.deb"
OUT_PAC="$ROOT/packing/pacman/opencode-wrapper-${VER}-1-aarch64.pkg.tar.xz"
DEB_ROOT="$ROOT/packing/dpkg/work"         # shared v1 work dir (cleaned each run)
WORK="$ROOT/packing/pacman/.v2wrap-$VER"    # isolated pacman build dir per run

RT="$WORK/rt"   # isolated TMPDIR for binary smoke (glibc/loader .so extraction)
mkdir -p "$WORK" "$RT"
trap 'rm -rf "$WORK"' EXIT

# ---- gate 0: wrapped binary exists + exact version (self-verifying input) ----
[ -x "$WRAP" ] || { echo "FATAL: missing $WRAP (run: make wrapper-native VER=$VER)" >&2; exit 1; }
v="$(TMPDIR="$RT" timeout 20 "$WRAP" --version 2>&1 | grep -oE 'opencode v[0-9][0-9a-z.]*' | head -1 || true)"
[ "$v" = "opencode v$VER" ] || { echo "FATAL: version gate: want [opencode v$VER] got [$v]" >&2; exit 1; }
echo "gate ok: $v"

# ---- deb: payload MUST land at $PREFIX/bin/opencode (never usr/tmp) ----
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN"
install -D -m755 "$WRAP" "$DEB_ROOT$PREFIX/bin/opencode"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
{
  sed -e "s/^Version: .*/Version: $VER/" \
      -e "/^Installed-Size:/d" \
      -e "/^Breaks:/s/<< [0-9][0-9.]*/<< $VER/g" \
      "$CTRL_TMPL"
  echo "Installed-Size: $(du -sk "$DEB_ROOT" | cut -f1)"
} > "$DEB_ROOT/DEBIAN/control"
dpkg-deb --build "$DEB_ROOT" "$OUT_DEB" >/dev/null
dpkg-deb -c "$OUT_DEB" | grep -q "usr/tmp/" && {
  dpkg-deb -c "$OUT_DEB" >&2; echo "FATAL: deb payload leaks usr/tmp path" >&2; exit 1; }
dpkg-deb -c "$OUT_DEB" | grep -qE "\./?${PREFIX#/}/bin/opencode$" || {
  dpkg-deb -c "$OUT_DEB" >&2; echo "FATAL: deb payload not at ${PREFIX}/bin/opencode" >&2; exit 1; }

# ---- pacman: pkgname=opencode-wrapper, payload usr/bin/opencode (verbatim fields) ----
cat > "$WORK/PKGBUILD" <<PKGB
pkgname=opencode-wrapper
pkgver=$VER
pkgrel=1
pkgdesc='OpenCode AI coding assistant for Termux (wrapper appendix, renamed opencode-wrapper)'
arch=('aarch64')
url='https://github.com/anomalyco/opencode'
license=('MIT')
options=('!strip' '!debug' '!emptydirs')
replaces=('opencode-glibc')
conflicts=('opencode' 'opencode-compressed')
source=()
sha256sums=()

package() {
  install -D -m755 "$WRAP" "\$pkgdir/usr/bin/opencode"
}
PKGB
MCONF="$WORK/makepkg.conf"
cp "$PREFIX/etc/makepkg.conf" "$MCONF"
printf '\nPACKAGER=%q\n' "${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}" >> "$MCONF"
( cd "$WORK" && makepkg --config "$MCONF" -f --noconfirm -p PKGBUILD )
[ -f "$WORK/opencode-wrapper-$VER-1-aarch64.pkg.tar.xz" ] || {
  ls -la "$WORK" >&2; echo "FATAL: makepkg output missing" >&2; exit 1; }
mv -f "$WORK/opencode-wrapper-$VER-1-aarch64.pkg.tar.xz" "$OUT_PAC"
tar -tf "$OUT_PAC" | grep -qx "usr/bin/opencode" || {
  tar -tf "$OUT_PAC" >&2; echo "FATAL: pac missing usr/bin/opencode" >&2; exit 1; }
tar -tf "$OUT_PAC" | grep -qE '^data/' && {
  tar -tf "$OUT_PAC" >&2; echo "FATAL: pac has data/ prefix payload" >&2; exit 1; }

# ---- dual extract re-verify: run the PACKED binaries ----
T1="$(mktemp -d "$WORK/exdeb-XXXX")"
T2="$(mktemp -d "$WORK/expac-XXXX")"
dpkg-deb -x "$OUT_DEB" "$T1"
tar -xf "$OUT_PAC" -C "$T2"
for b in "$T1$PREFIX/bin/opencode" "$T2/usr/bin/opencode"; do
  ov="$(TMPDIR="$RT" timeout 20 "$b" --version 2>&1 | grep -oE 'opencode v[0-9][0-9a-z.]*' | head -1 || true)"
  [ "$ov" = "opencode v$VER" ] || { echo "FATAL: packed binary gate failed: $b → [$ov]" >&2; exit 1; }
done

sha256sum "$WRAP" "$OUT_DEB" "$OUT_PAC"
echo "PKG_WRAPPER_V2_OK $VER"
