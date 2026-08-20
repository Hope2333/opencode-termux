# OpenCode Termux 性能优化路线图

**生成:** 2026-08-20  
**基准设备:** 联想拯救者 PLC110 (aarch64 / Android 16 / API 36 / UFS, 15.7GB RAM)  
**基线数据:** `$TMPDIR/opencode-bench-baseline-aug20.json`  
**基准脚本:** `scripts/bench/bench-opencode.sh`

---

## 1. 上游核查结论

### 1.1 guysoft/opencode-termux 与本项目的本质区别

| 维度 | guysoft/opencode-termux | 本项目 (Hope2333/opencode-termux) |
|---|---|---|
| 路线 | **原生 Bionic** | **wrapper 包装 glibc** |
| 启动机制 | kernel `execve` 单文件（Module graph 拼接在 Bun 后） | userland exec 借 glibc ld.so 二次加载 |
| glibc 依赖 | 零（NDK 编译，`/system/bin/linker64`） | 必须（`apt install glibc`） |
| Bun | **自行交叉编译 v1.2.13**（33 文件补丁 + WebKit 5 补丁 + ICU 75.1 + TinyCC + NDK r28b） | 复用上游 npm `opencode-linux-arm64` 内嵌 Bun（glibc 版） |
| 版本 | 钉死 1.3.13 / Bun 1.2.13（补丁不可迁移，升级需重新移植） | 跟随 npm 最新版本 |
| 已知降级 | @parcel/watcher 是 x86_64 ELF → 退化 polling；TinyCC FFI 可能无效；bun upgrade 禁用 | 无（glibc 全兼容） |
| 构建 | x86_64 Linux, 16GB RAM min, 60GB 磁盘, CI ~4min 热缓存 | 无需编译，produce-local.sh 下载+包装 |

### 1.2 关键转折点: 上游 Bun 已发布官方 Android 预编译

**2026-08-20 实证（本次测量）:**

1. **PR #29675** "Add aarch64-linux-android target" — **closed / NOT merged**（`merged_at: null`）。该 PR 增加 `--abi=android` 交叉编译 + `bun build --compile --target=bun-linux-arm64-android`。
2. **但 Bun v1.3.14 release 资产已实发 6 个 android 包**（GitHub API 实证）：

```
bun-linux-aarch64-android.zip        34,926,314 bytes
bun-linux-aarch64-android-profile.zip 274,932,074 bytes
bun-linux-x64-android(-baseline)(-profile).zip ×4
```

3. **本机实测 android Bun 直接可跑**（`/data/data/com.termux/files/usr/tmp/bun-android-probe/`）:

```
$ bun --version
1.3.14
$ bun hello.js
hello-bun-android 1.3.14 arm64 android
$ file bun
ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64, for Android 28,
built by NDK r27c, not stripped
```

   - 89.8MB 单文件，`/system/bin/linker64` 原生解释器，**零 glibc、零 wrapper、kernel execve 直接启动**。
   - `bun --version` 启动 **0.010s**（对比 opencode wrapper ~2.7s）。

4. **遗留限制: `bun build --compile` 在 Termux 仍失败**（本机复现）:

```
error: Cannot read directory "/data/": AccessDenied
```

   与 README 记载一致（Bun 从 `/` 扫描 FS 解析 import）。此限制**不影响模块图移植路线**——移植是从已编译的 npm 二进制提取模块图，而非在设备上重新编译。

### 1.3 结论

- **原生 Bionic 路线已被上游官方底座支持**（android Bun 预编译资产），不再需要 guysoft 式全套自建编译链（Bun+WebKit+ICU+TinyCC 补丁）。
- 本项目仍需要的移植工作 = guysoft 的**模块图移植 + 已知降级修补**（缩小到他已证明的步骤集），版本不再钉死而是按 opencode 版本区间自动化（见 §4）。
- wrapper 路线（现状）可立即做的**低成本优化**见 §5.1。

---

## 2. 基线数据（本机, 2026-08-20）

### 2.1 设备环境

