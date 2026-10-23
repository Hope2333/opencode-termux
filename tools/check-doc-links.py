#!/data/data/com.termux/files/usr/bin/python3
"""check-doc-links.py — report dead relative links in docs/*.md.

Usage: check-doc-links.py [root]
  root defaults to <repo>/docs.

Only relative markdown links are checked (http(s), mailto and pure anchors are
ignored). Links inside fenced code blocks are skipped. Anchors (#fragment) are
stripped before the existence check. Exit 1 when any target is missing.
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs")

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def iter_md(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".md"):
                yield os.path.join(dirpath, name)


def scan(path):
    dead = []
    in_fence = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for m in LINK_RE.finditer(line):
                target = m.group(1).strip()
                if not target or target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                target = target.split("#", 1)[0]
                if not target:
                    continue
                resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
                if not os.path.exists(resolved):
                    dead.append((os.path.relpath(path, ROOT), lineno, target))
    return dead


def main():
    if not os.path.isdir(ROOT):
        print(f"Error: docs root not found: {ROOT}", file=sys.stderr)
        return 2
    total = 0
    for path in iter_md(ROOT):
        for rel, lineno, target in scan(path):
            print(f"DEAD {rel}:{lineno} -> {target}")
            total += 1
    if total:
        print(f"\ncheck-doc-links: {total} dead link(s)")
        return 1
    print("check-doc-links: 0 dead link(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
