# v1.5.11 内存修复版

修复 Pico 启动时报错：

```text
MemoryError: memory allocation failed, allocating 3134 bytes
```

改动：

- 调整 `main.py` 导入顺序：先导入/编译 `rina_protocol.py`，再导入较大的显示辅助模块。
- 在关键导入之间执行 `gc.collect()`。
- no-demo 构建不再导入 `matrix_demos.py`。
- 正常启动路径不再导入 `demo_faces.py`，保存表情以 `saved_faces_370.py` 为唯一来源。
- 保留 v1.5.10 的 `.zfill()` 修复和手动控制模式。

成功启动后版本应为：

```text
Firmware version: 1.5.11-pico-webui-memory-fix
```
