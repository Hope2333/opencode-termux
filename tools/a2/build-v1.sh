#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-v1.sh — A2 line: opencode v1 (1.18.32) source compile on android bun.
#
# Produces the beta.83 BASELINE runtime (effect 4.0.0-beta.83 as shipped by
# upstream) — the control anchor for the A2 effect-upgrade line (beta.103
# rebuild targets the beta.83 fiber deadlock that freezes v1 TUI on kernel
# 3.18).
#
# Chain (differs from v2 scripts/build-bionic.sh where v1.18.32 diverged):
#   1. models.dev snapshot   — build.ts generate.ts fetches models.dev at
#      compile time; cached locally and injected via MODELS_DEV_API_JSON so
#      builds are network-independent.
#   2. deps                  — bun install (skipped when the beta.83 store is
#      already complete; this clone ships a warm node_modules).
#   3. opentui graft         — bionic libopentui.so deployed to every store
#      copy (same hard gates as the v2 B line: DT_NEEDED scan, no glibc).
#   4. platform patch        — reuse tools/build-bionic/apply-platform-patch.sh
#      (@opentui/core 0.4.5 probes process.platform the same way as 0.5.x).
#   5. target filter patch   — v1 build.ts has no --target flag and `--single`
#      filters by process.platform ("android" on our bun) which would select
#      ZERO targets; idempotently narrow the non-single branch to
#      linux/arm64/gnu/baseline-free instead.
#   6. compile               — packages/opencode/script/build.ts
#      --skip-install --skip-embed-web-ui (web UI embed skipped: disk-bound,
#      irrelevant to the TUI anchor; recorded as a known difference vs shelf).
#   7. normalize + smoke     — artifacts/build/<VER>/opencode-v1-<VER>-beta83-baseline
#      + build.json/sha256, then --version and tools/transplant/tui_smoke.py.
#
# Environment:
#   VER            version tag (default 1.18.32)
#   V1_SRC         v1 source tree (default $TMPDIR/a2-src/opencode-$VER)
#   ANDROID_BUN    android bun (default bun-1.4.0 — the 1.3.14 android base
#                  cannot compile: its resolver walks up past the workspace and
#                  dies on /data/data AccessDenied even for hello-world, and
#                  compiled products SIGSEGV at startup; 1.4.0 satisfies the
#                  v1.18.32 packageManager gate ^1.3.14 and is the B-line pin)
#   OPENAT2_SHIM   LD_PRELOAD shim for install-only paths
#   BUILTIN_SO     bionic libopentui.so to graft
#   MODELS_JSON    models.dev api.json cache (fetched on first run)
#   BUILD_ROOT     output root (default artifacts/build)
#   SKIP_SMOKE     1 = skip TUI smoke (default 0)

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="${VER:-1.18.32}"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-$VER}"
ANDROID_BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.0/bun}"
OPENAT2_SHIM="${OPENAT2_SHIM:-$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so}"
BUILTIN_SO="${BUILTIN_SO:-$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/artifacts/build}"
MODELS_JSON="${MODELS_JSON:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/models.dev-api.json}"
OUT_DIR="$BUILD_ROOT/$VER"
TAG="beta83-baseline"

for f in "$V1_SRC/packages/opencode/script/build.ts" "$ANDROID_BUN" "$OPENAT2_SHIM" "$BUILTIN_SO"; do
  [[ -e "$f" ]] || { echo "Error: missing $f" >&2; exit 1; }
done

df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 1200 ]] || {
  echo "Error: only ${FREE_MB}MB free on /data (<1200MB gate) — clean scratch first" >&2; exit 1; }
echo "==> build-v1 (A2) VER=$VER  free=${FREE_MB}MB"
echo "    src = $V1_SRC"
echo "    bun = $ANDROID_BUN ($("$ANDROID_BUN" --version))"

# ── 1. models.dev snapshot ─────────────────────────────────────────────
if [[ ! -s "$MODELS_JSON" ]]; then
  echo "==> fetching models.dev api.json snapshot..."
  mkdir -p "$(dirname "$MODELS_JSON")"
  ok=0
  for a in 1 2 3; do
    if curl -fsSL --max-time 120 "https://models.dev/api.json" -o "$MODELS_JSON"; then ok=1; break; fi
    sleep $((a * 5))
  done
  [[ $ok -eq 1 && -s "$MODELS_JSON" ]] || { echo "Error: models.dev snapshot fetch failed" >&2; exit 1; }
fi
echo "    models snapshot: $(du -h "$MODELS_JSON" | cut -f1) ($MODELS_JSON)"

# ── 2. deps (idempotent; store completeness keyed on effect beta.83) ──
if ! ls -d "$V1_SRC/node_modules/.bun/effect@4.0.0-beta.83" >/dev/null 2>&1; then
  echo "==> bun install (effect beta.83 store missing)..."
  (cd "$V1_SRC" && LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts 2>&1 | tail -3)
else
  echo "==> deps OK (effect beta.83 store present, $(ls "$V1_SRC/node_modules/.bun" | wc -l) store keys)"
fi

# ── 3. opentui graft (every libopentui.so under node_modules) ─────────
if readelf -d "$BUILTIN_SO" 2>/dev/null | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]'; then
  echo "Error: $BUILTIN_SO is glibc-linked — refusing" >&2; exit 1; fi
mapfile -t SO_TARGETS < <(find "$V1_SRC/node_modules" "$V1_SRC/packages/opencode/node_modules" \
  -name libopentui.so 2>/dev/null | sort -u)
