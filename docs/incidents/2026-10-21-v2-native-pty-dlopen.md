# TEMP-v2-native-pty-dlopen（第 3 判据缺口）

## 一、现象

`opencode serve` 起无头服务后，远程客户端创建终端（`POST /api/pty`）失败；
server 侧日志：

```
Failed to load lib 152 |       path = path.name;
...
error: Failed to open library "/data/data/com.termux/files/usr/tmp/.bun-10375-96736e86bbceb370.so":
dlopen failed: library "libpthread.so.0" not found: needed by
/data/data/com.termux/files/usr/tmp/.bun-10375-96736e86bbceb370.so in namespace (default)
    at dlopen (bun:ffi:157:28)
    at /$bunfs/root/chunk-4t04mpne.js:8:86
```

同一份 runtime 的 TUI 渲染正常，所以常规「TUI 冒烟」不暴露该缺陷。

## 二、根因（三段实锤）

1. **调用链**：`server.pty` 路由 `POST /api/pty`（`pty.create`，见 bundle
   `var ze=p.make("server.pty")`）→ `@opencode/Pty` 服务 →
   `jS=Vl(()=>import("/$bunfs/root/chunk-4t04mpne.js"))` 懒加载 bun-pty 的 FFI
   chunk。仅「创建终端」时才触发，故 serve/TUI 启动期无异常。
2. **解析顺序**（chunk 源码内 `function x()`）：
   `$BUN_PTY_LIB`（且 `existsSync`）→ **内嵌资产**
   `/$bunfs/root/librust_pty_arm64-kkpzdzzv.so` → 磁盘候选
   （`rust-pty/target/release/`、`../bun-pty/rust-pty/...`、`cwd/node_modules/bun-pty/...`）。
   内嵌资产**优先于任何磁盘替代件**。
3. **内嵌件是 glibc 版**：从已装 2.0.22（`$PREFIX/bin/opencode`，289,207,968 B）
   的 bunfs 槽 `288503269` 抽出 555,704 B 的 ELF：

   ```
   NEEDED libpthread.so.0 / libc.so.6 / libdl.so.2 / libutil.so.1
   nm -D --defined-only: 8 × bun_pty_*（与 JS FFI 表完全对应）
   dlopen → library "libpthread.so.0" not found   （与线上报错逐字一致）
   ```

   `$TMPDIR/.bun-<euid>-<wyhash>.so` 即 bun 对内嵌资产的提取副本（bunfs 资产
   加载机制，`docs/tui-reachability.md` 附录 A ①）。

## 三、为什么只有 native 主线中招

- v1 / compressed 线：`tools/a2/pty-embed-store-patch.sh`（编译前换 store 里的
  `librust_pty_arm64.so` 为 bionic）或 `tools/bun-pty-splice/` + launcher 注入
  `BUN_PTY_LIB`（`scripts/opencode1-launcher.sh`、`scripts/opencode-launcher.sh`）。
- v2 native 主线：`scripts/package/package_deb_native.sh` 把 runtime 直装
  `$PREFIX/bin/opencode`（**无 launcher**），`make transplant`（`tools/transplant/
  transplant.py`）只 graft `libopentui.so`，没有任何 pty 环节 →
  `BUN_PTY_LIB` 无处注入，内嵌 glibc 件原样出厂。

## 四、复现（本机，Android 15 / bionic）

```bash
B=$TMPDIR/octest; mkdir -p "$B/proj" "$B/home" "$B/tmp"
HOME="$B/home" XDG_CONFIG_HOME="$B/home/.config" XDG_DATA_HOME="$B/home/.local/share" \
XDG_CACHE_HOME="$B/home/.cache" XDG_STATE_HOME="$B/home/.local/state" TMPDIR="$B/tmp" \
  opencode serve --port 4461 --hostname 127.0.0.1 &
T=$(printf 'opencode:123456' | base64)      # 密码取 OPENCODE_SERVER_PASSWORD
curl -s "http://127.0.0.1:4461/api/pty?auth_token=$T&location%5Bdirectory%5D=$B/proj" \
  -H 'Content-Type: application/json' \
  -d "{\"command\":\"/system/bin/sh\",\"args\":[],\"cwd\":\"$B/proj\",\"title\":\"t\"}"
```

结果：`/api/pty` 返回空体（500），server 日志即上述 dlopen 报错；
提取件名 `.bun-10375-96736e86bbceb370.so`（10375=Termux euid）。

## 五、修法（已落地并用真机 serve 复验）

1. 资产手术：`tools/transplant/swap_pty.py` 把
   `tools/bun-pty-embed/vendor/librust_pty_arm64_bionic.so`（517,016 B，零未定义
   符号、8 × `bun_pty_*`）替换进 bunfs 槽 555,704 B（尾部 NUL 补齐，同
   `swap_tui.py` 手法），并跑 `ctypes.CDLL` 真 dlopen 门。
2. 管线集成：`transplant.py` 第 8b 步（`-tui` 与 `-revived` 两个出厂件原地替换），
   报告新增 `steps.pty` / `pty`；CLI 子命令 `pty-swap --check`；
   `make pty-check BIN=<product>` 作为发布门（glibc ⇒ 非零退出）。
3. 免改包逃生口：`BUN_PTY_LIB=<...>/librust_pty_arm64_bionic.so opencode serve`
   （解析顺序第 1 顺位，实测同样可创终端）。

复验（同一 `POST /api/pty`）：

| 件 | 结果 |
|---|---|
| 原 2.0.22（glibc 内嵌） | 500 + `libpthread.so.0 not found` |
| swap_pty 术后 | `{"status":"running","pid":14081,...}`，`ps` 见 `/system/bin/sh -l` |
| 原件 + `BUN_PTY_LIB` | `{"status":"running","pid":15740,...}` |

## 六、为什么没被既有门拦住

- `tests/` 只有 bats（packaging）与 transplant golden/`tui_smoke.py`（渲染帧），
  没有「创建终端」用例；`tui_probe` 只判 ANSI 渲染 ≥5KB。
- `docs/tui-reachability.md` 判据 3 描述的是「会话期」风险，且修法条目只写了
  BUN_PTY_LIB 拼接（对 native 不可用）；`docs/ops-lessons-rc3.md` §14「pty 能力
  已内置此件」来自 v1（store patch 后内嵌件本就是 bionic），不能推广到 v2 native。
- 结论：判据 3 需要按「厂商线」分列（compressed=BUN_PTY_LIB，native=资产替换），
  并把 `make pty-check` 纳入发布门。
