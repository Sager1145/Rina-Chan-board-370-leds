# iOS 功能与 UI 验收用例

> 基线：2026-09-12 工作区静态快照  
> 状态：本文所有用例均为 **未测试**。代码阅读、已有测试文件和静态扫描只用于设计用例，不计为通过证据。  
> 执行约束：本文编制阶段未启动模拟器、未连接硬件、未执行构建或测试。

## 1. 范围、判定与证据

验收范围覆盖五个主标签、控制中心、表情库、连接、Debug、启动流程、跨功能输出仲裁，以及 iPhone/iPad、语言、外观、字号和辅助功能矩阵。产品采用 `standard` 界面验收档位：系统导航和控件语义优先，功能稳定性、可达性和状态真实性优先于装饰效果。

执行人应把每条状态从“未测试”改为“通过 / 失败 / 阻塞 / 不适用”，并记录日期、构建号、设备、OS、连接方式、语言、截图或录屏路径。物理链路用例不得用模拟器结果替代；静态检查不得用作功能通过证据。

| 标记 | 含义 |
| --- | --- |
| 未测试 | 初始状态；尚无运行时证据 |
| 通过 | 在写明的环境中完成全部步骤且符合全部预期 |
| 失败 | 可复现地偏离任一预期；需记录实际结果 |
| 阻塞 | 环境、权限、素材或硬件不具备；需记录阻塞条件 |
| 不适用 | 该构建或平台明确不支持；需说明依据 |

建议证据命名：`<用例ID>_<设备>_<语言>_<结果>.<png|mov|txt>`。快速点击、断线、后台、导入失败等状态应保留录屏；涉及板载输出时，同时记录手机界面和 370 LED 面板。

## 2. 基准环境与测试数据

### 2.1 环境矩阵

| 环境 ID | 最低配置 | 用途 | 初始状态 |
| --- | --- | --- | --- |
| ENV-PHONE-S | 最小受支持 iPhone 宽度，iOS 17.x，竖屏 | 旧系统入口、窄屏、最小布局 | 未测试 |
| ENV-PHONE-T | 典型 iPhone，iOS 26.5，竖屏 | 主功能与 iOS 26 底部附件 | 未测试 |
| ENV-PAD-N | iPad，窄分屏/窄窗口，iOS 26.5 | 单栏阈值、窗口调整 | 未测试 |
| ENV-PAD-W | iPad，全屏或宽度 ≥760 pt，iOS 26.5 | 预览/工具双栏 | 未测试 |
| ENV-HW-BLE | 真机 + 物理面板，BLE 可用 | 蓝牙、口型、板载输出 | 未测试 |
| ENV-HW-LAN | 真机 + 面板 + 家庭 Wi-Fi | Bonjour/TCP、重连、配网 | 未测试 |
| ENV-HW-PH | 真机 + 面板 + iPhone 个人热点 | 热点配置与 TCP 切换 | 未测试 |
| ENV-HW-AP | 真机 + 面板直连热点 | NEHotspotConfiguration 与直连 TCP | 未测试 |

iPhone 只声明竖屏与倒置竖屏；iPad 声明四方向。不要把 iPhone 横屏列为必过项。代码位置：`ios/RinaBoard/Info.plist:53-64`，部署目标与设备族：`ios/RinaBoard.xcodeproj/project.pbxproj`（iOS 17.0，iPhone/iPad）。

### 2.2 数据夹具

| 夹具 ID | 内容 |
| --- | --- |
| DATA-FACE | 1 个默认/受保护表情；至少 3 个可编辑本机表情；至少 3 个可编辑面板表情；名称含中英日、64 字符边界 |
| DATA-TEXT | 短 ASCII、中文、日文、emoji、换行文本；恰好 4096 UTF-8 字节；超过 4096 字节文本 |
| DATA-LIVE | 一个有效 `.rinalive`、一个无效 UTF-8 文件、一个语法/部件无效脚本；有效音频、损坏音频、时长与脚本不同的音频 |
| DATA-FRAME | 有效 94 位 hex、47 项整数 JSON、base64；三种无效封包帧 |
| DATA-LOG | 含 app/firmware、debug/info/warn/error 以及 `password/token/authorization` 字段的日志 |
| DATA-NET | 开放网络、加密网络、错误密码网络；可发现与不可解析 Bonjour 项；BLE 同名设备和不同 RSSI |

### 2.3 关键代码索引

| 区域 | 主要代码位置 |
| --- | --- |
| 根导航/生命周期 | `ios/RinaBoard/App/RootTabView.swift:4-339`；`AppRouter.swift:3-6` |
| 控制 | `ios/RinaBoard/Features/Control/ControlView.swift:4-186`；`ControlViewModel.swift:15-401` |
| 表情库 | `ios/RinaBoard/Features/Faces/FaceLibraryView.swift:20-643`；`FaceLibraryModel.swift:39-768` |
| 文字 | `ios/RinaBoard/Features/Text/ScrollTextView.swift:10-246`；`TextViewModel.swift:12-518` |
| 口型 | `ios/RinaBoard/Features/LipSync/LipSyncView.swift:10-425`；`LipSyncModel.swift:21-456` |
| 演出 | `ios/RinaBoard/Features/PresetLive/PresetLiveView.swift:5-368`；`PresetLiveModel.swift:71-683` |
| 控制中心 | `ios/RinaBoard/Features/ControlCenter/BoardControlCenterView.swift:14-440`；`BoardControlCenterAccessory.swift:3-75` |
| 连接 | `ios/RinaBoard/Features/Connection/ConnectionView.swift:7-1244`；`ConnectionViewModel.swift:7-508` |
| 设置/Debug | `ios/RinaBoard/Features/Settings/SettingsView.swift:11-165`；`DebugView.swift:5-567`；`DebugViewModel.swift:210-775` |
| 共用布局/预览 | `ios/RinaBoard/Features/Shared/Components/FeatureWorkspace.swift:4-67`；`BoardPreviewRow.swift:18-140`；`LEDBoardPreview.swift:40-240`；`BoardPreviewZoom.swift:12-230` |

## 3. 导航、启动与生命周期

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| NAV-001 | 全新安装/清空偏好 | 启动 App；等待启动层完成 | 首屏为“控制”；底栏恰有“控制/文字/口型/演出/设置”五个同级标签；启动层最终不拦截触摸 | `RootTabView.swift:4-37,80-197`；`BootLoaderModel.swift:58-166` | 未测试 |
| NAV-002 | `记住上次的标签页` 关闭 | 切到任一非控制标签；终止并重启 | 仍回到控制标签 | `RootTabView.swift:23-37,92-104`；`AppSettings.swift:16-19` | 未测试 |
| NAV-003 | `记住上次的标签页` 开启 | 依次选“文字”“演出”；终止重启 | 每次重启恢复最后选择的有效标签 | `RootTabView.swift:23-37,92-104` | 未测试 |
| NAV-004 | 可传启动参数 | 分别以 `control/faces/text/lipSync/lipsync/presetLive/liveVideo/video/settings/debug/connect/未知值` 启动 | 旧值映射到新入口；`faces→控制`、`debug/connect→设置子页`、未知值→控制；无第六标签 | `RootTabView.swift:4-20`；`SettingsView.swift:20-53` | 未测试 |
| NAV-005 | iOS 26.5，未连接 | 点底部面板附件的展开区 | 打开“连接”sheet；可完成关闭；主标签选择不被替换 | `RootTabView.swift:275-329`；`BoardControlCenterAccessory.swift:15-36` | 未测试 |
| NAV-006 | iOS 26.5，已连接 | 点底部面板附件；在 medium/large detent 间拖动；交互下拉关闭 | 打开“面板控制”sheet；两档可用，背景交互符合系统行为；关闭回到原标签 | `RootTabView.swift:285-305,315-328` | 未测试 |
| NAV-007 | iOS 17.x | 打开设置 | 不显示 iOS 26 底部附件；设置首部提供唯一“面板控制中心”入口 | `RootTabView.swift:306-338`；`SettingsView.swift:30-41` | 未测试 |
| NAV-008 | iOS 26.5，任一前四标签，未连接/已连接各一次 | 点页面中的设备状态行（若该 OS 显示）；旧系统重点执行 | 未连接进入连接 sheet；已连接进入面板控制 sheet；均可关闭并保留草稿 | `FeatureWorkspace.swift:24-66` | 未测试 |
| NAV-009 | 口型运行中 | 切到其他标签；返回口型 | 麦克风立即释放；口型状态停止并闭嘴；不会在后台继续采集 | `RootTabView.swift:92-101`；`LipSyncModel.swift:265-296` | 未测试 |
| NAV-010 | 文字/演出/控制各有未提交草稿或当前选择 | 在五标签间来回切换 20 次 | App 级模型保持内容；无意外重置、重复 sheet 或导航错位 | `RinaBoardApp.swift:5-42` | 未测试 |
| NAV-011 | 任一活动状态 | App 进入后台再回前台 | 口型停止；演出暂停；控制与文字草稿持久化；文字预览循环按需恢复 | `RootTabView.swift:140-145`；`ScrollTextView.swift:49-55`；`PresetLiveView.swift:37-39` | 未测试 |
| NAV-012 | 已连接且正在自动重连/重同步 | 快速断开、重连、切换面板 | 旧重同步结果不覆盖新连接；表情、文字和控制状态属于当前连接代次 | `RootTabView.swift:108-127,211-233`；`FaceLibraryModel.swift:137-179` | 未测试 |
| BOOT-001 | 正常动效 | 冷启动；录屏首帧至主界面 | 启动层先出现；瀑布与退场连续；退场后完全移除；主页面不“呼吸式”重排 | `BootLoaderOverlay.swift`；`BootLoaderModel.swift:58-166`；`BootAnimationTimeline.swift:21-79` | 未测试 |
| BOOT-002 | 减少动态效果开启 | 冷启动与 Debug 中重播 | 瀑布简化；iOS 26 控制中心不用 zoom 转场；任务仍可完成 | `BootLoaderModel.swift:29,38-40,87-106`；`RootTabView.swift:281-328` | 未测试 |
| BOOT-003 | Debug 可达 | 在“测试→App 工具”连续点重播两次 | 旧序列被取消；只保留一套启动层；最终正常结束且不发送面板数据 | `DebugView.swift:285-290`；`BootLoaderModel.swift:143-157` | 未测试 |

