# D3 社区与 issue 状态（community-state）

> **快照日期**: 2026-09-30（交接基线，与 `docs/80-handover/83-open-items.md` 同日）
> **证据来源**: `git log --grep='issue #'` + `docs/99-reference/99-open-issues-and-upstream-sync.md` + `docs/90-incidents/91-ops-lessons-rc3.md` + `.omo/notepads/termux-asset-update/learnings.md`
> **⚠️ gh 认证状态**: `gh auth status`（2026-09-30）报未登录 → **本文件全部结论来自 git log 与仓内文档，未取 gh API**。接手者回帖前须先 `gh auth login`（需补 workflow scope，见 `./83-open-items.md` 第 8 项）。
> **用途**: 接手者可按图索骥回复任一 issue，无需重开考古。

---

## 1. 开放案（截至 2026-09-30）

三案挂起，统一阻塞点 = **RC5 发布后按 D3 模板回帖**（`./83-open-items.md:56-59`）。

| # | 案 | 现状 | 下一步 |
|---|----|------|--------|
| **#17** | mozzaru：kernel 4.19 / Android 11 上 v2 native `opencode 2.0.12-3` SIGSYS（close_range，exit 159），包内缺 seccomp shim | 修复已落并双轮实证：`217f88d`（2026-09-28，family-v2-native 接入 `harden-native`）随 RC4（Push260928，PKGREL=4）上架；`docs/99-reference/99-open-issues-and-upstream-sync.md:133` 记「4.19 两轮独立干净安装零 SIGSYS（shim 生效）✓」。**待回的是 RC5 金丝雀复测邀请 + 插件/OMO 模型分配追问**（2026-09-07 已回过一轮，comment id 5563207063） | RC5（Push260930）发布后，用英文回帖：金丝雀复测步骤 + shim 修复说明；顺带请他补 `pacman -v`（RootDir/DBPath）以判其 `/usr` 写入异常（`../90-incidents/91-ops-lessons-rc3.md` §6 遗留） |
| **#22** | serve web（v2 serve 静态 web 资产） | **代码侧双修已完成，仅欠回帖**：`751a498`（2026-09-28 前，dist pre-build + skipBuild-collect patch 把 #22 修复烤进 B 线）+ `93004bf`（2026-09-28，per-version web-ui dist 缓存，rebuild 跳过 vite） | RC5 上架后回帖确认修复已在 B1 包内，附验证命令（`opencode serve` 起服务访问 web 页） |
| **#24** | v2 native 缺 seccomp shim 的另一路 SIGSYS 报告（与 #17 同根因，`../90-incidents/91-ops-lessons-rc3.md` §6 标题「#17/#24 实证」） | 根因与修复同 #17（`217f88d`，RC4 PKGREL=4）；`docs/99-reference/99-open-issues-and-upstream-sync.md:123` 记 RC3 全家族 bun 1.4.0 重建、v1 1.18.32-3 已获用户实证。**仓内无任何 commit 直接引用 #24**（仅文档归组），故状态仅由文档背书 | 回帖说明与 #17 同一修复线、已随 RC4/RC5 出货；若对方环境仍旧，收 `pacman -v` + `opencode --version` 与 dmesg SIGSYS 记录 |

**附带开放（非 issue，但同一波社区反馈）**: mirrorlist db/pkg 非原子上传导致窗口期 sha 不符（mozzaru 2/2 复现，`89d8d4b` 2026-09-30 落档，`./83-open-items.md` 第 3 项）——**阻塞点在用户自动化侧（仓外）**，回帖时只说明「货架已收敛一致（7ec10039 双向验证）+ 原子成对上传在排期」。

---

## 2. 已闭案底（各一行结论）

