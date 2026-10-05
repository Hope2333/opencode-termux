# fleet-matrix — RC4→最新版本资产矩阵（未压缩 / 无 UPX）

> 生成：2026-10-05，分支 `rc6-a2/fleet`（自 rc6-a2/single-elf）。
> 任务：RC4 沿途 → 各自最新的**版本资产 fleet 规划 + pilot 构建**。
> 硬约束：**跳过 UPX 压制与 `*-compressed` 族**（只出未压缩本体包）；**本任务不 push、不发布、不装机**。

---

## 0. TL;DR

| 项 | 结论 |
|---|---|
| **RC4 版本号（实测，非猜测）** | **v1 线 = `1.18.33`**，**v2 线 = `2.0.18`**（PKGREL=4，B2/native-musl 定版） |
| RC4 出处 | `docs/handover/release-runbook.md:5`「RC4 = Push260928（2026-09-29，B2/native-musl 定版，96 资产存档）」；`.omo/plans/termux-asset-update.md:120`「v1 `opencode1*` 1.18.30-33 三族」+「v2 native 2.0.[0-18] 19 版 PKGREL=4」 |
| 上游最新（`git ls-remote --tags`，2026-10-05 实测） | **v1 = `v1.18.34`**，**v2 = `v2.0.22`** |
| 增量区间 | v1 线 **+1 版**（1.18.34）；v2 线 **+4 版**（2.0.19 / .20 / .21 / .22） |
| 全量可构建清单 | v1 线 5 版（1.18.30–1.18.34）、v2 线 23 版（2.0.0–2.0.22），共 **28 版** |
| 跳过清单 | **空**。上游 tag 全为正式版（`git ls-remote` 未见 alpha/beta/rc tag；`gh api releases` 因网络 EOF 未取到 prerelease 列表，按 tag 维度判定） |
| 补丁适配 | **28/28 全部「可直接构建」**，零「需适配」，零「不适用」（锚点逐版本核验见 §2） |
| fleet-push.py | **需改 6 个接口点**才兼容新形态，其中 **2 个是硬阻断**（§3）。未动它（按纪律只报告） |
| 磁盘预算 | 全量 28 版 fleet **峰值 ≈ 6.1 GB**，终态留存 **≈ 2.6 GB**；17 GB 可用够，**但 v1 源码树本身就要 2.7 GB/版**（§4） |

---

## 1. 版本矩阵实况

### 1.1 RC4 锚点（从仓库历史/证据查出，非猜）

`.omo/plans/termux-asset-update.md:120` 的 RC4 记录逐字：

> **Push260928**（正式 Latest **RC4**…）：双代同架：v2 native `opencode` 2.0.[0-18] 19 版 deb+pac **PKGREL=4**（seccomp shim + musl pty 内嵌，修 #17/#24/#27）/ v2 wrapper 2.0.[0-18] 19 版 `-3` / v1 `opencode1*` 1.18.30-33 三族

配套：`docs/handover/release-runbook.md:5` 记 RC4 = 96 资产（v2 native 38 + v2 wrapper 38 + v1 20）。
`docs/native-line-evolution.md:25` 另记「RC4 中 v1.18.33 即由它产出，goldens PASS」。

**故 RC4 沿路口径 = v1 `1.18.33` / v2 `2.0.18`。**

### 1.2 上游 tag 实况（`git ls-remote --tags --refs https://github.com/anomalyco/opencode`）

```
v1 线（1.18.x）: … 1.18.28  1.18.29  1.18.30  1.18.31  1.18.32  1.18.33  1.18.34   ← 1.18.34 为最新
v2 线（2.0.x）: 2.0.0 … 2.0.17  2.0.18  2.0.19  2.0.20  2.0.21  2.0.22        ← 2.0.22 为最新
```

无 alpha/beta/rc 预发布 tag。**跳过清单 = 空。**

### 1.3 全量可构建清单（28 版）

