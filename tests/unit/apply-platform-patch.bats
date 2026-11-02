#!/usr/bin/env bats
# Unit tests for tools/build-bionic/apply-platform-patch.sh

load '../lib/helper'

setup() {
	make_tmpdir
	PATCH_SCRIPT="$(script_path tools/build-bionic/apply-platform-patch.sh)"
	STORE_CHUNK="$TEST_TMPDIR/@opentui+core@0.6.8"
	CHUNK_DIR="$STORE_CHUNK/node_modules/@opentui/core"
	mkdir -p "$CHUNK_DIR"
	CHUNK_FILE="$CHUNK_DIR/chunk-bun-ehr9v0n8.js"
	cat > "$CHUNK_FILE" <<'EOF'
var POINTER_NEGATIVE = "Pointer must be non-negative";
var POINTER_UNSAFE = "Pointer exceeds safe integer range";
var isBun = true;
function toPointer(value) {
  if (isBun && typeof value === "bigint") {
    return toSafeNumberPointer(value);
  }
  return value;
}
function toSafeNumberPointer(pointer) {
  if (pointer < 0n) {
    throw new Error(POINTER_NEGATIVE);
  }
  if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(POINTER_UNSAFE);
  }
  return Number(pointer);
}
function toBunPointer(pointer) {
  return typeof pointer === "bigint" ? toSafeNumberPointer(pointer) : pointer;
}
function toBunPointer2(pointer) {
  return typeof pointer === "bigint" ? Number(pointer) : pointer;
}
const target = {
  platform: process.platform,
};
if (process.platform === "linux") {
  globalThis.__linuxLoaded = true;
}
EOF
}

teardown() {
	clean_tmpdir
}

@test "apply-platform-patch patches platform literal and linux branch" {
	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]
	grep -q 'platform: "linux",' "$CHUNK_FILE"
	grep -q 'if (true) {' "$CHUNK_FILE"
}

@test "apply-platform-patch patches toSafeNumberPointer to preserve Android tagged BigInt pointers" {
	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]
	! grep -q 'throw new Error(POINTER_UNSAFE);' "$CHUNK_FILE"
	grep -q 'if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {' "$CHUNK_FILE"
	grep -q 'return pointer;' "$CHUNK_FILE"
}

@test "apply-platform-patch preserves 64-bit precision in toPointer, toBunPointer, and toBunPointer2 at runtime" {
	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]

	run node -e '
const fs = require("fs");
const code = fs.readFileSync(process.argv[1], "utf8");
const fn = new Function(code + "; return { toPointer, toBunPointer, toBunPointer2 };");
const { toPointer, toBunPointer, toBunPointer2 } = fn();
const tagged = 0xb40000739dbee610n;
if (toPointer(tagged) !== tagged) throw new Error("toPointer corrupted tagged pointer");
if (toBunPointer(tagged) !== tagged) throw new Error("toBunPointer corrupted tagged pointer");
if (toBunPointer2(tagged) !== tagged) throw new Error("toBunPointer2 truncated low bits of tagged pointer");
if (toPointer(0x739dbee610n) !== 0x739dbee610) throw new Error("untagged pointer should return Number");
' "$CHUNK_FILE"
	[ "$status" -eq 0 ]
}

@test "apply-platform-patch is idempotent on repeated runs" {
	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]
	cp "$CHUNK_FILE" "$TEST_TMPDIR/first.js"

	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]
	cmp -s "$CHUNK_FILE" "$TEST_TMPDIR/first.js"
}

@test "apply-platform-patch succeeds on OpenTUI 0.5.x chunk without toSafeNumberPointer" {
	grep -v 'toSafeNumberPointer\|toBunPointer' "$CHUNK_FILE" > "$CHUNK_FILE.05"
	mv "$CHUNK_FILE.05" "$CHUNK_FILE"
	run bash "$PATCH_SCRIPT" "$STORE_CHUNK"
	[ "$status" -eq 0 ]
	grep -q 'platform: "linux",' "$CHUNK_FILE"
}
