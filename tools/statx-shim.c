/*
 * statx-shim.c — SIGSYS handler for Android/Termux statx seccomp compatibility
 *
 * Problem:
 *   Android's seccomp filter blocks the statx() syscall (aarch64 #291).
 *   glibc's stat()/fstatat() internally use INLINE_SYSCALL_CALL(statx, ...)
 *   which is a direct 'svc #0' instruction, NOT a call to the public statx()
 *   symbol. When seccomp blocks it, the kernel sends SIGSYS. The default
 *   SIGSYS handler terminates the process → crash.
 *
 *   LD_PRELOAD symbol interception CANNOT fix this because there is no symbol
 *   to intercept — it's a direct syscall instruction.
 *
 * Solution:
 *   Install a SIGSYS handler that catches seccomp-blocked statx syscalls.
 *   The handler sets the return register (x0) to -ENOSYS and advances the
 *   program counter past the svc #0 instruction. glibc sees -ENOSYS, sets
 *   errno=ENOSYS, caches the result, and falls back to fstatat/newfstatat.
 *
 * This is the same pattern used by:
 *   - libuv (src/unix/fs.c): static _Atomic int no_statx; on Android
 *   - OpenJDK 17/21/25: #if defined(__linux__) && !defined(__ANDROID__)
 *   - util-linux: ac_cv_func_statx=no
 *
 * Compile (any C compiler — self-contained, no libc calls beyond signal API):
 *   gcc -shared -fPIC -o libstatx-shim.so statx-shim.c
 *
 * Usage:
 *   LD_PRELOAD=/path/to/libstatx-shim.so ./your-binary
 */

#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>

/* aarch64 statx syscall number */
#ifndef __NR_statx
#define __NR_statx 291
#endif

/* ENOSYS — "Function not implemented" */
#ifndef ENOSYS
#define ENOSYS 38
#endif

/*
 * SIGSYS handler — intercept seccomp-blocked statx syscalls.
 *
 * When seccomp blocks a syscall, the kernel delivers SIGSYS with:
 *   si_code  = SYS_SECCOMP
 *   si_sysno = the blocked syscall number
 *
 * We check if it's statx. If so:
 *   1. Set x0 (return register) to -ENOSYS
 *   2. Advance PC past the svc #0 instruction (4 bytes on aarch64)
 *
 * glibc's INLINE_SYSCALL sees x0 = -ENOSYS, recognizes it as an error
 * (aarch64 uses negative errno in x0 for errors), sets errno = ENOSYS,
 * and returns -1. glibc's statx() wrapper then caches this and falls back
 * to fstatat/newfstatat syscalls.
 */
static void statx_sigsys_handler(int sig, siginfo_t *info, void *ucontext)
{
    (void)sig;

    if (info->si_code != SYS_SECCOMP)
        return;

    if (info->si_syscall != __NR_statx)
        return;

    ucontext_t *ctx = (ucontext_t *)ucontext;

    /* Set return value to -ENOSYS (glibc expects negative errno in x0) */
    ctx->uc_mcontext.regs[0] = (unsigned long long)(-(long long)ENOSYS);

    /* Advance past the svc #0 instruction (4 bytes) */
    ctx->uc_mcontext.pc += 4;
}

/*
 * Install the SIGSYS handler when the shared library is loaded.
 * Uses __attribute__((constructor)) so it runs before main().
 */
static void __attribute__((constructor)) statx_shim_init(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = statx_sigsys_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);

    /*
     * Only install if we're on aarch64 (the only architecture we support
     * for this shim). On other architectures, statx may not be blocked
     * by seccomp or the syscall number differs.
     */
#if defined(__aarch64__)
    sigaction(SIGSYS, &sa, NULL);
#endif
}
