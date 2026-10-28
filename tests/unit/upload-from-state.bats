#!/usr/bin/env bats
# Unit tests for tools/upload-from-state.sh (post-261026-roadmap todo 6).
# Everything runs against fixtures; gh is mocked on PATH, nothing hits the network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/bin" "$WORK/pkgs"
  export PATH="$WORK/bin:$PATH"

  # two fake artifacts with known digests
  printf 'deb-payload' > "$WORK/pkgs/opencode_9.9.9_aarch64.deb"
  printf 'pac-payload' > "$WORK/pkgs/opencode-9.9.9-1-aarch64.pkg.tar.xz"
  DEB_SHA="$(sha256sum "$WORK/pkgs/opencode_9.9.9_aarch64.deb" | cut -d' ' -f1)"
  PAC_SHA="$(sha256sum "$WORK/pkgs/opencode-9.9.9-1-aarch64.pkg.tar.xz" | cut -d' ' -f1)"
  export DEB_SHA PAC_SHA

  cat > "$WORK/state.json" <<EOF
{"builds": {"9.9.9:musl:1": {
  "variant": "musl", "pkgrel": "1", "ts": "2026-10-26T00:00:00+0800",
  "deb": {"path": "$WORK/pkgs/opencode_9.9.9_aarch64.deb", "sha256": "$DEB_SHA"},
  "pac": {"path": "$WORK/pkgs/opencode-9.9.9-1-aarch64.pkg.tar.xz", "sha256": "$PAC_SHA"}
}}}
EOF
}

# gh mock: prints whatever $GH_VIEW_TSV holds (first call = release view assets).
write_gh_mock() {
  cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) printf '%s\n' "${GH_VIEW_TSV:-}"; exit "${GH_VIEW_RC:-0}" ;;
  *"release upload"*) echo "mock-upload $*" >> "$GH_UPLOAD_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK/bin/gh"
}

@test "dry-run: uploads both assets when the release has none" {
  write_gh_mock
  export GH_VIEW_TSV=""
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --tag PushTEST --state "$WORK/state.json" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPLOAD opencode_9.9.9_aarch64.deb"* ]]
  [[ "$output" == *"UPLOAD opencode-9.9.9-1-aarch64.pkg.tar.xz"* ]]
  [[ "$output" == *"skipped(up-to-date): 0"* ]]
}

@test "dry-run: skips an asset whose digest already matches" {
  write_gh_mock
  export GH_VIEW_TSV
  GH_VIEW_TSV="$(printf 'opencode_9.9.9_aarch64.deb\tsha256:%s' "$DEB_SHA")"
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --tag PushTEST --state "$WORK/state.json" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP   opencode_9.9.9_aarch64.deb (digest match)"* ]]
  [[ "$output" == *"UPLOAD opencode-9.9.9-1-aarch64.pkg.tar.xz"* ]]
  [[ "$output" == *"skipped(up-to-date): 1"* ]]
}

@test "--only pac restricts the asset set" {
  write_gh_mock
  export GH_VIEW_TSV=""
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --tag PushTEST --state "$WORK/state.json" --dry-run --only pac
  [ "$status" -eq 0 ]
  [[ "$output" != *".deb"* ]]
  [[ "$output" == *".pkg.tar.xz"* ]]
}

@test "missing state file fails loudly" {
  write_gh_mock
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --tag PushTEST --state "$WORK/nope.json" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"state file not found"* ]]
}

@test "state without builds fails instead of uploading nothing silently" {
  write_gh_mock
  echo '{"builds": {}}' > "$WORK/empty.json"
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --tag PushTEST --state "$WORK/empty.json" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no builds"* ]]
}

@test "missing --tag is a usage error" {
  write_gh_mock
  run bash "$REPO_ROOT/tools/upload-from-state.sh" --state "$WORK/state.json" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tag is required"* ]]
}
