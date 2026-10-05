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
| 配方 | v1 = R1（真编译）｜v2 = R2（RC4 已实证件重打包，见 §3 说明） |
| 压缩 | **全部未压缩**（逐包复验 `UPX!` 魔数 = 0） |
| 状态 | 不 push、不发布、不装机；压制外包给下游 |

## 1. v1 线（single-elf 真编译，配方 R1）

| 版本 | 包体字节 | 包体 sha256 | 未压缩 ELF 字节 | ELF sha256 | 隔离 | TUI 冒烟 |
|---|---:|---|---:|---|---|---|
| `1.18.30` | 30,706,956 | `43899086a0d241d9…` | 135,132,928 | `8626c4d9344493c8…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.31` | 30,699,512 | `7767cbaccabfeb3f…` | 135,067,392 | `e764fc04ef546ece…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.32` | 30,701,252 | `ade8c784b3edff18…` | 135,132,928 | `9c10beb174bfeb6f…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.33` | 30,701,844 | `cbf9c1f760fc9fe3…` | 135,132,928 | `c18fadb2487f49d7…` | roots=4/4 decoy=0 | GREEN ✓ |
| `1.18.34` | 30,701,688 | `a4396fbb24f7c513…` | 135,132,928 | `4bc840e1d747f300…` | roots=4/4 decoy=0 | GREEN ✓ |

每版冒烟五项（`tools/a2/fleet-v1-build.sh` 第 7/8 步，硬门禁）：

1. `--version` 对版
2. 隔离假 HOME **四根**全部落位 `$HOME/{.local/share,.cache,.config,.local/state}/opencode1/opencode`
3. **诱饵 XDG 命名空间零外泄**（详见 §3 的判据说明）
4. 真 PTY TUI 一帧 + 键入 `DELTA_keys > 0`（`task-3-smoke.sh` harness，判 verdict=GREEN）
5. 形态自证：home 路径 0、**零 glibc NEEDED**、内嵌 pty 资产、**零 UPX 魔数**

## 2. v2 线（历史形态，配方 R2）

| 版本 | 包体字节 | 包体 sha256 | 未压缩 runtime 字节 | runtime sha256 | hermetic 分类 (n_t/n_opentui/n_cargo) | --version |
|---|---:|---|---:|---|---|---|
| `2.0.0` | 52,417,300 | `72856487954f8bf9…` | 283,899,552 | `85dcfdf8b8674145…` | `46/46/0` | 对版 ✓ |
| `2.0.1` | 52,398,404 | `463ec7960975a35a…` | 283,899,552 | `4bacc7adb71a8a97…` | `46/46/0` | 对版 ✓ |
| `2.0.2` | 52,573,464 | `eab7ca04d86d5006…` | 284,161,696 | `023d61e6b56c48b7…` | `46/46/0` | 对版 ✓ |
| `2.0.3` | 52,588,136 | `3b5f63de97661739…` | 284,292,768 | `46007db6f85a505f…` | `46/46/0` | 对版 ✓ |
| `2.0.4` | 71,823,532 | `f976538b774f3420…` | 310,638,240 | `a630d537509b4553…` | `46/46/0` | 对版 ✓ |
| `2.0.5` | 71,860,988 | `a68f6cb14eabd874…` | 310,769,312 | `2c48e38516bcac59…` | `46/46/0` | 对版 ✓ |
| `2.0.6` | 71,916,252 | `08f7e6df0c5ecc7e…` | 310,900,384 | `72fac23daac097a7…` | `46/46/0` | 对版 ✓ |
| `2.0.7` | 72,119,536 | `1e91cdec842eaa13…` | 310,900,384 | `f4eb6bb9d6ceb365…` | `46/46/0` | 对版 ✓ |
| `2.0.8` | 71,897,060 | `a7915adbd7193475…` | 310,965,920 | `d75782464add40ef…` | `46/46/0` | 对版 ✓ |
| `2.0.9` | 67,256,464 | `b6f0ad3b659568bd…` | 278,853,280 | `c8d8854d7c2d57c5…` | `46/46/0` | 对版 ✓ |
| `2.0.10` | 67,083,268 | `d617d1d29d0dc9a3…` | 278,853,280 | `fdb210e69f82f6d6…` | `46/46/0` | 对版 ✓ |
| `2.0.11` | 67,576,848 | `bcc5059d72cad6af…` | 282,130,080 | `64b7a5dae7cc7c0c…` | `46/46/0` | 对版 ✓ |
| `2.0.12` | 66,850,476 | `20b58176b1a3f339…` | 282,130,080 | `96995024fc2a5e4f…` | `46/46/0` | 对版 ✓ |
| `2.0.13` | 67,496,944 | `7867dc3749acc7c2…` | 282,457,760 | `3f6ab7a58d77cdae…` | `46/46/0` | 对版 ✓ |
| `2.0.14` | 67,388,876 | `9fee5a1e57680a85…` | 282,719,904 | `e9ab4acd92325234…` | `46/46/0` | 对版 ✓ |
| `2.0.15` | 67,356,448 | `f262b3164a9cdc42…` | 283,047,584 | `67afc251f662905d…` | `46/46/0` | 对版 ✓ |
| `2.0.16` | 68,438,440 | `51028b590322baf0…` | 285,603,488 | `58f01aa652cfb3e3…` | `46/46/0` | 对版 ✓ |
| `2.0.17` | 68,351,376 | `5e553f19530a53a1…` | 286,193,312 | `42108b3884eb02ba…` | `46/46/0` | 对版 ✓ |
| `2.0.18` | 68,545,012 | `c097afd84aa460b5…` | 286,258,848 | `6fdef1c68348eb51…` | `46/46/0` | 对版 ✓ |
| `2.0.19` | 68,025,656 | `d6a3291e9fbd8838…` | 0 | `287176352…` | `CLEAN` | 对版 ✓ |
| `2.0.20` | 68,369,420 | `aa1cce015d302a69…` | 0 | `288356000…` | `CLEAN` | 对版 ✓ |
| `2.0.21` | 68,981,716 | `75788c2dbb8deb68…` | 0 | `288552608…` | `CLEAN` | 对版 ✓ |
| `2.0.22` | 68,606,104 | `26e3ad5eb462d3fb…` | 0 | `289207968…` | `CLEAN` | 对版 ✓ |

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

## 4. 复现

```bash
# v1（真编译，单份clone 逐 tag checkout）
VERS="1.18.30 1.18.31 1.18.32 1.18.33 1.18.34" bash tools/a2/fleet-v1-build.sh

# v2（RC4 已实证件重打包）
VERS="$(seq -f '2.0.%g' 0 18)" bash tools/a2/fleet-v2-repack.sh

# manifest 复验 + 重生成
python3 tools/a2/fleet-manifest.py --check
python3 tools/a2/fleet-manifest.py
```

证据：`.omo/evidence/a2-v1-effect-rebuild/task-30-fleet-build.txt`（逐版全过程）、
`task-30-fleet-manifest.tsv`（机器可读一行一版，断线续接靠它）。