[[ ${#SO_TARGETS[@]} -ge 1 ]] || { echo "Error: no libopentui.so found in store" >&2; exit 1; }
for so in "${SO_TARGETS[@]}"; do
  cp -p "$BUILTIN_SO" "$so"
  echo "    grafted bionic libopentui.so -> ${so#$V1_SRC/}"
done
for so in "${SO_TARGETS[@]}"; do
  if readelf -d "$so" 2>/dev/null | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]'; then
    echo "Error: $so still glibc-linked after graft" >&2; exit 1
  fi
done
echo "    graft gate OK: ${#SO_TARGETS[@]} copies all bionic"

# ── 4. platform patch (reuse v2 tool; 0.4.5 probes platform identically) ──
# The tool discovers the loader by the PRE-patch content 'platform: process.platform';
# once patched that literal is gone, so skip when already applied.
CHUNK="$(ls -d "$V1_SRC"/node_modules/.bun/@opentui+core@*/ 2>/dev/null | head -n1 || true)"
: "${CHUNK:?Error: @opentui+core store chunk not found}"
if grep -q 'platform: process.platform' "${CHUNK%/}"/node_modules/@opentui/core/chunk-bun-*.js 2>/dev/null; then
  "$ROOT_DIR/tools/build-bionic/apply-platform-patch.sh" "${CHUNK%/}"
else
  echo "    platform patch already applied (skip)"
fi

# ── 5. target filter patch (A2: linux/arm64/gnu only; idempotent) ─────
BUILD_TS="$V1_SRC/packages/opencode/script/build.ts"
if ! grep -q 'A2_TARGET_FILTER' "$BUILD_TS"; then
  grep -n '^  : allTargets$' "$BUILD_TS" >/dev/null || {
    echo "Error: build.ts anchor ': allTargets' drifted — patch manually" >&2; exit 1; }
  sed -i 's#^  : allTargets$#  : allTargets.filter((item) => item.os === "linux" \&\& item.arch === "arm64" \&\& !item.abi \&\& !item.avx2) /* A2_TARGET_FILTER */#' "$BUILD_TS"
  echo "    target filter patched (linux-arm64 gnu only)"
else
  echo "    target filter already patched"
fi

# ── 6. compile ─────────────────────────────────────────────────────────
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 900 ]] || { echo "Error: ${FREE_MB}MB free before compile (<900MB)" >&2; exit 1; }
echo "==> compiling (android bun, target=bun-linux-arm64, no web-ui embed)..."
# Run from the source ROOT: packages/opencode/bunfig.toml has preload=@opentui/solid/preload
# and the android bun's preload resolver walks up past the workspace to /data/data and
# dies (AccessDenied). bunfig is loaded from cwd at startup, and the root bunfig has no
# preload; module imports through the symlinked node_modules work fine from the root.
cd "$V1_SRC"
LD_PRELOAD="$OPENAT2_SHIM" OPENCODE_VERSION="$VER" MODELS_DEV_API_JSON="$MODELS_JSON" \
  "$ANDROID_BUN" packages/opencode/script/build.ts --skip-install --skip-embed-web-ui
DIST_BIN="$V1_SRC/packages/opencode/dist/opencode-linux-arm64/bin/opencode"
[[ -x "$DIST_BIN" ]] || { echo "Error: build output missing: $DIST_BIN" >&2; exit 1; }

# ── 7. normalize ───────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
OUT_BIN="$OUT_DIR/opencode-v1-$VER-$TAG"
mv -f "$DIST_BIN" "$OUT_BIN"
sha256sum "$OUT_BIN" | awk '{print $1}' > "$OUT_DIR/build-v1-$VER-$TAG.sha256"
echo "==> normalized: $OUT_BIN ($(stat -c%s "$OUT_BIN") B)"
echo "    sha256: $(cat "$OUT_DIR/build-v1-$VER-$TAG.sha256")"

python3 - "$OUT_DIR" "$VER" "$V1_SRC" "$ANDROID_BUN" "$OUT_BIN" << 'PYEOF'
import json, hashlib, os, sys
out_dir, ver, src, bun, out_bin = sys.argv[1:6]
rec = {
  "version": ver,
  "kind": "native-a2-v1-baseline",
  "tag": "beta83-baseline",
  "source": src,
  "android_bun": bun,
  "effect": "4.0.0-beta.83 (upstream catalog, control anchor)",
  "note": "v1 source compile on android bun (bionic); bionic libopentui grafted pre-embed; web-ui embed skipped (A2 anchor is TUI + --version); pty uses @lydell/node-pty gnu asset (known gap, not exercised by anchor)",
  "size": os.path.getsize(out_bin),
  "sha256": hashlib.sha256(open(out_bin, "rb").read()).hexdigest(),
}
with open(os.path.join(out_dir, f"build-v1-{ver}-beta83-baseline.json"), "w") as f:
    json.dump(rec, f, indent=2, ensure_ascii=False)
print("    wrote build json")
PYEOF

# ── 8. smoke ───────────────────────────────────────────────────────────
if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
  echo "==> smoke: --version"
  V_OUT="$("$OUT_BIN" --version)" || { echo "Error: --version failed" >&2; exit 1; }
  echo "    --version = $V_OUT"
  [[ "$V_OUT" == *"$VER"* ]] || { echo "Error: version mismatch: $V_OUT" >&2; exit 1; }
  echo "==> smoke: TUI render (tui_smoke.py)"
  python3 "$ROOT_DIR/tools/transplant/tui_smoke.py" "$OUT_BIN" --timeout 30
  echo "==> TUI smoke PASS"
fi

echo "==> build-v1 done: $OUT_BIN"
