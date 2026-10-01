#!/usr/bin/env python3
"""relax_tlsdesc.py — offline TLSDESC→Initial-Exec relaxation for libopentui.so.

Why (task-1 adjudication, .omo/evidence/rc6-b2-upx-tui/task-1-jsc.txt):
  zig 0.16 hardcodes threadlocal IR mode = .generaldynamic (src/codegen/llvm.zig
  calls setThreadLocal(.generaldynamic) at both sites), and LLVM's AArch64 backend
  lowers the GeneralDynamic model to TLSDESC *unconditionally* ("AArch64 enables
  TLSDESC regardless of this value" — llvm CodeGenOptions.def). zig exposes no
  TLS-model flag for its own code, and LLD relaxes TLSDESC→IE only when linking
  executables (lld/ELF/Relocations.cpp: execOptimize = !ctx.arg.shared && ...).
  Result: every zig-built aarch64 .so carries R_AARCH64_TLSDESC dynamic relocs,
  which bionic < 11 does not process → descriptor resolver stays NULL →
  `blr x1` → pc=0 → SIGSEGV SEGV_MAPERR@0x0 (Thread.maybeAttachSignalStack,
  vaddr 0x2ae538 in the Sep-26 build).

What this does (replicates LLD AArch64::relaxTlsGdToIe, offline, on the FINAL
linked .so — the exact transform LLD would apply when linking an executable):
  TLSDESC access sequence (fixed x0/x1 ABI, adjacent, unscheduled):
      adrp  x0, :tlsdesc:v          [R_AARCH64_TLSDESC_ADR_PAGE21]
      ldr   x1, [x0, #:tlsdesc_lo12:v]
      add   x0, x0, #:tlsdesc_lo12:v
      blr   x1                      [R_AARCH64_TLSDESC_CALL]
  becomes Initial-Exec:
      adrp  x0, :gottprel:v         (same page — slot address unchanged)
      ldr   x0, [x0, #:gottprel_lo12:v]   (only Rt: x1 → x0)
      nop
      nop
  and each dynamic reloc in .rela.dyn: R_AARCH64_TLSDESC (0x407)
                                   → R_AARCH64_TLS_TPREL64 (0x406).
  Reloc symbol/addend are kept: every TLSDESC entry here has sym=0 and
  addend = st_value of the TLS var (offset within the module's TLS block),
  which is exactly the TPREL GOT semantics (GOT entry = 0 + addend = tp-offset;
  bionic adds the module's TLS base). bionic 9 processes R_AARCH64_TLS_TPREL64
  (AOSP 9.0.0_r1 linker.cpp has the case — task-1 §3).

Usage:
  python3 relax_tlsdesc.py --binary <in.so> --out <out.so>
  python3 relax_tlsdesc.py --check <so>        # exit 0 = no TLSDESC relocs left
"""
import argparse
import struct
import sys

R_AARCH64_TLS_TPREL64 = 0x406
R_AARCH64_TLSDESC = 0x407
NOP = 0xD503201F

ADRP_X0_MASK = 0x9F000000  # adrp opcode bits (op=1, 10000)
ADRP_X0_OP = 0x90000000
BLR_X1 = 0xD63F0020


class Elf:
    def __init__(self, data: bytes):
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            raise ValueError("not a little-endian ELF64")
        self.data = bytearray(data)
        (self.e_shoff,) = struct.unpack_from("<Q", self.data, 0x28)
        (self.e_shentsize, self.e_shnum, self.e_shstrndx) = struct.unpack_from(
            "<HHH", self.data, 0x3A
        )
        self.sections = []
        for n in range(self.e_shnum):
            off = self.e_shoff + n * self.e_shentsize
            (
                name, typ, flags, addr, offset, size, link, info, align, entsize,
            ) = struct.unpack_from("<IIQQQQIIQQ", self.data, off)
            self.sections.append(
                dict(nameoff=name, typ=typ, flags=flags, addr=addr, offset=offset,
                     size=size, link=link, entsize=entsize)
            )
        shstr = self.sections[self.e_shstrndx]
        base = shstr["offset"]
        for s in self.sections:
            end = self.data.index(b"\x00", base + s["nameoff"])
            s["name"] = self.data[base + s["nameoff"]: end].decode()
        self.by_name = {s["name"]: s for s in self.sections}

    def exec_sections(self):
        # SHF_EXECINSTR = 0x4
        return [s for s in self.sections if s["flags"] & 0x4 and s["size"] > 0]


