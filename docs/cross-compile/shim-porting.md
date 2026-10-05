# 自研 shim 层的跨构阻塞判定

> 本文是本仓跨架构工作的**核心判断**。逐项结论带源码行号，证据编号 E* 指向
> `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`。
> 全部为**源码取证**（读本仓与 bun 仓库真实代码），未取到的一律标注。

## 0. 总结论（先看这个）

**本仓 shim 层的存在理由是「Android 3.18 内核 + bionic <11」，不是「aarch64」。**

把目标换成 glibc/musl Linux 后，三个最重的组件**自动退休**：

| 组件 | 为何存在 | glibc/musl 目标是否需要 |
|---|---|---|
| `epoll-compat` | 内核 3.18 < 5.1 → 无 `epoll_pwait2`（nr 441） | **不需要**（目标机内核 ≥5.10） |
| `relax_tlsdesc` | bionic <11 不处理 `R_AARCH64_TLSDESC` 动态重定位 | **不需要**（glibc 动态链接器处理） |
| bionic `bun-pty` embed | 上游预编译是 glibc 版，bionic dlopen 失败 | **不需要**（上游预编译直接命中） |

唯一在 glibc 下需要**改**（而非重写）的是 `crhandler_patch.py` 的 libc 名。
唯一在 glibc 下**变贵**的是 musl 的 `libstdc++.so.6` 运行时依赖（不是移植，是分发）。

**反直觉的推论**：`android-x64` 是**最贵**的目标（TLSDESC 要写 x86_64 实现 +
bun-pty 要重编 + 无验证载体），因为它要**保留全部 shim 并再写一份 x86_64 版本**。

## 1. `tools/epoll-shim/epoll-compat.c` —— aarch64 硬绑定，但对 glibc 目标不必要

### 现状

文件头 `:23` 自己写明：`aarch64-only by design (this runtime line ships aarch64 ELFs only)`，
并在 `:44-46` 编译期强制：

```c
#ifndef __aarch64__
#error "epoll-compat shim is aarch64-only (runtime line contract)"
#endif
```

架构绑定点（E3.1）：

| 行 | 内容 | arch 依赖 |
|---|---|---|
| `:58-67` | `raw_syscall6`: `register long x8 __asm__("x8") = nr;` + `x0`..`x5` | aarch64 寄存器名 |
| `:92` | `long *regs = (long *)&uc->uc_mcontext.regs[0];` | aarch64 `sigcontext` 布局 |
| `:98` | `regs[0] = ret;` | x0 = 返回值 |
| `:103-104` | `if (uc_mcontext.pc == si_call_addr) uc_mcontext.pc += 4;` | **aarch64 `svc` 定长 4 字节** |
| `:151-161` | libc `syscall` interpose 层的同款寄存器操作 | 同上 |

### 为什么需要（根因）

bun 侧**无条件**发 `epoll_pwait2`，无版本探测。E3.2，`~/develop/bun-src-1.4.2/src/platform/linux.rs:78-102`：

```rust
#[unsafe(no_mangle)]
extern "C" fn sys_epoll_pwait2(...) -> isize {
    unsafe { raw_syscall6(libc::SYS_epoll_pwait2 as usize, ..., 8usize) }
}
```

且 `:72-76` 对非 x86_64/aarch64 直接 `compile_error!`。`raw_syscall6` 两份实现
（`:30-49` x86_64 `syscall`/rax、`:50-71` aarch64 `svc #0`/x8）都是**内联汇编**，
所以 `LD_PRELOAD` 符号拦截看不到（文件头 `:11-14` 记录了实测：纯 interposition
方案在 oscar 上毫无效果，仍是 4.4s SIGSEGV@0x0）。

### 移植判定

