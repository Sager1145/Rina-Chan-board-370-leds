# RinaBoard · Apple 设备应用

[English](README.md) · 简体中文

画出表情、发送滚动文字，让 370 LED 璃奈板跟着声音、音乐或视频变化。RinaBoard 是 **iPhone、iPad 与 Mac Catalyst 共用的 SwiftUI 应用**，另提供通过配对 iPhone 转发操作的 **Apple Watch 控制端**。

应用使用 RinaLink，通过 BLE 或局域网 TCP 连接板子，日常控制无需外部服务器。硬件、固件烧录和物理按钮说明见[项目根 README](../README.md)。

## 可以做什么

### 绘制与收藏表情

在 370 点画布上点按或拖动绘制、擦除，使用镜像绘制、反选、清空、撤销、双指缩放、草稿恢复和实时发送。支持悬停的 iPad 与 Apple Pencil 可在预览和实体板上提示对应 LED 位置。

也可以组合左眼、右眼、嘴巴和脸颊部件，开启眼睛对称或随机生成组合，再继续手绘。本机与板端表情库分别管理，支持应用、重命名、复制、排序、编辑、批量删除和 JSON 导入 / 导出。预设表情受保护，本机删除支持撤销。单帧 M370 点阵支持十六进制、字节数组与 Base64 导入 / 导出。

### 随时调整整块板

控制中心显示连接状态，提供上一张 / 下一张表情、手动 / 自动轮播、轮播间隔、亮度和颜色。可以选择 Love Live! 系列角色颜色预设，也可输入自定义颜色。

| 布局 | 控制中心位置 |
|---|---|
| iOS 26+ 单列 | 底部原生导航上方的可拖动卡片，支持收起、半页和整页；切换功能页时保留高度 |
| 宽屏 iPad | 固定预览下方，与页面操作区并排 |
| Mac | 窄窗口与宽窗口均嵌入页面 |
| 折叠 Duo | 工具栏快捷操作，以及应用内容区内可展开的菜单 |
| iOS 17–25 单列 | 设置中的独立页面 |

Duo 根据折叠状态与方向安排预览和操作区：半折叠竖屏将预览置于折痕上方，横屏将预览 / 板端控制与页面操作分列。设置也会随宽度在列表导航与分类 / 详情双列之间切换，保留当前页面和未提交输入。

### 播放文字、口型、音乐与视频

| 功能 | 现有操作 | 播放由谁完成 |
|---|---|---|
| 滚动文字 | Ark Pixel 12px 排版与预览；播放、暂停、继续、停止、循环、逐帧移动、定位和标称 1–60 fps 调速 | 上传后由板端独立播放，断电丢失文字帧 |
| 口型同步 | 麦克风驱动元音 / 闭嘴口型；声音预设、灵敏度、刷新率、平滑、元音校准与嘴型映射 | 应用分析音频并实时发送 |
| 预设演出 | 本地音频配合 `.rinalive` 表情关键帧；暂停、定位与循环 | 应用按音频进度发送表情 |
| 视频 | 文件或相册导入；适配方式、阈值、抖动、反相、镜像、帧率、循环、静音与定位 | 应用将视频转换为开关点阵并实时发送 |

视频使用全板主颜色与亮度。仓库包含预设演出时间轴，曲目音频需自行提供。口型同步需要麦克风权限；演出和视频恢复需要对应素材仍保存在当前设备。

### 控制单板与多板组

同时保持多个 BLE 或局域网 TCP 连接，选择当前控制对象。切换板子时，应用停止此前由手机驱动的输出，但保留连接；断开与忘记设备只作用于对应设备。

每组最多 **5 块板**。拼接模式将文字横向分配到长屏，支持板间间距；镜像模式让每块板显示相同内容。可用编号识别实体板，并在组预览中拖动调整成员顺序。组文字通过时钟采样和定时启动同步，表情、颜色、亮度与应用驱动的实时内容也支持组控制。

应用在本机保存已知设备、连接偏好和分组。启动时自动重连最近使用的已保存设备，其余设备可从列表连接。

### 使用 Apple Watch

通过数码表冠调整亮度、轮播间隔、正在播放的文字速度和口型灵敏度，也可切换表情、颜色预设、手动 / 自动模式及口型同步。

Watch 的控制对象可以跟随手机，也可独立选择其他已连接单板或组，不改变手机当前选择。非手机当前同步组不能从 Watch 启动口型同步。切换表情、自动模式与口型同步会接管输出；亮度、颜色、间隔与文字速度作用于正在播放的内容。

