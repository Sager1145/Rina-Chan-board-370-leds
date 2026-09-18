# RinaBoard 全局调试面板 + 协议级虚拟 ESP32 实施方案

编写于 2026-09-17，依据 `main` 的 HEAD `3651343`（工作区另有未提交修改，见文末「核对方式」）。

本文是对同名外部方案的**修订与补全版**。原方案的协议事实基本准确（见 §1 核对表），但它没有读 `ios/Packages/` 和 `esp32s3_firmware/test/host/`，因此**低估了仓库已有的基础设施**，并由此给出了一个成本明显偏高的实施顺序。本文保留原方案正确的架构主张，修正事实偏差，并按仓库现状重排实施顺序。

源码与本文不一致时以源码为准，并在报告里写明差异。

---

## 0. 目标与验收原则

**核心验收标准：不连接真实 ESP32，也能完整操作 App，并观察每项功能在「设备端」产生的实际结果。**

四种运行方式：

| 模式 | App 如何运行 | 通信另一端 | 主要用途 |
|---|---|---|---|
| **虚拟设备模式** | 原有全部页面、业务逻辑照常运行 | App 内的虚拟 ESP32 | 日常开发、离线测试、故障注入 |
| **外部固件模拟模式** | 真实 TCP 连接 | Mac 上独立进程 | App 退出/重启/后台恢复时设备仍在运行 |
| **真实设备观察模式** | 正常连接真实板子 | 真实 ESP32 | 捕获真实通信、硬件联调 |
| **录制回放模式** | 录制的输入、时序与素材 | 虚拟设备或回放端点 | 复现问题，形成回归测试 |

**必须区分两件事**：全部软件功能可通过模拟依赖来测试；真实蓝牙射频、系统授权弹窗、Wi-Fi 实际入网、ADC 电气精度和灯珠物理输出，需要对应的真机测试。报告必须标注覆盖层级，不能把「虚拟设备通过」写成「真实硬件通过」。

**绝对禁止的实现方式**（原方案此点正确，保留）：

```swift
if debugMode {
    connectionState = .connected
    currentFrame = editor.frame
    return success
}
```

这只能证明「界面能变」，无法测试编码错误、上传错误、设备拒绝、响应丢失、输出被抢占和预览不同步。

---

## 1. 对原方案的事实核对

### 1.1 已核实成立

| 断言 | 证据 |
|---|---|
| 13 种请求类型，且就是原方案列的那 13 个 | `RinaLinkMessageType.swift` 0x01–0x06、0x10–0x11、0x20–0x24 |
| 40 条 CMD，列表逐条正确 | `protocol.cpp` 分派 40 个名字；`RinaCommand.swift` 也是 40 个；两边集合完全一致 |
| 6 个 `EV_*`（0x90–0x95）+ `ERR`（0xFF） | `RinaLinkMessageType.swift` |
| `0xA5` / 6 字节头 / 小端长度 / 4096 payload | `RinaLinkFrameConstants` |
| 47 字节 / 370 位 / 末字节高 6 位必须为 0 | `PackedFrame.swift:5,7,8,95` |
| 3072 帧 / 128 表情 / 256 KiB 表情文档 | `RinaLinkConstants.swift`；`config.h:136` |
| 设备名是 UTF-8 **字节**预算（24） | `RinaLinkConstants.maxDeviceNameBytes` |
| 回复类型与事件类型重叠 | `SET_FRAME\|0x80 = 0x90 = EV_PREVIEW_SYNC`；`GET_FRAME\|0x80 = 0x91 = EV_STATUS` |
| `RinaTransport` 刻意不声明 `Sendable`，不应硬加 `@unchecked` | `RinaTransport.swift` 注释写明：`BLETransport` 是 `@MainActor` 隔离的 |
| `simAdcRaw`/`simAdcRef` 只是本地显示计算 | `DebugViewModel.swift:242-244`，`simADCVoltage` 是纯计算属性，不发命令 |
| `protocol.cpp` 无法独立编译 | 2331 行，includes `ArduinoJson`/`LittleFS`/`esp_heap_caps`/`esp_timer`/`freertos/task` |
| 上传有 3 种 kind | `scroll` / `scroll_bitmap` / `faces` |

### 1.2 需要修正

**(a) 「`BoardSessionStore` 无注入点」——结论对，理由错。**

`BoardSessionStore.init(scanner: BLETransport? = nil)` 已经有注入参数，但类型是**具体类**而非协议，塞不进虚拟扫描器。真正完全没有注入口的是 `BoardSession` 第 13 行的 `public let bleTransport = BLETransport()`。P0 要改的是这两处的**类型**，不是「新增注入口」。

**(b) 「4096 是编码后 payload 限制，不只是文本长度」——两个限制都存在。**

`RinaLinkConstants.maxScrollTextBytes = 4096`（文本字节）与 `RinaLinkFrameConstants.maxPayloadBytes = 4096`（帧 payload）是**两个独立约束，恰好数值相同**。虚拟板必须分别强制执行，不能合并成一条检查——否则一个超长文本被分块上传时会漏检。

**(c) 「需要可注入时钟」——部分已存在。**

`BoardConnection` 的重连退避已经是可注入闭包：`private var reconnectDelay: (Int) -> TimeInterval`（第 122 行）。P0 的时钟工作是把这个既有做法推广，不是从零引入。

**(d) 路径：** 固件是 `esp32s3_firmware/src/protocol.cpp`，不是 `firmware/src/`。

### 1.3 原方案漏掉的既有资产（本文最主要的补充）

**① `ios/Packages/RinaCore` 已经是一个平台无关的协议核心。**

25 个源文件 + 32 个测试文件，已包含：

