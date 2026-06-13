# Rina-Chan Board 固件与 WebUI AI 可执行规格书

本文档是基于当前项目实现反向整理的 `plan.md`。它的目标不是普通开发计划，而是一份可执行规格书：任何现代 AI 只读取本文件，不参考旧代码，也应能重建当前 PlatformIO 固件、LittleFS 数据文件、`index.html`、`app.js`、`styles.css` 和相关 WebUI 资源约定。

当前实现目标硬件为 ESP32-S3、370 颗 WS2812B、Arduino Core、PlatformIO、LittleFS、AP-only Web 控制界面。当前实现已明确剔除 I2C 电源管理芯片、PD/充电 IC 控制、硬件温度检测模块；重建时不得加入这些模块。

本版本已对照 2026-06-12 的实际代码做过同步：删除了文档中冗余的源码全文转储与历史变更日志，修正了与当前实现不符的字体资源与缓存版本号，并在文首补充逻辑结构导读、在文末补充“待办 / 未来工作”。最近一次同步补齐了逐帧按钮与 emoji 输入迭代引入的变化：文字滚动逐帧前进/后退按钮（`scroll_step` 支持 `direction`）、滚动暂停拆分为用户级/系统级两级（B6 电量覆盖层显示期间进入系统级暂停）、滚动页帧率滑条/±5/预设控件、`WEBUI_CONFIG.navigation.pages`、Ark 字体模型 v4 与 emoji 合并字体、加载揭示动画改为单半径径向遮罩。文档结构见 §0。

## 0. 概述与文档结构

### 0.1 项目目标（这是什么）

Rina-Chan Board 是一块 370 颗 WS2812B 组成的 22x18 非矩形 LED 表情板。本固件运行在 ESP32-S3 上，用 Arduino + PlatformIO 构建，挂载 LittleFS，开机后以 **AP-only**（无路由、无外网）方式提供一个浏览器 WebUI 控制台。用户通过 WebUI 或 6 个硬件按钮控制表情、颜色、亮度、自动播放、自定义画板、部件拼脸和文字滚动，并查看 2S LiPo 电池/充电状态。

本文件是一份**可执行规格书**：目标是让任何开发者或代码生成 Agent 只读本文件（不参考旧代码）即可重建当前固件、LittleFS 数据、`index.html` / `app.js` / `styles.css` 和资源约定。

### 0.2 当前实现状态（已实现功能）

下列功能在当前代码中均已实现并可用：

- **LED 渲染**：`Adafruit_NeoPixel` 驱动 370 颗 WS2812B，蛇形物理映射（奇数行反向），逻辑 row-major；BSS138 电平转换感知的 show 前后 idle-low 窗口。
- **M370 帧协议**：`M370:` + 93 hex（370 bit + 2 padding）的解析/校验/编码，固件内 47 字节 packed bit array，33 ms 限速 + 深度 3 的帧队列。
- **双核分工**：Core 1 跑 LED render/scroll FreeRTOS task，Core 0 跑 WebServer、按钮、电源、队列服务（由 `build_flags` 固定 core affinity）。
- **AP + HTTP API**：SSID `RinaChanBoard-V2`，域名 `rina.io`，IP `192.168.1.14`；路由 `/api/status`、`/api/power`、`/api/frame`、`/api/scroll`、`/api/command`、`/api/saved_faces` 加静态文件回退，gzip 优先 + 分块流式传输。
- **存储**：LittleFS 原子 JSON 写（temp + rename），`saved_faces.json`（默认+用户表情统一源，默认表情不可删除）、`runtime_settings.json`、`battery_calib.json`。
- **电源监控**：双 ADC（电池/充电），多采样去极值 + 时间常数 EMA + 固定 2S LiPo LUT 百分比；电池断开/低压未供电检测。**不含** I2C/PD/温度逻辑。
- **硬件按钮 B1–B6**：表情前后切换、manual/auto 切换、亮度 ±8、自动播放间隔调整、B6 电源覆盖层（由 `button_animations.*` 驱动）。
- **WebUI 五页**：基础控制、自定义画板、部件拼脸、文字滚动、调试/电源；外置 `app.js` + `styles.css`，无构建工具/无 npm；加载覆盖层动画、自适应 LED 预览矩阵、自定义下拉、发送/按钮队列限速、状态轮询。
- **文字滚动**：浏览器端用 `ark12.json` 位图字形（含融合 CJK 与 Mona12 单色 emoji）栅格化为帧，按 24 帧一包上传到固件 **RAM**（不落 flash），上传完成后下发 `start_scroll`；支持逐帧前进/后退（`scroll_step` + `direction`），暂停拆分为用户级（API/页面按钮）与系统级（B6 电量覆盖层期间自动暂停）两级。

### 0.3 架构 / 技术栈（怎么搭的）

- **MCU/框架**：ESP32-S3-DevKitC-1，Arduino 框架，PlatformIO，QSPI PSRAM。
- **文件系统**：LittleFS（`partitions.csv` 关闭 OTA、单 2 MB app + ~5.9 MB LittleFS）。
- **库**：`ArduinoJson@^6.21.5`、`Adafruit NeoPixel@^1.12.3`；HTTP 用 Arduino `WebServer`（非 AsyncWebServer），配 `DNSServer`。
- **固件模块**：`config` / `sync`(FreeRTOS mutex) / `state`(RuntimeStore 单例) / `led_renderer` / `scroll` / `faces` / `buttons` + `button_animations` / `storage` / `power_monitor` / `web_api` / `web_json` / `psram_json` / `utils`。
- **WebUI**：纯原生 JS/CSS/HTML 三文件；UI 字体为内联 GNU Unifont 子集，滚动字体为 `ark12.woff2` + `ark12.json`。
- **构建钩子**：`scripts/patch_webserver_timeout.py`（pre，改 WebServer TCP 超时）、`scripts/gzip_webui_assets.py`（构建期生成并清理 `.gz`）。

### 0.4 本文档结构导航

本规格书在本节（逻辑结构总览）之后，按主题展开详细规格；它们共同构成上面“当前实现状态 / 架构”的完整细节：

- **§1 项目边界**：必须实现 / 禁止实现。
- **§2 工程结构**：文件树与重建口径。
- **§3 PlatformIO 与构建** / **§4 硬件与引脚** / **§5 常量规格**：技术栈与硬件约束。
- **§6 固件模块规格** / **§7 启动流程**：后端实现细节（逐模块）。
- **§8 WebUI 架构** / **§9 CSS 规格** / **§10 工具函数** / **§11 资源文件** / **§12 功耗估算**：前端与资源实现细节。
- **§13 验收标准** / **§14 重建提示** / **§15 SSOT 锁定版**：验收、重建顺序与单一事实来源锁定值。
- **§16 待办 / 未来工作**：尚未实现或待清理项（本次同步新增）。

如各节描述与 §15 锁定值冲突，以 §15 中“当前实现锁定值”为准。

## 1. 项目边界

### 1.1 必须实现

- ESP32-S3 基于 Arduino Framework 的 PlatformIO 工程。
- 370 颗 WS2812B LED 的表情板渲染。
- `M370:<93 hex>` 帧格式解析、校验、编码与渲染。
- LittleFS 挂载、静态 WebUI 托管、`.gz` 资源优先服务。
- AP-only 模式：SSID `RinaChanBoard-V2`，密码 `rinachan`，域名 `rina.io`，默认 IP `192.168.1.14`。
- HTTP API：状态、电源、单帧、滚动帧、统一命令、保存表情文件读写。
- 硬件按钮 B1-B6：表情切换、手动/自动模式、亮度、自动播放间隔。
- Core 1 FreeRTOS LED 渲染/滚动任务，Core 0 负责 Web、按钮、电源、队列服务。
- 2S LiPo 电池/外部充电电压 ADC 监控，使用去极值平均、时间常数 EMA、固定 2S LiPo LUT 估算电量。
- WebUI V2：基础控制、自定义画板、部件拼脸、文本滚动、调试/电源状态页面。
- 表情库 `saved_faces.json` 读写，默认表情不可删除但可重命名/排序。
- 文本滚动帧只上传到固件 RAM，不保存到 flash。
- WebUI 运行时拆分为 `data/index.html` DOM、`data/styles.css` 样式和 `data/app.js` 行为逻辑；无构建工具、无 npm 运行时。

### 1.2 禁止实现

- 不得添加 I2C 电源管理、PD 协议、充电 IC 寄存器读写。
- 不得添加硬件温度传感器读取或温度保护逻辑。
- 不得将文本滚动帧持久化到 flash。
- 不得把当前电池算法改回动态峰谷自学习百分比算法；当前实现已移除动态 min/max 学习，采用固定 LUT + EMA。
- 不得用 FastLED 替代当前驱动；当前实现使用 `Adafruit_NeoPixel`。
- 不得把 Web 服务器替换成 AsyncWebServer；当前实现使用 Arduino `WebServer`，通过短 timeout 和分块流式传输优化。

## 2. 工程结构

必须重建以下文件结构：

```text
esp32s3_firmware/
  platformio.ini
  partitions.csv
  plan.md
  README.md
  .gitignore
  run_rinachan_unifont.sh           # 字体资源构建链（Bash 版）
  run_rinachan_unifont.ps1          # 字体资源构建链（PowerShell 版）
  scripts/
    patch_webserver_timeout.py      # pre 构建：修补 Arduino WebServer.h TCP 超时
    gzip_webui_assets.py            # 构建期生成并清理 .gz 静态资源
  tools/                            # 字体资源生成工具（离线运行，不参与固件编译）
    build_ark12_merged.py
    build_unifont_webui_subset_from_png.py
    compile_ark_bdf.py
    merge_mona12_emoji.py
    font_fusion/
  licenses/
    GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt
  src/
    config.h
    config.cpp
    main.cpp
    sync.h
    sync.cpp
    state.h
    state.cpp
    led_renderer.h
    led_renderer.cpp
    storage.h
    storage.cpp
    faces.h
    faces.cpp
    buttons.h
    buttons.cpp
    button_animations.h             # B6 电源覆盖层 / 组合键动画状态机
    button_animations.cpp
    scroll.h
    scroll.cpp
    power_monitor.h
    power_monitor.cpp
    web_api.h
    web_api.cpp
    web_json.h
    web_json.cpp
    psram_json.h
    utils.h
    utils.cpp
  data/
    index.html
    app.js
    styles.css
    resources/
      saved_faces.json
      runtime_settings.json
      battery_calib.json
      loading/
        rina_icon1_default.png
        rina_icon2_hover.png
      fonts/
        ark12.woff2
        ark12.json
        README.md
```

> 说明：仓库根目录还存在若干历史修复报告 `*.md`（如 `CODE_REVIEW.md`、`ARK12_FUSION_WEBUI_LED_FINAL_FIX_REPORT.md` 等）以及 `animation.md`，它们是过程记录，不属于重建源。`.pio/`、`.vscode/`、`.font_cache/`、空文件 `pio` 与各 `*.gz`（`index.html.gz`、`app.js.gz`、`styles.css.gz`、`resources/fonts/ark12.json.gz`）都是本地缓存或构建生成物，不作为重建源。早期文件树列出的 `ark12_fallback.woff2` 已删除，不再生成。


### 2.1 从零重建口径

从零重建时，`plan.md` 必须被当作完整规格，而不是历史变更记录。第 2 节只列文件树；实际代码、资源、API、WebUI DOM/CSS/JS 行为必须继续按第 3 到第 14 节实现。不得引入本文件没有列出的运行时文件、隐藏在线依赖或浏览器外部字体。

WebUI 的重建边界如下：

- `data/index.html` 负责 DOM 结构与稳定 id/class；行为由外置 `data/app.js` 加载，当前入口为 `<script src="app.js?v=20260612-step-buttons-v4"></script>`。
- `data/app.js` 负责全部 WebUI 行为、配置、表情/部件运行时数据、API 队列、矩阵、滚动、调试和启动编排；不得改回内联 `<script>`，除非同步更新本计划和 gzip/静态托管规则。
- `data/styles.css` 负责全部视觉、布局、动画和字体声明；GNU Unifont 必须以内联 `data:font/woff2;base64,...` 形式写在 CSS 内。当前实现只注册一个 Ark Pixel 浏览器字体 `/resources/fonts/ark12.woff2`（带缓存破坏 query，例如 `?v=20260612-emoji-input-v3`，该 token 每次发布会变化）；早期的 `ark12_fallback.woff2` 回退/别名注册已移除，对应文件也已从项目中删除。
- `/resources/fonts/ark12.json` 是文字滚动栅格化器的位图字形表；它必须保持懒加载，不得在首屏加载阶段同步读取。
- `/resources/loading/rina_icon1_default.png` 与 `/resources/loading/rina_icon2_hover.png` 是加载覆盖层的两个头像状态；默认图标需要在 `<head>` 预加载并作为 favicon。
- `scripts/gzip_webui_assets.py` 必须能为 `index.html`、`app.js`、`styles.css`、`resources/fonts/ark12.json` 生成临时 `.gz` 同级文件，LittleFS 镜像生成后删除工作树中的临时 `.gz`，固件静态服务按 Accept-Encoding 优先返回 gzip。
- 若实现与本文件有冲突，以“当前实现同步补充”小节和精确常量表为准；重建后应能只通过 `pio run`、`pio run -t uploadfs` 和浏览器访问 AP 完成验收。

## 3. PlatformIO 与构建

`platformio.ini` 必须满足：

- `platform = espressif32`
- `board = esp32-s3-devkitc-1`
- `framework = arduino`
- `monitor_speed = 115200`
- `upload_speed = 921600`
- `board_build.filesystem = littlefs`
- `board_build.partitions = partitions.csv`
- QSPI PSRAM 配置：
  - `board_build.psram_type = qspi`
  - `board_build.arduino.memory_type = qio_qspi`
- `lib_deps`：
  - `bblanchon/ArduinoJson@^6.21.5`
  - `adafruit/Adafruit NeoPixel@^1.12.3`
- `extra_scripts`：
  - `pre:scripts/patch_webserver_timeout.py`
  - `scripts/gzip_webui_assets.py`
- `build_flags`：
  - `-D BOARD_HAS_PSRAM`
  - `-D ARDUINO_USB_CDC_ON_BOOT=1`
  - `-D RINACHAN_AP_ONLY=1`
  - `-D ARDUINO_RUNNING_CORE=0`
  - `-D ARDUINO_EVENT_RUNNING_CORE=0`
  - `-D HTTP_MAX_DATA_WAIT=200`
  - `-D HTTP_MAX_POST_WAIT=200`
  - `-D HTTP_MAX_SEND_WAIT=200`

`build_unflags` 必须移除 Arduino core/event task 的 Core 1 默认值：

- `-DARDUINO_RUNNING_CORE=1`
- `-DARDUINO_EVENT_RUNNING_CORE=1`

`scripts/patch_webserver_timeout.py` 必须在构建前修补 Arduino `WebServer.h` 的 TCP 超时，作为响应迟滞优化。`scripts/gzip_webui_assets.py` 必须在构建期间生成静态资源的 `.gz` 版本，至少覆盖大型 HTML/JS/CSS/JSON 资源。

## 4. 硬件与引脚

### 4.1 Wi-Fi 与 HTTP

- AP SSID：`RinaChanBoard-V2`
- AP password：`rinachan`
- AP domain：`rina.io`
- HTTP port：`80`
- DNS port：`53`
- AP IP/gateway：`192.168.1.14`
- subnet：`255.255.255.0`

### 4.2 LED

- LED type：WS2812B / NeoPixel GRB 800 kHz。
- LED 驱动：`Adafruit_NeoPixel strip(370, 2, NEO_GRB + NEO_KHZ800)`。
- LED count：`370`
- LED data GPIO：`2`

### 4.3 按钮

所有按钮使用 `INPUT_PULLUP`，低电平表示按下。

| 按钮 | GPIO | 功能 |
|---|---:|---|
| B1 | 17 | 下一个保存表情，支持长按重复 |
| B2 | 16 | 上一个保存表情，支持长按重复 |
| B3 | 15 | 松开时切换 manual/auto；与 B1/B2 组合调整 auto interval |
| B4 | 40 | 亮度减 8，支持长按重复 |
| B5 | 41 | 亮度加 8，支持长按重复 |
| B6 | 42 | 电量覆盖层输入；短按显示百分比，长按循环详情；当前实现中 B6 长按只有在 B2/B3 均未按下时触发，B6+B2/B6+B3 不生成附加页面 |

### 4.4 ADC

- 电池电压 ADC GPIO：`10`
- 充电/外部输入 ADC GPIO：`1`
- ADC 分辨率：12 bit。
- ADC attenuation：`ADC_11db`。
- 每次采样 16 次，排序后去掉最低 4 个和最高 4 个样本，再平均剩余 8 个样本。
- 两次样本间 `delayMicroseconds(250)`。

## 5. 常量规格

### 5.1 LED 矩阵

逻辑矩阵为 22 列 x 18 行的非矩形布局，总计 370 个有效 LED。行内有效范围来自 `ROW_LENGTHS` 与 `ROW_OFFSETS`：

```cpp
constexpr uint8_t MATRIX_ROWS = 18;
constexpr uint8_t ROW_LENGTHS[18] = {
  18, 20, 20, 20, 22, 22, 22, 22, 22,
  22, 22, 22, 22, 20, 20, 20, 18, 16
};
constexpr uint16_t ROW_OFFSETS[18] = {
  0, 18, 38, 58, 78, 100, 122, 144, 166,
  188, 210, 232, 254, 276, 296, 316, 336, 354
};
```

WebUI 的 22 列坐标范围必须是：

```js
row_valid_x_ranges = [
  [2,19], [1,20], [1,20], [1,20],
  [0,21], [0,21], [0,21], [0,21], [0,21],
  [0,21], [0,21], [0,21], [0,21],
  [1,20], [1,20], [1,20],
  [2,19], [3,18]
]
```

### 5.2 M370 编码

- 一个逻辑帧包含 370 bit。
- 网络/文本格式为 `M370:` + 93 个十六进制字符。
- 93 hex = 372 bit，最后 2 bit 为 padding。
- 扫描顺序：逻辑 row-major，按 `ROW_LENGTHS` 逐行连续编号。
- bit 顺序：每个 hex nibble 从高位到低位代表 4 个连续逻辑 LED。
- 固件内部存储为 packed bit array：`FRAME_BYTES = (370 + 7) / 8 = 47`。
- 固件 `runtimeFrameBits()` 中 bit 小端存放：`byteIndex = index >> 3`，`mask = 1 << (index & 7)`。

M370 解析必须：

- 接受有或无 `M370:` 前缀的输入。
- 忽略空格、`\r`、`\n`、`\t`。
- 非 hex 字符报错。
- 长度必须恰好 93 hex。
- 输出 normalized string：`M370:<93 uppercase hex>`。

WebUI 编码必须：

```js
function frameToM370(frame) {
  let bits = frame.slice(0, 370).map(v => v ? '1' : '0').join('') + '00';
  let out = '';
  for (let i = 0; i < bits.length; i += 4) {
    out += parseInt(bits.slice(i, i + 4), 2).toString(16).toUpperCase();
  }
  return 'M370:' + out.padEnd(93, '0').slice(0, 93);
}
```

### 5.3 蛇形物理映射

- `SERPENTINE_WIRING = true`
- `SERPENTINE_ODD_ROWS_REVERSED = true`

映射规则：

```cpp
static uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (logicalIndex >= LED_COUNT) return logicalIndex;
    if (!SERPENTINE_WIRING) return logicalIndex;

    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t rowStart  = ROW_OFFSETS[row];
        const uint8_t  rowLength = ROW_LENGTHS[row];
        if (logicalIndex < rowStart || logicalIndex >= rowStart + rowLength) continue;
        const uint16_t localX    = logicalIndex - rowStart;
        const bool     reverseRow = SERPENTINE_ODD_ROWS_REVERSED && ((row & 1U) != 0);
        return reverseRow ? rowStart + (rowLength - 1U - localX) : logicalIndex;
    }
    return logicalIndex;
}
```

启动时必须构建 `uint16_t logicalToPhysicalMap[370]`，渲染时使用该数组把逻辑 bit 写到物理灯带索引。

### 5.4 亮度与帧率

- 默认亮度：`50`
- 最小亮度：`10`
- 最大亮度：`200`
- 按钮步进：`8`
- M370 帧最小应用间隔：`33 ms`
- M370 队列深度：`3`
- WebUI 发送 M370 的最小间隔：`45 ms`
- LED render task：
  - core：`1`
  - stack：`6144`
  - priority：`3`

当前实现的亮度不是独立渐变动画。`setBrightness(raw)` 直接限制到 `[10, 200]`，写入 `runtimeState().brightness` 并请求渲染。`Adafruit_NeoPixel::setBrightness()` 只在渲染任务中检测到亮度变化时调用，避免重复缩放。

### 5.5 WS2812/BSS138 时序

因为数据线上可能经过 BSS138 电平转换，必须留出比 WS2812 最小复位时间更长的低电平窗口：

- `LED_SIGNAL_RESET_US = 300`
- `LED_RENDER_MIN_GAP_US = 2500`
- 两次 `strip.show()` 之间必须先补足 `LED_RENDER_MIN_GAP_US`。
- `strip.show()` 前后均 `delayMicroseconds(LED_SIGNAL_RESET_US)`。
- 启动清屏后保持：
  - `LED_BOOT_DATA_LOW_HOLD_MS = 20`
  - `LED_BOOT_CLEAR_HOLD_MS = 350`
  - `LED_BOOT_STARTUP_SETTLE_MS = 120`
- 停止滚动时全黑帧保持：
  - `LED_STOP_CLEAR_BLANK_HOLD_MS = 90`

## 6. 固件模块规格

### 6.1 `config.h/.cpp`

集中定义全部硬件、网络、矩阵、亮度、帧率、按钮、电源、文件路径常量。`config.cpp` 只定义 `IPAddress` 实例：

```cpp
const IPAddress AP_IP_ADDR(192, 168, 1, 14);
const IPAddress AP_GATEWAY_ADDR(192, 168, 1, 14);
const IPAddress AP_SUBNET_MASK(255, 255, 255, 0);
```

`config.h` 还必须声明 `extern` 访问器内联函数和文件路径常量：

```cpp
inline const IPAddress& apIP()      { return AP_IP_ADDR; }
inline const IPAddress& apGateway() { return AP_GATEWAY_ADDR; }
inline const IPAddress& apSubnet()  { return AP_SUBNET_MASK; }

constexpr char SAVED_FACES_PATH[]         = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[]            = "/resources/runtime_settings.json";
constexpr char BATTERY_CALIB_PATH[]       = "/resources/battery_calib.json";
constexpr char LITTLEFS_BASE_PATH[]       = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
```

注意：`SETTINGS_PATH` 是运行时设置文件的常量名（不是 `RUNTIME_SETTINGS_PATH`）。

`config.h` 还包含以下辅助常量（用于 LUT、队列 reason 字符串等），重建时不得省略：

```cpp
struct BatteryLutPoint { float voltage; uint8_t percent; };
constexpr BatteryLutPoint BATTERY_PERCENT_LUT[] = { ... };  // 见 6.9.6
constexpr uint8_t  BATTERY_PERCENT_LUT_SIZE = sizeof(BATTERY_PERCENT_LUT) / sizeof(...);
constexpr uint8_t  M370_FRAME_REASON_CHARS  = 64;   // QueuedM370Frame.reason 数组大小
```

以下常量在 config.h 中存在但为历史遗留（无活跃代码路径引用），重建时可保留注释说明：

```cpp
constexpr uint32_t BATTERY_CALIB_SHRINK_TIMEOUT_MS = 7UL * 24 * 3600 * 1000;  // 已废弃
constexpr uint32_t BATTERY_CALIB_SAVE_DELAY_MS     = 15000;  // 校准文件写防抖，power_monitor.cpp 使用
constexpr float    BATTERY_CALIB_SHRINK_STEP_V     = 0.02f;  // 已废弃
constexpr float    BATTERY_CALIB_MIN_SPAN_V        = 0.10f;  // 已废弃
```

`BATTERY_CALIB_SAVE_DELAY_MS` 是唯一仍被 `power_monitor.cpp` 引用的"遗留"常量（用于校准文件的 15 s 写防抖）。

### 6.2 `sync.h/.cpp`

创建三个 FreeRTOS mutex：

- `frameMutex`
- `scrollMutex`
- `hardwareBusMutex`

锁顺序约定为：

```text
HardwareBus -> Frame -> Scroll
```

当前渲染路径应尽量避免同时持有多个锁。必须提供：

- `initSyncPrimitives()`
- `lockFrame()/unlockFrame()`
- `lockScroll()/unlockScroll()`
- `lockHardwareBus()/unlockHardwareBus()`
- `withFrameLock(fn)`（模板辅助，`sync.h` 内联）
- `withScrollLock(fn)`（模板辅助，`sync.h` 内联）
- `withHardwareBusLock(fn)`（模板辅助，`sync.h` 内联）

当前 `sync.h` 中三个 `with*Lock` 是**返回 lambda 结果**的模板（`auto withFrameLock(Fn fn) -> decltype(fn())`），由 `ScopedLock` 在作用域内加锁、执行 `fn()`、析构时解锁，并把 `fn()` 的返回值透传给调用方。源码签名必须保持这一形态（见 §17.2 的 divergence 修正）：

```cpp
template <typename Fn>
auto withFrameLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Frame);
    return fn();
}
```

`ScopedLock` 持有 `SyncDomain`（`Frame` / `Scroll` / `HardwareBus`），构造即 `lockDomain()`，析构即 `unlockDomain()`，禁用拷贝/赋值。重建时不得退化成 `void` 返回，否则像 `bool changed = withFrameLock([&]{...})` 这类“锁内计算并返回”的调用点会编译失败或语义漂移。

```cpp
template <typename Fn>
void withFrameLock(Fn fn) {
    lockFrame();
    fn();
    unlockFrame();
}

template <typename Fn>
void withScrollLock(Fn fn) {
    lockScroll();
    fn();
    unlockScroll();
}

template <typename Fn>
void withHardwareBusLock(Fn fn) {
    lockHardwareBus();
    fn();
    unlockHardwareBus();
}
```

`hardwareBusMutex` 用于保护 LittleFS 文件操作和 `strip.show()`，避免 flash/文件系统 与硬件输出并发冲突。

### 6.3 `state.h/.cpp`

必须实现 `RuntimeStore` 单例，集中持有：

- `RuntimeState state_`
- `RuntimeFace autoFaces_[MAX_AUTO_FACES]`（128 个元素）
- `uint16_t autoFaceCount_`
- `uint8_t frameBits_[FRAME_BYTES]`（47 字节）
- `uint8_t* scrollFrameBits_`（指向 PSRAM 分配或内部 SRAM heap 回退分配）
- `bool scrollFrameBitsInPsram_`
- `bool fsMounted_`

启动时调用 `initRuntimeScrollFrameBuffer()`：

- 目标大小：`MAX_SCROLL_FRAMES * FRAME_BYTES = 3072 * 47 = 144384 bytes`。
- 如果 `ESP.getPsramSize() > 0`，用 `heap_caps_malloc(..., MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)`。
- 失败则回退到一次性内部 SRAM heap 分配：`heap_caps_malloc(..., MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)`。
- 清零整个滚动缓冲区。
- 如果 PSRAM 和内部 SRAM heap 都失败，`initRuntimeScrollFrameBuffer()` 返回 `false`，`runtimeScrollFrameBufferReady()` 返回 `false`，滚动路径必须跳过或返回 507。
- `runtimeScrollFrameBits(index)` 在 `index >= MAX_SCROLL_FRAMES` 或缓冲区不可用时返回 `nullptr`，正常情况下返回 `scrollFrameBits_ + index * FRAME_BYTES`。

`RuntimeFace` 结构体必须包含以下字段：

```cpp
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;   // 原始 JSON 数组下标，用于稳定排序的第二关键字
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};
```

`RuntimeState` 结构体必须完全映射当前实现中的如下定义，以覆盖颜色、动画和日志状态：

```cpp
struct RuntimeState {
    String   colorHex            = DEFAULT_COLOR;
    uint8_t  colorR              = 0xf9;
    uint8_t  colorG              = 0x71;
    uint8_t  colorB              = 0xd4;
    uint8_t  brightness          = DEFAULT_BRIGHTNESS;
    String   mode                = DEFAULT_MODE;
    String   playback            = DEFAULT_PLAYBACK;
    String   lastM370;
    String   lastReason          = "boot";
    bool     paused              = false;

    uint32_t framesAccepted      = 0;
    uint32_t framesRejected      = 0;
    uint32_t framesQueued        = 0;
    uint32_t framesDequeued      = 0;
    uint32_t framesDropped       = 0;
    uint32_t commandsAccepted    = 0;
    uint32_t commandsRejected    = 0;
    uint32_t savedFacesWrites    = 0;
    uint32_t settingsWrites      = 0;
    uint32_t bootMs              = 0;
    uint32_t stateVersion        = 1;
    bool     slowUiDirty         = false;
    uint32_t lastSlowUiPublishMs = 0;

    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     firmwareScrollUserPaused = false;
    bool     firmwareScrollSystemPaused = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};
```

`state.h` 必须声明以下自由函数（在 `state.cpp` 中实现）：

```cpp
RuntimeState& runtimeState();
RuntimeFace*  runtimeAutoFaces();
uint16_t&     runtimeAutoFaceCount();
uint8_t*      runtimeFrameBits();
bool          initRuntimeScrollFrameBuffer();
bool          runtimeScrollFrameBufferReady();
bool          runtimeScrollFrameBufferInPsram();
size_t        runtimeScrollFrameBufferBytes();   // 返回实际分配字节数
uint8_t*      runtimeScrollFrameBits(uint16_t index);
bool&         runtimeFsMounted();
uint32_t      runtimeStateVersion();
void          touchRuntimeState();
void          touchRuntimeStateSlow();
void          serviceRuntimeSlowStatePublish();  // 在 loop() 中每帧调用
```

状态版本：

- `touchRuntimeState()` 递增 `stateVersion`，溢出到 0 时改为 1。
- `touchRuntimeStateSlow()` 只标记 `slowUiDirty = true`。
- `serviceRuntimeSlowStatePublish()` 每 `POWER_WEB_SLOW_PUBLISH_MS = 10000` 才把 slow dirty 转为版本递增。

### 6.4 `led_renderer.h/.cpp`

必须实现以下职责：

1. `Adafruit_NeoPixel` 灯带初始化、清屏、渲染。
2. M370 解析与 packed bits 转换。
3. 370 bit 当前帧操作。
4. M370 帧率限制队列。
5. 颜色、亮度状态设置。
6. 中断安全的渲染请求标记与渲染任务通知。

#### 6.4.1 M370 帧队列

队列结构：

```cpp
struct QueuedM370Frame {
  uint8_t bits[FRAME_BYTES];
  char    m370[5 + M370_HEX_CHARS + 1];   // = 5+93+1 = 99 字节
  char    reason[M370_FRAME_REASON_CHARS]; // = 64 字节，常量定义于 config.h
  bool    hasM370;
};
```

行为：

- 如果队列为空且距离上次应用已超过 33 ms，立即发布。
- 否则入队。
- 队列满时丢弃最旧帧，把新帧写入其位置，并递增 `framesDropped`。
- 入队递增 `framesQueued`。
- 出队递增 `framesDequeued`。
- 真正发布时：
  - `memcpy(runtimeFrameBits(), packedBits, 47)`
  - 如果有 normalized M370，写入 `runtimeState().lastM370`
  - 写入 `lastReason`
  - `framesAccepted++`
  - `touchRuntimeState()`
  - 请求 LED 渲染。

`serviceM370FrameQueue()` 必须在 `loop()` 每次调用，用全局 33 ms 限速出队。

#### 6.4.2 渲染

`renderCurrentFrameToLedStrip()` 只能由 Core 1 渲染任务或启动同步渲染调用。为了绝对保真渲染时序，代码必须包含完整的底层映射和覆盖动画：

```cpp
void renderCurrentFrameToLedStrip() {
    uint8_t localFrame[FRAME_BYTES];
    static uint8_t overlayRgb[LED_COUNT * 3];
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    withFrameLock([&]() {
        memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
        brightness = runtimeState().brightness;
        colorR     = runtimeState().colorR;
        colorG     = runtimeState().colorG;
        colorB     = runtimeState().colorB;
    });

    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) {
            delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
        }
    }

    static uint8_t lastAppliedBrightness = DEFAULT_BRIGHTNESS;
    if (brightness != lastAppliedBrightness) {
        strip.setBrightness(brightness);
        lastAppliedBrightness = brightness;
    }

    const bool overlayActive = copyButtonAnimationOverlay(overlayRgb, LED_COUNT);
    if (overlayActive) {
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            const uint16_t offset = logical * 3U;
            strip.setPixelColor(logicalToPhysicalMap[logical],
                strip.Color(overlayRgb[offset], overlayRgb[offset + 1], overlayRgb[offset + 2]));
        }
    } else {
        const uint32_t rgb = strip.Color(colorR, colorG, colorB);
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            strip.setPixelColor(logicalToPhysicalMap[logical],
                packedFrameBit(localFrame, logical) ? rgb : 0);
        }
    }

    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    delayMicroseconds(LED_SIGNAL_RESET_US);
}
```

`ledStripBegin()` 必须：

- `strip.begin()`
- `strip.setBrightness(DEFAULT_BRIGHTNESS)`
- `strip.clear()`
- show 前 300 us，`hardwareBusMutex` 下 `strip.show()`，show 后 300 us。

### 6.5 `scroll.h/.cpp`

必须创建一个固定到 Core 1 的 FreeRTOS 任务：`led_scroll_render`。

任务循环每 1 ms 醒来，或者被 `notifyScrollRenderTask()` 唤醒。流程：

1. 读取并清除 `consumeLedRenderRequest()`，这是主任务写入帧后的高优先级渲染请求。
2. 如果固件文字滚动处于 active、未 paused、有 frameCount、buffer ready：
   - 检查 `millis() - lastScrollFrameMs >= scrollIntervalMs`。
   - 每个合格渲染周期只推进 **一帧**：`scrollFrameIndex = (scrollFrameIndex + 1) % scrollFrameCount`。
   - 正常抖动下 `lastScrollFrameMs += intervalMs`，保持节奏贴住间隔网格。
   - 长暂停后如果漂移超过 `interval * SCROLL_DRIFT_RESET_INTERVALS`（常量 `SCROLL_DRIFT_RESET_INTERVALS = 4`），则重置补偿机制，将 `lastScrollFrameMs = now`，防止累积的延迟瞬间倾泻。
   - 拷贝下一帧到局部 `nextFrame`，标记有滚动帧。
3. 若有滚动帧，进入 `frameMutex`：
   - 只有当文字滚动仍 active 且没有主任务帧抢占时，才写入 `runtimeFrameBits()`。
   - 主任务帧优先于滚动帧。
4. 如果需要渲染，调用 `renderCurrentFrameToLedStrip()`。
5. `ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1))`。

### 6.6 `faces.h/.cpp`

必须实现 manual/auto 模式、保存表情应用、自动播放和滚动停止恢复。

模式规则：

- `normalizedMode()` 接受 `auto/a/A` 与 `manual/m/M`，返回 `auto` 或 `manual`。
- `setMode("auto")`：
  - `mode = "auto"`
  - `playback = "auto_saved_face"`
  - `paused = false`
  - `lastAutoSwitchMs = millis()`
  - 如持久化，保存运行时设置。
- `setMode("manual")`：
  - `mode = "manual"`
  - 如果 playback 是 `auto_saved_face`，改回 `idle`
  - 如持久化，保存运行时设置。

保存表情：

- `applySavedFaceIndex(index, reason, playback)`：
  - 确保 saved faces 已加载。
  - `autoFaceIndex = index % autoFaceCount`
  - 可选写 playback。
  - 调用 `applyM370(face.m370, reason)`。
- B1/B2 使用相对 index，循环取模。
- `serviceAutoPlayback()` 在 `loop()` 调用：
  - 仅 `mode == auto`、未 paused、有 face 时运行。
  - 距离上次切换超过 `autoIntervalMs` 后 index+1，playback=`auto_saved_face`，apply 当前 face。

滚动停止恢复：

- `stopFirmwareScroll(restoreAuto, clearDisplay)`：
  - 清除 active/paused/restoreAutoAfterScroll/frameCount/frameIndex/lastScrollFrameMs/paused。
  - 如果 playback 是 scroll 类，改回 `idle`。
  - `clearDisplay=true` 时先 `applyBlankFrame("firmware_text_scroll_stop_clear")`，再安排延迟恢复启动默认表情。
  - 延迟恢复不得在 HTTP 处理函数中阻塞，必须由 `serviceDeferredFaceRestore()` 在 loop 中等 90 ms 后执行。

滚动暂停两级标志（`faces.h` 导出）：

- `setFirmwareScrollUserPaused(bool)`：用户级暂停，由 `/api/command` 的 `pause_scroll` / `resume_scroll` 调用。
- `setFirmwareScrollSystemPaused(bool)`：系统级暂停，由 `button_animations` 在 B6 电量覆盖层显示期间设置、覆盖层结束时清除。
- 两者任一为 true 时 `firmwareScrollPaused` 为 true；`stopFirmwareScroll()` 与重新 `startFirmwareScroll()` 时两个标志都清零。
- `/api/status` 的 renderer 和 scroll 类命令响应同时暴露 `firmwareScrollUserPaused` / `firmwareScrollSystemPaused`，供 WebUI 区分“用户暂停”与“覆盖层临时暂停”。

### 6.7 `buttons.h/.cpp`

按钮去抖与关键时间常数：

- `BUTTON_DEBOUNCE_MS = 25`
- B1/B2 长按（通过 `FACE_REPEAT_DELAY_MS` 和 `FACE_REPEAT_MS` 定义）：
  - `FACE_REPEAT_DELAY_MS = 650`
  - `FACE_REPEAT_MS = 350`
- B4/B5 长按（通过 `BRIGHTNESS_REPEAT_DELAY_MS` 和 `BRIGHTNESS_REPEAT_MS` 定义）：
  - `BRIGHTNESS_REPEAT_DELAY_MS = 450`
  - `BRIGHTNESS_REPEAT_MS = 120`

动作：

- B1：停止文字滚动/其他活动，`applyRelativeSavedFace(+1, "gpio_B1_next_saved_face")`。
- B2：停止文字滚动/其他活动，`applyRelativeSavedFace(-1, "gpio_B2_prev_saved_face")`。
- B3：松开时触发，切换 manual/auto；如果之前在 scroll/custom/parts/debug 类非表情播放状态，先空白帧，再延迟恢复当前表情。例外：GPIO 来源且固件文字滚动正在 active 且未 paused 时，`runButtonAction("B3","gpio")` 直接返回已处理，不切换模式、不停止文字滚动，只播放按钮反馈，用于避免 B3 在滚动播放中误打断时序。
- B4：亮度 `-8`，lastReason=`gpio_B4_brightness_down`。
- B5：亮度 `+8`，lastReason=`gpio_B5_brightness_up`。
- B3+B1：自动播放间隔 `-500 ms`。
- B3+B2：自动播放间隔 `+500 ms`。
- B6 不走普通 `runButtonAction()`；按钮服务每轮把 B6/B2/B3 消抖后的状态传给 `button_animations`。B6 电池覆盖层显示逻辑受 `BATTERY_SHORT_HOLD_MS = 2000` 与 `BATTERY_LONG_PRESS_MS = 700` 控制；短按显示电池百分比覆盖层，长按进入多页电源详情。长按触发条件必须是 `sAnim.b6Pressed && b6Pressed && !sAnim.b6LongFired && !b2Pressed && !b3Pressed && now - sAnim.b6PressedAtMs >= BATTERY_LONG_PRESS_MS`；因此 B2/B3 在当前实现中是长按抑制输入，不是附加页面切换键。充电时电池填充动画刷新。包含边界呼吸动画：`EDGE_FLASH_MS = 305`、`EDGE_ATTACK_MS = 45`、`EDGE_DECAY_MS = 260`。覆盖层显示期间若固件文字滚动正在播放，`button_animations` 通过 `setFirmwareScrollSystemPaused(true)` 暂停滚动，覆盖层结束后调用 `resumeScrollAfterOverlayIfNeeded()` 恢复。

如果 GPIO B1/B2/B3 中断固件文字滚动或滚动预览，必须写入：

- `scrollStopEventSeq++`
- `scrollStopEventMs = millis()`
- `scrollStopEventButton`
- `scrollStopEventSource`
- `scrollStopEventReason = lastReason`

WebUI 通过轮询读取这个事件，同步停止页面中的滚动控件。

### 6.8 `storage.h/.cpp`

LittleFS 挂载：

```cpp
LittleFS.begin(false, "/littlefs", 10, "littlefs")
```

必须实现原子 JSON 写：

1. 写入 `path + ".tmp"`。
2. `serializeJson(document, file)`。
3. `flush()` 和 `close()`。
4. `LittleFS.rename(tempPath, path)`。
5. 失败时删除 temp。

写任何 `/resources/` 路径的文件前，必须先调用静态辅助函数 `ensureResourcesDirectory()`，该函数检查并在必要时创建 `/resources` 目录（`LittleFS.mkdir`），避免首次烧录后目录缺失导致写入失败。`ensureResourcesDirectory()` 是 storage.cpp 内部静态函数，不需要在 storage.h 中导出。

运行时设置文件：

`/resources/runtime_settings.json`

```json
{
  "format": "rina_runtime_settings_v1",
  "version": 1,
  "mode": "manual",
  "autoIntervalMs": 3000,
  "updatedAtMs": 0
}
```

保存表情文件：

`/resources/saved_faces.json`

顶层 schema：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "m370HexChars": 93 },
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": "ISO string",
  "faces": []
}
```

单个表情：

```json
{
  "id": "face_01_surprised_winking_with_mouth",
  "name": "surprised / winking with mouth",
  "type": "default",
  "m370": "M370:<93 hex>",
  "order": 1,
  "editable": true,
  "deletable": false,
  "locked": true,
  "is_startup_default": false,
  "sourceFile": "saved_faces.json",
  "savedAt": "ISO string",
  "updatedAt": null,
  "call": null
}
```

校验规则：

- `category` 必须是 `unified_saved_faces`。
- `faces` 必须是数组。
- 每个表情的 `order` 必须是 1-based 且 >= 1。
- 必须保留至少一个 `type:"default"` 表情。
- `type:"default"` 且 id 形如 `face_<number>` 时，number 必须 >= 1。
- 如果 `m370` 非空，必须通过 M370 校验。

加载规则：

- 解析 JSON 时使用 PSRAM 优先的 `PsramJsonDocument`。
- 每个有效表情规范化 M370 后进入 `runtimeAutoFaces`。
- 最多加载 `MAX_AUTO_FACES = 128`。
- 稳定排序：先 `order`，再原 JSON index。
- 启动时优先选择 `startupDefaultId` 或 `is_startup_default`，否则第一个 default，否则第一个表情。
- `applyStartupFace=true` 时设置默认亮度、playback idle、paused false，然后应用启动表情。

### 6.9 `power_monitor.h/.cpp`

当前电源实现不是 I2C，也不是动态峰谷百分比学习。它是两个 ADC 输入：

- battery ADC：电池分压后的电压。
- charge ADC：外部充电/输入电压。

`power_monitor.h` 必须声明 `PowerStatus` 结构体（集中持有所有电源状态，通过 `servicePowerMonitor()` 更新），关键字段如下：

```cpp
struct PowerStatus {
    float    vbat             = NAN;
    float    vcharge          = NAN;
    uint8_t  batteryPercent   = 0;
    bool     charging         = false;
    bool     batteryValid     = false;
    bool     chargeValid      = false;
    bool     batteryDisconnected = false;
    bool     batteryLowVoltageUnpowered = false;
    float    batteryCalibMaxV = NAN;
    float    batteryCalibMinV = NAN;
    bool     batteryCalibLoaded = false;
    bool     batteryCalibDirty  = false;
    uint16_t batteryAdcMv     = 0;
    uint16_t batteryPrevAdcMv = 0;
    uint16_t batteryDisconnectDropMv = 0;
    float    batteryLastInstantVbat = NAN;
    uint16_t chargeAdcMv      = 0;
    uint32_t lastBatteryMs    = 0;
    uint32_t lastChargeMs     = 0;
    uint32_t batteryDisconnectedSinceMs = 0;
    uint32_t lastBatteryDisconnectEventMs = 0;
    bool     batteryPrevAdcKnown = false;
    uint32_t lastCalibMaxMs   = 0;
    uint32_t lastCalibMinMs   = 0;
    uint32_t batteryCalibDirtySinceMs = 0;
    uint32_t lastWebSlowPublishMs = 0;
    float    webPublishedVbat     = NAN;
    float    webPublishedVcharge  = NAN;
    uint8_t  webPublishedBatteryPercent = 255;
    bool     webPublishedBatteryValid   = false;
    bool     webPublishedChargeValid    = false;
    bool     webPublishedCharging       = false;
    bool     webPublishedChargingKnown  = false;
    bool     webFastDirty               = true;
    bool     webSlowDirty               = true;
};
```

`/api/power` 的响应字段（见 6.11.6）直接映射到上述字段及衍生计算值。

#### 6.9.1 校准与换算

电池：

- `BATTERY_CAL_SCALE = 2.708333`
- `BATTERY_CAL_OFFSET_V = 0.2033`
- `instantVbat = adcMv / 1000.0 * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V`

充电输入：

- `CHARGE_CAL_SCALE = 6.684982`
- `CHARGE_CAL_OFFSET_V = 0.0712`
- `instantVcharge = adcMv / 1000.0 * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V`

分压电阻与 ADC 校准关键常量必须匹配以下实际代码：

- **电池 ADC 分压与校准**：`BATTERY_DIVIDER_R1_K` (100.0f), `BATTERY_DIVIDER_R2_K` (57.0f), `BATTERY_CAL_SCALE` (2.708333f), `BATTERY_CAL_OFFSET_V` (0.2033f)
- **充电 ADC 分压与校准**：`CHARGE_DIVIDER_R1_K` (270.0f), `CHARGE_DIVIDER_R2_K` (47.0f), `CHARGE_CAL_SCALE` (6.684982f), `CHARGE_CAL_OFFSET_V` (0.0712f)
- **特定电压阈值**：`BATTERY_EMPTY_V` (6.2f), `BATTERY_FULL_V` (8.0f), `BATTERY_UNPOWERED_LOW_V` (5.0f), `CHARGE_PRESENT_V` (4.0f)
- **WebUI 发布节流（EPS）**：`POWER_WEB_SLOW_PUBLISH_MS` (10000), `POWER_WEB_VBAT_EPS_V` (0.01f), `POWER_WEB_VCHARGE_EPS_V` (0.05f)

#### 6.9.2 采样周期

- 电池采样周期：`BATTERY_SAMPLE_MS = 1000` ms。
- 充电输入采样周期：`CHARGE_SAMPLE_MS = 1000` ms。
- 采样过滤：每次连续读取 `POWER_ADC_SAMPLES = 16` 个样本，排序后去掉最高和最低 `POWER_ADC_TRIM_COUNT = 4` 个样本后取平均。
- `servicePowerMonitor(force=false)` 每次 loop 调用，按周期决定是否采样。
- `initPowerMonitor()`：
  - 加载 `/resources/battery_calib.json`
  - 设置校准默认值
  - 设置 ADC 分辨率/衰减
  - 强制采样一次。

#### 6.9.3 电池 EMA

电池使用按真实时间差计算 alpha 的 EMA。`BATTERY_EMA_TAU_S` 和 `CHARGE_EMA_ALPHA` **定义在 `power_monitor.cpp` 文件作用域**，不在 `config.h`：

```cpp
// power_monitor.cpp 顶部
constexpr float BATTERY_EMA_TAU_S = 20.0f;
constexpr float CHARGE_EMA_ALPHA  = 0.20f;
```

EMA 计算：

```cpp
dtS = constrain((now - lastBatteryMs) * 0.001f, 0.001f, 10.0f);
emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
vbat = vbat * (1.0f - emaAlpha) + instantVbat * emaAlpha;
```

首次有效读数或从断电/低压状态恢复时，`vbat = instantVbat`。

不得因为大电压下跌直接绕过 EMA；这样会让 LED 大电流瞬间拉低电量显示，当前实现特意删除该行为。

#### 6.9.4 充电输入 EMA

充电输入使用固定 alpha（见上方 `CHARGE_EMA_ALPHA = 0.20f` 定义于 `power_monitor.cpp`）。但插入/拔出边沿必须瞬间吸附到 `instantVcharge`，避免充电状态延迟数秒。

`charging = vcharge > CHARGE_PRESENT_V`（即 `> 4.0f`，常量定义于 `config.h`）。

#### 6.9.5 电池断开/未供电检测

常量：

- `BATTERY_UNPOWERED_LOW_V = 5.0`
- `BATTERY_DISCONNECT_ADC_DROP_MV = 1000`
- `BATTERY_DISCONNECT_ADC_LOW_MV = 900`
- `BATTERY_RECONNECT_ADC_MV = 1500`

判定（旁路 EMA 过滤器）：

- 如果上次 ADC 已知，且 `prevAdcMv - adcMv >= BATTERY_DISCONNECT_ADC_DROP_MV`，并且 `adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV`，认为电池被物理拔出，瞬间跌落，触发断开逻辑而不经过 EMA 延迟。
- 如果已经断开且 `adcMv < 1500`，保持 disconnected。
- 只要检测到 charger present，充电状态覆盖视觉“未供电”状态，不进入断开显示。
- 如果 instantVbat < 5.0 且无 charger，认为 lowVoltageUnpowered。
- disconnected 或 lowVoltageUnpowered 时：
  - `vbat = 0.0`
  - `batteryPercent = 0`
  - `batteryValid = true`
- 标记 Web slow dirty。

#### 6.9.6 电量百分比 LUT

必须使用固定 2S LiPo 分段线性 LUT。为了保证四舍五入和边界安全，必须按照下述代码实现：

```cpp
static uint8_t batteryPercentFromVoltage(float vbat) {
    if (!isfinite(vbat)) return 0;
    const uint8_t n = BATTERY_PERCENT_LUT_SIZE;
    if (vbat >= BATTERY_PERCENT_LUT[0].voltage)     return 100;
    if (vbat <= BATTERY_PERCENT_LUT[n - 1].voltage) return 0;

    for (uint8_t i = 0; i + 1 < n; ++i) {
        const float vHi = BATTERY_PERCENT_LUT[i    ].voltage;
        const float vLo = BATTERY_PERCENT_LUT[i + 1].voltage;
        if (vbat < vHi && vbat >= vLo) {
            const float pHi = static_cast<float>(BATTERY_PERCENT_LUT[i    ].percent);
            const float pLo = static_cast<float>(BATTERY_PERCENT_LUT[i + 1].percent);
            const float t   = (vbat - vLo) / (vHi - vLo);
            return static_cast<uint8_t>(lroundf(pLo + t * (pHi - pLo)));
        }
    }
    return 0;
}
```

高于第一点限制到 100，低于最后一点限制到 0，中间线性插值并四舍五入。显示百分比有 1% 死区：只有新值与旧值差超过 1，或首次有效读数，才更新 `batteryPercent`。

#### 6.9.7 Flash 校准文件

`/resources/battery_calib.json`：

```json
{
  "format": "rina_battery_calibration_v1",
  "version": 1,
  "v_max": 8.0,
  "v_min": 6.2,
  "v_max_nominal": 8.0,
  "v_min_nominal": 6.2
}
```

当前 `v_min/v_max` 只用于诊断和手动 reset API，不用于动态百分比学习。`reset_battery_min`、`reset_battery_max` 会写入当前安全值或标称值，并立刻保存。

#### 6.9.8 Web 发布节流

- 充电状态变化为快速 dirty，立即 `touchRuntimeState()`。
- 慢字段变化每 10000 ms 发布一次，除非强制刷新。
- 慢字段 epsilon：
  - vbat：0.01 V
  - vcharge：0.05 V

### 6.10 `web_json.h/.cpp`

为 `/api/scroll` 的大 JSON body 提供轻量字段提取，避免整包反序列化造成内存压力。必须实现：

- `findJsonStringEnd(body, quotePos)`：识别 escape。
- `extractJsonStringAt(body, quotePos, value, endQuote)`：支持基本 JSON string escape。
- `jsonBoolField(body, key, defaultValue)`
- `jsonUintField(body, key, value)`
- `jsonFloatField(body, key, value)`
- `jsonStringField(body, key, value)`

仅用于已知扁平字段和 frames array 手动扫描，不替代通用 JSON 解析器。

### 6.11 `web_api.h/.cpp`

必须使用 Arduino `WebServer server(80)` 与 `DNSServer dnsServer`。

#### 6.11.1 AP 与 DNS

`startAccessPoint()`：

- `WiFi.mode(WIFI_AP)`
- `WiFi.softAPConfig(apIP(), apGateway(), apSubnet())`
- `WiFi.softAP(AP_SSID, AP_PASSWORD)`
- `dnsServer.setTTL(60)`
- `dnsServer.start(53, "rina.io", WiFi.softAPIP())`

#### 6.11.2 静态资源

静态资源从 LittleFS 提供：

- `/` 和 `/index.html` 映射到 `/index.html`。
- 任意 GET 未命中路由时尝试 `serveStaticFile(server.uri())`。
- 如果客户端 `Accept-Encoding` 含 gzip 且存在 `path + ".gz"`，优先服务 `.gz`。
- 如果只有 `.gz` 无 raw，也服务 `.gz`。
- `.gz` 响应头：
  - `Content-Encoding: gzip`
  - `Vary: Accept-Encoding`
- HTML：`Cache-Control: no-cache`
- 非 HTML 静态资源：`Cache-Control: public, max-age=31536000, immutable`
- 所有静态资源加 `Access-Control-Allow-Origin: *`。
- API 响应必须 `Cache-Control: no-store`。

分块流式传输：

- `STATIC_STREAM_CHUNK_BYTES = 8192`
- 尝试从 heap 分配 8KB 缓冲区，失败则回退到 512B 栈缓冲区。
- 每发送 4 个分块后 `vTaskDelay(1)` 喂 watchdog。
- 文件操作包裹 `hardwareBusMutex`。

LittleFS 挂载失败：

- LED 前 12 颗显示红色错误图案。
- Web 请求返回内联 HTML 503，提示运行 `pio run -t uploadfs`。

#### 6.11.3 CORS/OPTIONS

API 响应头：

- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`
- `Cache-Control: no-store`

所有 API 的 OPTIONS 返回 204。

#### 6.11.4 路由表

必须注册：

| 路由 | 方法 | 行为 |
|---|---|---|
| `/` | GET | 服务 `/index.html` |
| `/index.html` | GET | 服务 `/index.html` |
| `/api/status` | GET/OPTIONS | 完整或摘要状态 |
| `/api/power` | GET/OPTIONS | 电源完整状态 |
| `/api/frame` | POST/OPTIONS | 接收单帧 M370 |
| `/api/scroll` | 不限定方法注册；处理函数内部只接受 POST/OPTIONS | 接收仅 RAM 的滚动帧分块，`server.on("/api/scroll", handleApiScroll)` 后由处理函数自查 method |
| `/api/command` | POST/OPTIONS | 统一辅助命令 |
| `/api/saved_faces` | 不限定方法注册；处理函数内部只接受 GET/POST/OPTIONS | 表情 JSON 读写，`server.on("/api/saved_faces", handleApiSavedFaces)` 后由处理函数自查 method |
| 未命中路由 | GET | 静态文件回退 |

#### 6.11.5 `/api/status`

查询参数：

- `runtimeOnly=1`：只返回 AP、power、renderer、memory，不返回 matrix/endpoints/storage/stats/lastM370。
- `summary=1` 或 `noFrame=1`：跳过 lastM370，减小响应。
- `fullPower=1`：即使慢速 power 字段未 dirty 也包含完整 power 慢字段（无 `since` 时默认包含）。
- `since=<version>`：如果 version 未变，返回：

```json
{
  "ok": true,
  "v": 123,
  "version": 123,
  "unchanged": true,
  "next_poll_ms": 1000
}
```

完整响应顶层：

```json
{
  "ok": true,
  "v": 1,
  "version": 1,
  "next_poll_ms": 1000,
  "device": "RinaChanBoard",
  "uptimeMs": 0,
  "ap": {},
  "power": {},
  "renderer": {},
  "memory": {},
  "matrix": {},
  "endpoints": {},
  "storage": {},
  "stats": {}
}
```

`ap`：

- `ssid`
- `ip`
- `domain`
- `url`
- `clients`

`renderer`：

- color、brightness、brightnessMin、brightnessMax
- mode、playback、paused
- autoIntervalMs、autoFaceCount、autoFaceIndex、autoFaceId、autoFaceName
- firmwareScrollActive、firmwareScrollPaused、firmwareScrollUserPaused、firmwareScrollSystemPaused、restoreAutoAfterScroll
- deferredFaceRestoreActive
- scrollFrameCount、scrollFrameIndex、scrollIntervalMs、scrollMaxFrames
- m370FrameMinIntervalMs、m370FrameQueueDepth、m370FrameQueueCount
- lastM370 + lit，或 lastM370Skipped/lastM370Deferred
- lastReason
- scrollStopEvent：seq/ms/button/source/reason

`memory`：

- freeHeap
- psramSize
- freePsram
- scrollBufferBytes
- scrollBufferReady
- scrollBufferInPsram

`matrix`：

- leds=370
- m370HexChars=93
- gpio=2
- m370BitOrder=`logical_row_major`
- physicalWiring=`serpentine`
- serpentineOddRowsReversed=true

`endpoints`：frame、command、scroll、savedFaces、power、status。

`storage`：

- mounted
- savedFacesPath
- savedFacesExists
- settingsPath
- settingsExists
- totalBytes/usedBytes，除非 summary 或正在滚动。

`stats`：所有 RuntimeState 统计字段。

#### 6.11.6 `/api/power`

先 `servicePowerMonitor()`，返回：

```json
{
  "ok": true,
  "power": { "...": "full power fields" }
}
```

`power` 字段至少包括：

- partial
- chargeGpio、batteryGpio
- charging、chargeValid、batteryValid、ok
- chargeIconClass、chargeIconColor
- batteryIconClass、batteryIconColor、batteryStateText
- batteryPowered、batteryDisconnected、batteryLowVoltageUnpowered
- vbat、vcharge、batteryPercent
- batteryAdcMv、batteryPrevAdcMv、batteryDisconnectDropMv
- batteryDisconnectDropThresholdMv、batteryDisconnectLowThresholdMv、batteryReconnectThresholdMv
- batteryUnpoweredLowThreshold
- batteryLastInstantVbat
- batteryDisconnectedSinceMs、lastBatteryDisconnectEventMs
- chargeAdcMv
- batteryRangeMin、batteryRangeMax、batteryNominalMin、batteryNominalMax
- batteryCalibLoaded、batteryCalibDirty、batteryCalibPath
- chargeThreshold、batterySampleMs、chargeSampleMs、slowPublishMs
- lastBatteryMs、lastChargeMs、lastCalibMaxMs、lastCalibMinMs

#### 6.11.7 `/api/frame`

请求：

```json
{
  "m370": "M370:<93 hex>",
  "mode": "idle",
  "reason": "api_frame",
  "faceId": "optional_saved_face_id"
}
```

行为：

- 缺少 m370 返回 400。
- 如果 mode 不是 scroll 类，先 `stopFirmwareScroll(false)`。
- 如果 reason 以 `custom_` 或 `parts_` 开头，`setMode("manual", false)`。
- `runtimeState().playback = mode`。
- `applyM370(m370, reason)`。
- 如果 `faceId` 匹配保存表情，更新 `autoFaceIndex`，保证 B1/B2 后续从当前表情继续。

响应：

- ok、v/version、next_poll_ms
- accepted=true
- queued、queueDepth、queueCount、frameMinIntervalMs
- leds、color、brightness、reason、mode、autoIntervalMs、autoFaceIndex
- autoFaceId/autoFaceName
- m370、lit

#### 6.11.8 `/api/scroll`

请求必须 POST：

```json
{
  "frames": ["M370:<93 hex>", "..."],
  "stepLedPerFrame": 1,
  "start": false,
  "append": false,
  "chunkIndex": 0,
  "chunkFrames": 24,
  "totalFrames": 120,
  "source": "webui_text_scroll_frames_only",
  "storage": "ram",
  "persist": false,
  "saveToFlash": false,
  "fps": 10,
  "intervalMs": 100
}
```

行为：

- 只支持 RAM：如果 `persist=true`、`saveToFlash=true` 或 `storage` 不是空/`ram`，返回 400。
- `append=false`：停止已有文字滚动，清空 frameCount/frameIndex。
- `append=true`：从当前 `scrollFrameCount` 继续写入。
- 手动扫描 frames array，逐个字符串解析为 packed bits，写入 `runtimeScrollFrameBits(targetIndex)`。
- 超过 `MAX_SCROLL_FRAMES=3072` 返回 413。
- 任意非法 M370 返回 400，并清空 `scrollFrameCount`。
- 如果 `start=true`，调用 `startFirmwareScroll(intervalMs)`。

响应：

- ok
- frames：当前缓存总帧数
- chunkFrames、chunkIndex、totalFrames、append
- started
- source
- storage=`ram`
- persist=false
- saveToFlash=false
- mode、playback、restoreAutoAfterScroll
- scrollIntervalMs、scrollMaxFrames
- stepLedPerFrame=1

#### 6.11.9 `/api/command`

统一请求：

```json
{ "cmd": "set_brightness", "payload": { "brightness": 80 } }
```

支持命令：

| cmd | payload | 行为 |
|---|---|---|
| `set_color` | `{ "hex": "#RRGGBB" }` | 设置当前颜色并渲染 |
| `set_brightness` | `{ "raw": 80 }` 或 `{ "brightness": 80 }` | 设置亮度 |
| `set_mode` | `{ "mode": "manual|auto" }` | 设置模式 |
| `set_auto_interval` | `{ "ms": 3000 }` | 设置自动播放间隔 |
| `set_scroll_interval` | `{ "intervalMs": 100 }` 或 `{ "fps": 10 }` | 改滚动间隔 |
| `start_scroll` | `{ "intervalMs": 100 }` 或 `{ "fps": 10 }` | 从 RAM 缓存启动滚动 |
| `scroll_step` | `{ "direction": 1 }`（可选，<0 后退一帧，默认 +1） | 手动前进/后退一帧：更新 `scrollFrameIndex`，playback=`scroll_step`，清空 M370 队列后立即渲染该帧 |
| `pause_scroll` | `{}` | 用户级暂停：`setFirmwareScrollUserPaused(true)` |
| `resume_scroll` | `{}` | 用户级恢复：`setFirmwareScrollUserPaused(false)`（system pause 仍生效时不恢复播放） |
| `stop_scroll` | `{ "clear": true, "restoreAuto": true }` | 停止滚动，可清屏和恢复 auto |
| `pause` | `{}` | 暂停当前播放 |
| `resume` | `{}` | 恢复 |
| `button` | `{ "button": "B1" }` | 执行按钮动作 |
| `terminate_other_activities` | `{ "targetMode": "face|scroll|..." }` | 为 WebUI 页面切换清理其他活动 |
| `reset_battery_min` | `{}` | 重置最低电压记录 |
| `reset_battery_max` | `{}` | 重置最高电压记录 |

响应包含当前核心运行时状态，字段与 `/api/frame` 类似，并含 scrollStopEvent。电池 reset 命令还必须附带完整 power。

#### 6.11.10 `/api/saved_faces`

GET：

- 如果 LittleFS 未挂载，503。
- 如果文件不存在，404。
- 直接流式返回 `/resources/saved_faces.json`。

POST：

请求可以是完整 saved faces 文档，也可以是：

```json
{
  "document": { "...": "saved_faces document" },
  "path": "/resources/saved_faces.json",
  "reason": "save_user_face"
}
```

行为：

- 解析 JSON，使用 nesting limit 32。
- `document` 不存在时把整个 body 当 document。
- 运行 `validateSavedFaces()`。
- 原子写入 `SAVED_FACES_PATH`。
- 重新 `loadSavedFaces(false)`。

响应：

- ok
- v/version
- path
- requestPath
- reason
- bytes
- writes

### 6.12 `button_animations.h/.cpp`

> 本模块在 §6 早期版本中缺失（仅在 §6.6/§6.7 旁述提到 B3/B4/B5/B6 覆盖层），但 `button_animations.cpp` 是固件端**最大的动画/渲染子系统**（约 777 行）。它在 LED 矩阵上叠加按钮反馈、电量页和边沿提示，并在覆盖层期间临时系统级暂停文字滚动。重建时此模块的几何映射、缓动曲线和状态机必须逐字保真，否则覆盖层会错位、闪烁或破坏滚动节奏。

职责：

1. 维护单实例 `AnimationState sAnim`（受 `portMUX_TYPE sAnimMux` 临界区保护，可被 GPIO 路径并发访问）。
2. 把覆盖层渲染成 `LED_COUNT*3` 字节的 RGB 缓冲；`led_renderer.cpp` 在 `renderCurrentFrameToLedStrip()` 中调用 `copyButtonAnimationOverlay()`，若覆盖层 active 则用覆盖层像素覆盖基础帧。
3. 覆盖层活跃时通过 `setFirmwareScrollSystemPaused(true)` 暂停滚动，结束时清除。

**坐标系与几何**（必须保真，覆盖层用 22×18 网格，逐行居中映射到蛇形逻辑 index）：

- 网格常量：`COLS = 22`、`ROWS = 18`。
- `xyToLogical(x,y)`：每行按 `ROW_LENGTHS[y]` 居中，`leftPad = (COLS - rowLength)/2`；落在 pad 外返回 `-1`，否则返回 `ROW_OFFSETS[y] + (x - leftPad)`。这保证覆盖层文字/图标与物理矩阵的居中行对齐。
- `putPixel()` 写入 `out[logical*3 + {0,1,2}]`；`drawBitmap()` 遍历 `'#'` 像素调用 `putPixel`。

**覆盖层种类**（`enum class OverlayKind { None, Mode, Interval, Brightness, Battery }`）与触发：

- `Mode`（B3）：绘制 10×13 大字形 `BIG_A`/`BIG_M`（auto/manual），原点 `(6,2)`，色 `MODE_COLOR = {180,0,255}`。
- `Interval`（B3+B1 / B3+B2）：`CLOCK_ICON` + `formatInterval()` 文本（如 `"3.0S"`、满 10 秒为 `"10S"`），色 `MODE_COLOR`。
- `Brightness`（B4/B5）：`SUN_ICON` + `brightnessPercent()`（`round(raw*100/MAX_BRIGHTNESS)`）拼 `"%u%%"`，色 `BRIGHTNESS_COLOR = {0,120,255}`。
- `Battery`（B6 短按单次显示 / B6 长按循环）：`drawBatteryPage()`。
- 时间常量：`FLASH_HOLD_MS = 1000`、`EDGE_FLASH_MS = 305`、`EDGE_ATTACK_MS = 45`、`EDGE_DECAY_MS = 260`、`BATTERY_SHORT_HOLD_MS = 2000`、`BATTERY_LONG_PRESS_MS = 700`、`BATTERY_PHASE_MS = 2000`、`BATTERY_REFRESH_MS = 100`、`BATTERY_ANIM_REFRESH_MS = 50`。

**边沿提示（边沿闪烁）缓动**：当 interval/brightness 已到达上/下限时，在矩阵顶/底行画一条带缓动的提示线：攻击/衰减包络 × 以列中心 `x=10.5` 为峰的空间衰减 `max(0.20, 1 - dist/10.5)`。精确实现见 §17.4.11。

**电量页状态机**（B6）：

- B6 **松开**前未触发长按 → `startBatteryOverlay(singleShot=true)`，显示 `BATTERY_SHORT_HOLD_MS` 后自动结束。
- B6 **按住** ≥ `BATTERY_LONG_PRESS_MS` 且 B2/B3 未同时按下 → `startBatteryOverlay(singleShot=false)`，循环分页直到松开。
- 充电中（`chargeValid && charging`）分 3 页（百分比 / 电压 V / 充电电压），否则 2 页；每 `BATTERY_PHASE_MS` 轮换，并以 `BATTERY_ANIM_REFRESH_MS`（充电）或 `BATTERY_REFRESH_MS` 刷新。
- 电量颜色 `batteryColor()`：≤10% 红，10–30% 红→橙插值，30–50% 橙→绿插值，>50% 纯绿；填充列数 `batteryFillCols()` 把 10–90% 映射到 0–8 列。充电时电池图标做扫描式填充动画。

**字形 / 图标资源**（重建时必须逐字保留，定义于匿名 namespace）：5×7 字形 `GLYPH_0..9`、`GLYPH_S`、`GLYPH_V`、`GLYPH_DOT`(宽1)、`GLYPH_PCT`(宽3)；大字形 `BIG_A`/`BIG_M`(10×13)；图标 `CLOCK_ICON`/`SUN_ICON`/`BATTERY_ICON`(22×18)。`glyphFor(ch)` 是字符→`{rows,width}` 的查表；`drawText()` 居中排版（字间距 `GAP=1`，电压布局在第 3 字后多插 1 列），`y0 = hasIcon ? 9 : 5`。

**与滚动/渲染的耦合**：`serviceButtonAnimations()`（loop 调用）按到期/分页/刷新节奏调用 `requestLedRender()` 或 `stopOverlay()`；`serviceButtonAnimationButtonInputs()` 由 `buttons.cpp` 喂入 B6/B2/B3 实时电平以判定长按；覆盖层不写 `runtimeFrameBits()`，只在渲染时叠加，因此覆盖层结束后基础帧无需重建即恢复。

公开 API（`button_animations.h`）：`startButtonAnimationForGpioAction(code)`、`handleButtonAnimationGpioPress/Release(code)`、`serviceButtonAnimationButtonInputs(b6,b2,b3)`、`serviceButtonAnimations()`、`copyButtonAnimationOverlay(rgbOut, ledCount)`。

## 7. 启动流程

`setup()` 必须按以下顺序：

1. 复位后立即压低 LED 数据线：`pinMode(LED_PIN, OUTPUT)`、`digitalWrite(LED_PIN, LOW)`、`delay(LED_BOOT_DATA_LOW_HOLD_MS)`、`delayMicroseconds(LED_SIGNAL_RESET_US)`；随后 `Serial.begin(115200)`，`delay(200)`。
2. `runtimeState().bootMs = millis()`。
3. `initRuntimeScrollFrameBuffer()`。
4. `initSyncPrimitives()`，失败打印日志。
5. `initLedIndexMap()`。
6. `ledStripBegin()`，清屏 latch。
7. `delay(LED_BOOT_CLEAR_HOLD_MS)`。
8. `setColorStateNoRender(DEFAULT_COLOR)`。
9. `mountFilesystem()`。
10. 如果 mount 失败，`showFilesystemErrorPattern()`。
11. 如果 mount 成功：
    - `loadRuntimeSettings()`
    - `loadSavedFaces(true)`
12. 同步 `renderCurrentFrameToLedStrip()`，确保启动第一帧是保存表情。
13. `consumeLedRenderRequest()`，清掉 loadSavedFaces 留下的任务渲染请求，避免重复渲染。
14. `delay(LED_BOOT_STARTUP_SETTLE_MS)`。
15. `startScrollRenderTask()`。
16. `initHardwareButtons()`。
17. `initPowerMonitor()`。
18. `startAccessPoint()`。
19. `startWebServer()`。

`loop()` 必须每次调用：

```cpp
serviceM370FrameQueue();
webServerTick();
serviceRuntimeSlowStatePublish();
serviceHardwareButtons();
serviceButtonAnimations();
servicePowerMonitor();
serviceDeferredFaceRestore();
serviceAutoPlayback();
vTaskDelay(pdMS_TO_TICKS(1));
```

## 8. WebUI 架构

当前 WebUI 是 `data/index.html` + `data/styles.css` + `data/app.js`，不使用构建工具，不依赖 npm。`index.html` 只声明 DOM 与稳定 id/class，`app.js` 是外置浏览器运行时。

### 8.1 顶层配置

`WEBUI_CONFIG` 必须包含：

```js
faces: {
  resourcePath: '/resources/saved_faces.json',
  localFilename: 'saved_faces.json',
  schemaFormat: 'rina_faces_370_v2',
  startupFaceId: 'face_07_triangle_eyes_frown'
}
device: {
  apSsid: 'RinaChanBoard-V2',
  apPassword: 'rinachan',
  apDomain: 'rina.io',
  defaultApIp: '192.168.1.14'
}
navigation: {
  pages: [
    ['basic', '6.1', '基础功能'],
    ['custom', '6.2', '自定义表情'],
    ['parts', '6.3', '表情部件'],
    ['scroll', '6.4', '文字滚动'],
    ['debug', '6.5', '调试']
  ]
}
led: {
  defaultColor: '#f971d4',
  defaultBrightness: 50,
  minBrightness: 10,
  maxBrightness: 200,
  estimatedWattsPerChannel: 0.06,
  channelCount: 5,
  fullBrightness: 255,
  powerWarningWatts: 40,
  previewSize: { defaultCell: 18, minCell: 5, maxCell: 48, minWidth: 320, maxHeight: 500, edgeGap: 12 }
}
autoInterval: {
  minMs: 500,
  maxMs: 10000,
  buttonStepMs: 500,
  presetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000]
}
api: {
  getTimeoutMs: 2500,
  postTimeoutMs: 5000,
  uploadTimeoutMs: 15000,
  bootStatusTimeoutMs: 2500,
  runtimeStatusQuery: '?runtimeOnly=1&noFrame=1',
  endpoints: {
    frame: '/api/frame',
    command: '/api/command',
    scroll: '/api/scroll',
    savedFaces: '/api/saved_faces',
    power: '/api/power',
    status: '/api/status'
  }
}
layout: {
  oneColumnMaxPx: 980,
  threeColumnsMinPx: 1471
}
firmwareQueues: {
  m370SendIntervalMs: 45,
  m370QueueMax: 3,
  buttonCommandIntervalMs: 120,
  buttonCommandQueueMax: 4,
  scrollButtonStopFullSyncDelayMs: 140
}
scroll: {
  defaultFps: 10,
  fpsMin: 1,
  fpsMax: 60,
  fpsPresets: [1, 10, 20, 30, 40, 50, 60],
  firmwareMaxFramesDefault: 3072,
  uploadChunkFrames: 24,
  maxTextChars: 1000
}
textScroll: {
  fontModel: 'ark_pixel_12px_fusion_bitmap_v4',
  fontResource: '/resources/fonts/ark12.json',
  fontFamily: 'Ark Pixel 12px Monospaced',
  fontFallbackFamily: '',
  browserFontSample: 'RinaChanBoard 370 LED 继续 暂停 こんにちは 璃奈ちゃんボード 然燃滚滾 🏠︎😀︎',  // 末尾含 VS15 文本变体 emoji 样本
  browserFallbackFontSample: '',
  charSpacing: 0,
  spaceColumns: 6,
  missingGlyphCodePoint: 0x25A1
}
fonts: {
  uiFamily: 'GNU Unifont'
}
interaction: {
  buttonPressDownMs: 90,
  buttonPressUpMs: 150,
  selectMenuHideDelayMs: 260,
  pageScrollKeys: ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Home', 'End', ' ']
}
boot: {
  loadingIconBefore: './resources/loading/rina_icon1_default.png',
  loadingIconAfter: './resources/loading/rina_icon2_hover.png',
  holdMs: 260,
  haloBreathMs: 1620,
  haloPeakRatio: 0.5,
  haloToleranceMs: 24,
  haloContractMs: 520,
  imageReleaseMs: 2100,
  blurDurationMs: 850,
  extraMs: 180,
  minDisplayMs: 400,
  firstPageRevealSelector: [
    '.sidebar',
    '#page-basic .hero',
    '#page-basic .basic-preview-card',
    '#page-basic .control-panel > .card.control-section'
  ]
}
power: {
  statusRefreshMs: 900
}
```

注意：`WEBUI_CONFIG.faces.startupFaceId` 当前 HTML 回退值是 `face_07_triangle_eyes_frown`，但运行时 `saved_faces.json` 顶层 `startupDefaultId` 是 `face_08_triangle_eyes_frown`，且固件和 WebUI 在已加载表情库后优先采用文件里的 `startupDefaultId`。

### 8.2 HTML 文档结构

#### 8.2.1 `<html>` 与 `<head>`

```html
<html data-boot-phase="preload" data-scroll-lock="boot" lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Rina WebUI V2</title>
  <link type="image/png" rel="preload" href="/resources/loading/rina_icon1_default.png" as="image">
  <link type="image/png" rel="icon" href="/resources/loading/rina_icon1_default.png">
  <link type="image/png" rel="shortcut icon" href="/resources/loading/rina_icon1_default.png">
  <link rel="stylesheet" href="styles.css?v=20260612-emoji-input-v3">
  <!-- hover image 和 ark12 字体 **不** 在 <head> 预加载，由 JS lazy load -->
</head>
```

`data-boot-phase` 生命周期：`"preload"` → `"ui-ready"` → `"ready"`。

`data-boot-phase="preload"` 期间，CSS 应隐藏所有应用内容（`body>*:not(.loading-overlay) { visibility: hidden }`）。

`data-ui-font-loaded`（`true|false`）和 `data-scroll-font-loaded`（`true|false|unsupported`）动态写入 `<html>` 元素，供调试和选择器使用。

`data-first-page-reveal` 在瀑布揭示准备阶段暂时设为 `"preparing"` 再删除，用于抑制 boot-reveal-item 的过渡动画。

#### 8.2.2 App 壳结构

```html
<body>
  <!-- 加载覆盖层（必须是 body 的第一个直接子元素） -->
  <div class="loading-overlay is-assets-pending" id="loadingOverlay" role="status" aria-live="polite" aria-label="页面加载中">
    <div class="blur-screen" id="blurScreen" aria-hidden="true"></div>
    <div class="loading-box">
      <div class="loader-stage">
        <div class="flash-halo" aria-hidden="true"></div>
        <div class="avatar-circle">
          <img class="avatar-before" id="avatarBefore" src="./resources/loading/rina_icon1_default.png" alt="" height="96" width="96">
          <img class="avatar-after"  id="avatarAfter" data-src="./resources/loading/rina_icon2_hover.png" alt="" height="96" width="96">
        </div>
      </div>
      <div class="loading-text">Loading</div>
    </div>
  </div>

  <aside class="sidebar">
    <!-- Brand bar 是 body 的直接子元素，不包在 .app 内 -->
    <div class="brand">
      <div class="brand-copy">
        <h1>RinaChanBoard 370 V2</h1>
        <div class="row">
          <span class="badge mono"><span class="status-dot"></span> 运行中</span>
          <span class="badge" id="badge-battery">
            <span class="status-dot dim" id="badge-battery-dot"></span>
            <span id="badge-battery-label">-- %</span>
          </span>
          <span class="badge" id="badge-charging">
            <span class="status-dot dim" id="badge-charging-dot"></span>
            <span id="badge-charging-label">充电 --</span>
          </span>
        </div>
      </div>
      <!-- 导航覆盖层的汉堡按钮 -->
      <button class="brand-nav-toggle" id="brand-nav-toggle" type="button"
              aria-controls="top-page-nav" aria-expanded="false" aria-label="打开页面切换器">
        <span class="menu-icon" aria-hidden="true">
          <span></span><span></span><span></span>
        </span>
      </button>
    </div>
  </aside>

  <!-- 导航覆盖层是 body 的直接子元素，位于 .app 之前，z-index 高于 sidebar 和内容 -->
  <div class="top-page-nav" id="top-page-nav" aria-hidden="true">
    <div class="nav-shell" id="nav-shell">
      <div class="nav" id="nav" aria-hidden="true" role="menu">
        <!-- 5 个 <button type="button" data-page="id" role="menuitem">
             <span>name</span><span class="num">num</span></button>
             由 initNav() 动态生成 -->
      </div>
    </div>
  </div>

  <!-- App shell 只包 main content -->
  <div class="app">
    <!-- Main content area -->
    <main class="content">
      <section class="page active" id="page-basic">  <!-- 基础 --></section>
      <section class="page"        id="page-custom"> <!-- 自定义 --></section>
      <section class="page"        id="page-parts">  <!-- 部件 --></section>
      <section class="page"        id="page-scroll"> <!-- 滚动 --></section>
      <section class="page"        id="page-debug">  <!-- 调试 --></section>
    </main>
  </div>
  <script src="app.js?v=20260612-step-buttons-v4"></script>
</body>
```

`document.body.dataset.page` 在 `switchPage()` 时设为当前页 id（如 `'basic'`），供 CSS `body[data-page="debug"]` 等选择器使用。

#### 8.2.3 隐藏文件输入

自定义页和部件页的表情管理面板各需要一个隐藏文件输入用于 JSON 导入：

```html
<input class="faces-json-import-file" type="file" accept="application/json" hidden>
```

### 8.3 页面导航

必须实现 5 个页面，顶部导航按钮动态生成：

| id | 页面 | 模式 |
|---|---|---|
| `basic` | 6.1 基础功能 | `face` |
| `custom` | 6.2 自定义画板 | `custom` |
| `parts` | 6.3 部件拼脸 | `parts` |
| `scroll` | 6.4 文本滚动 | `scroll` |
| `debug` | 6.5 调试/电源 | `debug` |

`switchPage(id)` 行为：

- 更新 `body.dataset.page`、`.page.active` 类、`#nav button[data-page]` 的 `.active` 状态。
- 调用 `terminateOtherActivities(modeForPage(id), "switch_page_<id>")`，再切换页面。
- 更新 `#brand-nav-toggle` 的 `.active`、`aria-expanded`、`aria-label`、`title`，并用 `setNavMenuOpen(false)` 关闭导航菜单。
- 切换到 `'scroll'` 时调用 `ensureScrollFontsLoaded()`，然后在 `requestAnimationFrame` 中调用 `autoResizeScrollTextInput()` 和 `updateScrollUi()`。
- 切换到 `'custom'` / `'parts'` 时在 `requestAnimationFrame` 中自动调整对应 M370 textarea 高度。
- 切换到 `'debug'` 时调用 `setupDebugMasonryLayout(true)` + `refreshPowerStatusFromFirmware('debug_page_enter', true)`。
- 切换到 `'basic'` 时调用 `syncRuntimeStateFromFirmware('basic_page_enter')` + `refreshPowerStatusFromFirmware('basic_page_enter', true)`。
- 切换离开 scroll/custom/parts/debug 时调用 `terminateOtherActivities(targetMode)` 清理活动状态。

`initNav()` 必须动态生成 `PAGES = [['basic','6.1','基础功能'], ...]` 的按钮，按钮内容为 `<span>${name}</span><span class="num">${num}</span>`。菜单打开时 `.top-page-nav.open`、`.nav.open`、`.brand-nav-toggle.active` 同步，`topNav.inert = !open`，关闭时所有导航按钮 `tabIndex=-1`。点击文档空白处或按 Escape 关闭菜单。

### 8.4 加载覆盖层动画

HTML 结构见 8.2.2。

#### 8.4.1 动画常量（来自 `WEBUI_CONFIG.boot`）

| 常量 | 值 | 说明 |
|---|---|---|
| `HOLD_MS` | 260 | ring contract + image pop 之后到 final-release 的延迟 |
| `HALO_BREATH_MS` | 1620 | halo 呼吸动画完整周期 (ms)，与 CSS `animation-duration: 1.62s` 对齐 |
| `HALO_PEAK_RATIO` | 0.5 | 峰值在周期的哪个比例处 → peak at 810 ms |
| `HALO_TOL_MS` | 24 | 认为已在峰值的时间窗口 |
| `HALO_CONTRACT_MS` | 520 | 与 CSS `--rina-halo-contract-duration: 520ms` 对齐 |
| `IMG_RELEASE_MS` | 2100 | 与 CSS `--rina-image-release-duration: 2100ms` 对齐 |
| `IMG_SHRINK_MS` | `Math.round(IMG_RELEASE_MS * 0.18)` = 378 | 从 `is-final-release` 到开始 `animateReveal()` 的延迟 |
| `BLUR_DUR_MS` | 850 | 径向渐变 reveal rAF 循环总时长 |
| `EXTRA_MS` | 180 | 两处用到：(1) 在 `max(IMG_RELEASE_MS, IMG_SHRINK_MS + BLUR_DUR_MS)` 后等待隐藏；(2) 在 `is-hidden` 后设置 `overlay.hidden = true` |
| `BOOT_MIN_DISPLAY_MS` | 400 | 最短显示时间（从动画开始） |

#### 8.4.2 加载 IIFE 结构

整个加载覆盖层动画封装在一个立即执行的 IIFE 中，暴露以下全局接口：

```js
window.rinaLoaderComplete          // = requestFinish，完成后调用
window.rinaLoadingImagesReadyPromise // = preloadInitialLoadingImage()，default 图 decode 后 resolve
window.rinaStartLoaderAnimation    // async：先 await rinaLoadingImagesReadyPromise，再 initOverlay() 启动动画
window.rinaLoaderStartedAt         // = haloCycleStart（performance.now() 的动画开始时间）
```

#### 8.4.3 关键函数

**`lockLoaderCenter()` / `syncLoaderCenter()`**：读取视口尺寸（`firstViewportCenter()`），将 `--rina-loader-x` 和 `--rina-loader-y` CSS 变量设为实际视口中心（px）。在 `resize`、`visualViewport.resize`、`visualViewport.scroll` 上监听，通过 `scheduleLoaderCenterSync()` 在 `requestAnimationFrame` 中更新；`doFinish()` 开始后置 `loaderCenterFrozen = true` 冻结中心点。

**`delayToPeak(now)`**：
```js
function delayToPeak(now) {
  const phase = ((now - haloCycleStart) % HALO_BREATH_MS + HALO_BREATH_MS) % HALO_BREATH_MS;
  let d = HALO_BREATH_MS * HALO_PEAK_RATIO - phase;
  if (Math.abs(d) <= HALO_TOL_MS) return 0;
  if (d < 0) d += HALO_BREATH_MS;
  return d;
}
```

**`animateReveal()`**：
- 先把 `--rina-reveal-radius` 复位为 `0px`，给 `blurScreen` 加 `is-revealing` 类，给覆盖层加 `is-scroll-passthrough`，调用 `unlockBootPageScroll()`。
- `setOrigin()` 把 `--rina-reveal-x/--rina-reveal-y` 写为 loader 中心在模糊层内的坐标，并返回原点。
- 启动 `requestAnimationFrame` 循环，持续 `BLUR_DUR_MS` ms。
- 用自定义缓动 `eic(t)` = `t<0.5 ? 4t³ : 1 - (-2t+2)³/2`（ease-in-cubic-like）。
- `maxR = getMaxR(origin)` = 中心到 surface 四角距离的最大值 + 90（`getMaxR(center = revealCenterInSurface())`）。
- 每帧只更新一个 CSS 变量：`--rina-reveal-radius = maxR * eic(t)`（保留两位小数带 `px`）。
- 通过 CSS `mask-image` 的两段 radial-gradient（transparent 到 `--rina-reveal-radius`，`#000` 从 `radius + --rina-reveal-edge` 开始，edge 默认 `1px`，见 9.5 节）产生从中心向外扩散的圆形揭示。当前实现不再使用早期的 7 变量羽化渐隐方案。

**`doFinish()`**（全程带 `timelineSeq` 序列号防过期）：
```
1. 等待 hover image decode（preloadAfterLoadingImage()）；loaderCenterFrozen = true
2. 同时添加 is-ring-contracting + is-image-pop
3. 并行调度（不阻塞）：HALO_CONTRACT_MS (520ms) 后添加 is-halo-hidden
4. await HOLD_MS (260ms) → 添加 is-final-release
5. 并行调度：IMG_SHRINK_MS (378ms) 后调用 animateReveal()
6. await max(IMG_RELEASE_MS, IMG_SHRINK_MS+BLUR_DUR_MS) + EXTRA_MS
   → 覆盖层添加 is-hidden
7. await EXTRA_MS → overlay.hidden = true, 移除 is-animating, unlockBootPageScroll()
```

**`requestFinish()`**：调用 `delayToPeak(performance.now())`，等待到最近的 halo 呼吸峰值后调用 `doFinish()`。

**`initOverlay()`**（`= window.rinaStartLoaderAnimation`）：
- 记录 `window.rinaLoaderStartedAt = performance.now()`。
- 给覆盖层添加 `is-assets-ready is-animating`，移除所有其他动画 class。
- 记录 `haloCycleStart = performance.now()`。

#### 8.4.4 启动序列 JS

```
bootstrapWebUi() 入口（document.readyState 检查后）
  └─ await window.rinaStartLoaderAnimation() // 启动 halo 呼吸并等待首张 loading 图 decode
  └─ prepareFirstPageProgressiveReveal()     // 给 basic 页元素加 boot-reveal-item
  └─ await ensureWebUiFontReady()            // GNU Unifont 必须在首屏瀑布揭示前就绪
  └─ initFirstPageUiBeforeShow()             // 绑定事件、初始化基础控件/颜色/select/nav
  └─ initializeBasicPreviewMatrix()          // 只先初始化 basic 矩阵
  └─ renderFirstPageUiBeforeShow()           // 同步渲染颜色/亮度/状态
  └─ showBootUiBehindLoader()                // data-boot-phase="ui-ready"
  └─ revealFirstPageWaterfall()              // 顺序逐元素加 is-revealed（间隔 115ms，最后 260ms）
  └─ preloadFirmwareRuntimeState()           // reveal 后、loader 仍显示时 GET /api/status?runtimeOnly=1&noFrame=1
  └─ waitForBootLoaderMinimum()              // 等 BOOT_MIN_DISPLAY_MS
  └─ finishBootVisibility()                  // data-boot-phase="ready", rinaLoaderComplete()
  └─ initDeferredUiAfterShow()               // 初始化剩余矩阵、部件页、自定义页、滚动页、调试页
  └─ await runtimePingPromise                // 等 runtime 快照稳定
  └─ startFirmwareStatusPolling()            // 启动 500ms tick
  └─ startPowerStatusPolling()               // 启动 1000ms tick
  └─ runPostBootDeferredReads()              // 页面已显示后加载表情库、同步预览、预热 ark12.woff2
```

瀑布揭示的元素选取使用 `FIRST_PAGE_REVEAL_SELECTOR`（见 8.1），按 `getBoundingClientRect().top` 排序，再按 `left` 二次排序。

### 8.5 LED 预览矩阵

必须在页面中至少创建以下矩阵：

- `matrix-basic`
- `matrix-custom-edit`
- `matrix-parts`
- `matrix-scroll`
- `matrix-debug`

矩阵使用 DOM 单元格，不用 canvas。每个有效 LED 生成 cell，无效位置留空或不生成。支持：

- 当前帧显示。
- 自定义页可点击编辑（`attachDrawing()` 挂载 click 事件到 `.matrix` 元素，切换对应单元格的 `editFrame[index]`）。
- 部件页展示拼脸结果。
- 滚动页展示当前滚动帧。
- 调试页展示测试图案。

WebUI 必须同时构建：

- `XY_TO_INDEX[y][x]`
- `INDEX_TO_XY[index]`
- `PHYSICAL_TO_LOGICAL_INDEX`

`logicalToPhysicalIndex()` 必须与固件蛇形映射一致。

`MATRIX_VIEW_CONFIGS` 数组描述每个矩阵视图的初始化参数，每项为 `[id, frameProvider, editable, editHandler, compact]`：

```js
const MATRIX_VIEW_CONFIGS = [
  ['matrix-basic',       () => currentFrame, false, null, false],
  ['matrix-custom-edit', () => editFrame,    true,  editCell, false],
  ['matrix-parts',       () => partsFrame,   false, null, false],
  ['matrix-scroll',      () => scrollFrame,  false, null, false],
  ['matrix-debug',       () => currentFrame, false, null, false],
];
```

#### 矩阵自适应缩放（fitMatrix）

每个矩阵包裹在 `.matrix-wrap` 元素中，CSS 变量控制尺寸。`fitMatrix(view)` 使用以下算法：

```js
// 从 computed style 读取配置
const cfg = CSS custom props on .matrix-wrap:
  --matrix-default-cell, --matrix-min-cell, --matrix-max-cell,
  --matrix-max-height, --matrix-edge-gap

// 宽度预算（父元素可用宽度）
const edgeRatioRaw = parseFloat(wrapStyle.getPropertyValue('--led-preview-edge-ratio'));
const edgeRatio = Number.isFinite(edgeRatioRaw) && edgeRatioRaw >= 0 ? edgeRatioRaw : 0.1000;
const cellByWidth = (widthBudget - gap * (COLS - 1)) / (COLS + 2 * edgeRatio);

// 高度预算（视口高度减去上方兄弟元素高度之和）
const heightBudget = Math.min(configuredMaxHeight, viewportHeight - chromeHeight);
const cellByHeight = (heightBudget - gap * (ROWS - 1)) / (ROWS + 2 * edgeRatio);

// 取较小值，clamp 到 [min, max]
const cell = clamp(Math.min(cellByWidth, cellByHeight), minCell, maxCell);
wrap.style.setProperty('--cell', cell + 'px');
```

`observeMatrixWraps()` 使用 `ResizeObserver` 监听 `.matrix-wrap,.led-preview-card,.debug-measure-card`，任何矩阵包装层、预览卡片或 debug 测量卡片尺寸变化时都调用 `scheduleMatrixFitRender(2)` → 在 `settleFrames` 帧后执行 `fitAllMatrices()` 与 `renderMatrices()`（防抖）。如果浏览器没有 `ResizeObserver`，仍要注册 `resize`、`orientationchange`、`visualViewport.resize` 与 `visualViewport.scroll` 作为回退。

注意：`WEBUI_CONFIG.led.previewSize.edgeGap = 12` 是遗留配置字段，当前实现的真实等比边界留白由 CSS 变量 `--led-preview-edge-ratio` 控制；`styles.css` 的默认值为 `.1000`。`fitMatrix()` 每次根据 `cell * edgeRatio` 写回当前 `.matrix-wrap` 的 `--matrix-edge-gap`。

### 8.6 基础页

控件：

- 顶部状态徽章：见 8.2.2（badge-battery-dot、badge-battery-label、badge-charging-dot、badge-charging-label）
- 颜色：
  - `#color-input`（`<input type="text">` 宽度约 7 字符，`#RRGGBB` 格式）
  - `#color-swatch`（可点击的颜色方块，点击触发 native color picker 或打开颜色选择）
  - `#parent-color-select`（角色大类 `<select>`，包裹在自定义 select shell 内）
  - `#child-color-select`（具体颜色 `<select>`，包裹在自定义 select shell 内）
- 亮度：
  - `#brightness-range`
  - `#brightness-input`
  - `#brightness-reset-default`
  - `#brightness-minus`
  - `#brightness-plus`
  - `#brightness-presets` 内的预设按钮
- 表情/模式：
  - `#face-prev`
  - `#face-next`
  - `#mode-toggle`
  - 自动播放间隔：`#auto-interval-range`、`#auto-interval`
  - `#interval-down`、`#interval-up`
  - `#auto-interval-presets` 内的预设按钮
- 预览：`#matrix-basic`

按钮点击应优先通过 `/api/command` 的 `button` 命令进入固件按钮逻辑，失败时才做本地回退。

#### 颜色预设系统

颜色面板提供两级联动下拉：`#parent-color-select`（角色大类，6 组，id 0–5）→ `#child-color-select`（具体颜色，5 个子色组共 67 个条目；id 0 的“默认璃奈粉色”仅提供父级色，无子色组）。

数据结构（内联于 JS，完整字面值见 §15.4）：

```js
// 每个父组：{ id, name, color（不带 # 的 hex）, desc }
const parent_color_groups = [
  { id: 0, name: '默认璃奈粉色', color: 'f971d4', desc: '父级颜色按钮，仅提供父级色' },
  { id: 1, name: "μ's-洋红色",  color: 'e4007f', desc: "μ's 子颜色组" },
  // ... id 2..5：Aqours / 虹咲学园 / Liella! / 蓮ノ空
];
// 以父组 id 为 key，每个子色为 ['颜色名', 'RRGGBB']（不带 #）
const child_color_groups = {
  1: [['高坂穗乃果-橙色', 'f38500'], /* ... */],
  // ... 2..5
};
```

`syncColorDropdownsToHex(hex)` 在固件状态同步时将 hex 值反查回对应 parent/child 选项；查找失败时不修改下拉状态。

颜色下拉的选项条目具有 `style="--option-color: #RRGGBB"` CSS 变量，自定义 select 选中项用该变量显示彩色高亮。

### 8.7 自定义页

控件：

- `#custom-send`：发送当前画板。
- `#custom-live-toggle`：实时发送开关。
- `#custom-clear`：清空。
- `#custom-fill`：全亮。
- `#custom-invert`：反转。
- `#custom-m370`：M370 文本。
- `#custom-copy`
- `#custom-import`
- `#custom-save`
- `#custom-name`
- 表情管理器通用控件：读取、打开本地、保存到本地、下载、导入。

行为：

- 点击/拖动画板修改 `editFrame`。
- `sendCustomFrame()` 发送 `/api/frame`，reason 默认 `custom_face_send`。
- 实时发送打开时，编辑后排队发送，受 WebUI M370 队列限速。
- 保存自定义表情时写入 `userFaces`，type=`custom`，随后 `persistFaceDocuments('save_user_face')`。

### 8.8 部件拼脸页

必须包含内联 `EXPRESSION_PARTS` 数据：

- 格式：`rina_expression_parts_370_runtime_v4`
- 版本：4
- matrix：cols 22、rows 18、num_leds 370、row_lengths、row_valid_x_ranges、serpentine。
- 布局：
  - 左眼：x=2,y=1,w=8,h=8
  - 右眼：x=12,y=1,w=8,h=8
  - 嘴：x=7,y=9,w=8,h=8
  - 左脸颊：x=2,y=9,w=4,h=4, mirror_x=true
  - 右脸颊：x=16,y=9,w=4,h=4
- 调用字段：`leye`、`reye`、`mouth`、`cheek`
- 默认表情：
  - leye=101
  - reye=201
  - mouth=301
  - cheek=400
- ids：
  - leye：`0,101..127`
  - reye：`0,201..227`
  - mouth：`0,301..332`
  - cheek：`400..405`
- 部件：每个 part 至少包含 `name`、`size`、`row_hex` 或 `preview`。

控件：

- `#parts-apply`
- `#parts-live-toggle`
- `#parts-random`
- `#parts-reset`
- `#parts-symmetry-toggle`
- `#part-groups`
- `#parts-m370-text`
- `#parts-copy-m370`
- `#parts-import-m370`
- `#parts-save-bottom`
- `#parts-name`

行为：

- 选择部件后合成 `partsFrame`。
- 对称模式打开时，左右眼同步到同编号序列。
- 应用时发送 `/api/frame`，reason `parts_face_apply` 或类似 `parts_` 前缀。
- 保存时写入 type=`parts`，并在 `call` 字段保存 selectedCall。

### 8.9 文本滚动页

控件：

- `#scroll-text`，`<textarea>`，maxlength=1000。
- 帧率 fps 控件组：
  - `#scroll-speed`，FPS 数字输入，整数，仅允许 1..60。
  - `#scroll-speed-range`，FPS 滑条（min=1，max=60，step=1，默认 10），input 时与数字框双向同步。
  - `#scroll-speed-minus` / `#scroll-speed-plus`，−5 / +5 步进按钮。
  - `#scroll-speed-reset-default`，重置为默认帧率（10 fps）。
  - `#scroll-speed-presets`，FPS 预设按钮容器（由 `fpsPresets` 生成）。
- `#scroll-play`（发送）
- `#scroll-pause`（`toggle-button`，带 `aria-pressed`，初始 disabled；点击走 `togglePauseScroll()`：userPaused 时 resume，否则 pause，250 ms `pauseToggleLocked` 防抖；仅 systemPaused 时点击不生效）
- `#scroll-stop`（停止/清屏）
- `#scroll-step-prev` / `#scroll-step-next`，逐帧步进按钮。必须按当前源码字面值绑定：`setScrollStepHandler("scroll-step-prev", 1)`、`setScrollStepHandler("scroll-step-next", -1)`；`advanceScroll(true, direction)` 中 `direction < 0` 后退，否则前进，所以当前 UI 文案“上一帧/下一帧”和发送方向存在反向字面值。重建当前版本时不得擅自纠正这个绑定，除非同步改代码、文案与本计划。
- `#scroll-upload-progress`
- `#scroll-upload-bar`
- `#scroll-upload-label`
- `#scroll-state`
- `#scroll-frame-index`
- 预览：`#matrix-scroll`

字体：

- UI 字体：CSS 内联 GNU Unifont 子集 data URI。
- 滚动字体：`/resources/fonts/ark12.woff2`（浏览器预览字体）与 `/resources/fonts/ark12.json`（栅格化器位图字形表）。`ark12_fallback.woff2` 已废弃并从项目删除。
- WebUI 必须懒加载 `ark12.json`。
- 字体模型 `ark_pixel_12px_fusion_bitmap_v4`（Ark Pixel 基础字形 + 融合 CJK 补丁 + Mona12 单色 emoji）。
- 缺字回退 codepoint：`0x25A1`。

文本滚动算法：

1. 输入文本截断到 1000 字符。
2. 对每个 Unicode 字符：
   - 查 `arkPixelFont.glyphs`。
   - 缺字使用缺字 glyph。
   - 空格使用 `spaceColumns = 6`。
3. 构建一个位图：
   - 前导空白 = `COLS + 4`
   - 尾随空白 = `COLS + 4`
   - charSpacing = 0
4. 对 offset 从 0 到 `source.width - COLS`：
   - 从位图提取当前 22x18 非矩形窗口。
   - 只写 row_valid_x_ranges 内的 LED。
   - 每步移动 1 LED。
5. 限制帧数 <= 固件 `scrollMaxFrames`，默认 3072。
6. 每帧转 `M370`。
7. 按 24 帧一包上传 `/api/scroll`：
   - 第一包 `append=false`
   - 后续 `append=true`
   - 所有包 `start=false`
   - `storage='ram'`
   - `persist=false`
   - `saveToFlash=false`
8. 所有包上传完成后，POST `/api/command`：

```json
{
  "cmd": "start_scroll",
  "payload": {
    "fps": 10,
    "intervalMs": 100,
    "source": "webui_text_scroll_after_frames"
  }
}
```

文本栅格化前必须先过滤 emoji 格式控制符：`isEmojiFormatControl(cp)` 剔除 VS15/VS16（U+FE00–FE0F）、ZWJ（U+200D）、肤色修饰符（U+1F3FB–1F3FF）和 tag 字符（U+E0000–E007F）；emoji 字形本身按全宽汉字 advance 渲染（由 `ark12.json` 字形表提供）。

暂停/恢复/停止/步进必须通过 `/api/command` 对应命令（step 带 `direction: ±1`）。WebUI 通过 `/api/status` 的 `firmwareScrollUserPaused` / `firmwareScrollSystemPaused`（拆分暂停标志）同步本地 `scroll.userPaused` / `scroll.systemPaused`；旧固件无这两个字段时回退到单一 paused。停止时：

- WebUI 本地先恢复启动默认表情预览。
- 固件执行 `stop_scroll` 可清屏并延迟恢复。
- 如果 GPIO B1/B2/B3 中断滚动，WebUI 轮询到 `scrollStopEventSeq` 变化后必须停止滚动控件，并延迟 20 ms 或 140 ms 进行完整状态同步。

### 8.10 调试页

必须包含：

- 状态 KV：`#state-kv`
- 功耗警告：`#dps-warning`，估算超过 40W 显示。
- 图案按钮：
  - `#debug-all-off`
  - `#debug-all-on`
  - `#debug-checker`
  - `#debug-border`
  - `#debug-current-face`
- M370：
  - `#debug-m370`
  - `#debug-apply-m370`
  - `#debug-copy-status`
  - `#debug-reset-storage`
- 电源：
  - `#debug-refresh-power`
  - `#debug-reset-battery-min`
  - `#debug-reset-battery-max`
  - `#battery-v`
  - `#charge-v`
  - `#update-adc`
- 调试预览：`#matrix-debug`
- 日志：
  - `#serial-input`
  - `#serial-send`
  - `#log-clear`
  - `#log-download`
  - `#log`
- 固件状态：
  - `#firmware-kv`
  - `#firmware-ping`
  - `#firmware-pause`
- 资源状态：
  - `#resource-kv`

#### KV 面板详细字段

**`#state-kv`**（12 行）：

| key | 值 |
|---|---|
| 当前模式 | `state.mode` |
| 当前表情序号 | `faceIndex+1 / library.length` |
| 当前表情名称 | `currentFace.name` |
| 当前表情属性 | `faceTypeLabel(currentFace.type)` |
| 当前亮度 | `brightness/255` |
| 当前颜色 | `state.color` |
| 当前播放状态 | `state.playback` |
| 当前 AP 域名 | `state.apDomain` |
| 当前 AP IP | `state.apIp` |
| 刷新策略 | `state.refreshPolicy` |
| 最近刷新原因 | `state.lastRefreshReason` |
| 刷新计数 | `state.refreshCount` |

**`#debug-kv`**（25 行）：

| key | 值 |
|---|---|
| LED 数量 | `TOTAL_LEDS` |
| 矩阵 | `22x18 / 不规则 370` |
| M370 长度 | `93 hex + M370:` |
| 亮度原始值 | `state.brightness` |
| DPS 状态 | `active / inactive` |
| 播放状态 | `state.playback` |
| 文字滚动 | `active / inactive` |
| 实际 FPS | `state.actualFps.toFixed(1)` |
| 电池状态 | `batteryPowerText()` |
| 低压未上电锁定 | `是 / 否` |
| Vbat | `formatVolts(batteryV) / formatBatteryPercent(batteryPercent)` |
| 电池瞬时电压 | `formatVolts(batteryLastInstantVbat)` |
| 未上电电压阈值 | `formatVolts(batteryUnpoweredLowThreshold)` |
| 电池最低电压记录 | `formatVolts(batteryMinV)` |
| 电池最高电压记录 | `formatVolts(batteryMaxV)` |
| 电池 ADC 原始值 | `formatMilliVolts(batteryAdcMv)` |
| 上次电池 ADC 原始值 | `formatMilliVolts(batteryPrevAdcMv)` |
| 断电快速压降 | `dropMv / 阈值 thresholdMv` |
| 断电低 ADC 阈值 | `formatMilliVolts(batteryDisconnectLowThresholdMv)` |
| 恢复 ADC 阈值 | `formatMilliVolts(batteryReconnectThresholdMv)` |
| Vcharge | `formatVolts(chargeV) / formatChargingState(charging)` |
| 充电 ADC 原始值 | `formatMilliVolts(chargeAdcMv)` |
| AP SSID | `DEVICE_AP_SSID` |
| AP 密码 | `DEVICE_AP_PASSWORD` |
| AP 域名 | `state.apDomain` |

**`#resource-kv`**（16 行）：

| key | 值 |
|---|---|
| JSON 格式 | `EXPRESSION_PARTS.format` |
| 版本 | `EXPRESSION_PARTS.version` |
| stored_unique_parts | `EXPRESSION_PARTS.counts.stored_unique_parts` |
| callable_ids | `EXPRESSION_PARTS.counts.callable_ids` |
| eye_left | `counts.stored_by_group.eye_left` |
| eye_right | `counts.stored_by_group.eye_right` |
| mouth | `counts.stored_by_group.mouth` |
| cheek | `counts.callable_by_group.cheek` |
| default_faces | `defaultFaces.length` |
| user_saved_faces | `userFaces.length` |
| interface_mode | `HTML generates M370 / firmware receives commands` |
| face_library_json | `firmware.savedFacesPath` |
| physical_wiring | `serpentine / odd rows reversed` 或 `linear` |
| parts_compose | `m370 logical row-major canonical` |
| parts_eye_symmetry | `on / same display index` 或 `off` |
| preview_scale | `smooth fractional --cell live scaling / card horizontal-min vertical-max fit` |

**`#firmware-kv`**（11 行）：

| key | 值 |
|---|---|
| online | `✓ connected` 或 `✗ offline` |
| lastRequest | `firmware.lastRequest` |
| lastStatus | `firmware.lastStatus` |
| lastError | `firmware.lastError` |
| sentFrames | `firmware.sentFrames` |
| sentCommands | `firmware.sentCommands` |
| frameQueue | `firmware.frameQueue / WEBUI_M370_QUEUE_MAX` |
| buttonQueue | `firmware.buttonQueue / WEBUI_BUTTON_COMMAND_QUEUE_MAX` |
| droppedFrames | `firmware.droppedFrames` |
| droppedCommands | `firmware.droppedCommands` |
| savedFacesSync | `firmware.savedFacesSync` |

`kvRows(rows)` 辅助函数：将 `[[key, value], ...]` 映射为 `<span class="k">key</span><span>value</span>` 拼接字符串，渲染于 `.kv` 网格中。

#### Debug GPIO 按钮（未实现占位符）

HTML 中有 `data-gpio="B1"` 到 `data-gpio="B6B3"` 的按钮，无 JS 绑定。这是未实现功能的占位符，重建时保留但无需添加处理逻辑。

#### Debug 瀑布流布局算法

`setupDebugMasonryLayout(force)` 使用贪心最短列算法：

```js
// 列数由视口宽度决定
function responsiveColumnCount() {
  const w = document.documentElement.clientWidth || window.innerWidth;
  if (w <= 980)  return 1;
  if (w >= 1471) return 3;
  return 2;
}

function setupDebugMasonryLayout(force = false) {
  const layout = document.querySelector('#page-debug .debug-layout');
  // 首次运行时记录初始卡片列表并用 data-debug-order 标记稳定顺序
  if (!debugLayoutCards.length) {
    debugLayoutCards = [...layout.querySelectorAll('.debug-column > .card, :scope > .card')];
    debugLayoutCards.forEach((card, i) => card.dataset.debugOrder = String(i));
  }
  const cards = debugLayoutCards.filter(c => layout.contains(c));
  const count = responsiveColumnCount();
  if (!force && debugLayoutColumnCount === count && /* 已有正确列数 */ ) return;

  // 保存滚动位置（force 时恢复）
  const prevScrollTop = scrollEl.scrollTop;

  const columns = Array.from({ length: count }, (_, i) => {
    const col = document.createElement('div');
    col.className = 'debug-column';
    col.dataset.debugColumn = String(i + 1);
    return col;
  });
  const columnHeights = Array(count).fill(0);

  cards.sort((a, b) => Number(a.dataset.debugOrder) - Number(b.dataset.debugOrder))
    .forEach((card, i) => {
      const h = card.getBoundingClientRect().height || 0;
      // 已测量高度：放入最短列；无法测量（h==0）：轮流分配
      const shortest = columnHeights.indexOf(Math.min(...columnHeights));
      const col = h > 0 ? shortest : i % count;
      columns[col].appendChild(card);
      columnHeights[col] += h;
    });

  layout.replaceChildren(...columns);
  debugLayoutColumnCount = count;
  scheduleMatrixFitRender(2);
  // force 时在下一帧恢复滚动位置
}
```

`scheduleDebugMasonryLayout(force)` 用 `requestAnimationFrame` 防抖；仅在 `body.dataset.page === 'debug'` 时有效。在 `resize`、`orientationchange`、`visualViewport.resize` 事件时触发。每次进入 debug 页时以 `force=true` 强制重建。

### 8.11 API 客户端

必须实现：

- `apiUrl(path)`：
  - 如果 path 已是 http(s)，直接返回。
  - file/offline 模式时允许本地回退，但 API 请求应显示 offline。
- `apiGet(path, { timeoutMs })`：
  - `fetch` GET
  - `cache: 'no-store'`
  - `Accept: application/json`
  - 默认 timeout 2500 ms。
- `apiPost(path, payload, { timeoutMs })`：
  - `fetch` POST
  - `Content-Type: application/json`
  - `Accept: application/json`
  - 默认 timeout 5000 ms。
- `apiPostWithUploadProgress(path, payload, onProgress)`：
  - 用 `XMLHttpRequest`
  - timeout 15000 ms
  - 用 `xhr.upload.onprogress` 更新滚动上传进度。

API JSON 解析器：

- 空响应回退到 `{ ok:true }` 或调用者传入的回退值。
- 解析失败时记录 path 和错误。
- 网络/超时错误更新 `firmware.online=false`、`firmware.lastError`。

### 8.12 WebUI 发送队列

M370 帧队列：

- `WEBUI_M370_SEND_INTERVAL_MS = 45`
- `WEBUI_M370_QUEUE_MAX = 3`
- 如果正在发送，新帧进入队列。
- 队列满时保留最新意图，避免拖动画板时堆积过多旧帧。

按钮命令队列：

- `WEBUI_BUTTON_COMMAND_INTERVAL_MS = 120`
- `WEBUI_BUTTON_COMMAND_QUEUE_MAX = 4`
- API 失败时执行本地回退。

### 8.13 自定义 Select 下拉系统

所有原生 `<select>` 元素必须用自定义下拉替换，原生 select 隐藏为 `position:absolute; opacity:0; pointer-events:none; width:1px; height:1px`。

HTML 结构：

```html
<div class="select-shell">
  <select id="parent-color-select">...</select>
  <!-- ensureCustomSelect() 动态插入 toggle 和 menu -->
</div>
```

常量：`SELECT_MENU_HIDE_DELAY_MS = 260`（来自 `WEBUI_CONFIG.interaction.selectMenuHideDelayMs`）。

**核心函数：**

`ensureCustomSelect(select)` — 幂等初始化。若 `.select-toggle` 不存在，创建并插入到 select 之后：
```html
<button class="select-toggle" aria-haspopup="menu" aria-expanded="false">
  <span class="select-label">当前选中</span>
  <span class="select-caret" aria-hidden="true">▾</span>
</button>
```
菜单 `.select-menu` 以 `document.body.appendChild` 挂到 body（fixed 定位），并在 `shell._selectMenu` 上保存引用。返回 `{ shell, toggle, menu }`。

`refreshSelectDropdown(idOrSelect)` — 同步 `.select-option` 列表到 `select.options`：
- 每个 option 生成一个 `<button class="select-option" role="menuitem" data-value="...">` 按钮。
- `option.textContent` 若含两个以上空格，用 `splitDropdownLabel()` 拆分主标签与次标签（`<span class="num">`）。
- 若次标签含 `#RRGGBB`，设 `button.style.setProperty('--option-color', color)`。
- 当前选中项加 `.active`。
- 点击选项：`select.value = opt.value` → 触发 `change` 事件 → `closeOneCustomSelect()` → `refreshAllCustomSelects()`。

`positionSelectMenu(shell, options)` — 用 fixed 定位菜单于 toggle 正下方（若空间不足则置于上方）：
- 宽度精确匹配 toggle 宽度（`r.width`），left 对齐 toggle 左边（`r.left`）。
- `options.verticalOnly = true`：仅更新垂直位置，避免 window scroll 时水平跳动。
- 判断上下空间：`spaceBelow >= 96 || spaceBelow >= spaceAbove` 则开下，否则开上。
- 高度 = 可用空间（无任意上限），内容能装下时 `overflow-y: hidden`，否则 `overflow-y: auto`。

`closeOneCustomSelect(shell)` — 移除 `.open`，设 `aria-expanded=false`，延迟 `SELECT_MENU_HIDE_DELAY_MS` 后 `display:none`。

`closeCustomSelects(exceptShell)` — 关闭所有打开的 shell（排除 exceptShell）。

`initCustomSelectDropdowns()` — 初始化所有 `.select-shell select`，注册全局：
- `document.click` → `closeCustomSelects()`
- `document.keydown Escape` → `closeCustomSelects()`
- `document.touchmove` (passive:false) → 阻止页面滚动（dropdown 内可滚动除外）
- `window.wheel` (passive:false) → 同上
- `window.resize` → `positionSelectMenu(shell, { recalcWidth: true })`
- `visualViewport.resize/scroll` → `positionSelectMenu(shell)`
- `window.scroll` → `positionSelectMenu(shell, { verticalOnly: true })`（selectScrollLock 时跳过）

**滚动锁定机制**：下拉菜单打开时设 `selectScrollLock = true`（仅标志位，不修改 overflow），通过拦截 `touchmove`/`wheel`/键盘箭头键阻止页面滚动，下拉菜单内部允许滚动（检查 `menu.scrollHeight > menu.clientHeight`）。

### 8.14 JS 全局状态变量

所有模块级变量（`let`/`const`）：

```js
// 帧数据
let currentFrame = blankFrame();   // 当前显示帧（从固件同步）
let editFrame    = blankFrame();   // 自定义画板编辑帧
let partsFrame   = blankFrame();   // 部件合成帧
let scrollFrame  = blankFrame();   // 滚动预览帧

// 部件状态
let selectedCall = { leye: '101', reye: '201', mouth: '301', cheek: '400' };
let partsSymmetry = false;

// 实时发送
let liveSendEnabled = false;

// Face library
let defaultFaces = [];
let userFaces = [];
let faceLibraryDocument = null;
let faceLibraryFileHandle = null;  // File System Access API handle

// 拖拽状态
let pointerFaceDrag = null;

// 日志
let logs = [];

// M370 发送队列
let frameSendInFlight = false;
let pendingFramePacket = null;
let frameSendQueue = [];
let frameSendTimer = 0;
let lastFrameSendAt = 0;

// 按钮命令队列
let buttonCommandQueue = [];
let buttonCommandInFlight = false;
let buttonCommandTimer = 0;
let lastButtonCommandAt = 0;

// API 错误节流
let lastApiErrorLogAt = 0;

// 固件状态轮询
let firmwareStatusPollTimer = null;
let lastFirmwareStatusPollAt = 0;
let firmwareStatusVersion = null;   // since= 版本号，null 表示未知
let firmwareNextPollMs = 1000;
let lastScrollStopEventSeq = 0;
let firmwareScrollStopFullSyncTimer = null;
let firmwareRuntimeSummaryInFlight = false;
let firmwareFullStatusInFlight = false;

// 电源状态轮询
let powerStatusPollTimer = null;
let lastPowerStatusRefreshAt = 0;
let powerStatusRefreshInFlight = false;

// 亮度
let brightnessChangedByUser = false;

// 固件动态上限
let firmwareScrollMaxFrames = FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT;  // 默认 3072

// custom select 状态
let selectScrollLock = null;
let uiFontObserverStarted = false;
let textScrollBrowserFontLoading = null;

// debug masonry 状态
let debugLayoutCards = [];
let debugLayoutColumnCount = 0;
let debugLayoutRaf = 0;

// 矩阵视图列表
let matrixViews = [];
```

`state` 对象（`let state = { ... }`，所有属性）：

```js
let state = {
  mode: 'manual',
  faceIndex: 0,
  brightness: DEFAULT_LED_BRIGHTNESS,
  defaultBrightness: DEFAULT_LED_BRIGHTNESS,
  color: DEFAULT_LED_COLOR,
  parentColorId: 0,
  selectedChildColor: null,
  colorSelection: 'parent',
  playback: 'idle',
  apDomain: DEVICE_AP_DOMAIN,
  apIp: DEFAULT_AP_IP,
  autoInterval: 3000,
  refreshPolicy: 'dirty-frame / 按需刷新',
  lastRefreshReason: 'init',
  refreshCount: 0,
  textScrollActive: false,
  actualFps: 0,
  dpsActive: false,
  restoreAutoAfterScroll: false,
  batteryV: null, batteryPercent: null,
  batteryPowered: true,
  batteryStateText: '电池',
  batteryMinV: null, batteryMaxV: null,
  batteryNominalMin: null, batteryNominalMax: null,
  batteryAdcMv: null, batteryPrevAdcMv: null,
  batteryDisconnectDropMv: null,
  batteryDisconnectDropThresholdMv: null,
  batteryDisconnectLowThresholdMv: null,
  batteryReconnectThresholdMv: null,
  batteryDisconnected: false,
  batteryLowVoltageUnpowered: false,
  batteryUnpoweredLowThreshold: 5.0,
  batteryLastInstantVbat: null,
  batteryIconClass: 'status-dot dim',
  batteryIconColor: '#9aa6b2',
  chargeV: null,
  charging: null,
  chargeAdcMv: null,
  chargeIconClass: 'status-dot dim',
  chargeIconColor: '#9aa6b2'
};
```

`firmware` 对象（`const firmware = { ... }`）：

```js
const firmware = {
  online: false,
  lastRequest: '—',
  lastStatus: 'not connected',
  lastError: '—',
  frameEndpoint: API_ENDPOINTS.frame,
  commandEndpoint: API_ENDPOINTS.command,
  savedFacesEndpoint: API_ENDPOINTS.savedFaces,
  savedFacesPath: FACE_LIBRARY_RESOURCE,
  faceLibrarySource: FACE_LIBRARY_FILENAME,
  sentFrames: 0, sentCommands: 0,
  droppedFrames: 0, droppedCommands: 0,
  frameQueue: 0, buttonQueue: 0,
  savedFacesSync: 'not loaded'
};
```

`scroll` 对象（`let scroll = { ... }`）：

```js
let scroll = {
  timer: null,
  active: false,
  paused: false,
  userPaused: false,    // 用户级暂停（页面暂停按钮 / pause_scroll）
  systemPaused: false,  // 系统级暂停（固件 B6 覆盖层期间）
  pauseToggleLocked: false, // togglePauseScroll() 的 250ms 防抖锁
  firmwareBacked: false,
  uploading: false,
  uploadProgress: 0,    // 0..1
  uploadLabel: '',
  offset: 0,
  frameIndex: 0,
  frames: [],           // 本地 bitmap 帧数组
  signature: '',
  dirty: true,
  dirtyNoticeLogged: false,
  frameCounter: 0,
  fpsStarted: performance.now(),
  measuredFps: 0
};
```

### 8.15 状态同步与轮询

启动：

- 启动阶段只先初始化 UI、basic 矩阵和轻量运行状态；`preloadFirmwareRuntimeState()` 请求 `BOOT_STATUS_ENDPOINT = /api/status?runtimeOnly=1&noFrame=1`，不读取 saved_faces，也不要求完整 `lastM370`。
- `finishBootVisibility()` 后，`runPostBootDeferredReads()` 再加载 saved faces，并用完整 `/api/status` 同步 LED 预览矩阵。
- 初始 basic 预览必须在加载器关闭前初始化；完整当前帧可在启动后的延迟读取中补齐。

常规：

- `startFirmwareStatusPolling()` 每 500 ms tick。
- 如果固件正在滚动且当前是 scroll 页面，用较快的摘要轮询，最小约 550 ms。
- 否则按固件 `next_poll_ms`，最低约 1000 ms。
- 完整状态使用 `/api/status`。
- 运行时摘要使用 `/api/status?runtimeOnly=1&noFrame=1`。
- 支持 `since=<version>`，如果 unchanged 则不刷新 DOM。

电源：

- `startPowerStatusPolling()` 只在 basic/debug 页面有效。
- 每 1000 ms tick。
- 实际刷新间隔 `POWER_STATUS_REFRESH_MS = 900`。
- 请求 `/api/power`。

### 8.16 表情库前端规则

WebUI 必须支持：

- 从 `/api/saved_faces` 读取。
- 如果 offline/file 模式，从本地 `saved_faces.json` 或 `/resources/saved_faces.json` 回退。
- 使用 File System Access API 打开本地 saved_faces.json。
- 保存到已打开本地文件。
- 下载完整 saved_faces.json。
- 导入 saved_faces.json。
- 拖拽排序表情。
- 重命名表情。
- 应用表情。
- 删除用户表情。
- 默认表情不可删除。

保存用户表情：

- id：`${type}_${Date.now()}`
- name：用户输入，最长 64。
- type：`custom` 或 `parts`。
- m370：当前 frame。
- order：现有最大 order + 1。
- editable/deletable true。
- sourceFile：`saved_faces.json`
- savedAt/updatedAt：ISO 字符串。
- 部件表情还保存 `call`。
- 保存后调用 `persistFaceDocuments('save_user_face')`，POST `/api/saved_faces`。

### 8.17 WebUI JS 完整性补充

本节用于避免从零重建时漏掉当前实现中已经存在的交互细节。以下内容不是可选增强，而是当前 WebUI 行为的一部分。

#### 8.17.1 按钮按压动画 JS

所有 `<button>` 的按压反馈由 JS 统一管理，不依赖每个按钮单独绑定：

- 常量来自 `WEBUI_CONFIG.interaction`：`buttonPressDownMs = 90`、`buttonPressUpMs = 150`。
- 全局状态：
  - `buttonPressAnimationsReady = false`
  - `buttonPressStates = new WeakMap()`
  - `activeButtonPointers = new Map()`
- `pressableButtonFromTarget(target)` 找最近的 button；disabled 或 `aria-disabled="true"` 时返回 `null`。
- `startButtonPressAnimation(button)` 清掉旧 timer，移除 `.is-releasing`，添加 `.is-pressing`，记录 `startedAt = performance.now()`。
- `releaseButtonPressAnimation(button)` 保证 `.is-pressing` 至少持续 `BUTTON_PRESS_DOWN_MS`；之后移除 `.is-pressing`、添加 `.is-releasing`，再在 `BUTTON_PRESS_UP_MS` 后清理 class 和 WeakMap。
- `initButtonPressAnimations()` 只运行一次，监听：
  - `document.pointerdown`：只处理左键/主指针，记录 `activeButtonPointers[pointerId]`，尝试 `button.setPointerCapture(pointerId)`。
  - `document.pointerup` / `pointercancel`：释放对应按钮动画。
  - `document.keydown`：Space/Enter 且非 repeat 时启动动画。
  - `document.keyup`：Space/Enter 时释放动画。

#### 8.17.2 字体加载与 DOM 后处理

WebUI 字体不是只靠 CSS 声明；JS 必须在运行时强制应用并观测新增节点：

- `ensureWebUiFontReady()` 设置 `--ui-font`，用 `document.fonts.load('16px "GNU Unifont"', sample)` 等待内联 GNU Unifont，随后写 `documentElement.dataset.uiFontLoaded = 'true'|'false'`。
- `applyWebUiFont(root)` 给 `body, body *` 或新增 subtree 写 inline `font-family: "GNU Unifont" !important`，但跳过 `#scroll-text`，最后调用 `applyTextScrollInputFont()`。
- `observeWebUiFont()` 用 `MutationObserver(document.body, { childList:true, subtree:true })`，对新增元素再次调用 `applyWebUiFont(node)`。
- 字体加载后必须调用 `autoResizeM370Textareas()` 和 `autoResizeScrollTextInput()`，因为 textarea 高度依赖像素字体实际度量。
- `ensureTextScrollBrowserFontReady()` 设置 `--scroll-font`，用 `document.fonts.load('12px "Ark Pixel 12px Monospaced"', TEXT_SCROLL_BROWSER_FONT_SAMPLE)` 预热 `ark12.woff2`，并写 `data-scroll-font-loaded = 'true'|'false'|'unsupported'`。它只预热浏览器字体；大型 `ark12.json` 仍由 `ensureArkPixelFontReady()` 在进入/使用滚动页时 lazy-load。

#### 8.17.3 启动后的延迟读取

`runPostBootDeferredReads(bootOk)` 只能执行一次，且要等一帧和一个 0ms timeout，让首屏先稳定：

1. 设置 `firmware.savedFacesSync = 'loading after WebUI ready'`，记录日志。
2. 调用 `loadFaceLibrary()`，失败时状态设为 `deferred load failed`。
3. 调用 `syncRuntimeStateFromFirmware('post_load_matrix_preview')`。
4. 如果同步失败且表情库可用、当前不是文字滚动播放：`bootOk` 为真则 `applyKnownFaceIndexLocal('post_load_face_index_fallback')`，否则 `applyStartupDefaultFaceLocal('post_load_default_face_fallback')`。
5. 重新 `renderSavedFaces()`、`renderMatrices()`、`renderState()`，并 `scheduleMatrixFitRender(3)`。
6. 后台调用 `ensureTextScrollBrowserFontReady()` 预热 `ark12.woff2`；不要在此处加载 1.8MB 左右的 `ark12.json`。

#### 8.17.4 图案与 debug 控件

`makePatternFrame(kind)` 必须支持：

- `checker`：有效 LED 上 `(x + y) & 1` 为 0 时点亮。
- `border`：每行有效 x 范围的左右边界，或 y 为首/末行时点亮。
- `all-off` / `all-on` 由调用者直接传 blank/full frame。

Debug 的“辅助命令”文本框 `#serial-input` 接受 JSON；若可解析为对象且含 `cmd`，通过 `sendAuxCommand(cmd, payload || {}, 'serial_input')` 发送。日志下载使用 `downloadJsonFile('rina_webui_log.txt', logs.join('\n'))`，即虽然函数名是 JSON 下载，也可下载纯文本日志。

### 8.18 当前实现同步补充

本小节是对照当前 `data/index.html`、`data/styles.css`、`src/web_api.cpp` 后补齐的重建清单。若前文 WebUI 描述遗漏细节，以此小节为准。

#### 页面、DOM 与初始化顺序

- WebUI 页面数组定义在 `WEBUI_CONFIG.navigation.pages`，并由别名导出：
```js
// WEBUI_CONFIG.navigation.pages = [
//   ['basic', '6.1', '基础功能'],
//   ['custom', '6.2', '自定义表情'],
//   ['parts', '6.3', '表情部件'],
//   ['scroll', '6.4', '文字滚动'],
//   ['debug', '6.5', '调试']
// ];
const PAGES = WEBUI_CONFIG.navigation.pages;
```
- `<html>` 初始必须带 `data-boot-phase="preload"` 与 `data-scroll-lock="boot"`；启动完成后移除滚动锁，避免加载期间页面抖动。
- `bootstrapWebUi()` 的顺序必须是：记录启动开始 -> `await rinaStartLoaderAnimation()`（内部先等待首图 decode 再 `initOverlay()`）-> `prepareFirstPageProgressiveReveal()` -> `await ensureWebUiFontReady()` -> `initFirstPageUiBeforeShow()` -> `initializeBasicPreviewMatrix()` -> `renderFirstPageUiBeforeShow()` -> `showBootUiBehindLoader()` -> `await revealFirstPageWaterfall()` -> 启动 `preloadFirmwareRuntimeState()`（异步，不阻塞）-> `await waitForBootLoaderMinimum()`（`minDisplayMs=400`）-> `finishBootVisibility()`（内部触发 `rinaLoaderComplete()`）-> `initDeferredUiAfterShow()` -> `await runtimePingPromise` -> `startFirmwareStatusPolling()` + `startPowerStatusPolling()` -> `runPostBootDeferredReads()`。
- 首屏只取 `/api/status?runtimeOnly=1&noFrame=1`，不得阻塞读取 `saved_faces.json` 或完整 `lastM370`。完整表情库与矩阵预览由 `runPostBootDeferredReads()` 在页面显示后补齐。

#### 必须保留的 JS 功能簇

- API：`apiUrl()`、`apiGet()`、`apiPost()`、`apiPostWithUploadProgress()`，GET 默认 2500 ms，POST 默认 5000 ms，上传默认 15000 ms，所有 API 请求使用 `no-store` 和 JSON Accept。
- 发送队列：`queueFirmwareFrame()`、`scheduleFrameSendPump()`、`pumpFrameSendQueue()`，M370 队列最多 3 个，45 ms 节流，队列满时丢旧保新；按钮/命令队列最多 4 个，120 ms 节流。
- 固件同步：`preloadFirmwareRuntimeState()`、`syncRuntimeStateFromFirmware()`、`syncRuntimeSummaryFromFirmware()`、`startFirmwareStatusPolling()`、`rememberFirmwareStatusPoll()`，需要支持 `since=<version>`、`runtimeOnly=1&noFrame=1` 和固件返回的 `next_poll_ms`。
- 电源同步：`refreshPowerStatusFromFirmware()`、`startPowerStatusPolling()`、`applyPowerData()`，basic/debug 页进入时强制刷新；顶部徽章与 debug KV 共用同一份电源状态。
- 导航：`initNav()`、`switchPage()`、`setNavMenuOpen()`、`updateCurrentPageLabel()`；切换到 `scroll` 时懒加载 Ark JSON/生成滚动预览，切换到 `debug` 时强制重排瀑布流并刷新电源。
- 字体：`ensureWebUiFontReady()` 等待 GNU Unifont；`applyWebUiFont()` 对新增 DOM 继续写入 UI 字体但跳过 `#scroll-text`；`ensureTextScrollBrowserFontReady()` 只预热 `ark12.woff2`；`ensureArkPixelFontReady()` 只在滚动功能需要栅格化时加载 `ark12.json`。
- 矩阵：`initMatrix()`、`attachDrawing()`、`fitMatrix()`、`observeMatrixWraps()`、`renderMatrices()`；矩阵可编辑页只允许有效单元格响应 click，无效单元格需要保持不可点且视觉为熄灭/弱化。
- 表情库：`loadFaceLibrary()`、`normalizeFaceDocument()`、`buildUnifiedFaceDocument()`、`persistFaceDocuments()`、`renderSavedFaces()`、`attachFaceReorderHandle()`、`saveFace()`；默认表情不可删除，custom/parts 可删除，排序、重命名、拖拽都必须写回统一 `/api/saved_faces`。
- 部件拼脸：`composePartsFrame()`、`selectPart()`、`syncSymmetricEyesFrom()`、`randomParts()`、`renderPartButtons()`；左右眼对称模式打开时按显示序号同步，而不是按原始 ID 字符串硬套。
- 文字滚动：`prepareTextScrollTimelineAsync()`、`buildTextScrollBitmap()`、`buildTextGlyph()`、`isEmojiFormatControl()`、`extractFrameFromTextImage()`、`uploadFirmwareScrollTimeline()`、`startScroll()`、`togglePauseScroll()`、`pauseScroll()`、`resumeScroll()`、`stopScroll()`、`advanceScroll(manual, direction)`、`setScrollStepHandler()`、`setScrollFps()`；滚动帧只写 RAM，24 帧一包，全部包上传完成后再发送 `start_scroll` 指令设置最终 fps/interval；逐帧按钮本地步进预览并发送带 `direction` 的 `scroll_step`。
- Debug：`initializeDebugControls()`、`makePatternFrame()`、`setupDebugMasonryLayout()`、`scheduleDebugMasonryLayout()`；图案必须支持 `all-off`、`all-on`、`checker`、`border`。

#### 事件与交互细节

- 所有 `<button>` 和 `.part-card` 必须接入按压动画：pointerdown/keyboard Space/Enter 进入 `.is-pressing`，至少保持 90 ms；释放后进入 `.is-releasing` 150 ms；disabled 或 `aria-disabled="true"` 不参与。
- 自定义 select 必须保留原生 `<select>` 作为 value/change 源，同时创建 `.select-toggle` 和 append 到 `body` 的 fixed `.select-menu`。打开时只用 `selectScrollLock` 标志和事件拦截阻止页面滚动，不直接改页面 overflow；菜单内部可滚动。
- `positionSelectMenu()` 必须考虑 `visualViewport.offsetLeft/offsetTop`、上下可用空间、`verticalOnly` 重定位和滚动条宽度；`window.scroll` 时只做垂直重定位，`visualViewport.resize/scroll` 时做完整重定位。
- GPIO B1/B2/B3 中断文字滚动时，WebUI 通过 `scrollStopEvent.seq` 变化识别，只接受 `source === 'gpio'` 且 button 为 B1/B2/B3 的事件；如果固件处于延迟恢复，延迟 140 ms 做完整状态同步，否则延迟 20 ms。
- `terminateOtherActivities(targetMode, reason)` 在切换到会输出 LED 的页面/操作前发送 `terminate_other_activities`，`targetMode='scroll'` 时若原模式是 auto，固件要记录 `restoreAutoAfterScroll`。

#### API 合约补齐

- `/api/scroll` 只接受 POST，body 必须含 `frames` 数组，元素是 M370 字符串；支持 `append`、`start`、`chunkIndex`、`totalFrames`、`fps` 或 `intervalMs`。`persist`、`saveToFlash` 或非 `storage:'ram'` 必须返回 400。
- `/api/command` 当前命令集合必须包括：`set_color`、`set_brightness`、`set_mode`、`set_auto_interval`、`set_scroll_interval`、`start_scroll`、`scroll_step`、`pause_scroll`、`resume_scroll`、`stop_scroll`、`pause`、`resume`、`button`、`terminate_other_activities`、`reset_battery_min`、`reset_battery_max`。
- `/api/status` 在滚动中或仅摘要时必须避免返回完整 frame，仍要返回 renderer scroll 状态、滚动停止事件、memory scroll buffer 信息与 `next_poll_ms`。完整非滚动状态才返回 `lastM370`/frame 相关预览数据和 LittleFS 容量。
- `/api/saved_faces` GET/POST 操作唯一文件 `/resources/saved_faces.json`；POST 需要校验 unified document，且必须保留至少一个 `type:"default"` face。

#### CSS 与动画补齐

- `styles.css` 的 root 变量必须包含 `--led-preview-edge-ratio:.1000`；matrix 留白通过 `fitMatrix()` 写 `--matrix-edge-gap = cell * edgeRatio`，不是固定 12 px。
- 加载覆盖层必须包含 `.blur-screen`、`.loading-box`、`.loader-stage`、`.flash-halo`、`.avatar-circle`、`.avatar-before`、`.avatar-after`、`.loading-text`；状态类必须支持 `is-assets-pending`、`is-animating`、`is-image-pop`、`is-final-release`、`is-ring-contracting`、`is-halo-hidden`、`is-hidden`、`is-scroll-passthrough`。
- 加载 keyframes 必须保留：`rinaBoot-pulseRingBreath`、`rinaBoot-haloContractOut`、`rinaBoot-avatarShrinkThenRelease`。reduced motion 下 halo 动画放慢到约 2.6s，瀑布揭示 transition 约 1ms。
- 首屏瀑布揭示使用 `.boot-reveal-item` 与 `.is-revealed`，初始 `visibility:hidden; opacity:0; transform:translateY(10px)`，显示时恢复 visible/opacity/transform。
- 导航覆盖层的 z-index 需要高于 sidebar 但低于加载覆盖层：`.top-page-nav` 约 `2147483000`，`.select-menu` 约 `2147482501`，`.sidebar` 约 `2147482999`，加载覆盖层约 `2147483000` 且在 DOM 上覆盖。
- `@media (hover:none), (pointer:coarse)` 必须取消 hover 抬升/阴影，仅保留按压状态；`@media (max-width:980px)` 单列布局，`@media (min-width:1471px)` parts/debug 宽布局，`@media (max-width:640px/520px/400px)` 缩小控制高度、字体、padding 和 LED 默认 cell。


### 8.19 WebUI 源码级硬性补遗：DOM、动画、队列、布局锁定（2026-05-23 追加）

本小节用于把第 8 节和第 15 节中的源码片段收束成可直接重建的强制规则。若本小节与更早的概略描述冲突，以本小节为准；但不得据此重构实现，只能按当前实现复现。

#### 8.19.1 DOM 绑定与 JSON 解析

必须保留以下无依赖辅助层，不允许引入 Vue/React 或事件总线替代：

```js
function safeJsonParse(text, fallback = {}) {
  try { return JSON.parse(text); }
  catch (e) { return fallback; }
}

function parseApiJson(text, path, fallback = {}) {
  if (!text) return fallback;
  try { return JSON.parse(text); }
  catch (err) { throw new Error(`invalid JSON from ${path}: ${err.message || err}`); }
}
const boundControls = new WeakMap();
function bindControls(selector, eventName, handler) {
  document.querySelectorAll(selector).forEach(el => {
    const token = `${selector}:${eventName}`;
    let bound = boundControls.get(el);
    if (!bound) { bound = new Set(); boundControls.set(el, bound); }
    if (bound.has(token)) return;
    bound.add(token);
    el.addEventListener(eventName, handler);
  });
}
function setClickHandlers(entries) {
  for (const [id, handler] of entries) {
    const el = $(id);
    if (el) el.onclick = handler;
  }
}
```

实现细节必须注意：

- `safeJsonParse` 的职责是非 API JSON 容错，解析失败直接返回回退值。
- `parseApiJson` 的职责是 API 响应校验：空响应返回回退值，非法 JSON 抛出 `invalid JSON from ${path}: ...`，由调用处统一进入错误路径；不要把它改成静默回退，否则会掩盖固件返回异常。
- `bindControls` 的 token 必须是 ``${selector}:${eventName}``，并以 `WeakMap` 存每个 DOM 元素已绑定事件集合，防止 `initFirstPageUiBeforeShow`、表情库初始化、debug 初始化重复执行时多次触发。
- `setClickHandlers` 不做 `addEventListener` 叠加，不使用 `data-click-bound`，而是覆盖 `onclick`，用于 id 精确绑定的一组按钮。

#### 8.19.2 HTML 页面与组件隐藏态

- 所有页面必须是 `<section class="page" id="page-basic/custom/parts/scroll/debug">` 这一类 DOM，不得在切页时销毁重建。
- 切页只通过 `.page.active` 和 `.nav button.active` 的 class 同步完成；隐藏页保持 DOM 和输入状态存在。
- 任何被 JS/CSS 绑定的核心控件 id 必须与第 15.3 的完整 DOM id 清单严格一致，尤其包括 `badge-battery-dot`、`brightness-reset-default`、`custom-live-toggle`、`parts-symmetry-toggle`、`update-adc`、`debug-reset-battery-min`、`debug-reset-battery-max` 等。

#### 8.19.3 `switchPage(id)` 必须按当前源码顺序执行

```js
function switchPage(id) {
  terminateOtherActivities(modeForPage(id), `switch_page_${id}`);
  document.body.dataset.page = id;
  for (const [pid] of PAGES) {
    $('page-' + pid).classList.toggle('active', pid === id);
    const b = document.querySelector(`.nav button[data-page="${pid}"]`);
    if (b) b.classList.toggle('active', pid === id);
  }
  updateCurrentPageLabel(id);
  setNavMenuOpen(false);
  scheduleMatrixFitRender(2);
  if (id === 'scroll') {
    ensureScrollFontsLoaded();
    requestAnimationFrame(() => { autoResizeScrollTextInput(); updateScrollUi(); });
  }
  if (id === 'custom') requestAnimationFrame(() => autoResizeTextarea($('custom-m370')));
  if (id === 'parts') requestAnimationFrame(() => autoResizeTextarea($('parts-m370-text')));
  if (id === 'debug') {
    requestAnimationFrame(() => { setupDebugMasonryLayout(true); autoResizeTextarea($('debug-m370')); });
    refreshPowerStatusFromFirmware('debug_page_enter', true);
  }
  if (id === 'basic') {
    syncRuntimeStateFromFirmware('basic_page_enter');
    refreshPowerStatusFromFirmware('basic_page_enter', true);
  }
}
```

强制约束：进入 custom/parts/debug/scroll 页时必须使用 `requestAnimationFrame` 触发 textarea 高度重算或滚动 UI 重算，原因是隐藏页 `display:none` 下直接测量高度会失真。进入任何页面前必须先调用 `terminateOtherActivities(modeForPage(id), ...)`，避免文字滚动播放、custom 实时发送、parts 实时发送互相覆盖。

#### 8.19.4 加载覆盖层径向揭示动画

`animateReveal()` 使用 loader 中心点作为揭示原点，半径必须按当前公式计算：

```js
function eic(t) {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}
function getMaxR(center = revealCenterInSurface()) {
  const o = center.surface;
  const cx = center.x, cy = center.y;
  return Math.ceil(Math.max(
    Math.hypot(cx, cy),
    Math.hypot(o.width - cx, cy),
    Math.hypot(cx, o.height - cy),
    Math.hypot(o.width - cx, o.height - cy)
  ) + 90);
}
// animateReveal 内部：
const origin = setOrigin();          // 写入 --rina-reveal-x/y
const maxR = getMaxR(origin);
const r = maxR * eic(t);             // 每帧写入 --rina-reveal-radius
```

每帧只写入 `--rina-reveal-radius`（数值保留两位小数并带 `px`）；揭示原点由 `setOrigin()` 写入 `--rina-reveal-x/--rina-reveal-y`，羽化由固定的 `--rina-reveal-edge`（默认 1px）控制。`is-revealing` 添加在 `.blur-screen` 上；`is-scroll-passthrough` 添加在覆盖层上并调用 `unlockBootPageScroll()`，保证首屏揭示时页面滚动恢复。

#### 8.19.5 LED preview 平滑等比缩放

`fitMatrix(view)` 必须复现当前三层预算算法：CSS 变量读取 → card chrome/reserved height 扣除 → cell/edge gap 写回。核心公式如下：

```js
const borderX = borderLeftWidth + borderRightWidth;
const borderY = borderTopWidth + borderBottomWidth;
const widthBudget = Math.max(1, wrapRect.width - borderX);
const maxContentHeight = matrixMaxContentHeight(wrap, configuredMaxHeight);
const heightBudget = Number.isFinite(maxContentHeight) ? Math.max(1, maxContentHeight - borderY) : Infinity;
const widthDenom = COLS + 2 * edgeRatio;
const heightDenom = ROWS + 2 * edgeRatio;
const cellByWidth = (widthBudget - gap * (COLS - 1)) / widthDenom;
const cellByHeight = Number.isFinite(heightBudget) ? (heightBudget - gap * (ROWS - 1)) / heightDenom : Infinity;
const fitCell = Math.min(cellByWidth, cellByHeight, maxCell);
const cell = clamp(fitCell, minCell, maxCell);
const edgeGap = cell * edgeRatio;
view.el.style.setProperty('--cell', cell.toFixed(4) + 'px');
view.el.dataset.cellPx = cell.toFixed(4);
wrap.style.setProperty('--matrix-edge-gap', edgeGap.toFixed(4) + 'px');
```

`matrixMaxContentHeight(wrap, configuredMaxHeight)` 必须扣除同卡片内除 matrix wrap 外的兄弟元素高度、margin、card padding、border、row gap；不是简单的视口高度换算。`edgeRatio` 默认 `.1000`，用于让 LED 矩阵边缘留白随 cell 同比例缩放。

#### 8.19.6 文本滚动垂直居中和滑入滑出空白

必须保留独立函数：

```js
function textScrollVerticalOffset() {
  return Math.min(Math.max(0, ROWS - 1),
    Math.max(0, Math.floor((ROWS - Math.max(1, arkPixelFont.lineHeight || 12)) / 2)) + 2);
}
```

`buildTextScrollBitmap(text)` 必须把 cache key 绑定到文本、字体模型、字体来源和 `centerY${textScrollVerticalOffset()}`。生成 bitmap 时：

- `leadingBlank = COLS + 4`
- `trailingBlank = COLS + 4`
- `width = Math.max(COLS * 2 + 8, leadingBlank + contentWidth + trailingBlank)`
- 每个 glyph 通过 `blitGlyphBitmap(bitmap, x, g)` 写入，`baseY = textScrollVerticalOffset() + glyph.dstY + glyph.yOffset`

这样才能保证文字完整滑入、完整滑出，并且在 10 行 LED 画布中相对当前 Ark Pixel 行高向下偏移 2 行。

#### 8.19.7 按钮按压动画状态机

所有 `button` 必须走全局按压动画系统，不允许各按钮单独实现不同的 pressed 样式。实现要求：

- 常量：`BUTTON_PRESS_DOWN_MS = WEBUI_CONFIG.interaction.buttonPressDownMs`，当前值 90；`BUTTON_PRESS_UP_MS` 当前值 150。
- 状态容器：`buttonPressStates = new WeakMap()`；pointer 捕获表：`activeButtonPointers = new Map()`。
- `pointerdown`：只接受主键；找到最近 `button`；写入 `activeButtonPointers`；调用 `startButtonPressAnimation(button)`；尝试 `button.setPointerCapture(ev.pointerId)`。
- `pointerup` / `pointercancel`：从 `activeButtonPointers` 取回原按钮并释放动画。
- 键盘：`Space` / `Enter` 也必须触发相同动画，不得只依赖 CSS `:active`。
- 快速点击时必须计算 `delay = max(0, BUTTON_PRESS_DOWN_MS - elapsed)`，保证 `.is-pressing` 至少存在 90ms，再进入 `.is-releasing` 150ms。

#### 8.19.8 API 客户端、离线模式和 M370 发送队列

- `isOfflineHtmlMode()` 判断 `location.protocol === 'file:'` 时，API 请求必须短路到模拟结果或回退值，不向网络发起请求。
- 离线发送状态文本必须包括 `queued offline` / `offline html mode`，并避免把离线模式当作错误刷屏。
- `/api/frame` 不允许并发高频 POST，必须统一通过 `enqueueFrameSend(packet, source)` → `pumpFrameSendQueue()`。
- M370 队列最大长度为 3；超出时丢弃队首最老帧，保留最新用户意图。
- `pumpFrameSendQueue()` 每次发送前必须检查：

```js
const waitMs = Math.max(0, WEBUI_M370_SEND_INTERVAL_MS - (performance.now() - lastFrameSendAt));
if (waitMs > 0) { scheduleFrameSendPump(waitMs); return; }
```

当前 `WEBUI_M370_SEND_INTERVAL_MS = 45`，必须由 `WEBUI_CONFIG.firmwareQueues.m370SendIntervalMs` 派生。

#### 8.19.9 Debug 页电源模拟与瀑布流布局

Debug 页 `update-adc` 按钮必须手动推导运行时电池状态，核心逻辑：

```js
state.batteryLastInstantVbat = Number($('battery-v')?.value || state.batteryV);
state.chargeV = Number($('charge-v')?.value || state.chargeV);
state.charging = Number(state.chargeV || 0) > 4.0;
state.batteryLowVoltageUnpowered = !state.charging && Number(state.batteryLastInstantVbat || 0) < Number(state.batteryUnpoweredLowThreshold || 5.0);
state.batteryPowered = state.charging || !state.batteryLowVoltageUnpowered;
state.batteryV = state.batteryPowered ? state.batteryLastInstantVbat : 0;
state.batteryPercent = null;
state.batteryStateText = state.batteryPowered ? '电池' : '未上电';
```

Debug 瀑布流必须读取每张卡片的 `getBoundingClientRect().height`，使用 `columnHeights.indexOf(Math.min(...columnHeights))` 贪心放入当前最短列。无高度时回退到 `index % count`，并且重排前后保持滚动位置。


## 9. CSS 规格

`styles.css` 必须是暗色像素风控制台界面，核心变量：

```css
:root {
  --ui-font: "GNU Unifont";
  --scroll-font: "Ark Pixel 12px Monospaced";
  --bg: #0f1117;
  --panel: #161a24;
  --panel2: #1e2430;
  --text: #f4f7fb;
  --muted: #9aa6b2;
  --line: #2b3344;
  --accent: #f971d4;
  --accent2: #77d7ff;
  --ok: #59d98e;
  --primary-gradient: linear-gradient(135deg, #f971d4, #8f74ff);
  --card-shadow: 0 12px 32px #00000035;
  --control-radius: 12px;
  --control-font-size: 16px;
  --control-line-height: 1.35;
  --control-padding-y: 10px;
  --control-padding-x: 14px;
  --control-compact-padding-x: 10px;
  --button-radius: var(--control-radius);
  --button-font-size: var(--control-font-size);
  --button-padding-y: var(--control-padding-y);
  --button-padding-x: var(--control-padding-x);
  --button-hover-color: var(--accent2);
  --page-edge-gap: 14px;
  --sidebar-padding-y: 14px;
  --sidebar-padding-x: 18px;
  --led-preview-default-cell: 18px;
  --led-preview-min-cell: 5px;
  --led-preview-max-cell: 48px;
  --led-preview-min-width: 320px;
  --led-preview-max-height: 500px;
  --led-preview-edge-ratio: .1000;
  --cell: var(--led-preview-default-cell);
  --gap: 4px;
  --led-color: #f971d4;
  --control-height: 44px;
  --page-min-width: 320px;
}
```

必须包含：

- `@font-face` GNU Unifont：内联 data URI woff2，`font-display:block`。
- `@font-face` Ark Pixel 12px Monospaced：单一基础字体 `/resources/fonts/ark12.woff2`（带缓存破坏 query，例如 `?v=20260612-emoji-input-v3`）。当前 `styles.css` 共 2 个 `@font-face`（GNU Unifont + Ark Pixel），已不再注册回退/别名字体。
- 全局强制像素字体：body、button、input、select、textarea 等。
- `#scroll-text` 强制 Ark Pixel。
- 深色滚动条。
- 加载覆盖层动画 class：
  - `is-assets-pending`
  - `is-animating`
  - `is-image-pop`
  - `is-final-release`
  - `is-ring-contracting`
  - `is-halo-hidden`
  - `is-hidden`
  - `is-scroll-passthrough`
- 按钮按压动画：
  - `is-pressing`
  - `is-releasing`
  - CSS 变量 `--button-hover-y`、`--button-press-y`、`--button-press-scale`
- 响应式：
  - <= 980 px 单列布局。
  - >= 1471 px parts/debug 更宽布局。
  - <= 640/520/400 px 调整按钮、矩阵、间距。
- `.matrix-wrap` 使用 CSS 变量控制 cell size、min/max、edge gap。
- `.matrix` 使用 grid，cell 稳定尺寸，不因 hover 或文本改变布局。
- `.face-library-list` 可滚动，face 行有拖拽手柄、主体、动作区。
- `.scroll-upload-progress` 支持进度条。

### 9.1 页面外壳与导航 CSS

必须实现当前层级对应的外壳样式：

- `.sidebar` 是 body 直接子元素，`position: relative`，`z-index: 2147482999`，顶部横条布局，底部 1px 分割线，背景 `linear-gradient(180deg, #151927, #0f1117)`。
- `.app` 只包 main，`display:block`，`min-height: calc(100vh - 160px)`。
- `.top-page-nav` 是 body 直接子元素，默认不可点且透明：`position:absolute`，`top: calc(var(--control-height) + var(--sidebar-padding-y) * 2 + var(--page-edge-gap))`，左右 `var(--page-edge-gap)`，`z-index:2147483000`，`opacity:0`，`transform: translateY(-8px)`，`pointer-events:none`。
- `.top-page-nav.open`：`opacity:1`、`transform: translateY(0)`、`pointer-events:auto`、`border-color: var(--line)`、`box-shadow: 0 18px 46px #00000090`。
- `.brand-nav-toggle` 是正方形汉堡按钮，宽高均为 `var(--control-height)`；`.active` 时 border/accent 与阴影变为 `var(--accent)`。
- `.menu-icon span` 三条线：`width:18px; height:2px; border-radius:999px; background: currentColor`。
- `.nav button.active` 使用 `var(--primary-gradient)`，`.top-page-nav.open .nav button.active .num` 需要白色发光 `text-shadow`。

### 9.2 控件与按压动画 CSS

按钮和选择器必须共享同一套尺寸变量与动效：

- `button` 默认 `transform: translateY(calc(var(--button-hover-y) + var(--button-press-y))) scale(var(--button-press-scale))`。
- `button:hover:not(:disabled)` 设置 `--button-hover-y:-1px`，并用 `color-mix(in srgb, var(--button-hover-color) 34%, transparent)` 产生 2px 外发光。
- `.is-pressing` 设置 `--button-press-y:2px`、`--button-press-scale:.985`，transition duration 90ms。
- `.is-releasing` 恢复 `--button-press-y:0`、`--button-press-scale:1`，transition duration 150ms。
- `.part-card.is-pressing .part-mini` 和 `.part-card.is-releasing .part-mini` 也要有相同节奏的 transform/border/box-shadow 反馈。
- `@media (hover:none), (pointer:coarse)` 中必须禁用纯 hover 位移/发光，避免触屏上出现粘滞 hover；但 `.is-pressing` 仍生效。

### 9.3 自定义 Select CSS

自定义 select 的 CSS 必须与 JS 结构匹配：

- `.select-shell`：`position:relative; width:100%; z-index:50`；`.select-shell.open` 提升到 `z-index:2147482500`。
- 原生 `.select-shell select`：绝对定位 1x1 px，`opacity:0!important`，`pointer-events:none!important`，保留在 DOM 中供 value/change 使用。
- `.select-toggle`：宽 100%，`min-height: var(--control-height)`，flex 两端对齐，背景 `#141926`，box-shadow `0 12px 30px #00000035`。
- `.select-menu`：由 JS 挂到 body，`position:fixed`，`z-index:2147482501`，默认 `display:none`、`opacity:0`、`transform:translateY(-8px)`、`pointer-events:none`，打开时 `.open` 设置 `opacity:1`、`transform:translateY(0)`、`pointer-events:auto`、`box-shadow:0 18px 46px #00000090`。
- `.select-menu` 要 `overscroll-behavior: contain`、`touch-action: pan-y`、`-webkit-overflow-scrolling: touch`，webkit scrollbar 隐藏。
- `.select-caret` 在 `.select-shell.open` 时旋转 180deg。
- `.select-option.active` 使用 `--option-color` 高亮 border 和外发光；`.select-option .num` 是右侧小号辅助标签。

### 9.4 矩阵与卡片 CSS

- `.matrix-wrap` 使用 `--matrix-default-cell`、`--matrix-min-cell`、`--matrix-max-cell`、`--matrix-max-height`、`--matrix-edge-gap`，JS 会写入 `--cell` 和 `--matrix-edge-gap`。
- `.matrix` 是 22 列 x 18 行 grid；每个 cell 尺寸固定为 `var(--cell)`，gap 使用 `--gap`，无效 LED cell 加 `.invalid`，有效且亮起加 `.on`。
- `.matrix.editable-matrix` 要允许 pointer/click 编辑，但不能因 hover 改变 cell 尺寸。
- `.led-preview-card .matrix-wrap.fill-column` 在卡片中尽量填充剩余空间；`.debug-measure-card .matrix-wrap` 使用较小 `--matrix-max-height`。
- 表情库列表中的 `.saved-face-card` 使用 grid：拖拽手柄、主体、动作栏三块；动作按钮在桌面宽度有固定 `--face-control-size`，移动端可换行。

### 9.5 加载覆盖层 CSS 精确要求

加载相关 CSS 变量必须包含：

```css
--rina-icon-size: 96px;
--rina-avatar-frame-width: 5px;
--rina-avatar-size: calc(var(--rina-icon-size) + var(--rina-avatar-frame-width) * 2);
--rina-halo-spread: 18px;
--rina-halo-size: calc(var(--rina-avatar-size) + var(--rina-halo-spread) * 2);
--rina-icon-pop-scale: 1.22;
--rina-icon-shrink-scale: 1.12;
--rina-icon-release-scale: 2.35;
--rina-halo-contract-scale: 0.65;
--rina-halo-contract-duration: 520ms;
--rina-image-pop-duration: 620ms;
--rina-image-release-duration: 2100ms;
--rina-blur-size: 14px;
--rina-loader-x: 50vw;
--rina-loader-y: 50vh;
--rina-reveal-radius: 0px;
--rina-reveal-edge: 1px;
--rina-reveal-x: 50%;
--rina-reveal-y: 50%;
```

加载元素样式：

- `.loading-overlay`：`position:fixed; inset:0; z-index:2147483000; overflow:hidden; pointer-events:auto; background:transparent`。
- `.blur-screen`：铺满覆盖层，`backdrop-filter: blur(var(--rina-blur-size))`，通过 `.is-revealing` 的 `mask-image` / `-webkit-mask-image` 两段 radial-gradient（`transparent` 到 `var(--rina-reveal-radius)`，`#000` 从 `calc(var(--rina-reveal-radius) + var(--rina-reveal-edge))` 开始）从中心向外揭示。
- `.loading-box`：`position:fixed; left:var(--rina-loader-x); top:var(--rina-loader-y); transform:translate(-50%,-50%)`。
- `.avatar-circle`：白底圆形，尺寸 `var(--rina-avatar-size)`，overflow hidden；`.avatar-before` 默认 opacity 1，`.avatar-after` 默认 opacity 0。
- `.flash-halo`：圆形径向渐变光环，默认执行 `rinaBoot-pulseRingBreath 1.62s cubic-bezier(.42,0,.58,1) infinite both`。
- `.is-assets-pending .loading-box` opacity 为 0；`.is-hidden` opacity 0 且不可点击；`.is-scroll-passthrough` pointer-events none。

必须实现 3 个 keyframes：

- `rinaBoot-pulseRingBreath`：0/100% opacity `.28` scale `.965`，50% opacity `1` scale `1.075`。
- `rinaBoot-haloContractOut`：从 scale `1.075` opacity `1` 到 scale `.65` opacity `0`。
- `rinaBoot-avatarShrinkThenRelease`：0% scale `1.22`，18% scale `1.12`，100% scale `2.35` opacity `0`。

首屏渐进揭示：

- `.boot-reveal-item` 默认 `visibility:hidden; opacity:0; transform:translateY(10px)`，transition 为 opacity 320ms + transform 360ms。
- `html[data-first-page-reveal="preparing"] .boot-reveal-item` 禁用 transition。
- `.boot-reveal-item.is-revealed` 设 visible、opacity 1、transform 0。
- `@media(prefers-reduced-motion:reduce)` 中 halo 周期放慢到 2.6s，reveal transition duration 1ms。

### 9.6 响应式断点

必须至少保留这些断点行为：

- `@media (min-width:1471px)`：debug/parts 使用更宽内容区，debug 瀑布流可变 3 列。
- `@media (max-width:980px)`：主要布局降为单列，导航覆盖层宽度仍为左右 page gap 内的全宽。
- `@media (min-width:981px)`：矩阵和保存表情行使用桌面尺寸。
- `@media (max-width:640px)`、`max-width:520px`、`max-width:400px`：逐步缩小 `--control-height`、`--control-font-size`、padding、`--led-preview-default-cell` 和 gap，保证按钮文字不溢出，矩阵仍能在 320px 宽视口内显示。


### 9.7 源码级视觉补遗：动画、发光、响应式与矩阵 CSS 锁定（2026-05-23 追加）

本小节锁定当前 `data/styles.css` 中容易被 Agent 误写成近似效果的视觉细节。

#### 9.7.1 根变量与全局视觉基线

`:root` 必须至少包含并使用以下变量：

```css
--primary-gradient: linear-gradient(135deg, #f971d4, #8f74ff);
--card-shadow: 0 12px 32px #00000035;
--control-height: 44px;
--page-edge-gap: 14px;
--led-preview-edge-ratio: .1000;
--cell: var(--led-preview-default-cell);
--gap: 4px;
```

`@font-face` 必须保留 GNU Unifont 内联 woff2 data URI 和 Ark Pixel 基础字体 `/resources/fonts/ark12.woff2`（缓存破坏 query 例如 `?v=20260612-emoji-input-v3`）。当前实现已不含 `ark12_fallback.woff2` 的回退/别名声明。`body, button, input, select, textarea` 强制使用 `var(--ui-font)`；`#scroll-text` 强制使用 Ark Pixel。

#### 9.7.2 页面切换动画

必须使用当前 keyframes，不得改成仅 opacity 或 display:none 后无动画：

```css
.page { display: none; animation: fade .16s ease-out; }
.page.active { display: block; }
@keyframes fade {
  from { opacity: .4; transform: translateY(4px); }
  to { opacity: 1; transform: none; }
}
```

#### 9.7.3 导航数字霓虹发光

`.nav .num` 默认无光晕，但必须带当前缓动过渡：

```css
.nav .num {
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
  white-space: nowrap;
  text-shadow: none;
  transition: color .18s cubic-bezier(.33, 1, .68, 1), text-shadow .18s cubic-bezier(.33, 1, .68, 1);
}
.top-page-nav.open .nav button.active .num {
  color: #fff;
  text-shadow: 0 0 4px #fff, 0 0 10px rgba(255, 255, 255, .95), 0 0 18px rgba(255, 255, 255, .75);
}
```

#### 9.7.4 按钮、自定义 Select 与 `color-mix` 发光

所有交互式按钮 hover/pressed 视觉必须以 `--button-hover-color` 为源，通过 `color-mix` 生成外发光：

```css
button:hover:not(:disabled) {
  --button-hover-y: -1px;
  border-color: var(--button-hover-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent);
}
button.is-pressing:not(:disabled) {
  --button-hover-y: 0px;
  --button-press-y: 2px;
  --button-press-scale: .985;
  border-color: var(--button-hover-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent);
  filter: brightness(.9);
  transition-duration: 90ms;
}
button.is-releasing:not(:disabled) {
  --button-hover-y: 0px;
  --button-press-y: 0px;
  --button-press-scale: 1;
  filter: brightness(1);
  transition-duration: 150ms;
}
```

自定义 select 激活项必须由 JS 注入的 `--option-color` 控制：

```css
.select-option.active {
  --button-hover-color: var(--option-color, var(--accent));
  border-color: var(--option-color, var(--accent));
  background: linear-gradient(180deg, #172033, #111827);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--option-color, var(--accent)) 28%, transparent), 0 8px 22px #00000028;
}
.select-option.active .num {
  color: var(--option-color, var(--accent));
  text-shadow: 0 0 9px color-mix(in srgb, var(--option-color, var(--accent)) 72%, transparent),
    0 0 18px color-mix(in srgb, var(--option-color, var(--accent)) 36%, transparent);
}
```

#### 9.7.5 响应式断点和防溢出规则

- `@media (min-width:1471px)`：只扩展 `body[data-page="parts"] .content` 与 `body[data-page="debug"] .content` 到 `max-width: 2209px`；不要把 basic 页扩展到 2209px。
- 同一断点下 `.parts-outer-layout` 必须为三列：`grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr)`。
- `@media (max-width:980px)`：`.basic-layout`、`.parts-outer-layout`、`.cols-2` 等主布局回退一列，并降低 `--page-edge-gap`、`--control-height` 等移动端变量。
- `.brightness-row` 必须是 `grid-template-columns: minmax(0, 1fr) 68px`，range 输入 `min-width:0`，数字输入 `width:100%; min-width:0; text-align:center`，保证窄屏滑条不会被固定宽度挤爆。
- 在最窄屏规则里必须允许卡片和矩阵容器取消过大的 `min-width`，以满足 320px 视口。

#### 9.7.6 矩阵 CSS 不得引发布局抖动

- `.matrix-wrap` 通过 CSS 变量管理 `--matrix-default-cell`、`--matrix-min-cell`、`--matrix-max-cell`、`--matrix-max-height`、`--matrix-edge-gap`。
- `.matrix` 必须使用 `display:grid` 与 `gap:var(--gap)`；每个 `.led` 必须使用 `width:var(--cell); height:var(--cell)`，不能用百分比反推。
- `.led.invalid` 表示非物理 LED 空洞；`.led.on` 表示点亮；`.editable-matrix .led.editable` 才允许绘制交互。
- hover、`.on`、`.invalid` 状态不得改写 `--cell` 或 grid template，避免实时预览时整块矩阵抖动。

#### 9.7.7 加载覆盖层 CSS 与 reduced motion

`.boot-reveal-item` 首屏瀑布揭示必须固定为：

```css
.boot-reveal-item {
  visibility: hidden;
  opacity: 0;
  transform: translateY(10px);
  transition: opacity 320ms ease, transform 360ms cubic-bezier(.16, 1, .3, 1);
}
html[data-first-page-reveal="preparing"] .boot-reveal-item { transition: none; }
.boot-reveal-item.is-revealed { visibility: visible; opacity: 1; transform: translateY(0); }
@media(prefers-reduced-motion:reduce) {
  .flash-halo { animation-duration: 2.6s; }
  .boot-reveal-item { transition-duration: 1ms; transform: none; }
}
```

加载覆盖层状态类必须与 JS 一致：`is-assets-pending`、`is-animating`、`is-image-pop`、`is-final-release`、`is-ring-contracting`、`is-halo-hidden`、`is-hidden`、`is-scroll-passthrough`、`is-revealing`。


## 10. 工具函数

`utils.h/.cpp` 必须提供：

- `hexNibble(char)`：返回 0..15 或 -1。
- `parseColorHex(input, r, g, b)`：接受 `#RRGGBB` 或 `RRGGBB`。
- `formatColorHex(r,g,b)`：输出 lowercase 或统一格式 `#rrggbb`。

`psram_json.h` 必须提供一个 PSRAM 优先 JSON 文档封装。当前实现使用 ArduinoJson `BasicJsonDocument` 的自定义 allocator，而不是普通 `DynamicJsonDocument` 回退：

```cpp
#include <ArduinoJson.h>
#include <esp_heap_caps.h>

struct SpiRamAllocator {
    void* allocate(size_t size) {
        void* ptr = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_malloc(size, MALLOC_CAP_8BIT);
    }

    void deallocate(void* pointer) {
        heap_caps_free(pointer);
    }

    void* reallocate(void* pointer, size_t newSize) {
        void* ptr = heap_caps_realloc(pointer, newSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_realloc(pointer, newSize, MALLOC_CAP_8BIT);
    }
};

using PsramJsonDocument = BasicJsonDocument<SpiRamAllocator>;
```

`jsonCapacityFor(bodyLength)` 定义在 `utils.h/.cpp`，规则是至少 32 KB 或 2 倍源字节数，用于 saved_faces 和大 body JSON，并配合各解析点的 nesting limit。

## 11. 资源文件

### 11.1 加载 PNG

必须提供两个 96x96 左右的加载图：

- `/resources/loading/rina_icon1_default.png`
- `/resources/loading/rina_icon2_hover.png`

HTML 需要预加载默认图，并把默认图设为 favicon/shortcut icon。

### 11.2 字体资源

必须提供：

- `/resources/fonts/ark12.woff2`
- `/resources/fonts/ark12.json`
- 可选 `/resources/fonts/ark12.json.gz`
- `/resources/fonts/README.md`

`ark12.json` 必须是 WebUI 可读取的位图字形表。每个 glyph 至少有：

- codepoint
- width
- height 或 rows length
- rows
- xOffset/yOffset/dstY 可选

### 11.3 gzip

构建后 data 中可出现 `.gz` 同级文件，例如：

- `index.html.gz`
- `app.js.gz`
- `styles.css.gz`
- `resources/fonts/ark12.json.gz`

固件必须自动选择 gzip 同级文件，不需要 HTML 引用 `.gz`。

## 12. 功耗估算

WebUI 只做提示，不做固件限流。

估算：

```text
estimatedWatts = litLedCount * channelCount * estimatedWattsPerChannel * (brightness / 255)
channelCount = 5
estimatedWattsPerChannel = 0.06
warning threshold = 40 W
```

超过 40W 时 debug 页显示警告。固件不自动降低亮度。

## 13. 验收标准

### 13.1 固件

- `pio run` 编译通过。
- `pio run -t uploadfs` 可上传 LittleFS。
- 启动后 AP `RinaChanBoard-V2` 可连接。
- 浏览器访问 `http://rina.io/` 或 `http://192.168.1.14/` 显示 WebUI。
- `/api/status` 返回 ok、matrix、renderer、power、storage。
- `/api/frame` 接收合法 M370 并渲染。
- `/api/command` 的 `set_brightness`、`set_color`、`button`、`set_mode` 正常。
- `/api/scroll` 分块上传后 `start_scroll` 可在固件 RAM 中滚动。
- B1/B2/B3/B4/B5 按钮动作正常。
- LittleFS 缺失时显示前 12 颗红色错误图案，并返回错误页面。

### 13.2 WebUI

- 首屏加载动画结束后显示 basic 页面。
- 颜色、亮度、模式、自动播放间隔与固件同步。
- 保存表情列表能读取 `/api/saved_faces`。
- 自定义画板能画、导入、复制、发送、保存。
- 部件拼脸能组合眼睛/嘴/脸颊，能发送和保存。
- 文本滚动能生成 <=3072 帧，24 帧一包上传 RAM，完成后固件滚动；逐帧前进/后退按钮和暂停 toggle 正常；B6 电量覆盖层期间滚动自动系统级暂停并在覆盖层结束后恢复。
- GPIO B1/B2/B3 中断滚动后，scroll 页面能自动停止并同步当前表情。
- Debug 页能显示状态、电源、日志、图案、M370 手动应用。

### 13.3 性能与缓存

- 非 HTML 静态资源响应头为 `public, max-age=31536000, immutable`。
- HTML 响应头为 `no-cache`。
- API 响应为 `no-store`。
- gzip 客户端优先获取 `.gz`。
- 静态文件传输不会触发 watchdog reset。
- M370 高频发送不会突破固件 33 ms 限速，队列满时丢旧保新。

## 14. 重建提示

如果根据本文档从零生成代码，推荐顺序：

1. 先生成 `config`、`state`、`sync`、`utils`。
2. 再实现 `led_renderer`，用串口测试 M370 解析和物理映射。
3. 加入 `storage` 和最小 `saved_faces.json`，启动后渲染启动表情。
4. 加入 `scroll` 渲染任务，验证主任务帧优先于滚动帧。
5. 加入 `power_monitor`，先串口输出 ADC/电压/百分比，再接 API。
6. 加入 `buttons` 和 `faces` 模式逻辑。
7. 加入 `web_api`，先 status/frame/command，再 scroll/saved_faces/static gzip。
8. 最后生成 WebUI：先 basic + 矩阵预览，再 custom/parts/scroll/debug。

重建时以本文件的常量、路径、API 字段名、JSON schema、M370 编码、锁顺序、启动顺序为准。

## 15. 当前实现对齐补遗：单一事实来源锁定版（2026-06-11）

> 本章节由当前实现逆向抽取生成，用于修正 `plan.md` 与实际代码之间的剩余偏差。后续开发以本章节和前文规格共同作为重建依据；如二者冲突，以本章节中“当前实现锁定值”为准。严禁因为本章节暴露了源代码而重构现有程序：本次任务只允许修改 `plan.md`。

### 15.1 对齐结论与重建口径

- 当前项目是 **ESP32-S3 + Arduino + PlatformIO + LittleFS + AP-only WebUI** 固件。
- WebUI 当前实现是 `data/index.html` 单文件 DOM + `data/app.js` 外置浏览器运行时 + `data/styles.css` 单文件 CSS。没有 npm/打包器，但有外置 JS 静态资源。
- `data/index.html.gz`、`data/app.js.gz`、`data/styles.css.gz`、`data/resources/fonts/ark12.json.gz` 是 `scripts/gzip_webui_assets.py` 在 LittleFS 镜像构建期间临时生成并随后清理的产物，不能人工维护。
- `saved_faces.json` 是默认表情和用户表情的唯一统一存储源；默认表情使用 `type: "default"`，可重命名/排序/应用，但前端不得删除。
- 文字滚动使用 `/resources/fonts/ark12.json` 字形表（融合 CJK 补丁 + Mona12 单色 emoji，WebUI 端字体模型 token 为 `ark_pixel_12px_fusion_bitmap_v4`）；WebUI 通用字体使用内嵌 GNU Unifont 子集。字体二进制载荷必须由工具链生成并写入 CSS/资源文件，本文档不展开二进制字体字节。`styles.css` 中 Ark Pixel `@font-face` 的 `unicode-range` 由工具链按合并后的 cmap 重新生成，不应手工维护。
- `data/app.js` / `data/styles.css` 已经过 Prettier 风格统一（双引号、尾随逗号、折行）；本章及第 8/9 节的源码片段以**行为与字面值**为准，引号与换行风格按当前源码为准，不构成重建偏差。
- 如果一个开发者或代码生成 Agent 需要从零重建，必须按以下顺序执行：
  1. 创建本文档列出的目录和文件。
  2. 按本章和前文规范写入 `platformio.ini`、`src/*`、`scripts/*`、`tools/*`、`data/index.html`、`data/app.js`、`data/styles.css`、JSON 资源。
  3. 运行字体资源构建链，生成/注入 GNU Unifont 子集和 Ark Pixel 字体资源。
  4. 运行 PlatformIO LittleFS target，由 `scripts/gzip_webui_assets.py` 生成并清理 gzip 静态资源。
  5. 用 PlatformIO `esp32s3` 环境构建并上传固件/LittleFS。

### 15.2 当前文件清单与维护边界

原 `plan.md` 在此处保存过一份文件大小 + SHA256 快照表，用于确认实现未被误改。由于源文件和字体资源在多次迭代后已发生变化（例如 `ark12.json`、`ark12.woff2` 体积都已增大），该哈希表早已过期，因此本版本移除哈希表，改为只锁定“哪些文件是可维护源、哪些是生成物”的边界；任何固定的字节数/哈希值都不应写回本文档，因为它们会随每次构建变化。

可维护源（重建依据）：

- 构建/分区：`platformio.ini`、`partitions.csv`。
- 固件源：`src/*.h`、`src/*.cpp`（含 `button_animations.*`）。
- 构建脚本：`scripts/patch_webserver_timeout.py`、`scripts/gzip_webui_assets.py`。
- 字体工具链：`tools/*.py`、`tools/font_fusion/`、`run_rinachan_unifont.sh`、`run_rinachan_unifont.ps1`。
- WebUI 源：`data/index.html`、`data/app.js`、`data/styles.css`。
- JSON 资源：`data/resources/saved_faces.json`、`runtime_settings.json`、`battery_calib.json`。
- 字体/图片资源：`data/resources/fonts/ark12.woff2`、`ark12.json`、`fonts/README.md`、`data/resources/loading/rina_icon1_default.png`、`rina_icon2_hover.png`。
- 许可声明：`licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt`。

非源（本地缓存或构建生成物，不作为重建依据）：

- 各 `*.gz`（`data/index.html.gz`、`data/app.js.gz`、`data/styles.css.gz`、`data/resources/fonts/ark12.json.gz`）由 `scripts/gzip_webui_assets.py` 在 LittleFS 镜像构建期间生成并随后清理。
- `.pio/`、`.vscode/`、`.font_cache/`、空文件 `pio`。

`data/index.html`、`data/app.js`、`data/styles.css` 引用静态资源时带缓存破坏 query（如 `?v=20260612-...`）。这些 token 每次发布都会变化，属于易变值，重建时按当前实现取用即可，不应被当作固定常量硬编码。

### 15.3 WebUI DOM、挂载点与页面结构锁定

#### DOM `id` 清单

`loadingOverlay`, `blurScreen`, `avatarBefore`, `avatarAfter`, `badge-battery`, `badge-battery-dot`, `badge-battery-label`, `badge-charging`, `badge-charging-dot`, `badge-charging-label`, `brand-nav-toggle`, `top-page-nav`, `nav-shell`, `nav`, `page-basic`, `color-swatch`, `color-input`, `parent-color-select`, `child-color-select`, `brightness-reset-default`, `brightness-minus`, `brightness-plus`, `brightness-range`, `brightness-input`, `brightness-presets`, `face-prev`, `face-next`, `mode-toggle`, `interval-down`, `interval-up`, `auto-interval-range`, `auto-interval`, `auto-interval-presets`, `matrix-basic`, `page-custom`, `custom-send`, `custom-live-toggle`, `custom-clear`, `custom-fill`, `custom-invert`, `matrix-custom-edit`, `custom-m370`, `custom-copy`, `custom-import`, `custom-save`, `custom-name`, `page-parts`, `parts-apply`, `parts-live-toggle`, `parts-random`, `parts-reset`, `parts-symmetry-toggle`, `parts-preview-card`, `matrix-parts`, `part-groups`, `parts-m370-text`, `parts-copy-m370`, `parts-import-m370`, `parts-save-bottom`, `parts-name`, `page-scroll`, `matrix-scroll`, `scroll-text`, `scroll-speed-reset-default`, `scroll-speed-minus`, `scroll-speed-plus`, `scroll-speed-range`, `scroll-speed`, `scroll-speed-presets`, `scroll-play`, `scroll-pause`, `scroll-stop`, `scroll-step-prev`, `scroll-step-next`, `scroll-upload-progress`, `scroll-upload-bar`, `scroll-upload-label`, `scroll-state`, `scroll-frame-index`, `page-debug`, `state-kv`, `dps-warning`, `debug-all-off`, `debug-all-on`, `debug-checker`, `debug-border`, `debug-current-face`, `debug-m370`, `debug-apply-m370`, `debug-copy-status`, `debug-reset-storage`, `debug-kv`, `debug-refresh-power`, `debug-reset-battery-min`, `debug-reset-battery-max`, `battery-v`, `charge-v`, `update-adc`, `matrix-debug`, `serial-input`, `serial-send`, `log-clear`, `log-download`, `log`, `firmware-kv`, `firmware-ping`, `firmware-pause`, `resource-kv`, `parts-list-${key}`

#### 静态 class 清单

`loading-overlay`, `is-assets-pending`, `blur-screen`, `loading-box`, `loader-stage`, `flash-halo`, `avatar-circle`, `avatar-before`, `avatar-after`, `loading-text`, `sidebar`, `brand`, `brand-copy`, `row`, `badge`, `mono`, `status-dot`, `dim`, `brand-nav-toggle`, `menu-icon`, `top-page-nav`, `nav-shell`, `nav`, `app`, `content`, `page`, `active`, `hero`, `basic-layout`, `control-panel`, `card`, `control-section`, `flush`, `color-control-row`, `color-swatch`, `field`, `color-dropdown-grid`, `select-shell`, `select-caret`, `slider-step-row`, `compact-btn`, `push-right`, `brightness-row`, `slider-number`, `button-row`, `mode-button-row`, `toggle-button`, `basic-preview-card`, `led-preview-card`, `matrix-wrap`, `fill-column`, `led-preview-wrap`, `matrix`, `primary`, `grid`, `cols-2`, `stack`, `face-manager-panel`, `ok`, `faces-json-load`, `faces-json-open-local`, `faces-json-save-local`, `faces-json-download-all`, `faces-json-import-btn`, `faces-json-import-file`, `list`, `face-library-list`, `parts-outer-layout`, `parts-left-col`, `parts-manager-col`, `scroll-upload-progress`, `scroll-upload-label`, `kv`, `k`, `debug-layout`, `status-merged`, `warning`, `hint`, `danger`, `debug-measure-card`, `debug-measure-grid`, `debug-measure-controls`, `debug-log-card`, `log`, `num`, `select-label`, `face-source-badge`, `part-list`, `part-meta`, `part-display-id`, `part-mini`, `&&`, `rows[y][x]==='#'?'`

#### HTML 结构要求

- `<html>` 初始属性必须为 `data-boot-phase="preload" data-scroll-lock="boot" lang="zh-CN"`。
- `<head>` 必须预加载 `/resources/loading/rina_icon1_default.png`，并将 favicon/shortcut icon 指向同一文件。
- `loadingOverlay` 必须位于 `body` 最前，内部包含 `blurScreen`、双层头像 `avatarBefore/avatarAfter`、加载环、加载文字。
- Sidebar/brand 区必须包含电池状态徽章和充电状态徽章，并在首屏揭示前已可根据启动状态渲染。
- 主页面固定为 `page-basic`、`page-custom`、`page-parts`、`page-scroll`、`page-debug` 五页；所有页面切换通过 `PAGES` 和 `.page.active` 控制，不创建路由框架。
- LED 预览挂载点固定为 `matrix-basic`、`matrix-custom-edit`、`matrix-parts`、`matrix-scroll`、`matrix-debug`。各自的 wrapper 必须保持 `matrix-wrap`、`led-preview-wrap`、`matrix` 层级。

### 15.4 WebUI JS 状态、生命周期、队列与 API 锁定

#### 必须保留的全局配置/数据块

#### JS `WEBUI_CONFIG`

~~~~javascript
const WEBUI_CONFIG = Object.freeze({
  faces: {
    resourcePath: '/resources/saved_faces.json',
    localFilename: 'saved_faces.json',
    schemaFormat: 'rina_faces_370_v2',
    startupFaceId: 'face_07_triangle_eyes_frown'
  },
  device: {
    apSsid: 'RinaChanBoard-V2',
    apPassword: 'rinachan',
    apDomain: 'rina.io',
    defaultApIp: '192.168.1.14'
  },
  navigation: {
    pages: [
      ['basic', '6.1', '基础功能'],
      ['custom', '6.2', '自定义表情'],
      ['parts', '6.3', '表情部件'],
      ['scroll', '6.4', '文字滚动'],
      ['debug', '6.5', '调试']
    ]
  },
  led: {
    defaultColor: '#f971d4',
    defaultBrightness: 50,
    minBrightness: 10,
    maxBrightness: 200,
    estimatedWattsPerChannel: 0.06,
    channelCount: 5,
    fullBrightness: 255,
    powerWarningWatts: 40,
    previewSize: {
      defaultCell: 18,
      minCell: 5,
      maxCell: 48,
      minWidth: 320,
      maxHeight: 500,
      edgeGap: 12
    }
  },
  autoInterval: {
    minMs: 500,
    maxMs: 10000,
    buttonStepMs: 500,
    presetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000]
  },
  api: {
    getTimeoutMs: 2500,
    postTimeoutMs: 5000,
    uploadTimeoutMs: 15000,
    bootStatusTimeoutMs: 2500,
    runtimeStatusQuery: '?runtimeOnly=1&noFrame=1',
    endpoints: {
      frame: '/api/frame',
      command: '/api/command',
      scroll: '/api/scroll',
      savedFaces: '/api/saved_faces',
      power: '/api/power',
      status: '/api/status'
    }
  },
  layout: {
    oneColumnMaxPx: 980,
    threeColumnsMinPx: 1471
  },
  firmwareQueues: {
    m370SendIntervalMs: 45,
    m370QueueMax: 3,
    buttonCommandIntervalMs: 120,
    buttonCommandQueueMax: 4,
    scrollButtonStopFullSyncDelayMs: 140
  },
  scroll: {
    defaultFps: 10,
    fpsMin: 1,
    fpsMax: 60,
    fpsPresets: [1, 10, 20, 30, 40, 50, 60],
    firmwareMaxFramesDefault: 3072,
    uploadChunkFrames: 24,
    maxTextChars: 1000
  },
  textScroll: {
    fontModel: 'ark_pixel_12px_fusion_bitmap_v4',
    fontResource: '/resources/fonts/ark12.json',
    fontFamily: 'Ark Pixel 12px Monospaced',
    fontFallbackFamily: '',
    browserFontSample: 'RinaChanBoard 370 LED \u7ee7\u7eed \u6682\u505c \u3053\u3093\u306b\u3061\u306f \u7483\u5948\u3061\u3083\u3093\u30dc\u30fc\u30c9 \u7136\u71c3\u6eda\u6efe \ud83c\udfe0\ufe0e\ud83d\ude00\ufe0e',
    browserFallbackFontSample: '',
    charSpacing: 0,
    spaceColumns: 6,
    missingGlyphCodePoint: 0x25A1
  },
  fonts: {
    uiFamily: 'GNU Unifont'
  },
  interaction: {
    buttonPressDownMs: 90,
    buttonPressUpMs: 150,
    selectMenuHideDelayMs: 260,
    pageScrollKeys: ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Home', 'End', ' ']
  },
  boot: {
    loadingIconBefore: './resources/loading/rina_icon1_default.png',
    loadingIconAfter: './resources/loading/rina_icon2_hover.png',
    holdMs: 260,
    haloBreathMs: 1620,
    haloPeakRatio: 0.5,
    haloToleranceMs: 24,
    haloContractMs: 520,
    imageReleaseMs: 2100,
    blurDurationMs: 850,
    extraMs: 180,
    minDisplayMs: 400,
    firstPageRevealSelector: [
      '.sidebar',
      '#page-basic .hero',
      '#page-basic .basic-preview-card',
      '#page-basic .control-panel > .card.control-section'
    ]
  },
  power: {
    statusRefreshMs: 900
  }
});
~~~~
#### JS `API_ENDPOINTS`

~~~~javascript
const API_ENDPOINTS = Object.freeze(WEBUI_CONFIG.api.endpoints);
~~~~
#### JS `MATRIX_VIEW_CONFIGS`

~~~~javascript
const MATRIX_VIEW_CONFIGS = [
  ['matrix-basic', () => currentFrame, false, null, false],
  ['matrix-custom-edit', () => editFrame, true, editCell, false],
  ['matrix-parts', () => partsFrame, false, null, false],
  ['matrix-scroll', () => scrollFrame, false, null, false],
  ['matrix-debug', () => currentFrame, false, null, false]
];
~~~~
#### JS `RUNTIME_STATUS_QUERY`

~~~~javascript
const RUNTIME_STATUS_QUERY = WEBUI_CONFIG.api.runtimeStatusQuery;
~~~~
#### JS `parent_color_groups`

~~~~javascript
const parent_color_groups = [{
  id: 0,
  name: '默认璃奈粉色',
  color: 'f971d4',
  desc: '父级颜色按钮，仅提供父级色'
}, {
  id: 1,
  name: "μ's-洋红色",
  color: 'e4007f',
  desc: "μ's 子颜色组"
}, {
  id: 2,
  name: 'Aqours-水蓝色',
  color: '00a1e8',
  desc: 'Aqours / Saint Snow / 子团体颜色组'
}, {
  id: 3,
  name: '虹咲学园-金色',
  color: 'f8b656',
  desc: '虹咲 / 子团体颜色组'
}, {
  id: 4,
  name: 'Liella!-紫色',
  color: 'a5469b',
  desc: 'Liella! / 子团体颜色组'
}, {
  id: 5,
  name: '蓮ノ空-粉色',
  color: 'fb8a9b',
  desc: '蓮ノ空 子颜色组'
}];
~~~~
#### JS `child_color_groups`

~~~~javascript
const child_color_groups = {
  1: [
    ['高坂穗乃果-橙色', 'f38500'],
    ['绚濑绘里-水蓝色', '7aeeff'],
    ['南小鸟-白色', 'cebfbf'],
    ['园田海未-蓝色', '1769ff'],
    ['星空凛-黄色', 'fff832'],
    ['西木野真姬-红色', 'ff503e'],
    ['东条希-紫罗兰色', 'c455f6'],
    ['小泉花阳-绿色', '6ae673'],
    ['矢泽妮可-粉色', 'ff4f91']
  ],
  2: [
    ['高海千歌-蜜柑色', 'ff9547'],
    ['樱内梨子-樱花粉色', 'ff9eac'],
    ['松浦果南-祖母绿色', '27c1b7'],
    ['黑泽黛雅-红色', 'db0839'],
    ['渡边曜-亮蓝色', '66c0ff'],
    ['津岛善子-白色', 'c1cad4'],
    ['国木田花丸-黄色', 'ffd010'],
    ['小原鞠莉-紫罗兰色', 'c252c6'],
    ['黑泽露比-粉色', 'ff6fbe'],
    ['CYaRon!-橙色', 'ffa434'],
    ['AZALEA-粉色', 'ff5a79'],
    ['Guilty Kiss-紫色', '825deb'],
    ['YYY-绿色', '53ab7f'],
    ['鹿角圣良-天蓝色', '00ccff'],
    ['鹿角理亚-纯白色', 'bbbbbb'],
    ['Saint Snow-红色', 'cb3935']
  ],
  3: [
    ['上原步梦-浅粉色', 'ed7d95'],
    ['中须霞-蜡笔黄色', 'e7d600'],
    ['樱坂雫-浅蓝色', '01b7ed'],
    ['朝香果林-皇室蓝色', '485ec6'],
    ['宫下爱-超橙色', 'ff5800'],
    ['近江彼方-堇色', 'a664a0'],
    ['优木雪菜-猩红色', 'd81c2f'],
    ['艾玛·维尔德-浅绿色', '84c36e'],
    ['天王寺璃奈-纸白色', '9ca5b9'],
    ['三船栞子-翡翠色', '37b484'],
    ['米雅·泰勒-白金银色', 'a9a898'],
    ['钟岚珠-玫瑰金色', 'f8c8c4'],
    ['DiverDiva-银紫色', 'ab76f7'],
    ['A·ZU·NA-意大利红色', 'ff0042'],
    ['QU4RTZ-奶茶色', 'd9db83'],
    ['R3BIRTH-坦桑蓝色', '424a9d']
  ],
  4: [
    ['涩谷香音-金盏花色', 'ff7f27'],
    ['唐可可-蜡笔蓝色', 'a0fff9'],
    ['岚千砂都-桃粉色', 'ff6e90'],
    ['平安名堇-蜜瓜绿色', '74f466'],
    ['叶月恋-宝石蓝色', '0000a0'],
    ['樱小路希奈子-玉米黄色', 'fff442'],
    ['米女芽衣-胭脂红色', 'ff3535'],
    ['若菜四季-冰绿白色', 'b2ffdd'],
    ['鬼冢夏美-鬼夏粉色', 'ff51c4'],
    ['薇恩·玛格丽特-优雅紫色', 'e49dfd'],
    ['鬼冢冬毬-烟熏蓝色', '4cd2e2'],
    ['CatChu!-红色', 'e8243c'],
    ['KALEIDOSCORE-浅紫色', 'bcbcde'],
    ['5yncri5e!-黄色', 'ffe840']
  ],
  5: [
    ['日野下花帆-太阳色', 'f8b500'],
    ['村野沙耶香-冰蓝色', '5383c3'],
    ['乙宗梢-人鱼绿色', '68be8d'],
    ['夕雾缀理-我的红色', 'ba2636'],
    ['大泽瑠璃乃-瑠璃粉色', 'e7609e'],
    ['藤岛慈-天使白色', 'c8c2c6'],
    ['百生吟子-天之原色', 'a2d7dd'],
    ['徒町小铃-长庚星色', 'fad764'],
    ['安养寺姬芽-糖果紫色', '9d8de2'],
    ['Cerise Bouquet-玫瑰色', 'da645f'],
    ['DOLLCHESTRA-蓝色', '163bca'],
    ['Mira-Cra Park!-黄色', 'f3b171']
  ]
};
~~~~

#### 关键生命周期与 API 函数

#### JS function `initDeferredUiAfterShow`

~~~~javascript

function initDeferredUiAfterShow() {
  if (deferredUiInitialized) return;
  deferredUiInitialized = true;
  initializeMatrixViews();
  basicPreviewMatrixInitialized = true;
  observeMatrixWraps();
  initCustom();
  initParts();
  initScroll();
  initializeDebugControls();
  renderSavedFaces();
  renderMatrices();
  renderState();
  fitAllMatrices();
}
~~~~
#### JS function `buildTextScrollBitmap`

~~~~javascript

function buildTextScrollBitmap(text) {
  const key = `${text}@@${TEXT_SCROLL_FONT_MODEL}@@${arkPixelFont.source}@@centerY${textScrollVerticalOffset()}`;
  if (buildTextScrollBitmap.cacheKey === key && buildTextScrollBitmap.cache) return buildTextScrollBitmap.cache;
  if (!arkPixelFont.ready) throw new Error('Ark Pixel Font bitmap table is not ready');
  const rawChars = Array.from(text || ' ').filter(
    ch => !isEmojiFormatControl(codePointOfChar(ch))
  );
  const glyphs = rawChars.map(ch => buildTextGlyph(ch));
  const leadingBlank = COLS + 4;
  const trailingBlank = COLS + 4;
  let contentWidth = 0;
  for (let i = 0; i < glyphs.length; i++) {
    contentWidth += glyphs[i].advance;
    const next = glyphs[i + 1];
    if (next && !glyphs[i].isSpace && !next.isSpace) contentWidth += TEXT_SCROLL_CHAR_SPACING;
  }
  const width = Math.max(COLS * 2 + 8, leadingBlank + contentWidth + trailingBlank);
  const bitmap = Array.from({
    length: ROWS
  }, () => Array(width).fill(false));
  let x = leadingBlank;
  for (let i = 0; i < glyphs.length; i++) {
    const g = glyphs[i];
    if (!g.isSpace) blitGlyphBitmap(bitmap, x, g);
    x += g.advance;
    const next = glyphs[i + 1];
    if (next && !g.isSpace && !next.isSpace) x += TEXT_SCROLL_CHAR_SPACING;
  }
  buildTextScrollBitmap.cacheKey = key;
  buildTextScrollBitmap.cache = {
    bitmap,
    width,
    glyphs,
    contentWidth
  };
  return buildTextScrollBitmap.cache;
}
~~~~
#### JS function `stopScroll`

~~~~javascript

function stopScroll() {
  const shouldRestoreAuto = state.restoreAutoAfterScroll || isAutoModeValue(state.mode);
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.active = false;
  scroll.paused = false;
  scroll.userPaused = false;
  scroll.systemPaused = false;
  scroll.firmwareBacked = false;
  scroll.uploading = false;
  scroll.dirtyNoticeLogged = false;
  scroll.offset = 0;
  scroll.frameIndex = 0;
  resetScrollUploadProgress();
  scroll.frames = [];
  scroll.signature = '';
  scroll.dirty = true;
  state.textScrollActive = false;
  state.refreshPolicy = 'dirty-frame / 按需刷新';
  scrollFrame = blankFrame();
  currentFrame = blankFrame();
  state.lastRefreshReason = 'text_scroll_stopped_clear';
  state.playback = 'idle';
  renderMatrices();
  updateM370Views();
  updateScrollUi();
  renderState();

  const didApplyDefault = applyStartupDefaultFaceLocal('text_scroll_stop_default_saved_face');
  state.playback = shouldRestoreAuto ? 'auto_saved_face' : 'idle';
  state.mode = shouldRestoreAuto ? 'auto' : 'manual';
  state.restoreAutoAfterScroll = false;
  sendAuxCommand('stop_scroll', {
    clear: true,
    restoreAuto: shouldRestoreAuto
  }, 'text_scroll_stopped_clear');
  renderSavedFaces();
  updateScrollUi();
  renderState();
  log(shouldRestoreAuto ?
    `文字滚动停止/清屏，已清空并回到默认表情，返回 A 自动保存表情切换模式${didApplyDefault ? '，从默认表情开始循环' : ''}` :
    `文字滚动停止/清屏，已清空并回到默认表情，返回 M 手动保存表情模式${didApplyDefault ? '，保持不自动切换' : ''}`);

}
~~~~
#### JS function `initializeMatrixViews`

~~~~javascript
function initializeMatrixViews() {
  matrixViews = [];
  initMatrix('matrix-basic', () => currentFrame, false, null, false);
  initMatrix('matrix-custom-edit', () => editFrame, true, editCell, false);
  initMatrix('matrix-parts', () => partsFrame, false, null, false);
  initMatrix('matrix-scroll', () => scrollFrame, false, null, false);
  initMatrix('matrix-debug', () => currentFrame, false, null, false);
}
~~~~
#### JS function `fitMatrix`

~~~~javascript

function fitMatrix(view) {
  const wrap = view.el.closest('.matrix-wrap');
  if (!wrap) return;
  const wrapStyle = getComputedStyle(wrap);
  const cs = getComputedStyle(view.el);
  const gap = parseFloat(cs.getPropertyValue('--gap')) || (view.compact ? 2 : 3);
  const defaultCell = view.compact ? 8 : matrixSizeNumber(wrapStyle, '--matrix-default-cell', LED_PREVIEW_SIZE
    .defaultCell);
  const minCell = view.compact ? 4 : matrixSizeNumber(wrapStyle, '--matrix-min-cell', LED_PREVIEW_SIZE.minCell);
  const cssMaxCell = matrixSizeNumber(wrapStyle, '--matrix-max-cell', LED_PREVIEW_SIZE.maxCell);
  const configuredMaxHeight = matrixSizeNumber(wrapStyle, '--matrix-max-height', LED_PREVIEW_SIZE.maxHeight);
  const maxCell = view.compact ? 12 : cssMaxCell;
  const edgeRatioRaw = parseFloat(wrapStyle.getPropertyValue('--led-preview-edge-ratio'));
  const edgeRatio = Number.isFinite(edgeRatioRaw) && edgeRatioRaw >= 0 ? edgeRatioRaw : 0.1000;

  // 平滑实时缩放：保持透明内边距与 --cell 成比例。
  // 适配公式会在包装层内预留 2 * edgeRatio * cell，
  // 因此 LED 矩阵边距会随 LED 网格一起缩放，
  // 不会在卡片尺寸变化时保持固定。
  const wrapRect = wrap.getBoundingClientRect();
  if (wrapRect.width <= 0 || wrap.offsetParent === null) {
    const cell = clamp(defaultCell, minCell, maxCell);
    const edgeGap = cell * edgeRatio;
    view.el.style.setProperty('--cell', cell.toFixed(4) + 'px');
    view.el.dataset.cellPx = cell.toFixed(4);
    wrap.style.setProperty('--matrix-edge-gap', edgeGap.toFixed(4) + 'px');
    return;
  }

  const borderX = (parseFloat(wrapStyle.borderLeftWidth) || 0) + (parseFloat(wrapStyle.borderRightWidth) || 0);
  const borderY = (parseFloat(wrapStyle.borderTopWidth) || 0) + (parseFloat(wrapStyle.borderBottomWidth) || 0);
  const widthBudget = Math.max(1, wrapRect.width - borderX);
  const maxContentHeight = matrixMaxContentHeight(wrap, configuredMaxHeight);
  const heightBudget = Number.isFinite(maxContentHeight) ? Math.max(1, maxContentHeight - borderY) : Infinity;
  const widthDenom = COLS + 2 * edgeRatio;
  const heightDenom = ROWS + 2 * edgeRatio;
  const cellByWidth = (widthBudget - gap * (COLS - 1)) / widthDenom;
  const cellByHeight = Number.isFinite(heightBudget) ? (heightBudget - gap * (ROWS - 1)) / heightDenom : Infinity;
  const fitCell = Math.min(cellByWidth, cellByHeight, maxCell);
  const cell = clamp(fitCell, minCell, maxCell);
  const edgeGap = cell * edgeRatio;
  view.el.style.setProperty('--cell', cell.toFixed(4) + 'px');
  view.el.dataset.cellPx = cell.toFixed(4);
  wrap.style.setProperty('--matrix-edge-gap', edgeGap.toFixed(4) + 'px');
}
~~~~

#### 事件监听器清单

以下按功能簇列出当前 `data/app.js` 的全部 `addEventListener` 注册点（行号会随迭代漂移，仅列目标/事件/用途；重建时必须全部存在）：

~~~~text
bindControls 内部:          el.addEventListener(eventName, handler)
按压动画:                   document pointerdown / pointerup / pointercancel / keydown / keyup
loading 图片解码:           img load / error（waitForImage）
loader 中心同步:            window resize、visualViewport resize、visualViewport scroll → scheduleLoaderCenterSync
轮询清理:                   window pagehide → stopPollingTimers
导航菜单关闭:               document click、document keydown(Escape)
custom select:              sel change → refreshAllCustomSelects；document click / keydown(Escape) → closeCustomSelects；
                            document touchmove(blockPageTouchMoveWhileSelectOpen, passive:false)；
                            window wheel(blockPageWheelWhileSelectOpen, passive:false)；
                            window resize → resizeReposition；visualViewport resize/scroll → reposition；
                            window scroll → verticalOnly reposition（selectScrollLock 时跳过）
矩阵自适应 + debug masonry: window resize / orientationchange → onResize 与 scheduleDebugMasonryLayout(true)；
                            visualViewport resize → onResize 与 scheduleDebugMasonryLayout()；visualViewport scroll → onResize
matrix cell 编辑:           el click（editable cell）
亮度等数字输入:             input input / change
face 拖拽排序 handle:       pointerdown / pointermove / pointerup / pointercancel
face 重命名输入:            change / blur / keydown
滚动文本输入 #scroll-text:  input / change / paste
FPS 滑条 #scroll-speed-range: input（与数字框双向同步）
FPS 输入 #scroll-speed:     keydown / beforeinput / input / paste / change / blur
滚动输入自适应:             window resize → autoResizeScrollTextInput
入口:                       document DOMContentLoaded → bootstrapWebUi
~~~~

#### JS 功能完整性要求

- DOM 查询只通过 `$()` 或局部 `document.getElementById/querySelector` 进行，不引入框架。
- `bindControls()` 必须使用 `WeakMap<Element, Set<string>>` 避免重复绑定；`setClickHandlers()` 直接覆盖目标元素 `onclick`，当前实现不使用 `data-click-bound`。
- 所有按钮必须经过按压动画系统：pointerdown 触发 `.is-pressing`，pointerup/cancel/leave 按最小时长补齐释放动画。
- `apiGet/apiPost/apiPostWithTimeout` 必须包含 AbortController 超时、离线 HTML 模式拦截、JSON 解析失败错误、HTTP 非 2xx 错误日志节流。
- `/api/frame` 发送必须通过 `enqueueFrameSend` 队列节流：保留最近帧，避免并发 POST；custom/parts 实时发送都走同一队列。
- WebUI 模拟实体按钮命令必须通过 `enqueueButtonCommand` 队列节流：命令间隔、队列长度和进行中状态必须和当前实现一致。
- 当固件进入文字滚动播放时，基础页按钮、custom 实时发送、parts 实时发送必须避免覆盖滚动状态；按 B1/B2/B3 后前端必须检测 `scrollStopEventSeq` 并停止/复位滚动 UI。
- `initializeMatrixViews()` 创建所有 LED 预览；`fitMatrix()` 必须按 CSS 变量中的 min-width/max-height/edge-ratio 实时缩放，监听 resize/orientationchange/visualViewport。
- 文字滚动需同时支持浏览器字体预览和 Ark Pixel JSON 字体表；上传固件时必须按分块发送 `/api/scroll`，首块 `append=false`，后续块 `append=true`，最后才执行播放命令。
- 表情库需按 `type` 分 default/user；保存时写回 `/api/saved_faces`；拖拽排序、重命名、保存当前表情、导入/导出 JSON 必须保留。
- debug 页必须保留电源刷新、电池 min/max 重置、debug 图案、M370 应用/复制、firmware/resource KV、日志清空/下载。

### 15.5 CSS、动画、布局与交互状态锁定

#### CSS keyframes

~~~~css
@keyframes fade {
    from {
      opacity: .4;
      transform: translateY(4px)
    }

    to {
      opacity: 1;
      transform: none
    }
  }
@keyframes rinaBoot-pulseRingBreath {
    0% {
      opacity: .28;
      transform: scale(.965);
      animation-timing-function: cubic-bezier(.42, 0, .58, 1);
    }

    50% {
      opacity: 1;
      transform: scale(1.075);
      animation-timing-function: cubic-bezier(.42, 0, .58, 1);
    }

    100% {
      opacity: .28;
      transform: scale(.965);
    }
  }
@keyframes rinaBoot-haloContractOut {
    0% {
      transform: scale(1.075);
      opacity: 1;
      visibility: visible;
    }

    100% {
      transform: scale(.65);
      opacity: 0;
      visibility: visible;
    }
  }
@keyframes rinaBoot-avatarShrinkThenRelease {
    0% {
      transform: scale(1.22);
      opacity: 1;
      animation-timing-function: cubic-bezier(.34, 0, .2, 1);
    }

    18% {
      transform: scale(1.12);
      opacity: 1;
      animation-timing-function: cubic-bezier(.12, .88, .18, 1);
    }

    100% {
      transform: scale(2.35);
      opacity: 0;
    }
  }
~~~~

#### Media query 入口

~~~~css
@media (min-width:1471px) {
@media (max-width:980px) {
@media (min-width:1471px) {
@media (max-width:980px) {
@media (min-width:981px) {
@media (max-width:520px) {
@media (hover:none),
  (pointer:coarse) {
@media (max-width:640px) {
@media (max-width:400px) {
@media(prefers-reduced-motion:reduce) {
~~~~

#### CSS 必须满足的像素/交互规则

- 全局背景 `--bg: #0f1117`，面板 `#161a24/#1e2430`，强调色 `#f971d4`，次强调色 `#77d7ff`。
- 所有 UI 控件默认使用 `GNU Unifont`；文字滚动文本输入和预览使用 `Ark Pixel 12px Monospaced`。
- `.loading-overlay` 必须有 pending/ready/revealing/hidden 阶段类；遮罩在启动期间锁定 body 滚动，揭示完成后移除锁。
- 加载环颜色为 `#f971d4` 系列，背景高斯/遮罩为深灰，不得出现原加载进度条。
- 头像层级必须在加载环之上；切换时如果有空窗期，头像背景下方必须由不透明白色填充，不能露出加载环。
- 卡片使用 `border-radius: 16px/18px/20px` 系列、`box-shadow: var(--card-shadow)`；按钮 hover 使用 `--button-hover-color`，active/pressing 有 transform/brightness 反馈。
- LED 矩阵不显示外框；缩放只改变矩阵本体和卡片内部距离，不允许裁切任意 LED 单元格。
- LED 预览的最小横向适配宽度为 320px，最大预览高度为 500px，默认 cell 为 18px，min cell 为 5px，max cell 为 48px，edge ratio 为 0.1000。
- 保存表情索引不显示外框且字号较大；拖拽条必须是三横/handle 样式，不使用旧的点阵 `⠿`。
- debug 页瀑布流必须根据视口动态重排；低宽度下一列，高宽度多列，不允许卡片互相重叠。

### 15.6 固件 HTTP 路由、API 命令与后端状态锁定

#### endpoint JSON 注入块

~~~~cpp
    if (runtimeOnly) {
        sendJsonDocument(200, doc);
        return;
    }

    JsonObject matrix = doc.createNestedObject("matrix");
    matrix["leds"]                   = LED_COUNT;
    matrix["m370HexChars"]           = M370_HEX_CHARS;
    matrix["gpio"]                   = LED_PIN;
    matrix["m370BitOrder"]           = "logical_row_major";
    matrix["physicalWiring"]         = SERPENTINE_WIRING ? "serpentine" : "linear";
    matrix["serpentineOddRowsReversed"] = SERPENTINE_ODD_ROWS_REVERSED;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"]      = "/api/frame";
    endpoints["command"]    = "/api/command";
    endpoints["scroll"]     = "/api/scroll";
    endpoints["savedFaces"] = "/api/saved_faces";
    endpoints["power"]      = "/api/power";
    endpoints["status"]     = "/api/status";

    JsonObject storage = doc.createNestedObject("storage");
~~~~

#### 命令路由表

~~~~cpp
static const ApiCommandRoute API_COMMAND_ROUTES[] = {
    {"set_color",                  commandSetColor},
    {"set_brightness",             commandSetBrightness},
    {"set_mode",                   commandSetMode},
    {"set_auto_interval",          commandSetAutoInterval},
    {"set_scroll_interval",        commandSetScrollInterval},
    {"start_scroll",               commandStartScroll},
    {"scroll_step",                commandScrollStep},
    {"pause_scroll",               commandPauseScroll},
    {"resume_scroll",              commandResumeScroll},
    {"stop_scroll",                commandStopScroll},
    {"pause",                      commandPause},
    {"resume",                     commandResume},
    {"button",                     commandButton},
    {"terminate_other_activities", commandTerminateOtherActivities},
    {"reset_battery_min",          commandResetBatteryMinimum},
    {"reset_battery_max",          commandResetBatteryMaximum},
};
~~~~

#### WebServer 路由表

~~~~cpp
server.on("/",            HTTP_GET,     serveRoot);
server.on("/index.html",  HTTP_GET,     serveRoot);
server.on("/api/status",  HTTP_GET,     handleApiStatus);
server.on("/api/status",  HTTP_OPTIONS, handleOptions);
server.on("/api/power",   HTTP_GET,     handleApiPower);
server.on("/api/power",   HTTP_OPTIONS, handleOptions);
server.on("/api/frame",   HTTP_POST,    handleApiFrame);
server.on("/api/frame",   HTTP_OPTIONS, handleOptions);
server.on("/api/scroll",               handleApiScroll);
server.on("/api/command", HTTP_POST,    handleApiCommand);
server.on("/api/command", HTTP_OPTIONS, handleOptions);
server.on("/api/saved_faces",          handleApiSavedFaces);
server.onNotFound(handleNotFound);
~~~~

#### API 行为要求

- `serveRoot` 优先发送 gzip 版 `/index.html.gz`，若不存在则发送 `/index.html`。
- 静态资源必须支持 gzip 优先、正确 Content-Type、Cache-Control 与分块流式传输；HTML 禁止长缓存。
- `/api/status` 支持 query：`runtimeOnly=1`、`summary=1`、`noFrame=1`、`since=<version>`、`fullPower=1`。运行时摘要、滚动摘要和完整状态必须分级生成，避免频繁输出大 JSON。
- `/api/power` 返回 ADC、电源、电池、充电相关状态；电池最低/最高电压重置通过命令路由触发。
- `/api/frame` 接收 M370 帧，验证长度和字符，写入 M370 队列/状态，拒绝非法载荷并递增 rejected 计数。
- `/api/scroll` 只处理 OPTIONS 和 POST；其他方法返回 405。POST 支持 `frames`、`intervalMs`/`fps`、`append`、`start`、`chunkIndex`、`totalFrames`，且只允许 RAM 存储；最大帧数受固件上限控制，超限返回错误。
- `/api/command` 只接受路由表中的命令，不允许任意字符串执行。`scroll_step` 接受可选 `payload.direction`（<0 后退一帧，否则前进一帧），步进后清空 M370 队列并立即渲染；`pause_scroll`/`resume_scroll` 操作用户级暂停标志；scroll 类命令响应与 `/api/status` renderer 均包含 `firmwareScrollUserPaused` / `firmwareScrollSystemPaused`。
- `/api/saved_faces` GET 返回当前表情库，POST 进行 schema/format/type/id/m370 校验，原子写入 `saved_faces.json`。

### 15.7 固件隐藏边界条件与实现细节

- RuntimeStore 的共享访问由调用方/辅助函数使用 FreeRTOS 互斥锁保护；滚动帧缓冲区优先使用 PSRAM，失败则回退到一次性内部 SRAM heap 分配。不得重新引入常驻静态 `fallbackScrollFrameBits_` 大数组。
- M370 渲染队列必须限长，满时丢弃最旧帧并记录 dropped；解码在临界区外执行，降低锁持有时间。
- 渲染冲突优先级：Core 0 主任务通过 `requestLedRender()` 提交的当前运行时帧、队列中的 M370 或测试图案，在同一渲染周期内优先于滚动任务预取的下一帧；`scrollRenderTask()` 如果检测到 `mainTaskRenderPending`，不会把 `nextFrame` 覆盖进 `runtimeFrameBits()`。文字滚动播放仅在没有主任务渲染请求抢占时推进并写入一帧。brightness 只有变化时写入灯带。
- 按钮隐藏组合键必须按照当前 `buttons.cpp` 的时序与消抖/长按阈值执行；按钮事件应向 RuntimeState 写入 lastReason 并打断滚动预览同步。
- PowerMonitor 必须执行 ADC 多采样、排序去极值、EMA、电池断开快速压降检测、低于 5V 的未供电判定、min/max 记录过滤、LUT 百分比映射。
- Storage 写文件必须使用临时文件 + rename 原子更新；JSON 读取失败要回退默认数据而不是崩溃。
- `psram_json.h` 的动态文档分配必须优先 PSRAM，避免大 JSON 文档挤占内部 SRAM。

### 15.8 资源与生成物规范

- 必须保留加载图像路径：
  - `/resources/loading/rina_icon1_default.png`
  - `/resources/loading/rina_icon2_hover.png`
- 必须保留字体资源路径：
  - `/resources/fonts/ark12.woff2`（缓存破坏 query 例如 `?v=20260612-emoji-input-v3`；当前实现只有此一个 Ark Pixel woff2，已无回退/别名）
  - `/resources/fonts/ark12.json`
- `resources/fonts/ark12.json.gz` 是 LittleFS 构建期间生成的临时 gzip 同级文件，不是人工维护的源文件。
- `styles.css` 中的 GNU Unifont 子集为内嵌 data URI，本文档不显示原始二进制字体字节；重建时按工具链生成。不得把字体改成外链，也不得改回嵌入 `index.html`。
- gzip 生成脚本必须只压缩可压缩文本资源，不压缩 PNG/WOFF2 原二进制文件。


## 16. 待办 / 未来工作

本节记录当前代码中**尚未实现、仅为占位、或已遗留待清理**的项；它们不影响现有功能，但重建/继续开发时应当知晓。本节与 §1.2“禁止实现”互补：§1.2 是明确不做的方向，本节是可做但尚未做或需要收尾的事项。

### 16.1 未实现的占位

- **调试页 GPIO 占位按钮**：`#page-debug` 中存在 `data-gpio="B1"` 到 `data-gpio="B6B3"` 的按钮，当前**没有任何 JS 绑定**，是预留的硬件按钮模拟入口。重建时保留 DOM 占位即可，无需补处理逻辑；若未来要让 WebUI 直接模拟组合键，可在此接 `/api/command` 的 `button` 命令。

### 16.2 已遗留 / 待清理

- **启动默认表情 ID 不一致**：`WEBUI_CONFIG.faces.startupFaceId` 的 HTML 回退值是 `face_07_triangle_eyes_frown`，而运行时 `saved_faces.json` 顶层 `startupDefaultId` 是 `face_08_triangle_eyes_frown`。当前固件与 WebUI 在加载表情库后都以文件里的 `startupDefaultId` 为准，所以行为正确，但两个常量字面值应择机统一。
- **未使用的配置/常量**：
  - `WEBUI_CONFIG.led.previewSize.edgeGap = 12` 是遗留字段，真实矩阵留白由 CSS 变量 `--led-preview-edge-ratio`（默认 `.1000`）经 `fitMatrix()` 计算，不再使用该固定值。
  - `config.h` 中 `BATTERY_CALIB_SHRINK_TIMEOUT_MS`、`BATTERY_CALIB_SHRINK_STEP_V`、`BATTERY_CALIB_MIN_SPAN_V` 属于已废弃的“动态峰谷学习”遗留常量，无活跃代码路径引用（唯一仍被引用的是 `BATTERY_CALIB_SAVE_DELAY_MS`，用于校准文件 15 s 写防抖）。可保留注释，但不应再据此实现动态学习（见 §1.2）。
- **已删除资源**：`ark12_fallback.woff2` 已从项目删除（CSS 现仅 2 个 `@font-face`：GNU Unifont + 单一 Ark Pixel woff2）。`data/resources/fonts/README.md` 已同步更新，明确说明回退字形已合并进 `ark12.woff2`，无残留文案需要清理。
- **缓存版本号（cache-bust token）**：`index.html` 对 `app.js` / `styles.css` / `ark12.woff2` 的引用均带 `?v=...` token（当前为 `20260612-*` 系列），每次发布会变化，属易变值；本文档示例值仅供参考，不应硬编码为常量。
- **空文件 `pio`**：仓库根存在一个 0 字节的 `pio` 文件，疑似误建，可删除。

### 16.3 明确不在计划内（参见 §1.2）

为避免重复实现已被否决的方向，再次强调：不引入 I2C 电源管理 / PD / 充电 IC 寄存器读写、不加硬件温度传感器与温控、不把文字滚动帧持久化到 flash、不恢复动态电池峰谷学习、不改用 FastLED、不改用 AsyncWebServer。


## 17. 无损蓝图重建审计（2026-06-12 源码交叉审计）

本节是对当前 `src/*.cpp`、`src/*.h`、`data/app.js`、`data/index.html`、`data/styles.css` 与前文规格的逐项差异审计。若本节与更早章节冲突，以本节为准。本节的目标是让 `plan.md` 从“高度接近实现的规格”升级为“可重建实现的无损蓝图”。

### 17.1 重建审计 / 缺口分析

审计结论：前文已经覆盖大多数模块、常量和 WebUI 行为，但在以下位置仍会导致仅凭 `plan.md` 重建时出现行为漂移：

- **B6 组合键描述过期**：当前源码没有 B6+B2 或 B6+B3 附加电源/输入页。B2/B3 在 `serviceButtonAnimationButtonInputs()` 中只会抑制 B6 长按触发。重建者若按旧文档实现组合页面，会新增当前代码不存在的 UX。
- **B3 在滚动播放时的保护条件缺失**：GPIO B3 在固件端文字滚动 active 且未 paused 时不会切换 manual/auto，也不会停止 scroll。这个保护防止本地按钮在滚动播放中破坏 Core 1 渲染节奏。
- **滚动逐帧按钮存在源码字面反向绑定**：`scroll-step-prev` 绑定 `direction=1`，`scroll-step-next` 绑定 `direction=-1`；而 `direction<0` 在固件和前端函数中都表示后退。重建当前版本必须保留这个字面行为，不能按按钮文案自行纠正。
- **渲染冲突优先级原描述不精确**：Core 1 滚动任务预取滚动帧后，会再次检查主任务渲染请求；若 Core 0 已请求渲染，滚动帧不会覆盖 `runtimeFrameBits()`。因此同一渲染周期中主任务请求优先于滚动帧写入。
- **HTTP 路由表的 Arduino WebServer 重载细节不可省略**：`/api/scroll` 和 `/api/saved_faces` 是不限定方法的 `server.on(path, handler)`，处理函数内部检查 GET/POST/OPTIONS；不是分别注册 POST/OPTIONS 的形式。
- **模块 include 依赖图未被锁死**：前文只列模块名，未给出源码依赖边界。重建时若省略 `scroll.h` 对 `led_renderer.cpp` 的任务通知依赖、或省略 `psram_json.h` 在 `web_api/storage` 中的使用，会改变内存压力与跨核通知行为。
- **WebUI class 清单中存在自动抽取噪声**：第 15.3 的静态 class 清单里出现 `&&`、`rows[y][x]==='#'?'` 等非 DOM class token。这些是抽取伪影，不得在 HTML/CSS 中实现。真实 DOM/class 以 `data/index.html` 结构、CSS 选择器和本节审计为准。
- **`button_animations.cpp` 缺少模块级规格（已补 §6.12）**：早期 §6 没有为这个约 777 行的覆盖层/动画引擎建立专章。仅凭旧文档重建会丢失覆盖层的 22×18 居中坐标映射（`xyToLogical` 的 `leftPad`）、边沿闪烁攻击/衰减缓动、电量页分页状态机、`batteryColor/batteryFillCols` 数学和 5×7 字形/图标资源。本审计已新增 §6.12 模块规格并在 §17.4.11 注入精确覆盖层渲染片段。
- **`sync.h` 的 `with*Lock` 返回类型描述过期**：§6.2 早期文字称三个 `with*Lock` 为 `void` 返回、不透传 lambda 结果；实际源码是 `auto withFrameLock(Fn fn) -> decltype(fn())`，会返回 `fn()` 的值。多个调用点（如 `serveStaticFile`、`scrollRenderTask` 内的 `bool`/`size_t` 锁内计算）依赖该返回值；退化为 `void` 会破坏编译与语义。§6.2 文字已修正。

### 17.2 差异与偏离检查

当前代码中存在但前文没有足够精确锁定的元素：

- `button_animations.cpp` 的 B6 长按条件、电池分页轮换、滚动系统级暂停/恢复状态机。
- `buttons.cpp` 中 GPIO B3 在 active scroll 时提前返回的保护分支。
- `led_renderer.cpp` 中 `requestLedRender()` 的中断安全临界区与 `notifyScrollRenderTask()` 联动。
- `scroll.cpp` 中主任务渲染请求对滚动帧写入的抢占检查。
- `web_api.cpp` 中 `/api/scroll` 的 `explicitStart` / `totalFrames` 自动启动推导逻辑。
- `web_api.cpp` 中 `server.collectHeaders({"Accept-Encoding"}, 1)`，它是 gzip 静态资源协商的必要条件。
- `power_monitor.cpp` 中 `batteryCanRecordMinimumVoltage()`：低压断电、断开或充电时不记录最低校准重置值。
- `data/app.js` 中加载期间 `data-scroll-lock="boot"` 与自定义 select 打开时的页面滚动拦截；这些是 UI/UX 硬约束，不是视觉增强。
- `button_animations.cpp` 的覆盖层渲染引擎：`xyToLogical()` 居中映射、`overlayEdgeFlash()` 攻击/衰减 × 空间衰减缓动、`batteryColor()`/`batteryFillCols()`/`drawBatteryIcon()` 充电扫描动画、`copyButtonAnimationOverlay()` 的 kind→绘制分派，以及 5×7 字形与 `CLOCK/SUN/BATTERY/BIG_A/BIG_M` 图标位图常量。精确片段见 §17.4.11。
- `sync.h` 三个 `with*Lock` 模板的真实签名 `auto -> decltype(fn())`（透传 lambda 返回值），以及 `ScopedLock`/`SyncDomain` 的 RAII 边界。
- `renderCurrentFrameToLedStrip()` 中覆盖层优先于基础帧的合成顺序，以及 `static uint8_t overlayRgb[LED_COUNT*3]` 与 `lastAppliedBrightness` 的函数内 `static` 状态（跨调用保持，不可改为局部）。

前文中已发现并修正/覆盖的过期或矛盾计划：

- “B6 与 B2/B3 组合显示附加电源/输入页”已作废。
- “B3 松开总是切换 manual/auto”缺少 active scroll 例外。
- “文字滚动播放 > 队列 M370”作为同周期冲突优先级不符合 `scrollRenderTask()`。
- `/api/scroll`、`/api/saved_faces` 路由表的方法注册文字不够精确。
- 静态 class 清单里的伪 token 不是实际 UI 契约。
- “`with*Lock` 为 `void` 返回、不透传结果”已作废（实际返回 `decltype(fn())`，见 §6.2 修正）。
- “`button_animations` 无独立规格”已作废（已补 §6.12 与 §17.4.11）。

### 17.3 固件 include / 依赖图锁定

重建时必须保持下列 include 边界；这不是风格问题，而是模块依赖和链接顺序的事实来源：

```text
main.cpp: Arduino.h, config.h, state.h, sync.h, led_renderer.h, storage.h, faces.h, scroll.h, buttons.h, button_animations.h, web_api.h, power_monitor.h, freertos/task.h
led_renderer.cpp: led_renderer.h, state.h, sync.h, scroll.h, utils.h, button_animations.h, Adafruit_NeoPixel.h
scroll.cpp: scroll.h, state.h, sync.h, config.h, led_renderer.h, freertos/task.h
faces.cpp: faces.h, state.h, sync.h, config.h, led_renderer.h, storage.h
buttons.cpp: buttons.h, state.h, config.h, led_renderer.h, faces.h, button_animations.h
button_animations.cpp: button_animations.h, faces.h, led_renderer.h, power_monitor.h, state.h, sync.h, math.h, string.h
power_monitor.cpp: power_monitor.h, config.h, state.h, sync.h, storage.h, algorithm, ArduinoJson.h, LittleFS.h, math.h
storage.cpp: storage.h, state.h, config.h, utils.h, led_renderer.h, faces.h, sync.h, psram_json.h, LittleFS.h
web_api.cpp: web_api.h, state.h, sync.h, config.h, utils.h, led_renderer.h, storage.h, faces.h, buttons.h, power_monitor.h, web_json.h, psram_json.h, DNSServer.h, WebServer.h, WiFi.h, ArduinoJson.h, LittleFS.h, pgmspace.h, stdlib.h
```

### 17.4 精确代码片段注入：渲染、队列、滚动、协议、ADC

#### 17.4.1 中断安全渲染请求与 Core 1 唤醒

```cpp
void requestLedRender() {
    if (xPortInIsrContext()) {
        portENTER_CRITICAL_ISR(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL_ISR(&ledRenderRequestMux);
    } else {
        portENTER_CRITICAL(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL(&ledRenderRequestMux);
    }
    notifyScrollRenderTask();
}

bool consumeLedRenderRequest() {
    bool requested = false;
    portENTER_CRITICAL(&ledRenderRequestMux);
    requested = ledRenderRequested;
    ledRenderRequested = false;
    portEXIT_CRITICAL(&ledRenderRequestMux);
    return requested;
}
```

#### 17.4.2 M370 队列结构与满队列丢弃最旧帧行为

```cpp
struct QueuedM370Frame {
    uint8_t bits[FRAME_BYTES] = {};
    char    m370[5 + M370_HEX_CHARS + 1] = "";
    char    reason[M370_FRAME_REASON_CHARS] = "";
    bool    hasM370 = false;
};

static void enqueuePackedM370Frame(const uint8_t* packedBits, const char* normalizedM370, const String& reason) {
    if (!packedBits) return;

    const uint32_t now = millis();
    if (m370FrameQueueCount == 0 && m370FrameRateReady(now)) {
        publishPackedFrameNow(packedBits, normalizedM370, reason.c_str());
        return;
    }

    uint8_t target = m370FrameQueueTail();
    if (m370FrameQueueCount >= M370_FRAME_QUEUE_DEPTH) {
        target = m370FrameQueueHead;
        m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
        ++runtimeState().framesDropped;
    } else {
        ++m370FrameQueueCount;
    }

    memcpy(m370FrameQueue[target].bits, packedBits, FRAME_BYTES);
    if (normalizedM370 && normalizedM370[0] != '\0') {
        copyText(m370FrameQueue[target].m370, sizeof(m370FrameQueue[target].m370), normalizedM370);
        m370FrameQueue[target].hasM370 = true;
    } else {
        m370FrameQueue[target].m370[0] = '\0';
        m370FrameQueue[target].hasM370 = false;
    }
    copyText(m370FrameQueue[target].reason, sizeof(m370FrameQueue[target].reason), reason.c_str());
    ++runtimeState().framesQueued;
}

void serviceM370FrameQueue() {
    if (m370FrameQueueCount == 0) return;
    const uint32_t now = millis();
    if (!m370FrameRateReady(now)) return;

    QueuedM370Frame item;
    memcpy(&item, &m370FrameQueue[m370FrameQueueHead], sizeof(item));
    m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
    --m370FrameQueueCount;
    ++runtimeState().framesDequeued;

    publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
}
```

#### 17.4.3 Core 1 滚动/渲染循环与主任务抢占

```cpp
static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender          = mainTaskRenderPending;
        bool hasScrollFrame        = false;

        withScrollLock([&]() {
            if (runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused &&
                runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
                const uint32_t now = millis();
                if (runtimeState().lastScrollFrameMs == 0) runtimeState().lastScrollFrameMs = now;

                const uint16_t intervalMs = constrain(
                    runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
                const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;

                if (elapsedMs >= intervalMs) {
                    runtimeState().scrollFrameIndex =
                        (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

                    if (elapsedMs <= static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) {
                        runtimeState().lastScrollFrameMs += intervalMs;
                    } else {
                        runtimeState().lastScrollFrameMs = now;
                    }

                    memcpy(nextFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
                    hasScrollFrame = true;
                    shouldRender   = true;
                }
            }
        });

        if (hasScrollFrame) {
            withFrameLock([&]() {
                if (!mainTaskRenderPending) {
                    mainTaskRenderPending = consumeLedRenderRequest();
                    if (mainTaskRenderPending) shouldRender = true;
                }
                if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
                    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                    ++runtimeState().framesAccepted;
                } else {
                    if (!mainTaskRenderPending) shouldRender = false;
                }
            });
        }

        if (shouldRender) {
            renderCurrentFrameToLedStrip();
        }

        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1));
    }
}
```

#### 17.4.4 精确位打包与 M370 nibble 变换

```cpp
void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) runtimeFrameBits()[byteIndex] |=  bitMask;
    else    runtimeFrameBits()[byteIndex] &= ~bitMask;
}

bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits) {
    memset(outBits, 0, FRAME_BYTES);

    const char* hex = normalized.c_str() + 5;
    for (uint16_t nib = 0; nib < M370_HEX_CHARS; ++nib) {
        const int value = hexNibble(hex[nib]);
        if (value <= 0) continue;
        const uint16_t baseBit = static_cast<uint16_t>(nib) * 4U;
        for (uint8_t k = 0; k < 4U; ++k) {
            if ((value & (1 << (3 - k))) == 0) continue;
            const uint16_t bit = baseBit + k;
            if (bit < M370_BITS) outBits[bit >> 3] |= 1U << (bit & 7U);
        }
    }
}
```

#### 17.4.5 HTTP 路由表与 gzip 请求头收集

```cpp
void startWebServer() {
    auto serveRoot = []() {
        if (!serveStaticFile("/")) {
            if (!runtimeFsMounted()) sendFilesystemErrorPage();
            else sendError(404, "index.html not found; run pio run -t uploadfs");
        }
    };

    server.on("/",            HTTP_GET,     serveRoot);
    server.on("/index.html",  HTTP_GET,     serveRoot);
    server.on("/api/status",  HTTP_GET,     handleApiStatus);
    server.on("/api/status",  HTTP_OPTIONS, handleOptions);
    server.on("/api/power",   HTTP_GET,     handleApiPower);
    server.on("/api/power",   HTTP_OPTIONS, handleOptions);
    server.on("/api/frame",   HTTP_POST,    handleApiFrame);
    server.on("/api/frame",   HTTP_OPTIONS, handleOptions);
    server.on("/api/scroll",               handleApiScroll);
    server.on("/api/command", HTTP_POST,    handleApiCommand);
    server.on("/api/command", HTTP_OPTIONS, handleOptions);
    server.on("/api/saved_faces",          handleApiSavedFaces);
    server.onNotFound(handleNotFound);
    static const char* COLLECTED_HEADERS[] = { "Accept-Encoding" };
    server.collectHeaders(COLLECTED_HEADERS, 1);
    server.begin();
}
```

#### 17.4.6 `/api/scroll` 仅 RAM 载荷规则与自动启动推导

浏览器载荷必须保持以下形状；固件处理函数只支持 RAM：

```json
{
  "frames": ["M370:<93 hex>"],
  "stepLedPerFrame": 1,
  "start": false,
  "append": false,
  "chunkIndex": 0,
  "chunkFrames": 24,
  "totalFrames": 120,
  "source": "webui_text_scroll_frames_only",
  "storage": "ram",
  "persist": false,
  "saveToFlash": false
}
```

固件侧推导：

```cpp
const bool appendFrames = jsonBoolField(body, "append", false);
const bool explicitStart = body.indexOf("\"start\"") >= 0;
bool shouldStart = jsonBoolField(body, "start", false);
const bool persist = jsonBoolField(body, "persist", false);
const bool saveToFlash = jsonBoolField(body, "saveToFlash", false);
String storageTarget;
jsonStringField(body, "storage", storageTarget);
storageTarget.toLowerCase();
if (persist || saveToFlash || (!storageTarget.isEmpty() && storageTarget != "ram")) {
    sendError(400, "scroll uploads are RAM-only; persist/saveToFlash/storage flash is unsupported");
    return;
}

if (!explicitStart) {
    const uint32_t cachedFrames = static_cast<uint32_t>(baseIndex) + count;
    shouldStart = totalFrames > 0 ? (cachedFrames >= totalFrames) : !appendFrames;
}
```

浏览器上传路径：

```js
data = await apiPostWithUploadProgress(
  API_ENDPOINTS.scroll,
  {
    frames: chunkFrames,
    stepLedPerFrame: 1,
    start: false,
    append: !isFirstChunk,
    chunkIndex,
    chunkFrames: chunkFrames.length,
    totalFrames: frames.length,
    source: "webui_text_scroll_frames_only",
    storage: "ram",
    persist: false,
    saveToFlash: false,
  },
  (progress) => {
    const chunkProgress = (chunkIndex + progress) / totalChunks;
    setScrollUploadProgress(
      0.36 + chunkProgress * 0.5,
      `分批上传到固件 RAM ${chunkIndex + 1}/${totalChunks}`,
    );
  },
);
```

#### 17.4.7 `scroll_step` 命令与当前 WebUI 绑定

固件端：

```cpp
static bool commandScrollStep(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    int8_t direction = 1;
    if (!payload.isNull() && payload["direction"].is<int>()) {
        direction = payload["direction"].as<int>() < 0 ? -1 : 1;
    }
    uint8_t steppedFrame[FRAME_BYTES];
    bool    hasSteppedFrame = false;
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint16_t frameCount = runtimeState().scrollFrameCount;
            runtimeState().scrollFrameIndex =
                direction < 0
                    ? static_cast<uint16_t>((runtimeState().scrollFrameIndex + frameCount - 1U) % frameCount)
                    : static_cast<uint16_t>((runtimeState().scrollFrameIndex + 1U) % frameCount);
            runtimeState().playback         = "scroll_step";
            memcpy(steppedFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });
    if (hasSteppedFrame) {
        clearQueuedM370Frames();
        applyPackedFrameImmediate(steppedFrame, "firmware_text_scroll_step");
    }
    return true;
}
```

当前 WebUI 绑定：

```js
setScrollStepHandler("scroll-step-prev", 1);
setScrollStepHandler("scroll-step-next", -1);

function advanceScroll(manual = false, direction = 1) {
  prepareTextScrollTimeline(false);
  if (!scroll.frames.length) return;
  const delta = direction < 0 ? -1 : 1;
  scroll.frameIndex = (scroll.frameIndex + delta + scroll.frames.length) % scroll.frames.length;
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(scroll.frames[scroll.frameIndex]);
  setScrollPreviewFrame(
    scrollFrame,
    manual ? "text_scroll_manual_step_preview" : "text_scroll_firmware_preview",
    manual ? "scroll_step" : "scroll",
  );
  scroll.frameCounter++;
  const now = performance.now();
  if (now - scroll.fpsStarted >= 1000) {
    scroll.measuredFps = (scroll.frameCounter * 1000) / (now - scroll.fpsStarted);
    state.actualFps = scroll.measuredFps;
    scroll.frameCounter = 0;
    scroll.fpsStarted = now;
  }
  updateScrollUi();
}
```

#### 17.4.8 ADC 采样、衰减配置与电压换算

```cpp
static uint16_t readTrimmedAdcMilliVolts(uint8_t pin) {
    uint16_t samples[POWER_ADC_SAMPLES];
    for (uint8_t i = 0; i < POWER_ADC_SAMPLES; ++i) {
        samples[i] = static_cast<uint16_t>(analogReadMilliVolts(pin));
        delayMicroseconds(250);
    }

    std::sort(samples, samples + POWER_ADC_SAMPLES);

    constexpr uint8_t first = POWER_ADC_TRIM_COUNT;
    constexpr uint8_t last = POWER_ADC_SAMPLES - POWER_ADC_TRIM_COUNT;
    uint32_t sum = 0;
    for (uint8_t i = first; i < last; ++i) sum += samples[i];
    return static_cast<uint16_t>(sum / (last - first));
}

void initPowerMonitor() {
    const uint32_t now = millis();
    loadBatteryCalibration(now);
    ensureBatteryCalibrationDefaults(now);
    analogReadResolution(12);
    analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);
    analogSetPinAttenuation(CHARGE_ADC_PIN, ADC_11db);
    servicePowerMonitor(true);
}
```

关键电池换算与断开旁路：

```cpp
const uint16_t adcMv = readTrimmedAdcMilliVolts(BATTERY_ADC_PIN);
const uint16_t prevAdcMv = powerStatus.batteryAdcMv;
const bool hadPreviousAdc = powerStatus.batteryPrevAdcKnown;
const bool hugeRawDrop = hadPreviousAdc &&
    prevAdcMv > adcMv &&
    static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
    adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
const bool stillDisconnected = powerStatus.batteryDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV;

const float vadc = static_cast<float>(adcMv) / 1000.0f;
const float instantVbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;
powerStatus.batteryLastInstantVbat = instantVbat;

const bool chargerPresent = powerStatus.chargeValid && powerStatus.charging;
const bool rawDropUnpowered = (hugeRawDrop || stillDisconnected) && !chargerPresent;
const bool lowVoltageUnpowered = !chargerPresent && instantVbat < BATTERY_UNPOWERED_LOW_V;
```

充电输入换算与边沿吸附：

```cpp
const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
const float vadc = static_cast<float>(adcMv) / 1000.0f;
powerStatus.chargeAdcMv = adcMv;

const float instantVcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;
const bool instantCharging    = instantVcharge > CHARGE_PRESENT_V;
const bool chargerStateChange = (powerStatus.charging != instantCharging);

if (!powerStatus.chargeValid || !isfinite(powerStatus.vcharge) || chargerStateChange) {
    powerStatus.vcharge = instantVcharge;
} else {
    powerStatus.vcharge = (powerStatus.vcharge * (1.0f - CHARGE_EMA_ALPHA)) +
                           (instantVcharge * CHARGE_EMA_ALPHA);
}

powerStatus.charging = powerStatus.vcharge > CHARGE_PRESENT_V;
```

充电或未供电状态下，最低电压校准重置必须保持冻结：

```cpp
static bool batteryCanRecordMinimumVoltage() {
    return batteryHasPoweredVoltage() && !powerStatus.charging;
}
```

#### 17.4.9 B6 覆盖层输入门控与系统级暂停

```cpp
void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed) {
    bool shouldStartLong = false;
    const uint32_t now = millis();

    portENTER_CRITICAL(&sAnimMux);
    if (sAnim.b6Pressed && b6Pressed && !sAnim.b6LongFired &&
        !b2Pressed && !b3Pressed && now - sAnim.b6PressedAtMs >= BATTERY_LONG_PRESS_MS) {
        sAnim.b6LongFired = true;
        shouldStartLong = true;
    }
    if (!b6Pressed) sAnim.b6Pressed = false;
    portEXIT_CRITICAL(&sAnimMux);

    if (shouldStartLong) startBatteryOverlay(false);
}

void pauseScrollForOverlay() {
    if (sAnim.pausedScroll) return;

    bool shouldPause = false;
    withScrollLock([&]() {
        shouldPause = runtimeState().firmwareScrollActive &&
                      !runtimeState().firmwareScrollPaused &&
                      runtimeState().scrollFrameCount > 0;
    });
    if (shouldPause && setFirmwareScrollSystemPaused(true)) {
        sAnim.pausedScroll = true;
    }
}
```

#### 17.4.10 加载与滚动锁定 UX 约束

HTML 启动状态：

```html
<html data-boot-phase="preload" data-scroll-lock="boot" lang="zh-CN">
```

运行时解锁：

```js
function unlockBootPageScroll() {
  if (document.documentElement.dataset.scrollLock === "boot") {
    document.documentElement.removeAttribute("data-scroll-lock");
  }
}
```

自定义 select 的页面滚动拦截：

```js
function blockPageTouchMoveWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
function blockPageWheelWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
function blockPageKeyScrollWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  if (PAGE_SCROLL_KEYS.has(ev.key)) ev.preventDefault();
}
```

#### 17.4.11 覆盖层动画引擎（button_animations.cpp）

这是固件中最大的动画子系统，早期文档缺少精确片段。重建时必须逐字复现；几何映射、缓动包络和电池数学都是承重逻辑。

居中的 22×18 → 蛇形逻辑映射（覆盖层字形/图标依赖逐行居中）：

```cpp
constexpr uint8_t COLS = 22;
constexpr uint8_t ROWS = 18;

int16_t xyToLogical(uint8_t x, uint8_t y) {
    if (x >= COLS || y >= ROWS) return -1;
    const uint8_t rowLength = ROW_LENGTHS[y];
    const uint8_t leftPad = (COLS - rowLength) / 2;
    if (x < leftPad || x >= leftPad + rowLength) return -1;
    return static_cast<int16_t>(ROW_OFFSETS[y] + (x - leftPad));
}

void putPixel(uint8_t* out, uint8_t x, uint8_t y, Rgb color) {
    const int16_t logical = xyToLogical(x, y);
    if (logical < 0) return;
    const uint16_t offset = static_cast<uint16_t>(logical) * 3U;
    out[offset] = color.r;
    out[offset + 1] = color.g;
    out[offset + 2] = color.b;
}
```

边沿闪烁缓动（攻击/衰减包络 × 围绕第 10.5 列的空间衰减）：

```cpp
constexpr uint32_t EDGE_FLASH_MS  = 305;
constexpr uint32_t EDGE_ATTACK_MS = 45;
constexpr uint32_t EDGE_DECAY_MS  = 260;

void overlayEdgeFlash(uint8_t* out, const AnimationState& state, uint32_t now) {
    if (state.edge == EdgeKind::None) return;
    const uint32_t elapsed = now - state.edgeStartedMs;
    if (elapsed > EDGE_FLASH_MS) return;

    float factor = 0.0f;
    if (elapsed <= EDGE_ATTACK_MS) {
        factor = static_cast<float>(elapsed) / static_cast<float>(EDGE_ATTACK_MS);
    } else {
        const float t = static_cast<float>(elapsed - EDGE_ATTACK_MS) / static_cast<float>(EDGE_DECAY_MS);
        factor = max(0.0f, 1.0f - t);
    }

    const Rgb base = state.edgeUsesModeColor ? MODE_COLOR : EDGE_COLOR;
    const uint8_t y = state.edge == EdgeKind::Top ? 0 : ROWS - 1;
    for (uint8_t x = 0; x < COLS; ++x) {
        const float dist = fabsf(static_cast<float>(x) - 10.5f);
        const float spatial = max(0.20f, 1.0f - (dist / 10.5f));
        const float level = factor * spatial;
        putPixel(out, x, y, {
            static_cast<uint8_t>(static_cast<float>(base.r) * level),
            static_cast<uint8_t>(static_cast<float>(base.g) * level),
            static_cast<uint8_t>(static_cast<float>(base.b) * level),
        });
    }
}
```

电池颜色渐变与填充列变换（精确分段数学）：

```cpp
Rgb batteryColor(uint8_t percent) {
    const uint8_t p = min<uint8_t>(percent, 100);
    if (p <= 10) return RED_COLOR;                       // {255,0,0}
    if (p <= 30) { const float t = (p - 10.0f) / 20.0f;  // red -> orange
        return {255, static_cast<uint8_t>(165.0f * t), 0}; }
    if (p <= 50) { const float t = (p - 30.0f) / 20.0f;  // orange -> green
        return {static_cast<uint8_t>(255.0f * (1.0f - t)),
                static_cast<uint8_t>(165.0f + 90.0f * t), 0}; }
    return {0, 255, 0};
}

uint8_t batteryFillCols(uint8_t percent) {
    const uint8_t p = min<uint8_t>(percent, 100);
    if (p < 10) return 0;
    if (p > 90) return 8;
    return static_cast<uint8_t>(((static_cast<uint16_t>(p) - 10U) * 8U + 79U) / 80U);
}

void drawBatteryIcon(uint8_t* out, Rgb color, uint8_t percent, bool animate, uint32_t phaseMs) {
    drawBitmap(out, BATTERY_ICON, COLS, ROWS, 0, 0, color);
    uint8_t cols = batteryFillCols(percent);
    if (animate) {
        if (percent < 10) {
            cols = ((phaseMs / 300U) % 2U) == 0 ? 1 : 0;          // low-batt blink
        } else {
            const uint8_t target = percent > 90 ? 8 : max<uint8_t>(1, batteryFillCols(percent));
            cols = static_cast<uint8_t>(((phaseMs / 200U) % target) + 1U);  // charge sweep
        }
    }
    for (uint8_t x = 0; x < cols; ++x)
        for (uint8_t y = 2; y <= 4; ++y)
            putPixel(out, static_cast<uint8_t>(7 + x), y, color);
}
```

供 `renderCurrentFrameToLedStrip()` 消费的覆盖层分派（先在 `sAnimMux` 下快照，再按 kind 绘制，最后叠加边沿闪烁）：

```cpp
bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount) {
    if (!rgbOut || ledCount < LED_COUNT) return false;

    AnimationState state;
    const uint32_t now = millis();
    portENTER_CRITICAL(&sAnimMux);
    state = sAnim;
    portEXIT_CRITICAL(&sAnimMux);

    if (!state.active) return false;
    if (state.kind != OverlayKind::Battery && state.expiresMs != 0 && now >= state.expiresMs) return false;
    if (state.kind == OverlayKind::Battery && state.batterySingleShot &&
        state.expiresMs != 0 && now >= state.expiresMs) return false;

    if (state.kind == OverlayKind::Mode) {
        clearOverlay(rgbOut);
        drawBitmap(rgbOut, state.modeAuto ? BIG_A : BIG_M, 10, 13, 6, 2, MODE_COLOR);
    } else if (state.kind == OverlayKind::Interval) {
        char text[8] = {}; formatInterval(state.intervalMs, text, sizeof(text));
        drawIconText(rgbOut, text, MODE_COLOR, CLOCK_ICON);
    } else if (state.kind == OverlayKind::Brightness) {
        char text[8] = {}; snprintf(text, sizeof(text), "%u%%", brightnessPercent(state.brightnessRaw));
        drawIconText(rgbOut, text, BRIGHTNESS_COLOR, SUN_ICON);
    } else if (state.kind == OverlayKind::Battery) {
        drawBatteryPage(rgbOut, state, now);
    } else {
        return false;
    }

    overlayEdgeFlash(rgbOut, state, now);
    return true;
}
```

`serviceButtonAnimations()` 中的电池分页轮换（充电时 3 页，否则 2 页）：

```cpp
} else if (sAnim.kind == OverlayKind::Battery && !sAnim.batterySingleShot) {
    if (sAnim.batteryNextPhaseMs != 0 && now >= sAnim.batteryNextPhaseMs) {
        const uint8_t targetCount = (powerStatus.chargeValid && powerStatus.charging) ? 3 : 2;
        sAnim.batteryPhaseCount = targetCount;
        sAnim.batteryPhaseIndex = static_cast<uint8_t>((sAnim.batteryPhaseIndex + 1U) % targetCount);
        sAnim.batteryNextPhaseMs = now + BATTERY_PHASE_MS;
        request = true;
    }
    if (now >= sAnim.nextRenderMs) {
        sAnim.nextRenderMs = now + ((powerStatus.chargeValid && powerStatus.charging)
                                        ? BATTERY_ANIM_REFRESH_MS : BATTERY_REFRESH_MS);
        request = true;
    }
}
```

### 17.5 本次审计要求的策略性修订

后续开发或基于本文档重建时，必须遵守以下策略规则：

- 将时间敏感的 LED 工作保留在 Core 1，但 WebServer、电源、按钮、延迟恢复和队列排空必须在 Core 0 的 `loop()` 中配合 `vTaskDelay(1)` 服务。后台工作必须落在 1 ms loop 与 33 ms 帧限速暴露出的空闲间隙内；不得为了 LED 锁存时间在 HTTP 处理函数内阻塞。
- 滚动停止的 HTTP/按钮路径不得使用 `delay()`。应先 `applyBlankFrame("firmware_text_scroll_stop_clear")`，再由 `serviceDeferredFaceRestore()` 在 `LED_STOP_CLEAR_BLANK_HOLD_MS` 后执行延迟恢复。
- 保留主任务渲染请求对滚动帧的抢占。这保证 M370 帧、按钮覆盖层、亮度/颜色更新和文件系统错误图案能在当前渲染周期胜出，同时不与滚动缓冲区竞态。
- 保留仅 RAM 的文字滚动上传。任何把文字滚动帧保存到 flash 的计划都与当前实现矛盾，并会增加 LittleFS 磨损风险。
- 保留基于 LUT 的电量百分比。校准 min/max 文件仍是诊断/重置数据，不是动态百分比学习算法。
- 保留 UI 滚动锁：启动加载在揭示开始前锁定文档滚动；打开自定义 select 菜单时阻止页面 wheel/touch/key 滚动，同时允许菜单自身滚动。
- 保持覆盖层引擎的非破坏式、渲染时合成设计。按钮/电池/边沿覆盖层绝不能写入 `runtimeFrameBits()`；`renderCurrentFrameToLedStrip()` 会把 `copyButtonAnimationOverlay()` 合成在基础帧之上，因此覆盖层到期后底层表情/滚动帧会自动恢复。电池/边沿数学（居中的 `xyToLogical`、攻击/衰减缓动、`batteryColor`/`batteryFillCols`、充电扫描）是精确逻辑，不得重新推导或“平滑化”。
- 保留 `sync.h` 模板锁契约：`with*Lock` 返回 `decltype(fn())`。不得改成返回 `void` 的辅助函数；多个调用点依赖在锁内计算并返回结果。
- 覆盖层必须由 Core 0 `loop()` 中的 `serviceButtonAnimations()` 驱动（到期、分页轮换、刷新节奏），使其运行在空闲间隙内且绝不阻塞 Core 1 渲染任务；GPIO 按下/松开只在 `sAnimMux` 下修改 `sAnim`。

---

## 18. 代码审查、架构分析与已知问题（源自 `CODE_REVIEW.md`，2026-05-25）

> 合并说明：本章整合自独立的代码审查报告 `CODE_REVIEW.md`（评审 14 个 `src/` 源文件）。其中“模块逐一分析”与 §6 的模块规格、§17 的源码交叉审计存在主题重叠；为保留审查得出的**问题清单、严重度分级、并发模型与具体修复建议**，此处完整保留这些独有结论，并以本章作为“已知问题与修复优先级”的单一事实来源。阅读 §6（模块规格）与 §17（重建审计）时应与本章交叉对照。原报告的目录（Table of Contents）已删除（与本文档结构重复）。

**Project:** Rina-Chan Board V2 — 370-LED Matrix  
**Review Date:** 2026-05-25  
**Files Reviewed:** 14 source files across `src/`  
**Reviewer:** Senior C++ / Embedded Architect (AI-assisted review)

---

### 1. Executive Summary

The Rina-Chan Board ESP32-S3 firmware is a well-engineered, dual-core embedded system
driving a 370-LED hexagonal matrix over WS2812/SK6812 protocol. The codebase
demonstrates thoughtful hardware-aware design: Core-0 exclusively services HTTP, buttons,
power ADC, and state management, while Core-1 is pinned to a single real-time render/scroll
task that meets WS2812 timing constraints even under Wi-Fi load.

**Overall Quality: High.** The code is production-quality for its target domain. Synchronization
is handled through well-placed FreeRTOS mutexes and an ISR-safe portMUX, the M370 codec
and frame queuing system are robust, and the LittleFS I/O paths include atomic commit
semantics (temp-file-then-rename). The commentary throughout is thorough.

**Key risks and improvement areas identified:**

| Severity | Count | Summary |
|----------|-------|---------|
| HIGH     |  1    | 144 KB static SRAM array in `RuntimeStore` on the BSS |
| MEDIUM   |  5    | Code duplication in `web_api.cpp`; `storage→faces` layering; `power_monitor` duplicating directory creation; O(n²) sort at startup; missing `nullptr` guard in `RuntimeStore::scrollFrameBits()` |
| LOW / STYLE | 8 | Various minor readability, const-correctness, and redundancy notes |

No memory-safety bugs, race conditions, or undefined behavior were found.

---

### 2. Module Architecture Map

The firmware is organized into clean functional layers. Arrows show direct compile-time
dependencies (i.e., which module `#include`s another's header).

```
┌─────────────────────────────────────────────────────────┐
│                      main.cpp                           │
│  setup() → boot sequence (ordered by hardware deps)     │
│  loop()  → Core-0 cooperative service round             │
└────┬─────┬──────┬──────┬──────┬──────┬──────┬──────────┘
     │     │      │      │      │      │      │
     ▼     ▼      ▼      ▼      ▼      ▼      ▼
 config  state  sync  led_   scroll  faces  buttons  web_api
   .h     .h    .h   renderer  .h     .h     .h       .h
              │      .h  │
              │      │   │ (Core-1 task)
              │      ▼   ▼
              │   [NeoPixel strip.show()]
              │
              ▼
         button_animations.h
              │
              ▼
         power_monitor.h ─────────────────────────────┐
                                                       │
         storage.h ←── (LittleFS R/W)                 │
              │                                        │
              └─────────────────────────────────────────┘
                         (both read powerStatus directly)

Utility layer (no state, pure functions):
  utils.h ← used by led_renderer, storage, faces, web_api
  web_json.h ← used by web_api only
  psram_json.h ← used by state, storage, web_api
```

#### Data-flow summary

```
WebUI/API (Core-0, web_api.cpp)
    │  POST /api/frame  →  applyM370()  →  enqueuePackedM370Frame()
    │  POST /api/scroll →  write runtimeScrollFrameBits()  →  startFirmwareScroll()
    │  POST /api/command →  command handler table
    ▼
RuntimeStore (singleton, state.h/cpp)
  ├─ RuntimeState   ← mode, playback, color, brightness, scroll counters, deferred restore
  ├─ RuntimeFace[]  ← loaded saved faces (max 128)
  ├─ frameBits[]    ← currently displayed packed 370-bit frame (FRAME_BYTES = 47 bytes)
  └─ scrollFrameBits[] ← up to 3072 packed frames in PSRAM or static SRAM fallback

Core-0 loop() services (buttons.cpp, faces.cpp, power_monitor.cpp, led_renderer.cpp)
    │  applyM370 / applyPackedFrame → frameQueue → publishPackedFrameNow()
    │  requestLedRender() → sets ledRenderRequested flag + notifies Core-1 task
    ▼
Core-1 scrollRenderTask() (scroll.cpp)
    │  consumeLedRenderRequest()  → renderCurrentFrameToLedStrip()
    │  scroll timer advance       → memcpy nextFrame → renderCurrentFrameToLedStrip()
    ▼
renderCurrentFrameToLedStrip() (led_renderer.cpp)
    │  snapshot frameBits + color/brightness under frameMutex
    │  copyButtonAnimationOverlay() → may override with overlay RGB
    │  delayMicroseconds(LED_SIGNAL_RESET_US)
    │  withHardwareBusLock → strip.show()
    └  delayMicroseconds(LED_SIGNAL_RESET_US)
```

---

### 3. Lock-Ordering Policy & Concurrency Model

The firmware uses three FreeRTOS mutexes plus one portMUX, intentionally documented
with a strict acquire-order to prevent future deadlocks:

```
Acquire order (must always go left-to-right when nesting):
  HardwareBus → Frame → Scroll

portMUX (ledRenderRequestMux):
  ISR-safe flag for render-request; never held concurrently with any mutex.

portMUX (sAnimMux):
  Protects AnimationState snapshot in button_animations.cpp.
  Never held concurrently with any FreeRTOS mutex.
```

**Current paths respect this order.** No nested acquisitions of more than one
FreeRTOS mutex were found anywhere in the code. The scroll task acquires
`scrollMutex` then `frameMutex` in sequence (releases scroll before taking
frame), which is consistent with the declared ordering.

The `sAnimMux` portMUX sections are short (scalar copy only) and never call into
any module that could re-enter a FreeRTOS API, which is correct for a non-ISR
critical section on the ESP32.

---

### 4. Structural Findings

#### 4.1 Positives & Strong Patterns

These design decisions are explicitly called out as correct and should be preserved.

##### Meyers Singleton for `RuntimeStore`
`RuntimeStore::instance()` uses a function-local static, which is thread-safe under C++11
and avoids global constructor ordering hazards that are common on Arduino-based platforms.

```cpp
// state.cpp — correct singleton pattern
RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}
```

##### RAII `ScopedLock` + template wrappers
The `withFrameLock` / `withScrollLock` / `withHardwareBusLock` template helpers guarantee
mutex release even when a lambda returns early, without requiring callers to manually call
`unlock`. This is idiomatic modern C++ and prevents unlock-on-all-paths bugs.

##### Pre-computed logical-to-physical LED index map
`initLedIndexMap()` computes the serpentine row remapping once at boot and stores it in
`logicalToPhysicalMap[LED_COUNT]`. This removes a per-pixel row-walk from every render
loop iteration. The render path is correctly O(LED_COUNT) not O(LED_COUNT × MATRIX_ROWS).

##### ISR-safe render request flag (`portMUX`)
`requestLedRender()` correctly switches between `portENTER_CRITICAL_ISR` and
`portENTER_CRITICAL` depending on `xPortInIsrContext()`. The flag variable is `volatile bool`,
which is appropriate for a value written in ISR context and read from task context under the
same portMUX.

##### Atomic JSON file commit (temp-file-then-rename)
`writeJsonFileAtomic()` writes to a `.tmp` sibling, then renames it into place. On LittleFS
this prevents a power-loss from leaving a half-written file at the canonical path. The temp
file is removed before opening (to clear a stale previous attempt) and again on failure.

##### PSRAM-preferring ArduinoJson allocator (`psram_json.h`)
`SpiRamAllocator` tries `MALLOC_CAP_SPIRAM` first and falls back to `MALLOC_CAP_8BIT`.
This keeps large JSON documents (status responses, saved-faces editor payloads) in PSRAM,
freeing SRAM for stack and FreeRTOS bookkeeping.

##### Battery ADC: trimmed-mean sampling + time-delta EMA
`readTrimmedAdcMilliVolts()` takes 16 samples, sorts them, and averages the center 8.
The battery EMA uses `alpha = 1 - exp(-dt / tau)` rather than a fixed alpha, so the
20-second effective smoothing window is correct regardless of actual call frequency.
This is significantly better than the typical embedded fixed-alpha filter.

##### Drop-oldest frame-queue policy
When the M370 ring buffer overflows, the *oldest* frame is dropped, not the newest command.
For live animation controls this is the correct choice: the most-recent user intent should
always win, and the display converges to the current state within one `M370_FRAME_QUEUE_DEPTH`
cycle rather than being stuck showing stale frames.

##### Gzip pre-compressed static asset serving
`serveStaticFile()` checks for a `.gz` sibling and negotiates based on the client's
`Accept-Encoding` header. Serving gzip-compressed WebUI assets from LittleFS is
essential at 80 MHz with only 4 MB flash and a synchronous WebServer; this design
is correct and well-implemented.

---

#### 4.2 Issues & Recommendations

Issues are labeled **HIGH**, **MEDIUM**, or **LOW**.

---

##### [HIGH] 144 KB static fallback SRAM array in `RuntimeStore`

**File:** `state.h` line 218  
**Finding:**
```cpp
// state.h
uint8_t fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
// MAX_SCROLL_FRAMES = 3072, FRAME_BYTES = 47 → 3072 * 47 = 144,384 bytes
```
This array is a member of the Meyers singleton `RuntimeStore`. It lives in BSS and is
therefore always allocated regardless of whether PSRAM is available. On an ESP32-S3 with
512 KB SRAM, consuming 144 KB for a rarely-used fallback leaves only ~368 KB for all
other allocations, FreeRTOS task stacks, the heap, and the Wi-Fi TCP/IP stack.

**Risk:** The Wi-Fi stack alone needs approximately 60–100 KB. With 144 KB pre-committed
to the fallback buffer, boards without PSRAM may not have enough memory to bring up the
AP and WebServer at the same time, causing silent allocation failures downstream.

**Recommendation:** Move the fallback allocation to `initScrollFrameBuffer()` using
`heap_caps_malloc(MALLOC_CAP_8BIT)` instead of embedding it as a fixed static member.
Only allocate it when PSRAM is unavailable and the PSRAM path actually fails.

```cpp
// Proposed change in RuntimeStore (state.h):
// Remove:    uint8_t fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
// Replace member with:
//            uint8_t* sramFallbackBits_ = nullptr;

// In RuntimeStore::initScrollFrameBuffer() (state.cpp):
if (scrollFrameBits_ == nullptr) {
    // Only try heap SRAM as a last resort; print the real byte cost.
    sramFallbackBits_ = static_cast<uint8_t*>(
        heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_8BIT));
    if (sramFallbackBits_) {
        scrollFrameBits_ = sramFallbackBits_;
        scrollFrameBitsInPsram_ = false;
    }
    // If this also fails, scrollFrameBufferReady() returns false → scroll disabled.
}
```

This change converts a guaranteed SRAM cost into a conditional runtime allocation,
and allows `scrollFrameBufferReady()` to correctly return `false` instead of
silently committing 144 KB the firmware might not have.

---

##### [MEDIUM] Duplicated `/resources` directory-creation logic

**Files:** `storage.cpp` (line 33–40 `ensureResourcesDirectory()`) and
`power_monitor.cpp` (lines 187–190 inside `saveBatteryCalibration()`).

`power_monitor.cpp` duplicates the `LittleFS.exists("/resources") || LittleFS.mkdir("/resources")`
pattern inline rather than calling the `ensureResourcesDirectory()` helper that
already exists in `storage.cpp`. If the path changes or a different error-handling
strategy is needed, it must be updated in two places.

**Recommendation:** Move `ensureResourcesDirectory()` from a `static` function in
`storage.cpp` to a non-static function declared in `storage.h`, then call it from
`power_monitor.cpp`.

---

##### [MEDIUM] `storage → faces` layering violation

**File:** `storage.cpp` lines 163–167 in `loadRuntimeSettings()`  
**Finding:**
```cpp
// storage.cpp calls setMode() from faces.h — a higher-layer module
const char* mode = doc["mode"] | DEFAULT_MODE;
if (!setMode(mode, false)) setMode(DEFAULT_MODE, false);
```
`storage` should sit below `faces` in the dependency graph (storage loads raw data; faces
interprets it as playback state). This circular include is avoided at the header level
because `storage.h` does not include `faces.h`, but the runtime call goes upward.

**Recommendation:** Have `loadRuntimeSettings()` return a `RuntimeSettingsData` struct
containing the raw mode string, and let the call site (`main.cpp::setup()` → currently
`loadRuntimeSettings()` directly) call `setMode()` after `loadRuntimeSettings()` returns.
This removes the upward call and makes the data-flow explicit.

---

##### [MEDIUM] Missing initialized-state guard in `RuntimeStore::scrollFrameBits()`

**File:** `state.cpp` lines 58–73  
**Finding:**
```cpp
uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    // If scrollFrameBits_ is nullptr (initScrollFrameBuffer was never called),
    // the fallback pointer is used, which is fine IF the static array exists
    // but is silent about the uninitialized case.
    uint8_t* buffer = scrollFrameBits_ != nullptr
        ? scrollFrameBits_
        : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}
```
After the proposed [HIGH] fix above (removing the static fallback array),
`fallbackScrollFrameBits_` will no longer exist as a member. Callers that invoke
`runtimeScrollFrameBits()` before `initScrollFrameBuffer()` would then access a
null pointer. The fix is already implied by the proposed change: after making
`scrollFrameBits_` the only buffer pointer (set by `initScrollFrameBuffer()`), all
paths that pass through `scrollFrameBufferReady()` will be safe.

Even without the [HIGH] fix, adding a comment here explaining the two-path design
would help future maintainers.

---

##### [MEDIUM] O(n²) bubble sort in `loadSavedFaces()`

**File:** `storage.cpp` lines 385–397  
**Finding:**
```cpp
// O(n²) insertion-style sort over runtimeAutoFaces
for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
    for (uint16_t j = i + 1; j < runtimeAutoFaceCount(); ++j) {
        if (shouldSwap) { /* swap */ }
    }
}
```
With `MAX_AUTO_FACES = 128` the worst case is 8,128 iterations. This only runs
once per `loadSavedFaces()` call (boot + face editor save), so it is not a
performance concern at this scale. However, it is worth noting for future-proofing.

**Recommendation:** Replace with `std::sort` using a lambda comparator, which the
ESP32 Arduino core supports via `<algorithm>`. This shrinks the code and documents
the sort key explicitly:

```cpp
#include <algorithm>

std::sort(
    runtimeAutoFaces(),
    runtimeAutoFaces() + runtimeAutoFaceCount(),
    [](const RuntimeFace& a, const RuntimeFace& b) {
        // Primary: order field; secondary: original JSON index for stable tie-breaking.
        return a.order < b.order || (a.order == b.order && a.jsonIndex < b.jsonIndex);
    }
);
```

---

##### [MEDIUM] JSON reply assembly duplicated across three route handlers

**File:** `web_api.cpp`  
**Finding:** Three route handlers — `handleApiStatus()`, `handleApiFrame()`, and
`handleApiCommand()` — each independently assemble overlapping JSON response fields:
- `autoFaceId` / `autoFaceName` guard block (three copies)
- `scrollStopEvent` nested object (two copies in `handleApiStatus` and `handleApiCommand`)
- version fields (`v` and `version` — duplicated key for compatibility, appears five times)

**Recommendation:** Extract small inline helpers:
```cpp
// Add to web_api.cpp internal helpers:
static void addAutoFaceFields(JsonObject& obj) {
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        obj["autoFaceId"]   = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
        obj["autoFaceName"] = runtimeAutoFaces()[runtimeState().autoFaceIndex].name;
    }
}

static void addScrollStopEvent(JsonObject& obj) {
    JsonObject ev = obj.createNestedObject("scrollStopEvent");
    ev["seq"]    = runtimeState().scrollStopEventSeq;
    ev["ms"]     = runtimeState().scrollStopEventMs;
    ev["button"] = runtimeState().scrollStopEventButton;
    ev["source"] = runtimeState().scrollStopEventSource;
    ev["reason"] = runtimeState().scrollStopEventReason;
}

static void addVersionFields(JsonObject& obj, uint32_t version) {
    obj["v"]       = version;       // short form for WebUI fast path
    obj["version"] = version;       // long form for debuggability
}
```

---

##### [LOW] `parseColorHex()` performs redundant hex validation

**File:** `utils.cpp` lines 33–45  
**Finding:**
```cpp
// First pass: validate all 6 chars are hex
for (size_t i = 0; i < 6; ++i) {
    if (hexNibble(value.charAt(i)) < 0) return false;
}
// Then toLowerCase() + strtoul() — parses the same chars a second time
value.toLowerCase();
r = static_cast<uint8_t>(strtoul(value.substring(0, 2).c_str(), nullptr, 16));
```
The validation loop confirms all characters are valid hex, then `toLowerCase()` +
`strtoul()` re-parses them. Additionally, `strtoul` on an Arduino `String::c_str()`
creates three temporary `String` objects via `substring()`.

**Recommendation:** Eliminate the intermediate `String` objects and parse directly
using the already-validated `hexNibble()` results:
```cpp
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();
    if (value.startsWith("#")) value = value.substring(1);
    if (value.length() != 6) return false;

    int nibbles[6];
    for (size_t i = 0; i < 6; ++i) {
        nibbles[i] = hexNibble(value.charAt(i));
        if (nibbles[i] < 0) return false;
    }
    r = static_cast<uint8_t>((nibbles[0] << 4) | nibbles[1]);
    g = static_cast<uint8_t>((nibbles[2] << 4) | nibbles[3]);
    b = static_cast<uint8_t>((nibbles[4] << 4) | nibbles[5]);
    return true;
}
```

---

##### [LOW] `startOverlay()` manually copies each field instead of struct assignment

**File:** `button_animations.cpp` lines 514–536  
**Finding:**
```cpp
void startOverlay(const AnimationState& next) {
    portENTER_CRITICAL(&sAnimMux);
    sAnim.active = true;
    sAnim.kind = next.kind;
    sAnim.startedMs = next.startedMs;
    // ... 12 more individual assignments
    portEXIT_CRITICAL(&sAnimMux);
}
```
The portMUX section protects a copy of the entire `AnimationState` struct. A struct
assignment (`sAnim = next; sAnim.active = true;`) under the portMUX is functionally
identical and much shorter. There is no benefit to copying field-by-field here because
a struct assignment is not interruptible at the C++ level on Xtensa-LX7 (the compiler
emits a `memcpy`-style sequence that is protected by the portMUX just as well).

```cpp
void startOverlay(const AnimationState& next) {
    portENTER_CRITICAL(&sAnimMux);
    sAnim = next;       // single struct assignment under the critical section
    sAnim.active = true; // force active in case caller forgot to set it
    portEXIT_CRITICAL(&sAnimMux);
    pauseScrollForOverlay();
    requestLedRender();
}
```

---

##### [LOW] `serviceButtonAnimations()` expiry check uses magic constant for overflow guard

**File:** `button_animations.cpp` lines 674–675  
**Finding:**
```cpp
if ((sAnim.kind != OverlayKind::Battery &&
     now - sAnim.expiresMs < 0x80000000UL &&   // ← magic constant
     now >= sAnim.expiresMs) || ...)
```
`0x80000000UL` is half the `uint32_t` range, used to guard against the case where
`millis()` has wrapped past `expiresMs`. The logic is correct (it prevents interpreting
a post-wraparound `expiresMs` as "already expired"), but the magic number is opaque.

**Recommendation:** Replace with a named constant or a helper:
```cpp
// In the anonymous namespace at the top of button_animations.cpp:
// millis() wraps at ~49.7 days. If the elapsed time since expiresMs exceeds half
// the uint32_t range we assume the clock has not yet reached expiresMs.
constexpr uint32_t MILLIS_HALF_RANGE = 0x80000000UL;

inline bool millisPast(uint32_t now, uint32_t targetMs) {
    return (now - targetMs) < MILLIS_HALF_RANGE;
}
```

---

##### [LOW] `applyFirmwareScrollPauseIntentLocked()` unconditionally sets `firmwareScrollActive = true`

**File:** `faces.cpp` lines 389–391  
**Finding:**
```cpp
static void applyFirmwareScrollPauseIntentLocked() {
    // ... early return guard for truly idle state ...
    runtimeState().firmwareScrollActive = true;   // ← always set true
    runtimeState().firmwareScrollPaused = effectivePaused;
    ...
}
```
This function is only called from `setFirmwareScrollPauseFlag()`, which is itself
only called from `setFirmwareScrollUserPaused()` / `setFirmwareScrollSystemPaused()`.
Both callers check `runtimeState().firmwareScrollActive` before deciding whether
to call scroll-pause helpers in `button_animations.cpp`. The unconditional
`firmwareScrollActive = true` could activate scroll unexpectedly if the pause flags
are set when `scrollFrameCount == 0` but `firmwareScrollActive` was already `false`.
The early-return guard does protect this specific case, but the logic is fragile.

**Recommendation:** Add an explicit guard:
```cpp
// Only re-assert scroll active if there are frames to play.
if (runtimeState().scrollFrameCount > 0) {
    runtimeState().firmwareScrollActive = true;
}
```

---

##### [LOW] `handleApiStatus()` is 180+ lines — should be split

**File:** `web_api.cpp` lines 434–611  
The handler assembles six nested JSON objects (ap, power, renderer, memory, matrix, storage,
stats, endpoints) inline in one function. While the code is readable, a future change to any
sub-object requires modifying a single 180-line function.

**Recommendation:** Extract a `buildRendererStatus()`, `buildStorageStatus()`, and
`buildMatrixStatus()` helper to match the existing `addPowerStatus()` pattern. Each helper
receives a `JsonObject` by value and fills it from the appropriate module's state.

---

### 5. Module-by-Module Analysis

#### 5.1 `config.h` / `config.cpp`

**Role:** Single source of truth for all hardware pin assignments, timing constants,
matrix geometry, and network/filesystem paths.

**Design notes:**
- `constexpr` is used correctly throughout. All numeric constants are typed (e.g.,
  `constexpr uint8_t BRIGHTNESS_BUTTON_STEP = 8`) rather than raw `#define` macros,
  which preserves type safety.
- The `static_assert` verifying that `ROW_OFFSETS[MATRIX_ROWS-1] + ROW_LENGTHS[MATRIX_ROWS-1] == LED_COUNT`
  is excellent defensive practice — it catches matrix layout misconfigurations at compile time.
- `IPAddress` objects are defined in `config.cpp` (not `config.h`) because `IPAddress` is
  not a literal type on all Arduino cores and cannot be constexpr. The inline reference
  accessors (`apIP()`, `apGateway()`, `apSubnet()`) expose them without requiring a
  `config.h`-to-Arduino-WiFi dependency in every translation unit.
- `BATTERY_CALIB_SHRINK_TIMEOUT_MS` (7 days in ms) is computed with `UL` suffixed
  multiplication which is correct — without the suffix, the intermediate products would
  overflow `int` on 32-bit systems before the expression is promoted.

**Connection to other modules:** This is a leaf node; no other module's header is included
here (except `<IPAddress.h>` for the IPAddress declarations, which is isolated to `config.cpp`).
Every other module includes `config.h`.

---

#### 5.2 `state.h` / `state.cpp`

**Role:** Owns the singleton `RuntimeStore` containing `RuntimeState`, `RuntimeFace[]`,
`frameBits[]`, and the scroll-frame buffer. Provides free-function accessors so callers
do not need to know about the singleton directly.

**Design notes:**
- `RuntimeState` is a plain aggregate with default member initializers, making it safe
  under Arduino's static-init model.
- The `RuntimeFace` struct keeps only the fields needed for runtime navigation/playback.
  Raw JSON is never held in memory; it is re-read from LittleFS only when the editor
  needs it. This is the right memory budget strategy for a microcontroller.
- `touchRuntimeState()` / `touchRuntimeStateSlow()` / `serviceRuntimeSlowStatePublish()`
  implement a two-tier dirty-tracking scheme that rate-limits WebUI `stateVersion` bumps
  for slow-changing fields (power, brightness), while fast fields (frame changes, mode
  toggles) publish immediately. This reduces unnecessary HTTP long-poll responses.
- The `stateVersion` overflow guard (`if (stateVersion == 0) stateVersion = 1`) correctly
  skips zero, which the WebUI uses as the "no version yet" sentinel.

**Issue:** The 144 KB static fallback array (see §4.2 [HIGH]).

**Connections:**
- Written by: `led_renderer`, `faces`, `buttons`, `storage`, `power_monitor`, `web_api`
- Read by: every module
- Protected by: `frameMutex` (for `frameBits_`) and `scrollMutex` (for scroll counters),
  both managed through `sync.h`

---

#### 5.3 `sync.h` / `sync.cpp`

**Role:** Centralizes all FreeRTOS synchronization. Provides three FreeRTOS mutexes
and one portMUX, wrapped in an RAII `ScopedLock` and template `withXxxLock()` helpers.

**Design notes:**
- `ScopedLock` is `final` and non-copyable, which prevents accidental lock duplication.
- The `locked_` flag in `ScopedLock` ensures the destructor is safe even if the constructor
  fails partway through (though mutex creation failure is handled at `initSyncPrimitives()`
  before any `ScopedLock` is used).
- `initSyncPrimitives()` is idempotent (null-checks before creating), which is good for
  potential future re-init paths.
- Lock-ordering policy is documented in the header comment. This is critical documentation
  that should never be removed.

**Connections:** `sync.h` is included by `led_renderer`, `faces`, `buttons`,
`button_animations`, `storage`, `power_monitor`, `web_api`, and `scroll`. All shared-state
access flows through this module.

---

#### 5.4 `led_renderer.h` / `led_renderer.cpp`

**Role:** Owns the Adafruit NeoPixel `strip` object (the only module allowed to call
`strip.show()`), the M370 frame codec, the rate-limited frame queue, color/brightness
state, and the physical render path.

**Design notes:**
- The `Adafruit_NeoPixel strip` is `static` (module-local). No other module can call
  `strip.show()` directly. This is correct encapsulation: it enforces that every render
  goes through `renderCurrentFrameToLedStrip()`, which owns the required timing delays.
- The M370 codec (`normalizeM370` → `decodeNormalizedM370ToPackedBits`) is called OUTSIDE
  the frame mutex in `applyM370()`. Only `memcpy(runtimeFrameBits(), packed, FRAME_BYTES)`
  happens under the lock. This is the correct approach — decoding 370 bits is too slow to
  do inside a mutex that the Core-1 render task also needs.
- `copyText()` is a safe bounded string copy that guarantees null-termination. This replaces
  what would otherwise be `strncpy()` (which does not null-terminate when the source is too long).
- `lastAppliedBrightness` static in `renderCurrentFrameToLedStrip()` avoids calling
  `strip.setBrightness()` (which rescales the entire pixel buffer) on every frame.

**Connections:**
- Consumed by: `scroll` (render task), `faces`, `buttons`, `storage`, `web_api`
- Consumes: `state`, `sync`, `scroll` (for `notifyScrollRenderTask`), `utils`, `button_animations`

---

#### 5.5 `scroll.h` / `scroll.cpp`

**Role:** Creates and manages the Core-1 `scrollRenderTask`, which arbitrates between
scroll-timeline advancement and on-demand renders triggered from Core-0.

**Design notes:**
- The double-lock pattern (acquire `scrollMutex`, advance frame index, release; then acquire
  `frameMutex`, write to `runtimeFrameBits`, release) is correct. This ensures the render
  task does not overwrite a frame that Core-0 just committed via `applyM370`.
- The `mainTaskRenderPending` re-check inside `frameMutex` handles the TOCTOU window
  between releasing `scrollMutex` and acquiring `frameMutex`. This is a subtle but necessary
  race-condition guard: without it, one stale scroll frame could flash on the display.
- `ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1))` gives the task a 1 ms sleep when there is
  nothing to render, which keeps Core-1 mostly idle while scrolling is paused but wakes it
  promptly when `notifyScrollRenderTask()` fires.
- Scroll drift is handled by advancing `lastScrollFrameMs` by exactly `intervalMs` (grid-lock)
  unless the backlog exceeds `SCROLL_DRIFT_RESET_INTERVALS * intervalMs`, in which case it
  resets to `now`. This prevents burst-rendering multiple frames after a scheduling stall.

**Connections:** Consumes `state`, `sync`, `config`, `led_renderer`.

---

#### 5.6 `faces.h` / `faces.cpp`

**Role:** Manages saved-face navigation, auto-playback, mode switching, firmware scroll
lifecycle, and deferred face restore after blank frames.

**Design notes:**
- `normalizedMode()` accepts Chinese locale strings ("自动"/"手动") as aliases. This is
  intentional for the WebUI which uses locale-specific mode labels.
- The deferred-restore mechanism (blank frame → 90 ms hold → apply saved face) avoids
  `delay()` in HTTP handlers or button callbacks. The two-stage approach (set flag →
  service from `loop()`) is correct for cooperative multitasking on Core-0.
- `applyFirmwareScrollPauseIntentLocked()` is always called under `scrollMutex`, which
  is correct since it reads and writes multiple scroll-state fields atomically.
- `stopFirmwareScroll()` does a full state reset under `scrollMutex`, then conditionally
  applies a blank frame and schedules a deferred face restore. The lock is released before
  the blank-frame path to avoid holding `scrollMutex` across an I/O or render call.

**Connections:** Consumes `state`, `sync`, `config`, `led_renderer`, `storage`.
Called by: `buttons`, `button_animations`, `web_api`.

---

#### 5.7 `buttons.h` / `buttons.cpp`

**Role:** GPIO polling and debounce, button combo detection (B3+B1, B3+B2), hold-repeat
for face navigation (B1/B2) and brightness (B4/B5), and the `runButtonAction()` dispatcher
shared with the WebUI API.

**Design notes:**
- `runButtonAction()` is exposed publicly so the WebUI (`api_button` command) can simulate
  button presses with the same logic path as GPIO. This eliminates a parallel implementation.
- Combo detection is handled on the *press* edge of B1/B2 when B3 is already held, and
  marks both buttons as `comboConsumed` so their releases do not also fire solo actions.
- The `isScrollInterruptButton()` / `markScrollStoppedByButton()` mechanism publishes a
  monotonic sequence number (`scrollStopEventSeq`) that the WebUI can poll to detect that
  a GPIO button stopped the scroll. This avoids a heavyweight event queue for this specific
  notification need.
- `serviceHardwareButtons()` feeds debounced B6/B2/B3 states to `serviceButtonAnimationButtonInputs()`
  *after* all edge processing, so the overlay module always sees the settled debounced state,
  not raw GPIO levels.

**Connections:** Consumes `state`, `config`, `led_renderer`, `faces`, `button_animations`.

---

#### 5.8 `button_animations.h` / `button_animations.cpp`

**Role:** Manages the LED overlay system (Mode/Interval/Brightness/Battery overlays),
B6 short/long-press battery display logic, scroll pause-for-overlay, and the pixel renderer
for overlay frames.

**Design notes:**
- The anonymous `namespace { }` is used correctly to hide all internal state and helpers.
  Only the six public functions (`startButtonAnimationForGpioAction`, etc.) are exported.
- `xyToLogical()` maps the virtual 22×18 overlay canvas to the physical LED index
  accounting for the non-uniform row widths (via `ROW_LENGTHS[y]` and centering math).
  This is elegant: overlay designers can work in a uniform 22×18 grid without knowing
  the physical matrix shape.
- The `sAnimMux` portMUX (not a FreeRTOS mutex) is correct here because `copyButtonAnimationOverlay()`
  is called from the Core-1 render task, and a FreeRTOS mutex cannot be taken from a task
  at a higher priority than the task that took it on the other core. The portMUX approach
  is correct for cross-core atomic snapshot.
- Battery color interpolation uses linear RGB gradient across three threshold bands.
  Using `lroundf()` for the brightness percent conversion is correct to avoid truncation bias.
- The `drawBatteryIcon()` animate path uses `phaseMs / 200` column animation, producing
  a smooth fill-sweep during charging. The blink pattern for `< 10%` (`phaseMs / 300 % 2`)
  gives a 1.67 Hz blink without requiring a timer interrupt.

**Issue (LOW):** `startOverlay()` manual field-by-field copy (see §4.2).

**Connections:** Consumes `faces`, `led_renderer`, `power_monitor`, `state`, `sync`.
Called by: `buttons`, `led_renderer` (for overlay snapshot in render).

---

#### 5.9 `storage.h` / `storage.cpp`

**Role:** LittleFS mount, atomic JSON file writes, runtime settings persistence, and
saved-faces loading/validation/writing.

**Design notes:**
- `loadSavedFaces()` re-validates each face's M370 string through `normalizeM370()` on load,
  so the runtime can never contain an invalid M370 that was written by a buggy previous
  version of the WebUI editor.
- Face index is preserved across reloads by `id`-matching the previous face; the fallback
  cascade is well-documented (startup default → first default → index 0).
- `validateSavedFaces()` enforces the `unified_saved_faces` category contract, 1-based order
  fields, and at least one `type: "default"` face before any write completes. This ensures
  the firmware can always recover to a known startup face after a power cycle.
- `PsramJsonDocument` is used for the large saved-faces parse. The capacity is computed
  from actual file size via `jsonCapacityFor()`, which returns `max(sourceBytes*2+4096, 32768)`.
  The 2× factor accounts for ArduinoJson's internal object tree overhead.

**Issue (MEDIUM):** Duplicated `/resources` directory creation (see §4.2).
**Issue (MEDIUM):** `storage→faces` layering (`setMode()` called from `loadRuntimeSettings()`).
**Issue (MEDIUM):** O(n²) sort (see §4.2).

**Connections:** Consumes `state`, `config`, `utils`, `led_renderer`, `faces`, `sync`, `psram_json`.
Called by: `main`, `web_api`, `faces` (ensureSavedFacesLoaded).

---

#### 5.10 `power_monitor.h` / `power_monitor.cpp`

**Role:** ADC sampling for battery and charge lines, battery voltage EMA, disconnect
detection, piecewise-linear percent LUT, calibration persistence.

**Design notes:**
- `readTrimmedAdcMilliVolts()` uses `std::sort` from `<algorithm>`. This is correct
  for ESP32-S3 Arduino core which ships a full C++ standard library.
- Battery disconnect detection uses two criteria: a sudden large ADC drop (`>= BATTERY_DISCONNECT_ADC_DROP_MV`
  AND resulting value `<= BATTERY_DISCONNECT_ADC_LOW_MV`) OR a persistent low reading
  after a previous disconnect event. The hysteresis on reconnect (`>= BATTERY_RECONNECT_ADC_MV`)
  prevents oscillation at the threshold.
- The `vbat = NAN` reset on state transitions (disconnect recovery, low-voltage-unpowered
  recovery) forces the EMA to initialize from the live reading rather than ramping from
  the stale stored value. This is the correct behavior for state-change transitions.
- `updateBatteryCalibration()` is a stub (no-op with `(void)` suppression of unused params)
  with an extensive comment explaining that dynamic min/max learning was removed in favor
  of the fixed LUT. The code documents the *why* of a non-obvious design decision, which
  is excellent.
- `batteryPercentFromVoltage()` uses piecewise linear interpolation across the LUT. The
  `+/-1%` dead-band around `batteryPercent` prevents display jitter near segment boundaries.

**Issue (MEDIUM):** Duplicated `/resources` directory creation in `saveBatteryCalibration()`.

**Connections:** Consumes `state`, `config`, `sync`, `storage`. Exposes `powerStatus` global
read directly by `button_animations` and `web_api`.

---

#### 5.11 `web_api.h` / `web_api.cpp`

**Role:** SoftAP/DNS startup, static file serving with gzip negotiation, and all HTTP
REST API routes (`/api/status`, `/api/frame`, `/api/scroll`, `/api/command`,
`/api/saved_faces`, `/api/power`).

**Design notes:**
- The `ApiCommandRoute` dispatch table (`API_COMMAND_ROUTES[]`) cleanly maps command name
  strings to handler function pointers. Adding a new command requires one table entry and
  one handler function, with no changes to the dispatch loop.
- `handleApiScroll()` manually parses the `frames` JSON array inline rather than using
  ArduinoJson. This is intentional: the frames array can contain thousands of M370 strings
  totaling hundreds of KB, which would exceed ArduinoJson's practical memory limits on the
  ESP32 for a full parse. The custom parser consumes the body in a streaming fashion,
  writing directly to `runtimeScrollFrameBits()` as it goes.
- `serveStaticFile()` correctly handles the path normalization (`"/" → "/index.html"`,
  path-with-trailing-slash → `+ "index.html"`), gzip preference, and the fallback to
  raw file when gzip is absent.
- `streamFileChunked()` allocates an 8 KB heap buffer for file streaming with a 512-byte
  stack fallback if `malloc()` fails. The watchdog yield (`vTaskDelay`) every 4 chunks
  prevents reset under large file transfers on a busy AP.
- The `FILESYSTEM_ERROR_HTML` literal is stored in `PROGMEM` to avoid consuming 800+ bytes
  of SRAM for a rarely-used error page.

**Issues:**
- [MEDIUM] JSON reply field duplication across route handlers.
- [LOW] `handleApiStatus()` length (180+ lines).

**Connections:** Consumes all modules. This is the top-level integration point.

---

#### 5.12 `web_json.h` / `web_json.cpp`

**Role:** Lightweight raw-body JSON field extraction for the scroll upload path, which
cannot use ArduinoJson for the `frames` array due to memory constraints.

**Design notes:**
- `jsonFieldValuePosition()` does a simple string-search for `"key"` followed by `:`.
  This is intentionally a "good enough" parser for top-level fields in small command
  bodies. It does not handle fields inside nested objects, arrays, or escaped key names.
  This limitation is acceptable for its current use cases (booleans, integers, floats,
  and a single string field in the scroll body).
- `extractJsonStringAt()` correctly handles backslash escapes for the common JSON escape
  sequences. The `\uXXXX` (Unicode) case is left as its trailing character — this is noted
  in a comment and is acceptable because M370 frame strings contain only ASCII hex characters.

**Connections:** Consumed only by `web_api.cpp`.

---

#### 5.13 `utils.h` / `utils.cpp`

**Role:** Pure stateless helpers: hex nibble parse, JSON capacity estimate, color hex
parse/format.

**Design notes:**
- `hexNibble()` is called in the hot path of `normalizeM370()` (370 times per M370 decode).
  Its lookup is a simple range check — no table, no branch misprediction concern.
- `jsonCapacityFor()` uses `max(sourceBytes * 2 + 4096, 32768)` as a conservative
  ArduinoJson capacity estimate. The 2× factor accounts for the JSON tree overhead;
  the 32 KB floor handles the case where a small file's 2× estimate is still too small.

**Issue (LOW):** Redundant hex validation in `parseColorHex()` (see §4.2).

---

#### 5.14 `psram_json.h`

**Role:** PSRAM-preferring custom allocator for `BasicJsonDocument<SpiRamAllocator>`,
aliased as `PsramJsonDocument`.

**Design notes:**
- `allocate()` / `reallocate()` both try `MALLOC_CAP_SPIRAM` first, then fall back to
  `MALLOC_CAP_8BIT`. `heap_caps_free()` is used for deallocation (correct for both tiers).
- This header-only design is clean and composable. Using `BasicJsonDocument<SpiRamAllocator>`
  rather than overriding a global allocator keeps the custom allocation opt-in per document.

---

### 6. Specific Code Observations

Small-scale observations that do not rise to a structural finding but are worth noting
for future maintainers.

#### 6.1 `constrain()` with Arduino macros

`constrain()` is used in `faces.cpp`, `web_api.cpp`, and `power_monitor.cpp`. On Arduino
the `constrain(x, lo, hi)` macro expands to `((x)<(lo)?(lo):((x)>(hi)?(hi):(x)))`. Because
`x` is evaluated up to three times, it is unsafe with expressions that have side effects.
In this codebase, only simple variables are passed to `constrain()`, so there is no bug.
However, the ESP32 Arduino core ships `<algorithm>`, so `std::clamp(x, lo, hi)` (C++17)
or `std::min(std::max(x, lo), hi)` is the preferred alternative.

#### 6.2 `millis()` timestamp arithmetic and `int32_t` cast

`faces.cpp` line 346:
```cpp
if (static_cast<int32_t>(now - runtimeState().deferredFaceRestoreDueMs) < 0) return;
```
This correctly handles the case where `deferredFaceRestoreDueMs` is set in the future
by casting the unsigned difference to signed. This is the canonical Arduino pattern for
"is due time in the future?" The assumption is that the maximum due-time offset is less
than 2^31 ms (~24.9 days), which is always true here (`LED_STOP_CLEAR_BLANK_HOLD_MS = 90`).

#### 6.3 `DynamicJsonDocument` vs `PsramJsonDocument`

Several places in `storage.cpp` and `power_monitor.cpp` use `DynamicJsonDocument` for
small documents (384–768 bytes capacity). Since these capacities are well within SRAM
headroom and the documents are short-lived, using `DynamicJsonDocument` rather than
`PsramJsonDocument` is fine. Consistency could be improved by using `StaticJsonDocument`
for truly compile-time-known small capacities.

#### 6.4 String comparison in `playbackIsNonFaceActivity()`

```cpp
// faces.cpp
if (runtimeState().lastReason.startsWith("text_scroll_") ||
    runtimeState().lastReason.startsWith("custom_") || ...)
```
`String::startsWith()` is an O(n) case-insensitive scan. For the short reason strings
used here this is negligible, but it is worth noting that reason strings are not
validated/constrained, so a future module that sets a long reason string would make
these checks proportionally more expensive.

#### 6.5 `showFilesystemErrorPattern()` in `web_api.cpp`

This function lights the first 12 LEDs red to signal a LittleFS mount failure before the
WebServer is up. It correctly calls `setFrameBit()` inside a `withFrameLock` lambda,
then requests a render. The function should arguably live in `led_renderer.cpp` (pure
renderer concern) rather than `web_api.cpp` (HTTP concern), but since it is only called
from `main.cpp::setup()` and `web_api.cpp::handleNotFound()`, its current location is
acceptable.

#### 6.6 `normalizeM370()` String reservation

```cpp
String compact;
compact.reserve(M370_HEX_CHARS);  // pre-allocates 93 chars
```
Calling `reserve()` before the character-append loop prevents repeated heap reallocations
during the loop. This is correct performance practice for `String` on embedded targets.

---

### 7. Prioritized Recommendations

Listed in priority order. Items marked ✅ are already correct and should be preserved.

| # | Priority | File(s) | Action |
|---|----------|---------|--------|
| 1 | **HIGH** | `state.h` / `state.cpp` | Replace static `fallbackScrollFrameBits_[3072][47]` member with a runtime heap allocation in `initScrollFrameBuffer()`, freeing 144 KB of guaranteed SRAM. |
| 2 | **MEDIUM** | `storage.h/.cpp`, `power_monitor.cpp` | Move `ensureResourcesDirectory()` to `storage.h` (non-static), eliminating the duplicated mkdir logic in `saveBatteryCalibration()`. |
| 3 | **MEDIUM** | `storage.cpp`, `faces.h` | Decouple the `storage→faces` layering: have `loadRuntimeSettings()` return a settings struct; let `main.cpp` call `setMode()`. |
| 4 | **MEDIUM** | `web_api.cpp` | Extract `addAutoFaceFields()`, `addScrollStopEvent()`, and `addVersionFields()` helpers to eliminate JSON field duplication across route handlers. |
| 5 | **MEDIUM** | `storage.cpp` | Replace O(n²) bubble sort with `std::sort` + lambda. |
| 6 | **LOW** | `button_animations.cpp` | Replace manual field-by-field copy in `startOverlay()` with struct assignment under portMUX. |
| 7 | **LOW** | `button_animations.cpp` | Replace `0x80000000UL` magic constant with named `MILLIS_HALF_RANGE` and a `millisPast()` helper. |
| 8 | **LOW** | `utils.cpp` | Eliminate `parseColorHex()` double-parse by reusing `hexNibble()` results directly. |
| 9 | **LOW** | `faces.cpp` | Add `scrollFrameCount > 0` guard before `firmwareScrollActive = true` in `applyFirmwareScrollPauseIntentLocked()`. |
| 10 | **LOW** | `web_api.cpp` | Split `handleApiStatus()` into sub-helpers matching the existing `addPowerStatus()` pattern. |

**Items to preserve as-is (already optimal):**
- ✅ Meyers singleton in `RuntimeStore`
- ✅ RAII `ScopedLock` + `withXxxLock` template helpers
- ✅ Pre-computed `logicalToPhysicalMap` index table
- ✅ ISR-safe portMUX for render-request flag
- ✅ Atomic JSON write via temp-file-then-rename
- ✅ PSRAM-preferring `SpiRamAllocator` / `PsramJsonDocument`
- ✅ Time-delta EMA battery filter (`alpha = 1 - exp(-dt/tau)`)
- ✅ Trimmed-mean ADC sampling (`std::sort` + inner-subset average)
- ✅ Drop-oldest frame-queue overflow policy
- ✅ Gzip-negotiated static asset serving
- ✅ `scrollRenderTask` drift correction (grid-lock advance + burst-reset)
- ✅ Double-lock TOCTOU guard in `scrollRenderTask` (scroll unlock → frame lock re-check)
- ✅ `static_assert` verifying matrix row layout sums to `LED_COUNT`

---

*End of Review*

---

## 19. 文字滚动 6.4 源文本同步实现计划（v6，实施就绪版）

> 合并说明：本章整合自 `plan_scroll_source_text_v2.md` ~ `v6.md` 五个迭代版本。**v6 是 implementation-ready 版本，明确声明 supersedes v2–v5**，因此此处只保留 v6 的完整内容作为权威规格；v2/v3/v4/v5 为历次审计产生的历史草案（含被 v6 覆盖的决策，例如 v3 之前的 code-point 上限已在 v4/C1 改为仅 4096 字节上限），其增量已并入本章并删除源文件。该特性在原 `plan.md` 主体中**完全缺失**，属新增实现计划，落地时应与 §6.2 `sync`、§6.11 `web_api`、§8.9 文本滚动页交叉对照。审计标签（D1–D10、E1–E6、EH-A..C、SF1）保留以便追溯。

Core model unchanged: WebUI uploads generated M370 frames **plus** Unicode source
text + metadata; firmware stores both in RAM; WebUI rebuilds preview locally from
text; firmware never sends frames/bitmaps back; only frameIndex syncs during
playback.

### Changes from v5 (fifth audit, tags E1–E6 / EH-A..C, + one self-found item)

```text
E1  frame-overrun check applies to the FIRST chunk too (timeline-backed):
    parsedSoFar > totalFramesExpected -> 409 + invalidate
E2  timeline-backed upload requires totalFrames > 0 (else uploadComplete can
    never become true and D2 blocks playback forever) -> 400
E3  timelineId / fontId / generatorVersion validated WHENEVER present
    (independent of sourceText); D1 presence rule enforced separately
E4  scroll.restoredTextTruncated flag — truncated restore can NEVER bind
    framesTimelineId, even on coincidental frameCount match
E5  setScrollRestoreWarning() appends warnings instead of overwriting
    (truncation + version mismatch can coexist)
E6  start_scroll payload timelineId: length > MAX_SCROLL_TIMELINE_ID_CHARS or
    invalid charset -> 400 BEFORE the lock; never compare a truncated ID
EH-A comment: bad frame data invalidates playback cache but intentionally
     keeps sourceText
EH-B doc: timelineId-without-sourceText is an advanced/third-party form; the
     WebUI always sends timelineId + fontId + generatorVersion + sourceText
EH-C firmware invariant comment near meta helpers (see 1.2)
SF1 (self-found) variable first-chunk size changes upload-loop slicing:
    chunk 1 starts at offset firstChunkFrames (not SCROLL_UPLOAD_CHUNK_FRAMES);
    chunkIndex still increments by 1 per chunk — do NOT reuse the existing
    fixed-stride loop in uploadFirmwareScrollTimeline unchanged
```

Final invariants (EH-C, also added as firmware comments):

```text
timelineId present  = timeline-backed cache
timeline-backed     => totalFramesExpected > 0
timeline-backed     => never playable unless uploadComplete == true
framesTimelineId    = EXACT local preview identity only, never approximate
```

---

### 0. Hard rules

```text
- Playback never depends on sourceText; frames-only uploads keep working.
- Text-backed uploads are all-or-nothing: sourceText requires timelineId,
  fontId, generatorVersion. Timeline-backed uploads require totalFrames > 0
  (E2). Incomplete timeline-backed caches are never playable. Completed
  timeline-backed uploads reject further appends.
- No ark12.json fetch / frame regen during WebUI startup; regen on 6.4 entry
  (or immediately after restore if 6.4 already active).
- Identity = fontId + generatorVersion strings; no runtime hashing.
- Text hard limit: MAX_SCROLL_TEXT_BYTES = 4096 UTF-8 bytes; no code-point cap.
- scroll.timelineId vs scroll.framesTimelineId as v5; framesTimelineId binds
  only on exact generator identity + frameCount match + non-truncated text (E4).
- Metadata/text access under scrollMutex; copy under lock, serialize outside;
  no heap String writes inside the lock.
- No Unicode normalization; upload post-sanitize text; sanitize idempotent.
- Matrix dims fixed 22x18 / 370 LEDs — not metadata.
```

---

### 1. Firmware changes

#### 1.1 config.h

```cpp
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;
```

#### 1.2 state.h — ScrollTimelineMeta + helpers

Struct and buffer allocation as v4/v5. Helpers (called inside `withScrollLock`):

```cpp
// Invariant (EH-C):
// meta.timelineId[0] != '\0' means this is a timeline-backed cache:
//   - totalFramesExpected must be > 0 (enforced at upload),
//   - uploadComplete is authoritative,
//   - start_scroll must reject while uploadComplete == false.
// framesTimelineId on the WebUI side mirrors EXACT preview identity only.

static void invalidateScrollUploadLocked();   // EH-A: bad frame data invalidates
                                              // the playback cache but
                                              // intentionally keeps sourceText
static void clearScrollTimelineMetaLocked();  // full clear; start of every
                                              // append:false upload
```

`invalidateScrollUploadLocked()` call sites: append:false reset, the
`m370ToPackedBits` failure path (web_api.cpp ~729), the E1 overrun reject, any
future buffer clear.

#### 1.3 web_json.cpp — `\uXXXX` decoding (unchanged)

#### 1.4 utils — validators (unchanged signatures)

`validateScrollSourceText` (UTF-8 strict, rejects U+0000 and C0 except `\n`),
`validateMetaIdString` (nonempty, `[A-Za-z0-9._:-]`).

#### 1.5 /api/scroll upload handler

First chunk (`append:false`), strict order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames.
2. Validate BEFORE touching state:
   a. totalFrames <= MAX_SCROLL_FRAMES                      -> else 413
   b. E3: each of timelineId / fontId / generatorVersion, WHENEVER present:
      validateMetaIdString (covers length + charset)        -> else 400
   c. D1: if sourceText present:
      timelineId AND fontId AND generatorVersion present    -> else 400
      source-text buffer allocated?                         -> else 507
      byte length <= MAX_SCROLL_TEXT_BYTES                  -> else 413
      validateScrollSourceText passes                       -> else 400
   d. E2: if timelineId present: totalFrames > 0            -> else 400
3. stopFirmwareScroll(false); reset frame counters (existing behavior).
4. withScrollLock: clearScrollTimelineMetaLocked(); store present fields;
   hasSourceText only when sourceText stored;
   totalFramesExpected = totalFrames; nextChunkIndex = 1.
5. Stream/decode frames as today, with E1 inside the streaming loop for
   timeline-backed uploads:
      if totalFramesExpected > 0 && parsedSoFar > totalFramesExpected:
          withScrollLock { scrollFrameCount = 0; invalidateScrollUploadLocked(); }
          -> 409 "too many frames"
   (m370ToPackedBits failure keeps its existing zero-count path + invalidate.)
6. framesReceived = count; if totalFramesExpected > 0 &&
   framesReceived >= totalFramesExpected: uploadComplete = true.
```

Append chunk (`append:true`):

```text
if meta.timelineId is non-empty (timeline-backed):
    meta.uploadComplete == true            -> 409 "upload already complete"
    timelineId missing                     -> 409 "timeline required"
    timelineId != meta.timelineId          -> 409 "timeline mismatch"
    chunkIndex missing                     -> 409 "chunk index required"
    chunkIndex != meta.nextChunkIndex      -> 409 "chunk out of order"
    E1 (streaming): framesReceived + parsedSoFar > totalFramesExpected
                                           -> 409 "too many frames" + invalidate
else (legacy frames-only):
    timelineId/chunkIndex optional; chunkIndex if present must equal
    meta.nextChunkIndex -> else 409; MAX_SCROLL_FRAMES cap applies as today
decode frames; framesReceived += count; nextChunkIndex++
if totalFramesExpected > 0 && framesReceived >= totalFramesExpected:
    uploadComplete = true
```

EH-B: timelineId-without-sourceText is a valid but advanced/third-party form
(restore reports hasSourceText=false). The WebUI itself ALWAYS sends
timelineId + fontId + generatorVersion + sourceText on text sends.

Auto-start logic unchanged. Reply gains `timelineId` + `uploadComplete`.
Recovery from any upload error = full re-Send with a FRESH timelineId.

#### 1.6 Metadata lifecycle (unchanged from v5)

#### 1.7 /api/status — only 3 new fields (unchanged)

`scrollTimelineId, scrollUploadComplete, scrollHasSourceText`.

#### 1.8 GET /api/scroll/meta (unchanged from v5)

Copy under lock → serialize outside; `PsramJsonDocument doc(16384)`;
`capacity()==0` → 507; `overflowed()` → 507.

#### 1.9 commandStartScroll — atomic, enum errors, E6 pre-lock validation

```cpp
// BEFORE the lock (E6): extract payload timelineId into a stack buffer.
char payloadTimelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
const char* raw = payload["timelineId"] | "";
const size_t rawLen = strlen(raw);
if (rawLen > MAX_SCROLL_TIMELINE_ID_CHARS) { sendError(400, "timeline id too long"); return; }
if (rawLen > 0 && !validateMetaIdString(raw, MAX_SCROLL_TIMELINE_ID_CHARS)) {
    sendError(400, "invalid timeline id"); return;
}
memcpy(payloadTimelineId, raw, rawLen);   // never compare a truncated ID

enum class StartScrollError : uint8_t {
    None, TimelineMismatch, UploadIncomplete, NoCachedFrames
};
StartScrollError serr = StartScrollError::None;
withScrollLock([&]() {
    const bool timelineBacked = meta.timelineId[0] != '\0';
    const bool hasFrames = runtimeState().scrollFrameCount > 0 &&
                           runtimeScrollFrameBufferReady();
    if (timelineBacked) {
        if (rawLen > 0 && strcmp(payloadTimelineId, meta.timelineId) != 0) {
            serr = StartScrollError::TimelineMismatch; return;
        }
        if (!meta.uploadComplete) {            // D2: enforced even when the
            serr = StartScrollError::UploadIncomplete; return;   // payload has
        }                                       // no timelineId
    }
    if (!hasFrames) { serr = StartScrollError::NoCachedFrames; return; }
});
// map OUTSIDE the lock: TimelineMismatch/UploadIncomplete -> 409,
// NoCachedFrames -> 400 (existing message)
```

---

### 2. WebUI changes (data/app.js)

#### 2.1 Constants (unchanged from v5)

`SCROLL_GENERATOR_VERSION`, `SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES = 12*1024`;
both ID constants must pass `validateMetaIdString` (test enforces).

#### 2.2 scroll state additions + reset rules

As v5, plus E4:

```js
scroll.restoredTextTruncated = false;
```

Reset rules:

```text
markScrollTextDirty()          : framesTimelineId = "";
                                 restoredTextTruncated = false
stopScroll() / GPIO reset path : clear pendingScrollMeta/restored*/warning/
                                 restoredTextTruncated;
                                 KEEP timelineId and framesTimelineId
startScroll() (new Send)       : pendingScrollMeta = null;
                                 restoredSourceText = "";
                                 restoredFromFirmwareMeta = false;
                                 restoreWarning = "";
                                 restoredTextTruncated = false;
                                 then fresh timelineId; framesTimelineId =
                                 timelineId after prepare succeeds
clean restore start            : restoreWarning = "";
                                 restoredTextTruncated = false
```

Warning helper (E5) — use for ALL restore warnings (truncation, version
mismatch, frameCount mismatch, unsent-edit):

```js
function setScrollRestoreWarning(message) {
  if (!message) return;
  scroll.restoreWarning = scroll.restoreWarning
    ? `${scroll.restoreWarning}\n${message}`
    : message;
  // updateScrollUi renders multi-line warnings
}
```

#### 2.3 Upload

As v5 (generation guard, fresh timelineId per Send, metadata on first chunk,
timelineId + chunkIndex on every chunk, D4 budget guard with 1-frame throw,
one full retry on any 409 with fresh timelineId), plus SF1:

```js
// SF1: first chunk may carry fewer frames than SCROLL_UPLOAD_CHUNK_FRAMES.
// The chunk loop must slice by a running offset, not a fixed stride:
const firstChunkFrames = chooseFirstChunkFrames(buildFirstChunkPayload);
let offset = 0, chunkIndex = 0;
while (offset < frames.length) {
  const size = chunkIndex === 0 ? firstChunkFrames : SCROLL_UPLOAD_CHUNK_FRAMES;
  const chunk = frames.slice(offset, offset + size);
  // POST with { chunkIndex, chunkFrames: chunk.length, totalFrames, ... }
  offset += chunk.length;
  chunkIndex++;
}
// chunkIndex increments by 1 per chunk regardless of chunk size; firmware
// validates order by chunkIndex and total by frame counts, never by stride.
```

#### 2.4 Startup — text restore (E4, E5)

As v5, with these replacements:

```js
scroll.restoreWarning = "";              // clean slate
scroll.restoredTextTruncated = false;    // E4
...
setScrollTextFromFirmware(restoredText);
const valueAfterSanitize = $("scroll-text")?.value || "";
if (valueAfterSanitize && valueAfterSanitize !== restoredText) {
  scroll.restoredTextTruncated = true;   // E4
  setScrollRestoreWarning(               // E5
    "硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。");
}
...
if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
    meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
  setScrollRestoreWarning(               // E5: appends, does not overwrite
    "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。");
}
```

Unsent-edit guard also uses `setScrollRestoreWarning`. Everything else
(guard-before-bind, fps clamp, direct-on-6.4 regen call) unchanged from v5.

#### 2.5 Page 6.4 entry — regen (E4)

As v5, with the binding condition extended:

```js
if (!scroll.restoredTextTruncated &&          // E4
    exactGeneratorMatch(meta) &&
    scroll.frames.length === Number(meta.frameCount || 0)) {
  scroll.framesTimelineId = String(meta.scrollTimelineId || "");
} else {
  scroll.framesTimelineId = "";
  if (scroll.frames.length !== Number(meta.frameCount || 0)) {
    setScrollRestoreWarning(
      "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。");
  }
}
```

frameIndex apply + preview render + timer logic unchanged from v5.

#### 2.6 Timeline-mismatch refetch (unchanged from v5)

#### 2.7 No other sync changes

---

### 3. Implementation order

```text
1. web_json.cpp \uXXXX decoding (+ curl escape tests)
2. config.h limits; utils validators
3. state.h/.cpp: meta struct, text buffer alloc, invalidate/clear helpers,
   invariant comments (EH-C)
4. web_api.cpp: upload handler (E1/E2/E3 validation order, D3 rejects,
   invalidate call sites, 507/413/400/409s)
5. web_api.cpp: status fields, /api/scroll/meta, commandStartScroll (E6, D2, D8)
6. app.js: constants, scroll fields + reset rules (E4), upload loop (SF1),
   D4 budget guard, generation guard, fresh-id retry
7. app.js: restore functions (E4/E5), mismatch refetch, warning line in
   index.html (multi-line capable)
8. Tests
```

### 4. Test checklist

All v5 tests remain, plus:

```text
First-chunk malformed upload (E1, E2)
- append:false, timelineId, totalFrames=10, first chunk has 11+ frames
  -> 409 "too many frames", cache invalidated, start_scroll then 409/400
- append:false with timelineId and missing/zero totalFrames -> 400; no
  unplayable timeline-backed cache is ever created
Metadata validation (E3, E6)
- fontId present WITHOUT sourceText but invalid charset -> 400
- generatorVersion present WITHOUT sourceText but invalid -> 400
- start_scroll timelineId longer than MAX_SCROLL_TIMELINE_ID_CHARS -> 400,
  no truncated comparison
D10/E4 exactness
- oversized third-party text truncates; regenerated frameCount coincidentally
  equals meta.frameCount -> framesTimelineId STILL stays ""
Warnings (E5)
- oversized text + generator mismatch -> BOTH warnings visible
Upload loop (SF1)
- large text forcing reduced first chunk: total uploaded frame count exactly
  equals totalFrames (no duplicate/skipped frames at the chunk-1 boundary);
  firmware reports uploadComplete=true and plays correctly
```

v5 checklist highlights that still apply verbatim: 4096-byte ASCII accept,
frames-only compatibility, D1 400s, D2 partial-upload start reject, D3
complete-then-append reject, escape round-trips, race/stale-upload, restore
paths (boot / direct-6.4 / paused / stopped / second device), stale-frame
regen, input-overwrite guards, stop semantics, buffer invalidation,
boot-time + status-size regressions.

---

## 20. 按钮 LED overlay / 动画完整重建规格（含 bitmap，源自 `animation.md`）

> 合并说明：本章整合自 `animation.md`（按钮 LED 动画重建规格，指定规格版：无 IP 滚动、无电池时间页）。§6.12 `button_animations.h/.cpp` 给出的是模块级摘要，本章是**像素级实现参考**，保留全部 bitmap 资源（`_FONT[*]`、`CLOCK_ICON`、`SUN_ICON_1`、`_BIG_A`/`_BIG_M`、`BATTERY_ICON`、`BATTERY_FILL_*_COLS`、`BATTERY_CHARGE_SWEEP_*_COLS`）、颜色常量、`_render_string()` 布局规则、edge flash 动画逻辑、电池页面与充电动画逻辑、电池 ADC 与百分比/颜色换算。这些 bitmap 与精确逻辑在原 `plan.md` 主体中缺失，必须保留。硬件与坐标映射（§20 内 1.1/1.2）与 §5.1/§5.3 重复，保留作为该子系统的自洽参考；亮度 raw `0..200` 模型（§20 内 1.3）是本子系统的权威细节，与 §5.4 协同。原文件的“§0 一致性检查结论”元说明已并入本说明、不再单列。

本文件用于让另一个 Agent 仅根据本文档重建按钮 LED overlay / animation 行为。本文保留旧固件的动画结构、bitmap、颜色和刷新节奏，但按当前需求覆盖亮度数值规格，并删除 IP 滚动与电池时间页。范围只包含：

- 亮度加减 overlay
- auto interval 加减 overlay
- M/A 切换 overlay
- B6 电池页面与充电动画：百分比、电池电压、充电输入电压；不包含使用时间 / 充电时间页

明确排除：IP/SSID 滚动、默认表情、固定 saved face 示例、BadApple、matrix demo、WebUI 图片切换动画、电池使用时间页、电池充电时间页。


### 1. 硬件与全局显示基础

| 项目 | 值 |
|---|---:|
| LED data GPIO | `GPIO2` |
| LED 数量 | `370` |
| 逻辑画布 | `22 × 18` |
| `COLS` | `22` |
| `ROWS` | `18` |
| 行长度 `ROW_LENGTHS` | `[18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16]` |
| 走线 | serpentine，奇数行反向 |
| `FLIP_X` / `FLIP_Y` | `False` / `False` |
| 主循环/渲染调度 | Core 0 `loop()` 约每 `1 ms` 服务按钮、电源、队列与自动播放；Core 1 LED render task 约每 `1 ms` 等待唤醒/滚动步进 |

#### 1.1 逻辑坐标到 LED index

```python
def logical_to_led_index(x, y):
    if x < 0 or x >= 22 or y < 0 or y >= 18:
        return None

    row_width = ROW_LENGTHS[y]
    left_pad = (22 - row_width) // 2
    if x < left_pad or x >= left_pad + row_width:
        return None

    local_x = x - left_pad
    if y % 2 == 1:               # SERPENTINE
        local_x = row_width - 1 - local_x

    return ROW_STARTS[y] + local_x
```

#### 1.2 有效 LED mask

```text
row 00: ..##################..
row 01: .####################.
row 02: .####################.
row 03: .####################.
row 04: ######################
row 05: ######################
row 06: ######################
row 07: ######################
row 08: ######################
row 09: ######################
row 10: ######################
row 11: ######################
row 12: ######################
row 13: .####################.
row 14: .####################.
row 15: .####################.
row 16: ..##################..
row 17: ...################...
```

#### 1.3 亮度缩放与百分比显示

本文使用 raw brightness 作为 LED 通道上限。raw brightness 范围为 `0..200`。

- `0 / 255` 定义为显示 `0%`。
- `200 / 255` 定义为显示 `100%`。
- `201..255` 不作为按钮亮度范围使用。

显示百分比：

```python
def brightness_raw_to_percent(raw):
    raw = max(0, min(200, int(raw)))
    return int(round(raw * 100 / 200))
```

所有 overlay 颜色在写入 LED 前都经过 `scale_color(rgb)`，其中 `MAX_BRIGHTNESS = brightness_raw`：

```python
def scale_color(rgb):
    r, g, b = rgb
    m = max(r, g, b)
    cap = max(0, min(200, int(MAX_BRIGHTNESS)))
    if m <= cap:
        return (clamp(r,0,255), clamp(g,0,255), clamp(b,0,255))
    if cap <= 0:
        return (0, 0, 0)
    s = cap / m
    return (int(r * s), int(g * s), int(b * s))
```

注意：`scale_color()` 是 peak limiter / ceiling cap，不是全局亮度乘法。若输入颜色最大通道 `m <= brightness_raw`，颜色原样保留；只有当某个通道超过当前 brightness cap 时，才按比例压低到 cap。不要把它实现成 `rgb * brightness_raw / 200`，除非刻意改变旧固件的视觉语义。

示例：`raw=0 -> 0%`，`raw=8 -> 4%`，`raw=40 -> 20%`，`raw=100 -> 50%`，`raw=200 -> 100%`。

### 2. 按钮输入、组合键、repeat 参数

| 名称 | GPIO | 源码注释 / 用途 |
|---|---:|---|
| B1 / `BTN_PREV` | `17` | previous face；B3 held 时 interval 减少 |
| B2 / `BTN_NEXT` | `16` | next face；B3 held 时 interval 增加 |
| B3 / `BTN_AUTO` | `15` | A/M toggle；组合键 modifier |
| B4 / `BTN_BRIGHT_DN` | `40` | 当前规格：raw brightness `-8` |
| B5 / `BTN_BRIGHT_UP` | `41` | 当前规格：raw brightness `+8` |
| B6 / `BTN_BRIGHT_RST` | `42` | 电池短显/长显；B4+B5 reset 逻辑在本目标范围外 |

| 参数 | 值 |
|---|---:|
| active level | active-low，按下为 `0` |
| debounce | `25 ms` |
| autorepeat buttons | B1, B2, B4, B5 |
| repeat initial delay | `400 ms` |
| repeat period | `140 ms` |
| B3 repeat | 无 |
| B6 repeat | 无 |

#### 2.1 本文件范围内的按钮行为

| 输入 | 触发时机 | 源程序行为 | 对应 LED overlay / animation |
|---|---|---|---|
| B3 | 松开触发，且未被组合键消费 | `auto = not old_auto` | 显示大号 `A` 或 `M`，紫色，保持 1000ms |
| B3+B1 | 按住 B3 后按 B1；repeat 也生效 | `interval_s -= 0.5`，clamp 到 `0.5s` | 显示 `x.xS` + clock icon，紫色；到下限时 bottom edge flash |
| B3+B2 | 按住 B3 后按 B2；repeat 也生效 | `interval_s += 0.5`，clamp 到 `10.0s` | 显示 `x.xS` 或 `10S` + clock icon，紫色；到上限时 top edge flash |
| B4 | 按下立即；repeat 也生效 | `brightness_raw -= 8`，clamp 到 `0` | 显示 `NN%` + sun icon，蓝色；到下限时 bottom edge flash |
| B5 | 按下立即；repeat 也生效 | `brightness_raw += 8`，clamp 到 `200` | 显示 `NN%` + sun icon，蓝色；到上限时 top edge flash |
| B6 短按 | B6 按下后在 700ms 前释放 | 显示电池百分比 | `BATTERY_ICON + NN%`，2000ms，不播放充电 sweep |
| B6 长按 | B6 按住达到 700ms | 进入电池详细循环 | 非充电：百分比 / 电池电压；充电：百分比 / 电池电压 / 充电输入电压，并播放充电动画 |

#### 2.2 排除项

不得实现以下内容：

- IP/SSID 滚动显示
- `_SCROLL_FONT`
- `render_scrolling_text_window()`
- `check_ip_combo()` / B2+B6 IP 组合键
- 默认表情 bitmap / 默认 saved face 示例

### 3. overlay 通用生命周期

| 参数 | 值 |
|---|---:|
| `FLASH_HOLD_MS` | `1000 ms` |
| overlay types | `mode`, `interval`, `brightness` |
| 电池 overlay 是否使用 `FLASH_HOLD_MS` | 否，电池使用自己的 active/expires/phase 状态 |

#### 3.1 普通 overlay 启动

亮度、interval、M/A 都调用等价逻辑：

```python
flash_active = True
flash_kind = kind
flash_value = value
flash_expires_ms = now + 1000
```

#### 3.2 普通 overlay 到期

每个主循环 tick 检查：

```python
if flash_active and now >= flash_expires_ms:
    flash_active = False
    flash_kind = None
    flash_value = None
    render_current_visual(force=True)   # 恢复当前 face
```

如果 `battery_display_active == True`，不会执行普通 flash 到期恢复逻辑。

### 4. 颜色常量

| 名称 | RGB | Hex | 用途 |
|---|---:|---:|---|
| `BRIGHTNESS_COLOR` | `(0, 120, 255)` | `#0078FF` | 亮度百分比、太阳图标 |
| `MODE_COLOR` | `(180, 0, 255)` | `#B400FF` | M/A、interval、clock icon、interval edge flash |
| `EDGE_FLASH_COLOR` | `(0, 120, 255)` | `#0078FF` | 亮度 clamp edge flash |
| `DEFAULT_COLOR` | `(0, 120, 255)` | `#0078FF` | 默认数字/电池 fallback |
| charge-voltage text | `(255, 255, 255)` | `#FFFFFF` | 充电输入电压页面文字 |
| battery fallback | `(255, 0, 0)` | `#FF0000` | 电池百分比为空时显示 `0%` |

### 5. 字符、图标、bitmap 资源

#### 5.1 7×5 / 特殊字符 glyph

这些 glyph 被亮度、interval、电池数字页共用。`_render_string()` 字符间隔为 1 列；带图标时文字 y 起点为 `9`，无图标时文字 y 起点为 `(18 - 7)//2 = 5`。

#### `_FONT[0]`

```text
.###.
#...#
#..##
#.#.#
##..#
#...#
.###.
```

#### `_FONT[1]`

```text
.##..
#.#..
..#..
..#..
..#..
..#..
#####
```

#### `_FONT[2]`

```text
.###.
#...#
....#
...#.
..#..
.#...
#####
```

#### `_FONT[3]`

```text
####.
....#
....#
.###.
....#
....#
####.
```

#### `_FONT[4]`

```text
...#.
..##.
.#.#.
#..#.
#####
...#.
...#.
```

#### `_FONT[5]`

```text
#####
#....
####.
....#
....#
#...#
.###.
```

#### `_FONT[6]`

```text
.###.
#...#
#....
####.
#...#
#...#
.###.
```

#### `_FONT[7]`

```text
#####
....#
...#.
..#..
.#...
.#...
.#...
```

#### `_FONT[8]`

```text
.###.
#...#
#...#
.###.
#...#
#...#
.###.
```

#### `_FONT[9]`

```text
.###.
#...#
#...#
.####
....#
#...#
.###.
```


#### `_FONT[S]`

```text
.####
#....
#....
.###.
....#
....#
####.
```

#### `_FONT[V]`

```text
#...#
#...#
#...#
.#.#.
.#.#.
..#..
..#..
```

#### `_DOT`

```text
.
.
.
.
.
.
#
```

#### `_PCT_3`

```text
#.#
..#
.#.
.#.
#..
#.#
...
```


#### 5.2 `CLOCK_ICON` 22×18

```text
......................
.........####.........
........#...##........
........#..#.#........
........#....#........
........#....#........
.........####.........
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### 5.3 `SUN_ICON_1` 22×18

源码 `_sun_icon_rows(percent)` 始终返回 `SUN_ICON_1`。`SUN_ICON_2` / `SUN_ICON_3` 在当前源码中不会被亮度 overlay 使用。

```text
......................
.......#......#.##....
....##.#......#.......
........#....#........
.........####..#......
.......#........#.....
......#....#..........
...........#..........
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### 5.4 `_BIG_A` 原始 10×13 bitmap

```text
...####...
..######..
.##....##.
.##....##.
.##....##.
.##....##.
.########.
.########.
.##....##.
.##....##.
.##....##.
.##....##.
.##....##.
```

#### 5.5 `_BIG_M` 原始 10×13 bitmap

```text
##......##
###....###
####..####
##.####.##
##..##..##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
```

#### 5.6 `_BIG_A` 居中到 22×18 后的实际画面

```text
......................
......................
.........####.........
........######........
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
.......########.......
.......########.......
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
......................
......................
......................
```

#### 5.7 `_BIG_M` 居中到 22×18 后的实际画面

```text
......................
......................
......##......##......
......###....###......
......####..####......
......##.####.##......
......##..##..##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......................
......................
......................
```

#### 5.8 `BATTERY_ICON` 基础 22×18 bitmap

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### 6. `_render_string()` 精确布局规则

所有 `NN%`、`x.xS`、`N.NV`、`NM`、`N.NH`、`N.N` 页面都使用同一个文本布局规则。

```python
gap = 1
glyphs = [_glyph_for(ch) for ch in text]
total_w = sum(width(g) for g in glyphs) + gap * (len(glyphs) - 1)
x0 = (22 - total_w) // 2
y0 = 9 if icon_rows is not None else 5
```

绘制流程：

1. `clear()` 清空整个 LED buffer。
2. 如果有 icon：从 `(x0=0, y0=0)` 绘制完整 22×18 icon bitmap。
3. 文本使用 `color` 绘制到 `(x0, y0)`。
4. 每个字符之间空 1 列。
5. 任何落在无效物理 LED 位置的像素由 `logical_to_led_index()` 丢弃。
6. 绘制完成后 `show()`。

### 7. M/A overlay 完整逻辑

#### 7.1 触发

B3 按下时不切换；B3 释放时切换。B3 如果被组合键消费，则释放时不切换。

```python
# Persistent button state.
b3_consumed_by_combo = False

# On B3 press.
b3_consumed_by_combo = False

# On B3+B1 or B3+B2 interval action, including repeat.
b3_consumed_by_combo = True

# On B3 release.
if not b3_consumed_by_combo:
    old_auto = bool(state.auto)
    state.auto = not old_auto
    render_mode(state.auto)
    start_or_extend_flash("mode", state.auto)

b3_consumed_by_combo = False
```

#### 7.2 显示

| auto 状态 | glyph | 颜色 | 持续 |
|---|---|---|---:|
| `True` | `_BIG_A` | `MODE_COLOR #B400FF` | `1000 ms` |
| `False` | `_BIG_M` | `MODE_COLOR #B400FF` | `1000 ms` |

位置：

```python
x0 = (22 - 10) // 2 = 6
y0 = (18 - 13) // 2 = 2
```

### 8. interval overlay 完整逻辑

#### 8.1 参数

| 参数 | 值 |
|---|---:|
| 默认 interval | `1.0 s` |
| 步进 | `0.5 s` |
| 最小值 | `0.5 s` |
| 最大值 | `10.0 s` |
| overlay hold | `1000 ms` |
| 颜色 | `MODE_COLOR #B400FF` |

#### 8.2 按钮方向

```python
# B3 held + B1
interval_s = clamp_interval(interval_s - 0.5)

# B3 held + B2
interval_s = clamp_interval(interval_s + 0.5)
```

#### 8.3 clamp

```python
if value < 0.5:
    value = 0.5
elif value > 10.0:
    value = 10.0
value = round(value * 10) / 10.0
```

#### 8.4 文本格式

```python
tenths = int(round(seconds * 10))
whole = tenths // 10
frac = tenths % 10
text = "10" if whole == 10 and frac == 0 else f"{whole}.{frac}"
render_text = text + "S"
```

例：

| interval | text |
|---:|---|
| `0.5` | `0.5S` |
| `1.0` | `1.0S` |
| `9.5` | `9.5S` |
| `10.0` | `10S` |

#### 8.5 渲染

```python
render_interval(interval_s):
    _render_string(format_interval(interval_s) + "S", MODE_COLOR, icon_rows=CLOCK_ICON)
```

#### 8.6 interval clamp edge flash

| 条件 | edge | 颜色 |
|---|---|---|
| B3+B1 继续减少且已到 `0.5s` | bottom row `y=17` | `MODE_COLOR #B400FF` |
| B3+B2 继续增加且已到 `10.0s` | top row `y=0` | `MODE_COLOR #B400FF` |

源码在 `adjust_interval()` 中先 `render_interval()`，再 `start_or_extend_flash("interval")`，最后执行一次 `overlay_edge_flash()`，主循环后续会继续叠加 edge flash 直到 305ms 结束。

### 9. brightness overlay 完整逻辑

#### 9.1 参数

| 参数 | 值 |
|---|---:|
| brightness 存储单位 | raw LED brightness / channel cap |
| 默认 raw brightness | `60`，显示为 `30%` |
| 步进 | `8` raw units |
| 最小 raw brightness | `0`，显示为 `0%` |
| 最大 raw brightness | `200`，显示为 `100%` |
| LED 通道理论满量程 | `255` |
| overlay hold | `1000 ms` |
| 颜色 | `BRIGHTNESS_COLOR #0078FF` |

#### 9.2 按钮方向

```python
# B4 / GPIO40 / BTN_BRIGHT_DN
brightness_raw = clamp_brightness_raw(brightness_raw - 8)

# B5 / GPIO41 / BTN_BRIGHT_UP
brightness_raw = clamp_brightness_raw(brightness_raw + 8)
```

#### 9.3 clamp 与百分比换算

```python
def clamp_brightness_raw(value):
    if value < 0:
        return 0
    if value > 200:
        return 200
    return int(value)

def brightness_raw_to_percent(raw):
    raw = clamp_brightness_raw(raw)
    return int(round(raw * 100 / 200))
```

显示关系：

| raw brightness | 对应 LED 通道比例 | 显示百分比 |
|---:|---:|---:|
| `0` | `0 / 255` | `0%` |
| `8` | `8 / 255` | `4%` |
| `40` | `40 / 255` | `20%` |
| `100` | `100 / 255` | `50%` |
| `160` | `160 / 255` | `80%` |
| `200` | `200 / 255` | `100%` |

#### 9.4 渲染

```python
def render_brightness_raw(raw):
    percent = brightness_raw_to_percent(raw)
    _render_string(str(int(percent)) + "%", BRIGHTNESS_COLOR, icon_rows=SUN_ICON_1)
```

显示内容永远是百分比文字，不直接显示 raw brightness。

#### 9.5 brightness clamp edge flash

| 条件 | edge | 颜色 |
|---|---|---|
| B4 继续降低且已到 raw `0` | bottom row `y=17` | `EDGE_FLASH_COLOR #0078FF` |
| B5 继续升高且已到 raw `200` | top row `y=0` | `EDGE_FLASH_COLOR #0078FF` |

执行顺序：

```python
apply_brightness_raw()
render_brightness_raw(brightness_raw)
start_or_extend_flash("brightness", brightness_raw)
overlay_edge_flash_if_clamped()
```

`start_or_extend_flash("brightness", brightness_raw)` 必须先于 `overlay_edge_flash_if_clamped()` 执行，使触发 tick 的首帧也拥有正确的 `flash_kind`。brightness clamp 使用 `EDGE_FLASH_COLOR`；interval clamp 使用 `MODE_COLOR`，同样必须先设置 `flash_kind = "interval"` 再叠加 edge flash。

### 10. edge flash 完整动画逻辑

edge flash 用于 brightness / interval 到达 clamp 边界时的顶边/底边反馈。它不是独立 bitmap，而是在当前 overlay 上叠加一条渐变边缘。

| 参数 | 值 |
|---|---:|
| attack | `45 ms` |
| decay | `260 ms` |
| total | `305 ms` |
| top edge row | `y = 0` |
| bottom edge row | `y = 17` |
| x center | `(22 - 1) / 2 = 10.5` |
| max distance | `10.5` |
| minimum spatial factor | `0.20` |

#### 10.1 时间 envelope

```python
if elapsed_ms < 0 or elapsed_ms > 305:
    factor = 0.0
elif elapsed_ms <= 45:
    factor = elapsed_ms / 45.0
else:
    t = (elapsed_ms - 45) / 260.0
    factor = 1.0 - t
```

#### 10.2 空间 envelope

```python
for x in range(22):
    dist = abs(x - 10.5)
    spatial = 1.0 - (dist / 10.5)
    if spatial < 0.20:
        spatial = 0.20
    level = factor * spatial
```

#### 10.3 颜色合成

```python
flash_color = MODE_COLOR if flash_kind == "interval" else EDGE_FLASH_COLOR
pixel_rgb = scale_color((
    int(flash_color[0] * level),
    int(flash_color[1] * level),
    int(flash_color[2] * level),
))
```

只对 `logical_to_led_index(x, y) != None` 的有效 LED 写入。

#### 10.4 edge 有效行 mask

```text
top y=0:    ..##################..
bottom y=17:...################...
```

### 11. B6 电池页面与充电动画完整逻辑

#### 11.1 B6 短按

| 项目 | 值 |
|---|---:|
| 长按阈值 | `700 ms` |
| 短显持续 | `2000 ms` |
| phase count | `1` |
| phase index | `0` |
| 页面 | `percent_short` |
| 充电 sweep | 禁用，即使当前正在充电 |
| 到期行为 | `stop_battery_display()`，恢复当前 face |

启动逻辑：

```python
battery_display_active = True
battery_display_single_shot = True
flash_active = False
battery_next_refresh_ms = 0
battery_visual_next_refresh_ms = 0
refresh_battery_overlay_cache(force=True)
battery_display_toggle_started_ms = now
battery_display_phase_index = 0
battery_display_phase_count = 1
battery_display_next_phase_ms = 0
battery_display_expires_ms = now + 2000
render_battery_overlay(refresh_phase=False, refresh_cache=False)
```

#### 11.2 B6 长按

B6 按住达到 700ms，并且 B3 / B2 未按住时，进入长显。

| 项目 | 非充电 | 充电 |
|---|---:|---:|
| phase count | `2` | `3` |
| phase 0 | 百分比 `NN%` | 百分比 `NN%` |
| phase 1 | 电池电压 `N.NV` | 电池电压 `N.NV` |
| phase 2 | 不存在 | 充电输入电压 `N.N` |
| phase 切换周期 | `2000 ms` | `2000 ms` |
| 充电动画刷新 | 无 | 每 `50 ms` 尝试重绘 |

启动逻辑：

```python
b6_long_fired = True
battery_display_active = True
flash_active = False
flash_kind = None
flash_value = None
battery_next_refresh_ms = 0
battery_visual_next_refresh_ms = 0
refresh_battery_overlay_cache(force=True)
battery_display_toggle_started_ms = now
battery_display_phase_index = 0
battery_display_phase_count = 3 if cached_is_charging else 2
battery_display_next_phase_ms = now + 2000
render_battery_overlay(refresh_phase=False, refresh_cache=False)
```

释放 B6：如果 `battery_display_active` 或 `b6_long_fired`，调用 `stop_battery_display()`，立即恢复当前 face。

#### 11.3 电池页面刷新调度

| 参数 | 值 |
|---|---:|
| 电池显示缓存刷新周期 | `100 ms` |
| 动画视觉刷新周期 | `50 ms` |
| 平均窗口 | `1000 ms` |
| 平均窗口采样间隔 | `20 ms` |
| 校准/历史日志周期 | `30000 ms` |

长显 active 时，每个主循环 tick 执行：

```python
cache_due = now >= battery_next_refresh_ms
visual_due = now >= battery_visual_next_refresh_ms
phase_due = now >= battery_display_next_phase_ms

instant_charge_v = read_charge_voltage()
charging_instant = is_charging_voltage(instant_charge_v, previous=cached_is_charging)
if charging_instant != cached_is_charging:
    cache_due = True

if cache_due:
    cache_changed = refresh_battery_overlay_cache(force=charge_state_flipped)

if phase_due:
    update_battery_display_phase()

animate_due = cached_is_charging and visual_due

if cache_changed or phase_changed or animate_due:
    render_battery_overlay(refresh_phase=False, refresh_cache=False)
    battery_visual_next_refresh_ms = now + 50
```

短显 active 时：

- 先检查 `now >= battery_display_expires_ms`，到期则停止显示。
- 每个 tick 都读一次 instant charge ADC。
- 若充电状态改变，强制刷新缓存并重绘。
- 不做 phase 切换，不做 charging sweep 动画。

#### 11.4 充电状态判定

| 项目 | 值 |
|---|---:|
| 充电检测 GPIO | `GPIO1` |
| ADC 参考 | `3.3 V` |
| 单次采样数 | `16` |
| R1 | `270000 Ω` |
| R2 | `47000 Ω` |
| 进入充电 | `Vcharge > 4.0 V` |
| 退出充电 | `Vcharge <= 3.0 V` |
| 中间区 | 保持 previous 状态 |

```python
Vcharge = Vadc * (270000 + 47000) / 47000
```

```python
def is_charging_voltage(charge_v, previous=False):
    if charge_v is None:
        return bool(previous)
    if charge_v > 4.0:
        return True
    if charge_v <= 3.0:
        return False
    return bool(previous)
```

当充电状态变化时：

```python
target_phase_count = 3 if charging else 2
if battery_display_phase_count != target_phase_count:
    battery_display_phase_count = target_phase_count
    battery_display_phase_index = 0
    battery_display_toggle_started_ms = now
    battery_display_next_phase_ms = now + 2000
```

### 12. 电池 ADC 与百分比换算

#### 12.1 电池电压读取

| 项目 | 值 |
|---|---:|
| 电池 ADC GPIO | `GPIO10` |
| ADC 参考 | `3.3 V` |
| 单次采样数 | `16` |
| R1 | `100000 Ω` |
| R2 | `57000 Ω` |
| 固件校准 scale | `2.708333` |
| 固件校准 offset | `+0.2033 V` |

```python
instant_vbat = Vadc * 2.708333 + 0.2033
```

#### 12.2 百分比换算

当前程序不再用 `min_v/max_v` 线性区间和 `0.12 V` 端点吸附计算百分比。电池百分比来自固定 2S LiPo 分段 LUT；`battery_calib.json` 的 `v_min/v_max` 仍保留给诊断和手动 reset API，但不参与百分比映射。

```python
BATTERY_PERCENT_LUT = [
    (8.40, 100),
    (8.10,  90),
    (7.90,  80),
    (7.70,  65),
    (7.50,  50),
    (7.30,  35),
    (7.10,  20),
    (6.80,  10),
    (6.50,   5),
    (6.20,   0),
]

def battery_percent_from_voltage(vbat):
    if not isfinite(vbat):
        return 0
    if vbat >= BATTERY_PERCENT_LUT[0][0]:
        return 100
    if vbat <= BATTERY_PERCENT_LUT[-1][0]:
        return 0
    for (v_hi, p_hi), (v_lo, p_lo) in adjacent_pairs(BATTERY_PERCENT_LUT):
        if vbat < v_hi and vbat >= v_lo:
            t = (vbat - v_lo) / (v_hi - v_lo)
            return round(p_lo + t * (p_hi - p_lo))
    return 0
```

采样显示值先经过基于真实时间间隔的 EMA。目标时间常数为 `20 s`：

```python
alpha = 1.0 - exp(-dt_s / 20.0)
vbat = previous_vbat * (1.0 - alpha) + instant_vbat * alpha
```

百分比整数带 `±1%` dead-band：只有首次有效读数，或 LUT 结果和当前显示值相差超过 1 个百分点时，才更新显示百分比。

```python
raw_percent = battery_percent_from_voltage(vbat)
if first_valid_reading or abs(raw_percent - battery_percent) > 1:
    battery_percent = raw_percent
```

#### 12.3 已删除：使用时间 / 充电时间页

当前规格不实现任何使用时间或充电时间动画。Agent 不得实现以下内容：

- 剩余使用时间页。
- 充电完成时间页。
- `remaining_h` / `charge_time_h` 页面计算。
- `0M`、`1.5H`、`--` 等时间文本显示。

### 13. 电池颜色逻辑

```python
p = max(0, min(100, int(percent)))
if p <= 10:
    color = (255, 0, 0)
elif p <= 30:
    t = (p - 10) / 20.0
    color = (255, int(165 * t), 0)
elif p <= 50:
    t = (p - 30) / 20.0
    color = (int(255 * (1.0 - t)), int(165 + (90 * t)), 0)
else:
    color = (0, 255, 0)
```

| 百分比 | RGB | Hex |
|---:|---:|---:|
| 0 | `(255, 0, 0)` | `#FF0000` |
| 10 | `(255, 0, 0)` | `#FF0000` |
| 20 | `(255, 82, 0)` | `#FF5200` |
| 30 | `(255, 165, 0)` | `#FFA500` |
| 40 | `(127, 210, 0)` | `#7FD200` |
| 50 | `(0, 255, 0)` | `#00FF00` |
| 100 | `(0, 255, 0)` | `#00FF00` |

页面颜色：

| 页面 | 图标颜色 | 文字颜色 |
|---|---|---|
| 百分比 | battery color | battery color |
| 电池电压 | battery color | battery color |
| 充电输入电压 | battery color | white `#FFFFFF` |
| percent 为 `None` fallback | red `#FF0000` | red `#FF0000` |

### 14. 电池图标填充与充电动画

#### 14.1 电池内部填充区域

| 项目 | 值 |
|---|---:|
| 内部填充行 | `y = 2, 3, 4` |
| 内部起始列 | `x = 7` |
| 内部列数 | `8` |
| 可填充列编号 | `0..7` |

#### 14.2 非动画填充列

```python
p = max(0, min(100, int(percent)))
if p < 10:
    filled_cols = 0
elif p > 90:
    filled_cols = 8
else:
    filled_cols = ((p - 10) * 8 + 79) // 80
```

| percent 条件 | filled_cols |
|---|---:|
| `< 10` | `0` |
| `10..20` | `1` |
| `21..30` | `2` |
| `31..40` | `3` |
| `41..50` | `4` |
| `51..60` | `5` |
| `61..70` | `6` |
| `71..80` | `7` |
| `81..90` | `8` |
| `> 90` | `8` |

#### 14.3 非动画填充 bitmap 帧

#### `BATTERY_FILL_0_COLS`

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_1_COLS`

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_2_COLS`

```text
......................
......#########.......
......###......#......
......###......#......
......###......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_3_COLS`

```text
......................
......#########.......
......####.....#......
......####.....#......
......####.....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_4_COLS`

```text
......................
......#########.......
......#####....#......
......#####....#......
......#####....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_5_COLS`

```text
......................
......#########.......
......######...#......
......######...#......
......######...#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_6_COLS`

```text
......................
......#########.......
......#######..#......
......#######..#......
......#######..#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_7_COLS`

```text
......................
......#########.......
......########.#......
......########.#......
......########.#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_FILL_8_COLS`

```text
......................
......#########.......
......##########......
......##########......
......##########......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```


#### 14.4 充电动画规则

只有长显模式且 `charging == True` 时播放图标动画：

```python
animate_icon = (not battery_display_single_shot) and charging
```

短显模式永远：

```python
animate_icon = False
```

充电动画 phase time：

```python
charging_phase_ms = now - battery_display_toggle_started_ms
charge_step_interval_s = 0.2
```

##### A. `percent < 10`

低于 10% 时不 sweep，只闪烁第 1 个内部列：

```python
flash_period_ms = 300
on = ((charging_phase_ms // 300) % 2) == 0
lit_cols = 1 if on else 0
```

低电量充电闪烁 ON：

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

低电量充电闪烁 OFF：

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

##### B. `percent >= 10`

```python
filled_cols = _battery_fill_cols(percent)
target_cols = 8 if percent > 90 else max(1, filled_cols)
step_ms = int(0.2 * 1000)  # 200
anim_step = charging_phase_ms // step_ms
lit_cols = (anim_step % target_cols) + 1
```

这意味着：

- `10%..20%`：只显示 1 列，视觉上不移动。
- `21%..30%`：1 → 2 → 1 → 2。
- `31%..40%`：1 → 2 → 3 → 1 ...
- `>90%`：1 → 2 → ... → 8 → 1 ...

##### C. sweep bitmap 帧

#### `BATTERY_CHARGE_SWEEP_1_COLS`

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_2_COLS`

```text
......................
......#########.......
......###......#......
......###......#......
......###......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_3_COLS`

```text
......................
......#########.......
......####.....#......
......####.....#......
......####.....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_4_COLS`

```text
......................
......#########.......
......#####....#......
......#####....#......
......#####....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_5_COLS`

```text
......................
......#########.......
......######...#......
......######...#......
......######...#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_6_COLS`

```text
......................
......#########.......
......#######..#......
......#######..#......
......#######..#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_7_COLS`

```text
......................
......#########.......
......########.#......
......########.#......
......########.#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### `BATTERY_CHARGE_SWEEP_8_COLS`

```text
......................
......#########.......
......##########......
......##########......
......##########......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```


#### 14.5 源码中 `flash_last_column`

`render_battery_overlay()` 总是设置：

```python
flash_last_column = False
```

因此非充电状态下不会闪烁最后一列。`_battery_icon_rows()` 虽然支持 `flash_last_column`，但当前按钮电池页面不使用。

### 15. 电池页面 render 函数对应关系

#### 15.1 百分比页

```python
render_battery_percent(
    pct,
    color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    animate=animate_icon,
)
```

文本：`f"{int(pct)}%"`

#### 15.2 电池电压页

```python
render_battery_voltage(
    v_bat,
    percent=pct,
    color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    text_color=None,
    animate=animate_icon,
)
```

文本：

```python
if voltage is None:
    text = "0.0V"
else:
    text = "{:.1f}V".format(voltage)
```

特殊布局：

```python
char_extra_x = {3: 1}
```

也就是第 4 个字符额外右移 1 列，用于 `N.NV` 中的 `V`。


#### 15.3 充电输入电压页

```python
render_charge_voltage(
    charge_v,
    percent=pct,
    icon_color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    animate=animate_icon,
)
```

文本：

```python
text = "0.0" if charge_v is None else "{:.1f}".format(charge_v)
text_color = (255, 255, 255)
icon_color = battery_color
```

### 16. 实现校验清单

Agent 重建时必须满足：

- [ ] 不实现 IP/SSID 滚动，不包含 `_SCROLL_FONT`。
- [ ] B3 按下不切换，B3 释放才切换 A/M。
- [ ] B3 被 B1/B2 interval 组合键消费后，释放 B3 不切换 A/M。
- [ ] 普通 overlay 保持 1000ms，到期恢复当前 face。
- [ ] interval 使用 `MODE_COLOR #B400FF`，格式为 `0.5S` 到 `9.5S`，`10.0s` 显示为 `10S`。
- [ ] B3+B1 是 interval `-0.5s`，B3+B2 是 interval `+0.5s`。
- [ ] brightness 使用 `BRIGHTNESS_COLOR #0078FF`，显示 `round(raw * 100 / 200)%` + `SUN_ICON_1`。
- [ ] B4/GPIO40 是 raw brightness `-8`，B5/GPIO41 是 raw brightness `+8`，clamp 范围 `0..200`。
- [ ] 所有 B1/B2/B4/B5 repeat 都是先等 400ms，再每 140ms 触发一次。
- [ ] edge flash attack 45ms、decay 260ms，总 305ms，空间中心 10.5，最低空间强度 0.20。
- [ ] interval edge flash 用 `MODE_COLOR`，brightness edge flash 用 `EDGE_FLASH_COLOR`。
- [ ] B6 短按释放后显示电池百分比 2000ms，不播放 charging sweep。
- [ ] B6 长按 700ms 后进入电池循环；非充电 2 页，充电 3 页。
- [ ] 长显释放 B6 立即停止电池页面并恢复当前 face。
- [ ] 充电状态每个主循环 tick 读取 charge ADC 以快速切换动画状态。
- [ ] 充电图标动画每 50ms 尝试刷新，但 sweep 每 200ms 改变一列。
- [ ] `percent < 10` 充电时只闪烁第 1 列，300ms 半周期，不做 sweep。
- [ ] 充电输入电压页面文字固定白色，图标仍使用电池百分比颜色。
- [ ] 不实现电池使用时间页和充电时间页，不显示 `0M` / `1H` / `1.5H` / `--` 时间文本。
- [ ] 所有绘制都遵守 22×18 不规则矩阵 mask 和 serpentine 坐标映射。

---

## 21. 历史修复记录与回归验证（整合 5 份修复报告）

> 合并说明：本章对以下五份修复报告做**逻辑去重合并**，而非拼接。它们高度重叠（同一条上传命令出现 5 次、字体融合出现在 2 份、6.4 帧率控件对齐出现在 3 份且存在演进/冲突），此处按主题归并，冲突点见 §22。来源：`TWO_CHAT_ISSUES_FIX_REPORT.md`、`ARK12_FUSION_WEBUI_LED_FINAL_FIX_REPORT.md`、`FONT_REPLACEMENT_REPORT_ARK12_FUSION_REAPPLIED.md`、`CARD_EDGE_FPS_ALIGNMENT_V3_REPORT.md`、`SCROLL_FPS_CARD_BORDER_ALIGNMENT_FINAL_REPORT.md`。

### 21.1 启动首帧花屏 / 随机 LED 数据修复

来源：`TWO_CHAT_ISSUES_FIX_REPORT.md`（问题 1）。

问题：在加载到第一帧有效 saved face 之前，启动瞬间出现首帧花屏 / 随机 LED 数据（WS2812/SK6812 数据线在第一次有意 clear/show 序列前浮空或被噪声时钟驱动）。

修复（`src/main.cpp`、`src/config.h`）：`setup()` 在 `Serial.begin()` 与第一次 `ledStripBegin()` 之前，立即把 LED 数据脚拉低：

```cpp
pinMode(LED_PIN, OUTPUT);
digitalWrite(LED_PIN, LOW);
delay(LED_BOOT_DATA_LOW_HOLD_MS);
delayMicroseconds(LED_SIGNAL_RESET_US);
```

启动时序常量改为更保守值：

```cpp
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS  = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS     = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS = 120;
```

验收：上电后在首个有效 saved face 出现前不得有随机/花屏 LED 数据。

### 21.2 Ark12 Fusion 字体替换与 WebUI/LED glyph 修复

来源：`ARK12_FUSION_WEBUI_LED_FINAL_FIX_REPORT.md` 与 `FONT_REPLACEMENT_REPORT_ARK12_FUSION_REAPPLIED.md`（两份描述同一字体融合工作，已合并去重）。

**修复的根因：**

1. 压缩后的 WebUI 资源可能过期：`run_rinachan_unifont.ps1` 重建/内嵌了 GNU Unifont 子集到 `styles.css`，但未重新生成 `styles.css.gz`；若 ESP32 提供 `.gz` 资源，浏览器仍可能收到旧 CSS。
2. 浏览器字体匹配太脆弱：旧包用单独的 `Ark Pixel 12px Fusion Fallback` 字族；新版把 fallback WOFF2 注册到与 Ark 相同的字族 `Ark Pixel 12px Monospaced`，并用真实 cmap 生成确定性的 `unicode-range`。
3. WebUI JSON glyph 元组解析字段顺序错误：现按原始 schema 正确读取 `[advance, width, height, xOffset, yOffset, dstY, rowsHex]`。

**替换 / 新增的文件（含 SHA256，来自 reapplied 报告）：**

| 文件 | 动作 | 大小 (bytes) | SHA256 |
|---|---|---:|---|
| `data/resources/fonts/ark12.json` | 替换为严格格式融合 JSON | 2400588 | `fc81caa0a6d04c3ce2000c6b1c439411e48788346df9e42625a41b4d0ae04549` |
| `data/resources/fonts/ark12.json.gz` | 由融合 JSON 重新生成 | 531023 | `e94cb4ac5b63c20b96a7accc4329db24256f78f23ac8840ae23ceb66d3081643` |
| `data/resources/fonts/ark12.woff2` | 替换为打包 Ark12 base web font | 593276 | `97ebb9ae2d1d721eb048e025dd885621d566bd6fa9d38c4a3cf4bd56cc2fb175` |
| `data/resources/fonts/ark12_fallback.woff2` | 新增融合 fallback web font | 260352 | `6a1a4fcd5b6f4ec6c3690d15f7d75816c70e6f1608ba12b40e77589bf526e7a3` |
| `data/styles.css` | 改用 fallback 链 | 127077 | `d2b01a51e061a911ad91617ec5a258735ebbfdfd7f03ca55928a868b518772ef` |
| `data/index.html` | fallback 字体 preload 栈 | 279546 | `2332cb9ce22cf0e556a6bbcd1e290d82a1e506e5a528e18316e6867d4532d824` |
| `data/index.html.gz` | 由 patched HTML 重新生成 | 63613 | `166b95f9914d1aaa05baaa175396b716275d782d689bf3f37d625793ed7c075c` |
| `data/styles.css.gz` | 由 patched CSS 重新生成 | 62049 | `0a580f58c3d03a468e0dbea27be75ab54bf34d46412c5b48b74c8f5fb3200611` |
| `tools/font_fusion/*` | 新增打包融合源资源（供上传脚本） | - | - |
| `run_rinachan_unifont.ps1` | 安装/校验融合 Ark12 资源 | 21185 | `7b7b911a613a91553139536705c72d92fc8dd0c79c5d3e6ce4f3caa3fda19394` |

**上传脚本行为变更：** `run_rinachan_unifont.ps1` 现在在上传前校验 `ark12.json` 至少含 32,000 个 glyph 且包含 `7136 / 71C3 / 6EDA / 6EFE`；若文件缺失或过期，则从 `tools/font_fusion` 复制打包融合文件到 `data/resources/fonts` 并重新生成 `ark12.json.gz`。该脚本在 `uploadfs` 前重新生成压缩 WebUI 资源，避免板子提供过期 CSS/HTML。

**补丁 glyph 验证（JSON bitmap 与 web fallback WOFF2 均存在，且非方块 tofu）：**

| 字符 | 码点 | 宽 | 高 | advance | 点亮像素 |
|---|---:|---:|---:|---:|---:|
| 然 | `U+7136` | 12 | 12 | 12 | 42 |
| 燃 | `U+71C3` | 12 | 12 | 12 | 53 |
| 滚 | `U+6EDA` | 12 | 12 | 12 | 44 |
| 滾 | `U+6EFE` | 12 | 12 | 12 | 50 |

**gzip 同步校验：** `index.html.gz` ↔ `index.html`、`styles.css.gz` ↔ `styles.css`、`ark12.json.gz` ↔ `ark12.json` 均一致。

**浏览器手动验证：** 上传后硬刷新 WebUI 一次，DevTools Console 执行：

```js
document.fonts.check('12px "Ark Pixel 12px Monospaced"', '然燃滚滾')
```

期望返回 `true`。随后在文字滚动输入 `然燃滚滾` 并发送；加载器若 `ark12.json` 不含这四个补丁 glyph 会显式报错，不会静默使用 `□`。

### 21.3 6.4 帧率（FPS）控件 card 边缘对齐

来源：`TWO_CHAT_ISSUES_FIX_REPORT.md`（问题 2 及其“追加修复”）、`CARD_EDGE_FPS_ALIGNMENT_V3_REPORT.md`（v3）、`SCROLL_FPS_CARD_BORDER_ALIGNMENT_FINAL_REPORT.md`（最终版）。三份描述同一控件的对齐演进，**最终版（card 外框对齐）为权威结论**，演进与冲突见 §22。

问题：6.4 文字滚动页的帧率控件（`重置默认帧率` / `-5` / `+5` / `#scroll-speed` 数字框 / `scroll-speed-range` 滑条）在移动端布局错位，右边缘对不齐目标 card；`.row` 为 flex-wrap，旧 FPS 行依赖 `.push-right { margin-left:auto; }`，在窄屏上失效，并出现 shrink-wrap 右侧空白。

修复演进：

1. **初版（TWO_CHAT_ISSUES）：** 在 `data/styles.css` 追加页面级 override —— 强制 `#page-scroll .scroll-fps-control` 占满 100% 宽；仅把 FPS 的 `.slider-step-row` 改成 3 列 grid；reset 按钮在左、`-5/+5` 钉在右；取消该控件内的旧 `.push-right` 行为。追加修复进一步用 `flex: 1 1 100%; width:100%; max-width:100%; min-width:0` 消除 shrink-wrap 右侧空白。
2. **v3（CARD_EDGE_FPS_ALIGNMENT_V3）：** 不再只修 `.scroll-fps-control` 自身，给文字滚动控制 card 增加专用 class `scroll-control-card` 并设为单列全宽 grid（`grid-template-columns: minmax(0,1fr)` 等），把控件对齐到 card **内容**右边缘。
3. **最终版（SCROLL_FPS_CARD_BORDER_ALIGNMENT_FINAL）：** 目标改为对齐 card **外框**右边缘。`.card` 默认 `padding:15px`，仅设 `width:100%` 只能对齐内容区、距外框仍差 15px。最终用负 margin 抵消 padding：

```css
:root { --scroll-fps-card-edge-padding: 15px; }
#page-scroll .scroll-fps-card > .field.scroll-fps-control {
  width: calc(100% + (var(--scroll-fps-card-edge-padding) * 2)) !important;
  margin-left:  calc(-1 * var(--scroll-fps-card-edge-padding)) !important;
  margin-right: calc(-1 * var(--scroll-fps-card-edge-padding)) !important;
}
```

使 `-5`、`+5`、`#scroll-speed` 的右边缘对齐到 `scroll-fps-card` 外框右边缘。最终版同时删除了滚动文字输入 textarea 上方重复的 `滚动文字输入` label。

同步文件（各版本均涉及）：`data/index.html`、`data/index.html.gz`、`data/styles.css`、`data/styles.css.gz`。每次改动后 `index.html.gz` / `styles.css.gz` 必须重新生成并验证可精确解压回源文件。

### 21.4 统一上传命令与构建注意

所有修复报告共用同一上传命令（在解压后的 `esp32s3_firmware` 目录内、项目根运行）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

该脚本会重建固件、上传 LittleFS，并在 `uploadfs` 前重新生成压缩 WebUI 资源与校验融合 Ark12 资源。注意：ZIP 内预构建的 `.pio/build/...` 产物若未本地重建可能过期。

---

## 22. 待确认 / 冲突点

合并过程中识别出的冲突与需确认项，按主题列出。优先采纳“最新、最具体、最可执行”的描述（已在对应章节落实），冲突原文保留于此以便追溯。

1. **6.4 FPS 控件对齐目标演进（§21.3）。** 存在三种相互覆盖的实现：初版对齐 `.scroll-fps-control` 自身 → v3 对齐 `scroll-control-card` 的**内容**右边缘 → 最终版对齐 `scroll-fps-card` 的**外框**右边缘（负 margin 抵消 15px padding）。同时存在两个 card class 名（`scroll-control-card` 与 `scroll-fps-card`）。**结论：以最终版（外框对齐、`scroll-fps-card`）为准**；需确认源码中是否还残留 v3 的 `scroll-control-card` 规则，若残留应清理以免双重规则冲突。

2. **文字滚动源文本同步（§19）为“计划”而非“现状”。** v6 是 implementation-ready 规格，但原 `plan.md` 主体（§6、§8.9、§15、§17）描述的当前实现并不包含 `ScrollTimelineMeta` / `/api/scroll/meta` / `scrollTimelineId` 等字段。**需确认：该特性是否已落地于当前源码。** 若未落地，§19 应视为未实现的待办（参见 §16.1）；若已落地，§6.2/§6.11/§8.9 需补充对应字段说明。

3. **`plan_scroll_source_text_v4.md` 源文件损坏。** 该文件含 508 个 NUL 字节（被识别为 binary/data），无法可靠按文本读取。其内容已被 v6 完整覆盖（v6 supersedes v2–v5），故其增量以 v6 为准并删除；如需逐字核对 v4 的 C1–C10 审计标签原文，原文件已不可用，需从版本控制历史找回。

4. **亮度模型双处描述。** §5.4 与 §20（动画规格 1.3）都定义亮度；§20 明确 raw `0..200`、`200/255=100%`、`scale_color()` 为 peak limiter 而非线性乘法。**需确认 §5.4 的亮度上限/cap 定义与 §20 完全一致**（特别是 `0..200` vs 历史 `0..170` cap 的差异——动画规格已用 `0..200`）。

5. **CODE_REVIEW 的 [HIGH] 144KB 静态 SRAM 数组（§18）尚未确认是否已修。** 报告建议把 `fallbackScrollFrameBits_[3072][47]` 改为运行时 `heap_caps_malloc`。需确认当前 `state.h` 是否仍是静态成员；若仍是，应纳入修复计划（§18.6 / §16）。

---

## 23. 已合并文档来源记录

本节记录所有被合并进 `plan.md` 的 Markdown 文件、其内容归并到的章节、以及处理状态。`README.md`（及任意大小写变体）、`data/resources/fonts/README.md`、`tools/font_fusion/README.md`、`.pio/libdeps/**` 下的第三方库文档均未被合并、未被删除。

- `CODE_REVIEW.md`
  - 已合并到：§18（代码审查、架构分析与已知问题），交叉关联 §6、§17
  - 内容：执行摘要、模块架构图与数据流、锁顺序/并发模型、优秀模式（保留项）、HIGH/MEDIUM/LOW 问题与建议、模块逐一分析、优先级修复清单
  - 状态：已完整合并，可删除

- `plan_scroll_source_text_v6.md`
  - 已合并到：§19（文字滚动 6.4 源文本同步实现计划）
  - 内容：v6 完整规格（hard rules、固件改动、WebUI 改动、实现顺序、测试清单），作为 supersede v2–v5 的权威版
  - 状态：已完整合并，可删除

- `plan_scroll_source_text_v2.md` / `v3.md` / `v5.md`
  - 已合并到：§19（其最终决策已被 v6 吸收；§19 合并说明记录了演进，§22 记录相关待确认）
  - 状态：被 v6 取代，增量已并入，可删除

- `plan_scroll_source_text_v4.md`
  - 已合并到：§19（内容被 v6 覆盖）；§22 第 3 条记录其损坏情况
  - 状态：文件损坏（含 508 个 NUL 字节，binary/data），内容已被 v6 取代，可删除；逐字原文如需找回应查版本控制历史

- `animation.md`
  - 已合并到：§20（按钮 LED overlay/动画完整重建规格），交叉关联 §6.12、§5.1、§5.3、§5.4
  - 内容：硬件/坐标映射、亮度 raw 0..200 模型与 scale_color、按钮/组合键/repeat、overlay 生命周期、颜色常量、全部 bitmap（_FONT/CLOCK_ICON/SUN_ICON/_BIG_A/_BIG_M/BATTERY_ICON/BATTERY_FILL/BATTERY_CHARGE_SWEEP）、_render_string 布局、M/A/interval/brightness overlay、edge flash、B6 电池页面与充电动画、电池 ADC 与百分比/颜色换算、实现校验清单
  - 状态：已完整合并（含全部 bitmap），可删除

- `TWO_CHAT_ISSUES_FIX_REPORT.md`
  - 已合并到：§21.1（启动首帧花屏）、§21.3（FPS 控件对齐初版+追加修复）、§21.4（上传命令）
  - 状态：已完整合并，可删除

- `ARK12_FUSION_WEBUI_LED_FINAL_FIX_REPORT.md`
  - 已合并到：§21.2（字体融合根因/验证/gzip/浏览器检查）、§21.4
  - 状态：已完整合并，可删除

- `FONT_REPLACEMENT_REPORT_ARK12_FUSION_REAPPLIED.md`
  - 已合并到：§21.2（替换文件 SHA256 表、脚本校验行为）、§21.4
  - 状态：已完整合并，可删除

- `CARD_EDGE_FPS_ALIGNMENT_V3_REPORT.md`
  - 已合并到：§21.3（v3：内容边缘对齐）、§22 第 1 条（冲突点）
  - 状态：已完整合并（作为演进中间态保留记录），可删除

- `SCROLL_FPS_CARD_BORDER_ALIGNMENT_FINAL_REPORT.md`
  - 已合并到：§21.3（最终版：外框边缘对齐，权威结论）、§22 第 1 条
  - 状态：已完整合并，可删除

### 未合并 / 保留的 Markdown（不删除）

- `README.md`（根目录）— 项目主 README，按要求不修改、不删除
- `data/resources/fonts/README.md` — 字体资源说明，README 变体，保留
- `tools/font_fusion/README.md` — 字体融合工具说明，README 变体，保留
- `.pio/libdeps/esp32s3/**/*.md`（Adafruit NeoPixel、ArduinoJson 的 README/CONTRIBUTING/ISSUE/PR 模板）— 第三方依赖库文档，与本项目计划无关且有独立价值，保留
