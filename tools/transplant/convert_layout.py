#!/usr/bin/env python3
"""convert_layout.py — convert a standalone opencode binary's module-graph
record layout between 36B and 52B records (or the reverse).

Standalone Bun format (empirically verified, see detect_layout.py):
    [host bun][module graph][u64 LE total byte count = file size]

Module graph layout (graph-relative offsets):
    [0, mod_off)                    string data
    [mod_off, mod_off + mod_len)    module records
    [mod_off + mod_len, byte_count) argv string
    [byte_count, byte_count + 32)   Offsets
    [byte_count + 32, byte_count + 48) trailer b"\\n---- Bun! ----\\n"

Record layouts:
    36B record = 4 StringPointers (32B) + 3 u8 + 1 pad
    52B record = 6 StringPointers (48B) + 4 u8
    (StringPointer = u32 offset + u32 length, 8 B; offsets point into the
     string-data area, which is untouched by the conversion)

Conversion algorithm (review-fixed, BLOCKER-2 resolved):
     36->52: keep 4 StringPointers, append 2 zero StringPointers,
             keep all 4 u8 (36B record stores 4 u8 at offsets 32-35) -> +16 B per record
     52->36: keep first 4 StringPointers, keep all 4 u8 (52B stores 4 u8 at 48-51)
            -> -16 B per record

Offsets updates:
    byte_count        += 16*n (36->52) / -= 16*n (52->36)
    modules_ptr.length = 52*n / 36*n
    argv.offset       += 16*n / -= 16*n   (argv1 = argv string length, unchanged)
The argv string, Offsets block and trailer shift by +/-16*n bytes (they sit
after the records area). The trailing u64 LE is rewritten to the new file
size.

Zero third-party dependencies: python3 stdlib only.
"""

import argparse
import struct
import sys
from pathlib import Path

TRAILER = b"\n---- Bun! ----\n"
TRAILER_LEN = len(TRAILER)  # 16
OFFSETS_LEN = 32
U64_LEN = 8
RECORD_36 = 36
RECORD_52 = 52
DELTA = RECORD_52 - RECORD_36  # 16


class CorruptInput(Exception):
    """Raised when the input does not look like a valid standalone binary."""


