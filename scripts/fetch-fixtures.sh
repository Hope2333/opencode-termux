#!/usr/bin/env bash
# fetch-fixtures.sh — download transplant golden fixture tgz into
# tests/transplant/fixtures/tgz/ (tgz bodies are NOT committed to git;
# only expected.sha256 baselines + this script are).
#
# The golden regression test (tests/transplant/test_golden.py) never touches
# the network: run this once before `make transplant-check` on a fresh clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/transplant/fixtures/tgz"
VERSIONS="1.2.9 1.3.11 1.3.13"

mkdir -p "$FIXTURES"

for ver in $VERSIONS; do
  tgz="$FIXTURES/opencode-linux-arm64-$ver.tgz"
  if [ -f "$tgz" ]; then
    echo "cached: $tgz"
  else
    echo "downloading opencode-linux-arm64@$ver ..."
    npm pack "opencode-linux-arm64@$ver" --pack-destination "$FIXTURES" >/dev/null
  fi
done

echo
echo "fixtures ready in $FIXTURES:"
ls -la "$FIXTURES"