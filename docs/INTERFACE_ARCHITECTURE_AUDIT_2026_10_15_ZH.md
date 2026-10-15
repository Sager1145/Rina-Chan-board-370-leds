# 功能接口清单与架构审查（2026-10-15，基于 e7588cd + 工作区未提交改动）

范围：`esp32s3_firmware/src`、`ios/Packages/{RinaCore,RinaFaceSync}`、`ios/RinaBoard/{Services,App,Features}`、`ios/RinaBoardWatch`、`ios/RinaWatchLink`、`ios/MacSupport`、`tools/rinalink_board_emulator.py`。
方法：分 6 片并行盘点（Codex ×4、Grok ×2），关键结论由 Claude 对照源码抽查。行号以审查时的工作区为准。
术语沿用 codebase-design：**模块 / 接口 / 实现 / 深度 / 接缝（seam）/ 适配器**。“一个适配器 = 假想接缝；两个适配器 = 真接缝。”

---

## 0. 结论（先看这里）

1. **协议层（BLE/TCP → 一个 dispatcher）是对的。** 固件 `ITransport` 和 App `RinaTransport` 都有两个生产适配器，是真接缝，不要动。
2. **问题集中在三处摆放错误，数据在层间来回传：**
   - **滚动帧被展开了两次。** 手机把整条时间线展开成 `[PackedFrame]`（`ScrollRasterizer.swift:261-267`），上传时却只发 bitmap（`BoardConnection.swift:1467`）；固件收到 bitmap 后又展开成 `frameCount×47` 字节的 staging，再拷进运行时缓冲（`protocol.cpp:2064-2114`）。窗口化这件事两边各做一遍，还多出一条 raw 帧兜底路径。
   - **每条 CMD 的回复都是 2 KB 的状态回显**（`protocol.cpp:530-549, 1413`）。App 只读 `ok`，组播换表情时再读 `autoFaceId/Index`（`RinaBoardApp.swift:233`）。同样的状态 `EV_STATUS` 已经推送过一遍。
   - **组控制被塞进了 `BoardConnection`。** `command()` / `setFrame()` 内部会拦截消息，转发给 `GroupControlFanOut`（`BoardConnection.swift:1009, 1182`）。与此同时 `BoardGroupCoordinator` 又自己显式扇出一遍。于是组相关有 4 个模块（约 4150 行），外加 4 套重连引擎。
3. **一个功能多套实现的地方：** CMD 发送 6 套、滚动上传 3 套、表情库写入 2 套、Wi-Fi 配网 2 套（RinaLink 和 HTTP）、手表控制 2 套（走手机 model，或直连板子）、帧流发送 3 套（视频、口型、演出）。
4. **可直接删除的死代码：** `RinaFaceSync` 整包，约 1,070 行，App 没有任何 import；`AppDefaults`，约 170 行；还有一批 0 调用者的转发方法（§4）。
5. **兼容旧固件的兜底没有存在理由。** 固件和 App 在同一仓库里一起发布，两块板都由我们自己刷写。raw 滚动、legacy reason 解析、Wi-Fi 扫描三路完成、零调用者命令，都可以删。

---

## 1. 第一性原理：系统本质上只做这几件事

| 本质能力 | 最小接口 | 现状 |
|---|---|---|
| 显示一帧（1-bit × 370） | `SET_FRAME(bytes47, owner)` | ✅ 一个编码器，但 owner 靠解析 reason 字符串推导（`state.cpp:219-269`） |
| 改渲染参数（颜色 / 亮度 / 模式 / 间隔） | `CMD set_*` → ack | ⚠️ ack 是 2 KB 回显；手表有第二条发送路径 |
| 存 / 取表情 | 增量 op + 一次性导入 | ⚠️ 增量和整文件 blob 两条写入路径；每次 op 都要重读重解析两遍 |
| 播一段滚动 | 上传 bitmap + 播放控制 | ❌ 3 个上传入口、2 种格式，帧窗口两边各算一次 |
| 多板同步 | 时钟样本 + `group_start` | ⚠️ 引擎本身合理，但组控制的扇出逻辑侵入了 `BoardConnection` |
| 报告状态 | 一份状态推送 | ❌ `EV_STATUS` 和 `EV_POWER` 都带 power；`EV_PREVIEW_SYNC` 与 `EV_STATUS` 字段重叠；另有 `GET_*` 和 CMD 回显 |
| 配网 | 一组 wifi op | ⚠️ RinaLink 和 HTTP 门户各解析一遍；扫描有三种完成方式 |

