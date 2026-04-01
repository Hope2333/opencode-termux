# opencode-termux (OCT)

Termux-focused packaging and runtime workflow for OpenCode.

## Install first

Use one package-manager path per machine.

### Path A: default Termux (apt/pkg)

Recommended for most clean Termux test machines.

```bash
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
apt install -y /path/to/opencode_<version>_aarch64.deb
```

Optional fallback tooling:

```bash
apt install -y glibc-runner
```

### Path B: Termux with pacman as primary manager

Use this only when your Termux environment is already pacman-based.

```bash
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

Optional fallback tooling:

```bash
pacman -S glibc-runner
```

### Post-install quick checks

```bash
opencode --version
opencode --help
opencode web
```

This repository is part of the OML/OCT track and focuses on:

- reproducible OpenCode runtime packaging on real Termux devices
- consistent deb + pacman package outputs from one staged prefix
- safer launcher defaults for Termux runtime behavior
- plugin lifecycle support (install/update/rollback/patch)

## Current status (important)

- Verified runtime line: OpenCode Runtime (Android/Bionic wrapped)
- Final packages are produced **locally on Termux**
- GitHub Actions is used for **armv7 cross-prebuild handoff** only (non-mainline/deferred track)

### Completion snapshot (current)

- ✅ Mainline Termux packaging flow (deb + pacman) is operational
- ✅ machine1(build) -> local relay -> machine2(test) lifecycle is validated
- ✅ plugin/system-skill hook framework phase-2 is implemented and tested (registry + compatibility gates + blocklist)
- ✅ read-only diagnostics and matrix simulation are available (`make selfcheck`, `make matrix`)
- 🚧 Next: OML parent orchestration targets and richer plugin policy controls

### What OCT can do next

1. Expand matrix scenarios to cross-version ranges with archived logs per run.
2. Add registry inspection/reporting commands for system skills and hook outcomes.
3. Add policy presets for controlled networked plugin auto-update on machine1 only.
4. Tighten GNU/Linux secondary build validation while preserving Termux-first guarantees.

## Scope and status classification

- **Mainline (maintained in this repo)**
  - local Termux build/package flow (`make`, `tools/produce-local.sh`, `scripts/package/*`)
  - dependency policy and runtime stability improvements
  - docs and operational runbooks under `docs/`
- **Deferred / non-mainline**
  - arm32 adaptation and migration experiments
  - broad armv7 portability work beyond handoff artifacts

Deferred items may be referenced in docs/history but are not release-blocking for the mainline workflow.

## Repository layout

- `scripts/` - local build + package scripts
- `packaging/` - package metadata/templates
- `tools/` - helper tools (`produce-local.sh`, `plugin-manager.sh`)
- `docs/` - canonical documentation and runbooks

Start here: **`docs/README.md`**

## Build model (Phase A/B/C)

### Phase A: CI armv7 prebuild handoff

Workflow: `.github/workflows/prebuild-armv7.yml`

CI prepares cross-toolchain evidence + handoff templates/artifacts.
It does **not** claim final Termux runtime compatibility.

### Phase B: Local Termux final build/package

Use real Termux environment for final runtime wrapping and package generation.

Typical flow:

```bash
./tools/produce-local.sh <version>
./scripts/build.sh
./scripts/package/package_deb.sh
./scripts/package/package_pacman.sh
```

### Phase C: Plugin lifecycle

Use package-manager-driven plugin strategy + local recoverability tools.

See:
- `docs/plugin-packaging-design.md`
- `docs/plugin-management.md`

## Verified launcher safeguards

Installed launcher includes:

- TTY cleanup on exit
- stale lock cleanup
- broken plugin cache cleanup
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` default
- statx seccomp shim (`libstatx-shim.so`): installs a SIGSYS handler that catches seccomp-blocked `statx()` syscalls and returns `-ENOSYS`, so glibc falls back to `stat`/`fstatat` (Android seccomp blocks `statx` → `SIGSYS` → `SIGSEGV`). Disable with `OPENCODE_DISABLE_STATX_SHIM=1`.

## Metadata policy

Maintainer/packager identity defaults to:

`Hope2333(幽零小喵) <u0catmiao@proton.me>`

## What this repo does NOT do

- Does not use musl as the final Termux runtime path
- Does not use proot as official build path
- Does not treat CI artifacts as final Termux release binaries
- Default package hard dependency is `glibc`; `glibc-runner` is optional fallback tooling for compatibility/troubleshooting

## Quick links

- Glibc dependency reduction report: `docs/glibc-min-deps-test-report.md`
- Upgrade/downgrade simulation helper: `tools/upgrade-matrix.sh`
- Read-only plugin/environment self-check: `tools/plugin-selfcheck.sh`
- External plugin builder project (main route): `https://github.com/Hope2333/opencode-plugins-termux`
- System skill manifests (package mode): `packaging/manifests/system-skills/`
- Hook runner (package mode): `scripts/hooks/run-system-skills.sh`
- System-skill architecture: `docs/system-skills-hook-architecture.md`
- Runtime build details: `docs/13-opencode-runtime-build.md`
- Package docs: `docs/20-packaging-deb.md`, `docs/21-packaging-pkg-tar-xz.md`
- CI armv7 handoff: `docs/ci-prebuild-armv7.md`
- Execution checklist: `docs/execution-checklist.md`
- Incident RCA (`.so` restart snowball): `docs/incidents/2026-02-23-opencode-web-termux-so-avalanche.md`
- Statx seccomp shim: `tools/statx-shim.c` (compiled during staging, preloaded via launcher)

## License / upstream

- Upstream OpenCode: <https://github.com/anomalyco/opencode>
- This packaging workflow repository follows upstream license constraints for redistributed artifacts.

## Build convenience and version resolution

You can orchestrate full local build/package flow with Make targets or wrapper flags.

Examples:

```bash
make all VER=<version> PKG=both
make all VER=latest PKG=pacman
make batch VERS='<major.minor.[start-end]>' PKG=deb ODIR=~/oct-out
./tools/make-opencode --all --ver <version> --pkg pacman
./tools/make-opencode --batch --vers '<version1> <version2>' --pkg both --odir ~/oct-out
./tools/make-opencode --all --ver <version> --pkg both --odir ~/oct-out --mix
```

Rules:

- `tools/produce-local.sh` version priority:
  1) first positional argument (explicit version)
  2) latest `opencode-linux-arm64` from npm (if no version passed)
- if npm package for requested version is unavailable, fallback downloads GitHub release binary (`opencode-linux-arm64.tar.gz`) for that version.
- work directory defaults to project-local `.work/` (instead of `$HOME/work-*`), and is auto-cleaned unless `KEEP_WORK=1`.
- Packaging targets auto-clean generated work dirs before running to reduce stale contamination.
- Pacman package version is derived from staged runtime (`.../runtime/opencode --version`) instead of hardcoded `pkgver`.
- Package metadata now uses required `glibc` + `openssl-glibc`; `glibc-runner` is optional fallback tooling (`Suggests`/`optdepends`).
  Current validated network-minimal set (for `opencode run "hi"`): `glibc` + `openssl-glibc`.
- Package-mode system skill hooks are non-interactive and fail-soft by default:
  - `OPENCODE_HOOK_STRICT=0`
  - `OPENCODE_HOOK_ENABLE_NETWORK=0`
  - this avoids silent plugin auto-install/update during package install/upgrade.
- Phase-2 gate/registry support:
  - compatibility gates (`minimum_core_version` / `maximum_core_version` / blocklists)
  - system registry at `$PREFIX/share/opencode/system-skills-registry.json`
- output policy:
  - default output root is project `packing/`
  - if `ODIR` is set, outputs go to `ODIR` and do not use project `packing/`
  - default classified layout: `deb/` and `pacman/` subfolders
  - if `MIX=1` or `--mix`, artifacts are flattened into one directory

## Lifecycle simulation and self-check (machine1 -> machine2)

- Upgrade/downgrade simulation using cached deb artifacts only:

```bash
TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258 \
make matrix VERS='<old_version> <new_version>' ODIR=~/oct-out
```

or direct script call:

```bash
VERS='<old_version> <new_version>' ODIR=~/oct-out \
TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258 \
./tools/upgrade-matrix.sh
```

- Read-only self-check (no mutation):

```bash
make selfcheck
```

### Suggested production command patterns

- single version, classified output in project:
- `make all VER=<version> PKG=both`
- single version, custom output root:
- `make all VER=<version> PKG=both ODIR=~/oct-out`
- batch versions with range and flat output:
  - `make batch VERS='1.1.[1-20]' PKG=deb ODIR=~/oct-out MIX=1`

## TUI exit behavior

Launcher now preserves normal exit summaries better:

- successful exits use soft tty cleanup (keeps session/restore output visible)
- signal/error exits still use full tty cleanup for safety
