#!/usr/bin/env bats
# Unit tests for tools/a2/patch-v1-replies.py — v1's TUI "只显示不能操作" fix.
#
# Root cause (measured): Termux answers the startup capability probe in ONE
# burst, and opentui 0.4.5 guards each reply with ^...$-anchored regexes, so a
# multi-reply chunk matches nothing and becomes a text key. The patch drops any
# chunk with more than one ESC.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export REPO_ROOT
	PY="$REPO_ROOT/tools/a2/patch-v1-replies.py"
	BUN="$REPO_ROOT/artifacts/transplant/android-bun/bun-1.4.0/bun"
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/v1rep.XXXXXX")"
	export TMP
	CHUNK="$TMP/chunk-bun-x.js"
	cat >"$CHUNK" <<'JS'
var keyName = { "[A": "up" };
var parseKeypress = (s = "", options = {}) => {
  let parts;
  if (Buffer.isBuffer(s)) {
    s = String(s);
  }
  if (/^\x1b\[\?[\d;]+\$y$/.test(s)) {
    return null;
  }
  if (/^\x1b\[<\d+;\d+;\d+[Mm]$/.test(s)) {
    return null;
  }
  if (/^\x1b\][\d;].*(\x1b\\|\x07)$/.test(s)) {
    return null;
  }
  return { name: s };
};
JS
}

teardown() {
	[[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
	return 0
}

@test "patches parseKeypress with the reply-batch guard" {
	run python3 "$PY" "$CHUNK"
	[ "$status" -eq 0 ]
	grep -qF 'OT_DROP_REPLY_BATCH' "$CHUNK"
	# the per-reply anchored guards must survive
	grep -qF '\$y$' "$CHUNK"
	grep -qF '[Mm]$' "$CHUNK"
}

@test "is idempotent" {
	python3 "$PY" "$CHUNK"
	before="$(sha256sum "$CHUNK" | cut -d' ' -f1)"
	run python3 "$PY" "$CHUNK"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already patched"* ]]
	[ "$(sha256sum "$CHUNK" | cut -d' ' -f1)" = "$before" ]
}

@test "fails loudly when the parseKeypress anchor drifted" {
	sed -i 's/parseKeypress = (s = "", options = {}) => {/parseKeypress = (raw = "", opts = {}) => {/' "$CHUNK"
	run python3 "$PY" "$CHUNK"
	[ "$status" -ne 0 ]
	[[ "$output" == *"drifted"* || "$output" == *"expected exactly 1"* ]]
}

@test "runtime guard: reply batch dropped, real keys kept" {
	python3 "$PY" "$CHUNK"
	[ -x "$BUN" ] || skip "android bun not available"
	# pull the injected guard out of the patched chunk and exercise it
	guard="$(sed -n 's/.*OT_DROP_REPLY_BATCH\*\/\(.*\)$/\1/p' "$CHUNK" | head -1)"
	[ -n "$guard" ] || false
	cat >"$TMP/t.js" <<JS
function k(s) { $guard return "KEY"; }
const blob = "\x1b]10;rgb:c5c5/c8c8/c6c6\x07\x1b]11;rgb:1d1d/1f1f/2121\x07\x1b[45;1R\x1bP0+r4d73\x1b\\\\";
console.log("blob=" + k(blob));
console.log("char=" + k("a"));
console.log("arrow=" + k("\x1b[A"));
console.log("enter=" + k("\r"));
JS
	run "$BUN" "$TMP/t.js"
	[ "$status" -eq 0 ]
	[[ "$output" == *"blob=null"* ]]
	[[ "$output" == *"char=KEY"* ]]
	[[ "$output" == *"arrow=KEY"* ]]
	[[ "$output" == *"enter=KEY"* ]]
}
