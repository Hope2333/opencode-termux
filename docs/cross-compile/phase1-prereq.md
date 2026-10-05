# 阶段 1 前置：opentui 资产形态与 bun 1.4.0 配方核实

> 本文回答跨构阶段 1 的两个阻塞性不确定项，**结论先行**。
> 证据编号 **P*** → `.omo/evidence/a2-v1-effect-rebuild/task-33-phase1-prereq.txt`
> （与 [shim-porting.md](shim-porting.md) 的 E* 编号区分）。
> 全部为**实测**：bun 1.4.0 android blob 在本机（aarch64/bionic）真实跑出的命令与输出。
> 未能实测的一律显式标注「未取到证据」。

## 0. 两问的结论

### N2：opentui 在 glibc x64 下需不需要交叉编译？——**不需要，上游有官方预编译**

**opentui 在 glibc x64 目标下确实以独立 `.so` 形态存在，但那份 `.so` 由上游 npm
官方提供，我们不需要编译、不需要移植、也不需要把 opentui 源带进跨构管线。**
`@opentui/core` 的 `optionalDependencies` 覆盖 8 个平台，其中
`@opentui/core-linux-x64@0.4.5` 就是 glibc x64 的官方预编译包。

三点实测事实：

1. **`.so` 不在 `@opentui/core` 包内**，而在平台兄弟包。core 包里只有 JS；
   `@opentui/core-linux-x64/` 只有 4 个文件：`libopentui.so` + `index.js` +
   `index.bun.js` + `index.d.ts`。
2. **上游那份 `.so` 是货真价实的 glibc x86-64**（P5）：
   `NEEDED` = `libc.so.6` / `libm.so.6` / `libpthread.so.0` / `libdl.so.2` /
   `ld-linux-x86-64.so.2`。与我们自建的 bionic 版（`NEEDED` = `libc.so` /
   `libm.so` / `libdl.so`，无 `.so.N` 后缀）是**不同的 ABI 家族**——但既然上游
   glibc 版现成，这层差异我们不需要动手处理。
3. **它以 RAW（未压缩）字节内嵌进 bunfs，不进 `DT_NEEDED`**（P6、P7）：
   实测内嵌 blob 与安装的那份 `.so` **13,745,312 字节逐字节完全一致**，
   路径名 `/$bunfs/root/libopentui-<hash>.so`，机制是
   `fileURLToPath(new URL("./libopentui.so", import.meta.url))`
   （bun 的静态可分析资产模式）。

**对阶段 1 的直接影响**：本仓 `tools/a2/build-v1.sh:96-111` 的
「graft bionic `libopentui.so`」在 glibc 线上**对应动作不是移植代码，而是让
store 里出现正确的那个文件**——即用 `@cpu=x64 --os=linux` 装上平台包（P15）。
[shim-porting.md §7](shim-porting.md) 标注的「未取到证据 N2」到此结清。

### N5：bun 1.4.0 是不是同款坑？——**是，且纠正配方需加一个前代理漏掉的前提**

**bun 1.4.0 与 1.3.14 是同款坑，三个坑全部复现，且同样静默**（退出码 0、无 warning、
不报错）。仓内继续用 1.4.0 没问题，不需要回退或升降级。

但实测发现一个**前代理（E1–E5）未识别的关键约束**：

> **`--target` token 与 `--compile-executable-path` 是两个独立旋钮。**
> token 只决定 **JS 层烘焙**（`process.platform`），baseline 路径只决定 **ELF**。
> 要同时得到「linux 烘焙 + glibc ELF」，**必须同时给 musl token 和 glibc 路径**。

5 组对照实测（P13，同一 probe、同一 1.4.0、同一 glibc baseline）：

| 组合 | `--target` | `--compile-executable-path` | 烘焙 platform/arch | 实际 ELF INTERP |
|---|---|---|---|---|
| A | `bun-linux-x64` | 无 | **android** / x64 | `/system/bin/linker64` |
| B | `bun-linux-x64-musl` | 无 | linux / x64 | `/lib/ld-musl-x86_64.so.1` |
| **C** ★ | `bun-linux-x64-musl` | glibc | **linux** / x64 | **`/lib64/ld-linux-x86-64.so.2`** |
| D | `bun-linux-x64` | glibc | **android** / x64 | `/lib64/ld-linux-x86-64.so.2` |
| E | 无 | glibc | **android** / **arm64** | `/lib64/ld-linux-x86-64.so.2` |

只有 **C** 同时拿到「linux 烘焙 + glibc ELF」。

**组合 D 是最阴的失败模式**：ELF 看起来完全正确（glibc interpreter + 全套 glibc
`NEEDED`），但 `process.platform` 被烘成 `"android"`。按 P11，它落到
`resolveNativeLibraryPath` 的 `throw new Error("OpenTUI is not supported...")`
→ **TUI 100% 起不来，而产物本身合法、能跑**。
**只做 `readelf` 验收会漏掉它。**

