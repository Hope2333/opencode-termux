#!/usr/bin/env bats
# Unit tests for scripts/common.sh

load '../lib/helper'

setup() {
	make_tmpdir
	COMMON="$(script_path scripts/common.sh)"
}

teardown() {
	clean_tmpdir
}

@test "log prints tagged message to stdout" {
	run bash -c "source '$COMMON'; log 'hello world'"
	[ "$status" -eq 0 ]
	[ "$output" = "[opencode-termux] hello world" ]
}

@test "fail prints ERROR message and exits 1" {
	run bash -c "source '$COMMON'; fail 'boom'"
	[ "$status" -eq 1 ]
	[[ "$output" == *"[opencode-termux] ERROR: boom"* ]]
}

@test "fail writes to stderr not stdout" {
	run bash -c "source '$COMMON'; fail 'oops' 2>/dev/null"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "ensure_dir creates a nested directory" {
	target="$TEST_TMPDIR/a/b/c"
	run bash -c "source '$COMMON'; ensure_dir '$target'"
	[ "$status" -eq 0 ]
	[ -d "$target" ]
}

@test "ensure_dir is idempotent on existing directory" {
	target="$TEST_TMPDIR/exists"
	mkdir -p "$target"
	run bash -c "source '$COMMON'; ensure_dir '$target'"
	[ "$status" -eq 0 ]
	[ -d "$target" ]
}

@test "write_build_meta writes timestamp and key=value lines" {
	out="$TEST_TMPDIR/meta/build.meta"
	run bash -c "source '$COMMON'; write_build_meta '$out' 'component=opencode' 'runtime_mode=android-only'"
	[ "$status" -eq 0 ]
	[ -f "$out" ]
	grep -q '^timestamp=' "$out"
	grep -q '^component=opencode$' "$out"
	grep -q '^runtime_mode=android-only$' "$out"
}

@test "write_build_meta creates parent directory" {
	out="$TEST_TMPDIR/deep/nested/build.meta"
	run bash -c "source '$COMMON'; write_build_meta '$out' 'k=v'"
	[ "$status" -eq 0 ]
	[ -d "$TEST_TMPDIR/deep/nested" ]
}

@test "write_build_meta timestamp is UTC ISO-8601" {
	out="$TEST_TMPDIR/meta.txt"
	run bash -c "source '$COMMON'; write_build_meta '$out'"
	[ "$status" -eq 0 ]
	run grep -E '^timestamp=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$out"
	[ "$status" -eq 0 ]
}