## 4. 控制与 LED 编辑

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| CTL-001 | 未连接，实时同步关闭 | 在预览点按和连续划过有效 LED；划过空白区域 | 画笔值写入触达 LED；单笔重复经过不反复切换；空白区域不改帧；页面不随手指滚动 | `ControlView.swift:23-34,110-120`；`LEDBoardPreview.swift:60-83,189-240` | 未测试 |
| CTL-002 | 草稿有亮灯 | 切换“画亮/画灭”；分别在同一 LED 点按和回划 | 画亮只置 1，画灭只置 0；同值重复操作无变化、无多余触感 | `ControlView.swift:46-52`；`ControlViewModel.swift:212-234` | 未测试 |
| CTL-003 | 两眼内容不同 | 打开“双眼同步”；再编辑左右眼对应 LED | 开启瞬间以左眼同步右眼；此后任一眼的有效映射成对写入；非眼部只改自身 | `ControlView.swift:51-52`；`ControlViewModel.swift:181-210,221-233` | 未测试 |
| CTL-004 | 部件库有效，双眼同步开启 | 分别选择左右眼部件 | 另一眼自动选择镜像部件；预览与选择态一致 | `ControlView.swift:125-136`；`ControlViewModel.swift:251-283` | 未测试 |
| CTL-005 | 部件库有效 | 逐项选择左眼、右眼、嘴、脸颊；选择 0 号空部件 | 每一项预览来自实际部件；被选项具可见边框/选中语义；空部件可达 | `FacePartSelectorView.swift:4-87`；`ControlView.swift:125-133` | 未测试 |
| CTL-006 | 任意草稿 | 依次执行“随机组合/反转/清空” | 随机组合产生有效部件组合；反转所有 370 bit；清空后 0 灯；状态说明变为本地未发送 | `ControlView.swift:84-90`；`ControlViewModel.swift:236-269` | 未测试 |
| CTL-007 | 从已保存表情或新草稿开始 | 做多步编辑；点“回退到编辑起点” | 按钮在有差异时启用；恢复最近加载/成功保存时的帧、部件来源和选项 | `ControlView.swift:89`；`ControlViewModel.swift:29-35,167-179,376-385` | 未测试 |
| CTL-008 | 任意草稿 | 展开“逐灯编辑”；Stepper 到首/末 LED；观察行列；切换当前灯 | 范围为 1…370，无越界；行列与板型一致；按钮文案和灯状态同步 | `ControlView.swift:91-108`；`MatrixGeometry.swift` | 未测试 |
| CTL-009 | 控制页 | 双指在预览中心/边缘缩放到 3×，回缩低于 1×；缩放中单指移动 | 锚点保持；不露空边；最大 3×；低于 1×松手回弹；双指期间不误画灯；工具区仍可滚动 | `BoardPreviewZoom.swift:55-230`；`ControlView.swift:28-30,111` | 未测试 |
| CTL-010 | 未连接 | 查看“发送表情”与保存位置 | 发送禁用；仍可编辑和保存到本机；保存到当前面板禁用并有说明 | `ControlView.swift:54-81,139-160` | 未测试 |
| CTL-011 | 已连接，实时同步关闭 | 编辑后观察面板；点“发送表情” | 编辑前面板不变；点发送后显示草稿；按钮显示进行态；页脚变“最近发送成功” | `ControlView.swift:54-65`；`ControlViewModel.swift:290-311` | 未测试 |
| CTL-012 | 已连接 | 开实时同步；快速绘制/选部件 30 次；立即切到文字发送 | 面板跟随最新控制草稿；队列不洪泛；文字会话接管后迟到控制响应不得覆盖文字 | `ControlView.swift:70-81`；`ControlViewModel.swift:313-333`；`BoardPlaybackCoordinator.swift` | 未测试 |
| CTL-013 | 已连接并发送成功 | 断开或切换到另一面板 | “最近发送成功”不沿用到新连接；草稿仍保留 | `ControlViewModel.swift:120-124`；`RootTabView.swift:108-126` | 未测试 |
| CTL-014 | 已编辑草稿 | 后台/强制终止并重启 | 帧、名称、部件来源及选择恢复；错误时显示“无法恢复草稿/尚未保存”且不崩溃 | `ControlViewModel.swift:67-118`；`DraftStorage.swift` | 未测试 |
| CTL-015 | 保存 sheet | 空名、全空格、有效名各一次；切换本机/当前面板；编辑现有项时切换“另存为新表情” | 空名禁用；有效名保存；替换与另存逻辑符合目标库和连接代次；成功提示可进入表情库 | `ControlView.swift:139-185` | 未测试 |
| CTL-016 | 模拟部件资源不可用 | 打开控制 | 显示“部件库不可用”和原因；直接 LED 编辑、草稿保护行为不崩溃 | `ControlView.swift:125-136`；`ControlViewModel.swift:138-165` | 未测试 |

