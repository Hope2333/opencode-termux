# tests/lib/helper.bash — shared helpers for the shell unit tests.
#
# Sourced from every *.bats file. Provides REPO_ROOT plus small utilities for
# sourcing the project scripts (which guard their CLI dispatch behind a
# "run only when executed directly" check, so sourcing exposes functions only).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Path to a project script under test.
script_path() {
	printf '%s/%s' "$REPO_ROOT" "$1"
}

# Create an isolated temp dir for a test and cd into it. Call in setup().
make_tmpdir() {
	TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/oct-test.XXXXXX")"
	export TEST_TMPDIR
}

# Remove the per-test temp dir. Call in teardown().
clean_tmpdir() {
	[[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

# Prepend a directory of fake executables to PATH so we can stub external
# commands (git, npm, make, ...) inside a test.
prepend_path() {
	PATH="$1:$PATH"
	export PATH
}
