# RinaBoard 压力测试 Prompt

基于 2026-09-12 当前工作区的通信、播放与测试代码整理。本文件是测试执行指令，本次编写没有实际运行压力负载，也没有修改产品代码。固件分析期间运行了 2 个 C++ 和 5 个 Python host 基线程序，均通过；这些局部测试不代表真机压测通过。复制下方全文给执行测试的代码代理即可；执行时应重新核对代码，不能沿用历史测试结论。

---

你是负责 RinaBoard 稳定性验证的工程师。请分析当前工作区，编写并运行有明确断言、资源上限和复现方法的压力测试，找出通信拥塞、播放竞争、资源耗尽及故障恢复问题。输出实际证据，不要只给测试建议，也不要把构建成功或 mock 通过当作真机通过。

## 1. 范围与版本

- 仓库：`/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds`。
- 主要对象：`esp32s3_firmware/src`、`ios/Packages/RinaCore`、`ios/RinaBoard/Services`，以及文字、口型、演出、视频的播放模型。
- 先读取适用的 AGENTS.md 和技能，记录 HEAD、工作区差异、被测源码 SHA-256、工具链、构建配置和设备身份。以包含未提交修改的当前源码为准。
- 工作区可能有其他任务修改。发现漂移时，在包含当前修改的隔离副本继续测试，记录快照；不能只 checkout HEAD，也不能覆盖、重置或提交用户现有改动。
- `esp32s3_firmware_old`、`legacy` 和根目录旧预览不是当前主测试对象。`tools/protocol_selftest.py` 指向 `pico_firmware/rina_protocol.py`，先检查目标是否存在；它不能代替原生 ESP32-S3 的 RinaLink 测试。
- 历史 `docs/acceptance-20260912-a1/REPORT.md` 和 BLE 测试记录只作背景；其中失败或通过均需针对当前版本重新验证。

## 2. 先从代码核实约束

下面是编写本 prompt 时的值；若源码不同，以源码为准并报告差异：

| 对象 | 当前约束及代码入口 |
| --- | --- |
| RinaLink | magic 0xA5，6 字节头，小端长度，单包 payload ≤4096；`inbound_frame.h`、`RinaLinkCodec.swift` |
| 画面 | 370 LED，packed frame 47 字节；`config.h`、`PackedFrame.swift` |
| TCP | 端口 5370；连接与空闲策略读取 `transport_tcp.cpp`、`config.h` |
| 接收 | 每客户端缓冲 4166 字节，每轮最多分发 8 帧；`inbound_frame.h`、`protocol.cpp` |
| iOS 限流 | frame 间隔 20 ms、等待深度 6；command 间隔 120 ms、深度 4；blob 深度 4；output 深度 64；拥塞丢弃最旧的未开始任务 |
| iOS 底层发送 | TCP 等待深度 32；BLE 等待深度 255；不能把各队列容量简单相加作为吞吐能力 |
| 序号 | 1…255，默认请求超时 5 s，超时/取消序号隔离 2 s；`BoardConnection.swift` |
| 滚动 | 最多 3072 帧，文本最多 4096 UTF-8 字节，界面 FPS 1…60；packed 帧流与固件内部滚动的时序约束分别核实 |
| 固件 packed 队列 | 配置数组深度 3，但 `led_renderer.cpp` 拥塞路径只保留 1 个最新 pending 帧；最小间隔 33 ms（约 30.3 帧/s）。与 iOS 的 20 ms 生产间隔分开统计 |
| 素材 | 最多 128 表情，faces BLOB 上限 256 KiB；核实各种 BLOB 类型的长度、分片及提交约束 |
| 默认构建 | PlatformIO `esp32s3-rmt-dma`；控制面 Core 0、LED 渲染 Core 1 |

画出简短的数据流：功能生产者 → 播放 session → 发送队列 → TCP/BLE → 固件解析/调度 → 帧队列或滚动时间线 → LED，并标明丢弃、取消、超时和状态回传的位置。

## 3. 先建立可复现基线

在隔离输出目录运行现有测试，保留退出码及实际执行数量。环境错误、编译错误、断言失败要分开记录。

```sh
swift test --package-path ios/Packages/RinaCore

c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src esp32s3_firmware/test/host/stream_transport_test.cpp -o /tmp/rina-stress-stream-test
/tmp/rina-stress-stream-test

c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src esp32s3_firmware/test/host/ble_frame_sender_test.cpp -o /tmp/rina-stress-ble-test
/tmp/rina-stress-ble-test
```

检查并逐个运行 `esp32s3_firmware/test/host/` 下的 Python 测试，包括 ownership、presentation telemetry、RMT recovery、serial/network scheduling。它们部分使用抽取的生产函数和缩小的假环境，只能证明相应局部逻辑，不能证明完整固件运行正确。

通过 `xcodebuild -showdestinations` 发现实际可用模拟器，再运行 RinaBoard scheme 的 App 和 UI 测试；不要硬编码历史设备 UUID。重点复用 `BoardConnectionOutputTests`、`BoardPlaybackCoordinatorTests`、`TextTransportTests`、`LipSyncLifecycleTests` 的可控 transport 和时序设施。

