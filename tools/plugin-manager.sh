#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NAME="oh-my-opencode"
DEFAULT_REPO="https://github.com/code-yeongyu/oh-my-opencode.git"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUG_DIR="$CFG_DIR/local-plugins"
SNAP_DIR="$CFG_DIR/plugin-snapshots"
STATE_FILE="$CFG_DIR/plugin-manager-state.json"
GIT_RETRY_MAX="${PLUGIN_GIT_RETRY_MAX:-3}"
GIT_RETRY_DELAY="${PLUGIN_GIT_RETRY_DELAY:-2}"

log() { printf '[plugin-manager] %s\n' "$*"; }
die() {
	printf '[plugin-manager] ERROR: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

root_of() { printf '%s/%s' "$PLUG_DIR" "$1"; }
repo_of() { printf '%s/repo' "$(root_of "$1")"; }
pkg_of() { printf '%s/package' "$(root_of "$1")"; }
entry_of() { printf '%s/dist/index.js' "$(pkg_of "$1")"; }

ensure_dirs() { mkdir -p "$CFG_DIR" "$PLUG_DIR" "$SNAP_DIR"; }

update_state() {
	local action="$1" name="$2" status="$3" detail="$4" repo="${5:-}"
	python3 - "$STATE_FILE" "$action" "$name" "$status" "$detail" "$repo" <<'PY'
import json,sys
from datetime import datetime,timezone

path,action,name,status,detail,repo=sys.argv[1:]
now=datetime.now(timezone.utc).isoformat()

try:
    with open(path,'r',encoding='utf-8') as f:
        data=json.load(f)
except Exception:
    data={"items":{}}

items=data.setdefault("items",{})
entry=items.get(name,{})
entry.update({
    "last_action": action,
    "last_status": status,
    "last_detail": detail,
    "last_repo": repo,
    "updated_at": now,
})
items[name]=entry
data["updated_at"]=now

with open(path,'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
    f.write("\n")
PY
}

git_retry() {
	local attempt=1 delay="$GIT_RETRY_DELAY"
	while true; do
		if "$@"; then
			return 0
		fi
		if [[ "$attempt" -ge "$GIT_RETRY_MAX" ]]; then
			return 1
		fi
		log "git retry ${attempt}/${GIT_RETRY_MAX} failed; sleeping ${delay}s"
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
}

snapshot_latest() {
	local name="$1"
	find "$SNAP_DIR" -maxdepth 1 -type f -name "${name}-*" -print 2>/dev/null | sort -r | head -n1 || true
}

rollback_if_available() {
	local name="$1" snapshot="$2"
	if [[ -n "$snapshot" && -f "$snapshot" ]]; then
		log "auto-rollback using snapshot=$snapshot"
		cmd_rollback "$name" "$snapshot" || true
	else
		log "auto-rollback skipped: no snapshot available"
	fi
}

snapshot_plugin() {
	local name="$1" root ts out
	root="$(root_of "$name")"
	[[ -d "$root" ]] || return 0
	ts="$(date +%Y%m%d-%H%M%S)"
	if command -v zstd >/dev/null 2>&1; then
		out="$SNAP_DIR/${name}-${ts}.tar.zst"
		tar -C "$PLUG_DIR" -I zstd -cf "$out" "$name"
	else
		out="$SNAP_DIR/${name}-${ts}.tar.gz"
		tar -C "$PLUG_DIR" -czf "$out" "$name"
	fi
	log "snapshot=$out"
}

ensure_file_plugin_config() {
	local name="$1" cfg entry
	cfg="$CFG_DIR/opencode.json"
	entry="file://$(entry_of "$name")"
	python3 - "$cfg" "$entry" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); e=sys.argv[2]
if p.exists():
    data=json.loads(p.read_text())
else:
    data={"$schema":"https://opencode.ai/config.json"}
plugins=data.get("plugin")
if plugins is None:
    data["plugin"]=[e]
elif isinstance(plugins,list):
    if e not in plugins: plugins.append(e)
else:
    raise SystemExit("plugin field is not a list")
p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n")
print(e)
PY
}

build_plugin() {
	local name="$1" pkg
	pkg="$(pkg_of "$name")"
	[[ -f "$pkg/package.json" ]] || die "missing package.json: $pkg"
	_npm_install_fallback() {
		if ! (cd "$pkg" && npm install); then
			log "npm install failed; retrying with linux platform compatibility flags"
			(cd "$pkg" && npm_config_platform=linux npm_config_force=true npm install --force)
			if [[ ! -f "$pkg/node_modules/@code-yeongyu/comment-checker/package.json" ]]; then
				log "linux-platform retry still missing android-unsupported deps; pruning from package.json and retrying"
				python3 - "$pkg/package.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
d=json.loads(p.read_text())
changed=False
for key in ("dependencies","devDependencies","optionalDependencies"):
    obj=d.get(key)
    if isinstance(obj,dict) and "@code-yeongyu/comment-checker" in obj:
        del obj["@code-yeongyu/comment-checker"]
        changed=True
if changed:
    p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n")
PY
				(cd "$pkg" && npm install --force)
			fi
		fi
	}

	if command -v bun >/dev/null 2>&1 && [[ "${PLUGIN_FORCE_NPM:-0}" != "1" ]]; then
		if ! (cd "$pkg" && bun install); then
			log "bun install failed; falling back to npm installer path"
			need npm
			_npm_install_fallback
		fi
	else
		need npm
		_npm_install_fallback
	fi

	if command -v bun >/dev/null 2>&1 && [[ "${PLUGIN_FORCE_NPM:-0}" != "1" ]]; then
		(cd "$pkg" && (bun run build || bun run compile || npm run build || npm run compile || true))
	else
		(cd "$pkg" && (npm run build || npm run compile || true))
	fi
	[[ -f "$(entry_of "$name")" ]] || die "missing built plugin entry: $(entry_of "$name")"
}

cmd_install() {
	local name="${1:-$DEFAULT_NAME}" repo="${2:-$DEFAULT_REPO}"
	local snapshot=""
	ensure_dirs
	need git
	snapshot_plugin "$name"
	snapshot="$(snapshot_latest "$name")"
	rm -rf "$(root_of "$name")"
	mkdir -p "$(root_of "$name")"
	if ! git_retry git clone "$repo" "$(repo_of "$name")"; then
		update_state "install" "$name" "error" "git_clone_failed" "$repo"
		rollback_if_available "$name" "$snapshot"
		die "git clone failed for $repo"
	fi
	cp -a "$(repo_of "$name")" "$(pkg_of "$name")"
	if ! build_plugin "$name"; then
		update_state "install" "$name" "error" "build_failed" "$repo"
		rollback_if_available "$name" "$snapshot"
		die "plugin build failed for $name"
	fi
	if ! ensure_file_plugin_config "$name"; then
		update_state "install" "$name" "error" "config_update_failed" "$repo"
		rollback_if_available "$name" "$snapshot"
		die "failed to update plugin config for $name"
	fi
	update_state "install" "$name" "ok" "installed" "$repo"
	log "installed $name -> file://$(entry_of "$name")"
}

cmd_update() {
	local name="${1:-$DEFAULT_NAME}"
	local snapshot="" repo_url=""
	ensure_dirs
	need git
	[[ -d "$(repo_of "$name")/.git" ]] || die "plugin repo missing; run install first"
	snapshot_plugin "$name"
	snapshot="$(snapshot_latest "$name")"
	repo_url="$(cd "$(repo_of "$name")" && git remote get-url origin 2>/dev/null || true)"
	if ! (cd "$(repo_of "$name")" && git_retry git fetch --all --tags && git_retry git pull --ff-only); then
		update_state "update" "$name" "error" "git_update_failed" "$repo_url"
		rollback_if_available "$name" "$snapshot"
		die "git update failed for $name"
	fi
	rm -rf "$(pkg_of "$name")"
	cp -a "$(repo_of "$name")" "$(pkg_of "$name")"
	if ! build_plugin "$name"; then
		update_state "update" "$name" "error" "build_failed" "$repo_url"
		rollback_if_available "$name" "$snapshot"
		die "plugin build failed for $name"
	fi
	if ! ensure_file_plugin_config "$name"; then
		update_state "update" "$name" "error" "config_update_failed" "$repo_url"
		rollback_if_available "$name" "$snapshot"
		die "failed to update plugin config for $name"
	fi
	update_state "update" "$name" "ok" "updated" "$repo_url"
	log "updated $name"
}

cmd_list() {
	local name="${1:-$DEFAULT_NAME}"
	find "$SNAP_DIR" -maxdepth 1 -type f -name "${name}-*" -print 2>/dev/null | sort -r || true
}

cmd_rollback() {
	local name="${1:-$DEFAULT_NAME}" arc="${2:-}"
	ensure_dirs
	[[ -n "$arc" ]] || arc="$(snapshot_latest "$name")"
	[[ -n "$arc" && -f "$arc" ]] || die "snapshot not found"
	rm -rf "$(root_of "$name")"
	mkdir -p "$PLUG_DIR"
	case "$arc" in
	*.tar.zst) tar -C "$PLUG_DIR" -I zstd -xf "$arc" ;;
	*.tar.gz) tar -C "$PLUG_DIR" -xzf "$arc" ;;
	*) die "unsupported snapshot format: $arc" ;;
	esac
	[[ -f "$(entry_of "$name")" ]] || die "restored snapshot missing dist/index.js"
	ensure_file_plugin_config "$name"
	update_state "rollback" "$name" "ok" "rolled_back" ""
	log "rolled back $name from $arc"
}

