# opencode-termux — pure-android branch

**This is the current mainline branch.** It produces OpenCode packages using
bun-termux-loader to wrap the upstream `opencode-linux-arm64` binary for
Android/Bionic. glibc is required at runtime (the wrapper loads it via
userland exec).

**Looking for the legacy branch?** See the `glibc` branch (same approach,
older version).

---

## Dependencies

| Package | Required? | Why |
|---------|-----------|-----|
| `glibc` | ✅ Yes | OpenCode binary is glibc-linked; wrapper loads it via glibc's ld.so |
| `openssl-glibc` | ✅ Yes | HTTPS/TLS for API calls |
| `bash` | ✅ Yes | Launcher script |
| `ncurses` | ✅ Yes | TUI support |

```bash
# Install dependencies
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc

# Then install opencode
dpkg -i /path/to/opencode_<version>_aarch64.deb
```

### Path B: pacman (secondary)

```bash
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

### Optional: Android-native Bun

```bash
# From the bun-termux repo (pure-android branch)
# Provides: bun -- JavaScript runtime, 0 glibc
# Repo: https://github.com/Hope2333/bun-termux
```

---

## What this branch provides

- ✅ **Real OpenCode AI** (`opencode --version` → `1.17.x`)
- ✅ deb + pacman package output
- ✅ Plugin lifecycle system (install/update/rollback)
- ✅ TTY/signal cleanup launcher
- ✅ System-skill hooks (post-install/upgrade/remove)
- ✅ CI workflow for automated builds
- ✅ Batch build (`make batch VERS='1.17.[0-3]'`)
- ✅ Release upload automation (`make release-upload`)

---

## How it works

The upstream OpenCode binary (`opencode-linux-arm64` from npm) is a
**glibc-linked Bun-compiled application**. It contains the Bun runtime +
OpenCode JS code compiled into a single ELF executable.

To make it run on Android/Bionic, **bun-termux-loader** prepends a thin
Bionic wrapper:

```
┌──────────────────────────────────────────────┐
│ Bionic wrapper ELF (~12KB)                   │
│   - Reads /proc/self/exe                     │
│   - Finds BUNWRAP1 metadata                  │
│   - Extracts embedded OpenCode binary        │
│   - Userland exec via glibc's ld.so          │
├──────────────────────────────────────────────┤
│ BUNWRAP1 metadata                            │
├──────────────────────────────────────────────┤
│ Original opencode binary (glibc Bun + JS)    │
│   - Interpreter: /lib/ld-linux-aarch64.so.1  │
│   - Entry: compiled-app mode (RX seg base)   │
│   - ---- Bun! ---- marker + JS bytecode      │
└──────────────────────────────────────────────┘
```

**Userland exec**: Instead of `execve()` (which would update `/proc/self/exe`
and break Bun's JS location), the wrapper mmap()s glibc's `ld.so` and jumps
to its entry point, keeping `/proc/self/exe` pointing to itself.

---

## Constraints (zero-glibc attempts)

We invested significant research into removing the glibc dependency.
Here's what we tried and why it didn't work:

| Approach | Result | Root Cause |
|----------|--------|------------|
| **Android Bun as runtime** (v1.3.14 Bionic binary) | ❌ | `bun build --compile` fails on Termux (`/data/` permission) |
| **JS bundle from source** (`bun build --target=bun`) | ❌ | Native modules (`@opentui/solid`) require `--compile` |
| **Runtime swap** (replace glibc Bun with Android Bun) | ❌ | Android Bun lacks compiled-app entry point code (ELF entry at 0x1f00200, not segment base) |
| **Binary surgery** (patch ELF entry + swap) | ❌ | Missing Zig/C++ level "load embedded JS" code in Android Bun |
| **Fork Bun + add android target** | ⏳ | Requires modifying Bun's Zig/C++ build system + WebKit |
> **Update (2026-08)**: the "Runtime swap" and "Binary surgery" verdicts above were
> **overturned** by the transplant revival surgery — patching `BUN_COMPILED.size` (+ a
> `.rela.dyn` relocation) lets the official Android Bun carry the grafted module graph.
> The native line now ships as alpha with full TUI; see `docs/transplant.md` and the
> Native-android section below.

**Current path**: bun-termux-loader wrapping. Production-stable, works today.
The glibc dependency is standard on Termux (`apt install glibc`).

**Future**: When upstream Bun supports `--target=bun-linux-aarch64-android`,
we can switch to native Android Bun as the runtime and eliminate glibc.

See `docs/native-android-research.md` for full research details.

---

## Install

Two packaging tracks provide the same `opencode` command — pick ONE provider:

- **`opencode` (glibc wrapper line) — default recommended.** Mature, full TUI.
- **`opencode-native` (transplant revival line) — alpha.** Zero glibc deps,
  Android API >= 28, full TUI (bionic libopentui injected); startup ~1s. Installing it
  replaces the glibc provider (and vice versa).

```bash
# Track 1 (default recommended): glibc wrapper packages
# Path A: apt/pkg
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
dpkg -i /path/to/opencode_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz

