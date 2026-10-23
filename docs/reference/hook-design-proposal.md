# Hook 设计提案（一页纸）— 安装期 hook 的族归属与特征化

> 状态：**提案**，供「后面看看」裁决；未实现任何 v2 族 hook 变更。
> 依据：task-hist-ocomp 六族 hook 审计（2026-10-02）+ 用户实测（v1-compressed 缺安装 hook）。
> 背景：hook 服务于「v1 保留 + v1/v2 共存」场景；v2 是同代主线，不继承 v1 时代的迁移债务。

## 一、现状矩阵（六族 × hook 实装）

| 族 | 包脚本 | 数据迁移(migrate) | migrate 随包 | stale-serve-kill | stale-runtime-quarantine | system-skills runner |
|---|---|---|---|---|---|---|
| v1 native (opencode1) | package_deb/pacman_native.sh | deb postinst + pacman .INSTALL（已特征化：check 优先，v12.2） | ✓ | registry 默认 glob `2.0.[0-3]` → **1.18.x 默认关** | ✓ | ✗ |
| v1 compressed (opencode1-compressed) | package_deb_compressed.sh | deb postinst（已特征化）；**pacman 侧本次补齐**（.INSTALL + install= 烘焙，此前 PKGBUILD 内 post_install 因缺 install= 从未随包） | deb ✓ / pacman ✓（本次补） | ✗ | ✗ | ✗ |
| v2 native (opencode) | package_deb/pacman_native.sh | echo 分支（不迁移，正确） | ✗ | registry 2.0.[0-3] | ✓ | ✗ |
| v2 compressed (opencode-compressed，新族) | package_deb/pacman_compressed.sh | ✗（正确） | ✗ | ✗ | ✗ | ✗ |
| wrapper (opencode-wrapper，附录) | package_deb.sh / package_pacman.sh | ✗（deb 连 postinst 都不生成） | ✗ | ✗ | ✗ | 已移除（pacman 显式 sed 删除，runner 引用 dropped files） |
| standalone (冻结回滚包) | package_deb/pacman_standalone.sh | ✗ | ✗ | ✗ | ✗ | ✗ |

遗留残留：`PKGBUILD.aarch64/armv7l` 模板仍带 system-skills post_upgrade，但 wrapper 打包器会 sed 删除全部 hook——模板与打包器语义不一致，属死代码。

## 二、归属原则（提案）

1. **数据迁移 hook 只随 v1 族走**。migrate-to-opencode1.sh 解决的是「v1 数据留在 plain XDG 根 + v1 二进制硬编码路径」的 v1 内部问题，v2 永远不该执行迁移分支。v2 native 的 echo 分支仅作共存提示，保留。
2. **v2 族趋向零 hook**（用户裁决方向）：v2 native 现有 echo + quarantine + gated serve-kill 属「升级安全网」，与 v1 无关，可保留；v2 compressed 保持零 hook。若用户确认「v2 零 hook」，v2 native 的 quarantine/serve-kill 是否保留需单独裁决（它们不碰 v1 数据）。
3. **wrapper/standalone 维持零 hook**：附录/冻结定位，安装即用，不做任何数据操作。
4. **跨族特征识别（v12.2 已落地，凡有改写动作的 hook 一律遵守）**：
   - 先 `migrate-to-opencode1.sh check`（dry-run：打印 detected-state + WOULD-* 清单；exit 0 = 已隔离/无 v1 期数据/插件干净 → 跳过）
   - v2 opencode 在装时 plain 根属 live v2：不移动、不 symlink（autopilot shim 的 v2_installed 门已落地）
   - 任何改写前打印将执行动作；失败时明示「数据未动」+ 恢复路径（--take-plain）
   - stale-serve-kill 只 pkill 本包二进制路径的 serve 进程（跨代路径不同，天然隔离）
5. **registry 化**：stale-serve-kill 的 hook_enabled（HOOKS_ENABLE/HOOKS_DISABLE/版本 glob）是可复用机制；若未来 hook 增多，全部走该 registry，禁止散装 if。

## 三、待用户裁决的缺口

1. **v1 native 的 stale-serve-kill 默认关**：默认 glob `2.0.[0-3]` 不匹配 1.18.x——但 v1 runtime 同样有 serve 语义（lib/opencode1/runtime/opencode），升级时同样可能被 stale daemon 卡 TUI。→ 是否把默认 glob 放开到两代？或 v1 族一律默认开？
2. **v1-compressed 的 stale-serve-kill / quarantine**：本次只补了数据迁移 hook（deb 已有项对齐）；这两项 v1 native 有而 compressed 没有，是否需要对齐？
3. **v2 native 是否彻底零 hook**（去掉 quarantine/gated serve-kill）？涉及升级安全网回退，建议保留，交裁决。
4. **PKGBUILD.aarch64/armv7l 的 system-skills 残留**：建议下一次清死代码时随 wrapper 线一并删除（模板 hook 与打包器行为已脱节）。
5. **hook 幂等性验证自动化**：本次特征化改造靠沙盒场景测试（S/A/B 三组）；建议后续加一个 `tools/hook-selfcheck.sh` 固化六族 hook 的沙盒回归。

## 四、本次已落地（v1 族，最小 diff）

- migrate-to-opencode1.sh：`check` 子命令（零改动 dry-run）+ autopilot shim 的 v2_installed 门
- 三处 postinst/.INSTALL 调用点（deb compressed / deb native / pacman native）：检测优先、不再静默、失败明示数据未动
- v1-compressed pacman 侧补齐：`opencode1-compressed.install`（install= 注入 + MIGRATE_HOOK 烘焙）+ migrate-to-opencode1.sh 随包；v2 族输出零变化（MIGRATE_HOOK=0 字面量，零 hook 契约）

## 五、实测注记（2026-10-02，rc6-b2-upx-tui）

- **v1-compressed pacman 装 .INSTALL hook 静默不跑**：termux-pacman libalpm 事务临时目录
  落在 `/usr/tmp`（Android 只读），.INSTALL 执行报 `/usr/tmp/alpm_*/.INSTALL: No such file`
  ——#17 家族 Bug B（上游问题表见 `docs/99-open-issues-and-upstream-sync.md`）。oscar 实测
  `pacman -U` 时 post_install 报错同属此 scriptlet TMPDIR quirk。
- **推论：pacman 线 hook 可靠性 = 待解**。在关键逻辑迁 pacman hook 文件（HookDir 真实路径）
  落地之前，本提案中所有 pacman 侧 .INSTALL hook（含 v1 native/v1 compressed 的 migrate、
  四 §三待裁决项的 pacman 面）**均不可视为可靠执行**；deb postinst 不受影响。