cmd_patch_export() {
	local name="${1:-$DEFAULT_NAME}" outdir="$SNAP_DIR/patches" out
	mkdir -p "$outdir"
	[[ -d "$(repo_of "$name")/.git" ]] || die "plugin repo missing"
	out="$outdir/${name}-$(date +%Y%m%d-%H%M%S).patch"
	(cd "$(repo_of "$name")" && git diff >"$out")
	log "patch exported: $out"
}

cmd_patch_apply() {
	local name="${1:-$DEFAULT_NAME}" patch="${2:-}"
	[[ -n "$patch" ]] || die "usage: patch-apply [name] <patch-file>"
	[[ -f "$patch" ]] || die "patch not found: $patch"
	[[ -d "$(repo_of "$name")/.git" ]] || die "plugin repo missing"
	snapshot_plugin "$name"
	(cd "$(repo_of "$name")" && git apply "$patch")
	rm -rf "$(pkg_of "$name")"
	cp -a "$(repo_of "$name")" "$(pkg_of "$name")"
	build_plugin "$name"
	ensure_file_plugin_config "$name"
	log "patch applied and rebuilt"
}

cmd_verify() {
	local port="${1:-7600}"
	command -v curl >/dev/null 2>&1 || die "curl required for verify"
	python3 - "$(curl -fsS "http://127.0.0.1:${port}/config")" <<'PY'
import sys,json
d=json.loads(sys.argv[1])
m=d.get('mcp',{}) if isinstance(d.get('mcp',{}),dict) else {}
a=d.get('agent',{}) if isinstance(d.get('agent',{}),dict) else {}
print('mcp=', sorted(m.keys()))
print('agent_sample=', sorted(a.keys())[:15])
body=json.dumps(d,ensure_ascii=False).lower()
print('mentions_oh_my_opencode=', 'oh-my-opencode' in body)
PY
}

usage() {
	cat <<'TXT'
plugin-manager.sh commands:
  install [name] [repo-url]
  update [name]
  list-snapshots [name]
  rollback [name] [snapshot-file]
  patch-export [name]
  patch-apply [name] <patch-file>
  verify-config [port]
TXT
}

case "${1:-}" in
install)
	shift
	cmd_install "$@"
	;;
update)
	shift
	cmd_update "$@"
	;;
list-snapshots)
	shift
	cmd_list "$@"
	;;
rollback)
	shift
	cmd_rollback "$@"
	;;
patch-export)
	shift
	cmd_patch_export "$@"
	;;
patch-apply)
	shift
	cmd_patch_apply "$@"
	;;
verify-config)
	shift
	cmd_verify "$@"
	;;
"" | -h | --help | help) usage ;;
*) die "unknown command: $1" ;;
esac
