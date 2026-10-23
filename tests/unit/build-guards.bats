#!/usr/bin/env bats
# Unit tests for the guards introduced by docs-reorg-maint E1/E2.
# No network, no full build: everything runs against fixtures in $BATS_TEST_TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

@test "resolve_dep_pins: known versions map to upstream pins" {
  run bash -c 'source "$1/scripts/lib/build-pins.sh"; resolve_dep_pins 2.0.32' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "PTY_VER=0.2.0 OPENTUI_VER=0.5.17" ]

  run bash -c 'source "$1/scripts/lib/build-pins.sh"; resolve_dep_pins 2.1.4' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "PTY_VER=0.3.1 OPENTUI_VER=0.6.8" ]
}

@test "resolve_dep_pins: unknown version fails loudly" {
  run bash -c 'source "$1/scripts/lib/build-pins.sh"; resolve_dep_pins 9.9.9' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown VER=9.9.9"* ]]
}

@test "resolve_dep_pins: environment override wins" {
  PTY_VER=7.7 run bash -c 'source "$1/scripts/lib/build-pins.sh"; resolve_dep_pins 2.0.31' _ "$REPO_ROOT"
  [[ "$output" == PTY_VER=7.7* ]]
}

@test "apply-platform-patch: pristine anchors are patched" {
  d="$WORK/pristine/node_modules/@opentui/core"
  mkdir -p "$d"
  printf 'const a = { platform: process.platform, };\nif (process.platform === "linux") {\n  x()\n}\n' >"$d/chunk-bun-x.js"
  run bash "$REPO_ROOT/tools/build-bionic/apply-platform-patch.sh" "$WORK/pristine"
  [ "$status" -eq 0 ]
  grep -q 'platform: "linux",' "$d/chunk-bun-x.js"
  grep -q 'if (true) {' "$d/chunk-bun-x.js"
}

@test "apply-platform-patch: drifted anchors hard-fail and leave the file untouched" {
  d="$WORK/drift/node_modules/@opentui/core"
  mkdir -p "$d"
  # discovery string present, but both sed anchors miss (no comma / no space)
  printf 'const a = { platform: process.platform };\nif (process.platform === "linux"){\n  x()\n}\n' >"$d/chunk-bun-x.js"
  before="$(sha256sum "$d/chunk-bun-x.js" | cut -d' ' -f1)"
  run bash "$REPO_ROOT/tools/build-bionic/apply-platform-patch.sh" "$WORK/drift"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sed anchor drifted"* ]]
  after="$(sha256sum "$d/chunk-bun-x.js" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}

@test "is_hardened and harden-check CLI: marker detection" {
  printf 'plain\n' >"$WORK/no"
  printf 'libopencode-crhandler.so\n' >"$WORK/yes"
  run bash "$REPO_ROOT/scripts/lib/harden-check.sh" "$WORK/no"
  [ "$status" -eq 1 ]
  run bash "$REPO_ROOT/scripts/lib/harden-check.sh" "$WORK/yes"
  [ "$status" -eq 0 ]
}

@test "pkg_base_name: v1 vs v2 split" {
  run bash -c 'source "$1/scripts/package/lib.sh"; pkg_base_name 1.19.3' _ "$REPO_ROOT"
  [ "$output" = "opencode1" ]
  run bash -c 'source "$1/scripts/package/lib.sh"; pkg_base_name 2.0.31' _ "$REPO_ROOT"
  [ "$output" = "opencode" ]
}

@test "pkgrel_default: env override" {
  run bash -c 'source "$1/scripts/package/lib.sh"; pkgrel_default' _ "$REPO_ROOT"
  [ "$output" = "1" ]
  PKGREL=5 run bash -c 'source "$1/scripts/package/lib.sh"; pkgrel_default' _ "$REPO_ROOT"
  [ "$output" = "5" ]
}

@test "require_pkg_installed: store and node_modules layouts" {
  mkdir -p "$WORK/empty"
  run bash -c 'source "$1/scripts/lib/build-guards.sh"; require_pkg_installed "$2" "$2" "@x/y"' _ "$REPO_ROOT" "$WORK/empty"
  [ "$status" -eq 1 ]

  mkdir -p "$WORK/store/@x+y@1.0.0/node_modules/@x/y"
  printf '{}\n' >"$WORK/store/@x+y@1.0.0/node_modules/@x/y/package.json"
  run bash -c 'source "$1/scripts/lib/build-guards.sh"; require_pkg_installed "$2" "$2" "@x/y"' _ "$REPO_ROOT" "$WORK/store"
  [ "$status" -eq 0 ]

  mkdir -p "$WORK/src/node_modules/@x/y"
  printf '{}\n' >"$WORK/src/node_modules/@x/y/package.json"
  run bash -c 'source "$1/scripts/lib/build-guards.sh"; require_pkg_installed "$2" "$2" "@x/y"' _ "$REPO_ROOT" "$WORK/src"
  [ "$status" -eq 0 ]
}

@test "build-bionic: unknown VER fails before any network call" {
  run env VER=9.9.9 V2_SRC=/nonexistent bash "$REPO_ROOT/scripts/build-bionic.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown VER=9.9.9"* ]]
}

@test "assert-pty: embedded sha256 detection" {
  printf 'prefix 389a6e86417176c15d0d18f0486e9f0d669ed8c08f8e9c7fbfb727b41f55f8b4 suffix\n' >"$WORK/bin"
  run make -C "$REPO_ROOT" assert-pty BIN="$WORK/bin" SHA=389a6e86417176c15d0d18f0486e9f0d669ed8c08f8e9c7fbfb727b41f55f8b4
  [ "$status" -eq 0 ]

  run make -C "$REPO_ROOT" assert-pty BIN="$WORK/bin" SHA=deadbeefdeadbeef
  [ "$status" -ne 0 ]
  [[ "$output" == *"not embedded"* ]]
}

@test "verify-artifact: large stream check must not false-fail (SIGPIPE trap)" {
  # `strings | grep -q` under pipefail: grep exits at the first hit, strings
  # dies with SIGPIPE (141) and the check reports a false failure. The codebase
  # uses `grep -c` for exactly this reason; this guards against a regression.
  {
    echo "# libopencode-crhandler.so"
    echo "_assets/index-abc"
    for i in $(seq 1 60000); do echo "padding-line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done
  } >"$WORK/bigbin"
  chmod +x "$WORK/bigbin"
  run bash "$REPO_ROOT/scripts/verify-artifact.sh" "$WORK/bigbin" --web
  [ "$status" -eq 0 ]
  [[ "$output" == *"web-ui: OK"* ]]
}
