#!/data/data/com.termux/files/usr/bin/bash
# verify-release-dir.sh — pre-upload gate for the staged release directory.
#
# Usage: verify-release-dir.sh <release-dir> [version] [pty-variant] [pty-sha]
#   Every *.deb / *.pkg.tar.* in the dir goes through verify-artifact:
#   hardened always; --web for v2 (2.*) artifacts; --pty-sha when provided
#   (UPX-packed members are SKIPped for hash-level checks).
#
# Exit 0 only when at least one artifact was checked and all passed.
set -uo pipefail

DIR="${1:-}"
VER="${2:-}"
PTY_VARIANT="${3:-}"
PTY_SHA="${4:-}"

[[ -n "$DIR" ]] || { echo "usage: verify-release-dir.sh <dir> [ver] [pty-variant] [pty-sha]" >&2; exit 2; }
[[ -d "$DIR" ]] || { echo "Error: release dir not found: $DIR" >&2; exit 2; }

[[ -n "$PTY_SHA" ]] || { echo "  pty: SKIP (no pty-sha256.txt for VER=$VER)"; }

n=0
for f in "$DIR"/*.deb "$DIR"/*.pkg.tar.*; do
  [[ -f "$f" ]] || continue
  args=()
  case "$(basename "$f")" in
    opencode1*|opencode1-*) ;;
    *) [[ "$VER" == 2.* ]] && args+=(--web) ;;
  esac
  if [[ -n "$PTY_SHA" ]]; then
    case "$(basename "$f")" in
      *compressed*) : ;;   # UPX-packed: verify-artifact SKIPs hash checks itself
      *) args+=("--pty-sha=$PTY_SHA") ;;
    esac
  fi
  bash "$(dirname "$0")/verify-artifact.sh" "$f" "${args[@]}" || exit 1
  n=$((n + 1))
done

[[ $n -gt 0 ]] || { echo "Error: no .deb / .pkg.tar.* artifacts in $DIR" >&2; exit 1; }
echo "verify-release-dir: $n artifact(s) OK ($DIR${PTY_VARIANT:+, pty=$PTY_VARIANT})"
