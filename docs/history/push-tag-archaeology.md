# Push tag × 包名家族：考古表（历史快照）

> 状态：historical ｜ 适用版本：≤ Push260906

> **历史快照，勿按此操作。** 本表是 2026-09-06 的 `gh release list` 资产实测，
> 批次已推进多代；现行安装请取最新 tag（`gh release list -L 3`）。
> 现行包族说明见 `../packaging/package-families.md`。

> 本表仅供**考古/分类参考**，不是安装指引；现行安装请直接取最新 tag（`gh release list -L 3`）。

## 逐 tag 分类表

| Tag | plain `opencode_*` 归属 | 证据（大小 + 家族标记） | 备注 |
|---|---|---|---|
| `Push260906` | **native 主线（当前 Latest）** | 92 资产；标题 `v1.18.27 v1.18.[15-26]`；native/compressed/wrapper 三家族齐全 | **推荐下载 tag**（正式 Latest） |
| `Push260905` | native 主线 | `opencode_1.18.15~27_aarch64.deb` 约 40.0~40.1MB；`opencode-wrapper_*` 82.4MB 同现；pacman 对应约 40.0~40.1MB | 上一个正式 tag；被 Push260906 取代 |
| `Push260903`（rc2 批次） | native 主线（**已降级批次**） | plain deb 40.1~40.7MB；`opencode-wrapper_*` 同现 | release 标题标注 `[demoted: TUI patch insufficient]`，**勿从此 tag 下载** |
| `Push260828` | **native 主线（分界点）** | `opencode_1.18.21_aarch64.deb` 40.7MB；`opencode-wrapper_1.18.15_*` 82.4MB、`opencode-wrapper-standalone_*` 41.3MB、`opencode-compressed_*` 50.4MB 同现 | 包名更名后首个正式 tag（Latest） |
| `Push260822` | **旧 glibc 时代（末班）** + 过渡双名 | plain `opencode_1.18.21_aarch64.deb` 41.3MB；native 线以旧名 `opencode-native_1.18.21_aarch64.deb` 40.7MB 同场 | 唯一 plain/native 双名并存 tag |
| `Push260803` | 旧 glibc 时代 | `opencode_1.18.8~15_aarch64.deb` 40.5~41.2MB；场内无 glibc/native 命名资产 | |
| `Push260719` | 旧 glibc 时代 | `opencode_1.18.3~7_aarch64.deb` 40.3~40.5MB | |
| `Push260522` | 旧 glibc 时代 | `opencode_1.15.1~1.18.3_aarch64.deb` 33.9~40.3MB | |

## 判定信号（供 AI 代理自动化分类）

1. plain `opencode_*` 约 40MB 且场内同现 `opencode-wrapper_*`（约 82MB）或 `opencode-<v>-*-android-native*` 资产 → native 主线时代。
2. plain `opencode_*` 且场内完全无 `opencode-wrapper_*` / `opencode-native_*` / `*-android-native*` 命名资产 → 旧 glibc 时代（更名前）。
3. 大小陷阱：旧 glibc 时代的 plain deb 本身只有 30~41MB，不是 80MB；约 82MB 档是现行 `opencode-wrapper` 家族。单看 plain deb 大小无法区分 1.18.x 的两族，必须看场内是否同现带 `glibc` / `native` 命名的资产。
