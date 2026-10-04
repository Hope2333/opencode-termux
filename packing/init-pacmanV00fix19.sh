#!/data/data/com.termux/files/usr/bin/bash
set -e

# init-pacmanV00fix19 — Termux pacman 初始化/自愈脚本（基于 v00fix18 迭代）
#
# v00fix19 变更摘要（对照 v00fix18）:
#   1. 新增 [4/18] pacman.conf 根配置规范化：
#      RootDir 若为非 "/" 的绝对路径（如 /data/data/com.termux/files），而
#      Termux-pacman 官方包全部使用绝对路径（/data/data/com.termux/files/usr/...），
#      安装时会在 RootDir 之下再叠一次前缀，文件落到
#      /data/data/com.termux/files/data/data/com.termux/files/usr/...（双叠路径，
#      即「pacman 安装后运行总是失效」的根因，oscar 机器 strace 实证）。
#      根修 = 注释 RootDir 使其回落默认 "/"，绝对路径包从 / 起算正好落对；
#      原值记录到 ~/pacman-fix19-report.txt。
#      DBPath/CacheDir/HookDir/GPGDir/LogFile 为绝对路径选项，pacman 对绝对路径
#      不再叠加 RootDir 前缀，保持不动（以 pacman-conf 实测输出为准）。
#   2. 新增 [17/18] 双叠路径残留检测：列出 $PREFIX/data/data/ 下残留文件
#      （写入报告文件），只报告不自动删除（属用户数据操作，附手动清理命令）。
#   3. 新增 [18/18] 装后自检：安装 strace 并断言落点正确
#      （$PREFIX/bin/strace 存在 且 $PREFIX/data/ 不存在 = 叠影哨兵），
#      失败红字报错并提示 RootDir 状态，通过绿字确认。
#   4. 步骤总数 15 → 18；fix18 其余能力原样保留：
#      源解锁 / keyring / 镜像自愈（ftp.agdsn.de）/ db 升级 /
#      缓存迁移（/data/data/com.termux/cache/pacman）/ apt 移除。

# 调试模式开关：1=开启调试输出，0=静默
DEBUG=0

log() {
    echo -e "$@"
}

echo "[1/18] apt 全量升级 pacman/gnupg/rsync..."
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

echo "[2/18] 预热 gpg 环境..."
gpg --batch --list-keys  >/dev/null 2>&1 || true
gpg --batch --list-secret-keys >/dev/null 2>&1 || true

PACMAN_CONF=$PREFIX/etc/pacman.conf
KEYRING_DIR=$PREFIX/share/pacman/keyrings
REPORT=$HOME/pacman-fix19-report.txt

echo "[3/18] 备份 pacman.conf 并解锁所有官方扩展源..."
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

echo "[4/18] pacman.conf 根配置规范化（RootDir 双叠路径修复）..."
# RootDir 启用且指向非 "/" 的绝对路径时，绝对路径包会双叠前缀（见文件头说明）。
# 注释 RootDir 回落默认 "/"；DBPath/CacheDir/HookDir/GPGDir/LogFile 保持绝对路径不动。
rootdir_line=$(grep -E '^[[:space:]]*RootDir[[:space:]]*=' "$PACMAN_CONF" | head -n1 || true)
if [ -n "$rootdir_line" ]; then
    rootdir_val="${rootdir_line#*=}"
    rootdir_val=$(echo "$rootdir_val" | xargs)
    if [ -n "$rootdir_val" ] && [ "$rootdir_val" != "/" ]; then
        sed -i -E 's|^([[:space:]]*RootDir[[:space:]]*=)|#\1|' "$PACMAN_CONF"
        echo "  → 检测到 RootDir = $rootdir_val（非 \"/\" 的绝对路径，会与包内绝对路径叠加）"
        echo "  → 已注释该行并回落默认 \"/\"，原值已记录到 $REPORT"
        {
            echo "[$(date '+%F %T')] [4/18] RootDir 规范化：原值 = $rootdir_val（已注释，回落默认 /）"
            echo "[$(date '+%F %T')] 若需恢复，编辑 $PACMAN_CONF 取消注释 RootDir 行（仅对相对路径包适用）"
        } >> "$REPORT"
    else
        echo "  → RootDir = \"/\" 或为空，无需处理"
    fi
else
    echo "  → 未启用 RootDir（默认 \"/\"），无需处理"
fi

echo "[5/18] 禁签 + 占位 keyring..."
sed -i 's/^SigLevel.*/SigLevel = Never/' $PACMAN_CONF
install -dm755 "$KEYRING_DIR"
for f in termux-pacman; do
    touch "$KEYRING_DIR/$f-trusted" \
          "$KEYRING_DIR/$f-revoked"
done

echo "[6/18] 修复 pacman 本地库版本（database is incorrect version）..."
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

echo "[7/18] 检测并修复 pacman 镜像源..."
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
    printf '## Auto-switched by init-pacmanV00fix19 (previous mirror unavailable)\nServer = https://ftp.agdsn.de/termux-pacman/$repo/$arch\n' > "$mtmp"
    cat "$MIRROR_LIST" >> "$mtmp"
    mv "$mtmp" "$MIRROR_LIST"
    echo "  → 已切换: $MIRROR_LIST"
fi

