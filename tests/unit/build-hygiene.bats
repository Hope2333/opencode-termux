#!/usr/bin/env bats
# Unit tests for scripts/build-hygiene.sh (df gate / sweep / LRU / manifest)

load '../lib/helper'

setup() {
	make_tmpdir
	HYG="$(script_path scripts/build-hygiene.sh)"
	# 全部旋钮重定向到隔离目录：测试绝不触碰真实 artifacts/build、bun cache、v2src 树
	export HYG_LOG="$TEST_TMPDIR/hyg.log"
	export BUN_CACHE="$TEST_TMPDIR/buncache"
	export TREE_ROOT="$TEST_TMPDIR/v2src"
	export HYG_ARTIFACTS_BUILD="$TEST_TMPDIR/artifacts/build"
	export DF_TARGET="/data"
	mkdir -p "$BUN_CACHE" "$TREE_ROOT" "$HYG_ARTIFACTS_BUILD"
}

teardown() {
	clean_tmpdir
}

# ── df_gate ──────────────────────────────────────────────────────────────

@test "df_gate happy: passes at normal water level (tiny threshold, no sweep needed)" {
	run bash -c ". '$HYG'; df_gate 1"
	[ "$status" -eq 0 ]
	grep -q "df_gate ok" "$HYG_LOG"
}

@test "df_gate happy: default threshold via env override passes on this host" {
	run bash -c ". '$HYG'; DF_MIN_KB=1 df_gate"
	[ "$status" -eq 0 ]
}

@test "df_gate failure: threshold above free space exits non-zero with reason (mock df)" {
	mkdir -p "$TEST_TMPDIR/bin"
	cat > "$TEST_TMPDIR/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/data 100 50 999 50% /data"
EOF
	chmod +x "$TEST_TMPDIR/bin/df"
	run bash -c "export PATH='$TEST_TMPDIR/bin':\"\$PATH\"; . '$HYG'; df_gate 3000000"
	[ "$status" -eq 1 ]
	[[ "$output" == *"df_gate FAIL"* ]]
	[[ "$output" == *"999K free < 3000000K"* ]]
	grep -q "df_gate FAIL after" "$HYG_LOG"
}

@test "df_gate failure: real disk, threshold forced above actual free space" {
	run bash -c ". '$HYG'; df_gate 999999999999"
	[ "$status" -eq 1 ]
	[[ "$output" == *"df_gate FAIL"* ]]
	grep -q "df_gate FAIL after" "$HYG_LOG"
}

# ── sweep_intermediates ──────────────────────────────────────────────────

@test "sweep_intermediates KEEP_BINS=1 removes pre-crhandler but keeps revived bin" {
	ab="$HYG_ARTIFACTS_BUILD/9.9.9"
	mkdir -p "$ab"
	: > "$ab/opencode-native-revived"
	: > "$ab/opencode-native-revived.pre-crhandler"
	run bash -c ". '$HYG'; KEEP_BINS=1 sweep_intermediates"
	[ "$status" -eq 0 ]
	[ ! -f "$ab/opencode-native-revived.pre-crhandler" ]
	[ -f "$ab/opencode-native-revived" ]
}

@test "sweep_intermediates default removes revived bin too" {
	ab="$HYG_ARTIFACTS_BUILD/9.9.9"
	mkdir -p "$ab"
	: > "$ab/opencode-native-revived"
	run bash -c ". '$HYG'; sweep_intermediates"
	[ "$status" -eq 0 ]
	[ ! -f "$ab/opencode-native-revived" ]
}

# ── bun_cache_gc (LRU) ───────────────────────────────────────────────────

@test "bun_cache_gc removes oldest dir first until under cap" {
	mkdir -p "$BUN_CACHE/a" "$BUN_CACHE/b"
	dd if=/dev/zero of="$BUN_CACHE/a/f" bs=1k count=100 2>/dev/null
	dd if=/dev/zero of="$BUN_CACHE/b/f" bs=1k count=100 2>/dev/null
	touch -d '2026-01-01 00:00:00' "$BUN_CACHE/a/f" "$BUN_CACHE/a"
	touch -d '2026-06-01 00:00:00' "$BUN_CACHE/b/f" "$BUN_CACHE/b"
	# cap=150K：两目录各 ~104K（4K 块粒度），总量 >cap 触发 GC，淘汰最旧的 a 后即低于 cap，b 必须保留
	run bash -c ". '$HYG'; BUN_CACHE_CAP_KB=150 bun_cache_gc"
	[ "$status" -eq 0 ]
	[ -d "$BUN_CACHE/b" ]
	[ ! -d "$BUN_CACHE/a" ]
	grep -q "bun_cache_gc removed" "$HYG_LOG"
}

@test "bun_cache_gc skips when cache under cap" {
	mkdir -p "$BUN_CACHE/small"
	run bash -c ". '$HYG'; BUN_CACHE_CAP_KB=2097152 bun_cache_gc"
	[ "$status" -eq 0 ]
	[ -d "$BUN_CACHE/small" ]
}

# ── sweep_trees (LRU) ────────────────────────────────────────────────────

