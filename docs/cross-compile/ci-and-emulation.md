# CI 与模拟执行方案：边界与代价

> 证据编号 E* 指向 `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`。
> **本机实测结论先行：本机做不了「交叉 + 模拟验证」闭环**（E2.3/E2.5），
> 验证必须外移到 CI 或真机。

## 1. 本机能力实测（这是选型的事实基础）

| 组件 | 状态 | 实测输出 |
|---|---|---|
| `qemu-x86_64` | ✅ v11.0.3 | `qemu-x86_64 version 11.0.3` |
| `qemu-x86_64-static` | ❌ | `not found` |
| `qemu-aarch64` / `-static` | ❌ | `not found`（本机是 aarch64 宿主，非必需） |
| `docker` | ⚠ 仅 client | Client v24.0.6-ce；`docker info` **未返回 daemon 段** |
| `podman` | ❌ | `not found` |
| `binfmt_misc` | ❌ 不可用 | `/proc/sys/fs/binfmt_misc/`: **Permission denied**（Termux 沙箱） |
| `rustc` | ⚠ 无 target 管理 | 1.98.0 (source tarball)，**无 rustup** |
| `zig` / `zig cc` | ✅ 可交叉 | `zig cc -target x86_64-linux-gnu` 出 glibc x64 ELF（E2.4） |

### 关键实测：qemu-user 在本机跑不了目标产物

```console
$ qemu-x86_64 ./o-bun-linux-x64
qemu-x86_64: /system/bin/linker64: Invalid ELF image for this architecture
$ qemu-x86_64 ./o-bun-linux-x64-musl
qemu-x86_64: Could not open '/lib/ld-musl-x86_64.so.1': No such file or directory
```

两个失败是**不同原因**，都要认清：

