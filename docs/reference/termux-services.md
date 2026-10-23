# 22 - opencode web 的 Termux sv 服务

## 目标
为 `opencode web` 提供可由 `sv` 管理的常驻服务，并在安装后默认启用。

## 可选依赖
- `termux-services`（可选）
  - deb: `Recommends: termux-services`
  - pacman: `optdepends=('termux-services: manage opencode-web service via sv')`

> 说明：`opencode` 主功能不强依赖该包；仅在需要 `sv up/down/status` 管理时才需要。

## 服务布局
- 服务定义：`$PREFIX/share/termux-services/opencode-web/run`
- 启用链接：`$PREFIX/var/service/opencode-web`

`run` 脚本行为：
- 进入工作目录：`cd "$HOME"`
- 默认参数：
  - `OPENCODE_WEB_HOSTNAME=0.0.0.0`（监听所有网卡，局域网可访问）
  - `OPENCODE_WEB_PORT=4096`
- 执行：`opencode web --hostname "$OPENCODE_WEB_HOSTNAME" --port "$OPENCODE_WEB_PORT"`

## 默认启用策略
- 打包产物包含 `var/service/opencode-web` 软链接（pacman/deb 均可用）
- deb 安装后脚本（postinst）会补充创建该软链接，确保默认启用

## 常用运维命令
```bash
sv status opencode-web
sv up opencode-web
sv down opencode-web
sv restart opencode-web
```

## 访问
默认监听 `0.0.0.0:4096`，局域网可访问：
```text
http://本机IP:4096
```

> **安全提示**：默认无认证。如需启用 HTTP Basic Auth，设置环境变量 `OPENCODE_SERVER_USERNAME` 和 `OPENCODE_SERVER_PASSWORD`。

## HTTPS
当前 opencode web 不内置 TLS。如需 HTTPS：
- 方案 A：使用 Caddy 反向代理（自动 Let's Encrypt）
- 方案 B：使用 Cloudflare Tunnel（无需公网 IP）
- 方案 C：修改 opencode 源码添加 TLS 支持
