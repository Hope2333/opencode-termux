#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# pty-embed-store-patch.sh — A2 T16: swap the glibc librust_pty prebuilt in
# the v1 bun-pty store chunk for the bionic-native build, so bun --compile
# embeds a bionic-loadable pty and the runtime needs no external
# pty/librust_pty_arm64_musl_patched.so + shim.so (nor BUN_PTY_LIB env).
#
# bun-pty's terminal.ts resolves the lib via a statically analyzable
# `require(`../rust-pty/target/release/${ternary}`)`; for both the
# bun-linux-arm64 compile target and the android runtime the name is
# librust_pty_arm64.so. Replacing that file in the store is therefore the
# whole patch — no JS edits, no bun source edits.
#
# Idempotent: skips when the store already carries the bionic build.
# Run BEFORE build-v1.sh (build-v1 reuses a warm store).

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR_SO="$ROOT_DIR/tools/bun-pty-embed/vendor/librust_pty_arm64_bionic.so"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-1.18.32}"
VENDOR_SHA="58aeeb4647cdcdb7e4d9f855ebaa75339ab934039d7ddd977a0be5a3b5cf1c2d"

[[ -f "$VENDOR_SO" ]] || { echo "ERR: vendor .so missing — run tools/bun-pty-embed/build-embed.sh first" >&2; exit 1; }
echo "$VENDOR_SHA  $VENDOR_SO" | sha256sum -c - >/dev/null || { echo "ERR: vendor sha256 drift" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "ERR: readelf missing" >&2; exit 1; }

CHUNKS="$(ls -d "$V1_SRC"/node_modules/.bun/bun-pty@*/node_modules/bun-pty 2>/dev/null || true)"
[[ -n "$CHUNKS" ]] || { echo "ERR: no bun-pty store chunk under $V1_SRC/node_modules/.bun" >&2; exit 1; }

for D in $CHUNKS; do
  TGT="$D/rust-pty/target/release/librust_pty_arm64.so"
  if [[ -f "$TGT" ]] && sha256sum "$TGT" | awk '{print $1}' | grep -q "$VENDOR_SHA"; then
    echo "OK (already patched): ${TGT#$V1_SRC/}"
    continue
  fi
  [[ -f "$TGT" ]] && echo "    replacing: ${TGT#$V1_SRC/} ($(stat -c%s "$TGT") B)"
  mkdir -p "$(dirname "$TGT")"
  install -m755 "$VENDOR_SO" "$TGT"
  # gates: bionic-only NEEDED + the 8 exported bun_pty_ symbols
  readelf -d "$TGT" | grep NEEDED | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]' && {
    echo "ERR: glibc-linked NEEDED after patch" >&2; exit 1; }
  SYMS="$(nm -D --defined-only "$TGT" | grep -c ' T bun_pty_' || true)"
  [[ "$SYMS" -eq 8 ]] || { echo "ERR: bun_pty_* exports=$SYMS (expect 8)" >&2; exit 1; }
  echo "OK: ${TGT#$V1_SRC/} -> bionic build ($(stat -c%s "$TGT") B, exports=$SYMS)"
done
echo "==> pty-embed store patch done (bun --compile will embed the bionic lib)"
