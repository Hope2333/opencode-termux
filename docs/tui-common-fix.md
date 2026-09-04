# TUI 崩溃修复过程与技术总览

> 本文记录 OpenCode-on-Termux native 线 TUI 渲染层 (`libopentui.so`) 从首次崩溃到公共层根治的完整技术历程。涉及 commit `342d68d` (crashfix v2)、`17b51a4` / `10afa28` / `faf1334` (公共层根治三部曲)、补丁 `patches/opentui/fix-drawchar-negative-coords.patch` 和 `ffi-int-truncation-guards.patch`。

---

## TL;DR

2026-08-25 alpha 包用户报告 TUI 点击展开 thinking 块时概率性 SIGABRT。根因分两层: (1) JS 侧负坐标/负尺寸经 FFI 以补码跨入 Zig 变为巨大 u32, `bufferDrawChar` 内 `@intCast(u32->i32)` 安全检查 panic; (2) 构建管线公共层 `libopentui.so` 从未应用补丁导致 13 版本全线复发。修复分两层: (1) `fix-drawchar-negative-coords.patch` 在 8 处插入 bit31 早退 + `@min(w/h, 0x7FFFFFFF)` 饱和钳位 + 饱和加法; (2) `build-libopentui.sh` 重写为五步管线 (补丁全应用 -> zig 构建 -> objdump 守卫自检 -> hostile FFI harness -> 装槽位), `swap_tui.py` 拒收无守卫 .so, `tui_smoke.py` pty 冒烟进常备矩阵。最终: 13 版本全量重建, 12/12 守卫验证通过, 1.18.21 通过新鲜 `make transplant` 重建后 smoke PASS, 4/4 golden 回归通过。

---

## 时间线

| 日期 | 事件 | 关键 commit / hash |
|------|------|--------------------|
| 2026-08-25 | alpha 用户报告 TUI SIGABRT: 点击展开 thinking 块 -> `integer does not fit in destination type` in `lib.bufferDrawChar` | crash report |
| 2026-08-25 | DIAG1: 从崩溃进程提取 `bun-10258.so` (fd29387d, 13,995,736B), 确认为 OpenTUI bionic lib (SONAME=libopentui.so) | DIAG1 完成 |
| 2026-08-26 | DIAG2: 反汇编定位 `bufferDrawChar@0x2ad104` 内 4 个 `@intCast` 失败分支 (+0x12c/0x130/0x154/0x178), 锁定 `buffer.zig:925` 与 `:322-324` | DIAG2 完成 |
| 2026-08-26 | v1 守卫 (仅坐标): `if (x >= 0x80000000 or y >= 0x80000000) return;` 插入 `buffer.zig:925` | 重建 FFI 压测: 坐标压力 PASS, scissor-residual FAIL |
| 2026-08-26 | v2 守卫 (坐标 + scissor): `@min(scissor.width, 0x7FFFFFFF)` 钳位 + `+|` 饱和加法写入 `isPointInScissor` | **342d68d** `fix(opentui): guard negative FFI coords in bufferDrawChar` |
| 2026-08-27 | beta 发布 1.18.21, 含 seccomp shim + TUI 守卫 v2; `tui_probe` 仅测 `--version` | `956515a` beta channel 标记 |
| 2026-08-30~09-03 | Push260903 准备: 13 版本 glibc + native 批量构建; 走 `transplant.py` 等长换入 | batch build logs |
| 2026-09-03 | 发现 1.18.27 批量包内嵌 `libopentui.so` 无守卫; `build-libopentui.sh` (UNTRACKED) 未应用 `patches/opentui/*` | `task-tui-common-fix.log` P2 |
| 2026-09-04 | P3: `build-libopentui.sh` 重写为五步管线; `swap_tui.py` 增加 `has_ffi_guard` 拒收逻辑; canonical .so 917,832B | **17b51a4** `fix(transplant): common-layer libopentui guard` |
| 2026-09-04 | P4: 补丁扩展覆盖 `packages/native` 树 (`ffi-int-truncation-guards.patch`), differential FFI proof: 新构建 exit=0, 旧 .so exit=134 | **10afa28** `fix(transplant): wire libopentui common layer` |
| 2026-09-04 | P5: 13 版本全量重建 + 12/12 守卫通过 + 4/4 golden + attach 冒烟 render=yes panic=no | **faf1334** `feat(transplant): P5 hardening` |

