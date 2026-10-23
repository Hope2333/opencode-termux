# docs/ — 文档地图与维护规则

> 状态：active ｜ 适用版本：全代

## 分区

| 分区 | 职责 | 代表文件 |
|---|---|---|
| `install/` | 用户安装/迁移/切换 | `dual-track-install.md`、`migration-v1-to-v2.md` |
| `build/` | 构建链与工具链 | `transplant.md`（A 线）、`make-maintainer.md`、`native-line-evolution.md` |
| `packaging/` | 包族与布局契约 | `package-families.md`（**单一事实源**）、`compressed-line.md`、`upx-notes.md` |
| `runbooks/` | 可照着跑的流程 | `release-runbook.md`、`install-and-verify.md`、`machine-env.md` |
| `reference/` | 查阅型资料 | `tui-reachability.md`、`upstream-issues.md`、`plugin-management.md` |
| `history/` | 历史快照（带横幅） | `push-tag-archaeology.md`、`ops-lessons-rc3.md` |
| `incidents/` | 事故 RCA | `2026-02-23-…` |
| `measurements/` | 测量数据 | `native-baseline-1.3.13.json` |

## 单一事实源（冲突时以此为准）

| 事实 | 真源 |
|---|---|
| 有哪些包族、能否共存、包体多大 | `packaging/package-families.md` |
| v2 构建怎么做 | `../scripts/build-bionic.sh` + `../scripts/lib/build-pins.sh` |
| v1 构建怎么做 | `build/transplant.md` + `../tools/transplant/transplant.py` |
| 怎么发一批 | `runbooks/release-runbook.md` |
| TUI 能否用 | `reference/tui-reachability.md` |

## 写作约定

- 文首 12 行内写元信息：`> 状态：active|snapshot|historical`、`> 适用版本：<范围>`。
- 相对链接（`../` 跨区），不写 `docs/` 前缀；死链由 `tools/check-doc-links.py` 拦截。
- 历史快照：进 `history/`，文首加「**历史快照，勿按此操作**（当前见 X）」。
- 一份文档只讲一个生命周期：安装指引不夹 tag 考古，发布手册不夹历史决议。

## 工具

```bash
tools/gen-docs-index.sh          # 重新生成 README 索引块
tools/gen-docs-index.sh --check  # 只校验（CI 用）
tools/check-doc-links.py         # 死链检查，0 dead link 才通过
```
