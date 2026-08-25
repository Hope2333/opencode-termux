#!/usr/bin/env python3
"""swap_tui.py — replace the embedded glibc libopentui.so inside a transplanted
opencode-native binary with a bionic-built one (equal-length byte swap).

The embedded asset is stored RAW (uncompressed) in the bun standalone payload,
immediately after its registry name string:
    \\x00/$bunfs/root/libopentui-x8k2b6xk.so\\x00<ELF bytes>

The replacement .so must be <= the embedded ELF's exact size; it is padded with
trailing NUL bytes to exactly that length (ELF loaders ignore out-of-section
trailing bytes).

Usage:
  python3 tools/transplant/swap_tui.py --binary <in> --tui-lib <libopentui.so> --out <out>
"""
import argparse
import struct
import sys

ASSET_MARKER = b"\x00/$bunfs/root/libopentui-x8k2b6xk.so\x00\x7fELF"


def elf_size(data: bytes, off: int) -> int:
    """Exact on-disk size of an ELF64 at `off` (max of shdr-table end and last
    section's file extent)."""
    if data[off + 4] != 2:  # EI_CLASS != ELFCLASS64
        raise ValueError("not ELF64")
    e_shoff = struct.unpack_from("<Q", data, off + 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, off + 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, off + 0x3C)[0]
    end = e_shoff + e_shentsize * e_shnum
    for n in range(e_shnum):
        so = off + e_shoff + n * e_shentsize
        s_type = struct.unpack_from("<I", data, so + 0x4)[0]
        if s_type == 8:  # SHT_NOBITS occupies no file bytes
            continue
        s_offset = struct.unpack_from("<Q", data, so + 0x18)[0]
        s_size = struct.unpack_from("<Q", data, so + 0x20)[0]
        end = max(end, s_offset + s_size)
    return end


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--tui-lib", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    data = open(args.binary, "rb").read()
    lib = open(args.tui_lib, "rb").read()

    idx = data.find(ASSET_MARKER)
    if idx < 0:
        print("swap_tui: asset marker not found", file=sys.stderr)
        return 2
    base = idx + len(ASSET_MARKER) - 4  # position of \x7fELF

    # Raw-ELF sanity: reject compressed payloads.
    head = data[base : base + 16]
    if not head.startswith(b"\x7fELF"):
        print("swap_tui: region is not raw ELF (compressed?)", file=sys.stderr)
        return 3
    for magic in (b"\x28\xb5\x2f\xfd", b"\x1f\x8b\x08"):  # zstd / gzip
        if magic in data[base : base + 64]:
            print(f"swap_tui: compression magic {magic!r} near asset start", file=sys.stderr)
            return 3

    try:
        slot = elf_size(data, base)
    except ValueError as e:
        print(f"swap_tui: {e}", file=sys.stderr)
        return 3

    print(f"swap_tui: embedded asset @ {base:#x} slot={slot} incoming={len(lib)}")
    if len(lib) > slot:
        print(
            f"swap_tui: tui-lib ({len(lib)}) larger than slot ({slot}); "
            "strip debug info first",
            file=sys.stderr,
        )
        return 4

    padded = lib + b"\x00" * (slot - len(lib))
    out = data[:base] + padded + data[base + slot :]
    assert len(out) == len(data), "output length drifted"
    with open(args.out, "wb") as f:
        f.write(out)
    print(f"swap_tui: wrote {args.out} ({len(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
