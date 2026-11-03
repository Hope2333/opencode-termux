#!/usr/bin/env bats
# Unit tests for tools/build-bionic/patch-ffi-pointer.py (and its wrapper).
# The fixture reproduces the exact shape of opentui 0.8.0's bundled
# chunk-bun-*.js (issues #43/#45/#46: Android 11+ tagged heap pointers).

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export REPO_ROOT
	PY="$REPO_ROOT/tools/build-bionic/patch-ffi-pointer.py"
	WRAP="$REPO_ROOT/tools/build-bionic/apply-ffi-pointer.sh"
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/ffip.XXXXXX")"
	export TMP
	CHUNK="$TMP/chunk-bun-abc123.js"
	cat >"$CHUNK" <<'JS'
var POINTER_NEGATIVE = "Pointer must be non-negative";
var POINTER_UNSAFE = "Pointer exceeds safe integer range";
function toSafeNumberPointer(pointer) {
  if (pointer < 0n) {
    throw new Error(POINTER_NEGATIVE);
  }
  if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(POINTER_UNSAFE);
  }
  return Number(pointer);
}
JS
}

teardown() {
	[[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
	return 0
}

@test "patches the tagged-pointer throw into a BigInt passthrough" {
	run python3 "$PY" "$CHUNK"
	[ "$status" -eq 0 ]
	grep -qF 'OT_PTR_BIGINT' "$CHUNK"
	# the constant must survive: other call sites still throw with it
	grep -qF 'POINTER_UNSAFE' "$CHUNK"
	# the unsafe branch must no longer throw
	! grep -q 'if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) {$' "$CHUNK"
	# the safe path is untouched (Android <= 10 behaviour must not change)
	grep -qF 'return Number(pointer);' "$CHUNK"
}

@test "is idempotent (second run keeps the file byte-identical)" {
	python3 "$PY" "$CHUNK"
	first="$(sha256sum "$CHUNK" | cut -d' ' -f1)"
	run python3 "$PY" "$CHUNK"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already patched"* ]]
	[ "$(sha256sum "$CHUNK" | cut -d' ' -f1)" = "$first" ]
}

@test "fails loudly when the anchor drifted (no silent unpatched bundle)" {
	sed -i 's/pointer > BigInt(Number.MAX_SAFE_INTEGER)/pointer >= BigInt(Number.MAX_SAFE_INTEGER)/' "$CHUNK"
	before="$(sha256sum "$CHUNK" | cut -d' ' -f1)"
	run python3 "$PY" "$CHUNK"
	[ "$status" -ne 0 ]
	[[ "$output" == *"drifted"* || "$output" == *"expected exactly 1"* ]]
	[ "$(sha256sum "$CHUNK" | cut -d' ' -f1)" = "$before" ]
}

@test "wrapper fails when no chunk carries POINTER_UNSAFE at all" {
	mkdir -p "$TMP/empty"
	printf 'var nothing = 1;\n' >"$TMP/empty/chunk-bun-x.js"
	run bash "$WRAP" "$TMP/empty"
	[ "$status" -ne 0 ]
	[[ "$output" == *"POINTER_UNSAFE"* ]]
}

@test "wrapper patches every chunk that carries the constant" {
	mkdir -p "$TMP/multi"
	cp "$CHUNK" "$TMP/multi/chunk-bun-1.js"
	cp "$CHUNK" "$TMP/multi/chunk-bun-2.js"
	run bash "$WRAP" "$TMP/multi"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 chunk(s)"* ]]
	grep -qF 'OT_PTR_BIGINT' "$TMP/multi/chunk-bun-1.js"
	grep -qF 'OT_PTR_BIGINT' "$TMP/multi/chunk-bun-2.js"
}
