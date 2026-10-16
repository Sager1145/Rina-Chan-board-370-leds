# iOS 与固件联合接口审计：功能 → 接口 → 实现（基线 c409ea8）

日期：2026-10-15。基线：`main` = `c409ea8`（含板上表情库、多板保存与复审修复）。本文只审查，未改功能代码。

## 1. 结论

上午的接口审计（[2026-10-15-interface-audit](2026-10-15-interface-audit.zh-CN.md) §11）列出的阶段 1–5 已落地：回复已精简，组 hook 已移出连接层，文字改为按需取帧。本轮在 `c409ea8` 上重新盘点。剩下的冗余**集中在新加的表情保存链路**，其次是几处“同一事实走两条通道”。

按收益排序，最值得做的五项：

1. **parts/custom 判定在 3 处各做一次**（F1）。App 的 `ControlViewModel`、`FaceLibraryModel.canonicalPayload` 和固件 `canonicalizeSavedFaces` 都“合成部件 → 与位图比对 → 决定存引用还是存位图”。为此 App 还要维护能力位、`partsReferenceOnly` 字段和两处硬编码的目录名。这件事只该在固件做一次。
2. **`face_upsert` 是唯一一个成功后必定全库回读的写操作**（F2）。rename、delete、reorder 都按“回复 gen = 原 gen + 1 → 本地修补”的规则处理，只有 upsert 每次都重新下载并解析整份库。多板保存时每块板要读 2 次，主板还有第 3 次。
3. **状态事件里已有 `facesGeneration`，App 没有解码**（F3）。结果是 App 为了拿到一个 4 字节的代次，要下载整份表情库（`BoardConnection.swift:1718`），而且只能通过写入时碰到 409 才知道别的客户端改过库。
4. **固件写一次表情，就对全库做 4 遍校验或合成，外加 2 次读文件和整库解析**（F4）。权威文档没有常驻内存：每次修改都先读文件，下一次 GET_FACES 再读文件、展开、序列化一遍。
5. **单板保存与多板保存是两套状态机，各用一份日志**（F5）。单板保存其实就是只有一个目标的多板保存。两套实现现在靠互相查对方的日志来避免冲突。

更底层的一条放置问题：**表情库在 App 有两层缓存**，`BoardConnection.verifiedFacesCache` 存原始字节，`FaceLibraryModel.faceDocument` 存解析结果，此外每个多板目标还会临时新建一个 `FaceLibraryModel`。数据在这几层之间反复“下载 → 解析 → 丢弃 → 再下载”，F2、F3、F5 都是这个问题的表现。

## 2. 范围与方法

- 词汇沿用 `mattpocock-skills:codebase-design`：module、interface、depth、seam、adapter，判定用 deletion test（删掉这个 module，复杂度是消失了，还是分散回 N 个调用方？）和“一个 adapter 是假想 seam，两个才是真 seam”。
- 读取由 3 个 Sonnet scout 并行完成：固件接口清单、iOS 接口清单、跨层数据流。下列结论我已亲自对照源码核实：F1–F4、F8 的 RatePump 串行、F9 的同步回读、F10 的 power 双写，以及 F11 的 AP 双重校验。
- 已纳入 `ios/Packages/RinaCore` 和 `esp32s3_firmware/test/host`（以往外部报告常漏这两处）。
- 未跑构建、测试或硬件；没有实测耗时。性能结论是“次数”，不是“毫秒”。

## 3. 功能 → 线上接口 → 实现 总表

“一对一”是指一个能力只有一个线上接口和一个实现 module；入口（按钮、页面）可以有多个，只要它们调用同一实现。