1. 第一个产物是 bionic（坑，见 [toolchains.md §3](toolchains.md#三个坑全部实测)），
   `qemu-x86_64` 试图用 Android 的 `/system/bin/linker64` 加载 x86-64 bionic ELF，
   架构不匹配。
2. 第二个产物**确实是** musl x86_64，但 Termux 的 `qemu-x86_64` **没有 `-L sysroot` 语义**
   —— `qemu-user` 只做用户态 CPU/ syscall 模拟，**不提供目标 libc 根文件系统**。
   本机没有 `/lib/ld-musl-x86_64.so.1`，所以失败。

**结论**：`qemu-user-static` 在本机**单独使用不可行**。它必须搭配一个 target sysroot
（proot/distrobox 里的 glibc rootfs，或 CI 容器）。这一点与业界「binfmt + qemu 一条命令
跑多架构」的说法不同——那条成立的前提是**宿主机有 binfmt_misc 注册 + 能装 sysroot**，
本机两条都不满足（沙箱封了 `/proc/sys/fs/binfmt_misc`）。

## 2. 方案逐个评估

### 方案 A：bun baseline 打包 + CI 原生 runner 验证 ★推荐

**形态**：编译在本机/任意宿主完成（`--compile-executable-path`），**验证**放到
GitHub Actions 的原生 runner 上跑。

| 项 | 内容 |
|---|---|
| 前置 | 改 `build.ts` target 参数化 + 放宽 `A2_TARGET_FILTER`（`tools/a2/build-v1.sh:129`）；CI 加 glibc job |
| 工具链 | bun 官方 baseline（npm 拉取）+ `zig cc`（编 shim，如需） |
| 风险 | **低**。不引入新依赖类别，全是已验证过的机制 |
| 增量成本 | 首个 glibc 目标 **1–2 天**；此后每目标 **+0.5 天** |
| 优点 | 与上游 opencode 做法一致（E4.1：上游每个 linux 架构一个原生 runner，含 `ubuntu-2404-arm`）；无模拟误差 |
| 缺点 | 需要 CI 额度；arm64 runner 比 x64 贵；本机不能自验（需 push 到 CI 才知对错） |

**上游参照（E4.1，`~/develop/opencode-upstream` @ `ad1d14775`）**
`.github/workflows/publish.yml:226-250`：

```yaml
matrix:
  settings:
    - host: macos-26-intel                   → x86_64-apple-darwin
    - host: macos-26                         → aarch64-apple-darwin
    - host: windows-2025                     → aarch64-pc-windows-msvc
    - host: blacksmith-4vcpu-windows-2025    → x86_64-pc-windows-msvc
    - host: blacksmith-4vcpu-ubuntu-2404     → x86_64-unknown-linux-gnu
    - host: blacksmith-4vcpu-ubuntu-2404-arm → aarch64-unknown-linux-gnu   # ← 原生 ARM runner
```

注意 `:247` 的注释：`github-hosted: blacksmith lacks ARM64 MSVC cross-compilation toolchain`
—— 上游**没有做交叉编译**，而是为每个架构用原生 runner。`bun compile.target` 本身
（E4.2 `build.ts:205-213`）确实是交叉的，但上游的 arm64 job 跑在 ARM runner 上，
所以从未踩到我们坑 1。

**可直接复用**：`.github/workflows/` 由另一代理负责，本目录只给出**需求**：
新增 `linux-glibc-x64` 与 `linux-glibc-arm64` 两个 job，验证项见 [plan.md](plan.md#阶段-1)。

### 方案 B：qemu-user + binfmt 全交叉（业界常规）

| 项 | 内容 |
|---|---|
| 前置 | 可写 `/proc/sys/fs/binfmt_misc`（**本机被沙箱封，E2.3**）+ `qemu-*-static` + 目标 rootfs |
| 本机可行性 | **不可行**（E2.3 + E2.5 双重失败） |
| CI 可行性 | ✅ 可行（GitHub Actions ubuntu runner 上 `docker run --privileged tonistiigi/binfmt`） |
| 风险 | **中**。binfmt 全局注册影响宿主；模拟执行比原生慢 5–20×；TUI 类程序在模拟下可能因时序/终端行为不真实而误判 |
| 增量成本 | 3–5 天（含调试） |
| 何时值得 | 需要在**本地**（无 CI 额度）验证多架构时；或需要在模拟环境里跑**测试套件**（不只是 `--version`） |

**本仓的具体障碍**：`docker info` 显示 daemon 不可用（E2.3）—— Termux 上的 docker
是 client-only（Docker-in-Android 无 root 权限跑不了 daemon）。所以方案 B 在本机
**没有落地路径**，只能在 CI 上做。

### 方案 C：Termux 官方 `termux-build` 流程

**适用边界**：**只解决「从 Termux 源码构建 Termux 包」**，不解决「从 Android 宿主产出
glibc 产物」。它是 Termux 自己的 bootstrap 机制（交叉编译 Android 原生包），
与本项目的方向**正交**。

**结论：不适用。** 本仓要的是 glibc/musl Linux 产物，不是更好的 Android 产物。
若未来目标是「用官方渠道发 Termux 包」，那时才与 `termux-build` 有关。

### 方案 D：proot / distrobox / chroot

| 工具 | 适用边界 | 在本场景的代价 |
|---|---|---|
| **proot** | 用户态路径重定向，无需 root。Termux 上跑 glibc rootfs（Debian/Ubuntu arm64） | 能提供 glibc sysroot 让 qemu-user 跑通（补上 E2.5 缺的那块）。但 proot 用 ptrace 拦截，**与 qemu 叠加时性能损失严重**（嵌套翻译层），且 TUI 程序的 `TERM`/tty 行为在 ptrace 下可能失真 |
| **distrobox** | 需要 user namespaces + `podman`/`docker`。**本机 `podman` 无、docker daemon 不可用**（E2.3） | 本机不可行。CI 上可用，但收益与方案 B 重叠 |
| **chroot** | 需要 root | **Termux 无 root**，本机不可行 |

**判断**：proot 是本机**唯一**能补出 glibc sysroot 的手段（若要本机验证），
但它是「本地验证的补充」，不替代方案 A 的 CI 验证。

### 方案 E：`uraimo/run-on-arch-action` 类现成 action

**状态：未取到证据（N4）** —— 网络取证未成功，本机也无相关工具，**不做断言**。

从命名与用途看这类 action 属于方案 B 的封装（GitHub Actions 上用 QEMU 跑
`arm64v8/ubuntu` 等容器镜像），即「在 x64 runner 上模拟 arm64 执行构建」。
若采用，代价与风险与方案 B 相同（模拟误差 + 慢），只是省掉自己写 binfmt 配置。

**建议**：优先方案 A（原生 runner，无模拟误差）。只有在需要 arm64 而没有 ARM runner
额度时，才退到这类方案。

## 3. 方案对比

| | A: bun baseline + CI 原生 | B: qemu+binfmt | D: proot 补 sysroot | E: run-on-arch 类 |
|---|---|---|---|---|
| 本机可落地 | ✅ 编译可，验证不可 | ❌ | ⚠ 部分 | ❌ |
| CI 可落地 | ✅ | ✅ | ✅ | ✅ |
| 模拟误差 | **无**（原生） | 有 | 有（ptrace+qemu 双层） | 有 |
| 速度 | 原生 | 慢 5–20× | 更慢 | 慢 5–20× |
| 新增依赖 | 无 | qemu-static + binfmt（需 privileged） | proot + glibc rootfs | 同 B |
| 与上游一致性 | ✅ 同上游做法 | ✗ | ✗ | ✗ |
| 增量成本 | 1–2 天 | 3–5 天 | 2–3 天（叠加 B） | 2–3 天 |
| 风险 | 低 | 中 | 中高 | 中 |

## 4. 一个必须知道的验收约束

上游 `build.ts:230-238`（E4.2）自己就承认：

```ts
// Smoke test: only run if binary is for current platform
if (item.os === process.platform && item.arch === process.arch && !item.abi) { ... }
```

即**上游也只 smoke 本机平台产物**，非本平台产物在 CI 里连 `--version` 都不跑。
这意味着：跨架构产物的**首次验证必须靠目标平台 runner 或真机**，
不能指望编译侧自检。这是方案 A 不可替代的原因。

对本仓的直接影响：`tools/a2/build-v1.sh:177-185` 的 smoke
（`--version` + `tools/transplant/tui_smoke.py`）**在跨目标时会跳过或失败**，
需要在 CI 的目标 runner 上有对应的执行路径。