```text
RinaLinkCodec.swift        RinaLinkEncoder / RinaLinkDecoder.feed(_:) -> [RinaLinkFrame]（流式字节解码）
RinaLinkMessageType.swift  13 请求 + 6 事件 + ERR，replyType = type | 0x80
RinaLinkConstants.swift    全部数值边界
RinaCommand.swift          40 条 CMD 的类型化编码
PackedFrame.swift          47 字节 / 370 位 / hex·int 数组·base64 三种文本形式
FaceDocument.swift         表情库文档模型
ScrollRasterizer.swift     文字栅格化
ScrollPreviewController.swift
VideoFrameQuantizer.swift  LipSyncDSPEngine.swift
```

并且 `Package.swift` 声明 `.macOS(.v14)`。

**这一条改变实施顺序。** 原方案 §5.1 把「抽 C++ FirmwareCore + C 桥接」列为最终推荐，把 Swift 行为模拟器降格为过渡手段。按仓库现状这是反的：

- 协议编解码这一半**在 Swift 里已经存在，且已有 `RinaLinkDecoderBaselineTests` / `RinaLinkDecoderDifferentialTests` 做过差分验证**，虚拟板可以直接复用。
- 因为 RinaCore 支持 macOS，**App 内虚拟板与 Mac 上的外部固件模拟器可以共用同一份 Swift 实现**，后者做成 SwiftPM 可执行目标即可，不需要单独的 C++ 构建。原方案让两者走不同技术栈，等于要维护两份行为。
- C++ 抽核心的价值只剩**状态机与命令语义**那一半，成本高得多，应推迟到出现真实分歧证据时再做（见 §5.3）。

**② 仓库已有「从 `protocol.cpp` 切片 + 手写桩 + host 编译」的成熟做法。**

`esp32s3_firmware/test/host/blob_ownership_test.py` 直接按字符串定位从 `protocol.cpp` 截出 `expireBlobSessions()`，补 stub 后在 host 上编译运行。同目录另有 9 个测试（`inbound_recovery`、`output_mode`、`playback_ownership`、`presentation_telemetry`、`rmt_recovery`、`serial_network_scheduling`、`stress_findings`、`ble_frame_sender`、`stream_transport`）。

这是「渐进抽取 FirmwareCore」的现成起点，比重构整个固件便宜得多，且已经跑通。

**③ 测试里已有 5 份重复的假传输，其中一份已在合成真实协议字节。**

```text
ConnectionLifecycleTests.swift:316   LifecycleTransport
DualBoardHostStressTests.swift:387   StressTransport      ← :444 用 RinaLinkEncoder.encode(...) 回灌真字节
ExplicitModeCommandTests.swift:37    ModeCommandTransport
BoardSessionStoreTests.swift:437     SessionTransport
BoardSyncCoordinatorTests.swift:185  SyncTransport
```

即原方案的核心架构主张（虚拟传输 + 真字节）**已被既有测试小规模验证**。做共享的 `VirtualTransport` 顺带能消掉这五份重复。

**④ `BoardConnection` 的既有能力比原方案描述的多。**

| 能力 | 位置 |
|---|---|
| 4 条独立限速通道 | `framePump(20ms/6)`、`commandPump(120ms/4)`、`blobPump(0/4)`、`outputPump(0/64)`，第 130-133 行 |
| seq 隔离（quarantine）与阈值触发重连 | `quarantinedSeqs`、`quarantineReconnectThreshold = 128`，第 106-111 行 |
| 指数退避重连，可注入延迟 | 第 115-122 行，`maxReconnectAttempts = 5` |
| 连接代次与输出会话 | `transportSessionID`、`connectionGeneration`、`BoardOutputContext.session`，第 232/754-755 行 |
| 多消费者事件流 | `events()` / `subscribeToEvents()`，第 467-496 行 |
| 事件与回复的类型冲突已正确处理 | 第 617 行以 `frame.seq == 0` 判定事件 |

追踪系统应当**读取并暴露**这些既有结构（尤其是 `connectionGeneration` 和 `transportSessionID`），而不是另建一套并行状态。

---

## 2. 架构：保留真实业务，只替换外部世界

```text
原有所有 App 页面 → ViewModel / 编辑器 / 音视频处理
    ▼
BoardPlaybackCoordinator（7 个输出来源的所有权仲裁）
    ▼
BoardConnection（请求生成、4 条限速通道、seq 隔离、重连、输出会话）
    ▼
RinaCore：RinaLinkEncoder
    ▼
TraceTransport / FaultInjectingTransport（装饰器）
    │
    ├── BLETransport / TCPTransport ──► 真实 ESP32
    │
    └── VirtualTransport
              │  原始 Data 字节
              ▼
        RinaCore：RinaLinkDecoder.feed(_:)
              ▼
        VirtualBoardEngine：命令处理 / 上传事务 / 播放状态机
              ▼
        VirtualLEDDriver：最终输出 ──► 悬浮窗「设备实际显示」
              ▼
        RinaLinkEncoder 生成真实格式 Reply / EV_*
              ▼
        BoardConnection 原有接收、解码和同步逻辑
```

`BoardOutputSource` 的 7 个来源（`manual`、`automatic`、`text`、`lipSync`、`performance`、`video`、`debug`，`BoardPlaybackCoordinator.swift:4`）都必须经由这条链路，虚拟板不得为任何来源开后门。

### 2.1 依赖装配

新增 `AppDependencies` 负责创建：连接与发现服务、设备会话工厂、时钟与调度、草稿与媒体存储、`UserDefaults`/Keychain 命名空间、音频输入、视频输入、系统权限与生命周期适配器、诊断记录器、虚拟设备运行时。

业务模型通过初始化参数获得依赖。**不要在每个 ViewModel 里加 `if debugMode` 分支。**

### 2.2 两个概念必须分开

```text
设备来源：真实 / 虚拟
链路类型：BLE / 局域网 TCP / 板子热点 TCP / 手机热点 TCP
```

`TransportKind` 现有三个 case（`bluetooth`、`wifi(host:port:)`、`hotspot`）。**不要新增 `.mock` case**——那会绕过全部分块、限速和配网判断。虚拟设备应当声明自己是「虚拟的 BLE」或「虚拟的 TCP」，从而走对应的真实路径（例如 BLE 的 `preferredChunkBytes = MTU-3` 与 TCP 的 `blobChunkMaxTCP = 4032` 是不同的分块行为，必须都能测到）。

