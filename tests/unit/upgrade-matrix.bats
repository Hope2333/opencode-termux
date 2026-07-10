#!/usr/bin/env bats
# Unit tests for tools/upgrade-matrix.sh
#
# Exercises the pure helpers (version-range expansion, deb resolution, payload
# validation). The remote ssh/scp matrix flow is guarded behind direct
# execution and is not run here.

load '../lib/helper'

setup() {
	make_tmpdir
	UM="$(script_path tools/upgrade-matrix.sh)"
	export ODIR="$TEST_TMPDIR/debs"
	export PKG_NAME="opencode"
	mkdir -p "$ODIR"
	STUB_BIN="$TEST_TMPDIR/bin"
	mkdir -p "$STUB_BIN"
}

teardown() {
	clean_tmpdir
}

# Source upgrade-matrix.sh with given VERS and run a snippet.
um() {
	local vers="$1"
	shift
	run bash -c "export VERS='$vers'; source '$UM'; $*"
}

@test "expand_versions passes through explicit versions" {
	um "1.2.8 1.2.9 1.2.10" "expand_versions"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "1.2.8" ]
	[ "${lines[1]}" = "1.2.9" ]
	[ "${lines[2]}" = "1.2.10" ]
	[ "${#lines[@]}" -eq 3 ]
}

@test "expand_versions expands a [start-end] range" {
	um "1.1.[1-4]" "expand_versions"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "1.1.1" ]
	[ "${lines[1]}" = "1.1.2" ]
	[ "${lines[2]}" = "1.1.3" ]
	[ "${lines[3]}" = "1.1.4" ]
	[ "${#lines[@]}" -eq 4 ]
}

@test "expand_versions mixes ranges and explicit versions" {
	um "1.0.9 1.1.[1-2] 2.0.0" "expand_versions"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "1.0.9" ]
	[ "${lines[1]}" = "1.1.1" ]
	[ "${lines[2]}" = "1.1.2" ]
	[ "${lines[3]}" = "2.0.0" ]
}

@test "expand_versions handles a single-element range" {
	um "3.4.[5-5]" "expand_versions"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "3.4.5" ]
	[ "${#lines[@]}" -eq 1 ]
}

@test "find_deb locates aarch64 deb in ODIR" {
	touch "$ODIR/opencode_1.2.10_aarch64.deb"
	um "" "find_deb 1.2.10"
	[ "$status" -eq 0 ]
	[ "$output" = "$ODIR/opencode_1.2.10_aarch64.deb" ]
}

@test "find_deb locates arm64 deb as alternative" {
	touch "$ODIR/opencode_1.2.11_arm64.deb"
	um "" "find_deb 1.2.11"
	[ "$status" -eq 0 ]
	[ "$output" = "$ODIR/opencode_1.2.11_arm64.deb" ]
}

@test "find_deb returns non-zero when no artifact matches" {
	um "" "find_deb 9.9.9"
	[ "$status" -ne 0 ]
}

@test "validate_deb_payload accepts payload containing runtime binary" {
	cat >"$STUB_BIN/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
echo "drwxr-xr-x root/root 0 ./usr/lib/opencode/runtime/opencode"
EOF
	chmod +x "$STUB_BIN/dpkg-deb"
	run bash -c "export VERS='1.0.0' PATH='$STUB_BIN:$PATH'; source '$UM'; validate_deb_payload '$ODIR/x.deb'"
	[ "$status" -eq 0 ]
}

@test "validate_deb_payload rejects payload missing runtime binary" {
	cat >"$STUB_BIN/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
echo "drwxr-xr-x root/root 0 ./usr/bin/somethingelse"
EOF
	chmod +x "$STUB_BIN/dpkg-deb"
	run bash -c "export VERS='1.0.0' PATH='$STUB_BIN:$PATH'; source '$UM'; validate_deb_payload '$ODIR/x.deb'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid deb payload"* ]]
}

@test "validate_deb_payload dies when payload is unreadable/empty" {
	cat >"$STUB_BIN/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$STUB_BIN/dpkg-deb"
	run bash -c "export VERS='1.0.0' PATH='$STUB_BIN:$PATH'; source '$UM'; validate_deb_payload '$ODIR/x.deb'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot read deb payload"* ]]
}
