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

FILE="${1:-}"
WANT_WEB=0
[[ "${2:-}" == "--web" ]] && WANT_WEB=1

[[ -n "$FILE" ]] || { echo "usage: verify-artifact.sh <file> [--web]" >&2; exit 2; }
[[ -s "$FILE" ]] || { echo "Error: artifact missing or empty: $FILE" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN=""

case "$FILE" in
  *.deb)
    dpkg-deb -x "$FILE" "$TMP" 2>/dev/null || { echo "Error: cannot extract deb: $FILE" >&2; exit 1; }
    BIN="$(find "$TMP" -type f \( -name opencode -o -name opencode1 \) | head -n1)"
    ;;
  *.pkg.tar.*)
    tar -xOf "$FILE" --wildcards '*/opencode' '*/opencode1' >"$TMP/bin" 2>/dev/null || true
    [[ -s "$TMP/bin" ]] && BIN="$TMP/bin"
    ;;
  *)
    BIN="$FILE"
    ;;
esac

[[ -n "$BIN" && -s "$BIN" ]] || { echo "Error: no runtime binary found inside $FILE" >&2; exit 1; }

if ! is_hardened "$BIN"; then
  echo "Error: artifact is not seccomp-hardened (no libopencode-crhandler.so reference): $FILE" >&2
  exit 1
fi
echo "  harden: OK ($FILE)"

if [[ "$WANT_WEB" -eq 1 ]]; then
  if ! strings -a "$BIN" | grep -q '/_assets/'; then
    echo "Error: web UI assets missing from artifact (empty app archive, issue #42): $FILE" >&2
    exit 1
  fi
  echo "  web-ui: OK ($FILE)"
fi

if head -c 4 "$BIN" 2>/dev/null | grep -q 'UPX!'; then
  if command -v upx >/dev/null 2>&1; then
    upx -t "$BIN" >/dev/null 2>&1 || { echo "Error: UPX integrity test failed: $FILE" >&2; exit 1; }
    echo "  upx: OK ($FILE)"
  else
    echo "  upx: SKIP (upx not installed)"
  fi
fi

echo "verify-artifact: PASS ($FILE)"