---

## 3. 悬浮窗

### 3.1 三种形态

| 形态 | 内容 |
|---|---|
| 悬浮按钮 | 虚拟／真实标识、连接状态、错误数量 |
| 紧凑面板 | 小尺寸设备画面、当前输出来源、TX/RX、最后一次错误 |
| 展开面板 | 完整设备模拟器、协议记录、状态检查器、故障注入、测试场景 |

### 3.2 必须有两份独立画面

**左侧**来自编辑器／文字时间轴／口型处理器／视频量化器（App 期望）。
**右侧**只能来自虚拟设备最终 LED 输出接口，**不得直接读取左侧的帧**。

右侧需体现：接收到的帧 → 固件接受的帧 → 进入输出队列的帧 → 实际完成显示的帧 → 叠加颜色／亮度／电池提示后的最终结果。

支持：按 LED 查看逻辑索引、物理索引、坐标和最终 RGB；显示差异 LED 数量与位置；查看当前帧的 47 字节 / hex / 摘要；分别显示「精确匹配」「预测画面」「等待显示」「无法确认」。

**比较必须对齐同一个帧身份或显示序号**，不能比较两个不同时间点的「最新帧」，否则正常延迟会被误报为错误。

### 3.3 通信记录分阶段

`Created` → `Queued` → `Encoded` → `TransportWritten` → `DeviceReceived` → `DeviceDecoded` → `Accepted/Rejected` → `Applied` → `Presented` → `ReplyReceived` → `UISynchronized`

**真实设备模式不能凭空填满这些阶段。** 没有对应遥测时，`DeviceReceived`／`Applied`／`Presented` 显示「未确认」，不得由发送成功或 ACK 推断。

### 3.4 原生悬浮窗约束

每个 `UIWindowScene` 对应一个调试 `UIWindow`，内部承载 SwiftUI 面板。

| 项目 | 要求 |
|---|---|
| 全局可见 | 切换标签页、打开控制中心和普通弹出页时仍可访问 |
| 触摸穿透 | 面板以外区域不拦截原 App 操作 |
| 命中区域 | 按实际交互区域判断，不依赖 SwiftUI 私有视图层级 |
| 键盘 | 缩小状态不抢键盘；原始命令编辑时正常获得焦点 |
| 位置 | 拖动后限制在安全区域内，旋转后重新校正 |
| 生命周期 | Scene 关闭时释放窗口、观察任务和订阅 |
| 可访问性 | VoiceOver、较大字体、减少动态效果 |
| 系统界面 | 不覆盖系统授权弹窗，不做跨 App 悬浮窗 |

---

## 4. 虚拟 ESP32

### 4.1 技术选型（相对原方案已修正）

**主线：Swift，基于 RinaCore，App 内与 Mac 外部进程共用一份实现。**

```text
RinaCore（已存在，iOS + macOS）
    编解码、PackedFrame、FaceDocument、ScrollRasterizer、常量
        ↑ 复用
VirtualBoardEngine（新增，纯 Swift，无 UIKit 依赖）
    命令语义、状态机、上传事务、输出调度、持久化
        ↑ 两个宿主
   ┌────┴────┐
App 内 VirtualTransport      tools/FirmwareHostSimulator（SwiftPM 可执行，监听 TCP 5370）
```

**不在 P1 做 C++ FirmwareCore 抽取。** 理由见 §1.3①。C++ 路线在 §5.3 作为一致性验收手段引入。

### 4.2 每块虚拟板的独立状态

| 状态域 | 内容 |
|---|---|
| 身份 | Board ID、默认名称、自定义名称、固件版本、协议能力 |
| 运行状态 | 手动／自动、暂停、自动表情索引与间隔 |
| 输出 | 当前内容来源、输出流 ID、位置、待显示帧、已显示帧 |
| 灯光 | 颜色、亮度、有效 LED 布局、物理映射 |
| 滚动 | 时间轴身份、帧集合、帧索引、循环、用户暂停、系统暂停 |
| 上传 | 所属客户端、kind、期望长度、当前偏移、暂存内容、事务状态 |
| 表情库 | 文档、默认／自定义类型、顺序、版本与 generation |
| 电源 | ADC 原始输入、换算结果、充电状态、校准值、有效性 |
| 网络 | 工作模式、家庭网络与手机热点配置、扫描结果、连接状态 |
| 客户端 | 独立订阅、接收缓冲、连接代次、发送状态 |
| 持久化 | 重启后保留的设置与文件，以及重启后清空的运行状态 |

**重启模拟必须真正重新初始化运行状态并重新加载持久化数据，不能只把 uptime 改成零。**

客户端槽位数须与固件一致（固件侧为 BLE + 两个 TCP 客户端，见 `blob_ownership_test.py` 中 `g_clients[4]` 与 `MAX_CLIENTS`），跨客户端的上传抢占行为必须复现。

### 4.3 可控时钟

```text
正常速度 / 暂停虚拟设备 / 推进一次协议处理 / 推进一次 LED 显示
推进 1 ms / 一帧 / 1 秒 / 快进到下一个事件
```

App 侧的超时、4 条限速通道、重连退避、草稿延迟保存也应通过可注入调度器控制（`reconnectDelay` 是既有先例）。

**命名必须区分**：「暂停日志显示」不停止通信；「暂停虚拟设备」才停止设备执行。真实板模式只能暂停面板更新，不能假装冻结真实 ESP32。

### 4.4 App 退出后的持续运行

App 内模拟器与 App 同进程。要验证「App 被关闭，板子继续滚字，重开后恢复同步」，必须用 `tools/FirmwareHostSimulator`（独立进程，真实 TCP）。

App 内模式也可保存快照并在恢复时推进虚拟时间，但报告须标为「恢复行为模拟」，不等同于独立设备持续运行测试。

---

## 5. 协议覆盖

