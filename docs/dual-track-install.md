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

| | Track 1: glibc wrapper (`opencode-glibc`) | Track 2: native (`opencode-native`) |
|---|---|---|
| Status | Appendix maintenance (renamed `opencode-glibc`) | **Stable mainline** (since 27/28) |
| Runtime | glibc via bun-termux-loader userland exec | Pure Bionic (zero glibc deps) |
| Scope | Full: TUI + run + serve + web | TUI + `run` / `serve` (TUI verified on-device) |
| TUI | Works | Works (bionic libopentui.so; W10a deep smoke 5/5) |
| Requirement | `glibc` + `openssl-glibc` packages | Android API >= 28 |

## Track 1 — glibc wrapper (appendix maintenance, renamed `opencode-glibc`)

```bash
# apt/pkg
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
dpkg -i /path/to/opencode-glibc_<version>_aarch64.deb

# pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-glibc-<version>-1-aarch64.pkg.tar.xz
```

## Track 2 — native (stable mainline since 27/28)

Built from the transplant revival pipeline (`make transplant VER=<x>` →
`artifacts/transplant/<ver>/opencode-native-revived`), packaged by
`scripts/package/package_deb_native.sh` / `scripts/package/package_pacman_native.sh`
(Make targets: `make deb-native VER=<x>`, `make pacman-native VER=<x>`,
`make native-pkg VER=<x>`).

```bash
dpkg -i /path/to/opencode-native_<version>_aarch64.deb
# or
pacman -U /path/to/opencode-native-<version>-1-aarch64.pkg.tar.xz
```

Constraints:

- Zero glibc runtime dependencies (pure Bionic).
- Requires Android API >= 28.
- Full TUI: works via the self-built bionic `libopentui.so` (W10a deep smoke 5/5); `opencode run "..."` and `opencode serve` work.
- Installing it removes the glibc provider package and vice versa.

## Switching providers

```bash
dpkg -i opencode-native_<v>_aarch64.deb   # glibc -> native
dpkg -i opencode-glibc_<v>_aarch64.deb    # native -> glibc
```

Both packages ship `/data/data/com.termux/files/usr/bin/opencode`; dpkg/pacman
resolve the conflict by replacing the other provider.

## Release assets naming

- native mainline (stable since 27/28): `opencode-native_<ver>_aarch64.deb`,
  `opencode-native-<ver>-1-aarch64.pkg.tar.*`,
  raw binary `opencode-<ver>-aarch64-android-native`, plus
  `opencode-<ver>-report.json` and `opencode-<ver>-watcher.tar.gz`
- glibc appendix (renamed `opencode-glibc`): `opencode-glibc_<ver>_aarch64.deb`,
  `opencode-glibc-<ver>-1-aarch64.pkg.tar.*`
