#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_VER="${1:-}"

log() { printf '[produce-local] %s\n' "$*"; }
die() {
	printf '[produce-local] ERROR: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

resolve_version() {
	if [[ -n "$INPUT_VER" ]]; then
		printf '%s' "$INPUT_VER"
		return 0
	fi
	local latest
	latest="$(npm view opencode-linux-arm64 version 2>/dev/null || true)"
	[[ -n "$latest" ]] || die "unable to resolve latest opencode-linux-arm64 version; pass explicit version as first argument"
	printf '%s' "$latest"
}

VER="$(resolve_version)"
WORK_BASE="${WORK_BASE:-$ROOT_DIR/.work}"
WORK_DIR="${WORK_DIR:-$WORK_BASE/opencode-$VER}"
KEEP_WORK="${KEEP_WORK:-0}"
RUNTIME_DIR="$ROOT_DIR/artifacts/opencode/runtime"
RUNTIME_OUT="$RUNTIME_DIR/opencode-termux"
UPSTREAM_TGZ="opencode-linux-arm64-$VER.tgz"
UPSTREAM_BIN="$WORK_DIR/package/bin/opencode"
GITHUB_URL="https://github.com/anomalyco/opencode/releases/download/v${VER}/opencode-linux-arm64.tar.gz"

find_loader_repo() {
	# Allow explicit override via environment variable
	if [[ -n "${BUN_TERMUX_LOADER:-}" ]]; then
		if [[ -f "$BUN_TERMUX_LOADER/build.py" ]]; then
			printf '%s' "$BUN_TERMUX_LOADER"
			return 0
		fi
		return 1
	fi
	local c
	for c in "$HOME/bun-termux-loader" "$HOME/develop/bun-termux-loader"; do
		if [[ -f "$c/build.py" ]]; then
			printf '%s' "$c"
			return 0
		fi
	done
	return 1
}

clone_loader_repo() {
	local target="${1:?target dir required}"
	local url="${2:?repo URL required}"
	log "bun-termux-loader not found locally, cloning from $url"
	if ! command -v git >/dev/null 2>&1; then
		return 1
	fi
	local parent
	parent="$(dirname "$target")"
	mkdir -p "$parent"
	git clone --depth 1 "$url" "$target" 2>&1 || return 1
	if [[ ! -f "$target/build.py" ]]; then
		log "warning: cloned repo missing build.py, cleaning up"
		rm -rf "$target"
		return 1
	fi
	return 0
}

resolve_loader_repo() {
	local found
	if found="$(find_loader_repo)"; then
		printf '%s' "$found"
		return 0
	fi

	# Auto-clone fallback: try common upstream locations
	local candidates=(
		"$HOME/develop/bun-termux-loader:https://github.com/kaan-escober/bun-termux-loader"
		"$HOME/bun-termux-loader:https://github.com/kaan-escober/bun-termux-loader"
	)
	local c target url
	for c in "${candidates[@]}"; do
		target="${c%%:*}"
		url="${c#*:}"
		if clone_loader_repo "$target" "$url"; then
			printf '%s' "$target"
			return 0
		fi
	done

	return 1
}

download_upstream_binary() {
	local npm_ok=0
	log "downloading upstream package from npm (preferred)"
	if npm pack "opencode-linux-arm64@$VER" >/dev/null 2>&1 && [[ -f "$UPSTREAM_TGZ" ]]; then
		tar -xzf "$UPSTREAM_TGZ"
		if [[ -x "$UPSTREAM_BIN" ]]; then
			npm_ok=1
		fi
	fi

	if [[ "$npm_ok" -eq 1 ]]; then
		log "using npm package source for version $VER"
		return 0
	fi

	log "npm package for version $VER not available, falling back to GitHub release binary"
	local gh_tgz="$WORK_DIR/opencode-linux-arm64-github-$VER.tar.gz"
	if command -v curl >/dev/null 2>&1; then
		curl -fL "$GITHUB_URL" -o "$gh_tgz" || die "github fallback download failed: $GITHUB_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$gh_tgz" "$GITHUB_URL" || die "github fallback download failed: $GITHUB_URL"
	else
		die "missing curl/wget for github fallback download"
	fi

	mkdir -p "$WORK_DIR/package/bin"
	tar -xzf "$gh_tgz" -C "$WORK_DIR" || true

	local candidate=""
	for c in "$WORK_DIR/opencode-linux-arm64" "$WORK_DIR/opencode"; do
		if [[ -x "$c" ]]; then
			candidate="$c"
			break
		fi
	done

	if [[ -z "$candidate" ]]; then
		candidate="$(find "$WORK_DIR" -maxdepth 3 -type f \( -name 'opencode' -o -name 'opencode-*' \) -perm -u+x 2>/dev/null | head -n1 || true)"
	fi

	[[ -n "$candidate" && -x "$candidate" ]] || die "github fallback unpacked but upstream binary not found"
	cp "$candidate" "$UPSTREAM_BIN"
	log "using GitHub release source for version $VER (candidate: $candidate)"
}

need npm
need tar
need file
need python3

LOADER_REPO="$(resolve_loader_repo || true)"
[[ -n "$LOADER_REPO" ]] || die "bun-termux-loader not found and auto-clone failed (need build.py)"

log "version=$VER"
log "work_base=$WORK_BASE"
log "work_dir=$WORK_DIR"
log "loader_repo=$LOADER_REPO"

mkdir -p "$WORK_BASE"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

download_upstream_binary

log "upstream fingerprint"
file "$UPSTREAM_BIN"

mkdir -p "$RUNTIME_DIR"
log "wrapping upstream binary for Termux/Android"
(cd "$LOADER_REPO" && python3 build.py "$UPSTREAM_BIN" --wrapper ./wrapper)
[[ -f "$WORK_DIR/package/bin/opencode-termux" ]] || die "wrapped runtime not generated"
install -m 755 "$WORK_DIR/package/bin/opencode-termux" "$RUNTIME_OUT"

log "wrapped runtime verification"
file "$RUNTIME_OUT"
"$RUNTIME_OUT" --version

log "cleaning generated outputs to avoid stale contamination"
rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packaging/dpkg/work" "$ROOT_DIR/packaging/pacman/src"

if [[ "$KEEP_WORK" != "1" ]]; then
	log "cleaning temporary work directory"
	rm -rf "$WORK_DIR"
fi

cat <<MSG
[produce-local] Runtime prepared successfully:
  $RUNTIME_OUT

Next steps (repo-specific):
  1) build staged tree from this runtime
  2) package deb/pacman
  3) verify staged/deb/pacman runtime versions are all $VER
MSG