固件可执行 `pio run -d esp32s3_firmware -e esp32s3-rmt-dma` 做构建验证；构建不意味着刷写或真机测试完成。没有设备时继续完成所有主机测试，真机项标为 BLOCKED。

## 4. 按优先级实现压力场景

### P0：序号耗尽、迟到响应和内存积压

1. 使用快速接收写入但可扣留应答的 fake transport，并发发送非输出类请求，例如 PING；分别制造 254、255、256、512 个未完成请求。不要让 frame/command 限流掩盖 pending 序号耗尽。
2. 重点检查 `nextSequenceNumber()`：遍历 255 次后是否仍返回已占用序号，随后 `pending[seq]` 是否覆盖旧 continuation。断言每个调用最终且仅完成一次，忙时应明确拒绝或背压；不得悬挂、错误匹配或遗失 continuation。设置测试进程级 watchdog，不能无限等待已泄漏任务。
3. 注入请求超时与取消，在隔离窗口前后分别发送旧响应；使序号多次回绕，验证旧响应不能完成新请求。覆盖旧连接结束、新连接建立、相同 seq/type 的跨代响应。
4. 对一个支持 MORE 聚合的请求连续发送合法大小分片但不发终止帧；测量 `PendingRequest.accumulated` 增长及超时后释放。分开验证 GET_FACES 的 MORE 分页语义。
5. 创建慢速/暂停消费的事件订阅者，持续输入日志、preview、status；测量 AsyncStream 缓冲、RSS 和取消订阅后的回落。
6. 第 4、5 项使用假数据和独立进程，从总计 1、4、16 MiB 阶梯注入，设 64 MiB 注入上限和进程内存停止阈值；目标是验证增长规律和恢复，不是耗尽整台机器。

这些是静态分析提出的优先假设。请用可复现测试决定是否为缺陷，不要预先宣告已发生崩溃或泄漏。

### P1：拥塞、分包与多客户端公平性

- iOS 生产端帧请求采用 10、25、50、75、100 次/s；命令采用 2、5、8、12、20 次/s。每档预热 10 s、采样 60 s，档间排空队列并恢复基线。
- 分别测试真实 App 队列路径和绕过 App 限流的固件协议路径。帧、命令、请求 ACK、实际呈现四种速率分别计数，不得混用。
- TCP 按实际支持的连接数测试，加入额外连接验证拒绝或隔离；再测试 TCP 与 BLE 同时工作。一条连接慢读/停读，另一条发送 PING，验证公平性和主循环响应。
- 任意位置拆包（含逐字节）、多个包粘连、错误 magic、长度 0/4095/4096/4097/65535、截断后接合法包、未知类型。畸形输入由原始字节构造，不要用合法编码器的 precondition 使测试工具自身崩溃。
- 47 字节帧增加 46/48 字节反例。分别断言可恢复输入的重新同步、不可恢复输入的明确拒绝/断连以及重连后的可用性。
- 注入短写、零写、暂不可写、写出一部分后断线；在代码规定发送期限的前后取边界值（当前发送器以 250 ms 为关键边界）。验证已发出的帧片段不会与后续帧混接。
- BLE 根据协商值测试分片；host fake 至少覆盖 20 字节 ATT payload 及较大 payload、notify 拥塞和 mid-frame 断开。真机只报告实际协商到的值。
- 每轮停止负载后发一个有唯一标记的最终帧，核查队列最终输出是否收敛到它；预期 drop-oldest 单列，不计为协议错误。
- 固件 packed 路径断言仅保留最新 pending，不能按配置数组深度 3 误写 FIFO 断言。压测实际 dropped、queueCount 和最终输出。
- 对 preview/status event 制造一次零字节发送失败，随后保持画面/状态不再变化并解除拥塞。检查 `serviceProtocolEvents()` 是否已提前推进 lastPreviewSeq/lastStatusVersion，导致最终状态不再推送；另测主动查询能否恢复。区分“允许丢弃中间事件”和“最终状态永久不收敛”。

### P1：播放所有权与 BLOB 事务竞争

- 枚举 `BoardOutputSource` 当前全部来源，覆盖每两个不同来源之间的有向切换，并测试同来源重启。当前有 7 个来源，理论有 42 个跨来源方向；前置条件不足的方向单独记录。
- 每个方向至少 100 次可控时序循环，分别在排队中、写入中、等待 ACK、ACK 即将返回时接管/取消；旧生产者不得在新 session 建立后发送新数据或改写当前画面。
- 同时覆盖直接 SET_FRAME、固件自动播放、文字、口型、演出和视频；验证文本暂停/seek/变速与其他来源接管，以及已暂停状态重连后不会自行前进。
- BLOB 的 begin/chunk/end/abort 各阶段注入取消、断开、重复分片、缺失分片、乱序、长度不匹配、总长度越界；验证事务所有者、旧上传取消和新上传之间的顺序。
- 验证 BLOB 30 s 无活动回收边界，以及滚动 generation 变化后的事务失效；分别在期限前后尝试续传，检查暂存资源和全局上传所有权是否释放。
- 一个客户端上传时另一个客户端提交/abort；检查所有权隔离和失败后旧素材/旧时间线是否仍完整。用哈希验证内容，不只看 ok 响应。
- raw scroll 当前在 BLOB_BEGIN 就重置时间线，bitmap 在 END 才替换：分别验证中断影响，并依据协议判定其是否满足预期原子性，不能假设两种上传都自动回滚。faces 可由不同客户端各自上传，测试并发暂存及 END 的 JSON 解码/写盘内存峰值；真机写盘仅用小批次测试素材。
- 验证超时、失败、取消都释放锁、buffer、播放 lease 和发送许可，不留下后续请求永久阻塞。