---

## 崩溃机制

### 触发路径

```
JS Renderable._screenX/_screenY (可为负, thinking 块顶部越出视口)
  -> buffer.ts:613 drawChar (未 clamp, 直传 lib.bufferDrawChar)
    -> FFI 边界: lib.zig:3207 export fn bufferDrawChar(buffer_handle, char:u32, x:u32, y:u32, ...)
      -> JS 负数 (-1) 经补码变为 u32 0xFFFFFFFF (bit31 set)
        -> bufferDrawChar 内 @intCast(u32->i32) 安全检查
          -> panic: "integer does not fit in destination type"
            -> SIGABRT (rc=134)
```

### 反汇编定位实录

从未 strip 的崩溃 .so (fd29387d) 反汇编 `bufferDrawChar@vaddr 0x2ad104`:

- `+0x12c` (`0x2ad230`): `tbnz w0, #31, fail` -- `@intCast(x)` 失败分支
- `+0x130` (`0x2ad234`): `tbnz w0, #31, fail` -- `@intCast(y)` 失败分支
- `+0x154` (`0x2ad258`): `tbnz w0, #31, fail` -- `@intCast(scissor.width)` 失败分支
- `+0x178` (`0x2ad27c`): `tbnz w0, #31, fail` -- `@intCast(scissor.height)` 失败分支

4 个 fail 分支统一跳转 `0x2ad610` 引用 `defaultPanic.integerOutOfBounds` (vaddr `0x3509a4`), panic 串 `"integer does not fit in destination type"` 位于 `0x4074a`。

`validateAndIndex@0x2aea54` 证实结构体布局: `width@[0x118]`, `height@[0x11c]`, `scissor_stack@[0xd0/0xd8]`。

### 暴露场景

`Renderable.ts:1521` 的 `_screenX` / `_screenY` 在 thinking 块展开后顶部越出视口或滚动裁剪边界时为负值。经 `Renderable.ts:1424-1434` 的 `pushScissorRect` 进入 `scissor_stack`, 产生负派生 scissor 尺寸。点击展开 thinking 块是概率性触发, 取决于滚动位置、内容宽度、点击时机。

---

## 修复演进

### v1: 仅坐标守卫

```zig
// buffer.zig:925 setVisibleCellWithAlphaBlending
if (x >= 0x80000000 or y >= 0x80000000) return;  // 新增: bit31 早退
if (!self.isPointInScissor(@intCast(x), @intCast(y))) return;
```

效果: FFI 坐标压力测试 2000 次迭代 PASS, 但 **scissor-residual 压测失败** -- `isPointInScissor` 内 `@intCast(scissor.width)` / `@intCast(scissor.height)` 仍然 panic (rc=134)。

教训: 只守坐标入口不够; scissor 尺寸来自 JS 侧 `pushScissorRect`, 同样可携带负派生值跨 FFI。

### v2: isPointInScissor 内饱和钳位 (342d68d)

```zig
// buffer.zig:297-303 isPointInScissor
pub fn isPointInScissor(self: *const OptimizedBuffer, x: i32, y: i32) bool {
    const scissor = self.getCurrentScissorRect() orelse return true;
    // FFI negative-coordinate defense: clamp u32 scissor sizes before @intCast
    const w = @as(i32, @intCast(@min(scissor.width, 0x7FFFFFFF)));
    const h = @as(i32, @intCast(@min(scissor.height, 0x7FFFFFFF)));
    return x >= scissor.x and x < scissor.x +| w and
        y >= scissor.y and y < scissor.y +| h;
}
```

关键设计选择:

