#!/usr/bin/env python3
r"""patch-v1-replies.py — make v1's key parser drop concatenated terminal replies.

WHY (measured, not guessed)
    On Termux the v1 TUI writes a batch of capability probes at startup
    (OSC 10/11, DA1, DECRQM, XTVERSION, XTGETTCAP, CPR, window size) and the
    terminal answers them in one burst. opentui 0.4.5's `parseKeypress` guards
    every reply with an ANCHORED regex (`^...$`), e.g.

        if (/^\\x1b\\[\\?[\\d;]+c$/.test(s)) return null;          // DA1
        if (/^\\x1b\\][\\d;].*(\\x1b\\\\|\\x07)$/.test(s)) return null; // OSC

    so a single reply is swallowed correctly — but a read that contains TWO OR
    MORE replies matches none of them, falls through the whole function, and
    comes back as a key whose `sequence` is the raw blob. The textarea then
    renders it:

        ^[]10;rgb:c5c5/c8c8/c6c6^G ^[[?1016;0$y ^[P0+r4d73^[\ ...

    Mouse reports lose their `ESC[<` prefix the same way, so clicks arrive as
    text like `0;108;22M` and the TUI is unusable ("只显示不能操作").

WHAT
    Insert one guard at the very top of parseKeypress: if the string carries
    more than one ESC, it is a reply batch (or a paste), not a keystroke — drop
    it. Single keys, arrow keys and bracketed paste (ESC[200~ ... which is
    handled before this point by the paste path) are unaffected.

Gates:
    * exactly ONE insertion point (anchor) in the chunk
    * idempotent (marker present -> skip)
    * the anchored per-reply guards stay untouched (they still cover the
      single-reply case)

Usage: patch-v1-replies.py <chunk-*.js>
"""
import re
import sys

ANCHOR = re.compile(
    r"(parseKeypress\s*=\s*\(\s*s\s*=\s*\"\",\s*options\s*=\s*\{\}\s*\)\s*=>\s*\{)"
)
MARKER = "OT_DROP_REPLY_BATCH"
# `let` inside a block: the bundle is ESM (strict mode), an undeclared
# assignment would throw ReferenceError at runtime.
GUARD = '{let _otE=String(s).match(/\\x1b/g);if(_otE!==null&&_otE.length>1)return null;}'


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    src = open(path, encoding="utf-8", errors="surrogateescape").read()

    if MARKER in src:
        print(f"already patched ({MARKER} present) — skip")
        return 0

    hits = ANCHOR.findall(src)
    if len(hits) != 1:
        print(
            f"ERR: expected exactly 1 parseKeypress anchor in {path}, found {len(hits)} "
            f"— upstream chunk drifted, refusing to patch",
            file=sys.stderr,
        )
        return 1

    out = ANCHOR.sub(
        lambda m: m.group(1) + f'/*{MARKER}*/' + GUARD, src, count=1
    )

    # Post-conditions
    if MARKER not in out:
        print("ERR: patch did not land", file=sys.stderr)
        return 1
    if out.count("parseKeypress") != src.count("parseKeypress"):
        print("ERR: patch disturbed other parseKeypress references", file=sys.stderr)
        return 1
    # The single-reply guards must survive: they are still the primary defence.
    for needle in ("\\$y$", "[Mm]$", "\\x1b\\]\\[\\d;\\]"):
        if needle not in out and needle in src:
            print(f"ERR: existing reply guard '{needle}' disappeared", file=sys.stderr)
            return 1

    open(path, "w", encoding="utf-8", errors="surrogateescape").write(out)
    print("patched: parseKeypress drops multi-ESC reply batches (%s)" % MARKER)
    return 0


if __name__ == "__main__":
    sys.exit(main())
