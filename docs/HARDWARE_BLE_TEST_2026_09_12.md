# 2026-09-12 BLE 真机测试记录

## 设备与构建

- iPhone 13 mini「艱難困苦」。
- Xcode Beta 27.0，build 27A5237l；RinaBoard Debug 真机编译、安装和启动成功。
- ESP32-S3，8 MB flash / 8 MB PSRAM，PlatformIO `esp32s3-rmt-dma`。
- USB UART：`/dev/cu.usbmodem5AE70745091`，115200，USB VID:PID `1A86:55D3`。
- 最终 upload 构建后固件 app SHA-256：`7848f228413d35354265a77cb21b7a6572ce3bd3bbeda2f611608c49408ca5aa`。

## 已验证

1. 首次串口读取显示旧固件循环报 `invalid segment length 0xffffffff`、`No bootable app partitions`。通过 PlatformIO upload 重新写入引导、分区和应用后，板子正常进入 `stage=ready`。
2. 板端名称为 `RinaBoard-80B54EF48E09`，来自完整 Bluetooth MAC。广播日志确认 `uuidSet=1 nameSet=1 advSet=1 scanRspSet=1 advertising=1`。服务 UUID 放主广播，完整名称放 scan response。
3. 新增 UART0 控制台输入可正常响应 `status`。原生 USB 和 UART0 使用独立输入缓冲区。
4. 串口修改亮度 50 → 42 → 50，逐次查询得到对应值；最终恢复 50。板端 `ledReady=1 refreshFail=0`。这验证 UART 和板端状态，不能代替手机 BLE 联动或肉眼观察 LED。
5. Xcode Beta 下 RinaCore 136 项测试通过，0 failures。
6. App 连接页增加名称／设备编号筛选，保留按 RinaLink 服务过滤和点击指定设备连接；设备身份使用 CoreBluetooth UUID，显示名称不作为唯一标识。

默认板名具有硬件独立性；用户自定义名称仍可能重名，列表同时显示设备编号以便区分。当前只有一块 ESP32 的硬件证据，未进行多板同时扫描验证。

## 本次补充修复

- BLE INFO 使用 JSON 序列化，正确处理名称中的引号与反斜杠。
- 固件按当前连接 handle 处理 MTU、RX 和分片发送状态。
- App 使用 INFO 名称优先于缓存名称，并要求通知真正启用后才完成连接。
- 串口状态输出有效名称、默认名称和是否自定义。

## 未完成与阻塞

Device Hub 的电脑操控 `cua.getApp` 持续返回 `-10005 timeoutReached`。已尝试退出重开、重置操控会话，以及由用户关闭镜像只保留设备列表，仍然失败。用户确认 Device Hub 本身可以手动操作，因此不能把这个错误解释为手机或 BLE 故障。

尚未验证：真机 App 扫描结果、筛选交互、点击 BLE 连接、断开重连、App 表情／颜色／亮度到 LED 的联动、多板选择。Device Hub 放大也未完成。用户后续明确要求不使用 Claude，已停止操作 Claude。

启动日志另有 ADC 初始化和缺少 core dump 分区提示；本轮未诊断这两项，未将它们算作 BLE 测试失败。

## 本机原始日志

- `/private/tmp/rinaboard-device-build.log`
- `/private/tmp/rina-core-tests.log`
- `/private/tmp/rinaboard-firmware-upload-final.log`
- `/private/tmp/rinaboard-uart-validation.log`

临时目录日志可能由系统清理；本记录保留关键结果。