| 守卫策略 | 适用场景 | 实现 |
|----------|---------|------|
| bit31 早退 | FFI 入口坐标 (x/y u32) | `if (x >= 0x80000000) return;` |
| `@min(w/h, 0x7FFFFFFF)` 钳位 | scissor 尺寸 (width/height u32) | clamp 后再 `@intCast` 安全转换 |
| 饱和加法 `+\|` | 终点坐标计算 | `x +| w` 不溢出, 超界即被 `@min` 截断 |
| `<= -0x40000000` 早退 | `drawTextBufferInternal` 等 `@intCast(-y)` | 防 `INT32_MIN` 取反溢出 |

效果: FFI 差分压测 (含 `pushScissorRect` toggle 循环) 2000 次迭代新旧 .so 对比 -- 新 .so 全 PASS (rc=0), 旧 .so SIGABRT (rc=134)。TUI smoke 通过。

---

## 复发与根因 (1.18.27 批量包)

### 事实

2026-09-03 发现: 1.18.27 的 pacman 包内嵌 `libopentui.so` **无任何守卫**, `objdump` guard pattern count = 0, attach SIGABRT 依旧。13 版本全线如此。

### 根因链

```
build-libopentui.sh (UNTRACKED 文件, 未纳入 git)
  -> 不应用 patches/opentui/* 补丁
    -> 构建的 .so 是原始无守卫版本

transplant.py:1410
  -> 硬编码 bionic_lib = artifacts/transplant/opentui-bionic/libopentui.so
    -> 该文件 mtime Aug 24, 早于 fix commit 342d68d (Aug 26)
      -> 永远是旧的无守卫 .so

transplant.py 等长换入
  -> 所有版本的 .bun slot 替换同一份旧 .so
    -> 13 版本全量继承缺陷
```

### 伴生发现

老 1.18.21 host bun 缺 `bun:ffi` dlopen (TinyCC disabled), `libopentui.so` 从不可用。`tui_probe` 只测 `--version` (进程存活即 PASS), **不测渲染层**, 掩盖了问题。

### 通用教训

- **公共层陈旧产物复用 = 批量线整批继承缺陷**: 一份 stale .so 经等长换入污染所有版本
- **UNTRACKED 构建脚本 = 不可见退化**: `build-libopentui.sh` 未纳入 git, 补丁应用步骤丢失无人察觉
- **探针必须测到渲染层**: `--version` 通过不代表 TUI 可用; 必须 pty 冒烟 + panic 扫描

---

## 公共层根治架构

### canonical 构建五步 (build-libopentui.sh)

```
Step 1: 补丁全应用
  -> reverse-first: 先 reverse, 再 git apply patches/opentui/*.patch
  -> 确保幂等: 无补丁时干净, 有补丁时不重复

Step 2: zig 0.16 bionic 构建
  -> zig build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
  -> NDK bionic sysroot + libm

Step 3: objdump guard 自检 (fail-loudly)
  -> 扫描 guard-owning symbols 内编译后的守卫 pattern
  -> 未检测到 clamp/csel 指令 = 构建失败

Step 4: ffi_guard_harness.c (hostile FFI harness)
  -> dlopen + dlsym 所有 FFI 入口
  -> 注入 bit31 坐标 drawChar + INT32_MIN grayscale + 巨型 fill/scissor
  -> exit=0 才放行; exit=134 (SIGABRT) = 构建失败

Step 5: 装槽位
  -> llvm-strip -> cp -> 清理 build artifacts
```

### swap_tui.py 守卫验证

