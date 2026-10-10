#!/usr/bin/env bats
# Unit tests for tools/transplant/revive_patch.py on a minimal ELF shaped like
# an android Bun base: one RW PT_LOAD [0, 0x200) whose .bss reaches 0x8000,
# with .shstrtab, a non-zero .symtab and the section header table stored right
# after the segment, inside the .bss range (as every official android Bun
# 1.3.14 - 1.4.3 does).

load '../lib/helper'

setup() {
	make_tmpdir
	REVIVE="$(script_path tools/transplant/revive_patch.py)"
	python3 - "$TEST_TMPDIR" <<'PY'
import struct, sys
d = sys.argv[1]
names = b"\0.bun\0.shstrtab\0.symtab\0"
symtab = b"\xaa" * 64
shstrtab_off, symtab_off = 0x200, 0x200 + len(names)
shoff = (symtab_off + len(symtab) + 7) & ~7
out = bytearray(shoff + 4 * 64)
out[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
struct.pack_into("<HHIQQQIHHHHHH", out, 16, 3, 183, 1, 0, 64, shoff, 0, 64, 56, 1, 64, 4, 2)
struct.pack_into("<IIQQQQQQ", out, 64, 1, 6, 0, 0, 0, 0x200, 0x8000, 0x10000)
out[0x110:0x11a] = b"Bun v1.4.3"
out[shstrtab_off:shstrtab_off + len(names)] = names
out[symtab_off:symtab_off + len(symtab)] = symtab
for i, (name, kind, flags, addr, off, size) in enumerate([
    (0, 0, 0, 0, 0, 0),
    (1, 1, 3, 0x100, 0x100, 8),
    (6, 3, 0, 0, shstrtab_off, len(names)),
    (16, 2, 0, 0, symtab_off, len(symtab)),
]):
    struct.pack_into("<IIQQQQIIQQ", out, shoff + i * 64, name, kind, flags, addr, off, size, 0, 0, 8, 0)
open(f"{d}/bun", "wb").write(out)
open(f"{d}/graph.bin", "wb").write(b"/$bunfs/root/x.js" + bytes(32) + b"\n---- Bun! ----\n")
PY
}

teardown() {
	clean_tmpdir
}

graft() {
	run python3 "$REVIVE" --bun "$TEST_TMPDIR/bun" --graph "$TEST_TMPDIR/graph.bin" \
		--out "$TEST_TMPDIR/out"
	[ "$status" -eq 0 ]
}

@test "old .bss extent maps as zeros after the graft" {
	graft
	run python3 - "$TEST_TMPDIR/out" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
payload = struct.unpack_from("<Q", b, 0x100)[0]
assert payload >= 0x8000, hex(payload)
assert not any(b[0x200:payload]), "base bytes left inside the old .bss extent"
PY
	[ "$status" -eq 0 ]
}

@test "section headers and .symtab survive outside the mapped range" {
	graft
	run python3 - "$TEST_TMPDIR/out" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
filesz = struct.unpack_from("<Q", b, 64 + 32)[0]
shoff = struct.unpack_from("<Q", b, 0x28)[0]
assert shoff >= filesz
sec = {}
for i in range(4):
    name, _, _, addr, off, size = struct.unpack_from("<IIQQQQ", b, shoff + i * 64)
    sec[name] = (addr, off, size)
assert b[sec[6][1]:sec[6][1] + 5] == b"\0.bun"
assert sec[1][:2] == (0x100, 0x100)
_, off, size = sec[16]
assert off >= filesz and b[off:off + size] == b"\xaa" * 64
PY
	[ "$status" -eq 0 ]
}
