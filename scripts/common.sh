#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

log() {
	printf '[opencode-termux] %s\n' "$*"
}

fail() {
	printf '[opencode-termux] ERROR: %s\n' "$*" >&2
	exit 1
}

ensure_dir() {
	mkdir -p "$1"
}

write_build_meta() {
	local out="$1"
	shift
	mkdir -p "$(dirname "$out")"
	{
		printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		for kv in "$@"; do
			printf '%s\n' "$kv"
		done
	} >"$out"
}
