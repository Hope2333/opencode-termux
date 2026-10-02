/*
 * selftest.c — exercise the interposed syscall() both ways.
 *
 * T1 (translate): raw syscall(441 epoll_pwait2, epfd, ev, 1,
 *     {200ms timespec}, NULL, 8) — with the shim this becomes epoll_pwait
 *     with a 200ms timeout: returns 0 after ~200ms on ANY kernel.
 * T2 (passthrough): raw syscall(__NR_getpid) must equal libc getpid().
 * T3 (semantics): {0,0} timespec = non-blocking poll -> returns 0/EAGAIN
 *     immediately; NULL timeout would block — not tested here.
 *
 * Without the shim on kernel < 5.1, T1 returns -ENOSYS — the failure mode
 * this shim exists to fix (bun 1.4.0 TUI crash, oscar 3.18.140).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <sys/epoll.h>
#include <sys/syscall.h>

static double now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(void) {
	long epfd = syscall(__NR_epoll_create1, 0, 0L, 0L, 0L, 0L, 0L);
	if (epfd < 0) {
		perror("epoll_create1");
		return 2;
	}
	struct epoll_event ev;
	memset(&ev, 0, sizeof(ev));
	struct timespec ts = { .tv_sec = 0, .tv_nsec = 200000000 };

	double t0 = now_ms();
	long r = syscall(__NR_epoll_pwait2, (long)epfd, (long)&ev, 1L,
			 (long)&ts, 0L, 8L);
	double dt = now_ms() - t0;
	int t1_ok = (r == 0) && dt >= 150.0;
	printf("T1 epoll_pwait2(200ms): ret=%ld errno=%d elapsed=%.0fms -> %s\n",
	       r, errno, dt, t1_ok ? "PASS" : "FAIL");

	long g1 = syscall(__NR_getpid, 0L, 0L, 0L, 0L, 0L, 0L);
	long g2 = getpid();
	int t2_ok = (g1 == g2);
	printf("T2 passthrough getpid: raw=%ld libc=%ld -> %s\n",
	       g1, g2, t2_ok ? "PASS" : "FAIL");

	struct timespec z = { .tv_sec = 0, .tv_nsec = 0 };
	t0 = now_ms();
	r = syscall(__NR_epoll_pwait2, (long)epfd, (long)&ev, 1L, (long)&z,
		    0L, 8L);
	dt = now_ms() - t0;
	int t3_ok = (r == 0 || r == -1) && dt < 50.0;
	printf("T3 non-blocking {0,0}: ret=%ld elapsed=%.0fms -> %s\n",
	       r, dt, t3_ok ? "PASS" : "FAIL");

	/* T4 (raw svc, drives the seccomp TRAP layer): issue 441 by inline
	 * assembly — exactly how bun 34cbb9a40 does it (Rust raw_syscall6) —
	 * so no symbol interposition can see it. The seccomp TRAP + SIGSYS
	 * emulation must translate it; run it THREE times to prove the pc
	 * resume is correct (a wrong skip corrupts the following calls). */
	long t4_ret = 0;
	double t4_elapsed[3];
	int t4_ok = 1;
	for (int i = 0; i < 3; i++) {
		register long x8 __asm__("x8") = 441;
		register long x0 __asm__("x0") = epfd;
		register long x1 __asm__("x1") = (long)&ev;
		register long x2 __asm__("x2") = 1L;
		struct timespec ts4 = { .tv_sec = 0, .tv_nsec = 100000000 };
		register long x3 __asm__("x3") = (long)&ts4;
		register long x4 __asm__("x4") = 0L;
		register long x5 __asm__("x5") = 8L;
		double s = now_ms();
		__asm__ volatile("svc #0" : "=r"(x0)
				 : "r"(x8), "r"(x0), "r"(x1), "r"(x2),
				   "r"(x3), "r"(x4), "r"(x5)
				 : "memory", "cc");
		t4_ret = x0;
		t4_elapsed[i] = now_ms() - s;
		if (!(t4_ret == 0 && t4_elapsed[i] >= 50.0))
			t4_ok = 0;
	}
	printf("T4 raw-svc 441 x3: ret=%ld elapsed=%.0f/%.0f/%.0fms -> %s\n",
	       t4_ret, t4_elapsed[0], t4_elapsed[1], t4_elapsed[2],
	       t4_ok ? "PASS" : "FAIL");

	return (t1_ok && t2_ok && t3_ok && t4_ok) ? 0 : 1;
}