- 机型: PLC110（联想拯救者） / aarch64 / Android 16 / API 36 / kernel 6.6.118
- 内存: MemTotal 15.7GB, 采样时 MemFree 仅 481MB, Cached 3.4GB（内存压力大）
- 存储: UFS（dm-77, 936G 用户分区）
- runtime: `/data/data/com.termux/files/usr/lib/opencode/runtime/opencode` = **183,232,603 bytes (183MB)**
- 缓存: `$TMPDIR/bun-termux-cache/bun-45af29dd0c497dbb`（183MB, 命中即不重写）

### 2.2 启动时间

| 测量 | 结果 |
|---|---|
| opencode wrapper --version（页缓存热, 初次会话） | **0.91 - 0.99s** |
| opencode wrapper --version（内存压力冷读） | **2.4 - 4.1s**（波动 4.5×） |
| launcher.sh 路径（bin/opencode） | +0.03s 增量 |
| 对照 android Bun --version | **0.010 - 0.048s** |
| **加速比** | **约 60 - 90×** |

> 波动根因: wrapper 每次启动 `malloc(183MB) + read_all()` 堆读嵌入 ELF，读写完全依赖内核页缓存二次利用。内存压力把 183MB 挤出 Cached 后，每次启动都从 UFS 冷读 → 2.7s+。低端 eMMC 上可预期 5-10s+。

### 2.3 内存占用 (RSS/HWM)

| 采样点 | 模式 | RSS | HWM |
|---|---|---|---|
| 启动 3s（爆发） | TUI 交互 | 364MB | — |
| 启动 8s（稳定） | TUI 交互 | 571MB | 583MB |
| 启动 3s | serve 模式 | 140MB | 183MB |
| 启动 8s | serve 模式 | 305MB | 341MB |

- 虚拟地址空间 VmPeak 137GB/VmSize 77GB（JSC 保留映射，非实际占用，Android 默认无 overcommit 限制）
- 对照 android Bun mini 脚本: 启动 RSS 忽略不计（<30MB 量级）

### 2.4 启动路径开销分解（wrapper.c 实读确认）

`/data/data/com.termux/files/home/bun-termux-loader/wrapper.c`:

1. `main()` → `open(/proc/self/exe)` → 读 ELF 头
2. `read_all(fd, bun, bun_sz)` — **堆读 183MB 嵌入 Bun ELF**（不可绕，除非改 mmap）
3. `cache_bun_elf()` — fnv1a 采样 hash（首/末 64KB + size），命中缓存则不写盘
4. 读 BUNLIBS1 元数据 → 提取 native libs
5. `userland_exec()` — mmap glibc ld.so → 手工构造 10MB 栈 + 20 项 auxv → 跳转
   - 注: **bun 本体不是 mmap 而是堆读后由 ld.so 二次加载**，183MB 全程内存搬运

---

## 3. 两分支迁移顺序

### 3.1 现状（分支拓扑）

```
pure-android（当前 mainline, wrapper 路线, 含未被其他分支吸收的改动）
glibc（旧 wrapper 路线基底）
```

### 3.2 迁移顺序（用户确认方案）

1. **【先做】pure-android 现状并入 glibc 分支定稿**
   - 包装路线所有成熟改动（produce-local、plugin-manager、hooks、批量构建）合入 glibc
   - glibc 成为纯 wrapper 路线的稳定归宿，后续仅做低成本优化（§5.1）
2. **【后做】pure-android 转型为混合原生路线**
   - 基底切换为官方 android Bun（§4）而非自编译
   - 目标: 真原生 Bionic、零 glibc、降级补全、版本不钉死

---

## 4. 原生路线图（pure-android 转型）

### 4.1 目标架构

```
[官方 android Bun v1.3.x (89.8MB, /system/bin/linker64)] + [opencode Module graph (约46MB)]
= 单个 ELF, kernel execve, 零 glibc, 零 wrapper
```

### 4.2 移植手术自动化（用户明确要求的版本区间 hash patch）

**背景**: guysoft 发现不同版本 Bun 的 compiled-binary 布局不同（host Bun ≤1.3.2 的 CompiledModuleGraphFile stride 36B vs ≥1.3.11 的 52B；catalog 协议需 1.3.x）。每个 opencode npm 版本内置的 Bun 运行时/模块图格式不同，纯手工逆向不可维护。

