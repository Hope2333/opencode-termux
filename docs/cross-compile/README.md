# 异构架构 / 交叉编译构建体系

> 调研日期 2026-10-05 · worktree `~/develop/ot-docs-ci` @ `736540a` · 分支 `rc6-a2/docs-ci`
> 完整实测原始输出见 `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`（证据编号 E1–E5 引用它）

本目录回答一个问题：**本仓（当前只产 aarch64 + bionic Android 原生包）要扩到非 Android Linux / 其他架构，需要动的是「打包」还是「工具链」？**

结论先行：**是打包活。** bun 的 `--compile --target` 走 npm 预编译 baseline 下载，本机零交叉工具链即在 aarch64 Android 上产出了 x86_64 glibc / x86_64 musl / x86_64 bionic 产物（E1.2/E1.3 实测）。真正的成本集中在**自研 shim 层的移植**与**bun 宿主 libc 误推断的规避**，而这两件事都有明确的可复用路径。

## 文档地图

| 页 | 内容 | 适合谁先读 |
|---|---|---|
| [targets.md](targets.md) | 逐目标成熟度矩阵（工具链/评级/阻塞点/工作量） | 决策者 |
| [toolchains.md](toolchains.md) | bun `--target` 语义、可用 target 清单、**经实测的交叉编译配方**、本机与 CI 工具链现状 | 实现者 |
| [phase1-prereq.md](phase1-prereq.md) | 阶段 1 前置结清：opentui 资产形态、bun 1.4.0 配方核实、**install 门控** | 实现者 |
| [shim-porting.md](shim-porting.md) | 自研层逐项跨构阻塞判定（本仓最关键的判断） | 实现者 |
| [ci-and-emulation.md](ci-and-emulation.md) | Docker/qemu/binfmt/自托管 runner 各方案边界与代价 | 实现者 |
| [plan.md](plan.md) | 分阶段实施计划（阶段/前置/验收/回退） | 执行者 |

证据编号约定：`E*` → `.omo/evidence/.../task-31-crossarch.txt`（本组）；
`P*` → `.omo/evidence/.../task-33-phase1-prereq.txt`（阶段 1 前置）。

## 成熟度矩阵（摘要）

评级定义：**生产可用** = 本仓已有验证闭环；**可用** = 路径清晰、阻塞点已知且可解；**实验性** = 能跑通但缺关键验证；**不可行** = 上游不支持。

| 目标 | 工具链路径 | 评级 | 主要阻塞点 | 工作量 |
|---|---|---|---|---|
| `android-arm64`（现状基准） | 仓内 NDK bionic bun + 自研 shim 全套 | **生产可用** | — | — |
| `linux-x64` glibc | `--compile-executable-path=<glibc baseline>` | **可用** | bionic 宿主 libc 误推断；`process.platform` 烘焙成 `android` | 1–2 天 |
| `linux-arm64` glibc | 同上，arch 换 arm64 | **可用** | 同上（install 门控改 `--cpu=arm64`）；~~N2 已结清~~：opentui 不需编译/移植 | 1–2 天 |
| `linux-x64` musl | `--target=bun-linux-x64-musl` 纯 target | **可用** | 需静态链接 sysroot 策略决策；`libstdc++.so.6` 运行时依赖 | 2–3 天 |
| `linux-arm64` musl | 同上 | **可用** | 同上 | 2–3 天 |
| `android-x64` bionic | `--target=bun-linux-x64-android` | **实验性** | baseline 官方存在（E1.4）；但 bun-pty 需 bionic x86_64 重编 + x86_64 android termios os 模块（E3.7，工作量中）；TLSDESC 手术需 x86_64 对应实现 | 3–7 天 |
| `linux-riscv64` | — | **不可行** | bun `Architecture` 枚举只有 X64/Arm64/Wasm；`raw_syscall6` 对非 x86_64/aarch64 是 `compile_error`（E1.4） | — |

## 三个必须知道的坑（都实测过）

