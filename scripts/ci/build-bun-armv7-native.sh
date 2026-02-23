#!/usr/bin/env bash
set -euo pipefail

BUN_VERSION="${1:?bun version required}"
OUT_DIR="${2:?out dir required}"
ABS_OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$ABS_OUT_DIR/assets" "$ABS_OUT_DIR/logs" "$ABS_OUT_DIR/status" "$ABS_OUT_DIR/work"

ARCH_RAW="$(uname -m || true)"
if ! echo "$ARCH_RAW" | grep -Eiq 'armv7|armv6|arm'; then
  printf '{\n  "status": "failed",\n  "reason": "native runner is not arm32",\n  "detected_arch": "%s"\n}\n' "$ARCH_RAW" > "$ABS_OUT_DIR/status/bun-native-build-status.json"
  exit 51
fi

WORK="$ABS_OUT_DIR/work/bun-native-src"
rm -rf "$WORK"
mkdir -p "$WORK"

if ! git clone --depth=1 --branch "bun-v${BUN_VERSION}" https://github.com/oven-sh/bun.git "$WORK" >"$ABS_OUT_DIR/logs/bun-native-git-clone.txt" 2>&1; then
  printf '{\n  "status": "failed",\n  "reason": "failed to clone bun tag",\n  "bun_version": "%s"\n}\n' "$BUN_VERSION" > "$ABS_OUT_DIR/status/bun-native-build-status.json"
  exit 52
fi

cd "$WORK"
{
  echo "uname=$(uname -a)"
  command -v bun && bun --version || true
  command -v cmake && cmake --version | head -n 1 || true
  command -v ninja && ninja --version || true
  command -v rustc && rustc --version || true
  command -v cargo && cargo --version || true
  command -v python3 && python3 --version || true
} > "$ABS_OUT_DIR/logs/bun-native-env.txt" 2>&1

set +e
bash -lc 'bun run build:release' > "$ABS_OUT_DIR/logs/bun-native-build.log" 2>&1
rc=$?
set -e

if [[ -f "$WORK/build/release/bun" ]]; then
  cp -a "$WORK/build/release/bun" "$ABS_OUT_DIR/assets/bun-linux-armv7-native"
  file "$ABS_OUT_DIR/assets/bun-linux-armv7-native" > "$ABS_OUT_DIR/logs/bun-native-file.txt" || true
  printf '{\n  "status": "success",\n  "bun_version": "%s",\n  "exit_code": %s,\n  "artifact": "assets/bun-linux-armv7-native"\n}\n' "$BUN_VERSION" "$rc" > "$ABS_OUT_DIR/status/bun-native-build-status.json"
  exit 0
fi

printf '{\n  "status": "failed",\n  "bun_version": "%s",\n  "exit_code": %s,\n  "reason": "native build completed without release bun binary"\n}\n' "$BUN_VERSION" "$rc" > "$ABS_OUT_DIR/status/bun-native-build-status.json"
exit 53
