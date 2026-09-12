# RinaBoard iOS 功能验收报告

批次：20260912-a1；日期：2026-09-12（America/Toronto）。

**冻结版本验收结论：不通过；最新工作区尚未验收。** 已有测试的通过不足以覆盖本次完整功能要求；本轮已复现日志脱敏、非法帧导入、默认实时输出等缺陷，且真实 BLE/Wi-Fi、麦克风和 LED 时序仍被环境阻塞。没有修改产品代码、刷写固件或提交 commit。

## 1. 版本与工作区完整性

- Git HEAD：`6983ca849fea86ec3e42582f01da8a436bdad45e`。实际构建使用未提交工作区，不能把HEAD当成全部构建内容。
- App：`com.rinachan.board`，2.0.0 (1)，Debug；最低 iOS 17.0，支持 iPhone/iPad。
- macOS 27.0 (26A428)，Xcode 27.0 beta (27A5237l)，Swift 6.4；构建显式指定 `/Applications/Xcode-beta.app/Contents/Developer`，未改变系统 xcode-select。
- 指定的6个skill已读取；并行agent只梳理代码/编写隔离测试，所有模拟器和硬件操作由主流程串行执行。
- 仓库没有发现另一个磁盘 AGENTS.md；采用用户提供的全局 AGENTS 指令。

**本轮发生外部并发源码修改。** 最初构建期间及其后，有其他进程改动导航、控制、文字、设置、表情库等；本任务从未写入这些产品文件。早期通过结论只适用于相应构建，不能迁移为后续版本的通过。16:35:01（本地时间）冻结 iOS 源码到 `/private/tmp/rina-acceptance-a1-snapshot/ios`，之后只在此副本构建。新增测试同步到副本，产品文件固定；[最终哈希核对](evidence/final-frozen-verification.json)显示产品文件变化为0，最终测试代码散列另列于[测试清单](evidence/final-test-harness-sha256.json)。

证据：初始Git状态 [git-before.txt](evidence/git-before.txt)，工作区比较哈希 [source-sha256.json](evidence/source-sha256.json)，冻结清单 [frozen-ios-sha256.json](evidence/frozen-ios-sha256.json)，差异 [freeze-diff.json](evidence/freeze-diff.json)，可复现源包 [frozen-ios-source.tar.gz](evidence/frozen-ios-source.tar.gz)。RinaCore在两次清单间没有变化；早期136项Core结果可追溯到相同Core源码。最终核对当前工作区另有16个产品文件偏离冻结版本，涉及控制、表情库、通信、播放协调和本地化，详见 [最终工作区差异](evidence/final-workspace-drift.json)。因此所有缺陷与通过结论仅针对冻结版本；不推断这些缺陷在最新工作区仍存在，也不将最新源码宣布验收通过。

[SNAPSHOT_DELTA.md](SNAPSHOT_DELTA.md) 记录旧功能清单与冻结实现的差异。以下代码位置除非另注，指冻结副本中的仓库相对路径；可从源包复现。

## 2. 测试环境与实际数量

计数以 `.xcresult` 的 `totalTestCount / passedTests / failedTests` 为准。XCTest同一测试的多个断言失败不重复算测试；Swift Testing的空运行器“0 tests passed”不计通过。

| 运行 | 实际执行 | 通过 | 失败 | 证据/范围 |
| --- | ---: | ---: | ---: | --- |
| Core | 136 | 136 | 0 | [core-tests.log](evidence/core-tests.log)，相同Core源码 |
| baseline | 12 | 12 | 0 | [变化前工作区；App10/UI2](evidence/baseline-summary.json) |
| extended | 10 | 3 | 7 | [变化中；App4/UI6，含定位问题](evidence/extended-summary.json) |
| recovery-ui | 15 | 11 | 4 | [变化中；App10/UI5](evidence/recovery-ui-summary.json) |
| frozen-baseline | 32 | 28 | 4 | [冻结版；App29/UI3](evidence/frozen-baseline-summary.json) |
| ios27 | 6 | 4 | 2 | [iOS27；App1/UI5](evidence/ios27-summary.json) |
| ipad | 2 | 0 | 2 | [iPad首轮；UI2定位失败](evidence/ipad-summary.json) |
| ipad-retry | 2 | 2 | 0 | [iPad重试；UI2，图片采集待复核](evidence/ipad-retry-summary.json) |
| se | 6 | 4 | 2 | [SE；UI6](evidence/se-summary.json) |
| models-retry | 15 | 15 | 0 | [SE；App15](evidence/models-retry-summary.json) |
| ipad-screen | 2 | 0 | 2 | [iPad设备类型判断导致定位失败](evidence/ipad-screen-summary.json) |
| ipad-screen-retry | 2 | 2 | 0 | [iPad整屏截图及实际层级定位复核](evidence/ipad-screen-retry-summary.json) |

