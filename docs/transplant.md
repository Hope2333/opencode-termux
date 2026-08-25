# transplant — native-android 移植操作手册

> [!IMPORTANT] 状态横幅：C1 路线**已复活且全链产品化**（revive 手术实证 + TUI 可用 + alpha 发布）
>
> **C1 路线 = 用官方预编译 android Bun（Bionic 直跑）作为底座，
> 与 opencode 的 module graph 拼接/嫁接成单个可 execve 的 ELF**（docs/performance-optimization.md §1.2/§4.1）。
>
> **当前结论：可行，已产品化。** 管线一条龙
> （extract→detect→convert(if 36)→patch→assemble→**revive**→verify），手术实现
> `tools/transplant/revive_patch.py`（commit `57ddee1`）。双格式支持：旧 trailer 格式
> （1.3.13 实证）与新版 `.bun` section 格式（opencode ≥1.18，1.18.21 实证，
> reloc_count=50）；底座绑定 `tools/transplant/config/bun-bind.json` target=1.4.0
> （commit b270d11 自 1.3.14 升级；**新版格式图必须用 ≥1.4 底座**）。
> **TUI 完整可用**：swap_tui.py 等长注入 NDK 构建的 bionic libopentui.so 后完整渲染
> （W10a 深度冒烟 5/5）。发布双渠道：stable=Push260822 双轨包；alpha=native-alpha-260825
> prerelease（native 线长期定档 alpha pre-release，维护主线 pure/glibc）。
> CI：`.github/workflows/build-native-android.yml`（workflow_dispatch，evidence-only
> --no-execve），最新 run 32831119197 success。
> 早前的"三重证伪"结论**已被推翻**——真因是 assemble 从未 patch `.bun` 节的
> `BUN_COMPILED.size`，而 standalone 检测链在 android bun 中**完整存在**
> （证伪历史留档见 §0.1，手术细节见 §0.2，遗留问题见 §0.3）。

## 0.1 证伪历史（已被推翻，仅留档）

以下为早前得出的"三重证伪"证据，当时据此判定 C1 不可行。**该结论已被复活手术推翻**，
保留于此作为"为什么之前认为不可行"的记录：

1. **ELF 入口缺失（compiled-app 模式不存在）**：android bun 1.3.14 的 entry `0x1F00200`
   落在 `.text` 起始（纯解释器模式），而 RX base 为 `0x0`；对照 glibc host-bun 1.3.11 的
   entry `0x2A5B300` 恰好等于 RX base（compiled-app 模式）。拼接产物以解释器模式启动，
   不会进入"加载内嵌 JS"路径。
2. **standalone 检测代码缺失**：compiled-app 模式入口字节 `e50300aa e10340f9`
   在 android bun 中 **0 次出现**；`---- Bun! ----` 标记虽存在于 android bun 的 `.rodata`，
   但代码中对它的引用为 0（`isStandalone` 检测函数缺失）——拼接产物无法被识别为 standalone。
3. **无触发开关**：env/flag/CLI 均无手段让 android bun 进入 standalone 模式；
   `bun build --compile` 在 Android 上报 `Cannot read directory "/data/": AccessDenied`
   （Bun 源码硬编码从 `/` 扫描，Android 权限限制无法绕过）。

当时的表象：无参运行打印 `bun <command>` 用法（纯解释器）；`run`/`serve` 报
`CouldntReadCurrentDirectory`。

**推翻要点**：上述现象的真因不在 android Bun 底座——standalone 检测链完整存在，
只是拼接产物中 `BUN_COMPILED.size` 字段从未被 assemble 写入正确值，检测链读到 0
即按解释器模式回退。"检测代码缺失"系误判。

## 0.2 复活手术（revive）

两处关键修正（`tools/transplant/revive_patch.py`，由 `transplant.py revive` 子命令 /
`all` 流水线第 6 步调用，`--no-revive` 可跳过）：

1. **patch 点 = `.bun` 节起始 `0x5568000`，而非 +8**：Bun 的 getter 返回节起始后
   直接解引用读取 size，patch 偏移必须落在节起始。
