#!/usr/bin/env bats
# Unit tests for tools/plugin-manager.sh
#
# Only the pure / filesystem-local helpers are exercised here; network and
# build paths (git clone, npm/bun, tsc) are out of scope for unit tests.

load '../lib/helper'

setup() {
	make_tmpdir
	PM="$(script_path tools/plugin-manager.sh)"
	# Isolate all config/state under the temp dir.
	export HOME="$TEST_TMPDIR/home"
	export XDG_CONFIG_HOME="$TEST_TMPDIR/cfg"
	export PREFIX="$TEST_TMPDIR/prefix"
	export PLUGIN_GIT_RETRY_MAX=3
	export PLUGIN_GIT_RETRY_DELAY=0
	CFG_DIR="$XDG_CONFIG_HOME/opencode"
	PLUG_DIR="$CFG_DIR/local-plugins"
	SNAP_DIR="$CFG_DIR/plugin-snapshots"
	mkdir -p "$CFG_DIR" "$PLUG_DIR" "$SNAP_DIR"
}

teardown() {
	clean_tmpdir
}

# Run a snippet with plugin-manager.sh sourced and sleep neutralised.
pm() {
	run bash -c "source '$PM'; sleep() { :; }; $*"
}

@test "root_of composes local-plugins path" {
	pm "root_of foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$PLUG_DIR/foo" ]
}

@test "repo_of / pkg_of / entry_of derive from root_of" {
	pm 'repo_of foo; echo; pkg_of foo; echo; entry_of foo'
	[ "$status" -eq 0 ]
	[[ "$output" == *"$PLUG_DIR/foo/repo"* ]]
	[[ "$output" == *"$PLUG_DIR/foo/package"* ]]
	[[ "$output" == *"$PLUG_DIR/foo/index.js"* ]]
}

@test "dist_entry_of points at package/dist/index.js" {
	pm "dist_entry_of foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$PLUG_DIR/foo/package/dist/index.js" ]
}

@test "system_root_of uses PREFIX plugins dir" {
	pm "system_root_of foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$PREFIX/lib/opencode/plugins/foo" ]
}

@test "system_entry_of prefers index.js when present" {
	root="$PREFIX/lib/opencode/plugins/foo"
	mkdir -p "$root"
	: >"$root/index.js"
	pm "system_entry_of foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$root/index.js" ]
}

@test "system_entry_of falls back to dist/index.js" {
	root="$PREFIX/lib/opencode/plugins/foo"
	mkdir -p "$root/dist"
	: >"$root/dist/index.js"
	pm "system_entry_of foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$root/dist/index.js" ]
}

@test "system_entry_of returns non-zero when nothing installed" {
	mkdir -p "$PREFIX/lib/opencode/plugins/foo"
	pm "system_entry_of foo"
	[ "$status" -ne 0 ]
}

@test "ensure_dirs creates config/plugin/snapshot dirs" {
	rm -rf "$CFG_DIR"
	pm "ensure_dirs"
	[ "$status" -eq 0 ]
	[ -d "$PLUG_DIR" ]
	[ -d "$SNAP_DIR" ]
}

@test "git_retry returns 0 when command succeeds first try" {
	pm "git_retry true"
	[ "$status" -eq 0 ]
}

@test "git_retry succeeds after transient failures" {
	counter="$TEST_TMPDIR/count"
	echo 0 >"$counter"
	# Fails twice, succeeds on the third attempt (== GIT_RETRY_MAX).
	pm "flaky() { n=\$(cat '$counter'); n=\$((n+1)); echo \$n >'$counter'; [ \$n -ge 3 ]; }; git_retry flaky"
	[ "$status" -eq 0 ]
	[ "$(cat "$counter")" -eq 3 ]
}

@test "git_retry gives up after GIT_RETRY_MAX failures" {
	counter="$TEST_TMPDIR/count"
	echo 0 >"$counter"
	pm "always_fail() { n=\$(cat '$counter'); echo \$((n+1)) >'$counter'; return 1; }; git_retry always_fail"
	[ "$status" -eq 1 ]
	[ "$(cat "$counter")" -eq 3 ]
}

