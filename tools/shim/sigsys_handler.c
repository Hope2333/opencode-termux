// libopencode-crhandler: SIGSYS handler + PLT interposer shim for Android
// seccomp traps.
//
// Why: bun calls close_range(4, ~0U, CLOSE_RANGE_CLOEXEC) at startup (PLT
// syscall sites), during spawn-path fd hygiene (PLT sites, executed in the
// forked child before exec), and via an inline-svc wrapper (0x21a2250, svc
// sites 0x1f2b41c/0x1f2b5e4). On Android <= 14 the zygote seccomp allowlist
// lacks nr 436 -> SECCOMP_RET_TRAP -> SIGSYS kills the process
// (oven-sh/bun#30766). The LD_PRELOAD hotfix (libopencode-crshim.so) only
// covers PLT call sites and needs an env var; the inline-svc sites are not
// interposable at all.
//
// This shim combines both proven routes:
//
// 1. PLT interposition (crshim design): the library exports syscall() and
//    close_range() and is linked as the FIRST DT_NEEDED entry of the main
//    ELF, putting it at the head of bionic's symbol lookup order. The main
//    ELF's PLT calls to syscall(436, ...) therefore land here and return
//    -1/ENOSYS without trapping. This is the only layer that rescues the
//    spawn-child fd-hygiene sites: the forked child runs bun's own pre-exec
//    close_range via PLT, and on-device measurement shows the child inherits
//    no usable SIGSYS disposition there (signal handlers do not survive into
//    that context), while an interposed syscall() does. Bun (and dash/bash
//    children) degrade gracefully on -ENOSYS.
//
// 2. SIGSYS handler (#39060 on-device, #39775 in-binary design): for the
//    inline-svc sites no interposition can reach, a SIGSYS handler rewrites
//    the interrupted context so the syscall appears to have returned
//    -ENOSYS. ALL seccomp traps are blanket-answered with -ENOSYS (#39775
//    semantics: also rescues openat2 437 / fchmodat2 452 / pidfd_open traps
//    during bun install).
//
// Delivery: linked into the main ELF as the FIRST DT_NEEDED entry
// (libopencode-crhandler.so, self-activation; no env vars). The constructor
// runs during early loader init, before bun main() and before any JS
// executes.
//
// Bionic aarch64 ucontext (sys/ucontext.h -> asm/sigcontext.h):
//   struct sigcontext { __u64 fault_address; __u64 regs[31]; __u64 sp;
//                       __u64 pc; __u64 pstate; }
//   regs[0] == x0. On SECCOMP_RET_TRAP the context pc points AT the svc
//   instruction (4 bytes on aarch64); pc += 4 skips it, x0 = -ENOSYS fakes
//   the syscall return. Bionic handler return performs sigreturn
//   automatically, applying the edits.
//
// Build (Termux NDK-style clang, aarch64 bionic):
//   clang -shared -fPIC -O2 -o libopencode-crhandler.so sigsys_handler.c
// Debug logging is opt-in: OPENCODE_CRSHANDLER_DEBUG=1 (default: silent).
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

// SYS_SECCOMP is the only si_code seccomp TRAP can deliver for SIGSYS
// (kernel uapi siginfo.h); guard for header variance.
#ifndef SYS_SECCOMP
#define SYS_SECCOMP 1
#endif

#ifndef ENOSYS
#define ENOSYS 38
#endif

// Cached once by the constructor (before any handler can run), so the
// handler itself never calls getenv (async-signal-unsafe).
static int debug_cached = -1;

static int getenv_debug(void) {
    if (debug_cached < 0) debug_cached = getenv("OPENCODE_CRSHANDLER_DEBUG") ? 1 : 0;
    return debug_cached;
}

static int write_str(const char *s) {
    size_t n = 0;
    while (s[n] != '\0') n++;
    return (int)write(2, s, n);
}

static void sigsys_handler(int signo, siginfo_t *info, void *uctx) {
    (void)signo;
    ucontext_t *uc = (ucontext_t *)uctx;
    if (info == NULL || info->si_code != SYS_SECCOMP || uc == NULL) {
        // Not a seccomp trap: restore default disposition (kill) and re-raise.
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigaction(SIGSYS, &sa, NULL);
        raise(SIGSYS);
        return;
    }
    uc->uc_mcontext.pc += 4;                              // skip the svc
    uc->uc_mcontext.regs[0] = (unsigned long)(long)-ENOSYS; // x0 = -ENOSYS
    if (getenv_debug()) {
        write_str("CRHANDLER: SIGSYS(SYS_SECCOMP) -> -ENOSYS\n");
    }
}

__attribute__((constructor))
static void crhandler_init(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigsys_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, NULL) != 0 && getenv_debug()) {
        write_str("CRHANDLER: sigaction(SIGSYS) failed\n");
    } else if (getenv_debug()) {
        write_str("CRHANDLER: SIGSYS handler installed\n");
    }
}

// ---------------------------------------------------------------------------
// PLT interposers. Only close_range (nr 436) is short-circuited; every other
// syscall passes through to libc unchanged. Returning -1/ENOSYS (instead of
// emulating) is sufficient: bun's fd-hygiene fallback (fcntl F_GETFD /
// F_SETFD loop) is proven, and POSIX callers treat close_range ENOSYS as the
// standard graceful-degrade signal.
// ---------------------------------------------------------------------------

typedef long (*real_syscall_t)(long, long, long, long, long, long, long);

static real_syscall_t real_syscall_cached;

long syscall(long number, ...) {
    if (number == 436 /* __NR_close_range */) {
        if (getenv_debug()) write_str("CRHANDLER: syscall(436) -> -ENOSYS\n");
        errno = ENOSYS;
        return -1;
    }
    if (real_syscall_cached == NULL) {
        real_syscall_cached = (real_syscall_t)dlsym(RTLD_NEXT, "syscall");
    }
    if (real_syscall_cached == NULL) {
        // libc syscall() must exist (we are linked against it); fail loud in
        // debug builds rather than corrupting unrelated syscalls silently.
        write_str("CRHANDLER: dlsym(RTLD_NEXT, \"syscall\") failed\n");
        errno = ENOSYS;
        return -1;
    }
    va_list ap;
    va_start(ap, number);
    long a = va_arg(ap, long);
    long b = va_arg(ap, long);
    long c = va_arg(ap, long);
    long d = va_arg(ap, long);
    long e = va_arg(ap, long);
    long f = va_arg(ap, long);
    va_end(ap);
    return real_syscall_cached(number, a, b, c, d, e, f);
}

int close_range(unsigned int first, unsigned int last, unsigned int flags) {
    (void)first;
    (void)last;
    (void)flags;
    if (getenv_debug()) write_str("CRHANDLER: close_range() -> -ENOSYS\n");
    errno = ENOSYS;
    return -1;
}
