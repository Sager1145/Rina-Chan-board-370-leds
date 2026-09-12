# 冻结 iOS 快照与功能清单差异

> 冻结版本：`/private/tmp/rina-acceptance-a1-snapshot/ios`，主流程记录的冻结时间为 2026-09-12 16:35:01（本地时间）。  
> 身份证据：`evidence/source-sha256.json` 与 `evidence/frozen-ios-sha256.json`。  
> 本文只记录静态可证的界面、入口和清单映射差异，不是运行测试结果。编制时未构建、未启动模拟器、未连接硬件。  
> `FEATURE_CASES.md` 保留为冻结前的历史功能清单；执行冻结快照时，以本文修订其入口、步骤、预期和代码位置，不回写历史清单。

## 1. 版本边界

散列清单确认冻结版本与最初编制 `FEATURE_CASES.md` 时的 source baseline 不同。以下是直接影响验收入口的文件；完整文件散列以两份 JSON 为准。

| 文件 | source baseline SHA-256 | frozen iOS SHA-256 |
| --- | --- | --- |
| `RinaBoard/App/RootTabView.swift` | `f71b5dcba947…` | `b0a639372e55…` |
| `RinaBoard/Features/Control/ControlView.swift` | `ce46eb206fe6…` | `304056b72ec6…` |
| `RinaBoard/Features/Control/ControlViewModel.swift` | `ce07a0b24fbe…` | `d4ebae246e7a…` |
| `RinaBoard/Features/Faces/FaceLibraryView.swift` | `2ea221472865…` | `af592ff85745…` |
| `RinaBoard/Features/ControlCenter/BoardControlCenterView.swift` | `50520fda8aa9…` | `5c7de5822315…` |
| `RinaBoard/Features/ControlCenter/BoardControlCenterAccessory.swift` | `5ec0cb59ea57…` | `3f594859f7fc…` |
| `RinaBoard/Features/Settings/SettingsView.swift` | `ca2415364aa5…` | `f00eb1f58e84…` |
| `RinaBoard/Features/Connection/ConnectionView.swift` | `4547d2d819c9…` | `56b9c123ca06…` |
| `RinaBoard/Features/Text/ScrollTextView.swift` | `0dea454c70ce…` | `6f9ae605dbec…` |
| `RinaBoard/Features/LipSync/LipSyncView.swift` | `a30209294d94…` | `3d2a41283f6d…` |
| `RinaBoard/Features/PresetLive/PresetLiveView.swift` | `2b5463697efb…` | `49d3aca15f0a…` |
| `RinaBoard/Resources/Localizable.xcstrings` | `70201b261076…` | `fc06000965a7…` |

旧的构建、截图或测试结果只有在其源散列与 `frozen-ios-sha256.json` 对应时，才能作为冻结版证据。文件名相同或测试名相同不能证明版本相同。

### 1.1 冻结后加入的测试 harness

复核时发现以下两个测试文件的修改时间为 16:37:33，晚于 16:35:01 的冻结 manifest，且 `frozen-ios-sha256.json` 不含它们的键：

- `RinaBoardTests/AcceptanceDefaultsTests.swift`
- `RinaBoardUITests/SnapshotAcceptanceUITests.swift`

三个关键产品文件的现场散列仍与 manifest 相同：RootTab `b0a639…`、Control `304056…`、FaceLibrary `af592f…`。因此本文的产品判断仍绑定 16:35 manifest；上述两份测试应标记为 **post-freeze test harness**，由主流程另存散列和加入时间。除非重新生成完整 manifest，不应描述整个快照目录在 16:35 后完全未变。

## 2. 冻结版实际导航图

冻结版仍有五个同级标签：

1. `控制` → `ControlView`
2. `文字` → `ScrollTextView`
3. `口型` → `LipSyncView`
4. `演出` → `PresetLiveView`
5. `设置` → `SettingsView`

实际二级入口如下：