| 能力 | App 实现 owner | 线上接口 | 固件实现 | 判定 |
|---|---|---|---|---|
| 连接/握手 | `BoardConnection.establish` :358 | PING、subscribe、GET_STATUS、GET_FRAME、GET_PREVIEW_SYNC、get_info | `dispatch` protocol.cpp:2347 | 一对一；**读取重复**（F9） |
| 亮度/颜色/自动间隔/模式/按钮 | `BoardControlCenterModel` :87–253 | `set_*`、`button` | `setBrightness` 等，按钮、串口、CMD 共用 `runButtonAction` buttons.cpp:157 | 固件一对一；**App 有两份**（Watch direct 路径，F6） |
| 应用已存表情 | `FaceLibraryModel.apply` :429 | `apply_saved_face` → `{frameHex}` | `applySavedFaceIndex` faces.cpp:116 | 一对一 |
| 新增/覆盖表情 | `ControlViewModel.saveEditedFace`、`FaceLibraryModel.save`、`MultiBoardFaceSaveCoordinator.run` | `face_upsert` | `mutateFacesDocument` → `writeSavedFaces` | **App 三个 owner**（F1、F5）；**回读冗余**（F2） |
| 改名/删除/排序 | `FaceLibraryModel` :787/:887/:1070 | `face_rename/delete/reorder` | 同上 | 一对一（依 gen 本地修补） |
| 整库导入 | `FaceLibraryModel` :1208 → `saveFaces` | blob `faces` | blob END → `writeSavedFaces` | 与增量写共用写入实现；保留两种粒度（§8） |
| 读表情库 | `BoardConnection.getFaces` + `FaceLibraryModel.reload` | GET_FACES（分页、ifUnchanged） | `prepareFacesReadSnapshot` :2240 | **两层缓存**（F5）；固件每代读文件一次（F4） |
| 文字滚动 | `TextViewModel`、`BoardGroupCoordinator` | blob `scroll` / `scroll_bitmap`，`*_scroll` | `scroll_session.cpp` | 一对一；固件 bitmap 仍整段展开（§7 遗留） |
| 实时帧（画板/视频/口型） | 各 model → `setFrame` :1246 | SET_FRAME → `{ok}` | `handleSetFrame` :1609 | 一对一；**每帧一次往返**（F8） |
| 状态/预览/电量 | `BoardConnection.applyStatus` :842 | EV_STATUS、EV_PREVIEW_SYNC、EV_POWER | `serviceProtocolEvents` :2529 | **电量两条通道**（F10） |
| Wi-Fi 配网 | `ConnectionViewModel` :979–1065 | `wifi_*` ×10；HTTP `/api/wifi/*` | `wifiManager*` | **入口校验与流程两份**（F11） |
| 组模式 | `BoardGroupCoordinator` 等 5 个 module | identify、clock_sample、group_start、blob | `scrollSessionGroupStart` | 上午已判定不合并（§8） |
| 改名设备/提示灯/重启/电池校准 | Settings、Debug | `set_device_name` 等 | 各自 inline | 一对一 |
| 调试终端 | `DebugViewModel` | 任意原始帧 | — | 调试 adapter，不计 |

线上接口面：13 种请求、44 个 CMD 名、3 种 blob、6 种事件；HTTP 8 个端点、串口 8 条命令（逐项清单见固件 scout 报告的要点，本文 §6 只列有重复的部分）。

## 4. 数据跨层往返（次数）

### 4.1 单板保存一个表情（`ControlViewModel.saveEditedFace`）

