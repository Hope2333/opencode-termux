#!/data/data/com.termux/files/usr/bin/bash
# matrix-render.sh — render build/matrix/pins.sh from build/matrix/pins.yaml.
#
# Why: the pins table is the single source of truth for pty/opentui/lib/ffi/effect
# per upstream version, but hand-editing shell case patterns invites drift (the
# 2.1.4 wrong-ABI crash and the stale 2.0.0-2.0.24 pins both came from that).
# YAML is the editable source; the shell file is generated.
#
# Contract:
#   - output is byte-for-byte deterministic (versions expanded and sorted,
#     no timestamps) so `matrix-render.sh` twice produces identical files;
#   - the rendered file keeps the same functions/contract as before
#     (matrix_pins_for / matrix_versions / matrix_libopentui_path / matrix_ffi_syms),
#     so consumers need no change;
#   - unknown version still returns 1 (no default row).
#
# Usage:
#   tools/matrix-render.sh            # write build/matrix/pins.sh
#   tools/matrix-render.sh --check    # render to a temp file and diff (exit 1 on drift)
#   tools/matrix-render.sh --stdout   # print to stdout

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$ROOT_DIR/build/matrix/pins.yaml"
OUT="$ROOT_DIR/build/matrix/pins.sh"

MODE="write"
case "${1:-}" in
	--check) MODE="check" ;;
	--stdout) MODE="stdout" ;;
	"") ;;
	*) echo "usage: matrix-render.sh [--check|--stdout]" >&2; exit 2 ;;
esac

[[ -f "$YAML" ]] || { echo "Error: $YAML missing" >&2; exit 1; }

