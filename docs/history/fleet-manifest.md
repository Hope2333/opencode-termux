# fleet-manifest — task-30 未压缩本体包 fleet（**不 UPX**）

> 生成：2026-10-05，
> 分支 `rc6-a2/fleet`，生成器 `tools/a2/fleet-manifest.py`。
> 规划见 [fleet-matrix.md](fleet-matrix.md)。
>
> **本文件是结论**：表里每个 sha256/尺寸都是生成时从盘上包体**重算**的，
> 不是 driver 的转述。`tools/a2/fleet-manifest.py --check` 可复验。

## 0. TL;DR

| 项 | 值 |
|---|---|
| 版本数 | **28**（v1 线 5 + v2 线 23） |
| 包体总量 | 1673432972 B ≈ **1.56 GiB** |
| 命名 | `opencode[1]-<ver>-90-aarch64.pkg.tar.xz`（pkgrel=90 为 fleet 专用带，**不带任何额外标识**） |
| 配方 | v1 = R1（真编译 5 版）｜v2 = R2（重打包 19 版）+ R3（真编译 4 版），见 §3 |
| 料源 | **fresh-compile 9 版**（v1 全部 + v2 2.0.19–2.0.22）｜**repack-from-RC4-asset 19 版**（v2 2.0.0–2.0.18）|
| 来源自证 | 9 版真编件逐版核对「上游 tag 解析 commit == 实际 checkout 的 HEAD == 包内 `--version`」，见 `tools/a2/fleet-provenance.py` |
| 压缩 | **全部未压缩**（逐包复验 `UPX!` 魔数 = 0） |
| 键入活性 | v1 = `measured`（`DELTA_keys>0` 逐版 GREEN）｜v2 = **`not-measured-by-this-harness`**（见 §3.5） |
| 状态 | 不 push、不发布、不装机；压制外包给下游 |

## 1. v1 线（single-elf 真编译，配方 R1，料源 fresh-compile）

| 版本 | 料源 | 包体字节 | 包体 sha256 | 未压缩 ELF 字节 | ELF sha256 | 隔离 | TUI 冒烟 |
|---|---|---:|---|---:|---|---|---|
| `1.18.30` | `fresh-compile(single-elf A+)` | 30,706,956 | `43899086a0d241d9…` | 135,132,928 | `8626c4d9344493c8…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.31` | `fresh-compile(single-elf A+)` | 30,699,512 | `7767cbaccabfeb3f…` | 135,067,392 | `e764fc04ef546ece…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.32` | `fresh-compile(single-elf A+)` | 30,701,252 | `ade8c784b3edff18…` | 135,132,928 | `9c10beb174bfeb6f…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.33` | `fresh-compile(single-elf A+)` | 30,701,844 | `cbf9c1f760fc9fe3…` | 135,132,928 | `c18fadb2487f49d7…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.34` | `fresh-compile(single-elf A+)` | 30,701,688 | `a4396fbb24f7c513…` | 135,132,928 | `4bc840e1d747f300…` | roots=4/4 decoy=0 | GREEN ✓ |

每版冒烟五项（`tools/a2/fleet-v1-build.sh` 第 7/8 步，硬门禁）：

1. `--version` 对版
2. 隔离假 HOME **四根**全部落位 `$HOME/{.local/share,.cache,.config,.local/state}/opencode1/opencode`
3. **诱饵 XDG 四根命名空间路径零外泄**（判的是「诱饵下出现 `opencode1|opencode` 命名空间路径 = FAIL」；
   bun 自身转译缓存 `bun/@t@/*.pile` 记 informational **不计分**，理由见 §3.2）
4. 真 PTY TUI 一帧 + 键入 `DELTA_keys > 0`（`task-3-smoke.sh` harness，判 verdict=GREEN）
5. 形态自证：home 路径 0、**零 glibc NEEDED**、内嵌 pty 资产、**零 UPX 魔数**

## 2. v2 线（历史形态；R2 重打包 19 版 + R3 真编 4 版）