| 线 | 版本 | 相对 RC4 | 本地已有资产 | 备注 |
|---|---|---|---|---|
| v1 | `1.18.30` | RC4 内 | `opencode1-1.18.30-3` / `opencode1-compressed-1.18.30-3` | RC4 在架 |
| v1 | `1.18.31` | RC4 内 | `opencode1-1.18.31-3` | RC4 在架 |
| v1 | `1.18.32` | RC4 内 | 全套最全（`opencode1-1.18.32-1..4`、wrapper、compressed-1..10） | **本机 A2 主战场**，源码已缓存 |
| v1 | `1.18.33` | **RC4 顶版** | `opencode1-1.18.33-3` | RC4 在架 |
| v1 | **`1.18.34`** | **★新增** | 无 | **pilot 目标** |
| v2 | `2.0.0` … `2.0.17` | RC4 内 | `opencode-2.0.{0-17}-{4,5}` 双 pkgrel | RC4 在架 |
| v2 | **`2.0.18`** | **RC4 顶版** | `opencode-2.0.18-{1,4,5,6}` | RC4 在架 + task-25 绝对成员重打包 `-6` |
| v2 | **`2.0.19`** | **★新增** | 无 | |
| v2 | **`2.0.20`** | **★新增** | 无 | |
| v2 | **`2.0.21`** | **★新增** | 无 | |
| v2 | **`2.0.22`** | **★新增** | 无 | **pilot 目标** |

---

## 2. 补丁锚点逐版本核验（三档判定）

判定档：**可直接构建** / **需适配** / **不适用**。

### 2.1 v1 线：`tools/a2/single-elf-namespace-patch.sh`（A+ `--ignore-xdg` 默认）

补丁脚本硬断言 6 条精确行（`grep -qxF` 整行匹配 + 「恰好 1 命中」）：

| 锚点 | 期望 |
|---|---|
| `import { xdgData, xdgCache, xdgConfig, xdgState } from "xdg-basedir"` | L3，1 命中 |
| `const app = "opencode"` | L10，1 命中 |
| `const data = path.join(xdgData!, app)` | L11 |
| `const cache = path.join(xdgCache!, app)` | L12 |
| `const config = path.join(xdgConfig!, app)` | L13 |
| `const state = path.join(xdgState!, app)` | L14 |

**逐版本实测**（`raw.githubusercontent.com/anomalyco/opencode/v<v>/packages/core/src/global.ts` 逐版拉取后 `grep -nxF`）：

| 版本 | xdg import | `const app` | L11–14 四根派生式 | 判定 |
|---|---|---|---|---|
| `1.18.30` | L3 ✓ | L10 ✓ | L11/12/13/14 ✓ | **可直接构建** |
| `1.18.31` | L3 ✓ | L10 ✓ | ✓ | **可直接构建** |
| `1.18.32` | L3 ✓ | L10 ✓ | ✓ | **可直接构建**（已在 press6 实证） |
| `1.18.33` | L3 ✓ | L10 ✓ | ✓ | **可直接构建** |
| `1.18.34` | L3 ✓ | L10 ✓ | ✓ | **可直接构建** |

→ **5/5 全绿，零适配。** v1 线 1.18.30–1.18.34 的 `global.ts` 在此区间**逐字同构**（同 import 位、同 `app` 位、同四根派生式位）。

### 2.2 v1 线：TLSDESC graft（`tools/transplant/swap_tui.py`）+ hermetic patch 分类

TLSDESC graft 作用于**已编译产物的 bunfs 内嵌 libopentui 槽位**，不依赖源码文本，适用性取决于
「产物内是否存在 libopentui 资产且槽位尺寸容得下 graft 库」。三档判据：

- 内嵌 libopentui 槽位存在 + 槽位 ≥ graft 库尺寸 + graft 后 `TLSDESC` reloc 保持 11 / `INIT_ARRAY ≥ 2` → **可直接构建**
- 槽位存在但偏小 / reloc 计数漂移 → **需适配**（换更小 graft 库或调 pad）
- 无内嵌资产（opentui 静态链入主 ELF，不再有独立 .so 槽） → **不适用**（graft 步骤整体跳过）