| 步 | 位置 | 成本 |
|---|---|---|
| 1 | `ControlViewModel` :864：若 `currentFacesGeneration == nil` 先 `library.reload` | 0–1 次全库 GET |
| 2 | `BoardConnection.faceWriteMetadata` :1718：`facesGen == nil` 时再 `getFaces()` | 0–1 次全库 GET（**只为拿 gen**） |
| 3 | `persistDraft` | 写草稿文件 |
| 4 | `sendFaceOp` :1738：`cmd.encode()` → `JSONSerialization` 解析 → 合并元数据 → 再编码 | App 3 遍 JSON |
| 5 | 固件 `mutateFacesDocument` :690 | 读文件 + 整库解析 |
| 6 | `validateSavedFaces`（:720）→ `canonicalizeSavedFaces` 内两次 validate（storage.cpp:322、:345）→ `prepare` 再 materialize（:485） | 全库 4 遍校验/合成 |
| 7 | `writeJsonFileAtomic` → `publish`，回复 `{ok,v,gen,count}` | 写文件 |
| 8 | `FaceLibraryModel.saveBoardPayload` :652：**无条件** `reload` | 全库 GET（N+1 次往返） |
| 9 | 固件 `prepareFacesReadSnapshot`：再读文件、解析、展开（再 validate + materialize）、序列化 | 读文件 + 全库 2 遍 |
| 10 | App `reload` :368–374：`JSONSerialization` 一遍 + `JSONDecoder` 一遍 | 全库 2 遍解析 |
| 11 | `matchesSavedPayload` 比对 | — |

为改一个 47 字节的表情：至少 2 次请求（常见 3–4 次），固件读文件 2 次、全库校验/合成 6 遍，App 全库解析 2–6 遍。

### 4.2 多板保存（`MultiBoardFaceSaveCoordinator.run` :188）

每个目标：持久化日志 3 次以上、新建一个临时 `FaceLibraryModel()`（:205）、写前 `reload`（:211）、`save` 内再 `reload`（4.1 第 8 步），即全库 GET 2 次 + upsert 1 次。保存结束后 `ControlView.swift:496` 再对主板 `reload` 一次。

### 4.3 连接

握手：PING、subscribe、GET_STATUS、GET_FRAME、GET_PREVIEW_SYNC、get_info（`BoardConnection.swift:358–400`、:813、:1143）。之后 `BoardSyncCoordinator.swift:130–131` 再读 GET_STATUS + GET_PREVIEW_SYNC，`ControlViewModel.swift:1163` 再读 GET_FRAME，`ConnectionViewModel.swift:210/236` 再读 get_info，然后读表情库。读状态共约 9–10 次往返，其中 3–4 次是重复读刚读过的数据。

这次重复读**在现行事件语义下是对的**：状态事件最短间隔 200 ms、预览只在变化时发，H1 已证明复用握手快照会错过变化。问题出在协议形状上（F9），而不在同步代码。

### 4.4 实时帧

每帧：`framePump`（`RatePump` depth 6、20 ms，actor 内 `isBusy` 串行）→ SET_FRAME 二进制 → 固件构造 JSON `{ok}` → App `JSONDecoder` → 下一帧才能发。帧率上限因此是 `1 / max(20 ms, RTT)`。另外板子还会单独发预览事件回显。

## 5. 问题与收敛方向

格式：现状 → deletion test → 一处实现应在哪 → 删掉什么 → 风险。“Strong”表示有直接源码证据、且收敛方向唯一；“Worth exploring”表示需要先测量或做产品取舍。

### F1 parts/custom 判定三处重复 — Strong

- **现状**：
  - `ControlViewModel.swift:896–900` 先根据 `supportsPartsReferences` 设置 `partsReferenceOnly` 和目录名 `"rina_expression_parts_370_runtime_v4"`/`4`，紧接着 :901 调用 `canonicalPayload` 又重算一遍。
  - `FaceLibraryModel.canonicalPayload` :489–514 合成部件、比对 `hex94`，再写一次同样的硬编码目录名。多板保存在 `MultiBoardFaceSaveCoordinator` :171、:218 各调一次。
  - 固件 `canonicalizeSavedFaces` storage.cpp:321 在**每次写入**时都做同样的“合成并比对，相同就去掉 frameBytes 存引用，不同就降为 custom”。