**目标形态（不加新层，只做合并）：**

- **板 ← 手机**：`command<Reply>(cmd, policy)` 一个执行器；`setFrame`；`upload(.scrollBitmap | .faces)`。
- **板 → 手机**：一份 `BoardState` 推送，按 version 递增；`GET_*` 只用于连接时拿首帧快照。
- **App 内部**：
  - `BoardConnection` 只负责传输加协议，不再知道“组”的存在。
  - 一个 `GroupRuntime` 包住多条连接，统一管目标、扇出、拨号、轮播、定时滚动。
  - 一个 `FrameStreamer` 供视频、口型、演出共用。
  - 一组 `ControlActions` 供控制中心和手表共用。

---

## 2. 功能接口总表（一个能力一行；`#` 为独立实现数，标 ⚠️ 的违反“一接口一实现”）

### 2.1 显示输出

| 能力 | 入口接口 | 实现 | # | 主要调用方 |
|---|---|---|---|---|
| 显示任意帧 | `BoardConnection.setFrame(_:playback:reason:)` → `SET_FRAME` | App `BoardConnection.swift:1174-1200`；FW `protocol.cpp:1548-1605` → `applyPackedFrameQueued` `led_renderer.cpp:423` | 1（另有串口 `frame hex` `serial_console.cpp:232`） | Control `:601,661`、Faces `:423`、Video `:693`、LipSync `:496`、PresetLive `:843`、Debug `:829,894`、组扇出 `GroupControlFanOut.swift:746` |
| 读当前帧 | `getFrame()` → `GET_FRAME` | `BoardConnection.swift:1161`；FW `protocol.cpp:1607` | 1 | Control 刷新 `ControlViewModel.swift:970`、组表情回读 `GroupControlFanOut.swift:601` |
| 清屏 | 全零 `SET_FRAME`、串口 `frame clear`、内部 `applyBlankFrame` | `protocol.cpp:1548`、`serial_console.cpp:224`、`led_renderer.cpp:451` | ⚠️ 3 | — |
| 编辑器悬停提示灯 | `set_hint_led` | FW `protocol.cpp:1238-1267` + `led_renderer.cpp:511-530`（两处都校验范围） | 1 | `ControlViewModel.swift:710,742` |
| 板号识别覆盖层 | `identify` | `protocol.cpp:1096`、`led_renderer.cpp:268-361` | 1 | `BoardGroupCoordinator.swift:342,373` |
| 帧流（视频） | `VideoPlayerModel.play→tick→setFrame` | `VideoPlayerModel.swift:506-711` | ⚠️ 与下两行共 3 套“lease + 合并发送 + setFrame”外壳 | `VideoPlayerView.swift:152` |
| 帧流（口型） | `LipSyncModel.start→tick→setFrame` | `LipSyncModel.swift:317-510` | ⚠️ | `LipSyncView.swift:123`、手表 |
| 帧流（演出） | `PresetLiveModel.play→tick→setFrame` | `PresetLiveModel.swift:582-857` | ⚠️ | `PresetLiveView.swift:107` |

### 2.2 渲染参数

