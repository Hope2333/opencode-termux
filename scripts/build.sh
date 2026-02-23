#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"

OPENCODE_SRC_DIR="${OPENCODE_SRC_DIR:-$ROOT_DIR/sources/opencode/repo}"
OUT_DIR="${OPENCODE_OUT_DIR:-$ROOT_DIR/artifacts/staged}"
PREFIX_DIR="${OPENCODE_PREFIX_DIR:-$OUT_DIR/prefix}"
RUNTIME_INPUT="${OPENCODE_RUNTIME_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/opencode-termux}"
RUNTIME_FALLBACK_INPUT="${OPENCODE_RUNTIME_FALLBACK_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/opencode}"

ensure_dir "$PREFIX_DIR/lib/opencode/runtime"
ensure_dir "$PREFIX_DIR/bin"

if [[ -d "$OPENCODE_SRC_DIR" ]]; then
	log "copying source from $OPENCODE_SRC_DIR"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete --exclude '.git' --exclude 'node_modules' "$OPENCODE_SRC_DIR/" "$PREFIX_DIR/lib/opencode/"
	else
		rm -rf "$PREFIX_DIR/lib/opencode"
		ensure_dir "$PREFIX_DIR/lib/opencode"
		cp -a "$OPENCODE_SRC_DIR/." "$PREFIX_DIR/lib/opencode/"
		rm -rf "$PREFIX_DIR/lib/opencode/.git" "$PREFIX_DIR/lib/opencode/node_modules"
	fi
else
	log "source tree not found; continuing runtime-only staging"
fi

if [[ -f "$RUNTIME_INPUT" ]]; then
	install -m 755 "$RUNTIME_INPUT" "$PREFIX_DIR/lib/opencode/runtime/opencode"
	RUNTIME_MODE="release-loader"
elif [[ -f "$RUNTIME_FALLBACK_INPUT" ]]; then
	install -m 755 "$RUNTIME_FALLBACK_INPUT" "$PREFIX_DIR/lib/opencode/runtime/opencode"
	RUNTIME_MODE="release-raw"
else
	fail "runtime not found: $RUNTIME_INPUT or $RUNTIME_FALLBACK_INPUT"
fi

install -m 755 "$ROOT_DIR/scripts/launcher.sh" "$PREFIX_DIR/bin/opencode"

write_build_meta "$ROOT_DIR/artifacts/opencode/build.meta" \
	"component=opencode" \
	"prefix=$PREFIX_DIR" \
	"runtime_mode=$RUNTIME_MODE" \
	"runtime_path=$PREFIX_DIR/lib/opencode/runtime/opencode"

log "staged build ready: $PREFIX_DIR"
