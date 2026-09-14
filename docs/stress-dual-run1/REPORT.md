# RinaBoard 双板压力测试 run1（进行中）

计划：`docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md`。用例：`CASES.csv`。强退循环：`RECOVERY-FQ.csv`。过程记录：`logs/notes.txt`。

## 环境

- iPhone 13 mini，iOS 27.0（24A435），UDID 00008110-000E38321AA2801E。App 为当前工作区的 Debug 构建，2026-09-13 02:21 安装。
- 板 A `RinaBoard-80B54EF48E09`（`/dev/cu.usbmodem5AE70745091`），板 B `RinaBoard-80B54EF74801`（`/dev/cu.usbmodem5AE70735521`），两块都走 BLE。
- 串口日志 `logs/serial/{A,B}.log`，由 `tools/serial_logger.py` 记录（逐行时间戳，端口停更或消失后自动重开）。
- 两块板在 02:23 左右被本会话以外的操作重启过，之后处于开机默认状态。

## 本轮修复

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| DB-BUG-1：控制中心切到已在线的板时，产生重复会话 | 另一会话已写入：`connectSavedBoard(_:sessions:boardStore:)` 改为使用目标板自己的会话，已连接就直接选中 | 单测全过；Opus 审查 ACCEPT；真机 DB-SW-04 PASS |
| DB-BUG-2：热切换后会话身份过期，点已保存的旧板无反应 | 同上，不再改写另一块板的会话 | 真机 DB-ID-06① PASS |
| 选到不在范围的板后，面板菜单被锁约 2.5 min | 本会话修改：`isSwitchingBoard` 只看菜单自己发起的切换 | 单测 198/199（1 个与本改动无关的负载下偶发失败，单独运行通过） |
| 连接中菜单名称显示为 "Rina-Chan Board" | 本会话修改：回退显示当前会话名 | 同上 |
| 热点直连加入时，可能占用另一块板的离线会话 | 已拆为独立任务 task_f8eba8a3，由另一会话处理 | — |

## 真机结果

| 用例 | 结果 | 证据 |
| --- | --- | --- |
| DB-SW-05 已保存行连接 B（A 在线） | PASS | B 端 `get_info` @1789280587；A 没有断开 |
| DB-SW-04 控制中心切到已在线的 A | PASS | A 没有新的连接或握手；B 没有断开；「控制对象」显示两块不同的板在线 |
| DB-ID-06① 热切换后点已保存的 B | PASS | 直接切到 B，没有重新连接，A 没有断开 |
| DB-FQ-01 强退重启循环 run2（Q1，20 轮，seed 20260913） | PASS 20/20 | 每轮 pid 都变化（1694→1737）；B 重连 p50 982 ms、最小 802、最大 1479；每轮 B 恰好 1 次断开、1 次连接、1 次 subscribe，没有重复会话；A 无任何事件（App 启动只自动连最近使用的板，符合 E4）；无崩溃报告 |
| DB-RB 复位方法验证（B2，B 单次） | PASS | `rst:0x1 POWERON, boot:0x2b SPI_FAST_FLASH_BOOT`（正常启动，不是下载模式）；914 ms 启动完成；复位后 3173 ms 蓝牙重连，subscribe=1；A 不受影响；USB 端口没有消失 |
| DB-RB-02 双板同时在线随机复位（10 轮，seed 20260914，A 为当前板） | PASS 10/10 | A 复位 3 次，3015–3396 ms 重连；B 复位 7 次，3055–3325 ms 重连；被复位的板每次 subscribe=1；另一块板断开 0 次；App pid 始终是 1737 |
| DB-RB-02 随机复位循环（12 轮，settle 45 s，手机只连 B） | PASS 12/12 | 复位后 722–1561 ms 出现重启标记（p50 1393）。B 复位 7 次：3031–3428 ms 重连（p50 3199），每次 subscribe=1。A 复位 6 次：B 不受影响，断开次数为 0。App pid 始终是 1737，没有崩溃；USB 端口没有消失 |

