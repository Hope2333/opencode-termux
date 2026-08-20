#!/data/data/com.termux/files/usr/bin/bash
# tools/produce-local.sh — Build OpenCode for Termux
# Downloads from npm + wraps with bun-termux-loader
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/artifacts/opencode/runtime"
OPENCODE_OUT="$RUNTIME_DIR/opencode-termux"
INPUT_VER="${1:-}"

log() { printf '[produce] %s\n' "$*"; }
die() { printf '[produce] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

need npm
if [[ -z "$INPUT_VER" ]]; then
	if ! INPUT_VER="$(npm view opencode-linux-arm64 version)"; then
		die "failed to resolve latest opencode-linux-arm64 version"
	fi
fi
[[ -n "$INPUT_VER" ]] || die "no version specified"
VER="$INPUT_VER"

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/opencode-termux}"
LOADER_DIR="/data/data/com.termux/files/home/bun-termux-loader"
EXTRACT="${TMPDIR:-$PREFIX/tmp}/produce-$$"
mkdir -p "$RUNTIME_DIR" "$CACHE_DIR" "$EXTRACT"
trap 'rm -rf "$EXTRACT"' EXIT

log "opencode v$VER"

# Check cache
CACHE_BIN="$CACHE_DIR/opencode-$VER"
if [[ -f "$CACHE_BIN" ]]; then
	log "cache hit"
	install -m 755 "$CACHE_BIN" "$OPENCODE_OUT"
	if ! runtime_version="$("$OPENCODE_OUT" --version)"; then
		die "cached runtime failed version check: $CACHE_BIN"
	fi
	[[ -n "$runtime_version" ]] || die "cached runtime returned an empty version: $CACHE_BIN"
	log "version: $runtime_version"
	rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packing/dpkg/work" "$ROOT_DIR/packing/pacman/src"
	log "DONE"
	exit 0
fi

# Download from npm
cd "$EXTRACT"
log "downloading opencode-linux-arm64@$VER from npm"
if ! npm pack "opencode-linux-arm64@$VER" >/dev/null; then
	die "npm pack failed"
fi
tar -xzf opencode-linux-arm64-*.tgz
RAW="package/bin/opencode"
[[ -f "$RAW" && -x "$RAW" ]] || die "binary not found"

# Wrap with bun-termux-loader
if [[ ! -f "$LOADER_DIR/build.py" ]]; then
	log "cloning bun-termux-loader"
	if ! git clone --depth 1 https://github.com/Hope2333/bun-termux-loader "$EXTRACT/loader"; then
		die "clone failed"
	fi
	LOADER_DIR="$EXTRACT/loader"
fi

log "wrapping for Termux"
python3 "$LOADER_DIR/build.py" "$RAW" --wrapper "$LOADER_DIR/wrapper" --shim "$LOADER_DIR/bunfs_shim.so" 2>&1 | tail -3
WRAPPED="${RAW}-termux"
[[ -f "$WRAPPED" ]] || die "wrapping failed"

install -m 755 "$WRAPPED" "$OPENCODE_OUT"
install -m 755 "$WRAPPED" "$CACHE_BIN"
log "done: $(file "$OPENCODE_OUT" | cut -d: -f2)"
if ! runtime_version="$("$OPENCODE_OUT" --version)"; then
	die "wrapped runtime failed version check"
fi
[[ -n "$runtime_version" ]] || die "wrapped runtime returned an empty version"
log "version: $runtime_version"

rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packing/dpkg/work" "$ROOT_DIR/packing/pacman/src"
log "DONE"
