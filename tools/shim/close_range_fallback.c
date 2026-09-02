// libopencode-crshim: close_range(436) SIGSYS hotfix shim for Android <= 14
//
// Why: bun startup calls close_range(4, ~0U, CLOSE_RANGE_CLOEXEC). On Android
// <= 14 the zygote seccomp allowlist lacks nr 436 -> SECCOMP_RET_TRAP -> SIGSYS
// kills the process (oven-sh/bun#30766). This shim interposes libc `syscall`
// (bun reaches close_range via syscall(436, ...) at PLT sites) and emulates it
// in userspace; a SECCOMP_RET_TRAP policy then never sees the raw syscall.
//
// Coverage (caveat a): PLT call sites only. Bun's inline-svc spawn wrapper
// (0x21a2250, svc sites 0x1f2b41c / 0x1f2b5e4 per
// .omo/evidence/task-sigsys-closerange-diag.log) is NOT interposable; the full
// fix is the W11 handler-style shim (ucontext x0 rewrite, per #39060/#39775).
//
// Build (Termux NDK-style clang, aarch64-linux-android):
//   clang -shared -fPIC -O2 -o libopencode-crshim.so close_range_fallback.c
// Debug logging is opt-in: OPENCODE_CRSHIM_DEBUG=1 (default: silent).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>

#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif
#ifndef CLOSE_RANGE_UNSHARE
#define CLOSE_RANGE_UNSHARE (1U << 1)
#endif

static long (*real_syscall)(long, ...);
static int dbg = -1;

static int shim_debug(void) {
    if (dbg < 0) dbg = getenv("OPENCODE_CRSHIM_DEBUG") ? 1 : 0;
    return dbg;
}

// Kernel semantics: fds outside [fd, max_fd] untouched; closed fds in range are
// skipped (no error). Termux app processes keep a dense low fd table, so EBADF
// marks the end of the scan (caveat: sparse high fds would be missed; acceptable
// for the hotfix, superseded by the W11 handler shim).
static int emulate_close_range(unsigned fd, unsigned max_fd, unsigned flags) {
    if (flags & ~CLOSE_RANGE_CLOEXEC) { errno = EINVAL; return -1; } // UNSHARE not emulatable
    unsigned cap = (max_fd == ~0U) ? 1048576U : max_fd;
    for (unsigned f = fd; ; f++) {
        if (f > cap) break;
        int r = fcntl((int)f, F_GETFD);
        if (r < 0) {
            if (errno == EBADF) break; // dense fd table: reached end
            continue;
        }
        if (flags & CLOSE_RANGE_CLOEXEC)
            fcntl((int)f, F_SETFD, r | FD_CLOEXEC);
        else
            close((int)f);
    }
    return 0;
}

long syscall(long number, ...) {
    va_list ap; va_start(ap, number);
    long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long);
    long d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
    va_end(ap);
    if (number == __NR_close_range) {
        int saved = errno; // caveat (b): emulate may dirty errno via fcntl/close
        if (shim_debug())
            fprintf(stderr, "SHIM: syscall(436 close_range, fd=%ld max=%ld flags=%#lx) emulated\n", a, b, c);
        long rc = emulate_close_range((unsigned)a, (unsigned)b, (unsigned)c);
        if (rc >= 0) errno = saved;
        return rc;
    }
    if (!real_syscall) {
        int saved = errno; // dlsym may open/read libs and dirty errno
        real_syscall = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
        errno = saved;
    }
    return real_syscall(number, a, b, c, d, e, f);
}

int close_range(unsigned fd, unsigned max_fd, unsigned flags) {
    int saved = errno;
    if (shim_debug())
        fprintf(stderr, "SHIM: close_range(fd=%u max=%u flags=%#x) emulated\n", fd, max_fd, flags);
    int rc = emulate_close_range(fd, max_fd, flags);
    if (rc >= 0) errno = saved; // caveat (b)
    return rc;
}
