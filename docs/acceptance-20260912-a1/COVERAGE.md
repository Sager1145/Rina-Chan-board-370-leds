# 验收覆盖与证据边界

本表索引 [CASE_RESULTS.csv](CASE_RESULTS.csv) 的258项用例：FEATURE_CASES.md 210项、PROTOCOL_CASES.md 35项，以及SNAPSHOT_DELTA.md 13项。编号按原文保留（例如 DBG-012 与 DBG-03 是不同用例）。每项都有状态、环境、证据和剩余步骤/阻塞原因。

## 判定口径

仅完整执行原用例全部步骤且满足全部预期才算整例通过。本轮多数自动化只验证模型子路径，矩阵保持“未测试”；有硬件环境阻塞则记“阻塞”，并保留已有局部证据。已执行步骤违反明确预期即可判失败。已确认坏帧、脱敏、离线保存、本机库位置和辅助字号附件视觉反例映射为失败，其余步骤仍未测试。

| 整例状态 | 数量 |
| --- | ---: |
| 通过 | 0 |
| 失败 | 7 |
| 阻塞 | 131 |
| 未测试 | 120 |
| 不适用 | 0 |

这里的整例通过率不是单元测试通过率。没有任何整例被凭局部测试或静态检查自动标为通过。

## 源码版本与运行环境

初始 `baseline.xcresult` 为本次较早工作区的 App10/UI2通过；后续出现外部并发源码变化，因此不能称为冻结版本UI通过。Core的 `evidence/core-tests.log` 记录136通过，也不能据此推导App或硬件通过。

16:35冻结源码：`/private/tmp/rina-acceptance-a1-snapshot/ios`；可归档复查 `evidence/frozen-ios-source.tar.gz`、`evidence/frozen-ios-sha256.json`、`evidence/freeze-diff.json`。冻结运行证据：`evidence/frozen-baseline.xcresult`、`evidence/frozen-baseline-summary.json`、`evidence/frozen-baseline.log`。环境为 iPhone 17 Pro，专用 RinaAcceptance-a1-iPhone，iOS26.5 Simulator（23F77），zh-Hans，macOS27构建。

冻结运行合计32项：28通过、4失败；App29项中26通过、3失败；UI3项中2通过、1测试定位失败。其中Performance5全通过，Library10中9通过1失败，Recovery4中2通过2失败，原有App10全通过。App3个失败testcase有5个失败assertion，不能混算。未执行实板LED、真实音频同步或真实系统权限。

## 冻结自动化逐项索引

下列是实际小型测试结果，不是258项完整验收用例的完成状态。测试源码以冻结快照相应目录为准。