## 主机多板压力测试（模拟器，假连接）

新增 `ios/RinaBoardTests/DualBoardHostStressTests.swift`。连续跑 4 次，每次 5 个测试全部通过，每次约 24 s。

| 测试 | 覆盖 |
| --- | --- |
| `testSeededRandomWalkNeverRoutesToInactiveBoard` | 3 块假板上固定种子随机走 1000 步：选板 216 次、连接 195 次、断开 200 次、发令 206 次、移除后重新添加 183 次。检查了 167 次发令，没有一次发到非当前板，每块板只有一个会话 |
| `testQueuedCommandsAndFramesDoNotFollowSelectionToAnotherBoard`（及 connectSavedBoard 变体） | 超过队列深度的排队命令和帧，不会在切换后发到新板 |
| `testSwitchToConnectingBoardReturnsWithoutSecondDialAndFailedDialLeavesOtherSessionUntouched` | 切到正在连接的板时不会重复拨号；连接失败时，另一块板的会话不受影响 |
| `testBoardIdentityFromHandshakeDrivesDraftDiscard` | 握手得到的板身份决定草稿去留：同一块板保留，换板放弃 |

## 主机回归（不碰硬件，当前工作区）

| 套件 | 结果 |
| --- | --- |
| RinaCore `swift test` | 180/180 通过 |
| 固件 C++ 主机测试 | `ble_frame_sender_test`（14 个场景）、`stream_transport_test`（1000 个混合帧 + 9 个 TCP 故障场景）全部通过 |
| 固件 Python 主机测试 | blob/output_mode/playback_ownership/presentation_telemetry/rmt_recovery/serial_network_scheduling/stress_findings 共 7 个，全部通过 |
| 固件编译 `esp32s3-rmt-dma` | 成功；RAM 30.6%，Flash 16.9% |
| iOS 单元测试 RinaBoardTests | 198/199（1 个在整套负载下偶发失败，单独运行通过） |

### DB-RT-03 编辑器实时帧只发往当前板

- A 固件在滚动，B 为当前板；在 B 的编辑器上点灯 3 次（实时预览开启）。
- 结果：PASS。
  - B：accepted 从 1 变为 4（正好 3 次点击），lastReason=`custom_live_send`。
  - A：accepted 只按滚动速率增长（10.2 s 内 3300→3402），lastReason 一直是 `firmware_text_scroll_start`，`playback=scroll`，没有收到任何命令。

### DB-RT-02 控制中心 › 只作用于当前板

- B 为当前板，A 固件在滚动；在控制中心 accessory 上点 › 两次。
- 结果：PASS。
  - B：收到 2 个 `button` 命令，`FACE apply idx=9/11` 之后是 `10/11`；faceIndex 从 7 变为 9。
  - A：没有收到命令；faceIndex 仍是 7，`playback=scroll`。
- 固件在执行每个 button 之前，会先做一次 `SCROLL stop stopped=0`（B 当时没有滚动，所以没有效果）。
- 这次没有 flash 写入。`runtime_settings.json` 只保存 mode、autoIntervalMs 和 deviceName；亮度、颜色、表情序号都不写 flash。

### DB-ST-03 拖动亮度后立刻换板

- 操作：在 B 上拖动控制中心亮度滑块，约 0.7 s 内从「面板」菜单切到 A。
- 结果：PASS。
  - B：亮度从 50 变为 108。
  - A：前后所有 STATUS 样本的亮度都是 50，拖动值没有漏到 A。
- 证据局限：`set_brightness` 不会以 PROTO 命令的形式出现在日志里，这里只能用 STATUS 证明结果。
- 副作用：B 的亮度停在 108，测试结束时需恢复到 50。

### DB-FQ-02 播放中强退

