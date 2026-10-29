# Termux 仓库资产更新流程


> 状态：snapshot ｜ 适用版本：2026-09 快照

> **快照说明（2026-09，已实体化入仓）**：本文原为仓外 symlink，是四仓资产发布流程的历史快照。
> opencode-termux 的打包线此后已切到原生 bionic（native/compressed 族），本文中 "bun-termux-loader"
> 的描述只适用于 wrapper 附录线；现行流程见 `docs/make-maintainer.md` 与 `docs/handover/release-runbook.md`。

> 管理四个 Termux AI 工具仓库的二进制获取、包装、打包、发布的完整流程。
> 仓库位于 `~/develop/` 下，GitHub 均在 `Hope2333` 组织。

---

## 1. 仓库一览

| 仓库 | 本地路径 | 上游来源 | 二进制名 | 包装方式 | 包名 |
|------|---------|---------|---------|----------|------|
| **opencode-termux** | `~/develop/opencode-termux` | npm `opencode-linux-arm64` | `opencode` | bun-termux-loader | `opencode` |
| **MiMoCode-Termux** | `~/develop/MiMoCode-Termux` | GitHub Releases `XiaomiMiMo/MiMo-Code` | `mimo` | bun-termux-loader | `mimocode` |
| **freebuff-termux** | `~/develop/freebuff-termux` | npm `freebuff` + GitHub `CodebuffAI/codebuff-community` | `freebuff` | C wrapper + patchelf | `freebuff` |
| **codebuff-termux** | `~/develop/codebuff-termux` | npm `codebuff` + GitHub `CodebuffAI/codebuff-community` | `codebuff` | C wrapper + patchelf | `codebuff` |

### 1.1 仓库 GitHub URL

```
https://github.com/Hope2333/opencode-termux
https://github.com/Hope2333/MiMoCode-Termux
https://github.com/Hope2333/freebuff-termux
https://github.com/Hope2333/codebuff-termux
```

### 1.2 上游 URL

```
opencode:  https://github.com/anomalyco/opencode
MiMoCode:  https://github.com/XiaomiMiMo/MiMo-Code
Freebuff:  https://github.com/CodebuffAI/codebuff-community
Codebuff:  https://github.com/CodebuffAI/codebuff-community
```

---

## 2. 整体流程（四阶段）

```
                  阶段一                         阶段二                 阶段三              阶段四
           ┌─────────────────┐          ┌──────────────┐       ┌────────────┐       ┌──────────────┐
           │  获取 Runtime    │          │  Staging     │       │  打包      │       │  发布         │
           │  produce-local  │ ─────→   │  build.sh    │ ───→  │  package_* │ ───→  │  release-    │
           │  .sh            │          │              │       │  .sh       │       │  upload      │
           └─────────────────┘          └──────────────┘       └────────────┘       └──────────────┘
                  │                            │                      │                     │
                  ▼                            ▼                      ▼                     ▼
           artifacts/<name>/           artifacts/staged/        packaging/dpkg/        GitHub Release
           runtime/                    prefix/                  packaging/pacman/       Push<YYMMDD>
                                                                                        + assets
```

---

## 3. 阶段一：获取 Runtime 二进制

### 3.1 opencode-termux / MiMoCode-Termux（bun-termux-loader 路线）

```
produce-local.sh
│
├─ [版本解析]
│  opencode:  npm view opencode-linux-arm64 version
│  MiMoCode:  gh release list --repo XiaomiMiMo/MiMo-Code --limit 1
│
├─ [下载]
│  opencode:  npm pack "opencode-linux-arm64@$VER"
│  MiMoCode:  wget -c "https://github.com/XiaomiMiMo/MiMo-Code/releases/download/v$VER/mimocode-linux-arm64.tar.gz"
│
├─ [解压]
│  opencode:  tar -xzf → package/bin/opencode
│  MiMoCode:  tar -xzf → ./mimo
│
├─ [包装]  python3 bun-termux-loader/build.py $RAW --wrapper wrapper --shim bunfs_shim.so
│
├─ [缓存]  $HOME/.cache/{opencode,mimocode}-termux/{opencode,mimocode}-$VER
│
└─ [输出]  artifacts/{opencode,mimocode}/runtime/{opencode,mimocode}-termux
```

