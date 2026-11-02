#!/usr/bin/env bats
# Unit tests for scripts/lib/npm-fetch.sh and the bun.lock android-binding scan
# in scripts/lib/napi-android.sh. No network: the tarball fetch is stubbed by
# overriding npm_tarball after sourcing, so the layout logic is what gets
# exercised.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export REPO_ROOT
	NPM_LIB="$REPO_ROOT/scripts/lib/npm-fetch.sh"
	NAPI_LIB="$REPO_ROOT/scripts/lib/napi-android.sh"
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/npmfetch.XXXXXX")"
	export TMP
}

teardown() {
	[[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
	return 0
}

# Build a throwaway tarball shaped like an npm package tarball.
make_pkg_tarball() {
	local name="$1" ver="$2" dest="$3"
	local stage="$TMP/stage-$ver"
	mkdir -p "$stage/package"
	printf '{"name":"%s","version":"%s"}\n' "$name" "$ver" >"$stage/package/package.json"
	printf 'native\n' >"$stage/package/binding.android-arm64.node"
	tar czf "$dest" -C "$stage" package
}

@test "install_pkg_direct unpacks into node_modules and the bun store key" {
	local tgz="$TMP/lightningcss-android-arm64-1.32.0.tgz"
	make_pkg_tarball "lightningcss-android-arm64" "1.32.0" "$tgz"
	mkdir -p "$TMP/nm"

	run env FAKE_TGZ="$tgz" bash -c '
		source "$1"
		npm_tarball() { printf "%s\n" "$FAKE_TGZ"; }   # pretend the tarball is cached
		install_pkg_direct "lightningcss-android-arm64@1.32.0" "$2" "$3"
	' _ "$NPM_LIB" "$TMP/nm" "$TMP/cache"

	[ "$status" -eq 0 ]
	[ -f "$TMP/nm/lightningcss-android-arm64/package.json" ]
	[ -f "$TMP/nm/.bun/lightningcss-android-arm64@1.32.0/node_modules/lightningcss-android-arm64/package.json" ]
}

@test "install_pkg_direct handles scoped names without a version suffix" {
	local tgz="$TMP/scoped.tgz"
	make_pkg_tarball "@tailwindcss/oxide-android-arm64" "4.3.3" "$tgz"
	mkdir -p "$TMP/nm"

	run env FAKE_TGZ="$tgz" bash -c '
		source "$1"
		npm_tarball() { printf "%s\n" "$FAKE_TGZ"; }
		npm_registry_version() { echo "4.3.3"; }
		install_pkg_direct "@tailwindcss/oxide-android-arm64" "$2" "$3"
	' _ "$NPM_LIB" "$TMP/nm" "$TMP/cache"

	[ "$status" -eq 0 ]
	[ -f "$TMP/nm/@tailwindcss/oxide-android-arm64/package.json" ]
	# scoped store key: '@scope/name' -> '@scope+name'
	[ -f "$TMP/nm/.bun/@tailwindcss+oxide-android-arm64@4.3.3/node_modules/@tailwindcss/oxide-android-arm64/package.json" ]
}

@test "install_pkg_direct fails (caller falls back to bun) when the fetch fails" {
	mkdir -p "$TMP/nm"
	run bash -c '
		source "$1"
		npm_tarball() { return 1; }
		install_pkg_direct "missing-pkg@1.0.0" "$2" "$3"
	' _ "$NPM_LIB" "$TMP/nm" "$TMP/cache"
	[ "$status" -ne 0 ]
	[ ! -d "$TMP/nm/missing-pkg" ]
}

@test "install_pkg_direct is idempotent (second call keeps the first tree)" {
	local tgz="$TMP/idem.tgz"
	make_pkg_tarball "idem" "1.0.0" "$tgz"
	mkdir -p "$TMP/nm"
	for _ in 1 2; do
		run env FAKE_TGZ="$tgz" bash -c '
			source "$1"
			npm_tarball() { printf "%s\n" "$FAKE_TGZ"; }
			install_pkg_direct "idem@1.0.0" "$2" "$3"
		' _ "$NPM_LIB" "$TMP/nm" "$TMP/cache"
		[ "$status" -eq 0 ]
	done
	[ -f "$TMP/nm/idem/binding.android-arm64.node" ]
}

@test "napi_android_entries lists only android/arm64 optional deps, deduped" {
	local lock="$TMP/bun.lock"
	cat >"$lock" <<'LOCK'
{
  "packages": {
    "@rolldown/binding-android-arm64": ["@rolldown/binding-android-arm64@1.2.5", "", { "os": "android", "cpu": "arm64" }, "sha512-x"],
    "@rolldown/binding-linux-arm64-gnu": ["@rolldown/binding-linux-arm64-gnu@1.2.5", "", { "os": "linux", "cpu": "arm64" }, "sha512-y"],
    "lightningcss-android-arm64": ["lightningcss-android-arm64@1.32.0", "", { "os": "android", "cpu": "arm64" }, "sha512-z"],
    "lightningcss-android-arm64/dup": ["lightningcss-android-arm64@1.32.0", "", { "os": "android", "cpu": "arm64" }, "sha512-z2"]
  }
}
LOCK
	run bash -c 'source "$1"; napi_android_entries "$2"' _ "$NAPI_LIB" "$lock"
	[ "$status" -eq 0 ]
	[[ "$output" == *"@rolldown/binding-android-arm64	1.2.5"* ]]
	[[ "$output" == *"lightningcss-android-arm64	1.32.0"* ]]
	[[ "$output" != *"binding-linux-arm64-gnu"* ]]
	[ "$(printf '%s\n' "$output" | grep -c 'lightningcss-android-arm64')" -eq 1 ]
}