# Track 2 (alpha): native provider — zero glibc, full TUI
dpkg -i /path/to/opencode-native_<version>_aarch64.deb
# or: pacman -U /path/to/opencode-native-<version>-1-aarch64.pkg.tar.xz
```

See `docs/dual-track-install.md` for provider selection details.

Releases: https://github.com/Hope2333/opencode-termux/releases

---

## Usage

```bash
opencode --version          # → 1.17.3
opencode run "hi"           # OpenCode AI chat
opencode run --mode=dev .   # development mode
opencode serve              # API server mode
opencode web                # web interface
```

---

## Build

### Local build (Termux)

```bash
# Single version
make all VER=1.17.3 PKG=both

# Batch build (1.17.0 through 1.17.3)
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1
```

### Build + release upload

```bash
# Hidden target (not in help):
make release-upload TAG=Push260522 VERS='1.17.[0-3]'
# Defaults: TAG=Push<YYMMDD>, REPO=Hope2333/opencode-termux, PKG=both
```

### Build flow

```
make all VER=1.17.3 PKG=both
  → clean (rm -rf artifacts/staged, packaging work dirs)
  → runtime (tools/produce-local.sh: npm download + bun-termux-loader wrap)
  → stage (scripts/build.sh: copy to prefix tree)
  → deb (scripts/package/package_deb.sh)
  → pacman (scripts/package/package_pacman.sh)
```

---

## CI Pipeline

Workflow: `.github/workflows/build-pure-android.yml`

```
workflow_dispatch (manual, with version input)
  ↓ Install Bun (Linux) for optional bundle build
  ↓ Clone upstream source + apply patches (WIP)
  ↓ QEMU aarch64 emulation for binary handling
  ↓ Download opencode-linux-arm64 from npm
  ↓ Wrap with bun-termux-loader (pre-built aarch64 wrapper+shim)
  ↓ Create bundle + upload artifact + write status JSON
