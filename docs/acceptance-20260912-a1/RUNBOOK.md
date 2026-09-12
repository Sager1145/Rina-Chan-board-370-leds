# 验收执行与复跑

测试批次：`20260912-a1`。早期轮次以当时未提交工作区为构建源；16:35 后的轮次
固定使用 `/private/tmp/rina-acceptance-a1-snapshot/ios`，不以 HEAD 内容代替，也不把
冻结后的工作树变化混入结果。产品版本 2.0.0 (1)，最低 iOS 17.0。没有提交或刷写
固件。

## 边界与数据

- UI 只在本批次新建的 `RinaAcceptance-a1-*` 模拟器运行；禁止在用户日常模拟器/真机运行会编辑草稿的测试。
- 核心与App单元测试的模拟 transport 不证明物理 BLE/TCP 通过。
- `Acceptance*Tests.swift` 用独立临时目录、UserDefaults suite、虚构令牌、测试文本。UI表情名称带UUID；现有测试删除自己的表情。
- `git-before.txt` 是本任务基线；`source-sha256.json` 保存开始执行产品代码的工作区哈希。结果包包含测试机路径，但没有连接真实Wi-Fi或录制麦克风；不得填入真实密码后直接导出。

## 已执行命令

从仓库根目录执行。完整命令的参数按各轮结果包名称区分。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift test --package-path ios/Packages/RinaCore --scratch-path /private/tmp/rina-acceptance-a1-core
xcrun simctl create RinaAcceptance-a1-iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=D62E81EE-FA7A-47C5-A593-E1AC8124D114' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/baseline.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

增补首轮使用相同命令但结果包为 `extended.xcresult`，另加：

```sh
-only-testing:RinaBoardTests/AcceptanceRecoveryTests \
-only-testing:RinaBoardUITests/AcceptanceUITests
```

### 冻结源码轮次

16:35 后的轮次一律构建冻结产品副本
`/private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj`，并共用
`/private/tmp/rina-acceptance-a1-frozen-build`。`-only-testing` 限定执行范围，
`-parallel-testing-enabled NO` 保证同一模拟器上串行执行；这些命令不构建当前继续
变化的工作树产品。

**`frozen-baseline`（已执行）**：在 iPhone 17 Pro / iOS 26.5
`D62E81EE-FA7A-47C5-A593-E1AC8124D114` 上建立冻结基线。范围是全部
`RinaBoardTests`、原有 `RinaBoardUITests` 类，以及五标签/旋转截图用例；目的为
一次记录冻结模型、存储、旧入口可达性和基础布局。xcresult 统计 32 项，28 通过、
4 失败；失败按报告分别归因，不能把整轮 `TEST FAILED` 当成单一产品故障。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=D62E81EE-FA7A-47C5-A593-E1AC8124D114' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/frozen-baseline.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardTests \
  -only-testing:RinaBoardUITests/RinaBoardUITests \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  CODE_SIGNING_ALLOWED=NO test
```

**`ios27`（已执行）**：在 iPhone 17 Pro / iOS 27.0
`8BF8F6F1-1C32-4854-9859-5FFA51FA4E9F` 上检查新系统差异。范围包括新编辑器默认
实时输出、离线保存/恢复快照，以及五标签在普通字号与繁中/英文/日文最大辅助字号
下的旋转截图。xcresult 统计 6 项，4 通过、2 失败。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=8BF8F6F1-1C32-4854-9859-5FFA51FA4E9F' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/ios27.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardTests/AcceptanceDefaultsTests \
  -only-testing:RinaBoardUITests/SnapshotAcceptanceUITests \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testLocalizedTabsLargeTextLandscape \
  CODE_SIGNING_ALLOWED=NO test
```