| 测试 | 结果 | 日志证据 |
| --- | --- | --- |
| RinaBoardTests.AcceptanceLibraryTests.testBatchCopyReportsInvalidItemAndPersistsOnlySuccessfulCopies | 通过 | `evidence/frozen-baseline.log:1634` |
| RinaBoardTests.AcceptanceLibraryTests.testDuplicateNamesRemainIndependentWhenOneIsEditedAndReloaded | 通过 | `evidence/frozen-baseline.log:1636` |
| RinaBoardTests.AcceptanceLibraryTests.testFailedImportLeavesExistingLibraryIntactAfterRestart | 通过 | `evidence/frozen-baseline.log:1638` |
| RinaBoardTests.AcceptanceLibraryTests.testFailedReorderPreservesPublishedAndPersistedOrder | 通过 | `evidence/frozen-baseline.log:1640` |
| RinaBoardTests.AcceptanceLibraryTests.testFailedUndoRetainsRetryAndSuccessfulRetrySurvivesRestart | 通过 | `evidence/frozen-baseline.log:1642` |
| RinaBoardTests.AcceptanceLibraryTests.testInvalidFrameInImportRejectsWholeDocumentWithoutChangingDisk | 通过 | `evidence/frozen-baseline.log:1644` |
| RinaBoardTests.AcceptanceLibraryTests.testOutOfRangeImportedByteIsRejectedInsteadOfChangingTheFrame | 失败 | `evidence/frozen-baseline.log:1649` |
| RinaBoardTests.AcceptanceLibraryTests.testProtectedFaceCannotBeRenamedOrDeletedButCanBeCopied | 通过 | `evidence/frozen-baseline.log:1651` |
| RinaBoardTests.AcceptanceLibraryTests.testSavedFaceSurvivesNewStoreAndModelInstances | 通过 | `evidence/frozen-baseline.log:1653` |
| RinaBoardTests.AcceptanceLibraryTests.testSelectedExportImportsIntoAnotherLibraryAndSurvivesRestart | 通过 | `evidence/frozen-baseline.log:1655` |
| RinaBoardTests.AcceptancePerformanceTests.testCustomScriptAndAudioRestoreIntoANewModelInstance | 通过 | `evidence/frozen-baseline.log:1666` |
| RinaBoardTests.AcceptancePerformanceTests.testImportedAudioRemainsAssociatedWithItsOwnBuiltInPerformance | 通过 | `evidence/frozen-baseline.log:1678` |
| RinaBoardTests.AcceptancePerformanceTests.testInvalidAudioImportKeepsThePreviouslyCommittedCustomAudio | 通过 | `evidence/frozen-baseline.log:1684` |
| RinaBoardTests.AcceptancePerformanceTests.testInvalidBuiltInAudioReplacementKeepsTheOldPerSongAssociation | 通过 | `evidence/frozen-baseline.log:1690` |
| RinaBoardTests.AcceptancePerformanceTests.testInvalidScriptImportKeepsThePreviouslyCommittedCustomScript | 通过 | `evidence/frozen-baseline.log:1692` |
| RinaBoardTests.AcceptanceRecoveryTests.testLogExportDoesNotLeakPasswordSuffixAfterEscapedJSONQuote | 失败 | `evidence/frozen-baseline.log:1698` |
| RinaBoardTests.AcceptanceRecoveryTests.testLogExportRedactsEntireBearerAuthorizationValue | 失败 | `evidence/frozen-baseline.log:1701` |
| RinaBoardTests.AcceptanceRecoveryTests.testLogExportRedactsJSONPasswordAndKeepsDiagnosticContext | 通过 | `evidence/frozen-baseline.log:1703` |
| RinaBoardTests.AcceptanceRecoveryTests.testRawDiagnosticsKeepUnknownNestedFieldsAndNullValues | 通过 | `evidence/frozen-baseline.log:1705` |
| RinaBoardTests.BoardConnectionOutputTests.testCancellingInflightFrameUnblocksNewSessionAndQuarantinesLateReply | 通过 | `evidence/frozen-baseline.log:1710` |
| RinaBoardTests.BoardConnectionOutputTests.testCommandRejectsFirmwareReplyWithOkFalse | 通过 | `evidence/frozen-baseline.log:1712` |
| RinaBoardTests.BoardConnectionOutputTests.testLateCompletionFromSupersededConnectCannotOverwriteNewConnection | 通过 | `evidence/frozen-baseline.log:1714` |
| RinaBoardTests.BoardConnectionOutputTests.testSupersededQueuedFrameDoesNotSendAndLateReplyDoesNotChangeCurrentFrame | 通过 | `evidence/frozen-baseline.log:1716` |
| RinaBoardTests.BoardPlaybackCoordinatorTests.testBeginInvalidatesOldTokenBeforeStoppingPreviousSource | 通过 | `evidence/frozen-baseline.log:1721` |
| RinaBoardTests.BoardPlaybackCoordinatorTests.testClaimReusesCurrentSessionAndOnlyStopsWhenSourceChanges | 通过 | `evidence/frozen-baseline.log:1723` |
| RinaBoardTests.BoardPlaybackCoordinatorTests.testInvalidateClearsSessionBeforeRunningStopHandler | 通过 | `evidence/frozen-baseline.log:1725` |
| RinaBoardTests.DraftStorageTests.testMissingDraftReturnsNilAndAtomicWriteCanBeReplaced | 通过 | `evidence/frozen-baseline.log:1730` |
| RinaBoardTests.FaceLibraryLocalTests.testLocalCreateRenameDeleteAndUndoPersistThroughStore | 通过 | `evidence/frozen-baseline.log:1735` |
| RinaBoardTests.FaceLibraryLocalTests.testLocalReorderValidatesCompleteSetAndFailedPersistenceKeepsPublishedOrder | 通过 | `evidence/frozen-baseline.log:1737` |
| RinaBoardUITests.AcceptanceUITests.testAllTabsPortraitAndSupportedRotationScreenshots | 通过 | `evidence/frozen-baseline.log:1905` |
| RinaBoardUITests.RinaBoardUITests.testDebugWorkspacesAreReachable | 通过 | `evidence/frozen-baseline.log:2032` |
| RinaBoardUITests.RinaBoardUITests.testLegacyControlCenterAndFaceLibraryAreReachable | 失败 | `evidence/frozen-baseline.log:2214` |