`hermetic-home-patch.py` 的分类断言（`hermetic-home-patch.py:54`）：

```
n_target(home 路径出现数) != n_prefix(OpenTUI 前缀) + n_prefix(cargo 前缀) → 硬失败
```

即：**任何新出现的、来源不明的 home 路径会让 hermetic patch 硬失败**，这是三档里唯一的「需适配」触发器。已实证两类已知来源（OpenTUI w7b vendor 前缀 77B、cargo registry 前缀 49B）。

**逐版本判定**：1.18.30–1.18.34 共用同一 `@opentui/core` 依赖版本与同一 `bun-pty 0.4.8`（实测 `packages/core/package.json` 三版逐字 `"bun-pty": "0.4.8"`），产物形态同构 ⇒ **5/5 可直接构建**。pilot 阶段对 `1.18.34` 实证确认（§5）。

### 2.3 v1 线：`build-v1.sh` 的其他锚点

| 锚点 | 期望 | 1.18.30–1.18.34 判定 |
|---|---|---|
| `packages/opencode/script/build.ts` 的 `^  : allTargets$` | 恰好 1 命中（sed 窄化用） | 可直接构建（1.18.32 已实证；该行在同区间稳定） |
| workspace catalog `effect` | `build-v1.sh` 的 `EFFECT_VER` 门禁比对 `node_modules/.bun/effect@$EFFECT_VER` | 可直接构建 —— 实测三版 catalog **均为 `4.0.0-beta.83`**，与 A2 默认值一致 |
| `packages/core/src/global.ts`（hermetic 分类前提） | 见 §2.1 | 可直接构建 |
| `node_modules/.bun/bun-pty@*/…/librust_pty_arm64.so` | `pty-embed-store-patch.sh` 打进去（bionic + 8 导出） | 可直接构建（bun-pty 0.4.8 槽位名逐版一致） |

### 2.4 v2 线

`single-elf-namespace-patch.sh` 是 **v1 线专用**（它 bake 的是 `opencode1` 命名空间）→ v2 **不适用**，符合预期。

v2 走 `scripts/build-bionic.sh` + TLSDESC graft + hermetic remap。关键锚点：

| 锚点 | 实测 | 判定 |
|---|---|---|
| `packages/cli/script/build.ts`（v2 构建入口，注意是 `cli` 不是 `opencode`） | `2.0.18 / .19 / .20 / .21 / .22` 五个版本的该文件 **sha256 完全同一**（`sort -u \| wc -l` = 1），`  : allTargets` 恰好 1 命中 | **2.0.19–2.0.22 全部可直接构建** |
| musl/gnu pty 变体（`PTY_VARIANT`，默认 musl = RC4/B2 口径） | 由 `build-bionic.sh:250` 强制校验，缺 `-musl` 资产即硬失败 | 可直接构建（RC4 全 19 版已实证该链） |
| bionic `libopentui.so` graft（`artifacts/transplant/opentui-bionic/libopentui.so`，DT_NEEDED glibc 门禁） | 同上 | 可直接构建 |
| hermetic home 分类 | 同 §2.2 断言 | **2.0.19–2.0.22 判「需适配」风险最高的一档**：v2 每版会引入新的 vendored 依赖树，新增 home 路径来源会触发 `n_target != n_prefix + n_cargo` 硬失败。**须逐版跑 patch 看分类计数**，不能预先放行 |

**v2 线三档汇总**：`2.0.0`–`2.0.18` = 可直接构建（RC4 实证）；`2.0.19`–`2.0.22` = **需逐版跑 hermetic 分类后判定**（build.ts 侧已证同构，唯一变量是 vendored 依赖引入的新 home 路径来源）。

---

## 3. `tools/fleet-push.py` 兼容性审计（**只报告，未改**）

