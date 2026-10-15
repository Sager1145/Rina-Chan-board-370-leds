# RinaChanBoard · 370 LED 璃奈板

把表情画在璃奈板上，让文字横跨多块板滚动，或让嘴型跟着你的声音和音乐变化。

RinaChanBoard 使用 **ESP32-S3 + 370 颗 WS2812B LED**，通过 RinaBoard 原生应用控制。仓库包含板端固件、iPhone / iPad 应用、Mac Catalyst 应用和 Apple Watch 控制端。设备通过蓝牙或本地 Wi-Fi 通信，日常使用无需外部服务器。

[3D 打印模型](https://makerworld.com/zh/models/2569348-rina-chan-board-rina-board-rina-chan-board#profileId-2832058) · [Apple 应用开发说明](ios/README.zh-CN.md) · [Mac 构建与使用](docs/mac/README.md) · [RinaLink 协议](docs/RINALINK_PROTOCOL_V1.md)

## 可以做什么

### 画出、组合并收藏表情

在 370 点画布上点按或拖动绘制，切换画笔与橡皮擦，使用镜像绘制、反选、清空和撤销。画布支持缩放、草稿恢复和实时发送；支持悬停的 Apple Pencil 还可以在预览与实体板上提示对应 LED 位置。

也可以直接组合左眼、右眼、嘴巴和脸颊部件，开启眼睛对称，随机生成组合，再继续手绘修改。

表情库分为**本机收藏**和**板端收藏**，可应用、重命名、复制、排序、编辑、批量删除及 JSON 导入 / 导出。预设表情受保护，本机删除支持撤销。单帧点阵可通过 M370 十六进制、字节数组或 Base64 导入 / 导出。

### 随时调整整块板

控制中心集中提供连接状态、上一张 / 下一张表情、手动 / 自动轮播、轮播间隔、亮度和颜色。颜色可手动输入，也可选择内置 Love Live! 系列角色预设。

- **iOS 26+ 单列布局**：控制中心位于底部导航上方，可拖动到收起、半页和整页高度；展开后仍可切换功能页，切换时保留展开高度。
- **宽屏 iPad 与 Mac**：预览与操作并排显示，板端控制嵌入页面；窗口变窄时切换布局。
- **Duo 布局**：根据折叠状态与方向安排预览和操作区，折叠时通过工具栏展开控制中心。
- **iOS 17–25 单列布局**：从设置进入控制中心。

### 播放滚动文字

输入文字后，应用使用 Ark Pixel 12px 位图字体生成点阵，可先预览再上传。支持播放、暂停、继续、停止、循环、逐帧移动、拖动定位和速度调整，标称速度范围为 **1–60 fps**。

上传完成后，板端独立播放这段文字；应用重连会读取板端进度。文字帧保存在 RAM / PSRAM，断电后需要重新发送。

### 让嘴型跟随声音

使用控制设备的麦克风实时分析声音，切换元音和闭嘴口型。可选择声音识别预设，调整灵敏度、刷新率和平滑，并进行元音校准与嘴型映射。

口型分析由应用完成，需要麦克风权限，并在运行时持续向板端发送画面。

### 用音乐和视频驱动画面

**预设演出**将本地音频与 `.rinalive` 关键帧脚本配对，按音频播放位置切换表情，支持暂停、定位和循环。仓库提供预设时间轴，曲目音频需自行准备。

**视频播放**可从文件或相册导入视频，将画面转换为 370 点开关图案并实时发送。支持适配方式、阈值、抖动、反相、镜像、帧率、循环、静音和定位。输出使用全板主颜色与亮度。

演出与视频需要应用持续运行。重连或返回前台时，应用读取板端输出模式，并尝试用本机保留的对应素材恢复播放位置；素材缺失时会提示，板端暂停状态也会保留。

### 把多块板组成一块长屏

应用可以同时保持多个 BLE 或同一局域网 TCP 连接，选择单板或多板组作为控制对象。每组最多 **5 块板**，支持两种显示方式：

| 方式 | 显示效果 |
|---|---|
| 拼接 | 把文字横向分配到各块板，组成连续长屏，可设置板间间距 |
| 镜像 | 每块板显示同一内容 |

可显示实体板识别编号，并在组预览中拖动调整成员顺序。组文字播放使用时钟采样和定时启动同步；表情、颜色、亮度及应用驱动的实时内容也支持组控制。

已知设备、连接偏好和分组信息保存在本机。启动时自动重连最近使用的已保存设备，其余设备可从连接列表加入。

### 在 Apple Watch 上控制

Watch 经配对 iPhone 调整亮度、表情、颜色、自动轮播与间隔、正在播放的文字速度，以及口型同步开关和灵敏度；数值可用数码表冠调整。还可选择连接中的单板或组，独立于手机当前选择的控制对象。

Watch 操作由 iPhone 转发，**iPhone 应用需要在前台运行**。Watch 不直接连接璃奈板；非手机当前同步组不能从 Watch 启动口型同步。

应用和 Watch 提供简体中文、繁体中文、日语和英语本地化。

## 从零开始

### 1. 准备硬件与工具

默认固件面向 **8 MB Flash、8 MB OPI PSRAM 的 ESP32-S3** 和 370 颗 WS2812B LED，使用 PlatformIO + Arduino。外壳可参考上方的 3D 打印模型。

| 部分 | 开发与运行要求 |
|---|---|
| 固件 | PlatformIO Core 或 VS Code PlatformIO 插件 |
| iPhone / iPad | Xcode 27.1 或更新版本构建；最低运行版本 iOS / iPadOS 17 |
| Mac | Mac Catalyst；最低运行版本 macOS 14 |
| Apple Watch | `RinaBoardWatch` scheme；最低运行版本 watchOS 10 |

构建 SDK 与最低运行版本不同：当前源码引用了受运行时版本检查保护的 iOS 27.1 API。真机安装需在 Xcode 配置开发签名。

```sh
git clone https://github.com/Sager1145/Rina-Chan-board-370-leds.git
cd Rina-Chan-board-370-leds
```

### 2. 烧录璃奈板

```sh
cd esp32s3_firmware
pio run
pio run -t upload
pio run -t uploadfs
pio device monitor -b 115200
```

首次安装需要上传固件和 LittleFS 文件系统。`uploadfs` 会重写文件系统镜像，已有板端表情、运行设置或电池校准数据时，先备份再执行。

默认环境 `esp32s3-rmt-dma` 使用 RMT + DMA 输出 LED。另提供 `esp32s3-rmt`（RMT，无 DMA）与 `esp32s3`（Adafruit NeoPixel）后端，可通过 `pio run -e <环境名>` 选择。平台版本、依赖和 PSRAM 配置见 [platformio.ini](esp32s3_firmware/platformio.ini)。

### 3. 安装控制应用

从仓库根目录打开 `ios/RinaBoard.xcodeproj`，选择 `RinaBoard` scheme，在 iPhone / iPad 真机或模拟器运行。命令行示例：

```sh
xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Mac 本地开发版：

```sh
./tools/build_mac.sh
open "$HOME/Applications/RinaBoard-Mac/RinaBoard.app"
```

Mac 脚本生成本地签名应用，输出与签名选项见 [Mac 文档](docs/mac/README.md)。Watch 应用随 iPhone 应用嵌入安装，可使用 `RinaBoardWatch` scheme 单独运行与调试。

### 4. 连接并显示第一张表情

在应用的 **设置 → 添加璃奈板** 中先通过蓝牙连接，然后选择表情发送，或直接在画布上绘制并发送。后续可在 **设置 → Wi-Fi 与热点** 中配置网络，在 **设置 → 连接** 中管理设备和选择控制对象。

| 连接方式 | 如何连接 |
|---|---|
| 蓝牙 BLE | 扫描并选择默认名称为 `RinaBoard-<ID>` 的设备，可直接控制和配网 |
| 家庭 Wi-Fi | 应用与板子加入同一局域网，通过 Bonjour 发现或手动输入板端 IP；TCP 端口 `5370` |
| 板端热点 | 加入默认名称为 `RinaChanBoard-<ID>` 的热点，初始密码 `rinachan`，连接该板的热点 IP |

`<ID>` 是由蓝牙 MAC 地址生成的 12 位大写十六进制标识。设备名可以修改，连接仍核对物理身份。

每块板有自己的热点 IP，可通过蓝牙在网络设置中读取或修改，也可在 USB 串口查看。热点直连时，一台手机或电脑一次只能加入一个 Wi-Fi 网络；同时控制多板可使用 BLE 或共同的家庭 Wi-Fi。

也可加入板端热点后，打开 `http://rina.io/` 或该板实际热点 IP，通过轻量浏览器页面配网。

## 不打开应用也能操作

六个物理按钮提供表情、模式、亮度与电池操作：

| 按钮 | GPIO | 操作 |
|---|---:|---|
| B1 | 17 | 松开切换下一张表情；长按 10 秒重置蓝牙设置 |
| B2 | 16 | 切换上一张表情；长按连续切换 |
| B3 | 15 | 松开切换手动 / 自动轮播；配合 B1 / B2 调整间隔 |
| B4 | 40 | 亮度减 8；长按连续调整 |
| B5 | 41 | 亮度加 8；长按连续调整 |
| B6 | 42 | 短按显示电量；长按约 700 ms 显示电池详情；长按 10 秒重置 Wi-Fi 设置 |
| 按住 B3，再按 B1 / B2 | — | 轮播间隔分别减 / 加 500 ms |

亮度范围 **10–200**，默认 **50**；轮播间隔 **0.5–10 秒**，默认 **3 秒**。切换表情会接管输出并结束文字滚动；调节亮度可以作用于正在播放的内容。

应用也可读取电池电压、电量估计、充电状态和 ADC 信息，并保存校准数据。电量百分比取决于实际电池、采样电路与校准结果。

## 开发入口

```text
esp32s3_firmware/       ESP32-S3 固件、LittleFS 初始资源与主机测试
ios/RinaBoard/         iPhone / iPad / Mac 共用界面与服务
ios/RinaBoardWatch/    Apple Watch 界面
ios/RinaWatchLink/     Watch 与 iPhone 的消息与转发
ios/Packages/          RinaCore 协议核心、独立 RinaFaceSync 模块
tools/                 构建、验证、模拟板与资源维护脚本
docs/                  协议、功能说明、设计与验证记录
legacy/webui_v1/       历史浏览器控制端归档
```

### 硬件映射与点阵格式

| 项目 | 当前配置 |
|---|---|
| LED 数据 | `GPIO2` |
| 电池电压 / 充电检测 ADC | `GPIO10` / `GPIO1` |
| 点阵 | 22 × 18 外接网格，370 个有效位置，蛇形物理走线 |
| 默认颜色 | `#f971d4` |
| 板端存储 | LittleFS + NVS |

M370 一帧用 **47 字节**保存 370 个开关位，十六进制表示为 **94 个字符**。位序按逻辑 LED 索引、每字节 LSB-first，最后一字节高 6 位为零；颜色和亮度是全板参数。具体引脚、行长和限制见 [config.h](esp32s3_firmware/src/config.h)。

LittleFS 的 `resources/saved_faces.json`、`resources/runtime_settings.json` 和 `resources/battery_calib.json` 分别保存表情、运行设置和电池校准。网络与设备设置通过 NVS 保存。应用字体、表情部件和演出时间轴位于 [应用资源目录](ios/RinaBoard/Resources/README.md)。

### 验证与无硬件调试

在仓库根目录运行：

```sh
# 核心包与独立同步模块检查，无需模拟器
./tools/verify_ios.sh core facesync facesync-guard

# 默认包含核心包、同步模块、应用测试、并发检查与 Mac 测试
RINA_SIM_ID=<模拟器-UDID> ./tools/verify_ios.sh

# UI 测试需显式选择
RINA_SIM_ID=<模拟器-UDID> ./tools/verify_ios.sh ui

# 单板 TCP 模拟器
python3 tools/rinalink_board_emulator.py

# 五块本地模拟板，端口 15370–15374
python3 tools/run_simulator_group_boards.py
```

同机 iOS 模拟器可手动连接 `127.0.0.1`，真机使用电脑的局域网 IP。模拟器可验证界面和 TCP 路径，真实蓝牙、热点和 LED 输出需实体设备验证。

应用 **设置 → 调试** 提供设备状态、测试图案、诊断导出、RinaLink 命令终端和固件日志；终端通过 BLE / TCP 工作。USB 串口另有诊断与测试控制台。实体板测试脚本会操作设备，运行方式与恢复行为见 [Mac 验证说明](docs/mac/README.md)。

### 当前范围

- 表情与已上传文字由板端播放；口型、演出和视频依赖应用持续处理与发送。
- 应用未启用蓝牙后台运行模式；强制退出后需重新打开才能恢复自动连接，Watch 转发也要求 iPhone 应用在前台。
- 演出 / 视频恢复依赖本机对应素材，口型同步依赖麦克风权限。
- `RinaFaceSync` 为独立模块与集成代码，主应用尚未接入 iCloud 表情同步。
- 历史 WebUI 和显示控制 REST API 位于归档范围；当前浏览器入口用于 Wi-Fi 配网。

## 进一步阅读

| 文档 | 内容 |
|---|---|
| [Apple 应用开发说明](ios/README.zh-CN.md) | Xcode 构建、Watch、连接恢复、布局与模拟器 |
| [Mac 构建与验证](docs/mac/README.md) | Catalyst、本地签名、热点连接和实体板测试 |
| [RinaLink v1](docs/RINALINK_PROTOCOL_V1.md) | BLE / TCP 帧格式、命令、事件与设备身份 |
| [口型同步与演出](docs/LIVE_FEATURES_ZH.md) | 音频处理、脚本格式与素材 |
| [多板组协议设计](docs/BOARD_GROUP_SPEC.md) | 拼接、识别、时钟同步与定时启动 |
| [文字光栅化](docs/SCROLL_RASTERIZER_SPEC.md) | 位图字体排版与点阵生成 |
| [本地化工具](tools/i18n/README.md) | 字符串目录与翻译维护 |

## 许可证

项目使用 [GNU GPL v3](LICENSE)。第三方库、字体、表情和演出资源按各自许可使用，请保留随资源提供的来源与许可说明；演出音频不随仓库分发。
