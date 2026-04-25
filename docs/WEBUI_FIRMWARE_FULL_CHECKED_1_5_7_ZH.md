# WebUI Firmware Full Checked 1.5.7

本版本是在 1.5.6 基础上做整套代码检查后的修正版。

## 修复

- 修复 Pico 内部绘制保存表情时调用 `update_physical_face_hex()` 的通知路径问题。
- 之前内部按钮切换 / 自动循环 / 恢复当前表情时，可能被当作外部网络控制，从而触发 `on_network_control()` 并关闭自动循环。
- 现在内部绘制使用 `notify=False`。
- WebUI / 网络命令 `selectFace370|index` 仍然会显式停止 auto，避免用户点击载入后继续自动跳到下一个表情。

## 检查

- Python 语法检查通过。
- WebUI 外部 JS 语法检查通过。
- index.html 内联脚本语法检查通过。
- protocol_selftest 通过。
- WebUI gzip 解压一致性通过。
- web_app_gz.h 字节数与 gzip 文件一致。
- CPython 硬件 stub 集成测试通过。
