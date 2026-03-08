#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

EVENT="${1:-post_install}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
SYS_SKILL_DIR="$PREFIX/lib/opencode/system-skills"
USER_SKILL_DIR="$CFG_DIR/system-skills"
PLUGIN_MANAGER="$PREFIX/lib/opencode/tools/plugin-manager.sh"
SELFCHECK="$PREFIX/lib/opencode/tools/plugin-selfcheck.sh"
HOOK_LOG="${OPENCODE_HOOK_LOG:-$PREFIX/var/log/opencode-hooks.log}"
STRICT_MODE="${OPENCODE_HOOK_STRICT:-0}"
ENABLE_NETWORK="${OPENCODE_HOOK_ENABLE_NETWORK:-0}"
REG_DIR="${OPENCODE_HOOK_STATE_DIR:-$PREFIX/var/lib/opencode/hooks}"
REGISTRY_FILE="${OPENCODE_HOOK_REGISTRY:-$PREFIX/share/opencode/system-skills-registry.json}"
BLOCKLIST_FILE="${OPENCODE_HOOK_BLOCKLIST:-$SYS_SKILL_DIR/blocklist.json}"

mkdir -p "$(dirname "$HOOK_LOG")" "$REG_DIR" "$(dirname "$REGISTRY_FILE")" 2>/dev/null || true

log() {
	local level="$1"
	local msg="$2"
	printf '[opencode-hooks][%s][%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$level" "$msg" | tee -a "$HOOK_LOG" >/dev/null
}

run_or_warn() {
	local desc="$1"
	shift
	if "$@"; then
		log INFO "$desc: ok"
		return 0
	fi
	log WARN "$desc: failed"
	if [[ "$STRICT_MODE" == "1" ]]; then
		return 1
	fi
	return 0
}

core_version() {
	local ver
	ver="$(opencode --version 2>/dev/null || true)"
	if [[ -z "$ver" && -x "$PREFIX/lib/opencode/runtime/opencode" ]]; then
		ver="$($PREFIX/lib/opencode/runtime/opencode --version 2>/dev/null || true)"
	fi
	python3 - "$ver" <<'PY'
import re,sys
s=sys.argv[1]
m=re.search(r'(\d+\.\d+\.\d+)', s)
print(m.group(1) if m else "0.0.0")
PY
}

version_ge() {
	python3 - "$1" "$2" <<'PY'
import re,sys
def v(s):
    m=[int(x) for x in re.findall(r'\d+', s)]
    return tuple((m+[0,0,0])[:3])
raise SystemExit(0 if v(sys.argv[1]) >= v(sys.argv[2]) else 1)
PY
}

version_le() {
	python3 - "$1" "$2" <<'PY'
import re,sys
def v(s):
    m=[int(x) for x in re.findall(r'\d+', s)]
    return tuple((m+[0,0,0])[:3])
raise SystemExit(0 if v(sys.argv[1]) <= v(sys.argv[2]) else 1)
PY
}

