# v1(opencode1) 单一 ELF 化 —— 设计与可行性

> 状态：调研 + 原型（**未出包、未装机、未发布**）
> 分支：`rc6-a2/single-elf`
> 目标：把 `opencode1-compressed` 包从「bash wrapper + payload」压成包内单一可执行，去掉 bash 依赖，同时**不丢失** wrapper 承担的 v1/v2 双代隔离。

---

## 一、结论摘要

| 项 | 结论 |
|---|---|
| `opencode1` 命名来源 | **不在 v1 源码里**。`packages/core/src/global.ts:10` 硬编码 `const app = "opencode"`；全仓 `grep -rn opencode1 --include=*.ts` 在 `packages/*/src` 下**零命中**。命名 100% 来自 wrapper 的四个 `XDG_*_HOME` export。 |
| 单一 ELF 可行性 | **可行（方案 A）**，但**不能只做打包层**——必须在源码侧单点固化命名，否则裸 ELF 落进无命名空间的 `~/.local/share/opencode`，与 v2 直接撞库。 |
| 关键障碍 | ① 命名需编译期固化（唯一注入点 `global.ts:10-15`）② `~/.opencode` 是**跨代共享**的 project scope，XDG re-root 覆盖不到（既有缺口，非本次引入）③ wrapper 的 `service.json` 端口 bootstrap 与 `BUN_PTY_LIB`/`LD_PRELOAD` 两个可选 shim 对 v1 **已是死代码** |
| 原型验证 | 裸静态 ELF + 仅四个 XDG env（**零** LD_LIBRARY_PATH / 零 shim）→ `serve` 起 HTTP 200，布局与现役嵌套完全一致 |
| **env 免疫边界** | ❌ **不成立**。固化命名只固定**后缀**，不固定**根**；`xdg-basedir@5.1.0` 无条件读 env，诱饵 `XDG_*` 照样 re-root。详见 **§9**。但这是 **parity 而非回归** —— 现役 wrapper 用同样的 `${XDG_*:-$HOME/…}` 形式，实测落点逐字节相同。 |
| **tmp 根会变** | ⚠️ 固化 `app` 顺带把 `tmp` 也 namespaces 化：`$TMPDIR/opencode` → `$TMPDIR/opencode1/opencode`。与现役**不等价**，详见 **§5.1**。 |

---

## 二、命名机制溯源（问题 1）

### 2.1 数据根的唯一定义点

`packages/core/src/global.ts`：

```ts
const app = "opencode"                                   // L10  ← 唯一命名常量
const data   = path.join(xdgData!,   app)                // L11
const cache  = path.join(xdgCache!,  app)                // L12
const config = path.join(xdgConfig!, app)                // L13
const state  = path.join(xdgState!,  app)                // L14
const tmp    = path.join(os.tmpdir(), app)               // L15
```

`xdg-basedir@5.1.0/index.js` 的实现是**纯 env 读取**：

```js
export const xdgData   = env.XDG_DATA_HOME   || path.join(home, '.local', 'share')
export const xdgConfig = env.XDG_CONFIG_HOME || path.join(home, '.config')
export const xdgState  = env.XDG_STATE_HOME  || path.join(home, '.local', 'state')
export const xdgCache  = env.XDG_CACHE_HOME  || path.join(home, '.cache')
```

### 2.2 三个关键的结构性事实

1. **`app` 是 `const` 字面量**，不是 env、不是构建期 define。`Flag` 里枚举了 `OPENCODE_CONFIG_DIR`（`global.ts:64` 仅在 `make()` 里读一次，作用是覆盖 `config` 单项），但**没有任何 `OPENCODE_*` env 能改 `app`**。→ wrapper 注释「被枚举但不被消费」在此得到源码级证实。
2. **全仓单点消费**：`grep -rn 'from "xdg-basedir"' packages/*/src/` 只命中 `global.ts:3`。data/cache/config/state/tmp 五个根**全部**从这一个模块派生。→ 改一处即改全部，编译期固化是干净的。
3. **`os.tmpdir()` 优先 `TMPDIR`**：wrapper 注释提到「私有 TMPDIR」，但 launcher 实际**没有** export TMPDIR（`scripts/opencode1-launcher.sh` 全文无 `TMPDIR`）。runtime 落 `$TMPDIR/opencode`（实测确认），与 v2 共用同一 tmp 根 —— 这是**既有共享面**，不是 wrapper 造成的。

