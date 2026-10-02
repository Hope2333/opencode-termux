#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# selftest.sh — validate the epoll-compat shim end-to-end on this device.
#
# 1. selftest binary (plain libc build) calls raw syscall(441) three ways.
# 2. WITH the shim preloaded: T1 (200ms wait) / T2 (getpid passthrough) /
#    T3 (non-blocking {0,0}) must all pass — proves the shim loads, keeps
#    passthrough intact, and translates with correct timeout semantics.
# 3. Interposition probe: a THROWAWAY shim variant that mis-translates 441
#    to an invalid syscall number. With that preload, T1 must FAIL with
#    ENOSYS — if it still passed, our syscall() never intercepted the call
#    (interposition proof). This distinguishes "native 441 worked" from
#    "shim translated it" on kernels >= 5.1; on kernel < 5.1 (oscar) the
#    no-preload baseline itself already fails with ENOSYS.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${TMPDIR:-/tmp}/epoll-shim-selftest"
mkdir -p "$WORK"

clang -O1 -o "$WORK/selftest" "$DIR/selftest.c" || exit 2
sed 's/__NR_epoll_pwait, a0/0xdead, a0/' "$DIR/epoll-compat.c" > "$WORK/epoll-compat-broken.c"
clang -O2 -fPIC -shared -nostdlib -fvisibility=hidden \
	-Wl,-z,max-page-size=16384 -o "$WORK/libepoll-compat-broken.so" \
	"$WORK/epoll-compat-broken.c"

FAIL=0

echo "== baseline (no preload; on kernel >= 5.1 native 441 works, on 3.18 expect ENOSYS)"
"$WORK/selftest" || echo "(baseline failed — expected on kernel < 5.1)"

echo "== with shim (libepoll-compat.so)"
LD_PRELOAD="$DIR/dist/libepoll-compat.so" "$WORK/selftest" || FAIL=1

echo "== interposition probe (broken-translation shim: T1 must now FAIL)"
if LD_PRELOAD="$WORK/libepoll-compat-broken.so" "$WORK/selftest"; then
	echo "INTERPOSITION PROBE INCONCLUSIVE: broken shim still passed T1 — syscall() not intercepted?"
	FAIL=1
else
	echo "interposition probe: PASS (broken shim broke T1 => shim syscall() intercepts)"
fi

rm -rf "$WORK"
exit "$FAIL"
