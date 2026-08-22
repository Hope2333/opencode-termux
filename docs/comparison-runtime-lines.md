# OpenCode on Termux 三线运行时对比报告

**日期：** 2026-08-22
**分支：** `native-android`
**范围：** 对比三条 OpenCode-on-Termux 运行时路线，为包别名与默认选型提供依据。

| 简称 | 全称 | 代码归属 |
|---|---|---|
| **native 复活线** | 本项目 native-android 分支 · C1 官方 android Bun 底座 + module graph 嫁接复活管线 | 本仓库 `tools/transplant/` |
| **guysoft 线** | [guysoft/opencode-termux](https://github.com/guysoft/opencode-termux) · 自交叉编译 Bun v1.2.13 bionic 底座 + 同协议嫁接 | 外部仓库（patches + build scripts） |
| **glibc wrapper 主线** | 本项目 pure-android 分支主线 · bun-termux-loader 包装上游 glibc 二进制 | 本仓库 `Makefile` / `scripts/` / `tools/produce-local.sh` |

---

## 1. 一页总览表

> 所有数字均标注来源文件；guysoft 侧数字来自其仓库 README（2026-08-22 抓取）。

| 维度 | native 复活线（本项目） | guysoft/opencode-termux | glibc wrapper 主线（本项目） |
|---|---|---|---|
| **运行时机制** | 官方 android Bun v1.3.14（Bionic 直跑）+ opencode module graph 嫁接为单 ELF，ELF 手术复活 compiled-app 入口（`.bun` 节 patch + `R_AARCH64_RELATIVE` 重定位）[docs/transplant.md] | 自交叉编译 Bun v1.2.13 bionic 底座（33 文件 Bun 补丁 + 5 文件 WebKit 补丁），host Bun 1.3.2 构建后提取 module graph 嫁接追加 + 8B footer [guysoft README "How the Standalone Binary Works"] | bun-termux-loader Bionic 薄壳包装上游 `opencode-linux-arm64`（glibc Bun 内嵌），userland exec 经 glibc ld.so 二次加载 [README.md "How it works"] |
| **运行期依赖** | 零 glibc；interpreter=`/system/bin/linker64` NDK r27c [.omo/evidence/task-26-revive-latest.log verify 段]；python3 仅构建期需要 [docs/transplant.md §0.5] | 零 glibc（NDK r28b 编译，API 24+）；仅 `ripgrep` 为包依赖 [guysoft README Install/Version Pins] | 必须 glibc + openssl-glibc + bash + ncurses [README.md Dependencies 表] |
| **构建依赖** | python3 标准库 + npm 下载 + 网络；Termux 本机可跑全管线 [docs/transplant.md §0.5] | x86_64 Linux (Ubuntu 22.04+)、16GB RAM 起（WebKit 链接建议 30GB）、60GB 磁盘、NDK r28b/CMake/Ninja/Rust/Go/Zig 0.15.2/Bun 1.3.2(host)/Python3/Ruby/Perl [guysoft README Build Requirements] | Termux 本机即可（npm 下载 + loader 包装）；CI 另有 aarch64 workflow [README.md Build flow / .github/workflows/build-pure-android.yml] |
| **启动性能（实测）** | 复活版 startup min=1572ms（2506/1701/1572 三次，目标 <300ms 未达）；cold start 1798ms (<2000ms 达标)，rss=329788kB [<400MB 达标] [.omo/evidence/task-26-revive-latest.log]；1.3.13 参考：startup 1965ms、cold 2423ms [docs/transplant.md §0.2]；纯解释器底座 `--version` 参考 44ms [docs/measurements/native-baseline-1.3.13.json]（C1 证伪期测量，非 opencode 启动，仅参考） | 仓库未公布毫秒级启动基准（README 无 perf 数据）；机制上同为 kernel execve 单文件零双加载，理论接近原生路径，但无实测可引用 [guysoft README 全文无 benchmark 章节] | `--version` 页缓存热启 0.91–0.99s；内存压力冷启 2.4–4.1s（4.5× 波动）；launcher.sh 开销 +0.03s [docs/performance-optimization.md §2.2]；bench 基线 smoke=2675ms / goal=3047ms [$TMPDIR/opencode-bench-baseline-aug20.json，另见 docs/measurements/native-baseline-1.3.13.json wrapper_baseline 字段] |
| **TUI 能力（OpenTUI/FFI）** | ❌ 双层硬阻断：① 底座 TinyCC 禁用致 `bun:ffi dlopen()` 全灭（1.3.x 四入口 throw；≥1.4.0 Rust FFI 重写后仅 cc() 禁用）[.omo/evidence/task-27-tinyc-ffi.log]；② @opentui/core@0.5.6 无 android/bionic 变体，libopentui.so(linux-arm64) NEEDED=libm.so.6/libc.so.6/libpthread.so.0/libdl.so.2/librt.so.1 纯 glibc，musl 变体同样不可加载，无纯 JS 回退 [task-27 第二/三层]。定位 run/serve/--version 无 TUI 场景 [task-27 最终结论] | ✅ 完整 TUI 可用：自建 android 版 libopentui.so（patches/opentui/android-libc-link.patch 链接 NDK libc.so stub 使 dlopen 可解析符号），实测 Samsung Galaxy S10e (Android 12) 全 TUI 渲染确认 [guysoft README "What Was Done" #4 / Known Issues Working / Tested On]；TinyCC FFI 标注 Low 风险（TCC 运行时代码生成可能产不出有效 ARM64 码）[guysoft README Known Issues 表] | ✅ 完整 TUI（glibc 全兼容，OpenTUI/@parcel/watcher 原生 .so 直接可用）；代价是 TUI RSS 高位：3s burst 364MB → 8s stable 571MB HWM 583MB [docs/performance-optimization.md §2.3] |
| **版本覆盖范围** | 双格式支持：旧 trailer 格式（36B stride，≤1.3.x）+ 新 `.bun` section 格式（52B stride，≥1.18）[.omo/evidence/task-28-section-format.log]；golden 回归 4/4 PASS（1.2.9 / 1.3.11 / 1.3.13 / synth-36b）+ 实测复活 1.3.13 与 1.18.21 [task-28 验收 A/B]；未验证版本区间按 locked_versions 策略拒绝静默嫁接 [docs/transplant.md §0.4] | 版本钉死：OpenCode 1.3.13 / 目标 Bun v1.2.13 / host Bun v1.3.2 / WebKit 017930eb / ICU 75.1 / TinyCC b91835d8 [guysoft README Version Pins 表]；host 必须钉 1.3.2（36B stride 兼容 + catalog: 协议需 1.3.x），升级需整套重移植 [guysoft README "Why host Bun must be pinned to v1.3.2"] | 跟随 npm latest 即下即用（README 记录 1.17.x 时代，npm latest 已到 1.18.21 [.omo/evidence/task-26-revive-latest.log]）；无版本适配工作 [README.md / docs/performance-optimization.md §1.1] |
| **发布形态** | 单文件 ELF（如 artifacts/transplant/1.18.21/opencode-native-revived = 181,758,673B ≈173MB [.omo/evidence/task-28-section-format.log]；底座 89,796,776B ≈85.6MB [task-26 graft 段]）；暂无 deb/pacman 打包 | 三格式齐备：zip（opencode wrapper + opencode.bin + libtagfix.so/libc++_shared.so/libopentui.so）+ pacman pkg.tar.xz + deb，自动装 ripgrep [guysoft README Install Option 1–3] | deb + pacman 双格式（packing/deb、packing/pacman 模板），make all/batch 一键产出 [README.md What this branch provides / Makefile] |
| **主要风险** | TUI 硬阻断未解（换 ≥1.4.x 底座 + NDK 自建 bionic libopentui.so 两前置均为非常规工程量）[task-27 可修路径节]；startup 距 <300ms 目标远（1572ms）[task-26 item1]；新版本 ELF 布局变化需持续适配（1.4 为 Rust FFI，`.bun` 节结构待勘）[task-27 前置1] | 33 文件 Bun 补丁 + WebKit fork 永久维护负担（Bun 团队已将 Android 支持判 not planned，oven-sh/bun#9，补丁永无上游化可能）[guysoft README Upstream PR Opportunities]；版本钉死升级成本高；TinyCC FFI 不确定 [guysoft README Known Issues] | 内存压力冷启波动大（2.4–4.1s，eMMC 设备估算冷读 6–15s）[docs/performance-optimization.md §2.2/§6]；低内存设备风险（4GB 紧张、2GB OOM 风险，VmPeak ~137GB JSC 预留）[§2.3/§6]；glibc 双加载架构性开销无法归零 [§2.4] |
| **文件监听（watcher）** | @parcel/watcher 在 Termux 加载失败 → 完全无文件监听；配套 tools/watcher/watcher.c（NDK inotify 递归）+ shim.js 哨兵方案兜底 [docs/transplant.md watcher 附录] | @parcel/watcher `.node` 为 x86_64 编译，dlopen 报 EM_X86_64 vs EM_AARCH64，优雅降级 polling [guysoft README Known Issues 表] | 上游原生模块直接可用（glibc 环境），无降级 [README.md Constraints 表反证：native 模块均带 glibc .so] |
| **维护成本与上游耦合** | 管线单文件 python3（transplant.py + revive_patch.py），复用官方 android Bun 发布资产（PR #29675 关闭但资产照发）[docs/transplant.md §0.1/§0.2]；每版仅需 detect→patch→verify | 全套自维护交叉编译链（ICU/WebKit/TinyCC/Bun/OpenTUI 五个 Stage）[guysoft README Build pipeline 七阶段]；CI 热缓存 ~4min，WebKit 冷编 60–90min [同上] | 最薄：包装层 ~12KB Bionic 壳 + launcher.sh [README.md How it works]；上游发版零改动跟随 |

---

## 2. native 复活线详述（本项目 native-android）

### 2.1 实现原理

C1 路线：以官方预编译 android Bun（v1.3.14，Bionic 直跑，interpreter `/system/bin/linker64`）为底座，
把 opencode 的 module graph 拼接成单个可 execve 的 ELF。此前"三重证伪"结论已被推翻——真因是
assemble 从未 patch `.bun` 节的 `BUN_COMPILED.size`（standalone 检测链在 android bun 中完整存在）。

复活手术（`tools/transplant/revive_patch.py`，commit `57ddee1`）两处关键修正：

1. patch 点 = `.bun` 节起始 `0x5568000`（getter 返回节起始直接解引用），非 +8；
2. android bun 是 PIE，检测链把该值当绝对指针——直写 vaddr 会 SIGSEGV，须向
   `.rela.dyn` 追加 `R_AARCH64_RELATIVE` 重定位（r_offset=0x5568000 type=1027，
   addend=payload vaddr），ASLR 安全。实测 reloc_count=50 [.omo/evidence/task-26-revive-latest.log]。

管线：extract → detect → convert(仅 36B) → patch → assemble → revive → verify
（`make transplant VER=x.y.z` 一键）。2026-08-22 起支持新版 `.bun` section 格式
（opencode ≥1.18）：graph 位于 `.bun` PROGBITS 节内（首 8B=u64 LE BUN_COMPILED.size，
节尾 [Offsets32][marker16]，stride 52B），assemble 步跳过、revive 前幂等下载底座
[.omo/evidence/task-28-section-format.log]。

### 2.2 依赖树

- 运行期：零 glibc。仅 Android linker + 内嵌资产。
- 构建期：python3 标准库 + npm（下载 opencode tgz 与底座）+ 网络 [docs/transplant.md §0.5]。
- watcher 兜底：tools/watcher/watcher.c 需 NDK 编译（可选组件）。

### 2.3 构建链路

```
npm 下载 opencode-linux-arm64 tgz
  → extract（trailer 或 .bun section 定位 graph）
  → detect（stride 36B/52B 判别）
  → revive_patch（.bun 节 patch + RELATIVE 重定位追加）
  → verify（execve --version 断言 + transplant-verify 七项离线检查）
```

### 2.4 已知问题

| # | 问题 | 数据来源 |
|---|---|---|
| 1 | TUI 完全不可用：`Failed to initialize OpenTUI render library: bun:ffi dlopen() is not available in this build (TinyCC is disabled)`。第一层禁用点 scripts/build/config.ts:619-622（1.3.x）/ :898-900（v1.4.0）`abi === "android"` 强制 tinycc=false；第二层 @opentui 无 bionic 变体且无 JS 回退 | [.omo/evidence/task-27-tinyc-ffi.log] |
| 2 | startup 1572ms（min，三次 2506/1701/1572），距 <300ms 目标差距大；graph 1314 modules 比 1.3.13 的 554 反而更快 | [task-26 item1] |
| 3 | 1.3.13 serve 曾报 `Configuration is invalid`（schema 将 `"lsp": true` bool 判非法）；1.18.21 serve+HTTP200 已 PASS（port=43123） | [docs/transplant.md §0.2 / task-26 item4] |
| 4 | 插件生命周期与 hooks 已验证可用：plugin v1→v2→rollback PASS、post_install/post_upgrade hooks PASS | [task-26 item5/6] |

### 2.5 定位

run / serve / --version 无 TUI 场景；完整 TUI 由 wrapper 主线承担 [task-27 最终结论]。

---

## 3. guysoft/opencode-termux 详述

> 本节事实全部来自其仓库 README 与文件树（https://github.com/guysoft/opencode-termux ，main 分支，2026-08-22 抓取）。

### 3.1 实现原理

因 Bun 官方拒绝 Android 支持（oven-sh/bun#9 marked "not planned"），该项目从源码交叉编译
整条 Bun 工具链（含 WebKit/JSC 引擎）产出 bionic 底座，再走与本线相同的 module graph 嫁接协议：

1. host Bun（钉死 v1.3.2）执行 `bun build --compile` 构建 host 平台 standalone；
2. 按 `\n---- Bun! ----\n` trailer 定位并提取序列化 module graph（scripts/build-opencode-android.ts）；
3. 就地修补 graph（修 undici 全局引用）；打包前把 x86_64 libopentui.so 换成自建 ARM64 android 版再嵌入；
4. 追加到底座 Bun 后写 8B `total_byte_count` footer。

产物布局 `[Android Bun ~96MB][Module graph ~46MB][u64 LE 8B]` [guysoft README "How the Standalone Binary Works"]。

关键工程补丁（文件路径均可在其仓库追溯）：

- `patches/bun/android-support.patch` — 33 文件：NDK CMake toolchain（cmake/toolchains/android-aarch64.cmake 新增）、PIE/-fPIC、TLS 64B 对齐（android_tls_align.s 汇编防 __emutls）、close_range/preadv2/pwritev2/epoll_pwait2 seccomp 回退、JSC usePollingTraps=true（debuggerd 截获 SIGSEGV）、StandaloneModuleGraph Offsets 结构扩展等；
- `patches/webkit/android-support.patch` — 5 文件：bcmp→memcmp、aligned_alloc→posix_memalign、backtrace/pthread_getname_np stub 等；
- `patches/zig/posix-android-sigaction.patch` — Zig stdlib sigaction/sigprocmask 绕过 Bionic（152B vs 32B 结构体错位会静默内存损坏），改裸 syscall；
- `patches/opentui/android-libc-link.patch` — libopentui.so 链接 NDK libc.so stub，使 dlopen 能解析 getauxval 等符号（这正是本线 TUI 阻断的解法示范）。

### 3.2 依赖树

运行期零 glibc；唯一包依赖 ripgrep（pacman/deb 自动安装）[guysoft README Install]。
目标 API 24（Android 7.0+）。

### 3.3 构建链路

七阶段 CI（.github/workflows/build.yml）：ICU 75.1 (~5min) → WebKit/JSC (~60–90min, CACHED)
→ TinyCC (~1min) → Bun (~30–45min, CACHED) → libopentui.so (~2min) → OpenCode bundle (~30s)
→ Packages (~10s)；热缓存全程 ~4min [guysoft README Build pipeline]。
构建机要求 x86_64 Linux、16GB RAM 起（WebKit 链接建议 30GB）、60GB 磁盘 [Build Requirements]。

### 3.4 已知问题

| 问题 | 严重度 | 来源 |
|---|---|---|
| @parcel/watcher `.node` 为 x86_64 编译，dlopen 报 EM_X86_64(62) vs EM_AARCH64(183)，降级 polling | Low | [guysoft README Known Issues] |
| `bun upgrade` 在 Android 禁用（无官方发布通道） | Low | 同上 |
| TinyCC FFI：libtcc.a 已链接但 TCC 运行时代码生成可能产不出有效 ARM64 码 | Low | 同上 |
| SIGPWR 信号刷屏（Android 电源管理相关，非错误） | None | 同上 |

版本钉死矩阵（Upgrade 即重移植）：OpenCode 1.3.13 / target Bun v1.2.13 / host Bun v1.3.2 /
WebKit 017930eb / ICU 75.1 / NDK r28b / Zig 0.15.2 / TinyCC b91835d8 [Version Pins 表]。
host 钉 1.3.2 的原因：36B stride 兼容（Bun ≥1.3.11 变 52B）且 opencode monorepo 的
`catalog:` 协议需 Bun 1.3.x——两头不靠的唯一甜点版本 ["Why host Bun must be pinned to v1.3.2"]。

值得注意：其嫁接协议与本线旧 trailer 路径同源（36B stride 时代）；本线 transplant.py 已扩展
支持 52B section 格式，guysoft 尚停留在 36B + host 钉版方案（对比见第 1 节"版本覆盖"行）。

---

## 4. glibc wrapper 主线详述（本项目 pure-android）

### 4.1 实现原理

上游 `opencode-linux-arm64` 是 glibc 链接的 Bun-compiled 单 ELF。bun-termux-loader 在其前部
拼接 ~12KB Bionic 薄壳：读 `/proc/self/exe` 定位 BUNWRAP1 元数据 → 抽取内嵌 opencode 二进制 →
mmap glibc 的 ld.so 并跳转入口（userland exec，不走 execve 以保住 `/proc/self/exe` 指向），
手工铺 10MB 栈 + 20 项 auxv [README.md "How it works"；docs/performance-optimization.md §2.4]。

### 4.2 依赖树

glibc + openssl-glibc（TLS）+ bash + ncurses，全部 apt/pacman 标准包 [README.md Dependencies]。

### 4.3 构建链路

```
make all VER=x.y.z PKG=both
  → clean → runtime（tools/produce-local.sh: npm 下载 + loader 包装）
  → stage（scripts/build.sh）→ deb（scripts/package/package_deb.sh）
  → pacman（scripts/package/package_pacman.sh）
```

runtime 文件 183,232,603 bytes（≈183MB）[docs/performance-optimization.md §2.2]。

### 4.4 性能画像（实测）

| 场景 | 数值 | 来源 |
|---|---|---|
| `--version` 页缓存热启 | 0.91–0.99s | [docs/performance-optimization.md §2.2] |
| 内存压力冷启 | 2.4–4.1s（4.5× 波动） | [§2.2] |
| bench 基线 smoke/goal | 2675ms / 3047ms | [$TMPDIR/opencode-bench-baseline-aug20.json；docs/measurements/native-baseline-1.3.13.json wrapper_baseline] |
| TUI RSS | 3s burst 364MB → 8s stable 571MB HWM 583MB | [§2.3] |
| serve RSS | 3s 140MB HWM 183MB → 8s 305MB HWM 341MB | [§2.3] |
| VmPeak/VmSize | ~137GB / ~77GB（JSC 地址预留，非实占） | [§2.3] |

优化上限评估：malloc+read_all 183MB 堆读改 mmap 直映射后热启预估 0.3–0.5s [§2.5/§7.3]；
android Bun 解释器 `--version` 仅 0.010–0.048s，说明 60–90× 的机制级差距存在于双加载架构本身 [§1.2]。

### 4.5 已知问题

- 内存压力/eMMC 设备冷启不可控（30–80MB/s 顺序读估算冷读 6–15s）[§6]；
- 低内存设备风险：4GB 紧张、2GB OOM 风险 [§6]；
- glibc 双加载为架构性开销，无法归零 [§2.4]；
- 作为交换：TUI、watcher、FFI 全功能无降级，版本即下即用。

---

## 5. 选型建议

**包别名约定**：终端用户命令保持 `opencode` 不变，由 `opencode-native`（native 复活线产物）
或 `opencode-glibc`（wrapper 主线产物）两个具体包提供，互斥安装。

**当前默认推荐：`opencode-glibc` 成熟路线**（已拍板，写入本文档作为决议）：

1. **功能完整性**：唯一同时具备完整 TUI + watcher + FFI 的路线；native 复活线 TUI 双层硬阻断
   （bun:ffi 禁用 × @opentui 无 bionic 变体）短期无解 [.omo/evidence/task-27-tinyc-ffi.log 最终结论]；
2. **版本覆盖**：npm latest 即下即用（1.2.0→latest 全线打通的是 transplant 管线的检测能力，
   而 wrapper 线连适配都不需要）；guysoft 线钉死 1.3.13；
3. **成熟度**：deb/pacman 双格式 + 插件生命周期 + hooks + CI 全链路已在产；
4. **代价接受**：热启 ~1s、冷启 2.4–4.1s、TUI RSS ~571MB，在目标设备（aarch64 UFS 15.7GB RAM）
   可接受 [docs/performance-optimization.md §2.2/§2.3]。

**后续观察点**：

- native 复活线：待 bun ≥1.4.x 底座嫁接适配（Rust FFI 后 dlopen 解禁）+ @opentui bionic 变体
  出现（guysoft 的 patches/opentui/android-libc-link.patch 证明自建可行），届时可升级为默认；
- guysoft 线：作为零 glibc 全功能参照系，其 TLS 对齐/seccomp 回退/JSC polling traps 补丁集
  是本线未来换底座时的移植清单 [docs/performance-optimization.md §4.3]。

---

## 附：数据来源索引

| 来源 | 内容 |
|---|---|
| `README.md` | wrapper 主线架构、依赖表、构建流 |
| `docs/transplant.md` | C1 复活手术细节、管线命令、遗留问题、watcher 附录 |
| `docs/performance-optimization.md` | §1.1 三线机制对比、§2.2–2.5 wrapper 实测性能、§4.3 guysoft 补丁清单、§6 eMMC/低内存评估 |
| `docs/native-android-research.md` | 2026-05 零 glibc 研究（binary 结构对比、三方案裁定） |
| `docs/measurements/native-baseline-1.3.13.json` | 44ms/19ms 解释器参考值 + wrapper_baseline 2675/3047ms/364MB |
| `.omo/evidence/task-26-revive-latest.log` | 1.18.21 嫁接全程：startup 1572ms、cold 1798ms、rss 329788kB、serve HTTP200 |
| `.omo/evidence/task-27-tinyc-ffi.log` | TinyCC 禁用链（config.ts:619-622/:898-900）、@opentui glibc-only 证据、三层裁定 |
| `.omo/evidence/task-28-section-format.log` | `.bun` section 格式支持、golden 4/4、sha256(revived) |
| github.com/guysoft/opencode-termux README | guysoft 线全部事实（patches 路径、Version Pins、Known Issues、Build pipeline） |
