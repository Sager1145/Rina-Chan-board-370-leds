# 串口按钮模拟现状与验收命令

检查日期：2026-09-12  
检查对象：当前工作树中的 ESP32-S3 固件（包含尚未提交的用户修改）

## 结论

固件已经提供串口按钮模拟命令，因此本次没有修改固件代码。

串口控制台把 `btn <code>` 直接送入与 GPIO、RinaLink `button` 命令共用的
`runButtonAction()`。它适合验证按钮对应的**逻辑动作**和状态变化，但不是 GPIO
电平注入器：一条命令代表一次离散 action，不会生成真实按钮的 press/release
时序。

实现位置：

- `esp32s3_firmware/src/serial_console.cpp`：解析 `btn` 并以 source=`serial` 调用
  `runButtonAction()`。
- `esp32s3_firmware/src/buttons.cpp`：按钮动作、日志、GPIO press/release、组合键和
  自动连发逻辑。
- `esp32s3_firmware/platformio.ini`：当前所有构建环境继承
  `ENABLE_SERIAL_CONSOLE=1`、`ENABLE_SERIAL_UART0_MIRROR=1`。

## 接口与精确命令

控制台是逐行协议；命令以 LF (`\n`) 执行，CR (`\r`) 被忽略。命令名和按钮代码
不区分大小写。当前构建同时从原生 USB CDC `Serial` 与 115200 baud 的
`Serial0` 接收输入，两路有独立的行缓冲；回复和日志会镜像到两路输出。

建议先打开 INFO 日志，然后用 `status` 比较动作前后状态：

```text
log on
log level info
status
btn B1
btn B2
btn B3
btn B4
btn B5
btn B3B1
btn B3B2
status
```

每个成功动作回复：

```text
OK btn <原始输入代码>
```

INFO 日志还会产生一条规范按钮事件；例如：

```text
[<millis> ms] [INFO] [BUTTON] source=serial id=B4 event=action handled=1
```

无效或无法完成的动作回复：

```text
ERR btn invalid
```

并在 INFO 日志中记录 `event=action handled=0`。例如当前的 `btn B6`：

```text
[<millis> ms] [INFO] [BUTTON] source=serial id=B6 event=action handled=0
ERR btn invalid
```

## 动作语义

| 命令 | 逻辑动作 | 状态/边界 |
| --- | --- | --- |
| `btn B1` | 停止固件文字滚动，取消滚动结束后的自动恢复，切到下一张保存表情 | 表情索引循环；没有可用保存表情时返回错误 |
| `btn B2` | 停止固件文字滚动，取消滚动结束后的自动恢复，切到上一张保存表情 | 表情索引循环；没有可用保存表情时返回错误 |
| `btn B3` | 在 manual/auto 间切换，停止文字滚动并恢复当前保存表情 | 模式设置会持久化；若此前显示非表情内容，会先清屏并延迟恢复表情 |
| `btn B4` | 亮度减 8 | 下限 10；更新当前 LED 输出，不写入设置文件 |
| `btn B5` | 亮度加 8 | 上限 200；更新当前 LED 输出，不写入设置文件 |
| `btn B3B1` | 自动换脸间隔减 500 ms | 下限 500 ms；写入运行时设置 |
| `btn B3B2` | 自动换脸间隔加 500 ms | 上限 10000 ms；写入运行时设置 |

`status` 可观察 `mode`、`brightness`、`faceIndex`、`intervalMs` 和
`lastReason`。串口动作写入的原因字符串分别带有 `serial_B1_...`、
`serial_B2_...`、`serial_B3_...`、`serial_B4_...`、`serial_B5_...`、
`serial_B3B1_...` 或 `serial_B3B2_...` 前缀。

## 与真实 GPIO 按键的差异和限制

- 串口 `btn` 只触发一次逻辑 action，不改变 `ButtonRuntime.pressed`，因此没有
  25 ms 消抖，也不会发出 `event=press`、`event=release` 或 `event=repeat`。
- 串口命令没有 hold 时长。真实 GPIO 的 B1/B2 在按住 650 ms 后每 350 ms
  连发；B4/B5 在按住 450 ms 后每 120 ms 连发。要模拟连发，只能重复发送
  `btn` 命令，不能验证固件的按住计时器。
- 组合键无需模拟两个电平，直接发送 `btn B3B1` 或 `btn B3B2`。这会验证组合键
  动作，但不会验证“先按 B3、再按 B1/B2”的检测与 combo-consumed 状态机。
- GPIO 专属按钮反馈动画仅在 source=`gpio` 时启动；source=`serial` 不显示 B3、
  B4、B5、B3B1、B3B2 的 GPIO 反馈 overlay。
- `B6` 不属于 `runButtonAction()` 的逻辑 action 集合。真实 B6 依赖 press/release
  状态：短按显示约 2 秒的单次电池 overlay，按住 700 ms 触发持续电池详情，松开
  后结束。因此 `btn B6` 当前会返回 `ERR btn invalid`；帮助文本中的
  `btn <B1..B6>` 对 B6 过度承诺。
- 控制台没有 `btn down` / `btn up` 形式，不能通过 serial 验证 B6 长短按、GPIO
  消抖、物理组合键判定或硬件引脚本身。
- 单行缓冲上限为 192 bytes；超长行会清空当前输入缓冲。正常 `btn` 命令远低于
  此限制。

## 静态验收记录

本结论来自源码只读追踪：`serial_console.cpp` → `runButtonAction(...,
"serial")` → `buttons.cpp` 的统一动作分派。此次没有刷写固件、打开串口或操作硬件，
也没有改动现有固件文件。动态 LED、GPIO 时序和 B6 长短按仍需由硬件验收覆盖。