`models-final`因截图测试API编译错误，实际执行0；修正后`models-retry`15项全过。各行含重复复跑，不能相加当作独立功能数。冻结App模型共45个不同测试，41通过、4失败（3个导入/日志失败及1个默认值失败），分轮执行；UI失败需按第5节区分定位问题。


所有命令、结果路径及复跑方式见 [RUNBOOK.md](RUNBOOK.md)。各轮使用 `-parallel-testing-enabled NO` 和显式模拟器ID；无测试发现或仅编译成功的退出不算验收通过。首轮受沙箱限制的SwiftPM/CoreSimulator访问失败，经已审核的权限升级解决，与产品缺陷分开。

## 3. 覆盖矩阵与判定口径

- 完整功能清单：[FEATURE_CASES.md](FEATURE_CASES.md)，210项；来自导航、View/Model、存储与协议交叉提取，包含前置条件、步骤、预期及源码入口。
- 通信专项：[PROTOCOL_CASES.md](PROTOCOL_CASES.md)，35项；含正确TCP端口、BLE服务、三条Wi-Fi路线与故障注入步骤。
- 逐项状态：[CASE_RESULTS.csv](CASE_RESULTS.csv)，汇总说明：[COVERAGE.md](COVERAGE.md)。每项均可找到通过/失败/阻塞/未测试状态。部分步骤通过不能代表整例通过；一个明确反例足以使该例失败，剩余步骤仍注明未测。
- 另有13项冻结版替代观察点，合计258条矩阵记录。
- 清单是冻结前发现的完整验收范围；界面被移除、改入口或文档失效的项目仍保留，不悄悄从范围删除。

已实际验证的范围包括：Core帧/几何/编码/文本栅格/口型算法/演出脚本；App输出会话取消与旧响应隔离（替身）；真实临时文件的本机表情存储/重启/导入导出/重复名称隔离/保护/失败回滚/撤销重试/部分成功；独立演出素材恢复；五标签与Debug工作区的部分UI操作。它们都不能证明物理输出同步正确。

## 4. 已复现产品缺陷

### DEF-01 — P2：日志导出未完整隐藏 Bearer 令牌

前置：DebugViewModel本机测试，不需要网络；仅使用虚构字符串。步骤：`model.log(.warn, "Authorization: Bearer ACCEPTANCE_FAKE_BEARER_TOKEN")`，读取 `logShareText`。

预期：完整凭据被隐藏，保留必要诊断字段。实际：正则只隐藏 `Bearer`，令牌仍出现。复制/分享调用同一导出属性，但本轮未向外部分享真实日志。

代码：`ios/RinaBoard/Features/Debug/DebugViewModel.swift:406`、`:413`。证据：`AcceptanceRecoveryTests.testLogExportRedactsEntireBearerAuthorizationValue`，冻结版日志与xcresult均失败。风险取决于实际日志是否含该格式，不声称已泄露用户真实凭据。

### DEF-02 — P2：转义引号密码的尾部残留

步骤：先用JSONSerialization验证有效JSON `{"password":"ACCEPTANCE_PREFIX\"ACCEPTANCE_SECRET_SUFFIX","operation":"connect"}`，再记录并导出。

预期：密码前缀和尾部均不出现，`connect`保留。实际：转义双引号被当作值结束，尾部残留。

