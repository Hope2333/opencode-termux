#!/usr/bin/env python3
"""
revive_patch.py -- C1 revival surgery for android bun (pure-android branch).

Grafts an opencode standalone module graph onto the official android Bun ELF
and patches BUN_COMPILED so the runtime enters standalone mode (loads the
grafted graph) instead of falling back to interpreter mode.

Semantics follow bun-src src/exe_format/elf.zig writeBunSection():
  blob = u64_le(payload_len) || payload ; append page-aligned after the base ;
  extend the single writable PT_LOAD that covers .bun (identity mapping) ;
  publish the payload vaddr through BUN_COMPILED.size.

Android-specific deviations from upstream (both binary-verified, see
.omoevidence/task-22-c1-revival.log):
  1. BSS-safe placement: the RW LOAD has memsz >> filesz (large .bss).
     Appending right after file end would turn bss vaddrs into file-backed
     graph bytes and corrupt globals (v1 hang). We therefore place the blob
     past max(file_end, bss_end) and keep the old bss range zero-filled.
  2. PIE relocation (--size-mode reloc): bun <=1.3.x android
     dereferences
     BUN_COMPILED.size as an ABSOLUTE pointer (upstream compiled outputs are
     non-PIE where vaddr == absolute). Android bun is PIE, so we register an
     R_AARCH64_RELATIVE dynamic relocation (r_offset = .bun addr,
     r_addend = payload vaddr) and point DT_RELA/DT_RELASZ at an extended
     table appended after the blob. The linker then writes
     load_bias + payload_vaddr into the size field at load time.
     Binary truth: getter @0x3829310 returns adrp 0x5568000 (+0, NOT +8);
     chain does ldr x9,[x0]; ldr x8,[x9] -> len prefix inside blob.

  3. Plain offset (--size-mode plain-offset): bun >=1.4.x flipped the
     consumer semantics. Every getter call site (e.g. 0xebd098 / 0xf44254 in
     bun 1.4.0 android) loads x19 = *(u64*)&.bun[0], then dl_iterate_phdr()
     locates the PT_LOAD covering &.bun[0] and computes abs = dlpi_addr + x19
     before reading the len prefix. The size field must hold the UNBIASED
     payload vaddr as a plain constant - no relocation entry, DT_RELA
     untouched. Grafting with the 1.3.x reloc scheme onto 1.4.0 SIGSEGVs
     pre-init at bias + <relocated value> (task-w4a-bun140-base.log).

Usage:
  python3 revive_patch.py --bun <android-bun> --graph <module-graph.bin> \
                          --out <output-elf> [--size-mode reloc|plain-offset]

  --size-mode omitted (default): auto-detected from the base ELF's embedded
  bun version string ("bun-vX.Y.Z" / "Bun vX.Y.Z"): major.minor >= 1.4 ->
  plain-offset, else reloc. An explicit flag always wins and is noted as
  such in the output.
"""
import argparse
import os
import re
import struct
import sys

PAGE_ALIGN = 0x4000          # bun android binaries use 16K segment alignment
TRAILER = b"\n---- Bun! ----\n"
OFFSETS_SIZE = 32            # StandaloneModuleGraph.Offsets extern struct
PT_LOAD = 1
PT_DYNAMIC = 2
PF_W = 0x2                   # program header flag: writable (SHF_WRITE==0x1 is a SECTION flag!)
R_AARCH64_RELATIVE = 1027    # 0x403
DT_NULL = 0
DT_RELA = 7                  # address of rela table (vaddr)
DT_RELASZ = 8                # total size of rela table
DT_RELAENT = 9               # entry size (must stay 24)
RELAENT = 24

SCAN_HEAD_BYTES = 4 * 1024 * 1024   # bounded fast-path scan window
_BUN_VERSION_RE = re.compile(rb"(?:bun-v|Bun v)(\d+)\.(\d+)\.(\d+)")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def align_up(x: int, a: int) -> int:
    return (x + a - 1) & ~(a - 1)