- PASS 3/3，没有崩溃报告。
- 强退期间 A 没有收到任何命令，也没有滚动 stop/pause。
- 循环结束后检查：`playback=scroll`，accepted 从 1943 涨到 1981，trace 节拍每秒 +10，说明固件滚动完全没受影响。

## 其他发现

| 严重度 | ID | 发现 | 证据 / 去向 |
| --- | --- | --- | --- |
| 待决策 | LAUNCH-RESTORES-LAST-CONNECTED | 强退后重启，App 自动重连的是**最后连上**的板（B），不是**最后在控制**的板（A，当时正在滚动）。原因：自动重连按 `KnownBoard.lastSeen` 选板（`RootTabView.swift:377`），而 `lastSeen` 只在连接或保存时更新（`ConnectionViewModel.swift` 多处），在「控制对象」里选中别的板不会更新 | `RECOVERY-FQ-playback.csv`：3 次都连回 B，A 在 +11.0 s 断开后一直没连回。需要决定：重启时应恢复最后控制的板，还是最后连上的板 |
| 低（待真机验证） | FACE-SAVE-STALE-GEN | 表情库加载时的连接代次与当前连接不一致时，`FaceLibraryModel.save`（`FaceLibraryModel.swift:262-264`）会去掉 id，把「覆盖」改成「新建」，而不是拒绝。换板时编辑器草稿已被放弃（editingFaceId 清空），所以不会串板。但同一块板重连后（代次也会变）再保存正在编辑的板上表情，可能新建一个重复表情，而不是更新原表情 | 主机测试代理读码发现；DB-ST-04 未实现；需要一次会写 flash 的真机验证 |
| 信息 | FW-B-VCHARGE | B 板充电电压读数 19.6–21.1 V（raw 2899–3147，后期与 vbat raw 相同），A 板为 11.7 V。压测开始前就是这样，与测试无关；可能是 B 板硬件或校准问题，可与 ADC 衰减任务 task_bbd07574 交叉核对 | `logs/serial/B.log` [ADC] event=charge |
| 低 | TEXT-STALE-TIMELINE | 板子重启丢失滚动后，文字页状态显示「閒置」，但仍残留重启前的进度和预览帧；点播放能正确重新上传 | DB-RB-03 |
| 低 | FW-ADC-ATTEN | 每次开机都打印 2 条 `[E][esp32-hal-adc.c:208] __analogChannelConfig(): Pin is not configured as analog channel`（约 766/775 ms）。可能原因：`power_monitor.cpp:467-468` 在引脚配置成模拟输入之前就设置了衰减，衰减可能没有生效。这条错误还插进了 `[LED] apply_packed` 日志行中间，说明串口输出没有加锁 | `logs/serial/B.log` @1789282904、@1789282989；已拆为任务 task_bbd07574 |
| 中 | HOTSPOT-SESSION | 热点直连加入时，可能占用另一块板的离线会话（代码审查发现，本轮环境无法测） | 任务 task_f8eba8a3（另一会话处理中） |

### DB-OUT-01 双板并存：A 固件滚动时 App 来回切换

- 设置：A 在文字滚动（325 帧，100 ms 一帧，循环）；B 空闲；两块板都在线。
- 操作：通过「控制对象」列表切换 10 次（A/B 交替，每次停留 4 s）。

| 窗口 | A | B |
| --- | --- | --- |
| 第一组 5 次（56 s） | 只有 `get_info` ×6；无 stop/pause/start；无 BLE 断开；滚动 10.00 fps，节拍间隔全是 1000 ms | 只有 `get_info` ×4；无滚动命令；无 BLE 事件 |
| 第二组 5 次（54 s） | 只有 `get_info` ×4；无滚动事件；10.00 fps，节拍间隔全是 1000 ms | 只有 `get_info` ×6；无滚动命令；无 BLE 事件 |

