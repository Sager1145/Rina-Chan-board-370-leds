# Isolated LED Assets — Bundled Layout

此版本把大量小型 LED 资源文件合并为按类别拆分的 bundle 文件，减少文件系统目录项与打开/关闭文件开销，同时保持单个 bundle 默认不超过 32 KB。

## 读取规则

1. 先读取 `resources/bundles/<category>_index_manifest.json`。
2. 按需读取对应的 `*_index_XX.json`，找到逻辑路径对应的 `bundle` / `offset` / `length`。
3. 用二进制方式打开 bundle，`seek(offset)` 后读取 `length` 字节。
4. 校验 `sha1` 可在打包阶段或调试模式执行，运行热路径可关闭。

## 保留独立文件

- `resources/music/*.rnt` 与 `resources/video/*.rnt` 仍保持独立文件，便于按行流式播放。
- `resources/database/*.json` 保留为 compact database；`timeline_index.json` 已拆分为多个 `timeline_index_<kind>_XX.json`。

## 目标

- 减少 900+ 个资源文件带来的文件系统开销。
- 避免单个超大 JSON 导致解析卡顿。
- 保持 voice / face module / font / icon / color 的按需加载能力。