- **Deletion test**：删掉 App 侧的两处，固件仍会把纯部件表情存成引用，行为不变。复杂度消失，没有转移到别处，说明这是纯 pass-through 的重复。
- **一处实现**：只在固件。App 一律发送 `{id, name, type, call?, frameHex}`（frameHex 永远带上，作为权威像素），存储形式由固件决定。
- **删除**：`canonicalPayload`、`partsReferenceOnly`（RinaCommand.swift:315、:331）、App 内两处目录名硬编码，以及 `supportsPartsReferences` 在保存路径上的全部分支（如无其他用途，能力位本身也可删）。
- **兼容**：旧固件本来就收 frameHex 并存位图，新 App 一律带 frameHex 对旧固件更安全。`matchesSavedPayload` 的目录比对（:684）改为只比像素、名称、类型和顺序。
- **风险**：低。需要改 `BoardOwnedSaveSafetyTests`、`MultiBoardFaceSaveTests` 里断言 `partsReferenceOnly` 的用例。

### F2 upsert 后无条件全库回读 — Strong

- **现状**：`FaceLibraryModel.saveBoardPayload` :652 在 upsert 成功后一定 `reload`。而 rename、delete、reorder 在 `lastFaceOpGenMatchedExpectation`（BoardConnection.swift:1755）成立时直接修补本地文档（FLM :819、:908、:1051、:1083）。固件 upsert 回复只有 `{ok,v,gen,count}`（protocol.cpp:735–741），App 不知道固件实际落盘了什么（例如是否被降为 custom），只能整库读回。
- **一处实现**：所有写操作用同一条规则：“回复带被写记录 && gen = 原 gen + 1 → 本地修补；否则 reload”。为此 `face_upsert`（以及 rename）的回复要附上被写记录的展开视图，至少包括 `id, name, type, order, call?, frameHex`。固件在 `mutateFacesDocument` 里已经持有这份 JsonObject 和 47 字节，追加字段几乎零成本。
- **删除**：单板保存的 1 次全库 GET，多板保存每个目标的 1 次，`ControlView.swift:496` 的主板补读，以及保存核对对整份列表的依赖。`matchesSavedPayload` 直接与回复记录比对。
- **兼容**：旧固件没有记录字段，自然走 reload 分支，与 F3 的现有规则（“无 gen → reload”）是同一条分支，不新增代码路径。
- **风险**：中低，属协议回复的增量字段。验收：用 `FacesTransferTests` 统计保存一次的 GET_FACES 次数从 ≥1 降到 0；固件 host 测试覆盖“降为 custom”的回复内容。

### F3 状态里的 facesGeneration 未被使用 — Strong

- **现状**：`buildStatusJson` protocol.cpp:421 在每个状态事件里都带 `bootId` 和 `facesGeneration`。RinaCore 的 `DeviceStatus` 没有这个字段（全仓 Swift 无 `facesGeneration`）。App 的 `facesGen` 只能从 GET_FACES 或写回复里得到。于是：
  - `faceWriteMetadata` :1718 在 `facesGen == nil` 时下载整份库，只为拿 gen；
  - 别的客户端（另一部手机、Watch 经手机、整库导入）改了库，App 要等下次写入碰到 409，或者靠各错误路径上的 `reload` 才发现。
- **一处实现**：`DeviceStatus.facesGeneration` 解码后成为 `facesGen` 的唯一来源，写回复只负责推进它。状态里的 gen 与缓存不一致时，把列表标记为过期，可见时再按需 `reload`；不可见时不读。
- **删除**：`faceWriteMetadata` 里的 `getFaces()`，以及一批“出错就 reload 以防万一”的分支（`handleFaceOpError` FLM:1446、`validateBoard` :1433 可重新评估）。
- **风险**：低，不改协议。注意状态事件有 200 ms 限频：写入前仍以写条件（expectedGen → 409）为最终保护，状态里的 gen 只用于提前失效，不作为写入许可。

### F4 固件表情权威文档不常驻，写一次校验 4 遍 — Strong（固件内部）