**`ipad`（已执行）**：在 iPad / iOS 26.5
`EBB2B948-2492-42AC-A93B-EEB7160F7BE8` 上只运行两项标签、旋转、本地化和最大辅助
字号布局采集。两项都在启动就绪检查处失败：当时 harness 等待 iPhone 的
`TabBar`，但冻结 iPad UI 使用侧边栏图标；这是测试入口假设错误，尚未执行页面
断言，不能记为产品失败。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=EBB2B948-2492-42AC-A93B-EEB7160F7BE8' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/ipad.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testLocalizedTabsLargeTextLandscape \
  CODE_SIGNING_ALLOWED=NO test
```

**`ipad-retry`（已执行）**：保持同一冻结产品、模拟器和两项测试，只修正 harness
的 iPad 就绪/标签定位后复跑。xcresult 统计 2 项全部通过，用于证明侧边栏五项在
竖屏、横屏及三种语言最大辅助字号下可操作并成功生成附件。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=EBB2B948-2492-42AC-A93B-EEB7160F7BE8' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/ipad-retry.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testLocalizedTabsLargeTextLandscape \
  CODE_SIGNING_ALLOWED=NO test
```

**`se`（已执行）**：在小屏 iPhone SE / iOS 26.5
`E889C43F-2861-4A80-8080-12E477964D48` 上运行离线入口/保存/恢复快照与五标签截图，
目的为补最窄手机布局和操作可达性。日志记录 6 项，4 通过、2 失败；失败项需按
各自断言解释，不能由本轮退出码扩大成全部小屏布局失败。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=E889C43F-2861-4A80-8080-12E477964D48' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/se.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardUITests/SnapshotAcceptanceUITests \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  CODE_SIGNING_ALLOWED=NO test
```

### 最终模型轮与全屏截图轮

**`models-final`（已尝试，0 项执行）**：命令只选择
`AcceptanceControlTests` 与 `AcceptanceTextTests`，用于在 SE 目的地验证控制编辑、
镜像眼睛、保存表情载入/回退、连接代次，以及文字边界、冲突、离线重试与输出释放。
当时测试 harness 把截图 API 误写为不存在的
`XCUIDevice.shared.screenshot()`；scheme 构建 UI 测试 target 时编译失败，所以所选
模型测试没有开始。该记录是 harness 编译问题，不是产品测试失败。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=E889C43F-2861-4A80-8080-12E477964D48' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/models-final.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardTests/AcceptanceControlTests \
  -only-testing:RinaBoardTests/AcceptanceTextTests \
  CODE_SIGNING_ALLOWED=NO test
```

**`models-retry`（已执行）**：仅把 harness 截图调用修正为
`XCUIScreen.main.screenshot()`，其余选择、冻结工程、SE 目的地和 DerivedData 不变；
结果为 15 项模型测试全部通过。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=E889C43F-2861-4A80-8080-12E477964D48' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/models-retry.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardTests/AcceptanceControlTests \
  -only-testing:RinaBoardTests/AcceptanceTextTests \
  CODE_SIGNING_ALLOWED=NO test
```

**`ipad-screen`（已执行，2项定位失败）**：仍只运行两项 iPad 布局测试，但把所有保留截图和
tearDown 截图统一改用 `XCUIScreen.main.screenshot()`。目的不是重复计算已通过的
交互断言，而是采集完整主屏边界，解决前一轮 `app.screenshot()` 是否只截应用元素/
窗口、从而让附件看似被裁切的疑问。

`app.screenshot()` 的捕获范围随目标 application element 的可访问窗口 frame；在
iPad 侧边栏、旋转和 scene 布局下，附件边界看似裁切既可能是产品布局，也可能只是
捕获源范围。现有附件不足以区分两者，因此这个疑问不记为产品缺陷。
`XCUIScreen.main.screenshot()` 捕获主显示器完整画面，适合作为本轮判据。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -project /private/tmp/rina-acceptance-a1-snapshot/ios/RinaBoard.xcodeproj \
  -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=EBB2B948-2492-42AC-A93B-EEB7160F7BE8' \
  -derivedDataPath /private/tmp/rina-acceptance-a1-frozen-build \
  -resultBundlePath docs/acceptance-20260912-a1/evidence/ipad-screen.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testAllTabsPortraitAndSupportedRotationScreenshots \
  -only-testing:RinaBoardUITests/AcceptanceUITests/testLocalizedTabsLargeTextLandscape \
  CODE_SIGNING_ALLOWED=NO test
```