def detect_size_mode(bun_bytes: bytes) -> str:
    """Infer --size-mode from the Bun version string embedded in the base ELF.

    Evidence matrix: reloc fits bun <=1.3.x bases, plain-offset fits
    bun >=1.4.x bases; reloc+1.4.x SIGSEGVs pre-init. Scan strategy:
    bounded 4MB head first (cheap), then one pass over the remainder of the
    already-resident buffer (the base is fully loaded for surgery anyway --
    no second file read, no double buffering).
    Conservative fallback: reloc + WARN when no version string is found.
    """
    m = _BUN_VERSION_RE.search(bun_bytes[:SCAN_HEAD_BYTES])
    if m is None:
        m = _BUN_VERSION_RE.search(bun_bytes)
    if m is None:
        print("WARN: no bun version string found in base ELF; "
              "auto size-mode fallback -> reloc", file=sys.stderr)
        return "reloc"
    major, minor, patch = (int(g) for g in m.groups())
    mode = "plain-offset" if (major, minor) >= (1, 4) else "reloc"
    print(f"auto size-mode={mode} (base bun v{major}.{minor}.{patch})")
    return mode

def parse_elf64(data: bytes):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        fail("not a little-endian ELF64")
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]

    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags = struct.unpack_from("<II", data, off)
        p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
            "<QQQQQQ", data, off + 8
        )
        phdrs.append(
            dict(index=i, hdr_off=off, type=p_type, flags=p_flags, offset=p_offset,
                 vaddr=p_vaddr, filesz=p_filesz, memsz=p_memsz, align=p_align)
        )

    shdrs = []
    if e_shoff and e_shnum:
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            name, sh_type, flags = struct.unpack_from("<IIQ", data, off)
            addr, offset, size = struct.unpack_from("<QQQ", data, off + 16)
            link = struct.unpack_from("<I", data, off + 40)[0]
            shdrs.append(dict(hdr_off=off, name_off=name, type=sh_type, flags=flags,
                              addr=addr, offset=offset, size=size, link=link))
    return phdrs, shdrs

def section_name(data: bytes, shstrtab: dict, name_off: int) -> str:
    start = shstrtab["offset"] + name_off
    end = data.index(b"\x00", start)
    return data[start:end].decode("ascii", "replace")

