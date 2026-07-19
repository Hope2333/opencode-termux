#!/usr/bin/env bash
# tests/bootstrap.sh — ensure a bats runner is available for the unit tests.
#
# Resolution order:
#   1) vendored bats at tests/vendor/bats-core/bin/bats (fetched here on demand)
#   2) system `bats` on PATH
#
# The vendored copy is git-ignored; this script clones a pinned version when it
# is missing so `make test` works from a clean checkout without extra setup.
set -euo pipefail

BATS_VERSION="${BATS_VERSION:-v1.11.0}"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_BATS="$TESTS_DIR/vendor/bats-core"

if [[ -x "$VENDOR_BATS/bin/bats" ]]; then
	printf '%s\n' "$VENDOR_BATS/bin/bats"
	exit 0
fi

if command -v bats >/dev/null 2>&1; then
	command -v bats
	exit 0
fi

if command -v git >/dev/null 2>&1; then
	echo "[bootstrap] fetching bats-core $BATS_VERSION ..." >&2
	rm -rf "$VENDOR_BATS"
	mkdir -p "$(dirname "$VENDOR_BATS")"
	if git clone --depth 1 --branch "$BATS_VERSION" \
		https://github.com/bats-core/bats-core.git "$VENDOR_BATS" >&2 2>&1; then
		printf '%s\n' "$VENDOR_BATS/bin/bats"
		exit 0
	fi
fi

echo "[bootstrap] ERROR: bats not found and could not be fetched." >&2
echo "[bootstrap] Install bats-core (https://github.com/bats-core/bats-core) or set PATH." >&2
exit 1
