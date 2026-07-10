#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ci.sh"

BUN_VERSION="${1:?bun version required}"
OUT_DIR="${2:?out dir required}"
ABS_OUT_DIR="$(ci_prepare_out_dir "$OUT_DIR")"

ci_require_host_bun

"$HOST_BUN" build --help >"$ABS_OUT_DIR/logs/bun-build-help.txt" || true

cat >"$ABS_OUT_DIR/work/hello.ts" <<'TS'
console.log("hello from bun armv7 probe")
TS

status="failed"
reason="unknown"

if "$HOST_BUN" build "$ABS_OUT_DIR/work/hello.ts" --compile --target=bun-linux-armv7 --outfile "$ABS_OUT_DIR/assets/bun-hello-linux-armv7" >"$ABS_OUT_DIR/logs/bun-compile-command.txt" 2>&1; then
	file "$ABS_OUT_DIR/assets/bun-hello-linux-armv7" >"$ABS_OUT_DIR/logs/bun-hello-file.txt" || true
	status="success"
	reason="bun host supports bun-linux-armv7 compile target"
else
	reason="$(ci_compile_failure_reason "$ABS_OUT_DIR/logs/bun-compile-command.txt" "bun compile failed for another reason")"
fi

python3 - <<PY
import json
from pathlib import Path
data = {
  "status": "$status",
  "reason": "$reason",
  "bun_version": "$BUN_VERSION"
}
Path("$ABS_OUT_DIR/status/bun-armv7-attempt.json").write_text(json.dumps(data, indent=2)+"\n")
Path("$ABS_OUT_DIR/status/bun-target-support.json").write_text(json.dumps({
  "target": "bun-linux-armv7",
  "supported": $([ "$status" = "success" ] && echo True || echo False),
  "reason": "$reason"
}, indent=2)+"\n")
PY

[[ "$status" == "success" ]]
