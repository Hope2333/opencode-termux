[English](./README.md) | [简体中文](./README.zh.md) | [繁體中文](./README.zht.md) | [日本語](./README.ja.md) | [Español](./README.es.md)

# opencode-termux

OpenCode on Termux. AI-powered coding assistant, native bionic runtime, zero glibc dependencies.

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## Quick install

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

This installs the `opencode` command. After installation, upgrade via package manager:

```bash
# Termux (default)
pkg upgrade opencode

# pacman (if initialized)
pacman -Syu opencode
```

## What is this

[OpenCode](https://opencode.ai) is an AI-powered terminal coding assistant. This project packages it for [Termux](https://termux.dev) on Android, providing native bionic binaries with zero glibc dependencies.

Five package families across two generations, installable side by side (v1 and v2 coexist):

| Package | Gen | Runtime | Size | TUI | Notes |
|---------|-----|---------|------|-----|-------|
| `opencode` | v2 | Native bionic | ~66 MB | Full | Mainline, recommended |
| `opencode-wrapper` | v2 | Bun-termux-loader | ~50 MB | Full | v2 wrapper appendix |
| `opencode1` | v1 | Native bionic | ~40 MB | Full | v1 mainline |
| `opencode1-wrapper` | v1 | Glibc runtime payload | ~40 MB | Full | v1 wrapper appendix |
| `opencode1-compressed` | v1 | Native bionic (UPX) | ~56 MB | Full | UPX outsourced (`.pkg.tar.gz`) |

Within one generation pick exactly ONE of native / wrapper / compressed; v1 (`opencode1*`) and v2 (`opencode*`) coexist.

**Mainline** = native bionic (`opencode`). Zero glibc, Android API >= 28, full TUI via bionic libopentui.so.

## Install via pacman (optional)

Termux uses `apt` by default. If you prefer `pacman`:

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

Then install:

```bash
pacman -S opencode
```

## Upgrade

```bash
# apt (default)
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## Requirements

- Android API >= 28 (Android 9.0+)
- Termux (F-Droid or GitHub release)
- ~200 MB free storage

## Packages

### Stable releases

Packages are published on [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases) under rolling tags:

- `Push260922` -- **RC3**: v2.0.[0-12] native & wrapper + v1.18.[30-32] three families, all PKGREL=3 (70 assets, per-file digest-verified)
- `Push260912` -- archived (prerelease)

### Package formats

- **deb**: `opencode_<ver>_aarch64.deb` (Termux apt)
- **pacman**: `opencode-<ver>-<rel>-aarch64.pkg.tar.xz` (Termux pacman; current `rel` = 3)
- v1 compressed: `opencode1-compressed-<ver>-<rel>-aarch64.pkg.tar.gz` (note `.gz`)

## Building from source

Requires `make`, `python3`, `clang`, and `upx` (optional).

```bash
# Build native bionic binary
make build-native VER=2.0.0

# Build compressed (UPX) variant
make build-native-upx VER=2.0.0

# Build deb package
make deb-native VER=2.0.0

# Build pacman package
make pacman-native VER=2.0.0
```

See [docs/make-maintainer.md](./docs/make-maintainer.md) for full build reference.

## v1 and v2 (two generations)

v2 (`opencode*`, 2.0.x) is the mainline; v1 (`opencode1*`, 1.18.30–32) is maintained and **coexists** with v2 — install both side by side:

```bash
pacman -S opencode            # v2 mainline
pacman -S opencode1           # v1 mainline
```

Within one generation, native / wrapper / compressed are mutually exclusive (pick one). The old `opencode-glibc` name is retired — it was renamed `opencode1-wrapper` (v1) / replaced by `opencode-wrapper` (v2).

## Technical documentation

- [docs/transplant.md](./docs/transplant.md) -- Runtime transplant pipeline
- [docs/comparison-runtime-lines.md](./docs/comparison-runtime-lines.md) -- Runtime line comparison
- [docs/dual-track-install.md](./docs/dual-track-install.md) -- Dual-track install guide
- [docs/make-maintainer.md](./docs/make-maintainer.md) -- Makefile reference

## 💬 Community & Discussions

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

**English** — Chat, Q&A and ideas. RC3 refreshed the whole two-generation family: 13 v2 versions (native & wrapper) + v1 three families (1.18.30–32), all PKGREL=3, 70 assets digest-verified.

Other languages: [简体中文](./README.zh.md#-community--discussions) · [繁體中文](./README.zht.md#-community--discussions) · [日本語](./README.ja.md#-community--discussions) · [Español](./README.es.md#-community--discussions)

[![General](https://img.shields.io/badge/General-chat-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-help-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-share_ideas-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-releases-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-show_off-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## License

OpenCode is open source. This packaging project follows the same license.