def parse(data: bytes) -> dict:
    """Locate trailer, parse Offsets, run stride check, classify layout."""
    fs = len(data)
    ts = fs - U64_LEN - TRAILER_LEN
    if ts < 0 or data[ts : ts + TRAILER_LEN] != TRAILER:
        raise CorruptInput(
            f"standalone trailer {TRAILER!r} not found at EOF-8-16 "
            f"(file_size={fs})"
        )

    o = ts - OFFSETS_LEN
    byte_count, mod_off, mod_len, entry, argv0, argv1, flags = (
        struct.unpack_from("<QIIIIII", data, o)
    )
    module_graph_size = byte_count + OFFSETS_LEN + TRAILER_LEN
    host_bun_size = fs - U64_LEN - module_graph_size
    if host_bun_size < 0:
        raise CorruptInput(
            f"module graph size {module_graph_size} exceeds file size {fs}"
        )
    graph_start = host_bun_size

    # stride check: records area must end exactly where the argv string begins
    if mod_off + mod_len != argv0:
        raise CorruptInput(
            f"stride check failed: modOff+modLen={mod_off + mod_len} "
            f"!= argv_off={argv0} (graph_start={graph_start}, "
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

    return {
        "fs": fs,
        "byte_count": byte_count,
        "mod_off": mod_off,
        "mod_len": mod_len,
        "entry": entry,
        "argv0": argv0,
        "argv1": argv1,
        "flags": flags,
        "module_graph_size": module_graph_size,
        "host_bun_size": host_bun_size,
        "graph_start": graph_start,
        "layout": layout,
        "n": area // layout,
    }


def convert_records(records: bytes, src: int, dst: int) -> bytes:
    """Rewrite the records area from src-byte records to dst-byte records."""
    if src == RECORD_36 and dst == RECORD_52:
        out = bytearray()
        for i in range(0, len(records), RECORD_36):
            rec = records[i : i + RECORD_36]
            out += rec[0:32]  # 4 StringPointers
            out += b"\x00" * 16  # 2 zero StringPointers
            out += rec[32:36]  # 4 u8 (36B record stores all 4 u8 at offsets 32-35)
        return bytes(out)
    # src == RECORD_52 and dst == RECORD_36
    out = bytearray()
    for i in range(0, len(records), RECORD_52):
        rec = records[i : i + RECORD_52]
        out += rec[0:32]  # first 4 StringPointers
        out += rec[48:52]  # 4 u8 (flags live at offset 48-51 in a 52B record)
    return bytes(out)


def convert(data: bytes, target: int) -> tuple[bytes, dict]:
    """Convert the whole standalone binary to the target record layout."""
    p = parse(data)
    if p["layout"] == target:
        raise CorruptInput(
            f"input already uses {target}B layout; nothing to convert"
        )

    n = p["n"]
    delta = DELTA * n if target == RECORD_52 else -DELTA * n
    gs = p["graph_start"]
    mg_end = gs + p["module_graph_size"]

    string_data = data[gs : gs + p["mod_off"]]
    records = data[gs + p["mod_off"] : gs + p["mod_off"] + p["mod_len"]]
    argv_str = data[gs + p["argv0"] : gs + p["byte_count"]]

    new_records = convert_records(records, p["layout"], target)
    new_mod_len = target * n
    new_argv0 = p["mod_off"] + new_mod_len
    new_byte_count = p["byte_count"] + delta
    new_offsets = struct.pack(
        "<QIIIIII",
        new_byte_count,
        p["mod_off"],
        new_mod_len,
        p["entry"],
        new_argv0,
        p["argv1"],
        p["flags"],
    )

    new_graph = string_data + new_records + argv_str + new_offsets + TRAILER
    new_total = p["host_bun_size"] + len(new_graph) + U64_LEN
    out = data[:gs] + new_graph + struct.pack("<Q", new_total)

    return out, {
        "src_layout": p["layout"],
        "dst_layout": target,
        "n": n,
        "delta": delta,
        "old_byte_count": p["byte_count"],
        "new_byte_count": new_byte_count,
        "old_mod_len": p["mod_len"],
        "new_mod_len": new_mod_len,
        "old_argv0": p["argv0"],
        "new_argv0": new_argv0,
        "old_file_size": p["fs"],
        "new_file_size": len(out),
    }


def main(argv) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("binary", help="path to the standalone opencode binary")
    ap.add_argument(
        "--to",
        required=True,
        choices=("36", "52"),
        help="target record layout (36 or 52)",
    )
    ap.add_argument(
        "--out",
        default=None,
        help="output path (default: <binary>.converted)",
    )
    args = ap.parse_args(argv[1:])

    target = RECORD_36 if args.to == "36" else RECORD_52
    src = Path(args.binary)
    if not src.is_file():
        print(f"convert_layout: ERROR: input not found: {src}", file=sys.stderr)
        return 2

    try:
        data = src.read_bytes()
        out, info = convert(data, target)
    except CorruptInput as e:
        print(f"convert_layout: ERROR: {e}", file=sys.stderr)
        return 1

    out_path = Path(args.out) if args.out else Path(str(src) + ".converted")
    out_path.write_bytes(out)
    out_path.chmod(0o755)

    print(f"converted {src} ({info['src_layout']}B) -> {out_path} ({info['dst_layout']}B)")
    print(f"  modules={info['n']}  delta={info['delta']:+d} B/record")
    print(f"  byte_count: {info['old_byte_count']} -> {info['new_byte_count']}")
    print(f"  mod_len:    {info['old_mod_len']} -> {info['new_mod_len']}")
    print(f"  argv0:      {info['old_argv0']} -> {info['new_argv0']}")
    print(f"  file_size:  {info['old_file_size']} -> {info['new_file_size']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))