```

Matrix builds for: `aarch64`

> **Note**: The combination of amd64 (x64) + Android + Termux is extremely rare with virtually no real-world users.
> If you're on amd64, use a standard Linux distribution with your system package manager or npm/bun to install opencode directly — no Termux wrapper needed.
> For those who still need it, modify the workflow config and build yourself; this project does not provide x64 release assets.
>
> **armv7**: The 32-bit dependency chain is severely broken with prohibitively high fix costs. This experiment is abandoned.

---

## Native-android 分支（native 线，alpha）

`native-android` 是拓展分支，承载 transplant 复活管线（`tools/transplant/transplant.py`），
产出零 glibc 依赖的原生 Android 运行路径。当前状态：**管线贯通、TUI 完整可用，
发布定档 alpha**（长期 pre-release；stable 维护主线仍是 pure/glibc 双轨包）。

历史注记：早期"C1 已证伪/三重证伪"结论**已被推翻**——真因是 assemble 从未 patch
`.bun` 节的 `BUN_COMPILED.size`（standalone 检测链在 android bun 中完整存在）。
手术细节与证伪历史留档见 `docs/transplant.md` §0.1/§0.2。

### 现状一览

- **复活管线贯通**：`make transplant VER=<ver>` 一条龙
  extract→detect→convert→patch→assemble→revive→verify，直接产出可运行的
  `opencode-native-revived`。同时支持旧 trailer 格式与新版 `.bun` section 格式
  （opencode ≥1.18，1.18.21 实证）；`revive_patch.py --size-mode reloc|plain-offset`
  按底座版本自动选择语义（≤1.3.x reloc 重定位，≥1.4.x plain-offset 直写偏移；
  新版格式图必须用 ≥1.4 底座，见 `tools/transplant/config/bun-bind.json` target=1.4.0）。
- **TUI 完整可用**：`tools/transplant/swap_tui.py` 将 NDK 构建的 bionic
  `libopentui.so` 等长注入后 TUI 完整渲染。W10a 深度冒烟 5/5 通过
  （真实聊天往返 / resize / 干净退出 / 5min 浸泡 RSS 反降）。
- **CI 绿**：`.github/workflows/build-native-android.yml`（workflow_dispatch，
  evidence-only `--no-execve`），含 revive 步骤与 golden 回归。近期修正：
  d918c8c（重建补 --no-execve）、a0bee4e（golden 重建前清预置缓存防错底座）。
  最新 run 32831119197 success，产物 transplant-1.18.21。
- **watcher 栈**：`tools/watcher/`（`watcher.c` 原生 inotify 守护 + `shim.js`
  插件桥 + `install.sh`），E2E 三类事件 <100ms，kill -9 自愈 ≤612ms。

### 发布渠道（双轨）

| 渠道 | 内容 | 入口 |
|---|---|---|
| stable | Push260822 双轨包（glibc wrapper deb/pacman） | <https://github.com/Hope2333/opencode-termux/releases> |
| alpha | native-alpha-260825 prerelease（资产 `opencode-1.18.21-aarch64-android-native-tui`） | <https://github.com/Hope2333/opencode-termux/releases/tag/native-alpha-260825> |

政策：native 线长期定档 alpha pre-release；stable 主线由 pure/glibc 承担。

### 性能诚实数据（实测，非营销话术）

- 启动 ~1s 量级：`--version` 首试 1965ms，归因 Phase B bootstrap ~220ms +
  Phase C JS 求值 ~820ms。<300ms 目标需上游 Bun 改造，当前不可达（W3 报告）。
- 体积 ~180MB。

### 命令速查

```bash
# 一键管线（extract→detect→convert→patch→assemble→revive→verify）
# 现产 opencode-native-revived（可直接运行）
make transplant VER=1.18.21

# 回归（golden-file，fixtures 需先 scripts/fetch-fixtures.sh 预下载）
make transplant-check
```

完整手术原理、config schema、失败预案与 FAQ 见 `docs/transplant.md`。

---

## Repository layout

```
.github/workflows/
  build-pure-android.yml      CI automated build pipeline (aarch64)
  prebuild-armv7.yml          armv7 prebuild handoff (deferred)
tools/
  produce-local.sh            Download from npm + wrap
  prebuilt/                   Pre-built aarch64 wrapper+shim for CI
scripts/
  build.sh                    Stage prefix
  launcher.sh                 Runtime dispatcher (cleanup + exec)
  package/package_deb.sh      DEB builder
  package/package_pacman.sh   Pacman builder
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch   Upstream OpenCode Android patches (WIP)
docs/
  native-android-research.md  Research: zero-glibc approaches
