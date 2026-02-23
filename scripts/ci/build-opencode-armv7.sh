#!/usr/bin/env bash
set -euo pipefail

OPENCODE_VERSION="${1:?opencode version required}"
OUT_DIR="${2:?out dir required}"
ABS_OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$ABS_OUT_DIR/assets" "$ABS_OUT_DIR/logs" "$ABS_OUT_DIR/status" "$ABS_OUT_DIR/work/opencode"

HOST_BUN="$HOME/.bun/bin/bun"
if [[ ! -x "$HOST_BUN" ]]; then
	echo "host bun not found at $HOST_BUN" >&2
	exit 10
fi

WORK="$ABS_OUT_DIR/work/opencode"
cd "$WORK"

pack_source=""

if npm pack "@opencode-ai/cli@${OPENCODE_VERSION}" >"$ABS_OUT_DIR/logs/opencode-npm-pack.txt" 2>&1; then
	tgz=$(ls -1 *.tgz | head -n1)
	tar -xzf "$tgz"
	pack_source="npm-scoped-cli"
else
	printf '{\n  "status": "failed",\n  "reason": "@opencode-ai/cli package not available for this version",\n  "opencode_version": "%s",\n  "source": "npm-scoped-cli"\n}\n' "$OPENCODE_VERSION" >"$ABS_OUT_DIR/status/opencode-pack-status.json"
	echo "npm pack @opencode-ai/cli failed" >&2
	exit 20
fi

printf '{\n  "status": "ok",\n  "source": "%s",\n  "opencode_version": "%s"\n}\n' "$pack_source" "$OPENCODE_VERSION" >"$ABS_OUT_DIR/status/opencode-pack-status.json"

python3 - <<'PY' >"$ABS_OUT_DIR/logs/opencode-package-bin.txt"
import json
from pathlib import Path
p=Path('package/package.json')
d=json.loads(p.read_text())
print(json.dumps({"name":d.get("name"),"version":d.get("version"),"bin":d.get("bin")}, indent=2))
PY

BIN_REL=$(
	python3 - <<'PY'
import json
from pathlib import Path
d=json.loads(Path('package/package.json').read_text())
b=d.get('bin')
if isinstance(b, str):
    print(b)
elif isinstance(b, dict):
    print(next(iter(b.values())))
else:
    raise SystemExit(1)
PY
)

ENTRY="package/${BIN_REL}"
if [[ ! -f "$ENTRY" ]]; then
	echo "bin entry not found: $ENTRY" >&2
	exit 30
fi

status="failed"
reason="unknown"
if "$HOST_BUN" build "$ENTRY" --compile --target=bun-linux-armv7 --outfile "$ABS_OUT_DIR/assets/opencode-linux-armv7" >"$ABS_OUT_DIR/logs/opencode-bun-compile.txt" 2>&1; then
	file "$ABS_OUT_DIR/assets/opencode-linux-armv7" >"$ABS_OUT_DIR/logs/opencode-armv7-file.txt" || true
	status="success"
	reason="compiled opencode entry with host bun"
else
	if grep -q "Unsupported target" "$ABS_OUT_DIR/logs/opencode-bun-compile.txt" 2>/dev/null; then
		reason="bun compile target bun-linux-armv7 unsupported by current Bun"
	else
		reason="opencode compile failed for another reason"
	fi
fi

python3 - <<PY
import json
from pathlib import Path
Path("$ABS_OUT_DIR/status/opencode-armv7-attempt.json").write_text(json.dumps({
  "status": "$status",
  "reason": "$reason",
  "opencode_version": "$OPENCODE_VERSION",
  "entry_source": "$pack_source"
}, indent=2)+"\n")
PY

[[ "$status" == "success" ]]
