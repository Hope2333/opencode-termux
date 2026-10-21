#!/usr/bin/env python3
"""swap_pty.py — replace the embedded glibc librust_pty inside a transplanted
opencode-native binary with a bionic-built one (equal-or-smaller byte swap).

WHY: bun-pty (packages/core/src/pty/pty.bun.ts -> the lazily imported
`chunk-*.js` FFI module) resolves its native library in this order:

    1. $BUN_PTY_LIB, when set and the path exists
    2. the *embedded* asset  -> /$bunfs/root/librust_pty_arm64-<hash>.so
    3. rust-pty/target/release/librust_pty_arm64.so next to the JS chunk

Upstream ships the glibc build (DT_NEEDED libpthread.so.0 / libc.so.6 /
libdl.so.2 / libutil.so.1). bun extracts that asset to
$TMPDIR/.bun-<euid>-<hash>.so and dlopen()s it, which on Android/bionic fails:

    ERR_DLOPEN_FAILED: library "libpthread.so.0" not found

Because the embedded asset always wins over any on-disk bionic/musl rebuild, a
launcher that only exports BUN_PTY_LIB (the compressed family's approach) is the
only escape hatch — and the native mainline installs the runtime directly at
$PREFIX/bin/opencode, so it has none. This tool fixes the asset itself, the way
swap_tui.py fixes libopentui.

The embedded asset is stored RAW (uncompressed) in the bun standalone payload:

    \x00/$bunfs/root/librust_pty_arm64-<hash>.so\x00<ELF bytes>

The replacement .so must be <= the embedded ELF's exact size (section-header
table end, which is what bun extracts byte-for-byte); it is padded with trailing
NUL bytes to exactly that length. The loader ignores out-of-section trailing
bytes (same trick as swap_tui.py).

Usage:
  python3 tools/transplant/swap_pty.py \
      --binary artifacts/transplant/<ver>/opencode-native-tui \
      --pty-lib tools/bun-pty-embed/vendor/librust_pty_arm64_bionic.so \
      --out artifacts/transplant/<ver>/opencode-native-tui

Gates (all hard failures unless --allow-glibc):
  * the source asset must be the glibc bun-pty build (else nothing to fix)
  * the replacement must be <= slot size and bionic-linked (no glibc NEEDED)
  * the replacement must export the 8 bun_pty_* FFI symbols bun-pty binds
  * the product's byte at the slot must decode as ELF after the swap
  * optional --verify-dlopen: ctypes.CDLL() the new asset (real bionic dlopen)
"""
import argparse
import ctypes
import os
import struct
import sys
import tempfile

ASSET_PREFIX = b"\x00/$bunfs/root/librust_pty_arm64-"
ELF_MAGIC = b"\x7fELF"

GLIBC_MARKERS = (b"libpthread.so.0\x00", b"libc.so.6\x00", b"libdl.so.2\x00")
FFI_SYMBOLS = (
    b"bun_pty_spawn",
    b"bun_pty_write",
    b"bun_pty_read",
    b"bun_pty_resize",
    b"bun_pty_kill",
    b"bun_pty_get_pid",
    b"bun_pty_get_exit_code",
    b"bun_pty_close",
)


class SwapError(Exception):
    pass


def elf_extent(data: bytes, off: int) -> int:
    """Return the ELF byte length at `off` (section-header table end)."""
    if data[off:off + 4] != ELF_MAGIC:
        raise SwapError(f"no ELF magic at offset {off}")
    hdr = data[off:off + 64]
    if len(hdr) < 64:
        raise SwapError("truncated ELF header")
    _ident, _type, _machine, _ver, _entry, _phoff, shoff, _flags, _ehsize, \
        _phentsize, _phnum, shentsize, shnum, _shstrndx = struct.unpack(
            "<16sHHIQQQIHHHHHH", hdr
        )
    end = shoff + shnum * shentsize if shoff else 0

    # Fall back to the last PT_LOAD when there is no section table.
    for i in range(_phnum):
        po = _phoff + i * _phentsize
        p_type, _p_flags, p_off, _vaddr, _paddr, p_filesz, _memsz, _align = \
            struct.unpack("<IIQQQQQQ", data[off + po:off + po + 56])
        if p_type == 1:
            end = max(end, p_off + p_filesz)
    if end <= 0:
        raise SwapError("cannot determine ELF extent")
    return end


def find_pty_asset(data: bytes) -> tuple:
    """Locate the real embedded pty asset -> (elf_off, extent, name)."""
    hits = []
    start = 0
    while True:
        i = data.find(ASSET_PREFIX, start)
        if i < 0:
            break
        name_end = data.find(b"\x00", i + len(ASSET_PREFIX))
        if name_end > 0 and data[name_end + 1:name_end + 5] == ELF_MAGIC:
            elf_off = name_end + 1
            hits.append((elf_off, elf_extent(data, elf_off), data[i + 1:name_end]))
        start = i + 1
    if hits:
        if len(hits) > 1:
            raise SwapError(f"ambiguous pty asset: {len(hits)} candidates {hits}")
        return hits[0]

    # bun >= 1.4.2 standalone layout: the bunfs registry is a consolidated
    # NUL-separated name table, so the name no longer precedes its payload.
    # Fall back to locating the payload by its own dynamic symbol name (see
    # swap_tui.py for the same two-stage strategy).
    elf = find_pty_payload_by_symbols(data)
    if elf:
        elf_off, extent = elf
        name = b"(consolidated-registry)"
        return elf_off, extent, name

    raise SwapError(
        "no embedded librust_pty asset found — this product either has no "
        "bun-pty FFI payload or bun changed the bunfs layout"
    )


