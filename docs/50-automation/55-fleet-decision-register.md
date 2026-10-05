# 决策编号寄存器：两套 D 编号对照 + CI D1–D6 现状

> 仓库里存在**两套互不相干的 D 编号**，历史上被混用过。本文登记对照关系，
> 并把只存在于未跟踪证据文件（`.omo/evidence/…/task-32-ci-prep.txt` §7）里的
> CI 决策项落成随 git 分发的正式清单。**本文只登记现状，不替用户做裁决。**

## 1. 两套 D 编号（勿混）

| 体系 | 定义处 | 内容 | 状态 |
|---|---|---|---|
| **D1–D4（交接文档编号）** | `.omo/plans/handover-docs.md` todos；`docs/README.md` 登记为「交接快照（D1–D4 + 回忆包）」 | D1 发布运行手册 / D2 机器与环境手册 / D3 社区与 issue 状态 / D4 进行中与待决清单 → 实体落 `docs/80-handover/80~83`（`84-recall-pack.md` 为回忆拼图包） | 计划 4 个 todo 全部 `[x]`，终验 F1–F5 全部 `[x]`。**无剩余项**（仅一条开放项：交接对象身份影响 D2 深浅，不阻塞） |
| **D1–D6（CI 自动构建决策编号）** | `.omo/evidence/a2-v1-effect-rebuild/task-32-ci-prep.txt` §7「待用户/team-lead 决策」 | CI fleet 启用前 6 项待裁决事项（见 §2） | **全部未裁决**；`docs/README.md` 的 D1–D4 与这套无关 |

两套编号无映射关系。此后讨论「D3」必须先声明指哪套；建议口头交流用全称。

## 2. CI 决策 D1–D6（全部待用户裁决）

| # | 事项 | 草稿默认 | 备选与风险 |
|---|---|---|---|
| D1 | 自托管 runner 用专用设备还是开发机本机 | **建议专用机**：共用 `$PREFIX` + 共享 `artifacts/` + UPX `--best` 长负载；开发机混用 = 不可信 PR 代码 + 活 `$PREFIX` 同机 | 开发机本机可省一台设备，但人机构建无并发保护（多版本串扰病历在案） |
| D2 | nightly 频率 | `'17 3 * * *'`（UTC，≈北京时间 11:17）每日 | 可改周频 + 按需 dispatch；注意 GitHub 60 天无活动自动停摆，需外部巡检 |
| D3 | artifact 留存 | 手工 14 天 / nightly 7 天 | 免费档 0.5 GB/仓/月，可压到 7 天靠 asset-push 保持久性 |
| D4 | `environment: release` 的 required reviewers | workflow 只能声明 environment，reviewer 名单是**仓库侧配置** | 无 reviewer 时 `confirm: true` 就是唯一人工闸 |
| D5 | 跨仓推送 token | `secrets.GITHUB_TOKEN`（同仓 contents:write） | 推别仓需 fine-grained `secrets.RELEASE_PUSH_TOKEN`，**不用 PAT** |
| D6 | 矩阵切分 | 按**线**切（v1/v2 双轴），因两线 toolchain/门禁/超时零共享 | 待确认这是预期切法 |

附（README-build §10.7，编号体系外）：glibc 阶段 2（`linux-arm64`）是否值得做
—— 需 `ubuntu-2404-arm` 配额，且应在阶段 1 落地后再议。

## 3. 裁决后的回填义务

每项裁决后：(a) 回填 `.omo/evidence/a2-v1-effect-rebuild/task-32-ci-prep.txt` §7
标注结论与日期；(b) 更新本文表格状态列；(c) 涉及仓库侧配置的（D4 reviewer、
D5 secret）在仓库 Settings 落地后在本文记一行。裁决≠启用：开关翻转仍须按
[54-ci-fleet-switches.md](54-ci-fleet-switches.md) §2 前置逐条核过。
