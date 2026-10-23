# UPX 与 Bun 可执行文件（compressed 族说明）

> 状态：active ｜ 适用版本：v1 1.18.x / v2 2.0.x–2.1.x

UPX 与 Bun 产物标记的兼容问题曾让 compressed 族一度被判死；该结论已推翻——**现行 v1/v2 compressed 族可用**（v2 需 stub memfd 补丁，见 `history/ops-lessons-rc3.md` §11–§12）。本文保留机制说明与决策依据。

## 历史误判（勿再引用旧结论）

早期 `upx --best` 直接作用于 loader 包装件会报：

```text
$ upx --best opencode-termux
error: no embedded Bun runtime (missing BUNWRAP1)
```

原因：Bun `--compile` 产物用 `---- Bun! ----` 标记定位嵌入数据，loader 包装再叠加 `BUNWRAP1` 元数据；UPX 会破坏这些标记的位置与结构。

## 现行结论

| 方案 | 效果 | 现状 |
|---|---|---|
| `strip` | 减少 10–30% | ✅ 构建时执行 |
| `zstd -19` 分发压缩 | 减少 60–70% | ✅ 仅用于打包分发 |
| UPX | 减少 50–70% | ✅ v1/v2 compressed 族可用（v2 需 stub memfd 补丁） |

## 相关

- 契约与族名治理：`packaging/compressed-line.md`
- Bun 可执行结构：`build/bun-executable-structure.md`
- 终谳记录：`history/ops-lessons-rc3.md` §11–§12