- **现状**：见 §4.1 第 5–9 步。`validateSavedFaces` 本身就逐项 `materializeSavedFace`（storage.cpp:415），`prepare` 又逐项 materialize 一遍（:485），`canonicalize` 前后各 validate 一次。`mutateFacesDocument` 和 `prepareFacesReadSnapshot` 都从 LittleFS 读文件再整库解析，可文件内容正是上一次 `writeSavedFaces` 刚写下的那份。
- **一处实现**：PSRAM 中常驻一份已规范化的 `PsramJsonDocument` 作为唯一权威。写入路径改为：复制 → 修改 → **一遍** `prepare`（校验 + 合成 + 建 RuntimeFace 表）→ 原子写文件 → 交换文档与运行表。读快照直接从常驻文档展开，不再读文件。启动时读一次文件。
- **删除**：`mutateFacesDocument`、`prepareFacesReadSnapshot` 中的读文件和解析；`canonicalize` 内的重复 validate；`mutateFacesDocument` 与 `writeSavedFaces` 各自的 `measureJson` 上限检查（protocol.cpp:724 与 storage.cpp:567，合并为一处）。
- **风险**：中。内存上限受 `MAX_FACES_DOCUMENT_BYTES` 约束，需在 host 测试中量化“常驻 + 写时副本”的 PSRAM 峰值。写失败时旧文档和旧运行表都要保持不变，现有 `PreparedSavedFaces` 的“先准备、文件 rename 后再交换”模式可直接沿用。验收：`saved_faces_storage_test.py`、`faces_transfer_test.py`，以及在 128 项库上测一次写的耗时。

### F5 表情状态：两层缓存 + 三份日志 + 两套保存状态机 — Strong（方向），排在 F1–F3 之后

- **现状**：
  - 列表：`BoardConnection.verifiedFacesCache`（原始 Data）与 `FaceLibraryModel.faceDocument`（解析后）。即使 `ifUnchanged` 命中，`reload` 仍要把缓存字节再解析 2 遍（FLM:368–374）。多板保存每个目标还新建一个临时 `FaceLibraryModel`（MultiBoardFaceSaveCoordinator:205）。
  - 待确认写：`Drafts/face.json`（编辑草稿 + 基线）、`board_face_creates`（FLM:549–603）、`multi_board_face_save`（+`_unreadable`）。多板协调器启动时调用 `ControlViewModel.hasPendingSave` 检查单板日志（Coordinator:131），两套日志靠互查避免冲突。
  - 保存状态机：`ControlViewModel.saveEditedFace` 的 `pendingBoardSave` 一套，`MultiBoardFaceSaveCoordinator` 的 target 状态（saving/pending/confirmed/conflict/unavailable）一套。
- **Deletion test**：删掉单板那套，单板保存可以表达为“只有一个目标的多板保存”，复杂度不会回到调用方。说明两套状态机并非两个真实变体，属于“能用 A 解决却拆成 A/B”。
- **一处实现**：
  1. 每个 `BoardConnection` 持有一份已解析的 `FaceDocument`，以 `(boardID, bootId, gen)` 为键。`FaceLibraryModel` 只保留视图状态（选择、排序、编辑中），多板目标直接用目标连接的库。
  2. 一份“待确认表情写入”日志，记录 `{目标板, id, payload, 基线, 状态}` 的数组；单板保存是长度 1 的数组。
- **删除**：`verifiedFacesCache` 与 `faceDocument` 之一、临时 `FaceLibraryModel`、`board_face_creates` 与单板 `pendingBoardSave` 的独立持久化，以及两套状态机之间的互查。
- **风险**：中高。这部分是另一个对话刚写完的代码（记忆中 C1“合并三份日志”已约定等它落地后再做）。先做 F1–F3，状态机的分支会自然减少，再做本项。验收以 `BoardOwnedSaveSafetyTests`、`MultiBoardFaceSaveTests` 全绿为准，并补“单板 = 一个目标”的等价用例。

### F6 Watch 的 direct 路径重复实现控制命令 — Worth exploring

