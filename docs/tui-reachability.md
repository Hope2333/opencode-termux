# TUI 可达性判定表（rc6-b2-upx-tui 终版）

> 目标：任意 Android（bionic）/内核组合 → 查表即得「TUI 可达性 + 对位修补清单」。
> 依据：rc6-b2-upx-tui 四份定谳（task-1 TLSDESC / task-2 shim 落地 / task-3 readiness /
> task-4 pty 拼接）+ 2026-10-02 终版追补（task-v1graft 双代验证 / task-ocomp-graft UPX×graft /
> task-v1rgfix effect stat / task-v1tui-layer 版本归因），证据全文在
> `.omo/evidence/rc6-b2-upx-tui/`（ledger.jsonl 有索引；本表为其可版本化归档；
> 机制规则卡与假设矩阵终版全文见文末附录）。
>
> 为何独立成文而非塞进 `compressed-line.md`：判定表横跨原生线与压缩线两代、
> 覆盖整机设备矩阵，而 compressed-line.md 是按包契约组织的；本文是其上游的
> 设备侧判定层，compressed-line.md 的 pty 小节是判据 3 的包侧实现。

## 回归门槛

脚本：`.omo/evidence/rc6-b2-upx-tui/regress-tui.sh`
判据：`script -qec` 真 PTY 起 TUI，10s 内出现 ANSI 渲染帧（≥5KB）且无
SIGSEGV / bun.report 链接（oscar 实测量级：崩溃=1.3KB bun.report，正常渲染=14-15KB）。
沙箱全套 XDG/TMPDIR 隔离 + 预写分代端口（判据 2 机制的直接二进制等价），不碰用户数据与常驻装机。
- 本机旗舰（Android 15 / kernel 6.6.118，`opencode-native-tlsdesc-trial`）：2/2 GREEN（12385B / 10269B，task-5-gates.txt）
- oscar 一键命令行：`bash regress-tui.sh --oscar`（ssh + scp 试件 + 远程同判据，本轮命令就绪未实跑）

## 判定表

