#!/usr/bin/env python3
"""test_swap_pty.py — self-check for tools/transplant/swap_pty.py.

Synthetic fixtures only (no product binary, no network):

  * find_pty_asset() must locate the real bunfs asset (marker name + raw ELF)
    and ignore the same marker string when it appears inside bundled JS
  * elf_extent() must return the section-header-table end (what bun extracts)
  * is_glibc_linked() / check_replacement() must reject the upstream glibc
    librust_pty and any replacement missing the 8 bun_pty_* FFI exports
  * an end-to-end swap on the synthetic binary must yield a bionic slot,
    zero-padded to the exact original extent

Exit 0 when every check passes; exit 1 otherwise.
"""
import struct
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools" / "transplant"))

import swap_pty  # noqa: E402

FFI = swap_pty.FFI_SYMBOLS


def make_elf(payload: bytes = b"") -> bytes:
    """Minimal aarch64 ELF with one PT_LOAD and no section headers."""
    ehsize, phentsize = 64, 56
    phoff = ehsize
    body = b"\x00" * (phentsize) + payload
    e_ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\x00" * 8
    hdr = e_ident + struct.pack(
        "<HHIQQQIHHHHHH",
        3, 183, 1,      # e_type=ET_DYN, e_machine=EM_AARCH64, e_version
        0, phoff, 0,    # e_entry, e_phoff, e_shoff (0 => no section table)
        0, ehsize, phentsize, 1, 0, 0, 0,
    )
    ph = struct.pack(
        "<IIQQQQQQ",
        1, 5,           # PT_LOAD, PF_R|PF_X
        phoff, 0, 0,
        phentsize + len(payload), phentsize + len(payload), 0x1000,
    )
    return hdr + ph + payload


def glibc_pty_body() -> bytes:
    return b"".join(b"".join([s, b"\x00"]) for s in FFI) + (
        b"libpthread.so.0\x00libc.so.6\x00libdl.so.2\x00libutil.so.1\x00"
    )


def bionic_pty_body() -> bytes:
    return b"".join(b"".join([s, b"\x00"]) for s in FFI) + (
        b"libc.so\x00libdl.so\x00"
    )


def build_fake_binary(glibc: bytes, bionic: bytes) -> bytes:
    """JS decoy + real glibc asset + a bionic payload sitting later in the file."""
    decoy = b'\x00/$bunfs/root/librust_pty_arm64-decoy.so"\x00NOTELF'
    return (
        b"FAKE-BUN-HEADER\x00"
        + decoy
        + b"\x00/$bunfs/root/librust_pty_arm64-kkpzdzzv.so\x00"
        + glibc
        + b"TRAILER"
        + bionic
    )


def main() -> int:
    failures = []

    def check(name, cond, detail=""):
        if cond:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} {detail}")
            failures.append(name)

    glibc = make_elf(glibc_pty_body())
    bionic = make_elf(bionic_pty_body())
    binary = build_fake_binary(glibc, bionic)

    off, extent, name = swap_pty.find_pty_asset(binary)
    check("find_pty_asset ignores JS decoy", name.endswith(b".so"))
    check("find_pty_asset finds real GLIBC asset",
          swap_pty.is_glibc_linked(binary[off:off + extent]))
    check("elf_extent == synthetic size", extent == len(glibc),
          f"{extent} != {len(glibc)}")

    # consolidated-registry layout (bun >= 1.4.2): the name table sits apart
    # from the payload, so only the bun_pty_* symbol fallback can find it.
    consolidated = (
        b"FAKE-REGISTRY-TABLE\x00/$bunfs/root/librust_pty_arm64-abc.so\x00" + glibc
    )
    consolidated = consolidated.replace(
        b"\x00/$bunfs/root/librust_pty_arm64-abc.so\x00", b"|REGISTRY|")
    try:
        off2, extent2, _ = swap_pty.find_pty_asset(consolidated)
        check("find_pty_asset consolidated-registry fallback",
              swap_pty.is_glibc_linked(consolidated[off2:off2 + extent2]))
    except swap_pty.SwapError as e:
        check("find_pty_asset consolidated-registry fallback", False, str(e))

    # check_replacement gates
    for bad_name, bad in (("glibc", glibc), ("no-ffi", make_elf(b"libc.so\x00"))):
        try:
            swap_pty.check_replacement(bad)
            check(f"check_replacement rejects {bad_name}", False)
        except swap_pty.SwapError:
            check(f"check_replacement rejects {bad_name}", True)
    try:
        swap_pty.check_replacement(bionic)
        check("check_replacement accepts bionic", True)
    except swap_pty.SwapError as e:
        check("check_replacement accepts bionic", False, str(e))

    # end-to-end swap on a temp copy
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "product"
        lib = Path(td) / "bionic.so"
        src.write_bytes(binary)
        lib.write_bytes(bionic)
        sys.argv = ["swap_pty.py", "--binary", str(src),
                    "--pty-lib", str(lib), "--out", str(src)]
        try:
            swap_pty.main()
            patched = src.read_bytes()
            check("swap rewrites slot to bionic",
                  not swap_pty.is_glibc_linked(patched[off:off + extent]))
            check("swap keeps file length",
                  len(patched) == len(binary))
        except SystemExit as e:
            check("swap rewrites slot to bionic", False, f"exit {e.code}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASS: swap_pty self-check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
