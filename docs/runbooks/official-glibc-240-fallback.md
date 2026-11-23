# 官方 2.4.0 glibc 二进制在 Termux 的用户级回退方案

> 状态：active ｜ 适用版本：v2 2.4.0（官方 `@opencode/cli-linux-arm64`）
>
> 边界：本文**不是新包族**，也不改变 native bionic 主线。它只记录主线尚未跟到 2.4.0 时，
> 直接跑官方 glibc 二进制的用户级做法，供维护者判断是否需要收编或写进安装文档。
> 相关上下文：issue #50（background service 起不来）、PR #44（patchelf 改 INTERP/RPATH）。

## 结论先行

官方 2.4.0 的 glibc 二进制可以在 Termux 上完整跑起来（含 TUI、后台服务、PTY、联网），
但必须同时处理四件事，缺一不可：

1. 只改 ELF `INTERP` 指向 Termux glibc loader；**不要写 RUNPATH/RPATH**。
2. 启动时 `unset LD_PRELOAD`，再用 `LD_LIBRARY_PATH` 给库路径。
3. 用 `LD_PRELOAD` 注入 `getifaddrs` shim，绕过 Android 沙箱对 `/proc/net/dev` 的限制。
4. 补齐 glibc 的 `nsswitch.conf`，并把 `resolv.conf` 换成当前网络可达的 DNS。

## 环境

- Termux aarch64，未 root；`$PREFIX=/data/data/com.termux/files/usr`。
- 依赖：`pkg install glibc patchelf clang`。
- 官方包：`@opencode/cli-linux-arm64@2.4.0`，tarball SHA-256
  `0b6e6e2a25939bba2e6bdd7d07e86c9127c1afc52f5f0c084870f5786ec3f474`。

## 步骤

### 1. 解包并打补丁

```bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
WORK="$HOME_DIR/.local/src/oc240"
mkdir -p "$WORK" && cd "$WORK"
curl -fsSL -o oc240.tgz \
  https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.4.0.tgz
sha256sum -c <<'EOF'
0b6e6e2a25939bba2e6bdd7d07e86c9127c1afc52f5f0c084870f5786ec3f474  oc240.tgz
EOF
tar -xzf oc240.tgz
BIN="$WORK/package/bin/opencode"

patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$BIN"
```

**只执行 `--set-interpreter`。** 对 2.4.0 额外执行
`patchelf --set-rpath "$PREFIX/glibc/lib"` 会让二进制段错误；库路径必须由启动器用
`LD_LIBRARY_PATH` 提供。这一点与 PR #44 的补丁不同。

### 2. getifaddrs shim

Android 应用沙箱禁止读取 `/proc/net/dev` 与 `/sys/class/net`，glibc 的 `getifaddrs(3)` 因此失败。
后果是 Bun 的 `networkInterfaces()` 抛错，`/api/info` 返回 500，TUI 永远停在
`Starting background server...`。

保存为 `getifaddrs_shim.c`：

```c
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <stdlib.h>

struct ifaddrs_storage {
	struct ifaddrs ifa;
	struct sockaddr_in addr4;
	struct sockaddr_in mask4;
	struct sockaddr_in6 addr6;
	struct sockaddr_in6 mask6;
};

static void fill_v4(struct ifaddrs_storage *s) {
	memset(s, 0, sizeof(*s));
	s->ifa.ifa_name = (char *)"lo";
	s->ifa.ifa_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
	s->addr4.sin_family = AF_INET;
	s->addr4.sin_addr.s_addr = htonl(0x7f000001u);
	s->mask4.sin_family = AF_INET;
	s->mask4.sin_addr.s_addr = htonl(0xff000000u);
	s->ifa.ifa_addr = (struct sockaddr *)&s->addr4;
	s->ifa.ifa_netmask = (struct sockaddr *)&s->mask4;
}

static void fill_v6(struct ifaddrs_storage *s) {
	memset(s, 0, sizeof(*s));
	s->ifa.ifa_name = (char *)"lo";
	s->ifa.ifa_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
	s->addr6.sin6_family = AF_INET6;
	s->addr6.sin6_addr.s6_addr[15] = 1;
	s->mask6.sin6_family = AF_INET6;
	memset(&s->mask6.sin6_addr, 0xff, 16);
	s->ifa.ifa_addr = (struct sockaddr *)&s->addr6;
	s->ifa.ifa_netmask = (struct sockaddr *)&s->mask6;
}

int getifaddrs(struct ifaddrs **ifap) {
	if (!ifap) return -1;
	struct ifaddrs_storage *a = calloc(1, sizeof(*a));
	struct ifaddrs_storage *b = calloc(1, sizeof(*b));
	if (!a || !b) { free(a); free(b); return -1; }
	fill_v4(a);
	fill_v6(b);
	a->ifa.ifa_next = &b->ifa;
	*ifap = &a->ifa;
	return 0;
}

void freeifaddrs(struct ifaddrs *ifa) {
	while (ifa) {
		struct ifaddrs *next = ifa->ifa_next;
		free(ifa);
		ifa = next;
	}
}
```