## frozen-baseline失败与完整用例映射

| 失败 | 对应完整用例 | 已执行证据与尚未覆盖 |
| --- | --- | --- |
| byte=256导入未拒绝 | FACE-021 | AcceptanceLibraryTests越界字节失败；有效往返/短帧拒绝/写失败保护通过；空JSON等完整导入矩阵仍未执行 |
| Bearer token未完整脱敏 | DBG-012、DBG-03 | AcceptanceRecoveryTests对应失败；导出字符串可见假token；分享UI/全部敏感字段/清空未全执行 |
| 转义引号后的密码尾部残留 | DBG-012、DBG-03 | AcceptanceRecoveryTests对应失败；普通JSON密码隐藏通过，不足以推导复杂值安全 |
| 旧Control命令不可达断言 | CTL-006、FACE-001、CC-010关联待核 | LegacyControlCenterAndFaceLibrary组合UI测试失败于“全亮”控件可达断言；后续表情库步骤未执行。归测试定位/陈旧断言，不能证实真实表情库不可达；冻结保存区已接入，按SNAPSHOT_DELTA.md重新执行 |

## 环境阻塞与待补矩阵

| 环境 | 当前判定 | 证据/原因 |
| --- | --- | --- |
| BLE/家庭Wi-Fi/个人热点/板载AP/物理麦克风与LED | 阻塞 | serial-status.txt为空；serial-retry.txt为Received bytes: 0。主流程两次status均0字节；DeviceHub没有全屏操作API且应用调用超时，未形成可执行链路 |
| iOS17最小支持系统 | 阻塞 | evidence/runtimes.json无iOS17 runtime |
| iOS27 | 6项：4通过、2失败 | ios27-summary.json；默认livePreview模型失败，早期offlineSave定位失败须看SE修正定位复验；其余为部分UI证据 |
| iPad | 首轮2定位失败，重试2通过 | ipad-summary.json、ipad-retry-summary.json；app截图横屏裁剪，不能证明布局通过；全屏复核尚无完成结果 |
| SE / iOS26.5 | 6项：4通过、2真实需求失败 | se-summary.json；离线保存按钮禁用、本机库位置缺失；新系统小屏不替代iOS17 |
| VoiceOver/Voice Control/Switch Control/指针/高对比/减少透明/减少动态/RTL | 未测试或外设阻塞 | 静态扫描和截图不能证明辅助操作完成 |

主流程补结果时：先核对冻结源码哈希和实际测试方法，再更新CSV对应行的环境/证据/已执行子步骤；仅子步骤通过时保留“未测试”，只有原用例全完成才改“通过”。明确预期已有失败反例即标失败，其余步骤继续标未测；陈旧定位断言不等于产品失败。iPhone不支持的横屏请求不可算支持方向验收通过。

本文件与CSV生成阶段只读取现有证据和测试源码；未运行设备、模拟器或测试，未修改其他文件。

## 冻结版替代范围与追加测试

SNAPSHOT_DELTA.md的13项已追加CSV，保留旧245项编号。静态入口差异只说明旧步骤须重绑，不算运行失败。CC-010/011的候选前提已失效：冻结产品已有保存区。

AcceptanceDefaultsTests.swift与SnapshotAcceptanceUITests.swift是16:35后允许加入的test harness；产品仍绑定冻结manifest，harness最终散列由主流程补充。iOS27模型测试证实新编辑器livePreview默认开启，违反用户明确开启前保持本地的要求。该新增默认值回归在此独立记录；已有用例以前置实时同步关闭开始，不能把默认值失败冒充手动关闭后行为失败。CSV相关行保留证据。

iOS27、iPad首轮/重试及SE结果已按以下逐项日志纳入；未将运行中重试或设备全屏截图复核记通过。

## 后续已完成运行逐项结果

