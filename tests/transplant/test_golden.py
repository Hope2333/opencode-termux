#!/usr/bin/env python3
"""test_golden.py — golden-file regression for the transplant pipeline.

Reads tests/transplant/golden/<ver>/expected.sha256 and asserts the current
artifact artifacts/transplant/<ver>/opencode-native hashes identically.

Golden versions (both layout families covered):
  1.2.9, 1.3.11, 1.3.13  — real 52B-record products (layout family 52)
  synth-36b              — synthetic 36B-record fixture converted to 52B
                           (conversion path; built from a real fixture's
                           host-bun + string data + 20 synthetic records)

If an artifact is missing it is rebuilt from the local fixture tgz
(--fixtures-dir, no network). Run scripts/fetch-fixtures.sh first to
populate tests/transplant/fixtures/tgz/.

Exit 0 when every golden matches; exit 1 otherwise. Failure messages
always include the version name.
"""

import argparse
import hashlib
import io
import json
import struct
import subprocess
import sys
import tarfile
from pathlib import Path

TRAILER = b"\n---- Bun! ----\n"
TRAILER_LEN = len(TRAILER)  # 16
OFFSETS_LEN = 32
TAIL_LEN = 8
RECORD_36 = 36
RECORD_52 = 52
SYNTH_RECORDS = 20  # synthetic 36B fixture record count (todo 5 method)
SYNTH_VER = "synth-36b"
SYNTH_SOURCE_VER = "1.3.13"  # real fixture providing host-bun + string data

REPO = Path(__file__).resolve().parent.parent.parent
GOLDEN_DIR = REPO / "tests" / "transplant" / "golden"
ARTIFACT_ROOT = REPO / "artifacts" / "transplant"
TRANSPLANT_PY = REPO / "tools" / "transplant" / "transplant.py"
DEFAULT_FIXTURES = REPO / "tests" / "transplant" / "fixtures" / "tgz"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_offsets(data: bytes) -> dict:
    """Locate trailer + Offsets block; return parsed layout fields."""
    ts = len(data) - TAIL_LEN - TRAILER_LEN
    if ts < 0 or data[ts : ts + TRAILER_LEN] != TRAILER:
        raise ValueError(
            f"standalone trailer {TRAILER!r} not found at EOF-8-16 "
            f"(file_size={len(data)})"
        )
    o = ts - OFFSETS_LEN
    byte_count, mod_off, mod_len, entry, argv0, argv1, flags = (
        struct.unpack_from("<QIIIIII", data, o)
    )
    module_graph_size = byte_count + OFFSETS_LEN + TRAILER_LEN
    host_bun_size = len(data) - TAIL_LEN - module_graph_size
    if host_bun_size < 0:
        raise ValueError(f"module graph size {module_graph_size} exceeds file size")
    return {
        "byte_count": byte_count,
        "mod_off": mod_off,
        "mod_len": mod_len,
        "entry": entry,
        "argv0": argv0,
        "argv1": argv1,
        "flags": flags,
        "host_bun_size": host_bun_size,
        "module_graph_size": module_graph_size,
    }


def build_synthetic_binary(src_data: bytes) -> bytes:
    """Synthetic 36B-layout standalone binary (todo 5 method).

    Real host-bun + real string data + 20 synthetic 36B records
    (4 StringPointers + 4 u8 each) + real argv string + recomputed
    valid Offsets + trailer + tail. Never execve'd (records are bogus);
    used only to exercise the 36B -> 52B conversion path deterministically.
    """
    p = parse_offsets(src_data)
    gs = p["host_bun_size"]
    string_data = src_data[gs : gs + p["mod_off"]]
    argv_str = src_data[gs + p["argv0"] : gs + p["byte_count"]]
    host_bun = src_data[:gs]

    # 36B record: 4 StringPointers (offset u32, length u32) + 4 u8 flags.
    # Pointers point at string_data offset 0 (well-formed, never dereferenced).
    record = struct.pack("<IIII", 0, 0, 0, 0) * 4 + bytes(4)
    records = record * SYNTH_RECORDS

    new_mod_len = RECORD_36 * SYNTH_RECORDS
    new_argv0 = p["mod_off"] + new_mod_len
    new_byte_count = p["mod_off"] + new_mod_len + len(argv_str)
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
    new_mg = string_data + records + argv_str + new_offsets + TRAILER
    new_binary = host_bun + new_mg + struct.pack("<Q", len(host_bun) + len(new_mg) + TAIL_LEN)
    return new_binary