### 5.1 请求与命令

13 种请求类型、40 条 CMD、6 个事件 + ERR 全部进入模拟处理器、命令检查器和测试清单（清单见 §1.1，逐条已核实）。上传三种 kind 全部实现。

每条命令登记：输入格式、默认值、有效范围、超范围时夹紧还是拒绝、成功响应、失败响应、即时副作用、异步副作用、是否持久化、产生哪些事件。

**不能统一采用「无效参数全部报错」的理想化规则。** 模拟器要忠实执行当前固件实现，而不是替固件「修正行为」。已知需逐条核对的例子：亮度入口会做范围处理（`brightnessMin/Max = 10/200`）；`set_device_name` 明确区分 `ok` 与 `persisted`；`set_mode` 和 `set_auto_interval` 会写 flash。

### 5.2 必须严格复现的协议细节

| 项目 | 内容 |
|---|---|
| 帧结构 | `0xA5`、6 字节头、小端长度、type／seq／flags |
| 字节流 | 半个头、半个 payload、多帧粘连、逐字节输入（`RinaLinkDecoder.feed` 已有基线测试可对照） |
| 帧数据 | 47 字节、370 位、末字节高 6 位必须为 0 |
| 两个 4096 | `maxPayloadBytes`（帧）与 `maxScrollTextBytes`（文本）分别检查 |
| 序号 | 0 为事件；请求序号耗尽、超时隔离（`quarantinedSeqs`）、重用、旧连接回调 |
| 类型冲突 | 0x90/0x91 既是 `SET_FRAME`/`GET_FRAME` 的回复，也是 `EV_PREVIEW_SYNC`/`EV_STATUS`，必须结合 `seq == 0` 判断 |
| MORE | 普通多段响应聚合与 `GET_FACES` 的分页行为**分开实现**（`BoardConnection` 对此有专门说明，须照其行为） |
| 上传原子性 | 未 END、ABORT、断线、失败时不破坏之前的有效内容 |
| 表情库 generation | 下载过程中修改文档，不得拼出跨版本混合文档 |
| 持久化失败 | 写入失败、部分写入、即时生效但未保存，三者不可合并为成功 |
| 分块差异 | BLE `preferredChunkBytes = MTU-3` 与 TCP `blobChunkMaxTCP = 4032` 必须分别走到 |

边界数值一律从 `RinaCore.RinaLinkConstants` / `RinaLinkFrameConstants` 读取。**Debug 模式不得维护第二份常量。**

### 5.3 一致性验收（C++ 路线在此引入）

P1 的 Swift 虚拟板是行为模拟，不是固件一致性证明。达成一致性需要两条互补证据：

1. **共享核心差分测试**：按 `esp32s3_firmware/test/host/` 既有的切片手法，把 `protocol.cpp` 中的命令处理与上传事务逐段抽到 host 编译，对同一组输入比较 C++ 与 Swift 虚拟板的输出。优先抽取已被 host 测试覆盖过的段落（`expireBlobSessions` 等），成本最低。
2. **真实板差分测试**：同一脚本分别对真实板和虚拟板重放，比较 `GET_STATUS` / `GET_FRAME` / `GET_SCROLL_META` / `GET_PREVIEW_SYNC` 快照。

只有这两项通过，才允许在报告中写「与固件行为一致」。

---

## 6. 全部 App 功能的测试覆盖表

做成 `FeatureCoverageManifest`。**每一行都要有对应的测试场景、断言和当前结果，而不只是「支持」标记。**

| 功能域 | 必须覆盖的操作和状态 |
|---|---|
| **启动和导航** | 冷启动、启动动画、动画重播、恢复上次标签、首次加载资源、错误提示、页面来回切换、控制中心展开收起 |
| **全局控制中心** | 亮度全部入口、颜色输入及预设、上一／下一表情、手动／自动、自动间隔、快速连续修改、旧状态回显不得覆盖新操作 |
| **像素编辑器** | 所有有效 LED、无效区域、清空、填满、反转、发送、Live 开关、编辑恢复、发送失败、草稿保存和恢复 |
| **部件组合** | 左眼、右眼、嘴、脸颊的全部部件，默认、随机、左右同步、切换部件后的画面和发送结果 |
| **帧文本输入输出** | hex（94 字符）、47 元素整数数组、base64 的有效与无效输入，长度、范围、尾位、复制、预览及发送 |
| **表情库** | 加载、应用、新增、编辑、改名、排序、删除、默认表情保护、清除用户表情、导入、导出、版本冲突、本地与板端一致性 |
| **文字输入和生成** | 中文、日文、英文、emoji、组合字符、空白、长度边界（文本 4096 字节）、缺失字体、生成失败、缺失字形、草稿冲突选择 |
| **文字上传** | 位图上传、兼容路径的原始帧上传、进度、取消、上传中断、重试、旧时间轴保留、提交失败 |
| **文字播放** | 开始、暂停、继续、停止、循环、单次结束、逐帧前后移动、拖动跳转、实时调速、结束后恢复、重开后的恢复 |
| **文字同步** | 本地 PLL 与设备时间轴、实际速度、显示序号、跨多次循环、设备时钟重置、时间轴不匹配、旧遥测到达 |
| **口型同步** | 麦克风开始／停止、静音阈值、声音模型、防抖、刷新设置、全部嘴型映射、眼睛脸颊、校准、权限拒绝、音频中断 |
| **预设演出** | 9 首内置时间轴（lumf、poppin_up、solo0–5、tkmk）、脚本导入、音频导入、无音频、播放暂停、定位、循环、脚本错误、素材缺失、恢复位置、结束后的显示 |
| **视频** | Photos／文件导入、取消和失败、无视频轨道、画面方向、适配方式、量化模式、阈值、自动阈值、反色、镜像、帧率、循环、静音、跳转、恢复 |
| **输出互斥** | 7 个 `BoardOutputSource` 两两之间 42 个有向切换 + 7 个同来源重启；旧任务、旧上传、旧帧不得在接管后重新写入 |
| **BLE 连接** | 扫描、发现、名称、设备选择、连接、服务发现、通知启用、INFO、PING 握手、失败、取消、断线和重连 |
| **Wi-Fi 与热点** | 网络扫描、家庭网络配置、手机热点配置、板子热点、各工作模式、密码错误、连接失败、Bonjour（`_rinalink._tcp`）、手动地址、切换和回退 |
| **多设备** | 多块板发现、连接和切换；名称／身份识别；忘记设备；相同热点 IP 下不混淆；一块板重启不影响另一块 |
| **设备电源和按键** | 充电／放电、无效读数、ADC 饱和、校准重置、电池覆盖画面、全部固件按键动作、组合键和长短按路径 |
| **现有调试工具** | 状态读取、Ping、测试图案、本地预览与发送、原始命令、固件日志订阅、过滤、暂停、清空、复制、导出、危险操作确认 |
| **应用设置与关于** | 显示板子照片、触感反馈、保持常亮、标签恢复、设备重启、关于页内容及导航 |
| **持久化与资源** | 草稿、表情、已知设备、媒体位置、媒体文件、设置、凭据；损坏、缺失、写入失败、迁移和空间不足 |
| **生命周期与可访问性** | 进入后台、恢复前台、进程重启、任务取消、横竖屏、字体放大、VoiceOver、减少动态效果、中文／英文界面 |

