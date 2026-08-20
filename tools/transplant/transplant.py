#!/usr/bin/env python3
"""transplant.py — unified CLI for the native-android transplant pipeline.

Integrates the standalone probes (probe_extract.py / detect_layout.py /
convert_layout.py / probe_assemble.py) into one argparse CLI:

    extract   tgz -> module-graph.bin + host-bun.bin
    detect    layout detection (36B vs 52B records) + bun version probe
    convert   36<->52 module-graph record conversion
    patch     equal-length string_data replacements from config/patches.json
    assemble  android Bun download + concatenation + execve probe
    verify    re-run execve asserting version string consistency
    all       one-shot pipeline: extract -> detect -> (convert if 36)
              -> patch -> assemble -> verify

Output: artifacts/transplant/<ver>/opencode-native + report.json
        {ver, layout, steps:{extract:{sha256}, detect:{...}, convert:{...},
         patch:{hit_count}, assemble:{sha256}, verify:{execve_result}}}

Zero third-party dependencies: python3 stdlib only.
"""

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
import tarfile
from pathlib import Path

# Reuse core logic from the standalone probes (same directory).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_extract import (  # noqa: E402
    TRAILER as PE_TRAILER,
    TRAILER_LEN,
    OFFSETS_LEN,
    TAIL_LEN,
)
from detect_layout import (  # noqa: E402
    load_bytes,
    detect as detect_layout,
    CorruptInput as DetectCorrupt,
)
from convert_layout import (  # noqa: E402
    convert_records,
    RECORD_36,
    RECORD_52,
    DELTA,
    CorruptInput as ConvertCorrupt,
)
from probe_assemble import (  # noqa: E402
    download_bun,
    assemble as assemble_binary,
    verify_tail,
)

DEFAULT_BUN_VERSION = "1.3.14"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")


class TransplantError(Exception):
    """Actionable pipeline error (message is printed to stderr, exit != 0)."""