**配对 iPhone 的应用必须在前台运行。** WatchConnectivity 经手机转发操作，Watch 不直接连接板子。手机锁屏或应用挂起后，Watch 控制会不可达，直到手机应用返回前台。

应用与 Watch 均提供简体中文、繁体中文、日语和英语本地化。

## 构建与运行

### 环境要求

使用 **Xcode 27.1 或更新版本**。最低运行目标为 **iOS / iPadOS 17、macOS 14、watchOS 10**。构建 SDK 与最低运行版本不同：Duo 源码引用了受运行时版本检查保护的 iOS 27.1 API，Xcode 16 无法编译当前源码。

应用保持 Swift 5 语言模式，`RinaCore` 使用 Swift 6。真机安装需要开发签名。模拟器可验证界面和 TCP 路径，实际 BLE、热点加入和 LED 输出需要实体设备。

### iPhone 与 iPad

打开 `ios/RinaBoard.xcodeproj`，选择 `RinaBoard` scheme 和目标设备。以下所有命令均从**仓库根目录**运行：

```sh
xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### Mac

```sh
./tools/build_mac.sh
open "$HOME/Applications/RinaBoard-Mac/RinaBoard.app"
```

脚本生成本地签名的 Catalyst 开发版。输出路径、签名选项、热点连接与实体板测试见 [Mac 文档](../docs/mac/README.md)。

### Apple Watch

构建 `RinaBoard` 会嵌入 `RinaBoardWatch.app`。选择 `RinaBoardWatch` scheme，在 Watch 真机或与 iPhone 模拟器配对的 Watch 模拟器运行。控制端 bundle ID 为 `com.rinachan.board.watchkitapp`。

## 连接第一块板

在**设置 → 添加璃奈板**中先通过蓝牙连接，然后从编辑器或表情库发送一张表情。通过**设置 → 连接**管理设备与控制对象，通过 **Wi-Fi 与热点**配置网络。

| 连接方式 | 设置方法 |
|---|---|
| BLE | 扫描 `RinaBoard-<ID>`，可直接控制及 Wi-Fi 配网 |
| 家庭 Wi-Fi | 板子与控制设备加入同一局域网，通过 Bonjour 发现或输入 IP；TCP 端口 `5370` |
| 板端热点 | 加入 `RinaChanBoard-<ID>`，初始密码 `rinachan`，连接该板自己的热点 IP |

`<ID>` 是由板子蓝牙 MAC 生成的 12 位大写十六进制标识。名称可修改，连接仍核对物理身份。通过 BLE 在 Wi-Fi 与热点设置中读取或修改该板热点 IP。手机或 Mac 一次只能加入一个 Wi-Fi 网络，多板同时控制可使用 BLE 或共同局域网。

强制退出后，重新打开应用以恢复自动连接。BLE 重连会获取已保存外设，或扫描其准确 UUID，不会只凭同名替换为另一块板。连接完成协议握手和初始读取后才进入就绪状态。

## 播放与重连

启动、重连和返回前台时，应用读取板端实际输出模式。首次连接或明确切换设备时，会采用板端模式并打开对应页面，包括演出中的视频页；实际重连会保留已选功能页，设置页也不会被自动切走。物理按钮及其他客户端的修改优先于应用记忆状态。

- 文字跟随板端保留的时间轴，断电后需重新上传。
- 在允许恢复的页面和状态下，口型同步可以重新采集麦克风，需要权限。
- 演出与视频用对应本地素材恢复板端报告的位置，并保留流身份；已经运行的匹配播放器保留自己的播放进度。
- 板端暂停状态会保留；缺失素材时显示提示。

当前固件提供稳定的输出模式与流信息。旧固件回退到上一帧原因；缺少素材身份的旧内容需要从更新后的应用重新启动一次，才能可靠恢复实时内容。

应用没有蓝牙后台运行模式。口型与媒体处理依赖应用持续运行；离开口型页面会停止麦克风同步，演出在应用不活跃时暂停，视频在进入后台时暂停。已保存表情与上传文字可由板端独立播放。

## 开发与调试

### 源码入口

| 目录 | 职责 |
|---|---|
| `RinaBoard/App/` | 生命周期、导航、控制中心位置与恢复 |
| `RinaBoard/Features/` | 编辑器、表情库、文字、口型、演出、视频、多板、设置与调试界面 |
| `RinaBoard/Services/` | 连接、持久化、音频 / 媒体服务与 Watch 转发 |
| `RinaBoard/Resources/` | 字体、部件、表情、时间轴、图像与本地化 |
| `RinaBoardWatch/` | Watch 界面与本地化 |
| `RinaWatchLink/` | 共用 WatchConnectivity 消息与转发 |
| `Packages/RinaCore/` | 与传输无关的 RinaLink 编解码与模型 |
| `Packages/RinaFaceSync/` | 独立同步模块；主应用尚未接入 iCloud 表情同步 |

`RinaBoard/` 使用文件系统同步 Xcode 分组，新增到对应子目录的文件会被项目自动识别。维护内置内容时参考[资源说明](RinaBoard/Resources/README.md)和[本地化工具](../tools/i18n/README.md)。

### 验证

```sh
# 核心包与同步模块检查，无需模拟器
./tools/verify_ios.sh core facesync facesync-guard