render() {
	python3 - "$YAML" <<'PY'
import sys, yaml

path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8"))
rows = data.get("rows") or []
if not rows:
    print("Error: pins.yaml has no rows", file=sys.stderr)
    sys.exit(1)

REQUIRED = ("pty", "opentui", "lib", "ffi", "effect")


def vt(v):
    return tuple(int(x) for x in str(v).split("."))


def expand(row):
    a, b = str(row.get("from", "")), str(row.get("to", row.get("from", "")))
    if not a or not b:
        print("Error: row needs from/to", file=sys.stderr)
        sys.exit(1)
    va, vb = vt(a), vt(b)
    if va > vb:
        print(f"Error: range from>{a} to={b}", file=sys.stderr)
        sys.exit(1)
    # Crossing a minor version is a hard error, not a long loop: upstream skips
    # patches (1.18.35 then 1.19.0), and walking the patch counter across a minor
    # would generate hundreds of thousands of phantom versions and OOM the host.
    if va[:2] != vb[:2]:
        print(f"Error: range {a}..{b} crosses a minor version — write one row per minor "
              f"(or one row per version)", file=sys.stderr)
        sys.exit(1)
    out, cur = [], va
    while cur <= vb:
        out.append("%d.%d.%d" % cur)
        cur = (cur[0], cur[1], cur[2] + 1)
    return out


seen = {}
for row in rows:
    for field in REQUIRED:
        if field not in row:
            print(f"Error: row {row} missing field {field}", file=sys.stderr)
            sys.exit(1)
    if str(row["lib"]) not in ("tlsdesc", "missing") and not str(row["lib"]).startswith("opentui-"):
        print(f"Error: bad lib {row['lib']}", file=sys.stderr)
        sys.exit(1)
    for ver in expand(row):
        if ver in seen:
            print(f"Error: version {ver} defined twice", file=sys.stderr)
            sys.exit(1)
        seen[ver] = row

# v2 first (ascending), then the v1 line — matches the historical file order
# so `--check` diffs stay empty and reviews are readable.
versions = sorted(seen, key=lambda v: (0 if vt(v)[0] >= 2 else 1, vt(v)))

print("""#!/data/data/com.termux/files/usr/bin/bash
# build/matrix/pins.sh — GENERATED FILE. DO NOT EDIT.
#
# Source of truth: build/matrix/pins.yaml
# Regenerate:      tools/matrix-render.sh
# Drift check:     tools/matrix-render.sh --check   (also run by matrix-check)
#
# Consumers:
#   scripts/lib/build-pins.sh   (resolve_dep_pins / resolve_pin_matrix)
#   scripts/build-bionic.sh     (deploys the matching bionic libopentui + FFI gate)
#   tools/matrix-check.sh       (schema + upstream drift + deliberate upgrades)
#
# Columns printed by matrix_pins_for: pty opentui lib ffi effect
# Unknown versions return 1 — never fall back to a default pin.""")

print()
print("matrix_pins_for() {")
print('\tlocal ver="${1:-}"')
print('\t[[ -n "$ver" ]] || return 1')
print('\tcase "$ver" in')
for ver in versions:
    r = seen[ver]
    print("\t\t%s) printf '%s %s %s %s %s\\n' ;;" % (
        ver, r["pty"], r["opentui"], r["lib"], r["ffi"], r["effect"]))
print("\t\t*) return 1 ;;")
print("\tesac")
print("}")
print()
print("# Enumerate every registered version (used by tools/matrix-check.sh).")
print("matrix_versions() {")
print("\tprintf '%s\\n' \\")
for i in range(0, len(versions), 4):
    chunk = versions[i:i + 4]
    suffix = " \\" if i + 4 < len(versions) else ""
    print("\t\t" + " ".join(chunk) + suffix)
print("}")
print()
print("""# Resolve a lib name to an absolute .so path (empty when the build is missing).
matrix_libopentui_path() {
\tlocal repo_root="$1" name="${2:-}"
\tcase "$name" in
\t\ttlsdesc) printf '%s\\n' "$repo_root/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.so" ;;
\t\tmissing|"") printf '\\n' ;;
\t\t*) printf '%s\\n' "$repo_root/artifacts/transplant/opentui-bionic-${name#opentui-}/libopentui.so" ;;
\tesac
}

# FFI profile → symbols that MUST be exported by the deployed renderer library.
matrix_ffi_syms() {
\tcase "${1:-}" in
\t\tlegacy)
\t\t\tprintf '%s\\n' cancelKittyImageTransport editBufferSetTabWidth getBufferWidthMethod \\
\t\t\t\tgetKittyImageTransport imageCreateFromPixels imageUpdatePixels pollKittyImageTransport \\
\t\t\t\tprocessKittyImageReply setKittyImageTransport pthread_tryjoin_np
\t\t\t;;
\t\tot_ctx)
\t\t\tprintf '%s\\n' ot_scene_set_hooks ot_session_set_kitty_image_transport \\
\t\t\t\tot_session_cancel_kitty_image_transport ot_session_get_kitty_image_transport \\
\t\t\t\tot_session_poll_kitty_image_transport ot_session_process_kitty_image_reply \\
\t\t\t\tot_session_start_kitty_file_probe pthread_tryjoin_np
\t\t\t;;
\t\t*) return 1 ;;
\tesac
}""")
PY
}

case "$MODE" in
	stdout) render ;;
	write)
		tmp="$(mktemp)"
		render > "$tmp" || { rm -f "$tmp"; exit 1; }
		mv "$tmp" "$OUT"
		echo "matrix-render: wrote $OUT ($(grep -c 'printf' "$OUT") data rows)"
		;;
	check)
		tmp="$(mktemp)"
		render > "$tmp" || { rm -f "$tmp"; exit 1; }
		if diff -q "$tmp" "$OUT" >/dev/null; then
			rm -f "$tmp"
			echo "matrix-render --check: OK (generated file matches YAML)"
			exit 0
		fi
		echo "matrix-render --check: DRIFT — build/matrix/pins.sh does not match pins.yaml" >&2
		diff "$tmp" "$OUT" | head -20 >&2
		rm -f "$tmp"
		exit 1
		;;
esac
