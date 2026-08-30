#!/usr/bin/env python3
"""transplant.py — unified CLI for the native-android transplant pipeline.

Integrates the standalone probes (probe_extract.py / detect_layout.py /
convert_layout.py / probe_assemble.py) into one argparse CLI:

    predict   DRY-RUN feasibility: graph format + android bun base pairing +
              patch-era judgement + risk list (metadata/local state only, no
              downloads); exit 0=OK 1=FAIL 2=NEEDS_INFO
    extract   tgz -> module-graph.bin + host-bun.bin
    detect    layout detection (36B vs 52B records) + bun version probe
    convert   36<->52 module-graph record conversion
    patch     equal-length string_data replacements from config/patches.json
    assemble  android Bun download + concatenation + execve probe
    revive    C1 revival surgery: graft module graph onto android Bun ELF
              (BUN_COMPILED.size publish; delegates to revive_patch.py)
    verify    re-run execve asserting version string consistency
    all       one-shot pipeline: predict (fail-fast) -> extract -> detect ->
              (convert if 36) -> patch -> assemble -> revive (unless
              --no-revive) -> verify

Output: artifacts/transplant/<ver>/opencode-native + report.json
        {ver, layout, prediction:{verdict, format, base, patch_hit, risks},
         steps:{extract:{sha256}, detect:{...}, convert:{...},
         patch:{hit_count}, assemble:{sha256},
          revive:{status, patched_size, reloc_count}, verify:{execve_result}}}
Revived binary: artifacts/transplant/<ver>/opencode-native-revived
(standalone mode: --version prints the opencode version, e.g. 1.3.13).

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
import os
import pty
import select
import shutil
import threading
import time
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
    resolve_bun_base,
    ResolveError,
    _scan_local_buns,
    _satisfies,
    _load_bun_bind,
)

DEFAULT_BUN_VERSION = "1.3.14"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
REVIVE_SCRIPT = Path(__file__).resolve().parent / "revive_patch.py"
SECTION_MIN_FORMAT_VER = (1, 18, 0)  # opencode >=1.18 uses the .bun section format


def format_from_ver(ver: str) -> str:
    """Infer the module-graph format from the opencode version.

    opencode >=1.18 ships the new .bun section-format graph (needs a >=1.4 bun
    base); <=1.3.x ships the trailer-format graph (needs a 1.3.x bun base).
    """
    return "section" if _semver_key(ver) >= SECTION_MIN_FORMAT_VER else "trailer"


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


def _elf_section_by_name(data: bytes, name: str) -> tuple[int, int] | None:
    """Locate an ELF64 section by name; returns (sh_offset, sh_size) or None.

    ELF64 LE layout used: e_shoff=u64@40, e_shentsize=u16@58, e_shnum=u16@60,
    e_shstrndx=u16@62; shdr sh_name=u32@0, sh_type=u32@4, sh_offset=u64@24,
    sh_size=u64@32.
    """
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    (e_shoff,) = struct.unpack_from("<Q", data, 40)
    (e_shentsize,) = struct.unpack_from("<H", data, 58)
    (e_shnum,) = struct.unpack_from("<H", data, 60)
    (e_shstrndx,) = struct.unpack_from("<H", data, 62)
    if e_shoff == 0 or e_shnum == 0 or e_shentsize < 40:
        return None
    if e_shstrndx >= e_shnum:
        return None
    str_hdr = e_shoff + e_shstrndx * e_shentsize
    (str_off,) = struct.unpack_from("<Q", data, str_hdr + 24)

    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (sh_name,) = struct.unpack_from("<I", data, off + 0)
        start = str_off + sh_name
        end = data.find(b"\x00", start)
        if end < 0:
            continue
        if data[start:end] == name.encode("utf-8"):
            (sh_offset,) = struct.unpack_from("<Q", data, off + 24)
            (sh_size,) = struct.unpack_from("<Q", data, off + 32)
            return sh_offset, sh_size
    return None

def extract_section_bun(data: bytes) -> tuple[bytes, dict]:
    """New-format fallback (opencode >=1.18): the module graph lives inside the
    `.bun` PROGBITS section instead of a file-tail standalone trailer.

    Section layout: [u64 LE BUN_COMPILED.size][payload ...][Offsets32][marker16].
    Returns the revive_patch.py --graph payload (leading u64 stripped; revive adds
    its own u64_le(len) prefix) plus info {"format": "section", ...}.
    """
    sec = _elf_section_by_name(data, ".bun")
    if sec is None:
        raise TransplantError(
            "unsupported format: no standalone trailer and no .bun section found"
        )
    sh_offset, sh_size = sec
    if sh_offset + sh_size > len(data):
        raise TransplantError(
            f".bun section out of bounds: offset={sh_offset} size={sh_size} "
            f"file={len(data)}"
        )
    sec_bytes = data[sh_offset:sh_offset + sh_size]
    if len(sec_bytes) < 8 + OFFSETS_LEN + TRAILER_LEN:
        raise TransplantError(
            f".bun section too small ({len(sec_bytes)} B) to hold a module graph"
        )
    if sec_bytes[-TRAILER_LEN:] != PE_TRAILER:
        raise TransplantError(
            f".bun section does not end with the Bun trailer {PE_TRAILER!r}"
        )
    payload = sec_bytes[8:]
    info = {
        "format": "section",
        "section_offset": sh_offset,
        "section_size": sh_size,
    }
    return payload, info

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
    fmt = "trailer"
    if data[expected_trailer_start:expected_trailer_start + TRAILER_LEN] != PE_TRAILER:
        # New-format fallback (opencode >=1.18): graph inside .bun PROGBITS section.
        module_graph, sec_info = extract_section_bun(data)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "module-graph.bin").write_bytes(module_graph)
        return {
            "ver": ver,
            "file_size": file_size,
            "module_graph_size": len(module_graph),
            **sec_info,
        }

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
        "format": fmt,
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
        covering_noop = None
        for r in ranges:
            if not isinstance(r, dict) or "patches" not in r:
                raise TransplantError(
                    f"patches.json {cfg}: each range needs a 'patches' list"
                )
            rmin = r.get("min")
            rmax = r.get("max")
            covers = True
            if ver is not None:
                vk = _semver_key(ver)
                if rmin is not None and vk < _semver_key(rmin):
                    covers = False
                if rmax is not None and vk > _semver_key(rmax):
                    covers = False
            if covers and r.get("patch_required") is False:
                covering_noop = r
            if not covers:
                continue
            for pt in r["patches"]:
                if isinstance(pt, dict):
                    pt = dict(pt)
                    pt.setdefault("range", f"{rmin}-{rmax}")
                    pt.setdefault("bun_layout", r.get("bun_layout"))
                selected.append(pt)
        if ver is not None and not selected:
            if covering_noop is not None:
                # An explicit era entry declares this version needs no patch:
                # a deliberate no-op, NOT an undeclared gap (no gap risk).
                info["outcome"] = "intentional-no-op"
                info["reason"] = covering_noop.get("reason")
            else:
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


# ---------------------------------------------------------------- TUI gate
def aarch64_exec_available() -> bool:
    """True when this host can execute an aarch64 ELF (native aarch64/arm64, or
    a qemu-aarch64 binfmt interpreter is installed)."""
    machine = os.uname().machine
    if machine == "aarch64" or machine.startswith("arm64") or "aarch64" in machine:
        return True
    for q in ("qemu-aarch64", "qemu-aarch64-static"):
        if shutil.which(q):
            return True
    return False


def tui_probe(product: Path, timeout: int = 15) -> dict:
    """Post-swap TUI verification gate (W7c2).

    Runs the `-tui` product under a pty with a hard `timeout`, capturing merged
    stdout/stderr. Verdicts recorded into report.json under `tui_probe`:
      "pass"                — the product rendered (emitted TUI escape sequences
                              / survived until the timeout) without the OpenTUI
                              init-failure message.
      "fail"                — stdout/stderr contained
                              "Failed to initialize OpenTUI".
      "skipped(no-aarch64)" — host cannot execute an aarch64 ELF.

    The swap equal-length/NUL-padding algorithm is never touched here.
    """
    if not aarch64_exec_available():
        return {
            "verdict": "skipped(no-aarch64)",
            "reason": "host cannot execute aarch64 ELF (non-aarch64, no qemu)",
        }
    if not product.is_file():
        return {"verdict": "fail", "reason": f"tui product not found: {product}"}

    master, slave = pty.openpty()
    captured = bytearray()

    def _reader() -> None:
        try:
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                captured.extend(chunk)
        except Exception:
            pass

    reader = threading.Thread(target=_reader, daemon=True)
    reader.start()
    try:
        proc = subprocess.Popen(
            [str(product), "-tui"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
    except OSError as e:
        os.close(master)
        os.close(slave)
        if getattr(e, "errno", None) == 8:  # ENOEXEC
            return {
                "verdict": "skipped(no-aarch64)",
                "reason": f"exec format error (cannot run aarch64 here): {e}",
            }
        return {"verdict": "fail", "reason": f"spawn failed: {e}"}

    exit_code = None
    timed_out = False
    try:
        exit_code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        timed_out = True
    reader.join(timeout=1.0)
    try:
        os.close(master)
        os.close(slave)
    except OSError:
        pass

    text = captured.decode("utf-8", "replace")
    if "Failed to initialize OpenTUI" in text:
        return {
            "verdict": "fail",
            "reason": "stdout/stderr contained 'Failed to initialize OpenTUI'",
            "captured_tail": text[-400:],
        }
    if timed_out:
        return {
            "verdict": "pass",
            "reason": f"survived {timeout}s under pty without init failure (rendering)",
            "captured_bytes": len(captured),
        }
    return {
        "verdict": "pass",
        "reason": f"exited cleanly (code {exit_code}) without init failure",
        "exit_code": exit_code,
        "captured_bytes": len(captured),
    }


def swap_step(binary: Path, tui_lib: Path, out: Path, strip: bool = True) -> dict:
    """Swap a bionic libopentui.so into `binary` (wrapper over swap_tui.py).

    The bionic lib is stripped (debug info only) when a strip tool is available,
    so it fits the embedded slot. Raises TransplantError on swap failure; the
    equal-length/NUL-padding algorithm lives in swap_tui.py and is untouched.
    """
    if not binary.is_file():
        raise TransplantError(f"swap input missing: {binary}")
    if not tui_lib.is_file():
        raise TransplantError(f"bionic libopentui.so missing: {tui_lib}")
    lib = tui_lib
    if strip:
        strip_bin = shutil.which("llvm-strip") or shutil.which("strip")
        if strip_bin:
            tmp = out.with_name(out.name + ".strip.so")
            subprocess.run(
                [strip_bin, "--strip-debug", str(tui_lib), "-o", str(tmp)],
                check=True,
                capture_output=True,
                timeout=120,
            )
            lib = tmp
    swap_script = Path(__file__).resolve().parent / "swap_tui.py"
    proc = subprocess.run(
        [sys.executable, str(swap_script),
         "--binary", str(binary), "--tui-lib", str(lib), "--out", str(out)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise TransplantError(
            f"swap_tui failed (exit {proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )
    return {"out": str(out), "status": "ok", "swap_stderr": proc.stderr.strip()}


def cmd_tui_probe(args) -> int:
    """Manual TUI pty gate: probe a -tui product and print the verdict."""
    product = Path(args.product)
    info = tui_probe(product, timeout=args.timeout)
    print(json.dumps(info, indent=2))
    return 0 if info["verdict"] in ("pass", "skipped(no-aarch64)") else 1


def cmd_swap(args) -> int:
    """Manual TUI swap: graft a bionic libopentui.so into a native product."""
    out = Path(args.out) if args.out else Path(args.binary).with_name(
        "opencode-native-tui"
    )
    info = swap_step(Path(args.binary), Path(args.tui_lib), out)
    update_report(out.parent, "swap", info)
    print(f"swap: status={info['status']} out={info['out']}")
    return 0


# ---------------------------------------------------------------- commands

# ---------------------------------------------------------------- revive
def revive_step(bun: Path, graph: Path, out: Path) -> dict:
    """C1 revival surgery: delegate to revive_patch.py (subprocess reuse).

    Grafts the module graph onto the android Bun ELF and patches BUN_COMPILED
    so the runtime enters standalone mode (loads the grafted graph) instead of
    falling back to interpreter mode. Report info: status/patched_size/reloc_count.
    """
    if not REVIVE_SCRIPT.is_file():
        raise TransplantError(f"revive script not found: {REVIVE_SCRIPT}")
    if not bun.is_file():
        raise TransplantError(f"android bun ELF not found: {bun}")
    if not graph.is_file():
        raise TransplantError(f"module graph not found: {graph}")
    proc = subprocess.run(
        [sys.executable, str(REVIVE_SCRIPT),
         "--bun", str(bun), "--graph", str(graph), "--out", str(out)],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if proc.returncode != 0:
        raise TransplantError(
            f"revive surgery failed (exit {proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )
    info = {
        "status": "ok",
        "bun": str(bun),
        "graph": str(graph),
        "out": str(out),
        "patched_size": out.stat().st_size,
        "reloc_count": None,
    }
    # revive_patch.py prints the extended rela table line on success for reloc
    # (<=1.3.x base) mode:  "...(n=N) += RELATIVE off=... addend=...".
    # In plain-offset (>=1.4 base) mode there is intentionally NO RELATIVE
    # relocation, so that line is absent — treat that as success too.
    m = re.search(r"\(n=(\d+)\) \+= RELATIVE", proc.stdout)
    if m:
        info["reloc_count"] = int(m.group(1))
        info["size_mode"] = "reloc"
    elif "plain-offset" in proc.stdout:
        info["size_mode"] = "plain-offset"
    else:
        raise TransplantError(
            f"revive surgery succeeded but rela-table line missing from output; "
            f"stdout:\n{proc.stdout}"
        )
    info["sha256"] = sha256_file(out)
    return info


def cmd_extract(args) -> int:
    tgz = Path(args.tgz)
    out_dir = Path(args.out) if args.out else ver_dir(args.ver)
    info = extract_step(tgz, args.ver, out_dir)
    info["sha256"] = sha256_file(out_dir / "module-graph.bin")
    update_report(out_dir, "extract", info)
    fmt = info.get("format", "trailer")
    print(f"format={fmt}")
    print(f"moduleGraphSize={info['module_graph_size']}")
    if fmt == "trailer":
        print(f"hostBunSize={info['host_bun_size']}")
        print(f"byteCount={info['byte_count']}")
    print(f"module graph written: {out_dir / 'module-graph.bin'} ({info['module_graph_size']} B)")
    if fmt == "trailer":
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
    bun_elf = download_bun(
        bun_cache, graph_format=format_from_ver(args.ver), out_dir=out_dir
    )
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
    if args.bun_version:
        got = info["stdout"]
        if info["exit_code"] != 0 or got != args.bun_version:
            raise TransplantError(
                f"bun-version assertion failed: expected {args.bun_version!r}, "
                f"got exit_code={info['exit_code']} stdout={got!r} (binary: {binary})"
            )
        info["bun_version"] = args.bun_version
        info["bun_version_assert_ok"] = True
        print(f"BUN VERSION ASSERT PASS: {got!r} == {args.bun_version!r}")
    update_report(out_dir, "verify", info)
    print(f"verify: exit={info['exit_code']} stdout={info['stdout']!r}")
    print(f"ASSERT PASS: version string {info['expect_version']!r} present in stdout")
    return 0


def cmd_revive(args) -> int:
    out_dir = ver_dir(args.ver)
    bun = (Path(args.bun) if args.bun else download_bun(
        repo_root() / "artifacts" / "transplant" / "android-bun",
        graph_format=format_from_ver(args.ver),
        out_dir=out_dir,
    ))
    graph = Path(args.graph) if args.graph else out_dir / "module-graph.bin"
    out = Path(args.out) if args.out else out_dir / "opencode-native-revived"
    info = revive_step(bun, graph, out)
    update_report(out_dir, "revive", info)
    print(f"revive: status=ok patched_size={info['patched_size']} "
          f"reloc_count={info['reloc_count']}")
    print(f"revive: wrote {out} sha256={info['sha256'][:16]}...")
    return 0


def detect_section(payload: bytes) -> dict:
    """New-format detect (opencode >=1.18): read Offsets32+marker16 from the
    module-graph payload tail (payload = .bun section minus leading u64)."""
    if len(payload) < OFFSETS_LEN + TRAILER_LEN:
        raise TransplantError(
            f"module graph too small ({len(payload)} B) for Offsets+trailer"
        )
    o = len(payload) - TRAILER_LEN - OFFSETS_LEN
    byte_count, mod_off, mod_len, entry, argv0, argv1, flags = struct.unpack_from(
        "<QIIIIII", payload, o
    )
    area = mod_len
    if area % RECORD_36 == 0 and area % RECORD_52 != 0:
        layout = RECORD_36
    elif area % RECORD_52 == 0:
        layout = RECORD_52
    else:
        raise TransplantError(
            f"record area {area} B divisible by neither {RECORD_36} nor {RECORD_52}"
        )
    n = area // layout
    return {
        "byte_count": byte_count,
        "mod_off": mod_off,
        "mod_len": mod_len,
        "entry_point_id": entry,
        "argv": [argv0, argv1],
        "flags": flags,
        "layout": layout,
        "n": n,
        "bun_version": None,
        "module_count": n,
        "source_format": "section",
    }

# ---------------------------------------------------------------- predict
NEEDS_DOWNLOAD = "NEEDS_DOWNLOAD"


def _range_covers(rng: dict, ver: str) -> bool:
    """True when a patches.json range covers `ver`.

    Same semantics as _select_patches: min/max inclusive, `null` = open-ended.
    """
    vk = _semver_key(ver)
    rmin = rng.get("min")
    rmax = rng.get("max")
    if rmin is not None and vk < _semver_key(rmin):
        return False
    if rmax is not None and vk > _semver_key(rmax):
        return False
    return True


def predict_patch_hit(ver: str, cfg: Path) -> tuple[str, list, dict]:
    """Judge the patches.json outcome for `ver` without touching a module graph.

    Returns (patch_hit, risks, detail); patch_hit is one of:
      matched          — a covering range carries at least one patch
      intentional-noop — a covering range declares patch_required:false (an
                         era that is known to need no patch)
      miss             — no covering range at all (undeclared era = blind spot)
    """
    risks: list = []
    detail: dict = {"config": str(cfg)}
    if not cfg.is_file():
        risks.append(f"patches.json not found: {cfg}; patch era undeclared")
        return "miss", risks, detail
    try:
        raw = json.loads(cfg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        risks.append(f"patches.json unreadable ({type(e).__name__}: {e})")
        return "miss", risks, detail

    if isinstance(raw, list) or not isinstance(raw, dict) or "ranges" not in raw:
        detail["schema"] = "legacy-flat"
        risks.append(
            "patches.json uses the legacy flat schema (no ranges); "
            "per-version era judgement unavailable"
        )
        return "miss", risks, detail

    ranges = [r for r in (raw.get("ranges") or []) if isinstance(r, dict)]
    covering = [r for r in ranges if _range_covers(r, ver)]
    detail["ranges_total"] = len(ranges)
    detail["ranges_covering"] = [f"{r.get('min')}..{r.get('max')}" for r in covering]
    detail["patch_count"] = sum(len(r.get("patches") or []) for r in covering)

    if detail["patch_count"]:
        return "matched", risks, detail
    noop = next((r for r in covering if r.get("patch_required") is False), None)
    if noop is not None:
        detail["reason"] = noop.get("reason")
        return "intentional-noop", risks, detail
    if covering:
        risks.append(
            f"patches.json range {detail['ranges_covering']} covers {ver} but carries "
            f"no patches and no explicit patch_required:false — cannot tell an "
            f"intentional no-op from an omission"
        )
        return "intentional-noop", risks, detail
    risks.append(
        f"no patches.json range covers {ver}: patch era undeclared (a gap, not an "
        f"intentional no-op) — add a range entry (patch_required:false for a "
        f"deliberate no-op)"
    )
    return "miss", risks, detail


def predict_bun_base(
    graph_format: str, cache_dir: Path
) -> tuple[str, list, list, dict]:
    """DRY-RUN android bun base judgement: local cache only, never any network.

    Applies the very same pairing rule resolve_bun_base uses (section => base >=
    bun-bind.json min_base_for_section; trailer => base <= 1.3.x) against the
    bases already sitting in `cache_dir`, in the same scan order, so the
    prediction matches what the real build would pick. When nothing local
    satisfies the format, returns NEEDS_DOWNLOAD instead of downloading.

    Returns (base, risks, fatal, detail).
    """
    risks: list = []
    fatal: list = []
    bind = _load_bun_bind()
    min_base = _semver_key(bind.get("min_base_for_section", "1.4.0"))
    requirement = (
        ">=" + ".".join(map(str, min_base)) if graph_format == "section" else "<=1.3.x"
    )
    detail: dict = {
        "cache_dir": str(cache_dir),
        "requirement": requirement,
        "bind_target": bind.get("target"),
        "candidates": [],
    }
    if not bind:
        risks.append(
            "bun-bind.json missing or unreadable; base judgement fell back to "
            "built-in defaults"
        )
    if graph_format == "section" and min_base <= (1, 3, 999):
        fatal.append(
            f"bun-bind.json min_base_for_section={bind.get('min_base_for_section')!r} "
            f"contradicts the section era: a 1.3.x base cannot serve a .bun "
            f"section-format graph"
        )

    try:
        local = _scan_local_buns(cache_dir)
    except OSError as e:
        local = []
        risks.append(f"bun cache unreadable: {type(e).__name__}: {e}")

    chosen = None
    for c in local:
        ok = _satisfies(c["version"], graph_format, min_base)
        detail["candidates"].append(
            {
                "level": "local-cache",
                "version": c["version"],
                "kind": c["kind"],
                "satisfies": ok,
            }
        )
        if ok and chosen is None:
            chosen = c
    if chosen is not None:
        detail["source"] = "local-cache"
        detail["path"] = str(chosen["path"])
        return chosen["version"], risks, fatal, detail

    # Nothing local satisfies: judge (offline) whether the download chain COULD.
    detail["source"] = "needs-download"
    plan: list = []
    url_pattern = bind.get("url_pattern")
    target = bind.get("target")
    if target and _satisfies(target, graph_format, min_base):
        plan.append({"level": "bun-bind", "version": target, "satisfies": True})
    elif target:
        plan.append({"level": "bun-bind", "version": target, "satisfies": False})
    if graph_format == "section":
        # github-latest is always newer than min_base in the section era.
        plan.append({"level": "github-latest", "version": "unknown", "satisfies": True})
    else:
        plan.append(
            {"level": "github-latest", "version": "unknown", "satisfies": False,
             "note": "latest bun is >=1.4; a trailer graph needs <=1.3.x"}
        )
        if _satisfies(DEFAULT_BUN_VERSION, graph_format, min_base):
            plan.append(
                {"level": "default", "version": DEFAULT_BUN_VERSION, "satisfies": True}
            )
    detail["download_plan"] = plan
    reachable = [p for p in plan if p["satisfies"]]
    detail["can_download"] = bool(reachable) and bool(url_pattern)
    if not url_pattern:
        fatal.append(
            "bun-bind.json has no url_pattern: no local base satisfies "
            f"{requirement} and there is no download source to fall back to"
        )
    elif not reachable:
        fatal.append(
            f"no candidate in the resolution chain can satisfy {requirement} for a "
            f"{graph_format} graph (local cache empty/unsuitable, bun-bind target="
            f"{target!r}, github-latest too new, DEFAULT_BUN_VERSION="
            f"{DEFAULT_BUN_VERSION})"
        )
    else:
        risks.append(
            f"no cached android bun base satisfies {requirement}; the real build "
            f"must download one ({[p['level'] for p in reachable]}) — network required"
        )
    return NEEDS_DOWNLOAD, risks, fatal, detail


def predict_step(
    ver: str, tgz: Path | None = None, bun_cache: Path | None = None
) -> dict:
    """Dry-run feasibility prediction for one opencode version.

    Pure metadata + local state: infers the module-graph format from the version,
    judges the android bun base against the local cache, and judges the
    patches.json era. Never downloads anything (the bun zip download stays in
    the real build).

    verdict: OK        — everything needed is present and paired
             NEEDS_INFO— buildable in principle, but something is unconfirmed
                          (missing base needs a download, undeclared patch era,
                          odd version string). Proceed with eyes open.
             FAIL      — hard incompatibility; the real build cannot succeed.
    """
    risks: list = []
    fatal: list = []
    cache_dir = bun_cache or (repo_root() / "artifacts" / "transplant" / "android-bun")

    fmt = format_from_ver(ver)
    numeric = ".".join(str(x) for x in _semver_key(ver))
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(ver)):
        risks.append(
            f"version {ver!r} is not a plain x.y.z semver; format/base judged from "
            f"its numeric prefix {numeric}"
        )
    if _semver_key(ver)[:3] == (0, 0, 0):
        risks.append(
            f"version {ver!r} resolves to numeric 0.0.0 — not a known opencode "
            f"release line; graph-format prediction ({fmt}) is a guess, verify "
            f"against the real tgz before trusting it"
        )

    tgz_detail = None
    if tgz is not None:
        tgz_detail = {"path": str(tgz), "present": tgz.is_file()}
        if not tgz.is_file():
            risks.append(f"tgz not found: {tgz}")
        else:
            tgz_detail["size"] = tgz.stat().st_size
            if str(ver) not in tgz.name:
                risks.append(
                    f"tgz name {tgz.name!r} does not mention version {ver!r}; "
                    f"version/artifact mismatch risk"
                )

    base, base_risks, base_fatal, base_detail = predict_bun_base(fmt, cache_dir)
    risks += base_risks
    fatal += base_fatal

    patch_hit, patch_risks, patch_detail = predict_patch_hit(
        ver, config_dir() / "patches.json"
    )
    risks += patch_risks

    if fatal:
        verdict = "FAIL"
    elif risks:
        verdict = "NEEDS_INFO"
    else:
        verdict = "OK"

    pred = {
        "verdict": verdict,
        "ver": ver,
        "format": fmt,
        "base": base,
        "patch_hit": patch_hit,
        "risks": risks,
        "dry_run": True,
        "base_detail": base_detail,
        "patch_detail": patch_detail,
    }
    if fatal:
        pred["fatal"] = fatal
    if tgz_detail is not None:
        pred["tgz"] = tgz_detail
    return pred


def cmd_predict(args) -> int:
    """Dry-run prediction; exit 0=OK, 1=FAIL, 2=NEEDS_INFO."""
    bun_cache = Path(args.bun_cache) if args.bun_cache else None
    pred = predict_step(
        args.ver,
        tgz=Path(args.tgz) if args.tgz else None,
        bun_cache=bun_cache,
    )
    print(json.dumps(pred, indent=2))
    return {"OK": 0, "FAIL": 1, "NEEDS_INFO": 2}[pred["verdict"]]


def cmd_all(args) -> int:
    ver = args.ver
    tgz = Path(args.tgz)
    if not tgz.is_file():
        die(f"tgz not found: {tgz}")
    out_dir = ver_dir(ver)
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {"ver": ver, "layout": None, "steps": {}}
    bun_cache = (
        Path(args.bun_cache)
        if args.bun_cache
        else repo_root() / "artifacts" / "transplant" / "android-bun"
    )

    # 0. predict (fail-fast gate: refuse before doing any real work)
    print("== predict ==")
    prediction = predict_step(ver, tgz=tgz, bun_cache=bun_cache)
    report["prediction"] = prediction
    print(
        f"  verdict={prediction['verdict']} format={prediction['format']} "
        f"base={prediction['base']} patch_hit={prediction['patch_hit']}"
    )
    for r in prediction["risks"]:
        print(f"  risk: {r}")
    if prediction["verdict"] == "FAIL":
        # Persist the verdict so the abort is diagnosable after the fact.
        save_report(out_dir, report)
        raise TransplantError(
            "prediction verdict=FAIL — aborting before extract (fail-fast).\n  "
            + "\n  ".join(prediction.get("fatal", ["hard incompatibility"]))
            + f"\n  see {report_path(out_dir)} (prediction section) / rerun: "
            f"transplant.py predict --ver {ver}"
        )

    # 1. extract
    print("== extract ==")
    extract_info = extract_step(tgz, ver, out_dir)
    extract_info["sha256"] = sha256_file(out_dir / "module-graph.bin")
    report["steps"]["extract"] = extract_info
    print(f"  module-graph.bin sha256={extract_info['sha256'][:16]}...")

    # 2. detect
    print("== detect ==")
    section_mode = extract_info.get("format") == "section"
    if section_mode:
        detect_info = detect_section((out_dir / "module-graph.bin").read_bytes())
        detect_info["source"] = "module-graph.bin (.bun section payload)"
    else:
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

    # 5. assemble (skipped in section mode: revive grafts directly onto android bun)
    print("== assemble ==")
    graph_format = "section" if section_mode else "trailer"
    out_path = out_dir / "opencode-native"
    bun_elf = None
    if section_mode:
        report["steps"]["assemble"] = {
            "skipped": True,
            "reason": "section format: revive grafts graph directly onto android bun",
        }
        print("  skipped (section format)")
    else:
        bun_elf = download_bun(bun_cache, graph_format=graph_format, out_dir=out_dir)
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


    # 6. revive (C1 revival surgery; skip with --no-revive)
    revived_path = out_dir / "opencode-native-revived"
    revived_ok = False
    if args.no_revive:
        report["steps"]["revive"] = {"status": "skipped"}
        print("== revive == skipped (--no-revive)")
    else:
        print("== revive ==")
        if bun_elf is None:
            # section mode: ensure android bun base exists (idempotent download)
            bun_elf = download_bun(bun_cache, graph_format=graph_format, out_dir=out_dir)
        revive_info = revive_step(bun_elf, graph, revived_path)
        report["steps"]["revive"] = revive_info
        revived_ok = True
        print(f"  opencode-native-revived sha256={revive_info['sha256'][:16]}... "
              f"(patched_size={revive_info['patched_size']}, "
              f"reloc_count={revive_info['reloc_count']})")
    # 7. verify (revived binary expects opencode ver; raw concat expects bun ver)
    print("== verify ==")
    if args.no_execve:
        report["steps"]["verify"] = {
            "execve_result": "skipped (--no-execve)",
            "skipped": True,
        }
        print("  execve skipped (--no-execve)")
    else:
        if revived_ok:
            verify_target, expect_ver = revived_path, args.ver
        else:
            verify_target, expect_ver = out_path, DEFAULT_BUN_VERSION
        verify_info = verify_step(verify_target, expect_ver)
        report["steps"]["verify"] = verify_info
        print(f"  execve_result={verify_info['execve_result']!r}")

    # 8. swap bionic libopentui + post-swap TUI pty gate (W7c2)
    print("== swap + tui_probe ==")
    bionic_lib = (
        repo_root() / "artifacts" / "transplant" / "opentui-bionic" / "libopentui.so"
    )
    tui_bin = out_dir / "opencode-native-tui"
    swap_src = revived_path if revived_path.is_file() else out_path
    if bionic_lib.is_file() and swap_src.is_file():
        try:
            swap_info = swap_step(swap_src, bionic_lib, tui_bin)
            report["steps"]["swap"] = swap_info
            print(f"  swapped -> {tui_bin} ({tui_bin.stat().st_size} B)")
            probe = tui_probe(tui_bin)
        except TransplantError as e:
            print(f"  swap failed: {e}")
            probe = {"verdict": "fail", "reason": f"swap failed: {e}"}
        report["tui_probe"] = probe["verdict"]
        report["steps"]["tui_probe"] = probe
        print(f"  tui_probe={probe['verdict']} ({probe.get('reason', '')})")
    else:
        print("  bionic libopentui.so absent; skipping swap + probe")
        report["tui_probe"] = "skipped(no-bionic-lib)"
        report["steps"]["tui_probe"] = {
            "verdict": "skipped(no-bionic-lib)",
            "reason": "artifacts/transplant/opentui-bionic/libopentui.so absent",
        }

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
    p.add_argument("--bun-version", default=None, help="assert execve stdout version string equals this exact bun version (default: no bun-version assertion)")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser(
        "revive",
        help="C1 revival surgery: graft module graph onto android Bun ELF (standalone mode)",
    )
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--bun", default=None, help="android bun ELF path (default: cached download, same source as assemble)")
    p.add_argument("--graph", default=None, help="module graph path (default: artifacts/transplant/<ver>/module-graph.bin)")
    p.add_argument("--out", default=None, help="output ELF path (default: artifacts/transplant/<ver>/opencode-native-revived)")
    p.set_defaults(func=cmd_revive)


    p = sub.add_parser(
        "all",
        help="one-shot pipeline: extract -> detect -> (convert if 36) -> patch -> assemble -> revive -> verify",
    )
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.3.13")
    p.add_argument("--tgz", required=True, help="path to opencode-linux-arm64-<ver>.tgz")
    p.add_argument("--no-execve", action="store_true", help="skip the execve step (CI: produce binary + report only)")
    p.add_argument("--no-revive", action="store_true", help="skip the revive step (raw concat binary only)")
    p.add_argument("--bun-cache", default=None, help="cache dir for android bun (default: artifacts/transplant/android-bun)")
    p.set_defaults(func=cmd_all)

    p = sub.add_parser(
        "predict",
        help="dry-run feasibility prediction (format/base/patch era/risks; no downloads)",
    )
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.18.22")
    p.add_argument("--tgz", default=None, help="optional local tgz path (sanity-checked, not unpacked)")
    p.add_argument("--bun-cache", default=None, help="cache dir for android bun (default: artifacts/transplant/android-bun)")
    p.set_defaults(func=cmd_predict)

    p = sub.add_parser(
        "resolve-base",
        help="debug: resolve + report the android bun base chosen for a version",
    )
    p.add_argument("--ver", required=True, help="opencode version, e.g. 1.18.22")
    p.add_argument("--bun-cache", default=None, help="cache dir for android bun (default: artifacts/transplant/android-bun)")
    p.set_defaults(func=cmd_resolve_base)

    p = sub.add_parser(
        "tui-probe",
        help="post-swap TUI pty gate: verify a -tui product renders (or skip on no-aarch64)",
    )
    p.add_argument("--product", required=True, help="path to the -tui product (opencode-native-tui)")
    p.add_argument("--timeout", type=int, default=15, help="pty probe timeout in seconds (default: 15)")
    p.set_defaults(func=cmd_tui_probe)

    p = sub.add_parser(
        "swap",
        help="swap a bionic libopentui.so into a native product (equal-length byte swap)",
    )
    p.add_argument("--binary", required=True, help="source native binary (opencode-native-revived)")
    p.add_argument("--tui-lib", required=True, help="bionic libopentui.so (<= embedded slot size)")
    p.add_argument("--out", default=None, help="output path (default: <binary>-dir/opencode-native-tui)")
    p.set_defaults(func=cmd_swap)

    return ap


def cmd_resolve_base(args) -> int:
    """Debug: resolve + report the android bun base chosen for a version."""
    out_dir = ver_dir(args.ver)
    bun_cache = (
        Path(args.bun_cache)
        if args.bun_cache
        else repo_root() / "artifacts" / "transplant" / "android-bun"
    )
    fmt = format_from_ver(args.ver)
    print(f"ver={args.ver} graph_format={fmt}")
    res = resolve_bun_base(fmt, bun_cache, out_dir=out_dir)
    print(json.dumps(res, indent=2))
    return 0


def main(argv=None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except TransplantError as e:
        die(str(e))
    except ResolveError as e:
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
