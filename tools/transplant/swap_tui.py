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



def _iter_func_syms(data: bytes):
    """Yield (name, FILE OFFSET, st_size) for every defined STT_FUNC symbol in
    SHT_SYMTAB (full table; guard-owner functions are local F entries).
    st_value is a virtual address: translate through PT_LOAD segments."""
    if data[4] != 2:  # EI_CLASS != ELFCLASS64
        raise ValueError("not ELF64")
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    loads = []
    for n in range(e_phnum):
        po = e_phoff + n * e_phentsize
        p_type = struct.unpack_from("<I", data, po + 0x0)[0]
        if p_type == 1:  # PT_LOAD
            p_offset = struct.unpack_from("<Q", data, po + 0x8)[0]
            p_vaddr = struct.unpack_from("<Q", data, po + 0x10)[0]
            p_filesz = struct.unpack_from("<Q", data, po + 0x20)[0]
            loads.append((p_vaddr, p_offset, p_filesz))

    def vaddr_to_off(v):
        for p_vaddr, p_offset, p_filesz in loads:
            if p_vaddr <= v < p_vaddr + p_filesz:
                return v - p_vaddr + p_offset
        raise ValueError(f"symbol vaddr {v:#x} not in any PT_LOAD")

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    symtab_off = symtab_size = symtab_entsize = strtab_off = None
    for n in range(e_shnum):
        so = e_shoff + n * e_shentsize
        s_type = struct.unpack_from("<I", data, so + 0x4)[0]
        if s_type == 2:  # SHT_SYMTAB
            symtab_off = struct.unpack_from("<Q", data, so + 0x18)[0]
            symtab_size = struct.unpack_from("<Q", data, so + 0x20)[0]
            symtab_entsize = struct.unpack_from("<Q", data, so + 0x38)[0]
            link = struct.unpack_from("<I", data, so + 0x28)[0]
            strtab_so = e_shoff + link * e_shentsize
            strtab_off = struct.unpack_from("<Q", data, strtab_so + 0x18)[0]
            break
    if symtab_off is None:
        raise ValueError("no SHT_SYMTAB (symbol table stripped)")
    for off in range(symtab_off, symtab_off + symtab_size, symtab_entsize):
        st_name = struct.unpack_from("<I", data, off)[0]
        st_info = data[off + 4]
        st_shndx = struct.unpack_from("<H", data, off + 6)[0]
        st_value = struct.unpack_from("<Q", data, off + 8)[0]
        st_size = struct.unpack_from("<Q", data, off + 16)[0]
        if st_shndx == 0 or st_size == 0 or (st_info & 0xF) != 2:  # STT_FUNC
            continue
        end = data.index(b"\x00", strtab_off + st_name)
        name = data[strtab_off + st_name:end].decode("utf-8", "replace")
        yield name, vaddr_to_off(st_value), st_size

def _buffer_draw_char_range(data: bytes) -> tuple:
    """Locate the bufferDrawChar function's [st_value, st_value+st_size) text
    range (diagnostics; the guard gate itself scans all guard owners)."""
    for name, value, size in _iter_func_syms(data):
        if name in ("bufferDrawChar", "lib.bufferDrawChar"):
            return value, size
    raise ValueError("bufferDrawChar symbol not found")

# Functions whose code contains (or inlines) the FFI guard logic. Scanning all
# of their ranges is inlining-agnostic: the crashfix-era build inlined
# isPointInScissor into bufferDrawChar, while the 0.1.101 build keeps them
# out-of-line (setCellWithAlphaBlending etc).
_GUARD_OWNER_SUBSTRINGS = (
    "bufferDrawChar",
    "isPointInScissor",
    "isRectInScissor",
    "clipRectToScissor",
    "setCellWithAlphaBlending",
    "drawGrayscaleBuffer",
    "drawTextBufferInternal",
    "clipRectToHitScissor",
    "addToHitGrid",
    "pushScissorRect",
)

def has_ffi_guard(lib: bytes) -> bool:
    """Guard verification (task-tui-common-fix): scan the code ranges of all
    guard-owning symbols for the compiled guard patterns: `mov wN,
    #0x7fffffff` clamps (MOVN #0x8000,LSL#16) + saturating-add `csel ..., vs`.
    An unguarded build has plain adds + b.vs integerOutOfBounds branches in
    those ranges instead. Verified differentially: crashfix v2 .so passes,
    1.18.27 batch .so fails."""
    try:
        owners = []
        for name, value, size in _iter_func_syms(lib):
            if any(sub in name for sub in _GUARD_OWNER_SUBSTRINGS):
                owners.append((name, value, min(size, len(lib) - value)))
    except ValueError as e:
        print(f"swap_tui: guard check cannot run: {e}", file=sys.stderr)
        return False
    if not owners:
        print("swap_tui: guard check cannot run: no guard-owner symbols found", file=sys.stderr)
        return False
    clamp = csel_vs = 0
    for _, start, size in owners:
        for off in range(start, start + size - 3, 4):
            w = struct.unpack_from("<I", lib, off)[0]
            if (w & 0xFFFFFFE0) == 0x12B00000:  # movn wd, #0x8000, lsl #16 => mov wd, #0x7fffffff
                clamp += 1
            elif (w & 0xFFE00C00) == 0x1A800000 and ((w >> 12) & 0xF) == 6:  # csel wd,wn,wm,vs
                csel_vs += 1
    print(f"swap_tui: guard scan over {len(owners)} owner symbols: clamp={clamp} csel_vs={csel_vs}")
    return clamp >= 1 and csel_vs >= 1

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

    if not has_ffi_guard(lib):
        print(
            "swap_tui: REFUSED — tui-lib lacks the FFI negative-coordinate "
            "guard v2 (patches/opentui/*.patch); build via "
            "tools/transplant/build-libopentui.sh which applies + verifies them",
            file=sys.stderr,
        )
        return 5

    padded = lib + b"\x00" * (slot - len(lib))
    out = data[:base] + padded + data[base + slot :]
    assert len(out) == len(data), "output length drifted"
    with open(args.out, "wb") as f:
        f.write(out)
    print(f"swap_tui: wrote {args.out} ({len(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
