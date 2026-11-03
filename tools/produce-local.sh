#!/data/data/com.termux/files/usr/bin/bash
# tools/produce-local.sh — Build OpenCode for Termux
# Downloads from npm + wraps with bun-termux-loader
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/artifacts/opencode/runtime"
OPENCODE_OUT="$RUNTIME_DIR/opencode-termux"
INPUT_VER="${1:-}"

log() { printf '[produce] %s\n' "$*" >&2; }
die() { printf '[produce] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

need npm
# Upstream renamed the published platform binary at the 2.x line:
#   v1 (1.x)  -> opencode-linux-arm64        (npm versions stop at 1.19.x)
#   v2 (2.x+) -> @opencode/cli-linux-arm64
# Resolving 2.x against the v1 name fails with ETARGET, which is how the
# 2.2.5 wrapper build died.
pkg_for_version() {
	case "${1:-}" in
		2.*) printf '%s' "@opencode/cli-linux-arm64" ;;
		*)   printf '%s' "opencode-linux-arm64" ;;
	esac
}

if [[ -z "$INPUT_VER" ]]; then
	# "latest" must follow the v2 line now; v1 keeps its own name.
	if ! INPUT_VER="$(npm view @opencode/cli-linux-arm64 version)"; then
		die "failed to resolve latest @opencode/cli-linux-arm64 version"
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
SRC_PKG="$(pkg_for_version "$VER")"
log "downloading $SRC_PKG@$VER from npm"
rm -f ./*.tgz 2>/dev/null || true
if ! npm pack "$SRC_PKG@$VER" >/dev/null; then
	die "npm pack failed ($SRC_PKG@$VER)"
fi
# The tarball name follows the package name (scoped packages drop the @ and /):
#   opencode-linux-arm64-1.19.5.tgz  |  opencode-cli-linux-arm64-2.2.5.tgz
_tgz="$(ls -1 ./*.tgz 2>/dev/null | head -1)"
[[ -n "$_tgz" ]] || die "npm pack produced no tarball for $SRC_PKG@$VER"
tar -xzf "$_tgz"
RAW="package/bin/opencode"
[[ -f "$RAW" && -x "$RAW" ]] || die "binary not found"

# Wrap with bun-termux-loader
if [[ ! -f "$LOADER_DIR/build.py" ]]; then
	log "cloning bun-termux-loader"
	if ! git clone -q --depth 1 https://github.com/Hope2333/bun-termux-loader "$EXTRACT/loader"; then
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
