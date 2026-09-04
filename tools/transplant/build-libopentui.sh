#!/usr/bin/env bash
#
# build-libopentui.sh — reproducible bionic build of libopentui.so
#
# Context: MiMo/opencode embed a glibc-built libopentui.so. On Android (bionic)
# that library cannot dlopen, so the main TUI hangs. This script rebuilds a
# *bionic* libopentui.so from OpenTUI 0.1.101 source using Zig 0.15.2 — run
# under the Termux glibc loader (Zig 0.15.2 itself is a glibc binary) but
# emitting an android/bionic ELF.
#
# Fallback policy (user decision 2026-08-30): when a prebuilt historical
# package cannot be located, use glibc Zig 0.15.x purely as a *build tool*
# (never run the resulting artifact via glibc) to produce the bionic lib.
#
# Hard-won requirements (do not "simplify" these away):
#   1. The OpenTUI build.zig must call `lib.linkLibC()` on the `addLibrary`
#      step AND the libc spec must define lib_dir + dynamic_linker. Without
#      these Zig emits an unresolved `getauxval`, and the .so fails to dlopen
#      on bionic (TUI still hangs).
#   2. uucode's host table-generator breaks under a global `--libc`, so the
#      prebuilt tables.zig (generated once without --libc) is reused via the
#      UUCODE_USE_PREBUILT_TABLES env switch (see build.zig patch).
#   3. Guard v2 (task-tui-common-fix, root cause: batch builds swapped a
#      pre-fix libopentui.so because the patch was never applied at the
#      common build layer): ALL patches under patches/opentui/*.patch are
#      applied to the source tree BEFORE building (idempotently), and the
#      built .so is SELF-VERIFIED — bufferDrawChar must contain the FFI
#      negative-coordinate guard pattern (@min 0x7fffffff clamp + saturating
#      add). A build without the guard fails loudly.
#
# Modes:
#   build-libopentui.sh              apply patches + build + verify + install
#   build-libopentui.sh --check <so> only verify the guard pattern in <so>
#                                    (exit 0 = guarded, 1 = missing/unguarded)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- configurable locations (override via env) ---------------------------------
OPENTUI_ZIG_DIR="${OPENTUI_ZIG_DIR:-/data/data/com.termux/files/home/develop/OpenTUI-0.1.101/packages/core/src/zig}"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/opentui}"
INSTALL_PATH="${INSTALL_PATH:-$REPO_ROOT/artifacts/transplant/opentui-bionic/libopentui.so}"
GLIBC_LD="${GLIBC_LD:-/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1}"
GLIBC_LIB="${GLIBC_LIB:-/data/data/com.termux/files/usr/glibc/lib}"
ZIG_BIN="${ZIG_BIN:-/data/data/com.termux/files/usr/tmp/zig-0.15.2/zig-aarch64-linux-0.15.2/zig}"
# Corrected bionic libc spec (MUST include lib_dir + dynamic_linker).
LIBC_SPEC="${LIBC_SPEC:-/data/data/com.termux/files/usr/tmp/w7b-libc.txt}"
CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
OUT_DIR="${OUT_DIR:-$OPENTUI_ZIG_DIR/lib/aarch64-linux-android}"
# MiMo embedded slot — incoming lib must be <= this after stripping.
MAX_SLOT="${MAX_SLOT:-4567704}"

# --- guard-pattern verification ------------------------------------------------
# The guard (patches/opentui/fix-drawchar-negative-coords.patch) compiles the
# @min(w/h, 0x7FFFFFFF) clamps + saturating adds inside isPointInScissor into:
#   mov wN, #0x7fffffff            (movn encoding)
#   csel wX, ..., vs               (saturating-add overflow select)
# inside the (inlined) bufferDrawChar text range. The unguarded build has
# neither (verified differentially on 1.18.27 batch vs crashfix v2 .so).
find_tool() { command -v "$1" >/dev/null 2>&1 && { echo "$1"; return 0; }; command -v "$2" >/dev/null 2>&1 && { echo "$2"; return 0; }; return 1; }

# Guard verification (task-tui-common-fix), single source of truth = the
# symbol-range scanner in swap_tui.py (inlining-agnostic: pattern location
# varies between inlined-into-bufferDrawChar and out-of-line builds; scanning
# all guard-owner symbol ranges discriminates guarded vs unguarded builds
# differentially: crashfix v2 clamp=4/csel=8, 1.18.27 batch 0/0).
guard_check() {
  local so="$1"
  python3 -c 'import sys; sys.path.insert(0, sys.argv[2] + "/tools/transplant"); from swap_tui import has_ffi_guard; sys.exit(0 if has_ffi_guard(open(sys.argv[1], "rb").read()) else 1)' "$so" "$REPO_ROOT"
}

# Behavioral gate: dlopen the built .so and hammer the guarded FFI
# entrypoints with hostile coords; a guarded .so survives, an unguarded one
# aborts with the production panic ("integer does not fit in destination
# type in lib.bufferDrawChar").
harness_check() {
  local so="$1"
  command -v clang >/dev/null 2>&1 || {
    echo ">> harness: clang not found, skipping behavioral gate (pattern scan already passed)" >&2
    return 0
  }
  local bin="$CACHE_DIR/ffi_guard_harness"
  if [ ! -x "$bin" ] || [ "$REPO_ROOT/tools/transplant/ffi_guard_harness.c" -nt "$bin" ]; then
    clang -O2 -o "$bin" "$REPO_ROOT/tools/transplant/ffi_guard_harness.c" -ldl \
      || { echo "GUARD-HARNESS ERROR: compile failed" >&2; return 1; }
  fi
  "$bin" "$so" || { echo "GUARD-HARNESS FAILED: hostile FFI cases killed the .so" >&2; return 1; }
  return 0
}

