# Dual-track install: `opencode` providers

Two packaging tracks provide the same `opencode` command on Termux.
**Pick ONE provider** — the packages conflict with each other, so installing
one replaces the other.

## 包名变更过渡计划

未来将区分 glibc 和 bionic 构建。旧 `opencode` 包从 `opencode` 变更为 `opencode-glibc`，`opencode` 将继承 native 线。push 日期在 27、28 左右 native 线定为稳定版（BETA 横幅移除）。

### 重命名对照表

| 旧名称 | 新名称 | 渠道 |
|---|---|---|
| `opencode`（glibc wrapper 线） | `opencode-glibc` | 稳定附录（glibc 双轨包） |
| `opencode-native`（native bionic 线） | `opencode` | 稳定主推（native 线） |

### 现有用户预期

- 新包采用 dpkg/pacman 的 `Breaks`/`Replaces` 语义处理冲突：安装新包会自动替换同名旧 provider。
- 过渡期间 `opencode-glibc` 与 `opencode`（native 线）可并存安装，便于逐步切换。
- 切换 provider 的方式不变：`dpkg -i` / `pacman -U` 对应包即可。

### 时间线

- 约 Push 27/28（日期近似），以最终真机验证为准。
- 具体切换以 releases 页面公告为准。

| | Track 1: glibc wrapper (`opencode`) | Track 2: native (`opencode-native`) |
|---|---|---|
| Status | **Default recommended**, mature | Experimental |
| Runtime | glibc via bun-termux-loader userland exec | Pure Bionic (zero glibc deps) |
| Scope | Full: TUI + run + serve + web | Headless only: `run` / `serve` |
| TUI | Works | **Broken** (bun:ffi dlopen; @opentui is glibc-only) |
| Requirement | `glibc` + `openssl-glibc` packages | Android API >= 28 |

## Track 1 — glibc wrapper (default recommended)

```bash
# apt/pkg
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
dpkg -i /path/to/opencode_<version>_aarch64.deb

# pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

## Track 2 — native (experimental, headless only)

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

Constraints (also stated in the package description/postinst — never silent):

- Zero glibc runtime dependencies (pure Bionic).
- Requires Android API >= 28.
- Headless only: `opencode run "..."` and `opencode serve` work; the TUI is
  broken (bun:ffi TinyCC/dlopen disabled, `@opentui/solid` is glibc-only).
- Installing it removes the glibc provider package and vice versa.

## Switching providers

```bash
dpkg -i opencode-native_<v>_aarch64.deb   # glibc -> native
dpkg -i opencode_<v>_aarch64.deb          # native -> glibc
```

Both packages ship `/data/data/com.termux/files/usr/bin/opencode`; dpkg/pacman
resolve the conflict by replacing the other provider.

## Release assets naming

- glibc wrapper line (default recommended): `opencode_<ver>_aarch64.deb`,
  `opencode-<ver>-aarch64.pkg.tar.*`
- native line (experimental): `opencode-native_<ver>_aarch64.deb`,
  `opencode-native-<ver>-1-aarch64.pkg.tar.*`,
  raw binary `opencode-<ver>-aarch64-android-native`, plus
  `opencode-<ver>-report.json` and `opencode-<ver>-watcher.tar.gz`