# 默认执行 core、facesync、facesync-guard、app、concurrency、mac
RINA_SIM_ID=<simulator-UDID> ./tools/verify_ios.sh

# UI 测试需显式选择
RINA_SIM_ID=<simulator-UDID> ./tools/verify_ios.sh ui

# 仅运行 Mac 应用单元测试
./tools/verify_ios.sh mac
```

通过 `xcrun simctl list devices available` 获取模拟器 UDID。脚本覆盖本地包与应用，检查实际执行的测试数，并约束严格并发警告基线。仅运行应用 scheme 测试不会覆盖 `RinaCore` 测试。实体板测试独立执行，其准备和状态恢复说明见 [Mac 文档](../docs/mac/README.md)。

### TCP 模拟板

```sh
# 单板，默认 TCP 端口 5370
python3 tools/rinalink_board_emulator.py

# 五块板，端口 15370–15374
python3 tools/run_simulator_group_boards.py
```

同机 iOS 模拟器手动添加主机 `127.0.0.1`；真机使用电脑的局域网 IP。使用 Ctrl-C 停止监听器。

Debug 模拟器构建可以添加 `Test · 2 boards`、`Test · 3 boards`、`Test · 5 boards` 与 `Test · 3 mirrors`，保留已有分组。启动五板模拟器并安装应用后，先结束已有应用实例，再运行：

```sh
xcrun simctl terminate <simulator-UDID> com.rinachan.board
xcrun simctl launch <simulator-UDID> com.rinachan.board \
  -initialTab text -seedTestGroups YES -connectTestBoards YES \
  -testGroupName 'Test · 3 boards' -playTestGroup YES -pauseTestGroup YES
```

应用未运行时，terminate 命令可能报告未找到运行实例。移除 `-pauseTestGroup YES` 即可保持滚动播放。这些测试数据使用正常的握手、上传、同步与排序流程，不包含在 Release 构建中。

`GroupPreviewSimulatorUITests` 覆盖拼接 / 镜像预览、长按排序与窄预览滚动。五板横屏用例要求实际应用窗口处于横屏；运行对应测试前，在 Device Hub 设置 Duo 折叠状态与方向。

Watch 调试可用 `xcrun simctl pair` 配对模拟器，分别安装手机应用和其中嵌入的 Watch 应用，再由手机连接 TCP 模拟板。Watch 首次发送消息后才建立可达状态，模拟器可能先显示等待提示。

### 调试终端

**设置 → 调试 → 终端**使用当前 BLE / TCP 连接，可发送 `get_info` 等命令名，或 JSON：

```json
{"cmd":"set_brightness","raw":80}
```

也支持 `PING`、`GET_STATUS` 与 `GET_POWER`。启用“显示全部可用指令”可搜索固件模板并填入输入框。终端保留近期请求、回复与固件日志；USB 串口诊断使用固件的独立控制台。

## 进一步阅读

- [项目总览与固件安装](../README.md)
- [Mac 构建与验证](../docs/mac/README.md)
- [RinaLink 协议](../docs/RINALINK_PROTOCOL_V1.md)
- [口型同步与演出](../docs/LIVE_FEATURES_ZH.md)
- [多板组设计](../docs/BOARD_GROUP_SPEC.md)
- [文字光栅化](../docs/SCROLL_RASTERIZER_SPEC.md)

项目使用 [GNU GPL v3](../LICENSE)。请随第三方资源保留来源与许可说明；演出音频不随仓库分发。
