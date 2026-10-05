[简体中文](./README.zh.md) | [English](./README.md) | [繁體中文](./README.zht.md) | [日本語](./README.ja.md) | [Español](./README.es.md)

# opencode-termux

Termux 上的 OpenCode。AI 编程助手，原生 bionic 运行时，零 glibc 依赖。

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## 快速安装

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

安装的是 `opencode` 命令。安装后通过包管理器升级：

```bash
# Termux（默认）
pkg upgrade opencode

# pacman（如已初始化）
pacman -Syu opencode
```

## 简介

[OpenCode](https://opencode.ai) 是 AI 驱动的终端编程助手。本项目把它打包到 [Termux](https://termux.dev)（Android），提供零 glibc 依赖的原生 bionic 二进制。

双代共五族，可并排安装（v1 与 v2 共存）：

| 包名 | 代际 | 运行时 | 体积 | TUI | 说明 |
|------|------|--------|------|-----|------|
| `opencode` | v2 | 原生 bionic | ~66 MB | 完整 | 主线，推荐 |
| `opencode-wrapper` | v2 | Bun-termux-loader | ~50 MB | 完整 | v2 wrapper 附录 |
| `opencode1` | v1 | 原生 bionic | ~40 MB | 完整 | v1 主线 |
| `opencode1-wrapper` | v1 | glibc runtime payload | ~40 MB | 完整 | v1 wrapper 附录 |
| `opencode1-compressed` | v1 | 原生 bionic（UPX） | ~56 MB | 完整 | UPX 外包（`.pkg.tar.gz`） |

同代内 native / wrapper / compressed 三选一；v1（`opencode1*`）与 v2（`opencode*`）跨代共存。

**主线** = 原生 bionic（`opencode`）。零 glibc，Android API >= 28，经 bionic libopentui.so 支持完整 TUI。

## 通过 pacman 安装（可选）

Termux 默认用 `apt`。若偏好 `pacman`：

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

然后安装：

```bash
pacman -S opencode
```

## 升级

```bash
# apt（默认）
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## 系统要求

- Android API >= 28（Android 9.0+）
- Termux（F-Droid 或 GitHub release）
- 约 200 MB 可用存储

## 包

### 稳定版

包发布在 [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases)，滚动 tag：

- `Push260922` -- **RC3**：v2.0.[0-12] native 与 wrapper + v1.18.[30-32] 三族，全量 PKGREL=3（70 件，逐件 digest 对账）
- `Push260912` -- 已归档（prerelease）

### 包类型

- **deb**：`opencode_<ver>_aarch64.deb`（Termux apt）
- **pacman**：`opencode-<ver>-<rel>-aarch64.pkg.tar.xz`（Termux pacman；当前 `rel` = 3）
- v1 compressed：`opencode1-compressed-<ver>-<rel>-aarch64.pkg.tar.gz`（注意 `.gz`）

## 从源码构建

需要 `make`、`python3`、`clang` 与 `upx`（可选）。

```bash
# 构建原生 bionic 二进制
make build-native VER=2.0.0

# 构建 UPX 压缩变体
make build-native-upx VER=2.0.0

# 构建 deb 包
make deb-native VER=2.0.0

# 构建 pacman 包
make pacman-native VER=2.0.0
```

完整构建参考见 [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md)。

## v1 与 v2（双代）

v2（`opencode*`，2.0.x）为主线；v1（`opencode1*`，1.18.30–32）持续维护并与 v2 **共存**——可双装：

```bash
pacman -S opencode            # v2 主线
pacman -S opencode1           # v1 主线
```

同代内 native / wrapper / compressed 互斥（三选一）。旧名 `opencode-glibc` 已退役——v1 侧更名 `opencode1-wrapper`，v2 侧由 `opencode-wrapper` 承接。

## 技术文档

- [docs/10-build/14-transplant-pipeline.md](docs/10-build/14-transplant-pipeline.md) -- 运行时移植管线
- [docs/99-reference/comparison-runtime-lines.md](docs/99-reference/comparison-runtime-lines.md) -- 运行时方案对比
- [docs/20-packaging/23-dual-track-install.md](docs/20-packaging/23-dual-track-install.md) -- 双轨安装指南
- [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md) -- Makefile 参考

## 💬 社区与讨论

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

聊天吹水、问答求助、点子脑洞。RC3 双代全家族已上架：v2 native/wrapper 各 13 版 + v1 三族 1.18.30–32，全量 PKGREL=3，70 件 digest 逐件对账。v1（`opencode1*`）与 v2（`opencode*`）跨代共存，双装不冲突。

[![General](https://img.shields.io/badge/General-%E9%97%B2%E8%81%8A%E5%90%B9%E6%B0%B4-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-%E5%AE%89%E8%A3%85%E6%B1%82%E5%8A%A9-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-%E7%82%B9%E5%AD%90%E8%84%91%E6%B4%9E-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-%E5%8F%91%E7%89%88%E5%85%AC%E5%91%8A-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-%E6%99%92%E6%88%90%E6%9E%9C-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## 许可

OpenCode 是开源项目。本打包项目遵循相同许可。