def die(msg: str) -> None:
    print(f"transplant: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def ver_dir(ver: str) -> Path:
    return repo_root() / "artifacts" / "transplant" / ver


def config_dir() -> Path:
    return Path(__file__).resolve().parent / "config"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report_path(out_dir: Path) -> Path:
    return out_dir / "report.json"


def load_report(out_dir: Path) -> dict:
    p = report_path(out_dir)
    if not p.is_file():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def save_report(out_dir: Path, report: dict) -> Path:
    p = report_path(out_dir)
    p.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return p


def update_report(out_dir: Path, step: str, info: dict, layout=None) -> None:
    """Merge one step's info into the persistent report.json."""
    report = load_report(out_dir)
    report.setdefault("ver", out_dir.name)
    report.setdefault("steps", {})
    report["steps"][step] = info
    if layout is not None:
        report["layout"] = layout
    save_report(out_dir, report)


# ---------------------------------------------------------------- extract
def extract_step(tgz: Path, ver: str, out_dir: Path) -> dict:
    """tgz -> module-graph.bin + host-bun.bin (probe_extract core logic)."""
    if not tgz.is_file():
        raise TransplantError(f"tgz not found: {tgz}")

    elf_member = None
    with tarfile.open(tgz, "r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile() and m.name.endswith("/bin/opencode"):
                elf_member = m
                break
        if elf_member is None:
            raise TransplantError(f"no package/bin/opencode member in {tgz}")
        f = tf.extractfile(elf_member)
        if f is None:
            raise TransplantError(f"cannot read member {elf_member.name}")
        data = f.read()

    file_size = len(data)
    if file_size < TRAILER_LEN + OFFSETS_LEN + TAIL_LEN:
        raise TransplantError(
            f"binary too small ({file_size} B) to contain standalone trailer"
        )

    expected_trailer_start = file_size - TAIL_LEN - TRAILER_LEN
    if data[expected_trailer_start:expected_trailer_start + TRAILER_LEN] != PE_TRAILER:
        raise TransplantError(
            f"trailer not found at offset {expected_trailer_start} "
            f"(expected {PE_TRAILER!r})"
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
        raise TransplantError(
            f"implausible sizes: hostBunSize={host_bun_size} "
            f"moduleGraphSize={module_graph_size} byteCount={byte_count}"
        )

    slice_start = host_bun_size
    slice_end = file_size - TAIL_LEN
    module_graph = data[slice_start:slice_end]
    if len(module_graph) != module_graph_size:
        raise TransplantError(
            f"slice length mismatch: expected {module_graph_size}, "
            f"got {len(module_graph)}"
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "module-graph.bin").write_bytes(module_graph)
    (out_dir / "host-bun.bin").write_bytes(data[:host_bun_size])

    return {
        "ver": ver,
        "file_size": file_size,
        "host_bun_size": host_bun_size,
        "module_graph_size": module_graph_size,
        "byte_count": byte_count,
        "mod_ptr_offset": mod_ptr_offset,
        "mod_ptr_length": mod_ptr_length,
        "entry_point_id": entry_point_id,
        "argv": [argv0, argv1],
        "flags": flags,
        "module_graph": "module-graph.bin",
        "host_bun": "host-bun.bin",
    }


# ---------------------------------------------------------------- graph
def parse_graph(data: bytes) -> dict:
    """Parse a module-graph.bin: [string data][records][argv][Offsets][trailer].

    Offsets are graph-relative (same layout as the full binary's module graph).
    """
    fs = len(data)
    ts = fs - TRAILER_LEN
    if ts < 0 or data[ts:ts + TRAILER_LEN] != PE_TRAILER:
        raise TransplantError(
            f"module graph trailer {PE_TRAILER!r} not found at EOF-16 (size={fs})"
        )
    o = ts - OFFSETS_LEN
    byte_count, mod_off, mod_len, entry, argv0, argv1, flags = (
        struct.unpack_from("<QIIIIII", data, o)
    )
    if mod_off + mod_len != argv0:
        raise TransplantError(
            f"stride check failed: modOff+modLen={mod_off + mod_len} "
            f"!= argv_off={argv0}"
        )
    area = mod_len
    if area % RECORD_36 == 0 and area % RECORD_52 != 0:
        layout = RECORD_36
    elif area % RECORD_52 == 0:
        layout = RECORD_52
    else:
        raise TransplantError(f"record area {area} B divisible by neither 36 nor 52")
    return {
        "byte_count": byte_count,
        "mod_off": mod_off,
        "mod_len": mod_len,
        "entry": entry,
        "argv0": argv0,
        "argv1": argv1,
        "flags": flags,
        "layout": layout,
        "n": area // layout,
    }


def convert_graph(data: bytes, target: int) -> tuple[bytes, dict]:
    """Convert a module-graph.bin's record layout (36<->52), graph-only.

    Reuses convert_layout.convert_records for the per-record rewrite.
    """
    p = parse_graph(data)
    if p["layout"] == target:
        raise TransplantError(f"graph already uses {target}B layout; nothing to convert")

    n = p["n"]
    delta = DELTA * n if target == RECORD_52 else -DELTA * n
    string_data = data[0:p["mod_off"]]
    records = data[p["mod_off"]:p["mod_off"] + p["mod_len"]]
    argv_str = data[p["argv0"]:p["byte_count"]]

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

    new_graph = string_data + new_records + argv_str + new_offsets + PE_TRAILER
    return new_graph, {
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
        "old_graph_size": len(data),
        "new_graph_size": len(new_graph),
    }


# ---------------------------------------------------------------- patch
def _semver_key(ver: str) -> tuple:
    """'1.3.13' -> (1, 3, 13); tolerate suffixes ('1.3.13-beta' -> (1, 3, 13))."""
    key = []
    for tok in str(ver).split("."):
        digits = ""
        for ch in tok:
            if ch.isdigit():
                digits += ch
            else:
                break
        key.append(int(digits) if digits else 0)
    return tuple(key)

def _select_patches(raw, ver: str | None, cfg: Path, info: dict) -> list:
    """Resolve patches.json into the patch list for `ver`.

    New schema: {"schema_version": 1, "ranges": [{min, max, bun_layout,
    patches: [...]}]} — ranges are matched by semantic version (min <= ver
    <= max). Legacy flat forms (a bare list, or {"patches": [...]}) are
    still accepted and applied unconditionally.
    """
    if isinstance(raw, list):
        return raw
    if not isinstance(raw, dict):
        raise TransplantError(
            f"patches.json {cfg}: expected an object or a list of patches"
        )
    if "ranges" in raw:
        schema_version = raw.get("schema_version", 1)
        if not isinstance(schema_version, int) or schema_version < 1:
            raise TransplantError(
                f"patches.json {cfg}: unsupported schema_version {schema_version!r}"
            )
        ranges = raw["ranges"]
        if not isinstance(ranges, list) or not ranges:
            raise TransplantError(
                f"patches.json {cfg}: 'ranges' must be a non-empty list"
            )
        selected = []
        for r in ranges:
            if not isinstance(r, dict) or "patches" not in r:
                raise TransplantError(
                    f"patches.json {cfg}: each range needs a 'patches' list"
                )
            rmin = r.get("min")
            rmax = r.get("max")
            if ver is not None:
                vk = _semver_key(ver)
                if rmin is not None and vk < _semver_key(rmin):
                    continue
                if rmax is not None and vk > _semver_key(rmax):
                    continue
            for pt in r["patches"]:
                if isinstance(pt, dict):
                    pt = dict(pt)
                    pt.setdefault("range", f"{rmin}-{rmax}")
                    pt.setdefault("bun_layout", r.get("bun_layout"))
                selected.append(pt)
        if ver is not None and not selected:
            info["warnings"].append(
                f"no patch ranges match version {ver}; patch step no-op"
            )
        return selected
    patches = raw.get("patches", raw)
    if not isinstance(patches, list):
        raise TransplantError(
            f"patches.json {cfg}: expected a list of patches "
            f"(or {{'patches': [...]}})"
        )
    return patches

def patch_graph(graph: bytes, cfg: Path, ver: str | None = None) -> tuple[bytes, dict]:
    """Apply equal-length string_data replacements from patches.json.

    Returns (possibly-new graph bytes, info dict). A missing config file or a
    patch with zero hits is a warning recorded in the report, not a failure.
    """
    info = {"hit_count": 0, "warnings": [], "config": str(cfg)}
    if not cfg.is_file():
        info["warnings"].append(f"patches.json not found: {cfg}; patch step skipped")
        return graph, info

    try:
        raw = json.loads(cfg.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise TransplantError(f"invalid patches.json {cfg}: {e}") from e

    patches = _select_patches(raw, ver, cfg, info)
    p = parse_graph(graph)
    string_data_end = p["mod_off"]
    string_data_end = p["mod_off"]
    data = bytearray(graph)
    hits = 0
    for i, patch in enumerate(patches):
        if not isinstance(patch, dict):
            info["warnings"].append(f"patch #{i}: not an object; skipped")
            continue
        name = patch.get("name", f"#{i}")
        region = patch.get("region", "string_data")
        if region != "string_data":
            info["warnings"].append(
                f"patch {name}: unsupported region {region!r}; skipped"
            )
            continue
        search = patch.get("search")
        replace = patch.get("replace")
        if not isinstance(search, str) or not isinstance(replace, str):
            info["warnings"].append(
                f"patch {name}: search/replace must be strings; skipped"
            )
            continue
        sb = search.encode("utf-8")
        rb = replace.encode("utf-8")
        if len(sb) != len(rb):
            raise TransplantError(
                f"patch {name}: search.len ({len(sb)}) != replace.len ({len(rb)}) "
                f"— only equal-length replacements are allowed"
            )
        if not sb:
            info["warnings"].append(f"patch {name}: empty search; skipped")
            continue
        sd = bytes(data[:string_data_end])
        n = sd.count(sb)
        if n == 0:
            info["warnings"].append(f"patch {name}: no hit for {search!r}; skipped")
            continue
        data[:string_data_end] = sd.replace(sb, rb)
        hits += n
        info.setdefault("applied", []).append(
            {"name": name, "hits": n, "search": search, "replace": replace}
        )

    info["hit_count"] = hits
    return bytes(data), info


# ---------------------------------------------------------------- execve
def execve_probe(binary: Path, timeout: int = 60) -> dict:
    proc = subprocess.run(
        [str(binary), "--version"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        "exit_code": proc.returncode,
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
    }


def verify_step(binary: Path, expect_version: str) -> dict:
    """Re-run execve and assert the version string is present in stdout."""
    if not binary.is_file():
        raise TransplantError(f"binary not found: {binary} (run assemble first)")
    probe = execve_probe(binary)
    ok = probe["exit_code"] == 0 and expect_version in probe["stdout"]
    result = {
        "execve_result": probe["stdout"] or probe["stderr"],
        "exit_code": probe["exit_code"],
        "stdout": probe["stdout"],
        "stderr": probe["stderr"],
        "expect_version": expect_version,
        "assert_ok": ok,
    }
    if not ok:
        raise TransplantError(
            f"execve assertion failed: expected version {expect_version!r} in "
            f"stdout, got exit_code={probe['exit_code']} "
            f"stdout={probe['stdout']!r} stderr={probe['stderr']!r} "
            f"(binary: {binary})"
        )
    return result


# ---------------------------------------------------------------- commands
def cmd_extract(args) -> int:
    tgz = Path(args.tgz)
    out_dir = Path(args.out) if args.out else ver_dir(args.ver)
    info = extract_step(tgz, args.ver, out_dir)
    info["sha256"] = sha256_file(out_dir / "module-graph.bin")
    update_report(out_dir, "extract", info)
    print(f"hostBunSize={info['host_bun_size']}")
    print(f"moduleGraphSize={info['module_graph_size']}")
    print(f"byteCount={info['byte_count']}")
    print(f"module graph written: {out_dir / 'module-graph.bin'} ({info['module_graph_size']} B)")
    print(f"host bun written: {out_dir / 'host-bun.bin'} ({info['host_bun_size']} B)")
    return 0


def cmd_detect(args) -> int:
    out_dir = ver_dir(args.ver)
    if args.binary:
        src = Path(args.binary)
    elif args.tgz:
        src = Path(args.tgz)
    else:
        src = out_dir / "opencode-native"
    if not src.is_file():
        die(f"input not found: {src} (pass --tgz or --binary)")
    data = load_bytes(str(src))
    info = detect_layout(data)
    info["source"] = str(src)
    update_report(out_dir, "detect", info, layout=info["layout"])
    print(json.dumps(info))
    return 0


def cmd_convert(args) -> int:
    out_dir = ver_dir(args.ver)
    graph = Path(args.graph) if args.graph else out_dir / "module-graph.bin"
    if not graph.is_file():
        die(f"module graph not found: {graph} (run extract first)")
    target = RECORD_36 if args.to == "36" else RECORD_52
    data = graph.read_bytes()
    new_graph, info = convert_graph(data, target)
    out_path = Path(args.out) if args.out else graph
    out_path.write_bytes(new_graph)
    update_report(out_dir, "convert", info, layout=target)
    print(f"converted {graph} ({info['src_layout']}B) -> {out_path} ({info['dst_layout']}B)")
    print(f"  modules={info['n']}  delta={info['delta']:+d} B/record")
    print(f"  byte_count: {info['old_byte_count']} -> {info['new_byte_count']}")
    print(f"  mod_len:    {info['old_mod_len']} -> {info['new_mod_len']}")
    print(f"  argv0:      {info['old_argv0']} -> {info['new_argv0']}")
    return 0


def cmd_patch(args) -> int:
    out_dir = ver_dir(args.ver)
    graph = Path(args.graph) if args.graph else out_dir / "module-graph.bin"
    if not graph.is_file():
        die(f"module graph not found: {graph} (run extract first)")
    cfg = Path(args.config) if args.config else config_dir() / "patches.json"
    data = graph.read_bytes()
    new_data, info = patch_graph(data, cfg, ver=args.ver)
    if new_data != data:
        graph.write_bytes(new_data)
    update_report(out_dir, "patch", info)
    print(f"patch: hit_count={info['hit_count']}")
    for w in info.get("warnings", []):
        print(f"  warning: {w}")
    return 0


def cmd_assemble(args) -> int:
    out_dir = ver_dir(args.ver)
    bun_cache = (
        Path(args.bun_cache)
        if args.bun_cache
        else repo_root() / "artifacts" / "transplant" / "android-bun"
    )
    graph = Path(args.graph) if args.graph else out_dir / "module-graph.bin"
    out_path = Path(args.out) if args.out else out_dir / "opencode-native"
    if not graph.is_file():
        die(f"module graph not found: {graph} (run extract first)")
    bun_elf = download_bun(bun_cache)
    expected_total = assemble_binary(bun_elf, graph, out_path)
    verify_tail(out_path, expected_total)
    info = {
        "bun": str(bun_elf),
        "bun_size": bun_elf.stat().st_size,
        "graph": str(graph),
        "graph_size": graph.stat().st_size,
        "file_size": out_path.stat().st_size,
        "expected_total": expected_total,
        "sha256": sha256_file(out_path),
    }
    if args.no_execve:
        info["execve_result"] = "skipped (--no-execve)"
    else:
        probe = execve_probe(out_path)
        info["execve_result"] = probe["stdout"] or probe["stderr"]
        info["execve_exit_code"] = probe["exit_code"]
        print(f"execve probe: exit={probe['exit_code']} stdout={probe['stdout']!r}")
    update_report(out_dir, "assemble", info)
    print(f"assembled: {out_path} ({info['file_size']} B)")
    return 0


def cmd_verify(args) -> int:
    out_dir = ver_dir(args.ver)
    binary = Path(args.binary) if args.binary else out_dir / "opencode-native"
    expect = args.expect_version or DEFAULT_BUN_VERSION
    info = verify_step(binary, expect)
    update_report(out_dir, "verify", info)
    print(f"verify: exit={info['exit_code']} stdout={info['stdout']!r}")
    print(f"ASSERT PASS: version string {info['expect_version']!r} present in stdout")
    return 0


def cmd_all(args) -> int:
    ver = args.ver
    tgz = Path(args.tgz)
    if not tgz.is_file():
        die(f"tgz not found: {tgz}")
    out_dir = ver_dir(ver)
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {"ver": ver, "layout": None, "steps": {}}

    # 1. extract
    print("== extract ==")
    extract_info = extract_step(tgz, ver, out_dir)
    extract_info["sha256"] = sha256_file(out_dir / "module-graph.bin")
    report["steps"]["extract"] = extract_info
    print(f"  module-graph.bin sha256={extract_info['sha256'][:16]}...")

    # 2. detect
    print("== detect ==")
    data = load_bytes(str(tgz))
    detect_info = detect_layout(data)
    detect_info["source"] = str(tgz)
    report["layout"] = detect_info["layout"]
    report["steps"]["detect"] = detect_info
    print(
        f"  layout={detect_info['layout']}B bun_version={detect_info['bun_version']} "
        f"modules={detect_info['module_count']}"
    )

    # 3. convert if 36
    print("== convert ==")
    graph = out_dir / "module-graph.bin"
    if detect_info["layout"] == RECORD_36:
        graph_bytes = graph.read_bytes()
        new_graph, convert_info = convert_graph(graph_bytes, RECORD_52)
        graph.write_bytes(new_graph)
        report["steps"]["convert"] = convert_info
        report["layout"] = RECORD_52
        print(
            f"  converted 36B -> 52B: {convert_info['n']} records, "
            f"delta={convert_info['delta']:+d}"
        )
    else:
        report["steps"]["convert"] = {
            "skipped": True,
            "reason": f"layout already {RECORD_52}B",
        }
        print(f"  layout already {RECORD_52}B; convert skipped")

    # 4. patch
    print("== patch ==")
    graph_bytes = graph.read_bytes()
    patched, patch_info = patch_graph(graph_bytes, config_dir() / "patches.json", ver=args.ver)
    if patched != graph_bytes:
        graph.write_bytes(patched)
    report["steps"]["patch"] = patch_info
    print(f"  hit_count={patch_info['hit_count']}")
    for w in patch_info.get("warnings", []):
        print(f"  warning: {w}")

    # 5. assemble
    print("== assemble ==")
    bun_cache = repo_root() / "artifacts" / "transplant" / "android-bun"
    out_path = out_dir / "opencode-native"
    bun_elf = download_bun(bun_cache)
    expected_total = assemble_binary(bun_elf, graph, out_path)
    verify_tail(out_path, expected_total)
    assemble_info = {
        "bun": str(bun_elf),
        "bun_size": bun_elf.stat().st_size,
        "graph_size": graph.stat().st_size,
        "file_size": out_path.stat().st_size,
        "expected_total": expected_total,
        "sha256": sha256_file(out_path),
    }
    report["steps"]["assemble"] = assemble_info
    print(f"  opencode-native sha256={assemble_info['sha256'][:16]}...")

    # 6. verify
    print("== verify ==")
    if args.no_execve:
        report["steps"]["verify"] = {
            "execve_result": "skipped (--no-execve)",
            "skipped": True,
        }
        print("  execve skipped (--no-execve)")
    else:
        verify_info = verify_step(out_path, DEFAULT_BUN_VERSION)
        report["steps"]["verify"] = verify_info
        print(f"  execve_result={verify_info['execve_result']!r}")

    save_report(out_dir, report)
    print(f"\nreport: {report_path(out_dir)}")
    print(json.dumps(report, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="transplant",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="command", required=True, metavar="COMMAND")

    p = sub.add_parser("extract", help="tgz -> module-graph.bin + host-bun.bin")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--tgz", required=True, help="path to opencode-linux-arm64-<ver>.tgz")
    p.add_argument("--out", default=None, help="output dir (default: artifacts/transplant/<ver>)")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("detect", help="detect record layout (36/52) + bun version")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--tgz", default=None, help="source tgz (default: artifacts/transplant/<ver>/opencode-native)")
    p.add_argument("--binary", default=None, help="standalone binary path (alternative to --tgz)")
    p.set_defaults(func=cmd_detect)

    p = sub.add_parser("convert", help="convert module-graph record layout 36<->52")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--to", required=True, choices=("36", "52"), help="target record layout")
    p.add_argument("--graph", default=None, help="module graph path (default: artifacts/transplant/<ver>/module-graph.bin)")
    p.add_argument("--out", default=None, help="output graph path (default: in-place)")
    p.set_defaults(func=cmd_convert)

    p = sub.add_parser("patch", help="equal-length string_data replacements from config/patches.json")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--graph", default=None, help="module graph path (default: artifacts/transplant/<ver>/module-graph.bin)")
    p.add_argument("--config", default=None, help="patches.json path (default: tools/transplant/config/patches.json)")
    p.set_defaults(func=cmd_patch)

    p = sub.add_parser("assemble", help="download android Bun + concatenate + execve probe")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--bun-cache", default=None, help="cache dir for android bun (default: artifacts/transplant/android-bun)")
    p.add_argument("--graph", default=None, help="module graph path (default: artifacts/transplant/<ver>/module-graph.bin)")
    p.add_argument("--out", default=None, help="output dir (default: artifacts/transplant/<ver>)")
    p.add_argument("--no-execve", action="store_true", help="skip the execve probe")
    p.set_defaults(func=cmd_assemble)

    p = sub.add_parser("verify", help="re-run execve asserting version string consistency")
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--binary", default=None, help="binary path (default: artifacts/transplant/<ver>/opencode-native)")
    p.add_argument("--expect-version", default=None, help=f"expected version string in stdout (default: {DEFAULT_BUN_VERSION})")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser(
        "all",
        help="one-shot pipeline: extract -> detect -> (convert if 36) -> patch -> assemble -> verify",
    )
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--tgz", required=True, help="path to opencode-linux-arm64-<ver>.tgz")
    p.add_argument("--no-execve", action="store_true", help="skip the execve step (CI: produce binary + report only)")
    p.set_defaults(func=cmd_all)

    return ap


def main(argv=None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except TransplantError as e:
        die(str(e))
    except (DetectCorrupt, ConvertCorrupt) as e:
        die(str(e))
    except subprocess.TimeoutExpired as e:
        die(f"execve timed out after {e.timeout}s: {e.cmd}")
    except (OSError, struct.error, tarfile.TarError) as e:
        die(f"{type(e).__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