### 2.3 wrapper 的四个 export 做了什么

`XDG_DATA_HOME=$HOME/.local/share/opencode1` + runtime 追加 `app`("opencode") ⇒ `$HOME/.local/share/opencode1/opencode/`。即**嵌套布局**（`opencode1/opencode/`），正是 `migrate-to-opencode1.sh isolate` 维护的形状。

实测（隔离假 HOME）：

| 条件 | 落地路径 |
|---|---|
| 裸 ELF，零 env | `$FAKEHOME/.local/share/opencode` ← **无命名空间，与 v2 撞** |
| 裸 ELF + 四个 XDG | `$FAKEHOME/.local/share/opencode1/opencode` ← **与现役一致** |

---

## 三、单 ELF 形态设计（问题 2）

### 3.1 目标布局

```
bin/opencode1                 ← ELF 本体（唯一可执行，替代 wrapper + payload 二元结构）
lib/opencode1/migrate-to-opencode1.sh   ← 保留（数据迁移工具，非启动链）
```

`lib/opencode1/runtime/opencode` 消除，`bin/opencode1` 直接是 runtime 本体。migrate 脚本**不并入 ELF**：它需要 `pacman -Qi opencode` 探测 v2 是否在装、需要 tar 备份、需要在 `$PREFIX` 下可被 hook 调用 —— 这些是 shell 的活，编进 ELF 反而更脆。

### 3.2 wrapper 逻辑逐项裁决

| wrapper 逻辑 | 裁决 | 依据 |
|---|---|---|
| 四个 `XDG_*_HOME` export | **必须编译期固化** | 见 §2；裸跑实测落无命名空间路径 |
| `LD_LIBRARY_PATH`（三根） | **静态变体可删** | 见 §3.3 |
| `service.json` 端口 49376 | **v1 死代码，可删** | 判决实验：塞 `{"port":41987}` 后 `serve` 实听 **42617**（随机端口），41987/49374 均 HTTP 000；源码 `grep -rn service.json packages/` 零命中 |
| `BUN_PTY_LIB` → pty so | **死代码，可删** | 运行时 `strings` 无 `BUN_PTY_LIB`；press5 已把 bionic pty 内嵌（`tools/a2/pty-embed-store-patch.sh`） |
| `LD_PRELOAD` epoll-compat so | **v1 死代码，可删** | 运行时 `strings` 无 `epoll_pwait2`；press5 的 bun 1.4.2 已内建回退 |
| runtime 探测 + `exec` | **随 wrapper 一起消失** | ELF 即 `bin/opencode1`，无探测需求 |
| `migrate-to-opencode1.sh` | **保留为独立文件** | 见 §3.1 |

### 3.3 `LD_LIBRARY_PATH` 必要性 —— 分变体裁决

`readelf -l` + `file` 实测两个变体：

| 变体 | 形态 | 动态依赖 | 裸跑结果 |
|---|---|---|---|
| **press5 / UPX 压缩**（现役 `opencode1-compressed`） | `statically linked, no section header`；4 个 phdr，**无 PT_INTERP、无 PT_DYNAMIC** | 零 | ✅ 直接跑通 |
| 早期 native（`artifacts/mig-extract/v1/…/runtime/opencode` 181M） | `dynamically linked, interpreter /system/bin/linker64` | `DT_NEEDED libopencode-crhandler.so` + `DT_RUNPATH $ORIGIN/../lib/opencode` | ❌ `CANNOT LINK EXECUTABLE` |

**结论**：单 ELF 方案**只适用于 press5/静态变体**。动态变体若要单 ELF，必须先把 `libopencode-crhandler.so` 内联进 binary（转静态或 stub 掉），否则单 ELF 不可行 —— 而这正是 press5 已完成的工作。

⚠️ 注意：压缩变体的 ELF 是 **UPX 打包**的（`strings` 命中 `%t.UPX!x` / `UPXQX`），所以 `strings` 判据在压缩件上**不可靠**（会漏）。上面「死代码」结论对**未打包的 181M native 件**用 `strings` 复核过；压缩件靠「裸跑成功 + serve 200」的行为证据。