| 能力 | 入口接口 | 实现 | # | 调用方 |
|---|---|---|---|---|
| 亮度 | `BoardControlCenterModel.setBrightness` → `set_brightness` | App `BoardControlCenterModel.swift:82-88,211`；FW `protocol.cpp:1280` → `led_renderer.cpp:583` | ⚠️ 4 个入口：UI、手表直连 `WatchLinkService.swift:349-352`、GPIO `buttons.cpp:76`、串口 `serial_console.cpp:263` | 滑块 `BoardControlCenterView.swift:747` |
| 颜色 | `setColor(hex:)` → `set_color` | App `BoardControlCenterModel.swift:286-299`；FW `protocol.cpp:1278` → `led_renderer.cpp:492` | ⚠️ 3 个入口：UI、手表直连 `:386-391`、串口 | 5 个 UI 入口（sheet、hex、两个预设、accessory、toolbar） |
| 自动 / 手动 | `toggleAutoMode` → `set_mode` | App `:221-231`；FW `faces.cpp:34-85` | ⚠️ 3：UI、组轮播 `GroupAutoCycler`、手表直连 `WatchLinkService.swift:504-509`（另有 B3 按钮） | sheet、accessory、手表 |
| 上 / 下一张表情 | `step(face:)` → `button B1/B2` | App `:238-254`；FW `faces.cpp:137-145` | ⚠️ 3：UI、组轮播、手表直连 `:511-520` | sheet、accessory、手表 |
| 自动间隔 | `setAutoInterval` → `set_auto_interval` | App `:259-266`；FW `faces.cpp:88-96` | ⚠️ 2：UI、手表直连 `:378-384`（另有 B3+B1/B2 组合键） | sheet 滑块 |

### 2.3 表情库

| 能力 | 入口接口 | 实现 | # | 调用方 |
|---|---|---|---|---|
| 读整库 | `getFaces()` → `GET_FACES` 分页 + generation | `BoardConnection.swift:1232-1285`；FW `protocol.cpp:2184-2246` | 1 | `FaceLibraryModel.swift:356` |
| 显示库内表情 | `applySavedFace` → `apply_saved_face` | 转发器 `BoardConnection+Faces.swift:12`；FW `faces.cpp:116` | 1（本地表情走 `setFrame`） | `FaceLibraryModel.swift:439` |
| 单条增 / 改 / 删 / 排序 / 清空 | `faceUpsert / faceRename / faceDelete / faceReorder / facesClearUser` | 5 个一行转发 → `sendFaceOp` `BoardConnection.swift:1546-1580`；FW 共用 `mutateFacesDocument` `protocol.cpp:683-735` | 1 个内核、5 个浅包装 | FaceLibrary、Debug |
| 整库替换 | `saveFaces` → `BLOB kind:faces` | `BoardConnection.swift:1532`；FW `protocol.cpp:1816-1833, 2143-2173` | ⚠️ 与增量写入并存 | 仅导入 `FaceLibraryModel.swift:1062` |
| 排序策略 | `reorderUserFaces` / `reorderFaces` | `FaceLibraryModel.swift:884-925 / 931-981` | ⚠️ 2（前者 0 个 App 调用方） | View 只调 `reorderFaces` |

### 2.4 滚动文字

| 能力 | 入口接口 | 实现 | # | 调用方 |
|---|---|---|---|---|
| 栅格化 | `ScrollRasterizer.makeTimeline` | `ScrollRasterizer.swift:51-280`，同时产出 bitmap 和全部帧 | 1 | `TextViewModel.swift:446` |
| 单板上传 | `startScrollBitmapUpload`；mismatch 时退回 `startScrollUpload` | `BoardConnection.swift:1457 / 1420`；FW bitmap `protocol.cpp:1708-1815, 2035-2142`、raw `1641-1707, 1987-2034` | ⚠️ 2 种格式 | `TextViewModel.swift:466/479` |
| 组上传 | `uploadGroupScrollBitmap` | `BoardConnection.swift:1500`（元数据字典与单板版几乎相同） | ⚠️ 第 3 个上传入口 | `BoardGroupCoordinator.swift:758,1294` |
| 开始播放 | `BLOB_END start` / `start_scroll` / `group_start` | `protocol.cpp:2018, 2120 / 1292 / 1117` | ⚠️ 4 条路径；`start_scroll` 在 App 里 0 调用 | — |
| 暂停 / 继续 / 停止 / 定位 / 单步 / 循环 / 速度 | `pause_scroll / resume_scroll / stop_scroll / scroll_seek / scroll_step / set_scroll_loop / set_scroll_interval` | FW `protocol.cpp:1289-1325` → `scroll_session.cpp` | 各 1 | TextViewModel `:297,433,576-622`；组协调器 |
| 通用暂停 / 继续 | `pause` / `resume` | `protocol.cpp:1326-1335` | ⚠️ 与上面一行重叠，生产代码 0 显式调用 | — |
| 恢复 | `getScrollMeta` + 重新栅格化 `sourceText` | `TextViewModel.swift:695-723` | 1 | 重连 |
| 预览 | `ScrollPreviewController` 遍历 `timeline.frames`；组预览每 tick 重新采样 bool bitmap | `TextViewModel.swift:500`；`GroupScrollPreview.swift:115` | ⚠️ 两种采样器（`ScrollRasterizer.frame` 和 `GroupScrollBitmap.frame`，几乎相同） | — |

