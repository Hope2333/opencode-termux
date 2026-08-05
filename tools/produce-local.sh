#!/data/data/com.termux/files/usr/bin/bash
# tools/produce-local.sh — Build OpenCode for Termux
# Downloads from npm; wraps Bun ELF (v1 / v2-beta) with bun-termux-loader,
# or stages a Node.js distribution (future v2 GA) without wrapping.
#
# Version input accepts:
#   - concrete version (e.g. 1.18.13, 0.0.0-beta-202608050826)
#   - npm dist-tag (beta, tui-v2, latest; default: latest)
#
# Runtime-form detection (after download):
#   - ELF binary -> bun-termux-loader wrap path (v1 + v2 beta, glibc)
#   - non-ELF    -> Node.js dist path (future v2 GA, no wrapping)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/artifacts/opencode/runtime"
OPENCODE_OUT="$RUNTIME_DIR/opencode-termux"
INPUT="${1:-latest}"

log() { printf '[produce] %s\n' "$*"; }
die() { printf '[produce] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

need npm
need file

# ── Version resolution: dist-tag or concrete version ──────────────────
case "$INPUT" in
latest|beta|tui-v2|next)
	if ! VER="$(npm view "opencode-linux-arm64@$INPUT" version --fetch-retries=5 --fetch-retry-mintimeout=20000 --fetch-retry-maxtimeout=120000)"; then
		die "failed to resolve opencode-linux-arm64@$INPUT (dist-tag)"
	fi
	;;
*)
	VER="$INPUT"
	# validate the concrete version exists (catches typos early)
	if ! npm view "opencode-linux-arm64@$VER" version >/dev/null 2>&1 --fetch-retries=5 --fetch-retry-mintimeout=20000 --fetch-retry-maxtimeout=120000; then
		die "unknown version/dist-tag: $VER"
	fi
	;;
esac
[[ -n "$VER" ]] || die "no version resolved"
log "input=$INPUT -> version $VER"

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
if ! npm pack "opencode-linux-arm64@$VER" --fetch-retries=5 --fetch-retry-mintimeout=20000 --fetch-retry-maxtimeout=120000 >/dev/null; then
	die "npm pack failed"
fi
tar -xzf opencode-linux-arm64-*.tgz
RAW="package/bin/opencode"
[[ -f "$RAW" && -x "$RAW" ]] || die "binary not found"

# ── Runtime-form detection ────────────────────────────────────────────
if file "$RAW" | grep -q 'ELF'; then
	RUNTIME_FORM="bun-elf"
else
	RUNTIME_FORM="node-js"
fi
log "runtime form: $RUNTIME_FORM"

# ── v2 GA (Node.js dist) path: no loader wrapping needed ──────────────
if [[ "$RUNTIME_FORM" == "node-js" ]]; then
	log "Node.js distribution detected — staging as-is (no bun-termux-loader)"
	need node
	# Verify the entry runs under the system Node before staging.
	if ! runtime_version="$(node "$RAW" --version)"; then
		die "node distribution failed version check"
	fi
	[[ -n "$runtime_version" ]] || die "node distribution returned an empty version"
	install -m 755 "$RAW" "$OPENCODE_OUT"
	# Bundle adjacent JS chunks / node_modules if present in package/bin or package/
	if [[ -d package/bin && -n "$(ls package/bin 2>/dev/null)" ]]; then
		mkdir -p "$RUNTIME_DIR/v2-dist"
		cp -a package/bin/. "$RUNTIME_DIR/v2-dist/"
	fi
	if [[ -d package/node_modules ]]; then
		mkdir -p "$RUNTIME_DIR/v2-dist"
		cp -a package/node_modules "$RUNTIME_DIR/v2-dist/node_modules"
	fi
	log "version: $runtime_version"
	rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packing/dpkg/work" "$ROOT_DIR/packing/pacman/src"
	log "DONE (node-js)"
	exit 0
fi

# ── Bun ELF path: wrap with bun-termux-loader (v1 + v2 beta) ──────────
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