编译成零依赖的 `.so`：

```bash
clang --target=aarch64-linux-android -nostdlib -shared -fPIC \
  -I"$PREFIX/glibc/include" \
  -o "$WORK/getifaddrs-shim.so" "$WORK/getifaddrs_shim.c"
readelf -d "$WORK/getifaddrs-shim.so" | grep NEEDED   # 必须为空
```

**不能返回空接口列表**：Bun 的解析器需要至少一个带地址的接口，空列表会让
`getaddrinfo` 直接返回 `EAI_AGAIN`。所以这里固定返回 lo 的 IPv4 + IPv6。

### 3. DNS 配置

Termux 的 glibc 包没有 `nsswitch.conf`，glibc 因此不会查询 DNS（表现为
`EAI_AGAIN` / `Temporary failure in name resolution`）。补一个：

```bash
cat > "$PREFIX/glibc/etc/nsswitch.conf" <<'EOF'
passwd:         files
group:          files
shadow:         files
gshadow:        files
hosts:          files dns
networks:       files dns
protocols:      files
services:       files
ethers:         files
rpc:            files
netgroup:       files
automount:      files
EOF
```

`$PREFIX/glibc/etc/resolv.conf` 是指向 `$PREFIX/etc/resolv.conf` 的软链。
其中默认的 `8.8.8.8` 在部分网络下 **UDP 53 不通**（TCP 可连但 UDP 超时），
需换成当前网络可达的 DNS，例如：

```
nameserver 223.5.5.5
nameserver 119.29.29.29
```

此改动只影响走 glibc 的程序；bionic 的解析仍由 Android netd 负责，不受影响。

### 4. 启动器（隔离状态、配置、端口）

```bash
mkdir -p "$HOME_DIR/.local/bin"
cat > "$HOME_DIR/.local/bin/opencode2" <<EOF
#!/$PREFIX/bin/bash
set -euo pipefail
BIN="$WORK/package/bin/opencode"
SHIM="$WORK/getifaddrs-shim.so"
GLIBC_LIB="$PREFIX/glibc/lib"
HOME_BASE="$HOME_DIR/.local/state/oc240"

export XDG_STATE_HOME="\$HOME_BASE/state"
export XDG_DATA_HOME="\$HOME_BASE/share"
export XDG_CONFIG_HOME="\$HOME_BASE/config"
mkdir -p "\$XDG_STATE_HOME/opencode" "\$XDG_DATA_HOME/opencode" "\$XDG_CONFIG_HOME/opencode"

# 主配置用软链共享，不复制
for f in opencode.jsonc opencode.json cli.json; do
  [ -f "$HOME_DIR/.config/opencode/\$f" ] && \
    [ ! -e "\$XDG_CONFIG_HOME/opencode/\$f" ] && \
    ln -s "$HOME_DIR/.config/opencode/\$f" "\$XDG_CONFIG_HOME/opencode/\$f" 2>/dev/null || true
done

# 独立端口，避免踢掉系统 2.2.5 的 49374
[ -f "\$XDG_CONFIG_HOME/opencode/service.json" ] || printf '{\n  "hostname": "0.0.0.0",\n  "port": 49474\n}\n' > "\$XDG_CONFIG_HOME/opencode/service.json"

# termux-exec 预加载会把 glibc 的 libc.so（文本链接脚本）当共享库加载
unset LD_PRELOAD
export LD_LIBRARY_PATH="\$GLIBC_LIB"
export LD_PRELOAD="\$SHIM"
exec "\$BIN" "\$@"
EOF
chmod +x "$HOME_DIR/.local/bin/opencode2"
```