代码同DEF-01。证据：`AcceptanceRecoveryTests.testLogExportDoesNotLeakPasswordSuffixAfterEscapedJSONQuote`。普通未转义JSON密码脱敏对照通过，未知嵌套JSON和null字段保留对照通过。

### DEF-03 — P2：越界帧字节被静默改写并导入

前置：唯一临时目录的真实LocalFaceStore，已有一张有效表情。步骤：导入47字节数组，其中一个值为256，其余合法；对照导入前库ID和文件内容。

预期：拒绝非法帧，明确错误，原文件不变。实际：没有错误；新增表情并改写磁盘，256通过`UInt8(clamping:)`变成255。没有覆盖用户素材，本测试只操作自己创建的目录。

代码：`ios/Packages/RinaCore/Sources/RinaCore/FaceDocument.swift:121`，`ios/RinaBoard/Features/Faces/FaceLibraryModel.swift:584`。证据：`AcceptanceLibraryTests.testOutOfRangeImportedByteIsRejectedInsteadOfChangingTheFrame`；同一用例3条断言失败计为1项失败。短帧拒绝、失败导入保留旧文件的对照均通过。

### DEF-04 — P1：新编辑器默认开启实时输出

步骤：在冻结版新建`ControlViewModel`，不经过用户开启动作，检查`livePreview`。

预期（本次验收要求）：默认本地编辑，用户明确打开实时同步后才发送。实际：默认`true`；控制页截图中的“实时预览”处于启用状态。实际LED是否随之变化没有硬件证据，不能声称已观察到面板误输出。

代码：`ios/RinaBoard/Features/Control/ControlViewModel.swift:44`；UI入口 `ControlView.swift:117`。证据：`AcceptanceDefaultsTests.testRealtimeOutputIsOffForANewEditor` 在iOS27失败；[控制页截图](evidence/screenshots/iphone26-layout-1-tab-0.png)。该差异发生在外部并发修改后的冻结版，初始修复文档描述的是默认关闭。

### DEF-05 — P1：离线无法从控制页保存本机表情

前置：冻结版、iPhone SE第三代/iOS26.5、离线。步骤：打开控制页，定位标签以“保存”开头的实际按钮（完整辅助标签为“保存、保存”），检查启用状态。

预期：本机保存始终可用，面板保存单独受连接状态约束。实际：唯一保存按钮被禁用；代码中的命名确认仅保存到面板。此前iOS27的同名测试因精确标签错误未到达此断言，本次SE重测才是确定的功能失败。

代码：`ios/RinaBoard/Features/Control/ControlView.swift:140`、`:143`、`:56`。证据：`se.xcresult` / `SnapshotAcceptanceUITests.testOfflineSaveRemainsAvailable`，配套页面层级和截图在 [SE附件清单](evidence/se-attachments/manifest.json)。

### DEF-06 — P2：最大辅助字号下设备状态条视觉溢出

前置：冻结版，iPhone 17 Pro / iOS27，英文或日文，`UICTContentSizeCategoryAccessibilityXXXL`，未连接。步骤：打开任一主标签，观察底部面板控制条。

预期：设备入口标题/状态可辨认，控件图形容纳在各自区域。实际：摘要压缩成省略号，上/下/A/发送图标明显超出正常胶囊高度、相互挤占视觉空间；五标签仍可点击，不能因此判定设备条合格。未开启VoiceOver，因此不声称朗读失败或焦点不可达。

证据：[英文控制页](evidence/screenshots/iphone27-en-AXXXL-tab-0.png)、[日文设置页](evidence/screenshots/iphone27-ja-AXXXL-tab-4.png)，来自已通过的截图采集测试 `testLocalizedTabsLargeTextLandscape`，由本次人工实看确认视觉问题。iPad最终整屏图另见[英文控制页](evidence/screenshots/ipad-full-en-AXXXL-tab-0.png)和[日文设置页](evidence/screenshots/ipad-full-ja-AXXXL-tab-4.png)，完整画面消除了旧裁剪疑问。代码：`BoardControlCenterAccessory.swift:49` 固定横向排列，`:100` 固定slot，`:152` 动态字号图标配固定框；`:107` 摘要单行。

### DEF-07 — P1：表情库缺少本机位置入口

