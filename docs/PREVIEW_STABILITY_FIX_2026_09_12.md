# 所有通信入口与工作模式：快速切换／即时预览稳定性修复

范围为当前发布的 `esp32s3_firmware` 和 `ios`。`legacy`、`esp32s3_firmware_old` 与 zip 备份不参与当前固件构建。下列结果是代码审查、主机故障注入及服务测试结果；后续已完成开发板刷写及启动检查（见下节）；尚不能当作所有模式长时间压力测试通过的结论。

## 通信入口覆盖

| 入口 | 修复／审查内容 | 验证 |
| --- | --- | --- |
| BLE RinaLink | 串行完整包发送、拥塞重试、首字节前取消、部分包失败后关闭该流；禁止事件发送生成无限 EV_LOG 反馈 | 1,000 帧拥塞测试、部分包／断线／计时回绕 |
| 家庭 Wi-Fi TCP | 固件以 `MSG_DONTWAIT` 真正非阻塞发送，整帧期限 250 ms；部分事件不能直接丢弃 | 短写、持续微量进展、拥塞、断线等 9 个场景 |
| 板载热点／直连 TCP | 使用与家庭 Wi-Fi 相同的 TCP 实现；App 端有界队列、发送完成许可、5 秒写期限与 15 秒连接期限 | TCP 队列取消与关闭顺序；三载体模拟矩阵 |
| USB CDC／UART0 | 独立接收缓冲，每端口每轮 64 字节；超长命令整行丢弃；输出每端口 2 KB 有界队列、每次最多泵 128 字节，日志预留控制台响应空间 | 连续命令、行溢出恢复、双端口、发送容量／保留空间 |
| HTTP／DNS 配网 | 仅提供网络配置，不接收表情帧；维持现有 HTTP 有界等待和主循环实现 | 入口审查，未进行 HTTP 硬件负载测试 |

**TCP 确定缺陷**：锁定的 Arduino 3.3.9 `NetworkClient` 未覆盖 `Print::availableForWrite()`，该函数默认返回 0。原固件据此永远认为 TCP 不可写；直接调用 `NetworkClient::write()` 又可能在其内部多次等待 1 秒，绕过外层期限。现在直接使用 socket 的非阻塞发送。

BLE/TCP 共用接收器现在每次只取出一帧，未完成或未轮到处理的帧保留缓冲占用，避免旧实现整块取出后允许新数据占满、再回填旧数据造成溢出。新连接在首次主循环前收到的数据也会保留。测试以 1,000 个混合消息模拟分片、粘包及处理期间继续接收，覆盖最大长度帧。

## 工作模式覆盖

| 模式／操作 | 共同保证 |
| --- | --- |
| 手动表情：面板、本机、自定义绘制、部件组合、即时预览 | 新输出取消旧请求和未提交发送，待显示队列仅保留最新帧；共享接管入口取消 auto、旧滚动、延迟恢复和旧上传，不插入多余空白帧 |
| 自动轮播 | 切换后旧生产者失效；固件 auto 不在滚动／延迟恢复期间抢播 |
| 文字：上传、开始、暂停、继续、逐帧、停止 | Scroll→Frame 锁顺序下原子提交；旧 tick 不会在新表情后回写。上传 generation 防止旧数据继续写入或提交 |
| 口型同步、演出 | 经同一输出会话和 SET_FRAME 接管路径发送；模式失效立即取消旧输出 |
| 调试输出 | 直接帧／命令同样参与输出会话撤销，不绕过共用队列 |
| 按键、电池覆盖层 | 新表情清除延迟恢复；覆盖层结束保留用户暂停，不能启动仅上传但尚未播放的文字 |

App 在公共发送边界注册输出任务，覆盖直接 `setFrame` 和带输出上下文的命令／上传。TCP 已提交帧的任务取消后仍占用发送许可，直到实际 `contentProcessed` 或期限到达后关闭原连接；不会因快速取消不断追加旧包。

Raw scroll、scroll bitmap、faces 上传取消／失败后，在释放 App 上传队列前完成 `BLOB_ABORT`。清理不继承旧输出会话的取消状态，并检查连接代次；未确认 abort 时关闭原载体。固件撤销过期滚动所有权，并在闲置 30 秒后回收遗留上传。Blob 提交必须满足声明长度；失效 generation 不得提交。Faces 存储上传不因普通显示切换被固件撤销。