这也修正了 [shim-porting.md](shim-porting.md) 与 [plan.md](plan.md) 里
「`--target` + `--compile-executable-path=<glibc baseline>`」的表述：
在 bionic 宿主上，光给 glibc 路径（组合 D）**不够**，
「`--target=<glibc token>`」（组合 A）更是自相矛盾。

**额外发现**：`compile` 进度行里的 baseline 名**会谎报**。组合 C/D 都打印
`compile ... bun-linux-x64-android-v1.4.0`，但实际复制的二进制来自
`--compile-executable-path`。**不要拿这行日志判断成功与否。**

## 1. 实测命令与输出摘录

### 1.1 opentui 平台包布局（N2）

```bash
V=/data/data/com.termux/files/usr/tmp/a2-src/opencode-1.18.32
ls -d $V/node_modules/.bun/@opentui*
#  core-linux-arm64-musl@0.4.5  core-linux-arm64@0.4.5
#  core@0.4.5  keymap@0.4.5  solid@0.4.5      ← .so 只在前两个里

# core 的 optionalDependencies（P2）
"@opentui/core-linux-x64": "0.4.5",          ← 目标平台
"@opentui/core-linux-x64-musl": "0.4.5",
# dependencies 里只有纯 JS：bun-ffi-structs / diff / marked / string-width / strip-ansi
```

运行时解析逻辑（P3，`chunk-bun-t2myhmwd.js` 内 `resolveNativeLibraryPath`）：

```js
if (process.platform === "darwin") { ... }
if (true) {                     // ← 原为 process.platform === "linux"，被 bionic 线补丁改成 true
  if (process.arch === "x64") {
    if (process.env.OPENTUI_LIBC === "musl") return (await import("@opentui/core-linux-x64-musl")).default;
    return (await import("@opentui/core-linux-x64")).default;   // glibc 命中
  }
  ...
}
throw new Error(`OpenTUI is not supported on the current platform: ${asset.packageName}`);
```

> ⚠️ `if (true)` 是 `tools/a2/build-v1.sh:118-119` 调
> `tools/build-bionic/apply-platform-patch.sh` 的产物。**跨构 glibc 时必须撤掉**，
> 否则 platform 分支判断完全失效。

### 1.2 内嵌验证（N2 决定性，P6 / P7）

```bash
# 真实安装 + opentui 真实 import 模式
bun140 install --cpu=x64 --os=linux
bun140 build --compile --target=bun-linux-x64-musl \
    --compile-executable-path=<glibc baseline> probe.ts --outfile o-final

readelf -d o-final | grep NEEDED
#  libc.so.6 / ld-linux-x86-64.so.2 / libpthread.so.0 / libdl.so.2 / libm.so.6
#  → 没有 libopentui.so
python3 -c "swap_tui.find_libopentui_asset(...)"
#  offset = 82,482,855
#  prefix = .../$bunfs/root/libopentui-h3hyjpa5.so\0
#  内嵌 blob vs 安装的 .so：前 13,745,312 字节完全一致
```

用本仓**真实产物**交叉验证同一机制（P7）：

```bash
B=artifacts/build/1.18.32/opencode-v1-1.18.32-beta83-baseline   # 136M, bionic v1 build
readelf -d $B | grep -c opentui            # → 0
find_libopentui_asset($B)                  # → offset 130,095,105
#  prefix = .../$bunfs/root/libopentui-kcckf2nc.so\0
#  提取 blob → aarch64, Android 24, NDK r29；与本仓 graft 的 bionic .so 前 6,037,032 字节一致
```

→ 这解释了 `build-v1.sh` 的 graft 机制：**graft 的是「文件」，不是「链接」**。

### 1.3 bun 1.4.0 三坑复现（N5）

```bash
# 坑1：--target=bun-linux-x64 静默产出 bionic
bun140 build --compile --target=bun-linux-x64 probe.ts --outfile o140-linux-x64
#  [18.198s] compile  o140-linux-x64  bun-linux-x64-android-v1.4.0     ← android！
file o140-linux-x64   # interpreter /system/bin/linker64, for Android 28, NDK r27c
# BuildID 与 --target=bun-linux-x64-android 逐位相同 → 同一 baseline
#   e531a52388122a9d12bcca2bfbb09f299c14c405

# 坑2：process.platform 烘焙错
strings -a o140-linux-x64 | grep -oE 'PLATFORM=.{0,40}'
#  PLATFORM=" + "android" + " ARCH=" + "x64"      ← 1.3.14 同样为 android
strings -a o140-musl     | grep -oE 'PLATFORM=.{0,40}'
#  PLATFORM=" + "linux"  + " ARCH=" + "x64"      ← 只有 musl token 烘 linux

# 坑3：不给 --target 则 arch 也烘成宿主（组合 E：产物 x86-64 但烘焙 arm64）
```

1.4.0 vs 1.3.14 对照：三个坑**全部同款**，纠正配方（`--compile-executable-path`）**照旧生效**。

### 1.4 install 门控：阶段 1 真正会卡住的地方（P15）