`ipad-screen`两项都停在查找TabBar的前置：测试运行器的`UIDevice.current.userInterfaceIdiom`没有反映目标App的iPad导航结构。随后测试改成检查实际TabBar是否存在，否则使用顶部标签按钮。`ipad-screen-retry`使用上方完全相同命令，只把结果路径改为`evidence/ipad-screen-retry.xcresult`，日志改为`evidence/ipad-screen-retry.log`。该定位修正不涉及产品代码。

静态检查：

```sh
python3 /Users/sager/.codex/skills/design-swiftui-interfaces/scripts/audit_swiftui_ui.py ios/RinaBoard
python3 tools/i18n/sync_catalog.py --check --objroot /private/tmp/rina-acceptance-a1-build/Build/Intermediates.noindex
python3 tools/i18n/apply_translations.py --check
xcrun xcresulttool get test-results summary --path <result.xcresult>
xcrun xcresulttool export attachments --path <result.xcresult> --output-path <attachments>
```

读CoreSimulator/SwiftPM缓存/xcresult内部索引需要沙箱外权限，已通过自动审核。首次受沙箱限制的命令不算测试失败；实际执行结果以日志的test case和xcresult统计为准。

## 硬件恢复后优先步骤

1. 提供可用桌面全屏控制接口或修复 Device Hub 控制超时；当前工具仅有应用目标控制，没有全局鼠标API。确认真机镜像可操作后，记录实际安装App版本与工作区构建的一致性。
2. USB板只读发送 `status`，收到完整 STATUS BEGIN/END 后核对正常启动、当前模式/亮度、固件版本。此次两轮共8秒读等待均收到0字节，未发输出命令。
3. 在iPhone App扫描指定测试板、用完整设备标识确认身份；连接后PING/刷新状态；读取板SSID及实际transport。先验证BLE，再做TCP与三条配网路线。
4. 串口可执行 `btn B4`、查询状态，再 `btn B5`、查询状态；从原亮度不在边界时验证减8/加8并回到原值。若边界，使用明确 `bright <原值>` 恢复。没有可读基线时不要执行。
5. B1/B2、B3及组合动作会改变当前显示/模式/间隔，应逐项记录原状态再执行并恢复。它们不等于GPIO电气长按/消抖；B6不支持。
6. 执行两个面板的快速切换、迟到应答、断线重连与30个有向模式切换，记录iPhone/板端双方时间戳和LED录像。没有镜像/录像不能声称音频、预览与实体LED同步。

## 破坏性项目：待确认的具体步骤

未执行，也未提前索取没有可执行前置的授权。恢复硬件访问后再在执行前请求用户确认：

- **清空面板用户表情**：先导出面板完整库并核对数量/哈希；列出会删除的用户表情；进入Debug维护→清除用户表情，先取消并核对数量不变；获得针对该板的确认后再执行清除，验证默认表情保留、重新读取一致，再导回备份并逐帧核对。导回可能不能恢复原ID/排序，因此必须说明这一点。
- **重置电源校准**：先读取并记录原校准值和测量条件；打开确认后取消，核对未变化；获得确认后再重置，核对返回值和重新采样显示；若协议不支持精确恢复原系数，不能承诺自动恢复。
- **面板删除**：仅创建本批次UUID测试表情，核对来源与ID后请求板端不可撤销删除确认；先取消验证，再确认删除。不得删除用户素材。

最终`ipad-screen-retry`实际2项、2通过、0失败；数量以`evidence/ipad-screen-retry-summary.json`为准。原裁剪附件与两轮定位失败完整保留。
