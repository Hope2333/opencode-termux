#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
# apply-platform-patch.sh — idempotent @opentui/core platform patch for B-line.
# The v2 graph is compiled on android bun (process.platform="android"), but the
# bun-compiled @opentui/core runtime probes process.platform for its native
# asset selection and refuses "android-arm64". We force platform="linux" so the
# loader picks the linux-arm64 bionic libopentui.so we graft into the store.
STORE_CHUNK="$1"
[ -n "$STORE_CHUNK" ] || { echo "usage: $0 <@opentui+core store chunk path>"; exit 1; }
CHUNK_BASE="$STORE_CHUNK/node_modules/@opentui/core"
# Dynamic discovery: OpenTUI chunk filenames drift between releases (issue #25 —
# 0.5.12 ships chunk-bun-8f4q4e2m.js, older releases 9gqvxy8c). Locate the
# platform loader by content instead of by generated filename.
CHUNK_JS="$(grep -RIl --include='chunk-bun-*.js' 'platform: process.platform' "$CHUNK_BASE" 2>/dev/null | head -1)"
[ -n "$CHUNK_JS" ] && [ -f "$CHUNK_JS" ] || { echo "error: platform loader chunk not found under $CHUNK_BASE"; exit 1; }
echo "platform chunk: $(basename "$CHUNK_JS")"
# 1) platform literal present?
if grep -q 'platform: "linux",' "$CHUNK_JS"; then
  echo "platform patch already applied (platform literal)"; 
else
  sed -i 's/platform: process\.platform,/platform: "linux",/' "$CHUNK_JS"
  echo "platform literal patched"
fi
# 2) linux branch force
if grep -q 'if (true) {' "$CHUNK_JS"; then
  echo "platform patch already applied (branch force)"
else
  sed -i 's/if (process\.platform === "linux") {/if (true) {/' "$CHUNK_JS"
  echo "branch force patched"
fi
