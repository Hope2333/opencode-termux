#!/usr/bin/env python3
"""patch-ffi-pointer.py — keep Android tagged pointers alive across the Bun FFI.

WHY
    Android 11+ (Bionic Scudo) tags heap pointers in the top byte
    (0xb4xxxxxxxxxxxxxx), so the value is > 2^53-1. opentui's
    `toSafeNumberPointer()` refuses anything above `Number.MAX_SAFE_INTEGER`
    and the TUI dies in `createContext` with
    "Pointer exceeds safe integer range" (issues #43 / #45 / #46).

    Stripping the tag is NOT an option: Scudo validates it on free()
    ("Pointer tag for 0x... was truncated"). Bun's FFI accepts BigInt for
    pointer arguments, so the safe fix is to hand the BigInt through instead
    of converting it to a Number.

WHAT
    `toSafeNumberPointer(pointer)` { if (>MAX_SAFE) throw } -> { return pointer }

    Behaviour is unchanged for every pointer that fits in 2^53 (all of
    Android <= 10 and most of 11+), so this cannot regress a working host; it
    only converts a hard crash into a code path that at least reaches the
    loader. Real-device confirmation on Android 11+ is tracked in the plan
    (todo 9) — this script is the code half of that fix.

Gates (all hard failures):
    * exactly ONE occurrence of the throw-anchor in the chunk
    * the result still contains the POINTER_UNSAFE constant (other call sites
      still need it) and no longer throws on the MAX_SAFE comparison
    * a marker string is injected so a built artifact can be identified

Usage: patch-ffi-pointer.py <chunk-bun-*.js>
"""
import re
import sys

ANCHOR = re.compile(
    r"if \(pointer > BigInt\(Number\.MAX_SAFE_INTEGER\)\) \{\s*"
    r"throw new Error\(POINTER_UNSAFE\);\s*\}",
    re.S,
)
REPLACEMENT = (
    "if (pointer > BigInt(Number.MAX_SAFE_INTEGER)) { "
    "return pointer; /* OT_PTR_BIGINT: bionic tagged pointer, bun FFI takes BigInt */ }"
)
MARKER = "OT_PTR_BIGINT"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    src = open(path, encoding="utf-8", errors="replace").read()

    # Idempotency first: a patched chunk no longer matches ANCHOR by design.
    if MARKER in src:
        print(f"already patched ({MARKER} present) — skip")
        return 0
    hits = ANCHOR.findall(src)
    if len(hits) != 1:
        print(
            f"ERR: expected exactly 1 pointer anchor in {path}, found {len(hits)} "
            f"— upstream chunk layout drifted, refusing to patch",
            file=sys.stderr,
        )
        return 1
    if "POINTER_UNSAFE" not in src:
        print(f"ERR: POINTER_UNSAFE constant missing in {path}", file=sys.stderr)
        return 1

    out = ANCHOR.sub(REPLACEMENT, src, count=1)

    # Post-conditions: the throw is gone, the constant survives for other sites.
    if ANCHOR.search(out):
        print("ERR: replacement did not take effect", file=sys.stderr)
        return 1
    if MARKER not in out or "POINTER_UNSAFE" not in out:
        print("ERR: post-patch invariants violated", file=sys.stderr)
        return 1

    open(path, "w", encoding="utf-8").write(out)
    print(f"patched: toSafeNumberPointer now returns BigInt for tagged pointers ({MARKER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