| 版本 | 料源 | 配方 | 包体字节 | 包体 sha256 | 未压缩 runtime 字节 | runtime sha256 | hermetic 分类 | TUI |
|---|---|---|---:|---|---:|---|---|---|
| `2.0.0` | `repack-from-RC4-asset` | R2 | 52,417,300 | `72856487954f8bf9…` | 283,899,552 | `85dcfdf8b8674145…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.1` | `repack-from-RC4-asset` | R2 | 52,398,404 | `463ec7960975a35a…` | 283,899,552 | `4bacc7adb71a8a97…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.2` | `repack-from-RC4-asset` | R2 | 52,573,464 | `eab7ca04d86d5006…` | 284,161,696 | `023d61e6b56c48b7…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.3` | `repack-from-RC4-asset` | R2 | 52,588,136 | `3b5f63de97661739…` | 284,292,768 | `46007db6f85a505f…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.4` | `repack-from-RC4-asset` | R2 | 71,823,532 | `f976538b774f3420…` | 310,638,240 | `a630d537509b4553…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.5` | `repack-from-RC4-asset` | R2 | 71,860,988 | `a68f6cb14eabd874…` | 310,769,312 | `2c48e38516bcac59…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.6` | `repack-from-RC4-asset` | R2 | 71,916,252 | `08f7e6df0c5ecc7e…` | 310,900,384 | `72fac23daac097a7…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.7` | `repack-from-RC4-asset` | R2 | 72,119,536 | `1e91cdec842eaa13…` | 310,900,384 | `f4eb6bb9d6ceb365…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.8` | `repack-from-RC4-asset` | R2 | 71,897,060 | `a7915adbd7193475…` | 310,965,920 | `d75782464add40ef…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.9` | `repack-from-RC4-asset` | R2 | 67,256,464 | `b6f0ad3b659568bd…` | 278,853,280 | `c8d8854d7c2d57c5…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.10` | `repack-from-RC4-asset` | R2 | 67,083,268 | `d617d1d29d0dc9a3…` | 278,853,280 | `fdb210e69f82f6d6…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.11` | `repack-from-RC4-asset` | R2 | 67,576,848 | `bcc5059d72cad6af…` | 282,130,080 | `64b7a5dae7cc7c0c…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.12` | `repack-from-RC4-asset` | R2 | 66,850,476 | `20b58176b1a3f339…` | 282,130,080 | `96995024fc2a5e4f…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.13` | `repack-from-RC4-asset` | R2 | 67,496,944 | `7867dc3749acc7c2…` | 282,457,760 | `3f6ab7a58d77cdae…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.14` | `repack-from-RC4-asset` | R2 | 67,388,876 | `9fee5a1e57680a85…` | 282,719,904 | `e9ab4acd92325234…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.15` | `repack-from-RC4-asset` | R2 | 67,356,448 | `f262b3164a9cdc42…` | 283,047,584 | `67afc251f662905d…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.16` | `repack-from-RC4-asset` | R2 | 68,438,440 | `51028b590322baf0…` | 285,603,488 | `58f01aa652cfb3e3…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.17` | `repack-from-RC4-asset` | R2 | 68,351,376 | `5e553f19530a53a1…` | 286,193,312 | `42108b3884eb02ba…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.18` | `repack-from-RC4-asset` | R2 | 68,545,012 | `c097afd84aa460b5…` | 286,258,848 | `6fdef1c68348eb51…` | `46/46/0` | —（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件） |
| `2.0.19` | `fresh-compile(seccomp+graft+hermetic)` | R3 | 68,025,656 | `d6a3291e9fbd8838…` | 287,176,352 | `744c4122228bf84e…` | `CLEAN` | GREEN ✓ |
| `2.0.20` | `fresh-compile(seccomp+graft+hermetic)` | R3 | 68,369,420 | `aa1cce015d302a69…` | 288,356,000 | `2f1cf24addb03382…` | `CLEAN` | GREEN ✓ |
| `2.0.21` | `fresh-compile(seccomp+graft+hermetic)` | R3 | 68,981,716 | `75788c2dbb8deb68…` | 288,552,608 | `8f3341ca9537c55b…` | `CLEAN` | GREEN ✓ |
| `2.0.22` | `fresh-compile(seccomp+graft+hermetic)` | R3 | 68,606,104 | `26e3ad5eb462d3fb…` | 289,207,968 | `8b405d0de6ddacd7…` | `CLEAN` | GREEN ✓ |

每版门禁：零 UPX 魔数 → hermetic 分类断言 CLEAN → 绝对成员
`data/data/com.termux/files/usr/bin/opencode` + `usr/lib/opencode/libopencode-crhandler.so`
双成员齐 → **拒相对 `usr/` 成员**（termux-pacman 绝对约定，task-25） → `--version` 对版。