| # | 结论 | 出处 |
|---|------|------|
| **#16** | JulJuliano（ES）报 plugin loader 名字冲突 + 要求 GPT-5.3+ 的 MODEL_MAP——两者均为**上游**问题，维护者已完整回帖，本仓无动作 | `.omo/notepads/termux-asset-update/learnings.md:278`（2026-09-07 巡检，建议关闭） |
| **#23** | bun 1.4.2 在 B 线 SIGSEGV@0x40 → 钉死 bun@1.4.0（`5f0bbd4`，2026-09-27），RC3 全家族重建，v1 `1.18.32-3` 已获用户实证通过 | `docs/99-reference/99-open-issues-and-upstream-sync.md:123` |
| **#25** | OpenTUI 0.5.12 平台 chunk 文件名漂移破构建（`9gqvxy8c`→`8f4q4e2m`）→ `apply-platform-patch.sh` 改为按内容动态发现（`grep -RIl 'platform: process.platform'`，`ce1c2ca`，2026-09-28），**已关闭** | `docs/99-reference/99-open-issues-and-upstream-sync.md:122`；`../90-incidents/91-ops-lessons-rc3.md` §4 |
| **#27** | B1 gnu PTY 资产在脆弱环境（glibc 残基）下失败 → 换上游 musl 静态 PTY 资产（`7b271c7`，2026-09-29，commit 主题即 "issue #27"）；Android 16 serve 实测正常（musl pty 生效），与 #17 同批双修获独立设备确认 | `docs/99-reference/99-open-issues-and-upstream-sync.md:133` |

---

## 3. RFC discussions/29：B1/B2 shipping strategy 投票

- **是什么**: GitHub Discussion **#29**（`Hope2333/opencode-termux`），B1/B2 双家族 shipping strategy 的公开投票帖，中英双语改写为投票形态（v12.3 记录，2026-09-30）。开票动作见 `4952235`（2026-09-29，PTY_VARIANT toggle 的 RFC RC5 prep）与 `073718f`（2026-09-29，B1/B2 分类学入 `docs/10-build/15-native-line-evolution.md`，RFC 开放）。
- **四个选项（reaction emoji 映射，单选）**:
  | Emoji | 选项 |
  |---|---|
  | 👍 `THUMBS_UP` | ① 单家族 musl（RC4 现行） |
  | 🎉 `HOORAY` | ② 单家族 gnu 延续 |
  | 🚀 `ROCKET` | ③ 双家族并行 |
  | 👀 `EYES` | 其他想法（回帖表达） |
- **投票机制**: 每人一个 reaction = 一票；**按 user 去重**——同一个人投多个选项计「多投」，不进有效票。脚本输出 `有效单选 N 人；多投去重 M 人 [...]`。
- **tally 脚本位置**: **`/data/data/com.termux/files/home/develop/opencode-termux/.omo/evidence/rc3-release/rfc29-tally.sh`**
  - 用 GraphQL 取 `repository(owner:"Hope2333",name:"opencode-termux").discussion(number:29).reactionGroups`（`users(first:100)`，`--jq` 抽 content/totalCount/logins），再 `python3` 做去重与票型汇总。
  - 必须 `gh auth login` 后才能跑；当前（2026-09-30）gh 未认证 → **票数快照此刻取不到**。
- **快照落盘**: `.omo/evidence/rc3-release/task-rc5-tally.txt` 与 `task-rc5-tally-gate.txt`（rc5-b1-release 计划 T1 的 D-D gate 产物）。
- **票的用途（gate 语义）**: `.omo/plans/rc5-b1-release.md` T1 规定——批量重建前先跑 tally；若 👍①（单家族 musl）压倒性胜出 → **暂停并请示用户是否推迟 RC5-B1**。
- **票未齐的下游阻塞**（`./83-open-items.md` 第 2 项）: RC6 = B2 定版的 **musl 家族命名（`opencode-compressed` 归属）+ pkgrel 起始号** 待 RFC 票决。

---

## 4. 语言跟随规则 + bilingual 模板

### 4.1 语言跟随（中文问中文答）

**规则**: 回复语言跟随**提问者**所用语言，不跟随维护者习惯。
- 中文 issue/中文正文 → **中文回复**
- English issue/English 正文 → **English reply**
- 混合线程 → 以**开帖语言**为准，后续跟随对方最近一帖。

