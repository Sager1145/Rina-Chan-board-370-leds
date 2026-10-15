# 固件与 iOS 联合连接审计（合并后复核）

日期：2026-10-15。基线：`origin/main` = `7857cfd`（含 `refactor/interface-audit-1015` 全部改动与 `8303488`）。

## 1. 结论

两端的协议主干一致：命令名、blob kind、6 个能力 token、`proto: 1`、4096 B 帧上限、`MORE` 语义、3072 帧与 22…3093 位图宽度上限、滚动 rotation/frameCount 公式、组时钟游标数学、face `gen` 递增规则都对得上。本轮改动（精简回复、`frameHex`、原子滚动替换）新旧版本双向兼容。

仍需处理的问题集中在三处：

1. **iOS 没把固件已提供的物理身份用到底**：LAN 首次保存不记身份（J1），LAN 成功后不合并会话（J2）。
2. **两端限额口径不一致**：4096 B 源文本合法，但放进 BLOB_BEGIN 后超过 4096 B 帧上限（J3）。
3. **本轮引入的一处新风险**：首次同步复用握手 status/preview，可能错过事件限频窗口内的变化（H1）。

## 2. 方法与来源

- 方法：`mattpocock-skills:code-review` 两轴（Spec 轴对照契约、Standards 轴对照文档规则与 Fowler 坏味道），读取全部交给 Grok 4.7，主审查者核对关键结论后写入。
- 契约：[`docs/RINALINK_PROTOCOL_V1.md`](../RINALINK_PROTOCOL_V1.md)、[接口审计 §11](2026-10-15-interface-audit.zh-CN.md)。
- 纳入并复核了另一份联合报告 `docs/FIRMWARE_IOS_JOINT_AUDIT_2026_10_15_ZH.md`（基线 `8303488`，早于本分支合并）及其引用的 `docs/FIRMWARE_INTERFACE_ARCHITECTURE_AUDIT_2026_10_15_ZH.md`。该报告的条目在写作时均成立，没有误判；下表给出它们在当前代码上的状态。

## 3. 问题清单（按处理优先级）

| 编号 | 级别 | 状态 | 问题 | 证据（当前行号） |
|---|---|---|---|---|
| J1 | P2 | 未修 | LAN 首次保存（Bonjour、手动 host）不写 `physicalBoardID`；冷启动只靠它或热点 SSID 推导期望身份，地址被另一块板复用时会被接受并改写记录。**另有 `switchToWifi` 同样漏写**（原报告未列） | `ConnectionViewModel.swift:370-373`、`:400-401`、`:516`；冷启动 `:785-786`；BLE `:109-114` 与热点 `:485-493` 正确 |
| J2 | P2 | 未修 | 添加页 LAN 成功路径不调用 `consolidateVerifiedSession`，同板 BLE+LAN 留两个 session，LAN 掉线时找不到另一 session 的 BLE 候选 | `AddBoardView.swift:196-201`、`:214-220`；BLE `:140` 正确；合并实现 `BoardSessionStore.swift:256-275` |
| J3 | P2 | 未修 | 4096 B 源文本放进 BLOB_BEGIN 后超帧上限：单板位图 4322 B、组位图 4355 B、raw 4312 B；固件入站不聚合 `MORE`，无法绕过 | `ScrollText.swift:10`、`config.h:150`、`inbound_frame.h:9`、`BoardConnection.swift:1363-1366`、`:1497-1506`、`:1538-1541`、`:1586-1589` |
| H1 | P2 | **本轮引入** | 首次非恢复同步直接用握手时的 `connection.status/preview`。固件状态事件最短 200 ms、预览 100/250 ms 且只在变化时发；握手读完到同步开始之间的变化可能尚未以事件到达，恢复模式按旧值决策 | `BoardSyncCoordinator.swift:128-144`；固件 `protocol.cpp:2505-2529`；`BoardResumeMode.swift:109-127` |
| E1 | P2（仅测试） | 部分修 | 模拟板与固件不一致：`BLOB_END` 回 `{frameCount}` 而非 `{frames,rotation,width}`（App 会判为 mismatch 走 raw 回退）、`chunkMax` 4000≠4032、`SET_FRAME` 把 playback/reason 字节当帧存、`group_start` 失败无 `code`。ERR 帧与 caps 已在 `7857cfd` 修正 | `tools/rinalink_board_emulator.py:157-164`、`:260`、`:266`、`:289` |
| P1 | P3 | 未修 | 固件会回 503（LittleFS/表情不可用），协议错误码表未列，App 无专门分支 | `protocol.cpp:676`、`:1363`、`:2204`；协议 `:99-101` |
| P2 | P3 | 未修 | Wi-Fi 设置失败走普通回复 `{ok:false,error}` 无 `code`，不是 `0xFF`；App 只能当字符串错误 | `protocol.cpp:569-624`；`BoardConnection.swift:1077-1079` |
| P3 | P3 | 文档 | 协议称通用成功回复含 `autoFaceIndex`，但 `subscribe`/`log_subscribe`/`reboot` 只回 `{ok}`；App 只依赖 `ok`，无功能影响 | `protocol.cpp:1181-1204`；协议 `:127` |
| F1 | P3 | 未修 | 通用 `pause` 不暂停滚动；生产文字界面用 `pause_scroll`，仅调试可达 | `protocol.cpp:1344-1347`；`scroll_session.cpp:699-701` |
| F2 | P3 | 未修 | `group_start` 接受 ≤2000 ms，退出组计时后本地 tick 夹到 1000 ms；正常 UI 不产生 >1000 ms | `protocol.cpp:1153`；`config.h:146`；`scroll_session.cpp:744` |
| F3 | P3 | 未修 | 空时间线 `start_scroll` 仍回成功；生产文字走 `BLOB_END start=true`，不经此命令 | `protocol.cpp:1324`、`:1435-1437` |

