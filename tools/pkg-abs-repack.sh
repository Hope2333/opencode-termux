#!/data/data/com.termux/files/usr/bin/bash
# pkg-abs-repack.sh — repack a pacman package from relative `usr/...` member
# paths to the termux-pacman absolute-path convention
# `data/data/com.termux/files/usr/...` (no leading slash), bumping pkgrel by 1.
#
# Why: packages built under RootDir=/data/data/com.termux/files embed relative
# `usr/...` members; on a standard termux-pacman machine (RootDir=/) they
# resolve to /usr and the transaction fails with "Partition / is mounted read
# only". Official termux-pacman repo packages embed `data/data/com.termux/
# files/usr/...` members (verified via pacman cache, e.g. ninja-1.13.2).
#
# Usage: pkg-abs-repack.sh <input.pkg.tar.gz|tar.xz> [output.pkg.tar.gz|tar.xz]
#   output defaults to input path with pkgrel incremented (per .PKGINFO).
#
# What is rewritten:
#   - tar members:   usr/...  -> data/data/com.termux/files/usr/...
#   - .PKGINFO/.BUILDINFO: pkgver rev bumped (+1), digests refreshed in .MTREE
#   - .MTREE:        ./usr... paths rewritten, meta-file size/sha256 recomputed
#   - .INSTALL:      NOT rewritten (verified: uses $PREFIX / command -v only);
#                    script aborts loudly if it ever contains usr/ references.

set -euo pipefail

ABS_PREFIX="data/data/com.termux/files"

usage() { echo "usage: $0 <input.pkg.tar.{gz,xz}> [output.pkg.tar.{gz,xz}]" >&2; exit 2; }

[ $# -ge 1 ] && [ $# -le 2 ] || usage
IN=$(readlink -f "$1")
[ -f "$IN" ] || { echo "input not found: $IN" >&2; exit 1; }

case "$IN" in
  *.pkg.tar.gz)  DECOMP="gzip -dc"; COMP="gzip -n";  EXT=".pkg.tar.gz" ;;
  *.pkg.tar.xz)  DECOMP="xz -dc";  COMP="xz -T0";   EXT=".pkg.tar.xz" ;;
  *) echo "unsupported extension: $IN" >&2; exit 1 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/pkgabs.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- 1. extract -------------------------------------------------------------
$DECOMP "$IN" | tar -xf - -C "$WORK"
cd "$WORK"

for meta in .PKGINFO .MTREE; do
  [ -f "$meta" ] || { echo "FATAL: $meta missing in $IN" >&2; exit 1; }
done

# --- 2. sanity: refuse if .INSTALL references usr/ paths --------------------
if [ -f .INSTALL ] && grep -nE '(^|[^/A-Za-z])usr/' .INSTALL >/dev/null; then
  echo "FATAL: .INSTALL contains usr/ path references; manual review required:" >&2
  grep -nE '(^|[^/A-Za-z])usr/' .INSTALL >&2
  exit 1
fi

