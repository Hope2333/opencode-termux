# Native armv7 Runner Setup (self-hosted)

This document describes the minimum viable setup for a GitHub Actions self-hosted runner used by the optional native armv7 Bun build fallback job.

## Goal

Provide a runner with labels:

- `self-hosted`
- `linux`
- `armv7`

so workflow job `armv7-native-bun-fallback` can execute on real 32-bit ARM hardware.

## Why this exists

Cross-build attempts currently fail to produce a Bun armv7 binary, and CI emits `next-build-path.json` with:

- `native_required: true`
- `next_path: native-armv7-runner`

## Recommended hardware

Any reliable ARMv7/aarch32 Linux host that can run continuously and compile native code.

Examples:
- Raspberry Pi with 32-bit OS (armv7 capable model)
- ARM SBC with Debian/Ubuntu armhf userland
- armv7 development board with stable cooling and storage

## Recommended OS baseline

- Debian armhf / Raspberry Pi OS 32-bit / Ubuntu armhf
- `uname -m` should report `armv7l` (or equivalent 32-bit ARM)
- `file /bin/sh` should indicate 32-bit ARM ELF

## GitHub self-hosted runner setup (high level)

1. Create a dedicated user (recommended): `github-runner`
2. Register runner in repository settings:
   - Repo: `Hope2333/opencode-termux`
3. Assign labels:
   - `self-hosted`, `linux`, `armv7`
4. Run as a service for reliability

## Required build dependencies (first pass)

Install these before testing native Bun build fallback:

- `git`
- `curl`
- `ca-certificates`
- `build-essential`
- `cmake`
- `ninja-build`
- `python3`
- `pkg-config`
- `clang` (if available)
- `llvm` (version depends on distro)
- `rustc`, `cargo`
- `zig` (if Bun revision requires it)
- `bun` (host bun bootstrap, if needed by build scripts)

## Optional but recommended

- `ccache`
- swap enabled
- SSD or reliable storage
- persistent cache path

## Verification checklist (before dispatching workflow)

Run on runner host:

```bash
uname -a
uname -m
file /bin/sh
cmake --version
ninja --version
python3 --version
rustc --version || true
cargo --version || true
bun --version || true
```

Expected architecture signal:
- `uname -m` => `armv7l` (or armhf-compatible 32-bit ARM)

## Triggering the workflow

Use workflow dispatch and set:

- `run_native_armv7 = true`

The workflow runs `armv7-native-bun-fallback` on the self-hosted armv7 runner.

## Artifact outputs to inspect

After native run, inspect artifact:
- `armv7-native-bun-fallback`

Key files:
- `status/bun-native-build-status.json`
- `logs/bun-native-build.log`
- `logs/bun-native-env.txt`
- `logs/bun-native-file.txt` (if binary produced)

## First success criterion

A file exists and validates as 32-bit ARM Linux:

```bash
file assets/bun-linux-armv7-native
# expect: ELF 32-bit LSB executable, ARM ...
```

Once this succeeds, proceed to OpenCode armv7 compile/packaging on top of that Bun binary.
