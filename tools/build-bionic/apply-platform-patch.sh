#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
# apply-platform-patch.sh: idempotent @opentui/core platform + Android tagged-pointer patch for B-line.
# The v2 graph is compiled on android bun (process.platform="android"), but the
# bun-compiled @opentui/core runtime probes process.platform for its native
# asset selection and refuses "android-arm64". We force platform="linux" so the
# loader picks the linux-arm64 bionic libopentui.so we graft into the store.
#
# In OpenTUI 0.6.x (OpenCode >= 2.1.4), toSafeNumberPointer() rejects 64-bit
# pointers above Number.MAX_SAFE_INTEGER. On Android 11+ ARM64, Bionic/Scudo
# sets a 0xb4 top-byte tag (ARM TBI) on heap allocations, causing every native
# pointer to exceed 2^53 - 1 and throw "Pointer exceeds safe integer range"
# (issues #43, #46). Bun 1.4.0 FFI natively accepts BigInt pointers and preserves
# the top-byte tag required by Bionic free(), so we return tagged BigInt pointers
# unchanged instead of throwing POINTER_UNSAFE or truncating via Number(pointer).
STORE_CHUNK="${1:-}"
[ -n "$STORE_CHUNK" ] || { echo "usage: $0 <@opentui+core store chunk path>"; exit 1; }
CHUNK_BASE="$STORE_CHUNK/node_modules/@opentui/core"
# Dynamic discovery: OpenTUI chunk filenames drift between releases (issue #25:
# 0.5.12 ships chunk-bun-8f4q4e2m.js, 0.6.8 ships chunk-bun-ehr9v0n8.js). Locate
# the platform loader by content (matching both unpatched and patched forms for
# idempotency) instead of by generated filename.
CHUNK_JS="$(grep -RIlE --include='chunk-bun-*.js' 'platform: (process\.platform|"linux")' "$CHUNK_BASE" 2>/dev/null | head -1 || true)"
[ -n "$CHUNK_JS" ] && [ -f "$CHUNK_JS" ] || { echo "error: platform loader chunk not found under $CHUNK_BASE"; exit 1; }
echo "platform chunk: $(basename "$CHUNK_JS")"
# 1) platform literal present?
if grep -q 'platform: "linux",' "$CHUNK_JS"; then
  echo "platform patch already applied (platform literal)"
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
# 3) Android 11+ ARM64 TBI tagged-pointer passthrough (OpenTUI >= 0.6.x, issues #43, #46)
FFI_CHUNK_JS="$(grep -RIl --include='chunk-bun-*.js' 'function toSafeNumberPointer(' "$CHUNK_BASE" 2>/dev/null | head -1 || true)"
if [ -n "$FFI_CHUNK_JS" ] && [ -f "$FFI_CHUNK_JS" ]; then
  python3 - "$FFI_CHUNK_JS" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

old_fn = """function toSafeNumberPointer(pointer) {
  if (pointer < 0n) {
    throw new Error(POINTER_NEGATIVE);
  }
  if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(POINTER_UNSAFE);
  }
  return Number(pointer);
}"""

new_fn = """function toSafeNumberPointer(pointer) {
  if (pointer < 0n) {
    throw new Error(POINTER_NEGATIVE);
  }
  if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {
    return pointer;
  }
  return Number(pointer);
}"""

old_bun2 = """function toBunPointer2(pointer) {
  return typeof pointer === "bigint" ? Number(pointer) : pointer;
}"""

new_bun2 = """function toBunPointer2(pointer) {
  return pointer;
}"""

modified = False

if new_fn in src:
    print("tagged-pointer patch already applied (toSafeNumberPointer)")
elif old_fn in src:
    src = src.replace(old_fn, new_fn, 1)
    modified = True
    print("tagged-pointer passthrough patched (toSafeNumberPointer)")
else:
    print("error: toSafeNumberPointer body drifted in " + path, file=sys.stderr)
    sys.exit(1)

if new_bun2 in src:
    print("tagged-pointer patch already applied (toBunPointer2)")
elif old_bun2 in src:
    src = src.replace(old_bun2, new_bun2, 1)
    modified = True
    print("tagged-pointer passthrough patched (toBunPointer2)")

if modified:
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
PYEOF
fi
