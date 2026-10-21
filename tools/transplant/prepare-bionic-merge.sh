#!/data/data/com.termux/files/usr/bin/bash
# prepare-bionic-merge.sh — regenerate the w7b hdrfix-merge include dir.
#
# Why this exists: build-libopentui.sh (w7b native recipe) wires
# HDRFIX_MERGE_DIR as the libc.txt `include_dir`. That dir must carry the FULL
# bionic header set (libc++'s C-header wrappers `#include_next` into it for the
# real declarations) PLUS the kernel UAPI headers that live outside the sysroot
# top level (bionic's <errno.h> -> <linux/errno.h> -> <asm/errno.h> only
# resolves through the per-arch include dir; without it libc++'s own build
# dies with "asm/errno.h file not found"). The dir used to live in $TMPDIR and
# was lost with it (press-v3.sh carried a "待 hdrfix 目录可复现" note). This
# script makes the recipe self-contained.
#
# Construction (reconstructs the lost dir — "asm symlink via w7b-hdrfix-merge",
# task-w7b-build.log key enabler 3):
#   * every entry of the sysroot include dir is symlinked in (files + dirs)
#   * `asm`         -> <sysroot>/include/<triple>/asm     (per-arch kernel UAPI)
#   * `asm-generic` -> <sysroot>/include/asm-generic
#
# Deliberately a PLAIN farm (fix-tlsdesc-pipeline): do NOT re-link libc++'s
# C-header wrappers (stdlib.h/string.h/math.h/...) here. zig's own libcxx
# include dir already wins the search; a second copy in this dir breaks the C
# compiles (the wrappers' `#include <__config>` is C++-only, and the
# include_next/guard dance then loses bionic's <math.h> -> pow/exp undeclared).
#
# Usage:
#   prepare-bionic-merge.sh [OUT_DIR] [SYSROOT_INCLUDE_DIR] [TRIPLE]
#     OUT_DIR               default ${TMPDIR:-/tmp}/w7b-hdrfix-merge
#     SYSROOT_INCLUDE_DIR   default $PREFIX/include (Termux bionic headers)
#     TRIPLE                default aarch64-linux-android
#
# Idempotent: rebuilds the symlink farm from the current sysroot every run.
set -euo pipefail

OUT_DIR="${1:-${TMPDIR:-/tmp}/w7b-hdrfix-merge}"
SYS_INC="${2:-${PREFIX:-/data/data/com.termux/files/usr}/include}"
TRIPLE="${3:-aarch64-linux-android}"

[ -d "$SYS_INC" ] || { echo "sysroot include dir not found: $SYS_INC" >&2; exit 1; }
[ -d "$SYS_INC/$TRIPLE/asm" ] || { echo "per-arch kernel UAPI dir missing: $SYS_INC/$TRIPLE/asm" >&2; exit 1; }
[ -d "$SYS_INC/asm-generic" ] || { echo "asm-generic dir missing: $SYS_INC/asm-generic" >&2; exit 1; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# 1. full sysroot header set (top level; subdirs resolve through their symlinks)
for e in "$SYS_INC"/* "$SYS_INC"/.[!.]*; do
  [ -e "$e" ] || continue
  ln -s "$e" "$OUT_DIR/$(basename "$e")"
done

# 2. kernel UAPI: bionic's errno.h &co include <asm/...> which only exists
#    under the per-arch include dir — surface it at the merge top level.
ln -s "$SYS_INC/$TRIPLE/asm" "$OUT_DIR/asm"
ln -s "$SYS_INC/asm-generic" "$OUT_DIR/asm-generic"

# Sanity: the farm must resolve the headers libc++'s build include_next's into.
for probe in stdlib.h string.h math.h errno.h asm/errno.h asm-generic/errno.h; do
  [ -e "$OUT_DIR/$probe" ] || { echo "ERROR: merge farm missing $probe" >&2; exit 1; }
done

echo ">> hdrfix-merge farm ready: $OUT_DIR ($(ls "$OUT_DIR" | wc -l) entries, sysroot=$SYS_INC triple=$TRIPLE)"