`has_ffi_guard()` 扫描 ELF 内 guard-owning symbols (如 `bufferDrawChar`, `isPointInScissor`) 的代码段, 检测编译后的守卫 pattern:
- `mov wN, #0x7fffffff` 钳位指令 (MOVN #0x8000, LSL#16)
- `csel ..., vs` 饱和加法分支

未检测到守卫 pattern -> 拒收该 .so, `swap_tui.py` 退出码 5。

### tui_smoke.py pty 冒烟

```
1. 打开 pty, 启动 opencode 进程
2. 等待 TUI 渲染 (检测 ANSI 序列)
3. 执行交互操作 (打开 session, 点击 thinking 块)
4. 扫描 stderr/进程输出中的 panic 关键字
5. 运行时提取内嵌 .so (从 /proc/<pid>/maps + dd)
6. 对提取 .so 运行 has_ffi_guard 验证
```

---

## 补丁覆盖清单

### fix-drawchar-negative-coords.patch (buffer.zig + renderer.zig, packages/core)

| # | 文件:位置 | 守卫类型 | 防御的输入形态 |
|---|----------|---------|--------------|
| 1 | `buffer.zig:297-303` `isPointInScissor` | `@min(w/h, 0x7FFFFFFF)` + `+\|` 饱和加法 | 负派生 scissor 尺寸跨 FFI 变 u32 |
| 2 | `buffer.zig:320-324` `clipRectToScissor` | 同上 | 同上 (clipRect 终点计算) |
| 3 | `buffer.zig:807` `setVisibleCellWithAlphaBlending` | `if (x >= 0x80000000 or y >= 0x80000000) return;` | FFI 坐标 bit31 set |
| 4 | `buffer.zig:838` `setCellWithAlphaBlendingRaw` | 同上 | 同上 |
| 5 | `buffer.zig:1248` `drawTextBufferInternal` | `if (y <= -0x40000000) return;` | `INT32_MIN` 取反溢出 |
| 6 | `buffer.zig:2131` `drawGrayscaleBuffer` | `if (posX < -0x40000000 or posY < -0x40000000) return;` | 同上 (灰度缓冲区) |
| 7 | `buffer.zig:2200` `drawGrayscaleBufferSupersampled` | 同上 | 同上 (超采样灰度) |
| 8 | `renderer.zig:936/995/1000` hit-grid scissor | `@min(clipped.w/h, 0x7FFFFFFF)` + `+\|` | renderer 命中网格 scissor |

### ffi-int-truncation-guards.patch (packages/native)

覆盖 `packages/native/src/buffer.zig` 和 `renderer.zig` 中与 core 树同构的函数: `setCellWithAlphaBlendingCellWithoutImages` (:908), `setCellWithAlphaBlendingRawCell` (:964), `drawTextBufferInternal` (:1661), `drawGrayscaleBuffer` (:2828), `drawGrayscaleBufferSupersampled` (:2897), `renderer` hit-scissor (:2824/2885/2959)。守卫模式与 core 树完全一致。

### SAFE 不改清单

| 位置 | 原因 |
|------|------|
| `setCell` (非 Blending 变体) | 不经过 `@intCast` 到 i32, 直接作为 u32 索引使用 |
| `OptimizedBuffer.set` / `get` | 内部全 u32 运算, 不涉及有符号转换 |
| `blendCells` | 纯 u32 算术, 无 `@intCast` |
| `getCurrentScissorRect` 返回值 | 返回 `?ClipRect`, 裁剪判定由调用方 `isPointInScissor` 处理 |
| `pushScissorRect` 调用侧 | 负值合法 (表示视口外), 由 scissor 守卫端吸收 |

---

## 验证矩阵

### 13 版本重建结果

| 版本 | 守卫验证 (guard_check) | smoke (render) | 版本匹配 (tar) | SHA ok |
|------|----------------------|----------------|----------------|--------|
| 1.18.15 | PASS | PASS | PASS | PASS |
| 1.18.16 | PASS | PASS | PASS | PASS |
| 1.18.17 | PASS | PASS | PASS | PASS |
| 1.18.18 | PASS | PASS | PASS | PASS |
| 1.18.19 | PASS | PASS | PASS | PASS |
| 1.18.20 | PASS | PASS | PASS | PASS |
| 1.18.21 | PASS | PASS (rebuild) | PASS | PASS |
| 1.18.22 | PASS | PASS | PASS | PASS |
| 1.18.23 | PASS | PASS | PASS | PASS |
| 1.18.24 | PASS | PASS | PASS | PASS |
| 1.18.25 | PASS | PASS | PASS | PASS |
| 1.18.26 | PASS | PASS | PASS | PASS |
| 1.18.27 | PASS | PASS | PASS | PASS |

注: 1.18.21 初次 smoke FAIL (render=NO, guard=no-so), 原因: 旧 host bun 缺 `bun:ffi` dlopen。通过 `make transplant VER=1.18.21` 新鲜重建后 PASS。

### Golden 回归

| golden | 状态 |
|--------|------|
| 1.2.9 | PASS |
| 1.3.11 | PASS |
| 1.3.13 | PASS |
| synth-36b | PASS |

### Attach 冒烟

```
opencode attach localhost:4097 -s ses_f94b5affcffe0qtniR5tEoeXKT
-> render=yes, panic=no, exit=0
```

### 差分 FFI 压测

| .so | 坐标压力 2000 iter | scissor-residual 2000 iter |
|-----|---------------------|---------------------------|
| 新构建 (guard=OK) | PASS (rc=0) | PASS (rc=0) |
| 旧崩溃 .so (fd29387d) | SIGABRT (rc=134) | SIGABRT (rc=134) |

---

## 遗留风险

1. **guard 机器码 pattern 依赖编译器**: `has_ffi_guard()` 扫描 `mov wN, #0x7fffffff` 和 `csel ..., vs` 指令 pattern。zig 0.16 + NDK r29 aarch64 当前输出这些 pattern, 但 zig 版本升级或 NDK 变更可能改变编译器输出, 导致 guard scan 误判。需在 zig/NDK 升级时重新验证。

2. **crhandler 逐版 ABI 未审计**: seccomp SIGSYS shim (`libopencode-crhandler.so`) 作为 `DT_NEEDED` 被注入每个版本的二进制。当前只验证了存在性和 dlopen 成功, 未逐版审计 ABI 兼容性。

3. **tui_smoke 暖缓存依赖**: pty 冒烟依赖 bun 编译缓存 (`$HOME/.bun/install/cache`)。冷缓存环境下首次启动可能超时, 导致 smoke 误判 FAIL。

4. **0.1.101 profile 弃用警告**: zig 0.16 构建时输出 `warning: ...deprecated in newer Zig versions` (profile `aarch64-linux-android`), 不影响编译但可能在 zig 0.17+ 成为硬错误。

---

## 索引

### 提交链

| commit | 日期 | 说明 |
|--------|------|------|
| `342d68d` | 2026-08-26 | crashfix v2: guard negative FFI coords in bufferDrawChar |
| `17b51a4` | 2026-09-04 | 公共层根治: common-layer libopentui guard, 拒收无守卫 swap |
| `10afa28` | 2026-09-04 | 公共层扩展: wire libopentui common layer + extend guard patch |
| `faf1334` | 2026-09-04 | P5 hardening: w7b native recipe, pty smoke gate, truncation guard |

### 补丁文件

| 路径 | 目标树 | 守卫点数 |
|------|--------|---------|
| `patches/opentui/fix-drawchar-negative-coords.patch` | packages/core/src/zig | 8 |
| `patches/opentui/ffi-int-truncation-guards.patch` | packages/native/src | 8 |

### 脚本

| 路径 | 功能 |
|------|------|
| `tools/transplant/build-libopentui.sh` | canonical 五步构建管线 |
| `tools/transplant/swap_tui.py` | 等长 slot swap + `has_ffi_guard` 拒收 |
| `tools/transplant/tui_smoke.py` | pty 冒烟: render + panic scan + runtime .so 提取 |

### Evidence 日志

| 路径 | 内容 |
|------|------|
| `.omo/evidence/task-crash-alpha260825.log` | 原始 DIAG1/DIAG2 崩溃诊断链 |
| `.omo/evidence/task-tui-common-fix.log` | 公共层根治五阶段 (T1-T2, P3-P5) |
| `.omo/evidence/task-w10a-tui-deep-smoke.log` | W10a 深度 TUI 冒烟 |
| `.omo/evidence/task-w7b-opentui-bionic.log` | W7b opentui bionic 构建 |