### P2：数据边界、恢复与持续运行

- 滚动帧数：0、1、3071、3072、3073；文本按 UTF-8 字节测试 4095/4096/4097，包含中文、日文、emoji、组合字符。表情数测试 127/128/129，faces BLOB 测试上限附近。
- 非法帧、JSON 截断、非法字段和失败写入应返回可解释结果；原有效文件哈希保持不变。持久化边界先用临时目录/隔离文件系统验证。
- 重连 100 轮；模拟器/fake 中覆盖连接途中取消、快速切换设备、旧事件晚到、前后台切换、订阅恢复和音频中断。真机验证真实 BLE/Wi-Fi、麦克风与权限生命周期，不能用 fake 代替。
- 主机混合负载持续 30 min；真机可用时运行 60 min，将文字播放、packed 帧、低频状态查询和故障恢复按固定种子编排。持续高负载不要包含高频 flash 保存操作。
- 停止注入后观察至少 60 s，测量资源回落和最慢恢复时间。
- 固件 RMT/DMA 故障恢复优先使用现有 host 注入；真实电气故障不作默认步骤。真机维持原亮度或较低亮度，仅操作确认身份的测试板，不扫描无关设备、不清空用户库、不恢复出厂设置。
- 真机额外覆盖 17 ms 固件滚动与 TCP/BLE 并发，测量 RMT refresh 最大耗时和故障后的输出恢复。滚动逾期路径每 tick 只前进一帧、超出漂移阈值会重置时钟，因此要测实际播放速度与时间线偏移，不能仅按索引单调就判断时序通过。

## 5. 指标与判定

为每个 case 定义负载、前置状态、输入种子、预期状态、截止时间和复原步骤。

- 客户端：offered/sent/completed/dropped/cancelled/timeout，排队延迟与 RTT 的 p50/p95/p99/max，未完成任务数，进程 RSS/CPU、事件订阅数和资源恢复趋势。
- 固件：accepted/queued/dropped、heapFree/largestBlock、可用 PSRAM 指标、refreshUs/refreshMaxUs/refreshFail、重启及 watchdog 证据、实际渲染间隔。先核实计数器含义和已有观测入口，缺失指标写 unavailable；需要时只添加最小测试观测点。
- UI/物理输出：主线程停顿、切换响应、预览与 LED 的对应关系。只有拿到同步时间标记与物理录像/测量，才报告实体显示时延；ACK 或逻辑渲染记录不等于 LED 已显示。
- 硬性不变量：无请求串线、无重复 continuation resume、无永久悬挂、无越界、无死锁、无旧 session 覆盖新输出、无失败事务破坏原数据、无未预期重启。
- 超载允许按代码策略丢弃；必须分类并证明降载后恢复。受控断线、故意超时、主动取消不直接计为产品失败。
- 正常负载建议门槛：非注入请求错误率 0；负载停止后在合理截止时间内恢复正常请求。截止时间由超时、退避、排队上限推导，不凭空规定所有请求必须 100 ms 内完成。
- 对内存给出预热后曲线、每轮增长和冷却后残留。持续增长要用重复周期及对象/分配证据确认，不能把一次峰值或缓存直接叫作泄漏。
- 吞吐和延迟没有既定 SLA 时，先报告基线、拐点和退化幅度，再给明确标为“建议”的验收阈值，不伪装成项目原有要求。

## 6. 交付与完成标准

在 `docs/stress-<实际时间戳>/` 输出：

1. `REPORT.md`：被测版本、实际范围、主要发现、容量拐点和未测项目。
2. `CASES.csv`：case_id、层级、负载、状态 PASS/FAIL/BLOCKED/NOT_RUN、指标及证据路径。
3. `RUNBOOK.md`：环境、依赖、所有命令、种子、截止时间、设备信息和清理/恢复方法。
4. 原始日志、指标 CSV/JSON、测试结果包和源码散列；不要仅保留文字结论。
5. 每个已复现缺陷给出最小复现、准确源码位置、预期/实际、影响、最小修复建议；将静态疑点另列为待验证。

可以新增必要的测试和故障注入工具；本任务先保留产品缺陷现场，不进行顺带重构或自动修复产品代码。没有真机也必须完成可执行的 host/mock 测试，并提供具体真机步骤及阻塞原因。禁止用历史报告补充当前通过数，禁止把不同轮次的重复测试相加充当独立覆盖数。