### 2.5 多板组

| 能力 | 入口接口 | 实现 | # |
|---|---|---|---|
| 同步滚动 | `BoardGroupCoordinator.play / pause / resume / step / stop / updatePlayback` | `BoardGroupCoordinator.swift`，2400 行；`play` 只是转发到 `startGroup` `:429` | 1 |
| 时钟与排程 | `clock_sample` ×8 + `ClockOffsetEstimator` + `GroupSchedule.startCommands`（`reanchorCommands` 是改名转发） | `:787-853`；`GroupSchedule.swift:7-51` | 1 |
| 普通控制扇出 | 在 `BoardConnection.command / setFrame` 内部拦截 | `GroupControlFanOut.swift`，853 行 | ⚠️ 与协调器的显式扇出并存 |
| 成员自动拨号 | `GroupAutoConnector` | 467 行，自带 backoff 和失败计数 | ⚠️ 第 3 套重连 |
| 同步自动轮播 | `GroupAutoCycler` | 436 行 | 1 |
| 控制目标 | AppStorage 字符串，在 FanOut、AutoConnector、WatchLink 里各解析一次 | `RinaBoardApp.swift:12,199-212` | ⚠️ 3 处解析，手动广播 |

### 2.6 状态与遥测

| 能力 | 入口接口 | 实现 | # |
|---|---|---|---|
| 状态 | `EV_STATUS`（lite）/ `GET_STATUS` / 每条 CMD 的回显 / 串口 `status` | `protocol.cpp:421-474, 2520, 530-549`；`serial_console.cpp:150` | ⚠️ 3 种协议形态 + 1 种串口格式 |
| 电量 | `EV_POWER` / `EV_STATUS.power` / `GET_POWER`（仅 Debug 用） | `protocol.cpp:396-413`（`addPower` 被调用 3 次） | ⚠️ 3；App UI 写成 `power ?? status?.power` `BoardBattery.swift:36` |
| 预览同步 | `EV_PREVIEW_SYNC` / `GET_PREVIEW_SYNC` | `protocol.cpp:1477-1527, 2505` | 1 个 builder、2 种投递；字段和 `EV_STATUS` 重叠 |
| 日志 | `log_subscribe` / `subscribe.log` | `protocol.cpp:1171-1183` | ⚠️ 2 种命令形态 |
| 设备信息 | `get_info` | `ConnectionViewModel.swift:205,221` + `BoardConnection+Debug.swift:24` | ⚠️ App 侧 3 个调用实现 |

### 2.7 网络与连接

| 能力 | 入口接口 | 实现 | # |
|---|---|---|---|
| 配网（凭据 / 模式 / 连接 / AP） | `wifi_*` CMD；HTTP `/api/wifi/*` | `protocol.cpp:552-638`；`web_setup.cpp:227-351`，两边都调 `wifiManager*` | ⚠️ 2 套解析 |
| 扫描 | 同步 reply → `EV_WIFI_SCAN` → `wifi_scan_result` 轮询 | `BoardConnection.swift:1600-1672` | ⚠️ 3 种完成方式 |
| 热点凭据 | `wifi_set/clear_hotspot_credentials` | `protocol.cpp:593-604` | App 里 0 调用 |
| 连接 | `BoardConnection.connect(using:)` 加 BLE / TCP 适配器 | `BoardConnection.swift:284`；`BLETransport` / `TCPTransport` | ✅ 真接缝 |
| 重连 | 自动重试（5 次）/ `retryNow` / `GroupAutoConnector` / 启动恢复 `RootTabView.swift:344` | — | ⚠️ 4 套引擎 |
| 会话 | `BoardSessionStore.session(for:)` / `backgroundSession(for:)` | `BoardSessionStore.swift:200 / 230` | ⚠️ 2 条创建路径 |
| Mac 热点 | `MacWiFiBridgeProtocol`（ObjC ABI） | `RinaMacWiFiBridge.swift`；SSID 校验做了 3 遍（bridge、adapter、`HotspotJoiner` 再轮询 15 秒） | 接缝合理，校验冗余 |