### 6.1 覆盖机制

每个业务操作绑定稳定的 `FeatureID`：

```text
control.editor.send        faces.import           text.upload.bitmap
text.playback.seek         lipsync.calibration    performance.importScript
video.import.photos        connection.wifi.provision   settings.reboot
```

每项记录：入口页面及控件、使用的业务操作、涉及的协议、正常场景、失败场景、取消／恢复场景、UI 测试、是否需要真机补充验证、最近一次测试结果。

新增命令时，协议注册表检查模拟处理器与测试是否缺项；新增 UI 操作时要求使用登记过的 `FeatureID`。**有登记但没有执行过测试的项目显示「未验证」，不得显示绿色通过。**

---

## 7. 音频、视频与系统服务

### 7.1 口型：注入音频，不注入「识别结果」

| 输入 | 测什么 |
|---|---|
| 真实麦克风 | 真实采集、权限、音频会话和处理链 |
| 测试 PCM 音频源 | 确定性的 DSP、分类、防抖、校准和发送行为 |

素材：静音、噪声、不同幅度、不同采样率、元音样本、突然中断、超长输入。

**必须让音频经过 `LipSyncProcessor` / `LipSyncDSPEngine`**，不能直接告诉 ViewModel「现在是 a 嘴型」再把后半段当作整个口型功能通过。`LipSyncDSPEngineTests` 和 `LipSyncSampleRingTests` 已经在 RinaCore 里，可直接扩展。

### 7.2 演出：播放器与时间轴分开测

- **确定性时间轴测试**：可控播放位置，检查每个时间点选哪一帧、循环后是否重新触发首帧、拖动后是否正确更新。`LivePerformanceScriptTests` / `BundledPerformanceTests` 是现成基础。
- **真实媒体集成测试**：短测试音频，经过实际导入、播放器和恢复流程。

覆盖脚本错误、关键帧排序、越界部件、缺少素材、音轨结束、最后一帧保留。

> 注：Love Live! 音频为本地素材且被 gitignore，时间轴文件是入库的。CI 上跑演出测试须按无音频路径处理。

### 7.3 视频：合成帧与真实文件都要有

| 测试源 | 作用 |
|---|---|
| 合成像素缓冲 | 精确验证量化、阈值、镜像、反色、矩阵采样（`VideoFrameQuantizerDifferentialTests` 已有） |
| 短测试视频文件 | 真实导入、解码、旋转信息、播放器、跳转和恢复 |

慢链路场景必须检查：**是否丢弃过时帧以追上当前播放，而不是把几十秒旧画面排队发送。** 现有实现走 `LatestValueSender` 与 `LatestFrameProcessor`，测试应直接覆盖这两条真实路径。

### 7.4 系统能力适配器

```text
DeviceDiscovery   NetworkBrowser   HotspotJoining   PermissionProvider
AudioInput        MediaPlayback    FileImportExport PersistentStorage
AppLifecycle      ResourceLoader
```

虚拟模式返回可编排结果；真机模式调用实际系统服务。

系统授权弹窗、真实照片选择器、实际 Wi-Fi 加入仍由 UI／真机测试验证。**模拟返回「授权拒绝」是在测试 App 的拒绝处理，不是在验证系统真的改变了授权。**

---

## 8. 故障注入

| 类别 | 注入项 |
|---|---|
| **连接** | 握手超时、服务缺失、通知启用失败、连接中取消、突然断开、重连期间再次切板 |
| **传输** | 延迟、低带宽、背压、分片、粘包、部分写入后关闭连接 |
| **响应** | 请求已执行但响应丢失、响应迟到、重复响应、错误 seq、错误 type |
| **编码与解析** | 畸形 JSON、非法长度、未知消息、未知命令、无效 PackedFrame（含末 6 位非零） |
| **上传** | 错误 offset、声明长度不符、END 前断线、内存分配失败、多客户端竞争同一 slot |
| **存储** | 文件缺失、损坏、空间不足、部分写入、原子替换失败、即时生效但持久化失败 |
| **设备状态** | 自动模式运行中被按键接管、滚动时电池提示介入、用户暂停与系统暂停交叉 |
| **时间** | 显示延迟、时钟重置、序号回绕、遥测稀疏、长时间没有同步 |
| **多板** | A 的迟到响应到达 B 激活之后、相同地址不同设备、一个设备断线另一个继续 |
| **媒体与资源** | 字体缺失、音视频文件消失、解码失败、音频会话中断、导入被取消 |

**两条硬约束：**