- **现状**：`WatchLinkService.swift:349–386` 的每个控制都有 `phone:`（调 `BoardControlCenterModel`）和 `direct:`（自己 clamp 后直接 `c.command(...)`）两个闭包。clamp、颜色规范化、自动间隔的毫秒换算在 Watch 和控制中心各写一份。控制中心还有 `LatestValueSender` 合并与 touch 窗口，direct 路径没有。
- **一处实现**：把“对某个连接设置亮度”等动作做成接受 `BoardConnection` 的单一函数，由 `BoardControlCenterModel` 暴露（它的 `setBrightness(_:connection:)` 已经接受 connection 参数）。Watch 两条路径只在选择目标连接上不同。
- **前提**：先确认 direct 路由存在的原因（未同步组或非活跃板），确保单一函数不会改动当前选中的连接（见记忆：Watch 不改手机端选择）。

### F7 发送执行器的残余重复 — Worth exploring，低风险

- `sendFaceOp` :1738 先编码，再解析回字典合并元数据，再编码。只要 `RinaCommand` 的表情 case 自带 `expectedBootId/expectedGen/createOnly`，就只需编码一次，`sendFaceOp` 也能退化为 `command()` 加表情的 gen 处理。
- `startScrollUpload` :1558、`startScrollBitmapUpload` :1594、`uploadGroupScrollBitmap` :1637 是 `uploadBlob` 的三个外壳，只差 meta 字段，可合为一个 `uploadScroll(meta:)`。
- `getStatusRaw`、`getDeviceInfo`（`BoardConnection+Debug.swift`）重复了正式读取，Debug 可直接用正式方法再序列化显示。

### F8 实时帧每帧一次往返 + JSON 确认 — Worth exploring（需测量）

- **现状**：见 §4.4。实时帧本质是 latest-wins 的流，却按请求-响应处理：每帧都要等固件构造 JSON `{ok}`、App 解码后才发下一帧。在 BLE 上，RTT 直接就是帧率上限。
- **方向**：帧流不逐帧确认（或改为 1 字节二进制确认），送达与呈现由预览事件里已有的 `presentedSeq` 反映；错误用事件或下一次控制命令的回复报告。
- **前提**：先在 BLE 和 TCP 上分别实测视频与口型的实际帧率和 RTT。若 RTT 远小于 20 ms，此项收益有限，不做。属协议改动，需 App 与固件配套。

### F9 连接时的状态重复读取 — Worth exploring

- **根因**：状态有两种交付方式，主动读取和“变化且限频”的推送，订阅时却没有“立即推送当前快照”这一步，所以每个消费者都必须自己再读一遍才能确定状态是新的。
- **一处实现**：`subscribe` 的回复（或订阅后立即推送的首个事件）携带当前 `status`、`preview` 和 `v`。App 按 `v` 取最新值作为唯一权威。握手里的 GET_STATUS 和 GET_PREVIEW_SYNC 以及同步时的重读都可删掉。
- **注意**：`currentFrame` 不随事件更新（`BoardSyncCoordinator.swift` 注释已说明），GET_FRAME 的重读另需让 `apply_saved_face`/预览携带帧，或保留 GET_FRAME。不要在没有新协议保证时撤掉现有重读，H1 就是这样出的问题。

### F10 同一事实走两条事件 — Worth exploring，低

- **电量**：精简状态 `buildStatusJson(lite)` 总是 `addPower`（protocol.cpp:427），EV_POWER 又每 1 s 单独发一次。App 在 `applyStatus` :853、:862 和 EV_POWER 处理中都写 `power`。应只保留一个 owner，建议 EV_POWER，并从精简状态里去掉 power。
- **滚动字段**：`addScroll` :365、GET_SCROLL_META :1499、`buildPreviewSyncJson` :1538 是三个各自列字段的构造器。应按 owner 划分：时间线身份（id、帧数、rotation）只放 scroll meta，呈现位置只放 preview，status 只放模式与设置。三个构造器共用一个字段写入函数。
- 上午 §11.2 已否决“合成一个高频 BoardState”，理由是带宽。本项不是合并，而是去掉重叠字段，方向相反。

