# D4 进行中与待决清单


> **历史快照，勿按此操作。** 现行文档见 [docs/README.md](../README.md)。

> **快照日期**: 2026-09-30（交接基线）  
> 每项含：现状 / 下一步 / 阻塞点

---

## 1. UPX R-A 路线（v2 compressed 复活）

- **现状（2026-10-01 更新）**: **T3' 判决已出**——v1 bin + stock upx -4 = VIABLE（33.7%），坐实崩溃=v2 内嵌自省结构（非工具/level/版本）；「外包」确认为误记，v1 配方=本机 `make transplant-upx --best`（Makefile:365）；四假说判决表已入 `docs/upx-v2-fix.md` §6；下一探针=strace `/proc/self/exe` 自省铁证
- **下一步**: ①跑 `/proc/self/exe` strace 铁证探针（§6）；②按自省结论选修法（剥自省/launcher 挂载/等上游）→ R-A/R-B1/R-B2 三路复测；③`v2-upx-revival.md` T1 可勾（取证已被 recall-pack+§6 承接）
- **阻塞点**: strace 铁证未跑；修法选型待铁证

## 2. RC6 = B2 定版（musl 家族）

- **现状**: RC5=B1（gnu continuation）收口中；B1/B2 分类学已入 `docs/native-line-evolution.md`；RFC discussions/29 开放（shipping strategy 投票）
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

---

## 20. 评审 P2 挂账清单（compressed-review-fixes 评审团，2026-10-11/13）

> 来源：R1（打包脚本）/R2（Makefile）/R3（稳定性）三路评审的 P2 级发现，push261013 计划 todo 10 落盘。行号为**评审时快照**，执行时以 grep 定位为准。digest 比对与 422 清理**不在**本清单（已入 push261013 todo 3/C1）。

### R1（scripts/package/）
1. `package_pacman_compressed.sh:276-280` GOT_SHA 死代码：gzip/tar 失败时 sha256sum 仍输出空输入哈希（e3b0c442…），`[[ -z "$GOT_SHA" ]]` 永假 → bsdtar 回退分支不可达；非 .gz 包会误报 mismatch（当前 PKGEXT 恒 .gz，影响低）
2. `package_pacman_compressed.sh:253-254` BUILT_PKG glob 无匹配时所有守卫静默跳过（:274/:296/:342 同模式）——应断言非空，否则产物命名偏差=假绿；另 glob `*.pkg.*` 可能多匹配（同名 .tar.xz 残留）致变量多行
3. `package_deb_compressed.sh:127,145` `Version: $VERSION${DEB_REV:-}` 无格式校验，外部漏传负号（`DEB_REV=1`）产出 `2.0.x1`——建议校验 `^-` 前缀
4. `package_deb_compressed.sh:179` v1 postinst 迁移条件比 native 版（`package_deb_native.sh:189`）少 `|| [ -d "${CFG_DIR}1" ]`，漂移，仅影响提示语分支
5. `package_deb_compressed.sh:99/:114` deb 无 OCOMP_SHIMS 等价 knob（epoll/pty 仅按文件存在性发货），与 pacman 不对称——符合 deb 头注释契约，可接受（记录备查）
6. `package_pacman_compressed.sh:185` makepkg.conf 路径硬编码绝对前缀（native 同样写法，一致性 OK；可换 `${PREFIX:-…}`）

### R2（Makefile）
7. batch-v2 PKG=both 时每版 clean-version 执行 4 次（三个 family 尾+循环尾，冗余但幂等无害）——**push261013 C5 模式目标改造后循环尾冗余已消解，family 尾三次仍在**，待下批评估是否收编进 stamp 目标
8. `Makefile:136/139/142` batch-v2 三个子 make 缺 `--no-print-directory`（C5 重构后此段已重写，需复核是否仍缺；仅输出噪音）

### R3（ops 脚本，收编后对应 tools/compressed-*.sh）
9. watchdog 对「僵死」无效（pgrep 只证存在；网络黑洞时 gh api/DoH curl 无超时会挂死而 watchdog 永远显示 RUNNING）——建议 progress.log mtime >60min 标 STALE；按 R4-4 裁决 watchdog 不收编，维持一次性
10. 失败路径缓存清理：冒烟失败后 RT(200-600MB)+COMP(80-140MB)+SRC+SMOKE 全留（99% 磁盘水位下多版连败加速耗尽）——compressed-one.sh 已有成功路径清理，**失败路径 trap 未加**，建议下批补 `trap 'rm -rf "$SMOKE/$VER" "$RT/$VER"' EXIT`
11. ~~逐件跳过判断（deb 已传 pacman 未传时误重建好件）~~——**已修复**：push261013 C4 compressed-batch.sh 双命名逐件判 + compressed-one.sh 内部逐件 size 比对

### 处置建议
- 1/2/3/6 可在下批打包脚本维护波顺手修（各 ≤10 行）；4/5 记录备查不修；7/8 与 C5 落地效果复核后决定；9 维持现状；10 建议下批 compressed-one.sh 补 trap
