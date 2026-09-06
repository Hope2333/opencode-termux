# Dual-track install: `opencode` providers

Two packaging tracks provide the same `opencode` command on Termux.
**Pick ONE provider** — the packages conflict with each other, so installing
one replaces the other.

## 包名变更过渡计划

包名变更与主线切换已于 27/28 生效：glibc 与 bionic 构建已区分，旧 `opencode` 包已更名为 `opencode-glibc`，`opencode` 已由 native bionic 线继承并成为稳定主线（正式发布渠道，BETA 预发布阶段已结束）。

### 重命名对照表

| 旧名称 | 新名称 | 渠道 |
|---|---|---|
| `opencode`（glibc wrapper 线） | `opencode-glibc` | 稳定附录（glibc 双轨包） |
| `opencode-native`（native bionic 线） | `opencode` | 稳定主推（native 线） |
| —（新增过渡包） | `opencode-glibc-standalone` | 命令入口 `opencode-glibc`，与 `opencode` 可共存，单版本冻结，用于回退 |

### 现有用户预期

- 新包采用 dpkg/pacman 的 `Breaks`/`Replaces` 语义处理冲突：安装新包会自动替换同名旧 provider。
- `opencode` 与 `opencode-glibc` 互斥，不可并存安装（同现双轨关系保持不变）。
- 过渡期新增 `opencode-glibc-standalone`：命令入口为 `opencode-glibc`、库路径独立（`bin/opencode-glibc` + `lib/opencode-glibc`），**与 `opencode` 包可共存**，仅发布一个冻结版本，专用于过渡期回退。
- 切换 provider 的方式不变：`dpkg -i` / `pacman -U` 对应包即可。

### 典型升级路径

1. 卸载旧 glibc `opencode` 包。
2. 安装 native `opencode`（继承 `opencode` 名，稳定主推）。
3. 同时安装 `opencode-glibc-standalone` 作为保底回退（入口 `opencode-glibc`）。

### 打包注意

- `opencode-glibc-standalone` 包**不得**对字面名 `opencode` 声明 `Conflicts`，避免误伤已继承该名的 native 包。
- 互斥关系仅存在于 `opencode` ↔ `opencode-glibc` 这一对。

### 时间线

- 已于 27/28 生效（真机验证完成：迁移/回退/互斥拒绝全路径实测通过）。
- 具体切换以 releases 页面公告为准。

### 终态

仓库主线已切换到 native 线（发布主渠道与开发主线），glibc/pure 双轨已降级为附录维护（appendix maintenance）。

| | Track 1: glibc wrapper (`opencode-glibc`) | Track 2: native (`opencode`) |
|---|---|---|
| Status | Appendix maintenance | **Stable mainline** (since 27/28) |
| Runtime | glibc via bun-termux-loader userland exec | Pure Bionic (zero glibc deps) |
| Scope | Full: TUI + run + serve + web | TUI + `run` / `serve` (TUI verified on-device) |
| TUI | Works | Works (bionic libopentui.so; W10a deep smoke 5/5) |
| Requirement | `bash` + `ncurses` (self-contained; no glibc/openssl-glibc packages needed) | Android API >= 28 |

## Track 1 — glibc wrapper (appendix maintenance, renamed `opencode-glibc`)

The `opencode-glibc` package is **self-contained**: it runs on bare Termux without
the Termux `glibc` or `ca-certificates-glibc` packages. Packaging is bin-only (single
binary at `usr/bin/opencode`), with no postinst/prerm/postrm hooks and no full-prefix
copy.

```bash
# apt/pkg
dpkg -i /path/to/opencode-glibc_<version>_aarch64.deb

# pacman
pacman -U /path/to/opencode-glibc-<version>-1-aarch64.pkg.tar.xz
```

## Track 2 — native (stable mainline since 27/28)

Built from the transplant revival pipeline (`make transplant VER=<x>` →
`artifacts/transplant/<ver>/opencode-native-revived`), packaged by
`scripts/package/package_deb_native.sh` / `scripts/package/package_pacman_native.sh`
(Make targets: `make deb-native VER=<x>`, `make pacman-native VER=<x>`,
`make native-pkg VER=<x>`).

```bash
dpkg -i /path/to/opencode_<version>_aarch64.deb
# or
pacman -U /path/to/opencode-<version>-1-aarch64.pkg.tar.xz
```

Constraints:

- Zero glibc runtime dependencies (pure Bionic).
- Requires Android API >= 28.
- Full TUI: works via the self-built bionic `libopentui.so` (W10a deep smoke 5/5); `opencode run "..."` and `opencode serve` work.
- Installing it removes the glibc provider package and vice versa.

## Switching providers

```bash
dpkg -i opencode_<v>_aarch64.deb        # glibc -> native
dpkg -i opencode-glibc_<v>_aarch64.deb  # native -> glibc
```

Both packages ship `/data/data/com.termux/files/usr/bin/opencode`; dpkg/pacman
resolve the conflict by replacing the other provider.

