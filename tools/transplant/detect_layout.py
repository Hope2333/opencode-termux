#!/usr/bin/env python3
"""detect_layout.py — probe a standalone opencode binary for the embedded Bun
version and the module-graph record layout format (36B vs 52B records).

Input:  path to a standalone binary, or a .tgz (npm package) containing
        package/bin/opencode (auto-extracted to a temp file).
Output: single-line JSON report:
        {bun_version, layout, module_count, offsets, file_size,
         host_bun_size, module_graph_size}
Exit:   0 on success; non-zero with a stderr explanation on corrupt input
        (missing trailer, failed stride check, or unrecognized record size).

Layout algorithm (review-fixed):
  - trailer b"\\n---- Bun! ----\\n" (16 B) sits exactly 8 B before EOF
  - Offsets (32 B) immediately before the trailer:
        byte_count u64 @0, modules_ptr.offset u32 @8, modules_ptr.length u32 @12,
        entry_point_id u32 @16, argv u32 @20/24, flags u32 @28
  - module graph = [string data][module records][argv string][Offsets][trailer]
  - moduleGraphSize = byte_count + 32 + 16
  - hostBunSize     = fileSize - 8 - moduleGraphSize
  - records area    = [modOff, modOff + length)  (graph-relative)
  - stride check:   modOff + modLen == argv_off  (argv_off = Offsets.argv @20)
  - record size:    area % 36 == 0 -> 36 B (4 StringPointers + 3 u8 + 1 pad)
                    area % 52 == 0 -> 52 B (6 StringPointers + 4 u8)
  - module_count    = total number of records in the module graph
                      (area / record size)
"""
import io
import json
import re
import struct
import sys
import tarfile

TRAILER = b"\n---- Bun! ----\n"
TRAILER_LEN = len(TRAILER)  # 16
OFFSETS_LEN = 32
U64_LEN = 8
RECORD_36 = 36
RECORD_52 = 52


class CorruptInput(Exception):
    """Raised when the input does not look like a valid standalone binary."""


def load_bytes(path: str) -> bytes:
    """Read the input; if it is a gzip/tgz archive, extract package/bin/opencode."""
    with open(path, "rb") as f:
        head = f.read(2)
        f.seek(0)
        if head == b"\x1f\x8b":
            # npm tarball -> extract the standalone binary member
            with tarfile.open(fileobj=f, mode="r:gz") as tf:
                member = None
                for m in tf.getmembers():
                    if m.name.endswith("package/bin/opencode") and m.isfile():
                        member = m
                        break
                if member is None:
                    raise CorruptInput(
                        f"tgz {path!r} has no package/bin/opencode member"
                    )
                return tf.extractfile(member).read()
        return f.read()


def find_trailer(data: bytes) -> int:
    """Trailer must sit exactly 8 B before EOF (standalone format invariant)."""
    ts = len(data) - U64_LEN - TRAILER_LEN
    if ts >= 0 and data[ts : ts + TRAILER_LEN] == TRAILER:
        return ts
    return -1


def parse_offsets(data: bytes, trailer_pos: int):
    o = trailer_pos - OFFSETS_LEN
    byte_count = struct.unpack_from("<Q", data, o + 0)[0]
    mod_off = struct.unpack_from("<I", data, o + 8)[0]
    mod_len = struct.unpack_from("<I", data, o + 12)[0]
    entry = struct.unpack_from("<I", data, o + 16)[0]
    argv0 = struct.unpack_from("<I", data, o + 20)[0]
    argv1 = struct.unpack_from("<I", data, o + 24)[0]
    flags = struct.unpack_from("<I", data, o + 28)[0]
    return byte_count, mod_off, mod_len, entry, argv0, argv1, flags


def probe_bun_version(host_bun: bytes):
    """Search the hostBun region for an embedded Bun version string."""
    for pat in (rb"bun-v(\d+\.\d+\.\d+)", rb"Bun v(\d+\.\d+\.\d+)"):
        m = re.search(pat, host_bun)
        if m:
            return m.group(1).decode("ascii")
    return None


def detect(data: bytes) -> dict:
    fs = len(data)
    ts = find_trailer(data)
    if ts < 0:
        raise CorruptInput(
            f"standalone trailer {TRAILER!r} not found at EOF-8-16 "
            f"(file_size={fs})"
        )

    byte_count, mod_off, mod_len, entry, argv0, argv1, flags = parse_offsets(
        data, ts
    )
    module_graph_size = byte_count + OFFSETS_LEN + TRAILER_LEN
    host_bun_size = fs - U64_LEN - module_graph_size
    if host_bun_size < 0:
        raise CorruptInput(
            f"module graph size {module_graph_size} exceeds file size {fs}"
        )
    graph_start = host_bun_size

    mod_off_abs = graph_start + mod_off
    mod_end_abs = mod_off_abs + mod_len
    argv_off_abs = graph_start + argv0

    # stride check: records area must end exactly where the argv string begins
    if mod_end_abs != argv_off_abs:
        raise CorruptInput(
            f"stride check failed: modOff+modLen={mod_end_abs} "
            f"!= argv_off={argv_off_abs} (graph_start={graph_start}, "
            f"mod_off={mod_off}, mod_len={mod_len}, argv0={argv0})"
        )

    area = mod_len
    if area % RECORD_36 == 0 and area % RECORD_52 != 0:
        layout = RECORD_36
    elif area % RECORD_52 == 0:
        layout = RECORD_52
    else:
        raise CorruptInput(
            f"record area {area} B divisible by neither 36 nor 52"
        )

    # module_count = total records in the module graph (area / record size).
    # Empirically: 1.2.x series has 19 records (988/52), 1.3.13 has 554
    # (28808/52). The task brief's "19 modules" for 1.2.x equals this total.
    module_count = area // layout

    bun_version = probe_bun_version(data[:host_bun_size])

    return {
        "bun_version": bun_version,
        "layout": layout,
        "module_count": module_count,
        "offsets": {
            "byte_count": byte_count,
            "modules_ptr": {"offset": mod_off, "length": mod_len},
            "argv": [argv0, argv1],
            "flags": flags,
        },
        "file_size": fs,
        "host_bun_size": host_bun_size,
        "module_graph_size": module_graph_size,
    }


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <standalone-binary|package.tgz>", file=sys.stderr)
        return 2
    try:
        data = load_bytes(argv[1])
        report = detect(data)
    except (CorruptInput, OSError, tarfile.TarError, struct.error) as e:
        print(f"detect_layout: error: {e}", file=sys.stderr)
        return 1
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
