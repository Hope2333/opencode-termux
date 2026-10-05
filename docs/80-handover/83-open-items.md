# D4 进行中与待决清单

> **快照日期**: 2026-09-30（交接基线）  
> 每项含：现状 / 下一步 / 阻塞点

---

## 1. UPX R-A 路线（v2 compressed 复活）

- **现状（2026-10-01 更新）**: **T3' 判决已出**——v1 bin + stock upx -4 = VIABLE（33.7%），坐实崩溃=v2 内嵌自省结构（非工具/level/版本）；「外包」确认为误记，v1 配方=本机 `make transplant-upx --best`（Makefile:365）；四假说判决表已入 `docs/90-incidents/92-upx-v2-fix.md` §6；下一探针=strace `/proc/self/exe` 自省铁证
- **下一步**: ①跑 `/proc/self/exe` strace 铁证探针（§6）；②按自省结论选修法（剥自省/launcher 挂载/等上游）→ R-A/R-B1/R-B2 三路复测；③`v2-upx-revival.md` T1 可勾（取证已被 recall-pack+§6 承接）
- **阻塞点**: strace 铁证未跑；修法选型待铁证

## 2. RC6 = B2 定版（musl 家族）

- **现状**: RC5=B1（gnu continuation）收口中；B1/B2 分类学已入 `docs/10-build/15-native-line-evolution.md`；RFC discussions/29 开放（shipping strategy 投票）
- **下一步**: musl 家族命名（`opencode-compressed` 归属？）+ pkgrel 起始号待 RFC 票决 → 定版后跑 v2-upx-revival 批量
- **阻塞点**: RFC 票未齐；RC5 队列未收口

## 3. site-rebuild db+pkg 原子对上传

- **现状**: 89d8d4b 记录 mozzaru 2/2 复现——mirrorlist db 与 pkg 非原子上传导致窗口期 404（用户自动化侧）
- **下一步**: 上传改为同事务（或先 pkg 后 db 反序）+ 站点 CI 侧修复
- **阻塞点**: 用户自动化侧排期（仓外）

## 4. 实验机 RC5 验证

- **现状**: 实验机 10.254.129.10:8022（u0_a115 免密）**离线**（2026-09-30 快照）；双机验证条款挂起
- **下一步**: 设备上线后跑 v2.0.x compressed 双机安装冒烟（v2-upx-revival T5）
- **阻塞点**: 设备离线

## 5. build-hygiene 计划任务 2-6

- **现状**: `1a2c179` 函数库 + `0b3bfd3` LRU 修复已落；`.omo/plans/build-hygiene-backend.md`（2026-09-29 22:57）任务 1-6 中仅部分执行
- **下一步**: 前置=RC5 队列收口 → 续跑任务 2-6
- **阻塞点**: RC5 队列优先

## 6. rc5 若干小修

- **现状**: upload 脚本失败计数未传导退出码（知而不修，待收口）；其他小修散见 rc5-b1-release.md
- **下一步**: RC5 收口波一并处理
- **阻塞点**: 无（等波次）

## 7. compressed-offload 计划（旧）

- **现状**: `.omo/plans/compressed-offload.md` 0/4 未执行（2026-09-28 交付后被 RC3-RC5 进程实质取代）；其「UPX 外包分离」意图已并入 v2-upx-revival 的 R-A 路线
- **下一步**: 对比两计划 → 若 v2-upx-revival 完全覆盖则删旧计划（防双跑）
- **阻塞点**: 需一次对比裁决

## 8. gh auth token 过期

- **现状**: `gh auth status` 报未登录（2026-09-30 快照）——上传/issue 回复/API 全挂
- **下一步**: `gh auth login` 重认证（workflow scope 需补——此前拒推 site.yml 即因缺该 scope）
- **阻塞点**: 需人工过 OAuth 流程

## 9. 待回社区案（详见 D3）

- **现状**: #17（mozzaru 金丝雀 RC5 待回）、#22、#24 挂起
- **下一步**: RC5 发布后按 D3 模板回帖
- **阻塞点**: RC5 发布
