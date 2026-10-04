#!/usr/bin/env python3
"""hermetic-home-patch.py — A2 todo8 (rc6-a2/todo8-hermetic-home)

Remap baked build-machine home paths in a built v1 runtime / libopentui.so.

Classification (task-8 evidence + task-16 t16-absorb classification): two
sources, both assert()/panic __FILE__ tables baked in the .rodata of embedded
native libs; the JS bundle itself carries ZERO baked home paths. No
data/cache/session path resolution rides on them, so an in-place same-length
byte remap is behavior-preserving (no relocation, no size change, no code
change). In-place byte edits inside bunfs-embedded assets are proven
behavior-preserving by the press3/press4 chain (libopentui remap + smoke).
  1. OpenTUI w7b bionic build (vendored C: libwebp/lcms2/stb/miniaudio/yoga),
     prefix /data/data/com.termux/files/home/develop/OpenTUI-w7b-native/...
  2. bionic librust_pty build (tools/bun-pty-embed, Termux cargo; rust panic
     locations in the embedded pty .so), prefix
     /data/data/com.termux/files/home/.cargo/registry/...

Transform:
  - replace each 77-byte OpenTUI prefix
    /data/data/com.termux/files/home/develop/OpenTUI-w7b-native/packages/native/
    with "/opentui-vendor-src/" + NUL padding.
  - replace each 49-byte cargo prefix
    /data/data/com.termux/files/home/.cargo/registry/
    with "/cargo-registry-src/" + NUL padding (trailing crate path preserved).

Idempotent. Hard assertions:
  - output size == input size
  - every changed byte lies inside a replaced prefix range
  - no "/data/data/com.termux/files/home" remains in the output
  - a subsequent re-run is a no-op

usage: hermetic-home-patch.py <input> <output>
"""
import sys

OLD_PREFIX = b"/data/data/com.termux/files/home/develop/OpenTUI-w7b-native/packages/native/"
NEW = b"/opentui-vendor-src/"
CARGO_PREFIX = b"/data/data/com.termux/files/home/.cargo/registry/"
CARGO_NEW = b"/cargo-registry-src/"
TARGET = b"/data/data/com.termux/files/home"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: hermetic-home-patch.py <input> <output>", file=sys.stderr)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()

    n_prefix = data.count(OLD_PREFIX)
    n_cargo = data.count(CARGO_PREFIX)
    n_target = data.count(TARGET)
    if n_target and n_target != n_prefix + n_cargo:
        print(f"hermetic: ERROR — {n_target} home-path occurrences but only "
              f"{n_prefix} OpenTUI + {n_cargo} cargo match known prefixes; "
              f"refusing partial remap (unknown source, needs classification)",
              file=sys.stderr)
        return 1

    if n_target == 0:
        open(dst, "wb").write(data)
        print("hermetic: already clean (0 occurrences) — copied verbatim")
        return 0

    out = bytearray(data)
    ranges = []
    pos = 0
    while True:
        i = data.find(OLD_PREFIX, pos)
        if i < 0:
            break
        out[i:i + len(OLD_PREFIX)] = NEW + b"\x00" * (len(OLD_PREFIX) - len(NEW))
        ranges.append((i, i + len(OLD_PREFIX)))
        pos = i + len(OLD_PREFIX)
    pos = 0
    while True:
        i = data.find(CARGO_PREFIX, pos)
        if i < 0:
            break
        out[i:i + len(CARGO_PREFIX)] = CARGO_NEW + b"\x00" * (len(CARGO_PREFIX) - len(CARGO_NEW))
        ranges.append((i, i + len(CARGO_PREFIX)))
        pos = i + len(CARGO_PREFIX)

    ob = bytes(out)
    assert len(ob) == len(data), "size drift"
    assert ob.count(TARGET) == 0, "target prefix still present"
    # every changed byte must lie inside a replaced range
    changed = [k for k in range(len(data)) if data[k] != ob[k]]
    for k in changed:
        assert any(a <= k < b for a, b in ranges), f"drift outside ranges at {k:#x}"
    print(f"hermetic: remapped {len(ranges)} occurrences "
          f"({n_prefix} opentui + {n_cargo} cargo, "
          f"{len(changed)} bytes changed, all inside prefix ranges), "
          f"size {len(ob)}B unchanged")

    open(dst, "wb").write(ob)
    return 0


if __name__ == "__main__":
    sys.exit(main())