| 维度 | 判定 |
|---|---|
| 机制是否 arch 无关 | **是**。seccomp-bpf 过滤 `nr == 441` → `SECCOMP_RET_TRAP` → SIGSYS handler 用 `epoll_pwait(22)` 模拟（timespec→ms 向上取整）→ 写回 x0 → `pc` 跳过 svc。这套逻辑与 arch 无关 |
| 寄存器操作是否可移植 | **需改**。x86_64 `ucontext` 是 `uc_mcontext.gregs[REG_RAX]` / `REG_RIP`，`raw_syscall6` 改 `rax/rdi/rsi/rdx/r10/r8/r9`，`pc` 步长 **2** 而非 4 |
| 改造工作量 | **30–50 行** arch `#ifdef` |
| **对 glibc/musl 目标的必要性** | **0** —— 目标机内核普遍 ≥5.10，`epoll_pwait2` 存在，shim 无用武之地 |
| 对 android-x64 的必要性 | 需要（若目标设备 bionic <11）；x86_64 Android 设备 bionic 版本通常 ≥11，**可能也不需要**（未取证） |

**结论：不移植。** 仅当明确要支持「内核 <5.1 的 x86_64/arm64 glibc 设备」时才做，
届时工作量很小（改 #ifdef）。

## 2. `tools/transplant/relax_tlsdesc.py` —— 完全 AArch64 绑定，但 glibc 不需要

### 现状

文件头 `:20-26` 把根因写得很清楚（E3.3）：

> zig 0.16 硬编码 threadlocal IR mode = `.generaldynamic`；**LLVM 的 AArch64 后端把
> GeneralDynamic 无条件降级成 TLSDESC**（`llvm CodeGenOptions.def`: "AArch64 enables
> TLSDESC regardless of this value"）；zig 不暴露 TLS-model flag；LLD 只在**链接可执行
> 文件时**才 relax（`lld/ELF/Relocations.cpp`: `execOptimize = !ctx.arg.shared && ...`）。
> 结果：每个 zig 编的 aarch64 `.so` 都带 `R_AARCH64_TLSDESC` 动态重定位，bionic <11
> 不处理 → descriptor resolver 保持 NULL → `blr x1` → pc=0 → SIGSEGV SEGV_MAPERR@0x0

它做的事是**离线复刻 LLD 的 `AArch64::relaxTlsGdToIe`**（`:28-41`）：

```
adrp  x0, :tlsdesc:v          →  adrp  x0, :gottprel:v      （同页，槽位地址不变）
ldr   x1, [x0, #:tlsdesc_lo12:v] → ldr x0, [x0, #:gottprel_lo12:v]  （Rt: x1→x0）
add   x0, x0, :tlsdesc_lo12:v  →  nop
blr   x1                       →  nop
```

外加重定位改写 `:42-43`：`R_AARCH64_TLSDESC (0x407)` → `R_AARCH64_TLS_TPREL64 (0x406)`。
另有 `--check` 模式验证无残留（`:36-37`）。

### 移植判定

| 维度 | 判定 |
|---|---|
| 指令序列 | **AArch64 专用**（`adrp/ldr/add/blr` + x0/x1 固定 ABI） |
| 重定位编号 | **AArch64 专用**（0x407/0x406） |
| x86_64 对应物 | 完全不同：LLD 的 `relaxTlsGdToIe` 是**另一份实现**，x86_64 是 `GOTTPOFF` → `TPOFF32`，指令序列与寄存器分配都不同 |
| **能否直接复用** | **否**。属重写而非移植 |
| **对 glibc/musl 目标的必要性** | **0** —— 这层手术的前提是「zig 编的 `.so` 链进 bionic 主 ELF」。glibc 目标下 `.so` 由 glibc 动态链接器加载，TLSDESC 由它处理，不需要离线手术 |
| 对 android-x64 的必要性 | 可能需要（若设备 bionic <11），属**重写**量 |

**结论：glibc/musl 目标不移植。** android-x64 若要支持，需新写一份 x86_64 版
（`relax_tlsdesc.py` 的框架——离线改写 + `--check` 验证——可复用，指令与 reloc 部分重写）。

`tools/transplant/tlsdesc-shim/{tlsdesc-shim.c, tlsdesc_abi_test.c}` 同理，AArch64 专用。

## 3. `tools/transplant/crhandler_patch.py` —— arch 无关，需改 libc 名（**唯一需改的**）

### 现状

`W11 seccomp hardening`：给已 transplant 的原生 ELF 加 `DT_NEEDED libopencode-crhandler.so`，
让 shim 导出的 `syscall()` / `close_range()` 抢占主 ELF 的 PLT（救 spawn-child fd-hygiene）。