## 5. 表情库

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| FACE-001 | 控制页 | 点右上“表情库”；关闭 sheet | sheet 内标题为表情库；关闭回控制且草稿不丢 | `ControlView.swift:112-119` | 未测试 |
| FACE-002 | DATA-FACE | 切换“本机/当前面板” | 两库独立；默认与我的表情分组；切库清空选择模式；未连接面板时显示明确空状态 | `FaceLibraryView.swift:36-115` | 未测试 |
| FACE-003 | DATA-FACE | 搜索大小写、局部名称、无结果；清空搜索 | 只按名称本地标准匹配；无结果提示不混同空库；清空恢复完整列表 | `FaceLibraryView.swift:36-44,77-105` | 未测试 |
| FACE-004 | 本机库首次启动/已有持久数据各一次 | 打开本机库 | 首次合并内置默认表情；已有用户表情保留；加载失败回退默认并显示错误 | `FaceLibraryModel.swift:101-135,627-645` | 未测试 |
| FACE-005 | 当前面板已连接 | 切到面板库、下拉刷新；制造读取失败再重试 | 显示加载态；成功显示当前代次库；失败显示重试入口/错误且不冒充空库 | `FaceLibraryView.swift:61-76,107-120`；`FaceLibraryModel.swift:146-180` | 未测试 |
| FACE-006 | 任一有效表情 | 打开详情 | 显示预览、名称、类型、位置和可用动作；预览高度受限；无隐式应用 | `FaceLibraryView.swift:397-470` | 未测试 |
| FACE-007 | 已连接；本机和面板表情各一 | 点详情“应用到面板” | 本机项发送其帧；面板项按当前排序索引应用；输出源切手动；成功不自动进入编辑 | `FaceLibraryView.swift:486-505`；`FaceLibraryModel.swift:204-248` | 未测试 |
| FACE-008 | 未连接 | 打开详情/长按菜单 | 应用与本机→面板复制禁用；本机编辑、重命名、导出等离线操作仍可用 | `FaceLibraryView.swift:221-253,486-526` | 未测试 |
| FACE-009 | 默认/锁定表情 | 查看滑动、长按、详情操作；点“编辑副本” | 不出现重命名/删除；编辑以副本方式进入控制，原 ID 不作为覆盖目标 | `FaceLibraryModel.swift:93-99,184-197`；`FaceLibraryView.swift:204-252,492-504` | 未测试 |
| FACE-010 | 可编辑本机表情 | 点编辑；修改；保存覆盖；再另存为新表情 | sheet 关闭并回控制；标题显示编辑对象；覆盖保留 ID，另存创建新 ID | `FaceLibraryView.swift:492-498`；`RootTabView.swift:134-139`；`ControlView.swift:164-185` | 未测试 |
| FACE-011 | 可编辑面板表情，连接 A | 进入编辑；切换至连接 B；保存且未选另存 | 不用 A 的 ID 覆盖 B；在 B 新建或要求重新选择；有清晰结果 | `ControlView.swift:168-179`；`FaceLibraryModel.swift:250-289,693-703` | 未测试 |
| FACE-012 | 可编辑项 | 从列表滑动与详情分别重命名；输入前后空格、空名、>64 字符 | 去空格、最长 64 字符；本机持久化后更新；面板错误可见；受保护项拒绝 | `FaceLibraryView.swift:133-142,437-443`；`FaceLibraryModel.swift:349-389,741-744` | 未测试 |
| FACE-013 | 任一有效项 | “创建副本”连续执行三次 | 同库新增副本；命名为“副本”“副本 2”…且帧/部件信息保持 | `FaceLibraryView.swift:508-526`；`FaceLibraryModel.swift:391-415,729-739` | 未测试 |
| FACE-014 | 已连接 | 本机→面板、面板→本机各复制一项 | 目标库新增可编辑副本；来源不变；跨库名称冲突生成稳定后缀 | `FaceLibraryModel.swift:397-415` | 未测试 |
| FACE-015 | 可删除本机项 | 删除并取消；再次删除确认；点撤销 | 取消无变化；确认后从列表消失并出现撤销条；撤销恢复全部数据 | `FaceLibraryView.swift:143-153,283-294`；`FaceLibraryModel.swift:432-524` | 未测试 |
| FACE-016 | 可删除面板项 | 删除并确认 | 文案明确永久删除；成功后无撤销条；失败保留项及错误 | `FaceLibraryView.swift:143-153,444-460`；`FaceLibraryModel.swift:438-479` | 未测试 |
| FACE-017 | 多选含默认和可删除项 | 进入选择；选多项；执行复制、导出、删除 | 底栏图标有可理解辅助标签；默认项不删除；成功项从选择集移除；部分失败显示成功/失败数量并保留失败项 | `FaceLibraryView.swift:125-132,255-281,327-336`；`FaceLibraryModel.swift:417-429,466-479,749-766` | 未测试 |
| FACE-018 | 至少 2 个用户表情 | 打开排序；拖动和 VoiceOver 上移/下移；取消 | 默认项不参与；取消放弃草稿顺序；原列表不变 | `FaceLibraryView.swift:553-615` | 未测试 |
| FACE-019 | 至少 2 个用户表情 | 排序后点完成；保存期间尝试下拉关闭 | 成功后提交完整顺序并关闭；保存期间不能交互关闭；列表变化导致草稿过期时显示错误不误提交 | `FaceLibraryView.swift:588-607`；`FaceLibraryModel.swift:526-565` | 未测试 |
| FACE-020 | DATA-FACE | 导出单个、所选、全部；检查 JSON | 文件名安全；只含指定表情；帧可解码；不修改库 | `FaceLibraryView.swift:157-163,346-365,521-525`；`FaceLibraryModel.swift:567-578` | 未测试 |
| FACE-021 | 有效/无效 JSON | 分别导入本机；记录导入前后 | 有效项作为新本机副本加入；无效/空/坏帧拒绝并保留旧库 | `FaceLibraryModel.swift:584-604` | 未测试 |
| FACE-022 | 已连接与未连接各一次 | 向面板导入有效文档；制造失败 | 未连接明确拒绝；成功后重新读取；失败时错误可见且旧库可恢复 | `FaceLibraryModel.swift:593-617` | 未测试 |
| FACE-023 | 面板库详情打开 | 断开或换板 | 详情变“表情已不可用”，说明可能删除/更换面板；不会操作旧 ID | `FaceLibraryView.swift:465-468`；`FaceLibraryModel.swift:137-144` | 未测试 |

## 6. 文字滚动

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| TEXT-001 | 全新启动 | 打开文字；聚焦编辑器并输入/换行；点键盘“完成” | 默认文字可见；占位符仅空时显示；聚焦时预览隐藏以让出空间；键盘可收起 | `ScrollTextView.swift:18-45,126-200` | 未测试 |
| TEXT-002 | DATA-TEXT | 输入中英日、emoji、换行；观察字符/字节 | 可见字符计数与 UTF-8 字节分别正确；不会悄悄截断到 4096 字节 | `ScrollTextView.swift:182-199`；`TextViewModel.swift:114-116,175-178` | 未测试 |
| TEXT-003 | 空/全空格/超过字节上限 | 查看并尝试发送 | 主按钮禁用或返回明确错误；超限边框、字节数、说明为红色；旧播放不被新无效草稿破坏 | `ScrollTextView.swift:87-123,128-199`；`TextViewModel.swift:196-231` | 未测试 |
| TEXT-004 | 已连接且无绑定时间轴 | 输入短文；点“发送并播放” | 生成/上传/启动进度可见；成功后按钮变“更新并播放”；预览开始并显示上传摘要 | `ScrollTextView.swift:87-123`；`TextViewModel.swift:215-313` | 未测试 |
| TEXT-005 | 已有绑定时间轴 | 修改草稿并点“更新并播放” | 新内容替换播放；上传中禁用重复提交；旧帧/迟到响应不覆盖新时间轴 | `TextViewModel.swift:196-313`；`BoardPlaybackCoordinator.swift` | 未测试 |
| TEXT-006 | 正在播放 | 点暂停、继续、停止并清屏；快速交替暂停/继续 | 暂停/继续文案跟随固件状态；250 ms 锁防重复；停止后清屏并解除绑定，主按钮回发送 | `ScrollTextView.swift:100-111`；`TextViewModel.swift:331-355` | 未测试 |
| TEXT-007 | 时间轴已绑定 | 展开高级详情；上一帧/下一帧 | 连接和绑定时启用；单步后帧号/预览同步；首尾行为符合固件且不越界 | `ScrollTextView.swift:26-36`；`TextViewModel.swift:357-361` | 未测试 |
| TEXT-008 | 播放中 | 拖动速度到最小、最大及中间；快速往返 | 请求值按协议范围/整数显示；面板实时调速合并到最新值；实际 fps 与请求值分开显示 | `ScrollTextView.swift:202-224`；`TextViewModel.swift:315-317,363-371` | 未测试 |
| TEXT-009 | 播放中 | 观察 60 秒；暂停/单步/恢复 | 手机预览使用面板测量速度和相位；锁定状态可为自由/微调/追赶/锁定；漂移不会持续扩大 | `TextViewModel.swift:427-501` | 未测试 |
| TEXT-010 | 本地有未发送草稿，面板有不同可恢复文字 | 连接/重连；分别点“保留草稿”“使用面板文字” | 出现冲突提示；前者保留本地，后者采用面板；无静默覆盖 | `ScrollTextView.swift:133-146`；`TextViewModel.swift:180-192,373-425` | 未测试 |
| TEXT-011 | 本地无编辑草稿，面板有兼容元数据 | 连接 | 自动重建时间轴、恢复面板文字/速度/帧；元数据不兼容时不伪造恢复 | `TextViewModel.swift:375-425` | 未测试 |
| TEXT-012 | 草稿和速度已改 | 后台/终止/重启 | 原子恢复文字和速度；错误显示但页面可继续编辑 | `TextViewModel.swift:30-73`；`RootTabView.swift:140-145,156-162` | 未测试 |
| TEXT-013 | 播放中 | 切到控制发送、口型开始、演出播放或 Debug 发送 | 新输出会话接管；文字预览/绑定状态不会被迟到旧响应错误恢复；控制中心显示当前输出 | `RootTabView.swift:199-208`；`BoardPlaybackCoordinator.swift` | 未测试 |
| TEXT-014 | 播放中 | 断开、重连、后台前台 | 断开暂停本地预览循环；后台不空转；重连仅在身份/元数据一致时恢复 | `RootTabView.swift:108-126`；`ScrollTextView.swift:46-55`；`TextViewModel.swift:446-468` | 未测试 |

