#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"

OPENCODE_SRC_DIR="${OPENCODE_SRC_DIR:-$ROOT_DIR/sources/opencode/repo}"
OUT_DIR="${OPENCODE_OUT_DIR:-$ROOT_DIR/artifacts/staged}"

# STANDALONE=1 stages the opencode-glibc-standalone layout (lib/opencode-glibc/
# + bin/opencode-glibc launcher) into a separate prefix so the standalone
# packages never mix with the glibc mainline tree (both deb packagers copy the
# whole staged prefix into the package).
STANDALONE="${STANDALONE:-0}"
if [[ "$STANDALONE" == "1" ]]; then
	PREFIX_DIR="${OPENCODE_PREFIX_DIR:-$OUT_DIR/prefix-standalone}"
	LIB_DIR="$PREFIX_DIR/lib/opencode-glibc"
else
	PREFIX_DIR="${OPENCODE_PREFIX_DIR:-$OUT_DIR/prefix}"
	LIB_DIR="$PREFIX_DIR/lib/opencode"
fi
RUNTIME_INPUT="${OPENCODE_RUNTIME_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/opencode-termux}"

ensure_dir "$LIB_DIR/runtime"
ensure_dir "$PREFIX_DIR/bin"
ensure_dir "$LIB_DIR/tools"
ensure_dir "$LIB_DIR/system-skills"

if [[ -d "$OPENCODE_SRC_DIR" ]]; then
	log "copying source from $OPENCODE_SRC_DIR"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete --exclude '.git' --exclude 'node_modules' "$OPENCODE_SRC_DIR/" "$LIB_DIR/"
	else
		rm -rf "$LIB_DIR"
		ensure_dir "$LIB_DIR"
		cp -a "$OPENCODE_SRC_DIR/." "$LIB_DIR/"
		rm -rf "$LIB_DIR/.git" "$LIB_DIR/node_modules"
	fi
else
	log "source tree not found; continuing runtime-only staging"
fi

# Install wrapped OpenCode binary (the real OpenCode app)
if [[ -f "$RUNTIME_INPUT" ]]; then
	install -m 755 "$RUNTIME_INPUT" "$LIB_DIR/runtime/opencode"
	log "installed OpenCode app binary"
	RUNTIME_MODE="opencode-wrapped"
else
	fail "no runtime found at $RUNTIME_INPUT"
fi

# Optional: OpenCode JS bundle (built on CI, run via Android Bun)
BUNDLE_INPUT="${OPENCODE_BUNDLE_INPUT:-$ROOT_DIR/artifacts/opencode/runtime/bundle.js}"
if [[ -f "$BUNDLE_INPUT" ]]; then
	install -m 644 "$BUNDLE_INPUT" "$LIB_DIR/bundle.js"
	log "installed OpenCode JS bundle"
fi

if [[ "$STANDALONE" == "1" ]]; then
	# Standalone entry is the bash launcher (repo bin/opencode-glibc); it
	# resolves the runtime via ../lib/opencode-glibc/runtime/opencode.
	[[ -f "$ROOT_DIR/bin/opencode-glibc" ]] || fail "missing launcher: bin/opencode-glibc"
	install -m 755 "$ROOT_DIR/bin/opencode-glibc" "$PREFIX_DIR/bin/opencode-glibc"
else
	# bin-direct: packaged bin/opencode IS the wrapped runtime ELF itself
	ln -f "$LIB_DIR/runtime/opencode" "$PREFIX_DIR/bin/opencode" 2>/dev/null || \
		install -m 755 "$LIB_DIR/runtime/opencode" "$PREFIX_DIR/bin/opencode"
fi
if [[ -f "$ROOT_DIR/tools/plugin-manager.sh" ]]; then
	install -m 755 "$ROOT_DIR/tools/plugin-manager.sh" "$LIB_DIR/tools/plugin-manager.sh"
fi
if [[ -f "$ROOT_DIR/tools/plugin-selfcheck.sh" ]]; then
	install -m 755 "$ROOT_DIR/tools/plugin-selfcheck.sh" "$LIB_DIR/tools/plugin-selfcheck.sh"
fi
if [[ -f "$ROOT_DIR/scripts/hooks/run-system-skills.sh" ]]; then
	install -m 755 "$ROOT_DIR/scripts/hooks/run-system-skills.sh" "$LIB_DIR/tools/run-system-skills.sh"
fi
if [[ -d "$ROOT_DIR/packing/manifests/system-skills" ]]; then
	cp -a "$ROOT_DIR/packing/manifests/system-skills/." "$LIB_DIR/system-skills/"
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

# Compile statx-seccomp shim for Android/Termux compatibility
write_build_meta "$ROOT_DIR/artifacts/opencode/build.meta" \
	"component=opencode" \
	"prefix=$PREFIX_DIR" \
	"runtime_mode=android-only" \
	"runtime_path=$LIB_DIR/runtime/opencode"

log "staged build ready: $PREFIX_DIR"