| 平台/入口 | 冻结版目标 | 静态位置 |
| --- | --- | --- |
| iOS 26 底部附件的摘要区 | 始终展开 `BoardControlCenterView` sheet；未连接时也不是连接 sheet | `snapshot:RinaBoard/App/RootTabView.swift:275-324`；`BoardControlCenterAccessory.swift:102-143` |
| iOS 26 底部附件的右侧控件 | 上一个、下一个、自动模式、面板颜色、发送控制草稿 | `snapshot:…/BoardControlCenterAccessory.swift:51-92,145-257` |
| iOS 17–25 设置页首部 | 推入 `BoardControlCenterView` | `snapshot:…/SettingsView.swift:27-40` |
| 所有系统版本的连接入口 | `设置` → `连接设置` | `snapshot:…/SettingsView.swift:57-67` |
| 控制中心 | `管理表情` → `FaceLibraryView` | `snapshot:…/BoardControlCenterView.swift:374-399` |
| 口型页 | `口型与造型` → `LipSyncMouthMappingView` | `snapshot:…/LipSyncView.swift:281-301` |
| 设置页 | `调试工具`、`关于` | `snapshot:…/SettingsView.swift:139-177` |

启动参数映射也需按冻结版解释：`faces` 只选择控制标签；`connect` 只选择设置标签，不会自动推入连接页；`debug` 选择设置并通过 `opensDebug` 自动推入 Debug。证据为 `snapshot:RinaBoard/App/RootTabView.swift:5-20` 与 `SettingsView.swift:20-52`。

## 3. 控制、表情库与保存路径的实质变化

### 3.1 控制页

冻结版控制页是隐藏导航栏的三段 `List`：预览、两行命令 chip、部件选择。没有页面标题、导航栏按钮或右上角表情库入口。证据为 `snapshot:RinaBoard/Features/Control/ControlView.swift:29-61,71-235`。

| 冻结前清单假设 | 冻结版静态事实 | 受影响用例 |
| --- | --- | --- |
| 控制页有“逐灯编辑”展开区、LED Stepper 和行列说明 | 视图中没有逐灯控件；只有在预览上触摸/拖动绘制 | `CTL-008`、`UI-015`；两条不能按旧步骤执行 |
| 未连接时仍能保存到本机 | “保存”打开 alert，并固定调用面板库 `faceLibrary.save(payload, connection:)`；按钮在未连接时禁用 | `CTL-010` 的本机保存预期失效 |
| 保存 sheet 可选“本机/当前面板”、校验名称、覆盖或另存 | 冻结版是单一名称 alert；没有位置选择；alert 的保存按钮未设置禁用条件；编辑时另有“另存为新表情”chip | `CTL-015` 必须重写 |
| 控制页有“发送表情”主按钮和发送状态说明 | `ControlView` 内无 `model.send` 按钮；发送位于 iOS 26 底部附件最右侧。控制页只显示“未发送”状态 | `CTL-011`、`CTL-013`、`VIS-001` 的入口和预期失效 |
| 控制页可直接打开表情库 | 唯一可见表情库入口是控制中心的“管理表情” | `FACE-001` 入口失效 |

`CTL-001` 至 `CTL-007`、`CTL-009`、`CTL-012`、`CTL-014`、`CTL-016` 的核心状态机意图仍有相应代码，但旧行号不再可靠，应绑定冻结版 `ControlView.swift:71-235`、`ControlViewModel.swift:146-333` 和共享预览文件后执行。

### 3.2 表情库

冻结版 `FaceLibraryView` 只有当前面板的“默认表情/我的表情”两组。它支持点行应用、面板内重命名/删除、立即排序，以及整个面板文档导入/导出；没有库位置切换、搜索、详情页、多选或本机操作界面。证据为 `snapshot:RinaBoard/Features/Faces/FaceLibraryView.swift:22-165`。

`FaceLibraryModel` 仍定义本机文档、`LocalFaceStore`、复制、撤销和批量方法（例如 `FaceLibraryModel.swift:37-65,101-135,417-524`），但静态搜索没有发现冻结版可见 View 调用本机加载/保存或跨库 API。因此这是“模型能力存在、冻结 UI 无入口”，不能把模型单元测试当作用户功能可达证据。

