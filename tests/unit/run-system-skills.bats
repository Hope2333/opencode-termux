#!/usr/bin/env bats
# Unit tests for scripts/hooks/run-system-skills.sh
#
# Covers version comparison, core-version parsing, registry writes, and the
# global blocklist gate. Manifest processing that drives the plugin-manager is
# out of scope (needs a live plugin-manager); the compatibility helpers it
# relies on are tested directly.

load '../lib/helper'

setup() {
	make_tmpdir
	HOOK="$(script_path scripts/hooks/run-system-skills.sh)"
	export PREFIX="$TEST_TMPDIR/prefix"
	export XDG_CONFIG_HOME="$TEST_TMPDIR/cfg"
	export OPENCODE_HOOK_LOG="$TEST_TMPDIR/hooks.log"
	export OPENCODE_HOOK_STATE_DIR="$TEST_TMPDIR/state"
	export OPENCODE_HOOK_REGISTRY="$TEST_TMPDIR/registry.json"
	mkdir -p "$PREFIX" "$XDG_CONFIG_HOME"
	STUB_BIN="$TEST_TMPDIR/bin"
	mkdir -p "$STUB_BIN"
}

teardown() {
	clean_tmpdir
}

hook() {
	run bash -c "source '$HOOK'; $*"
}

@test "version_ge: equal versions compare as >=" {
	hook "version_ge 1.2.3 1.2.3"
	[ "$status" -eq 0 ]
}

@test "version_ge: higher patch is >=" {
	hook "version_ge 1.2.4 1.2.3"
	[ "$status" -eq 0 ]
}

@test "version_ge: lower version is not >=" {
	hook "version_ge 1.2.2 1.2.3"
	[ "$status" -eq 1 ]
}

@test "version_ge: minor/major precedence" {
	hook "version_ge 2.0.0 1.99.99"
	[ "$status" -eq 0 ]
	hook "version_ge 1.10.0 1.9.0"
	[ "$status" -eq 0 ]
}

@test "version_le: equal versions compare as <=" {
	hook "version_le 1.2.3 1.2.3"
	[ "$status" -eq 0 ]
}

@test "version_le: lower version is <=" {
	hook "version_le 1.2.2 1.2.3"
	[ "$status" -eq 0 ]
}

@test "version_le: higher version is not <=" {
	hook "version_le 1.3.0 1.2.9"
	[ "$status" -eq 1 ]
}

@test "core_version parses semver from opencode --version" {
	cat >"$STUB_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode 1.17.3"
EOF
	chmod +x "$STUB_BIN/opencode"
	run bash -c "export PATH=\"$STUB_BIN:\$PATH\"; source '$HOOK'; core_version"
	[ "$status" -eq 0 ]
	[ "$output" = "1.17.3" ]
}

@test "core_version defaults to 0.0.0 when unavailable" {
	# No opencode on PATH and no staged runtime binary under PREFIX.
	hook "core_version"
	[ "$status" -eq 0 ]
	[ "$output" = "0.0.0" ]
}

@test "run_or_warn returns 0 on success and logs ok" {
	hook "run_or_warn 'step' true"
	[ "$status" -eq 0 ]
	grep -q "step: ok" "$OPENCODE_HOOK_LOG"
}

@test "run_or_warn swallows failure in non-strict mode" {
	export OPENCODE_HOOK_STRICT=0
	hook "run_or_warn 'step' false"
	[ "$status" -eq 0 ]
	grep -q "step: failed" "$OPENCODE_HOOK_LOG"
}

@test "run_or_warn propagates failure in strict mode" {
	export OPENCODE_HOOK_STRICT=1
	hook "run_or_warn 'step' false"
	[ "$status" -eq 1 ]
}

@test "update_registry records plugin status entry" {
	hook "update_registry my-plugin post_install ok processed /tmp/m.json 1.17.3 warn idk-1 false true"
	[ "$status" -eq 0 ]
	[ -f "$OPENCODE_HOOK_REGISTRY" ]
	run python3 -c "import json;d=json.load(open('$OPENCODE_HOOK_REGISTRY'));i=d['items']['my-plugin'];print(i['last_event'],i['last_status'],i['core_version'],i['auto_update'])"
	[ "$output" = "post_install ok 1.17.3 True" ]
}

@test "blocked_by_global_blocklist returns 1 when no blocklist file" {
	export OPENCODE_HOOK_BLOCKLIST="$TEST_TMPDIR/missing-blocklist.json"
	hook "blocked_by_global_blocklist my-plugin 1.17.3"
	[ "$status" -eq 1 ]
}

@test "blocked_by_global_blocklist matches plugin_id + core version" {
	bl="$TEST_TMPDIR/blocklist.json"
	cat >"$bl" <<'EOF'
{"blocked":[{"plugin_id":"my-plugin","core_versions":["1.17.3"],"reason":"known crash"}]}
EOF
	export OPENCODE_HOOK_BLOCKLIST="$bl"
	hook "blocked_by_global_blocklist my-plugin 1.17.3"
	[ "$status" -eq 0 ]
	[[ "$output" == *"known crash"* ]]
}

@test "blocked_by_global_blocklist ignores non-matching core version" {
	bl="$TEST_TMPDIR/blocklist.json"
	cat >"$bl" <<'EOF'
{"blocked":[{"plugin_id":"my-plugin","core_versions":["1.0.0"],"reason":"old"}]}
EOF
	export OPENCODE_HOOK_BLOCKLIST="$bl"
	hook "blocked_by_global_blocklist my-plugin 1.17.3"
	[ "$status" -eq 1 ]
}
