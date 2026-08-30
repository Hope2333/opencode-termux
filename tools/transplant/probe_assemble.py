#!/usr/bin/env python3
"""probe_assemble.py — Bind the official android Bun with the extracted module graph.

guysoft Step 6 (scripts/build-opencode-android.ts), empirically verified:
    [android bun bytes] + [module graph bytes] + [u64 LE = androidBunSize + mgLen + 8]

The trailing u64 is the total byte count of the assembled file (bun + graph + 8),
mirroring the standalone Bun trailer layout that probe_extract.py reads back.

Zero third-party dependencies: python3 stdlib only.
"""

import argparse
import json
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
DEFAULT_BUN_VERSION = "1.3.14"
ZIP_MEMBER = "bun-linux-aarch64-android/bun"
TAIL_LEN = 8  # trailing u64 total byte count
SECTION_MIN_FORMAT_VER = (1, 18, 0)  # opencode >=1.18 uses the .bun section format

# Raised when no satisfying android bun base can be resolved for a graph format.
class ResolveError(Exception):
    pass

# Native module markers to inventory inside the module graph.
# NOTE: avoid greedy `[A-Za-z0-9._/-]+` prefixes — on 62 MB of module graph
# they cause catastrophic backtracking (minutes+). Match the suffix only and
# expand backwards manually (O(n)).
NATIVE_SUFFIXES = [
    re.compile(rb"\.node"),
    re.compile(rb"\.so(?:\.[0-9]+)*"),
]
PREFIX_PATTERNS = [
    re.compile(rb"@opentui/[A-Za-z0-9._/-]+"),
    re.compile(rb"@parcel/[A-Za-z0-9._/-]+"),
]
PATH_CHARS = frozenset(
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-"
)


def _expand_path(data: bytes, end: int) -> bytes:
    """Expand backwards from a suffix match to capture the full path string."""
    start = end
    while start > 0 and data[start - 1] in PATH_CHARS:
        start -= 1
    return data[start:end]


