#!/usr/bin/env bash
# tests/run.sh — run the shell unit test suite with bats.
#
# Usage:
#   tests/run.sh                 # run every *.bats file under tests/unit
#   tests/run.sh tests/unit/common.bats   # run specific file(s)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_BIN="$("$TESTS_DIR/bootstrap.sh")"

if [[ $# -gt 0 ]]; then
	exec "$BATS_BIN" "$@"
fi

exec "$BATS_BIN" --recursive "$TESTS_DIR/unit"
