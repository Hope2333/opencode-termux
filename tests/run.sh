#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$TESTS_DIR/local-runner.mjs" "$@"