### 3.4 编译期固化方案（方案 A 核心）

改 `packages/core/src/global.ts`，把 `app` 从字面量换成**编译期注入的命名空间**：

```ts
// 由构建脚本注入；未注入时回落到上游行为（app = "opencode"）
const ISOLATION = process.env["OPENCODE1_NAMESPACE"] ?? ""   // A2 注入 "opencode1/"
const app = ISOLATION ? ISOLATION + "opencode" : "opencode"
```

等价更干净的写法（避免 env 出现在产物里被误设）：**构建期文本替换**，把 `const app = "opencode"` 直接改成 `const app = "opencode1/opencode"`，产物零 env 依赖。

**为什么选文本替换而非运行时 env**：
- env 方案会在 `debug paths` 输出里暴露 `OPENCODE1_NAMESPACE`，且用户误设即失效；
- 文本替换后 `debug paths` 直接显示最终绝对路径，**可自证**（§5 断言 A2）；
- 单点替换，`app` 是 `const`，无其他写入点（§2.2-2）。

**为什么不用 `OPENCODE_CONFIG_DIR`**：它只覆盖 `config` 一项（`global.ts:64`），data/cache/state/tmp 四项不管用。

### 3.5 编译期固化的完整等价性论证

wrapper 方案的路径 = `join(XDG_DATA_HOME, "opencode")` where `XDG_DATA_HOME = $HOME/.local/share/opencode1`
⇒ `$HOME/.local/share/opencode1/opencode`

编译期固化方案的路径 = `join(xdgData, "opencode1/opencode")` where `xdgData = $HOME/.local/share`
⇒ `$HOME/.local/share/opencode1/opencode`

**四个根（data/config/state/cache）逐字节相同**（`path.join` 规范化）。

**⚠️ tmp 根不等价** —— `global.ts:15` 的 `tmp = path.join(os.tmpdir(), app)` 同样 join 了 `app`，
所以固化会把 tmp 一并 namespaces 化：`$TMPDIR/opencode` → `$TMPDIR/opencode1/opencode`。
详见 §5.1。

**⚠️ 「用户预先 export 的 `XDG_*` 依然生效」不是优势，是 parity**。实测（§9）表明现役 wrapper
用 `${XDG_DATA_HOME:-$HOME/.local/share}/opencode1` 形式，**同样尊重**外部预置的 `XDG_*`，
两者在诱饵 env 下落到**同一路径**。所以固化方案相对 wrapper 的真实增益只有一条：
**绕不过去**（§6.1，没有第二个可执行可直调），而**不是** env 免疫。

---

## 四、方案对比：A（编译期固化）vs B（保留极小 wrapper）

| 维度 | 方案 A 编译期固化 | 方案 B 保留极小 wrapper |
|---|---|---|
| 包内可执行数 | **1**（`bin/opencode1`） | 2（wrapper + payload） |
| bash 依赖 | **零** | 依赖 `$PREFIX/bin/bash` |
| 隔离正确性 | ✅ 由产物保证，用户绕不过去 | ⚠️ 绕过 wrapper 直调 payload 即失效（oscar 已实证） |
| 路径正确性 | ✅ 无 env 依赖，`debug paths` 自证 | ⚠️ 依赖 env 正确传入 |
| 升级风险 | 需改源码 + 重建，回归面在 global.ts 5 行 | 只改 shell，无编译 |
| 迁移成本 | 低（布局不变，无需迁数据） | 零 |
| 调试透明度 | 高（单一进程，`strace`/fd 直接看） | 低（多一层 exec） |
| 适配动态变体 | ❌ 需先内联 crhandler | ✅ 天然支持 |

**建议**：**A 为主，B 降级为回退**。若 A 的重建遇到 global.ts 相关的回归不可收敛，B 保留现状（把 wrapper 瘦身到只剩四个 export + exec，也是合规的「极小 wrapper」）。

---

## 五、验证断言清单（必须在新构建里逐条成立）