所有运行仍绑定冻结产品；定位和截图harness变更须使用各次运行存档。重复运行不能简单累加为独立需求覆盖数。

| 运行 | 测试 | 结果 | 证据 |
| --- | --- | --- | --- |
| ios27 | RinaBoardTests.AcceptanceDefaultsTests.testRealtimeOutputIsOffForANewEditor | 失败 | `evidence/ios27.log:285` |
| ios27 | RinaBoardUITests.AcceptanceUITests.testAllTabsPortraitAndSupportedRotationScreenshots | 通过 | `evidence/ios27.log:452` |
| ios27 | RinaBoardUITests.AcceptanceUITests.testLocalizedTabsLargeTextLandscape | 通过 | `evidence/ios27.log:678` |
| ios27 | RinaBoardUITests.SnapshotAcceptanceUITests.testFiveTabsAndOfflineSendGate | 通过 | `evidence/ios27.log:750` |
| ios27 | RinaBoardUITests.SnapshotAcceptanceUITests.testOfflineSaveRemainsAvailable | 失败 | `evidence/ios27.log:924` |
| ios27 | RinaBoardUITests.SnapshotAcceptanceUITests.testTextDraftRestoresAfterBackgroundAndRelaunch | 通过 | `evidence/ios27.log:994` |
| ipad | RinaBoardUITests.AcceptanceUITests.testAllTabsPortraitAndSupportedRotationScreenshots | 失败 | `evidence/ipad.log:246` |
| ipad | RinaBoardUITests.AcceptanceUITests.testLocalizedTabsLargeTextLandscape | 失败 | `evidence/ipad.log:316` |
| ipad-retry | RinaBoardUITests.AcceptanceUITests.testAllTabsPortraitAndSupportedRotationScreenshots | 通过 | `evidence/ipad-retry.log:309` |
| ipad-retry | RinaBoardUITests.AcceptanceUITests.testLocalizedTabsLargeTextLandscape | 通过 | `evidence/ipad-retry.log:586` |
| se | RinaBoardUITests.AcceptanceUITests.testAllTabsPortraitAndSupportedRotationScreenshots | 通过 | `evidence/se.log:326` |
| se | RinaBoardUITests.SnapshotAcceptanceUITests.testDebugCancelDestructiveDialogAndReplayBootLocally | 通过 | `evidence/se.log:472` |
| se | RinaBoardUITests.SnapshotAcceptanceUITests.testFiveTabsAndOfflineSendGate | 通过 | `evidence/se.log:540` |
| se | RinaBoardUITests.SnapshotAcceptanceUITests.testLocalLibraryLocationRemainsAvailableOffline | 失败 | `evidence/se.log:758` |
| se | RinaBoardUITests.SnapshotAcceptanceUITests.testOfflineSaveRemainsAvailable | 失败 | `evidence/se.log:789` |
| se | RinaBoardUITests.SnapshotAcceptanceUITests.testTextDraftRestoresAfterBackgroundAndRelaunch | 通过 | `evidence/se.log:892` |

SE的offlineSave使用修正后的“label BEGINSWITH 保存”定位，存在断言通过而enabled断言失败，确认为离线保存需求失败（CTL-010）。localLibrary实际进入表情库后缺少“本机”，映射FACE-002/008失败；不能再仅凭旧Control全亮定位失败判断入口。SNAP用例记录冻结事实，与原需求失败口径分开。

设备条AXXXL溢出：`evidence/screenshots/iphone27-en-AXXXL-tab-0.png`、`iphone27-ja-AXXXL-tab-4.png`，主审REPORT DEF06，映射CC-009视觉预期失败；没有VoiceOver操作证据。

Debug取消CLEAR弹窗与本地启动动画重播、文字后台重启草稿、五标签离线发送gate的通过均为局部证据，不推导维护命令、双重播取消、速度恢复或全部生命周期通过。

`models-final.log`：15项新模型测试在执行前因UI harness使用不存在的XCUIDevice.screenshot编译失败，实际0项执行；不是15项产品测试失败。主流程已修正为XCUIScreen.main.screenshot，`models-retry`已完成15/15通过（Control8+Text7），证据models-retry-summary.json。本索引没有启动设备或测试。

## 新增离线模型复验

