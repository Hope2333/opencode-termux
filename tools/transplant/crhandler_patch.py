#!/usr/bin/env python3
"""W11 seccomp hardening: add DT_NEEDED libopencode-crhandler.so to a
transplanted native ELF WITHOUT disturbing the graft.

patchelf is deliberately NOT used: it rebuilds the ELF and was verified to
disturb the transplant output (drops INTERP, relocates DYNAMIC into a new
PT_LOAD past the module-graph trailer, changes file size; see
.omo/evidence/task-w11-crhandler.log).

Strategy: zero-displacement surgical dynamic-section edit.
  1. Verify the expected transplant shape (bionic aarch64 DYN, first
     DT_NEEDED == libc.so, DT_DEBUG + DT_HASH + DT_GNU_HASH + trailing
     DT_NULL present).
  2. Write the shim-name, libc-name and runpath strings into zero padding
     inside the first R-E PT_LOAD that is covered by no section (linker only
     reads DT_STRTAB bytes; padding is dead space).
  3. Reorder DT_NEEDED so the shim is FIRST in the chain (head of bionic's
     symbol lookup order -> the shim's exported syscall()/close_range()
     interpose the main ELF's PLT sites, which is what rescues the
     spawn-child fd-hygiene path), relocating the displaced libc.so NEEDED
     into the DT_DEBUG slot (debugger-only entry, not required by bionic).
     DT_HASH -> DT_RUNPATH (bionic symbol lookup prefers the DT_GNU_HASH
     table, which is present). Extend DT_STRSZ so the new strings are inside
     the declared string table (bionic Android 16 hard-fails with "strtab
     out of bounds error" otherwise; proven on-device).
  4. Prove the result: file size unchanged, every PT_LOAD phdr unchanged,
     and a full byte-compare against the original allowing ONLY the padding
     region and the four repurposed dynamic entries to differ.
"""
import struct
import sys
from typing import NoReturn

SHIM_NAME = "libopencode-crhandler.so"
LIBC_NAME = "libc.so"
RUNPATH = "$ORIGIN/../lib/opencode"

DT_NULL, DT_NEEDED, DT_HASH, DT_STRTAB, DT_STRSZ, DT_GNU_HASH = 0, 1, 4, 5, 10, 0x6ffffef5
DT_DEBUG, DT_RUNPATH = 21, 29

PT_LOAD, PT_DYNAMIC, PF_X = 1, 2, 1


