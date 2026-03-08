#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
CFG_FILE="$CFG_DIR/opencode.json"
OMO_CFG="$CFG_DIR/oh-my-opencode.json"
LOCAL_PLUGINS="$CFG_DIR/local-plugins"
SYSTEM_PLUGINS="${PREFIX:-/data/data/com.termux/files/usr}/lib/opencode/plugins"
SYSTEM_SKILLS="${PREFIX:-/data/data/com.termux/files/usr}/lib/opencode/system-skills"
SKILL_REGISTRY="${PREFIX:-/data/data/com.termux/files/usr}/share/opencode/system-skills-registry.json"
SKILL_BLOCKLIST="${PREFIX:-/data/data/com.termux/files/usr}/lib/opencode/system-skills/blocklist.json"
PM_STATE="$CFG_DIR/plugin-manager-state.json"

json_escape() {
	local s="$1"
	python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$s"
}

print_check() {
	local key="$1" status="$2" detail="$3"
	printf '{"check":%s,"status":%s,"detail":%s}\n' "$(json_escape "$key")" "$(json_escape "$status")" "$(json_escape "$detail")"
}

main() {
	print_check "opencode.bin" "info" "$(command -v opencode || echo missing)"
	if command -v opencode >/dev/null 2>&1; then
		print_check "opencode.version" "info" "$(opencode --version 2>/dev/null || echo unknown)"
	fi

	if [[ -f "$CFG_FILE" ]]; then
		if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$CFG_FILE" >/dev/null 2>&1; then
			print_check "config.opencode_json" "ok" "$CFG_FILE"
			python3 - "$CFG_FILE" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
plugins=d.get("plugin",[])
if not isinstance(plugins,list):
    print('{"check":"config.plugin_mode","status":"warn","detail":"plugin field is not a list"}')
    raise SystemExit(0)
file_plugins=[x for x in plugins if isinstance(x,str) and x.startswith("file://")]
named_plugins=[x for x in plugins if isinstance(x,str) and not x.startswith("file://")]
if file_plugins and not named_plugins:
    print('{"check":"config.plugin_mode","status":"ok","detail":"file-plugin mode"}')
elif file_plugins and named_plugins:
    print('{"check":"config.plugin_mode","status":"warn","detail":"mixed file and named plugin entries"}')
elif named_plugins:
    print('{"check":"config.plugin_mode","status":"warn","detail":"named plugin mode may be unstable on Termux"}')
else:
    print('{"check":"config.plugin_mode","status":"info","detail":"no plugin entries"}')
PY
		else
			print_check "config.opencode_json" "fail" "invalid json: $CFG_FILE"
		fi
	else
		print_check "config.opencode_json" "warn" "missing: $CFG_FILE"
	fi

	if [[ -f "$OMO_CFG" ]]; then
		print_check "config.omo_json" "ok" "$OMO_CFG"
	else
		print_check "config.omo_json" "warn" "missing: $OMO_CFG"
	fi

	if [[ -d "$LOCAL_PLUGINS" ]]; then
		local count
		count="$(find "$LOCAL_PLUGINS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
		print_check "plugins.local.count" "info" "$count"
	else
		print_check "plugins.local.count" "warn" "local plugin dir missing"
	fi

	if [[ -d "$SYSTEM_PLUGINS" ]]; then
		local count2
		count2="$(find "$SYSTEM_PLUGINS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
		print_check "plugins.system.count" "info" "$count2"
	else
		print_check "plugins.system.count" "info" "system plugin dir not present"
	fi

	if [[ -d "$SYSTEM_SKILLS" ]]; then
		local scount
		scount="$(find "$SYSTEM_SKILLS" -mindepth 1 -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
		print_check "skills.system.manifest_count" "info" "$scount"
	else
		print_check "skills.system.manifest_count" "warn" "system skills dir missing"
	fi

	if [[ -f "$SKILL_REGISTRY" ]]; then
		if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SKILL_REGISTRY" >/dev/null 2>&1; then
			print_check "skills.registry" "ok" "$SKILL_REGISTRY"
		else
			print_check "skills.registry" "fail" "invalid json: $SKILL_REGISTRY"
		fi
	else
		print_check "skills.registry" "warn" "missing: $SKILL_REGISTRY"
	fi

	if [[ -f "$SKILL_BLOCKLIST" ]]; then
		if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SKILL_BLOCKLIST" >/dev/null 2>&1; then
			print_check "skills.blocklist" "ok" "$SKILL_BLOCKLIST"
		else
			print_check "skills.blocklist" "fail" "invalid json: $SKILL_BLOCKLIST"
		fi
	else
		print_check "skills.blocklist" "warn" "missing: $SKILL_BLOCKLIST"
	fi

	if [[ -f "$PM_STATE" ]]; then
		if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$PM_STATE" >/dev/null 2>&1; then
			print_check "plugin_manager.state" "ok" "$PM_STATE"
		else
			print_check "plugin_manager.state" "fail" "invalid json: $PM_STATE"
		fi
	else
		print_check "plugin_manager.state" "warn" "missing: $PM_STATE"
	fi
}

main