| # | 判据 | 不满足时的症状 | 对位修补 | 证据锚 |
|---|------|---------------|----------|--------|
| 1 | **bionic ≥ 10？**（linker TLSDESC 支持） | Android 9：libopentui 首次初始化即 `SIGSEGV SEGV_MAPERR@0x0`（TLSDESC resolver 槽=NULL，`blr x1`→pc=0）；旗舰同件正常 | TLSDESC 自解析 shim：`tools/transplant/tlsdesc-shim/`（模块内 ctor 回填 emutls 语义槽，仅 bionic 9 生效、10+ 为 no-op），`tools/transplant/transplant.py` 自动 graft `libopentui.embed.so`（`build-libopentui.sh` 门控）。oscar 真机 4/4 渲染零崩。**双代验证完成**：v1 1.18.32 runtime 重放同款 graft 后 oscar 真 PTY 全活化（压/未压双活 + session LLM 往返 "ok" rc=0，对照 graft 前 4.5s 确定性崩）——修法对 v1/v2 两代通用 | task-1-jsc.txt（根因裁决书）；task-2-jitfix.txt（落地+红测矩阵）；task-v1graft.txt（v1 重放）；oscar-logs/ |
| 2 | **多代共存？**（plain `opencode` 与 `opencode1` compressed 同时驻留） | TUI 卡 125s 后 "Timed out waiting for the background service"：两代默认端口同为 0xc0de=49374，XDG 注册文件分代隔离 → 本代反复 spawn `serve --service` 全部 EADDRINUSE exit-1，failure 被活 contender 掩蔽空转到 120s 死线 | launcher 端口分代：`scripts/opencode1-launcher.sh` 为本代 bootstrap 独立端口 49376（config `service.json` 写/注入，best-effort 回落）。等价于「预写 `$XDG_CONFIG_HOME/opencode/service.json` 端口」 | task-3-readiness.txt（根因 + oscar 全链路 READY 6.14s）；commit 29d3f69 |
| 3 | **会话期 pty？**（TUI 内开真实终端会话，bionic/旧内核） | TUI 外壳照常渲染，但会话期 bun-pty 内嵌 gnu `librust_pty` bionic dlopen 必败（缺 libpthread.so.0 等）；musl 件又缺 4 类符号（bcmp/__errno_location/__xpg_strerror_r/posix_spawn_file_actions_addchdir_np） | BUN_PTY_LIB 拼接：`tools/bun-pty-splice/`（musl librust_pty + shim + DT_NEEDED 等长补丁，sha256 锚定），launcher 检测到资产才注入（向后兼容）。包侧随包见 `docs/compressed-line.md` §pty 拼接 | task-4-pty.txt（oscar dlopen 8/8 符号 + environ 实证）；commit b302432 |
| 4 | **内核 3.18 专项？**（epoll_pwait2 / pidfd / memfd 缺失） | **均非 TUI 外壳阻塞项（已逐项排除）**：epoll_pwait2 ENOSYS——内嵌 bun 1.4.0 已含 #32490 修复且逃生 env 5/5 仍崩（与崩线无关）；pidfd_open 缺失有 waiter-thread fallback（spawn_process.rs L500-574）；memfd_create ENOSYS 与 JSC exec 分配无因果（serve 模式同机 JIT 正常 20s+） | 无需修补；保留判据仅供排障时快速排除，不进 release 门 | task-1-jsc.txt §5；draft 机制卡 ②③；ledger.jsonl todo1（LD_PRELOAD 取证含逃生 env 裁决） |
| 5 | **UPX×graft 组合？**（压制品出货规则） | graft 件一经 UPX 压制即崩（rc=139，oscar 启动即崩 / 本地退出崩）；二分矩阵排除 shim 逻辑（noctor 也崩）、回填（v3c/v11 也崩）、提取后 dlopen 的 .so 内容（换回旧 lib 仍崩）——崩因跟随主 ELF 的 UPX 压缩产物本身；疑 UPX memfd 布局 × bun 固定 VA 区预留交互，根因未钉死，待专项 | **graft 件一律未压出货**：2.0.12-2 起包载未压 graft runtime（94M，tar/gz 后反而小于 UPX 版 101M；代价装机后磁盘 282M）。UPX 压制仅限无 graft 的件 | task-ocomp-graft.txt §新发现：UPX×graft 不兼容 |
| 6 | **内核 3.18 effect stat 面？**（v1 ripgrep boot） | TUI boot 冻结在 "downloading ripgrep" 链：effect(v4-alpha) `@effect/platform-node` 的 stat 包装层对**存在路径**返回 NotFound/EEXIST（v1 ripgrep filepath effect 根因）；bun 原生 fs/stat/readdir/spawnSync 在 3.18 全活；npm lstat/Flock 同症状 | bunfs 同长度字节手术（1.18.32-7 起）：readdir 探针扫 PATH + Global.Path.bin 缓存位 + typed-failure 降级（`OPENCODE_SKIP_RG=1` 逃生口），移除 orDie/download/spawn-tar；oscar 真 PTY boot 过 ready + LLM 往返 rc=0 | task-v1rgfix.txt（探针矩阵 + patch 规格） |
| 7 | **内嵌 bun 版本？**（1.4.0 vs 1.4.2） | 无关判据：TLSDESC 崩面对版本不敏感——bun 1.4.2（v1 compressed 旧件记载）与 1.4.0（v1 native / v2）崩签名逐字节相同，版本差假说出局；后经 banner 实证本件内嵌即 1.4.0（34cbb9a40），「1.18.32 = 1.4.2」系该代归因讹误 | 无需修补 | task-v1tui-layer.txt 关键事实链 1；task-v1c-triage.txt |

判定流：判据 1 过（≥10 直载 / 9 需 shim 构建版）→ 判据 2 过（单代共存可跳过）→
判据 3 过（仅会话期需要）→ `regress-tui.sh` 应 GREEN。判据 4 恒为「已排除」；
判据 5 是构建侧出货规则（graft ⇒ 不压制）；判据 6 仅 v1 件（1.18.32-7 前无此修补）；
判据 7 恒为「无关」。

## 历史雷区备忘（一行定性，防走回头路）

