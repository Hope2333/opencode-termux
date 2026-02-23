# CI Prebuild (armv7, cross-toolchain scaffold)

Phase A uses GitHub Actions to prepare an armv7 cross-build platform and emit handoff artifacts.

## Why this replaces URL-only downloads

Direct armv7 download URLs for OpenCode/Bun are not reliable and often return 404.
So CI now prioritizes cross-toolchain setup and release asset evidence collection.

## What CI produces

- armv7 cross toolchain evidence (`gcc`/`qemu` versions)
- release asset snapshots from GitHub API for OpenCode and Bun
- armv7 candidate asset name lists (if any)
- pkgfile templates for downstream packaging
- manifest/checksums for handoff provenance

## What CI does not claim

- CI output is not final Termux runtime/package
- final wrapping, patching, package assembly, and runtime/plugin verification still happen on local Termux devices

## Next step to make this a real compiler pipeline

Add repository-specific source build scripts for OpenCode/Bun armv7 and run them in this cross-toolchain job.
