# Execution Checklist

## Phase A (CI armv7 prebuild)

1. Run workflow `prebuild-armv7.yml`
2. Download `prebuild-armv7-bundle`
3. Verify `manifest.json` and `checksums.txt`

## Phase B (local Termux final package)

1. Prepare runtime: `tools/produce-local.sh <version>`
2. Build staged prefix: `scripts/build.sh`
3. Verify staged runtime version
4. Build DEB: `scripts/package/package_deb.sh`
5. Build pacman package: `scripts/package/package_pacman.sh`
6. Verify package runtime versions before install

## Phase C (plugin lifecycle)

1. Install plugin package with apt or pacman
2. Register plugin file entry and verify
3. Update plugin package
4. Roll back snapshot if needed
5. Export or apply local patches when upstream changes break runtime