def find_pty_payload_by_symbols(data: bytes) -> tuple:
    """Find a bun-pty payload whose name marker is elsewhere (consolidated)."""
    marker = b"bun_pty_spawn\x00"
    found = {}
    pos = 0
    while True:
        i = data.find(marker, pos)
        if i < 0:
            break
        pos = i + 1
        # Walk back to the nearest plausible ELF start (payload < 4 MiB).
        lo = max(0, i - (4 << 20))
        elf_off = data.rfind(ELF_MAGIC, lo, i)
        if elf_off < 0:
            continue
        try:
            extent = elf_extent(data, elf_off)
        except SwapError:
            continue
        if extent < 64 or extent > (4 << 20) or elf_off + extent < i + len(marker):
            continue
        # Must actually be the bun-pty lib, not an unrelated blob.
        blob = data[elf_off:elf_off + extent]
        if not all(s + b"\x00" in blob for s in FFI_SYMBOLS):
            continue
        found[elf_off] = extent
    if not found:
        return None
    if len(found) > 1:
        raise SwapError(f"ambiguous pty payloads at offsets {sorted(found)}")
    off, extent = found.popitem()
    return off, extent



def is_glibc_linked(blob: bytes) -> bool:
    return any(m in blob for m in GLIBC_MARKERS)


def check_replacement(lib: bytes) -> None:
    if lib[:4] != ELF_MAGIC:
        raise SwapError("replacement is not an ELF shared object")
    if is_glibc_linked(lib):
        bad = [m.rstrip(b"\x00").decode() for m in GLIBC_MARKERS if m in lib]
        raise SwapError(f"replacement is glibc-linked ({', '.join(bad)})")
    if b"libc.so\x00" not in lib:
        raise SwapError("replacement has no bionic libc.so NEEDED entry")
    missing = [s.decode() for s in FFI_SYMBOLS if s + b"\x00" not in lib]
    if missing:
        raise SwapError(f"replacement misses FFI exports: {', '.join(missing)}")


def verify_dlopen(lib: bytes) -> str:
    """Real bionic dlopen of the replacement (aarch64 host only)."""
    fd, path = tempfile.mkstemp(suffix=".so", prefix="pty-verify-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(lib)
        os.chmod(path, 0o755)
        handle = ctypes.CDLL(path)
        for sym in FFI_SYMBOLS:
            getattr(handle, sym.decode())
        return "ok"
    except OSError as e:
        raise SwapError(f"dlopen verification failed: {e}") from e
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", required=True, help="input opencode-native binary")
    ap.add_argument("--pty-lib",
                    help="bionic librust_pty (tools/bun-pty-embed/vendor/...)")
    ap.add_argument("--out", help="output binary")
    ap.add_argument("--check", action="store_true",
                    help="report the embedded pty asset status and exit")
    ap.add_argument("--verify-dlopen", action="store_true",
                    help="ctypes.CDLL the replacement (real bionic dlopen gate)")
    ap.add_argument("--allow-glibc", action="store_true",
                    help="keep a glibc asset instead of failing (not recommended)")
    args = ap.parse_args()

    data = bytearray(open(args.binary, "rb").read())
    if args.check:
        try:
            elf_off, extent, name = find_pty_asset(bytes(data))
        except SwapError as e:
            print("STATUS=absent REASON=" + str(e).split("\n")[0])
            return 0
        blob = bytes(data[elf_off:elf_off + extent])
        status = "glibc" if is_glibc_linked(blob) else "bionic"
        print(f"STATUS={status} ASSET={name.decode()} SIZE={extent}")
        return 0
    if not args.pty_lib or not args.out:
        ap.error("--pty-lib and --out are required unless --check is used")
    elf_off, extent, name = find_pty_asset(data)
    src = bytes(data[elf_off:elf_off + extent])
    print(f"pty asset: {name.decode()} @ {elf_off} ({extent} B, "
          f"{'glibc' if is_glibc_linked(src) else 'bionic'} NEEDED)")

    if not is_glibc_linked(src):
        print("SKIP: embedded pty is already bionic-linked (nothing to do)")
        if args.out != args.binary:
            open(args.out, "wb").write(bytes(data))
            os.chmod(args.out, 0o755)
        return 0
    if args.allow_glibc:
        print("WARN: --allow-glibc given; shipping a bionic-dlopen-broken pty")
        if args.out != args.binary:
            open(args.out, "wb").write(bytes(data))
            os.chmod(args.out, 0o755)
        return 0

    lib = open(args.pty_lib, "rb").read()
    check_replacement(lib)
    if len(lib) > extent:
        raise SwapError(
            f"replacement too large: {len(lib)} B > embedded slot {extent} B")
    if args.verify_dlopen:
        print(f"dlopen gate: {verify_dlopen(lib)}")

    data[elf_off:elf_off + len(lib)] = lib
    data[elf_off + len(lib):elf_off + extent] = b"\x00" * (extent - len(lib))

    out = bytes(data)
    if is_glibc_linked(out[elf_off:elf_off + extent]):
        raise SwapError("post-swap slot still carries glibc NEEDED strings")
    open(args.out, "wb").write(out)
    os.chmod(args.out, 0o755)
    print(f"OK: {args.out} ({len(out)} B, pty slot {extent} B, "
          f"padded {extent - len(lib)} B)")
    print(f"    provider: {args.pty_lib} ({len(lib)} B)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SwapError as e:
        print(f"ERR: {e}", file=sys.stderr)
        sys.exit(1)