| # | 断言 | 检验方法 | 备注 |
|---|---|---|---|
| A1 | 全仓 `packages/*/src` 无 `opencode1` 残留命名硬编码 | `grep -rn opencode1 packages/*/src/` | 固化后应**有且仅有** global.ts 命中 |
| A2 | 裸 ELF 落嵌套命名空间 | 假 HOME 跑 `debug paths`，`data` 含 `/opencode1/opencode` | **核心断言** |
| A3 | 四个根全部嵌套 | `debug paths` 的 data/config/state/cache/tmp 五行 | **tmp 必须变**成 `…/opencode1/opencode`，见 §5.1 |
| A4 | 零 env 依赖（仅指命名） | `env -i` 跑通 `debug config`（仅 HOME/PATH/TERM） | 证明无 `OPENCODE1_*` 残留；**不代表 XDG 免疫**，见 A11 |
| A5 | 零动态依赖 | `readelf -l` 无 `PT_INTERP` / `readelf -d` 空 | 证明 `LD_LIBRARY_PATH` 可删 |
| A6 | 不读 v2 数据 | 假 HOME 跑完后 `find $FAKEHOME -path '*opencode1*'` 全部命中，**零**裸 `opencode/` 根 | 防回归到撞库 |
| A7 | 服务端口不被固定占用 | `serve` 起后随机端口可 curl 200 | 确认 v1 无需 49376 |
| A8 | 双线共存 | 假 HOME 隔离跑 v1 + 真机 v2 并存，检查 v2 目录 mtime 不变 | 需在 oscar 复核 |
| A9 | 迁移脚本仍可用 | `migrate-to-opencode1.sh check` 在新包下退出码语义不变 | 布局未变，应天然通过 |
| A10 | 无 bash 依赖 | `ldd`/`readelf` 无关；实测 `bin/opencode1` 是 ELF 且 `head -c4` = `\x7fELF` | 防误装 shell 脚本 |
| **A11** | **诱饵 XDG 下写入不外逸** | 假 HOME + `XDG_{DATA,CONFIG,STATE,CACHE}_HOME=<sandbox>/decoy-*` 跑 `debug paths` | **默认模式预期失败**（落 decoy，见 §9）；`--ignore-xdg` 模式预期落 `$HOME/.local/share/opencode1/opencode`。判据随模式而定，见 §9.3 |

### 5.1 ⚠️ tmp 根会随固化改变（与现役不等价）

`global.ts:15` 的 `tmp = path.join(os.tmpdir(), app)` 也 join 了 `app`。固化 `app` 顺带把 tmp
namespaces 化：

| 场景 | tmp 落点 | 与 v2 共用？ |
|---|---|---|
| 现役 wrapper（`app="opencode"`） | `$TMPDIR/opencode` | **是**（§6.3-2 的既有共享面） |
| 固化后 ELF（`app="opencode1/opencode"`） | `$TMPDIR/opencode1/opencode` | 否 |
| v2（`app="opencode"`） | `$TMPDIR/opencode` | — |

方向上是**修复**（顺带关掉 §6.3-2 记录的跨代 tmp 共用），但它是**行为变更**，不能默认
「与 wrapper 逐字节相同」。消费方：`plugin/agent.ts:101`、`tool/shell/prompt.ts:280`、
`agent/agent.ts:110`（含 permission 白名单 `path.join(Global.Path.tmp, "*")`）—— 语义不变，
但断言与文档需跟上。

**⚠️ 既有测试会红**：`packages/core/test/global.test.ts:9`
`expect(Global.Path.tmp).toBe(path.join(os.tmpdir(), "opencode"))` —— 固化后必然失败。
**重建前必须改这条测试**，否则回归门会被它挡住。

---

## 六、风险与回退（问题 4）

### 6.1 单 ELF 若失去 wrapper，隔离会不会退化？

**不会退化 —— 反而增强。** 关键区别：

- 现状：隔离是**运行时约定**，靠调用方经过 wrapper。oscar 已实证「绕过 wrapper 直调 runtime = 绕过隔离」，直调会读到 v2 的库与会话。
- 方案 A：隔离**编译进产物**。`bin/opencode1` 这个文件本身就是隔离的，**不存在「绕过」的路径** —— 没有第二个可执行文件可直调。

这消除了 oscar 那类事故的**结构性成因**，代价只是重建成本。

### 6.2 跨容器/双线共存的保护清单