```

## Launcher safeguards

- TTY cleanup on exit (soft/hard depending on exit code)
- Stale lock cleanup (`*.lock` in `$XDG_STATE_HOME`)
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` (default)

## Metadata

Maintainer: `Hope2333(幽零小喵) <u0catmiao@proton.me>`

## Related

- OpenCode upstream: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
- Android-native Bun: <https://github.com/Hope2333/bun-termux> (pure-android branch)
- Upstream Bun (Android builds): <https://github.com/oven-sh/bun>
- Research doc: `docs/native-android-research.md`

---

## Pure-Bionic OpenCode: constraint history

The notes below record why a from-source pure-Bionic build stayed out of reach,
and which of them the transplant revival has since bypassed. Full evidence:
`docs/transplant.md`. Obstacles without a superseded note still hold.

### 1. Compilation: `bun build --compile` is blocked on Android

Bun's `--compile` flag scans the filesystem from `/` to resolve imports and
native modules. On Android, `/data/` is permission-restricted (`AccessDenied`),
causing all `bun build` operations (with or without `--compile`) to fail.
There is no known workaround — it's hardcoded in Bun's Zig source.

```bash
bun build ./src/index.ts            # ❌ Cannot read directory "/data/": AccessDenied
bun build --compile ./src/index.ts  # ❌ same
```

### 2. Android Bun has no "compiled app" entry point

The Android Bun binary (v1.3.14) is a **pure interpreter** — it starts as
`bun`, not as a Bun-compiled application. The ELF entry point is at offset
`0x1f00200` (interpreter mode) instead of the RX segment base (compiled-app
mode). The compiled-app startup code (`mov x5, x0; ldr x1, [sp]` pattern)
does **not exist** in the binary. Simply concatenating Android Bun + JS
payload produces a binary that runs as `bun --help`, not as OpenCode.

> **Superseded**: the standalone detection chain does exist in Android Bun. The real
> blocker was an unpatched `BUN_COMPILED.size`, fixed by the revive surgery
> (`tools/transplant/revive_patch.py`). The grafted binary runs today — see
> `docs/transplant.md`.

### 3. JS bytecode is not portable

The JS extracted from the upstream binary is **compiled bytecode**, not
TypeScript source. It cannot be run with `bun run` — it requires the
`bun build --compile` loading path, which only exists in binaries produced
by that process.

### 4. Native modules lack Bionic builds

OpenCode depends on `@opentui/solid` (TUI framework) and `@parcel/watcher`
(file watcher). These ship with glibc `.so` files. Bionic-compiled versions
do not exist publicly.

> **Partially superseded**: `@opentui/solid` now runs via an NDK-built bionic
> `libopentui.so` (equal-length injection via `tools/transplant/swap_tui.py`), and file
> watching uses the native `tools/watcher/` stack instead of `@parcel/watcher`.

### 5. Upstream Bun has no Android compile target

```bash
bun build --compile --target=bun-linux-arm64           # ✅ works (produces glibc binary)
bun build --compile --target=bun-linux-aarch64-android # ❌ does not exist
```

There is no `--target` for Android in Bun's build system. Adding it requires
changes to Bun's Zig/C++ source code and WebKit/JavaScriptCore integration.

---

## This branch's commitment

This branch exists specifically to **track and resolve** these obstacles.
The path forward:

| Timeline | Milestone |
|----------|-----------|
| **Now** | bun-termux-loader wrapping (mainline, needs glibc) + transplant native line (alpha, zero glibc, TUI enabled) |
| **Short-term** | Fork Bun, patch `/data/` scan, add Android compile target |
| **Medium-term** | Build Android-native OpenCode on CI with forked Bun |
| **Goal** | `opencode` → runs on Termux, **zero glibc**, single Bionic binary |

Every constraint documented here has a corresponding issue or experiment in
the repo. When upstream Bun or OpenCode removes any of these blockers, this
branch will switch immediately.

**This is not a dead end. It's a work in progress.**

