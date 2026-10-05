# 各目标成熟度矩阵

> 证据编号 E* 指向 `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`。
> 评级：**生产可用** / **可用** / **实验性** / **不可行**（定义见 [README](README.md#成熟度矩阵摘要)）

## 矩阵详表

### `android-arm64` —— 现状基准

| 项 | 内容 |
|---|---|
| 工具链 | NDK r27c 编的 bun 1.4.x bionic blob（NDK，见 E1.2 `file` 输出）；`tools/a2/build-v1.sh` 用 `bun build --compile` 出单文件 ELF |
| 评级 | **生产可用** |
| 阻塞点 | 无（本机 + oscar 3.18/A9 验证过） |
| 自研层 | 全套在用：epoll-compat（内核 3.18 <5.1 无 `epoll_pwait2`）、sigsys_handler、TLSDESC relax（bionic <11）、crhandler、close_range fallback、bionic bun-pty embed |
| 验收现状 | `--version` + `tools/transplant/tui_smoke.py`；oscar 3.18 真机 TUI 冻结（effect beta.83 fiber deadlock）是当前主线议题 |

### `linux-x64` glibc —— **推荐的首个新增目标**

| 项 | 内容 |
|---|---|
| 工具链 | `--target=bun-linux-x64-musl` ＋ `--compile-executable-path=<glibc baseline>`（组合 C，P13 实测；**必须两者同给**） |
| 评级 | **可用** |
| 阻塞点 | ① bionic 宿主 libc 误推断（E1.3）② `process.platform` 烘焙错，且最阴组合是「readelf 全绿但 platform 错」（E1.6/P13）③ 本机无 glibc sysroot → 无法本机验证（E2.5）④ install 门控：需 `--cpu=x64 --os=linux` + 干净目录，否则 opentui 平台包静默不落地（P15） |
| 自研层移植 | epoll-compat **不需要**（目标机内核 ≥5.10 有 `epoll_pwait2`）· sigsys_handler **不需要** · TLSDESC **不需要**（glibc 动态链接器处理）· crhandler 需改 `LIBC_NAME` 为 `libc.so.6`（30–60 min）· close_range fallback arch 无关可直接复用（E3.4/E3.5）· pty 用上游 glibc 预编译（E3.7）· opentui **不需编译/移植**，装官方 `@opentui/core-linux-x64` 即可（P1–P7） |
| 工作量 | **1–2 天**：改 build.ts target 参数化 + 放宽 A2_TARGET_FILTER + install 加 `--cpu/--os` + 撤 bionic platform patch + CI 加 glibc 验证 job |
| 验证方式 | 只能在 CI 原生 x64 runner 或真机做（E2.5 实测 qemu 无 sysroot 失败） |

### `linux-arm64` glibc

| 项 | 内容 |
|---|---|
| 工具链 | 同 `linux-x64`，arch token 换 `arm64` |
| 评级 | **可用** |
| 阻塞点 | 同 `linux-x64`，外加 install 门控要改 `--cpu=arm64 --os=linux`（P15）。~~N2 已结清~~：opentui 不需编译/移植（P1–P7） |
| 自研层移植 | 与 x64 完全相同（shim 层是 aarch64 硬绑定，故 glibc arm64 与 glibc x64 的移植量一样） |
| 工作量 | **1–2 天**（与 x64 共用同一套改动，只换参数） |
| 额外价值 | 可复用上游 `blacksmith-4vcpu-ubuntu-2404-arm` 那类 ARM runner（E4.1 上游已在用） |

### `linux-x64` musl

| 项 | 内容 |
|---|---|
| 工具链 | `bun build --compile --target=bun-linux-x64-musl`（**纯 target 即可**，E1.2 实测 9.5s 通过） |
| 评级 | **可用** |
| 阻塞点 | ① 产物 NEEDED `libstdc++.so.6` / `libgcc_s.so.1`（E1.3 `readelf -d`）—— 目标机需装 musl 的 libstdc++，或改静态链接 ② 上游 opencode matrix 无 musl 项（E4.1），无前例可抄 |
| 自研层移植 | 同 glibc（shim 全退休） |
| 工作量 | **2–3 天**（多出 libstdc++ 依赖处理与 musl 目标机验证矩阵） |
| 注意 | 这是**唯一不需要任何纠正手段**的目标 —— target 串自带 `musl` token，libc 推断与 platform 烘焙都正确（E1.6 方案 C/D 实测 `"linux","x64"`） |

### `linux-arm64` musl

| 项 | 内容 |
|---|---|
| 工具链 | `--target=bun-linux-arm64-musl` |
| 评级 | **可用** |
| 阻塞点 | 同 musl x64；`libstdc++.so.6` 是 aarch64 musl 生态里的常见坑（Raspberry Pi OS 需 `libstdc++6`） |
| 工作量 | **2–3 天** |

### `android-x64` bionic

| 项 | 内容 |
|---|---|
| 工具链 | `--target=bun-linux-x64-android`（baseline 官方存在，E1.2 实测 385ms 通过） |
| 评级 | **实验性** |
| 阻塞点 | ① **bun-pty**：需把 rust-pty 重编到 bionic x86_64，且需一个 x86_64 的 android termios os 模块（现有 `dcuddeback/termios-rs` 只有 `src/os/android.rs`，未取证是否 aarch64 假设 → N1）。参考 `tools/bun-pty-embed/build-embed.sh:14-20` 的 aarch64 补丁量（139 items）② **TLSDESC**：bionic <11 的 x86_64 对应手术未实现（E3.3，AArch64 的 reloc 编号 0x407/0x406 与 x86_64 的 GOTTPOFF/TPOFF32 完全不同）③ 无真机（x86_64 Android 模拟器/设备） |
| 自研层移植 | epoll-compat + sigsys_handler 需 x86_64 ucontext 移植（`REG_RAX`/`REG_RIP`，pc 步长 2 而非 4）；crhandler 形状断言「bionic aarch64 DYN」要放宽（E3.4） |
| 工作量 | **3–7 天**，且**卡在无验证载体**（这是它评「实验性」而非「可用」的原因） |

> ⚠ TLSDESC 在 x86_64 上的严重性未知。x86_64 Android 设备（ChromeOS / x86 平板 / 模拟器）
> 的 bionic 版本通常较新（≥11），可能根本不需要这层手术 —— 但无法在本机取证。

### `linux-riscv64`

| 项 | 内容 |
|---|---|
| 工具链 | — |
| 评级 | **不可行** |
| 阻塞点 | bun 只支持两个 arch：`src/bun_core/env.rs:173-186` `enum Architecture { X64, Arm64, Wasm }`；`compile_target.rs:341-343` 显式拒绝 wasm，其余未知 token 走 `ParseError::UnsupportedTarget` → `Global::exit(1)`（`:348-385`）。更底层 `src/platform/linux.rs:72-76` `raw_syscall6` 对非 x86_64/aarch64 是 `compile_error!` |
| 结论 | 即使自己编 bun 也编不出 riscv64 支持（要改两个 crate 的架构枚举 + 写 riscv64 syscall asm + 一整套 libc）。**不建议投入** |

## 横向对比：移植成本排序

按「为该目标需要改的自研层工作量」从大到小：

| 目标 | TLSDESC | bun-pty | epoll-compat + sigsys | crhandler | close_range | 净判断 |
|---|---|---|---|---|---|---|
| `linux-riscv64` | — | — | — | — | — | 不可行 |
| `android-x64` | 需 x86_64 实现（贵） | 需 bionic x86_64 重编（贵） | 需移植（~50 行） | 放宽断言 | 复用 | **最贵，且无验证载体** |
| `linux-x64` musl | 不需要 | 上游预编译 | 不需要 | 改名 | 复用 | 中（libstdc++ 处理） |
| `linux-x64` glibc | 不需要 | 上游预编译 | 不需要 | 改名 | 复用 | **最便宜** |
| `linux-arm64` glibc | 不需要 | 上游预编译 | 不需要 | 改名 | 复用 | **最便宜** |

**关键洞察**（E3.1/E3.3/E3.7 的交叉结论）：

- 本仓 shim 层之所以存在，**根因是「Android 3.18 内核 + bionic <11」**，
  不是「aarch64」。换到 glibc/musl Linux，这三个问题（`epoll_pwait2` 缺失、
  TLSDESC 不被处理、bionic dlopen 失败）**全部消失**。
- 唯一在 glibc 目标下成本可能**上升**的组件是 pty —— 但方向相反：
  bun-pty 0.4.8 本来就是给 glibc 用的预编译（E4.3 `package.json:129`），
  glibc 目标**直接命中正确资产**，而 aarch64 Android 目标才需要我们自建 bionic 版（E3.7）。
  即 pty 在跨架构后**变简单**。

## 目标选择决策树

```text
想扩架构？
├─ 要 riscv64？            → 停（bun 不支持，见上）
├─ 要给 Android 桌面/模拟器用？ → android-x64，但先解决「无验证载体」问题
│                             （需采购/借 x86_64 Android 设备，成本 > 技术成本）
└─ 要服务普通 Linux 服务器/开发机？
    ├─ 目标机可控（能装依赖） → linux-x64 glibc  ← 推荐首个
    │                          代价：1–2 天，shim 层全退休
    ├─ 目标机 Alpine 容器    → linux-x64 musl
    │                          代价：2–3 天（libstdc++ 依赖）
    └─ 两者都要              → 先 glibc 后 musl：target 参数化是一次性投入，
                               每加一个 libc 变体只多一行配置
```