所有显示路径共用 LED 驱动：RMT 提交不再无限等待；传输等待失败时停止、回收、重置并恢复。恢复失败时冻结发送缓冲并停止继续提交。渲染失败不会发布成功呈现的遥测。

## 验证结果与复跑

- 固件：Adafruit (`esp32s3`)、RMT (`esp32s3-rmt`)、RMT DMA (`esp32s3-rmt-dma`) 三个环境构建通过；最后整合后的增量构建结果见本机 `/tmp/rina-all-transports-final-build.log`。
- Host：BLE、流接收／TCP、跨载体 blob 所有权、播放竞态／100 帧合并／100 次无空白接管、RMT 恢复、串口调度故障注入均通过。
- App 服务：15 项回归通过，包含六种 `BoardOutputSource` × BLE/LAN/hotspot 模拟载体、三类 Blob 中途取消、丢失 BEGIN 回复后的 ABORT 顺序、TCP 40 次排队取消和超时关闭顺序。用隔离 macOS Swift package 编译当前服务源文件，日志 `/tmp/rina-mode-service-tests.log`。
- 完整 iOS simulator 定向测试：未执行成功。最新一次构建被 `LEDBoardPreview.swift` 的 `@Environment(\.ledBoardPaintingSuspended)` 泛型／key path 类型推断错误阻塞，日志 `/tmp/rina-ios-all-modes-tests.log`。本轮未修改该 UI。上一轮全量 acceptance 的 6 处失败也未在本轮处理。
- `git diff --check` 通过。

从仓库根目录复跑主机测试：

```sh
c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src esp32s3_firmware/test/host/ble_frame_sender_test.cpp -o /tmp/rina-ble-test
/tmp/rina-ble-test
c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src esp32s3_firmware/test/host/stream_transport_test.cpp -o /tmp/rina-stream-test
/tmp/rina-stream-test
python3 esp32s3_firmware/test/host/blob_ownership_test.py
python3 esp32s3_firmware/test/host/playback_ownership_test.py
python3 esp32s3_firmware/test/host/rmt_recovery_test.py
python3 esp32s3_firmware/test/host/serial_network_scheduling_test.py
cd esp32s3_firmware
/Users/sager/.platformio/penv/bin/pio run -e esp32s3 -e esp32s3-rmt -e esp32s3-rmt-dma
```

## 后续真机刷写与启动检查

用户连接 ESP32 后，已通过 `/dev/cu.usbmodem5AE70745091` 刷入 `esp32s3-rmt-dma` 固件，PlatformIO upload 成功，esptool 报告 `Hash of data verified`，随后执行硬复位。

串口确认：

- `event=boot stage=ready faces=12 mode=auto`。
- `ledBackend=rmt-dma dma=1 ledReady=1 refreshFail=0`，刷新耗时约 11.05 ms。
- 自动表情正常切换，TCP 在 5370 端口监听。
- 板名 `RinaBoard-80B54EF48E09` 正常广播；观察到手机 BLE 连接，MTU 更新为 255，并收到 subscribe 命令。

此为刷写及短时启动检查，尚未完成下面的跨协议／全模式压力验收。启动另有 ADC 配置、未配置 NVS 项和 core dump 分区提示，本次没有把这些诊断项作为已修复内容。

本机原始日志：`/tmp/rina-stability-firmware-upload.log`、`/tmp/rina-stability-post-flash.log`。

## 真机验收待办

1. 更新 App 与固件，分别以 BLE、家庭 Wi-Fi、热点连接；每种连接连续切换表情、绘制／清空／全亮至少 60 秒。
2. 逐一在手动、自动、文字、口型、演出、调试之间切换；文字上传期间切换模式，暂停期间启停电池覆盖层。
3. 同时发送 USB／UART 连续命令，检查最后一次选择最终生效、状态查询仍响应、uptime 连续增长，无 panic/watchdog/reboot。
4. 断线或模拟背压后重连，确认完整帧解析、下一次上传可开始，记录 `refreshFail`、`tx_recovery`、溢出与断线原因。
