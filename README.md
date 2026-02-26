# opencode-termux (OCT)

Termux-focused packaging and runtime workflow for OpenCode.

This repository is part of the OML/OCT track and focuses on:

- reproducible OpenCode runtime packaging on real Termux devices
- consistent deb + pacman package outputs from one staged prefix
- safer launcher defaults for Termux runtime behavior
- plugin lifecycle support (install/update/rollback/patch)

## Current status (important)

- Verified runtime line: **OpenCode Runtime 1.2.10** (Android/Bionic wrapped)
- Final packages are produced **locally on Termux**
- GitHub Actions is used for **armv7 cross-prebuild handoff**, not final Termux runtime claims

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
./tools/produce-local.sh 1.2.10
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
- Runtime build details: `docs/13-opencode-runtime-build.md`
- Package docs: `docs/20-packaging-deb.md`, `docs/21-packaging-pkg-tar-xz.md`
- CI armv7 handoff: `docs/ci-prebuild-armv7.md`
- Execution checklist: `docs/execution-checklist.md`
- Incident RCA (`.so` restart snowball): `docs/incidents/2026-02-23-opencode-web-termux-so-avalanche.md`

## License / upstream

- Upstream OpenCode: <https://github.com/anomalyco/opencode>
- This packaging workflow repository follows upstream license constraints for redistributed artifacts.

## Build convenience and version resolution (latest update)

You can orchestrate full local build/package flow with Make targets or wrapper flags.

Examples:

```bash
make all VER=1.2.10 PKG=both
make all VER=latest PKG=pacman
make batch VERS='1.1.[1-20]' PKG=deb ODIR=~/oct-out
./tools/make-opencode --all --ver 1.2.10 --pkg pacman
./tools/make-opencode --batch --vers '1.2.10 1.2.11' --pkg both --odir ~/oct-out
./tools/make-opencode --all --ver 1.2.10 --pkg both --odir ~/oct-out --mix
```

Rules:

- `tools/produce-local.sh` version priority:
  1) first positional argument (explicit version)
  2) latest `opencode-linux-arm64` from npm (if no version passed)
- if npm package for requested version is unavailable, fallback downloads GitHub release binary (`opencode-linux-arm64.tar.gz`) for that version.
- work directory defaults to project-local `.work/` (instead of `$HOME/work-*`), and is auto-cleaned unless `KEEP_WORK=1`.
- Packaging targets auto-clean generated work dirs before running to reduce stale contamination.
- Pacman package version is derived from staged runtime (`.../runtime/opencode --version`) instead of hardcoded `pkgver`.
- Package metadata now uses `Depends: glibc` and recommends/optdepends `glibc-runner` as fallback helper tools.
  Current validated network-minimal set (for `opencode run "hi"`): `glibc` + `openssl-glibc`.
- output policy:
  - default output root is project `packing/`
  - if `ODIR` is set, outputs go to `ODIR` and do not use project `packing/`
  - default classified layout: `deb/` and `pacman/` subfolders
  - if `MIX=1` or `--mix`, artifacts are flattened into one directory

## TUI exit behavior (latest update)

Launcher now preserves normal exit summaries better:

- successful exits use soft tty cleanup (keeps session/restore output visible)
- signal/error exits still use full tty cleanup for safety