## 4. 原报告条目在当前代码上的状态

| 原编号 | 当前状态 | 说明 |
|---|---|---|
| C1 / A1 回复冗余 | 部分修（`38a12ce`、`62e202f`） | 通用回复已为 `{ok, autoFaceIndex, autoFaceId?}`，`SET_FRAME` 为 `{ok}`，`apply_saved_face` 带 `frameHex`；事件与状态的重叠仍在。原报告 637 B/297 B 样本已不适用 |
| C2 / A3 滚动双格式 | 部分修（`a9ee2a1`、`38a12ce`） | App 不再存全部帧（按需取帧），组位图只编码一次，固件替换为一次加锁拷贝；固件仍“展开到 staging 再拷贝”，单板 raw 回退仍在 |
| C3 握手与恢复重复读取 | 部分修（`71bb9e5`、`5f50354`） | 首次同步复用 status/preview（见 H1 风险），控制页帧与设置页 `get_info` 仍读线上 |
| C4 命令入口编排 | 部分修（`6815b8a`、`a9ee2a1`） | 共用 `transact`，组扇出改为 `BoardOutboundHook`；`requestReliable` 仍绕过队列与 hook，表情与 Wi-Fi 扫描仍各自编排 |
| A2 表情写后重读 | 部分修（`38a12ce`） | 修改后直接安装已解析文档；写入仍整串序列化 |
| A4 RuntimeStore 转发 | 未修 | 纯固件内部，不影响线上契约 |
| A5 LED 后端多套 | 未修 | 默认 env 已是 RMT+DMA，但未设宏时仍默认 Adafruit，依赖仍在 |
| A6 单槽环形队列残留 | 未修 | 深度 1 仍按环形实现 |

## 5. 版本兼容矩阵

| 组合 | 结果 |
|---|---|
| 新 App + `38a12ce` 之前的固件 | 可用。无 `frameHex` 时组表情仍两次 150 ms `GET_FRAME`；缺 cap 则 `supports` 为假；旧的胖回复因字段均可选而正常解码。旧固件上滚动上传失败仍可能留下空时间线，App 只显示错误 |
| `e7588cd` 的 App + 新固件 | 可用。旧 App 本就把回复字段当可选、不读被删字段；忽略 `frameHex`，保留回读；多出的 `apply_face_frame` 只是字符串 cap。替换失败时板子现在保留旧滚动而不是变空 |

## 6. Standards 轴（跨端坏味道，均为判断）

- **常量三处复制**：cap token 在 `protocol.cpp:656-665`、`Messages.swift:999-1014`、模拟板各写一份，本轮模拟板曾漏 `group_60fps`（已修）。帧字节 47、`MAX_SCROLL_FRAMES` 3072、`MAX_PAYLOAD` 4096、TCP `chunkMax` 4032 两端一致，模拟板 `chunkMax` 4000 漂移。
- **散弹式修改**：一次回复形状调整触及固件、`Messages.swift`、`BoardConnection`、组协调器、扇出、模拟板、协议文档及 4 个测试文件；这是阶段 4 要求的同步改动，但说明契约没有单一来源。
- **基本类型偏执**：固件 cap、命令名、reason 都是 C 字符串；`apply_saved_face` 被 `strcmp` 两次（`protocol.cpp:1354`、`:1431`）。`CommandReply` 仍保留所有已删字段作为可选，以兼容旧固件。

## 7. 建议处理顺序

1. **H1**：最小修法是恢复首次同步时的 `GET_STATUS`/`GET_PREVIEW_SYNC`（每次连接多两次请求），保留连接页改名复用；或在同步前确认握手后没有更新的状态版本。正确性优先，推荐前者。
2. **J1/J2**：只改 iOS 成功连接登记——LAN 三个入口传入握手身份，LAN 添加路径调用已有合并；补走真实入口的测试（手动 host 换板必须在 ready 前拒绝；BLE→LAN→BLE 只剩一个 session）。
3. **J3**：对完整 BEGIN 请求做同一预算检查并给出可理解的错误；若产品要支持任意 4096 B 文本，需要改变源文本的传输位置，不能靠 raw 回退。
4. **E1**：模拟板对齐 `BLOB_END` 回复、`chunkMax`、`SET_FRAME` 解析与错误码，否则基于模拟板的测试会走错分支。
5. P1–P3、F1–F3 及 A4–A6 作为低优先级清理，与支持固件范围的决定一起处理。

## 8. 验证与限制

- 已在 `9eb9cb3`/`7857cfd` 上验证：iOS `RinaBoardTests` 761 项 0 失败，RinaCore 378 项 0 失败；固件构建成功，17 个 host 测试全部通过（含合并 `8303488` 后修复的 `playback_ownership`）；模拟板测试通过。
- 两块板已刷写 `62e202f` 固件（与 `7857cfd` 固件源码相同），串口确认启动正常、11 个表情已载入。
- **未做**：Mac 硬件功能测试因本机 shell 无蓝牙权限（TCC）无法运行；没有 BLE/STA/AP 实机连接、换板、DHCP 复用或吞吐测量。J1/J2/H1 为静态调用链与时序分析结论，J3 的字节数由重建请求计算得出。