wrapper 提供、A 方案必须重新保证的不变量：

| 不变量 | A 方案如何保证 | 残余风险 |
|---|---|---|
| data/config/state/cache 分代 | `global.ts` `app` 固化 | 无 |
| 不覆盖 v2 目录 | 同上 | 无 |
| 迁移期不误搬 v2 数据 | 布局不变，`migrate-to-opencode1.sh` 的 `v2_installed()` 探测逻辑不变 | 无 |
| 插件路径 patch | 脚本独立于启动链，布局不变故 patch 目标不变 | 无 |
| 端口不互撞 | v1 随机端口（§3.2 实测） | 已天然更强 |

### 6.3 方案 A **不能**修复的既有共享面（重要）

1. **`~/.opencode`（project scope）跨代共享**。`config/paths.ts:34-38` 从 `Global.Path.home` 向上收集 `.opencode` 目录 —— 这是**工作树/家目录**层，**不受 XDG re-root 影响**。本机 `~/.opencode` 实测存在（含 `opencode.json` / `memory/` / `node_modules/`）。这是 v1/v2 **共读**的，且是**并集**语义（project scope 优先于 global）。
   → 记忆索引 `project_opencode_isolation_traps.md` 里的「`~/.opencode` 属 project scope 复制无法驱逐」在此得到源码级确认。
   → **A 方案不修它**（不修才能保持行为等价）。若要修，需给 `paths.ts` 加同样的 namespace 参数 —— 那是**独立的行为变更**，应单独立项。
2. **`$TMPDIR/opencode` 共用**。`global.ts:15` 用 `os.tmpdir()`，`launcher` 并未 export `TMPDIR`（注释与实现不符）。bunfs 提取落此处。→ 保持现状。
   → **但方案 A 会顺带修掉它**：固化 `app` 后 tmp 变 `$TMPDIR/opencode1/opencode`，不再与 v2 共用。方向是好的，但它同时构成一处**行为变更**，见 §5.1（含会让 `global.test.ts:9` 变红）。

### 6.4 回退

- 分支隔离在 `rc6-a2/single-elf`，未合主线；
- 方案 B（瘦身 wrapper）始终可作为回退路径，不需要新包；
- 数据布局零变更 ⇒ **回退零数据成本**。

---

## 七、迁移步骤

1. **改源码**：`packages/core/src/global.ts` 的 `app` 文本替换为 `opencode1/opencode`。用
   `tools/a2/single-elf-namespace-patch.sh`（默认模式；`--ignore-xdg` 变体见 §9.4，**默认不启用**）。
2. **改测试**：`packages/core/test/global.test.ts:9` 的 tmp 断言需随 §5.1 更新，否则回归门被挡。
3. **重建**：走 press5 管线（`tools/a2/press-v5.sh` + `build-v1.sh`）产出静态 ELF。
4. **验断言**：§5 的 A1–A11，**A2/A5/A6 为阻断门**，A11 判据随模式而定（§9.3）。
5. **改打包**：`packing/pacman/PKGBUILD.native`（及 compressed 线）把 `install -D … runtime/opencode` 改为 `install -D -m755 "$OPENCODE_NATIVE_BIN" …/bin/$OPENCODE_BIN_NAME`，删掉 `opencode1-launcher.sh` 的 install 行。
6. **改 `.install` 模板**：`packing/pacman/opencode1-compressed.install` 里那句「invoke via the opencode1 launcher only」不再成立，需改写。
7. **不迁数据**：布局未变，`migrate-to-opencode1.sh` 继续随包提供（hook 继续调 `check`/`isolate`）。

---

## 八、原型改动清单（本分支）

| 文件 | 性质 | 说明 |
|---|---|---|
| `docs/single-elf-v1.md` | 本文档 | 设计 + 证据 |
| `tools/a2/single-elf-namespace-patch.sh` | 幂等 store patch | 默认模式：把 `app` 固化为 `opencode1/opencode`；`--ignore-xdg`：额外派生 `home` 并移除 `xdg-basedir`（§9.4）。两者均带 `.bak` + post-verify + marker 行 |

**未做**（按任务边界）：不出包、不装机、不发布、不改 PKGBUILD、不动 oscar。

---

## 九、env 免疫边界（task-26 实测）

