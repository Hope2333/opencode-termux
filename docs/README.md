# opencode-termux Docs (Canonical)

This directory is the single source of truth for the current Termux packaging/runtime workflow.

## Start here

- `execution-checklist.md` — install/test runbook (default Termux apt first, pacman path second)
- `skills-index.md` — concise index for prompts + quick fixes
- `13-opencode-runtime-build.md` — canonical runtime build path (official `opencode-linux-arm64` + bun-termux-loader)
- `20-packaging-deb.md` / `21-packaging-pkg-tar-xz.md` — package layout and build outputs
- `22-termux-services-opencode-web.md` — service behavior and web mode notes
- `30-ci-local-build-matrix.md` — local/CI validation matrix
- `incidents/2026-02-23-opencode-web-termux-so-avalanche.md` — `.so` snowball restart-storm RCA note
- `local-production.md` — local final packaging policy and boundaries
- `plugin-management.md` — plugin install/update/rollback commands
- `ci-prebuild-armv7.md` — Phase A armv7-only CI prebuild handoff scope
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
- Validate versions again from staged/deb/pacman outputs (avoid stale `1.1.65` contamination)

## Known pitfalls

- Old generated `artifacts/staged`, `packaging/deb/work`, `packaging/pacman/src` can contain stale runtime versions
- `sv status opencode-web` in Termux should use full service path (`$PREFIX/var/service/opencode-web`)
- `opencode web` under runit may restart-loop and accumulate `.*-0000*.so` files if startup crashes
- **statx seccomp crash**: Android's seccomp filter blocks `statx()` syscall → SIGSYS → SIGSEGV. The statx shim (`libstatx-shim.so`) is automatically compiled during staging and preloaded via launcher. Disable with `OPENCODE_DISABLE_STATX_SHIM=1`.

## Install policy summary

- Default path: Termux apt/pkg with `glibc` + `openssl-glibc` required.
- Pacman path: Termux pacman environments use the same required deps.
- `glibc-runner` is optional fallback tooling (not a primary runtime dependency).
