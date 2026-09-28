[日本語](./README.ja.md) | [English](./README.md) | [简体中文](./README.zh.md) | [繁體中文](./README.zht.md) | [Español](./README.es.md)

# opencode-termux

Termux 向け OpenCode。AI コーディングアシスタント、ネイティブ bionic ランタイム、glibc 依存なし。

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## クイックインストール

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

`opencode` コマンドがインストールされます。インストール後はパッケージマネージャーでアップグレード：

```bash
# Termux（デフォルト）
pkg upgrade opencode

# pacman（初期化済みの場合）
pacman -Syu opencode
```

## これは何

[OpenCode](https://opencode.ai) は AI 搭載のターミナル型コーディングアシスタントです。本プロジェクトはそれを Android 向け [Termux](https://termux.dev) 用にパッケージ化し、glibc 依存のないネイティブ bionic バイナリを提供します。

二世代 x 5 ファミリー。v1 と v2 は共存でき、並列インストール可能です：

| パッケージ | 世代 | ランタイム | サイズ | TUI | 備考 |
|-----------|------|-----------|--------|-----|------|
| `opencode` | v2 | ネイティブ bionic | ~66 MB | フル | メインライン、推奨 |
| `opencode-wrapper` | v2 | Bun-termux-loader | ~50 MB | フル | v2 wrapper 付録 |
| `opencode1` | v1 | ネイティブ bionic | ~40 MB | フル | v1 メインライン |
| `opencode1-wrapper` | v1 | glibc ランタイム payload | ~40 MB | フル | v1 wrapper 付録 |
| `opencode1-compressed` | v1 | ネイティブ bionic（UPX） | ~56 MB | フル | UPX は外部化（`.pkg.tar.gz`） |

同一世代内では native / wrapper / compressed から 1 つだけ選択。v1（`opencode1*`）と v2（`opencode*`）は共存可能です。

**メインライン** = ネイティブ bionic（`opencode`）。glibc ゼロ、Android API >= 28、bionic libopentui.so によるフル TUI。

## pacman でインストール（任意）

Termux のデフォルトは `apt` です。`pacman` を使う場合：

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

インストール：

```bash
pacman -S opencode
```

## アップグレード

```bash
# apt（デフォルト）
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## 要件

- Android API >= 28（Android 9.0+）
- Termux（F-Droid または GitHub release）
- 約 200 MB の空き容量

## パッケージ

### 安定版リリース

パッケージは [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases) にローリングタグで公開されます：

- `Push260922` -- **RC3**：v2.0.[0-12] native & wrapper + v1.18.[30-32] 3 ファミリー、全て PKGREL=3（70 アセット、digest 照合済み）
- `Push260912` -- アーカイブ済み（prerelease）

### パッケージ形式

- **deb**：`opencode_<ver>_aarch64.deb`（Termux apt）
- **pacman**：`opencode-<ver>-<rel>-aarch64.pkg.tar.xz`（Termux pacman；現在の `rel` = 3）
- v1 compressed：`opencode1-compressed-<ver>-<rel>-aarch64.pkg.tar.gz`（`.gz` に注意）

## ソースからビルド

`make`、`python3`、`clang`、`upx`（任意）が必要です。

```bash
# ネイティブ bionic バイナリをビルド
make build-native VER=2.0.0

# UPX 圧縮バリアントをビルド
make build-native-upx VER=2.0.0

# deb パッケージをビルド
make deb-native VER=2.0.0

# pacman パッケージをビルド
make pacman-native VER=2.0.0
```

ビルドの詳細は [docs/make-maintainer.md](./docs/make-maintainer.md) を参照。

## v1 と v2（二世代）

v2（`opencode*`、2.0.x）がメインライン。v1（`opencode1*`、1.18.30–32）はメンテナンス継続中で v2 と**共存**します — 両方同時にインストール可能：

```bash
pacman -S opencode            # v2 メインライン
pacman -S opencode1           # v1 メインライン
```

同一世代内の native / wrapper / compressed は相互排他（1 つだけ選択）。旧名 `opencode-glibc` は廃止 — v1 は `opencode1-wrapper` に改名、v2 は `opencode-wrapper` が引き継ぎました。

## 技術ドキュメント

- [docs/transplant.md](./docs/transplant.md) -- ランタイム移植パイプライン
- [docs/comparison-runtime-lines.md](./docs/comparison-runtime-lines.md) -- ランタイムライン比較
- [docs/dual-track-install.md](./docs/dual-track-install.md) -- デュアルトラックインストールガイド
- [docs/make-maintainer.md](./docs/make-maintainer.md) -- Makefile リファレンス

## 💬 コミュニティ & Discussions

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

雑談・Q&A・アイデア募集中。RC3 で二世代ファミリーを全面リフレッシュ：v2 native/wrapper 各 13 バージョン + v1 3 ファミリー（1.18.30–32）、全て PKGREL=3、70 アセットを digest 照合済み。v1（`opencode1*`）と v2（`opencode*`）は共存できます。

[![General](https://img.shields.io/badge/General-%E9%9B%91%E8%AB%87-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-%E8%B3%AA%E5%95%8F-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-%E3%82%A2%E3%82%A4%E3%83%87%E3%82%A2-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-%E5%85%AC%E5%91%8A-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-%E7%99%BA%E8%A1%A8-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## ライセンス

OpenCode はオープンソースです。本パッケージングプロジェクトは同一ライセンスに従います。
