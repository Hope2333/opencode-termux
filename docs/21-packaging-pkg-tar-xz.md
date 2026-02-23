# 21 - Packaging as pkg.tar.xz (Pacman)

## 目标
为 `bun` 与 `opencode` 产出：
- `bun-<ver>-<rel>-aarch64.pkg.tar.xz`
- `opencode-<ver>-<rel>-aarch64.pkg.tar.xz`

## 当前策略
第一阶段先产出可安装布局归档（`pkg.tar.xz`），后续补全完整 PKGBUILD / .PKGINFO 流程。

## 关键约束
- `arch=('aarch64')`
- 打包逻辑只操作构建工作目录，不直接写宿主系统路径
- staged 文件布局必须指向 Termux 前缀（`$PREFIX`）
- `termux-services` 仅作为可选依赖（`optdepends`），用于 `sv` 管理 `opencode-web`

## 目录建议
```text
packaging/pacman/
├─ bun/
└─ opencode/
```

## 构建与验证
```bash
# 打包
scripts/package/package_pacman.sh bun
scripts/package/package_pacman.sh opencode

# 验证产物存在
ls artifacts/bun/pacman/*.pkg.tar.xz
ls artifacts/opencode/pacman/*.pkg.tar.xz
```

## 待补充
- [ ] 完整 PKGBUILD 流程
- [ ] 安装/卸载脚本与元数据一致性
- [ ] pacman -U 实装回归

## opencode-web 服务（sv）
- 服务目录：`$PREFIX/share/termux-services/opencode-web`
- 默认启用：包内预置 `$PREFIX/var/service/opencode-web -> ../../share/termux-services/opencode-web`
- 默认工作目录：`$HOME`
- 默认监听：`0.0.0.0:4096`（局域网可访问）
