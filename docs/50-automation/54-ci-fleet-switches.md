# CI Fleet 开关清单：位置、启用前置与风险

> **状态登记文档，不含任何开关翻转。** 三大 workflow（`build-fleet.yml` /
> `nightly-fleet.yml` / `asset-push.yml`）与 glibc 线（`glibc-cross.yml`）目前全部
> **PREPARED / 未启用**（cron 注释、dry-run、WIP）。任何开关翻转（去注释 schedule、
> `ENABLE_NIGHTLY=true`、`confirm=true`）都是**发布动作，须用户显式批准**。
> 总体策略与 runner 论证见 `.github/README-build.md`（§10 决策、§11 启用顺序）；
> 本文只做开关级登记。行号以 `rc6-a2/docs-ci` @ 6b0c150 为准。

## 1. 开关一览（位置逐项核实过）

| Workflow | 开关 | 位置 | 当前值 | 启用动作 |
|---|---|---|---|---|
| `nightly-fleet.yml` | 定时触发 | `on.schedule`（:47-48，注释态） | 注释 | 去注释 `schedule: - cron: "17 3 * * *"`（UTC，避开整点高峰） |
| `nightly-fleet.yml` | job 硬闸 | `env.ENABLE_NIGHTLY`（:79） | `"false"` | 改 `"true"`（**两步顺序无关但缺一不可**，见 §3 半启用空跑） |
| `nightly-fleet.yml` | `force` 输入 | `inputs.force`（:64） | **已声明、未接线**（全文件无 `inputs.force` 引用，job `if` 只看 event_name 与 ENABLE_NIGHTLY） | 启用前处置：接线或删除，不可留假闸 |
| `asset-push.yml` | 真推闸 | `inputs.confirm`（:67-71） | `false`（dry-run：只校验+打印计划） | 显式传 `confirm: true`；且走 `environment: release`（:112） |
| `asset-push.yml` | 覆盖闸 | `inputs.overwrite`（:72-76） | `false`（默认无 `--clobber`，同名资产=硬失败） | 保持默认；确需覆盖须显式且核对 tag 归属 |
| `asset-push.yml` | 新鲜 tag 闸 | `inputs.require_fresh_tag`（:77-81） | `true`（tag 已存在即失败，防 `--clobber` 覆盖他人资产） | 保持默认 |
| `glibc-cross.yml` | 负向验收 | `inputs.run_negative`（:59-63） | **`true`（默认开）** | 保持默认；负向验收是唯一能证明组合 D gate 真会拦的手段 |
| `glibc-cross.yml` | baseline 校验 | `inputs.baseline_sha256`（:64-67） | 空 = 只下载不校验 | 启用前必须填 1.4.0 实测 sha256（1.3.14 的 `a9a0d18d…` 不能沿用） |

另有手动闸（非开关、默认关）：`nightly` 的 `run_device_gate`（真机门禁
oscar-gate.sh，需真机 + 交互 PTY）；`asset-push` 的 `immutable_tags` / `sbom_release_asset`。

## 2. 启用前置条件（逐条有实测依据）

顺序照 `.github/README-build.md` §11，此处列硬前置：

1. **自托管真机 ARM runner**（唯一可行路径）：NDK 交叉实测不可行——构建脚本
   shebang 硬编码 Termux bash、须**执行** aarch64-android bun baseline（x86 无法
   exec aarch64 ELF）、`build-libopentui.sh` 依赖 `BIONIC_SYSROOT=$PREFIX` +
   SELinux hardlink EPERM shim（`w7b-shim.so`）。注册 labels
   `self-hosted, linux, ARM64, android, termux`；`upx`/`readelf`/`python3`/`make`/
   `ar`/`pkg`/`tar`/`xz` 齐备；磁盘余量按**整矩阵**留（build-v1 闸 1200 MB、
   press-v5 闸 800 MB、单条目 180 MB 级 ELF + UPX 工作副本）；供电与散热
   （UPX `--best` 是持续负载）。