## 3. 两条需要读懂才能用的口径

### 3.1 v2 为什么是「重打包」而不是重新编译

v2 2.0.0–2.0.18 的 runtime 是 **RC4 沿途已实证的未压缩 ELF**，且与在架包**逐字节同源**
（实测 `opencode-2.0.18-6` 包内 ELF sha256 == `artifacts/build/2.0.18/opencode-native-revived`）。
fleet 的用途是产出给外包压制的未压缩原件，用在架同源件比重编更稳，且省 19 次编译。
实测这些 ELF **`UPX!` 命中 = 0**，本就是未压缩本体，与「本轮不 UPX」一致。

### 3.2 诱饵 XDG 的判据为什么不是「字节数 = 0」

诱饵 cache 目录里会出现 `bun/@t@/*.pile` —— 那是 **bun 运行时自己的转译缓存**，
路径由 bun 按 `XDG_CACHE_HOME` 推导，A+ 只改 `global.ts` 的四根派生，管不到它。
内容是转译后的 JS，**不含 opencode 用户数据**。

对照实测：A2 参照件 `1.18.32-beta103-hermetic-grafted`（**无** A+ bake）诱饵
cfg=3922 / data=7 / state=2 / cache=3 条 —— opencode 自己的四根被 XDG **全量**重定向
（cache 下就是 `opencode/bin`、`opencode/models.json`），那才是命名空间泄漏。
本 fleet 件（A+ bake）诱饵 cfg/data/state **全 0**，命名空间零外泄。

故门禁判「诱饵下出现 `opencode1|opencode` 命名空间路径 = FAIL」，bun 自身缓存记 informational。
**已按此实现**：driver 逐版记 `namespace-leak=0` + `bun-runtime-cache=N`，后者不计分。

### 3.3 料源与来源自证（外包取料必读）

| 料源 | 版本 | 含义 |
|---|---|---|
| `fresh-compile` | v1 全部 5 版 + v2 2.0.19–2.0.22（共 9） | 本轮从上游 tag 真编译 |
| `repack-from-RC4-asset` | v2 2.0.0–2.0.18（共 19） | 从 RC4 在架资产提取 ELF 重打包，**与 RC4 在架件逐字节同源** |

「同源」有硬证据：`opencode-2.0.18-6` 包内 ELF 的 sha256 与
`artifacts/build/2.0.18/opencode-native-revived` **完全相同**（实测
`6fdef1c68348eb51ada7bc5025d23ec49fc650666c4a7dcef208ffd15490bbb0`），
且 `UPX!` 命中 = 0（本就是未压缩本体）。

**fresh-compile 9 版的来源三重自证**（`tools/a2/fleet-provenance.py --check --verify-payload`）：

| 版本 | 上游 tag 解析 commit | 实际 checkout 的 HEAD | 包内 `--version` |
|---|---|---|---|
| 1.18.30 | `3104c142` | `3104c142` | `1.18.30` |
| 1.18.31 | `014614d3` | `014614d3` | `1.18.31` |
| 1.18.32 | `545f51d2` | `545f51d2` | `1.18.32` |
| 1.18.33 | `51ef4be1` | `51ef4be1` | `1.18.33` |
| 1.18.34 | `aec0b9a6` | `aec0b9a6` | `1.18.34` |
| 2.0.19 | `1fd016ef` | `1fd016ef` | `opencode v2.0.19` |
| 2.0.20 | `84c9be93` | `84c9be93` | `opencode v2.0.20` |
| 2.0.21 | `8a8bd622` | `8a8bd622` | `opencode v2.0.21` |
| 2.0.22 | `527f0b93` | `527f0b93` | `opencode v2.0.22` |

**版本硬编码疑点的实测结论（CI 代理提出）**：`tools/a2/press-v5.sh` 有 `VER=1.18.32`、
`pty-embed-store-patch.sh` 有 `V1_SRC=…opencode-1.18.32` 与 `VENDOR_SHA`，看着都把版本钉死
1.18.32 —— **未污染本 fleet**：
1. fleet 链路**不调 `press-v*`**（那是 UPX 压制线，本轮跳过 UPX）；
2. 三个被调脚本都**显式传 `V1_SRC`**，默认值不生效；
3. `VENDOR_SHA` 是 **vendor blob 的完整性门禁**，不是 opencode 版本 pin —— 该 blob
   （`tools/bun-pty-embed/vendor/librust_pty_arm64.bionic.so`）是**跨版本通用静态资产**
   （bionic librust_pty，住在本仓 `tools/` 下、不在 v1 源树里），5 版共用同一 blob 正确
   （5 版的 `bun-pty@0.4.8` store 槽位名逐版一致）；