# --- 3. bump pkgrel in .PKGINFO / .BUILDINFO --------------------------------
OLD_VER=$(sed -n 's/^pkgver = //p' .PKGINFO)
PKGNAME=$(sed -n 's/^pkgname = //p' .PKGINFO)
ARCH=$(sed -n 's/^arch = //p' .PKGINFO)
OLD_REV=${OLD_VER##*-}
BASE_VER=${OLD_VER%-*}
NEW_REV=$((OLD_REV + 1))
NEW_VER="${BASE_VER}-${NEW_REV}"

# keep original mtimes of meta files so .MTREE time= stays truthful
for meta in .PKGINFO .BUILDINFO .INSTALL; do
  [ -f "$meta" ] || continue
  T=$(gzip -dc .MTREE | awk -v m="$meta" '$1 == "./"m {print $2}')
  T=${T#time=}; T=${T%.*}
  sed -i "s/^pkgver = .*/pkgver = $NEW_VER/" "$meta"
  [ -n "$T" ] && touch -d "@$T" "$meta"
done

# --- 4. rewrite .MTREE paths + refresh meta digests --------------------------
# .MTREE is gzip-compressed inside the package tar: decompress first, edit
# plain text, re-compress with gzip -n (no timestamp) at the end.
gzip -dc .MTREE > .MTREE.plain && mv .MTREE.plain .MTREE

sed -i \
  -e 's|^\./usr |./'"$ABS_PREFIX"'/usr |' \
  -e 's|^\./usr/|./'"$ABS_PREFIX"'/usr/|' \
  .MTREE

for meta in .PKGINFO .BUILDINFO; do
  [ -f "$meta" ] || continue
  SUM=$(sha256sum "$meta" | cut -d' ' -f1)
  SZ=$(stat -c %s "$meta")
  sed -i -E "\|^\./${meta} |s|size=[0-9]+|size=$SZ|; \
             \|^\./${meta} |s|sha256digest=[0-9a-f]{64}|sha256digest=$SUM|" .MTREE
done

gzip -n .MTREE && mv .MTREE.gz .MTREE

# --- 5. restructure tree to absolute convention ------------------------------
[ -d usr ] || { echo "FATAL: no usr/ tree in $IN" >&2; exit 1; }
mkdir -p "$ABS_PREFIX"
mv usr "$ABS_PREFIX"/usr

# --- 6. repack ---------------------------------------------------------------
OUT=${2:-}
if [ -z "$OUT" ]; then
  OUT=$(dirname "$IN")/${PKGNAME}-${NEW_VER}-${ARCH}${EXT}
fi
OUT=$(readlink -f "$OUT")

# shellcheck disable=SC2086
tar -cf - .BUILDINFO .INSTALL .MTREE .PKGINFO "$ABS_PREFIX" | $COMP > "$OUT"

# --- 7. assertions -----------------------------------------------------------
fail() { echo "FATAL: $*" >&2; exit 1; }

# capture full listing first: grep -q would SIGPIPE tar and trip pipefail
MEMBERS=$($DECOMP "$OUT" | tar -tf -)

# 7a. zero relative usr/ members
if echo "$MEMBERS" | grep -qE '^usr/'; then
  fail "output still contains relative usr/ members: $OUT"
fi

# 7b. expected absolute members present
echo "$MEMBERS" | grep -qE "^${ABS_PREFIX}/usr/" \
  || fail "output missing ${ABS_PREFIX}/usr/ members"

# 7c. .PKGINFO round-trips with bumped pkgver
GOT=$($DECOMP "$OUT" | tar -xOf - .PKGINFO | sed -n 's/^pkgver = //p')
[ "$GOT" = "$NEW_VER" ] || fail "pkgver mismatch: got $GOT want $NEW_VER"

# 7d. every .MTREE file entry matches on-disk content (size + sha256)
MT=$(mktemp); $DECOMP "$OUT" | tar -xOf - .MTREE > "$MT"
CHECK_FAILED=0
while read -r path size sum; do
  F="./$path"
  [ -f "$F" ] || { echo "mtree lists missing file: $F" >&2; CHECK_FAILED=1; continue; }
  ONDISK=$(stat -c %s "$F")
  [ "$ONDISK" = "$size" ] || { echo "size mismatch: $F ($ONDISK != $size)" >&2; CHECK_FAILED=1; }
  ONSUM=$(sha256sum "$F" | cut -d' ' -f1)
  [ "$ONSUM" = "$sum" ] || { echo "sha256 mismatch: $F" >&2; CHECK_FAILED=1; }
done < <(gzip -dc "$MT" | awk '/sha256digest=/ {
  p=$1; sub(/^\.\//,"",p); size=""; sum="";
  for (i=2;i<=NF;i++) {
    if ($i ~ /^size=/)  { size=$i; sub(/^size=/,"",size) }
    if ($i ~ /^sha256digest=/) { sum=$i; sub(/^sha256digest=/,"",sum) }
  }
  if (size != "" && sum != "") print p, size, sum
}')
rm -f "$MT"
[ "$CHECK_FAILED" = "0" ] || fail ".MTREE verification failed"

echo "OK: $OUT"
echo "    pkgver $OLD_VER -> $NEW_VER"
echo "    members now under ${ABS_PREFIX}/usr/, .MTREE digests verified"
