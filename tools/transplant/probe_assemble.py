#!/usr/bin/env python3
"""probe_assemble.py — Bind the official android Bun with the extracted module graph.

guysoft Step 6 (scripts/build-opencode-android.ts), empirically verified:
    [android bun bytes] + [module graph bytes] + [u64 LE = androidBunSize + mgLen + 8]

The trailing u64 is the total byte count of the assembled file (bun + graph + 8),
mirroring the standalone Bun trailer layout that probe_extract.py reads back.

Zero third-party dependencies: python3 stdlib only.
"""

import argparse
import re
import struct
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

BUN_URL = (
    "https://github.com/oven-sh/bun/releases/download/"
    "bun-v1.3.14/bun-linux-aarch64-android.zip"
)
ZIP_MEMBER = "bun-linux-aarch64-android/bun"
TAIL_LEN = 8  # trailing u64 total byte count

# Native module markers to inventory inside the module graph.
NATIVE_PATTERNS = [
    re.compile(rb"@opentui/[A-Za-z0-9._/-]+"),
    re.compile(rb"@parcel/[A-Za-z0-9._/-]+"),
    re.compile(rb"[A-Za-z0-9._/-]+\.node"),
    re.compile(rb"[A-Za-z0-9._/-]+\.so(?:\.[0-9]+)*"),
]


def die(msg: str) -> None:
    print(f"probe_assemble: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def download_bun(cache_dir: Path) -> Path:
    """Download + extract the official android Bun ELF (idempotent)."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    bun_elf = cache_dir / "bun"
    if bun_elf.is_file() and bun_elf.stat().st_size > 0:
        print(f"bun already present, skipping download: {bun_elf}")
        return bun_elf

    zip_path = cache_dir / "bun-linux-aarch64-android.zip"
    if not zip_path.is_file():
        print(f"downloading {BUN_URL}")
        urllib.request.urlretrieve(BUN_URL, zip_path)
    print(f"zip size: {zip_path.stat().st_size} B")

    with zipfile.ZipFile(zip_path) as zf:
        info = zf.getinfo(ZIP_MEMBER)
        with zf.open(info) as src, open(bun_elf, "wb") as dst:
            dst.write(src.read())
    bun_elf.chmod(0o755)
    print(f"bun ELF extracted: {bun_elf} ({bun_elf.stat().st_size} B)")
    return bun_elf


def assemble(bun_elf: Path, module_graph: Path, out_path: Path) -> int:
    """Concatenate bun + module graph + u64 LE total size; chmod 755."""
    bun_bytes = bun_elf.read_bytes()
    mg_bytes = module_graph.read_bytes()
    total = len(bun_bytes) + len(mg_bytes) + TAIL_LEN
    trailer = struct.pack("<Q", total)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(bun_bytes + mg_bytes + trailer)
    out_path.chmod(0o755)
    print(f"assembled: {out_path} ({out_path.stat().st_size} B)")
    print(f"  bun={len(bun_bytes)} B  module_graph={len(mg_bytes)} B  trailer={TAIL_LEN} B")
    return total


def verify_tail(out_path: Path, expected_total: int) -> None:
    """Self-check: last 8 B (u64 LE) must equal the file's total size."""
    data = out_path.read_bytes()
    (tail,) = struct.unpack_from("<Q", data, len(data) - TAIL_LEN)
    if tail != expected_total:
        die(f"tail mismatch: file size={len(data)} expected_total={expected_total} tail={tail}")
    print(f"ASSERT PASS: tail u64 LE ({tail}) == file size ({len(data)})")


def inventory_native(graph: Path, out_txt: Path) -> list:
    """Scan module graph for native module filename strings."""
    data = graph.read_bytes()
    found = set()
    for pat in NATIVE_PATTERNS:
        for m in pat.finditer(data):
            s = m.group(0).decode("utf-8", "replace")
            # Keep only plausible module paths (contain a separator or known prefix).
            if "/" in s or s.startswith(("@opentui", "@parcel")):
                found.add(s)
    ordered = sorted(found)
    out_txt.parent.mkdir(parents=True, exist_ok=True)
    out_txt.write_text("\n".join(ordered) + ("\n" if ordered else ""), encoding="utf-8")
    print(f"native modules: {len(ordered)} -> {out_txt}")
    for name in ordered:
        print(f"  {name}")
    return ordered


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--ver", default="1.3.13", help="opencode version (default: 1.3.13)"
    )
    ap.add_argument(
        "--bun-cache",
        default=None,
        help="cache dir for android bun (default: artifacts/transplant/android-bun)",
    )
    ap.add_argument(
        "--graph",
        default=None,
        help="module graph path (default: artifacts/transplant/<ver>/module-graph.bin)",
    )
    ap.add_argument(
        "--out",
        default=None,
        help="output dir (default: artifacts/transplant/<ver>)",
    )
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parent.parent.parent
    ver_dir = repo_root / "artifacts" / "transplant" / args.ver
    bun_cache = Path(args.bun_cache) if args.bun_cache else repo_root / "artifacts" / "transplant" / "android-bun"
    graph = Path(args.graph) if args.graph else ver_dir / "module-graph.bin"
    out_dir = Path(args.out) if args.out else ver_dir

    if not graph.is_file():
        die(f"module graph not found: {graph} (run probe_extract.py first)")

    bun_elf = download_bun(bun_cache)
    out_path = out_dir / "opencode-native"
    expected_total = assemble(bun_elf, graph, out_path)
    verify_tail(out_path, expected_total)

    # Local execve probe.
    print("--- execve probe ---")
    proc = subprocess.run(
        [str(out_path), "--version"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    print(f"exit code: {proc.returncode}")
    print(f"stdout: {proc.stdout.strip()!r}")
    if proc.stderr.strip():
        print(f"stderr: {proc.stderr.strip()!r}")

    # Native module inventory.
    native_txt = out_dir / "native-modules.txt"
    modules = inventory_native(graph, native_txt)

    print("--- summary ---")
    print(f"file: {out_path}")
    print(f"exit_code={proc.returncode} stdout={proc.stdout.strip()!r}")
    print(f"native_modules={len(modules)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())