`models-retry-summary.json`：SE第3代/iOS26.5专用模拟器，Control8+Text7共15项全部通过；编译失败的models-final仍作为前次harness故障留档，不能并入产品失败数。CSV只标局部模型证据，保留实际手势/触感/板端/生命周期未执行范围。

| 模型测试 | 结果 | 证据 |
| --- | --- | --- |
| RinaBoardTests.AcceptanceControlTests.testClearInvertAndRevertRestoreTheEditingBaseline | 通过 | `evidence/models-retry.log:115` |
| RinaBoardTests.AcceptanceControlTests.testEyePartSelectionStaysMirroredWhileSyncIsEnabled | 通过 | `evidence/models-retry.log:117` |
| RinaBoardTests.AcceptanceControlTests.testLoadingSavedPartsFaceCreatesARevertBaselineAndNewFaceClearsIdentity | 通过 | `evidence/models-retry.log:119` |
| RinaBoardTests.AcceptanceControlTests.testPaintWritesExplicitBrushValueAndRepeatedStrokeIsNoOp | 通过 | `evidence/models-retry.log:121` |
| RinaBoardTests.AcceptanceControlTests.testSelectingEveryPartGroupRecomposesTheDisplayedFrame | 通过 | `evidence/models-retry.log:123` |
| RinaBoardTests.AcceptanceControlTests.testSentStateIsBoundToTheConnectionGeneration | 通过 | `evidence/models-retry.log:125` |
| RinaBoardTests.AcceptanceControlTests.testSyncedEyePaintMirrorsTheBrushValueInBothDirections | 通过 | `evidence/models-retry.log:127` |
| RinaBoardTests.AcceptanceControlTests.testUntouchedEditorAdoptsBoardFrameButEditedDraftRejectsLaterBoardFrame | 通过 | `evidence/models-retry.log:129` |
| RinaBoardTests.AcceptanceTextTests.testConflictChoicesKeepDraftOrExplicitlyAdoptBoardText | 通过 | `evidence/models-retry.log:134` |
| RinaBoardTests.AcceptanceTextTests.testDisconnectedSendKeepsDraftAndDoesNotLeaveRetryLocked | 通过 | `evidence/models-retry.log:136` |
| RinaBoardTests.AcceptanceTextTests.testEditingEnforcesVisibleLimitWithoutSplittingEarlierContent | 通过 | `evidence/models-retry.log:138` |
| RinaBoardTests.AcceptanceTextTests.testEditingMultilingualDraftPreservesEmojiAndLineBreaks | 通过 | `evidence/models-retry.log:140` |
| RinaBoardTests.AcceptanceTextTests.testEditingRetainsOverByteLimitDraftAndExposesExactBoundary | 通过 | `evidence/models-retry.log:142` |
| RinaBoardTests.AcceptanceTextTests.testInvalidSendDoesNotReplaceExistingBindingOrOutputOwner | 通过 | `evidence/models-retry.log:144` |
| RinaBoardTests.AcceptanceTextTests.testReleaseOutputClearsPlaybackBindingAndPhaseButKeepsUnsentDraft | 通过 | `evidence/models-retry.log:146` |

剩余单独更新点：ipad-screen设备全屏截图复核正在执行；需要核对完整截图和窗口方向后再更新SNAP-UI-001及UI-003/004/005/021，不能仅凭截图测试pass判断布局。其余硬件、iOS17与辅助技术阻塞保持。

## 最终工作区版本边界

`evidence/final-workspace-drift.json`记录16个当前产品文件偏离冻结版本；本矩阵只对冻结源码负责，不代表变化后的最新仓库验收结论。产品冻结副本的最终核对为0改动，见`evidence/final-frozen-verification.json`；测试代码另见`evidence/final-test-harness-sha256.json`。

## iPad最终整屏复核

`ipad-screen`2项定位失败；改为按实际导航层级选择标签后，`ipad-screen-retry`2项全部通过（summary与同名log）。整个屏幕截图采用`XCUIScreen.main.screenshot()`，横屏设置图`evidence/screenshots/ipad-full-layout-3-tab-4.png`没有旧`app.screenshot()`的右边截断/大片黑边。未将旧裁剪图判产品失败；分屏、所有sheet/键盘边界及VoiceOver仍未覆盖，相关完整用例保持原状态。