> 原始输出：`.omo/evidence/a2-v1-effect-rebuild/task-26-xdg-boundary.txt`
> 沙箱：`$TMPDIR/a2-xdgprobe/sandbox`（全程 `env -i` + 假 HOME + 沙箱 TMPDIR）

### 9.1 判据 A 成立：诱饵 `XDG_*` 确实被消费

被测对象 = press5 裸静态 ELF（`statically linked, no section header`，2 个 LOAD，
零 `PT_INTERP` / 零 `PT_DYNAMIC`）。**基线（零 XDG）**：

```
data   $SB/home/.local/share/opencode          ← 未固化命名，故无 opencode1 段
config $SB/home/.config/opencode
tmp    $SB/tmp/opencode
```

**诱饵（四个 `XDG_*` 全部指向 `$SB/decoy-*`，全新空 fake HOME）**：

```
data   $SB/decoy-data/opencode                 ← ★ decoy
bin    $SB/decoy-cache/opencode/bin            ← ★ decoy
log    $SB/decoy-data/opencode/log             ← ★ decoy
repos  $SB/decoy-data/opencode/repos           ← ★ decoy
cache  $SB/decoy-cache/opencode                ← ★ decoy
config $SB/decoy-config/opencode               ← ★ decoy
state  $SB/decoy-state/opencode                ← ★ decoy
tmp    $SB/tmp/opencode                        ← tmp 走 os.tmpdir()，与 XDG 无关

$ ls -1 $SB/decoy-*
decoy-cache: opencode    decoy-config: opencode
decoy-data:  opencode    decoy-state:  opencode      ← 四根被真实创建

$ find $SB/home -mindepth 1 | wc -l
0                                                  ← 假 HOME 零写入，re-root 彻底
```

**固化命名后（`app="opencode1/opencode"`）是否免疫？—— 用真实 `xdg-basedir@5.1.0`
模块 + 逐行照抄 `global.ts:11-15` 的派生式实测**（把 `app` 取值换成固化后的值）：

```
[UNPATCHED_app_opencode]  app="opencode"
  data   = $SB/decoy-data/opencode
  => data root sits under DECOY? YES (HIJACKED)

[PATCHED_app_opencode1]  app="opencode1/opencode"
  data   = $SB/decoy-data/opencode1/opencode       ← ★ 仍在 decoy 下
  => data root sits under DECOY? YES (HIJACKED)
```

**判定：判据 A 对固化后的变体同样成立。** 固化改变的是**后缀**，不是**根** ——
`xdg-basedir@5.1.0/index.js:7-16` 在 import 时就无条件读 env，`app` 与之正交。

> **判据 B 不成立。** 「xdg-basedir 在无 wrapper 场景不消费外部 `XDG_*`」是**错的** ——
> 实测恰恰相反：裸 ELF（无 wrapper）**正是消费得最彻底**的那个。诱饵不被消费只在
> 一个条件下成立：调用方**没有** export `XDG_*`。

### 9.2 但这是 parity，不是回归

现役 wrapper（`scripts/opencode1-launcher.sh:17-20`）用的是**同样**的
`${XDG_*:-$HOME/…}` 形式 —— **它也尊重外部预置的 `XDG_*`**。真 wrapper 端到端
（`$PREFIX` 只读 + 假 HOME + 诱饵）：

```
data   $SB/decoy-data/opencode1/opencode      ← 与固化 ELF 同一路径
config $SB/decoy-config/opencode1/opencode
tmp    $SB/tmp/opencode                       ← wrapper 下 tmp 不带命名空间（§5.1）

wrapper   : $SB/decoy-data/opencode1/opencode
singleELF : $SB/decoy-data/opencode1/opencode
=> MATCH: patch is PARITY with wrapper even under adversarial XDG
```

**所以方案 A 不引入新的 env 暴露面。** A 相对 wrapper 的真实增益只有「绕不过去」
（§6.1），**不是** env 免疫。§3.5 原先「比 wrapper 更宽容」的表述据此修正。

### 9.3 两模式行为对照表

