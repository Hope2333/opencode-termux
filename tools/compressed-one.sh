#!/data/data/com.termux/files/usr/bin/bash
# compressed-one.sh — 单版 opencode-compressed 全流程（取源→压制→双包→冒烟→上传→核验→清理）
#
# 收编自 ops 一次性脚本 build-one.sh（Push261005 批 23 版实战验证），把隐性知识
# （size 窗口、双重压制防护、uploads fake-IP 直连、幂等上传、熔断语义）固化进仓库。
#
# 用法:
#   compressed-one.sh <version> [upload|noupload] [--noupx]
# 环境变量:
#   TAG=<批次 tag>          源 native deb 与上传目标 release（默认 Push261013）
#   WORKROOT=<目录>         缓存根（默认 ~/tmp/compressed-one）
#   NOUPX=1                 跳过压制，直接用 OPENCODE_COMPRESSED_BIN（需同时提供）
#   OPENCODE_COMPRESSED_BIN 外部压制产物（NOUPX=1 时必填）
#   DEB_REV=-1 / PKGREL=1   透传打包脚本（默认值即此）
#   OCOMP_FAMILY=opencode   家族（默认 v2；v1 用 opencode1）
#   OCOMP_LAYOUT=standard   single-efl 等布局透传
#   PREFETCH_NEXT=<version> 上传成功后后台预取下一版源 deb（流水化，R4-5）
set -euo pipefail

VER="${1:?usage: compressed-one.sh <version> [upload|noupload] [--noupx]}"
DO_UPLOAD="${2:-upload}"            # upload | noupload
[[ "${3:-}" == "--noupx" ]] && NOUPX=1 || NOUPX="${NOUPX:-0}"
TAG="${TAG:-Push261013}"
REPO="Hope2333/opencode-termux"
FAMILY="${OCOMP_FAMILY:-opencode}"

# REPO_ROOT 经 BASH_SOURCE 推导（tools/ 的上一级），禁硬编码 home
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPX_BIN="${UPX_BIN:-$REPO_ROOT/tools/upx-stub/upx-custom-aarch64}"
SHIM_SO="${SHIM_SO:-$REPO_ROOT/tools/upx-stub/shims/libopencode-crhandler.so}"
WORKROOT="${WORKROOT:-$HOME/tmp/compressed-one}"
SRC="$WORKROOT/src"; RT="$WORKROOT/runtime"; OUT="$WORKROOT/out"; PKG="$WORKROOT/pkg"; SMOKE="$WORKROOT/smoke"
RES="$WORKROOT/RESULTS.txt"
mkdir -p "$SRC" "$RT/$VER" "$OUT" "$PKG" "$SMOKE"

echo "=== [$VER] $(date +%T) start (tag=$TAG family=$FAMILY noupx=$NOUPX upload=$DO_UPLOAD, df: $(df -h "$WORKROOT" | awk 'NR==2{print $4}') free) ==="

# ── 1. runtime 提取（缓存可跳过；源=架上 native deb 的 usr/bin/opencode）──
RUNTIME="$RT/$VER/opencode"
if [[ ! -f "$RUNTIME" ]]; then
  DEB_SRC="$SRC/opencode_${VER}_aarch64.deb"
  # aria2c 被杀会留部分文件 + .aria2；部分文件可能过 size 护栏 → 先清再下
  if [[ -f "$DEB_SRC.aria2" ]]; then rm -f "$DEB_SRC" "$DEB_SRC.aria2"; echo "[src] stale partial cleaned: $DEB_SRC"; fi
  if [[ ! -f "$DEB_SRC" ]]; then
    aria2c -x8 -s8 -k1M --dir "$SRC" -o "opencode_${VER}_aarch64.deb" \
      "https://github.com/$REPO/releases/download/$TAG/opencode_${VER}_aarch64.deb" >/dev/null
  fi
  sz=$(stat -c%s "$DEB_SRC")
  [[ "$sz" -gt 40000000 ]] || { echo "FATAL: source deb too small: $sz"; exit 1; }
  dpkg-deb -x "$DEB_SRC" "$RT/$VER/root"
  mv "$RT/$VER/root/data/data/com.termux/files/usr/bin/opencode" "$RUNTIME"
  rm -rf "$RT/$VER/root"
