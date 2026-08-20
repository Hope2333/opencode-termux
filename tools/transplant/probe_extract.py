#!/usr/bin/env python3
"""probe_extract.py — Extract the standalone module graph from an opencode-linux-arm64 binary.

Standalone Bun format (guysoft scripts/build-opencode-android.ts Step 4, empirically verified):
    [bun binary][module_graph][u64 LE total_byte_count = file size]

Layout details:
    - trailer b"\\n---- Bun! ----\\n" (16 B) sits exactly 8 B before EOF
    - the 32 B before the trailer are Offsets:
        byte_count      u64 LE @ 0
        modules_ptr.offset u32 @ 8
        modules_ptr.length u32 @ 12
        entry_point_id  u32 @ 16
        compile_exec_argv u32 @ 20 / 24
        flags           u32 @ 28
    - moduleGraphSize = byte_count + 32 + 16
    - hostBunSize     = fileSize - 8 - moduleGraphSize
    - module graph slice = [hostBunSize, fileSize - 8)

Zero third-party dependencies: python3 stdlib only.
"""

import argparse
import struct
import sys
from pathlib import Path

TRAILER = b"\n---- Bun! ----\n"
TRAILER_LEN = len(TRAILER)  # 16
OFFSETS_LEN = 32
TAIL_LEN = 8  # trailing u64 total byte count


def die(msg: str) -> None:
    print(f"probe_extract: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def extract(tgz: Path, ver: str, out_dir: Path) -> dict:
    import tarfile

    if not tgz.is_file():
        die(f"tgz not found: {tgz}")

    # Locate the ELF inside the tarball without extracting to disk.
    elf_member = None
    with tarfile.open(tgz, "r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile() and m.name.endswith("/bin/opencode"):
                elf_member = m
                break
        if elf_member is None:
            die(f"no package/bin/opencode member in {tgz}")
        f = tf.extractfile(elf_member)
        if f is None:
            die(f"cannot read member {elf_member.name}")
        data = f.read()

    file_size = len(data)
    if file_size < TRAILER_LEN + OFFSETS_LEN + TAIL_LEN:
        die(f"binary too small ({file_size} B) to contain standalone trailer")

    # Trailer must sit exactly 8 B before EOF.
    expected_trailer_start = file_size - TAIL_LEN - TRAILER_LEN
    if data[expected_trailer_start:expected_trailer_start + TRAILER_LEN] != TRAILER:
        die(
            f"trailer not found at offset {expected_trailer_start} "
            f"(expected {TRAILER!r}, got {data[expected_trailer_start:expected_trailer_start + TRAILER_LEN]!r})"
        )

    offsets_start = expected_trailer_start - OFFSETS_LEN
    (byte_count,) = struct.unpack_from("<Q", data, offsets_start + 0)
    (mod_ptr_offset,) = struct.unpack_from("<I", data, offsets_start + 8)
    (mod_ptr_length,) = struct.unpack_from("<I", data, offsets_start + 12)
    (entry_point_id,) = struct.unpack_from("<I", data, offsets_start + 16)
    (argv0,) = struct.unpack_from("<I", data, offsets_start + 20)
    (argv1,) = struct.unpack_from("<I", data, offsets_start + 24)
    (flags,) = struct.unpack_from("<I", data, offsets_start + 28)

    module_graph_size = byte_count + OFFSETS_LEN + TRAILER_LEN
    host_bun_size = file_size - TAIL_LEN - module_graph_size
    if host_bun_size <= 0 or module_graph_size <= 0:
        die(
            f"implausible sizes: hostBunSize={host_bun_size} moduleGraphSize={module_graph_size} "
            f"byteCount={byte_count}"
        )

    slice_start = host_bun_size
    slice_end = file_size - TAIL_LEN
    module_graph = data[slice_start:slice_end]
    if len(module_graph) != module_graph_size:
        die(
            f"slice length mismatch: expected {module_graph_size}, got {len(module_graph)}"
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "module-graph.bin"
    out_path.write_bytes(module_graph)

    return {
        "ver": ver,
        "file_size": file_size,
        "host_bun_size": host_bun_size,
        "module_graph_size": module_graph_size,
        "byte_count": byte_count,
        "mod_ptr_offset": mod_ptr_offset,
        "mod_ptr_length": mod_ptr_length,
        "entry_point_id": entry_point_id,
        "argv": (argv0, argv1),
        "flags": flags,
        "out_path": str(out_path),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    ap.add_argument("--tgz", required=True, help="path to opencode-linux-arm64-<ver>.tgz")
    ap.add_argument(
        "--out",
        default=None,
        help="output dir (default: artifacts/transplant/<ver> under repo root)",
    )
    args = ap.parse_args()

    tgz = Path(args.tgz)
    if args.out:
        out_dir = Path(args.out)
    else:
        # Repo root = two levels up from this script (tools/transplant/).
        repo_root = Path(__file__).resolve().parent.parent.parent
        out_dir = repo_root / "artifacts" / "transplant" / args.ver

    r = extract(tgz, args.ver, out_dir)

    print(f"hostBunSize={r['host_bun_size']}")
    print(f"moduleGraphSize={r['module_graph_size']}")
    print(f"byteCount={r['byte_count']}")
    print(f"Trailer verified at offset {r['file_size'] - TAIL_LEN - TRAILER_LEN}")
    print(f"module graph written: {r['out_path']} ({r['module_graph_size']} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())