| 旧用例 | 冻结版处理 |
| --- | --- |
| `FACE-001` | 改为从控制中心点“管理表情”；不是控制页 sheet |
| `FACE-002`、`FACE-004`、`FACE-008`、`FACE-010`、`FACE-014`、`FACE-015`、`FACE-021` | 旧步骤依赖本机库 UI；冻结版不可执行。若本轮明确要求本机库，这些应记为范围缺口并保留静态证据，不应假装点过隐藏模型 API |
| `FACE-003` | 搜索 UI 不存在，旧步骤不可执行 |
| `FACE-005` | 只保留面板库下拉刷新意图；位置切换、独立空/错误态步骤须删除并按 `FaceLibraryView.swift:22-58` 重写 |
| `FACE-006`、`FACE-023` | 详情页不存在，旧步骤不可执行 |
| `FACE-007` | 改为直接点面板表情行；没有详情“应用到面板”按钮，也没有本机来源分支 |
| `FACE-009` | 冻结 View 的“编辑”直接调用 `editor.loadForEditing(face)`，绕过模型的 `requestEdit(...asCopy:)`；旧“编辑副本”步骤和保护语义不能照用 |
| `FACE-011` | 仍应验证换板后不覆盖旧 ID，但冻结入口没有把库位置和连接代次传给编辑器；按静态风险项执行 |
| `FACE-012` | 仅有面板列表重命名；没有详情或本机分支 |
| `FACE-013` | “创建副本”入口不存在 |
| `FACE-016` | 面板删除仍存在，但滑动/长按会直接调用删除；旧确认步骤不存在 |
| `FACE-017` | 多选与批量操作 UI 不存在 |
| `FACE-018`、`FACE-019` | 排序是列表 EditMode + `.onMove` 立即持久化；没有独立排序草稿、取消或 VoiceOver 上/下移动界面，旧预期失效 |
| `FACE-020` | 只保留“导出全部”；单个/所选导出入口不存在 |
| `FACE-022` | 面板整库导入仍可执行，代码位置改为 `FaceLibraryView.swift:63-95` 与 `FaceLibraryModel.swift:580-617` |

### 3.3 编辑交接

冻结版存在三条不同的编辑代码路径：

- 根视图监听 `pendingEditRequest` 时会加载编辑对象、切换到控制标签并消费请求（`snapshot:RinaBoard/App/RootTabView.swift:134-139`）。
- 表情库 context menu 没有调用 `requestEdit`，而是直接 `editor.loadForEditing(face)` 后 `dismiss()`（`snapshot:…/FaceLibraryView.swift:129-143`）。
- 控制中心保存行直接 `editor.loadForEditing(face)`，既不 dismiss，也不切换标签（`snapshot:…/BoardControlCenterView.swift:426-437`）。

冻结版可见入口均未使用第一条完整路由。执行 `FACE-009`、`FACE-011`、`CC-011` 时应记录用户最终停留页面、能否发现草稿已加载、编辑目标的位置/连接代次，以及保存后写入哪个库；静态代码只能证明路径不同，不能替运行结果判缺陷。

## 4. 控制中心附件差异

冻结版重新把 `savesSection` 插入控制中心，并提供导航栏“保存当前”；`FEATURE_CASES.md` 中把它标成“未上线候选能力”的描述已失效。`CC-010` 在冻结版应作为正式用例执行。证据为 `snapshot:RinaBoard/Features/ControlCenter/BoardControlCenterView.swift:32-84,374-399`。

| 旧用例 | 冻结版处理 |
| --- | --- |
| `NAV-005` | 未连接时附件也打开“面板控制”，不是“连接”sheet；连接需走设置页 |
| `CC-001` | 附件摘要只有连接状态、亮度、自动/手动；展开页显示面板名、电量、模式、当前表情。旧“当前输出”预期无对应 UI |
| `CC-002` 至 `CC-007` | 核心控制仍存在，按冻结行号 `BoardControlCenterView.swift:160-365` 执行 |
| `CC-008` | 活动来源摘要、“查看”跳转和暂停/停止控件均不在冻结附件；整条旧用例不可照用 |
| `CC-009` | 只保留摘要在辅助字号时收起副标题、VoiceOver value 和五个面板控件可达性；删除旧“查看/暂停”步骤 |
| `CC-010` | 改为正式验证“保存当前”、表情列表、应用和“管理表情”；不再条件性记不适用 |
| `CC-011` | 保留，但使用上节的实际编辑交接路径判定 |
| `CC-012` | 控制中心没有“连接设置”；旧步骤不可执行。连接入口在设置页 |