- **glibc pty 资产族（B1 gnu 会话期）**：bionic 进程内 dlopen glibc 件两机同败（`libpthread.so.0 not found`），glibc bridge 只救 loader-exec 不救 dlopen → gnu 资产唯一出路 = musl 拼接（判据 3）。〔task-flagship-tui.txt §4〕
- **bun.report 归因不可靠**：bun rust crash handler 用 glibc 系 ucontext 布局读 glibc+bionic 混合进程，pc/fp 错位 → "JSC/YarrJIT" 归因纯巧合；取证须用 sigaction-hijack shim（ckt-shim.c）或 bun.report base64-VLQ /remap。〔task-1-jsc.txt §4〕
- **bionic 9 IE/TPREL trace-only stub**：android-9 `linker.cpp:2968` 的 TLS_TPREL64 case 只有 TRACE 无写入 → IE/TPREL 重编路线=静默数据损坏，已证伪；`tools/transplant/relax_tlsdesc.py` 仅留作 `--check` 断言工具。〔task-2-jitfix.txt §IE/TPREL 路线证伪〕
- **useJIT=0 非 workaround**：OpenTUI→bun:ffi→JIT 硬依赖，关 JIT = 干净报错退出（"bun:ffi requires the JIT"），仅保留崩点因果判据价值。〔draft §useJIT=0 修正〕
- **kernel 3.18 三件套（epoll_pwait2/memfd/pidfd）对 TUI 外壳线全是红鲱鱼**：真正 OS 变量是 bionic 版本，不是内核版本。〔task-1-jsc.txt 结论〕
- **UPX×graft 不兼容（2026-10-02）**：graft 只改载荷 6MB asset 字节，UPX 压制后即崩且与 shim/回填/提取内容全无关——别再试「graft 后压制」，graft 件一律未压出货。〔task-ocomp-graft.txt 二分矩阵〕
- **v1 boot 冻结 ≠ bun 旧内核 syscall 坑**：bun 原生 fs/spawnSync 在 3.18 全活，坏点在 effect(v4-alpha) stat 包装层——别把 effect 层症状归罪 bun。〔task-v1rgfix.txt 探针矩阵〕

---

## 附录 A：机制规则卡归档（librarian-bunso，2026-10-02 终版，原文 draft §机制规则卡）

① bun 内嵌 .so 加载 = **提取到 {TMPDIR}/.bun-{euid}-{wyhash}.node 普通文件再 dlopen**
（非 memfd；BunProcess.cpp L465-480 / jsc_hooks.rs L4931-5015）；TMPDIR 不可写 = 优雅报错。

② **SIGSEGV@0x0 判据 = epoll_pwait2（syscall 441，kernel 5.13+）**：bun 某些 build 的
libc::syscall errno-TLS wrapper 在 441 不可用时崩于事件循环首次等待、fallback 不可达
（issue #32489 / PR #32490）；tag bun-v1.4.0 已含修复（inline-asm + uname 含 -android
禁用 + BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1 逃生 env）；bionic dlopen 缺 NEEDED =
优雅 NULL 不崩。
〔终版补注：此判据对本轮 TUI 崩线为红鲱鱼——task-1 定谳真因是 TLSDESC；epoll_pwait2
另有其案（B2 readiness 线早期主嫌，后被判据 2 端口分代取代）。保留原文供机制史参考。〕

③ pidfd_open 缺失有 waiter-thread fallback（spawn_process.rs L500-574）；唯一风险 =
seccomp SIGSYS（oscar 实测无）。

④ termux bun 补丁集先例：0004 openat2 / 0005 fchmodat2 / 0009 pidfd / 0006 tmpdir；
dextune shim = SIGSYS→ENOSYS 放行。

旗舰侧探针（2026-10-02 实测）：syscall 441 → EINVAL（存在）；pidfd_open → fd（存在）；
uname 含 `-android` → bun 修复版 uname 禁用启发式在旗舰同样触发。

## 附录 B：竞争假设矩阵（终版归档，原文 draft §竞争假设矩阵 + 终审裁决）

| 假设 | 内容 | 终审裁决 |
|------|------|----------|
| H-glibc | 旗舰 TUI 靠 $PREFIX/glibc bridge（libc.so.6+ld-linux）加载 glibc 资产 | **证伪**：旗舰 TUI 活体 maps 三采样零 glibc 映射、零 bridge 参与；bridge 只支持 loader-exec，bionic 进程内 dlopen glibc 件两机同败〔task-flagship-tui.txt §4/§6〕 |
| H-kernel | 旗舰 6.6 有 pidfd、oscar 3.18 无 → TUI init 崩在 syscall 面 | **假相关**：崩点在 bionic linker 重定位（用户态），与内核无关；旗舰"正常"实为 bionic 新（TLSDESC 支持）〔task-1-jsc.txt §5〕 |
| H-bunso | bun 对内嵌 .so 的 dlopen 失败路径未兜住 → 优雅报错变 SIGSEGV | **部分成立后收窄**：抽取+dlopen 机制本身健康（maps/strace 双证）；崩溃发生在 dlopen 成功之后——libopentui 的 TLSDESC 重定位未被 bionic 9 填槽〔task-1-jsc.txt §1-3〕 |
