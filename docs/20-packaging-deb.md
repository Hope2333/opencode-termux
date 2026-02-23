# 20 - Packaging as .deb

## 目标
为 `bun` 与 `opencode` 产出可安装的 Debian 包：
- `bun_<ver>_arm64.deb`
- `opencode_<ver>_arm64.deb`

## 架构与依赖约束
- `Architecture` 使用 Debian 规范值：`arm64`
- `Depends` 需按本地运行时实测确定，不预设固定 `libc6` 结论
- `termux-services` 作为可选依赖（`Recommends`），用于 `sv` 管理 `opencode web`

## 目录（staging）
```text
packaging/deb/
├─ bun/
│  ├─ DEBIAN/control
│  ├─ DEBIAN/postinst
│  └─ <PREFIX>/bin/bun
└─ opencode/
   ├─ DEBIAN/control
   ├─ DEBIAN/postinst
   └─ <PREFIX>/...
```

## 打包步骤
1. 清理并重建 staging
2. 拷贝 staged 产物到 `<PREFIX>` 目录树
3. 生成 control / postinst
4. `dpkg-deb --build ...`

## 安装后检查
```bash
bun --version
opencode --version
command -v bun
command -v opencode

# 可选：服务检查（需 termux-services）
sv status opencode-web
```

## opencode-web 服务（sv）
- 服务目录：`$PREFIX/share/termux-services/opencode-web`
- 默认启用：安装后会创建 `$PREFIX/var/service/opencode-web` 软链接
- 默认工作目录：`$HOME`
- 默认监听：`0.0.0.0:4096`（局域网可访问）
- 可通过环境变量覆盖：
  - `OPENCODE_WEB_HOSTNAME`
  - `OPENCODE_WEB_PORT`

## 约束
- 不写入共享存储 `noexec` 路径
- control 字段与文件布局每次打包前重新生成，避免脏数据
