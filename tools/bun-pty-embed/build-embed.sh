#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-embed.sh — A2 T16: bionic-native librust_pty (zero-shim pty embed).
#
# WHY: v1's bun-pty@0.4.8 store ships a glibc prebuilt (librust_pty_arm64.so);
# bun --compile embeds it verbatim, and bionic dlopen fails at runtime, which
# is why the compressed line carried pty/librust_pty_arm64_musl_patched.so +
# shim.so externally. Rebuilding rust-pty from source against Termux bionic
# yields a .so whose DT_NEEDED is only libc.so/libdl.so with ZERO undefined
# symbols — embeddable by bun's own asset mechanism (require → bunfs →
# $TMPDIR/.bun-<euid>-<hash>.so extract → dlopen).
#
# Source: https://github.com/sursaone/bun-pty (rust-pty/, single lib.rs).
# Pin: master @ 0.4.11 (ABI-identical to the 0.4.8 JS FFI surface:
# bun_pty_spawn(cmd, cwd, env, cols, rows) + 7 more bun_pty_* symbols).
#
# ANDROID PATCH: portable-pty -> serial -> serial-unix -> termios 0.2.2, and
# crates.io termios 0.2.2 has no android os module. dcuddeback/termios-rs
# master added src/os/android.rs (139 items, cfg-wired in os/mod.rs) but
# never re-versioned; we clone master, pin its version to 0.2.2 and feed it
# to cargo via [patch.crates-io].
#
# Output: vendor/librust_pty_arm64_bionic.so (sha256 printed; gates below).
#
# Env:
#   BUN_PTY_SRC   bun-pty source checkout (default: cloned to
#                 $HOME/develop/bun-pty-src, reused when present)
#   TERMIOS_SRC   patched termios checkout (default: $HOME/develop/termios-0.2.2-android)

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT_DIR/tools/bun-pty-embed/vendor"
BUN_PTY_SRC="${BUN_PTY_SRC:-$HOME/develop/bun-pty-src}"
TERMIOS_SRC="${TERMIOS_SRC:-$HOME/develop/termios-0.2.2-android}"

command -v cargo >/dev/null 2>&1 || { echo "ERR: cargo missing (pkg install rust)" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "ERR: readelf missing" >&2; exit 1; }

# ── 1. bun-pty source (pinned clone) ───────────────────────────────────
if [[ ! -f "$BUN_PTY_SRC/rust-pty/src/lib.rs" ]]; then
	echo "[1/4] cloning sursaone/bun-pty (master, 0.4.11)"
	git clone --depth 1 https://github.com/sursaone/bun-pty.git "$BUN_PTY_SRC"
else
	echo "[1/4] bun-pty source present: $BUN_PTY_SRC"
fi

# ── 2. patched termios 0.2.2 (android os module) ───────────────────────
if [[ ! -f "$TERMIOS_SRC/src/os/android.rs" ]]; then
	echo "[2/4] cloning dcuddeback/termios-rs + re-version 0.2.2"
	git clone --depth 1 https://github.com/dcuddeback/termios-rs.git "$TERMIOS_SRC"
	sed -i 's/^version = "0.3.3"/version = "0.2.2"/' "$TERMIOS_SRC/Cargo.toml"
else
	echo "[2/4] patched termios present: $TERMIOS_SRC"
fi

# ── 3. wire [patch.crates-io] + build ──────────────────────────────────
echo "[3/4] cargo build --release (bionic native)"
if ! grep -q "A2 T16" "$BUN_PTY_SRC/rust-pty/Cargo.toml"; then
	cat >> "$BUN_PTY_SRC/rust-pty/Cargo.toml" << PATCH

# A2 T16: crates.io termios 0.2.2 (via portable-pty -> serial) has no android
# os module; patch in dcuddeback master (has android.rs) re-versioned 0.2.2.
[patch.crates-io]
termios = { path = "$TERMIOS_SRC" }
PATCH
fi
( cd "$BUN_PTY_SRC/rust-pty" && cargo build --release -j 2 )

# ── 4. gates + install ─────────────────────────────────────────────────
echo "[4/4] gates + install"
SO_IN="$BUN_PTY_SRC/rust-pty/target/release/librust_pty.so"
[[ -f "$SO_IN" ]] || { echo "ERR: build output missing: $SO_IN" >&2; exit 1; }

NEEDED="$(readelf -d "$SO_IN" | grep NEEDED || true)"
echo "$NEEDED" | grep -Eq 'NEEDED.*libc\.so' || { echo "ERR: no libc.so NEEDED" >&2; exit 1; }
echo "$NEEDED" | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]' && {
	echo "ERR: glibc-linked NEEDED found: $NEEDED" >&2; exit 1; }

UNDEF="$(readelf --dyn-syms "$SO_IN" | grep -c ' UNDEF ' || true)"
SYMS="$(nm -D --defined-only "$SO_IN" | grep -c ' T bun_pty_' || true)"
[[ "$UNDEF" -eq 0 ]] || { echo "ERR: $UNDEF undefined dynsyms (expect 0 — bionic resolves at link time)" >&2; exit 1; }
[[ "$SYMS" -eq 8 ]] || { echo "ERR: bun_pty_* exports=$SYMS (expect 8)" >&2; exit 1; }

mkdir -p "$DIST"
install -m755 "$SO_IN" "$DIST/librust_pty_arm64_bionic.so"
echo "OK: $DIST/librust_pty_arm64_bionic.so"
echo "    DT_NEEDED: $(echo "$NEEDED" | tr -s ' \n' ' ')"
echo "    undef=$UNDEF exports=$SYMS size=$(stat -c%s "$DIST/librust_pty_arm64_bionic.so")"
sha256sum "$DIST/librust_pty_arm64_bionic.so"