fi
rsz=$(stat -c%s "$RUNTIME")
# 未压 runtime 窗口：200–600MB。104MB 量级输入 = 已压件（双重压制必崩，本项目踩过两次）
# 窗口 FAMILY 感知: v2 runtime 280MB 级(下限 200M); v1 transplant 产物 135-181MB(下限 120M; 1.18.30-34 实测 135MB 级)
if [[ "$FAMILY" == "opencode1" ]]; then MIN_RT=120000000; else MIN_RT=200000000; fi
[[ "$rsz" -gt "$MIN_RT" && "$rsz" -lt 600000000 ]] || { echo "FATAL: runtime size $rsz out of uncompressed range (double-compress hazard?)"; exit 1; }

# ── 2.5 seccomp harden（#36 修复：手术后压制，对齐 family-v2-compressed 顺序）──
# 无 DT_NEEDED crhandler 的 runtime 在 Android 12 seccomp 下 close_range SIGSYS
# （issue #36：shim 随包但未 interpose=死文件）。手术在 UPX 前（零位移 DT 编辑）。
if [[ "$NOUPX" == "1" ]]; then
  # 外部件：已手术放行，未手术拒绝（不手术已压件=UPX×graft 必崩，v12.4 教训）
  grep -aqF libopencode-crhandler.so "$COMP" 2>/dev/null || {
    echo "FATAL: NOUPX=1 external binary not hardened (no crhandler DT_NEEDED) — pass a hardened binary"; exit 1; }
  echo "[harden] external binary already hardened"
elif ! grep -aqF libopencode-crhandler.so "$RUNTIME" 2>/dev/null; then
  [[ -f "$SHIM_SO" ]] || { echo "FATAL: shim missing: $SHIM_SO"; exit 1; }
  cp "$SHIM_SO" "$RT/$VER/libopencode-crhandler.so"
  cp -p "$RUNTIME" "$RUNTIME.pre-crhandler"
  python3 tools/transplant/crhandler_patch.py "$RUNTIME" || { echo "FATAL: crhandler patch failed"; exit 1; }
  echo "[harden] runtime patched: $(readelf -dW "$RUNTIME" 2>/dev/null | grep -c 'libopencode-crhandler') DT_NEEDED entries"
else
  echo "[harden] runtime already hardened, skip"
fi
rsha=$(sha256sum "$RUNTIME" | cut -d' ' -f1)
echo "[input] runtime $rsz B sha=$rsha"

# ── 2. UPX 压制（缓存可跳过；NOUPX=1 用外部产物）──
COMP="$OUT/${VER}-upx"
if [[ "$NOUPX" == "1" ]]; then
  COMP="${OPENCODE_COMPRESSED_BIN:?NOUPX=1 requires OPENCODE_COMPRESSED_BIN}"
  [[ -x "$COMP" ]] || { echo "FATAL: OPENCODE_COMPRESSED_BIN not executable: $COMP"; exit 1; }
  echo "[upx] skipped (NOUPX=1), using $COMP"
else
  [[ -x "$UPX_BIN" ]] || { echo "FATAL: UPX binary missing: $UPX_BIN"; exit 1; }
  if [[ ! -f "$COMP" ]]; then
    "$UPX_BIN" -4 --no-color -o "$COMP" "$RUNTIME" >/dev/null
  fi
fi

