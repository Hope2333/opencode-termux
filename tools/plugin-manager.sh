#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NAME="oh-my-opencode"
DEFAULT_REPO="https://github.com/code-yeongyu/oh-my-opencode.git"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUG_DIR="$CFG_DIR/local-plugins"
SNAP_DIR="$CFG_DIR/plugin-snapshots"

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
	if command -v bun >/dev/null 2>&1; then
		(cd "$pkg" && bun install && (bun run build || bun run compile || true))
	else
		need npm
		(cd "$pkg" && npm install && (npm run build || npm run compile || true))
	fi
	[[ -f "$(entry_of "$name")" ]] || die "missing built plugin entry: $(entry_of "$name")"
}

cmd_install() {
	local name="${1:-$DEFAULT_NAME}" repo="${2:-$DEFAULT_REPO}"
	ensure_dirs
	need git
	snapshot_plugin "$name"
	rm -rf "$(root_of "$name")"
	mkdir -p "$(root_of "$name")"
	git clone "$repo" "$(repo_of "$name")"
	cp -a "$(repo_of "$name")" "$(pkg_of "$name")"
	build_plugin "$name"
	ensure_file_plugin_config "$name"
	log "installed $name -> file://$(entry_of "$name")"
}

cmd_update() {
	local name="${1:-$DEFAULT_NAME}"
	ensure_dirs
	need git
	[[ -d "$(repo_of "$name")/.git" ]] || die "plugin repo missing; run install first"
	snapshot_plugin "$name"
	(cd "$(repo_of "$name")" && git fetch --all --tags && git pull --ff-only)
	rm -rf "$(pkg_of "$name")"
	cp -a "$(repo_of "$name")" "$(pkg_of "$name")"
	build_plugin "$name"
	ensure_file_plugin_config "$name"
	log "updated $name"
}

cmd_list() {
	local name="${1:-$DEFAULT_NAME}"
	ls -1t "$SNAP_DIR/${name}-"* 2>/dev/null || true
}

cmd_rollback() {
	local name="${1:-$DEFAULT_NAME}" arc="${2:-}"
	ensure_dirs
	[[ -n "$arc" ]] || arc="$(ls -1t "$SNAP_DIR/${name}-"* 2>/dev/null | head -n1 || true)"
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
	curl -fsS "http://127.0.0.1:${port}/config" | python3 - <<'PY'
import sys,json
d=json.load(sys.stdin)
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