# --- mode dispatch --------------------------------------------------------------
if [ "${1:-}" = "--check" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --check <libopentui.so>" >&2; exit 1; }
  [ -f "$2" ] || { echo "GUARD-CHECK FAILED: $2 not found" >&2; exit 1; }
  guard_check "$2"
  exit $?
fi

command -v llvm-strip >/dev/null 2>&1 || { echo "llvm-strip not found" >&2; exit 1; }

echo ">> OpenTUI zig dir : $OPENTUI_ZIG_DIR"
echo ">> patch dir       : $PATCH_DIR"
echo ">> glibc loader    : $GLIBC_LD"
echo ">> zig binary      : $ZIG_BIN"
echo ">> libc spec       : $LIBC_SPEC"

[ -x "$GLIBC_LD" ] || { echo "glibc loader missing: $GLIBC_LD" >&2; exit 1; }
[ -x "$ZIG_BIN" ]  || { echo "zig binary missing: $ZIG_BIN" >&2; exit 1; }
[ -f "$LIBC_SPEC" ] || { echo "libc spec missing: $LIBC_SPEC" >&2; exit 1; }

# --- phase 0: apply ALL patches/opentui/*.patch (idempotent, fail on reject) ----
OPENTUI_TREE="$(cd "$OPENTUI_ZIG_DIR/../../../.." && pwd)"
command -v patch >/dev/null 2>&1 || { echo "patch(1) not found" >&2; exit 1; }
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
for p in "${PATCHES[@]}"; do
  echo ">> patch: $p"
  # reverse-check FIRST: patch(1) -N --forward silently skips a mixed-state
  # file ("Reversed (or previously applied) patch detected", exit 0), which
  # would leave half-applied guards in the tree unnoticed.
  if patch -d "$OPENTUI_TREE" -p1 -R --dry-run < "$p" >/dev/null 2>&1; then
    echo ">>   already applied, skipping"
  elif patch -d "$OPENTUI_TREE" -p1 -N --forward --dry-run < "$p" >/dev/null 2>&1; then
    patch -d "$OPENTUI_TREE" -p1 -N --forward < "$p"
  else
    echo "ERROR: patch does not apply cleanly to $OPENTUI_TREE (drift between patch and tree)" >&2
    exit 1
  fi
done

# Semantic post-check: regardless of what patch(1) decided, the tree MUST end
# up with the full guard set. Fail loudly if anything is absent.
BUF="$OPENTUI_TREE/packages/core/src/zig/buffer.zig"
RND="$OPENTUI_TREE/packages/core/src/zig/renderer.zig"
sem_fail=0
sem() { grep -qF "$2" "$1" || { echo "ERROR: guard missing in $1: $2" >&2; sem_fail=1; }; }
sem "$BUF" '@min(scissor.width, 0x7FFFFFFF)'
sem "$BUF" 'if (x >= 0x80000000 or y >= 0x80000000) return;'
sem "$BUF" 'if (posX < -0x40000000 or posY < -0x40000000) return;'
sem "$BUF" 'if (y <= -0x40000000) return;'
sem "$RND" '@min(width, 0x7FFFFFFF)'
[ "$sem_fail" -eq 0 ] || exit 1
echo ">> semantic patch verification: OK"

cd "$OPENTUI_ZIG_DIR"

# If the prebuilt tables.zig is absent, generate it first WITHOUT --libc (the
# only step that needs the host toolchain), then the real build reuses it.
if [ ! -f "zig-pkg/uucode-0.1.0-"*"/prebuilt_tables.zig" ]; then
  echo ">> phase 1: generate uucode tables.zig (no --libc)"
  UUCODE_USE_PREBUILT_TABLES= \
  "$GLIBC_LD" --library-path "$GLIBC_LIB" "$ZIG_BIN" build \
    -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
fi

echo ">> phase 2: build bionic libopentui.so (with --libc)"
export ZIG_GLOBAL_CACHE_DIR="$CACHE_DIR"
export UUCODE_USE_PREBUILT_TABLES=1
"$GLIBC_LD" --library-path "$GLIBC_LIB" "$ZIG_BIN" build \
  -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe \
  --libc "$LIBC_SPEC"

SO="$OUT_DIR/libopentui.so"
[ -f "$SO" ] || { echo "build did not produce $SO" >&2; exit 1; }

echo ">> strip debug info"
llvm-strip --strip-debug "$SO"

SIZE=$(stat -c '%s' "$SO")
echo ">> size: $SIZE bytes (slot limit $MAX_SLOT)"
if [ "$SIZE" -gt "$MAX_SLOT" ]; then
  echo "WARN: $SO ($SIZE) exceeds advisory slot $MAX_SLOT (authoritative per-binary slot check is swap_tui.py)" >&2
fi

echo ">> verify NEEDED libc (getauxval must resolve on bionic)"
if ! llvm-readelf -d "$SO" 2>/dev/null | grep -q 'NEEDED.*libc.so'; then
  echo "ERROR: libc.so not in NEEDED — linkLibC missing, dlopen will fail on bionic" >&2
  exit 1
fi

echo ">> phase 3: self-verify FFI guard (task-tui-common-fix)"
guard_check "$SO"
harness_check "$SO"

INSTALL_DIR="$(dirname "$INSTALL_PATH")"
mkdir -p "$INSTALL_DIR"
cp -f "$SO" "$INSTALL_PATH"
echo ">> installed: $INSTALL_PATH ($SIZE bytes)"

echo ">> OK: $INSTALL_PATH is a bionic-loadable, guard-verified libopentui.so"