`patchelf` 被**明确禁用**（`:11-13`）：它会重建 ELF 并破坏 transplant 输出
（丢 INTERP、把 DYNAMIC relocate 到新 PT_LOAD、改变文件大小；证据 `.omo/evidence/task-w11-crhandler.log`）。

手法（`:14-19`）是零位移外科手术：
1. 校验 transplant 形状；
2. 把 shim 名 / libc 名 / runpath 字符串写进第一个 R-E PT_LOAD 里**不被任何 section 覆盖的
   零填充**（linker 只读 `DT_STRTAB` 字节，padding 是死空间）；
3. 重排 `DT_NEEDED` 让 shim 在链首（bionic 符号查找顺序），被挤掉的 `libc.so` 塞进
   `DT_DEBUG` 槽（仅 debugger 用）；`DT_HASH` → `DT_RUNPATH`；扩展 `DT_STRSZ`
   （否则 bionic Android 16 hard-fail `strtab out of bounds error`，on-device 验证过）；
4. 证明结果：文件大小不变、每个 PT_LOAD phdr 不变、全量字节对比只允许 padding 区
   与四个被挪用的 dynamic entry 不同。

### 移植判定

| 维度 | 判定 |
|---|---|
| C 逻辑 | **纯 ELF 结构操作，arch 无关** |
| arch 依赖点 1 | `:16-19` 形状断言写死 `bionic aarch64 DYN` → x86_64 需放宽 |
| arch 依赖点 2 | `:37-38` `LIBC_NAME = "libc.so"` 是 **bionic** 名字 → glibc 须改 `libc.so.6`（musl 是 `libc.musl-x86_64.so.1`） |
| arch 依赖点 3 | `DT_HASH` 的存在性假设 —— glibc 可能只有 `DT_GNU_HASH`（需确认） |
| 改造工作量 | **30–60 分钟/目标** |
| 必要性 | 取决于是否要保留 seccomp 硬化 + fd-hygiene。**若 glibc 目标不需要这层硬化，可整个跳过**（默认 glibc 无 seccomp 限制，`close_range` 在 ≥5.11 内核原生存在） |

**结论：可复用，改两个常量。** 这是移植成本最低的一处。

## 4. `tools/shim/close_range_fallback.c` —— arch 无关，可直接复用

### 现状

`:5-7` 说明：bun 通过 `syscall(436, ...)` 到达 `close_range`，在 PLT 站点被拦截
（关联 `oven-sh/bun#30766` —— 不 interpose 会直接杀掉进程）。用
`SECCOMP_RET_TRAP` 策略让 raw syscall 不出现，再在 userspace 模拟。

`:27-28` `__NR_close_range 436` —— **x86_64 与 aarch64 同号**。
`:67-80` interpose `long syscall(long number, ...)` 变参，转发 `real_syscall`。
`:14` 注释写构建目标是 `aarch64-linux-android` / bionic。

### 移植判定

| 维度 | 判定 |
|---|---|
| arch 依赖 | **无** —— 走 libc PLT interpose，不是 raw asm |
| syscall 号 | 436 跨 x86_64/aarch64 一致 |
| 变参 ABI | 一致 |
| bionic 依赖 | 仅构建环境（注释 `:14`），源码无 bionic 专有 API |
| 改造工作量 | 接近 0（重新编译即可） |
| 必要性 | glibc 目标：内核 ≥5.11 原生有 `close_range` → **多半不需要**；<5.11 的 glibc 才需要 |

**结论：唯一「arch 无关 + 可直接复用」的组件。** 但 glibc 目标多半也用不上。

## 5. `tools/shim/sigsys_handler.c` —— aarch64 硬绑定

`:38-46` 直书（E3.6）：

> Bionic aarch64 ucontext（`sys/ucontext.h` → `asm/sigcontext.h`）：
> `struct sigcontext { __u64 fault_address; __u64 regs[31]; __u64 sp; __u64 pc; __u64 pstate; }`
> `regs[0] == x0`。SECCOMP_RET_TRAP 时 pc 指向 svc 指令本身（aarch64 上 4 字节）；
> `pc += 4` 跳过它，`x0 = -ENOSYS` 伪造 3.18 的应答。
> Build (Termux NDK-style clang, aarch64 bionic)

