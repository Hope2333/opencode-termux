# 工具链：bun `--target` 语义与可用 target 清单

> 全部结论带证据编号，指 `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`。
> **本文所有命令均为本机（aarch64 Android / Termux）实测输出**，非文档转述。

## 一句话结论

`bun build --compile --target=<platform>` 是**打包活**：它从 npm registry 拉该平台的
**预编译 bun baseline**，把你的 JS 产物塞进去。**不需要本地交叉编译 Rust。**

但——**在 bionic（Android）宿主上跑它，libc 会被误推断**，必须显式纠正。见下文「三个坑」。

## 1. `--target` 的两种语义（易混）

`bun build --help` 里 `--target` 写的是：

```
--target=<val>   The intended execution environment for the bundle.
                  "browser", "bun" or "node"
```

这是 **bundle（JS 打包）** 语义。但加了 `--compile` 后，同一 flag 额外接受
**平台串**（`bun-linux-x64` 等），控制的是「嵌入哪个 baseline」。help 文本没有区分，
容易误解 —— 这是 E1.1 记录的第一个坑。

## 2. 完整可用 target 清单

来源：bun 源码 `packages/bun-release/src/platform.ts:17-131`（14 条发布平台，E1.4）。
这是**官方 npm 上真实存在的 baseline**，也就是 `--target` 能拼出来的全集：

| # | os | arch | abi | npm 包 bin 名 | 对应 `--target` 串 |
|---|---|---|---|---|---|
| 1 | darwin | arm64 | — | `bun-darwin-aarch64` | `bun-darwin-arm64` |
| 2 | darwin | x64 | — | `bun-darwin-x64` | `bun-darwin-x64` |
| 3 | darwin | x64 | — | `bun-darwin-x64-baseline` | `bun-darwin-x64-baseline` |
| 4 | linux | arm64 | — | `bun-linux-aarch64` | `bun-linux-arm64` |
| 5 | linux | x64 | — | `bun-linux-x64` | `bun-linux-x64` |
| 6 | linux | x64 | — | `bun-linux-x64-baseline` | `bun-linux-x64-baseline` |
| 7 | linux | arm64 | musl | `bun-linux-aarch64-musl` | `bun-linux-arm64-musl` |
| 8 | linux | x64 | musl | `bun-linux-x64-musl` | `bun-linux-x64-musl` |
| 9 | linux | x64 | musl+baseline | `bun-linux-x64-musl-baseline` | `bun-linux-x64-musl-baseline` |
| 10 | **android** | arm64 | android | `bun-linux-aarch64-android` | `bun-linux-arm64-android` |
| 11 | **android** | **x64** | android | `bun-linux-x64-android` | `bun-linux-x64-android` |
| 12 | freebsd | arm64 | — | `bun-freebsd-aarch64` | `bun-freebsd-arm64` |
| 13 | freebsd | x64 | — | `bun-freebsd-x64` | `bun-freebsd-x64` |
| 14 | win32 | x64 / arm64 | — | `bun-windows-x64[-baseline]` / `bun-windows-aarch64` | `bun-windows-x64` 等 |

要点：
- **target 串里的 arch 词表**（`src/bun_core/env.rs:193-200`）是
  `x86_64 | x64 | amd64 | aarch64 | arm64 | wasm` —— 顺序无关，大小写敏感。
- **npm 包里的 arch 名不同**：`x64` → `x64`，`arm64` → **`aarch64`**。转换在
  `env.rs:188-198`。
- `baseline` 与 `arm64` 不能共存：`compile_target.rs:332-335` 静默取消 baseline。
  因为上游只发 x64 的 baseline 包。
- **没有 riscv64**。`compile_target.rs:341-343` 显式拒 wasm，其他未知 token 直接
  `Global::exit(1)`。

## 3. 三个坑（全部实测）

### 坑 1：在 bionic 宿主上，`--target=bun-linux-x64` 静默产出 **bionic**（E1.3）

```console
$ bun build --compile --target=bun-linux-x64 ./i.ts --outfile o-bun-linux-x64
[12.15s] compile  o-bun-linux-x64 bun-linux-x64-android-v1.3.14
                                     ^^^^^^^^^^^^^^^^^^^^^^^ 日志自己承认下的是 android 包

$ file o-bun-linux-x64
ELF 64-bit LSB pie executable, x86-64, interpreter /system/bin/linker64,
for Android 28, built by NDK r27c
```

`interpreter /system/bin/linker64` + `for Android 28` —— 这是 bionic 二进制，
**不是 glibc**。BuildID 与 `--target=bun-linux-x64-android` 完全相同
（`3ae48c8877847575cc7bfe60abde97ebaeeff375`）。

**根因**（`compile_target.rs:40-46`）：