1. **正常 TCP 模拟必须保持字节有序。** 丢字节、乱序字节保留为「破坏性解析测试」，不得描述成普通 TCP 丢包会产生的应用层行为。
2. **区分两种丢弃**——允许按策略丢弃：尚未发送的过时视频帧、调试日志记录；不允许静默丢弃：正在解析的协议原始字节。否则 Debug 模式自身会制造难以定位的通信损坏。

---

## 9. 记录、回放与自动测试

### 9.1 追踪记录字段

```text
traceID  boardID  connectionGeneration  requestID  输出会话 ID  FeatureID
阶段  方向  type/seq/flags  字节数  虚拟或单调时间  payload 摘要
响应或错误  关联帧身份  显示序号  队列深度
```

**不能仅靠 8 位 `seq` 关联整场记录**（序号会重用，且 `quarantinedSeqs` 会让同一 seq 跨越多个语义）。必须同时使用 `connectionGeneration` 与本地请求身份——两者 `BoardConnection` 已经维护，直接暴露即可。

### 9.2 两种回放

- **通信回放**：重放设备返回的字节和时序，复现解析、状态同步和 UI 问题。
- **完整场景回放**：从固定素材和初始状态开始，重放用户动作、权限结果、音视频输入、设备事件和故障。

仅保存 TX/RX 字节无法重建当时的音频、视频、草稿和 UI 操作。完整复现包：

```text
manifest.json  scenario.json  events.jsonl  device-initial-state.json
app-test-settings.json  fixtures/  expected-results.json
```

**凭据在进入日志和导出包之前就要脱敏**，包括原始命令面板里输入的 `wifi_set_credentials` / `wifi_set_hotspot_credentials` / `wifi_set_ap` 密码。不能只隐藏界面文字而保留导出的明文。

### 9.3 测试层级

| 层级 | 执行位置 | 验证内容 |
|---|---|---|
| 核心逻辑测试 | RinaCore 测试目标 / firmware host 测试 | 编解码、算法、状态机、文档处理 |
| 协议端到端测试 | App 内场景引擎或集成测试 | 真实业务→真实字节→虚拟固件→真实响应 |
| UI 自动化 | Xcode UI 测试 | 实际页面点击、输入、导航、弹出页 |
| 真机联调 | iPhone + ESP32 | 系统服务、真实链路与硬件行为 |

**App 内的「运行全部测试」按钮可以执行场景引擎，但不能把直接调用 ViewModel 方法等同于真实点击了全部 UI。**

### 9.4 跨功能回归场景

| 场景 | 核心断言 |
|---|---|
| 编辑表情→Live 发送→关闭 Live→继续编辑→手动发送 | 关闭 Live 后设备不再跟随编辑；手动发送后才更新 |
| 文字上传中断→重连→重新上传 | 旧有效时间轴未被破坏，新上传不错误继承偏移 |
| 文字播放→视频接管→旧文字任务返回 | 旧任务不得覆盖视频输出 |
| 演出播放→跳转→循环→后台→恢复 | 媒体位置、输出流身份和最终帧一致 |
| A 板操作→切换 B 板→A 的旧响应迟到 | B 的状态与草稿不受污染 |
| 表情库下载中另一客户端修改文档 | 返回冲突或重新下载，不生成混合版本 |
| 设备改名→存储失败→重启 | UI 区分即时名称（`ok`）与未持久化结果（`persisted`） |
| App 退出→外部虚拟板继续滚动→App 重开 | 从设备当前状态恢复，而不是用本地旧位置强制覆盖 |
| 切板时有未保存草稿 | 与已决行为一致（草稿被丢弃），不得静默改变 |
| 重连后文字速度 | 采用板子真实速率并记住，不回退到本地旧值 |

后两条对应已决定的行为，任何改动都属于回归。

---

## 10. 文件级改动

### 10.1 修改现有文件

| 文件 | 改动 |
|---|---|
| `App/RinaBoardApp.swift` | 用 `AppDependencies` 创建模型和会话，注入运行环境及诊断服务 |
| `App/RootTabView.swift` | 接入 Scene 调试窗口管理；自动重连和生命周期使用环境服务 |
| `Services/BoardSessionStore.swift` | ~~`scanner` 与 `BoardSession.bleTransport` 改协议类型、加 `makeBLETransport` 工厂~~（已完成，见 §11.4）；仍待做：注入设备身份提供者 |
| `Services/RinaTransport.swift` | 保留抽象与非 `Sendable` 约定；补充端点身份／能力描述，不把虚拟来源与链路类型混为一谈 |
| `Services/BoardConnection.swift` | 暴露既有的 `connectionGeneration`／`transportSessionID`／限速队列深度；加入请求生命周期追踪与原始收发观察；把 `reconnectDelay` 式的注入推广到超时与限速 |
| `Services/BoardPlaybackCoordinator.swift` | 暴露只读的输出持有者、会话身份、接管与取消记录 |
| `App/BoardSyncCoordinator.swift` | 记录同步原因、恢复决策、忽略旧状态的理由 |
| `Features/Connection/ConnectionViewModel.swift` | 通过发现、配网、热点、Bonjour 适配器执行流程 |
| `Features/Debug/DebugView.swift` | 增加模式、虚拟设备、故障、场景和覆盖率入口 |
| `Features/Debug/DebugViewModel.swift` | 不再作为全软件日志的唯一所有者；改为读取统一诊断服务（保留其 `RingBuffer` + 合并刷新做法，见 §11.2） |
| `Features/Debug/DebugCommandCatalog.swift` | 接入统一协议注册表和测试覆盖信息 |
| `Features/Text/TextViewModel.swift` | 注入草稿存储、资源加载和时钟，保留真实生成与上传逻辑 |
| `Features/LipSync/` | 抽出音频输入接口，支持真实麦克风和测试 PCM |
| `Features/PresetLive/` | 抽出播放器时间与素材存储接口 |
| `Features/Video/VideoPlayerModel.swift` | 注入媒体输入和存储，支持测试视频及合成帧集成测试 |
| `Services/DraftStorage.swift` 等存储模块 | 支持独立测试目录、失败注入，避免污染真实数据 |
| `ios/RinaBoardTests/` 五份私有假传输 | 收敛到共享 `VirtualTransport`（`LifecycleTransport`、`StressTransport`、`ModeCommandTransport`、`SessionTransport`、`SyncTransport`） |
| Xcode 工程与测试目标 | 增加 Debug Lab 配置、模拟器库、UI 测试和场景资源 |