结论：PASS。
- 切换时不会向任一块板发控制命令。
- A 的固件滚动完全不受影响，没有漂移。
- 切回 A 时 App 显示「播放中」，进度与板上同步。
- 「控制对象」列表始终是 2 块不同的板在线。

### DB-RB-03 滚动中复位非当前板

| 步骤 | 结果 |
| --- | --- |
| B 是当前板时，给正在滚动的 A 复位 | PASS。A 在 +0.45 s 重启，+1.47 s 就绪，+3.30 s 蓝牙重连，+4.32 s subscribe。B 没有收到命令，也没有 BLE 事件 |
| A 重启后的状态 | 回到手动、空闲状态，显示开机表情（lit=34）。滚动不会跨重启保留，这是固件现状 |
| 从「控制对象」切到 A | App 显示 A 的真实状态（表情 34/370，已同步）。A 只收到 `get_info` |
| 打开文字滚动页 | 状态显示「閒置」，这是对的；但仍残留重启前的进度 142/325 和预览帧（低严重度，界面问题） |
| 点播放 | PASS。App 重新发送时间线：`set_scroll_loop`，然后 `[SCROLL] start count=325`，从头播放，进度与板上同步 |

### 混合 soak（3 轮 × 8 次复位 + 3 次强退，seed 2026091501–03）

| 项 | 结果 |
| --- | --- |
| 板子复位 24 次 | PASS 24/24。A 复位 10 次，每次复位前都在线，全部在 3034–3357 ms 重连。B 复位 14 次，其中 5 次复位前在线（其余在强退之后，App 只自动连回 A），5 次全部在 3007–3321 ms 重连。另一块板从未受影响 |
| App 强退 9 次 | PASS 9/9。A 在 833–1136 ms 重连（p50 964）；无崩溃报告 |
| 板子健康（串口日志 5 h 39 min） | 开机横幅 `rst:` 次数等于注入的复位次数（A 19、B 28），没有意外重启；无 STALL、端口消失、panic 或 WDT；heapFree 最低 88.9 KB，之后回到 90.8 KB；refreshFail 始终为 0 |

## 阻塞：真机 XCUITest 无法启动

- 现象：新的多板 UI 测试和项目原有 UI 测试都一样，测试程序在手机上启动约 18 s 后，被手机端 testmanagerd 拒绝 `XCTestManager_IDEInterface` 通道，退出码 74。共失败 9 次（run 1–8，外加原有测试 1 次）。
- 已排除：
  - UI 自动化开关：手机上确认已开启。
  - Device Hub 镜像：退出 Device Hub 后仍失败。
  - 旧的构建产物：全新 build-for-testing 后仍失败。
  - xcode-select 指向：改到 Xcode-beta 后仍失败。
  - 锁屏：`passcodeRequired=false` 时仍失败。
  - 手动关闭再打开 UI 自动化：仍失败。
  - 会话、通道和 DDI：同一台手机上的宿主单元测试 14/14 通过，说明这一层正常。
- 结论：只有 UI 自动化会话被拒。可能与 Mac 上已安装的 CoreDevice 642.15 / DDI 27A5252f 比 Xcode-beta 27A5237l 新有关。下一步可试：重启手机，或安装与 DDI 匹配的 Xcode。
- 影响：随机游走、路由判定等依赖界面操作的大量切换用例暂时无法自动执行。改为主机端驱动：强退重启循环，板子硬件复位循环（`tools/rb_loop.py`，已写好，待运行），串口 oracle 判定。

## 测试工具问题（已修复）

- `iphone_app.py pid` 的 JSON 解析在 App 运行时返回空，导致 fq_loop run1 实际上没有强退 App。run1 已作废（`RECOVERY-FQ.run1-invalid.csv`）。
- fq_loop 的重启计数误把 STATUS 行里的 `lastReason=startup_sequence_complete_*` 当成重启。
- 修复：pid 查询、强退、启动都直接调用 devicectl；判断重启时忽略 STATUS 行。