### F11 固件多入口的校验与流程分叉 — Worth exploring，低

- **AP 设置**：HTTP `handleAp` web_setup.cpp:337 自己检查密码长度，`wifiManagerSetAp` wifi_manager.cpp:706 又检查一遍，错误码也不同。应删掉 HTTP 那份，由 manager 返回错误原因，两个 adapter 原样转出。
- **STA 凭证**：HTTP `/credentials` 是“设凭证 → `SetMode("sta_or_ap")` → `Connect()`”一步完成（:289–290），CMD 只设凭证，App 自己再发 `wifi_set_mode`、`wifi_connect` 两条（ConnectionViewModel.swift:1005–1007）。同一个用户意图在两端有两种编排。应在 `wifiManager` 提供一个“应用凭证并连接”的函数，HTTP 和 CMD 都调用它，App 从 3 条命令减为 1 条（CMD 加 `connect: true`，旧固件保留 3 条序列）。
- **帧十六进制解析**：`parseFaceFrameInput` protocol.cpp:771 与串口 `parsePackedHex` serial_console.cpp:91 是两个十六进制解码器，`frameBytes` 数组解析也有两份（protocol.cpp:791 与 storage.cpp `readPackedFrameBytes`，整数类型检查不同）。各合为一个。
- **停止滚动序列**：`stopFirmwareScroll(false,false,false); setMode("manual",false); scrollSessionSetRestoreAuto(false)` 在 protocol.cpp:1419、:1429 重复，buttons.cpp:112 是其子集，可抽成 `enterManualFace()`。

### F12 固件状态的派生字段被存储 — 低

- `firmwareScrollPaused` 恒等于 `UserPaused || SystemPaused`（scroll_session.cpp:175–178），却作为独立字段在 7 处写入，`RuntimeState.paused` 也同时被赋值。应改为读取时计算，消除“忘记同步”的可能。
- `colorHex` 与 `colorR/G/B` 双存（led_renderer.cpp:481、:495、:592）。可以只存 RGB，输出时再格式化。

## 6. 入口重复，但已共用实现（不需要改）

| 能力 | 入口 | 共用实现 |
|---|---|---|
| 按钮动作 | 物理键、CMD `button`、串口 `btn` | `runButtonAction` buttons.cpp:157 |
| 颜色/亮度 | CMD、串口、按键 | `setColor`/`setBrightness` |
| 下一个/上一个表情 | 按键、串口、CMD | 最终都进 `applySavedFaceIndex` |
| Wi-Fi 状态/扫描 | CMD、HTTP、事件 | `wifiManagerGetStatusJson`/`GetScanJson` |

这些入口是真正的 adapter（来源不同），实现只有一份，符合“一个接口一个实现”。

## 7. 上午遗留、本轮未重复展开

- **固件 scroll_bitmap 仍把整段位图展开成全部帧**，再拷贝进时间线（protocol.cpp:2090 起，`scrollBitmapBuildFrame` → staging → `scrollSessionPublishReplace`）。这是固件里剩下最大的一份数据复制。按 tick 从 bitmap 取帧仍是上午的阶段 6，需要双板硬件回归。
- **旧固件 fallback**（`apply_saved_face` 无 `frameHex` 时 150 ms 回读，GroupControlFanOut.swift:652）：要等产品确定支持的固件范围后才能删。

## 8. 明确不改（上午已判定，本轮复核仍成立）

- 整库导入（blob `faces`）与增量写共存：粒度不同，并且已共用 `validateSavedFaces` + `writeSavedFaces`。若改成“清空 + 多次 upsert”，会产生部分写入的窗口。
- HTTP 和串口不转换成 CMD JSON：它们是输入 adapter，转换只会增加一次编解码。真正的重复在校验，F11 只处理这一部分。
- 两套重连调度、组模式 5 个 module 不合并：生命周期和 `isExplicit` 语义不同。
- 固件“磁盘存部件引用、GET_FACES 下发展开视图”：这是固件内部的存储选择，对外只有一种视图，可以保留。冗余在于每次读都重新展开，F4 用常驻文档解决，不必改存储格式。