def find_tlsdesc_sites(code: bytes, sec_addr: int, slot: int):
    """Locate every 4-instruction TLSDESC access sequence computing `slot`.

    Sequence is adjacent and register-fixed (LLVM TLSDESC_CALLSEQ expansion):
        adrp x0, page(slot)   /  ldr x1,[x0,#lo12]  /
        add x0,x0,#lo12       /  blr x1
    """
    lo12 = slot & 0xFFF
    if lo12 & 7:
        raise ValueError(f"slot {slot:#x} not 8-aligned")
    t_ldr = 0xF9400001 | ((lo12 >> 3) << 10)  # ldr x1,[x0,#lo12] (Rt=1)
    t_add = 0x91000000 | (lo12 << 10)          # add x0,x0,#lo12
    page = slot & ~0xFFF
    hits = []
    n = len(code) // 4
    for i in range(n - 3):
        w0, w1, w2, w3 = struct.unpack_from("<IIII", code, i * 4)
        if w3 != BLR_X1 or w2 != t_add or w1 != t_ldr:
            continue
        if (w0 & ADRP_X0_MASK) != ADRP_X0_OP or (w0 & 0x1F) != 0:
            continue
        # decode adrp x0 target page at pc = sec_addr + i*4
        pc = sec_addr + i * 4
        immlo = (w0 >> 29) & 0x3
        immhi = (w0 >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= 1 << 21
        if (pc & ~0xFFF) + (imm << 12) != page:
            continue
        hits.append(i * 4)
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary")
    ap.add_argument("--out")
    ap.add_argument("--check")
    args = ap.parse_args()

    if args.check:
        data = open(args.check, "rb").read()
        elf = Elf(data)
        rd = elf.by_name.get(".rela.dyn")
        if rd is None:
            print("relax_tlsdesc: no .rela.dyn — nothing to check")
            return 0
        n = rd["size"] // 24
        left = 0
        for i in range(n):
            _, r_info, _ = struct.unpack_from("<QQq", elf.data, rd["offset"] + i * 24)
            if (r_info & 0xFFFFFFFF) == R_AARCH64_TLSDESC:
                left += 1
        if left:
            print(f"relax_tlsdesc: FAIL — {left} TLSDESC relocs remain in {args.check}")
            return 1
        print(f"relax_tlsdesc: OK — 0 TLSDESC relocs in {args.check}")
        return 0

    if not args.binary or not args.out:
        ap.error("need --binary/--out or --check")

    elf = Elf(open(args.binary, "rb").read())
    rd = elf.by_name.get(".rela.dyn")
    dynsym = elf.by_name.get(".dynsym")
    if rd is None or dynsym is None:
        print("relax_tlsdesc: .rela.dyn/.dynsym missing", file=sys.stderr)
        return 2

    exec_secs = elf.exec_sections()

    # Pass 1: collect TLSDESC dynamic relocs.
    n = rd["size"] // 24
    tlsdesc = []  # (file_off_of_rela, slot_vaddr, addend)
    for i in range(n):
        ro = rd["offset"] + i * 24
        r_off, r_info, r_add = struct.unpack_from("<QQq", elf.data, ro)
        if (r_info & 0xFFFFFFFF) == R_AARCH64_TLSDESC:
            sym = r_info >> 32
            if sym != 0:
                print(
                    f"relax_tlsdesc: UNSUPPORTED — TLSDESC reloc #{i} has symbol "
                    f"index {sym}; this relaxer handles sym=0/addend-only entries",
                    file=sys.stderr,
                )
                return 3
            tlsdesc.append((ro, r_off, r_add))
    if not tlsdesc:
        print("relax_tlsdesc: no TLSDESC relocs — nothing to do")
        open(args.out, "wb").write(bytes(elf.data))
        return 0

    # Pass 2: find + rewrite each access sequence.
    total_sites = 0
    for ro, slot, addend in tlsdesc:
        hits = []
        for sec in exec_secs:
            if not (sec["addr"] <= slot < sec["addr"] + sec["size"] + 0x100000):
                continue  # cheap range prefilter
            code = bytes(elf.data[sec["offset"]: sec["offset"] + sec["size"]])
            for h in find_tlsdesc_sites(code, sec["addr"], slot):
                hits.append((sec, h))
        if not hits:
            print(
                f"relax_tlsdesc: FAIL — no access sequence found for slot "
                f"{slot:#x} (addend {addend:#x}); file left unmodified",
                file=sys.stderr,
            )
            return 4
        for sec, h in hits:
            base = sec["offset"] + h
            # adrp x0 (unchanged); ldr x1→x0; add→nop; blr x1→nop
            struct.pack_into("<I", elf.data, base + 4, 0xF9400000 | (((slot & 0xFFF) >> 3) << 10))
            struct.pack_into("<I", elf.data, base + 8, NOP)
            struct.pack_into("<I", elf.data, base + 12, NOP)
        total_sites += len(hits)
        # Pass 3: dynamic reloc type swap 0x407 → 0x406 (sym/addend kept).
        struct.pack_into("<Q", elf.data, ro + 8, R_AARCH64_TLS_TPREL64)

    open(args.out, "wb").write(bytes(elf.data))
    print(
        f"relax_tlsdesc: relaxed {len(tlsdesc)} TLSDESC relocs "
        f"({total_sites} code sites) → R_AARCH64_TLS_TPREL64; wrote {args.out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