### 2.8 CMD 发送（App 内部）

| 实现 | 位置 | 差异 |
|---|---|---|
| `command(_:)` | `BoardConnection.swift:984` | 排队、扇出、解码 `CommandReply` |
| `requestReliable(_:)` | `:1044` | 不排队，要求 `ok` |
| `requestReliableDecoding<R>(_:)` | `:1058` | 不排队，泛型解码 |
| `sendFaceOp(_:)` | `:1571` | 排队，解码 `FaceOpReply`，带 generation |
| `wifiScan` / `refreshWifiStatus` | `:1617 / :1678` | 手写了一遍 encode → send → decode |
| Debug 原始发送 `send(type:payload:)` | `DebugViewModel.swift:936-964` | 绕过类型（调试工具，保留） |

⚠️ 前 5 套应合并为一个 `command<Reply>(_:policy:)`。

### 2.9 手表

| 能力 | 接口 | 实现 | # |
|---|---|---|---|
| 编解码 | `WatchLinkCodec` + `WatchLinkSessionRelay` | `RinaWatchLink/*` | 1（真复用，保留） |
| 控制命令 | `WatchCommand.*` → `WatchLinkService.handle` | `WatchLinkService.swift:334-527`：目标是手机时走 `BoardControlCenterModel`，目标是其他板时走一份重写的直连实现（文件里自己注明是 mirror） | ⚠️ 2 |
| 滚动速度 | `setScrollFps` | `:392-421`，四路分支：组协调器 / 手机组 / Text 模型 / 固件 | ⚠️ 4 |
| 快照推送 | reply + `updateApplicationContext` + live message | `:84-95, 567-584`，每条命令编码两次快照 | ⚠️ 3 种投递 |
| hex 解析、亮度百分比 | 手表本地实现 | `WatchRootView.swift:434`、`WatchSessionModel.swift:211` | ⚠️ 与手机侧重复 |

---

## 3. 架构摆放问题：数据在层间来回传

### 3.1 滚动帧：手机展开 → 只发 bitmap → 固件再展开
```
String → glyph → [[Bool]] bitmap ─┬→ [PackedFrame] ×N（手机，成功路径上只给预览用）
                                  └→ packedBytes → BLOB → FW bitmapBuf
                                       → stagingBuf(frameCount×47) → runtime scroll buf
                                       → 每 tick 拷到 nextFrame → frameBits → localFrame → RGB
```
- 窗口化是 O(370) 的位运算，在固件每个 tick 里直接从 bitmap 采样即可。这样可以删掉 staging、raw 格式、手机端的帧数组、mismatch 兜底，以及 `[PackedFrame]` 的大块分配。
- 手机预览也改成按需调用窗口函数。单板和组共用同一个采样器（合并 `ScrollRasterizer.frame` 与 `GroupScrollBitmap.frame`）。
- 重连恢复时，不再“重新栅格化，再核对帧数”，只核对 `timelineId`、`fontId`、`generatorVersion`。

### 3.2 CMD 回复是 2 KB 状态回显，和 EV_STATUS 重复
- `reply()` `protocol.cpp:530-549` 给每条成功的 CMD 填颜色、亮度、模式、播放、表情、滚动等全部字段，用的是 `DynamicJsonDocument(2048)`。
- App 读取的只有 `ok`、`autoFaceId/Index`（组表情解析）和设备名。状态同步靠 `EV_STATUS`。
- `SET_FRAME` 的回复同样带回发送方本来就有的字段（`protocol.cpp:1583-1603`）。
- **改法**：ack = `{ok, v}`，`apply_saved_face` 和 B1/B2 额外带 `faceId`、`index`、`frame`（47 字节）；`CommandReply` 从 30+ 个可选字段缩到 4 个。