实现见 `:96-97`：`uc->uc_mcontext.pc += 4; uc->uc_mcontext.regs[0] = -ENOSYS;`

**移植判定**：与 epoll-compat 同款 —— 机制 arch 无关，寄存器/pc 步长需改。
**20–30 行**。**glibc/musl 目标不需要**（无 seccomp 限制 → 无 SIGSYS）。

## 6. `tools/bun-pty-embed/` —— 真实跨架构阻塞点

### 现状

`build-embed.sh:5-20` 是本仓对 pty 问题的最完整记录（E3.7）：

> **WHY**：v1 的 `bun-pty@0.4.8` store 里带的是 **glibc 预编译**（`librust_pty_arm64.so`）；
> `bun --compile` 会原样内嵌它，而 **bionic dlopen 失败** —— 这正是 compressed line 不得不
> 外挂 `pty/librust_pty_arm64_musl_patched.so` + `shim.so` 的原因。
> 从源码重编 rust-pty 打到 Termux bionic，得到的 `.so` 的 `DT_NEEDED` 只有
> `libc.so`/`libdl.so`、**零 undefined symbol** —— 可被 bun 自己的 asset 机制内嵌
> （`require` → bunfs → `$TMPDIR/.bun-<euid>-<hash>.so` 提取 → dlopen）。
>
> **ANDROID PATCH**：`portable-pty` → `serial` → `serial-unix` → `termios 0.2.2`，
> 而 crates.io 的 `termios 0.2.2` **没有 android os 模块**。`dcuddeback/termios-rs` master
> 加了 `src/os/android.rs`（**139 items**，cfg 接进 `os/mod.rs`）但从未 re-version；
> 于是我们 clone master、把版本钉到 0.2.2、用 `[patch.crates-io]` 喂给 cargo。

### 移植判定 —— **方向与直觉相反**

| 目标 | pty 成本 | 原因 |
|---|---|---|
| `android-arm64`（现状） | **最贵**（已付） | 需自建 bionic 版 + android termios os 模块 |
| `linux-x64` / `linux-arm64` glibc | **最便宜** | `bun-pty 0.4.8` 的预编译**本来就是给 glibc 用的** → 直接命中正确资产 |
| `linux-*-musl` | 中 | glibc 预编译在 musl 上 dlopen 可能失败（`libc.so.6` vs `libc.musl-*.so.1`），需实测 |
| `android-x64` | **贵** | 需重编到 bionic x86_64 + 一个 x86_64 的 android termios os 模块 |

**关键结论**：跨到 glibc 目标后，pty **变简单**而非变难。
「需要 shim/graft」的原因是 bionic，不是架构。

⚠ **未取到证据 N1**：`termios-rs` 的 `src/os/android.rs`（139 items）是否含 aarch64 假设
—— 影响 android-x64 的实际成本。本机 `~/develop/termios-0.2.2-android` 在，
但未取证其 arch 假设。
⚠ **未取到证据 N3**：`bun-pty 0.4.8` 预编译资产的完整架构清单（未在 store 中找到
`prebuilds/` 目录）。

`tools/bun-pty-splice/shim.c`（199 行附近是 PATH search + exec，malloc-free in child）
**无 arch 依赖**（E3.7 grep 只命中一条注释），可复用。

## 7. `libopentui` graft —— glibc 目标不需要移植代码，只需装对平台包

`tools/a2/build-v1.sh:96-111` 把自建 bionic `libopentui.so` 覆盖到 `node_modules` 每个副本，
并 gate 掉 glibc 链接（`readelf -d` 匹配 `NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]` 就拒）。
`tools/build-bionic/apply-platform-patch.sh` 改 `@opentui/core` 的
`platform: process.platform` 探测（v1 `build.ts` 无 `--target`，`--single` 按
`process.platform` 过滤 → 在 android bun 上选出 **ZERO targets**）。

**移植判定：不需要编译、不需要移植、不需要把 opentui 源带进跨构管线。**

