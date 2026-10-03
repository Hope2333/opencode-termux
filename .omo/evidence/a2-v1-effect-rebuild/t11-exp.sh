#!/data/data/com.termux/files/usr/bin/bash
# t11-exp.sh — E-A(真实HOME stale-state) + E-B(fakehome 全新环境) 单变量两刀, nohup+采样
# 判据: opencode.log 是否越过 "booting location services"; typescript 增长; 进程自退出?
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo9
AK=/data/data/com.termux/files/usr/lib/opencode1
BIN=$AK/runtime/opencode
RH=/data/data/com.termux/files/home
CFG5C=/mnt/sdcard_ext4/apps/a2todo5b/press2.cfgstats.txt
OUT=$BASE/t11
mkdir -p $OUT

LDENV="env LD_LIBRARY_PATH=$AK:$AK/pty LD_PRELOAD=$AK/libopencode-crhandler.so:$AK/libepoll-compat.so BUN_PTY_LIB=$AK/pty/librust_pty_arm64_musl_patched.so"

echo "== T11 EXP $(date -u +%FT%TZ) host=$(uname -r) =="
echo "--- 5c cfgstats (content-identity baseline) ---"
cat "$CFG5C" 2>/dev/null || echo "(press2.cfgstats.txt missing)"
echo "--- today's real config stats (same metrics) ---"
echo "cfg_files=$(find $RH/.config/opencode -type f 2>/dev/null | wc -l)"
echo "cfg_bytes=$(du -s $RH/.config/opencode 2>/dev/null | cut -f1)KB"
echo "node_modules_dirs=$(find $RH/.config/opencode/node_modules -maxdepth 1 -type d 2>/dev/null | wc -l)"
echo "home_opencode_files=$(find $RH/.opencode -type f 2>/dev/null | wc -l)"

echo "--- phase 0: anchor sanity (files slot + LD env) ---"
$LDENV "$BIN" --version 2>&1 | head -2

run_case() { # TAG HOME_MODE WINDOW
  local TAG=$1 HOMEDIR=$2 WIN=$3
  local TS=$OUT/$TAG.typescript MARK=$OUT/$TAG.mark LOGD
  rm -f "$TS" "$MARK"
  if [ "$HOMEDIR" = real ]; then
    export HOME=$RH TMPDIR=/data/data/com.termux/files/usr/tmp
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    LOGD=$RH/.local/share/opencode/log
  else
    export HOME=$HOMEDIR/home TMPDIR=$HOMEDIR/tmp
    export XDG_CONFIG_HOME=$HOMEDIR/config XDG_DATA_HOME=$HOMEDIR/data
    export XDG_STATE_HOME=$HOMEDIR/state XDG_CACHE_HOME=$HOMEDIR/cache
    LOGD=$HOMEDIR/data/opencode/log
  fi
  cd /mnt/sdcard_ext4/apps/a2todo5b
  echo "$TAG start=$(date -u +%FT%TZ) HOME=$HOME TMPDIR=$TMPDIR" >> "$MARK"
  ( for i in $(seq 1 60); do
      echo "$(date +%s) bytes=$(wc -c < "$TS" 2>/dev/null || echo 0) mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo)" >> "$OUT/$TAG.progress.log"
      sleep 10
    done ) &
  local SAMPLER=$!
  script -qec "timeout $WIN $LDENV '$BIN'" "$TS" > "$OUT/$TAG.script.out" 2>&1 &
  local RUNNER=$!
  sleep 8
  # 记录精确 pid（exe 匹配 BIN 的唯一样本, 禁展开式 kill）
  local BPID=""
  for d in /proc/[0-9]*; do
    [ "$(readlink $d/exe 2>/dev/null)" = "$BIN" ] && BPID=${d#/proc/} && break
  done
  echo "$TAG binpid=$BPID" >> "$MARK"
  wait $RUNNER; local RC=$?
  kill $SAMPLER 2>/dev/null
  # 精确清理: 仅记录在案的 binpid + 其注册 service pid
  [ -n "$BPID" ] && kill -9 "$BPID" 2>/dev/null
  for REG in "$HOME/.local/state/opencode/service.json" "$XDG_STATE_HOME/opencode/service.json"; do
    [ -f "$REG" ] && { SP=$(sed -n 's/.*"pid"[": ]*\([0-9]*\).*/\1/p' "$REG" 2>/dev/null); [ -n "$SP" ] && [ "$SP" != "$BPID" ] && kill -9 "$SP" 2>/dev/null; }
  done
  local TOTAL=$(wc -c < "$TS" 2>/dev/null || echo 0)
  local ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
  echo "== $TAG $(date -u +%FT%TZ) rc=$RC TOTAL=$TOTAL ANSI=$ANSI loglines=$(wc -l < "$LOGD/opencode.log" 2>/dev/null || echo 0)" >> "$OUT/summary.txt"
  echo "-- $TAG log tail:" >> "$OUT/summary.txt"
  tail -4 "$LOGD/opencode.log" 2>/dev/null | cut -c1-200 >> "$OUT/summary.txt"
  tail -c 1200 "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' > "$OUT/$TAG.tail-clean.txt"
  grep -c "location services booted" "$LOGD/opencode.log" 2>/dev/null > "$OUT/$TAG.lsvcbooted" || echo 0 > "$OUT/$TAG.lsvcbooted"
}

# ===== E-A: 真实 HOME, 先备份 stale-state 小文件再移走 =====
BAK=$OUT/bak-realhome
mkdir -p "$BAK"
echo "== E-A backup $(date -u +%FT%TZ) ==" >> "$OUT/summary.txt"
for f in locks service.json session.json kv.json; do
  if [ -e "$RH/.local/state/opencode/$f" ]; then
    cp -a "$RH/.local/state/opencode/$f" "$BAK/$f" 2>/dev/null &&
    mv "$RH/.local/state/opencode/$f" "$BAK/$f.moved" 2>/dev/null &&
    echo "moved: .local/state/opencode/$f -> $BAK/$f.moved" >> "$OUT/summary.txt"
  fi
done
run_case t11ea real 420

# ===== E-B: fakehome 全新环境（零 config 零缓存零链接）=====
SB=$BASE/sbx-t11eb
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
run_case t11eb $SB 420

echo "== T11 EXP END $(date -u +%FT%TZ) ==" >> "$OUT/summary.txt"
echo T11_EXP_DONE