### 3.3 组内换表情：板 → 手机 → 板
`apply_saved_face` 在主板执行。如果 resolver 解析不出帧：sleep 150 ms → `getFrame` 回读主板（最多 2 次）→ `setFrame` 给其他板（`GroupControlFanOut.swift:556-602`）。
- 手机本来就持有表情库（`faceFrameResolver` 已经存在）。让 3.2 的 ack 直接带回 `frame`，回读和 sleep 就都可以删掉。

### 3.4 表情持久化：真相在 JSON 文件里，每次操作都要来回解析
- 单条 rename：读整文件 → 解析 → 修改 → 校验整树 → 序列化写回 → `loadSavedFaces` 再读一遍、再解析、转成 `RuntimeFace[]`（`protocol.cpp:683-735`、`storage.cpp:335-389`）。
- 帧数据在 Swift 端经过 `[Int]`、`PackedFrame`、`hex94`、JSON、ArduinoJson、LittleFS、`[Int]`、`PackedFrame`，转了六七次（`FaceDocument.swift:29,109-140`；`RinaCommand.swift:302-340`；`FaceLibraryModel.swift:501-518`）。
- 帧解码在固件里有两份：`parseFaceFrameInput` `protocol.cpp:738` 和 `readPackedFrameBytes` `storage.cpp:218`。
- **改法**：以 `RuntimeFace[]` 为唯一真相，修改内存后序列化写盘，不再回读。Swift 端统一用 `PackedFrame` 的 Codable 表示，hex 只在 JSON 边界出现一次。整库导入改为“清空 + 批量 upsert”，或保留一个 `faces_replace` 命令但共用同一个事务，删掉 `BLOB kind:faces`。

### 3.5 状态多源
- 固件：颜色存了 hex + RGB 四份（`state.h:23-27`）；滚动活动状态由 `firmwareScrollActive`、三个 pause 标志、`paused` 和 `playback` 字符串共同表示（`state.h:28-69`）；输出归属用 `mode`、`outputMode`、`playback`、`lastReason` 四个字段表示，`SET_FRAME` 还要解析 reason 字符串来推导归属（`protocol.cpp:1573-1582`）。
- App：`BoardConnection` 同时持有 `status`、`preview`、`power`、`wifi`、`currentFrame`，`applyStatus` 要合并新旧值（`BoardConnection.swift:801-823`）；控制中心有 5 个 draft，各带 2 秒回显窗口；Debug 又单独拉一份 `getStatusRaw`，而且不经过 `applyStatus`。
- 物理身份分布在 6 个地方：`BoardSession.boardID/aliases`、`BoardConnection.boardIdentity/lastKnown`、`KnownBoard.physicalBoardID`、`BoardGroup.Member.knownBoardIDs`。
- **改法**：协议上只推一份 `BoardState`（power、wifi、preview 作为字段，按 version 推送）；App 侧只保留 `connection.state` 一个值，UI 去掉 `??` 兜底链。固件侧用一个 `ScrollPhase` 枚举加 user / system 两个 pause 原因，effective pause 和 `playback` 字符串在序列化时现算。`SET_FRAME` 用独立的 `owner` 字节，不再解析 reason。

### 3.6 组控制侵入连接层
- `BoardConnection.command / setFrame` 里出现了 `fanOut?.dispatch`、`.resolveFace`、`beginLeasedAction` 这些组相关逻辑（`:1009-1031, 1182`），连接层因此要知道“组”的概念。
- 组相关拆成 4 个模块，各自观察 sessions 和 groups，各自解析目标字符串；FanOut 和 AutoConnector 持有同一个目标。
- **改法**：合并成一个 `GroupRuntime`。它持有所有成员连接，对外提供 `command / setFrame / play...`，内部决定是单播还是扇出；`BoardConnection` 退回纯点对点。重连只保留 `BoardConnection` 一套，`GroupRuntime` 只负责“哪些成员需要拨号”。

### 3.7 手表链路：JSON 套两层 + 控制逻辑重写一份
`Double → WatchCommand → JSON → plist 信封 → JSON → enum → [String:Any] → JSON → RinaLink 帧`
- 直连分支把模式切换、换表情、亮度和间隔的 clamp、fps 换算重写了一遍。
- 每条命令先在 reply 里编码一次快照，然后 `publish(force:)` 再重建、再编码一次。
- **改法**：两种目标都调用同一组 `ControlActions(connection:, updateDrafts:)`；快照每条命令只构建一次。