echo "[8/18] 初始化 keyring 并同步数据库..."
pacman-key --init || true
pacman -Sy --noconfirm --overwrite '*' || true

echo "[9/18] 安装 termux-keyring..."
pacman -S --noconfirm --overwrite '*' termux-keyring || true

echo "[10/18] 尝试导入 apt 包列表到 pacman..."
if command -v dpkg >/dev/null 2>&1; then
    dpkg --get-selections | awk '$2=="install"{print $1}' > ~/pkglist.txt
    pacman -S --needed --noconfirm --overwrite '*' - < ~/pkglist.txt || true
    rm ~/pkglist.txt
else
    echo "  → dpkg 已移除，跳过导入"
fi

echo "[11/18] 修正 pacman 目录权限..."
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

echo "[12/18] 全量升级（强制覆盖冲突文件）..."
pacman -Syyu --noconfirm --overwrite '*' || true

echo "[13/18] 移除 apt/dpkg 并切换 pkg 到 pacman..."
pacman -Rns --noconfirm apt dpkg 2>/dev/null || true
termux-setup-package-manager || true
ln -sf $PREFIX/bin/pkg $PREFIX/bin/apt
ln -sf $PREFIX/bin/pkg $PREFIX/bin/apt-get

echo "[14/18] 迁移 pacman 缓存目录并建立软链..."
NEW_CACHE=/data/data/com.termux/cache/pacman
OLD_CACHE=$PREFIX/var/cache/pacman
mkdir -p "$NEW_CACHE"
if [ -d "$OLD_CACHE" ] && [ ! -L "$OLD_CACHE" ]; then
    mv "$OLD_CACHE"/* "$NEW_CACHE"/ 2>/dev/null || true
    rm -rf "$OLD_CACHE"
fi
ln -sf "$NEW_CACHE" "$OLD_CACHE"

echo "[15/18] 检测 termux-keyring 是否安装成功..."
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
        echo "[16/18] 重新初始化+导入 keyring 并测试更新..."
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

echo "[17/18] 双叠路径残留检测（只报告，不自动删除）..."
# 此前错误配置（RootDir 叠加）可能已把包文件装进 $PREFIX/data/data/...，
# 这里列出残留供用户确认后手动清理；脚本不自动删（属用户数据操作）。
SHADOW_DIR=$PREFIX/data/data
if [ -d "$SHADOW_DIR" ]; then
    SHADOW_COUNT=$(find "$SHADOW_DIR" -type f 2>/dev/null | wc -l)
    echo "  !! 检测到历史双叠路径残留: $SHADOW_DIR（$SHADOW_COUNT 个文件）"
    {
        echo "[$(date '+%F %T')] [17/18] 双叠路径残留：$SHADOW_DIR（$SHADOW_COUNT 个文件）"
        find "$SHADOW_DIR" -type f 2>/dev/null
    } >> "$REPORT"
    echo "  --- 残留文件清单（前 50 条，完整清单见 $REPORT）---"
    find "$SHADOW_DIR" -type f 2>/dev/null | head -n 50 | sed 's/^/    /'
    echo "  → 确认无用后可手动清理: rm -rf $SHADOW_DIR"
    echo "  → 脚本不自动删除（属用户数据操作）"
else
    echo "  → 无双叠路径残留"
fi

echo "[18/18] 装后自检（strace 落点断言 + 叠影哨兵）..."
# 装一个小包验证真实落点：strace 应落在 $PREFIX/bin/strace
# （= /data/data/com.termux/files/usr/bin/strace）；
# 叠影哨兵：$PREFIX/data（= /data/data/com.termux/files/data/）不应存在。
RED='\033[31m'; GREEN='\033[32m'; NC='\033[0m'
pacman -S --noconfirm --overwrite '*' strace >/dev/null 2>&1 || true
self_fail=0
if [ -x "$PREFIX/bin/strace" ]; then
    echo "  ✓ strace 落点正确: $PREFIX/bin/strace"
else
    echo -e "${RED}  !! 自检失败: $PREFIX/bin/strace 不存在（strace 安装或落点异常）${NC}"
    self_fail=1
fi
if [ -e "$PREFIX/data" ]; then
    echo -e "${RED}  !! 叠影哨兵触发: $PREFIX/data 存在（包文件被装入 RootDir 叠加路径）${NC}"
    echo -e "${RED}     详见上一步残留报告与 $REPORT${NC}"
    self_fail=1
else
    echo "  ✓ 叠影哨兵通过: $PREFIX/data 不存在"
fi
if [ "$self_fail" -eq 0 ]; then
    echo -e "${GREEN}  ✓ 装后自检全部通过，包落点正常${NC}"
else
    cur_rootdir=$(grep -E '^[[:space:]]*RootDir[[:space:]]*=' "$PACMAN_CONF" || true)
    if [ -n "$cur_rootdir" ]; then
        echo -e "${RED}  !! RootDir 仍启用: ${cur_rootdir} —— 这会导致双叠路径，请检查 [4/18] 为何未生效${NC}"
    else
        echo -e "${RED}  !! RootDir 已回落默认 \"/\"，失败可能源于镜像/网络或安装中断，重跑本脚本再验${NC}"
    fi
    exit 1
fi

echo "=== Pacman 切换完成 v00fix19 ==="
