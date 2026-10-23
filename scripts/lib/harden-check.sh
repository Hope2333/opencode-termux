#!/data/data/com.termux/files/usr/bin/bash
# harden-check.sh — CLI wrapper around lib.sh:is_hardened for Makefile recipes.
# Exit 0 when the binary references libopencode-crhandler.so (zero-displacement
# DT_NEEDED patch), 1 otherwise. Single implementation lives in
# scripts/package/lib.sh (docs-reorg-maint E2).
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../package" && pwd)/lib.sh"
# shellcheck source=scripts/package/lib.sh
source "$LIB"

[[ -n "${1:-}" ]] || { echo "usage: harden-check.sh <binary>" >&2; exit 2; }
is_hardened "$1"