```rust
libc: if Environment::IS_MUSL {
    Libc::Musl
} else if Environment::IS_ANDROID {
    Libc::Android      // ← 我们在这里
} else {
    Libc::Default
},
```

target 串里没写 `musl`/`android` token → `found_libc = false` → `libc` 保持宿主推断值
`Android` → registry URL 解析成 `@oven/bun-linux-x64-android`。

旁证：`~/.bun/install/cache/` 里只有 `bun-linux-x64-musl-v1.3.14` 和
`bun-linux-x64-android-v1.3.14`，**没有 glibc 的 `bun-linux-x64`** —— 它根本没被请求。

**同类坑**：`--target=bun-linux-arm64` 产物与宿主 bun 大小不同（92M vs 90M），
`file` 却是 bionic/aarch64 —— 也是 android baseline，没换平台。

### 坑 2：`process.platform` 烘焙错（E1.6）

编译期常量 `process.platform` / `process.arch` / `process.versions.bun` 会被
**字面量替换**（`compile_target.rs:411-442` `define_values()`）。实测烘焙值：

| 编译方式 | 烘焙结果 | 对否 |
|---|---|---|
| `--compile-executable-path=<glibc baseline>`（无 target） | `"android", "arm64"` | ❌ 全错 |
| `--target=bun-linux-x64` + executable-path | `"android", "x64"` | ❌ **platform 错（最阴，见下）** |
| `--target=bun-linux-x64-musl` | `"linux", "x64"` | ✅ |
| `--target=bun-linux-x64-musl` + `BUN_COMPILE_TARGET_TARBALL_URL=<glibc>` | `"linux", "x64"` | ✅ |
| **`--target=bun-linux-x64-musl` + `--compile-executable-path=<glibc>`** ★ | `"linux", "x64"` | ✅ **唯一正解** |

`define_values()` 里 platform 维度看 `self.libc`：`Libc::Android => "\"android\""`
（`:425`），只有 `Musl | Default` 才按 os 给 `"linux"`（`:426-432`）。
而 `Default` 在 bionic 宿主上根本不会被设置（坑 1）。

**★ 关键机制（P13，见 [phase1-prereq.md](phase1-prereq.md)）**：
`--target` token 与 `--compile-executable-path` 是**两个独立旋钮** ——
token 只决定 **JS 层烘焙**，`--compile-executable-path` 只决定 **ELF**。
要同时拿到「linux 烘焙 + glibc ELF」，**必须同时给 musl token 和 glibc 路径**。

同款 5 组对照（bun 1.4.0 android blob / aarch64-bionic 宿主 / 同一 glibc baseline）：

| 组合 | `--target` | executable-path | 烘焙 platform/arch | 实际 ELF INTERP | 判定 |
|---|---|---|---|---|---|
| A | `bun-linux-x64` | 无 | **android** / x64 | `/system/bin/linker64` | 坏（bionic） |
| B | `bun-linux-x64-musl` | 无 | linux / x64 | `/lib/ld-musl-x86_64.so.1` | ✅ musl 目标可用 |
| **C** ★ | `bun-linux-x64-musl` | glibc | **linux** / x64 | **`/lib64/ld-linux-x86-64.so.2`** | ✅ **glibc 正解** |
| D | `bun-linux-x64` | glibc | **android** / x64 | `/lib64/ld-linux-x86-64.so.2` | **坏（最阴）** |
| E | 无 | glibc | **android** / **arm64** | `/lib64/ld-linux-x86-64.so.2` | 坏（全错） |