# ── 2.6 v1 族 UPX 后重 graft（2026-10-18 实测: UPX 过程使 swap_tui 的 bionic
# graft 失效——bunfs 提取回退 glibc OpenTUI 件，TUI 崩 "libm.so.6 not found"。
# 修法: 解压→重 graft（等长替换 bionic libopentui.so）→重压。v2 不受影响
# （B 线 graft 在 build.ts 期，TUI 实证 pass）。──
if [[ "$FAMILY" == "opencode1" && "$NOUPX" != "1" ]]; then
  TUI_LIB="$REPO_ROOT/artifacts/transplant/opentui-bionic/libopentui.so"
  [[ -f "$TUI_LIB" ]] || { echo "FATAL: bionic libopentui.so missing: $TUI_LIB"; exit 1; }
  echo "[regraft] decompress -> swap_tui -> repack"
  "$UPX_BIN" -d --no-color -o "$COMP.dec" "$COMP" >/dev/null 2>&1 || { echo "FATAL: regraft decompress failed"; exit 1; }
  python3 tools/transplant/swap_tui.py --binary "$COMP.dec" --tui-lib "$TUI_LIB" --out "$COMP.graft" >/dev/null || { echo "FATAL: regraft swap failed"; exit 1; }
  "$UPX_BIN" -4 --no-color -o "$COMP.new" "$COMP.graft" >/dev/null || { echo "FATAL: regraft repack failed"; exit 1; }
  mv "$COMP.new" "$COMP"; rm -f "$COMP.dec" "$COMP.graft"
  echo "[regraft] done: $(stat -c%s "$COMP") B"
fi
csz=$(stat -c%s "$COMP")
# 压制产物窗口：80–140MB（历史 37% 压缩率带容差；区间外停下）
if [[ "$FAMILY" == "opencode1" ]]; then MIN_CP=40000000; else MIN_CP=80000000; fi
[[ "$csz" -gt "$MIN_CP" && "$csz" -lt 140000000 ]] || { echo "FATAL: compressed size $csz out of range"; exit 1; }
csha=$(sha256sum "$COMP" | cut -d' ' -f1)
ratio=$(awk -v a="$csz" -v b="$rsz" 'BEGIN{printf "%.2f%%", a/b*100}')
echo "[upx] $csz B ($ratio) sha=$csha"

# ── 3. 双包（deb + pacman，走主仓打包脚本；rel 透传）──
env OCOMP_FAMILY="$FAMILY" VERSION="$VER" DEB_REV="${DEB_REV:--1}" \
  OPENCODE_COMPRESSED_BIN="$COMP" OPENCODE_CRHANDLER_SO="$SHIM_SO" \
  "$REPO_ROOT/scripts/package/package_deb_compressed.sh" >"$WORKROOT/log-deb-$VER.txt" 2>&1 \
  || { echo "FATAL: deb build failed, see log-deb-$VER.txt"; tail -5 "$WORKROOT/log-deb-$VER.txt"; exit 1; }
DEB_FILE="$REPO_ROOT/packing/dpkg-compressed/${FAMILY}-compressed_${VER}_aarch64.deb"

env OCOMP_FAMILY="$FAMILY" VERSION="$VER" PKGREL="${PKGREL:-1}" \
  OPENCODE_COMPRESSED_BIN="$COMP" OPENCODE_CRHANDLER_SO="$SHIM_SO" \
  "$REPO_ROOT/scripts/package/package_pacman_compressed.sh" >"$WORKROOT/log-pac-$VER.txt" 2>&1 \
  || { echo "FATAL: pacman build failed, see log-pac-$VER.txt"; tail -5 "$WORKROOT/log-pac-$VER.txt"; exit 1; }
PAC_FILE=$(ls "$REPO_ROOT/packing/pacman/${FAMILY}-compressed-$VER-${PKGREL:-1}-"*.pkg.tar.gz)

deb_sz=$(stat -c%s "$DEB_FILE"); pac_sz=$(stat -c%s "$PAC_FILE")
echo "[pkg] deb=$deb_sz B  pacman=$pac_sz B"

