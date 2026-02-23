#!/usr/bin/env bash
set -euo pipefail

BUN_VERSION="${1:?bun version required}"
OUT_DIR="${2:?out dir required}"
ABS_OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$ABS_OUT_DIR/assets" "$ABS_OUT_DIR/logs" "$ABS_OUT_DIR/status" "$ABS_OUT_DIR/work"

WORK="$ABS_OUT_DIR/work/bun-src"
rm -rf "$WORK"
mkdir -p "$WORK"

printf '{\n  "status": "started",\n  "bun_version": "%s",\n  "strategy": "cross-compile-first"\n}\n' "$BUN_VERSION" >"$ABS_OUT_DIR/status/bun-source-build-status.json"

git clone --depth=1 --branch "bun-v${BUN_VERSION}" https://github.com/oven-sh/bun.git "$WORK" >"$ABS_OUT_DIR/logs/bun-source-git-clone.txt" 2>&1 || {
	printf '{\n  "status": "failed",\n  "phase": "git-clone",\n  "reason": "failed to clone bun tag",\n  "bun_version": "%s"\n}\n' "$BUN_VERSION" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
	exit 41
}

cd "$WORK"

{
	echo "pwd=$(pwd)"
	echo "uname=$(uname -a)"
	command -v clang-21 && clang-21 --version | head -n 2 || true
	command -v cmake && cmake --version | head -n 1 || true
	command -v ninja && ninja --version || true
	command -v rustc && rustc --version || true
	command -v cargo && cargo --version || true
	command -v go && go version || true
	command -v python3 && python3 --version || true
	command -v arm-linux-gnueabihf-gcc && arm-linux-gnueabihf-gcc --version | head -n 1 || true
} >"$ABS_OUT_DIR/logs/bun-source-env.txt" 2>&1

export CC=arm-linux-gnueabihf-gcc
export CXX=arm-linux-gnueabihf-g++
export AR=arm-linux-gnueabihf-ar
export STRIP=arm-linux-gnueabihf-strip
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
export BUN_CROSS_TARGET="linux-armv7l"

printf '{\n  "status": "attempting",\n  "phase": "source-build",\n  "bun_version": "%s",\n  "strategy": "cross-compile-first"\n}\n' "$BUN_VERSION" >"$ABS_OUT_DIR/status/bun-source-build-status.json"

set +e
bash -lc 'bun run build:release' >"$ABS_OUT_DIR/logs/bun-source-build.log" 2>&1
rc=$?
set -e

if [[ -f "$WORK/build/release/bun" ]]; then
	cp -a "$WORK/build/release/bun" "$ABS_OUT_DIR/assets/bun-linux-armv7-source-attempt"
	file "$ABS_OUT_DIR/assets/bun-linux-armv7-source-attempt" >"$ABS_OUT_DIR/logs/bun-source-build-file.txt" || true
	printf '{\n  "status": "success",\n  "phase": "source-build",\n  "bun_version": "%s",\n  "artifact": "assets/bun-linux-armv7-source-attempt",\n  "build_exit_code": %s\n}\n' "$BUN_VERSION" "$rc" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
	exit 0
fi

reason="source build failed; see bun-source-build.log"
if grep -qi 'unsupported\|unknown target\|aarch64\|x86_64' "$ABS_OUT_DIR/logs/bun-source-build.log" 2>/dev/null; then
	reason="source build did not produce armv7 binary; likely default host-target build path or unsupported cross flags"
fi

printf '{\n  "status": "failed",\n  "phase": "source-build",\n  "bun_version": "%s",\n  "build_exit_code": %s,\n  "reason": "%s",\n  "next": "try explicit bun build scripts/flags or native armv7 runner"\n}\n' "$BUN_VERSION" "$rc" "$reason" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
exit 42