### 5. PTY helper（仅 TUI 需要持久终端时）

Bun 的 `opencode-pty` 也是 glibc 二进制，同样要改 interpreter：

```bash
HELPER=$(find "$HOME_DIR/.cache/opencode/bin/opencode-pty" -type f -name opencode-pty | head -1)
cp "$HELPER" "$HELPER.orig"
patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$HELPER"
```

注意：该路径按 `opencode-pty` 版本散列命名，由两个 opencode 版本共用。升级后需重做；
若新旧两版都要用 PTY，应给新版单独设置 `XDG_CACHE_HOME` 后再分别打补丁。

### 6. 迁移旧库（可选）

不要把 2.2.5 与 2.4.0 的 schema 手工合并——让 2.4.0 自己跑最后两条迁移。
老库仍被 2.2.5 占用（WAL 模式），必须用 SQLite 在线备份，不能裸 `cp`：

```bash
BK="$HOME_DIR/.local/share/opencode-backup-$(date +%Y%m%d)"
mkdir -p "$BK"
export HOME_DIR BK
python3 - <<'PY'
import sqlite3, os
home = os.environ["HOME_DIR"]
bk = os.environ["BK"]
src = sqlite3.connect(f"file:{home}/.local/share/opencode/opencode.db?mode=ro", uri=True)
dst = sqlite3.connect(f"{bk}/opencode-old.db")
src.backup(dst); dst.close(); src.close()
PY
```

然后把快照放到新版隔离目录的 `share/opencode/opencode.db`，启动一次 2.4.0，
它会自动补齐迁移（实测 62 → 64 条）。迁移前务必备份，且两库此后完全分叉。

## 验证

实测通过：

- `opencode2 --version` → `opencode v2.4.0`
- `opencode2 models` → 52 个模型
- `opencode2 run --model <provider/model> "只回三个字：网络通"` → 正常返回
- TUI 打开 2.2.5 的旧会话，历史逐条可读；无 `EAI_AGAIN` 重试提示
- PTY helper 输出 `opencode-pty 0.6.0 (protocol 9)`

## 坑位表

| 症状 | 根因 | 处理 |
|---|---|---|
| `cannot open shared object file` / `invalid ELF header` | `grun` 包裹导致 `process.execPath` 变成 ld.so；或 termux-exec 预加载混入 glibc | 改 INTERP 直接执行；`unset LD_PRELOAD` 后再注入 shim |
| TUI 卡在 `Starting background server...` | glibc `getifaddrs` 读不到 `/proc/net/dev` | 注入 getifaddrs shim，返回 lo |
| `getaddrinfo EAI_AGAIN` | shim 返回空接口列表；或缺 `nsswitch.conf`；或 DNS 的 UDP 53 不通 | 返回 lo v4+v6；补 nsswitch.conf；换可达 DNS |
| 加 RUNPATH 后段错误 | 2.4.0 与 patchelf 的 RUNPATH 不兼容 | 只用 `--set-interpreter`，库路径走 `LD_LIBRARY_PATH` |
| PTY 起不来 | `opencode-pty` 仍是 glibc INTERP | 同样改 INTERP；版本升级后需重做 |

## 回退

删掉新版的安装目录与隔离状态即可，系统包和它的原库从未被改动：

```bash
kill $(ps -ef | grep '[o]pencode-240/bin/opencode' | awk '{print $2}')
rm -rf "$HOME_DIR/.local/src/oc240" "$HOME_DIR/.local/state/oc240" "$HOME_DIR/.local/bin/opencode2"
```

## 待维护者决策

- PR #44 的 `--set-rpath` 在 2.4.0 上会段错误；是否要把该 PR 改为只设 INTERP？
- 这套 glibc 方案要不要收进仓库（例如 `docs/install/` 的用户级 appendix），
  还是仅在 issue #50 里作为排查线索保留？
- PTY helper 路径被两个版本共用，是否需要在启动器里强制隔离 `XDG_CACHE_HOME`？
