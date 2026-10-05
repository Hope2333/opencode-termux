[繁體中文](./README.zht.md) | [English](./README.md) | [简体中文](./README.zh.md) | [日本語](./README.ja.md) | [Español](./README.es.md)

# opencode-termux

Termux 上的 OpenCode。AI 編程助手，原生 bionic 執行時，零 glibc 相依。

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## 快速安裝

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

安裝的是 `opencode` 指令。安裝後透過套件管理器升級：

```bash
# Termux（預設）
pkg upgrade opencode

# pacman（如已初始化）
pacman -Syu opencode
```

## 簡介

[OpenCode](https://opencode.ai) 是 AI 驅動的終端機編程助手。本專案把它打包到 [Termux](https://termux.dev)（Android），提供零 glibc 相依的原生 bionic 二進位。

雙代共五族，可並排安裝（v1 與 v2 共存）：

| 套件名 | 代際 | 執行時 | 體積 | TUI | 說明 |
|--------|------|--------|------|-----|------|
| `opencode` | v2 | 原生 bionic | ~66 MB | 完整 | 主線，推薦 |
| `opencode-wrapper` | v2 | Bun-termux-loader | ~50 MB | 完整 | v2 wrapper 附錄 |
| `opencode1` | v1 | 原生 bionic | ~40 MB | 完整 | v1 主線 |
| `opencode1-wrapper` | v1 | glibc runtime payload | ~40 MB | 完整 | v1 wrapper 附錄 |
| `opencode1-compressed` | v1 | 原生 bionic（UPX） | ~56 MB | 完整 | UPX 外包（`.pkg.tar.gz`） |

同代內 native / wrapper / compressed 三選一；v1（`opencode1*`）與 v2（`opencode*`）跨代共存。

**主線** = 原生 bionic（`opencode`）。零 glibc，Android API >= 28，經 bionic libopentui.so 支援完整 TUI。

## 透過 pacman 安裝（可選）

Termux 預設用 `apt`。若偏好 `pacman`：

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

然後安裝：

```bash
pacman -S opencode
```

## 升級

```bash
# apt（預設）
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## 系統需求

- Android API >= 28（Android 9.0+）
- Termux（F-Droid 或 GitHub release）
- 約 200 MB 可用儲存空間

## 套件

### 穩定版

套件發布在 [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases)，滾動 tag：

- `Push260922` -- **RC3**：v2.0.[0-12] native 與 wrapper + v1.18.[30-32] 三族，全量 PKGREL=3（70 件，逐筆 digest 對帳）
- `Push260912` -- 已歸檔（prerelease）

### 套件格式

- **deb**：`opencode_<ver>_aarch64.deb`（Termux apt）
- **pacman**：`opencode-<ver>-<rel>-aarch64.pkg.tar.xz`（Termux pacman；當前 `rel` = 3）
- v1 compressed：`opencode1-compressed-<ver>-<rel>-aarch64.pkg.tar.gz`（注意 `.gz`）

## 從原始碼建置

需要 `make`、`python3`、`clang` 與 `upx`（可選）。

```bash
# 建置原生 bionic 二進位
make build-native VER=2.0.0

# 建置 UPX 壓縮變體
make build-native-upx VER=2.0.0

# 建置 deb 套件
make deb-native VER=2.0.0

# 建置 pacman 套件
make pacman-native VER=2.0.0
```

完整建置參考見 [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md)。

## v1 與 v2（雙代）

v2（`opencode*`，2.0.x）為主線；v1（`opencode1*`，1.18.30–32）持續維護並與 v2 **共存**——可雙裝：

```bash
pacman -S opencode            # v2 主線
pacman -S opencode1           # v1 主線
```

同代內 native / wrapper / compressed 互斥（三選一）。舊名 `opencode-glibc` 已退役——v1 側更名 `opencode1-wrapper`，v2 側由 `opencode-wrapper` 接替。

## 技術文件

- [docs/10-build/14-transplant-pipeline.md](docs/10-build/14-transplant-pipeline.md) -- 執行時移植管線
- [docs/99-reference/comparison-runtime-lines.md](docs/99-reference/comparison-runtime-lines.md) -- 執行時方案對比
- [docs/20-packaging/23-dual-track-install.md](docs/20-packaging/23-dual-track-install.md) -- 雙軌安裝指南
- [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md) -- Makefile 參考

## 💬 社群與討論

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

聊天吹水、問答求助、點子腦洞。RC3 雙代全家族已上架：v2 native/wrapper 各 13 版 + v1 三族 1.18.30–32，全量 PKGREL=3，70 件逐筆對帳。v1（`opencode1*`）與 v2（`opencode*`）跨代共存，雙裝不衝突。

[![General](https://img.shields.io/badge/General-%E9%96%92%E8%81%8A%E5%90%B9%E6%B0%B4-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-%E5%AE%89%E8%A3%9D%E6%B1%82%E5%8A%A9-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-%E9%BB%9E%E5%AD%90%E8%85%A6%E6%B4%9E-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-%E7%99%BC%E7%89%88%E5%85%AC%E5%91%8A-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-%E6%99%92%E6%88%90%E6%9E%9C-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## 授權

OpenCode 是開源專案。本打包專案遵循相同授權。
