#!/usr/bin/env bats
# Unit tests for tools/make-opencode (CLI flag -> make variable mapping).
#
# `make` is stubbed on PATH to print the exact argument vector it receives, so
# these tests assert the wrapper's translation without running a real build.

load '../lib/helper'

setup() {
	make_tmpdir
	MK="$(script_path tools/make-opencode)"
	STUB_BIN="$TEST_TMPDIR/bin"
	mkdir -p "$STUB_BIN"
	cat >"$STUB_BIN/make" <<'EOF'
#!/usr/bin/env bash
# Print each received argument on its own line for exact assertions.
printf '%s\n' "$@"
EOF
	chmod +x "$STUB_BIN/make"
}

teardown() {
	clean_tmpdir
}

mkoc() {
	run env PATH="$STUB_BIN:$PATH" bash "$MK" "$@"
}

@test "no args maps to the help target" {
	mkoc
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "help" ]
	[ "${#lines[@]}" -eq 1 ]
}

@test "--all --ver --pkg maps to all VER= PKG=" {
	mkoc --all --ver 1.2.10 --pkg both
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "all" ]
	[ "${lines[1]}" = "VER=1.2.10" ]
	[ "${lines[2]}" = "PKG=both" ]
}

@test "--batch --vers preserves version string as one argument" {
	mkoc --batch --vers "1.2.10 1.2.11" --pkg pacman
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "batch" ]
	[ "${lines[1]}" = "VERS=1.2.10 1.2.11" ]
	[ "${lines[2]}" = "PKG=pacman" ]
}

@test "--mix adds MIX=1" {
	mkoc --all --ver 1.2.10 --mix
	[ "$status" -eq 0 ]
	printf '%s\n' "${lines[@]}" | grep -qx "MIX=1"
}

@test "--odir and --packager are forwarded" {
	mkoc --all --odir /tmp/out --packager "Me <me@example.com>"
	[ "$status" -eq 0 ]
	printf '%s\n' "${lines[@]}" | grep -qx "ODIR=/tmp/out"
	printf '%s\n' "${lines[@]}" | grep -qx "PACKAGER_NAME=Me <me@example.com>"
}

@test "unknown passthrough args collapse into MORE= for non-batch targets" {
	mkoc --runtime extra1 extra2
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "runtime" ]
	printf '%s\n' "${lines[@]}" | grep -qx "MORE=extra1 extra2"
}

@test "batch target does not forward passthrough values into MORE" {
	mkoc --batch --vers "1.2.10" leftover
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "batch" ]
	printf '%s\n' "${lines[@]}" | grep -qx "MORE="
	! printf '%s\n' "${lines[@]}" | grep -q "leftover"
}

@test "args after -- are treated as passthrough" {
	mkoc --stage -- --flag-for-runtime
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "stage" ]
	printf '%s\n' "${lines[@]}" | grep -qx "MORE=--flag-for-runtime"
}

@test "--ver without a value errors out" {
	mkoc --all --ver
	[ "$status" -ne 0 ]
}
