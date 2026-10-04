#!/data/data/com.termux/files/usr/bin/bash
set -e

# init-pacmanV00fix20 — Termux pacman 初始化/自愈脚本（基于 v00fix19 迭代）
#
# v00fix20 变更摘要（对照 v00fix19）:
#   1. 新增 [18/20] 已装包归位：从叠影目录（$PREFIX/data/data/...）反查受影响
#      包名（叠影文件路径剥去 $PREFIX/data 前缀即 pacman 本地库记录的绝对路径，
#      与 `pacman -Ql` 输出求交得到属主包），对受影响集合执行
#      `pacman -S --noconfirm --overwrite '*' <pkgs>` 重装，使其在 RootDir
#      回落 "/" 之后真正落到 /data/data/com.termux/files/usr/... 归位；
#      归位后以 `pacman -Qk <pkgs>`（文件缺失断言）验证，失败红字报错。
#   2. 新增 [19/20] 叠影目录交互式清理：归位成功后询问用户确认（默认不删），
#      仅清理 $PREFIX/data/data/com.termux/files 子树并摘除空壳父目录与哨兵；
#      非交互模式（管道/curl | bash）只报告不删除。归位失败时一律只报告。
#   3. [17/20] 残留检测升级：除列文件外同时反查受影响包名清单（写入报告）；
#      叠影目录定位按「原 RootDir」动态推导（fix19 只查 $PREFIX/data/data，
#      而 RootDir = $PREFIX 上级时叠影实际落在 $PREFIX/../data —— 受影响机
#      实证 /data/data/com.termux/files/data/，fix20 双候选全覆盖）。
#   4. 步骤总数 18 → 20；fix19 其余能力原样保留：
#      RootDir 规范化 / 源解锁 / keyring / 镜像自愈（ftp.agdsn.de）/ db 升级 /
#      缓存迁移 / apt 移除 / strace 落点自检。
#
# 线上一键修复地址（EarlyEmergencyRelease0）:
#   bash <(curl -sL https://github.com/Hope2333/opencode-termux/releases/download/EarlyEmergencyRelease0/init-pacmanV00fix20.sh)

# 调试模式开关：1=开启调试输出，0=静默
DEBUG=0

log() {
    echo -e "$@"
}

echo "[1/20] apt 全量升级 pacman/gnupg/rsync..."
if ! command -v apt >/dev/null 2>&1; then
    echo "  → apt 已移除（此前已切换），跳过本步"