## 9. 无生产调用者

| 位置 | 项 | 说明 |
|---|---|---|
| 固件 | `writeStringToFileLocked` storage.cpp:80 | 全仓无调用 |
| 固件 | `installSavedFacesDocument`、`canonicalizeSavedFaces` 在 storage.h 公开 | 只在文件内使用，可改为 static |
| RinaCore | `IdentifyReply`、`GroupStartReply`（Messages.swift:904、:935） | 只在注释中出现 |
| RinaCore | `ClockOffsetEstimator.phoneTime(forBoard:)`、`PartsLibrary.frameFromStripIndices`、`ScrollRasterizer.projectedFrameCount`/`rotatedToFirstLitFrame` | 只被测试引用 |
| App | `ConnectionViewModel.switchToWifi` :519、`BootLoaderModel.waitUntilDone` :213 | 无调用、无测试 |
| App | `ControlViewModel.suggestedSaveLocation`（恒返回 `.board`）、`upsertPayload`、`startNewFace`、`resetPartsToDefault`、`FaceLibraryModel.reorderUserFaces` | 只被测试引用；删除时连同测试一起删 |
| RinaCommand | `startScroll`、`pause`、`resume`、`terminateOtherActivities`、`wifiSet/ClearHotspotCredentials` | 无类型化发送方；调试终端以原始 JSON 可达（DebugCommandCatalog），按上午结论保留 |
| 包 | `ios/Packages/RinaFaceSync` | 未链接进任何 target；去留待产品决定 |

扫描按名字匹配（`grep -w`），同名方法可能掩盖死代码，删除前逐项再查一次。

## 10. 建议顺序

| 步 | 内容 | 改协议？ | 验证 |
|---|---|---|---|
| 1 | F3 解码 facesGeneration；F1 删除 App 侧 parts 判定；§9 无调用代码 | 否 | `RinaBoardTests`、RinaCore `swift test` |
| 2 | F2 upsert/rename 回复附带被写记录，所有写操作统一修补规则 | 增量字段 | App 测试 + `faces_transfer_test.py` + 模拟板 `tools/rinalink_board_emulator.py` |
| 3 | F4 固件常驻权威文档、单遍 prepare | 否 | `saved_faces_storage_test.py`，128 项库写入计时，两板刷写后串口 `btn B1/B2` 遍历 |
| 4 | F5 单一库 owner + 单一待确认日志（等原对话确认后） | 否 | `BoardOwnedSaveSafetyTests`、`MultiBoardFaceSaveTests`、`SaveDestinationsUITests` |
| 5 | F7、F10、F11、F12 机械清理 | F10/F11 小改 | 同上 + 固件 host 测试 |
| 6 | F8、F9 先测量再决定 | 是 | BLE/TCP 实测帧率与连接耗时，双板回归 |

第 1–3 步彼此独立，可以并行，收益也最确定：一次单板保存从“≥2 次请求、固件读文件 2 次、全库处理约 6 遍”降到“1 次请求、读文件 0 次、全库处理 1 遍”。

## 11. 限制

- 未运行任何构建、测试或硬件；表中次数来自源码路径，不是实测。F8、F9 必须先测量。
- 没有完整追踪的部分：`scroll_session.cpp` 的 tick 采样、`ScrollPreviewController` 是否与预览事件重复渲染、`RinaRequestBroker`/BLE/TCP transport 内部、`BoardSessionStore` 的持久化键，以及状态的观察者数量。
- F5 涉及另一对话刚落地的代码，方向判断是 Strong，但实施前要先与那个对话的 owner 对齐。