## Release assets naming

- native mainline (stable since 27/28): `opencode_<ver>_aarch64.deb`,
  `opencode-<ver>-1-aarch64.pkg.tar.*`,
  raw binary `opencode-<ver>-aarch64-android-native`, plus
  `opencode-<ver>-report.json` and `opencode-<ver>-watcher.tar.gz`
- glibc appendix (renamed `opencode-glibc`): `opencode-glibc_<ver>_aarch64.deb`,
  `opencode-glibc-<ver>-1-aarch64.pkg.tar.*`
- compressed variant: `opencode-compressed_<ver>_aarch64.deb`,
  `opencode-compressed-<ver>-1-aarch64.pkg.tar.*`
- UPX runtime asset: `opencode-native-<ver>-upx.xz` (one per version)

## Push tag × 包名家族分界

下载 release 资产前必须先分清时代：**同一个 `opencode_*.deb` 文件名，在分界 tag 之前属于 glibc 包装线，分界 tag 之后属于 native bionic 主线**。AI 代理与脚本不得凭文件名直接下载，先按下表核对 tag。

**分界裁定**：自 `Push260828` 起，`opencode` 包名 = native bionic 主线；此前 tag 的 `opencode` 资产 = glibc 包装线（现名 opencode-glibc）。

**红线**：native 包名永远是 `opencode`，不加 `-native` 后缀。

**互斥教义**：三家族（`opencode` native 主线 / `opencode-glibc` / `opencode-compressed`）互斥不可共存；`opencode-glibc` 的 deb 现为硬互斥（`Conflicts: opencode, opencode-native, opencode-compressed`；无 `Replaces`）。

### 逐 tag 分类表（ground truth：`gh release list` + `gh release view` 资产实测，2026-09-06）

| Tag | plain `opencode_*` 归属 | 证据（大小 + 家族标记） | 备注 |
|---|---|---|---|
| `Push260906` | **native 主线（当前 Latest）** | 92 资产；标题 `v1.18.27 v1.18.[15-26]`；native/compressed/glibc 三家族齐全 | **推荐下载 tag**（正式 Latest） |
| `Push260905` | native 主线 | `opencode_1.18.15~27_aarch64.deb` 约 40.0~40.1MB；`opencode-glibc_*` 82.4MB 同现；pacman 对应约 40.0~40.1MB | 上一个正式 tag；被 Push260906 取代 |
| `Push260903`（rc2 批次） | native 主线（**已降级批次**） | plain deb 40.1~40.7MB；`opencode-glibc_*` 同现 | release 标题标注 `[demoted: TUI patch insufficient]`，**勿从此 tag 下载** |
| `Push260828` | **native 主线（分界点）** | `opencode_1.18.21_aarch64.deb` 40.7MB；`opencode-glibc_1.18.15_*` 82.4MB、`opencode-glibc-standalone_*` 41.3MB、`opencode-compressed_*` 50.4MB 同现 | 包名更名后首个正式 tag（Latest） |
| `Push260822` | **旧 glibc 时代（末班）** + 过渡双名 | plain `opencode_1.18.21_aarch64.deb` 41.3MB；native 线以旧名 `opencode-native_1.18.21_aarch64.deb` 40.7MB 同场 | 唯一 plain/native 双名并存 tag |
| `Push260803` | 旧 glibc 时代 | `opencode_1.18.8~15_aarch64.deb` 40.5~41.2MB；场内无 glibc/native 命名资产 | |
| `Push260719` | 旧 glibc 时代 | `opencode_1.18.3~7_aarch64.deb` 40.3~40.5MB | |
| `Push260522` | 旧 glibc 时代 | `opencode_1.15.1~1.18.3_aarch64.deb` 33.9~40.3MB | |

### 判定信号（供 AI 代理自动化分类）

1. plain `opencode_*` 约 40MB 且场内同现 `opencode-glibc_*`（约 82MB）或 `opencode-<v>-*-android-native*` 资产 → native 主线时代。
2. plain `opencode_*` 且场内完全无 `opencode-glibc_*` / `opencode-native_*` / `*-android-native*` 命名资产 → 旧 glibc 时代（更名前）。
3. 大小陷阱：旧 glibc 时代的 plain deb 本身只有 30~41MB，不是 80MB；约 82MB 档是现行 `opencode-glibc` 家族。单看 plain deb 大小无法区分 1.18.x 的两族，必须看场内是否同现带 `glibc` / `native` 命名的资产。

### 当前安装指引

- 安装一律取 `Push260906`（或更新的 tag）：native 主线下 `opencode_<v>_aarch64.deb` / `opencode-<v>-1-aarch64.pkg.tar.xz`；glibc 附录下 `opencode-glibc_<v>_aarch64.deb` / `opencode-glibc-<v>-1-aarch64.pkg.tar.xz`；压缩变体 `opencode-compressed_*`；UPX 运行时资产 `opencode-native-<v>-upx.xz`。
- 勿从 `Push260903`（降级批次）下载任何资产。