@test "snapshot_latest returns most recent matching archive" {
	touch "$SNAP_DIR/foo-20240101-000000.tar.gz"
	touch "$SNAP_DIR/foo-20240201-000000.tar.gz"
	touch "$SNAP_DIR/bar-20990101-000000.tar.gz"
	pm "snapshot_latest foo"
	[ "$status" -eq 0 ]
	[ "$output" = "$SNAP_DIR/foo-20240201-000000.tar.gz" ]
}

@test "snapshot_latest is empty when no snapshot exists" {
	pm "snapshot_latest missing"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "cmd_list lists snapshots newest first" {
	touch "$SNAP_DIR/foo-20240101-000000.tar.gz"
	touch "$SNAP_DIR/foo-20240301-000000.tar.gz"
	pm "cmd_list foo"
	[ "$status" -eq 0 ]
	first_line="$(printf '%s\n' "$output" | head -n1)"
	[ "$first_line" = "$SNAP_DIR/foo-20240301-000000.tar.gz" ]
}

@test "ensure_root_entry copies built dist to plugin root entry" {
	pkg="$PLUG_DIR/foo/package/dist"
	mkdir -p "$pkg"
	echo "module.exports={}" >"$pkg/index.js"
	pm "ensure_root_entry foo"
	[ "$status" -eq 0 ]
	[ -f "$PLUG_DIR/foo/index.js" ]
	grep -q "module.exports" "$PLUG_DIR/foo/index.js"
}

@test "ensure_root_entry fails when built dist entry missing" {
	mkdir -p "$PLUG_DIR/foo"
	pm "ensure_root_entry foo"
	[ "$status" -ne 0 ]
}

@test "ensure_file_plugin_config creates config with file:// entry" {
	pm "ensure_file_plugin_config foo"
	[ "$status" -eq 0 ]
	cfg="$CFG_DIR/opencode.json"
	[ -f "$cfg" ]
	run python3 -c "import json;d=json.load(open('$cfg'));print(any(x.startswith('file://') and x.endswith('/foo/index.js') for x in d['plugin']))"
	[ "$output" = "True" ]
}

@test "ensure_file_plugin_config removes bare-name plugin entry" {
	cfg="$CFG_DIR/opencode.json"
	printf '%s\n' '{"plugin":["foo","other-plugin"]}' >"$cfg"
	pm "ensure_file_plugin_config foo"
	[ "$status" -eq 0 ]
	run python3 -c "import json;d=json.load(open('$cfg'));p=d['plugin'];print('foo' not in p and 'other-plugin' in p and any(x.endswith('/foo/index.js') for x in p))"
	[ "$output" = "True" ]
}

@test "ensure_file_plugin_config is idempotent (no duplicate entries)" {
	pm "ensure_file_plugin_config foo"
	pm "ensure_file_plugin_config foo"
	[ "$status" -eq 0 ]
	cfg="$CFG_DIR/opencode.json"
	run python3 -c "import json;d=json.load(open('$cfg'));e=[x for x in d['plugin'] if x.endswith('/foo/index.js')];print(len(e))"
	[ "$output" = "1" ]
}

@test "update_state records action/status in state json" {
	pm "update_state install foo ok installed https://example.com/repo.git"
	[ "$status" -eq 0 ]
	state="$CFG_DIR/plugin-manager-state.json"
	[ -f "$state" ]
	run python3 -c "import json;d=json.load(open('$state'));i=d['items']['foo'];print(i['last_action'],i['last_status'],i['last_detail'])"
	[ "$output" = "install ok installed" ]
}

@test "usage lists the documented subcommands" {
	pm "usage"
	[ "$status" -eq 0 ]
	[[ "$output" == *"install [name] [repo-url]"* ]]
	[[ "$output" == *"rollback [name] [snapshot-file]"* ]]
}