@test "sweep_trees keeps newest TREE_KEEP trees, removes the rest" {
	mkdir -p "$TREE_ROOT/opencode-2.0.1" "$TREE_ROOT/opencode-2.0.2" "$TREE_ROOT/opencode-2.0.3"
	touch -d '2026-01-01 00:00:00' "$TREE_ROOT/opencode-2.0.1"
	touch -d '2026-02-01 00:00:00' "$TREE_ROOT/opencode-2.0.2"
	touch -d '2026-03-01 00:00:00' "$TREE_ROOT/opencode-2.0.3"
	run bash -c ". '$HYG'; TREE_KEEP=1 sweep_trees"
	[ "$status" -eq 0 ]
	[ -d "$TREE_ROOT/opencode-2.0.3" ]
	[ ! -d "$TREE_ROOT/opencode-2.0.1" ]
	[ ! -d "$TREE_ROOT/opencode-2.0.2" ]
}

# ── write_build_state / skip_if_fresh ────────────────────────────────────

@test "write_build_state records sha256 manifest entry in isolated cwd" {
	run bash -c "cd '$TEST_TMPDIR' && mkdir -p packing/pacman packing/dpkg-native artifacts/build/9.9.9 && \
		head -c 512 /dev/zero > packing/pacman/opencode-9.9.9-7-aarch64.pkg.tar.xz && \
		head -c 256 /dev/zero > packing/dpkg-native/opencode_9.9.9_aarch64.deb && \
		. '$HYG' && write_build_state 9.9.9 gnu 7"
	[ "$status" -eq 0 ]
	[[ "$output" == *"build-state: 9.9.9:gnu:7 recorded"* ]]
	grep -q '"sha256"' "$TEST_TMPDIR/packing/build-state.json"
	grep -q '"pac"' "$TEST_TMPDIR/packing/build-state.json"
	grep -q '"deb"' "$TEST_TMPDIR/packing/build-state.json"
}

@test "write_build_state refuses empty VER (no silent skip)" {
	run bash -c "cd '$TEST_TMPDIR' && . '$HYG' && write_build_state ''"
	[ "$status" -eq 1 ]
	[[ "$output" == *"requires VER"* ]]
}

@test "skip_if_fresh: fresh when manifest entry matches and pac/deb exist" {
	run bash -c "cd '$TEST_TMPDIR' && mkdir -p packing/pacman packing/dpkg-native && \
		touch packing/pacman/opencode-9.9.9-7-aarch64.pkg.tar.xz packing/dpkg-native/opencode_9.9.9_aarch64.deb && \
		. '$HYG' && write_build_state 9.9.9 gnu 7 >/dev/null && skip_if_fresh 9.9.9 gnu 7"
	[ "$status" -eq 0 ]
}

@test "skip_if_fresh: not fresh for unknown version" {
	run bash -c "cd '$TEST_TMPDIR' && mkdir -p packing/pacman packing/dpkg-native && \
		touch packing/pacman/opencode-9.9.9-7-aarch64.pkg.tar.xz packing/dpkg-native/opencode_9.9.9_aarch64.deb && \
		. '$HYG' && write_build_state 9.9.9 gnu 7 >/dev/null && skip_if_fresh 9.9.8 gnu 7"
	[ "$status" -eq 1 ]
}

@test "skip_if_fresh: not fresh when packaged asset deleted from disk" {
	run bash -c "cd '$TEST_TMPDIR' && mkdir -p packing/pacman packing/dpkg-native && \
		touch packing/pacman/opencode-9.9.9-7-aarch64.pkg.tar.xz packing/dpkg-native/opencode_9.9.9_aarch64.deb && \
		. '$HYG' && write_build_state 9.9.9 gnu 7 >/dev/null && rm packing/dpkg-native/opencode_9.9.9_aarch64.deb && \
		skip_if_fresh 9.9.9 gnu 7"
	[ "$status" -eq 1 ]
}

# ── Makefile wiring ──────────────────────────────────────────────────────

@test "Makefile: family-v2-native recipe expands df_gate hook (make -n)" {
	run bash -c "cd '$REPO_ROOT' && make -n family-v2-native VER=2.0.12"
	[ "$status" -eq 0 ]
	[[ "$output" == *"df_gate"* ]]
}

@test "Makefile: family-v2-compressed recipe expands df_gate hook (make -n)" {
	run bash -c "cd '$REPO_ROOT' && make -n family-v2-compressed VER=2.0.12"
	[ "$status" -eq 0 ]
	[[ "$output" == *"df_gate"* ]]
}

@test "Makefile: df gate blocks build entry when threshold exceeds free space (QA failure)" {
	# 隔离旋钮全部走 env（make 透传给 recipe shell）；阈值高于真实可用空间 → 入口非零退出
	run env HYG_LOG="$TEST_TMPDIR/make-hyg.log" \
		BUN_CACHE="$TEST_TMPDIR/buncache" \
		TREE_ROOT="$TEST_TMPDIR/v2src" \
		HYG_ARTIFACTS_BUILD="$TEST_TMPDIR/artifacts/build" \
		bash -c "cd '$REPO_ROOT' && make family-v2-native VER=9.9.9 DF_MIN_KB=999999999999"
	[ "$status" -ne 0 ]
	[[ "$output" == *"df gate blocked build"* ]]
	[[ "$output" == *"df_gate FAIL"* ]]
	grep -q "df_gate FAIL after" "$TEST_TMPDIR/make-hyg.log"
}