**自动化方案**（对应"版本区间 hash patch"）:

```
输入: opencode-linux-arm64@<VER>.tgz (npm 下载)
  → 探测内嵌 Bun 版本字节 (Bun! marker 附近版本串)
  → 归类到已知格式区间 [36B条带 | 52B条带 | ...]
  → 查移植配置表 (per-format: 偏移、header 布局、loader 拼接方式)
  → 执行拼接: [android Bun] + [模块图重定位] + [8B total_byte_count LE]
  → 输出: 可直接 execve 的原生 opencode-<VER> ELF
```

- 新增 opencode 版本 → 仅需验证其内置 Bun 是否落入已覆盖区间；否则逆向一次并登记新区间表
- 移植配置表 + 探测脚本入库 `tools/transplant/`（新脚本目录，与现有 tools/ 风格一致）
- 自动化管线挂入 `make release-upload` 之前的 `make transplant VER=...`

### 4.3 移植所需补丁集（取自 guysoft 已验证清单，按需裁剪）

| 补丁 | 目的 | 本路线是否需要 |
|---|---|---|
| zig sigaction 152B→直调 syscall | Bionic struct 差异 | ✅ 继承 |
| .tbss 64B 对齐 | 防 TCB 冲突 | ✅ 继承 |
| seccomp 拦截 close_range/preadv2/pwritev2/epoll_pwait2 → ENOSYS | 内核缺失 syscall | ✅ 继承 |
| JSC usePollingTraps=true | debuggerd 抢占 SIGSEGV | ✅ 继承 |
| TinyCC FFI | 视模块图是否含 FFI 依赖 | ⚠️ 验证后定 |
| ICU | android Bun 已内置 ICU？需验证 | ⚠️ 验证后定 |

### 4.4 验证清单（移植后每版本必须通过）

1. `opencode --version` < 300ms
2. TUI 交互渲染正常（无乱码/卡死）
3. `opencode run "hi"` 端到端对话成功
4. `opencode serve` 启动 + HTTP 请求响应
5. plugin install/update/rollback 全生命周期
6. 系统 skill hooks（post-install/upgrade/remove）
7. 冷启动（fresh boot 后首次）< 2s，RSS 稳定 < 400MB

---

## 5. Watcher 模块设计（降级补全）

### 5.1 背景

opencode 依赖 `@parcel/watcher`（文件监听）。guysoft 移植版中该 `.node` 文件是 x86_64 ELF（EM_X86_64 vs EM_AARCH64 不匹配）→ **退化为 polling**，导致文件变更响应延迟。

### 5.2 目标

**不依赖重构 opencode 本身**，提供 Termux 原生的目录监听能力，作为降级补全。

### 5.3 设计方案

| 方案 | 机制 | 优点 | 缺点 | 推荐 |
|---|---|---|---|---|
| A. 独立原生 watcher 守护模块 | 独立小 ELF（NDK 编译）用 inotify 递归监听工作目录，通过 Unix socket/stdout 事件流通知 opencode 兼容层 | 真事件驱动、零 CPU 空闲开销 | opencode 内仍走 polling 抽象层，需 shim 转换 | ⭐ 推荐 |
| B. 静态重建 @parcel/watcher | NDK 编译 @parcel/watcher 的 aarch64 版 `.node` 替换 | 与上游 API 完全兼容 | 需匹配 Bun 的 NAPI ABI | 备选 |
| C. 保持 polling + 调优轮询间隔 | 降低 poll 频率 | 零改动 | 响应延迟仍高 | 兜底 |

**方案 A 落地结构**:

```
tools/watcher/watcher.c        # inotify 递归监听 (NDK, ~50KB 静态 ELF)
tools/watcher/shim.js          # opencode 插件侧: 订阅 socket 事件 → 触发 opencode 的变更回调
packing/manifests/watcher.json # 安装清单 (随包安装到 $PREFIX/lib/opencode/watcher/)
```

- 递归 inotify 监听（目录树 + 符号链接处理，仿 `fswatch` 语义）
- 事件去抖（50ms coalesce）+ 批量上报（防事件风暴）
- 工作目录变更时自动重挂（`git checkout` 等大操作）

### 5.4 验证