## 7. 口型同步

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| LIP-001 | 未连接 | 打开口型 | 开始按钮禁用；说明需先连接；高级设置仍可查看 | `LipSyncView.swift:87-133` | 未测试 |
| LIP-002 | 真机已连接，麦克风权限未决定 | 点开始；允许权限 | 只出现一次系统请求；只创建一条采集循环；按钮变停止；音量/元音读数出现 | `LipSyncModel.swift:217-263`；`Info.plist:27-28` | 未测试 |
| LIP-003 | 权限请求弹出 | 连点开始；权限完成前切页或断线 | 不启动双循环；离页/断线使旧请求失效；权限回来后不偷偷开麦 | `LipSyncModel.swift:224-240,270-275`；`RootTabView.swift:92-126` | 未测试 |
| LIP-004 | 麦克风权限拒绝 | 点开始 | 显示拒绝说明和“打开应用设置”；无录音指示、无面板输出 | `LipSyncView.swift:118-129`；`LipSyncModel.swift:217-221` | 未测试 |
| LIP-005 | 正在运行 | 发静音和 a/i/u/e/o；观察手机和面板 | 音量条、阈值、原始猜测与平滑结果更新；预览/面板嘴型一致；相同结果不重复发帧 | `LipSyncView.swift:50-85,135-192`；`LipSyncModel.swift:298-352` | 未测试 |
| LIP-006 | 正在运行 | 点停止 | 始终可停止；麦克风释放、指标归零、嘴闭合；在线时向面板推闭嘴帧 | `LipSyncView.swift:92-112`；`LipSyncModel.swift:265-296` | 未测试 |
| LIP-007 | 正在运行 | 断开面板 | 麦克风最终释放（根连接监听）；不会因按钮禁用而无法停止；错误/状态不冒充仍同步 | `RootTabView.swift:119-125`；`LipSyncView.swift:124-130` | 未测试 |
| LIP-008 | 正在运行 | 锁屏/后台；接电话或音频会话改变 | 立即停止并释放麦克风；返回前台不自动重启 | `LipSyncView.swift:43-47`；`RootTabView.swift:140-145` | 未测试 |
| LIP-009 | 停止状态 | 调灵敏度 -70/-10、刷新 10/60 Hz、防抖 1/12 | 数值准确、边界不可越；重启后保留；运行/校准时全部锁定 | `LipSyncView.swift:194-247`；`LipSyncModel.swift:57-102` | 未测试 |
| LIP-010 | 已校准至少一个元音 | 切换标准/男声/女声/动画模型 | 参考模型切换并清除旧校准；页内说明明确这一行为；无运行中切换 | `LipSyncView.swift:215-255`；`LipSyncModel.swift:91-101` | 未测试 |
| LIP-011 | 停止，权限允许 | 对单个元音点校准，持续发声约 1.5 s | 进度连续；成功出现已校准标记并持久化；采集结束自动关麦 | `LipSyncView.swift:258-296`；`LipSyncModel.swift:363-428` | 未测试 |
| LIP-012 | 正在校准 | 点取消；再测试声音过小 | 取消立即停采集并清进度；采样不足显示可行动错误，不写入坏配置 | `LipSyncView.swift:271-284`；`LipSyncModel.swift:371-436` | 未测试 |
| LIP-013 | 麦克风权限未决定/拒绝 | 不先开始同步，直接校准 | 权限路径有明确系统请求或明确错误；不出现无反馈卡住；不残留录音 | `LipSyncModel.swift:371-415`；`LipSyncAudioCapture.swift` | 未测试 |
| LIP-014 | 已有多项校准 | 点“恢复默认声音模型” | 运行/校准时禁用；确认执行后校准标记清空并恢复当前 preset 合成模型 | `LipSyncView.swift:288-296`；`LipSyncModel.swift:438-443` | 未测试 |
| LIP-015 | 部件库可用 | 进入“口型与造型”；分别修改静音、五元音、左右眼、脸颊 | 每个选择立即更新预览和选择态；非嘴部在同步期间固定；返回后设置保留 | `LipSyncView.swift:299-320,339-425`；`LipSyncModel.swift:183-213` | 未测试 |
| LIP-016 | 自定义口型 | 点恢复默认；终止重启 | 默认映射恢复；持久化值经过部件库清洗，不引用不存在 ID | `LipSyncView.swift:384-388`；`LipSyncModel.swift:175-195` | 未测试 |

## 8. 预设/自定义演出

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| LIVE-001 | 全新启动 | 打开演出 | 恢复上次模式；否则选择首个可载入内置演出；若没有可用选择则显示演示脚本/缺音频状态 | `PresetLiveView.swift:17-39`；`PresetLiveModel.swift:141-185` | 未测试 |
| LIVE-002 | 内置目录可用 | 打开歌曲列表和各详情 | 显示标题、艺人、时长、关键帧、来源、音频状态；当前选项有非颜色选中标记 | `PresetLiveView.swift:214-305` | 未测试 |
| LIVE-003 | 未选中的内置歌曲 | 点“使用此演出” | 成功后回主演出页；脚本、首帧、时长和选择一致；选择持久化 | `PresetLiveView.swift:242-245,273-289`；`PresetLiveModel.swift:187-223` | 未测试 |
| LIVE-004 | 选中歌曲缺音频 | 从主页面和详情分别导入有效音频 | 显示明确缺音频状态；导入验证并复制后才启用播放；该音频只关联此歌曲 | `PresetLiveView.swift:97-106,281-304`；`PresetLiveModel.swift:254-285` | 未测试 |
| LIVE-005 | 已有歌曲音频 | 导入损坏音频或导入期间切换歌曲 | 导入失败/选择改变有错误；原音频、脚本、预览保持；临时副本不成为活动素材 | `PresetLiveModel.swift:254-283,666-675` | 未测试 |
| LIVE-006 | 打开自定义演出 | 分别导入有效脚本和有效音频 | 两者独立显示；只有都有效时 `canPlay`；进入自定义模式并持久化 | `PresetLiveView.swift:308-363`；`PresetLiveModel.swift:287-326` | 未测试 |
| LIVE-007 | 已有有效自定义素材 | 分别导入无效脚本、损坏音频、取消选择 | 显示错误；旧脚本/音频/预览/可播放状态不变 | `PresetLiveView.swift:346-361`；`PresetLiveModel.swift:287-335` | 未测试 |
| LIVE-008 | 当前在内置模式且保存过自定义素材 | 点“使用已保存的自定义演出” | 恢复保存的脚本和音频；不混入当前内置歌曲音频 | `PresetLiveView.swift:329-338`；`PresetLiveModel.swift:225-240,579-607` | 未测试 |
| LIVE-009 | 脚本和音频有效，面板在线 | 点播放；观察至多个关键帧 | 本机音频开始；首帧立即显示并发板；后续按播放器实际位置推进；面板和预览一致 | `PresetLiveView.swift:125-181`；`PresetLiveModel.swift:338-387,498-565` | 未测试 |
| LIVE-010 | 正在播放 | 点暂停，再点播放 | 暂停位置保留；恢复从同位置继续并重新同步当前帧；不从头跳转 | `PresetLiveModel.swift:360-396` | 未测试 |
| LIVE-011 | 已播放一段 | 点停止 | 音频回 0；预览回首帧；停止按钮禁用；音频会话释放 | `PresetLiveView.swift:137-175`；`PresetLiveModel.swift:398-411` | 未测试 |
| LIVE-012 | 可播放 | 播放中和暂停时分别拖进度至首/中/尾 | 时间标签与位置一致；预览立即切到对应关键帧；在线且有输出租约时同步面板 | `PresetLiveView.swift:148-175`；`PresetLiveModel.swift:413-423` | 未测试 |
| LIVE-013 | 循环开启/关闭各一次 | 播放到末尾 | 开启时无明显停顿回 0 并同步首帧；关闭时结束并释放会话 | `PresetLiveView.swift:177`；`PresetLiveModel.swift:512-575` | 未测试 |
| LIVE-014 | 未连接但素材有效 | 点播放 | 本机音频与预览正常播放；显示“仅本机播放，尚未同步到面板”；无伪失败 | `PresetLiveModel.swift:360-385`；`PresetLiveView.swift:183-195` | 未测试 |
| LIVE-015 | 在线播放中 | 断开面板 | 本机音频继续；面板输出租约清空；恢复连接后不自动抢占输出 | `RootTabView.swift:119-126`；`PresetLiveModel.swift:340-358` | 未测试 |
| LIVE-016 | LIVE-015 状态，重新在线 | 点“恢复同步到面板” | 显式取得新会话并从当前音频位置发送正确帧；提示消失 | `PresetLiveView.swift:183-194`；`PresetLiveModel.swift:346-358` | 未测试 |
| LIVE-017 | 播放中 | App 后台；模拟系统音频中断可恢复/不可恢复 | 后台暂停；中断按系统建议恢复或结束；用户主动暂停后不自动恢复 | `PresetLiveView.swift:37-39`；`PresetLiveModel.swift:426-496` | 未测试 |
| LIVE-018 | 播放中 | 切到口型并开始，或 Debug/控制发送 | 新输出源接管；演出暂停或只保留明确的本机状态；迟到演出帧不覆盖新输出 | `RootTabView.swift:199-208`；`PresetLiveModel.swift:547-563`；`BoardPlaybackCoordinator.swift` | 未测试 |