iOS 26 附件新增的冻结版验收重点是：五个固定控件在已连接时可用、未连接时整组禁用；只有摘要区展开 sheet；操作控件不能同时触发展开；发送按钮显示 `editor.isSending` 进度。代码位置为 `snapshot:…/BoardControlCenterAccessory.swift:51-92,102-257`。

## 5. 连接、布局及其他页面差异

### 5.1 连接页

冻结版连接页是单个长 `Form`，依次为状态、蓝牙、板名、家庭 Wi-Fi、热点直连、iPhone 热点、板载 Wi-Fi 设置（`snapshot:RinaBoard/Features/Connection/ConnectionView.swift:29-48`）。

| 旧用例 | 冻结版处理 |
| --- | --- |
| `CONN-001` 至 `CONN-005` | 冻结 View 没有 `PhoneNetworkInfo`、读取当前 iPhone Wi-Fi、定位授权状态或手填手机 SSID 的可见控件；旧步骤不可执行 |
| `CONN-006` | 改为验证传输方式、连接状态、BLE 名称、板端 IP/RSSI；删除手机 SSID 与三类事实分栏预期 |
| `CONN-007` 至 `CONN-011` | 功能意图仍存在，但入口和行号改为同一 Form 的对应 section |
| `CONN-012` | 模型有 `connectSavedBoard`，View 只在 BLE 扫描项显示“已保存”徽章；没有已保存设备列表、重连行或左滑移除，旧步骤不可执行 |
| `CONN-013` | 根视图自动重连仍存在，改绑 `RootTabView.swift:235-259` |
| `CONN-014` 至 `CONN-016`、`CONN-018` 至 `CONN-026` | 大部分操作仍在长 Form 中；旧 `ConnectionView.swift:500-1244` 行号全部越出冻结文件的 516 行范围。阶段显示需按冻结 UI 重写 |
| `CONN-019` | 模型仍区分发送、等待、连板等状态，但 View 把中间状态统一显示为“等待板子加入热点…”；旧“阶段依次显示”预期不能直接沿用 |
| `CONN-022` | 直连按钮只有进行中 spinner；模型阶段未完整映射为可见说明，应分别记录系统确认、连接结果和可恢复错误 |
| `CONN-023` | 板名编辑就在连接主 Form，不存在“网络与名称”子页 |
| `CONN-027` | 是服务层代次安全用例，继续执行；View 行号变化不改变测试意图 |

### 5.2 共用布局与标题

冻结树没有 `RinaBoard/Features/Shared/Components/FeatureWorkspace.swift`。控制、文字、口型和演出都直接使用单栏 `NavigationStack + List`，并隐藏 navigation bar：

- Control：`ControlView.swift:29-40`
- Text：`ScrollTextView.swift:18-29`
- LipSync：`LipSyncView.swift:20-35`
- PresetLive：`PresetLiveView.swift:27-39`

因此 `NAV-008`、`UI-003`、`UI-004`、`UI-005`、`UI-021` 中的 `FeatureWorkspace` 部分、`UI-025` 及所有“760 pt 自动双栏/页面设备状态行”预期均不适用于冻结版。iPad、旋转、最大字号仍须测试，但判定目标应改为冻结版单栏 List 是否完整可达，不能因没有双栏直接给运行用例判失败，除非双栏本身是确认的产品要求。

主页面设置过 `navigationTitle` 的口型页也同时隐藏了 navigation bar；控制、文字、演出没有可见页面标题。`UI-001` 和各视觉用例应明确检查“标签选择是否足以建立页面身份”，并将无标题作为冻结事实记录，不要沿用旧截图定位。

### 5.3 文字与演出

