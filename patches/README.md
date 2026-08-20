# Patches for OpenCode Android support

These patches modify the upstream OpenCode source (`github.com/anomalyco/opencode`)
to support Android/Termux as a build target.

## Patch files

- `0001-android-support.patch` — Adds "android" as a supported OS in build script
- `0002-bun-termux-cwd-fix.patch` — Default paths for Termux environment

## Applying

```bash
cd opencode-source
git apply ../patches/*.patch
bun install
bun run build --target=linux-arm64  # produces opencode-linux-arm64
```

## Building for Termux

The patches produce a standard `bun build --compile` output. The binary is then
wrapped for Android using bun-termux-loader (in CI or locally).