## 9. 控制中心与当前活动附件

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| CC-001 | 未连接/连接中/重连/失败/已连接 | 查看附件和展开页 | 状态用图标+文字表达；设备名、电量、当前输出、当前表情只在数据存在时显示；无纯颜色含义 | `BoardControlCenterAccessory.swift:15-74`；`BoardControlCenterView.swift:74-146` | 未测试 |
| CC-002 | 已连接 | 快速拖亮度到最小/最大/中间 | 百分比正确；控件发送合并到最新值；2 秒内旧状态回声不拉回滑块，失败后可回到面板真值 | `BoardControlCenterView.swift:148-176`；`BoardControlCenterModel.swift:105-164,242-263` | 未测试 |
| CC-003 | 已连接，表情数 >0 | 上一个/下一个跨首尾；滚动文字运行中点切换 | 索引循环；滚动先停止再切表情；控制中心和面板一致 | `BoardControlCenterView.swift:178-228`；`BoardControlCenterModel.swift:178-196` | 未测试 |
| CC-004 | 已连接 | 快速切自动/手动；观察文字、图标和面板 | 状态不靠颜色；新输出会话正确；失败可见并回到固件状态 | `BoardControlCenterView.swift:195-228`；`BoardControlCenterModel.swift:168-176` | 未测试 |
| CC-005 | 已连接 | 调自动切换间隔到边界并快速往返 | 0.1 s 步进、协议范围夹紧；仅最新值生效；设置页摘要同步 | `BoardControlCenterView.swift:230-249`；`BoardControlCenterModel.swift:198-208` | 未测试 |
| CC-006 | 已连接 | 通过 ColorPicker、hex、配色组/色块分别改色 | 颜色预览/面板/hex 同步；`#RRGGBB` 规范化；色块有 44 pt 点击区和选中勾 | `BoardControlCenterView.swift:252-360`；`BoardControlCenterModel.swift:210-240` | 未测试 |
| CC-007 | 已连接 | 输入无效、空、半成品 hex 并提交；再改有效 | 编辑时不发送；无效显示格式提示；有效才提交且错误消失 | `BoardControlCenterView.swift:266-287`；`BoardControlCenterModel.swift:212-225` | 未测试 |
| CC-008 | iOS 26，文字/口型/演出分别活动 | 查看附件；点“查看”；点暂停/停止 | 摘要指出活动和本机/面板同步状态；查看跳到正确标签；口型为停止，其余为暂停 | `BoardControlCenterAccessory.swift:37-54,62-74` | 未测试 |
| CC-009 | 辅助功能字号 | 查看紧凑附件并用 VoiceOver | 视觉副标题可收起且高度稳定；VoiceOver 仍读完整标题和值；查看/暂停可达 | `BoardControlCenterAccessory.swift:20-59` | 未测试 |
| CC-010 | 仅在产品范围确认要求控制中心提供保存入口时适用；已连接且面板有保存表情 | 展开控制中心，寻找“已保存的表情/管理表情/保存当前状态” | 若该候选能力纳入本轮范围，已保存项可应用并可进入管理，当前控制草稿有保存入口；若未纳入则记“不适用”并引用范围结论，不据死代码判失败 | `BoardControlCenterView.swift:32-72,362-440` | 未测试 |
| CC-011 | 仅在控制中心保存候选能力纳入范围时适用；从保存表情上下文菜单触发“编辑” | 执行后关闭控制中心或切控制 | 控制编辑器加载该表情且有清晰导航/反馈；候选能力未纳入则记“不适用” | `BoardControlCenterView.swift:389-425`；`ControlViewModel.swift:346-369` | 未测试 |
| CC-012 | 已连接/未连接 | 点“连接设置” | 两状态均可进入同一连接页；返回控制中心不重建全局草稿 | `BoardControlCenterView.swift:32-39` | 未测试 |

## 10. 连接、配网与设备身份（物理设备）

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| CONN-001 | 未请求定位 | 打开连接页，不点读取 | iPhone Wi-Fi 显示“尚未读取”；不弹定位权限；面板 SSID、App transport 分开显示 | `ConnectionView.swift:56-109`；`PhoneNetworkInfo.swift:33-36` | 未测试 |
| CONN-002 | 定位允许且精确位置允许 | 点读取当前 Wi-Fi | 权限只由点按触发；成功显示真实 SSID；按钮可重新读取 | `ConnectionView.swift:58-83,333-384`；`PhoneNetworkInfo.swift:36-74` | 未测试 |
| CONN-003 | 定位拒绝/受限 | 点读取 | 显示“定位权限被拒绝”，出现手填项和未经验证说明；不显示“断网” | 同上 | 未测试 |
| CONN-004 | 精确位置关闭 | 点读取 | 显示需精确位置并提供手填；状态不冒充不可联网 | `PhoneNetworkInfo.swift:58-64`；`ConnectionView.swift:350-383` | 未测试 |
| CONN-005 | 系统返回 nil SSID | 点读取 | 显示“系统未提供名称”及歧义说明；提供手填；不推断断网 | `PhoneNetworkInfo.swift:67-74`；`ConnectionView.swift:333-383` | 未测试 |
| CONN-006 | 各连接状态/方式 | 观察概览 | 手机 SSID、板子 SSID/活动 profile/IP、实际 BLE/Wi-Fi TCP/直连 transport 各自准确；状态有文字 | `ConnectionView.swift:333-425` | 未测试 |
| CONN-007 | 已连接 | 点断开 | 控制通道断开；概览更新；草稿保留；活动口型停、文字板输出悬置、演出按规则转本机 | `ConnectionView.swift:99-103`；`RootTabView.swift:108-126` | 未测试 |
| CONN-008 | 蓝牙开/关/未授权各一次 | 点扫描、停止；等待超时；再次扫描 | 只显示 RinaLink 外设；进度/停止/超时/错误清晰；可重试；不会显示 Wi-Fi 扫描为蓝牙结果 | `ConnectionView.swift:178-225`；`ConnectionViewModel.swift:82-95` | 未测试 |
| CONN-009 | 至少两个 BLE 结果 | 用名称/UUID 筛选；点一个连接；连接中连点 | 过滤准确；RSSI 同时用条形和 dBm；只建立一次；成功显示已连接并保存设备 | `ConnectionView.swift:18-25,206-220,279-331`；`ConnectionViewModel.swift:97-115` | 未测试 |
| CONN-010 | Bonjour 有已解析/未解析项 | 点两类结果 | 未解析项禁用/等待；已解析使用 endpoint/host 连接并保存；不把服务显示名当主机地址 | `ConnectionView.swift:147-175,476-491`；`ConnectionViewModel.swift:193-230` | 未测试 |
| CONN-011 | 可达/不可达主机 | 输入手动 IP/主机名、空格和空值并连接 | 空值禁用；trim 后连接；成功保存；失败弹可行动错误且不伪造已连接 | `ConnectionView.swift:493-504`；`ConnectionViewModel.swift:232-247` | 未测试 |
| CONN-012 | 已有 BLE/Wi-Fi/直连/个人热点保存项 | 点各项重连；制造缺地址；左滑移除 | 按偏好 transport 重连；失败显示具体原因；缺地址要求重扫；移除不删除板端凭据 | `ConnectionView.swift:228-262`；`ConnectionViewModel.swift:292-326` | 未测试 |
| CONN-013 | 启动前已有最后设备 | 冷启动，分别测试 BLE/Wi-Fi/hotspot 保存项 | 每次启动最多自动重连一次；使用正确偏好；失败不循环创建连接 | `RootTabView.swift:235-259` | 未测试 |
| CONN-014 | 先以 BLE 连接面板 | 让面板扫描家庭 Wi-Fi | 按钮仅连接时启用；列表明确来自面板；加密项有锁和 RSSI；App 不声称扫描 iPhone 周围网络 | `ConnectionView.swift:509-543,1025-1046`；`ConnectionViewModel.swift:438-447` | 未测试 |
| CONN-015 | 面板扫描返回开放/加密网络 | 选网络；取消一次；再输入正确/错误密码发送 | sheet 文案正确；开放网络无需密码；凭据只发给板；阶段依次发送/等待/加入或失败 | `ConnectionView.swift:521-557,1206-1243`；`ConnectionViewModel.swift:449-475` | 未测试 |
| CONN-016 | BLE 控制仍在，板子已加入家庭 Wi-Fi 并报告 IP | 点“改用 Wi-Fi 控制板子” | 建立 TCP 后才更新为已连接/保存；失败保持明确阶段，不混同“板子已入网” | `ConnectionView.swift:530-538`；`ConnectionViewModel.swift:274-290` | 未测试 |
| CONN-017 | 个人热点页，无已确认记录 | 打开页面 | 名称不自动使用泛化 `iPhone`；密码为空；说明系统不提供热点名/密码 | `ConnectionView.swift:572-609`；`ConnectionViewModel.swift:53-75` | 未测试 |
| CONN-018 | BLE 在线 | 让面板扫描热点，点选属于用户的 SSID | 扫描按钮只有 BLE 在线时启用；选择只填热点名，不宣称识别所有者；匹配钥匙串密码时明确提示 | `ConnectionView.swift:611-640`；`ConnectionViewModel.swift:408-415` | 未测试 |
| CONN-019 | 热点开启，名称/密码正确 | 点“发送并连接” | 三阶段分开显示；板子报告 hotspot profile 后才转 TCP；成功保存密码到对应 SSID 钥匙串并保存 `hotspot-tcp` | `ConnectionView.swift:642-679`；`ConnectionViewModel.swift:328-406` | 未测试 |
| CONN-020 | 热点名/密码错误或 45 s 无关联 | 点发送并连接 | 失败说明检查热点、凭据、最大兼容性；不显示已连接；可修改后重试 | `ConnectionViewModel.swift:361-405` | 未测试 |
| CONN-021 | 已保存热点密码 | 改热点名来回切换；清除板子和本机密码 | 密码按 SSID 分开载入；清除后板端凭据与对应钥匙串值均移除，UI 回空 | `ConnectionViewModel.swift:408-428`；`KeychainStore.swift` | 未测试 |
| CONN-022 | 板载默认 AP 可用 | 点加入热点并连接；在 iOS 系统确认允许/取消；制造 TCP 失败 | 阶段区分 iPhone 加网与 App 控制连接；成功保存直连地址；失败可重试；说明互联网可能暂停 | `ConnectionView.swift:695-746`；`ConnectionViewModel.swift:249-272` | 未测试 |
| CONN-023 | 已连接 | 进入“网络与名称”；改名为 ASCII、中文边界、超 UTF-8 字节、空名 | 合法名更新面板、BLE 显示和保存项；超限提示实际字节；空名恢复默认；持久化失败明确说明重启会丢 | `ConnectionView.swift:750-816`；`ConnectionViewModel.swift:117-189` | 未测试 |
| CONN-024 | 已连接 | 切换 off/ap/sta/sta_or_ap；观察板端状态 | 选择发送且回显；Wi-Fi、IP、RSSI、AP 状态/名称/IP 各自准确；未知值不伪造 | `ConnectionView.swift:818-849,877-896`；`ConnectionViewModel.swift:431-435` | 未测试 |
| CONN-025 | 已连接且有家庭凭据 | 点忘记家庭 Wi-Fi | 只清家庭凭据；热点配置与本机保存项按协议保持；失败可见 | `ConnectionView.swift:843-846`；`ConnectionViewModel.swift:477-480` | 未测试 |
| CONN-026 | 已连接 | 保存自定义板载 AP：有效 SSID+开放/带密码；空 SSID | 空 SSID禁用；有效项发送；回显更新；密码字段不明文回显 | `ConnectionView.swift:851-874`；`ConnectionViewModel.swift:482-485` | 未测试 |
| CONN-027 | 连接 A 正在请求，随后立即连接 B | 让 A 延迟成功、B 先成功 | 最终 transport、状态、设备名、面板库均属于 B；A 的迟到完成被隔离 | `BoardConnection.swift`；已有设计入口 `RootTabView.swift:108-127` | 未测试 |

