# native 线演进史 — 从 ELF 拼接手术到 bionic 真编译

> 定位：串起 native 线三个阶段的架构叙事。操作手册见 `transplant.md`（A 线）、
> 本仓 `scripts/build-bionic.sh`（B 线），实战教训见 `ops-lessons-rc3.md`。
> 生成：2026-09-28（RC4 收口期）。

## 0. 不变的定义

**native 线**：产物为**零 glibc 的 bionic ELF**，直接在 Termux（Android bionic）
上执行，无 wrapper、无 proot、无 glibc 运行时。与 **wrapper 线**（glibc-bin +
bun-termux-loader 包装，v1→v2 迁移全程未动、最稳定的线）完全独立。

| 代际 | 包名 | 产物线 |
|------|------|--------|
| v1（1.18.x） | `opencode1` | native = A 线（transplant/revive） |
| v2（2.0.x） | `opencode` | native = B 线（build-bionic） |

## 1. 阶段一：v1 时代 — transplant/revive 拼接手术

`tools/transplant/` + `make transplant`（详见 `transplant.md`）：

- **android-bun 底座**（bionic 版 bun 1.4.0）+ 上游 JS bundle **拼接**进 ELF
- **复活手术（revive）**：处理 `.bun` section 格式（opencode >=1.18 换过格式，task-28 适配）
- 产物：`opencode-native-revived`；golden-file 回归（`transplant-check` 4/4）
- **现状**：仍是 v1 1.18.30-33 的现役产线（RC4 中 v1.18.33 即由它产出，goldens PASS）

## 2. 阶段二：v2 时代 — build-bionic B 线真编译

上游 2.0 起结构剧变（monorepo + OpenTUI + chunk 化），拼接手术不够，换成**底座上真编译**：

`scripts/build-bionic.sh` 流水：

1. **bun 1.4.0 bionic 底座** + opencode 源树（`bun install`）
2. **PTY 资产处置**（RC4 起）：上游经 `resolveOpencodePty` 把
   `@opencode-ai/pty-linux-arm64-gnu/bin/opencode-pty` 作为资产嵌入编译产物——
   glibc ABI 在 bionic 必死（#27）。处置 = **B 方案**：换入上游官方
   `pty-linux-arm64-musl` 全静态变体（无 INTERP / 无 NEEDED，内核直接 exec），
   构建后逐版嵌入哈希断言（musl ≥1 / gnu =0）
3. **platform patch**：`apply-platform-patch.sh` 改 `process.platform`
   （OpenTUI chunk 文件名漂移防线，#25 后改为按内容动态发现）
4. **bionic libopentui.so 换入**（Zig 0.15.x 重建的 bionic 版，替换上游 glibc 版）
5. **harden-native**：clang 编 `libopencode-crhandler.so` seccomp shim，零位移写回
   二进制（DT_NEEDED[0] + DT_RUNPATH `$ORIGIN/../lib/opencode`）
6. 双格式打包（deb-native / pacman-native，PKGREL 透传）+ clean-version 尾自洁

### 方案命名对照（#27 PTY；RFC discussions/29 征求社区意见中）

| 方案 | 内容 | 结论 |
|------|------|------|
| **B2 — native-musl**（RC4 起采用） | 接受 #27 PTY 变体：换上游官方 musl 全静态变体 | 实证可跑（`--version` 正常、嵌入断言过） |
| **B1 — native-gnu**（v2.0 时期现状） | 不接受变体，GNU glibc 资产原样嵌入 | **构建侧**在 v2.0 时期十分稳定（可复现）；**运行侧**稳定——含零 glibc 环境（MT 管理器实测稳定运行；PTY 与 agent-pty 程序调试通过），仅 #27 报告的脆弱环境暴露加载失败；glibc 残留违反零-glibc 产线纯度（非普遍硬错误）；patchelf 抢救手术无法兜底脆弱环境（死于 `__libc_start_main` 入口 ABI） |

> 附注：全家族中**最稳定的是 wrapper 线**——v1→v2 迁移全程未动它。
> GNU 嵌入的本质是 **B 线手术残留**：bun --compile 从 node_modules 嵌入上游资产，
> 手术此前只处理 platform / opentui / crhandler 三层，PTY 资产漏网（本机无 glibc
> 与报错自洽；MT 管理器等系统级 PTY 终端正常佐证系统层 pty 设施无恙）。

## 3. 阶段三：制度化（RC3~RC4，2026-09-28）

| 变化 | commit | 内容 |
|------|--------|------|
| shim 缺口修复 | `217f88d` | `family-v2-native` 接入 `harden-native`（原来只有 compressed 链跑），v2 native 全线 PKGREL=4 |
| musl pty 替换 | `7b271c7` | B 方案落地 + 污染检测方法论（嵌入 sha256 字符串检索） |
| clean-version | `afb31db` | batch/family 尾自洁（NOT_CLEAN=1 退出）；make 逐行配方=独立 shell 陷阱（skip 分支 exit 0 拦不住后续行，须单 shell） |
| PKGREL 透传 | `22bcb94` | 三个打包脚本 env 化（wrapper 原硬编码 pkgrel=1） |
| hook 注册表 | `ff9bcd7` | `HOOKS_ENABLE`/`HOOKS_DISABLE` 数组 + 版本区间默认（`stale-serve-kill` 仅 v2 2.0.[0-3]），deb postinst / pac .INSTALL 条件发射 |
| 源码获取双路 | — | codeload 间歇阻断 → `git clone --depth 1` 直连 github.com（fake-IP 白名单内稳定）+ gzip -t 校验 |

## 4. 教训

1. **上游嵌入资产是第四层手术对象**：platform / opentui / crhandler 之外，
   node_modules 里的平台二进制资产同样会被 bun --compile 嵌入，必须逐项清点。
2. **构建后断言**：每版产出后对嵌入哈希做 strings 检索断言（musl/gnu 计数），
   防"修复加入前构建"的时序混入（RC4 首批 14 包即因此重建）。
3. **glibc exec → bionic exec 无捷径**：patchelf 换 NEEDED/解释器/清符号版本
   到头仍死在 C 运行时入口 ABI；正解是换用静态 musl 变体或 bionic 原生编译。
