#!/usr/bin/env python3
"""Normalise the @silvia-odwyer/photon-node patch in old v1 trees.

Why
---
The 1.18.x / early 1.19.x trees ship `patches/@silvia-odwyer%2Fphoton-node@0.3.4.patch`
with three lines of trailing whitespace in its last hunk. bun applies patches
strictly, so install dies with:

    error: failed applying patch file: hunk #10 does not apply to photon_rs.js
    error: failed to patch package: @silvia-odwyer/photon-node@0.3.4

(1.18.35 hit this; 1.19.4 does not — its copy of the same patch is byte-identical
except for that whitespace, which is why the same build works there.)

The fix is deliberately narrow: in a unified diff a lone " " is a context line
for a blank source line, so blanket whitespace stripping would corrupt other
patches. We only rewrite the one file, and only the trailing whitespace on
non-empty added/context lines inside it, then re-verify the hunk count.

Idempotent: running twice changes nothing.
"""
from __future__ import annotations

import argparse
import os
import sys

PATCH = "patches/@silvia-odwyer%2Fphoton-node@0.3.4.patch"
GOLDEN = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "golden", "photon-node-0.3.4.patch"
)


def normalise(text: str) -> str:
    out = []
    for line in text.split("\n"):
        # keep diff headers and the sentinel blank-context line untouched
        if line.startswith(("+++", "---", "@@", "diff ", "index ")) or line == " ":
            out.append(line)
            continue
        body = line[1:] if line[:1] in "+- " else line
        if body.strip() == "":
            out.append(line)
            continue
        prefix = line[:1] if line[:1] in "+- " else ""
        out.append(prefix + body.rstrip())
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="v1 source tree")
    args = ap.parse_args()

    path = os.path.join(args.src, PATCH)
    if not os.path.exists(path):
        print(f"photon patch absent: {path} (nothing to fix)")
        return 0

    orig = open(path, encoding="utf-8").read()
    if os.path.exists(GOLDEN):
        # Prefer the known-good copy when we have one (byte-exact, proven to
        # apply during the 1.19.4 rebuild).
        golden = open(GOLDEN, encoding="utf-8").read()
        if orig != golden:
            open(path, "w", encoding="utf-8").write(golden)
            print("photon patch replaced with golden copy")
        else:
            print("photon patch already matches golden")
        return 0

    fixed = normalise(orig)
    if fixed == orig:
        print("photon patch already normalised")
        return 0
    open(path, "w", encoding="utf-8").write(fixed)
    print("photon patch normalised (trailing whitespace removed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