| 维度 | 默认（namespace only） | `--ignore-xdg`（A+ 草案） |
|---|---|---|
| `app` 常量 | `opencode1/opencode` | `opencode1/opencode`（相同） |
| XDG 根来源 | `xdg-basedir`（**读 env**） | `process.env.HOME ?? os.homedir()`（**不读 XDG_***） |
| 诱饵 XDG 下 data 落点 | `$DECOY/opencode1/opencode`（**被劫持**） | `$HOME/.local/share/opencode1/opencode`（**免疫**，实测 IGNORED） |
| 与现役 wrapper 关系 | **parity**（诱饵下逐字节相同） | **strictly stronger**（wrapper 会被劫持，A+ 不会） |
| `XDG_*` 支持 | 尊重（用户可重定向） | **不再尊重**（能力回退） |
| 零 XDG 时布局 | `$HOME/…/opencode1/opencode` | 同左（**逐字节相同**） |
| tmp | `$TMPDIR/opencode1/opencode` | 同左 |
| 适用场景 | 与现役**行为等价**，迁移零风险；保留用户用 `XDG_*` 重定向 v1 数据的能力（如外置盘/加密卷） | 要「产物即隔离、env 绕不过去」的**强保证**；或审计要求拒绝一切外部 env 输入 |
| 代价 | 无（现状等价） | 用户若依赖 `XDG_*` 重定向 v1 数据 → **配置失效**；`TMPDIR` **不**在 neutralize 范围（`os.tmpdir()` 仍生效），刻意保留 |

**建议：默认模式随单 ELF 一起发布**（等价、零风险）；`--ignore-xdg` **留作可选项**，
仅在「必须拒绝外部 env」的场景显式启用。这是发布决策，不是构建决策。

### 9.4 `--ignore-xdg` 变体（草案，**未启用**）

```bash
tools/a2/single-elf-namespace-patch.sh --ignore-xdg   # 默认不加此参数
```

`global.ts` 改动（6 行；实测产出，L3 承接原 import 槽位，ESM import 提升使其合法）：

```ts
const home = process.env.HOME ?? os.homedir()                    // 替换 xdg-basedir import
// single-elf-patch: namespace=opencode1 ignore-xdg=1
const app = "opencode1/opencode"
const data   = path.join(home, '.local', 'share', app)
const cache  = path.join(home, '.cache', app)
const config = path.join(home, '.config', app)
const state  = path.join(home, '.local', 'state', app)
const tmp    = path.join(os.tmpdir(), app)                      ← 刻意不动
```

补丁脚本已实现并验证：默认/`--ignore-xdg` 双模式幂等、`.bak` 保留、`post-verify`
逐条校验、`marker` 行自我标记、上游漂移时 fail-fast、`--ignore-xdg` 下断言
`xdg-basedir` import 已消失。**未接入任何打包脚本**，`--ignore-xdg` **默认关闭**。

**运行时验证**（bun 执行与 patch 产出逐行同构的派生区，诱饵 XDG 下）：

```
XDG_DATA_HOME = $SB/decoy-data
data   = $SB/home/.local/share/opencode1/opencode
=> IGNORED decoy XDG_* (GOOD)
```

### 9.5 等价性说明（为何用未固化 ELF 做实测）

任务允许在构建成本过高时改用现有裸静态 ELF。此处**两条链互补**，须合并阅读：

1. **实测链（真 ELF 端到端）**：press5 未固化 ELF 的 `debug paths` 证明
   **XDG_* 确实被消费**（§9.1）。此结论**与 app 命名无关** —— `xdg-basedir` 的读 env
   行为发生在 `global.ts:11-15` 派生之前，与 `app` 取值正交。
2. **推导链（模块级）**：真实 `xdg-basedir` 模块 + 照抄派生式，把 `app` 换成固化后的值，
   **直接计算**固化变体的落点（§9.1 第二段）。

**差异必须写明**：实测链用的是**未固化** ELF，故落在 `$SB/decoy-*/opencode`（无
`opencode1` 段）；固化后落在 `$SB/decoy-*/opencode1/opencode`（多一层）。**前缀差一层，
XDG 消费行为完全相同。** §9.2 用真 wrapper 补上了这一层对照，证明「加不加这层，
wrapper 与 ELF 都同样被 decoy 劫持」。

**未做**：press5 全管线重建（磁盘 99% / 余 18G）。留待发布决策后按 §七 执行。