```bash
# 在 bionic/aarch64 宿主上装 x64 平台包
bun140 install --ignore-scripts
#  Resolved, downloaded and extracted [2]  →  Saved lockfile  →  done
find node_modules
#  node_modules                    ← ★ 空目录！包没落地
grep core-linux-x64 bun.lock
#  "@opentui/core-linux-x64": [..., { "os": "linux", "cpu": "x64" }, ...]
#  → 解析进 lockfile 了，但因宿主 android/aarch64 被**静默跳过解压**。退出码 0，无 warning。
#  只加 flag 不够（命中缓存不重试）：
bun140 install --cpu=x64            # → [8.00ms] done，node_modules 仍空
# 干净目录 + 两个 flag 一起给：
bun140 install --cpu=x64 --os=linux --ignore-scripts
#  + @opentui/core-linux-x64@0.4.5    1 package installed [2.73s]
find node_modules -name '*.so'
#  node_modules/@opentui/core-linux-x64/libopentui.so     ← ★ 成功
```

**配方：`bun install --cpu=x64 --os=linux`，且必须在无旧 `bun.lock`/`node_modules`
的干净目录**（或先删掉），否则命中缓存不会重新解压。

## 2. 阶段 1 go/no-go

**GO（有条件）。**

| 阶段 1 隐含前置 | 判断 | 依据 |
|---|---|---|
| opentui 需交叉编译/移植 | **不需要** | 上游有官方 glibc x64 预编译包 |
| opentui 需以独立 .so 存在 | **是，但上游已提供** | RAW 内嵌进 bunfs，不进 `DT_NEEDED` |
| 需把 opentui 源带进跨构管线 | **不需要** | `optionalDependencies` 覆盖 x64 |
| 需为 glibc 重编 opentui | **不需要** | 官方 `.so` 已是 x86-64 glibc ABI |
| 需移植 epoll-compat / relax_tlsdesc | **不需要** | 承 [shim-porting.md](shim-porting.md) 结论，本任务未推翻 |
| 仓内 bun 1.4.0 能用 | **能，同坑，配方照旧** | P8–P14 |
| 新增阻塞 | **1 个：install 门控** | P15 |

**阶段 1 必须遵守的三条**（违反则**静默**产出坏产物）：

1. `bun install --cpu=x64 --os=linux` 且在干净目录 —— 否则 opentui 平台包不落地（P15）
2. `--target=bun-linux-x64-musl` **与** `--compile-executable-path=<glibc baseline>`
   **同时**给 —— 只给其一出「arch 对但 platform 错」的坏件（P13）
3. 撤掉 `apply-platform-patch.sh` 的 `if (true)` 补丁 —— 它是 bionic 线专用（P3）

**验收判据**：不能看 compile 日志的 baseline 名（谎报，P12），必须三查：
`readelf -l` 看 INTERP + `strings` 查烘焙 platform + opentui 解析分支命中情况。

## 3. 剩余未知

⚠ **未取到证据 N2-a：glibc x64 产物未真机运行。** 本机 aarch64，跑不了 x86-64
二进制。以上全为静态取证（`readelf` / bunfs 字节比对）。
阶段 1 必须在真 linux-x64 上跑 `--version` + TUI 渲染。

⚠ **未取到证据 N2-b：未在完整 opencode 构建上验证内嵌。** P6 是最小复现
（单文件 probe + 真实平台包）。真实构建里 opentui 还经 `@opentui/solid` preload、
`parser.worker.js`、`tree-sitter.wasm` 等多路资产，bunfs 资产表更复杂。
形态应相同（同一 `new URL` 模式），但未取证。

⚠ **未取到证据 N5-a：1.4.0 的 `compile_target.rs` 精确行号。** [shim-porting.md](shim-porting.md)
E1.4 引的是 `bun-src-1.4.2` 的 `:40-46`——行为实测一致，但行号属 1.4.2，
不能当 1.4.0 的行号引用。

⚠ **未取到证据 N5-c：`BUN_COMPILE_TARGET_TARBALL_URL` 在 1.4.0 上的行为**
（E1.4 只证 1.3.14 源码支持）。因 `--compile-executable-path` 已足够，非必需路径。

## 4. 下一验证动作

开工时按序做，任一失败即停：

- **V1** 干净 clone v1.18.32 → `bun install --cpu=x64 --os=linux` →
  断言 `find node_modules -name libopentui.so` **非空**且其 `NEEDED` 是 `libc.so.6`
  （空 → 门控配方失败，阶段 1 停）
- **V2** 用组合 C 跑完整 `packages/opencode/script/build.ts`，产出真 glibc x64 opencode
- **V3** `find_libopentui_asset` 断言内嵌 blob 与 store 那份**逐字节一致**
  （补 N2-b）
- **V4** 必须在真 linux-x64 上跑 `--version` + TUI 渲染（补 N2-a）；
  本机只能静态验收
- **V5** bionic 线回归：确认撤掉 platform patch 后 arm64 产物仍能起 TUI
  （防 glibc 修复踩坏现有主线）
