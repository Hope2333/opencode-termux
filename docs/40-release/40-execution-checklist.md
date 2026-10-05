# Execution Checklist

## Phase A (CI armv7 prebuild)

> Status: handoff/deferred track. Not a substitute for local Termux final runtime validation.

1. Run workflow `prebuild-armv7.yml`
2. Download `prebuild-armv7-bundle`
3. Verify `manifest.json` and `checksums.txt`

## Phase B (local Termux final package)

> Status: mainline release path.

1. Prepare runtime: `tools/produce-local.sh <version>`
   - If npm has no requested version, script falls back to GitHub release binary download for that version.
2. Build staged prefix: `scripts/build.sh`
3. Verify staged runtime version
4. Build DEB: `scripts/package/package_deb.sh`
5. Build pacman package: `scripts/package/package_pacman.sh`
6. Verify package runtime versions before install
7. (Optional) Batch build multiple versions:
   - `make batch VERS='1.2.10 1.2.11 1.2.12' PKG=both`
   - supports bracket ranges like: `VERS='1.1.[1-20]'`
8. (Optional) Send artifacts to custom output dir:
   - `ODIR=~/oct-out make all VER=1.2.10 PKG=both`
   - `ODIR=~/oct-out make batch VERS='1.1.[1-20]' PKG=deb`
9. Output layout policy:
   - default output root: project `packing/`
   - with `ODIR`, do not write into project `packing/`
   - default classified layout: `deb/` and `pacman/`
   - flattened layout: use `MIX=1` or wrapper `--mix`

10. Cross-machine lifecycle simulation (cached artifacts only):
   - `TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258 make matrix VERS='1.2.9 1.2.10' ODIR=~/oct-out`
   - validates install/upgrade/downgrade/reinstall on machine2

11. Environment/plugin read-only self-check:
   - `make selfcheck`
12. Hook/skill verification in matrix run:
   - matrix run should emit hook log under `$PREFIX/var/log/opencode-hooks.log`
   - verify system skill manifests are visible in selfcheck output

## Phase C (plugin lifecycle)

1. Install plugin package with apt or pacman
2. Register plugin file entry and verify
3. Update plugin package
4. Roll back snapshot if needed
5. Export or apply local patches when upstream changes break runtime
6. If package-mode system skills are used, verify hook runner log + manifest status after install/upgrade

## Machine2 first-time prep

Before opencode install tests on a clean machine2:

1. `apt install -y glibc-repo`
2. `apt update`
3. `apt install -y glibc openssl-glibc`
4. (Optional fallback) `apt install -y glibc-runner`

Then run package install and behavior verification (`opencode --version`, `opencode --help`, `opencode web`).

## Pacman-primary machine prep

For Termux environments that already use pacman as primary package manager:

1. `pacman -Syu`
2. `pacman -S glibc openssl-glibc`
3. (Optional fallback) `pacman -S glibc-runner`
