/*
 * epoll-compat.c — kernel-level epoll_pwait2 compat shim for pre-gate bun
 * builds on kernels < 5.1 (opencode1-compressed 1.18.32-4 runtime, bun
 * v1.4.0 34cbb9a40, oscar 3.18.140).
 *
 * WHY NOT LD_PRELOAD SYMBOL INTERPOSITION ALONE:
 *   bun 34cbb9a40 issues epoll_pwait2 via a Rust inline-asm `svc #0`
 *   (src/platform/linux.rs raw_syscall6 — verified in the bun tree at that
 *   commit), so interposing the libc `syscall` symbol cannot see it.
 *   Measured on oscar: symbol-interposition-only shim changed nothing
 *   (identical 4.4s SIGSEGV@0x0 crash, identical bun.report signature).
 *
 * MECHANISM HERE (two layers):
 *   1. seccomp-bpf filter: nr == 441 (epoll_pwait2) -> SECCOMP_RET_TRAP;
 *      everything else -> ALLOW. The SIGSYS handler emulates the call with
 *      epoll_pwait (22) — timespec -> ms timeout, round UP — then writes
 *      the result into x0 and advances pc past the svc. Works regardless
 *      of how the syscall instruction is reached.
 *   2. libc `syscall()` symbol interposition as a belt-and-braces layer for
 *      any caller that does go through libc (raw aarch64 svc passthrough,
 *      no dlsym — cannot recurse).
 *
 * aarch64-only by design (this runtime line ships aarch64 ELFs only).
 * Ships as lib/opencode1/libepoll-compat.so; injected by the opencode1
 * launcher via LD_PRELOAD only when the asset exists (optional asset,
 * backward compatible with packages built before it).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/ucontext.h>
#include <ucontext.h>

#ifndef __aarch64__
#error "epoll-compat shim is aarch64-only (runtime line contract)"
#endif

#ifndef __NR_epoll_pwait
#define __NR_epoll_pwait 22
#endif
#ifndef __NR_epoll_pwait2
#define __NR_epoll_pwait2 441
#endif

/* ── self-contained raw syscall (no libc symbols, handler-safe) ─────────── */
static long raw_syscall6(long nr, long a0, long a1, long a2, long a3,
			 long a4, long a5) {
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a0;
	register long x1 __asm__("x1") = a1;
	register long x2 __asm__("x2") = a2;
	register long x3 __asm__("x3") = a3;
	register long x4 __asm__("x4") = a4;
	register long x5 __asm__("x5") = a5;
	__asm__ volatile("svc #0"
			 : "=r"(x0)
			 : "r"(x8), "r"(x0), "r"(x1), "r"(x2), "r"(x3), "r"(x4),
			   "r"(x5)
			 : "memory", "cc");
	return x0;
}

/* timespec* -> epoll_pwait timeout in ms. NULL/negative = -1 (infinite).
 * Round UP so a sub-ms timeout still yields one pollable ms. */
static long ts_to_ms(const struct timespec *ts) {
	if (ts == NULL || ts->tv_sec < 0 || (ts->tv_sec == 0 && ts->tv_nsec < 0))
		return -1;
	long ms = ts->tv_sec * 1000 + (ts->tv_nsec + 999999) / 1000000;
	if (ms < 0)
		ms = 0x7fffffff;
	return ms;
}

/* ── layer 1: seccomp TRAP + SIGSYS emulation ───────────────────────────── */
static void sigsys_handler(int sig, siginfo_t *info, void *uctx_p) {
	(void)sig;
	if (info == NULL || uctx_p == NULL)
		return;
	if (info->si_syscall != __NR_epoll_pwait2)
		return; /* not ours: nothing sane to do, let it fault again */
	ucontext_t *uc = (ucontext_t *)uctx_p;
	long *regs = (long *)&uc->uc_mcontext.regs[0];
	/* epoll_pwait2(epfd, events, maxevents, timeout_ts, sigmask, sigsetsize)
	 * -> epoll_pwait(epfd, events, maxevents, timeout_ms, sigmask, sigsetsize) */
	long ret = raw_syscall6(__NR_epoll_pwait, regs[0], regs[1], regs[2],
				ts_to_ms((const struct timespec *)regs[3]),
				regs[4], regs[5]);
	regs[0] = ret; /* syscall return register */
	/* Kernel-dependent: the saved pc may point AT the svc (ELR not yet
	 * advanced) or already past it (arm64 exception entry sets ELR = svc+4).
	 * si_call_addr is the svc instruction address — only advance when the
	 * frame still points at it, never blindly skip an extra instruction. */
	if ((uintptr_t)uc->uc_mcontext.pc == (uintptr_t)info->si_call_addr)
		uc->uc_mcontext.pc += 4;
}