1. 创建/修改/删除文件 → <100ms 内 opencode 感知
2. 万级文件目录初始枚举 < 1s
3. 空闲 CPU < 0.5%（对比 polling 的持续占用）

---

## 6. 低端兼容策略（硬约束）

**设备约束**: 必须兼容中低端设备（eMMC 存储、低内存）。当前仅本机（UFS 旗舰）可实测，低端策略先立项建模，后续在低端设备复测。

### 6.1 存储层（eMMC 场景预估）

| 项 | UFS 实测 | eMMC 预估 | 策略 |
|---|---|---|---|
| wrapper 冷读 183MB | 2.4-4.1s | **6-15s**（eMMC 顺序读 30-80MB/s） | 快速优化（§7.1）消灭堆读 |
| 原生路线 冷启动 | ~0.1s（89.8MB 由 linker 映射, 按需缺页） | 0.3-1s | 天然免疫此问题 |
| 缓存写入 183MB | 首次一次性 | 同左 | 保持命中即不写（已实现） |

### 6.2 内存层

- 当前 TUI 稳定态 RSS 571MB — **低端 4GB 设备可运行但紧张**；2GB 设备可能 OOM
- 原生路线预估: 模块图加载后 JSC 驻留可压至 **250-350MB**（无 glibc 双份 libc + wrapper 开销）
- 策略: 提供 `opencode --memory-mode=low` 环境开关（降低 JSC heap 上限、关闭非必要后台任务）

### 6.3 兼容矩阵（目标）

| 设备级别 | 存储 | RAM | 冷启动目标 | RSS 目标 | 状态 |
|---|---|---|---|---|---|
| 旗舰 | UFS | ≥8GB | <1s（原生）/ <2s（wrapper 优化后） | <400MB | ✅ 本机已测 |
| 中端 | UFS/eMMC | 4-6GB | <2s | <350MB | 📋 待测 |
| 低端 | eMMC | 2-4GB | <3s | <300MB（low 模式） | 📋 待测 |

---

## 7. 优化措施总览

### 7.1 Wrapper 路线（glibc 分支定稿后的低成本优化, 立即可做）

1. **OFFSET 直读缓存头**（改 build.py 阶段）: 启动时按固定偏移读 BUNWRAP1 元数据 + 每 lib 的文件偏移表，直接 mmap 各段，**消灭 183MB 堆读**
2. **launcher.sh → 静态 launcher**（可选）: bin/opencode 改为链接到 native 小 ELF（省 bash 解释 + fork 开销 ~30ms）
3. **缓存目录移到持久位置**: `$TMPDIR` 在部分设备被清；移到 `$XDG_STATE_HOME` 或安装目录旁，防冷读重复
4. **预分配 + 顺序预读**: read_all 改 `posix_fadvise(WILLNEED)` 提前拉页，让 UFS 并发预读

### 7.2 原生路线（pure-android 转型, 中期主线）

1. 官方 android Bun 底座（已实证可用）
2. 移植手术自动化（§4.2）集成到 `make transplant`
3. watcher 模块（§5）
4. 真 native launcher（不需要 bash）

### 7.3 量化预期

| 指标 | 现状 | wrapper 优化后 | 原生路线 |
|---|---|---|---|
| 启动（页缓存热） | 0.9s | 0.3-0.5s | <0.15s |
| 启动（内存压力冷读） | 2.4-4.1s | 0.5-0.8s | <0.3s |
| TUI 稳定 RSS | 571MB | ~550MB | **250-350MB** |
| glibc 依赖 | 必须 | 必须 | **零** |
| 版本升级成本 | 下载即用 | 同左 | 移植配置表登记 |

---

## 8. 附录: 本次实测原始过程

见 `$TMPDIR/opencode-bench-baseline-aug20.json`（机器可读）+ `scripts/bench/bench-opencode.sh`（可复跑的基准工具）。

```bash
# 复跑基线
bash scripts/bench/bench-opencode.sh --runs 5 --label <name> --device-class ufs \
  --runtime $PREFIX/lib/opencode/runtime/opencode \
  --bun /data/data/com.termux/files/usr/tmp/bun-android-probe/bun-linux-aarch64-android/bun
```