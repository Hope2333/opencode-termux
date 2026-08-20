# transplant — native-android 移植操作手册

> [!WARNING] 状态横幅：C1 路线（官方 android Bun 底座）**已被证伪**
>
> **C1 路线 = 用官方预编译 android Bun（v1.3.14，89.8MB，Bionic 直跑）作为底座，
> 与 opencode 的 module graph 拼接成单个可 execve 的 ELF**（docs/performance-optimization.md §1.2/§4.1）。
> 经三重证据证伪，此路线**不可行**：
>
> 1. **ELF 入口缺失（compiled-app 模式不存在）**：android bun 1.3.14 的 entry `0x1F00200`
>    落在 `.text` 起始（纯解释器模式），而 RX base 为 `0x0`；对照 glibc host-bun 1.3.11 的
>    entry `0x2A5B300` 恰好等于 RX base（compiled-app 模式）。拼接产物以解释器模式启动，
>    不会进入"加载内嵌 JS"路径。
> 2. **standalone 检测代码缺失**：compiled-app 模式入口字节 `e50300aa e10340f9`
>    在 android bun 中 **0 次出现**；`---- Bun! ----` 标记虽存在于 android bun 的 `.rodata`，
>    但代码中对它的引用为 0（`isStandalone` 检测函数缺失）——拼接产物无法被识别为 standalone。
> 3. **无触发开关**：env/flag/CLI 均无手段让 android bun 进入 standalone 模式；
>    `bun build --compile` 在 Android 上报 `Cannot read directory "/data/": AccessDenied`
>    （Bun 源码硬编码从 `/` 扫描，Android 权限限制无法绕过）。
>
> 无参运行打印 `bun <command>` 用法（纯解释器）；`run`/`serve` 报 `CouldntReadCurrentDirectory`。
> 与本仓库早前结论（`docs/native-android-research.md`，2026-05）一致。
>
> **唯一 workaround = Zig/C++ 级修改**：补 compiled-app 入口 + standalone 检测逻辑 =
> guysoft 自编译 Bun 路线（`docs/performance-optimization.md` §1.1 上游方案）。
>
> **本手册描述的工具链（probe/transplant 管线）仍有效**——可正常产出并自验拼接 ELF，
> 但产物为**纯 Bun 解释器模式**（如 `artifacts/transplant/1.3.13/opencode-native`，
> 152,017,164B），**不可作为 opencode 运行**，仅可用于布局/格式研究。

## 1. 前置条件

| 依赖 | 用途 | 检查 |
|---|---|---|
| `python3`（标准库即可，零第三方依赖） | 运行 probe/transplant 管线 | `python3 --version` |
| `npm` | `npm pack opencode-linux-arm64@<VER>` 获取上游 tgz | `npm --version` |
| 网络 | npm 下载 + GitHub 下载 android Bun（`bun-v1.3.14/bun-linux-aarch64-android.zip`） | — |

输出固定落 `artifacts/transplant/<ver>/`（`opencode-native` + `report.json`），
产物属生成物，按 AGENTS.md 反模式约定**不提交 git、不手工编辑**。

## 2. 三命令速查

```bash
# ① 单步 probe（手动排查用），子命令：extract / detect / convert / patch / assemble / verify / all
python3 tools/transplant/transplant.py detect --mg artifacts/transplant/1.3.13/module-graph.bin

# ② 一键管线（extract→detect→convert(if 36)→patch→assemble→verify）
python3 tools/transplant/transplant.py all --ver 1.3.13 --tgz /tmp/opencode-linux-arm64-1.3.13.tgz

# ③ make 入口（内部自动 npm pack 到 $TMPDIR）
make transplant VER=1.3.13

# 回归（golden-file，fixtures 需先 scripts/fetch-fixtures.sh 预下载）
make transplant-check
```

每步失败打印可操作错误并以非 0 退出；`verify` 子命令重跑 execve 断言版本串一致
（`--no-execve` 跳过 execve 步，供 x86 CI 只产二进制 + report）。

## 3. config schema 解释

### 3.1 `tools/transplant/config/patches.json`（已存在）

