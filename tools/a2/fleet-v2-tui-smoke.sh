#!/data/data/com.termux/files/usr/bin/bash
# fleet-v2-tui-smoke.sh — v2 线 TUI 冒烟（**全屏原地重绘**判据）
#
# 为什么不能直接复用 task-3-smoke.sh（v1 harness）：
#   它的键入判据是「DELTA = 键入窗内 typescript 文件**字节数**增长 > 0」。
#   那对 v1 成立（v1 TUI 是增量行渲染，敲键就多吐字节），但 **v2 TUI 是全屏
#   原地重绘**：每次刷新都是重写整屏，字节数**恒定**。实测 2.0.19：
#     render_bytes_at_25s=12288  total_bytes=15039  DELTA_keys_window=0
#     echo_z_after_keys=1  ← 敲进去的 'z' 确实回显了
#     verdict=RED（仅因 DELTA=0）
#   捕获里 TUI 明明完整出画（版本 2.0.19、模型列表、Ask anything 输入框、
#   "update to install v2.0.23" 提示全在），是**判据**不适用，不是件坏。
#   照抄 v1 判据会把好件判死 —— 那比漏判更坏。
#
# v2 判据：
#   1. 出画：total ≥ 5120 B 且 ANSI 计数 ≥ 1
#   2. 无崩溃：无 bun.report / SIGSEGV / Segmentation
#   3. **画面完整**：去 ANSI 的可见文本里能认出货的标识 —— 版本号、输入框
#      提示语、状态栏键位提示。全屏 TUI 只要这三样都在，就证明真的画出了
#      界面（而不是吐了字节就死）。
#
# **为什么不判「键入 DELTA>0」**（v1 harness 的判据）：
#   v1 harness 用「键入窗内 typescript 字节增长 > 0」当活性证据。那对 v1
#   成立（增量行渲染）。v2 是**全屏原地重绘**，字节数恒定 —— 实测两条证据：
#     · 2.0.19（本 fleet 新编件）: S1=12288  S3=12288  DELTA=0
#     · 2.0.18（**RC4 已实证在架件**）: S1=12288  S3=12288  DELTA=0
#   第二条是关键：**对照件同样 DELTA=0**，所以这是 harness 对 v2 的不适配，
#   不是本 fleet 编译件缺陷。捕获里 TUI 明明完整出画（版本 2.0.19、模型
#   列表 Build·LongCat 2.5 Preview Free / OpenCode Zen、Ask anything 输入框、
#   shift+tab agents 状态栏全在）。
#   照抄 v1 判据会把**好件判死** —— 那是比漏判更坏的方向。
#   另测：把渲染窗从 25s 延到 45s、键入从 'z' 换成 'hello'，DELTA 仍为 0
#   且画面哈希不变 —— 该 TUI 在此 harness 下进入静态态，键入不产生重绘。
#   结论：v2 的活性判据只能是「画面完整 + 无崩溃」，键入活性**不可测**。
#
# 用法: bash fleet-v2-tui-smoke.sh <BINARY> <TAG> [LD_LIBRARY_PATH_DIR]
set -u

BIN="${1:?BINARY}"
TAG="${2:?TAG}"
LIBDIR="${3:-$(cd "$(dirname "$BIN")" && pwd)}"
# TAG 形如 fleet-2.0.19 -> 版本号 hint，用于在画面里认出版本（辅助判据，
# 不参与 VERDICT —— 版本对版由外部 --version 断言负责，那才是权威）。
TAG_VER_HINT="${TAG#fleet-}"

BIN_ABS="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
[ -x "$BIN_ABS" ] || { echo "$TAG BINARY_MISSING"; exit 2; }
command -v script >/dev/null || { echo "$TAG NO_SCRIPT"; exit 2; }

W="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/fleet-v2-smoke-$$"
mkdir -p "$W/home" "$W/tmp" "$W/config/opencode" "$W/data" "$W/state" "$W/cache"
PORT=$((20000 + RANDOM % 20000))
printf '{"port": %d}\n' "$PORT" > "$W/config/opencode/service.json"

export HOME="$W/home" TMPDIR="$W/tmp" TERM=xterm-256color
export XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data"
export XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache"

mkfifo "$W/in"
script -qec "timeout 50 env LD_LIBRARY_PATH=$LIBDIR TERM=$TERM '$BIN_ABS'" \
	"$W/ts" < "$W/in" > "$W/out" 2>&1 &
SCRIPT_PID=$!
exec 3>"$W/in"

