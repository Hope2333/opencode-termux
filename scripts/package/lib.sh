# scripts/package/lib.sh — 打包脚本公共纯函数（push261013 C3 抽取）
#
# 只放纯函数，不动控制流/heredoc/sed。四个打包脚本以 source 引入：
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# 来源：resolve_version×4、hook_enabled×2（native 对）、append_installed_size×2
# （deb 对）、require_cmd 模式×4（dpkg-deb×2、makepkg×2）—— 均为逐字节重复块。
# 语义与原内联版完全一致（含 exit 1 诊断文案），调用方行为不变。

# resolve_version TRANSPLANT_ROOT — 显式 VERSION 优先，否则解析唯一 transplant
# 构建目录。设置全局 VERSION 并回显；歧义/缺失时带诊断 exit 1（与原内联同文案）。
resolve_version() {
	local root="$1"
	if [[ -z "${VERSION:-}" ]]; then
		shopt -s nullglob
		local builds=("$root"/*)
		shopt -u nullglob
		if [[ ${#builds[@]} -eq 0 ]]; then
			echo "Error: no transplant builds under $root (run: make transplant VER=<x>)" >&2
			exit 1
		fi
		if [[ ${#builds[@]} -gt 1 ]]; then
			echo "Error: multiple transplant builds found; set VERSION=<x> explicitly:" >&2
			printf '  %s\n' "${builds[@]}" >&2
			exit 1
		fi
		VERSION="$(basename "${builds[0]}")"
	fi
	printf '%s' "$VERSION"
}

# require_cmd NAME — 命令存在性守卫（原 4 处逐字节重复块）
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Error: $1 not found" >&2
		exit 1
	}
}

# hook_enabled NAME DEFAULT-GLOB — 打包 hook 注册表解析器（Makefile:
# HOOKS_ENABLE / HOOKS_DISABLE / HOOK_*_VERSIONS）。HOOKS_DISABLE 胜出；
# 否则 hook 的默认版本 glob 决定。
hook_enabled() {
	case " ${HOOKS_DISABLE:-} " in *" $1 "*) return 1 ;; esac
	case " ${HOOKS_ENABLE:-} " in *" $1 "*) return 0 ;; esac
	case "${VERSION:-}" in $2) return 0 ;; *) return 1 ;; esac
}

# append_installed_size ROOT CONTROL — deb control 的 Installed-Size 字段
# （du -sk KB 值；与原 deb 双脚本内联版一致）
append_installed_size() {
	local size
	size=$(du -sk "$1" | cut -f1)
	echo "Installed-Size: $size" >>"$2"
}
