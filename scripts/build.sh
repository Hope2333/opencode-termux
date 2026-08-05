#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"

OPENCODE_SRC_DIR="${OPENCODE_SRC_DIR:-$ROOT_DIR/sources/opencode/repo}"
OUT_DIR="${OPENCODE_OUT_DIR:-$ROOT_DIR/artifacts/staged}"
PREFIX_DIR="${OPENCODE_PREFIX_DIR:-$OUT_DIR/prefix}"
RUNTIME_INPUT="${OPENCODE_RUNTIME_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/opencode-termux}"

ensure_dir "$PREFIX_DIR/lib/opencode/runtime"
ensure_dir "$PREFIX_DIR/bin"
ensure_dir "$PREFIX_DIR/lib/opencode/tools"
ensure_dir "$PREFIX_DIR/lib/opencode/system-skills"

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

# Install wrapped OpenCode binary (the real OpenCode app)
if [[ -f "$RUNTIME_INPUT" ]]; then
	install -m 755 "$RUNTIME_INPUT" "$PREFIX_DIR/lib/opencode/runtime/opencode"
	log "installed OpenCode app binary"
	RUNTIME_MODE="opencode-wrapped"
else
	fail "no runtime found at $RUNTIME_INPUT"
fi

# Node.js dist (future v2 GA): adjacent chunks live in v2-dist/ — copy them next to the entry.
V2_DIST="$ROOT_DIR/artifacts/opencode/runtime/v2-dist"
if [[ -d "$V2_DIST" ]]; then
	ensure_dir "$PREFIX_DIR/lib/opencode/runtime/v2-dist"
	cp -a "$V2_DIST/." "$PREFIX_DIR/lib/opencode/runtime/v2-dist/"
	log "installed Node.js v2 dist chunks"
fi

# Optional: OpenCode JS bundle (built on CI, run via Android Bun)
BUNDLE_INPUT="${OPENCODE_BUNDLE_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/bundle.js}"
if [[ -f "$BUNDLE_INPUT" ]]; then
	install -m 644 "$BUNDLE_INPUT" "$PREFIX_DIR/lib/opencode/bundle.js"
	log "installed OpenCode JS bundle"
fi

install -m 755 "$ROOT_DIR/scripts/launcher.sh" "$PREFIX_DIR/bin/opencode"
if [[ -f "$ROOT_DIR/tools/plugin-manager.sh" ]]; then
	install -m 755 "$ROOT_DIR/tools/plugin-manager.sh" "$PREFIX_DIR/lib/opencode/tools/plugin-manager.sh"
fi
if [[ -f "$ROOT_DIR/tools/plugin-selfcheck.sh" ]]; then
	install -m 755 "$ROOT_DIR/tools/plugin-selfcheck.sh" "$PREFIX_DIR/lib/opencode/tools/plugin-selfcheck.sh"
fi
if [[ -f "$ROOT_DIR/scripts/hooks/run-system-skills.sh" ]]; then
	install -m 755 "$ROOT_DIR/scripts/hooks/run-system-skills.sh" "$PREFIX_DIR/lib/opencode/tools/run-system-skills.sh"
fi
if [[ -d "$ROOT_DIR/packing/manifests/system-skills" ]]; then
	cp -a "$ROOT_DIR/packing/manifests/system-skills/." "$PREFIX_DIR/lib/opencode/system-skills/"
fi

DOCS_LIST="${DOCS_LIST:-$ROOT_DIR/docs/bundle-list.txt}"
DOCS_OUT="$PREFIX_DIR/share/opencode/docs"
if [[ -f "$DOCS_LIST" ]]; then
	ensure_dir "$DOCS_OUT"
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		[[ "$rel" == \#* ]] && continue
		src="$ROOT_DIR/$rel"
		if [[ -f "$src" ]]; then
			dest="$DOCS_OUT/${rel#docs/}"
			ensure_dir "$(dirname "$dest")"
			cp -a "$src" "$dest"
		else
			log "docs bundle missing: $rel"
		fi
	done <"$DOCS_LIST"
fi

# Record runtime form in build metadata for packaging decisions.
# bun-elf  -> android-only (bun-termux-loader wrapped, glibc).
# node-js -> portable Node.js distribution (future v2 GA).
RUNTIME_FORM="bun-elf"
if [[ -f "$PREFIX_DIR/lib/opencode/runtime/opencode" ]] && ! file "$PREFIX_DIR/lib/opencode/runtime/opencode" | grep -q 'ELF'; then
	RUNTIME_FORM="node-js"
fi
RUNTIME_MODE="android-only"
[[ "$RUNTIME_FORM" == "node-js" ]] && RUNTIME_MODE="node"
write_build_meta "$ROOT_DIR/artifacts/opencode/build.meta" \
	"component=opencode" \
	"prefix=$PREFIX_DIR" \
	"runtime_form=$RUNTIME_FORM" \
	"runtime_mode=$RUNTIME_MODE" \
	"runtime_path=$PREFIX_DIR/lib/opencode/runtime/opencode"

log "staged build ready: $PREFIX_DIR"