/* Probe mode (diagnostics only): TRAP every syscall newer than kernel 3.18
 * (the set a modern build may attempt), LOG the number with a raw write(),
 * and return -ENOSYS — byte-identical behavior to the real kernel's answer
 * for a missing syscall, so the process follows its unshimmed code path
 * while we learn which post-3.18 syscalls it actually attempts. */
static int g_probe_fd = -1;

static void write_nr(long nr, const char *tag) {
	char buf[32];
	int i = 0;
	buf[i++] = '[';
	for (const char *p = tag; *p && i < 20; p++)
		buf[i++] = *p;
	buf[i++] = ' ';
	/* hex, no division (handler-safe) */
	int started = 0;
	for (int sh = 28; sh >= 0; sh -= 4) {
		int d = (int)((nr >> sh) & 0xf);
		if (d || started || sh == 0) {
			buf[i++] = d < 10 ? (char)('0' + d) : (char)('a' + d - 10);
			started = 1;
		}
	}
	buf[i++] = ']';
	buf[i++] = '\n';
	raw_syscall6(64 /*write*/, 2L, (long)buf, (long)i, 0L, 0L, 0L);
}

static int nr_is_post_318(long nr) {
	if (nr == 291) return 1; /* statx (4.11) */
	if (nr == 286) return 1; /* copy_file_range (4.5) */
	if (nr == 288) return 1; /* pkey_alloc */
	if (nr >= 424) return 1; /* pidfd(5.1) .. epoll_pwait2(441) .. clone3(435), openat2(437), faccessat2(439), close_range(436) */
	return 0;
}

static void sigsys_probe_handler(int sig, siginfo_t *info, void *uctx_p) {
	(void)sig;
	if (info == NULL || uctx_p == NULL)
		return;
	long nr = info->si_syscall;
	if (g_probe_fd >= 0)
		write_nr(nr, "P");
	ucontext_t *uc = (ucontext_t *)uctx_p;
	long *regs = (long *)&uc->uc_mcontext.regs[0];
	if (nr == __NR_epoll_pwait2) {
		regs[0] = raw_syscall6(__NR_epoll_pwait, regs[0], regs[1],
				       regs[2],
				       ts_to_ms((const struct timespec *)regs[3]),
				       regs[4], regs[5]);
	} else {
		regs[0] = -38; /* -ENOSYS: exactly what kernel 3.18 answers */
	}
	if ((uintptr_t)uc->uc_mcontext.pc == (uintptr_t)info->si_call_addr)
		uc->uc_mcontext.pc += 4;
}

static void install_seccomp_trap(void) {
	int probe = getenv("OPENCODE_EPOLL_COMPAT_PROBE") != NULL;
	const char *pf = getenv("OPENCODE_EPOLL_COMPAT_PROBE_FD");
	if (probe && pf)
		g_probe_fd = (int)strtol(pf, NULL, 10);

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = probe ? sigsys_probe_handler : sigsys_handler;
	sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_RESTART;
	sigaction(SIGSYS, &sa, NULL);

	struct sock_filter filter[16];
	int fi = 0;
	if (probe) {
		/* arch check */
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
		/* nr >= 424 -> TRAP; statx(291)/copy_file_range(286)/pkey(288) -> TRAP */
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 424, 0, 4);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 291, 1, 0);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 286, 1, 0);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP); /* 286 falls here */
	} else {
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
		filter[fi++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_epoll_pwait2, 0, 1);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
		filter[fi++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	}
	struct sock_fprog prog = {
		.len = (unsigned short)fi,
		.filter = filter,
	};
	(void)nr_is_post_318; /* retained for reference */
	/* no_new_privs is required to install a filter without CAP_SYS_ADMIN;
	 * it is inherited across exec and harmless for this runtime. */
	if (raw_syscall6(__NR_prctl, PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L, 0L) != 0)
		return;
	raw_syscall6(__NR_prctl, PR_SET_SECCOMP, (long)SECCOMP_MODE_FILTER,
		     (long)&prog, 0L, 0L, 0L);
}

/* ── layer 2: libc `syscall` interposition (belt and braces) ────────────── */
__attribute__((visibility("default"))) long
syscall(long number, long a0, long a1, long a2, long a3, long a4, long a5) {
	if (number == __NR_epoll_pwait2) {
		return raw_syscall6(__NR_epoll_pwait, a0, a1, a2,
				    (long)ts_to_ms((const struct timespec *)a3),
				    a4, a5);
	}
	return raw_syscall6(number, a0, a1, a2, a3, a4, a5);
}

/* Constructor: install the filter before any runtime code runs. */
__attribute__((constructor)) static void epoll_compat_init(void) {
	install_seccomp_trap();
}
