# opencode-termux — glibc branch (legacy)

**This is the legacy glibc-wrapper branch.** It produces OpenCode packages using
bun-termux-loader to wrap the glibc-linked upstream binary for Android/Bionic.
Stable, proven, actively maintained.

**Looking for the current mainline?** See the `main` branch (native-android line).

---

## Install

```bash
# Path A: apt/pkg (recommended)
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
apt install -y /path/to/opencode_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

## Build (local Termux)

```bash
make all VER=<version> PKG=both
make batch VERS='<major.minor.[start-end]>' PKG=deb ODIR=~/oct-out
```

## Dependencies

- `glibc` + `openssl-glibc` (required)
- `glibc-runner` (optional fallback)
- bun-termux-loader (auto-cloned)

## What this branch provides

- ✅ Local Termux build/package flow (produce-local.sh + build.sh + package_*)
- ✅ deb + pacman package output
- ✅ statx seccomp shim
- ✅ Plugin lifecycle system
- ✅ Cross-machine matrix simulation

## Upstream

- OpenCode: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
