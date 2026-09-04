/* FFI guard differential harness (task-tui-common-fix).
 *
 * dlopens a bionic libopentui.so and hammers the guard-covered FFI
 * entrypoints with hostile coordinates (bit31-set u32 = JS negatives,
 * INT32_MIN negations, huge widths/heights).
 *
 *   guarded .so   -> every call is a no-op; exits 0 ("SURVIVED")
 *   unguarded .so -> Zig panic (@intCast integer does not fit) aborts the
 *                    process (SIGABRT / exit 134) ("died")
 *
 * Usage: ffi_guard_harness <libopentui.so>
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *(*create_buf_fn)(uint32_t, uint32_t, bool, uint8_t, const char *, size_t);
typedef void (*destroy_buf_fn)(void *);
typedef void (*draw_char_fn)(void *, uint32_t, uint32_t, uint32_t, const float *, const float *, uint32_t);
typedef void (*fill_rect_fn)(void *, uint32_t, uint32_t, uint32_t, uint32_t, const float *);
typedef void (*gray_fn)(void *, int32_t, int32_t, const float *, uint32_t, uint32_t, const float *, const float *);
typedef void (*push_scissor_fn)(void *, int32_t, int32_t, uint32_t, uint32_t);
typedef void (*pop_scissor_fn)(void *);
typedef void (*draw_text_fn)(void *, const char *, size_t, uint32_t, uint32_t, const float *, const float *, uint32_t);

int main(int argc, char **argv)
{
  if (argc != 2)
  {
    fprintf(stderr, "usage: %s <libopentui.so>\n", argv[0]);
    return 2;
  }
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h)
  {
    fprintf(stderr, "ffi_guard_harness: dlopen failed: %s\n", dlerror());
    return 2;
  }

  create_buf_fn createBuf = (create_buf_fn)dlsym(h, "createOptimizedBuffer");
  destroy_buf_fn destroyBuf = (destroy_buf_fn)dlsym(h, "destroyOptimizedBuffer");
  draw_char_fn drawChar = (draw_char_fn)dlsym(h, "bufferDrawChar");
  draw_char_fn setCellBlend = (draw_char_fn)dlsym(h, "bufferSetCellWithAlphaBlending");
  fill_rect_fn fillRect = (fill_rect_fn)dlsym(h, "bufferFillRect");
  gray_fn drawGray = (gray_fn)dlsym(h, "bufferDrawGrayscaleBuffer");
  push_scissor_fn pushScissor = (push_scissor_fn)dlsym(h, "bufferPushScissorRect");
  pop_scissor_fn popScissor = (pop_scissor_fn)dlsym(h, "bufferPopScissorRect");
  draw_text_fn drawText = (draw_text_fn)dlsym(h, "bufferDrawText");
  if (!createBuf || !destroyBuf || !drawChar || !setCellBlend || !fillRect ||
      !drawGray || !pushScissor || !popScissor || !drawText)
  {
    fprintf(stderr, "ffi_guard_harness: missing symbol: %s\n", dlerror());
    return 2;
  }

  void *buf = createBuf(8, 4, false, 0, "harness", 7);
  if (!buf)
  {
    fprintf(stderr, "ffi_guard_harness: createOptimizedBuffer returned null\n");
    return 3;
  }

  const float fg[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  const float bg[4] = {0.0f, 0.0f, 0.0f, 1.0f};
  const float intens[4] = {0.2f, 0.5f, 0.8f, 1.0f};
  const uint32_t BIT31 = 0x80000000u;
  const uint32_t ONES = 0xFFFFFFFFu;
  const int32_t IMIN = -2147483647 - 1; /* INT32_MIN */

  /* 1. the incident case: JS negative x crossing FFI as bit31 u32 */
  drawChar(buf, 'A', BIT31, 0, fg, bg, 0);
  /* 2. all-ones coords */
  drawChar(buf, 'A', ONES, ONES, fg, bg, 0);
  /* 3. blending setter, hostile y */
  setCellBlend(buf, 0, BIT31, 'A', fg, bg, 0);
  /* 4. huge fill extent */
  fillRect(buf, 0, 0, ONES, ONES, bg);
  /* 5./6. INT32_MIN negation overflow in grayscale draws */
  drawGray(buf, IMIN, 0, intens, 2, 2, fg, bg);
  drawGray(buf, 0, IMIN, intens, 2, 2, fg, bg);
  /* 7./8. huge / hostile scissor rects */
  pushScissor(buf, 0, 0, ONES, ONES);
  popScissor(buf);
  pushScissor(buf, IMIN, IMIN, 4, 4);
  popScissor(buf);
  /* 9. text draw at hostile coords */
  drawText(buf, "hi", 2, ONES, ONES, fg, NULL, 0);

  destroyBuf(buf);
  dlclose(h);
  printf("ffi_guard_harness: SURVIVED all hostile FFI cases\n");
  return 0;
}
