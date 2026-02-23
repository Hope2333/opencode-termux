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

## Quick links

- Runtime build details: `docs/13-opencode-runtime-build.md`
- Package docs: `docs/20-packaging-deb.md`, `docs/21-packaging-pkg-tar-xz.md`
- CI armv7 handoff: `docs/ci-prebuild-armv7.md`
- Execution checklist: `docs/execution-checklist.md`
- Incident RCA (`.so` restart snowball): `docs/incidents/2026-02-23-opencode-web-termux-so-avalanche.md`

## License / upstream

- Upstream OpenCode: <https://github.com/anomalyco/opencode>
- This packaging workflow repository follows upstream license constraints for redistributed artifacts.
