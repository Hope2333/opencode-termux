#!/data/data/com.termux/files/usr/bin/bash
# verify-artifact.sh — artifact-level assertions for a built binary or package.
#
# Usage: verify-artifact.sh <file> [--web]
#   <file>  raw ELF, .deb, or .pkg.tar.* (xz/zst/gz auto-detected by tar)
#   --web   also require embedded web UI assets (v2 native builds only)
#
# Checks (fail fast, exit 1 with a named cause):
#   1. file exists and is non-empty
#   2. the runtime binary inside references libopencode-crhandler.so (harden)
#   3. --web: the binary carries the web UI archive (/_assets/)
#   4. if UPX-packed: `upx -t` passes (skipped when upx is absent)
#
# Single harden implementation: scripts/package/lib.sh:is_hardened.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/package/lib.sh
source "$SCRIPT_DIR/package/lib.sh"

FILE=""
WANT_WEB=0
PTY_SHA=""
for a in "$@"; do
  case "$a" in
    --web) WANT_WEB=1 ;;
    --pty-sha=*) PTY_SHA="${a#*=}" ;;
    *) [[ -z "$FILE" ]] && FILE="$a" ;;
  esac
done

[[ -n "$FILE" ]] || { echo "usage: verify-artifact.sh <file> [--web] [--pty-sha=<sha256>]" >&2; exit 2; }
[[ -s "$FILE" ]] || { echo "Error: artifact missing or empty: $FILE" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN=""

# Pick the LARGEST opencode/opencode1 member: v1 packages ship a ~10 KB shell
# launcher with the same basename as the real 160 MB runtime, and `find | head -n1`
# used to pick whichever came first — the launcher has no DT_NEEDED, so every
# hardened v1 package failed the harden gate.
pick_runtime() {
  find "$1" -type f \( -name opencode -o -name opencode1 \) -printf '%s %p\n' 2>/dev/null |
    sort -rn | head -n1 | cut -d' ' -f2-
}

case "$FILE" in
  *.deb)
    dpkg-deb -x "$FILE" "$TMP" 2>/dev/null || { echo "Error: cannot extract deb: $FILE" >&2; exit 1; }
    BIN="$(pick_runtime "$TMP")"
    ;;
  *.pkg.tar.*)
    mkdir -p "$TMP/x" && tar -xf "$FILE" -C "$TMP/x" 2>/dev/null
    BIN="$(pick_runtime "$TMP/x")"
    ;;
  *)
    BIN="$FILE"
    ;;
esac

[[ -n "$BIN" && -s "$BIN" ]] || { echo "Error: no runtime binary found inside $FILE" >&2; exit 1; }

IS_UPX=0
head -c 4 "$BIN" 2>/dev/null | grep -q 'UPX!' && IS_UPX=1

if ! is_hardened "$BIN"; then
  echo "Error: artifact is not seccomp-hardened (no libopencode-crhandler.so reference): $FILE" >&2
  exit 1
fi
echo "  harden: OK ($FILE)"

if [[ "$WANT_WEB" -eq 1 ]]; then
  if [[ "$IS_UPX" -eq 1 ]]; then
    echo "  web-ui: SKIP (UPX-packed; verify the uncompressed native artifact)"
  elif ! strings -a "$BIN" | grep -cE '(_)?assets/index-' >/dev/null; then
    echo "Error: web UI assets missing from artifact (empty app archive, issue #42): $FILE" >&2
    exit 1
  else
    echo "  web-ui: OK ($FILE)"
  fi
fi

if [[ -n "$PTY_SHA" ]]; then
  if [[ "$IS_UPX" -eq 1 ]]; then
    echo "  pty: SKIP (UPX-packed; verify the uncompressed native artifact)"
  elif ! strings -a "$BIN" | grep -c "$PTY_SHA" >/dev/null; then
    echo "Error: pty asset sha256 $PTY_SHA not embedded (stale/mixed pty variant): $FILE" >&2
    exit 1
  else
    echo "  pty: OK ($FILE)"
  fi
fi

if [[ "$IS_UPX" -eq 1 ]]; then
  if command -v upx >/dev/null 2>&1; then
    upx -t "$BIN" >/dev/null 2>&1 || { echo "Error: UPX integrity test failed: $FILE" >&2; exit 1; }
    echo "  upx: OK ($FILE)"
  else
    echo "  upx: SKIP (upx not installed)"
  fi
fi

echo "verify-artifact: PASS ($FILE)"
