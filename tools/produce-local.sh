#!/usr/bin/env bash
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
WORK_DIR="${WORK_DIR:-$HOME/work-opencode-$VER}"
RUNTIME_DIR="$ROOT_DIR/artifacts/opencode/runtime"
RUNTIME_OUT="$RUNTIME_DIR/opencode-termux"
UPSTREAM_TGZ="opencode-linux-arm64-$VER.tgz"
UPSTREAM_BIN="$WORK_DIR/package/bin/opencode"
GITHUB_URL="https://github.com/anomalyco/opencode/releases/download/v${VER}/opencode-linux-arm64.tar.gz"

find_loader_repo() {
	local c
	for c in "$HOME/bun-termux-loader" "$HOME/develop/bun-termux-loader"; do
		if [[ -f "$c/build.py" ]]; then
			printf '%s' "$c"
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
	if [[ -x "$WORK_DIR/opencode-linux-arm64" ]]; then
		cp "$WORK_DIR/opencode-linux-arm64" "$UPSTREAM_BIN"
	fi
	[[ -x "$UPSTREAM_BIN" ]] || die "github fallback unpacked but upstream binary not found"
	log "using GitHub release source for version $VER"
}

need npm
need tar
need file
need python3

LOADER_REPO="$(find_loader_repo || true)"
[[ -n "$LOADER_REPO" ]] || die "bun-termux-loader not found (need build.py)"

log "version=$VER"
log "work_dir=$WORK_DIR"
log "loader_repo=$LOADER_REPO"

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

cat <<MSG
[produce-local] Runtime prepared successfully:
  $RUNTIME_OUT

Next steps (repo-specific):
  1) build staged tree from this runtime
  2) package deb/pacman
  3) verify staged/deb/pacman runtime versions are all $VER
MSG
