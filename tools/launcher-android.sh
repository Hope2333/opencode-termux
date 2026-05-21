#!/data/data/com.termux/files/usr/bin/bash
# tools/launcher-android.sh — Android-native OpenCode launcher
#
# This launcher uses Android Bun as the runtime interpreter to run
# OpenCode's JS bundle directly. No glibc, no statx shim, no userland exec.
#
# Install layout:
#   $PREFIX/bin/opencode              → this script
#   $PREFIX/lib/opencode/runtime/bun  → Android-native Bun binary
#   $PREFIX/lib/opencode/runtime/bundle.js → OpenCode JS bundle
#
# Env:
#   OPENCODE_DISABLE_ANDROID_BUNDLE=1  # fall back to glibc-wrapped binary

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
RUNTIME_DIR="$(cd "$SELF_DIR/../lib/opencode/runtime" 2>/dev/null || echo "$SELF_DIR/../lib/opencode/runtime")"
BUN_BINARY="$RUNTIME_DIR/bun"
BUNDLE_JS="$RUNTIME_DIR/bundle.js"
WRAPPED_BINARY="$RUNTIME_DIR/opencode"

# Determine which runtime to use
if [[ -z "${OPENCODE_DISABLE_ANDROID_BUNDLE:-}" && -x "$BUN_BINARY" && -f "$BUNDLE_JS" ]]; then
    # Android-native path: use Bun + JS bundle
    exec "$BUN_BINARY" run "$BUNDLE_JS" "$@"
elif [[ -x "$WRAPPED_BINARY" ]]; then
    # Fallback: glibc-wrapped binary (backward compatible)
    exec "$WRAPPED_BINARY" "$@"
else
    echo "opencode: no runtime found (tried Android Bun + bundle.js and wrapped binary)" >&2
    exit 1
fi