### 3.8 同一能力，固件有多套解析
- HTTP 门户把 6 个 Wi-Fi 操作重新解析了一遍（`web_setup.cpp:227-351`）。
- 串口把 frame、button、color、bright 各自解析了一遍（`serial_console.cpp:197-290`）。
- **改法**：两者都把输入翻译成同一个 `CMD` JSON，交给 `handleCmd`，只做输入和输出的适配。

---

## 4. 浅模块 / 臭抽象（删除测试：删掉后复杂度不会转移到别处）

**一行转发**：
- App：`BoardConnection.applySavedFace`、5 个 `face*` 包装、`events()` 与 `subscribeToEvents()`（两种订阅形式，应合并为一种）、`saveFaces`、`BoardGroupCoordinator.play`、`.session(for:)`、`BoardPlaybackCoordinator.claim/isCurrent`、`MacWiFiAdapter.currentSSID`、`WatchSessionModel.refresh/stepFace`、`WatchCrownInput.synchronize`。
- RinaCore：`GroupSchedule.reanchorCommands`、`RinaLinkEncoder.encode(type:seq:flags:payload:)`、`PartsLibrary.frame(for:)`、`RinaLinkConstants.maxPayloadBytes`（别名）。
- 固件：`showCurrentFrameNoLock`（就是 `requestLedRender`，名字还有误导）、`startServer`、`existsFs`、`openFs`、`isAutoMode`、`scrollSessionExitGroupTimed`、`scrollSessionGet/SetRestoreAuto`、`scrollSessionFillPresentationContext`。
- 固件 `RuntimeStore`：每个字段都同时提供成员访问器和全局自由函数，两套接口，应只留一套（`state.h:127-178`、`state.cpp:75-141`）。

**0 调用者（已 grep）**：
- `RinaFaceSync` 整包（约 1,070 行，App 3 个 target 都没有 import）。
- `AppDefaults`、`RinaResources.appDefaults`、`RinaResources.matrixGeometryJSON`、`ErrorReply`。
- `CardContainer`、`BoardConnection.loadFaceDocument`、`FaceLibraryModel.exportData()`、`importDocument(from:connection:)`、`reorderUserFaces(_:connection:)`；`apply / rename / delete` 的 board-only 重载只有硬件测试在调用。
- `BoardBatteryRow.init(connection:)`、`KeychainStore.delete`、`WatchSessionModel.isActivated`、`DebugPackedParse`。
- 命令：`start_scroll`、`terminate_other_activities`、`wifi_set/clear_hotspot_credentials`、通用 `pause` / `resume`。

**保留（真接缝，不是臭抽象）**：
- `RinaTransport`（BLE/TCP）、固件 `ITransport`：各有两个生产适配器。
- `LipSyncCapturing`、`LocalFaceStoring`、`BLEConnecting`、`BoardScanning`：有多个测试 fake，是测试接缝。
- `MacWiFiBridgeProtocol`：Catalyst 不能直接用 CoreWLAN，这是 ObjC ABI 边界。
- `WatchLinkSessionRelay`：删掉的话，两端会各复制一份 delegate 代码。

**不建议新增**：在 `BoardConnection` 前面再加一个 “command gateway”。合并现有的 5 套执行器就够了。

---

## 5. 冗余与兜底（建议删除，除非注明）