update_registry() {
	local plugin_id="$1" event="$2" status="$3" detail="$4" manifest="$5" core_ver="$6" policy="$7" idk="$8" ai="$9" au="${10}"
	python3 - "$REGISTRY_FILE" "$plugin_id" "$event" "$status" "$detail" "$manifest" "$core_ver" "$policy" "$idk" "$ai" "$au" <<'PY'
import json,sys
from datetime import datetime,timezone

path,plugin_id,event,status,detail,manifest,core_ver,policy,idk,ai,au=sys.argv[1:]
now=datetime.now(timezone.utc).isoformat()

try:
    with open(path,'r',encoding='utf-8') as f:
        data=json.load(f)
except Exception:
    data={"items":{}}

items=data.setdefault("items",{})
item=items.get(plugin_id,{})
item.update({
    "last_event": event,
    "last_status": status,
    "last_detail": detail,
    "last_manifest": manifest,
    "core_version": core_ver,
    "policy": policy,
    "idempotency_key": idk,
    "auto_install_latest": ai == "true",
    "auto_update": au == "true",
    "updated_at": now,
})
items[plugin_id]=item
data["updated_at"]=now

with open(path,'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
    f.write("\n")
PY
}

blocked_by_global_blocklist() {
	local plugin_id="$1" cver="$2"
	if [[ ! -f "$BLOCKLIST_FILE" ]]; then
		return 1
	fi
	python3 - "$BLOCKLIST_FILE" "$plugin_id" "$cver" <<'PY'
import json,sys
path,pid,core=sys.argv[1:]
try:
    data=json.load(open(path))
except Exception:
    raise SystemExit(1)
for item in data.get("blocked",[]):
    if item.get("plugin_id")==pid and core in item.get("core_versions",[]):
        print(item.get("reason","blocked by system blocklist"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

process_manifest() {
	local mf="$1"
	local cver line
	local base
	base="$(basename "$mf")"
	if [[ "$base" == "blocklist.json" ]]; then
		return 0
	fi
	cver="$(core_version)"

	line="$({
		python3 - "$mf" "$EVENT" <<'PY'
import json,sys
mf,event=sys.argv[1],sys.argv[2]
data=json.load(open(mf))
if not data.get("enabled", True):
    print("SKIP|disabled")
    raise SystemExit(0)
events=data.get("events", [])
if events and event not in events:
    print("SKIP|event_not_matched")
    raise SystemExit(0)
pid=data.get("plugin_id","")
repo=data.get("repo","")
ai=str(data.get("auto_install_latest",False)).lower()
au=str(data.get("auto_update",False)).lower()
idk=data.get("idempotency_key","")
policy=data.get("policy","warn")
minv=data.get("minimum_core_version","")
maxv=data.get("maximum_core_version","")
blocked=data.get("blocked_core_versions",[])
if not isinstance(blocked,list):
    blocked=[]
print(f"RUN|{pid}|{repo}|{ai}|{au}|{idk}|{policy}|{minv}|{maxv}|{','.join(blocked)}")
PY
	})" || {
		log WARN "manifest parse failed: $mf"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	}

	case "$line" in
	SKIP*)
		log INFO "skip $mf ($line)"
		return 0
		;;
	esac

	local _run plugin_id repo auto_install auto_update idk policy minv maxv blocked marker reason
	IFS='|' read -r _run plugin_id repo auto_install auto_update idk policy minv maxv blocked <<<"$line"
	[[ -n "$plugin_id" ]] || {
		log WARN "manifest missing plugin_id: $mf"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	}

	if [[ -n "$minv" ]] && ! version_ge "$cver" "$minv"; then
		log WARN "skip $plugin_id: core version $cver below minimum $minv"
		update_registry "$plugin_id" "$EVENT" "blocked_min_version" "core=$cver min=$minv" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	fi

	if [[ -n "$maxv" ]] && ! version_le "$cver" "$maxv"; then
		log WARN "skip $plugin_id: core version $cver above maximum $maxv"
		update_registry "$plugin_id" "$EVENT" "blocked_max_version" "core=$cver max=$maxv" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	fi

	if [[ -n "$blocked" ]]; then
		if python3 - "$cver" "$blocked" <<'PY'; then
import sys
core=sys.argv[1]
blocked={x.strip() for x in sys.argv[2].split(',') if x.strip()}
raise SystemExit(0 if core in blocked else 1)
PY
			log WARN "skip $plugin_id: core version $cver explicitly blocked in manifest"
			update_registry "$plugin_id" "$EVENT" "blocked_manifest_list" "core=$cver" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
			[[ "$STRICT_MODE" == "1" ]] && return 1
			return 0
		fi
	fi

	if reason="$(blocked_by_global_blocklist "$plugin_id" "$cver" 2>/dev/null)"; then
		log WARN "skip $plugin_id: $reason"
		update_registry "$plugin_id" "$EVENT" "blocked_global_blocklist" "$reason" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	fi

	if [[ ! -x "$PLUGIN_MANAGER" ]]; then
		log WARN "plugin-manager not executable: $PLUGIN_MANAGER"
		update_registry "$plugin_id" "$EVENT" "warn_no_plugin_manager" "$PLUGIN_MANAGER" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
		[[ "$STRICT_MODE" == "1" ]] && return 1
		return 0
	fi

	marker=""
	if [[ -n "$idk" ]]; then
		marker="$REG_DIR/${idk}.${EVENT}.${cver}.done"
		if [[ -f "$marker" ]]; then
			log INFO "skip $plugin_id: idempotency marker exists ($marker)"
			update_registry "$plugin_id" "$EVENT" "skipped_idempotent" "$marker" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
			return 0
		fi
	fi

	if [[ "$EVENT" == "post_install" && "$auto_install" == "true" ]]; then
		if [[ "$ENABLE_NETWORK" == "1" ]]; then
			run_or_warn "install plugin $plugin_id" "$PLUGIN_MANAGER" install "$plugin_id" "$repo"
		else
			log INFO "auto-install skipped for $plugin_id (network disabled)"
		fi
	fi

	if [[ "$EVENT" == "post_upgrade" && "$auto_update" == "true" ]]; then
		if [[ "$ENABLE_NETWORK" == "1" ]]; then
			run_or_warn "update plugin $plugin_id" "$PLUGIN_MANAGER" update "$plugin_id"
		else
			log INFO "auto-update skipped for $plugin_id (network disabled)"
		fi
	fi

	if [[ -x "$SELFCHECK" ]]; then
		run_or_warn "selfcheck after $plugin_id" "$SELFCHECK"
	fi

	if [[ -n "$marker" ]]; then
		: >"$marker"
	fi

	update_registry "$plugin_id" "$EVENT" "ok" "processed" "$mf" "$cver" "$policy" "$idk" "$auto_install" "$auto_update"
}

main() {
	log INFO "event=$EVENT strict=$STRICT_MODE network=$ENABLE_NETWORK"
	local manifests=()
	if [[ -d "$SYS_SKILL_DIR" ]]; then
		while IFS= read -r -d '' f; do manifests+=("$f"); done < <(find "$SYS_SKILL_DIR" -maxdepth 1 -type f -name '*.json' -print0)
	fi
	if [[ -d "$USER_SKILL_DIR" ]]; then
		while IFS= read -r -d '' f; do manifests+=("$f"); done < <(find "$USER_SKILL_DIR" -maxdepth 1 -type f -name '*.json' -print0)
	fi

	if [[ ${#manifests[@]} -eq 0 ]]; then
		log INFO "no skill manifests found"
		exit 0
	fi

	local mf
	for mf in "${manifests[@]}"; do
		process_manifest "$mf"
	done
}

main "$@"
