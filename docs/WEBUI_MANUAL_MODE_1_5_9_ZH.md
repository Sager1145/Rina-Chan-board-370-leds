# WebUI Manual Control Mode 1.5.9

## 变更

- 新增 `manual_control_mode` 运行状态。
- 通过网络/WebUI 操控时自动退出手动控制模式。
- 按实体按钮时自动进入手动控制模式，并停止 WebUI 运行时动画。
- WebUI 首页新增“手动控制模式”卡片，可启动/退出/读取状态。
- `requestState` 增加 `manual_control_mode` 和 `control_mode` 字段。

## 新增文本协议

```text
requestManualMode
requestControlMode
manualMode|1
manualMode|0
manualMode|toggle
manualControlMode|1
manualControlMode|0
```

## 模式规则

```text
实体按钮按下 -> manual_control_mode = true
普通网络/WebUI 控制 -> manual_control_mode = false
WebUI 首页手动控制按钮 -> 可显式进入/退出 manual_control_mode
```
