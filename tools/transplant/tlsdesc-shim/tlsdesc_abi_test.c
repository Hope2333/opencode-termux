/* tlsdesc_abi_test.c — unit test for the TLSDESC resolver register-preservation
 * contract (rc6-b2-upx-tui todo2).
 *
 * The AArch64 TLSDESC ABI requires the resolver to preserve x1-x18, x30, SP
 * and NZCV; the generated access sequence keeps caller values live across
 * `blr x1`. This test calls tlsdesc_resolver_stub with poisoned registers and
 * asserts:
 *   1. every register x1-x18 survives byte-for-byte,
 *   2. NZCV flags survive,
 *   3. x0 is a genuine tp-offset: two calls with descriptor args differing by
 *      D return values differing by exactly D (independent of the internal
 *      per-thread block address, which the test cannot know).
 *
 * Usage: tlsdesc_abi_test <shim.so>   (built without -fvisibility=hidden so
 * the stub is dlsym-able in the TEST build only)
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef unsigned long (*stub_t)(void *);

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <shim.so>\n", argv[0]); return 2; }
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  stub_t stub = (stub_t)dlsym(h, "tlsdesc_resolver_stub");
  if (!stub) { fprintf(stderr, "dlsym tlsdesc_resolver_stub failed\n"); return 1; }

  static unsigned long out[20]; /* x1..x18 @0..136, nzcv @144, x0(call1) @152 */
  static unsigned long desc1[2] = {0, 0x1234};
  static unsigned long desc2[2] = {0, 0x2345};
  static unsigned long x0_second = 0;

  /* bind pointers to callee-saved regs we do NOT poison (x20-x24) */
  register unsigned long r_out asm("x20") = (unsigned long)out;
  register unsigned long r_desc1 asm("x21") = (unsigned long)desc1;
  register unsigned long r_ret2 asm("x22") = (unsigned long)&x0_second;
  register unsigned long r_stub asm("x23") = (unsigned long)stub;
  register unsigned long r_desc2 asm("x24") = (unsigned long)desc2;

  asm volatile(
      "mov x1, #0x111\n\t"
      "mov x2, #0x222\n\t"
      "mov x3, #0x333\n\t"
      "mov x4, #0x444\n\t"
      "mov x5, #0x555\n\t"
      "mov x6, #0x666\n\t"
      "mov x7, #0x777\n\t"
      "mov x8, #0x888\n\t"
      "mov x9, #0x999\n\t"
      "mov x10, #0xaaa\n\t"
      "mov x11, #0xbbb\n\t"
      "mov x12, #0xccc\n\t"
      "mov x13, #0xddd\n\t"
      "mov x14, #0xeee\n\t"
      "mov x15, #0xfff\n\t"
      "mov x16, #0x1010\n\t"
      "mov x17, #0x1111\n\t"
      "mov x18, #0x1212\n\t"
      "cmp xzr, xzr\n\t"   /* set Z=1 C=1 (nzcv=0x60000000) */
      "mov x0, %[desc1]\n\t"
      "blr %[stub]\n\t"
      "str x1, [%[out], #0]\n\t"
      "str x2, [%[out], #8]\n\t"
      "str x3, [%[out], #16]\n\t"
      "str x4, [%[out], #24]\n\t"
      "str x5, [%[out], #32]\n\t"
      "str x6, [%[out], #40]\n\t"
      "str x7, [%[out], #48]\n\t"
      "str x8, [%[out], #56]\n\t"
      "str x9, [%[out], #64]\n\t"
      "str x10, [%[out], #72]\n\t"
      "str x11, [%[out], #80]\n\t"
      "str x12, [%[out], #88]\n\t"
      "str x13, [%[out], #96]\n\t"
      "str x14, [%[out], #104]\n\t"
      "str x15, [%[out], #112]\n\t"
      "str x16, [%[out], #120]\n\t"
      "str x17, [%[out], #128]\n\t"
      "str x18, [%[out], #136]\n\t"
      "mrs x9, nzcv\n\t"
      "str x9, [%[out], #144]\n\t"
      "str x0, [%[out], #152]\n\t"
      "mov x0, %[desc2]\n\t"
      "blr %[stub]\n\t"
      "str x0, [%[ret2]]\n\t"
      :
      : [out] "r"(r_out), [desc1] "r"(r_desc1), [ret2] "r"(r_ret2),
        [stub] "r"(r_stub), [desc2] "r"(r_desc2)
      : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10",
        "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "memory",
        "cc");

  static const unsigned long magic[18] = {0x111, 0x222, 0x333, 0x444, 0x555,
                                          0x666, 0x777, 0x888, 0x999, 0xaaa,
                                          0xbbb, 0xccc, 0xddd, 0xeee, 0xfff,
                                          0x1010, 0x1111, 0x1212};
  int fail = 0;
  for (int i = 0; i < 18; i++) {
    if (out[i] != magic[i]) {
      printf("FAIL x%d: got %#lx want %#lx\n", i + 1, out[i], magic[i]);
      fail = 1;
    }
  }
  if ((out[18] & 0xF0000000UL) != 0x60000000UL) {
    printf("FAIL nzcv: got %#lx (flags not preserved)\n", out[18]);
    fail = 1;
  }
  unsigned long x0_first = out[19];
  unsigned long delta = x0_second - x0_first;
  if (delta != 0x1111) {
    printf("FAIL x0 delta: %#lx want 0x1111 (tp-offset arithmetic broken)\n",
           delta);
    fail = 1;
  } else {
    printf("x0[0]=%#lx x0[1]=%#lx delta=%#lx (OK)\n", x0_first, x0_second,
           delta);
  }
  if (!fail) printf("TLSDESC ABI TEST: PASS\n");
  return fail;
}
