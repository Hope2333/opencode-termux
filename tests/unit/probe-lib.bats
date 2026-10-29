#!/usr/bin/env bats
# Unit tests for scripts/lib/probe-lib.sh — the verdict rules behind
# tools/probe-version.sh. No device, no network: the device output is faked as
# `key=value` text exactly like tools/probe/device-probe.sh prints it.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export REPO_ROOT
	LIB="$REPO_ROOT/scripts/lib/probe-lib.sh"
}

lib() { run bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

@test "probe_ver_key sorts 2.0.32 below 2.1.0" {
	lib probe_ver_key 2.0.32
	[ "$output" = "002000032" ]
	lib probe_ver_key 2.1.0
	[ "$output" = "002001000" ]
}

@test "probe_ver_lt compares across minor bumps" {
	run bash -c 'source "$1"; probe_ver_lt 2.0.32 2.1.0 && echo LT' _ "$LIB"
	[ "$output" = "LT" ]
	run bash -c 'source "$1"; probe_ver_lt 2.1.4 2.0.32 || echo NOT-LT' _ "$LIB"
	[ "$output" = "NOT-LT" ]
}

@test "probe_expand_range expands inside one minor" {
	lib probe_expand_range 2.0.30..2.0.32
	[ "$status" -eq 0 ]
	[ "$output" = "2.0.30
2.0.31
2.0.32" ]
}

@test "probe_expand_range refuses to cross a minor (upstream skips patches)" {
	run bash -c 'source "$1"; probe_expand_range 2.0.32..2.2.2' _ "$LIB"
	[ "$status" -ne 0 ]
	[[ "$output" == *"crosses a minor version"* ]]
}

@test "probe_expand_range accepts an explicit list" {
	lib probe_expand_range "2.0.32,2.1.0,2.2.0"
	[ "$output" = "2.0.32
2.1.0
2.2.0" ]
}

@test "probe_pkg_path maps kind to package name and skips absent files" {
	mkdir -p "$BATS_TEST_TMPDIR/debs"
	touch "$BATS_TEST_TMPDIR/debs/opencode_2.0.32_aarch64.deb"
	touch "$BATS_TEST_TMPDIR/debs/opencode1_1.19.4_aarch64.deb"

	lib probe_pkg_path "$BATS_TEST_TMPDIR/debs" v2 2.0.32
	[ "$output" = "$BATS_TEST_TMPDIR/debs/opencode_2.0.32_aarch64.deb" ]
	lib probe_pkg_path "$BATS_TEST_TMPDIR/debs" v1 1.19.4
	[ "$output" = "$BATS_TEST_TMPDIR/debs/opencode1_1.19.4_aarch64.deb" ]
	lib probe_pkg_path "$BATS_TEST_TMPDIR/debs" v2 9.9.9
	[ -z "$output" ]
}

GOOD='install=ok
version=opencode v2.1.0
expected=opencode v2.1.0
serve=200
tui_bytes=1342
typed_diff=2
echoed=1
alive15=YES
crash=0
degrade=0'

verdict() { run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$1"; }

@test "probe_verdict passes a healthy probe" {
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$GOOD"
	[ "$output" = "PASS" ]
}

@test "probe_verdict rejects a failed install" {
	bad="${GOOD/install=ok/install=fail}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*install* ]]
}

@test "probe_verdict rejects a version mismatch" {
	bad="${GOOD/version=opencode v2.1.0/version=opencode v2.0.31}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == *"v2.0.31"* ]]
}

@test "probe_verdict rejects a non-200 serve" {
	bad="${GOOD/serve=200/serve=404}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*serve* ]]
}

@test "probe_verdict treats a CLI fallback frame as TUI failure" {
	# 307 B is what the removed legacy-kernel fallback printed; a real frame is
	# 1200+ B, so the threshold has to sit above the fallback text.
	bad="${GOOD/tui_bytes=1342/tui_bytes=307}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*tui* ]]
}

@test "probe_verdict rejects lost keystrokes" {
	bad="${GOOD/echoed=1/echoed=0}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*input* ]]
}

@test "probe_verdict rejects a process that died before 15s" {
	bad="${GOOD/alive15=YES/alive15=NO}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*alive* ]]
}

@test "probe_verdict rejects crash markers and degradation banners" {
	bad="${GOOD/crash=0/crash=2}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*crash* ]]

	bad="${GOOD/degrade=0/degrade=1}"
	run bash -c 'source "$1"; printf "%s\n" "$2" | probe_verdict' _ "$LIB" "$bad"
	[[ "$output" == FAIL:*degradation* ]]
}