步骤：离线控制页 → 面板控制 → 管理表情 → 表情库，确认页面标题后查找“本机”。预期：可选择本机库并管理本机内容；实际只有默认表情/我的表情列表，没有本机位置。底层LocalFaceStore模型测试通过不能弥补UI入口缺失。

代码：`ios/RinaBoard/Features/Faces/FaceLibraryView.swift:22`。证据：`se.xcresult` / `SnapshotAcceptanceUITests.testLocalLibraryLocationRemainsAvailableOffline`，最后失败断言已实际进入表情库，区别于旧测试停在“全亮”的定位失败。未执行真实面板删除。

## 5. 测试定位问题与静态风险

- 新UI首轮在启动遮罩outro期间点击，XCUITest尝试处理已经消失的“页面加载完成”Alert失败。增加遮罩消失等待；原失败结果包保留，不计为产品缺陷。
- 首轮文本输入在光标开头连续删除，没有清除原默认文本。实际重启恢复了完整编辑结果；测试误把“替换输入”当成前置。后续改为保存编辑后的完整value进行对照。
- 最初标签恢复测试点到包裹Switch的行而没有验证实际切换；增加子Switch定位与值断言，并后台后重启。冻结前修正后的测试通过，但不能据此证明所有设置持久化。
- 外部修改去掉控制/文字的导航标题、保存sheet和键盘“完成”，旧定位失败不独立证明产品崩溃。冻结版的已有UI测试还查找不存在的“全亮”，在进入控制中心之前已经失败；这是陈旧测试断言，不能把后续表情库步骤算失败或通过。
- iPad首轮把顶部标签当成TabBar；修正后两项通过。后续换设备构建时运行器的idiom判断仍与目标层级不一致，`ipad-screen`两项再次停在定位前置；最终测试改为识别实际目标导航层级。未把这些失败记作App崩溃。
- UI日志含Xcode beta的`ColorWell/Key`旧新自动化类型不一致提示。必须以实际层级/截图和具体断言判断，不能将工具提示一概当App缺陷。

以下仅静态风险，**尚未运行证明**：ConnectionViewModel配网跨await未固定连接代次；忽略connect返回Bool导致旧流程误记成功；Keychain save/delete结果被忽略；255序号耗尽和2秒隔离窗口；重连订阅、手动/自动/文字/口型/演出/Debug全30个有向切换；口型首次校准授权取消路径。详细步骤及代码在通信专项与快照差异文档中。

UI静态扫描初次为56文件、high=0/medium=54/low=2，属于启发式提示而非54个缺陷。初次本地化校验发现708个代码键、0缺失；`translations.jsonl`缺4个条目但catalog无待填字段，不能因此宣称4条运行时未翻译。扫描/校验针对当时工作区，不替代冻结版或后续语言资源的视觉验证。

## 6. UI矩阵

| 环境/维度 | 实际结果及证据边界 |
| --- | --- |
| iPhone17Pro / iOS26.5 | 五标签截图、Debug工作区操作通过；已存在UI旧定位测试失败 |
| iPhone17Pro / iOS27 | 五标签离线发送门控、文字后台/重启恢复、3语言最大辅助字号标签点击通过；默认实时同步失败；设备条视觉缺陷 |
| iPhone SE第三代 / iOS26.5 | 五标签、文字恢复、Debug取消/本地重播通过；离线保存和本机库入口失败 |
| iPad11 / iOS26.5 / 深色 | 最终整屏复测2项通过，五标签深色横竖屏/3语言最大字号点击；[横屏设置整屏证据](evidence/screenshots/ipad-full-layout-3-tab-4.png)。旧app截图裁剪不计产品缺陷 |
| 简中/繁中/英文/日文 | 简中基础操作；繁中/英文/日文最大辅助字号切换五标签；未覆盖所有页面和长名称 |
| 浅色/深色 | 独立iPhone默认浅色与iPad指定深色截图；未穷尽每个二级页 |
| 最低iOS17 | 阻塞：无安装runtime，iOS26.5不能替代最低版本 |
| iPad分屏、VoiceOver、减少动态效果 | 未测试，静态扫描/普通点击不能代替系统辅助功能实际操作 |
| 麦克风、真实网络、音频中断、LED | 硬件链路阻塞；算法/内存替身测试与真实输出分开 |