```jsonc
{
  "schema_version": 1,
  "ranges": [                       // 版本区间驱动的 patch 表
    {
      "min": "1.0.0",               // 区间下限（含）
      "max": "1.3.99",              // 区间上限（含）
      "bun_layout": "52",           // 该区间的模块图 record 布局（36|52）
      "patches": [
        {
          "name": "guysoft-1-undici-case",   // patch 标识（入 report）
          "search": "__reExport(exports_Undici, undici)",  // 等长替换：search.len == replace.len 强校验
          "replace": "__reExport(exports_Undici, Undici)",
          "region": "string_data"   // 仅 string data 区 [0, modOff)；禁止触碰 module list 区
        }
      ]
    }
  ],
  "locked_versions_schema": {       // 可选：必须钉死到某布局的版本登记表
    "description": "Optional registry of versions that must be pinned to a layout",
    "locked": [
      { "ver": "string", "reason": "string", "detected_layout": "36|52|unknown" }
    ]
  }
}
```

要点：非等长 patch 会被校验器拒绝（offset 漂移即失败）；无 search 命中 = warning 入 report
而非失败；已替换图再跑 `hit_count == 0`（幂等）。

### 3.2 `tools/transplant/config/bun-bind.json`（todo 10 规划，尚未落盘）

> 当前 android Bun 下载地址硬编码在 `tools/transplant/probe_assemble.py` 的 `BUN_URL`
> （`https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-linux-aarch64-android.zip`，
> zip 成员 `bun-linux-aarch64-android/bun`）。todo 10 将其抽为配置，规划 schema：

```jsonc
{
  "target": "1.3.14",               // 绑定的 android Bun 版本（semver）
  "url_pattern": "https://github.com/oven-sh/bun/releases/download/bun-v{ver}/bun-linux-aarch64-android.zip"
}
```

配套 `scripts/ci/probe-latest-bun.sh`：GitHub API `repos/oven-sh/bun/releases/latest` 解析
tag → 比对 assets 是否含 aarch64-android.zip → 与 `target` 不同则输出 CHANGELOG 提示 +
暂存更新（`--apply` 才落盘，`--offline` 跳过网络沿用配置）。

## 4. 失败预案表

| 失败场景 | 判定 | 处置 |
|---|---|---|
| **版本不兼容锁定** | 目标版本落入 probe 未覆盖区间（布局 `unknown`）或 execve 失败，且相邻版本（1.3.12/1.3.10 → 1.2.x）逐一确认版本特异性 | 登记 `config/patches.json` 的 `locked_versions`（ver/reason/detected_layout），管线**明确报错拒绝产出**，绝不静默拼接未验证二进制 |
| **布局转换失败** | 36→52 转换后 execve 失败或 `detect_layout` 复核非 52 | 登记"转换不兼容锁定"，报错含版本 + 布局 + 失败原因，写 `locked_versions` |
| **execve 失败** | `./opencode-native --version` 非 0 或 stderr 首行异常 | 保留原始输入供诊断（不删 bun/图）；对照 C1 证伪现状核对——若为 android Bun 底座本身（解释器模式/standalone 缺失），属已知证伪结论，升级走 guysoft 自编译 Bun 路线 |
| **patch 无命中** | `hit_count == 0` | warning 入 report，非失败（等长 patch 为可选优化） |
| **`--compile` 阻断** | `bun build --compile` 报 `/data/` AccessDenied | 已知硬限制（Bun 源码硬编码），无 workaround；不走此路 |

## 5. FAQ

**Q: 为何不用源码编译 Bun/WebKit/ICU？**
A: 源码编译是 guysoft 路线（`docs/performance-optimization.md` §1.1、`docs/native-android-research.md`），
工作量级 = 修改 Bun 的 Zig/C++ 构建系统 + WebKit/JavaScriptCore 集成，且需逐个打 Bionic 兼容补丁
（zig sigaction 152B→直调、.tbss 64B 对齐、seccomp 拦截缺失 syscall、JSC usePollingTraps 等，
见 performance-optimization.md §4.3）。C1 证伪恰恰证明：**光换官方 android Bun 底座不够**——
android Bun 缺少 compiled-app 入口与 standalone 检测，唯一出路就是 Zig/C++ 级补全
（补 compiled-app 入口 + standalone 检测），即回到 guysoft 自编译 Bun 路线。

**Q: 那 probe/transplant 管线白做了吗？**
A: 不白做。管线是**格式研究基础设施**：extract/detect/convert/patch/assemble 全套能力
对任何 future 底座（guysoft 自编译 Bun、上游修复后的 android Bun）都直接复用——
拼接、等长 patch、布局转换、golden 回归与验证清单与底座无关。当前产物
（`artifacts/transplant/<ver>/opencode-native`）为纯 Bun 解释器模式，**仅作研究用**。