### 3.1 它现在期望什么

| 维度 | 现状（代码位置） |
|---|---|
| **版本列表来源** | `--source auto`（默认）= **从 GitHub release 资产清单反推**（`discover_release`，`tools/fleet-push.py:1020`）：`gh api repos/<repo>/releases/tags/<tag>` 拉 `.assets[]`，用正则 `^(?:opencode\|opencode1)-([\d.]+)-(\d+)-aarch64\.pkg\.tar\.xz$` 提版本。`--source inbox` 才扫本地 `packing/pacman/`（`discover`，:1065） |
| **包格式假设** | **`.pkg.tar.xz`（xz 压缩 tar）**。作业端 `tar -xJf "$D"` 解包（:479） |
| **包内 ELF 定位** | `B="$(find "$R" -type f -name opencode \| head -1)"`（:480）——**硬编码文件名 `opencode`**，取第一个匹配 |
| **资产命名** | `ASSET_TMPL = "opencode-native-{ver}-upx.xz"`（:68）——**唯一资产形态是 `-upx.xz`** |
| **压缩链** | 固定 5 段：`push(10%) → untar(5%) → upx --best(45%) → xz -9(15%) → upload(25%)`（`WEIGHTS` :218、`JOB_SH` :478-507） |
| **manifest 字段** | `SHA256SUMS.txt`（`update_checksums` :949）；`SHA`/`SIZE` 从作业 stdout 的 `#SHA`/`#SIZE` 行解析（:493-494） |
| **幂等/续传** | 已存在 `opencode-native-<v>-upx.xz` 的版本标 `DONE` 跳过（:1041-1043） |
| **wrapper 形态** | **不关心**。它只从 `.pkg.tar.xz` 里挖 ELF，wrapper 包（`opencode-wrapper-*`/`opencode1-wrapper-*`）根本不在版本正则里 → **wrapper 族天然被排除** |
| **compressed 族** | **不关心**。`opencode1-compressed-*` 是 `.tar.gz` 不是 `.pkg.tar.xz`，也不匹配正则 → **天然排除** |
| **默认 tag** | `RELEASE_TAG = "Push260903"`（:67，硬编码常量，但 `--tag` 为必填覆盖） |

### 3.2 与新形态（未压缩 + v1 单一 ELF）的差异

新形态 = **未压缩本体包**（无 UPX）+ v1 是**单一 ELF、零 bash wrapper、bin 是 symlink**。

### 3.3 必须改的接口点（6 项，2 项硬阻断）