截图只证明相应静态状态；标签可点击不等于该页所有功能、焦点顺序、触控区域和错误状态全部合格。不提供“Apple Fidelity 90分”等无完整运行证据的评分。iPhone仅声明竖屏/倒置竖屏，旋转到landscape不会构成受支持横屏；iPad声明四方向。

## 7. 实体设备和面板

系统能枚举两台可用/连接的实体iPhone（另有一台不可用）和一个USB串口，但没有把“被发现”当作“App验收通过”。没有重新安装或覆盖用户真机App/素材。

用户要求桌面全屏鼠标控制Device Hub。当前工具仅暴露应用/浏览器Target，无桌面全局鼠标/全屏截图API；Device Hub用bundle ID和已验证安装路径多次连接均返回`-10005 timeoutReached`。未绕用其他UI自动化技术，也未把CLI操作称作全屏操控。**真机UI验收阻塞。** [环境观察记录](evidence/control-environment-notes.md)。

USB UART115200只读`status`两轮（分别约3秒/5秒）均收到0字节，见 [serial-status.txt](evidence/serial-status.txt)、[serial-retry.txt](evidence/serial-retry.txt)。未确认当前运行固件版本，未发按键或输出改变命令，未刷写/复位/清屏；不能依据历史硬件文档推定本轮硬件正常。

用户追加的serial按钮要求：代码中已有 `btn B1…B5` 与 `btn B3B1/B3B2`，因此未重复实现。B6帮助文字与实际分派不一致：`btn B6`在源码路径返回invalid。此为静态P3文档/能力差异，未获得串口动态回包验证。逻辑action不模拟GPIO press/release、消抖、长按、连发计时或GPIO专属overlay；详见 [SERIAL_BUTTONS.md](SERIAL_BUTTONS.md)。

实体清空用户表情、重置电源校准、不可撤销板端删除均未执行。具体备份、取消确认、执行、恢复核对步骤已准备在RUNBOOK；待硬件前置恢复后才会在执行前请求用户对明确对象确认。

## 8. 未验证风险与下一步

1. 先协调正在修改仓库的任务，确认最终功能基线：离线本机保存、默认实时同步、设备入口与原修复方案是否仍是目标；本报告不替用户取消这些验收要求。
2. 修复已确认缺陷后，复跑对应失败测试，再执行关联UI路径；保持坏输入、保存失败、部分成功测试为回归。
3. 提供可用全屏控制接口/修复Device Hub、确认面板供电与串口通信后，按专项步骤分别验收BLE、LAN TCP、家庭网、iPhone热点、板AP、授权与SSID来源。Keychain错误注入不能靠真实用户账号反复试错。
4. 补iOS17、小窗口分屏、VoiceOver实际朗读/焦点/可达性、Reduce Motion/Transparency、高对比、键盘/sheet边缘和长名称。没有执行的格子继续保留未测试/阻塞。
5. 麦克风真实许可和音频中断、后台/断线资源释放、实体LED与音频/预览时间轴、长时间内存与任务残留必须用真机做有时间戳记录的持续测试。当前没有长时间资源曲线，不宣称无泄漏。

## 9. 交付与新增文件

新增测试：`AcceptanceRecoveryTests.swift`、`AcceptanceLibraryTests.swift`、`AcceptancePerformanceTests.swift`、`AcceptanceDefaultsTests.swift`、`AcceptanceControlTests.swift`、`AcceptanceTextTests.swift`（App共35项增补），`AcceptanceUITests.swift`、`SnapshotAcceptanceUITests.swift`（当前UI共10项增补，连同原有2项为12项）。没有注册/改写项目文件，测试目录由项目自动同步。

所有证据和报告在本目录。失败结果包保留原状；没有把确认的产品缺陷标为expectedFailure或修改产品来使结果变绿。测试创建的临时库由各例清理；独立模拟器及源码副本保留用于复现。没有删除用户原有未提交修改或用户素材。