# ── 4. 冒烟（XDG/HOME/dbpath 全隔离——真实 db 曾被污染过）──
rm -rf "$SMOKE/$VER"; mkdir -p "$SMOKE/$VER"/{root,home,config,cache,data,db}
dpkg-deb -x "$DEB_FILE" "$SMOKE/$VER/root"
BIN="$SMOKE/$VER/root/data/data/com.termux/files/usr/bin/$FAMILY"
OLD_HOME="$HOME"
export PREFIX="$SMOKE/$VER/root/data/data/com.termux/files/usr"
export HOME="$SMOKE/$VER/home" XDG_CONFIG_HOME="$SMOKE/$VER/config" \
       XDG_CACHE_HOME="$SMOKE/$VER/cache" XDG_DATA_HOME="$SMOKE/$VER/data"
vout=$("$BIN" --version 2>&1); vrc=$?
hout=$("$BIN" --dbpath "$SMOKE/$VER/db" --help >/dev/null 2>&1; echo $?)
export HOME="$OLD_HOME"; unset OLD_HOME PREFIX XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
echo "[smoke] --version rc=$vrc out='$vout' | --dbpath --help rc=$hout"
[[ "$vrc" -eq 0 && "$hout" -eq 0 ]] || { echo "FATAL: smoke failed"; exit 1; }
[[ "$vout" == *"$VER"* ]] || { echo "FATAL: version string mismatch: $vout"; exit 1; }
# TUI 级冒烟（2026-10-18 #36-后续: v1 compressed 的 UPX 丢 graft 只现形 TUI，
# --version/--help 全绿灯漏网——本段用 pty 实跑 -tui 探 OpenTUI 初始化失败特征）
export HOME="$SMOKE/$VER/home" XDG_CONFIG_HOME="$SMOKE/$VER/config" \
       XDG_CACHE_HOME="$SMOKE/$VER/cache" XDG_DATA_HOME="$SMOKE/$VER/data" \
       PREFIX="$SMOKE/$VER/root/data/data/com.termux/files/usr"
tp=$(python3 tools/transplant/transplant.py tui-probe --product "$BIN" --timeout 20 2>&1 | grep -o '"verdict": "[^"]*"' | head -1 || true)
tui_err=$(timeout 25 "$BIN" -tui 2>&1 | grep -c 'Failed to initialize OpenTUI' || true)
export HOME="$OLD_HOME"; unset OLD_HOME PREFIX XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
echo "[smoke] TUI probe=$tp opentui-fail-count=$tui_err"
[[ "$tp" == *'"pass"'* && "$tui_err" == "0" ]] || { echo "FATAL: TUI smoke failed (probe=$tp err=$tui_err)"; exit 1; }