**组合 D 是最阴的失败模式**：ELF 看起来完全正确（glibc interpreter + 全套 glibc
`NEEDED`），`readelf` 验收 100% 通过，但 `process.platform` 被烘成 `"android"`。
后果见 [坑 2 的杀伤](#对本仓的杀伤)。**只做 `readelf` 验收会漏掉它。**

> ⚠️ 我最初把「组合 D」写成了推荐配方（`--target=<glibc token>` + executable-path），
> 那是在 bionic 宿主上**自相矛盾**的表述：该 token 单独用产出 bionic（坑 1），
> 配 glibc 路径又产出 platform 错件（D）。已由 P13 实测纠正，配方见下文 §4。

**对本仓的杀伤**：`tools/a2/build-v1.sh:129` 的 `A2_TARGET_FILTER` 与上游
`build.ts:146-165` 的 `--single` 过滤都依赖 `process.platform`。烘焙成 `android`
会让 linux 目标的产物在运行时选错分支。

对 opencode 具体是**致命**的：`@opentui/core` 的 `resolveNativeLibraryPath`
（P3）先判 `if (process.platform === "darwin")`、再判 linux 分支，末尾
`throw new Error("OpenTUI is not supported on the current platform: ...")`。
platform 烘成 `android` → 两个分支都不命中 → **落到 throw → TUI 100% 起不来**，
而产物本身合法、能跑。详见 [phase1-prereq.md §1.1](phase1-prereq.md#11-opentui-平台包布局n2)。

### 坑 3：只给 `--compile-executable-path` 不给 `--target`，arch 也烘焙错

上表第 1 行。`--compile-executable-path` 只换「用哪个 baseline 二进制」，
**不改 target 常量**。arch 维度必须靠 `--target` 传。

## 4. 交叉编译配方

> ★ **在 bionic 宿主上产出 glibc 产物的唯一正解是组合 C**：
> `--target=bun-linux-x64-musl` **与** `--compile-executable-path=<glibc baseline>`
> **同时给**。两个旋钮各管一头，缺一即产出静默坏件（见 §3 坑 2 的 5 组对照）。
> 复现于 1.3.14（E1.6）与 1.4.0（P13）两个版本，行为一致。

### 配方 1（推荐）：musl token + glibc baseline 路径 = 组合 C

```bash
# 1. 取目标平台的 glibc baseline
curl -fsSL -o bun-linux-x64.tgz \
  https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-1.4.0.tgz
tar xzf bun-linux-x64.tgz
file package/bin/bun
#   ELF 64-bit x86-64, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux

# 2. 编译：musl token 负责 JS 烘焙(linux/x64)，executable-path 负责 ELF(glibc)
bun build --compile \
  --target=bun-linux-x64-musl \
  --compile-executable-path=./package/bin/bun \
  ./index.ts --outfile out-linux-x64

# 3. 验证（两查，缺一不可）
readelf -l out-linux-x64 | grep interpreter
#   期望 /lib64/ld-linux-x86-64.so.2（不是 /system/bin/linker64）
strings -a out-linux-x64 | grep -oE 'PLATFORM=" \+ "[a-z]+'
#   期望 PLATFORM=" + "linux     ← 这一查是 readelf 查不出来的
```

⚠️ **target 串里的 `musl` 与实际 lib 不一致是故意的**：token 只影响烘焙，
`--compile-executable-path` 才决定真实 libc。这是绕过坑 1 的唯一手段。
**不要因为「串里写着 musl 却产出 glibc」就判定出错** —— 判据是 `readelf` + `strings`。

⚠️ **compile 日志会谎报 baseline 名**：组合 C 照样打印
`compile ... bun-linux-x64-android-v1.4.0`（P12），但复制的是你给的 glibc 二进制。
**不要拿这行日志验收**。

官方依据（E1.5，`docs/snippets/cli/build.mdx:224-226`）：
> `--compile-executable-path` — Path to a Bun executable to use for cross-compilation instead of downloading

**版本注意**：配方里驱动编译的 bun 必须是仓内那个
`artifacts/transplant/android-bun/bun-1.4.0/bun`（`build-v1.sh:48`）——
其注释 `:34-38` 明确说 1.3.14 android base 不能 compile（resolver 走到
`/data/data` AccessDenied，产物启动 SIGSEGV）。baseline tarball 版本号要与之匹配
（`bun-linux-x64-1.4.0.tgz`）。本节 E1.6 的对照数据用 1.3.14 取得，
P13 用 1.4.0 复现，两者一致。

### 配方 2：`BUN_COMPILE_TARGET_TARBALL_URL` + musl token

功能等价于配方 1（同样落到组合 C 的效果），适合不想手工解 tarball 的场景。

```bash
rm -rf clean_cache && mkdir clean_cache      # ⚠ 必须干净缓存
BUN_COMPILE_TARGET_TARBALL_URL="https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-1.4.0.tgz" \
BUN_INSTALL_CACHE_DIR=$PWD/clean_cache \
bun build --compile --target=bun-linux-x64-musl ./index.ts --outfile out-linux-x64
```

实测产出（E1.5，1.3.14）：`interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux`，
BuildID 与 glibc baseline 一致；烘焙 `"linux"/"x64"`（正确）。

依据：`compile_target.rs:120-130`，`to_npm_registry_url()` 优先读
`BUN_COMPILE_TARGET_TARBALL_URL`（需 `http://`/`https://` 前缀）。

**三个坑**：
- **必须干净 cache**。`exe_path()`（`:210-213`）先查 cwd、再查
  `<cache_dir>/<version_str>`，命中就不下载。旧缓存会让 TARBALL_URL 失效（E1.5 实测）。
- **日志误导**：命令行打印的 target 名仍是 `bun-linux-x64-musl`，但 lib 换成了 glibc。
  别信日志，信 `readelf` + `strings`。
- **同样必须带 musl token**：本配方与配方 1 的区别只在 baseline 来源
  （URL vs 本地路径），token 要求完全一样。

**推荐优先用配方 1**（本地 tarball 可控、可校验 sha256/BuildID、无缓存陷阱）。
配方 2 保留为「拿不到 glibc baseline 本地副本时」的备选。
⚠️ 未取到证据 N5-c：`BUN_COMPILE_TARGET_TARBALL_URL` 在 **1.4.0** 上的行为未实测
（E1.4 只证 1.3.14 源码支持该 env var）。因配方 1 已足够，此路径非必需。

### 配方 3：纯 musl 目标（无需任何纠正）

```bash
bun build --compile --target=bun-linux-x64-musl ./index.ts --outfile out-musl
```

唯一「什么都不用管」的目标：target 串自带 `musl` token，libc 推断与 platform
烘焙都正确（E1.6 实测）。代价是产物 NEEDED `libstdc++.so.6` + `libgcc_s.so.1`
（E1.3），目标机要能提供。

## 5. 本机与 CI 工具链现状

| 工具 | 状态 | 证据 |
|---|---|---|
| `qemu-x86_64` | ✅ 存在，v11.0.3 | E2.3 |
| `qemu-x86_64-static` / `qemu-aarch64` | ❌ 无 | E2.3 |
| `docker` | ⚠ client v24.0.6-ce 在，**daemon 不可用** | E2.3 |
| `podman` | ❌ 无 | E2.3 |
| `binfmt_misc` | ❌ `/proc/sys/fs/binfmt_misc/` Permission denied（Termux 沙箱） | E2.3 |
| `rustc` | 1.98.0（source tarball），**无 rustup** → 无法 `rustup target add` | E2.3 |
| `zig` | 0.16.0 | E2.3 |
| `zig cc -target x86_64-linux-gnu` | ✅ **实测通过**，出 glibc x64 ELF | E2.4 |

**`zig cc` 是本机唯一即插即用的交叉 C 工具链**（E2.4）：

```console
$ zig cc -target x86_64-linux-gnu t.c -o t_x64
$ file t_x64
ELF 64-bit LSB executable, x86-64, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 2.0.0
```

用途：编 shim（epoll-compat / close_range fallback / sigsys_handler）时，
**不需要** proot / 容器 / 交叉 gcc。但注意 zig 0.16.0 的已知限制
（缺 `@Type`、`std.time.Instant`，uucode 系依赖编不了）—— shim 是纯 C，不受影响。

**本机做不了闭环验证**（E2.5 实测）：

```console
$ qemu-x86_64 ./o-bun-linux-x64
qemu-x86_64: /system/bin/linker64: Invalid ELF image for this architecture
$ qemu-x86_64 ./o-bun-linux-x64-musl
qemu-x86_64: Could not open '/lib/ld-musl-x86_64.so.1': No such file or directory
```

Termux 的 `qemu-x86_64` 没有 `-L sysroot` 语义（qemu-user 只做用户态模拟），
本机也没有 glibc/musl 根文件系统 → **纯 qemu-user-static 路线在本机不可行**，
必须配 proot/distrobox 或 CI 容器提供 target sysroot。详见
[ci-and-emulation.md](ci-and-emulation.md)。

## 6. 与上游 opencode build.ts 的对接

上游 `packages/opencode/script/build.ts` 的 target 串生成（E4.2 `:174-186`）：

```ts
const name = [pkg.name, item.os === "win32" ? "windows" : item.os, item.arch,
              item.avx2 === false ? "baseline" : undefined,
              item.abi === undefined ? undefined : item.abi].filter(Boolean).join("-")
// → compile.target = name.replace(pkg.name, "bun")  即 "bun-linux-x64"
```

`allTargets`（`:83-144`）共 12 项：os ∈ {linux, darwin, win32} × arch ∈ {arm64, x64}
+ musl 变体 + baseline 变体。**无 android 项，无 riscv64。**

`:225` 还定义了 `OPENCODE_LIBC: item.os === "linux" ? "'" + (item.abi ?? "glibc") + "'" : ""`
—— 这是**编译期显式常量**，不依赖 `process.platform` 推断，所以不受坑 2 影响。
我们复用 build.ts 时应优先依赖它。

**我们的差异**：本仓 `tools/a2/build-v1.sh:129` 的 `A2_TARGET_FILTER` 把 target
硬收窄到「linux + arm64 + 无 abi + 无 avx2」一条。要扩目标，这行必须改成参数化。

⚠ 上游 build.ts 的 target 串**不带 musl token 时依赖宿主 libc 推断**。在 glibc linux
宿主上跑它是对的；**在 Android 宿主上照抄会踩坑 1**。这是我们移植时最容易漏的一处。