def write_tgz(binary: bytes, out_path: Path) -> None:
    """Package a standalone binary as npm-style tgz (package/bin/opencode)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    info = tarfile.TarInfo("package/bin/opencode")
    info.size = len(binary)
    info.mode = 0o755
    with tarfile.open(out_path, "w:gz") as tf:
        tf.addfile(info, io.BytesIO(binary))


def run_transplant(ver: str, tgz: Path, no_execve: bool = False) -> None:
    cmd = [sys.executable, str(TRANSPLANT_PY), "all", "--ver", ver, "--tgz", str(tgz)]
    if no_execve:
        cmd.append("--no-execve")
    subprocess.run(cmd, check=True, capture_output=True, text=True)


def rebuild_artifact(ver: str, fixtures_dir: Path) -> None:
    """Rebuild a missing artifact from local fixtures (no network)."""
    if ver == SYNTH_VER:
        src_tgz = fixtures_dir / f"opencode-linux-arm64-{SYNTH_SOURCE_VER}.tgz"
        if not src_tgz.is_file():
            raise SystemExit(
                f"golden {ver}: source fixture {src_tgz} missing — "
                f"run scripts/fetch-fixtures.sh first"
            )
        with tarfile.open(src_tgz, "r:gz") as tf:
            member = next(
                m for m in tf.getmembers()
                if m.isfile() and m.name.endswith("/bin/opencode")
            )
            src_data = tf.extractfile(member).read()
        synth_tgz = fixtures_dir / f"opencode-linux-arm64-{ver}.tgz"
        write_tgz(build_synthetic_binary(src_data), synth_tgz)
        run_transplant(ver, synth_tgz, no_execve=True)
        return
    tgz = fixtures_dir / f"opencode-linux-arm64-{ver}.tgz"
    if not tgz.is_file():
        raise SystemExit(
            f"golden {ver}: fixture {tgz} missing — run scripts/fetch-fixtures.sh first"
        )
    run_transplant(ver, tgz)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--fixtures-dir",
        default=str(DEFAULT_FIXTURES),
        help="local fixture tgz dir (default: tests/transplant/fixtures/tgz)",
    )
    ap.add_argument(
        "--golden-dir",
        default=str(GOLDEN_DIR),
        help="golden baseline dir (default: tests/transplant/golden)",
    )
    args = ap.parse_args(argv)

    golden_dir = Path(args.golden_dir)
    fixtures_dir = Path(args.fixtures_dir)
    if not golden_dir.is_dir():
        print(f"FAIL: golden dir not found: {golden_dir}", file=sys.stderr)
        return 1

    versions = sorted(
        p.name for p in golden_dir.iterdir()
        if p.is_dir() and (p / "expected.sha256").is_file()
    )
    if not versions:
        print(f"FAIL: no golden versions under {golden_dir}", file=sys.stderr)
        return 1

    failures = []
    for ver in versions:
        expected = (golden_dir / ver / "expected.sha256").read_text().strip()
        artifact = ARTIFACT_ROOT / ver / "opencode-native"
        if not artifact.is_file():
            print(f"== {ver}: artifact missing, rebuilding from fixtures ==")
            try:
                rebuild_artifact(ver, fixtures_dir)
            except SystemExit as e:
                print(f"FAIL {ver}: {e}", file=sys.stderr)
                failures.append(ver)
                continue
        actual = sha256_file(artifact)
        if actual == expected:
            print(f"PASS {ver}: {actual}")
        else:
            print(
                f"FAIL {ver}: sha256 mismatch\n"
                f"  expected: {expected}\n"
                f"  actual:   {actual}",
                file=sys.stderr,
            )
            failures.append(ver)

    if failures:
        print(f"\n{len(failures)} golden(s) FAILED: {', '.join(failures)}", file=sys.stderr)
        return 1
    print(f"\nall {len(versions)} golden(s) PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())