# CI Prebuild (armv7, cross-toolchain + binary attempts)

Phase A now does two things:

1. Prepare a Linux armv7 cross-build platform in GitHub Actions
2. Attempt to produce **two armv7l-linux bins** for handoff:
   - `bun` armv7 probe binary (hello sample first)
   - `bun` armv7 source-build attempt binary
   - `opencode` armv7 binary (compiled only when package source is available)

## Why this approach

Upstream armv7 release URLs are unreliable or unavailable. The workflow still records release asset evidence, but the main path is now **attempt-based source/compile execution** with preserved logs.

## Success condition (Phase A target)

Artifact contains both files (or their build logs explaining blockers):

- `assets/bun-hello-linux-armv7` (or future `bun-linux-armv7`)
- `assets/opencode-linux-armv7`

## Debug loop

- Trigger workflow by push/workflow_dispatch
- Download artifact bundle
- Inspect:
- `logs/build-bun-armv7.log`
- `logs/build-bun-armv7-source.log`
- `logs/build-opencode-armv7.log`
- `status/*.json`
- `status/build-attempt-status.json`

This keeps CI iterations fast and makes failures actionable.
