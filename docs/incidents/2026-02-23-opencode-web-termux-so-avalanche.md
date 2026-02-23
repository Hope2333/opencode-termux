# TEMP-opencode-web-termux-so-avalanche

## 目的
给“信息机”快速接入调试机并继续排查：Termux 环境下 `$PREFIX/tmp/.*-0000*.so` 持续堆积导致磁盘雪崩。

---

## 一、事件摘要（可直接汇报）

- 现象：Termux 启动后，`/data/data/com.termux/files/usr/tmp` 中持续出现 `.*-00000000.so` 文件。
- 文件特征：单文件大小约 `4,358,296` 字节，动态段 `SONAME = libopentui.so`。
- 历史峰值：一度累积到 900+ 个，约 3.9GB，接近把 `/` 填满。
- 关联进程：`/data/data/com.termux/files/usr/lib/opencode/runtime/opencode`（Bun runtime）及 `opencode web` 相关进程。
- 关键修正认知：
  - 直接 `opencode` 拉起 TUI 不复现持续增长；
  - 手工 `opencode web` 启动时通常只产生 1 个副本；
  - 更像“外层服务/重启链路导致多次启动后遗留文件”，而不是单个稳定进程每秒无限泄漏。

---

## 二、已执行的止损操作（用户现场）

> 以下为已执行命令（原始记录）

```bash
sv down /data/data/com.termux/files/usr/var/service/opencode-web
rm $PREFIX/tmp/.*-0000*.so
sv disable /data/data/com.termux/files/usr/var/service/opencode-web
opencode web
```

手工启动 `opencode web` 后输出：

- `Web interface: http://127.0.0.1:4096/`
- 提示：`OPENCODE_SERVER_PASSWORD is not set; server is unsecured.`

---

## 三、当前状态快照（止损后）

- runit 服务状态：`opencode-web` 已 `down` 且 `disable`。
- 残留异常文件：`$PREFIX/tmp/.*-00000000.so` 当前约 `1` 个（约 4.36MB）。
- 仍有 runtime 进程存在（含手工 `opencode web` 会话）。

---

## 四、调试结论（阶段性）

### 高置信结论

1. 这些 `.so` 文件确实是 OpenTUI 相关动态库落地副本（`libopentui.so`）。
2. “雪崩”在服务常驻/重启链路中更容易触发。
3. 通过 `down + disable + 清理 + 手工启动`，已有效阻断爆盘链路。

### 待验证假设

1. `opencode-web` 被 supervisor/外层脚本频繁拉起（短生命周期进程各自产生 1 个副本并遗留）。
2. 临时 `.so` 清理逻辑在 Termux/Android/Bun fallback 路径失效或未触发。

---

## 五、给信息机的下一步调试清单

1. **复现矩阵**
   - A: 直接 `opencode`（TUI）
   - B: 手工 `opencode web`
   - C: runit `opencode-web` 服务模式
   - 对比每种模式下 `.so` 增速、进程存活时间、是否残留。

2. **确认是否重启风暴**
   - 观察 `opencode web` PID 是否高频变化；
   - 检查 runit 日志与上层 watchdog/健康检查脚本。

3. **库加载生命周期打点（上游代码）**
   - 记录：`create temp so -> dlopen -> unlink/remove -> drop/dlclose` 每一步成功/失败与 errno。
   - 记录：web/tui 模式下 OpenTUI 初始化次数（全局计数器）。

4. **安全与接入**
   - 当前 web 提示未设置密码，禁止暴露公网。
   - 调试接入前建议设置 `OPENCODE_SERVER_PASSWORD`，或仅通过本机/隧道访问。

---

## 六、相关参考（外部）

- OpenCode Issue #8620（Termux/PRoot、OpenTUI、`/proc/self/fd` 相关回归）
  - https://github.com/anomalyco/opencode/issues/8620

> 注：本文件用于“信息机”接入调试机的快速上下文，不替代正式 RCA。
