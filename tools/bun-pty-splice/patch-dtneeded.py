#!/usr/bin/env python3
"""patch-dtneeded.py -- equal-length DT_NEEDED patch for musl librust_pty.

Replaces the single NUL-terminated b"libc.so" string (DT_NEEDED entry of the
musl-built bun-pty 0.4.11 arm64 lib) with b"shim.so" (same length, 7 bytes).
The shim exports every symbol the musl lib used to get from bionic-incompatible
musl libc (bcmp / __errno_location / __xpg_strerror_r / posix_spawn* family),
so the loader now binds the pty lib against shim.so instead of libc.so.

Safety: asserts exactly ONE occurrence of b"libc.so\\x00" in the input, and
that output length == input length (equal-length guarantee, byte offsets
unchanged so section/program headers stay valid).

Usage: patch-dtneeded.py <input.so> <output.so>
"""
import sys

OLD = b"libc.so\x00"
NEW = b"shim.so\x00"
assert len(OLD) == len(NEW), "patch must be equal-length"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()

    occ = []
    i = data.find(OLD)
    while i != -1:
        occ.append(i)
        i = data.find(OLD, i + 1)
    if len(occ) != 1:
        print(
            f"ERR: expected exactly 1 occurrence of {OLD!r}, found {len(occ)} "
            f"at offsets {occ} in {src} — refusing to patch",
            file=sys.stderr,
        )
        return 1

    off = occ[0]
    patched = data[:off] + NEW + data[off + len(OLD):]
    assert len(patched) == len(data), "post-patch length must be identical"

    with open(dst, "wb") as f:
        f.write(patched)

    # verify: written file has NEW at the same offset, no OLD left
    back = open(dst, "rb").read()
    assert back[off:off + len(NEW)] == NEW
    assert back.find(OLD) == -1
    print(f"patched: {OLD.decode().rstrip(chr(0))} -> {NEW.decode().rstrip(chr(0))} "
          f"at offset {off} ({len(data)} bytes, length unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
