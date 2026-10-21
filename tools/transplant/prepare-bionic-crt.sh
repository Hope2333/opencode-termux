#!/data/data/com.termux/files/usr/bin/bash
# prepare-bionic-crt.sh — regenerate the w7b bionic crt/lib glue dir.
#
# Why this exists: build-libopentui.sh (w7b native recipe) wires
# BIONIC_CRT_DIR as the libc.txt `crt_dir`. zig uses that single dir for BOTH
# the crt objects (crtbegin_so.o/crtend_so.o) AND the linker's -L search path
# (the libc.txt `lib_dir` field is ignored by zig 0.16), so the dir must also
# expose libc.so/libdl.so/libm.so for the final `-lm -lc -ldl` link. It used to
# live in $TMPDIR and was lost with it (task-w7b-build.log recorded a sibling
# stubs dir with exactly these libs). This script makes it reproducible:
#
#   * crt objects  -> Termux's NDK-built $PREFIX/lib/crt*.o (aarch64, Android 24)
#   * lib stubs    -> the platform bionic libs in /system/lib64 (libc/libdl/libm;
#                     pthread/rt are folded into libc on bionic 10+, matching
#                     build.zig's android branch which skips linkSystemLibrary)
#
# Usage:
#   prepare-bionic-crt.sh [OUT_DIR] [PREFIX_LIB_DIR] [PLATFORM_LIB64_DIR]
#     OUT_DIR             default ${TMPDIR:-/tmp}/w7b-bionic-lib
#     PREFIX_LIB_DIR      default $PREFIX/lib (Termux crt objects)
#     PLATFORM_LIB64_DIR  default /system/lib64 (bionic platform libs)
#
# Idempotent: rebuilds the symlink set from the current sources every run.
set -euo pipefail

OUT_DIR="${1:-${TMPDIR:-/tmp}/w7b-bionic-lib}"
PREFIX_LIB="${2:-${PREFIX:-/data/data/com.termux/files/usr}/lib}"
PLATFORM_LIB64="${3:-/system/lib64}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# crt objects (shared-library variants are what the .so link needs).
for o in crtbegin_so.o crtend_so.o crtbegin_dynamic.o crtbegin_static.o \
         crtend_android.o crt_pad_segment.o; do
  [ -f "$PREFIX_LIB/$o" ] || { echo "missing crt object: $PREFIX_LIB/$o" >&2; exit 1; }
  ln -s "$PREFIX_LIB/$o" "$OUT_DIR/$o"
done

# bionic platform libs for -lm/-lc/-dl.
for l in libc.so libdl.so libm.so; do
  [ -e "$PLATFORM_LIB64/$l" ] || { echo "missing platform lib: $PLATFORM_LIB64/$l" >&2; exit 1; }
  ln -s "$PLATFORM_LIB64/$l" "$OUT_DIR/$l"
done

# Sanity: every link input must resolve.
for probe in crtbegin_so.o crtend_so.o libc.so libdl.so libm.so; do
  [ -e "$OUT_DIR/$probe" ] || { echo "ERROR: crt glue dir missing $probe" >&2; exit 1; }
done

echo ">> bionic crt/lib glue ready: $OUT_DIR (crt=$PREFIX_LIB libs=$PLATFORM_LIB64)"
