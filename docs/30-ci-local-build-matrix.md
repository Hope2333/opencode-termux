# 30 - Local Build Matrix & Verification

## 构建矩阵
| 组件 | 构建策略 | 产物 |
|---|---|---|
| bun | compile input + loader wrap | deb + pkg.tar.xz |
| opencode | staged source build | deb + pkg.tar.xz |

## 基础环境采集
```bash
uname -a
getprop ro.product.cpu.abi
echo "$PREFIX"
echo "$TMPDIR"
pacman -V
node -v
npm -v
```

## Bun 门禁
```bash
strings -n 8 <bun-input> | rg '---- Bun! ----'
strings -n 8 <bun-output> | rg 'BUNWRAP1|---- Bun! ----'
"$TMPDIR"/../tmp  # 仅确认 TMPDIR 可写（示意）
```

## 运行最小测试
```bash
bun --version
printf 'console.log("ok")\n' > "$TMPDIR/t.js"
bun "$TMPDIR/t.js"
opencode --version || opencode --help
```

## 错误关键字门禁
- `loader cannot load itself`
- `Cannot find module 'opencode-android-arm64/package.json'`

## 产物门禁
```bash
ls artifacts/bun/deb/*.deb
ls artifacts/bun/pacman/*.pkg.tar.xz
ls artifacts/opencode/deb/*.deb
ls artifacts/opencode/pacman/*.pkg.tar.xz
```