## 11. 设置与关于

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| SET-001 | 已连接/未连接 | 打开设置 | 状态文字准确；连接设置、面板、应用、调试、关于层级清晰；设置页没有 LED 预览 | `SettingsView.swift:28-80` | 未测试 |
| SET-002 | 未连接/已连接 | 点重启面板；取消/确认 | 未连接禁用；确认文案说明会断线；取消无动作；确认只发送一次 | `SettingsView.swift:84-111` | 未测试 |
| SET-003 | 任一含预览页面 | 切“显示面板照片” | 所有共用大预览同步切换照片；无照片时显示未亮网格；布局不裁切 | `SettingsView.swift:115-133`；`BoardPreviewRow.swift:18-76` | 未测试 |
| SET-004 | 控制和控制中心 | 切“触感反馈” | 关闭时 LED 实际变化和用户控制动作不触发触感；开启后仅用户动作触发，固件回显不触发 | `AppSettings.swift:11-14`；`ControlView.swift:120`；`BoardControlCenterView.swift:23-28,228` | 未测试 |
| SET-005 | 真机 | 切“控制时保持屏幕常亮”；后台前台 | 开启时前台不自动熄屏；关闭恢复系统行为；设置即时生效并持久 | `RootTabView.swift:63-64,105-107` | 未测试 |
| SET-006 | 系统浅色/深色 | 查看设置 | App 跟随系统；没有重复的 App 外观开关 | `SettingsView.swift:115-133`；`AppSettings.swift:3-8` | 未测试 |
| SET-007 | 可访问网络浏览器 | 打开关于；检查版本；分别点四个项目/致谢链接 | 版本/构建显示；链接目标正确并用系统方式打开；返回 App 状态保留 | `AboutView.swift:7-61` | 未测试 |

## 12. Debug 四工作区

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| DBG-001 | 设置页 | 进入调试；切换概览/日志/测试/原始数据 | 四段都可达且顶部固定；切换不丢本次 Debug 会话状态 | `DebugView.swift:19-51` | 未测试 |
| DBG-002 | 未连接 | 打开概览 | 显示未连接；刷新/PING 禁用；未知字段用“未知/未采样/输入不足”，不显示 0 冒充采样 | `DebugView.swift:55-169`；`DebugViewModel.swift:428-513` | 未测试 |
| DBG-003 | 已连接 | 自动刷新；手动下拉和“刷新全部” | 分别读取 GET_STATUS/GET_POWER/get_info；进度可见；指标和时间更新；错误可清除 | 同上 | 未测试 |
| DBG-004 | 已连接且提供/缺少不同字段 | 展开硬件、网络、电源详情 | optional bool 为是/否/未知；没有字段不推断；设备/固件/内存/网络值对应原始回复 | `DebugView.swift:82-117`；`DebugViewModel.swift:508-513` | 未测试 |
| DBG-005 | 状态含 lit/brightness/color；再移除一项 | 查看客户端估算功耗 | 输入齐时显示 W；>40 W 有图标+颜色警示；任一输入缺失显示“输入不足” | `DebugView.swift:119-129`；`DebugViewModel.swift:485-494` | 未测试 |
| DBG-006 | 已采样 | 等 >30 s；断线 | 时间从“更新于”变“可能陈旧”，断线后标“断线前”；不悄悄清成当前值 | `DebugViewModel.swift:496-506` | 未测试 |
| DBG-007 | 已连接 | PING 成功/失败 | 成功显示 RTT 并记录 uptime 日志；失败入错误日志；不改变板输出 | `DebugView.swift:140-151`；`DebugViewModel.swift:515-523` | 未测试 |
| DBG-008 | 执行若干 Debug 命令/帧并制造拒绝/通信失败 | 展开本次 Debug 会话 | 尝试、设备拒绝、通信失败、帧尝试/失败分类累计；仅统计本页 | `DebugView.swift:154-162`；`DebugViewModel.swift:565-629` | 未测试 |
| DBG-009 | DATA-LOG | 按来源、最低级别、搜索组合筛选 | 结果同时满足过滤条件，最新在前，最多 120；空结果明确 | `DebugView.swift:184-243`；`DebugViewModel.swift:251-291` | 未测试 |
| DBG-010 | 日志持续产生 | 开“暂停列表更新”，产生更多日志，再关闭 | 冻结的是显示快照，后台继续收集；解除后显示新日志 | `DebugView.swift:206-241`；`DebugViewModel.swift:256-262` | 未测试 |
| DBG-011 | 已连接/断线各一次 | 开始、取消订阅、停止、断线、重试固件日志 | off/subscribing/on/failed 状态完整；EV_LOG 标为固件来源；断线结束消费任务且可重试 | `DebugView.swift:245-274`；`DebugViewModel.swift:317-389` | 未测试 |
| DBG-012 | DATA-LOG | 复制/分享脱敏日志；清空 | password/passwd/pwd/psk/secret/token/authorization 值被替换；清空后列表和暂停快照都空 | `DebugView.swift:229-235`；`DebugViewModel.swift:305-315,406-424` | 未测试 |
| DBG-013 | 未连接/已连接 | 在测试图案选择全黑/棋盘/边框/当前保存/全亮 | 选择只改本机预览；未连接发送禁用；非全亮发送直接执行；全亮先显示 370 LED/>40 W 确认 | `DebugView.swift:336-363`；`DebugViewModel.swift:137-190,599-636` | 未测试 |
| DBG-014 | 已连接 | 依次点 B1/B2/B3/B4/B5/B3B1/B3B2/B6 单次/B6 详情/暂停滚动 | 每个命令只发一次、日志与计数匹配、面板行为符合协议；新输出会话接管 | `DebugView.swift:365-388`；`DebugViewModel.swift:567-597` | 未测试 |
| DBG-015 | DATA-FRAME | 在封包帧实验室逐种校验、预览、发送、复制 | 三种有效格式解析为同一 370-bit 帧；无效显示原因；预览不发送；发送需连接；复制为 94 hex | `DebugView.swift:390-421`；`DebugViewModel.swift:645-700` | 未测试 |
| DBG-016 | 任意连接 | 改 ADC 原始值/参考电压；执行电压最小/最大重置并取消/确认 | ADC 仅本地计算；维护命令需连接和确认；取消无命令 | `DebugView.swift:424-442,312-319` | 未测试 |
| DBG-017 | 已采样含未知键 | 搜索来源/字段/值；查看原始 JSON | 未建模键仍展开显示；过滤准确；原始 JSON 可选择；无采样显示“未采样” | `DebugView.swift:445-494`；`DebugViewModel.swift:293-303` | 未测试 |
| DBG-018 | 原始快照含敏感字段 | 点复制脱敏快照 | GET_STATUS/GET_POWER 均包含且敏感值隐藏 | `DebugView.swift:470-474`；`DebugViewModel.swift:559-563` | 未测试 |
| DBG-019 | 已连接 | 进入原始命令；输入数组/无效 JSON/对象；切确认开关并发送 | 只有 JSON 对象+确认+连接同时满足时启用；回复格式化；拒绝/失败分类记录 | `DebugView.swift:525-559`；`DebugViewModel.swift:702-737` | 未测试 |
| DBG-020 | 面板有用户与默认表情 | 危险操作“清空用户表情”；输入错误确认词、取消、输入 `CLEAR` | 错词不执行；取消无变化；正确词只删非默认且不可撤销，日志记录保留数 | `DebugView.swift:292-333`；`DebugViewModel.swift:739-761` | 未测试 |
| DBG-021 | 已连接 | 重启设备，取消/确认 | 取消无动作；确认发送一次并记录；随后连接状态真实变化 | `DebugView.swift:292-333`；`DebugViewModel.swift:763-766` | 未测试 |
| DBG-022 | 任一标签有活动输出 | Debug 发送图案/帧/原始改变输出命令 | Debug 会话接管；旧功能迟到帧不能覆盖；离开 Debug 后不会把过期状态写回 | `DebugViewModel.swift:565-737`；`BoardPlaybackCoordinator.swift` | 未测试 |

