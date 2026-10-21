#!/data/data/com.termux/files/usr/bin/bash
# prepare-bionic-hdrfix.sh — regenerate the w7b hdrfix shadow-header dir.
#
# Why this exists: build-libopentui.sh (w7b native recipe) needs a shadow
# include dir whose headers have ARRAY-parameter nullability specifiers
# stripped. zig 0.16's translate-c (clang) rejects them outright:
#   error: nullability specifier cannot be applied to non-pointer type
#          'const struct timeval [2]'   (utimes/futimes/lutimes/futimesat,
#   socketpair, utimensat/futimens, regexec, getopt, erand48/jrand48/
#   lcong48/nrand48/seed48, getloadavg, pipe/pipe2)
# The dir used to live in $TMPDIR and was lost with it (press-v2.sh carried a
# "待 hdrfix 目录可复现后可切换到重建路线" note). This script makes the recipe
# self-contained: shadow copies of the affected headers, annotation stripped,
# nothing else touched.
#
# Usage:
#   prepare-bionic-hdrfix.sh [OUT_DIR] [SYSROOT_INCLUDE_DIR]
#     OUT_DIR               default ${TMPDIR:-/tmp}/w7b-hdrfix
#     SYSROOT_INCLUDE_DIR   default $PREFIX/include (Termux bionic headers)
#
# Idempotent: rewrites the shadow set from the current sysroot every run.
set -euo pipefail

OUT_DIR="${1:-${TMPDIR:-/tmp}/w7b-hdrfix}"
SYS_INC="${2:-${PREFIX:-/data/data/com.termux/files/usr}/include}"

[ -d "$SYS_INC" ] || { echo "sysroot include dir not found: $SYS_INC" >&2; exit 1; }

# Headers carrying nullability specifiers inside array brackets. Keep in sync
# with the sysroot: if a future Termux update adds a new one, translate-c will
# fail loudly and this list grows by that file.
# fix-tlsdesc-pipeline: ONLY the original w7b trio (task-w7b-build.log:
# "hdrfix shadow headers (sys/time.h sys/stat.h sys/socket.h array-nullability
# stripped)"). A wider set (regex.h / bits/getopt.h / stdlib.h / unistd.h) is
# an over-correction: with the plain-farm merge dir, the C/C++ compiles never
# reach this shadow (they resolve those headers through libcxx wrappers ->
# merge's bionic copies), but the C++ (yoga) TUs DO reach it, and a stripped
# <stdlib.h> there fails libc++'s cstdlib marker check ("<cstdlib> tried
# including <stdlib.h> but didn't find libc++'s <stdlib.h> header"). Minimal
# set = translate-c gets its strips, C/C++ builds never see them.
SHADOWED=(
  sys/socket.h
  sys/stat.h
  sys/time.h
)

mkdir -p "$OUT_DIR"
changed=0
for rel in "${SHADOWED[@]}"; do
  src="$SYS_INC/$rel"
  dst="$OUT_DIR/$rel"
  [ -f "$src" ] || { echo "missing sysroot header: $src" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  tmp="$dst.tmp.$$"
  # Strip ONLY nullability specifiers sitting inside array brackets:
  #   [_Nonnull 2] / [_Nullable 2] / [_Nonnull] / [_Nullable]  ->  [2] / []
  # Pointer nullability (foo* _Nullable) is valid and left untouched.
  sed -e 's/\[_Nonnull \([0-9]*\)\]/[\1]/g' \
      -e 's/\[_Nullable \([0-9]*\)\]/[\1]/g' \
      -e 's/\[_Nonnull\]/[]/g' \
      -e 's/\[_Nullable\]/[]/g' \
      "$src" > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$dst"
    changed=$((changed + 1))
  fi
done

# Sanity: no array-nullability may survive in the shadow set.
if grep -rn "\[[^]]*_Nullable\|\[[^]]*_Nonnull\|\[[^]]*_Null_unspecified" "$OUT_DIR" >/dev/null 2>&1; then
  echo "ERROR: array nullability survived in $OUT_DIR — extend SHADOWED/sed rules" >&2
  exit 1
fi

echo ">> hdrfix shadows ready: $OUT_DIR (${#SHADOWED[@]} headers, $changed rewritten)"
