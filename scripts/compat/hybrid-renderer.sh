#!/data/data/com.termux/files/usr/bin/bash
# hybrid-renderer.sh — B 档混合件构建（新版 CLI + 1.18.34 旧 OpenTUI 渲染器）
#
# 背景: opencode >=1.18.35 内嵌 OpenTUI 0.5.14+ 在 kernel<4.x 老设备 TUI 渲染
# 路径竞态 SIGSEGV（oscar 实测 first_bad=1.18.35/last_good=1.18.34, pty 5/5）。
# 本脚本把 1.18.34 bunfs 内的 bionic OpenTUI(0.5.10, 5495136B) 等长换入目标
# 版本 native 件（slot 6037032, 小换大剩余 NUL padding=swap_tui 支持）。
#
# 用法: hybrid-renderer.sh <target-ver> [--donor-ver 1.18.34] <out>
set -euo pipefail
cd "$(dirname "$0")/../.."
TARGET="${1:?usage: hybrid-renderer.sh <target-ver> [donor-ver] <out>}"
DONOR="${2:-1.18.34}"
OUT="${3:?output path}"
WORK=$(mktemp -d ~/tmp/hybrid-XXXX); trap "rm -rf $WORK" EXIT
# 1) donor runtime（native deb 解包）
dpkg-deb -x "packing/dpkg-native/opencode1_${DONOR}_aarch64.deb" "$WORK/donor" 2>/dev/null || {
  echo "FATAL: donor deb missing (opencode1_${DONOR}_aarch64.deb)"; exit 1; }
DONOR_BIN="$WORK/donor/data/data/com.termux/files/usr/lib/opencode1/runtime/opencode"
# 2) 提取 donor 内嵌 OpenTUI
python3 - "$DONOR_BIN" "$WORK/opentui-old.so" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location('swap_tui', 'tools/transplant/swap_tui.py')
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
data = open(sys.argv[1], 'rb').read()
off = st.find_libopentui_asset(data)
assert off > 0, 'donor libopentui asset not found'
size = st.elf_size(data, off)
open(sys.argv[2], 'wb').write(data[off:off+size])
print(f'[donor] opentui slot {size}B @ {off}')
PY
# 3) target runtime（native deb 解包, 已 harden 手术件）
dpkg-deb -x "packing/dpkg-native/opencode1_${TARGET}_aarch64.deb" "$WORK/target" 2>/dev/null || {
  echo "FATAL: target deb missing (opencode1_${TARGET}_aarch64.deb)"; exit 1; }
TARGET_BIN="$WORK/target/data/data/com.termux/files/usr/lib/opencode1/runtime/opencode"
# 4) 等长换入（小换大; guard scan 防 FFI 符号漂移）
python3 tools/transplant/swap_tui.py --binary "$TARGET_BIN" --tui-lib "$WORK/opentui-old.so" --out "$OUT"
echo "[hybrid] $OUT ($(stat -c%s "$OUT")B) = opencode1 $TARGET CLI + OpenTUI 0.5.10 renderer"