1. **bionic 宿主上 `--target=bun-linux-x64` 静默产出 bionic，不是 glibc**（E1.3）。
   BuildID 与 `--target=bun-linux-x64-android` 完全相同 —— 看起来成功了，其实没换平台。
2. **`process.platform` 会烘焙错**（E1.6 / P13）。`--target` token 与
   `--compile-executable-path` 是**两个独立旋钮**：token 只管 JS 烘焙，路径只管 ELF。
   最阴的失败模式是两者给错组合 —— ELF 看起来完全是 glibc（`readelf` 全绿），
   但 `process.platform` 烘成 `"android"`，opentui 落到 `throw`，**TUI 100% 起不来**。
3. **只给 `--compile-executable-path` 不给 `--target`，arch 也烘焙成宿主 arch**（E1.6）。

> ★ **在 bionic 宿主上产出 glibc 的唯一正解**（P13 五组对照实测）：
> `--target=bun-linux-x64-musl` **与** `--compile-executable-path=<glibc baseline>`
> **同时给**。详见 [toolchains.md §4](toolchains.md#4-交叉编译配方)。

另有两个**静默**陷阱（不报错、退出码 0）：
**`bun install` 在 bionic 宿主上会静默跳过 x64 平台包**
（lockfile 有记录、`node_modules` 空；需 `--cpu=x64 --os=linux` + 干净目录，P15），
以及 **compile 日志里的 baseline 名会谎报**（打印 android 实际是 glibc，P12）。
两条详情见 [phase1-prereq.md](phase1-prereq.md)。

## 推荐方案

**推荐：「方案 A —— bun baseline 打包路线 + CI 原生 runner 验证」**，即
在 bionic 宿主上用 `--target=<musl token>` + `--compile-executable-path=<目标 glibc baseline>`
产出多目标产物，把**验证**（跑起来、TUI smoke、pty、libopentui）放到 GitHub Actions 的
原生 x64 runner 上做。

- 前置条件：改 build.ts 的 target 串 / 引入 baseline 路径；把 `A2_TARGET_FILTER`
  从「只留 linux/arm64/gnu」放宽为按目标参数化（E4.2）；
  **install 加 `--cpu/--os` 门控并撤 bionic platform patch**（P15 / P3）。
- 风险：低。不需要 Rust/Zig/容器/模拟器。
- 增量成本：相对现状 +1–2 天（首个 glibc 目标），此后每目标 +0.5 天。
- 为什么不是别的：见 [plan.md §方案对比](plan.md#方案对比)。

> **为什么不先做 `linux-x64` glibc？** 因为它让**自研 shim 层几乎全部退休**：
> epoll-compat（E3.1）与 sigsys_handler（E3.6）是 aarch64 硬绑定，但 glibc 目标机
> 内核普遍 ≥5.10，`epoll_pwait2`（nr 441）存在 → 不需要 shim；TLSDESC 手术（E3.3）
> 是 bionic <11 专属问题，glibc 动态链接器自己处理 → 也不需要；
> opentui 上游有官方 glibc x64 预编译包，**不需编译或移植**（P1–P7）。
> 反过来 `android-x64` 会让 TLSDESC + bun-pty 两笔成本同时落地。

## 术语与既有资产

- **baseline**：bun 官方预编译二进制，从 npm registry 按
  `@oven/bun-{os}-{arch}[-{libc}][-baseline]` 拉取（E1.4 `compile_target.rs:150`）。
  `baseline` 后缀 = 不要求 AVX2 的保守构建。
- **graft**：把外部 `.so` 塞进目标产物的动作。准确说是**换文件**而非改链接 ——
  opentui 以 RAW 字节内嵌进 bunfs（`/$bunfs/root/libopentui-<hash>.so`），
  **不进 `DT_NEEDED`**（P6/P7）。本仓有四处：opentui graft
  （`tools/a2/build-v1.sh:96-111`）、TLSDESC relax、crhandler DT_NEEDED 手术、pty embed。
- **shim 层**：`tools/epoll-shim/`、`tools/shim/`、`tools/transplant/tlsdesc-shim/`、
  `tools/bun-pty-splice/`、`tools/bun-pty-embed/`。
