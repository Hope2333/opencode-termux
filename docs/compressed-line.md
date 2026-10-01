# Compressed 线契约（opencode1-compressed / UPX-packed）

> 适用：`opencode1-compressed` deb（`scripts/package/package_deb_compressed.sh`）
> 与 pacman 包（`scripts/package/package_pacman_compressed.sh` + `packing/pacman/PKGBUILD.compressed`）。

## Launcher-only 契约

compressed 包内的压制 runtime（`$PREFIX/lib/opencode1/runtime/opencode`）
**只允许经 `opencode1` launcher 调用**，不允许直跑 runtime。

- launcher（`scripts/opencode1-launcher.sh`）在 exec 前设置
  `LD_LIBRARY_PATH`，覆盖 runtime 的 `DT_RUNPATH $ORIGIN/../lib/opencode`
  解析（crhandler shim 等）。
- 两个打包器都有构建期 guard：payload 必含 launcher（`bin/opencode1`）
  与 crhandler shim，缺一即 FATAL。

## 机制一句话

UPX stub 把 ELF 段解压映射到匿名 `/memfd:upx`，磁盘上的
`$ORIGIN`（= `lib/opencode1/runtime/`）不再对应任何可解析路径，
`DT_RUNPATH $ORIGIN/../lib/opencode` 随之失效 —— 所以必须有 launcher
显式喂 `LD_LIBRARY_PATH`。

## 直跑报错样例

```text
$ $PREFIX/lib/opencode1/runtime/opencode --version
CANNOT LINK: library "libopencode-crhandler.so" not found
```

这不是包损坏：请改用 `opencode1 --version`。

## 陈旧 runtime 隔离（native 包安装钩子）

历史 v1 包（pre-v12.1）把 runtime 放在 `$PREFIX/lib/opencode/runtime/`；
现行包已迁到 `lib/opencode1/runtime/`，旧路径可能残留无主文件（实测
o s c a r 机上有 6 月期 1.17.9，159M）。native deb/pacman 安装钩子含
保守隔离规则，满足以下**全部**条件才动它：

1. `$PREFIX/lib/opencode/runtime/opencode` 存在；
2. `dpkg -S` / `pacman -Qo` 判定无包拥有；
3. `file` 头与本包 runtime 同架构（aarch64 ELF）。

动作 = 改名备份 `opencode.stale-<日期>`（**绝不 rm**，删除由用户手动）。
若不满足条件则原样保留，仅在同名备份已存在等边缘情况下跳过。

## pty 拼接（可选资产，BUN_PTY_LIB 契约）

compressed 包可选携带 **musl librust_pty 拼接件**，让 bun-pty 在 bionic
（Android 9）上可用：

- **方案**：npm `bun-pty@0.4.11` 的 musl 变体
  `librust_pty_arm64_musl.so` 在 bionic 上缺 4 类符号（`bcmp` /
  `__errno_location` / `__xpg_strerror_r` / `posix_spawn_file_actions_addchdir_np`）。
  拼接层 = 自编 `shim.so`（补齐符号 + fork+exec 自管 posix_spawn 家族，
  musl 标志位语义）+ 对 musl .so 做 **DT_NEEDED 等长补丁**
  （`libc.so` → `shim.so`，7 字节串原地替换，长度不变，节区偏移全保）。
- **加载链**：bun-pty 的 JS 层优先读 `BUN_PTY_LIB` 环境变量；
  launcher 检测到
  `$PREFIX/lib/opencode1/pty/librust_pty_arm64_musl_patched.so` 存在时注入
  `BUN_PTY_LIB` 指向它，并把 `lib/opencode1/pty` 加进 `LD_LIBRARY_PATH`
  供 shim.so 解析。**向后兼容**：无该资产的旧包/手工布局不注入任何东西，
  行为与从前完全一致。
- **随包**：两个打包器把 `tools/bun-pty-splice/dist/` 的两件产物作为
  **可选资产**落到 `lib/opencode1/pty/`（`OPENCODE_PTY_SPLICE_DIR` 可覆盖
  来源；资产缺失时照常打包，仅打印跳过提示）。现有 crhandler / launcher
  guard 不受影响。

### 复刻步骤

```bash
tools/bun-pty-splice/build-splice.sh
# 产物: tools/bun-pty-splice/dist/{librust_pty_arm64_musl_patched.so, shim.so}
# 校验: 补丁件 sha256 必须等于验证台基准（等长补丁是确定性的）
#   1047d3e2b55580918b01256e992817ff46e5a2521c7421fa04235f5799f21a0d
```

脚本自动完成：取原件（npm tgz，sha256 锚定）→ Termux clang 编 shim →
等长 DT_NEEDED 补丁（单次出现断言 + 前后长度断言）→ 基准 sha256 校验。
shim 源码在 `tools/bun-pty-splice/shim.c`（canary 需设
`OPENCODE_PTY_SHIM_LOG=<path>` 才写日志，出厂零副作用）。

### 验证记录（2026-10-02，oscar 试验机 Android 9 kernel 3.18）

- 补丁件 + shim 于 oscar `dlopen` 通过，8 个 `bun_pty_*` 符号全解析，
  shim 构造器（canary）触发证明 DT_NEEDED 链生效；
- launcher 注入后 `/proc/<pid>/environ` 见
  `BUN_PTY_LIB=/data/data/com.termux/files/usr/lib/opencode1/pty/librust_pty_arm64_musl_patched.so`；
- `opencode1 --version` 回归通过；会话期（TUI 内真实 pty 会话）验证
  **延后**：JIT 层崩溃未修（todo 1/2），headless `run` 亦不加载 pty
  （pty 仅在终端会话路径加载）。