4. 上表逐版三方对账，全部一致。

### 3.4 两条不可省的门禁（都是「不报错但结果错」的教训）

**① 形态一致性 = 与 RC4 在架件成员集逐一比对。** W11 seccomp harden 是 `Makefile`
`transplant` 目标在 build 之后单独跑的一步（`Makefile:296-299`），直编 `build-bionic.sh`
**会漏**。漏掉的后果：PKGBUILD 的 W11 判据「binary 引用 shim 才装 shim」为假 →
**合法地不装** → 包能打出、`--version` 过、TUI 出画，只有并排比才看得出，
而 shim 的 spawn-child fd 卫生机制已失效。已做**双向**硬断言：harden 后
`DT_NEEDED refs>=1`，且包**必须**含 `usr/lib/opencode/libopencode-crhandler.so`。
实测 2.0.19–2.0.22 四版包与 2.0.18 **逐成员 diff 为空**。

**② 任何「条件性必跑」的步骤不得放在 RESUME 等可选块内。** harden 最初被放在
`SKIP_BUILD` 块内，于是 RESUME 路径静默跳过它 —— 包**仍然不带 shim**而 driver 报 DONE。
续接快路径只能省「产物无关」的步骤（编译），**产物相关**的步骤（harden/graft/remap/
形态自证/打包门/冒烟）永远不能跳。

### 3.5 键入活性：v1 measured / v2 not-measured-by-this-harness

| 线 | 键入活性 | 依据 |
|---|---|---|
| v1（5 版） | **`measured`** | `task-3-smoke.sh` 判 `DELTA_keys_window > 0`，逐版 GREEN（实测 4096） |
| v2（4 版真编） | **`not-measured-by-this-harness`** | 见下 |

v2 的 TUI 是**全屏原地重绘**，typescript 字节数恒定，所以 v1 那套「键入窗内字节增长 > 0」
在本 harness 下永远判 RED。对照实验（决定性在第二条）：

| 件 | S1@25s | S3 键入后 | DELTA |
|---|---:|---:|---:|
| 2.0.19（本 fleet 新编） | 12288 | 12288 | **0** |
| 2.0.18（**RC4 已实证在架件**） | 12288 | 12288 | **0** |

第二条证明是 harness 对 v2 的不适配，**不是编译件缺陷**。捕获里 TUI 完整出画。
另测把渲染窗 25s→45s、键入 `z`→`hello`，DELTA 仍 0 且画面哈希不变。

故 v2 判据改为「出画 + 无崩溃 + **画面完整**（输入框提示语 + 状态栏键位提示 +
版本号可见，三者齐）+ `rc != 139`」（`tools/a2/fleet-v2-tui-smoke.sh`），
**键入活性如实记为不可测**，不假装测了。**外包或后续若需真测键入活性，
请用真实交互会话或真 PTY 会话脚本**（例如人工在真机终端里敲键看响应），
不要沿用本 harness 的 DELTA 判据。

## 4. 复现

```bash
# v1（真编译，单份 clone 逐 tag checkout）
VERS="1.18.30 1.18.31 1.18.32 1.18.33 1.18.34" bash tools/a2/fleet-v1-build.sh

# v2 上游新增 4 版（真编译，含 seccomp harden）
VERS="2.0.19 2.0.20 2.0.21 2.0.22" bash tools/a2/fleet-v2-build.sh

# v2 RC4 沿途 19 版（重打包）
VERS="$(seq -f '2.0.%g' 0 18)" bash tools/a2/fleet-v2-repack.sh

# 三项复验
python3 tools/a2/fleet-provenance.py --check --verify-payload   # 来源自证
python3 tools/a2/fleet-manifest.py --check                      # 产物复验
python3 tools/a2/fleet-manifest.py                              # 重生成 md
```

证据：`.omo/evidence/a2-v1-effect-rebuild/task-30-fleet-build.txt`（逐版全过程）、
`task-30-fleet-manifest.tsv`（机器可读一行一版，断线续接靠它）、
`task-30-fleet-provenance.txt`（来源三方对账）。