def die(msg: str) -> None:
    print(f"probe_assemble: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _semver_key(ver: str) -> tuple:
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


def bun_version_from_elf(path: Path) -> str | None:
    """Read the Bun version string from an android bun ELF.

    The version string lives near the front for 1.3.x builds but can be tens of
    MiB deep for 1.4.x builds, so fall back to a full scan when the head miss.
    """
    try:
        with open(path, "rb") as f:
            head = f.read(4 * 1024 * 1024)
            m = re.search(rb"Bun v(\d+)\.(\d+)\.(\d+)", head)
            if m:
                return _ver_from_match(m)
            f.seek(0)
            data = f.read()
        m = re.search(rb"Bun v(\d+)\.(\d+)\.(\d+)", data)
        if not m:
            return None
        return _ver_from_match(m)
    except OSError:
        return None


def _ver_from_match(m: "re.Match[bytes]") -> str:
    return f"{m.group(1).decode()}.{m.group(2).decode()}.{m.group(3).decode()}"


def bun_version_from_zip_name(zip_path: Path) -> str | None:
    m = re.search(r"bun-(\d+\.\d+\.\d+)", zip_path.name)
    return m.group(1) if m else None


def _extract_bun_zip(zip_path: Path, dest_elf: Path) -> str | None:
    """Extract the android bun ELF from a zip into dest_elf; return detected version."""
    with zipfile.ZipFile(zip_path) as zf:
        info = zf.getinfo(ZIP_MEMBER)
        dest_elf.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(info) as src, open(dest_elf, "wb") as dst:
            dst.write(src.read())
    dest_elf.chmod(0o755)
    return bun_version_from_elf(dest_elf)


def _scan_local_buns(cache_dir: Path) -> list:
    """Identify bun ELFs/zips already present in the cache (any version)."""
    found = []
    if not cache_dir.is_dir():
        return found
    for p in sorted(cache_dir.iterdir()):
        if p.is_file() and p.name == "bun":
            v = bun_version_from_elf(p)
            if v:
                found.append({"version": v, "kind": "elf", "path": p})
        elif p.is_file() and p.suffix == ".zip":
            v = bun_version_from_zip_name(p)
            if v:
                found.append({"version": v, "kind": "zip", "path": p})
        elif p.is_dir() and p.name.startswith("bun-"):
            elf = p / "bun"
            if elf.is_file():
                v = bun_version_from_elf(elf)
                if v:
                    found.append({"version": v, "kind": "elf", "path": elf})
    return found


def _satisfies(version: str, graph_format: str, min_base: tuple) -> bool:
    k = _semver_key(version)
    if graph_format == "section":
        return k >= min_base
    # trailer format needs a <=1.3.x base (reloc size-mode)
    return k <= (1, 3, 999)


def _load_bun_bind() -> dict:
    cfg = Path(__file__).resolve().parent / "config" / "bun-bind.json"
    try:
        return json.loads(cfg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def resolve_bun_base(
    graph_format: str, cache_dir: Path, out_dir: Path | None = None
) -> dict:
    """Resolve the android bun base ELF for a module-graph format via a
    cache-priority candidate chain.

    Chain (each level yields candidates, then pairing-validated):
      1. local-cache  : ELFs/zips already in cache_dir (any version)
      2. bun-bind     : download bun-bind.json['target'] via url_pattern
      3. github-latest: probe-latest-bun.sh -> latest tag -> download
      4. default      : DEFAULT_BUN_VERSION (legacy; trailer-only; NOT used
                         for section graphs)
    Pairing rule: section => base >= min_base_for_section;
                  trailer => base <= 1.3.x.
    On full-chain failure -> ResolveError + write <out_dir>/bun-base.QUARANTINE.json.
    Returns {'path': Path, 'version': str, 'trial': [...], 'verdict': 'OK'}.
    """
    bind = _load_bun_bind()
    target = bind.get("target", DEFAULT_BUN_VERSION)
    url_pattern = bind.get(
        "url_pattern",
        "https://github.com/oven-sh/bun/releases/download/bun-v{ver}/"
        "bun-linux-aarch64-android.zip",
    )
    min_base = _semver_key(bind.get("min_base_for_section", "1.4.0"))
    trial: list = []
    chosen = None

    # --- level 1: local cache ---
    for c in _scan_local_buns(cache_dir):
        ok = _satisfies(c["version"], graph_format, min_base)
        entry = {
            "level": "local-cache",
            "version": c["version"],
            "kind": c["kind"],
            "satisfies": ok,
        }
        if ok and chosen is None:
            path = c["path"]
            if c["kind"] == "zip":
                dest = cache_dir / f"bun-{c['version']}" / "bun"
                try:
                    _extract_bun_zip(c["path"], dest)
                    path = dest
                    entry["extracted"] = str(dest)
                except Exception as e:  # noqa: BLE001
                    entry["status"] = f"extract-failed: {e}"
                    ok = False
            if ok:
                chosen = {"path": str(path), "version": c["version"]}
        trial.append(entry)
    if chosen is not None:
        return {
            "path": chosen["path"],
            "version": chosen["version"],
            "trial": trial,
            "verdict": "OK",
        }

    # --- level 2: bun-bind target (download) ---
    if _satisfies(target, graph_format, min_base):
        dest = cache_dir / f"bun-{target}" / "bun"
        url = url_pattern.format(ver=target)
        trial.append(
            {"level": "bun-bind", "version": target, "url": url,
             "satisfies": True, "status": "trying"}
        )
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            zip_path = cache_dir / f"bun-{target}.zip"
            if not zip_path.is_file():
                print(f"downloading {url}")
                urllib.request.urlretrieve(url, zip_path)
            got = _extract_bun_zip(zip_path, dest)
            trial[-1]["status"] = "ok"
            trial[-1]["path"] = str(dest)
            if got:
                trial[-1]["detected_version"] = got
            return {"path": dest, "version": target, "trial": trial, "verdict": "OK"}
        except Exception as e:  # noqa: BLE001
            trial[-1]["status"] = f"failed: {e}"

    # --- level 3: github latest (true source) ---
    try:
        probe = (
            Path(__file__).resolve().parent.parent.parent
            / "scripts" / "ci" / "probe-latest-bun.sh"
        )
        out = subprocess.run(
            ["bash", str(probe)], capture_output=True, text=True, timeout=60
        )
        latest = None
        for line in out.stdout.splitlines():
            if line.startswith("latest_tag="):
                latest = line.split("=", 1)[1].strip()
                if latest.startswith("bun-v"):
                    latest = latest[5:]
        if latest and _satisfies(latest, graph_format, min_base):
            dest = cache_dir / f"bun-{latest}" / "bun"
            url = url_pattern.format(ver=latest)
            trial.append(
                {"level": "github-latest", "version": latest, "url": url,
                 "satisfies": True, "status": "trying"}
            )
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                zip_path = cache_dir / f"bun-{latest}.zip"
                if not zip_path.is_file():
                    print(f"downloading {url}")
                    urllib.request.urlretrieve(url, zip_path)
                _extract_bun_zip(zip_path, dest)
                trial[-1]["status"] = "ok"
                trial[-1]["path"] = str(dest)
                return {"path": dest, "version": latest, "trial": trial, "verdict": "OK"}
            except Exception as e:  # noqa: BLE001
                trial[-1]["status"] = f"failed: {e}"
    except Exception as e:  # noqa: BLE001
        trial.append({"level": "github-latest", "status": f"skipped: {e}"})

    # --- level 4: default (legacy, trailer-only) ---
    if graph_format == "trailer":
        dest = cache_dir / "bun"
        if dest.is_file() and dest.stat().st_size > 0:
            trial.append(
                {"level": "default", "version": DEFAULT_BUN_VERSION,
                 "path": str(dest), "satisfies": True}
            )
            return {
                "path": dest,
                "version": DEFAULT_BUN_VERSION,
                "trial": trial,
                "verdict": "OK",
            }
        url = url_pattern.format(ver=DEFAULT_BUN_VERSION)
        trial.append(
            {"level": "default", "version": DEFAULT_BUN_VERSION, "url": url,
             "satisfies": True, "status": "trying"}
        )
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            zip_path = cache_dir / "bun-linux-aarch64-android.zip"
            if not zip_path.is_file():
                print(f"downloading {url}")
                urllib.request.urlretrieve(url, zip_path)
            _extract_bun_zip(zip_path, dest)
            trial[-1]["status"] = "ok"
            trial[-1]["path"] = str(dest)
            return {
                "path": dest,
                "version": DEFAULT_BUN_VERSION,
                "trial": trial,
                "verdict": "OK",
            }
        except Exception as e:  # noqa: BLE001
            trial[-1]["status"] = f"failed: {e}"

    # --- full chain failure -> QUARANTINE ---
    if graph_format == "section":
        base_req = ">=" + ".".join(map(str, min_base))
    else:
        base_req = "<=1.3.x"
    q = {
        "verdict": "QUARANTINE",
        "graph_format": graph_format,
        "breakpoint": "no-satisfying-base",
        "candidates": trial,
        "suggestion": (
            f"Provide a {base_req} android Bun base for {graph_format} graphs "
            f"(e.g. bun-bind.json target=<ver>) or place the ELF/zip under {cache_dir}."
        ),
    }
    if out_dir is not None:
        (out_dir / "bun-base.QUARANTINE.json").write_text(
            json.dumps(q, indent=2) + "\n", encoding="utf-8"
        )
    raise ResolveError(
        f"resolve_bun_base QUARANTINE: no satisfying base for {graph_format} graph "
        f"across chain (see bun-base.QUARANTINE.json). trial={trial}"
    )


def download_bun(
    cache_dir: Path, graph_format: str | None = None, out_dir: Path | None = None
) -> Path:
    """Resolve + download the official android Bun ELF.

    With graph_format set, resolves via the cache-priority chain (resolve_bun_base).
    Without it (legacy), falls back to the hardcoded 1.3.14 behaviour.
    """
    if graph_format is not None:
        res = resolve_bun_base(graph_format, cache_dir, out_dir)
        last = res["trial"][-1] if res["trial"] else {}
        print(
            f"resolve_bun_base: chose {res['version']} via "
            f"{last.get('level', '?')}"
        )
        return Path(res["path"])
    # legacy behaviour
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
    """Scan module graph for native module filename strings (O(n), no backtracking)."""
    data = graph.read_bytes()
    found = set()

    # Suffix-anchored matches: expand backwards to capture the full path.
    for pat in NATIVE_SUFFIXES:
        for m in pat.finditer(data):
            s = _expand_path(data, m.start()).decode("utf-8", "replace")
            if "/" in s:
                found.add(s)

    # Known-prefix matches (fast, anchored on the prefix).
    for pat in PREFIX_PATTERNS:
        for m in pat.finditer(data):
            found.add(m.group(0).decode("utf-8", "replace"))

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