**执行记录（可审计）**（`.omo/notepads/termux-asset-update/learnings.md:145,211`）:
- #13（中文）→ 中文回复 ✅ ｜ #8（English）→ English reply ✅ ｜ #6（English）→ English reply ✅ ｜ MiMoCode #1（English body）→ English reply ✅
- 2026-09-07 巡检轮: mozzaru / alguma0pessoa0 → EN，yzjdev → ZH，按 260719 convention。
- **对本文件三开放案的直接含义**: #17、#22、#24 均为英文案 → **一律英文回帖**（含 #17 的 mozzaru）。

### 4.2 bilingual 模板（欢迎帖 / 公告 / reply）

**已落位**（`docs/90-incidents/91-ops-lessons-rc3.md` §7，2026-09-28）:
- Discussions **五语**（`en` / `zh-Hans` / `zh-Hant` / `ja` / `es`）的**公告帖**与**欢迎帖**模板，发布于 **Announcements** 与 **General** 两个板块；**新增语言 = 加一行**。
- README 五语对标结构: `README{,.zh,.es,.zht,.ja}.md` 各 140 行逐章节对齐；横幅单源 `assets/discussions-banner.svg`（SMIL 动画，camo 下可动）。
- ⚠️ **未定位到模板的文件路径**（本仓 grep 无 `welcome`/`template` 命中的 discussion 模板文件，`../90-incidents/91-ops-lessons-rc3.md` 亦未写路径；其中「已落 31 仓」字样无法在本仓核实）→ 接手者发帖前先在 Discussions 板块直接翻既有公告/欢迎帖照抄结构，或向用户索取模板源文件。**这是本文档的已知缺口。**

**reply 结构（从在案回帖实践归纳，可直接套用）**:
```
[EN 版]                                    | [ZH 版]
1. 复述对方问题（1 句，确认理解一致）        | 1. 同左
2. 根因（模块/commit 短 hash + 日期）        | 2. 同左
3. 修复状态（已合入 / 随哪个 RC 上架）        | 3. 同左
4. 请对方复测的具体命令 + 期望输出            | 4. 同左
5. 残留问题的取证请求（如 `pacman -v`）        | 5. 同左
```

**API 边界（发帖前必读）**: Discussions 的分类**创建 / 改名 / 描述 / 置顶均无 API（UI-only）**；**发帖与改帖**经 GraphQL `createDiscussion` / `updateDiscussion`（`../90-incidents/91-ops-lessons-rc3.md` §7）。issue 评论走 `gh api .../issues/<n>/comments`（需先认证）。

---

## 5. 交接提醒：哪些 issue 需要新会话**先读再回**

按「先读优先级」排序（越靠前越不能凭记忆回帖）:

1. **#17（mozzaru）— 最高优先**：线程最长（SIGSYS 修复 + 插件/OMO 模型分配追问 + `pacman -U` 写 `/usr` 待澄清三件事交织）。**先读**：issue 全文与既有评论（含 comment 5563207063）→ `docs/90-incidents/91-ops-lessons-rc3.md` §6 → `docs/99-reference/99-open-issues-and-upstream-sync.md:133`。**再回**：英文，附 RC5 金丝雀复测步骤。
2. **#22**：修复跨两个 commit（`751a498` + `93004bf`），**先读** issue 确认对方原始复现命令，回帖才好给对得上的验证命令。
3. **#24**：**先读** issue 正文判断它是否与 #17 同一报告人/同一环境——若不同环境，需单独取证（`pacman -v`、dmesg），不能直接引用 #17 的 PASS 结论。
4. **#16**：已答完、建议关闭 → 只需**读一遍确认维护者原回帖仍在**，再关，**不要重复作答**。
5. **#23 / #25 / #27**：均已闭并有实证，**无需回**；若被 re-open 才按 §2 出处回。
6. **RFC discussions/29**：计票前**先跑 tally 脚本**（需 gh 认证），不要手点目测；票型触发 gate 时**先请示用户**再动 RC5 队列。

**回帖前置动作清单**: ① `gh auth login`（补 workflow scope）→ ② `git log --grep='issue #' -30` 对齐案号 → ③ 读目标 issue 全文 → ④ 按 §4.1 定语言 → ⑤ 按 §4.2 reply 结构回 → ⑥ 回帖链接 id 记回 `.omo/notepads/termux-asset-update/learnings.md`。
