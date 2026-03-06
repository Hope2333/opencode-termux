# PROJECT KNOWLEDGE BASE

**Generated:** 2026-03-05T13:10:53Z  
**Commit:** 1b92c1e  
**Branch:** main

## OVERVIEW
Termux-first OpenCode build/packaging workspace. Mainline release path is local Termux build (`tools/produce-local.sh` + `scripts/*`), while GitHub Actions armv7 workflow is diagnostic/handoff, not final runtime release.

## STRUCTURE
```text
opencode-termux/
├── Makefile                    # top-level orchestration (all/batch/selfcheck/matrix)
├── scripts/                    # staging, packaging, hook runners, CI helper scripts
├── tools/                      # operator-facing CLIs (make wrapper, plugin lifecycle, matrix)
├── packaging/                  # package templates + manifests (mixed with generated outputs)
├── docs/                       # canonical runbooks, architecture notes, incident records
├── artifacts/                  # generated runtime/staging outputs (disposable)
└── .github/workflows/          # CI handoff workflows
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Build orchestration | `Makefile`, `tools/make-opencode` | `make` is source of truth; wrapper maps CLI flags to make vars |
| Prepare runtime artifact | `tools/produce-local.sh` | resolves version, wraps runtime, cleans stale generated dirs |
| Stage install tree | `scripts/build.sh`, `scripts/common.sh` | writes staged prefix + build metadata |
| Build DEB package | `scripts/package/package_deb.sh`, `packaging/deb/DEBIAN/control` | postinst hook calls system-skill runner |
| Build pacman package | `scripts/package/package_pacman.sh`, `packaging/pacman/PKGBUILD*` | dynamic pkgver/pkgrel rewrite + makepkg flow |
| System-skill hook behavior | `scripts/hooks/run-system-skills.sh`, `packaging/manifests/system-skills/*.json` | strict/network flags default to safe mode |
| Plugin lifecycle | `tools/plugin-manager.sh`, `tools/plugin-selfcheck.sh`, `docs/plugin-management.md` | local file plugin path + snapshot rollback model |
| Upgrade/downgrade simulation | `tools/upgrade-matrix.sh`, `docs/execution-checklist.md` | machine2 lifecycle validation with cached deb artifacts |
| CI armv7 handoff | `.github/workflows/prebuild-armv7.yml`, `scripts/ci/*` | attempt-based build evidence, not final Termux release path |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|---|---|---|---:|---|
| `all`, `batch`, `selfcheck`, `matrix` | Make targets | `Makefile` | high | primary workflow control surface |
| `build_plugin` | shell function | `tools/plugin-manager.sh` | medium | plugin build pipeline (bun/npm + fallback) |
| `cmd_install` / `cmd_update` / `cmd_rollback` | shell functions | `tools/plugin-manager.sh` | high | plugin lifecycle commands |
| `run-system-skills.sh` entry flow | hook runner | `scripts/hooks/run-system-skills.sh` | high | post-install/post-upgrade hook orchestration |
| `produce-local.sh` main flow | script entrypoint | `tools/produce-local.sh` | medium | runtime acquisition + wrapper + cleanup |
| `upgrade-matrix.sh` main flow | script entrypoint | `tools/upgrade-matrix.sh` | medium | remote install/upgrade/downgrade simulation |

## CONVENTIONS
- Shell scripts use strict mode (`set -euo pipefail`) and fail-fast checks for required binaries/files.
- Runtime/package scripts rely on uppercase env knobs (`VER`, `VERS`, `PKG`, `ODIR`, `MIX`, `STAGED_PREFIX`, `PACKAGER_NAME`).
- Hook execution is explicit and safe-by-default (`OPENCODE_HOOK_STRICT=0`, `OPENCODE_HOOK_ENABLE_NETWORK=0`) in package lifecycle paths.
- Packaging sources live under `packaging/*` templates; versioned package files are generated artifacts.

## ANTI-PATTERNS (THIS PROJECT)
- Do not use musl/proot as official Termux final runtime path (`README.md`, `docs/local-production.md`).
- Do not treat CI armv7 handoff artifacts as final release binaries.
- Do not edit generated outputs (`artifacts/`, `packaging/dpkg/work/`, `packaging/pacman/pkg/`, versioned `.deb` / `.pkg.tar.xz`).
- Do not run staging/packaging scripts against shared or wrong prefixes: several flows use destructive `rm -rf` cleanup.

## UNIQUE STYLES
- Packaging and hook flows are manifest-driven (`packaging/manifests/system-skills/*.json`) with idempotency + registry updates.
- Plugin management is Termux-biased toward local `file://.../index.js` registration instead of bare plugin name mode.
- CI armv7 jobs emit JSON status artifacts (`status/*.json`) and logs for diagnosis-first iteration.

## COMMANDS
```bash
# Runtime preparation (mainline local flow)
./tools/produce-local.sh 1.2.10

# Build/package via make
make all VER=1.2.10 PKG=both
make batch VERS='1.2.10 1.2.11' PKG=deb

# Validation
make selfcheck
make matrix VERS='1.2.9 1.2.10' TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258

# Direct package scripts
./scripts/package/package_deb.sh
./scripts/package/package_pacman.sh
```

## NOTES
- `packing/` (default outputs) and `packaging/` (templates/manifests) are different; keep them conceptually separate.
- When adding new workflow-critical scripts, update both `docs/README.md` navigation and this root map.
