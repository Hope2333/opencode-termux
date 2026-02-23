#!/usr/bin/env bash
set -euo pipefail

BUN_VERSION="${1:?bun version required}"
OUT_DIR="${2:?out dir required}"
ABS_OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$ABS_OUT_DIR/assets" "$ABS_OUT_DIR/logs" "$ABS_OUT_DIR/status" "$ABS_OUT_DIR/work"

WORK="$ABS_OUT_DIR/work/bun-src"
rm -rf "$WORK"
mkdir -p "$WORK"

printf '{\n  "status": "started",\n  "bun_version": "%s",\n  "strategy": "cross-compile-matrix"\n}\n' "$BUN_VERSION" >"$ABS_OUT_DIR/status/bun-source-build-status.json"

if ! git clone --depth=1 --branch "bun-v${BUN_VERSION}" https://github.com/oven-sh/bun.git "$WORK" >"$ABS_OUT_DIR/logs/bun-source-git-clone.txt" 2>&1; then
	printf '{\n  "status": "failed",\n  "phase": "git-clone",\n  "reason": "failed to clone bun tag",\n  "bun_version": "%s"\n}\n' "$BUN_VERSION" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
	exit 41
fi

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
export BUN_CROSS_TARGET="linux-armv7l"

attempt_names=(
	"baseline-release"
	"explicit-cmake-processor"
	"explicit-cmake-system-arm"
)
attempt_cmds=(
	"bun run build:release"
	"bun ./scripts/build.mjs -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_PROCESSOR=armv7 -B build/release-armv7-processor"
	"bun ./scripts/build.mjs -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7 -B build/release-armv7-system"
)

success="false"
selected_artifact=""
selected_attempt=""

for i in "${!attempt_names[@]}"; do
	name="${attempt_names[$i]}"
	cmd="${attempt_cmds[$i]}"
	log_file="$ABS_OUT_DIR/logs/bun-source-${name}.log"
	status_file="$ABS_OUT_DIR/status/bun-source-${name}.json"

	printf '{\n  "status": "running",\n  "attempt": "%s",\n  "command": "%s"\n}\n' "$name" "$cmd" >"$status_file"

	set +e
	bash -lc "$cmd" >"$log_file" 2>&1
	rc=$?
	set -e

	found=""
	for candidate in \
		"$WORK/build/release/bun" \
		"$WORK/build/release-armv7-processor/bun" \
		"$WORK/build/release-armv7-system/bun"; do
		if [[ -f "$candidate" ]]; then
			found="$candidate"
			break
		fi
	done

	if [[ -n "$found" ]]; then
		out_bin="$ABS_OUT_DIR/assets/bun-linux-armv7-source-${name}"
		cp -a "$found" "$out_bin"
		file "$out_bin" >"$ABS_OUT_DIR/logs/bun-source-${name}-file.txt" || true

		arch_line="$(file "$out_bin" 2>/dev/null || true)"
		is_armv7="false"
		if echo "$arch_line" | grep -Eiq 'arm(,| )|armv7|EABI'; then
			is_armv7="true"
		fi

		printf '{\n  "status": "completed",\n  "attempt": "%s",\n  "exit_code": %s,\n  "artifact": "%s",\n  "file": "%s",\n  "armv7_like": %s\n}\n' "$name" "$rc" "$out_bin" "$arch_line" "$is_armv7" >"$status_file"

		if [[ "$is_armv7" == "true" ]]; then
			success="true"
			selected_artifact="$out_bin"
			selected_attempt="$name"
			break
		fi
	else
		printf '{\n  "status": "completed",\n  "attempt": "%s",\n  "exit_code": %s,\n  "artifact": null,\n  "reason": "no bun binary produced"\n}\n' "$name" "$rc" >"$status_file"
	fi
done

if [[ "$success" == "true" ]]; then
	printf '{\n  "status": "success",\n  "phase": "source-build",\n  "bun_version": "%s",\n  "selected_attempt": "%s",\n  "artifact": "%s"\n}\n' "$BUN_VERSION" "$selected_attempt" "$selected_artifact" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
	exit 0
fi

reason="no armv7-like bun binary produced across cross-build attempts"
printf '{\n  "status": "failed",\n  "phase": "source-build",\n  "bun_version": "%s",\n  "reason": "%s",\n  "next": "inspect bun-source-*.log and consider native armv7 runner"\n}\n' "$BUN_VERSION" "$reason" >"$ABS_OUT_DIR/status/bun-source-build-status.json"
exit 42