| 项 | 位置 | 处理 |
|---|---|---|
| bitmap mismatch 退回 raw 帧 | `TextViewModel.swift:472-487`、`BoardConnection.swift:1420-1447`、FW raw 分支 | 删（随 3.1 一起） |
| Wi-Fi 扫描三路完成 | `BoardConnection.swift:1600-1672` | 只留事件 + 超时；删 `wifi_scan_result` |
| legacy reason 推导恢复模式 | `BoardResumeMode.swift:19-83` | 改用 owner 字段后删除 |
| 组表情 sleep + 回读 | `GroupControlFanOut.swift:592-602` | 随 3.3 删除 |
| `power ?? status?.power` | `BoardBattery.swift:36` | 随 3.5 删除 |
| 重复校验：帧 47 字节、hint 范围、滚动 fps、文本 4096 字节、hex 解析 3 次、表情名清洗 2 次 | `protocol.cpp:1566` 与 `led_renderer.cpp:423`；`TextViewModel.swift:381/417`；`BoardControlCenterModel.swift:274/279/287` 等 | 只在拥有该不变量的那一层校验 |
| lip-sync 参考 DSP 与缓存 DSP 两套 | `LipSync.swift:239-306` vs `LipSyncDSPEngine.swift` | 参考实现移到测试里做差分基准 |
| `Messages.swift` 全可选字段 + int/float 双解码 + `PowerStatus` 两种布局 | `Messages.swift:3-95` | 固件和 App 同仓发布，改成必填 |
| `FaceDocument` 吞掉坏数据，另开 `decodedForImport` 输出诊断 | `FaceDocument.swift:72-106, 209-283` | 一个严格解码器 |
| 手表 8 次 × 1.5 秒激活重试、口型开始后再轮询 2 次 | `WatchSessionModel.swift:72-82, 199-207` | 依赖 applicationContext，删掉轮询 |
| Mac SSID 三重校验 + 15 秒轮询 | `HotspotJoiner.swift:40-92` | adapter 返回 SSID 后直接采用 |
| PSRAM → heap 回退（5 处） | `state.cpp:14-52`、`protocol.cpp:1684` 等 | 两块板都带 PSRAM，确认硬件后改成启动时断言 |
| 渲染任务创建失败时回退到主循环渲染 | `scroll.cpp:78-96` | 同上，改断言 |
| 模拟器把未知命令一律回 `ok` | `tools/rinalink_board_emulator.py:176,251` | 改成报错，暴露协议漂移 |

---

## 6. 执行顺序（按收益 / 风险排序；行数为估计值）

| # | 动作 | 删减 | 风险 |
|---|---|---|---|
| 1 | 删死代码：`RinaFaceSync` 包、`AppDefaults`、§4 的 0 调用者转发和命令 | ~1,400 | 低。`RinaFaceSync` 需要用户确认是否保留为计划中的功能 |
| 2 | CMD ack 瘦身（3.2）+ `apply_saved_face` 回带帧，删组回读（3.3） | FW ~40、App ~80、`CommandReply` 26 个字段 | 低 |
| 3 | App 侧 5 套 CMD 执行器合并为 `command<Reply>(_:policy:)` | 100–160 | 中（扇出和丢弃语义） |
| 4 | 滚动只保留 bitmap：固件按 tick 采样，手机不再展开帧，删 raw 格式和兜底，3 个上传入口合并为 1 个 | 400–600 | 高（tick、seek、组游标都依赖帧缓冲；需要 `stress_findings` 和双板实测） |
| 5 | 状态统一为一份 `BoardState` 推送；`DeviceStatus` 作为唯一缓存；删 `GET_POWER`、`EV_POWER` 重复字段和 UI 兜底 | 150–250 | 中高 |
| 6 | `GroupRuntime` 合并 FanOut + AutoConnector（+ 协调器的参与者循环），让 `BoardConnection` 不再知道组 | 300–500 | 高 |
| 7 | `FrameStreamer` 合并视频、口型、演出外壳，同时合并 video 和 performance 的播放控件行 | 250–400 | 中 |
| 8 | 手表直连改走 `ControlActions`；快照每条命令只构建一次 | 100–160 | 中 |
| 9 | 固件：HTTP 和串口改为翻译成 CMD 交给 `handleCmd`；`RuntimeStore` 只留一套访问器；`ScrollPhase` 枚举；表情以 `RuntimeFace[]` 为真相 | 300–450 | 中高 |
| 10 | UI：电池 3 种画法合 1、颜色预设 3 处合 1、连接状态文案 2 处合 1、`get_info` 3 处合 1 | 250–350 | 低 |

总计约 3,000–4,500 行。第 1–3 步可以立刻做；第 4–6 步需要改协议，App 和固件必须同时发布，并做双板硬件回归。
