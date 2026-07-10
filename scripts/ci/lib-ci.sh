#!/usr/bin/env bash
# scripts/ci/lib-ci.sh — shared helpers for armv7 prebuild CI scripts.
# Sourced by scripts/ci/build-*.sh; not meant to be executed directly.

# Resolve OUT_DIR to an absolute path, create the standard output subtree
# (assets/logs/status/work), and echo the absolute path.
ci_prepare_out_dir() {
	local out_dir="$1"
	local abs
	abs="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"
	mkdir -p "$abs/assets" "$abs/logs" "$abs/status" "$abs/work"
	printf '%s' "$abs"
}

# Ensure a host Bun toolchain is present. Sets HOST_BUN on success; exits 10
# otherwise (matching the historical CI exit code).
ci_require_host_bun() {
	HOST_BUN="$HOME/.bun/bin/bun"
	if [[ ! -x "$HOST_BUN" ]]; then
		echo "host bun not found at $HOST_BUN" >&2
		exit 10
	fi
}

# Shallow-clone the Bun source tree for a given version into DEST, logging to
# LOGFILE. Returns git's exit status so callers can emit their own status JSON.
ci_clone_bun() {
	local version="$1" dest="$2" logfile="$3"
	git clone --depth=1 --branch "bun-v${version}" \
		https://github.com/oven-sh/bun.git "$dest" >"$logfile" 2>&1
}

# Classify a bun compile failure by inspecting its log. Prints the shared
# "unsupported target" reason when detected, otherwise the caller's fallback.
ci_compile_failure_reason() {
	local logfile="$1" fallback="$2"
	if grep -q "Unsupported target" "$logfile" 2>/dev/null; then
		printf 'bun compile target bun-linux-armv7 unsupported by current Bun'
	else
		printf '%s' "$fallback"
	fi
}