2. **PIE + ASLR 安全写法**：android bun 是 PIE，检测链把该值当**绝对指针**解引用——
   直接写 vaddr 会在运行期 SIGSEGV。须向 `.rela.dyn` 追加一条
   `R_AARCH64_RELATIVE` 重定位（`r_offset=0x5568000`、type=`1027`、
   `addend=payload vaddr`），由动态链接器加载时完成重定位，ASLR 安全。

**--size-mode 语义（按底座版本自动选择）**：`revive_patch.py --size-mode reloc|plain-offset`
——≤1.3.x 底座走 reloc 重定位（上述第 2 点）；≥1.4.x 底座走 plain-offset 直写偏移
（新版 `.bun` section 格式，见 §0.4）。管线按绑定的底座版本自动选择语义。

术后验证（双格式均 exit=0）：trailer 路径 `1.3.13`；section 路径 `1.18.21`
（证据 `.omo/evidence/task-28-section-format.log`）。

## 0.3 遗留问题

| 编号 | 问题 | 说明 |
|---|---|---|
| #4 | `serve` 报 `Configuration is invalid` | 配置 schema 版本差异所致，见下方「serve 故障排查注记」 |
| #1 | 启动 ~1s 量级（`--version` 首试 1965ms） | 归因 Phase B bootstrap ~220ms + Phase C JS 求值 ~820ms；<300ms 目标需上游 Bun 改造，当前不可达（W3 报告），按 ~1s 现实验收 |
| #7 | 冷启动 ~2s 量级（首测 2423ms） | module graph 全量解析慢；随上游优化跟进 |

现状补充：以上为诚实性能边界，非阻塞项；体积 ~180MB；TUI 已可用（见状态横幅）。

### serve 故障排查注记（"Configuration is invalid"）

常见根因是**配置 schema 版本差异**：1.3.13 不接受 `"lsp": true`（布尔），只认
`false` 或对象表；1.18.x 才接受布尔 `true`。隔离 `XDG_CONFIG_HOME` /
`XDG_DATA_HOME` 可复现验证。另注意：首次启动全新 data 目录需预留 sqlite
migration 时间（>6s），勿误判为挂死。

## 0.4 新版 `.bun` section 格式（opencode >=1.18，task-28）

opencode 1.18 起二进制布局变化：文件尾不再有 standalone trailer
（旧定位报 `trailer not found at offset ...`），module graph 改为存放在
`.bun` PROGBITS section 内：

- 节首 8B = u64 LE `BUN_COMPILED.size`；
- 节尾 = `[Offsets32][marker16]`（Offsets 结构跨版本不变，stride 52B），
  其后紧跟 shdr table。

`transplant.py` 处理方式：

1. **extract**：trailer 定位失败时回退 `extract_section_bun()`——解析 ELF64
   节表按名找 `.bun` 节，返回去首 8B 的 payload（即 revive_patch.py
   `--graph` 约定格式，revive 自加 u64_le(len) 前缀）；report.json 记
   `"format": "section"`（旧路径为 `"trailer"`）。
2. **detect**：`detect_section()` 直接从 payload 尾读 Offsets32+marker16，
   mod_len%36/52 判 layout；bun_version 不可知记 None。
3. **convert/patch**：复用原逻辑（payload 尾结构与旧 module-graph.bin 一致）。
4. **assemble 跳过**：不再拼接 host bun，直接进入 revive 嫁接——底座用
   `artifacts/transplant/android-bun/bun`（缺失时按 config/bun-bind.json
   url_pattern 幂等下载）。

实测 1.18.21：`.bun` off=0x5940000 size=0x562A621，全管线 exit=0，
产物 `--version`=1.18.21（reloc_count=50）。旧版（≤1.3.x）trailer 路径
不受影响，golden 回归 4/4 PASS。证据：`.omo/evidence/task-28-section-format.log`。

## 1. 前置条件

| 依赖 | 用途 | 检查 |
|---|---|---|
| `python3`（标准库即可，零第三方依赖） | 运行 probe/transplant 管线 | `python3 --version` |
| `npm` | `npm pack opencode-linux-arm64@<VER>` 获取上游 tgz | `npm --version` |
| 网络 | npm 下载 + GitHub 下载 android Bun（`bun-v1.3.14/bun-linux-aarch64-android.zip`） | — |

输出固定落 `artifacts/transplant/<ver>/`（`opencode-native` + `opencode-native-revived` + `report.json`），
产物属生成物，按 AGENTS.md 反模式约定**不提交 git、不手工编辑**。

