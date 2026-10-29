#!/usr/bin/env python3
"""effect-migrate.py — apply the A2 effect-version migration to a v1 source tree.

Why this exists: getting opencode v1 1.19.4 to build against effect 4.0.0-beta.103
required seven manual edits (see .omo/evidence/post-261026-roadmap/task-14-v1-build.md).
Doing them by hand made the artifact un-rebuildable: delete the source tree and
the next build fails at the same seven places. This script makes them repeatable.

Every step is idempotent and anchor-checked:
  * already migrated  -> "skip" (and the assertion still runs)
  * anchor missing    -> exit 1 with the file/pattern, never a silent pass

Phases:
  pre-install   package.json (catalog + overrides + patchedDependencies key),
                source rewrites (unstable/ subpaths, OtelTracer, Schedule.min),
                effect patch file for the target version
  post-install  @opentui/core-linux-arm64 platform package: bun refuses to install
                optional platform deps for this host, so fetch the npm tarball and
                extract it into the store key the build expects, plus the
                node_modules symlink.

Usage:
  effect-migrate.py pre  --src DIR --effect 4.0.0-beta.103 --opentui 0.4.5
  effect-migrate.py post --src DIR --opentui 0.4.5
Exit: 0 all applied or already applied; 1 anchor/assert failure.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

EFFECT_PKGS = [
    "effect",
    "@effect/platform-node",
    "@effect/platform-node-shared",
    "@effect/opentelemetry",
    "@effect/sql-sqlite-bun",
]


def die(msg):
    print(f"effect-migrate: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def note(msg):
    print(f"    {msg}")


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def phase_pre(args):
    src = args.src
    pkg_path = os.path.join(src, "package.json")
    if not os.path.isfile(pkg_path):
        die(f"no package.json under {src}")
    data = load_json(pkg_path)
    catalog = (data.get("workspaces") or {}).get("catalog")
    if catalog is None:
        die("package.json has no workspaces.catalog — v1 layout changed")

    # 1) catalog
    changed = 0
    for name in EFFECT_PKGS:
        if name in catalog and catalog[name] != args.effect:
            note(f"catalog {name}: {catalog[name]} -> {args.effect}")
            catalog[name] = args.effect
            changed += 1
    if changed == 0:
        note(f"catalog already at {args.effect} (skip)")

    # 2) overrides — transitive @effect/* deps can still resolve to a stable 4.0.x
    overrides = data.setdefault("overrides", {})
    for name in EFFECT_PKGS:
        if overrides.get(name) != args.effect:
            overrides[name] = args.effect
    note(f"overrides pinned for {len(EFFECT_PKGS)} effect packages")

    # 3) patchedDependencies key must point at a file that exists
    patches = data.get("patchedDependencies") or {}
    for key in list(patches):
        if key.startswith("effect@"):
            old_file = os.path.join(src, patches[key])
            new_key = f"effect@{args.effect}"
            new_rel = f"patches/effect@{args.effect}.patch"
            new_file = os.path.join(src, new_rel)
            if not os.path.isfile(new_file):
                if not os.path.isfile(old_file):
                    die(f"patch {old_file} missing; cannot derive {new_file}")
                shutil.copyfile(old_file, new_file)
                note(f"effect patch copied -> {new_rel}")
            if key != new_key or patches[key] != new_rel:
                del patches[key]
                patches[new_key] = new_rel
                note(f"patchedDependencies key -> {new_key}")
            break

    save_json(pkg_path, data)

    # 4) source rewrites
    roots = [os.path.join(src, "packages"), os.path.join(src, "src")]
    files = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            if "node_modules" in dirpath:
                continue
            for fn in filenames:
                if fn.endswith((".ts", ".tsx")):
                    files.append(os.path.join(dirpath, fn))

    unstable_map = {"http": "http", "process": "process", "socket": "socket"}
    counts = {"unstable": 0, "tracer": 0, "schedule": 0, "ctxref": 0, "schedule_max": 0}
    for path in files:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        orig = text

        # effect/http/X -> effect/unstable/http/X  (beta.103 moved these)
        for sub in unstable_map:
            text = re.sub(
                rf'(from\s+["\'])effect/{sub}/',
                rf"\1effect/unstable/{sub}/",
                text,
            )

        # @effect/opentelemetry/Tracer -> /OtelTracer (renamed in beta.103)
        if "@effect/opentelemetry/Tracer" in text:
            text = text.replace("@effect/opentelemetry/Tracer", "@effect/opentelemetry/OtelTracer")
            counts["tracer"] += 1

        # Schedule.either(X) inside a pipe -> Schedule.min([...])
        # Only the known v1.19.4 shape is rewritten; anything else must be manual.
        pattern = re.compile(
            r"Schedule\.exponential\(([^)]*)\)\.pipe\(\s*"
            r"Schedule\.either\(Schedule\.spaced\(([^)]*)\)\),",
            re.M,
        )
        both_pat = re.compile(
            r'Schedule\.spaced\("([^"]+)"\)\.pipe\(Schedule\.both\(Schedule\.recurs\((\d+)\)\)\)'
        )
        if "Schedule.either(" in text:
            def repl(m):
                return (
                    "Schedule.min([\n"
                    f"    Schedule.exponential({m.group(1)}),\n"
                    f"    Schedule.spaced({m.group(2)}),\n"
                    "  ]).pipe("
                )
            new_text, n = pattern.subn(repl, text)
            if n == 0:
                die(
                    "Schedule.either( found but the known pipe shape did not match "
                    f"in {path} — rewrite it manually (beta.103 replaced either/both "
                    "with array-taking min/max)"
                )
            text = new_text
            counts["schedule"] += n

        # Context.getReferenceUnsafe was removed in beta.103. The call sites want
        # "unbound -> undefined" (they use `?? fallback` / `? :` right after), so
        # getOrUndefinedUnsafe is the exact replacement, not getUnsafe (which throws).
        if "Context.getReferenceUnsafe(" in text:
            text = text.replace("Context.getReferenceUnsafe(", "Context.getOrUndefinedUnsafe(")
            counts["ctxref"] += 1

        # Schedule.both(a, b) -> Schedule.max([a, b]) — same array form as min;
        # both means "keep going until either would stop", i.e. the larger one.
        if "Schedule.both(" in text:
            def repl_both(m):
                return 'Schedule.max([Schedule.spaced("%s"), Schedule.recurs(%s)])' % (m.group(1), m.group(2))
            new_text, n = both_pat.subn(repl_both, text)
            if n == 0:
                die(
                    "Schedule.both( found but the known spaced/recurs shape did not match "
                    f"in {path} — rewrite it manually (beta.103 replaced either/both "
                    "with array-taking min/max)"
                )
            text = new_text
            counts["schedule_max"] += n

        if text != orig:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            counts["unstable"] += 1

    note(
        "source rewrites: unstable-path files={unstable} tracer-files={tracer} "
        "schedule-min={schedule} ctx-ref-unsafe={ctxref} schedule-max={schedule_max}".format(**counts)
    )

    # 5) assertion: no stale subpaths remain
    leftovers = subprocess.run(
        ["grep", "-rl", "--include=*.ts", "-E", r"from [\"']effect/(http|process|socket)/", *roots],
        capture_output=True, text=True,
    ).stdout.strip()
    if leftovers:
        die(f"stale effect subpaths still present:\n{leftovers}")
    note("assert: no effect/http|process|socket/ imports remain")

    for bad, msg in (
        (r"Context\.getReferenceUnsafe\(", "Context.getReferenceUnsafe (removed in beta.103)"),
        (r"Schedule\.(either|both)\(", "Schedule.either/both (removed in beta.103)"),
    ):
        hits = subprocess.run(
            ["grep", "-rl", "--include=*.ts", "-E", bad, *roots],
            capture_output=True, text=True,
        ).stdout.strip()
        if hits:
            die(f"stale effect API still present ({msg}):\n{hits}")
    note("assert: no removed effect APIs remain (getReferenceUnsafe / Schedule.either|both)")
    return 0


def npm_tarball(pkg, version):
    scope, name = pkg.split("/", 1)
    return f"https://registry.npmjs.org/{scope}%2F{name}/-/{name}-{version}.tgz"


def phase_post(args):
    src = args.src
    store = os.path.join(src, "node_modules", ".bun")
    if not os.path.isdir(store):
        die(f"no store at {store} — run bun install first")

    pkg = "@opentui/core-linux-arm64"
    key = f"@opentui+core-linux-arm64@{args.opentui}"
    target = os.path.join(store, key, "node_modules", "@opentui", "core-linux-arm64")
    so = os.path.join(target, "libopentui.so")

    if os.path.isfile(so) and os.path.getsize(so) > 1_000_000:
        note(f"platform package already present ({os.path.getsize(so)} B) — skip")
    else:
        os.makedirs(target, exist_ok=True)
        url = npm_tarball(pkg, args.opentui)
        note(f"fetching {url}")
        tgz = os.path.join(target, ".platform.tgz")
        try:
            urllib.request.urlretrieve(url, tgz)
        except Exception as exc:  # noqa: BLE001 - surface any network failure
            die(f"download failed: {exc}")
        with tarfile.open(tgz, "r:gz") as tf:
            members = [m for m in tf.getmembers() if m.name.startswith("package/")]
            for m in members:
                m.name = m.name[len("package/"):]
                if not m.name:
                    continue
                tf.extract(m, target)
        os.remove(tgz)
        if not os.path.isfile(so) or os.path.getsize(so) < 1_000_000:
            die(f"extracted tarball has no usable libopentui.so at {so}")
        note(f"extracted {os.path.getsize(so)} B libopentui.so")

    # node_modules/@opentui/core-linux-arm64 must resolve for the JS side
    link_dir = os.path.join(src, "node_modules", "@opentui")
    link = os.path.join(link_dir, "core-linux-arm64")
    os.makedirs(link_dir, exist_ok=True)
    rel = os.path.relpath(target, link_dir)
    if os.path.islink(link):
        if os.readlink(link) != rel:
            os.unlink(link)
            os.symlink(rel, link)
            note("symlink repointed")
    elif os.path.isdir(link):
        note("real directory already present — leave as is")
    else:
        os.symlink(rel, link)
        note("symlink created")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["pre", "post"])
    ap.add_argument("--src", required=True)
    ap.add_argument("--effect", default="4.0.0-beta.103")
    ap.add_argument("--opentui", default="0.4.5")
    args = ap.parse_args()
    if not os.path.isdir(args.src):
        die(f"source dir not found: {args.src}")
    return phase_pre(args) if args.phase == "pre" else phase_post(args)


if __name__ == "__main__":
    sys.exit(main())
