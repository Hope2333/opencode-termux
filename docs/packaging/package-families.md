# 包族单一事实源（package families）

> 状态：active ｜ 适用版本：v1 1.18.x–1.19.x / v2 2.0.x–2.1.x

本文件是「有哪些包族、叫什么、能不能共存、多大」的**唯一事实源**。README 的包表、`install/dual-track-install.md` 的安装指引、`build/native-line-evolution.md` 的历史叙述都以此为准。

## 家族总表

| 包名 | 代 | 运行时 | 包体（aarch64） | TUI | 定位 |
|---|---|---|---|---|---|
| `opencode` | v2 | native bionic（B 线编译） | ~66 MB deb | 完整 | **主线，推荐** |
| `opencode-wrapper` | v2 | bun-termux-loader（glibc 载荷） | ~82 MB deb（实测） | 完整 | v2 wrapper 附录 |
| `opencode-compressed` | v2 | native bionic（UPX） | 视压制比 | 完整 | v2 压缩变体（过渡） |
| `opencode1` | v1 | native bionic（A 线 transplant） | ~40 MB deb | 完整 | v1 主线 |
| `opencode1-wrapper` | v1 | glibc 载荷 | ~40 MB deb | 完整 | v1 wrapper 附录 |
| `opencode1-compressed` | v1 | native bionic（UPX） | ~56 MB（`.pkg.tar.gz`） | 完整 | v1 压缩变体 |
| `opencode-wrapper-standalone` | v1 | — | — | — | **已弃用**（回滚专用，不再发布新版） |

> 体积口径：表中是**包体**；装机后（解包）尺寸另计，不要混用。历史文档里的 ~180/210MB 是装机口径。

## 共存与互斥

- **同一代内三选一**：native / wrapper / compressed 互斥；换族请先卸载旧族（deb 的 `Conflicts` 已声明）。
- **v1 与 v2 可共存**：`opencode` 与 `opencode1` 包名不同，可同时安装。
- **命名红线**：native 包的包名永远是 `opencode`（v2）/ `opencode1`（v1），**不加 `-native` 后缀**；历史上出现过的 `opencode-native` 命名已废弃。

## 分界与考古

- `Push260828` 起，`opencode` 包名 = native bionic 主线；此前 tag 的 `opencode` = glibc 包装线（现 `opencode-wrapper`）。
- 逐 tag 的家族归属与判定信号已迁至 `../history/push-tag-archaeology.md`（历史快照，勿用于安装决策）。

## 相关

- 安装与切换：`../install/dual-track-install.md`
- 压缩族契约：`compressed-line.md`
- deb / pacman 布局：`packaging-deb.md` / `packaging-pacman.md`
