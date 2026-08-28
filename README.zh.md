[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux。**主线 = native bionic 直跑线**：经 transplant 复活管线产出的
单个零 glibc Android ELF，以 `opencode` 原名作为正式发布渠道出货。glibc wrapper 线
（继承自原 `pure-android` 线）保留为附录维护。当前分支：`native-android`（默认主线）。

---

## Native 线（主线）：零 glibc 单 ELF 运行时

官方预编译 Android Bun 作底座，把 opencode 的 module graph 移植拼接进同一个 ELF，
经 revive 复活手术后产出单个可直接 execve 的 Bionic 可执行文件。零 glibc 依赖，
要求 Android API >= 28。

### 功能亮点

- ✅ **零 glibc**：不依赖 glibc-repo / openssl-glibc。此前"零 glibc 不可能"的结论
  已被复活手术推翻——真因是 assemble 从未 patch `.bun` 节的 `BUN_COMPILED.size`。
  详见 `docs/transplant.md` §0.1/§0.2。
- ✅ **TUI 完整可用**：NDK 自建的 bionic `libopentui.so` 经
  `tools/transplant/swap_tui.py` 等长换入。W10a 深度冒烟 5/5 通过（真实聊天往返 /
  resize / 干净退出 / 5min 浸泡 RSS 反降）。
- ✅ **原生 watcher**：`tools/watcher/` 提供独立守护模块（`watcher.c`，NDK inotify
  递归监听）+ 插件侧 shim（`shim.js`）。解决上游 `@parcel/watcher` 在 Termux 上
  加载失败导致的完全无文件监听问题。E2E 三类事件 <100ms，kill -9 自愈 ≤612ms。
- ✅ **bin 直放打包**：包内 `bin/opencode` 即真实可执行 ELF，无 bash 启动器包装。
- ✅ **UPX 压缩变体**：同一 native ELF 经 UPX `--best` 压缩，以 `opencode-compressed`
  包家族出货——体积 -71.14%，代价为实测启动变慢。见
  [压缩变体](#压缩变体opencode-compressednative--upx)。

### 工作原理

```
官方 android bun ELF            opencode module graph
        │                              │
        └──────────────┬───────────────┘
                       ▼
    tools/transplant/transplant.py（拼接 + patch）
                       ▼
       revive 复活手术（BUN_COMPILED.size 修复）
                       ▼
  swap_tui.py：bionic libopentui.so 等长换入
                       ▼
     单个可 execve 的 opencode ELF（~180MB）
```

### 安装（主线包名：`opencode`）

native 主线已继承 `opencode` 原名（glibc wrapper 线更名为 `opencode-glibc`，
见[共存矩阵](#包共存矩阵)）：

```bash
# 从 https://github.com/Hope2333/opencode-termux/releases 下载
# ELF 资产名形如 opencode-1.18.21-aarch64-android-native
dpkg -i opencode_<version>_aarch64.deb
# 或
pacman -U opencode-<version>-1-aarch64.pkg.tar.xz
```

```bash
opencode --version   # → 1.18.x
opencode run "hi"
opencode             # TUI
```

### 压缩变体：`opencode-compressed`（native + UPX）

同一复活后的 native ELF，额外经 UPX `--best` 压缩，以 `opencode-compressed`
包家族出货（命令入口仍为 `opencode`）：

| 阶段 | 体积 | 说明 |
|---|---|---|
| 未压缩 native ELF | 179,807,785 B | sha256 `02609002…`（native-beta-260826 构建） |
| UPX `--best` | 51,891,796 B | **-71.14%**，sha256 `30c074ab…` |
| + `xz -9` 上传层 | 50,362,704 B | sha256 `42a0ef39…`；xz 仅再省 ~3%，因 UPX 输出已是高熵数据 |

- **启动代价（实测）**：UPX 解压增加 ~0.7–1.1s（总计 1.9–2.3s vs 未压缩 ~1.1s）。
  要下载体积选 `opencode-compressed`，要启动速度选原生 `opencode`。
- **指纹链**：未压缩 `02609002…` → UPX `30c074ab…` → xz `42a0ef39…`
  （sha256 前缀；完整哈希见 release 说明与 `SHA256SUMS.txt`）。
- **AV 误报声明**：UPX 加壳的可执行文件是杀毒软件误报的常见触发源。使用前请对照
  `SHA256SUMS.txt` 校验下载产物。
- 首次同现于 **Push260828** 发布（四包家族首次同台）：ELF 资产
  `opencode-1.18.21-aarch64-android-native-tui-upx`（+ `.xz`）、包
  `opencode-compressed_1.18.21_aarch64.deb` /
  `opencode-compressed-1.18.21-1-aarch64.pkg.tar.xz`，以及 `SHA256SUMS.txt`。

```bash
dpkg -i opencode-compressed_<version>_aarch64.deb
# 或
pacman -U opencode-compressed-<version>-1-aarch64.pkg.tar.xz
```

### 包共存矩阵

| 包名 | 线 | 命令入口 | 共存关系 |
|---|---|---|---|
| `opencode` | native bionic（主线） | `opencode` | 与 `opencode-glibc`、`opencode-compressed` 互斥 |
| `opencode-compressed` | native bionic + UPX | `opencode` | 与 `opencode`、`opencode-glibc` 互斥 |
| `opencode-glibc` | glibc wrapper（附录） | `opencode` | 与 `opencode`、`opencode-compressed` 互斥 |
| `opencode-glibc-standalone` | glibc wrapper，单版本冻结 | `opencode-glibc` | **可与 `opencode` 共存**；仅作回退 |

三个以 `opencode` 为入口的包通过包管理器冲突机制相互替换；standalone 包使用独立
库路径与独立命令名，因此可作为冻结回退与 native 主线并存。

### 构建

一条龙管线：

```bash
make transplant VER=1.18.21
# extract → detect → convert → patch → assemble → revive → verify
# 直接产出可运行的 opencode-native-revived
```

要点：

- **全版本覆盖**：1.2.x → latest 全线打通。旧 trailer 格式与新版 `.bun` section
  格式（opencode ≥1.18，1.18.21 实证）自动识别。
- **revive 尺寸模式自动选择**：底座 ≤1.3.x 用 reloc 重定位写法，≥1.4.x 用
  plain-offset 直写偏移（自 b09c28c 起按底座版本自动判定）；可用
  `--size-mode reloc|plain-offset` 显式覆盖。新版 section 格式的 graph 必须用
  ≥1.4 底座（见 `tools/transplant/config/bun-bind.json`，target=1.4.0）。
- **TUI 注入**：管线内含 swap_tui 步骤，等长换入 bionic libopentui.so。
- **goldens 回归**：`make transplant-check`（golden-file 回归；fixtures 需先
  `scripts/fetch-fixtures.sh` 预下载）。

### 依赖

| 工具 | 必需？ | 用途 |
|---|---|---|
| python3 | ✅ | 管线本体，纯标准库即可运行 |
| NDK | 仅自建组件时 | 编译 bionic libopentui.so / watcher.c |
| gh / npm / curl | ✅ | 拉取 Bun 底座、opencode 包与 fixtures |

### CI 与验证边界

`.github/workflows/build-native-android.yml`（workflow_dispatch 手动触发）：
在 x86 runner 上执行完整 revive 流程与 golden 回归，产物为 evidence-only
artifact（CI 不执行产物）。**CI 绿 ≠ 可跑**：最终验收必须本机真机终验。
另注意：隔离 HOME 测试需预热缓存镜像，否则二进制会在启动时挂起。

### 发布策略（诚实标注）

> native 线为稳定主线发布渠道。性能现实（实测，非营销话术）：启动 ~1s 量级
> （`--version` 首试 1965ms = Phase B bootstrap ~220ms + Phase C JS 求值 ~820ms；
> <300ms 目标需上游 Bun 改造，当前不可达），体积未压缩 ~180MB / UPX 后 ~50MB。

完整手术原理、config schema、失败预案与 FAQ 见 `docs/transplant.md`；
各运行线对比见 `docs/comparison-runtime-lines.md`。

---

## 分支拓扑

| 分支 | 角色 |
|---|---|
| `native-android` | **默认主线** — native bionic 线（本分支） |
| `glibc` | glibc wrapper 线，附录维护（由 `pure-android` 改名） |
| `archive/glibc-classic` | 旧版 glibc 线，已归档 |

---

## 附录：glibc wrapper 线（继承自 pure-android 线）

bun-termux-loader 包装方案：上游 `opencode-linux-arm64` 是 glibc 链接的
Bun 单文件应用（Bun runtime + JS 编译进单个 ELF）。loader 在其前部拼一个
~12KB 的 Bionic wrapper ELF：读 `/proc/self/exe` 定位 BUNWRAP1 元数据、
抽出内嵌 opencode 二进制，再 mmap glibc 的 ld.so 并跳到其入口
（userland exec，不走 execve），使 `/proc/self/exe` 保持指向自身、
Bun 的 JS 定位不被破坏。

### 依赖

| Package | Required? | Why |
|---------|-----------|-----|
| `glibc` | ✅ Yes | OpenCode binary is glibc-linked; wrapper loads it via glibc's ld.so |
| `openssl-glibc` | ✅ Yes | HTTPS/TLS for API calls |
| `bash` | ✅ Yes | Launcher script |
| `ncurses` | ✅ Yes | TUI support |

### 安装

```bash
# Path A: apt/pkg
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
dpkg -i opencode-glibc_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U opencode-glibc-<version>-1-aarch64.pkg.tar.xz
```

回退包（与 native `opencode` 共存，命令入口 `opencode-glibc`，单版本冻结）：

```bash
dpkg -i opencode-glibc-standalone_<version>_aarch64.deb
# 或
pacman -U opencode-glibc-standalone-<version>-1-aarch64.pkg.tar.xz
```

### 构建

```bash
# 单版本
make all VER=1.17.3 PKG=both

# 批量构建
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1

# 构建流程: clean → runtime(produce-local.sh: npm download + loader wrap)
#          → stage(scripts/build.sh) → deb → pacman
```

### CI

`.github/workflows/build-pure-android.yml`：workflow_dispatch 手动触发，
QEMU aarch64 处理二进制，npm 下载 opencode-linux-arm64 后用预构建
wrapper+shim（`tools/prebuilt/`）包装，上传 artifact 并写 status JSON。

> amd64 (x64) + Android + Termux 组合几乎无真实用户，本项目不提供 x64 资产；
> armv7 32 位依赖链破损严重、修复成本过高，该实验已放弃。

### Launcher 安全机制

- 退出时 TTY 清理（按 exit code 分软/硬清理）
- 陈旧锁清理（`$XDG_STATE_HOME` 下 `*.lock`）
- 默认 `OPENCODE_DISABLE_DEFAULT_PLUGINS=1`

---

## Repository layout

```
.github/workflows/
  build-native-android.yml    Native 线 CI（evidence-only artifact）
  build-pure-android.yml      glibc 线 CI（aarch64）
tools/
  transplant/                 Native 复活管线（transplant.py / revive_patch.py /
                              swap_tui.py / config/bun-bind.json）
  watcher/                    原生 inotify watcher 守护 + shim 插件桥
  produce-local.sh            glibc 线：npm 下载 + loader wrap
  prebuilt/                   glibc 线 CI 用预构建 aarch64 wrapper+shim
scripts/
  fetch-fixtures.sh           transplant-check golden fixtures 预下载
  build.sh                    Stage prefix（glibc 线；STANDALONE=1 出回退包）
  launcher.sh                 Runtime dispatcher（cleanup + exec）
  package/package_deb.sh      DEB builder（opencode-glibc）
  package/package_pacman.sh   Pacman builder（opencode-glibc）
  package/package_deb_native.sh        DEB builder（native opencode）
  package/package_pacman_native.sh     Pacman builder（native opencode）
  package/package_deb_compressed.sh    DEB builder（opencode-compressed）
  package/package_pacman_compressed.sh Pacman builder（opencode-compressed）
  package/package_deb_standalone.sh    DEB builder（opencode-glibc-standalone）
  package/package_pacman_standalone.sh Pacman builder（opencode-glibc-standalone）
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch  Upstream OpenCode Android patches (WIP)
docs/
  transplant.md               Native 线手术权威文档
  comparison-runtime-lines.md 各运行线对比
  dual-track-install.md       各包家族间的 provider 选择
  native-android-research.md  零 glibc 研究史
```

## Related

- OpenCode upstream: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
- Android-native Bun: <https://github.com/Hope2333/bun-termux>
- Upstream Bun (Android builds): <https://github.com/oven-sh/bun>
- Releases: <https://github.com/Hope2333/opencode-termux/releases>

## Metadata

Maintainer: `Hope2333(幽零小喵) <u0catmiao@proton.me>`
