# opencode-termux Docs (Canonical)

This directory is the single source of truth for the current Termux packing/runtime workflow.

## Start here

- `execution-checklist.md` — install/test runbook (default Termux apt first, pacman path second)
- `skills-index.md` — concise index for prompts + quick fixes
- `13-opencode-runtime-build.md` — canonical runtime build path (official `opencode-linux-arm64` + bun-termux-loader)
- `20-packaging-deb.md` / `21-packaging-pkg-tar-xz.md` — package layout and build outputs
- `22-termux-services-opencode-web.md` — service behavior and web mode notes
- `30-ci-local-build-matrix.md` — local/CI validation matrix
- `incidents/2026-02-23-opencode-web-termux-so-avalanche.md` — `.so` snowball restart-storm RCA note
- `local-production.md` — local final packaging policy and boundaries
- `transplant.md` — native-android transplant pipeline (revived: dual-format revive + TUI + alpha channel)
- `migration-v1-to-v2.md` — v1 → v2 升级/回退/包名/构建线迁移指南
- `dual-track-install.md` — opencode provider selection (native mainline `opencode` vs appendix `opencode-wrapper`, full TUI)；包名时代分界（哪个 Push tag 的 `opencode` 资产属于哪个家族）→ [`dual-track-install.md#push-tag--包名家族分界`](./dual-track-install.md#push-tag--包名家族分界)
- `plugin-management.md` — plugin install/update/rollback commands
- `make-maintainer.md` — maintainer build/upload/cache operations (Make system doctrine, `tools/maintain.sh`, fleet push, cache cleanup)
- `ci-prebuild-armv7.md` — Phase A armv7-only CI prebuild handoff scope
- `ops-lessons-rc3.md` — RC3 发布实战经验（PKGREL 矩阵 / clean-version / chunk 漂移防线 / 网络链路 / v2 native shim open item）
- `native-line-evolution.md` — native 线演进史（A 线拼接手术 → B 线真编译 → RC3~4 制度化；B/B1 方案对照）
- `upx-v2-fix.md` — v2 UPX 压制修复：四假说（bin 结构/内嵌 store/crhandler/版本漂移）+ 检验序列 + v1 两成功线辨析（2026-09-30）
- `handover/recall-pack.md` — 回忆拼图包（交接老代理，五节：现状/拼图/精确提问/检索法/对照基准）
- `handover/release-runbook.md` — D1 发布运行手册（环境自检→PTY_VARIANT→构建→hygiene→PKGREL→上架→对账→双机→回写）
- `handover/machine-env.md` — D2 机器与环境手册（fake-IP/glibc 桥接/termux-exec 陷阱/实验机/磁盘纪律/RootDir 双机）
- `handover/community-state.md` — D3 社区与 issue 状态（开放案/已闭案底/RFC29/语言规则/回帖模板）
- `handover/open-items.md` — D4 进行中与待决清单（UPX R-A/RC6 定版/原子对上传等 9 项，快照 2026-09-30）
- `plugin-packaging-design.md` — package-manager-driven plugin model for apt/pacman
- `OCTPLUGIN-PREBRANCH-RESEARCH.md` — single-file pre-split plugin research baseline
- `system-skills-hook-architecture.md` — package-mode system skill + hook framework
- `arch-reference-mapping.md` — reusable parts from Arch plugin packaging approach
- `ci-prebuild-armv7.md` / `armv7-native-runner-setup.md` — deferred arm32/armv7 planning and debug paths

## Classification

- `mainline/` information in this docs tree reflects the currently maintained local Termux packaging workflow.
- arm32 and broader armv7 portability implementation work is **deferred/non-mainline** unless explicitly promoted.
- CI armv7 content should be treated as handoff/prebuild context, not final runtime release proof.

## Rewrite / maintenance notes

- If implementation behavior and docs diverge, update docs first in this directory and then adjust root README summary.
- Prefer replacing stale sections rather than appending contradictory notes.

## Repository map (current)

- OpenCode Termux repo (canonical): `~/develop/opencode-termux`
- Workspace root (multi-repo, not single source of truth): `~/develop`
- Runtime wrapper tool repo: `~/develop/bun-termux` (or legacy `~/bun-termux-loader`, verify active toolchain before release)
- Runtime config/plugins (user state): `~/.config/opencode/`

## Guardrails (verified)

- **Do not use musl** for the Termux runtime packaging path
- **Do not use proot** as the official build path
- Build runtime from official upstream Linux arm64 binary, then wrap for Android/Bionic
- Validate final runtime with `file` + `--version` before staging/package
- Validate versions again from staged/deb/pacman outputs (avoid stale version contamination)

## Known pitfalls

- Old generated `artifacts/staged`, `packing/dpkg/work`, `packing/pacman/src` can contain stale runtime versions
- `sv status opencode-web` in Termux should use full service path (`$PREFIX/var/service/opencode-web`)
- `opencode web` under runit may restart-loop and accumulate `.*-0000*.so` files if startup crashes
- **statx seccomp crash**: Android's seccomp filter blocks `statx()` syscall → SIGSYS → SIGSEGV. The statx shim (`libstatx-shim.so`) is automatically compiled during staging and preloaded via launcher. Disable with `OPENCODE_DISABLE_STATX_SHIM=1`.

## Install policy summary

- Default path: the Make system is the highest-priority entry (`make family=wrapper,native,compressed VER=<ver>`); individual tools are help-first.
- The native mainline `opencode` package has zero glibc runtime dependencies (Android API >= 28).
- The wrapper appendix `opencode-wrapper` package is self-contained (bash + ncurses only; no glibc/openssl-glibc packages needed).
- Pacman path: Termux pacman environments use the same package families.
- `glibc-runner` is optional fallback tooling (not a primary runtime dependency).
