[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux，双运行时线：**native bionic 直跑线（主推）+ glibc wrapper 线（稳定附录）**。
当前分支：`native-android`。

> **包名即将变更（过渡公告）：** 现有的 glibc `opencode` 包将更名为 `opencode-glibc`；native bionic 线将继承 `opencode` 名称，并在约 Push 27/28（日期近似）成为稳定渠道。过渡期间两个包可并存安装。请关注 [releases 页面](https://github.com/Hope2333/opencode-termux/releases) 的切换进展。

---

## Native 线（主推）：零 glibc 原生 Android 运行时

官方预编译 Android Bun 作底座，把 opencode 的 module graph 移植拼接进同一个 ELF，
经 revive 复活手术后产出单个可直接 execve 的 Bionic 可执行文件。零 glibc 依赖，
要求 Android API >= 28。

### 功能亮点

- **零 glibc**：不依赖 glibc-repo / openssl-glibc。此前"零 glibc 不可能"的结论已被
  复活手术推翻，真因是 assemble 从未 patch `.bun` 节的 `BUN_COMPILED.size`
  （standalone 检测链在 android bun 中完整存在），详见 `docs/transplant.md` §0.1/§0.2。
- **TUI 完整可用**：NDK 自建的 bionic `libopentui.so` 经 `tools/transplant/swap_tui.py`
  等长换入后 TUI 完整渲染。W10a 深度冒烟 5/5 通过（真实聊天往返 / resize /
  干净退出 / 5min 浸泡 RSS 反降）。
- **原生 watcher**：`tools/watcher/` 提供独立守护模块（`watcher.c`，NDK inotify
  递归监听）+ 插件侧 shim（`shim.js`）+ `install.sh`，解决上游 `@parcel/watcher`
  在 Termux 上加载失败导致的完全无文件监听问题。E2E 三类事件 <100ms，
  kill -9 自愈 ≤612ms。
- **bin 直放打包**：包内 `bin/opencode` 即真实可执行 ELF，无 bash 启动器包装。

### 快速开始（beta 预发布）

native 资产发布在长期 pre-release BETA 渠道（tag 形如 `native-beta-*`）；首个 beta tag：`native-beta-260826`（含 crashfix，commit 342d68d）：

```bash
# 从 https://github.com/Hope2333/opencode-termux/releases/tag/native-beta-260826
# （及后续 native-beta-* tag）下载资产（名形如 opencode-1.18.21-aarch64-android-native-tui）
dpkg -i opencode-native_<version>_aarch64.deb
# 或
pacman -U opencode-native-<version>-1-aarch64.pkg.tar.xz
```

安装 `opencode-native` 会替换 glibc 线的 `opencode` provider（反之亦然），
provider 选择细节见 `docs/dual-track-install.md`。

```bash
opencode --version   # → 1.18.x
opencode run "hi"
opencode             # TUI
```

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

> **native 线资产长期定档 pre-release BETA 渠道**（`native-beta-*` tag，首个 beta：`native-beta-260826`）；
> stable 维护主线仍由 pure/glibc 双轨包承担。
>
> 性能现实（实测，非营销话术）：启动 ~1s 量级（`--version` 首试 1965ms =
> Phase B bootstrap ~220ms + Phase C JS 求值 ~820ms；<300ms 目标需上游 Bun
> 改造，当前不可达），体积 ~180MB。

完整手术原理、config schema、失败预案与 FAQ 见 `docs/transplant.md`；
三条运行线对比见 `docs/comparison-runtime-lines.md`。

---

## 附录：glibc/pure 线（稳定双轨包）

bun-termux-loader 包装方案：上游 `opencode-linux-arm64` 是 glibc 链接的
Bun 单文件应用（Bun runtime + JS 编译进单个 ELF）。loader 在其前部拼一个
~12KB 的 Bionic wrapper ELF：读 `/proc/self/exe` 定位 BUNWRAP1 元数据、
抽出内嵌 opencode 二进制，再 mmap glibc 的 ld.so 并跳到其入口
（userland exec，不走 execve），使 `/proc/self/exe` 保持指向自身、
Bun 的 JS 定位不被破坏。旧版本维护分支：`glibc`。

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
dpkg -i /path/to/opencode_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

### 构建

```bash
# 单版本
make all VER=1.17.3 PKG=both

# 批量构建
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1

# 构建流程: clean → runtime(produce-local.sh: npm download + loader wrap)
#          → stage(scripts/build.sh) → deb → pacman

# 隐藏目标: release-upload（默认 TAG=Push<YYMMDD>, REPO=Hope2333/opencode-termux, PKG=both）
make release-upload TAG=Push260522 VERS='1.17.[0-3]'
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

### 零 glibc 约束史（历史记录）

早期"零 glibc 不可能"的 Constraints 结论表已被 transplant 复活手术部分推翻
（"runtime swap / binary surgery 不可行"的真因是未 patch `BUN_COMPILED.size`）。
仍然成立的约束：Android 上 `bun build --compile` 因 `/data/` 权限扫描被
Zig 源码硬编码阻断；上游 Bun 至今没有 `--target=bun-linux-aarch64-android`。
完整证伪与推翻记录见 `docs/transplant.md` 与 `docs/native-android-research.md`。

---

## Repository layout

```
.github/workflows/
  build-native-android.yml    Native 线 CI（evidence-only artifact）
  build-pure-android.yml      glibc 线 CI（aarch64）
  prebuild-armv7.yml          armv7 prebuild handoff（已搁置）
tools/
  transplant/                 Native 复活管线（transplant.py / revive_patch.py /
                              swap_tui.py / config/bun-bind.json）
  watcher/                    原生 inotify watcher 守护 + shim 插件桥
  produce-local.sh            glibc 线：npm 下载 + loader wrap
  prebuilt/                   glibc 线 CI 用预构建 aarch64 wrapper+shim
scripts/
  fetch-fixtures.sh           transplant-check golden fixtures 预下载
  build.sh                    Stage prefix（glibc 线）
  launcher.sh                 Runtime dispatcher（cleanup + exec）
  package/package_deb.sh      DEB builder
  package/package_pacman.sh   Pacman builder
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch  Upstream OpenCode Android patches (WIP)
docs/
  transplant.md               Native 线手术权威文档
  comparison-runtime-lines.md 三条运行线对比
  dual-track-install.md       Provider 选择（opencode vs opencode-native）
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