**Q: 哪些版本已验证？**
A: 诚实边界：已实证的是 **1.3.13** 的完整管线与 1.3.14 android Bun 的证伪证据
（见状态横幅与 `docs/performance-optimization.md` §1.2/§2）。probe 未覆盖的版本一律标
**"待验证"**，落入未覆盖区间即按 §4 失败预案锁定报错，不产出未验证二进制。

## 6. 引用（不复制报告全文）

- 目标架构 / 自动化方案 / 补丁集 / 7 项验证清单：`docs/performance-optimization.md` §4
- 优化措施总览与量化预期（启动 <0.3s、TUI RSS <350MB、零 glibc）：`docs/performance-optimization.md` §7
- 零-glibc 研究历史与结论（2026-05，与 C1 证伪一致）：`docs/native-android-research.md`
- 7 项验证脚本：`scripts/transplant-verify.sh`（agent-executable，`--runtime <opencode-native>`）
- golden 回归：`tests/transplant/test_golden.py`（fixtures 由 `scripts/fetch-fixtures.sh` 预下载）

---

## 附：watcher 集成点（todo 15）

### 背景

上游 opencode 的文件监听依赖 `@parcel/watcher`（`packages/opencode/src/file/watcher.ts`）。
在 Termux 上该 binding 是 x86_64 ELF，加载失败 → `watcher()` 返回 undefined →
`if (!w) return {}` → **完全无文件监听**（连 polling 退化都没有）。

方案 A（docs/performance-optimization.md §5.3）：独立原生 watcher 守护模块
（`tools/watcher/watcher.c`，NDK inotify 递归监听）+ 插件侧 shim（`tools/watcher/shim.js`）。

### 挂钩点（外部信号通路，已实证）

opencode 插件 API 存在事件总线通路，shim 的变更回调可接入：

1. **事件发布**：`src/file/watcher.ts:27` 定义 `file.watcher.updated` 总线事件，
   载荷 `{file: string, event: "add"|"change"|"unlink"}`。
2. **插件接收**：`src/plugin/index.ts:init()` 执行 `Bus.subscribeAll(...)`，
   把全部总线事件投递给每个插件的 `Hooks.event` 钩子
   （`@opencode-ai/plugin` 类型：`event?: (input: {event: Event}) => Promise<void>`）。
3. **启用开关**：内部 watcher 的目录订阅受 `OPENCODE_EXPERIMENTAL_FILEWATCHER=1`
   环境变量门控（`src/flag/flag.ts:37`）。

### 退化路径（哨兵 touch）

当内部 watcher 未启用（默认）时，shim 检测到原生事件后 touch 受 watch 目录下的
哨兵文件 `<root>/.opencode-sentinel`，触发 opencode 内部感知（若后续启用
`OPENCODE_EXPERIMENTAL_FILEWATCHER`，哨兵变更会经内部 watcher 发布
`file.watcher.updated`，插件 `event` 钩子即可消费）。哨兵事件被 shim 忽略，
touch 限速 200ms，避免 touch→事件→touch 死循环。

### shim 行为（tools/watcher/shim.js）

- spawn watcher（root 参数化，`WATCHER_BIN`/`--watcher` 可覆盖二进制路径）
- 逐行解析 JSON Lines 事件流，映射为变更回调：
  `create→add`、`modify→change`、`delete→unlink`、`rename→change`
- 回调 = 日志输出（`[hook]` 唯一标记，含 ISO 时间戳 + 事件类型 + 路径）+ 哨兵 touch
- 失败自动重启：watcher 崩溃 500ms backoff 拉活，重启次数记入日志
- 不吞 watcher stderr（`[watcher-stderr]` 前缀透传）
- 忽略自身日志文件事件（防反馈循环）
- `--debounce-ms`/`--max-depth` 透传给 watcher；`--help` 对齐 watcher CLI

### 验证

- `node --check tools/watcher/shim.js` 通过
- 冒烟：touch 文件 → 日志出现 `[hook] event=add watcher_type=create path=<file>`（含时间戳+路径）
- 失败：`kill -9` watcher → 500ms 内重启，事件流 ≤2s 恢复
- 证据：`.omo/evidence/task-15-native-android-transplant.log`