# ── 5. 上传（单件 + --clobber 幂等 + state/size/digest 三重核验）──
if [[ "$DO_UPLOAD" == "upload" ]]; then
  # uploads.github.com 的代理 fake-IP 规则损坏（TLS 直掐），绕过：DoH 取真实 IP + SNI 直连
  UP_HOST=uploads.github.com
  REL_ID=$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id)
  TOKEN=$(gh auth token)
  UP_IP=$(curl -s --max-time 15 "https://dns.google/resolve?name=uploads.github.com&type=A" \
    | grep -oE '"data":"[0-9.]+"' | grep -oE '[0-9.]+' | head -1)
  [[ -n "$UP_IP" ]] || { echo "FATAL: cannot resolve real uploads IP via DoH"; exit 1; }
  echo "[upload] via $UP_HOST=$UP_IP rel_id=$REL_ID"
  for f in "$DEB_FILE" "$PAC_FILE"; do
    name=$(basename "$f"); lsz=$(stat -c%s "$f"); ok=0
    # 远端逐件跳过（双命名都判：deb 下划线族名_版本，pacman 连字符族名-版本）
    existing=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$name\") | \"\(.id) \(.size)\"" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      eid=$(echo "$existing" | awk '{print $1}'); esz=$(echo "$existing" | awk '{print $2}')
      if [[ "$esz" == "$lsz" ]]; then
        echo "[upload] $name already exists ($esz B), skip"
      else
        echo "[upload] $name exists with wrong size ($esz != $lsz), re-upload"
        gh api -X DELETE "repos/$REPO/releases/assets/$eid" >/dev/null
      fi
    fi
    if [[ "$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$name\") | .name")" != "$name" ]]; then
      for attempt in 1 2 3 4 5; do
        code=$(curl -s --connect-timeout 20 --speed-time 90 --speed-limit 1024 \
          --resolve "$UP_HOST:443:$UP_IP" -X POST \
          -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
          --data-binary @"$f" -o /dev/null -w '%{http_code}' \
          "https://$UP_HOST/repos/$REPO/releases/$REL_ID/assets?name=$name")
        [[ "$code" == "201" ]] && { ok=1; break; }
        # 422 = 同名残留资产（POST 超时留下的 starter 状态）：先删再重试
        if [[ "$code" == "422" ]]; then
          stale=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$name\") | .id" 2>/dev/null || true)
          if [[ -n "$stale" ]]; then
            echo "[upload] 422 on $name: deleting stale starter-state asset $stale before retry"
            gh api -X DELETE "repos/$REPO/releases/assets/$stale" >/dev/null 2>&1 || true
          fi
        fi
        echo "[upload] attempt $attempt failed for $name (http=$code), retry in 20s"
        sleep 20
      done
      [[ "$ok" == 1 ]] || { echo "FATAL: upload failed after 5 attempts: $name"; exit 1; }
    fi
    lsz=$(stat -c%s "$f")
    info=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$name\") | \"\(.state) \(.size) \(.digest)\"" 2>/dev/null || true)
    state=${info%% *}; rsize=$(echo "$info" | awk '{print $2}'); rdigest=$(echo "$info" | awk '{print $3}')
    [[ "$state" == "uploaded" && "$rsize" == "$lsz" ]] \
      || { echo "FATAL: upload verify failed: $name state=$state remote=$rsize local=$lsz"; exit 1; }
    lsha=$(sha256sum "$f" | cut -d' ' -f1)
    if [[ -n "$rdigest" && "$rdigest" != "sha256:$lsha" ]]; then
      echo "FATAL: digest mismatch: $name remote=$rdigest local=sha256:$lsha"; exit 1
    elif [[ -z "$rdigest" ]]; then
      echo "[upload] WARN: $name remote digest empty, digest check degraded (state+size passed)"
    else
      echo "[upload] digest OK ($lsha)"
    fi
    echo "[upload] $name OK ($lsz B)"
  done
fi

# ── 6. 流水化预取（R4-5：下一版源 deb 与本次收尾重叠）──
if [[ -n "${PREFETCH_NEXT:-}" ]]; then
  echo "[prefetch] backgrounding next source deb for $PREFETCH_NEXT"
  setsid nohup bash -c "aria2c -x8 -s8 -k1M --dir '$SRC' -o 'opencode_${PREFETCH_NEXT}_aarch64.deb' \
    'https://github.com/$REPO/releases/download/$TAG/opencode_${PREFETCH_NEXT}_aarch64.deb'" >/dev/null 2>&1 &
fi

# ── 7. 记录 + 清理 ──
{
  echo "$VER | runtime $rsz sha=$rsha | upx $csz ($ratio) sha=$csha | deb $deb_sz | pacman $pac_sz | smoke OK | upload $DO_UPLOAD"
} >> "$RES"
if [[ "$NOUPX" != "1" ]]; then rm -f "$COMP"; fi
rm -rf "$SMOKE/$VER" "$RT/$VER" "$PKG"/*
if [[ "$DO_UPLOAD" == "upload" ]]; then
  # 已上架：本地包为 disposable 副本，清掉
  rm -f "$SRC/opencode_${VER}_aarch64.deb" "$DEB_FILE" "$PAC_FILE"
else
  # noupload：本地留存（todo15 语义：上传统一在发布波）
  echo "[keep] local packages retained: $DEB_FILE $PAC_FILE"
fi
rm -rf "$REPO_ROOT/packing/dpkg-compressed/work" "$REPO_ROOT/packing/pacman/pkg" "$REPO_ROOT/packing/pacman/src"
echo "=== [$VER] done $(date +%T) (df: $(df -h "$WORKROOT" | awk 'NR==2{print $4}') free) ==="