- `TEXT-001` 的“编辑器聚焦时预览隐藏”不成立：冻结版始终把 `previewSection` 放在列表首项，焦点只改变编辑器边框。证据为 `snapshot:…/ScrollTextView.swift:18-29,104-176`。其余文字状态机用例可保留，但 View 行号需重绑。
- 冻结演出页没有歌曲列表或歌曲详情页；它使用一个菜单 Picker、内联艺人/时长/关键帧摘要，以及选中自定义模式后才显示的音频/脚本按钮（`snapshot:…/PresetLiveView.swift:172-264`）。`LIVE-002`、`LIVE-003`、`LIVE-004`、`LIVE-006`、`LIVE-008` 的“列表/详情/使用此演出/使用已保存自定义”步骤必须按此结构重写。
- `songSelection` 对“自定义…”值直接返回，不改变 `selectedBuiltIn`（`PresetLiveView.swift:227-235`）。执行时需单独确认从内置演出能否进入自定义素材；这里只标记静态可达性风险，不先判失败。

### 5.4 旧代码位置失效速查

散列已经不同，因此即使旧行号仍落在文件范围内，也必须先核对语义。下表列出可直接判定失效的索引：

| `FEATURE_CASES.md` 旧索引/常见引用 | 冻结版事实 | 执行要求 |
| --- | --- | --- |
| `ControlView.swift:4-186` 及 `:112-119` 表情库入口 | 冻结文件 265 行；112–119 是实时预览和随机按钮的一部分 | 改绑 `:29-61,71-235`，不得用旧行号证明入口存在 |
| `FaceLibraryView.swift:20-643` | 冻结文件只有 180 行，且是面板单库实现 | 所有超过 180 的引用失效；按 `:22-165` 重写 |
| `BoardControlCenterAccessory.swift:3-75` | 冻结文件 311 行，已从活动附件变为带五项面板控件的附件 | `CC-001/008/009` 全部重新定位和解释 |
| `BoardControlCenterView.swift:32-72,362-440` 被描述为未接入保存区 | 冻结 `body` 在 38 行插入 `savesSection`，42–60 行有保存 toolbar | 使用 `:32-84,374-451`，删除“候选未上线”前提 |
| `ConnectionView.swift:7-1244` 及 `:500-1244` | 冻结文件 516 行；后半旧引用大多越界 | 按单 Form 的 `:29-475` 逐 section 重绑 |
| `FeatureWorkspace.swift:*` | 冻结树不存在该文件 | `NAV-008`、`UI-003/004/005/021/025` 不得继续引用 |
| `ScrollTextView.swift:10-246` | 冻结文件 229 行，布局散列不同 | 按 `:18-229` 重绑；删除聚焦隐藏预览预期 |
| `PresetLiveView.swift:5-368` | 冻结文件 285 行，无列表/详情导航 | 按 `:27-281` 和 Picker 结构重写 |
| `RootTabView.swift` 的旧散列与入口语义 | 冻结文件 334 行；未连接附件和 `connect` 启动参数行为变化 | 以 `:5-20,80-197,262-334` 为准 |

## 6. 冻结版替代验收点

这些条目用于替代已失效的旧步骤，初始状态全部为 **未测试**。

