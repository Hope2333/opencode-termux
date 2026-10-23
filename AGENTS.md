# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-12
**Refreshed:** 2026-10-24 (docs-reorg-maint D1)
**Branch:** working branch varies (`fix-tlsdesc-pipeline` at refresh time)

## OVERVIEW
Termux-first OpenCode build/packaging workspace. Two generations coexist: v2 (`opencode*`, 2.0.x → 2.1.x) is the mainline, v1 (`opencode1*`, 1.18.x → 1.19.x) stays maintained. The v2 mainline is the **native bionic line**: B line compiles upstream source with android-bun (`scripts/build-bionic.sh`), A line revives the official ELF (`tools/transplant/`); both produce a zero-glibc Android binary. `opencode-wrapper` / `opencode1-wrapper` are glibc-loader appendix families, `*-compressed` are UPX variants, and `opencode-wrapper-standalone` is deprecated. Within one generation native / wrapper / compressed are mutually exclusive; v1 and v2 coexist. GitHub Actions workflows are diagnostic/handoff, not the final runtime release path.

## STRUCTURE
```text
opencode-termux/
├── Makefile                    # top-level orchestration (family/batch/selfcheck/matrix; SHELL=bash)
├── scripts/                    # build, packaging, hooks, CI helpers (+ lib/ for testable guards/pins)
├── tools/                      # operator CLIs (transplant, fleet push, compressed-one, plugin manager)
├── packing/                    # package templates + manifests (mixed with generated outputs)
├── docs/                       # runbooks, architecture notes, history (docs/README.md is the index)
├── tests/                      # bats unit tests + transplant golden
├── artifacts/                  # generated runtime/staging outputs (disposable)
└── .github/workflows/          # unit tests, upstream probe, CI handoff workflows
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Build orchestration | `Makefile`, `tools/make-opencode` | `make` is source of truth; entry points: `family-v2-native`, `family-v2-compressed`, `family-native`, `family-compressed`, `family=...` dispatcher |
| v2 native build (B line) | `scripts/build-bionic.sh` | android-bun source compile; pins in `scripts/lib/build-pins.sh`; guards in `scripts/lib/build-guards.sh` |
| v1 native build (A line) | `tools/transplant/transplant.py`, `docs/transplant.md` | ELF revival + TUI swap + seccomp harden |
| Native packaging | `scripts/package/package_deb_native.sh`, `package_pacman_native.sh`, `packing/pacman/PKGBUILD.native` | package names are `opencode` (v2) / `opencode1` (v1) — never `opencode-native`; un-hardened artifacts are refused |
| Compressed packaging | `tools/compressed-one.sh`, `scripts/package/package_deb_compressed.sh`, `package_pacman_compressed.sh` | UPX variants; contract in `docs/compressed-line.md` |
| Wrapper appendix | `tools/produce-local.sh`, `scripts/package/package_deb.sh`, `package_pacman.sh` | glibc loader line — not the mainline |
| Upstream drift probe | `scripts/ci/probe-latest-opencode.sh`, `.github/workflows/probe-upstream.yml` | must query `/tags` — upstream v2 has no GitHub Releases |
| Release ops | `tools/fleet-push.py`, `scripts/push-stage.sh`, `docs/handover/release-runbook.md` | batch tags `PushYYMMDD`; never rebind or reuse an existing tag |
| System-skill hooks | `scripts/hooks/run-system-skills.sh`, `packing/manifests/system-skills/*.json` | strict/network default to safe mode |
| Plugin lifecycle | `tools/plugin-manager.sh`, `docs/plugin-management.md` | `file://` plugin paths on Termux |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|---|---|---|---:|---|
| `resolve_dep_pins` | shell function | `scripts/lib/build-pins.sh` | high | per-version pty/opentui pins; unknown VER hard-fails, no network |
| `require_clang` / `require_hardened` | shell function | `scripts/package/lib.sh` | high | packaging gates for the seccomp shim (#17/#36) |
| `is_store_populated` / `require_pkg_installed` / `require_file` | shell function | `scripts/lib/build-guards.sh` | high | build-side guards (#42 class silent failures) |
| `transplant.py` main flow | python | `tools/transplant/transplant.py` | high | A-line revival pipeline |
| `cmd_install` / `cmd_update` / `cmd_rollback` | shell function | `tools/plugin-manager.sh` | high | plugin lifecycle commands |
| `compressed-one.sh` main flow | shell entrypoint | `tools/compressed-one.sh` | high | single-version compressed pipeline |

## CONVENTIONS
- Shell scripts use strict mode (`set -euo pipefail`) and fail-fast checks for required binaries/files.
- Runtime/package scripts rely on uppercase env knobs (`VER`, `VERS`, `PKG`, `TAG`, `PKGREL`, `STAGED_PREFIX`).
- **Fail loud, never silent-skip**: if an upstream anchor drifts, the build must fail rather than ship a broken artifact (issue #42).
- Hook execution is explicit and safe-by-default (`OPENCODE_HOOK_STRICT=0`, `OPENCODE_HOOK_ENABLE_NETWORK=0`).
- Packaging sources live under `packing/*`; versioned packages are generated artifacts.

## ANTI-PATTERNS (THIS PROJECT)
- Do not use musl/proot as the official Termux runtime path.
- Do not treat CI armv7 handoff artifacts as release binaries.
- Do not edit generated outputs (`artifacts/`, `packing/dpkg/work/`, `packing/pacman/pkg/`, versioned packages).
- Do not rebind or reuse an existing batch tag; a new batch means a new `PushYYMMDD` tag.
- Do not ship an un-hardened native binary (`ALLOW_UNHARDENED=1` is rollback/debug only).
- Do not run staging/packaging scripts against shared or wrong prefixes (several flows use destructive `rm -rf`).

## UNIQUE STYLES
- Packaging and hook flows are manifest-driven (`packing/manifests/system-skills/*.json`) with idempotency + registry updates.
- Plugin management is Termux-biased toward local `file://.../index.js` registration.
- CI armv7 jobs emit JSON status artifacts (`status/*.json`), diagnosis-first.

## COMMANDS
```bash
# v2 native mainline (B line) / compressed / v1
make family-v2-native VER=2.0.31
make family-v2-compressed VER=2.0.31
make family-native VER=1.19.3

# Upstream drift check (queries tags, exits 1 on drift)
bash scripts/ci/probe-latest-opencode.sh --check

# Shell unit tests
./tests/run.sh
```

## NOTES
- `packing/` holds both templates/manifests and generated outputs — keep them conceptually separate.
- When adding workflow-critical scripts, update both `docs/README.md` (index) and this root map.
- Release discipline and current-batch discovery: `docs/handover/release-runbook.md` + `gh release list`.