### 3.2 freebuff-termux / codebuff-termux（C wrapper + patchelf 路线）

```
produce-local.sh
│
├─ [版本解析]  npm view {freebuff,codebuff} version
│
├─ [下载]     wget -c "https://github.com/CodebuffAI/codebuff-community/releases/download/v$VER/{freebuff,codebuff}-linux-arm64.tar.gz"
│
├─ [解压]     tar -xzf → ./{freebuff,codebuff}
│
├─ [patchelf]  patchelf --set-interpreter /.../glibc/lib/ld-linux-aarch64.so.1 $BINARY
│
├─ [编译 hook] gcc -fPIC -shared -o hook.so hook.c -Iglibc/include -Lglibc/lib -nostdlib -lc -ldl
│
├─ [编译 wrapper] gcc -O2 -s -o {freebuff,codebuff}-wrapper {freebuff,codebuff}-wrapper.c
│
├─ [输出]  ~/.config/manicode/{freebuff,codebuff}  (原始 binary, patchelf'd)
│          tools/hook.so
│          tools/{freebuff,codebuff}-wrapper
│
└─ [缓存]  ~/.cache/{freebuff,codebuff}-termux/ （尚未实现，可通过更新 produce-local.sh 添加）
```

### 3.3 重复点

| 步骤 | opencode | MiMoCode | freebuff | codebuff |
|------|:--------:|:--------:|:--------:|:--------:|
| 版本解析 | npm view | gh release | npm view | npm view |
| 下载工具 | npm | wget -c | wget -c | wget -c |
| 解压 | tar | tar | tar | tar |
| 包装方式 | bun-termux-loader | bun-termux-loader | patchelf+编译 | patchelf+编译 |
| 缓存 | ~/.cache/* | ~/.cache/* | ❌ 无 | ❌ 无 |

---

## 4. 阶段二：Staging（布局到 staged prefix）

### 4.1 opencode-termux / MiMoCode-Termux

```tree
artifacts/staged/prefix/
├── bin/
│   └── {opencode, mimo}              ← launcher.sh（bash 脚本）
└── lib/
    └── {opencode, mimocode}/
        ├── runtime/
        │   └── {opencode, mimo}       ← bun-termux-loader 包装后的 ELF
        ├── tools/
        │   ├── plugin-manager.sh
        │   ├── plugin-selfcheck.sh
        │   └── run-system-skills.sh
        ├── system-skills/
        │   ├── blocklist.json
        │   └── omo.json
        └── docs/ (via bundle-list.txt)
```

### 4.2 freebuff-termux / codebuff-termux

```tree
artifacts/staged/
├── bin/
│   └── {freebuff, codebuff}          ← C wrapper（Bionic 编译）
└── lib/
    └── {freebuff, codebuff}/
        ├── runtime/
        │   └── {freebuff, codebuff}   ← 原始 binary（patchelf'd）
        ├── hook.so                    ← LD_PRELOAD hook
        ├── patches/                   ← npm 补丁
        ├── scripts/
        │   ├── {freebuff,codebuff}-wrapper.c
        │   └── produce-local.sh
        ├── install.sh
        └── Makefile
```

### 4.3 关键区别

| 项目 | opencode/MiMoCode | freebuff/codebuff |
|------|:-----------------:|:-----------------:|
| Staged 根路径 | `artifacts/staged/prefix/` | `artifacts/staged/` |
| Launcher 类型 | bash 脚本 (`launcher.sh`) | C ELF 包装器 |
| 额外组件 | tools/, system-skills/, docs/ | hook.so, patches/ |
| 二进制来源 | bun-termux-loader 包装产物 | 原始 binary (patchelf'd) |

---

## 5. 阶段三：打包（DEB + Pacman）

### 5.1 文件结构

```
scripts/package/
├── package_deb.sh          ← DEB 打包脚本（4个仓库 ≈90% 相同）
└── package_pacman.sh       ← Pacman 打包脚本（4个仓库 ≈90% 相同）

packaging/
└── pacman/
    └── PKGBUILD            ← Pacman 构建模板（4个仓库 ≈85% 相同）
```

### 5.2 package_deb.sh 模板

| 参数 | opencode | MiMoCode | freebuff | codebuff |
|------|----------|----------|----------|----------|
| `Package:` | opencode | mimocode | freebuff | codebuff |
| `Description:` | OpenCode AI | MiMoCode AI | Freebuff AI | Codebuff AI |
| `Depends:` | bash, ncurses | bash, ncurses | bash, glibc, openssl-glibc | bash, glibc, openssl-glibc |
| 检测 launcher | `bin/opencode` | `bin/mimo` | `bin/freebuff` | `bin/codebuff` |
| postinst 消息 | opencode --version | mimo --version | freebuff --version | codebuff --version |
| hook 路径 | `lib/opencode/tools/` | `lib/mimocode/tools/` | `lib/freebuff/` | `lib/codebuff/` |

### 5.3 package_pacman.sh 模板

差异点与 DEB 完全一致（包名、路径、依赖）。

### 5.4 PKGBUILD 模板

差异点相同：
- `pkgname=`
- `pkgdesc=`
- `url=`
- 路径检查 `lib/<name>/runtime/<binary>`
- post_install 消息

### 5.5 构建命令

```bash
# 统一接口
make clean                   # 清除 artifacts/staged + packaging work dirs
make stage                   # produce + build.sh
make deb VERSION=<ver>       # 构建 DEB
make pacman VERSION=<ver>    # 构建 Pacman

# 或一键
make all VER=<ver> PKG=both
```

---

## 6. 阶段四：发布（Release + Upload）

### 6.1 Makefile release-upload 流程

```makefile
release-upload:
  1. make batch VERS='...' PKG=both ODIR=/tmp/<prefix>-release-$(TAG) MIX=1
  2. gh release create "$(TAG)" --repo "$(REPO)" --title "$(TAG)" --notes "..."
  3. gh release upload "$(TAG)" <assets> --repo "$(REPO)" --clobber
```

### 6.2 各仓库参数

| 参数 | opencode | MiMoCode | freebuff | codebuff |
|------|----------|----------|----------|----------|
| `REPO` | `Hope2333/opencode-termux` | `Hope2333/MiMoCode-Termux` | `Hope2333/freebuff-termux` | `Hope2333/codebuff-termux` |
| 临时目录 | `/tmp/oc-release-*` | `/tmp/mc-release-*` | `/tmp/fb-release-*` | `/tmp/cb-release-*` |
| DEB 匹配 | `opencode_*.deb` | `mimocode_*.deb` | `freebuff_*.deb` | `codebuff_*.deb` |
| Pacman 匹配 | `opencode-*.pkg.*` | `mimocode-*.pkg.*` | `freebuff-*.pkg.*` | `codebuff-*.pkg.*` |

### 6.3 手动发布步骤

```bash
# 1. 构建（在对应仓库目录下）
cd ~/develop/<repo>
make all VER=<版本> PKG=both

# 2. 创建 Release
TAG=Push$(date +%y%m%d)
gh release create "$TAG" --repo "Hope2333/<repo>" --title "$TAG" --notes "..."

# 3. 上传资产
gh release upload "$TAG" packaging/dpkg/<pkg>_<ver>_aarch64.deb --repo "Hope2333/<repo>" --clobber
gh release upload "$TAG" packaging/pacman/<pkg>-<ver>-1-aarch64.pkg.tar.xz --repo "Hope2333/<repo>" --clobber

# 4. 更新 Release Notes（如需要）
gh release edit "$TAG" --repo "Hope2333/<repo>" --notes "更新后的内容"
```

---

## 7. 核心重复组件清单

| 组件 | 重复仓库 | 重复度 | 差异点 |
|------|---------|:------:|--------|
| `scripts/package/package_deb.sh` | 全部4个 | ~90% | 包名，路径前缀，依赖列表，postinst 消息 |
| `scripts/package/package_pacman.sh` | 全部4个 | ~90% | 同上 |
| `packaging/pacman/PKGBUILD` | 全部4个 | ~85% | pkgname, url, 路径检查, 描述 |
| `Makefile` 的 deb/pacman/batch/release-upload | 全部4个 | ~80% | REPO, 文件匹配 pattern, 临时目录名 |
| `.gitignore` | 全部4个 | ~90% | 包名 pattern |
| `scripts/build.sh` 的 staged layout | opencode/MiMoCode | ~70% | 路径前缀，额外组件 |
| `scripts/build.sh` 的 staged layout | freebuff/codebuff | ~95% | 几乎完全一致 |
| `tools/produce-local.sh` 下载+解压 | opencode vs MiMoCode | ~60% | 来源不同（npm vs GitHub） |
| `tools/produce-local.sh` 下载+解压 | freebuff vs codebuff | ~95% | 包名不同 |

---

## 8. 完整更新操作步骤

### 8.1 检查上游新版本

```bash
# opencode-linux-arm64
npm view opencode-linux-arm64 version

# MiMoCode
gh release list --repo XiaomiMiMo/MiMo-Code --limit 1

# freebuff / codebuff
npm view freebuff version
npm view codebuff version
```

### 8.2 构建并发布（单版本）

```bash
cd ~/develop/<repo>

make clean
make all VER=<version> PKG=both

ls -la packaging/dpkg/<pkg>_<version>_aarch64.deb
ls -la packaging/pacman/<pkg>-<version>-1-aarch64.pkg.tar.xz

# 上传到现有 Push 标签
gh release upload Push<YYMMDD> packaging/dpkg/<pkg>_<version>_aarch64.deb --repo Hope2333/<repo> --clobber
gh release upload Push<YYMMDD> packaging/pacman/<pkg>-<version>-1-aarch64.pkg.tar.xz --repo Hope2333/<repo> --clobber
```

### 8.3 批量构建并发布

```bash
cd ~/develop/<repo>

# 批量构建多个版本
make batch VERS='1.0.1 1.0.2 1.0.3' PKG=both ODIR=~/out MIX=1

# 使用 release-upload 一键完成
make release-upload TAG=Push<YYMMDD> VERS='1.0.[1-3]'
```

### 8.4 更新 Release Notes

```bash
gh release edit Push<YYMMDD> --repo Hope2333/<repo> --notes "## BUILD LOG
<YYMMDD>: v<版本>
Latest: v<最新版本>

...
"
```

---

## 9. 各仓库版本对照表（截至 2026-10-30）

> 本表是**快照**，会过期。发布前用命令取真值，不要拿这张表当依据：
> `gh release list --repo Hope2333/<repo> --limit 3`

| 仓库 | 最新版本 | 最新 Push Tag |
|------|:-------:|:------------:|
| opencode-termux | v2 `2.1.4` / v1 `1.19.4` | `Push261026` |
| MiMoCode-Termux | `0.1.13`（wrapper `0.1.15`） | `Push260912` |
| freebuff-termux | `0.2.29` | `Push260914` |
| codebuff-termux | `1.0.688` | `Push260911` |
| codegraph-termux | `1.6.0` | `Push260803` |

版本取自统一 pacman 索引 `hope2333.db`（随最新批次发布）；tag 取自 `gh api
repos/<owner>/<repo>/releases?per_page=1`。opencode-termux 的双代版本口径：
v2 = `opencode`，v1 = `opencode1`，两者独立跟踪、可共存安装。

---

## 10. 发布规范

### 10.1 Tag 命名

```
Push<YYMMDD>
```

示例：`Push260611`（2026-06-11）

### 10.2 Release Notes 模板

```markdown
## BUILD LOG
<YYMMDD>: v<版本范围>
Latest: v<最新版本>

## <项目名> for Termux

<描述>

### Assets

| Format | Versions |
|--------|----------|
| DEB | <文件名> |
| Pacman | <文件名> |

### Dependencies

- `glibc` + `openssl-glibc` — ...

### Install

```bash
apt install -y glibc-repo && apt update && apt install -y glibc openssl-glibc
apt install -y /path/to/<package>_<version>_aarch64.deb
```

Run: `<binary> --version`
```

### 10.3 文件命名

```
DEB:   <pkgname>_<version>_<arch>.deb
Pacman: <pkgname>-<version>-<pkgrel>-<arch>.pkg.tar.xz
```

示例：
```
mimocode_0.1.0_aarch64.deb
mimocode-0.1.0-1-aarch64.pkg.tar.xz
freebuff_0.0.106_aarch64.deb
freebuff-0.0.106-1-aarch64.pkg.tar.xz
```