| ID | 前置 | 步骤 | 冻结版预期/需记录 | 状态 |
| --- | --- | --- | --- | --- |
| SNAP-NAV-001 | iOS 26，未连接 | 点附件摘要；关闭；进入设置并点连接设置 | 摘要打开面板控制 sheet；连接只从设置进入；关闭不换标签 | 未测试 |
| SNAP-NAV-002 | 可传启动参数 | 分别以 `faces/connect/debug` 启动 | `faces` 停在控制；`connect` 停在设置根；`debug` 推入 Debug | 未测试 |
| SNAP-CTL-001 | iOS 26，已连接，实时预览关闭 | 编辑控制草稿；点附件最右发送 | 只由附件发送；进度可见；附件操作不展开 sheet | 未测试 |
| SNAP-CTL-002 | iOS 17，已连接，实时预览关闭 | 编辑草稿；检查控制页、设置和控制中心所有可见操作 | 记录是否有明确可达的发送动作；若无，引用冻结代码和录屏交产品范围判定 | 未测试 |
| SNAP-CTL-003 | 未连接 | 编辑草稿；检查保存；重启后恢复 | 面板保存禁用；不存在本机库保存入口；草稿持久化仍应工作 | 未测试 |
| SNAP-CTL-004 | VoiceOver | 不用坐标拖画，尝试指定并修改某一 LED | 记录是否存在等效可操作路径；冻结版没有旧 Stepper，不以静态阅读代替结果 | 未测试 |
| SNAP-FACE-001 | iOS 17 与 iOS 26 各一次 | 按实际导航进入表情库 | iOS 17：设置→控制中心→管理表情；iOS 26：附件→控制中心→管理表情 | 未测试 |
| SNAP-FACE-002 | 未连接/已连接各一次 | 遍历表情库全部控件 | 记录仅面板库可见；没有本机切换、搜索、详情、多选、复制、撤销入口 | 未测试 |
| SNAP-FACE-003 | 面板有默认及用户表情 | 从表情库和控制中心分别触发编辑 | 记录停留页面、反馈、控制草稿、目标 ID/连接代次和后续保存库 | 未测试 |
| SNAP-CC-001 | iOS 26，已连接 | 逐一操作附件上一步、下一步、自动、颜色、发送；分别点摘要和控件 | 五项控制各执行一次且不会展开；摘要才展开；面板和展开页一致 | 未测试 |
| SNAP-CONN-001 | 所有连接环境 | 从设置进入连接；完成 BLE/家庭/直连/个人热点路径 | 全部位于同一 Form；记录各阶段实际可见文案，不套用旧子页或手机 SSID 预期 | 未测试 |
| SNAP-LIVE-001 | 当前选中内置演出 | 在歌曲 Picker 选择“自定义…” | 记录是否能显示音频/脚本入口并完成自定义选择；失败时保留页面和选择态证据 | 未测试 |
| SNAP-UI-001 | iPad 窄/宽窗口与最大字号 | 遍历控制、文字、口型、演出 | 按冻结版单栏 List 验证可滚动、无裁切、状态不丢；不要求 760 pt 双栏 | 未测试 |

## 7. 执行优先级与静态风险

以下均是基于冻结快照的运行重点，不是已确认缺陷：

1. **最高优先级：本机表情库可达性。** 模型和存储仍存在，但可见 View 没有本机入口；这直接影响 `DATA-FACE`、离线保存、跨库复制、撤销和本机导入导出范围。
2. **最高优先级：控制草稿发送的系统版本差异。** iOS 26 附件有发送；iOS 17–25 没有附件，控制页和展开控制中心也没有等价 `send` 按钮。执行 `SNAP-CTL-002` 后再判定。
3. **高优先级：逐灯无障碍替代。** 直接触摸编辑仍存在，但旧 Stepper 已移除；需 VoiceOver/Voice Control 证据确认指定 LED 任务能否完成。
4. **高优先级：编辑交接。** 可见入口绕过带 location、asCopy、boardGeneration 的 `FaceEditRequest` 路由；应验证默认/锁定项、换板和保存目标。
5. **高优先级：演出自定义入口。** Picker 对自定义 sentinel 没有状态转移；需运行确认入口是否可达。
6. **中优先级：连接事实和阶段透明度。** 手机 Wi-Fi 权限/SSID UI、已保存设备列表和细分阶段视图不在冻结 View；按确认产品范围判定，不用模型字段代替用户可见证据。
7. **中优先级：页面身份与 iPad 布局。** 四个主任务隐藏导航栏并采用单栏；需在大字号和宽窗口下确认内容层级、滚动位置和主要动作仍清楚。

主流程执行冻结快照时，应先完成 `SNAP-NAV/CTL/FACE/CC`，再继续旧清单中不依赖已移除入口的模型、连接和跨输出用例。任何旧用例若步骤找不到，应记录为“清单与冻结版不匹配”，再依据本文替代步骤执行；不能把“找不到旧入口”自动换算为该行为已失败或通过。