def die(msg: str) -> NoReturn:
    print(f"crhandler_patch: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_phdrs(data: bytes, ehdr: tuple) -> list:
    e_phoff, e_phentsize, e_phnum = ehdr[5], ehdr[9], ehdr[10]
    return [
        struct.unpack_from("<IIQQQQQQ", data, e_phoff + i * e_phentsize)
        for i in range(e_phnum)
    ]


def load_shdrs(data: bytes, ehdr: tuple) -> list:
    e_shoff, e_shentsize, e_shnum = ehdr[6], ehdr[11], ehdr[12]
    return [
        struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
        for i in range(e_shnum)
    ]


def dyn_str(entries: list, strtab_off: int, data: bytes, val: int) -> str:
    end = data.index(b"\0", strtab_off + val)
    return data[strtab_off + val:end].decode()


def main() -> None:
    if len(sys.argv) != 2:
        die(f"usage: {sys.argv[0]} <native-elf>")
    path = sys.argv[1]
    with open(path, "rb") as f:
        orig = f.read()

    ehdr = struct.unpack_from("<16sHHIQQQIHHHHHH", orig, 0)
    ident = ehdr[0]
    etype, emachine = ehdr[1], ehdr[2]
    if ident[:4] != b"\x7fELF" or ident[4] != 2 or ident[5] != 1:
        die(f"not a little-endian ELF64: {path}")
    if etype != 3 or emachine != 183:
        die(f"not an aarch64 DYN (PIE) ELF: type={etype} machine={emachine}")
    if SHIM_NAME.encode() in orig:
        print(f"crhandler_patch: already hardened, skip: {path}")
        return

    phdrs = load_phdrs(orig, ehdr)
    dyn_phdr = None
    for p in phdrs:
        if p[0] == PT_DYNAMIC:
            dyn_phdr = p
            break
    if dyn_phdr is None:
        die("no PT_DYNAMIC found")
    dyn_off = dyn_phdr[2]
    dyn_filesz = dyn_phdr[5]
    if dyn_filesz % 16:
        die(f"PT_DYNAMIC filesz {dyn_filesz} not a multiple of 16")
    entries = [
        struct.unpack_from("<qQ", orig, dyn_off + i * 16)
        for i in range(dyn_filesz // 16)
    ]
    tags = {}
    for i, (t, _) in enumerate(entries):
        tags.setdefault(t, i)  # first occurrence wins
    for need, name in ((DT_DEBUG, "DT_DEBUG"), (DT_HASH, "DT_HASH"),
                       (DT_GNU_HASH, "DT_GNU_HASH"), (DT_STRTAB, "DT_STRTAB"),
                       (DT_STRSZ, "DT_STRSZ")):
        if need not in tags:
            die(f"expected {name} missing; ELF shape drifted beyond this patcher")
    if entries[-1][0] != DT_NULL:
        die("dynamic section does not end with DT_NULL")

    strtab_va = next(v for t, v in entries if t == DT_STRTAB)
    old_strsz = next(v for t, v in entries if t == DT_STRSZ)

    # vaddr -> file offset via the containing PT_LOAD (congruent mapping).
    def vaddr_to_off(vaddr: int) -> int:
        for p in phdrs:
            if p[0] != PT_LOAD:
                continue
            p_off, p_va, p_memsz = p[2], p[3], p[6]
            if p_va <= vaddr < p_va + p_memsz:
                return vaddr - p_va + p_off
        die(f"vaddr {vaddr:#x} not in any PT_LOAD")

    strtab_off = vaddr_to_off(strtab_va)

    # The first DT_NEEDED must be libc.so; it is displaced to the DT_DEBUG
    # slot so the shim can take the head of the lookup order.
    first_needed_idx = next((i for i, (t, _) in enumerate(entries)
                             if t == DT_NEEDED), None)
    if first_needed_idx is None:
        die("no DT_NEEDED entry found")
    first_needed_name = dyn_str(entries, strtab_off, orig,
                                entries[first_needed_idx][1])
    if first_needed_name != LIBC_NAME:
        die(f"first DT_NEEDED is {first_needed_name!r}, expected {LIBC_NAME!r}; "
            "shape drifted beyond this patcher")

    # Find zero padding inside the first R-E LOAD covered by no section.
    exec_load = None
    for p in phdrs:
        if p[0] == PT_LOAD and (p[1] & PF_X):
            exec_load = p
            break
    if exec_load is None:
        die("no R-E PT_LOAD found")
    e_off, e_va, e_filesz = exec_load[2], exec_load[3], exec_load[5]
    covered = [(s[3], s[4], s[5]) for s in load_shdrs(orig, ehdr) if s[4] or s[5]]
    runs, run_start = [], None
    for pos in range(e_off, e_off + e_filesz):
        zero = orig[pos] == 0 and not any(a <= pos < a + sz for a, _, sz in covered)
        if zero and run_start is None:
            run_start = pos
        elif not zero and run_start is not None:
            runs.append((run_start, pos - run_start))
            run_start = None
    if run_start is not None:
        runs.append((run_start, e_off + e_filesz - run_start))
    shim_bytes = SHIM_NAME.encode() + b"\0"
    libc_bytes = LIBC_NAME.encode() + b"\0"
    rpath_bytes = RUNPATH.encode() + b"\0"
    need_total = len(shim_bytes) + len(libc_bytes) + len(rpath_bytes)
    run = next((r for r in runs if r[1] >= need_total + 8), None)
    if run is None:
        die(f"no sectionless zero run >= {need_total + 8}B inside the R-E LOAD")
    str_shim = (run[0] + 7) & ~7  # 8-align for tidiness
    str_libc = str_shim + len(shim_bytes)
    str_rpath = str_libc + len(libc_bytes)
    str_end = str_rpath + len(rpath_bytes)
    print(f"crhandler_patch: strings @file {str_shim:#x}..{str_end:#x} "
          f"(zero run {run[0]:#x}+{run[1]}B)")

    # File offset -> vaddr inside the containing LOAD (strings live in the
    # R-E LOAD whose mapping is congruent for this binary shape).
    str_shim_va = str_shim - e_off + e_va
    str_libc_va = str_libc - e_off + e_va
    str_rpath_va = str_rpath - e_off + e_va
    new_strsz = (str_rpath_va + len(rpath_bytes)) - strtab_va
    if new_strsz <= old_strsz:
        die(f"new strsz {new_strsz} <= old {old_strsz}; padding arithmetic broken")

    # Apply: strings + NEEDED reorder (shim first, libc -> DT_DEBUG slot)
    # + DT_HASH->DT_RUNPATH + STRSZ extend.
    out = bytearray(orig)
    out[str_shim:str_shim + len(shim_bytes)] = shim_bytes
    out[str_libc:str_libc + len(libc_bytes)] = libc_bytes
    out[str_rpath:str_rpath + len(rpath_bytes)] = rpath_bytes
    struct.pack_into("<qQ", out, dyn_off + first_needed_idx * 16,
                     DT_NEEDED, str_shim_va - strtab_va)
    struct.pack_into("<qQ", out, dyn_off + tags[DT_DEBUG] * 16,
                     DT_NEEDED, str_libc_va - strtab_va)
    struct.pack_into("<qQ", out, dyn_off + tags[DT_HASH] * 16,
                     DT_RUNPATH, str_rpath_va - strtab_va)
    struct.pack_into("<qQ", out, dyn_off + tags[DT_STRSZ] * 16,
                     DT_STRSZ, new_strsz)

    # Proof: only the padding region and the four dynamic entries may differ.
    allowed = set(range(str_shim, str_end))
    for idx in (first_needed_idx, tags[DT_DEBUG], tags[DT_HASH], tags[DT_STRSZ]):
        allowed.update(range(dyn_off + idx * 16, dyn_off + idx * 16 + 16))
    diffs = [i for i, (a, b) in enumerate(zip(orig, out)) if a != b and i not in allowed]
    if len(orig) != len(out) or diffs:
        die(f"unexpected displacement: size {len(orig)}->{len(out)}, {len(diffs)} stray diffs")
    if struct.unpack_from("<q", out, dyn_off + dyn_filesz - 16)[0] != DT_NULL:
        die("trailing DT_NULL lost")

    with open(path, "wb") as f:
        f.write(out)
    print(f"crhandler_patch: OK {path} (DT_NEEDED[{first_needed_idx}] -> {SHIM_NAME} "
          f"first, libc.so -> DT_DEBUG slot, DT_RUNPATH {RUNPATH}, "
          f"DT_STRSZ {old_strsz}->{new_strsz}, zero displacement proven)")


if __name__ == "__main__":
    main()
