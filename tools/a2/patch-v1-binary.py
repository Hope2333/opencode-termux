#!/usr/bin/env python3
"""patch-v1-binary.py — drop concatenated terminal-reply batches in a v1 binary.

WHY (measured on oscar, 2.2.5-era v1 1.19.4)
    The v1 TUI asks the terminal a batch of capability questions at startup
    (OSC 10/11, DA1, DECRQM, XTVERSION, XTGETTCAP, CPR, window size). Termux
    answers all of them in ONE burst, and opentui 0.4.5's reply guards are
    anchored (`^...$`), so a chunk holding two or more replies matches nothing
    and falls through as a key whose sequence is the raw blob — the textarea
    then renders `^[]10;rgb:...`, and mouse reports lose their `ESC[<` prefix,
    arriving as text like `0;108;22M`.

    The source-level fix (`tools/a2/patch-v1-replies.py`) inserts a
    "more than one ESC -> drop" guard. This script applies the same semantics
    to an ALREADY BUILT binary, because the JS bundle inside is plaintext and
    can be edited in place — but the bunfs manifest records exact file sizes, so
    the replacement must be byte-for-byte the same length.

HOW
    Take an existing per-reply guard and generalise it in place:

        if(/^\\x1b\\[\\d+;\\d+R$/.test(e))return null;            # CPR
      ->
        if(/\\x1b[^\\x1b]*\\x1b/.test(e))return null;            # any 2nd ESC

    Both spellings mean "a lone CPR reply"; the replacement also catches the
    concatenated case, and is padded with spaces to keep the length identical
    (whitespace between `)` and `return` is syntactically neutral).

Gates:
    * the anchor must occur exactly once
    * idempotent (already-generalised form -> skip)
    * output size == input size
    * the file still parses as ELF and the JS is still valid UTF-8 at the edit

Usage: patch-v1-binary.py <binary> [--check]
"""
import sys

ANCHOR = rb"if(/^\x1b\[\d+;\d+R$/.test(e))return null;"
REPLACEMENT = rb"if(/\x1b[^\x1b]*\x1b/.test(e))return null;"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    check_only = "--check" in sys.argv[2:]

    data = open(path, "rb").read()
    if REPLACEMENT in data and ANCHOR not in data:
        print(f"{path}: already patched — skip")
        return 0

    hits = data.count(ANCHOR)
    if hits != 1:
        print(
            f"ERR: expected exactly 1 CPR guard anchor in {path}, found {hits} "
            f"— bundle drifted, refusing to patch",
            file=sys.stderr,
        )
        return 1

    if len(REPLACEMENT) > len(ANCHOR):
        print("ERR: replacement is longer than the anchor", file=sys.stderr)
        return 1
    padded = REPLACEMENT + b" " * (len(ANCHOR) - len(REPLACEMENT))

    if check_only:
        print(f"{path}: patchable (anchor at {data.find(ANCHOR)})")
        return 0

    out = data.replace(ANCHOR, padded, 1)
    if len(out) != len(data):
        print("ERR: size changed — refusing to write", file=sys.stderr)
        return 1
    if out[:4] != b"\x7fELF":
        print("ERR: not an ELF after patch", file=sys.stderr)
        return 1

    open(path, "wb").write(out)
    print(
        f"patched {path}: CPR guard generalised to 'drop any 2nd ESC' "
        f"({len(ANCHOR)} bytes, offset {data.find(ANCHOR)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