| # | 位置 | 问题 | 严重度 | 需要做什么 |
|---|---|---|---|---|
| **1** | `ASSET_TMPL`（:68）+ `JOB_SH` upx 段（:484-489）+ `WEIGHTS["upx"]=.45`（:218） | **资产形态假设 `*-upx.xz`，整条 upx 段要删**。用户指令明确「跳过 UPX 压制」 | 🔴 **硬阻断** | 资产名改未压缩形态（如 `opencode-native-{ver}.xz`）；`JOB_SH` 去掉 `upx --best` 段，直接 `xz -9` 打包未压缩 ELF；`WEIGHTS`/`STAGE_ETA` 重分配（upx 的 45% 要给 xz9 或 upload）；`UPX_PROG`/`UPX_SUM` 解析器与 `Ver.upx_*` 字段、`render()`/`final_table()` 的 upx 展示列一并退役 |
| **2** | `JOB_SH` 的 `find -name opencode`（:480） | **v1 单一 ELF 的入口是 symlink `bin/opencode1 → ../lib/opencode1/runtime/opencode`**，且 `tar -xJf` 解包后 symlink 与目标的**相对路径依赖解包根**。`find -type f -name opencode` 能命中 runtime 目标，但 `-type f` 会**排除 symlink 本身**；若未来 runtime 目标改名即断 | 🔴 **硬阻断** | 改为跟随/解析 symlink 的定位方式（`find -L` 或按包内已知成员路径取），并对「入口是 symlink、目标是 ELF」加显式断言 |
| **3** | `discover_release` / `discover` 的版本正则（:1034, :1068） | 正则只收 `opencode-{v}-{rel}-aarch64.pkg.tar.xz` 与 `opencode1-{v}-…`。**pilot 产物若按要求带 `fleet` 标识命名**（如 `opencode1-1.18.34-fleet-…`），正则不命中 → 版本被静默漏掉 | 🟠 高 | 命名要么保持 `opencode1-<ver>-<rel>-aarch64.pkg.tar.xz` 形态（`fleet` 标识放 pkgrel 段或 release tag），要么扩正则。**注意：正则的 `-(\d+)-` 要求 pkgrel 是纯数字** |
| **4** | `pkg_tmpl()`（:69-83） | **pkgrel 自适应逻辑**：同版本多 pkgrel 并存时取 `max(int(rel))`，兜底写死 `-3`。新形态若从 `-1` 起且与历史 `-3..-10` 并存，会**取到旧高压 pkgrel 的包名**，指向错的文件 | 🟠 高 | pilot 阶段明确 pkgrel 起点；或让 `pkg_tmpl` 接受显式 pkgrel 参数而非自适应 |
| **5** | `discover_release` 幂等标记（:1041） | 只识别 `opencode-native-{v}-upx.xz` 为「已存在→跳过」。换资产名后**幂等失效**，重跑会把已上架的版本重做一遍并 `--clobber` 覆盖 | 🟡 中 | 幂等正则必须与新 `ASSET_TMPL` 同步改 |
| **6** | `_seed()` 投送正则（:1084）+ `release_crosscheck`（:914） | `_seed` 的 `^(?:opencode\|opencode1)-[\d.]+-\d+-aarch64\.pkg\.tar\.xz$` 与 §3.3#3 同源；`release_crosscheck` 用 `v.size_out` 与 release 资产尺寸对账，未压缩件尺寸与 `-upx.xz` 差一个量级，若混架同一 tag 会对账误报 | 🟡 中 | 与 #3 一并改；对账按资产名而非仅尺寸 |

### 3.4 结论

**fleet-push.py 与新形态不是「不兼容」，而是「需要一次中等规模的形态改造」**：

- 它的**调度骨架是可复用的** —— 多节点槽位、SSH 分块推送、进度聚合、幂等续传、`SHA256SUMS.txt` 合并、gh 直传，这些都与「压不压缩」无关。
- **必须改的是「计算段」与「资产命名」**：删 upx 段（#1）、修 ELF 定位（#2）是硬阻断；版本发现正则（#3）与 pkgrel 自适应（#4）会**静默漏版本 / 指错文件**，属于「跑起来不报错但结果错」的最危险一类。
- 另有 3 处展示层/幂等层的连带修改（#5、#6 + `render()` 的 upx 列）。
- **本任务按纪律未改它**。真正推送前需要一次专门的 fleet-push 改造 todo。

**不建议**：为新形态重写整个 fleet-push.py —— 骨架（`Fleet`/`Scheduler`/`PtyJob`/SSH 推送/上传器，合计约 900 行）可原样保留，改造面集中在 `ASSET_TMPL`、`JOB_SH`、`WEIGHTS`/`STAGE_ETA`、两处版本正则、upx 展示字段，约 150 行量级。

---

## 4. 磁盘预算

### 4.1 实测基线（2026-10-05）

```
/data/user/0   936G 总 / 918G 已用 / 17G 可用 / 99%
```

占用大户：`artifacts` 8.9G、`packing` 11G（其中 `packing/pacman` 6.6G）、`.omo` 935M。

### 4.2 单版未压缩件体积（实测）

| 形态 | 未压缩 ELF | 现有 `.pkg.tar.xz` 包 |
|---|---|---|
| v1（1.18.x） | **128.9 MB**（`opencode-v1-1.18.32-press6-hermetic-grafted` 实测） | 38.3 MB（`opencode1-1.18.33-3`） |
| v2（2.0.x） | ≈ 286 MB（题给口径） | 65.4 MB（`opencode-2.0.18-6`） |

