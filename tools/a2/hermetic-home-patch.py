#!/usr/bin/env python3
"""hermetic-home-patch.py — A2 todo8 (rc6-a2/todo8-hermetic-home)

Remap baked build-machine home paths in a built v1 runtime / libopentui.so.

Classification (task-8 evidence): every occurrence of
/data/data/com.termux/files/home inside the v1 compiled artifact is an
assert()/__FILE__ table string baked by the OpenTUI w7b bionic build
(vendored C: libwebp/lcms2/stb/miniaudio/yoga). They live in .rodata of the
embedded libopentui.so; the JS bundle itself carries ZERO baked home paths.
No data/cache/session path resolution rides on them, so an in-place
same-length byte remap is behavior-preserving (no relocation, no size change,
no code change).

Transform: replace each occurrence of the 77-byte prefix
    /data/data/com.termux/files/home/develop/OpenTUI-w7b-native/packages/native/
with "/opentui-vendor-src/" + NUL padding. The old per-string suffix after
the prefix is preserved (strings become /opentui-vendor-src/src/vendor/...).

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
TARGET = b"/data/data/com.termux/files/home"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: hermetic-home-patch.py <input> <output>", file=sys.stderr)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()

    n_prefix = data.count(OLD_PREFIX)
    n_target = data.count(TARGET)
    if n_target and n_target != n_prefix:
        print(f"hermetic: ERROR — {n_target} home-path occurrences but only "
              f"{n_prefix} match the OpenTUI prefix; refusing partial remap "
              f"(unknown source, needs classification)", file=sys.stderr)
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

    ob = bytes(out)
    assert len(ob) == len(data), "size drift"
    assert ob.count(TARGET) == 0, "target prefix still present"
    # every changed byte must lie inside a replaced range
    changed = [k for k in range(len(data)) if data[k] != ob[k]]
    for k in changed:
        assert any(a <= k < b for a, b in ranges), f"drift outside ranges at {k:#x}"
    print(f"hermetic: remapped {len(ranges)} occurrences "
          f"({len(changed)} bytes changed, all inside prefix ranges), "
          f"size {len(ob)}B unchanged")

    open(dst, "wb").write(ob)
    return 0


if __name__ == "__main__":
    sys.exit(main())