> `Features/Debug/BoardConnection+Debug.swift` 中过期的 C10 注释已于本次修复。

### 10.2 新增模块

```text
ios/RinaBoard/DebugLab/
├── Runtime/    DebugRuntime · DebugConfiguration · DebugSessionFactory
├── Overlay/    DebugOverlayCoordinator · DebugOverlayWindow · DebugFloatingPanel · DebugDevicePreview
├── Transport/  VirtualTransport · TraceTransport · FaultInjectingTransport
├── Trace/      TraceEvent · TraceStore · TraceRedactor · TraceExporter
├── Scenarios/  ScenarioRunner · ScenarioAssertions · FeatureCoverageManifest
└── Fixtures/   Audio/ Video/ Faces/ Protocol/

ios/Packages/RinaVirtualBoard/          # 新 SwiftPM 目标，依赖 RinaCore，iOS + macOS
    VirtualBoardEngine · VirtualBoardSnapshot · VirtualBoardStorage · VirtualBoardEnvironment
tools/FirmwareHostSimulator/            # SwiftPM 可执行，复用 RinaVirtualBoard，监听 TCP 5370
esp32s3_firmware/test/host/parity_*.py  # C++ ↔ Swift 差分（§5.3）
tests/debug_scenarios/
```

把虚拟板放进 SwiftPM 包（而不是 App 内目录）是为了让 Mac 端模拟器复用同一份代码——这是相对原方案 `ios/Packages/FirmwareSimBridge/` + 独立 `tools/FirmwareHostSimulator` 的关键简化。

### 10.3 并发约定

`RinaTransport` 刻意不是 `Sendable`，`BLETransport` 是 `@MainActor` 隔离的。**不要为了模拟器方便给整个协议加 `@unchecked Sendable`。** 让主 actor 的适配器与独立的模拟器 actor 通过不可变数据交换（`RinaLinkFrame` 与 `PackedFrame` 都已经是 `Sendable` 值类型）。

---

## 11. 隔离、性能与实施顺序

### 11.1 Debug 数据与真实数据隔离

```text
构建配置 RinaBoard-DebugLab
编译条件 RINA_DEBUG_LAB
独立 Bundle ID / UserDefaults suite / Application Support 子目录 / Keychain service
```

只替换 `UserDefaults` 不够，还要处理现有 `.shared` 存储入口、媒体文件目录和直接使用 `.standard` 的地方。

**运行环境切换不能只改一个布尔值。** 必须停止输出生产者、取消旧任务、断开旧端点、失效旧连接代次，再重新装配。优先使用干净重建或重启进入另一环境，避免旧异步任务继续写入新环境。

真实设备模式默认只观察。故障注入、重放写命令、清库、重启、改配网须单独授权；录制回放默认禁止向真实设备发送。

### 11.2 性能目标

以下是设计目标，不是已测得的结果：

| 项目 | 要求 |
|---|---|
| 日志存储 | 同时限制记录数和总字节数 |
| 界面刷新 | 批量刷新，不因每条协议日志重建整个页面 |
| 原始数据 | 默认保存摘要，需要时再开启有上限的原始包录制 |
| 模拟执行 | 与 UI 解耦，避免大 Blob 展开和文档处理阻塞主线程 |
| 设备画面 | 独立刷新，不让日志列表变化触发 LED 画面重建 |
| 关闭面板 | 取消不需要的 UI 订阅，保留用户明确开启的记录 |
| 资源泄漏 | 反复开关、断连、切板后检查任务和内存 |
| 性能比较 | 对比调试关闭、仅记录、展开面板三种状态 |

`DebugViewModel` 现有做法（`RingBuffer(capacity: 500)` + `logRing`/`logs` 双层 + `flushPendingLogs()` 合并刷新，第 259-263 行）已经是正确思路，新系统沿用，不得退回逐条发布。

性能门禁按项目既有约定：`RINA_PERF_GATE` opt-in，交叉执行 + p50 + 3 次运行。

### 11.3 实施顺序（相对原方案已重排）

| 阶段 | 交付 | 通过标准 |
|---|---|---|
| **P0：可替换依赖** | BLE 依赖可替换（✅ 已完成，见 §11.4）；`AppDependencies`；独立存储命名空间；时钟注入面推广 | 虚拟模式不会偷偷初始化真实 BLE 服务（✅ 已验证）；现有测试全绿（✅ 65/65） |
| **P1：虚拟板核心** | `RinaVirtualBoard` 包（依赖 RinaCore）+ `VirtualTransport`；13 请求 / 40 CMD / 7 事件 / 3 种 blob kind / LED 输出 / 持久化；收敛测试里五份重复假传输 | 不存在「未实现但返回成功」的入口；五份假传输已删除且原测试仍通过 |
| **P2：全局悬浮窗** | 独立设备画面、双向追踪、状态检查、设备操作 | 在所有业务页面都能观察真实链路 |
| **P3：全部功能输入** | 音频、视频、文件、权限、资源与生命周期适配器 | 覆盖表中的路径均可进入、可断言 |
| **P4：故障与回放** | 可控时钟、故障配置、场景记录、回放与覆盖报告 | 常见竞态和失败可确定性重现 |
| **P5：一致性验收** | `tools/FirmwareHostSimulator`（复用 P1 的包）、C++↔Swift 差分、真实板差分、UI 自动化、性能测试 | 报告明确区分软件模拟通过与真实硬件通过 |

相对原方案的顺序调整：C++ FirmwareCore 抽取从 P1 移到 P5，且缩小为「差分验证手段」而非「虚拟板实现基础」；外部固件模拟器从独立技术栈改为复用 P1 产物，因此成本从一个独立阶段降为 P5 的一个交付项。

