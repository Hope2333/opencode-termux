# 40 - Upstream v2 Adaptation (feat/v2-adaptation)

## Scope

This branch adapts the opencode-termux packaging pipeline to upstream OpenCode **v2**
(`anomalyco/opencode` dev history / `2.0` branch) while **preserving full v1
compatibility**. Smart version routing decides which pipeline runs.

## Facts established (2026-08-05)

| Item | Value | Source |
|------|-------|--------|
| Active upstream branch | `dev` (updating daily, e.g. #40603) | GitHub API |
| v2 branch | `2.0` exists but stale since 2026-04-13 ("2.0 exploration #22335") | GitHub API |
| npm dist-tag `beta` | `opencode-linux-arm64@beta` → e.g. `0.0.0-beta-202608050914` (rotates daily) | npm |
| npm dist-tag `tui-v2` | `opencode-linux-arm64@tui-v2` → `0.0.0-tui-v2-202606261840` | npm |
| v2 beta runtime form | **Bun ELF** (aarch64 + glibc interpreter, contains Bun runtime / bun-pty / @opentui) | unpacked tarball |
| v2 GA direction | Node.js (rewrite); dev shows `@npmcli/arborist`, `@hono/node-server`, `fix-node-pty` postinstall | repo source |

**Key conclusion**: v2 **beta** is still a Bun ELF → it reuses the existing
bun-termux-loader + glibc wrap path unchanged. Only the future Node-based v2 GA
needs a new staging path (no loader wrapping).

## Smart version routing

`tools/produce-local.sh` accepts:

- concrete version: `1.18.13`, `0.0.0-beta-202608050826`
- npm dist-tag: `beta`, `tui-v2`, `latest` (default: `latest`)

After download it `file`-detects `package/bin/opencode`:

- `ELF` → `RUNTIME_FORM=bun-elf` → bun-termux-loader wrap (v1 + v2 beta, glibc)
- non-ELF → `RUNTIME_FORM=node-js` → stage as-is + copy adjacent chunks to
  `artifacts/opencode/runtime/v2-dist/` (future v2 GA; **no wrapping**)

```bash
# v2 beta (today, Bun ELF path)
make all VER=beta PKG=both

# v2 tui-v2 snapshot
make all VER=tui-v2 PKG=both

# v1 as always
make all VER=1.18.13 PKG=both
```

## Packaging runtime-form awareness

- `scripts/build.sh` writes `runtime_form=bun-elf|node-js` + `runtime_mode` into
  `artifacts/opencode/build.meta`; copies `v2-dist/` when present.
- `scripts/package/package_deb.sh`: Depends `bash, ncurses` (bun-elf) vs
  `bash, nodejs` (node-js); postinst "Runtime:" line via `__RUNTIME_DESC__`
  placeholder + sed.
- `scripts/package/package_pacman.sh` + `packing/pacman/PKGBUILD`:
  `depends=()` default; swaps to `depends=('nodejs')` when `RUNTIME_FORM=node-js`.

- ✔ Version resolution (dist-tag vs concrete) tested against npm (beta/tui-v2/1.18.13).
- ✔ Runtime-form detection (ELF vs non-ELF) implemented + shell syntax checked (`bash -n`).
- ✔ Real v2 beta build: `make all VER=beta PKG=both` full chain OK (wrap 194MB → deb → pacman).
- ✔ Real tui-v2 build: `make all VER=tui-v2 PKG=both` full chain OK (wrap 159MB → deb → pacman).
- ✔ v1 regression: `make all VER=1.18.13 PKG=both` full chain OK.
- ✔ pacman install test: `pacman -U` beta pkg → deps satisfied (glibc openssl-glibc bash ncurses), `opencode --version` OK.
- ✔ deb install test: dpkg extracts + runs (dpkg db empty on this pacman host → unconfigured warning, runtime still works).
- ℹ npm fetch hardened: `--fetch-retries=5` on pack/view (large tarball ECONNABORTED fix).

```bash
make all VER=beta PKG=both          # v2 beta via Bun ELF pipeline
make all VER=1.18.13 PKG=both       # v1 regression
```

## Future v2 GA handoff checklist

- [ ] Confirm v2 GA npm artifact is Node.js (non-ELF) → `node-js` path activates.
- [ ] Verify entry `#!/usr/bin/env node` shebang works through `scripts/launcher.sh`.
- [ ] Confirm `nodejs` rpm/apt dependency satisfied in target pkg repos.
- [ ] Drop the glibc `Depends` once loader path is abandoned for v2.
- [ ] Re-sync when upstream cuts a v2.0 release tag.

## v2pre release line (current) — decided 2026-08-05

v2 尚未正式发布。当前主推是 **beta/v2pre 先行线**，发布模式如下：

- **发布节奏**：跟随上游 `beta`/`tui-v2` dist-tag（beta 每日轮换）。
- **版本路由**：`make all VER=beta|tui-v2|1.18.x PKG=both` 由 `produce-local.sh` 自动分流。
- **发布形态**：未来 v2 正式版发布后，将沿用与 v1 类似的正式发布模式
  （`make release-upload` 批量 tag 上传流程），v2 正式 tag 出现后切换默认线。
- **依赖声明**：bun-elf 形态 `glibc openssl-glibc bash ncurses`（已验证 pacman 安装通过）；
  v2 GA node-js 形态切换为 `nodejs bash`。
- **安装测试**：本机（Termux pacman）`pacman -U` beta 包 → 依赖校验通过、
  `opencode --version` 正常；beta 版本号 < v1 时 pacman 视为 downgrade（预期行为）。