## 2. 三命令速查

```bash
# ① 单步 probe（手动排查用），子命令：extract / detect / convert / patch / assemble / verify / all
python3 tools/transplant/transplant.py detect --mg artifacts/transplant/1.3.13/module-graph.bin

# ② 一键管线（extract→detect→convert(if 36)→patch→assemble→revive→verify）
python3 tools/transplant/transplant.py all --ver 1.3.13 --tgz /tmp/opencode-linux-arm64-1.3.13.tgz

# ③ make 入口（内部自动 npm pack 到 $TMPDIR；现产 opencode-native-revived）
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

### 3.2 `tools/transplant/config/bun-bind.json`（已落盘，target=1.4.0）

android Bun 底座绑定配置（commit b270d11 将 target 自 1.3.14 升级至 1.4.0）。
新版 `.bun` section 格式的 module graph **必须用 ≥1.4 底座**；旧 trailer 格式
（≤1.3.x）沿用 reloc 语义底座即可。底座缺失时按 `url_pattern` 幂等下载：

```jsonc
{
  "target": "1.4.0",                // 绑定的 android Bun 版本（semver）
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
| **execve 失败** | `./opencode-native --version` 非 0 或 stderr 首行异常 | 保留原始输入供诊断（不删 bun/图）；先确认是否执行了 revive 步（未 revive 的 `opencode-native` 为解释器模式，属预期行为）；revive 后仍失败再对照 §0.2 排查 patch 点与重定位表 |
| **patch 无命中** | `hit_count == 0` | warning 入 report，非失败（等长 patch 为可选优化） |
| **`--compile` 阻断** | `bun build --compile` 报 `/data/` AccessDenied | 已知硬限制（Bun 源码硬编码），无 workaround；不走此路 |

## 5. FAQ

**Q: 为何不用源码编译 Bun/WebKit/ICU？**
A: 源码编译是 guysoft 路线（`docs/performance-optimization.md` §1.1、`docs/native-android-research.md`），
工作量级 = 修改 Bun 的 Zig/C++ 构建系统 + WebKit/JavaScriptCore 集成，且需逐个打 Bionic 兼容补丁
（zig sigaction 152B→直调、.tbss 64B 对齐、seccomp 拦截缺失 syscall、JSC usePollingTraps 等，
见 performance-optimization.md §4.3）。C1 曾被判证伪，但复活手术（§0.2）证明：
**无需 Zig/C++ 级修改**——ELF 层 patch `BUN_COMPILED.size` + 向 `.rela.dyn` 追加
`R_AARCH64_RELATIVE` 重定位，即可让官方 android Bun 底座承载 grafted module graph。
源码编译路线仅当需要深度改造底座时才考虑。

**Q: 那 probe/transplant 管线白做了吗？**
A: 不白做。管线是**格式研究基础设施**：extract/detect/convert/patch/assemble 全套能力
对任何 future 底座（guysoft 自编译 Bun、上游修复后的 android Bun）都直接复用——
拼接、等长 patch、布局转换、golden 回归与验证清单与底座无关。未 revive 的产物
（`artifacts/transplant/<ver>/opencode-native`）为纯 Bun 解释器模式，作研究/对照用；
经 revive 的 `opencode-native-revived` 可直接作为 opencode 运行（§0.2）。

**Q: 哪些版本已验证？**
A: 诚实边界：**trailer 路径已实证 1.3.13 完整管线**（含 revive 复活，`--version` exit=0）；
**section 新格式已实证 1.18.21 全管线**（reloc_count=50，exit=0，golden 回归 4/4 PASS，
见 §0.4）。probe 未覆盖的版本一律标
**"待验证"**，落入未覆盖区间即按 §4 失败预案锁定报错，不产出未验证二进制。

## 6. 引用（不复制报告全文）

- 目标架构 / 自动化方案 / 补丁集 / 7 项验证清单：`docs/performance-optimization.md` §4
- 优化措施总览与量化预期（启动 <0.3s、TUI RSS <350MB、零 glibc）：`docs/performance-optimization.md` §7
- 零-glibc 研究历史（2026-05，早于 C1 复活，其"不可行"结论已被 §0.2 推翻）：`docs/native-android-research.md`
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
