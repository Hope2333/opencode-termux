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

# Generalized asset marker: registry-name prefix (incl. leading NUL) up to the
# dynamic hash suffix, terminated by the raw ELF magic that follows the name's
# trailing NUL. This matches any libopentui-<hash>.so asset regardless of its
# hash suffix.
ASSET_PREFIX = b"\x00/$bunfs/root/libopentui-"
ASSET_TERMINATOR = b"\x7fELF"


def find_libopentui_asset(data: bytes) -> int:
    """Locate the embedded libopentui asset's ELF start within the bunfs payload.

    The asset is stored RAW (uncompressed) as:
        \\x00/$bunfs/root/libopentui-<hash>.so\\x00<ELF bytes>
    We match the prefix (incl. leading NUL) and require the asset name to end in
    ".so" with the raw ELF magic immediately following its trailing NUL, so any
    hash suffix matches. Scanning continues past incidental matches inside the
    bundled JS source (which may also contain the "/$bunfs/root/libopentui-"
    literal). Returns the absolute offset of \\x7fELF, or -1 if none exists.
    """
    start = 0
    while True:
        idx = data.find(ASSET_PREFIX, start)
        if idx < 0:
            return -1
        name_end = data.find(b"\x00", idx + len(ASSET_PREFIX))
        if name_end < 0:
            return -1
        name = data[idx + len(ASSET_PREFIX):name_end]
        # The raw ELF magic follows the name's trailing NUL.
        elf_off = name_end + 1
        if name.endswith(b".so") and data[elf_off:elf_off + 4] == ASSET_TERMINATOR:
            return elf_off
        # Not the real asset (e.g. a reference inside bundled JS); keep scanning.
        start = name_end + 1


def list_bunfs_assets(data: bytes) -> list:
    """Enumerate all /$bunfs/root/<name> registry strings present in `data`.

    Used to give the operator a clear picture of what assets ARE available when
    the expected libopentui asset cannot be found. Only plausible asset names
    (short, NUL-terminated tokens) are returned; long spans that merely contain
    the "/$bunfs/root/" literal inside bundled JS are skipped as noise.
    """
    token = b"/$bunfs/root/"
    candidates = []
    start = 0
    while True:
        i = data.find(token, start)
        if i < 0:
            break
        name_start = i + len(token)
        name_end = data.find(b"\x00", name_start)
        if name_end < 0:
            break
        name = data[name_start:name_end]
        if 0 < len(name) <= 255:
            candidates.append(name.decode("utf-8", "replace"))
        start = name_end + 1
    return candidates


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

    base = find_libopentui_asset(data)
    if base < 0:
        assets = list_bunfs_assets(data)
        libs = [a for a in assets if "libopentui" in a]
        print(
            "swap_tui: libopentui asset not found (no /$bunfs/root/libopentui-*.so)",
            file=sys.stderr,
        )
        if libs:
            print(
                "swap_tui: candidate libopentui-like assets present:",
                file=sys.stderr,
            )
            for a in libs:
                print(f"  - {a}", file=sys.stderr)
        else:
            print(
                "swap_tui: no libopentui-like asset; available bunfs assets "
                "(first 20):",
                file=sys.stderr,
            )
            for a in assets[:20]:
                print(f"  - {a}", file=sys.stderr)
        return 2

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