def find_dynamic_entries(out: bytearray, dyn_phdr: dict):
    """Yield (tag_index_byte_off, tag, val) for each entry of PT_DYNAMIC."""
    ents = []
    base = dyn_phdr["offset"]
    for k in range(dyn_phdr["filesz"] // 16):
        off = base + k * 16
        tag, val = struct.unpack_from("<qQ", out, off)
        ents.append((off, tag, val))
        if tag == DT_NULL:
            break
    return ents

def main() -> None:
    ap = argparse.ArgumentParser(description="C1 revival ELF surgery")
    ap.add_argument("--bun", required=True, help="official android bun ELF (base)")
    ap.add_argument("--graph", required=True, help="module-graph.bin ([graph][Offsets32][trailer16])")
    ap.add_argument("--out", required=True, help="output ELF path")
    ap.add_argument("--size-mode", choices=["reloc", "plain-offset"], default=None,
                    help="how BUN_COMPILED.size (.bun[0]) is published: "
                         "'reloc' = R_AARCH64_RELATIVE absolute pointer (bun "
                         "<=1.3.x android PIE chain dereferences .bun[0] "
                         "directly); 'plain-offset' = constant unbiased payload "
                         "vaddr, runtime adds dlpi_addr itself (bun >=1.4.x); "
                         "default: auto-detect from the base bun version "
                         "(>=1.4 -> plain-offset, else reloc)")
    args = ap.parse_args()

    with open(args.bun, "rb") as f:
        bun_bytes = f.read()
    if args.size_mode is None:
        # Auto-detect from the embedded bun version; kills the mode x base
        # mismatch class (reloc onto a 1.4.x base SIGSEGVs pre-init).
        args.size_mode = detect_size_mode(bun_bytes)
    else:
        print(f"size-mode={args.size_mode} (explicit)")
    with open(args.graph, "rb") as f:
        payload = f.read()

    print(f"[1/6] base={args.bun} ({len(bun_bytes)} B)  payload={args.graph} ({len(payload)} B)")

    # --- sanity: payload must end with Offsets + trailer ---
    if len(payload) < OFFSETS_SIZE + len(TRAILER):
        fail("payload too small to contain Offsets+trailer")
    if payload[-len(TRAILER):] != TRAILER:
        fail("payload does not end with trailer '\\n---- Bun! ----\\n'")
    print(f"[2/6] payload trailer OK: last 16B == {TRAILER!r}")

    phdrs, shdrs = parse_elf64(bun_bytes)

    # --- locate .bun section via shstrtab ---
    e_shstrndx = struct.unpack_from("<H", bun_bytes, 62)[0]
    if not shdrs or e_shstrndx >= len(shdrs):
        fail("invalid section header table / e_shstrndx")
    shstrtab = shdrs[e_shstrndx]
    bun_sec = None
    for s in shdrs:
        if section_name(bun_bytes, shstrtab, s["name_off"]) == ".bun":
            bun_sec = s
            break
    if bun_sec is None:
        fail("no .bun section found")
    if bun_sec["addr"] != bun_sec["offset"]:
        fail(f".bun addr {bun_sec['addr']:#x} != offset {bun_sec['offset']:#x}")
    print(f"[3/6] .bun section: addr==offset={bun_sec['addr']:#x} size={bun_sec['size']:#x}")

    # --- locate writable PT_LOAD covering .bun (writeBunSection semantics) ---
    load = None
    for p in phdrs:
        if p["type"] != PT_LOAD or not (p["flags"] & PF_W):
            continue
        if p["offset"] <= bun_sec["offset"] and bun_sec["offset"] + bun_sec["size"] <= p["offset"] + p["filesz"]:
            load = p
            break
    if load is None:
        fail("no writable PT_LOAD covers .bun section")
    if load["offset"] != load["vaddr"]:
        fail(f"covering PT_LOAD offset {load['offset']:#x} != vaddr {load['vaddr']:#x}; identity mapping required")
    old_filesz, old_memsz = load["filesz"], load["memsz"]

    # BSS-safe placement: skip past the old NOBITS extent so appended bytes can
    # never alias zero-initialized globals (v1 hang root cause).
    bss_end = load["offset"] + old_memsz
    new_off = align_up(max(len(bun_bytes), bss_end), PAGE_ALIGN)
    print(f"[4/6] covering PT_LOAD #{load['index']}: off==vaddr={load['vaddr']:#x} "
          f"filesz={old_filesz:#x} memsz={old_memsz:#x} | bss_end={bss_end:#x} -> new_off={new_off:#x}")

    # --- build output: zero-pad over old bss extent, append blob ---
    if args.size_mode == "plain-offset":
        # Consumer contract: the qword at the published vaddr is the graph
        # byte count, with the graph bytes immediately following it.
        # - Legacy standalone payloads open with their own mg_size prefix
        #   (== len-8): publish verbatim (W4a/W7a era).
        # - Section-format payloads (1.18.x+, leading b"/$bunfs/") carry NO
        #   prefix: publish one ourselves (matches the proven w7c2 layout;
        #   grafting them verbatim makes the runtime read ASCII as mg_size
        #   and SIGSEGV).
        lead = payload[:8]
        if struct.unpack_from("<Q", payload)[0] == len(payload) - 8:
            blob = payload + b"\x00" * 8
        else:
            if lead != b"/$bunfs/":
                print(f"[warn] unrecognized module-graph lead {lead!r}; "
                      "publishing own length prefix")
            blob = struct.pack("<Q", len(payload)) + payload + b"\x00" * 8
    else:
        blob = struct.pack("<Q", len(payload)) + payload
    out = bytearray(bun_bytes)
    out.extend(b"\x00" * (new_off - len(bun_bytes)))
    out.extend(blob)

    append_end = new_off + len(blob)           # identity mapping: vaddr == file offset

    if args.size_mode == "plain-offset":
        # bun >=1.4.x flipped consumer semantics: every getter call site loads
        # x19 = *(u64*)&.bun[0], finds the covering PT_LOAD via dl_iterate_phdr,
        # and dereferences dlpi_addr + x19. Publish the UNBIASED payload vaddr
        # as a plain constant; DT_RELA stays untouched.
        struct.pack_into("<Q", out, bun_sec["addr"], new_off)
        print(f"      size field: plain-offset {new_off:#x} @ {bun_sec['addr']:#x} "
              f"(bun>=1.4.x runtime adds dlpi_addr itself)")
        size_note = f"plain-offset {new_off:#x}; runtime computes load_bias + {new_off:#x}"
    else:
        # --- extended .rela.dyn with one R_AARCH64_RELATIVE entry for the size field ---
        dyn_phdr = next((p for p in phdrs if p["type"] == PT_DYNAMIC), None)
        if dyn_phdr is None:
            fail("no PT_DYNAMIC")
        dt = {t: v for _o, t, v in find_dynamic_entries(out, dyn_phdr)}
        if DT_RELA not in dt or DT_RELASZ not in dt:
            fail("DT_RELA/DT_RELASZ missing")
        old_rela_off, old_rela_sz = dt[DT_RELA], dt[DT_RELASZ]
        if old_rela_off != old_rela_sz and False:
            pass  # offset/vaddr equality checked below via identity mapping of seg0
        if old_rela_off % 8:
            fail(f"DT_RELA not 8-aligned: {old_rela_off:#x}")
        old_table = bytes(out[old_rela_off:old_rela_off + old_rela_sz])
        if len(old_table) != old_rela_sz:
            fail("existing rela table not fully inside file")

        rela_vaddr = append_end                 # identity mapping: vaddr == file offset
        add_entry = struct.pack("<QQq", bun_sec["addr"], R_AARCH64_RELATIVE, new_off)
        new_table = old_table + add_entry

        out.extend(new_table)
        append_end = rela_vaddr + len(new_table)

        # rewrite DT_RELA / DT_RELASZ in place (PT_DYNAMIC is identity-mapped too)
        patched_dt = False
        for off, tag, _val in find_dynamic_entries(out, dyn_phdr):
            if tag == DT_RELA:
                struct.pack_into("<Q", out, off + 8, rela_vaddr)
                patched_dt = True
            elif tag == DT_RELASZ:
                struct.pack_into("<Q", out, off + 8, len(new_table))
        if not patched_dt:
            fail("failed to rewrite DT_RELA")
        if dt.get(DT_RELAENT) != RELAENT:
            fail(f"unexpected DT_RELAENT {dt.get(DT_RELAENT)}")

        print(f"      rela table: {old_rela_off:#x}(n={old_rela_sz//RELAENT}) -> "
              f"{rela_vaddr:#x}(n={len(new_table)//RELAENT}) += RELATIVE off={bun_sec['addr']:#x} addend={new_off:#x}")
        size_note = (f"BUN_COMPILED.size left 0 pre-link, filled by ld.so "
                     f"relocation = load_bias + {new_off:#x}")

    # --- extend the writable PT_LOAD over everything appended ---
    new_filesz = append_end - load["offset"]
    new_memsz = max(old_memsz, new_filesz)
    struct.pack_into("<Q", out, load["hdr_off"] + 8 + 8 * 3, new_filesz)   # p_filesz
    struct.pack_into("<Q", out, load["hdr_off"] + 8 + 8 * 4, new_memsz)    # p_memsz

    print(f"[5/6] PT_LOAD extended: filesz {old_filesz:#x}->{new_filesz:#x} "
          f"memsz {old_memsz:#x}->{new_memsz:#x}")
    print(f"      blob: [{new_off:#x}, {new_off+len(blob):#x})  "
          f"(u64 len={len(payload)} @ {new_off:#x}; size-field target)")

    with open(args.out, "wb") as f:
        f.write(out)
    os.chmod(args.out, 0o755)
    print(f"[6/6] wrote {args.out} ({len(out)} B); {size_note}")

if __name__ == "__main__":
    main()
