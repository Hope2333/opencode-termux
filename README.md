[English](./README.md) | [简体中文](./README.zh.md)

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

Three runtime variants are available:

| Package | Runtime | Size | TUI | Notes |
|---------|---------|------|-----|-------|
| `opencode` | Native bionic | ~66 MB (UPX) | Full | Mainline, recommended |
| `opencode-compressed` | Native bionic (UPX) | ~66 MB | Full | Alias for `opencode` |
| `opencode-wrapper` | Bun-termux-loader | ~193 MB | Full | Glibc wrapper, legacy |

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

- `Push260912` -- v1.18.30 / v1.18.31 (last v1 release)
- `Push260921` -- v2.0.0 GA (current mainline)

### Package formats

- **deb**: `opencode_<ver>_aarch64.deb` (Termux apt)
- **pacman**: `opencode-<ver>-1-aarch64.pkg.tar.xz` (Termux pacman)
- **native UPX**: `opencode-native-<ver>-upx.xz` (binary only, ~66 MB)

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

## v1 to v2 migration

v2.0.0 is the current mainline. v1.18.x packages are retained for rollback.

If you have v1 installed:

```bash
# v2 replaces v1 automatically (Conflicts/Replaces in control)
pkg upgrade opencode
```

Package name changed from `opencode-glibc` (v1) to `opencode-wrapper` (v2 wrapper variant).

## Technical documentation

- [docs/transplant.md](./docs/transplant.md) -- Runtime transplant pipeline
- [docs/comparison-runtime-lines.md](./docs/comparison-runtime-lines.md) -- Runtime line comparison
- [docs/dual-track-install.md](./docs/dual-track-install.md) -- Dual-track install guide
- [docs/make-maintainer.md](./docs/make-maintainer.md) -- Makefile reference

## 💬 Community & Discussions

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

**简体中文** — 聊天吹水、问答求助、点子脑洞。RC3 双代全家族已上架：v2 native/wrapper 各 13 版 + v1 三族 1.18.30–32，全量 PKGREL=3，70 件 digest 逐件对账。
**English** — Chat, Q&A and ideas. RC3 refreshed the whole two-generation family: 13 v2 versions (native & wrapper) + v1 three families (1.18.30–32), all PKGREL=3, 70 assets digest-verified.
**繁體中文** — 聊天吹水、問答求助、點子腦洞。RC3 雙代全家族已上架：v2 native/wrapper 各 13 版 + v1 三族 1.18.30–32，全量 PKGREL=3，70 件逐筆對帳。
**日本語** — 雑談・Q&A・アイデア募集中。RC3 で二世代ファミリーを全面リフレッシュ：v2 native/wrapper 各 13 バージョン + v1 3 ファミリー（1.18.30–32）、全て PKGREL=3、70 アセット。
**Español** — Charla, preguntas e ideas. RC3 renovó toda la familia en dos generaciones: 13 versiones v2 (native y wrapper) + 3 familias v1 (1.18.30–32), todo con PKGREL=3 y 70 assets verificados.

[![General](https://img.shields.io/badge/General-%E9%97%B2%E8%81%8A%E5%90%B9%E6%B0%B4-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-%E5%AE%89%E8%A3%85%E6%B1%82%E5%8A%A9-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-%E7%82%B9%E5%AD%90%E8%84%91%E6%B4%9E-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-%E5%8F%91%E7%89%88%E5%85%AC%E5%91%8A-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-%E6%99%92%E6%88%90%E6%9E%9C-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## License

OpenCode is open source. This packaging project follows the same license.
