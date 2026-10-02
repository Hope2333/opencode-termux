#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-android.sh — build the epoll_pwait2 compat shim on-device (Termux).
#
# Precedent: tools/upx-stub/ (custom memfd-patched UPX built natively on
# Android aarch64). Same philosophy: no cross toolchain, plain Termux clang
# targeting bionic, single small artifact.
#
# Output: dist/libepoll-compat.so — installed by the compressed packaging
# chain (OPENCODE_EPOLL_SHIM_SO) under lib/opencode1/ and injected via
# LD_PRELOAD by the opencode1 launcher when present (optional asset,
# backward compatible: packages built before the asset ship unchanged and
# the launcher skips the block).
#
# Why not -nostdlib: the seccomp layer needs sigaction/memset at load time.
# The .so carries a single DT_NEEDED libc.so, which the hardened bionic
# runtime already links — no extra resolution burden under the UPX memfd
# stub (its LD_LIBRARY_PATH roots are injected by the launcher).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${EPOLL_SHIM_OUT:-$ROOT_DIR/tools/epoll-shim/dist}"
OUT="$OUT_DIR/libepoll-compat.so"

command -v clang >/dev/null 2>&1 || {
	echo "Error: clang not found (pacman -S clang)" >&2
	exit 1
}
[[ "$(uname -m)" == "aarch64" ]] || {
	echo "Error: aarch64 host required (shim is aarch64-only)" >&2
	exit 1
}

mkdir -p "$OUT_DIR"
# -fvisibility=hidden + explicit default visibility on `syscall`: exports
# exactly one interposition symbol. -Wl,-z,max-page-size=16384 keeps the .so
# loadable on 16KB-page kernels as well as 4KB.
clang -O2 -fPIC -shared -fvisibility=hidden \
	-Wl,-z,max-page-size=16384 -Wl,--no-undefined \
	-o "$OUT" "$ROOT_DIR/tools/epoll-shim/epoll-compat.c"

echo "OK: $OUT"