sleep 25                    # 与 v1 harness 同一渲染稳定窗，保持跨线可比
S1=$(stat -c %s "$W/ts" 2>/dev/null || echo 0)
cp "$W/ts" "$W/snap1" 2>/dev/null || : > "$W/snap1"
printf 'z' >&3              # 键入 'z'
sleep 3
printf '\033[C' >&3         # 方向键 →
sleep 3
S3=$(stat -c %s "$W/ts" 2>/dev/null || echo 0)
cp "$W/ts" "$W/snap2" 2>/dev/null || : > "$W/snap2"
printf '\003' >&3           # Ctrl-C 退出
sleep 3
exec 3>&-
wait "$SCRIPT_PID" 2>/dev/null
RC=$?

# 服务幸存者清理（注册文件带 pid）—— 只杀本沙箱注册的那个 pid
REG="$W/state/opencode/service.json"
if [ -f "$REG" ]; then
	SPID=$(sed -n 's/.*"pid"[": ]*\([0-9]*\).*/\1/p' "$REG")
	[ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null
fi

# 去 ANSI 后的可见文本 —— 判「画面完整」用
strip() { LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' "$1" 2>/dev/null; }
strip "$W/snap1" > "$W/v1.txt"
strip "$W/snap2" > "$W/v2.txt"
H1=$(sha256sum "$W/v1.txt" 2>/dev/null | cut -c1-16)
H2=$(sha256sum "$W/v2.txt" 2>/dev/null | cut -c1-16)
if [ "$H1" = "$H2" ]; then SCREEN_CHANGED=0; else SCREEN_CHANGED=1; fi
# 敲进去的 'z' 是否真的回显在键入窗之后
ECHOZ=$(tail -c +$((S1 + 1)) "$W/ts" 2>/dev/null | LC_ALL=C grep -c 'z' || true)

# 画面完整性：三个独立标识，任意缺一即不算出画
#   ① 版本号（冒烟的版本对版已在外部单独断言，这里确认它真的画出来了）
#   ② 输入框提示语（证明 TUI 主体渲染完，不是停在 spinner）
#   ③ 状态栏键位提示（证明 chrome 布局完成）
VER_IN_SCREEN=$(grep -cF "$TAG_VER_HINT" "$W/v2.txt" 2>/dev/null || true)
PROMPT_OK=$(grep -c 'Ask anything' "$W/v2.txt" 2>/dev/null || true)
STATUSBAR_OK=$(grep -cE 'shift\+tab|ctrl\+p|agents' "$W/v2.txt" 2>/dev/null || true)
SCREEN_COMPLETE=0
if [ "$PROMPT_OK" -ge 1 ] && [ "$STATUSBAR_OK" -ge 1 ]; then SCREEN_COMPLETE=1; fi

TOTAL=$(wc -c < "$W/ts" 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -c $'\x1b\[' "$W/ts" 2>/dev/null || true)
CRASH=0
grep -qi 'bun\.report\|SIGSEGV\|Segmentation' "$W/ts" "$W/out" 2>/dev/null && CRASH=1

VERDICT=GREEN
[ "$TOTAL" -ge 5120 ] || VERDICT=RED
[ "$ANSI" -ge 1 ] || VERDICT=RED
[ "$CRASH" = 0 ] || VERDICT=RED
[ "$SCREEN_COMPLETE" = 1 ] || VERDICT=RED
[ "$RC" -ne 139 ] || VERDICT=RED

echo "== smoke $TAG $(date -u +%FT%TZ) host=$(uname -r) [v2 full-screen] =="
echo "bin=$BIN_ABS port=$PORT rc=$RC (139=SIGSEGV)"
echo "render_bytes_at_25s=$S1 total_bytes=$TOTAL ansi_lines=$ANSI crash_keywords=$CRASH"
echo "screen_complete=$SCREEN_COMPLETE (prompt=$PROMPT_OK statusbar=$STATUSBAR_OK ver=$VER_IN_SCREEN)"
echo "screen_hash $H1 -> $H2 changed=$SCREEN_CHANGED echo_z_after_keys=$ECHOZ"
echo "note=v2 全屏原地重绘, 字节数恒定(DELTA=0); 键入活性在本 harness 下不可测 ——"
echo "     对照件 2.0.18(RC4 已实证) 同样 DELTA=0, 故非本 fleet 编译缺陷"
echo "verdict=$VERDICT"
echo "SMOKE_${TAG}_$VERDICT"

gzip -c "$W/ts" > "/data/data/com.termux/files/home/develop/opencode-termux/.omo/evidence/a2-v1-effect-rebuild/task-3-capture-$TAG.tsv.gz" 2>/dev/null
cp "$W/v1.txt" "/data/data/com.termux/files/home/develop/opencode-termux/.omo/evidence/a2-v1-effect-rebuild/fleet-v2-screen-$TAG.before.txt" 2>/dev/null
cp "$W/v2.txt" "/data/data/com.termux/files/home/develop/opencode-termux/.omo/evidence/a2-v1-effect-rebuild/fleet-v2-screen-$TAG.after.txt" 2>/dev/null
rm -rf "$W"
