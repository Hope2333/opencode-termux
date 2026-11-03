#!/data/data/com.termux/files/usr/bin/bash
# build-bionic-embed.sh — build bun-pty's librust_pty for aarch64-linux-android.
#
# WHY THIS EXISTS (and why the musl splice is not enough for the native line)
#   Upstream bun-pty ships the glibc build of librust_pty; bun-pty dlopens it for
#   POST /api/pty, which on bionic dies with ERR_DLOPEN_FAILED. The compressed
#   family works around that with a musl build + a symbol shim (build-splice.sh).
#   For the native family that shim is a dead end: the musl .so loads but SIGSEGVs
#   inside the loader/init path (Bun 1.4.0 "Segmentation fault at address 0x0"
#   right after POST /api/pty), because musl's runtime expectations go far beyond
#   the handful of libc symbols a shim can satisfy.
#
#   This host's rustc is built for aarch64-linux-android, so the crate can simply
#   be compiled for the target it runs on — no shim, no DT_RUNPATH, no surgery.
#   The only upstream gap is termios 0.2.2 (dependency of portable-pty) which has
#   no android cfg; the vendored copy adds `target_os = "android"` next to linux.
#
# Output: dist/librust_pty_arm64_bionic.so
# Knobs:  BUN_PTY_VER (default 0.4.11), FORCE=1 to rebuild, RUST_EMBED_SRC to
#         reuse an already-extracted tree.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="$ROOT_DIR/tools/bun-pty-splice"
DIST="$SRC_DIR/dist/librust_pty_arm64_bionic.so"
VER="${BUN_PTY_VER:-0.4.11}"

if [[ -f "$DIST" && "${FORCE:-0}" != "1" ]]; then
	echo "OK: $DIST already built (FORCE=1 to rebuild)"
	exit 0
fi

command -v cargo >/dev/null 2>&1 || { echo "ERR: cargo missing (pkg install rust)" >&2; exit 1; }
command -v llvm-readelf >/dev/null 2>&1 || { echo "ERR: llvm-readelf missing (pkg install llvm)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/bunpty-embed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SRC="${RUST_EMBED_SRC:-}"

if [[ -z "$SRC" ]]; then
	if [[ -d "$WORK/src/rust-pty" ]]; then
		SRC="$WORK/src"
	else
		echo "[1/4] fetch bun-pty $VER source"
		tgz="$WORK/bun-pty-src.tar.gz"
		ok=0
		for url in \
			"https://gh-proxy.com/https://github.com/sursaone/bun-pty/archive/refs/tags/v${VER}.tar.gz" \
			"https://ghproxy.net/https://github.com/sursaone/bun-pty/archive/refs/tags/v${VER}.tar.gz"; do
			if timeout 240 curl -fsSL "$url" -o "$tgz" 2>/dev/null && gzip -t "$tgz" 2>/dev/null; then ok=1; break; fi
		done
		[[ $ok -eq 1 ]] || { echo "ERR: cannot fetch bun-pty源码 ($VER)" >&2; exit 1; }
		mkdir -p "$WORK/src"
		tar xzf "$tgz" -C "$WORK/src" --strip-components=1
		SRC="$WORK/src"
	fi
fi

[[ -f "$SRC/rust-pty/Cargo.toml" ]] || { echo "ERR: $SRC/rust-pty/Cargo.toml missing" >&2; exit 1; }

echo "[2/4] patch termios for android (vendored)"
TERMIOS="$SRC_DIR/vendor/termios-0.2.2"
[[ -d "$TERMIOS" ]] || { echo "ERR: vendored termios missing: $TERMIOS" >&2; exit 1; }
python3 - "$SRC/rust-pty/Cargo.toml" "$TERMIOS" <<'PY'
import io, sys
manifest, termios_path = sys.argv[1], sys.argv[2]
s = io.open(manifest, encoding="utf-8").read()
if "[patch.crates-io]" not in s:
    s = s.rstrip() + (
        "\n\n# Android/bionic: upstream termios 0.2.2 has no android cfg; the\n"
        "# vendored copy only maps target_os=android onto its linux module.\n"
        "[patch.crates-io]\n"
        f'termios = {{ path = "{termios_path}" }}\n'
    )
    io.open(manifest, "w", encoding="utf-8").write(s)
    print("     [patch.crates-io] added")
else:
    print("     [patch.crates-io] already present")
PY

# The C++ unwinder must be linked STATICALLY *before* the bionic libc stub:
# rustc's link line puts `-lc` (whose stub declares _Unwind_*@LIBC_R) ahead of
# any libunwind archive, so lld "resolves" them against the stub and the .so
# ends up with `_Unwind_Resume@LIBC_R` undefined — dlopen on bionic then fails
# with 'cannot locate symbol "_Unwind_Resume"'. A tiny linker wrapper inserts
# the archive right before the first -lc.
WRAP="$WORK/cc-unwind.sh"
cat >"$WRAP" <<'WRAPPER'
#!/bin/sh
LIBUNWIND="${LIBUNWIND:?}"
out=""; placed=0
for a in "$@"; do
	if [ "$placed" -eq 0 ] && [ "$a" = "-lc" ]; then out="$out $LIBUNWIND"; placed=1; fi
	out="$out $a"
done
# shellcheck disable=SC2086
exec cc $out
WRAPPER
chmod +x "$WRAP"
LIBUNWIND_PATH="${LIBUNWIND_PATH:-/data/data/com.termux/files/usr/lib/libunwind.a}"
[[ -f "$LIBUNWIND_PATH" ]] || { echo "ERR: $LIBUNWIND_PATH missing (pkg install libc++)" >&2; exit 1; }

echo "[3/4] cargo build --release (host = $(rustc -vV | sed -n 's/^host: //p'))"
( cd "$SRC/rust-pty" && \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$WRAP" \
  LIBUNWIND="$LIBUNWIND_PATH" \
  cargo build --release )

SO="$SRC/rust-pty/target/release/librust_pty.so"
[[ -f "$SO" ]] || { echo "ERR: build produced no $SO" >&2; exit 1; }

echo "[4/4] gates"
if llvm-readelf -d "$SO" | grep -q 'NEEDED.*libc\.so\.6'; then
	echo "ERR: $SO is glibc-linked (libc.so.6) — refusing" >&2; exit 1
fi
llvm-readelf -d "$SO" | grep -q 'NEEDED.*libc\.so' \
	|| { echo "ERR: $SO does not NEED libc.so (bionic) — wrong target" >&2; exit 1; }
if [[ "$(llvm-nm -D --undefined-only "$SO" | grep -c '_Unwind' || true)" != "0" ]]; then
	echo "ERR: $SO still has undefined _Unwind_* (libunwind not linked statically) — dlopen would fail on bionic" >&2
	exit 1
fi
syms="$(llvm-nm -D --defined-only "$SO" | grep -c 'bun_pty_' || true)"
[[ "$syms" -ge 8 ]] || { echo "ERR: only $syms bun_pty_* symbols (want >= 8)" >&2; exit 1; }
for m in libc.so.6 libpthread.so.0 libdl.so.2; do
	if strings -a "$SO" | grep -qF "$m"; then
		echo "ERR: $SO still carries glibc marker $m" >&2; exit 1
	fi
done

mkdir -p "$SRC_DIR/dist"
install -m755 "$SO" "$DIST"
echo "OK: $DIST ($(stat -c%s "$DIST") bytes, bionic NEEDED, $syms bun_pty_* symbols)"
sha256sum "$DIST"