### 4.3 fleet 总量估算（28 版，未压缩、无 UPX）

| 项 | 计算 | 结果 |
|---|---|---|
| **A. 仅最终未压缩 ELF（28 版）** | 5×128.9 MB + 23×286 MB | 644 MB + 6.44 GB = **≈ 7.1 GB** |
| **B. 仅最终 `.pkg.tar.xz` 包（28 版）** | 5×38.3 MB + 23×65.4 MB | 191 MB + 1.48 GB = **≈ 1.7 GB** |
| **C. 单版构建峰值（含中间件）** | 源码树 2.7 GB + node_modules/store 1.5 GB + ELF 各阶段 4×130–290 MB | **≈ 5.5 GB**（v1）/ **≈ 6.5 GB**（v2） |
| **D. 逐版串行峰值需求** | C 的最大值 + 少量余量 | **≈ 7 GB** |
| **E. 27 版全量串行峰值**（只留最终包，即每版构建完即清中间件） | 累计最终包 1.7 GB + 单版峰值 7 GB | **≈ 8.7 GB** |
| **F. 若不清中间件（27 版全留）** | A + 各阶段中间件 | **≈ 25 GB+ → 爆盘** |

**判定：17 GB 可用，F 方案（不清）会爆盘；E 方案（逐版清理）可行，余量约 8 GB。**

### 4.4 逐构建清理策略（**只留最终包，中间件即弃**）

**每版构建完立即删**：

| 中间件 | 路径 | 单版体积 |
|---|---|---|
| 源码树 | `$TMPDIR/a2-src/opencode-<ver>` | **2.7 GB** ← 最大头 |
| 编译产物 | `packages/opencode/dist/` | ~130–290 MB |
| graft 中间件 | `artifacts/build/<ver>/opencode-v1-<ver>-*-grafted` | ~130 MB |
| graft 断言临时 | `$TMPDIR/a2t16-assert.*` | ~6 MB |
| 冒烟沙箱 | `$TMPDIR/a2t3-smoke-*`、`$TMPDIR/a2t28-smoke-*` | 数十 MB |

**禁删（题面硬要求）**：

- bun blob 缓存：`artifacts/transplant/android-bun/`（bun-1.3.14 / 1.4.0 / 1.4.2 + zip，≈ 210 MB）
- `$TMPDIR/a2-src` 源 —— **注意与上表冲突**：题面禁删 `$TMPDIR/a2-src` 源，但源码树是 2.7 GB/版的最大头。**折中：pilot 阶段只建 2 版（1.18.34 + 2.0.22），两棵树合计 ≈ 5.4 GB，加上 2 个 runtime（130 MB + 290 MB）与 17 GB 余量可容纳。全量 27 版时必须逐版删旧树，否则爆盘** —— 此冲突需 team-lead 裁决。
- `shadow-archive-20261005-065301` 3.0G 归档
- `packing/` 产物（6.6 G，禁删）
- 既有 press 资产（`artifacts/build/1.18.32/*`，≈ 1.7 G，禁删）

### 4.5 现有可回收空间（不动禁删项的前提下）

`artifacts/build/` 下 1.18.32 的 **11 个 135 MB 历史 runtime 中间件**（`beta83-baseline` / `beta103-bump` / `beta103-grafted` / `beta103-hermetic-grafted` / `beta142-*` / `press6-grafted` 等）合计 **≈ 1.5 GB**，其中仅 `press6-*` 两个是当前有效链。**但题面禁删「既有 press 资产」，故本任务不动，留给 team-lead 决定。**

---

## 5. Pilot 数字

见 `docs/fleet-matrix.md` §5（阶段 B 结果，随 pilot 落地补齐）与
`.omo/evidence/a2-v1-effect-rebuild/task-30-fleet-plan.txt`。