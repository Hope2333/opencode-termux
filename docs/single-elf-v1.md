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

**逐字节相同**（`path.join` 规范化）。四个根 + tmp 全部成立，唯一差别是固化方案下**用户预先 export 的 `XDG_*` 依然生效**（因为 `xdg-basedir` 仍读 env），这比 wrapper 的 `${XDG_DATA_HOME:-…}/opencode1` **更宽容**（wrapper 会把 opencode1 再套一层）。

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
| A3 | 四个根全部嵌套 | `debug paths` 的 data/config/state/cache/tmp 五行 | tmp 断言 `…/opencode1/opencode` 或确认 tmp 共用（见 §6） |
| A4 | 零 env 依赖 | `env -i` 跑通 `debug config`（仅 HOME/PATH/TERM） | 证明无 `OPENCODE1_*` 残留 |
| A5 | 零动态依赖 | `readelf -l` 无 `PT_INTERP` / `readelf -d` 空 | 证明 `LD_LIBRARY_PATH` 可删 |
| A6 | 不读 v2 数据 | 假 HOME 跑完后 `find $FAKEHOME -path '*opencode1*'` 全部命中，**零**裸 `opencode/` 根 | 防回归到撞库 |
| A7 | 服务端口不被固定占用 | `serve` 起后随机端口可 curl 200 | 确认 v1 无需 49376 |
| A8 | 双线共存 | 假 HOME 隔离跑 v1 + 真机 v2 并存，检查 v2 目录 mtime 不变 | 需在 oscar 复核 |
| A9 | 迁移脚本仍可用 | `migrate-to-opencode1.sh check` 在新包下退出码语义不变 | 布局未变，应天然通过 |
| A10 | 无 bash 依赖 | `ldd`/`readelf` 无关；实测 `bin/opencode1` 是 ELF 且 `head -c4` = `\x7fELF` | 防误装 shell 脚本 |

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

### 6.4 回退

- 分支隔离在 `rc6-a2/single-elf`，未合主线；
- 方案 B（瘦身 wrapper）始终可作为回退路径，不需要新包；
- 数据布局零变更 ⇒ **回退零数据成本**。

---

## 七、迁移步骤

1. **改源码**：`packages/core/src/global.ts` 的 `app` 文本替换为 `opencode1/opencode`（或用 store patch 脚本，见 `tools/a2/pty-embed-store-patch.sh` 同款幂等写法）。
2. **重建**：走 press5 管线（`tools/a2/press-v5.sh` + `build-v1.sh`）产出静态 ELF。
3. **验断言**：§5 的 A1–A10，**A2/A5/A6 为阻断门**。
4. **改打包**：`packing/pacman/PKGBUILD.native`（及 compressed 线）把 `install -D … runtime/opencode` 改为 `install -D -m755 "$OPENCODE_NATIVE_BIN" …/bin/$OPENCODE_BIN_NAME`，删掉 `opencode1-launcher.sh` 的 install 行。
5. **改 `.install` 模板**：`packing/pacman/opencode1-compressed.install` 里那句「invoke via the opencode1 launcher only」不再成立，需改写。
6. **不迁数据**：布局未变，`migrate-to-opencode1.sh` 继续随包提供（hook 继续调 `check`/`isolate`）。

---

## 八、原型改动清单（本分支）

| 文件 | 性质 | 说明 |
|---|---|---|
| `docs/single-elf-v1.md` | 本文档 | 设计 + 证据 |
| `tools/a2/single-elf-namespace-patch.sh` | 幂等 store patch | 把 `global.ts` 的 `app` 固化为 `opencode1/opencode`；未注入时跳过；带备份与 verify |

**未做**（按任务边界）：不出包、不装机、不发布、不改 PKGBUILD、不动 oscar。