### 11.4 P0 BLE 依赖可替换（已完成，2026-09-17）

**通过标准已达成**：给出两个 BLE 替身后，`BoardSessionStore` 不再构造任何 `BLETransport`，因此虚拟运行不会打开 `CBCentralManager`。

**一、扫描器可替换。**

新增 `BoardScanning` 协议（`Services/RinaTransport.swift`），成员正好是连接界面今天消费的那六项：`discoveredPeripherals` / `isScanning` / `scanDidTimeOut` / `lastError` / `startScan()` / `stopScan()`。`BLETransport` 声明该 conformance；`BoardSessionStore.scanner` 与 `init(scanner:)` 改为 `any BoardScanning`；`ConnectionViewModel.toggleBLEScan(ble:)` 同步改签名。`BoardSessionStoreTests` 新增 `testInjectedScannerServesDiscoveryInsteadOfCoreBluetooth`，注入一个不碰 CoreBluetooth 的 `StubScanner` 并断言扫描确实路由到它。

原 `init(scanner:)` 参数虽然存在，但改动前的 **18 个构造点全部使用默认值**，从未被真正注入过，所以这次改类型是源码兼容的。

**二、每个会话的 BLE 载体可替换。**

新增 `BLEConnecting: RinaTransport, BoardScanning`，补上连接界面用到的 BLE 专属面：`peripheralIdentifier`（读写）、`connectingPeripheralID`、`connectedPeripheralID`、`connectedPeripheralName`、`connectedRSSI`、`updateConnectedPeripheralName(_:)`。它同时继承 `BoardScanning`，因为**一个 `CBCentralManager` 本来就既扫描又连接**，替身也必须两样都答得出来。

`BoardSession.bleTransport` 改为 `any BLEConnecting`，并由 `BoardSessionStore` 的 `makeBLETransport` 工厂构造（三个构造点：初始会话、`session(for:name:)`、`remove` 的占位会话）。

**SwiftUI Environment 的限制绕开了，没有引入外观类。** `@Environment(T.self)` 需要具体的 `@Observable` 类，不接受 `any Protocol`——但 `.environment(sessions.active.bleTransport)` 本来就是多余的：`BoardSessionStore` 已经在 Environment 里，而两个消费视图也都已经取了 `sessions`。所以直接删掉这条注入，视图改用计算属性 `sessions.active.bleTransport`。这比塞一个 `BLELinkStatus` 外观类更少一层间接，也更正确：读取点取值总是当前活动板，而不是注入时刻捕获的那块。

`ConnectionViewModel` 的 6 处 `ble: BLETransport` 与一处 `@MainActor (BLETransport) async -> Bool` 同步改为 `any BLEConnecting`。

> 连接侧本身**早就可注入**——`BoardConnection.connect(using:)` 一直接受 `any RinaTransport`，五个测试假件正是走这条路。`bleTransport` 属性只是 BLE 专属身份与链路状态的持有者。

**一个并发坑：** `BoardSessionStore.init` 的工厂不能写成默认实参 `= { BLETransport() }`——默认实参在 nonisolated 上下文求值，而 `BLETransport.init` 是 main-actor 隔离的（`error: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context`）。改成 `nil` 默认值 + 在初始化器体内回退，并把闭包类型标成 `@MainActor () -> any BLEConnecting`。

**验证**：`xcodebuild build` 成功；`BoardSessionStoreTests` / `ConnectionLifecycleTests` / `SavedConnectionRecoveryTests` / `BoardSyncCoordinatorTests` / `ControlEventRefreshTests` 共 65 个测试全过。新增两个测试：`testInjectedScannerServesDiscoveryInsteadOfCoreBluetooth` 与 `testInjectedBLESeamsKeepEveryBoardSessionOffCoreBluetooth`（后者断言三个会话构造点都没有生成 `BLETransport`）。

**顺带发现，未修（不在本次范围内）：** `BLETransport.swift:157` 在初始化器里无条件 `CBCentralManager(delegate: self, queue: .main)`。虚拟模式已经不受影响（根本不构造 `BLETransport`），但**真实用户仍然在 App 启动时就被要求蓝牙授权并点亮射频，哪怕他只用 Wi-Fi**。改成 lazy 不能直接做：`startScan()`（第 193 行）硬性 `guard centralManager.state == .poweredOn`，而新建的 `CBCentralManager` 在首个 `centralManagerDidUpdateState` 回调到达前是 `.unknown`，首次点扫描会直接报「蓝牙不可用」。要做必须让 `startScan` 像 `connect()` 那样等待 powered-on（`poweredOnContinuation` 机制已存在，第 102-103 行），属于独立的 UX 改进，需要配回归测试。

---

## 12. 核对方式

本文的事实性断言来自 2026-09-17 对工作区的直接读取，主要引用点：

```text
ios/Packages/RinaCore/Sources/RinaCore/{RinaLinkMessageType,RinaLinkConstants,RinaLinkCodec,PackedFrame,RinaCommand}.swift
ios/Packages/RinaCore/Package.swift
ios/RinaBoard/Services/{RinaTransport,BoardConnection,BoardSessionStore,BoardPlaybackCoordinator}.swift
ios/RinaBoard/Features/Debug/{DebugViewModel,BoardConnection+Debug}.swift
ios/RinaBoardTests/{ConnectionLifecycle,DualBoardHostStress,ExplicitModeCommand,BoardSessionStore,BoardSyncCoordinator}Tests.swift
esp32s3_firmware/src/{protocol.cpp,config.h}
esp32s3_firmware/test/host/blob_ownership_test.py
```

尚未执行：iOS 构建、iOS 测试、固件 host 测试。§11.2 的性能数字是目标而非实测。§5.1 中「亮度夹紧 / `set_mode` 写 flash」等命令语义细节来自既有文档与常量，逐条行为仍需在 P1 实现时对照 `protocol.cpp` 复核。