## 13. 跨功能一致性与故障注入

| ID | 前置 | 步骤 | 预期 | 代码位置 | 状态 |
| --- | --- | --- | --- | --- | --- |
| XFLOW-001 | 已连接 | 按控制→文字→口型→演出→Debug 的顺序快速启动输出，每次上一请求延迟返回 | 最后一个用户动作拥有输出；过期帧和迟到响应不改当前帧/状态 | `BoardPlaybackCoordinator.swift`；`BoardConnection.swift`；`RootTabView.swift:199-208` | 未测试 |
| XFLOW-002 | 任一发送/上传中 | 断线并立即连接同一面板 | 等待 continuation 被释放；UI 不永久转圈；新代次可发送 | `BoardConnection.swift`；`ControlViewModel.swift:120-124` | 未测试 |
| XFLOW-003 | 连接 A 有面板库/播放状态 | 连接 B，其 ID 与 A 部分相同 | A 的表情 ID、帧、状态、请求结果不应用到 B；重新读取 B | `FaceLibraryModel.swift:137-179,693-703`；`RootTabView.swift:211-233` | 未测试 |
| XFLOW-004 | 控制/文字草稿已修改 | 模拟 Application Support 写失败；继续编辑和切页 | 明确显示持久化失败；内存草稿不被旧文件回滚；面板状态不受影响 | `DraftStorage.swift`；`ControlViewModel.swift:76-118`；`TextViewModel.swift:36-73` | 未测试 |
| XFLOW-005 | 本机表情库已有内容 | 模拟本机库保存失败，执行新增/重命名/删除/排序 | 只有持久化成功才发布新列表；失败保留旧内容与撤销状态 | `FaceLibraryModel.swift:292-323,355-371,499-565,678-690` | 未测试 |
| XFLOW-006 | 演出有效素材 | 模拟复制中断、存储文件损坏、重启恢复 | 半文件不激活；旧素材可用；恢复找不到文件时显示缺项而不崩溃 | `PresetLiveModel.swift:23-65,143-160,577-639` | 未测试 |
| XFLOW-007 | 任一网络/输出操作中 | 高频切页、重复点、后台/前台、断开/重连组合 | 无崩溃、死锁、永久禁用、重复录音、重复音频、错误 sheet 风暴 | 各功能 model 与 `RootTabView.swift` | 未测试 |

## 14. UI、适配与辅助功能矩阵

### 14.1 每个核心页面必须执行的组合

核心页面集：控制、表情库列表/详情/排序、文字、口型/口型造型、演出/歌曲详情/自定义、控制中心、连接概览/三条连接路线/高级、设置、Debug 四工作区/原始命令。

| ID | 组合 | 步骤 | 通用预期 | 重点代码 | 状态 |
| --- | --- | --- | --- | --- | --- |
| UI-001 | ENV-PHONE-S + zh-Hans + 浅色 + 默认字号 | 遍历核心页面，滚动到末尾并操作主按钮 | 无裁切/重叠/不可达；标题、返回、sheet 关闭、主动作清楚；44 pt 目标 | 各 View；`AppLayout.swift:12` | 未测试 |
| UI-002 | ENV-PHONE-T + zh-Hans + 深色 + 默认字号 | 同上 | 文本、LED、材质、危险动作对比清楚；无硬编码浅色背景 | 各 View；`LEDBoardPreview.swift` | 未测试 |
| UI-003 | ENV-PAD-N + en + 默认字号 | 在窄分屏打开控制/口型/演出并动态调宽 | 宽度 <760 单栏；切换阈值无状态丢失、重叠或跳回顶部 | `FeatureWorkspace.swift:9-20` | 未测试 |
| UI-004 | ENV-PAD-W + en + 默认字号 | 打开控制、口型、演出、表情详情 | 宽度 ≥760 且非辅助字号时预览左、工具右，两列独立滚动；预览宽 ≤440/44% | `FeatureWorkspace.swift:9-20` | 未测试 |
| UI-005 | ENV-PAD-W + 最大辅助功能字号 | 重复 UI-004 | 自动回单栏；任务关键控件不隐藏；长标签竖向增长 | `FeatureWorkspace.swift:5,11-19` | 未测试 |
| UI-006 | iPhone/iPad + zh-Hant | 遍历全部页面和错误/空状态 | 无简中残留的活跃 UI、截断、格式占位符错位；术语一致 | `Localizable.xcstrings`；`InfoPlist.xcstrings` | 未测试 |
| UI-007 | iPhone/iPad + ja | 同上 | 日文自然且不裁切；a/i/u/e/o 的假名/罗马字意图清楚 | 同上；`LipSyncView.swift:74-85` | 未测试 |
| UI-008 | iPhone/iPad + en | 同上 | 英文长字符串可换行；按钮仍可达；无未翻译活跃项 | 同上 | 未测试 |
| UI-009 | 支持的 RTL 伪语言 | 遍历导航、列表、工具栏、滑动动作、进度 | 系统方向镜像合理；数值/hex/IP/时间仍可读；无手工左右假设破坏任务 | 各 SwiftUI View | 未测试 |
| UI-010 | Increase Contrast | 遍历预览、色块、选中项、状态色、启动层 | 文字/边框/选中状态可分辨；不靠低透明度色差 | `FacePartSelectorView.swift:43-86`；`BoardControlCenterView.swift:295-350` | 未测试 |
| UI-011 | Reduce Transparency | 遍历列表、底部附件、sheet、缩放预览边缘 | 层级与文字保持清楚；透明/模糊不是唯一分隔手段 | `RootTabView.swift:297-305`；`BoardPreviewZoom.swift:149-166` | 未测试 |
| UI-012 | Differentiate Without Color + 灰度 | 检查连接、校准、颜色、日志级别、错误、选择态 | 图标/文字/边框提供冗余线索；所有状态不只靠颜色 | 各 View 的 Label/选中 trait | 未测试 |
| UI-013 | Reduce Motion | 启动、开关控制中心、缩放回弹、列表切页、播放 | 启动和 zoom 转场简化；任务不延迟；交互状态仍明确 | `BootLoaderModel.swift`；`RootTabView.swift:281-328` | 未测试 |
| UI-014 | VoiceOver | 按视觉顺序遍历每页并激活主要动作 | 标题/值/状态/禁用原因可理解；图标按钮有标签；组合行不重复朗读 | 各 `.accessibility*`；`LEDBoardPreview.swift:118-120` | 未测试 |
| UI-015 | VoiceOver + 控制预览 | 尝试编辑一颗指定 LED，随后使用逐灯 Stepper | 预览提供总体摘要；逐灯编辑作为无需精确拖动的完整替代；状态变化可读 | `ControlView.swift:91-108`；`LEDBoardPreview.swift:118-120` | 未测试 |
| UI-016 | VoiceOver + 表情排序 | 仅用“上移/下移”和完成/取消排序 | 可完成同等排序任务；边界项无错误移动；焦点稳定 | `FaceLibraryView.swift:553-615` | 未测试 |
| UI-017 | Voice Control/Switch Control | 完成控制保存、文字发送、口型开始/停止、演出播放/停止 | 控件有可说名称且不依赖精确手势；焦点顺序符合任务顺序 | 系统 Button/Toggle/NavigationLink | 未测试 |
| UI-018 | iPad 硬件键盘 | 遍历 Form/List/TextEditor、sheet、文件选择 | Tab/Shift-Tab 焦点可达；Return/Space 可激活；Escape/取消路径可用；输入不陷住 | 各原生控件 | 未测试 |
| UI-019 | 粗体文本 + 最大字号 | 全部核心页 | 关键值、错误、进度和破坏性确认不裁切；可滚动到主动作 | 各 View | 未测试 |
| UI-020 | 典型/超长/空/加载/错误/离线内容 | 对每个列表页注入五态 | 状态之间不混淆；错误有恢复路径；晚到数据不破坏当前选择 | 各功能 ViewModel | 未测试 |
| UI-021 | iPad 四方向；iPhone 竖屏与倒置竖屏 | 在页面打开、sheet/键盘显示、导入过程中旋转 | 安全区、键盘、列表、双栏适配；任务状态不丢；无错误横屏强制 | `Info.plist:53-64`；`FeatureWorkspace.swift` | 未测试 |
| UI-022 | iPad 指针/触控板 | hover/点击色块、列表、附件、滑动替代菜单 | 点击区清楚；context menu 可用；无只有触摸才可达的关键动作 | 控制中心/表情库/连接列表 | 未测试 |
| UI-023 | 浅色/深色 + 显示面板照片开/关 | 在控制、文字、口型、演出、Debug 对比同帧 | 370 LED 位置/亮灭一致；照片关闭时未亮网格可见；预览不裁切、不拉伸 | `BoardPreviewRow.swift:18-140`；`LEDBoardPreview.swift:85-187` | 未测试 |
| UI-024 | 快速手势压力 | 控制预览快速绘制、交叉回划、边缘起手、缩放中加第二手势、页面滚动 | 绘制/滚动/缩放仲裁稳定；取消后临时状态清空；无卡住禁滚 | `LEDBoardPreview.swift:67-83,189-240`；`BoardPreviewZoom.swift:91-230` | 未测试 |
| UI-025 | 动态窗口宽度 | 在 740→780→740 pt 缓慢/快速调整，操作仍在进行 | 仅在阈值切布局；模型和导航保持；无两份交互同时响应 | `FeatureWorkspace.swift:9-20` | 未测试 |

