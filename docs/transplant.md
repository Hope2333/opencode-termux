# transplant — native-android 移植记录

> 本文件记录 native-android 分支的移植工作：把上游 opencode 的依赖/组件
> 移植到 Termux/Bionic 环境。按 todo 顺序追加小节。

## watcher 集成点（todo 15）

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