2. **B1 版本钉死参数化**：`tools/a2/press-v5.sh` 硬编码 `VER=1.18.32`；
   `pty-embed-store-patch.sh` 的 `V1_SRC` 与 `VENDOR_SHA` 同样钉死。多版本 v1
   矩阵前必须参数化，否则 1.18.30/31/33/34 全构建成 1.18.32。
3. **B3**：`build-fleet.yml` 尚无 `workflow_call` 触发器，nightly 走 `gh workflow
   run` 拿不到 run id / aggregate 结论——半自动状态，启用 nightly 前知情。
4. **B4**：v2 源码获取无自动 fetch 步骤（`build-bionic.sh` 期望 `V2_SRC` monorepo
   checkout 已在 runner 上）。
5. **glibc 线五项未落地**（`tools/a2/build-v1.sh`，在 CI 之外）：T1
   `A2_TARGET_FILTER` 参数化（:129 硬编码 arm64）、T1b `--compile-executable-path`
   支持、T3b glibc 线撤 platform patch（:118 无条件打 patch）、T3 `strings` gate、
   P3 baseline sha256 重取。`glibc-cross.yml` 的 preflight 因此**必败（设计使然）**，
   修完五项前跑它是浪费配额。

## 3. 启用后的风险（每条都有病历或配额数字背书）

- **配额**：免费档 artifact 0.5 GB/仓/月、cache 10 GB/仓。7 条目 × 数十 MiB 包
  artifact × 14 天留存可逼近配额；超配额后 artifact 上传**直接失败**（非静默降级）。
  nightly 已强制 retention 7 天 + 跳过 bun baseline 缓存。
- **静默停摆**：GitHub 对 60 天无活动的定时 workflow 自动停用（90 天无活动仓库级
  停）。启用后忘动 = 静默死，需外部巡检（本地 cron 查 `gh workflow list` state）。
- **单执行器串行**：一台真机一次一个 job，7 条目 ≈ 7 × 单条耗时（v1 单条含
  UPX `--best`，分钟到十分钟级）。`max-parallel: 1` 语义由此保证，但**人的手工
  构建不受保护**——多版本共写 runtime 路径有串扰病历（STAGED_PREFIX 病历在案）。
- **超时**：GitHub 硬上限 6 h/job；nightly 设 5 h 留上传收尾。
- **cron 不补跑**：错过的触发永久丢失；要「每日必达」须外部调 `gh workflow run`。
- **半启用空跑**：只去注释 cron 不改 `ENABLE_NIGHTLY` = 每天产出一个全跳过的空
  run 并在 Actions 页堆积。双重闸就是防这个。
- **缓存投毒**：`actions/cache` 只认 key 不验完整性；坏 run 写入的缓存会被好
  run 恢复。恢复手段是 bump key 后缀，不是调试 restore。
- **推送侧**：推送不可中断（`asset-push` concurrency `cancel-in-progress: false`），
  半推的 release 比不推更难收拾；6 道独立闸（package artifact `if: success()`、
  status `if: always()`、aggregate 部分成功即 false、回读 aggregate artifact、
  正则+sha256 对权威清单复核、confirm + environment）——但**没有 reviewer 时
  `confirm: true` 就是唯一人工闸**（README-build §10.4）。
- **glibc 线特有**：查 2（`strings` 查烘焙 platform）是唯一能拦组合 D
  （`--target=<glibc token>` 单给 → ELF 全绿但 platform 烘成 android）的一查；
  撤 `apply-platform-patch.sh` 的 `if (true)` patch 必须排在三查之前，否则得到
  **虚假 PASS**（真实教训：组合 D 表面全绿掩盖配方回归）；bun install 门控必须
  `--cpu=x64 --os=linux` + 干净目录（bionic 宿主裸 install 静默跳过 x64 平台包）。

## 4. 边界

本文与 `.omo/evidence/a2-v1-effect-rebuild/task-32-ci-prep.txt`（验证记录、4 个
真 bug 修复史）互补：那边是「为什么这样设计」，这边是「开关在哪、开了会怎样」。
决策项见 [55-fleet-decision-register.md](55-fleet-decision-register.md)。