### 14.2 页面专项视觉检查

| ID | 页面 | 检查点 | 状态 |
| --- | --- | --- | --- |
| VIS-001 | 控制 | 预览标题/已发送说明、画笔、主发送、保存、部件、更多编辑层级；缩放框只在放大时出现 | 未测试 |
| VIS-002 | 表情库 | 默认/我的分组、受保护标记、缩略图、搜索、多选底栏、撤销条不会互相遮挡 | 未测试 |
| VIS-003 | 文字 | 编辑器为主内容；聚焦时空间合理；超限错误和上传进度不跳版；播放预览为只读 | 未测试 |
| VIS-004 | 口型 | 开始/停止为主动作；音量条阈值标记；原始/平滑元音区别；校准进度不挤压操作 | 未测试 |
| VIS-005 | 演出 | 素材与播放层级；进度/时间稳定；缺音频与仅本机状态明确；错误可关闭 | 未测试 |
| VIS-006 | 连接 | 三种事实摘要清楚；三条路线描述可换行；阶段状态不跳跃；密码不明文 | 未测试 |
| VIS-007 | Debug | 顶部分段不遮内容；密集网格随宽度适配；危险动作与本机工具区分明显 | 未测试 |
| VIS-008 | 启动/附件 | 启动层安全区、浅深色和文字对比；附件不遮 tab 或页面末项；sheet 来源连续 | 未测试 |

## 15. 静态风险与执行优先级

以下是静态代码迹象生成的验收重点，不是已确认缺陷。

1. **控制中心存在未上线的保存候选能力**：`BoardControlCenterView` 定义了 `savesSection` 和 `saveCurrentState()`（`BoardControlCenterView.swift:64-72,362-440`），但当前 `body` 列表只插入状态、亮度、模式、颜色和连接（`32-39`）。这属于当前不可达的候选实现，不能仅据此判定用户可见功能缺陷；若产品范围确认要求从控制中心保存，再执行 `CC-010` 并按实际 UI 判定。
2. **控制中心候选“编辑”路径需要范围确认**：未上线保存区的 context menu 直接调用 `editor.loadForEditing(face)`（`415`），没有像表情库路径一样设置全局路由或关闭 sheet。仅在该候选能力纳入范围后执行 `CC-011`，确认用户能理解结果并到达编辑器；否则不据此判缺陷。
3. **首次直接校准的权限路径需要真机确认**：开始同步显式调用 `requestPermission()`，校准路径直接 `capture.start()`（`LipSyncModel.swift:217-245,371-415`）。执行 `LIP-013`，确认未决定/拒绝权限都有明确反馈且不残留录音。
4. **辅助效果环境覆盖需运行验证**：代码显式读取 Reduce Motion，但静态搜索未发现 Reduce Transparency、Increase Contrast 或 Differentiate Without Color 的专门分支。系统语义样式可能已足够，必须执行 `UI-010` 至 `UI-013` 后判定。
5. **紧凑附件限制字号需要辅助技术证据**：附件视觉字号封顶到 `xxxLarge`（`BoardControlCenterAccessory.swift:59`），设计意图是通过 VoiceOver value 保留完整状态。执行 `CC-009`，分别记录视觉和 VoiceOver 结果。
6. **自定义手势需做仲裁压力测试**：控制预览同时组合零距离 Drag 与 Magnify，且通过环境暂停绘制。静态审计没有高风险结论，但手势取消、边缘和第二指必须用 `CTL-001/009`、`UI-024` 证实。
7. **等待/节流代码被规则扫描提示**：本清单早期扫描范围含测试文件，与主流程口径不同；最终数量统一以主报告的 56 files、high=0、medium=54、low=2 为准。多数是 `Task.sleep`、固定 frame、GeometryReader 和 blur 的启发式命中，不能直接视为缺陷。相应行为已映射到启动、配网 45 s 超时、草稿节流、口型时钟、演出时钟、布局和减少效果用例。
8. **本地化统计要区分 catalog 与代码键**：当前 `Localizable.xcstrings` 静态解析到 870 个 catalog 条目，语言为 `zh-Hans/zh-Hant/en/ja`；主流程按代码键口径得到 708 个、missing=0。执行结果以主报告为准，并用 `UI-006` 至 `UI-008` 做运行验证，不能用 catalog 总条目数替代代码键覆盖率。

执行顺序建议：先 `NAV/CTL/FACE/TEXT` 的离线与模拟器项，再执行全 UI 矩阵；随后用一块物理面板依次完成 `ENV-HW-BLE → ENV-HW-LAN → ENV-HW-PH → ENV-HW-AP`；最后做 `XFLOW` 故障注入和输出争用。任何最高优先级功能失败应先停止扩展性视觉评分，保留证据并修复后回归相关区域。

## 16. 可安全隔离注入的自动化缺口建议

以下只是基于当前测试文件和构造路径的注入建议，不代表对应行为已经失败。当前 `RinaBoardAppTests` 有连接输出、播放协调器、草稿存储和本地表情库等测试，但没有以 `ControlViewModelTests`、`TextViewModelTests` 或 `PresetLiveModelTests` 命名的专门模型测试。

| 区域 | 建议隔离边界 | 可补的确定性模型测试 | 不应在该层触达 |
| --- | --- | --- | --- |
| Control | 为草稿仓库、面板帧输出和随机组合源定义最小协议/闭包；测试传入内存实现和固定随机序列 | 双眼镜像映射；370 bit 反转/清空；编辑基线恢复；节流期间只提交最终帧；连接代次改变后晚到结果不覆盖当前状态；保存替换与另存分支 | CoreBluetooth、网络 socket、真实 `UserDefaults.standard`、主共享草稿目录 |
| Text | 隔离草稿仓库、字体/帧生成器、时钟（`now/sleep`）和输出 sink；使用虚拟时钟推进上传、暂停和播放 | UTF-8/字符限制；同名草稿冲突；字体 bitmap 不可用时的帧回退；发送取消；暂停/继续；新输出会话使旧任务失效；前后台恢复时相位计算 | 真机面板、真实睡眠、系统字体时序、共享连接单例 |
| PresetLive | 保留已有 `Bundle`、`UserDefaults`、`PresetLiveFileStore` 注入，并增加音频播放器、时钟和面板输出协议；文件用临时目录，偏好用独立 suite | 导入成功/取消/损坏包事务性；替换失败仍保留旧素材；无音频素材播放；seek/loop；音频中断；切连接后恢复/停止；播放结束释放输出会话 | `AVAudioPlayer` 设备输出、系统音频会话、真实 Documents、物理板 |

这些模型测试适合验证状态机、取消和代次安全；真实麦克风、音频同步、BLE/LAN 时序及手势/布局仍必须由本清单中的模拟器、真机和实板用例验收。

## 17. 完成门槛

- 所有适用用例有非“未测试”的状态和可追溯证据。
- 五个主任务、连接、Debug 及跨输出会话没有阻断性失败。
- 最小布局、最大辅助字号、浅/深/高对比、Reduce Motion/Transparency、VoiceOver 的关键路径全部通过。
- BLE、家庭 Wi-Fi、个人热点、板载 AP、麦克风口型、演出音频与 370 LED 时序均有真机/实板证据。
- 没有把静态扫描、已有自动化测试数量或修复记录中的旧结果当成本轮通过证据。