else
    apt update || {
        echo "  !! apt update 失败（疑似镜像同步中），30 秒后重试..."
        sleep 30
        apt update || {
            echo "  !! 重试仍失败，切换备用镜像（清华 TUNA）并再次尝试..."
            for f in "$PREFIX/etc/apt/sources.list" "$PREFIX"/etc/apt/sources.list.d/*.sources; do
                [ -e "$f" ] || continue
                cp -n "$f" "$f.bak" 2>/dev/null || true
                sed -i -E \
                  -e 's#https?://mirror\.nyist\.edu\.cn/termux#https://mirrors.tuna.tsinghua.edu.cn/termux#g' \
                  -e 's#https?://packages\.termux\.dev#https://mirrors.tuna.tsinghua.edu.cn/termux#g' \
                  "$f" 2>/dev/null || true
            done
            apt update || true
        }
    }
    apt full-upgrade -y pacman gnupg rsync || true
fi

echo "[2/20] 预热 gpg 环境..."
gpg --batch --list-keys  >/dev/null 2>&1 || true
gpg --batch --list-secret-keys >/dev/null 2>&1 || true

PACMAN_CONF=$PREFIX/etc/pacman.conf
KEYRING_DIR=$PREFIX/share/pacman/keyrings
REPORT=$HOME/pacman-fix20-report.txt

echo "[3/20] 备份 pacman.conf 并解锁所有官方扩展源..."
cp $PACMAN_CONF{,.bak}
sed -i \
  -e 's/^#\s*\[main\]/[main]/' \
  -e 's/^#\s*\[x11\]/[x11]/' \
  -e 's/^#\s*\[root\]/[root]/' \
  -e 's/^#\s*\[tur\]/[tur]/' \
  -e 's/^#\s*\[tur-continuous\]/[tur-continuous]/' \
  -e 's/^#\s*\[tur-multilib\]/[tur-multilib]/' \
  -e 's/^#\s*\[gpkg\]/[gpkg]/' \
  $PACMAN_CONF

echo "[4/20] pacman.conf 根配置规范化（RootDir 双叠路径修复）..."
# RootDir 启用且指向非 "/" 的绝对路径时，绝对路径包会双叠前缀（见文件头说明）。
# 注释 RootDir 回落默认 "/"；DBPath/CacheDir/HookDir/GPGDir/LogFile 保持绝对路径不动。
# 原 RootDir 值记入 ORIG_ROOTDIR，供 [17] 叠影定位与 [18] 归位映射使用。
ORIG_ROOTDIR=""
rootdir_line=$(grep -E '^[[:space:]]*RootDir[[:space:]]*=' "$PACMAN_CONF" | head -n1 || true)
if [ -n "$rootdir_line" ]; then
    rootdir_val="${rootdir_line#*=}"
    rootdir_val=$(echo "$rootdir_val" | xargs)
    if [ -n "$rootdir_val" ] && [ "$rootdir_val" != "/" ]; then
        ORIG_ROOTDIR="${rootdir_val%/}"
        sed -i -E 's|^([[:space:]]*RootDir[[:space:]]*=)|#\1|' "$PACMAN_CONF"
        echo "  → 检测到 RootDir = $rootdir_val（非 \"/\" 的绝对路径，会与包内绝对路径叠加）"
        echo "  → 已注释该行并回落默认 \"/\"，原值已记录到 $REPORT"
        {
            echo "[$(date '+%F %T')] [4/20] RootDir 规范化：原值 = $rootdir_val（已注释，回落默认 /）"
            echo "[$(date '+%F %T')] 若需恢复，编辑 $PACMAN_CONF 取消注释 RootDir 行（仅对相对路径包适用）"
        } >> "$REPORT"
    else
        echo "  → RootDir = \"/\" 或为空，无需处理"
    fi
else
    echo "  → 未启用 RootDir（默认 \"/\"），无需处理"
fi

echo "[5/20] 禁签 + 占位 keyring..."
sed -i 's/^SigLevel.*/SigLevel = Never/' $PACMAN_CONF
install -dm755 "$KEYRING_DIR"
for f in termux-pacman; do
    touch "$KEYRING_DIR/$f-trusted" \
          "$KEYRING_DIR/$f-revoked"
done

echo "[6/20] 修复 pacman 本地库版本（database is incorrect version）..."
# 触发条件: local/ 目录有残留条目但 ALPM_DB_VERSION 缺失或数值 != 9,
# 任何 pacman 命令都会在 alpm 初始化时直接失败
# (pacman 5.2.2/6.0.2/6.1.0/7.1.0 的 ALPM_LOCAL_DB_VERSION 均为 9)
pkg_dbcheck() {
    pacman -Q >/dev/null 2>&1
}
if ! pkg_dbcheck; then
    echo "  → 本地库异常，尝试 pacman-db-upgrade..."
    pacman-db-upgrade >/dev/null 2>&1 || true
fi
if ! pkg_dbcheck; then
    echo "  → 补写 ALPM_DB_VERSION=9..."
    echo 9 > "$PREFIX/var/lib/pacman/local/ALPM_DB_VERSION" 2>/dev/null || true
fi
if ! pkg_dbcheck && pacman -Q 2>&1 | grep -q "database is incorrect version"; then
    echo "  !! 数据库版本错误仍无法修复，备份后重建空库（仅丢失残留记录）"
    mv "$PREFIX/var/lib/pacman/local" "$PREFIX/var/lib/pacman/local.bak.$(date +%s)" 2>/dev/null || true
    mkdir -p "$PREFIX/var/lib/pacman/local"
fi

echo "[7/20] 检测并修复 pacman 镜像源..."
# service.termux-pacman.dev 对 .db 持续返回 403（官方列表已标注 Not working），
# 探测当前启用镜像，全部不可用则自动切换官方可用镜像 ftp.agdsn.de
MIRROR_LIST=$PREFIX/etc/pacman.d/mirrorlist
mirror_ok() { # $1 = Server 模板（含 $repo/$arch 或不含均可）
    local base i
    base="${1//\$repo/main}"
    base="${base//\$arch/aarch64}"
    # 大陆链路偶发连接失败（000），重试 3 次×双 URL
    for i in 1 2 3; do
        curl -sfI -m 15 "$base/main.db" -o /dev/null 2>/dev/null && return 0
        curl -sfI -m 15 "$base/main/aarch64/main.db" -o /dev/null 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
mirror_found=0
if [ -f "$MIRROR_LIST" ]; then
    while IFS= read -r mline; do
        case "$mline" in
            "Server = "*)
                msrv="${mline#Server = }"
                if mirror_ok "$msrv"; then
                    mirror_found=1
                    echo "  → 当前镜像可用: $msrv"
                    break
                fi
                ;;
        esac
    done < "$MIRROR_LIST"
fi
if [ "$mirror_found" -eq 0 ]; then
    echo "  !! 当前镜像不可用，切换到官方可用镜像 ftp.agdsn.de..."
    mkdir -p "$(dirname "$MIRROR_LIST")"
    if [ -f "$MIRROR_LIST" ]; then
        sed -i 's|^Server = |# Server = |' "$MIRROR_LIST"
    else
        : > "$MIRROR_LIST"
    fi
    mtmp=$(mktemp)
    printf '## Auto-switched by init-pacmanV00fix20 (previous mirror unavailable)\nServer = https://ftp.agdsn.de/termux-pacman/$repo/$arch\n' > "$mtmp"
    cat "$MIRROR_LIST" >> "$mtmp"
    mv "$mtmp" "$MIRROR_LIST"
    echo "  → 已切换: $MIRROR_LIST"
fi

echo "[8/20] 初始化 keyring 并同步数据库..."
pacman-key --init || true
pacman -Sy --noconfirm --overwrite '*' || true

echo "[9/20] 安装 termux-keyring..."
pacman -S --noconfirm --overwrite '*' termux-keyring || true

echo "[10/20] 尝试导入 apt 包列表到 pacman..."
if command -v dpkg >/dev/null 2>&1; then
    dpkg --get-selections | awk '$2=="install"{print $1}' > ~/pkglist.txt
    pacman -S --needed --noconfirm --overwrite '*' - < ~/pkglist.txt || true
    rm ~/pkglist.txt
else
    echo "  → dpkg 已移除，跳过导入"
fi

echo "[11/20] 修正 pacman 目录权限..."
if [ -d "$PREFIX/var/lib/pacman" ]; then
    if [ "$DEBUG" -eq 1 ]; then
        chown root:root "$PREFIX/var/lib/pacman" -R || true
        chmod 755 "$PREFIX/var/lib/pacman" || true
    else
        chown root:root "$PREFIX/var/lib/pacman" -R >/dev/null 2>&1 || true
        chmod 755 "$PREFIX/var/lib/pacman" >/dev/null 2>&1 || true
    fi
else
    [ "$DEBUG" -eq 1 ] && echo "  → 目录不存在，跳过权限修正"
fi

echo "[12/20] 全量升级（强制覆盖冲突文件）..."
pacman -Syyu --noconfirm --overwrite '*' || true

echo "[13/20] 移除 apt/dpkg 并切换 pkg 到 pacman..."
pacman -Rns --noconfirm apt dpkg 2>/dev/null || true
termux-setup-package-manager || true
ln -sf $PREFIX/bin/pkg $PREFIX/bin/apt
ln -sf $PREFIX/bin/pkg $PREFIX/bin/apt-get

echo "[14/20] 迁移 pacman 缓存目录并建立软链..."
NEW_CACHE=/data/data/com.termux/cache/pacman
OLD_CACHE=$PREFIX/var/cache/pacman
mkdir -p "$NEW_CACHE"
if [ -d "$OLD_CACHE" ] && [ ! -L "$OLD_CACHE" ]; then
    mv "$OLD_CACHE"/* "$NEW_CACHE"/ 2>/dev/null || true
    rm -rf "$OLD_CACHE"
fi
ln -sf "$NEW_CACHE" "$OLD_CACHE"

echo "[15/20] 检测 termux-keyring 是否安装成功..."
if pacman -Qi termux-keyring >/dev/null 2>&1; then
    # Termux 的 keyring 名为 termux-pacman（文件来自 termux-keyring 包），
    # 若缺失则重装一次；仍缺失则保持免签模式
    if [ ! -f "$KEYRING_DIR/termux-pacman.gpg" ]; then
        echo "  → termux-keyring 已装但缺 keyring 文件，尝试重装..."
        pacman -S --noconfirm --overwrite '*' termux-keyring >/dev/null 2>&1 || true
    fi
    if [ -f "$KEYRING_DIR/termux-pacman.gpg" ]; then
        echo "  → 存在真实 keyring 文件，恢复严格签名模式"
        sed -i 's/^SigLevel.*/SigLevel = DatabaseRequired/' $PACMAN_CONF
        echo "[16/20] 重新初始化+导入 keyring 并测试更新..."
        pacman-key --init
        pacman-key --populate || true
        if pacman-key --list-keys 2>/dev/null | grep -q '^pub'; then
            pacman -Syu --noconfirm --overwrite '*'
        else
            echo "  !! keyring 导入失败（未导入任何公钥），回退免签模式"
            sed -i 's/^SigLevel.*/SigLevel = Never/' $PACMAN_CONF
        fi
    else
        echo "  !! 无法获得 termux-pacman.gpg，保持免签模式以避免卡死"
    fi
else
    echo "  !! termux-keyring 未安装成功，保持免签模式以避免卡死"
fi

RED='\033[31m'; GREEN='\033[32m'; NC='\033[0m'

# ── 叠影目录定位（[17]/[19] 共用）─────────────────────────────────────────
# 叠影顶层 = <原 RootDir>/data（绝对路径包被 pacman 叠加 RootDir 后，成员的
# /data/data/... 前缀落在此处）。覆盖两类病灶场景：
#   A. RootDir = $PREFIX 上级（/data/data/com.termux/files）→ 叠影在
#      $PREFIX/../data（受影响机实证路径）；
#   B. RootDir = $PREFIX 本身 → 叠影在 $PREFIX/data（fix19 原检查点）。
# 再叠加原 RootDir 动态候选兜底。判定须含完整结构 data/com.termux/files/usr。
shadow_tops() {
    local c root_data
    root_data=$(cd "$PREFIX/.." 2>/dev/null && pwd)/data
    for c in "$root_data" "$PREFIX/data"; do
        [ -d "$c/data/com.termux/files/usr" ] && echo "$c"
    done
    if [ -n "$ORIG_ROOTDIR" ] && [ "$ORIG_ROOTDIR" != "/" ]; then
        c="$ORIG_ROOTDIR/data"
        if [ -d "$c/data/com.termux/files/usr" ] && [ "$c" != "$root_data" ] && [ "$c" != "$PREFIX/data" ]; then
            echo "$c"
        fi
    fi
}

echo "[17/20] 双叠路径残留检测 + 受影响包反查（只报告，不删除）..."
# 此前错误配置（RootDir 叠加）把包文件装进了 <原 RootDir>/data/...。
# 叠影文件剥去原 RootDir 前缀后，正是 pacman 本地库记录的绝对路径，
# 据此与 `pacman -Ql` 求交反查属主包，得到待归位包清单（[18] 使用）。
AFFECTED_PKGS=""
SHADOW_TOPS=$(shadow_tops || true)
if [ -n "$SHADOW_TOPS" ]; then
    SHADOW_COUNT=$(find $SHADOW_TOPS -type f 2>/dev/null | wc -l)
    echo -e "${RED}  !! 检测到 pacman 叠影病灶（$SHADOW_COUNT 个文件）:${NC}"
    for t in $SHADOW_TOPS; do
        echo -e "${RED}     $t${NC}"
    done
    echo -e "${RED}     根因: pacman.conf RootDir 指向非 \"/\" 路径时，绝对路径包被装入叠加目录${NC}"
    {
        echo "[$(date '+%F %T')] [17/20] 双叠路径残留（$SHADOW_COUNT 个文件）：$(echo $SHADOW_TOPS | tr '\n' ' ')"
        find $SHADOW_TOPS -type f 2>/dev/null
    } >> "$REPORT"
    echo "  --- 残留文件清单（前 50 条，完整清单见 $REPORT）---"
    find $SHADOW_TOPS -type f 2>/dev/null | head -n 50 | sed 's/^/    /'
    # 反查属主包：一个叠影文件可能对应三种本地库记录形态——
    #   k1 = 原样全路径（旧生成器产物：db 直录双叠绝对路径，pacman -Ql 即叠影路径）
    #   k2 = 剥原 RootDir 后补前导 /（新绝对约定：db 录 /data/data/com.termux/files/usr/...）
    #   k3 = 剥原 RootDir 后不补 /（相对成员约定：db 录 data/data/com.termux/files/usr/...）
    rel_list=$(mktemp)
    for t in $SHADOW_TOPS; do
        eff_root="${t%/data}"   # 叠影顶层 = <原 RootDir>/data
        find "$t" -type f 2>/dev/null | while IFS= read -r f; do
            printf '%s\n' "$f"
            strip="${f#"$eff_root"}"
            printf '/%s\n%s\n' "$strip" "$strip"
        done | sort -u > "$rel_list"
    done
    AFFECTED_PKGS=$(pacman -Ql 2>/dev/null | awk -v list="$rel_list" '
        { pkg=$1; $1=""; sub(/^ /,""); print $0 "\t" pkg }
    ' | sort | join -t "$(printf '\t')" - "$rel_list" 2>/dev/null \
        | cut -f2 | sort -u)
    rm -f "$rel_list"
    if [ -n "$AFFECTED_PKGS" ]; then
        echo -e "${RED}  !! 受影响包（文件被装入叠影目录）: $(echo $AFFECTED_PKGS | tr '\n' ' ')${NC}"
        echo "[$(date '+%F %T')] [17/20] 受影响包清单：$(echo $AFFECTED_PKGS | tr '\n' ' ')" >> "$REPORT"
    else
        echo "  → 叠影文件不匹配任何已装包的记录路径（可能来自已卸载包或历史残留）"
    fi
else
    echo "  → 无双叠路径残留"
fi

echo "[18/20] 已装包归位（受影响包重装至正确路径）..."
# 前置: [4] 已注释 RootDir 回落 "/"，[12] 已完成全量升级。
# 对受影响集合执行 --overwrite 重装，包内绝对路径从 / 起算正好落对；
# 归位后以 pacman -Qk 断言记录路径下文件真实存在（叠影目录因此不再新增）。
RELOCATE_OK=1
if [ -z "$AFFECTED_PKGS" ]; then
    echo "  → 无需归位（无受影响包）"
else
    SHADOW_BEFORE=$(find $SHADOW_TOPS -type f 2>/dev/null | wc -l)
    # shellcheck disable=SC2086
    if pacman -S --noconfirm --overwrite '*' $AFFECTED_PKGS; then
        SHADOW_AFTER=$(find $SHADOW_TOPS -type f 2>/dev/null | wc -l)
        if [ "$SHADOW_AFTER" -gt "$SHADOW_BEFORE" ]; then
            echo -e "${RED}  !! 重装仍向叠影目录写入（+$(($SHADOW_AFTER - $SHADOW_BEFORE)) 个文件）—— 这些包是旧相对/双叠约定产物，源内尚无绝对约定重打包${NC}"
            echo -e "${RED}     修复动作:等待 repack 版（绝对路径约定）发布后 pacman -Syu 升级，再重跑本脚本${NC}"
            echo "[$(date '+%F %T')] [18/20] 重装仍写入叠影（旧约定包）: $AFFECTED_PKGS" >> "$REPORT"
            RELOCATE_OK=0
        else
            relocate_fail=""
            for p in $AFFECTED_PKGS; do
                if ! pacman -Qk "$p" >/dev/null 2>&1; then
                    relocate_fail="$relocate_fail $p"
                fi
            done
            if [ -n "$relocate_fail" ]; then
                echo -e "${RED}  !! 归位校验失败:以下包在正确路径下仍有文件缺失（-Qk 不通过）:${relocate_fail}${NC}"
                echo -e "${RED}     修复动作:检查网络后重跑本脚本;或手动 pacman -S --noconfirm --overwrite '*'${relocate_fail}${NC}"
                echo "[$(date '+%F %T')] [18/20] 归位校验失败：${relocate_fail}" >> "$REPORT"
                RELOCATE_OK=0
            else
                echo -e "${GREEN}  ✓ 归位完成并校验通过: $(echo $AFFECTED_PKGS | tr '\n' ' ')${NC}"
            fi
        fi
    else
        echo -e "${RED}  !! 重装事务失败（多为网络/镜像问题）${NC}"
        echo -e "${RED}     修复动作:恢复网络后重跑本脚本,或手动执行: pacman -S --noconfirm --overwrite '*' ${AFFECTED_PKGS}${NC}"
        echo "[$(date '+%F %T')] [18/20] 重装事务失败：$AFFECTED_PKGS" >> "$REPORT"
        RELOCATE_OK=0
    fi
fi

echo "[19/20] 叠影目录清理（交互确认；非交互模式只报告）..."
# 归位成功（或本就无受影响包）后，叠影目录内容均为冗余副本，可安全清除。
# 仅清理结构可证的叠影顶层（<原 RootDir>/data）；含意外条目时只报告不删除。
if [ -n "$SHADOW_TOPS" ]; then
    if [ "$RELOCATE_OK" -eq 1 ]; then
        for t in $SHADOW_TOPS; do
            # 安全护栏：叠影顶层下除 data/ 外不得有其他条目
            if [ -n "$(find "$t" -mindepth 1 -maxdepth 1 ! -name data -print -quit 2>/dev/null)" ]; then
                echo -e "${RED}  !! $t 下含未知条目，不自动清理，请人工核查${NC}"
                continue
            fi
            if [ -t 0 ]; then
                printf "  → 是否清理叠影目录 %s（冗余副本，归位已完成）? [y/N] " "$t"
                read -r ans || ans=""
                case "$ans" in
                    y|Y|yes|YES)
                        rm -rf "$t"
                        echo -e "${GREEN}  ✓ 已清理: $t${NC}"
                        echo "[$(date '+%F %T')] [19/20] 叠影目录已清理（用户确认）: $t" >> "$REPORT"
                        ;;
                    *)
                        echo "  → 已跳过: $t；可稍后手动执行: rm -rf $t"
                        ;;
                esac
            else
                echo "  → 非交互模式，只报告不删除；确认无用后可手动清理: rm -rf $t"
                echo "[$(date '+%F %T')] [19/20] 非交互模式跳过清理（$t 仍在）" >> "$REPORT"
            fi
        done
    else
        echo -e "${RED}  !! 归位未完成，暂不清理叠影目录（防止数据丢失）${NC}"
        echo -e "${RED}     修复动作:先完成 [18] 归位并校验通过后，再手动 rm -rf $(echo $SHADOW_TOPS | tr '\n' ' ')${NC}"
    fi
else
    echo "  → 叠影目录不存在，无需清理"
fi

echo "[20/20] 装后自检（strace 落点断言 + 叠影哨兵）..."
# 装一个小包验证真实落点：strace 应落在 $PREFIX/bin/strace
# （= /data/data/com.termux/files/usr/bin/strace）；
# 叠影哨兵：$PREFIX/../data 与 $PREFIX/data（两类病灶的叠影顶层）均不应存在。
pacman -S --noconfirm --overwrite '*' strace >/dev/null 2>&1 || true
self_fail=0
if [ -x "$PREFIX/bin/strace" ]; then
    echo "  ✓ strace 落点正确: $PREFIX/bin/strace"
else
    echo -e "${RED}  !! 自检失败: $PREFIX/bin/strace 不存在（strace 安装或落点异常）${NC}"
    self_fail=1
fi
root_data=$(cd "$PREFIX/.." 2>/dev/null && pwd)/data
if [ -e "$root_data" ] || [ -e "$PREFIX/data" ]; then
    echo -e "${RED}  !! 叠影哨兵触发: 叠影顶层仍存在（$root_data 或 $PREFIX/data）${NC}"
    echo -e "${RED}     详见上一步残留报告与 $REPORT${NC}"
    self_fail=1
else
    echo "  ✓ 叠影哨兵通过: 无叠影目录"
fi
if [ "$self_fail" -eq 0 ]; then
    echo -e "${GREEN}  ✓ 装后自检全部通过，包落点正常${NC}"
else
    cur_rootdir=$(grep -E '^[[:space:]]*RootDir[[:space:]]*=' "$PACMAN_CONF" || true)
    if [ -n "$cur_rootdir" ]; then
        echo -e "${RED}  !! RootDir 仍启用: ${cur_rootdir} —— 这会导致双叠路径，请检查 [4/20] 为何未生效${NC}"
    else
        echo -e "${RED}  !! RootDir 已回落默认 \"/\"，失败可能源于镜像/网络或安装中断，重跑本脚本再验${NC}"
    fi
    exit 1
fi

echo "=== Pacman 切换完成 v00fix20 ==="