- `.so` 不在 `@opentui/core` 包内，而在 8 个 `optionalDependencies` 平台兄弟包之一。
  `@opentui/core-linux-x64@0.4.5` 就是 glibc x64 的**上游官方预编译**
  （P5：`NEEDED` = `libc.so.6`/`libm.so.6`/`libpthread.so.0`/`libdl.so.2`/
  `ld-linux-x86-64.so.2`，与我们自建 bionic 版是不同 ABI 家族但上游已提供）。
- 它以 **RAW 未压缩字节内嵌进 bunfs**（`/$bunfs/root/libopentui-<hash>.so`），
  **不进 `DT_NEEDED`**（P6/P7：内嵌 blob 与安装那份逐字节一致，13,745,312 字节）。
  这解释了 graft 机制：**graft 的是「文件」，不是「链接」**。

**对跨构的准确表述**：不是「baseline 自带 glibc opentui 生效」（baseline 里没有
opentui，opentui 来自 npm 平台包），而是——**bionic 线的动作是「换文件」，
glibc 线的动作是「让 store 里出现正确的那个文件」**，即
`bun install --cpu=x64 --os=linux` 装上平台包（P15）。
两者都不涉及代码移植。

✅ 原「未取到证据 N2」**已结清**，详见 [phase1-prereq.md](phase1-prereq.md)。

⚠ **随之而来的两个新必做动作**（P3/P15，违反则**静默**产出坏产物）：

1. **必须 `bun install --cpu=x64 --os=linux` 且在干净目录**。bionic/aarch64 宿主上
   裸 `bun install` 会**静默跳过** x64 平台包：lockfile 有记录、exit 0、无 warning，
   但 `node_modules` 是空的。只加 `--cpu=x64` 也无效（命中缓存不重试）。
2. **必须撤掉 `apply-platform-patch.sh` 的 `if (true)` 补丁**。它把
   `if (process.platform === "linux")` 改成 `if (true)`，是 bionic 线专用；
   跨构 glibc 时会让 platform 分支判断完全失效。

## 8. 汇总：移植工作量表

| 组件 | 文件 | arch 绑定强度 | glibc 目标是否需要 | 移植工作量 | 优先级 |
|---|---|---|---|---|---|
| `relax_tlsdesc.py` | `tools/transplant/` | **完全绑定**（指令+reloc 编号） | ❌ 不需要 | 重写（仅 android-x64） | 低 |
| bun-pty bionic embed | `tools/bun-pty-embed/` | 需重编 + termios os 模块 | ❌ 不需要（上游预编译命中） | 2–5 天（仅 android-x64） | 中（阻塞 android-x64） |
| `epoll-compat.c` | `tools/epoll-shim/` | **硬绑定**（`#error` + 寄存器 + pc+=4） | ❌ 不需要 | 30–50 行 | 低 |
| `sigsys_handler.c` | `tools/shim/` | **硬绑定**（ucontext 布局） | ❌ 不需要 | 20–30 行 | 低 |
| `crhandler_patch.py` | `tools/transplant/` | **arch 无关**，libc 名绑定 | ⚠ 视是否保留 seccomp 硬化 | 30–60 分钟 | **高（最先做）** |
| `close_range_fallback.c` | `tools/shim/` | **arch 无关** | ⚠ 仅 <5.11 内核需要 | ≈0 | 低 |
| `bun-pty-splice/shim.c` | `tools/bun-pty-splice/` | **arch 无关** | ⚠ 若走外挂路线 | ≈0 | 低 |
| libopentui graft | `tools/a2/build-v1.sh` | bionic 专有 | ❌ 不移植代码；改用 `@cpu=x64 --os=linux` 装平台包 | 参数化 + 撤 platform patch | 中（install 门控是硬前置 P15） |

**给执行者的一句话**：
做 glibc 目标时，**不要移植 shim，要先删 shim 路径**。唯一要动手的是 `crhandler_patch.py`
的两个常量，以及把 `A2_TARGET_FILTER` 参数化。移植 shim 只在 `android-x64` 目标下
才成为必要，而那个目标当前**没有验证载体**（见 [targets.md](targets.md)）。
