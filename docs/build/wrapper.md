# wrapper 线：glibc 加载形态的三个判定

> 状态：active ｜ 适用版本：v1/v2 wrapper 兼容线（含早期 glibc 加载形态）
>
> 来源：issue #54 的实测记录，经维护者确认——早期 wrapper 线与这里描述的坑一致。
> 边界：这是**历史形态的判定表**，不是当前 wrapper 的架构说明。现在的 wrapper 启动层已经
> 收敛、不再依赖系统 glibc 库；主线与推荐路径始终是 native bionic 零 glibc 线，见
> [native-line-evolution.md](native-line-evolution.md)。包族清单见
> [package-families.md](../packaging/package-families.md)（单一事实源）。

## 适用场景

在用户机上直接跑官方 glibc 二进制，或在排查「TUI 卡在 Starting background server...」、
`getaddrinfo EAI_AGAIN`、`invalid ELF header` 这三类症状时，按下面三条依次核对。
这些判定来自早期 glibc 加载形态；当前 wrapper 包不应再需要手工做这些事，
若现网 wrapper 出现同样症状，请优先怀疑回归而不是按本文改配置。

## 判定 1：只改 INTERP，不写 RPATH/RUNPATH

- 现象：给官方 2.4.x 二进制 `patchelf --set-rpath ...` 后直接段错误；或子进程报
  `cannot open shared object file` / `invalid ELF header`。
- 根因：RPATH/RUNPATH 在部分 Bun 版本上会触发段错误；用 `grun` 包裹还会让
  `process.execPath` 变成 ld.so，TUI 子进程 re-exec 失败。
- 处理：只设 INTERP 指向目标 loader，库路径由启动器通过 `LD_LIBRARY_PATH` 提供；
  启动前 `unset LD_PRELOAD`（termux-exec 会把 glibc 的 `libc.so` 文本链接脚本当共享库加载）。
- 验证：`patchelf --print-interpreter <binary>` 应等于目标 loader；`opencode --version` 能返回。

## 判定 2：getifaddrs shim 必须返回 lo 的 v4 + v6

- 现象：后台服务起不来，TUI 停在 `Starting background server...`；`/api/info` 返回 500。
- 根因：Android 应用沙箱禁止读 `/proc/net/dev` 与 `/sys/class/net`，glibc 的
  `getifaddrs(3)` 必失败 → Bun 的 `networkInterfaces()` 抛错。
- 处理：注入零依赖的 `getifaddrs` shim，返回 `lo` 的 IPv4（127.0.0.1/8）和 IPv6（::1）。
- **不能返回空列表**：空列表会让 Bun 的解析器直接返回 `getaddrinfo EAI_AGAIN`。
  这是最容易写错的一点，空 shim 比不装 shim 更难排查。
- 验证：TUI 能进入主界面；`/api/info` 200；无 `EAI_AGAIN` 重试提示。
  更多 TUI 侧判据见 [tui-reachability.md](../reference/tui-reachability.md)。

## 判定 3：glibc 的 DNS 配置必须自成一体且可达

- 现象：`getaddrinfo EAI_AGAIN` / `Temporary failure in name resolution`；联网功能全废，
  但系统侧的 `getent hosts` / `curl` 正常（bionic 走 Android netd，不受影响）。
- 根因有两层：
  1. Termux 的 glibc 包默认没有 `nsswitch.conf`，glibc 因此不查询 DNS；
  2. `$PREFIX/etc/resolv.conf` 里的公共 DNS（如 `8.8.8.8`）在部分网络下 **UDP 53 不通**
     ——TCP 能连、UDP 超时，所以不要用 TCP 连通性代替 DNS 验证。
- 处理：补 `nsswitch.conf`（至少 `hosts: files dns`），并把 `resolv.conf` 指向当前网络
  实际可达的解析器（国内网络实测 `223.5.5.5` / `119.29.29.29` 可用，约 22ms 返回）。
- 验证：用 glibc 自己的解析链测，别用 bionic 的 `getent`——后者恒走 netd，测不出问题。
  例如最小 C 程序调 `getaddrinfo("100milionseek.top")`，应返回 A/AAAA 记录。

## 排查顺序

1. `unset LD_PRELOAD` + INTERP-only，先让二进制能起来。
2. 注入返回 lo v4+v6 的 shim，让后台服务和 `/api/info` 起来。
3. 补 nsswitch.conf + 换可达 DNS，让联网功能起来。

三者的症状会互相掩盖：DNS 不通时容易误判成 shim 失败，shim 返回空列表时又容易误判成 DNS 失败，
所以必须按上面顺序逐项验证。
