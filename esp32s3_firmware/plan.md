# Rina-Chan Board 固件与 WebUI AI 可执行规格书

本文档是基于当前项目实现反向整理的 `plan.md`。它的目标不是普通开发计划，而是一份可执行规格书：任何现代 AI 只读取本文件，不参考旧代码，也应能重建当前 PlatformIO 固件、LittleFS 数据文件、`index.html`、`styles.css` 和相关 WebUI 资源约定。

当前实现目标硬件为 ESP32-S3、370 颗 WS2812B、Arduino Core、PlatformIO、LittleFS、AP-only Web 控制界面。当前实现已明确剔除 I2C 电源管理芯片、PD/充电 IC 控制、硬件温度检测模块；重建时不得加入这些模块。

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
- 2S LiPo 电池/外部充电电压 ADC 监控，使用 trimmed average、时间常数 EMA、固定 2S LiPo LUT 估算电量。
- WebUI V2：基础控制、自定义画板、部件拼脸、文本滚动、调试/电源状态页面。
- 表情库 `saved_faces.json` 读写，默认表情不可删除但可重命名/排序。
- 文本滚动帧只上传到固件 RAM，不保存到 flash。

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
  scripts/
    patch_webserver_timeout.py
    gzip_webui_assets.py
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

### 2.1 从零重建口径

从零重建时，`plan.md` 必须被当作完整规格，而不是历史变更记录。第 2 节只列文件树；实际代码、资源、API、WebUI DOM/CSS/JS 行为必须继续按第 3 到第 14 节实现。不得引入本文件没有列出的运行时文件、隐藏在线依赖或浏览器外部字体。

WebUI 的重建边界如下：

- `data/index.html` 负责 DOM 结构与内联 JavaScript；不得拆成额外运行时 JS 文件，除非同步更新本计划和 gzip/静态托管规则。
- `data/styles.css` 负责全部视觉、布局、动画和字体声明；GNU Unifont 必须以内联 `data:font/woff2;base64,...` 形式写在 CSS 内，Ark12 文字滚动浏览器字体从 `/resources/fonts/ark12.woff2?v=20260511-ark12-merged-trad1` 加载。
- `/resources/fonts/ark12.json` 是文字滚动 rasterizer 的位图字形表；它必须保持 lazy-load，不得在首屏加载阶段同步读取。
- `/resources/loading/rina_icon1_default.png` 与 `/resources/loading/rina_icon2_hover.png` 是 loading overlay 的两个头像状态；默认图标需要在 `<head>` preload 并作为 favicon。
- `scripts/gzip_webui_assets.py` 必须能为 `index.html`、`styles.css`、`resources/fonts/ark12.json` 生成 `.gz` sibling，固件静态服务按 Accept-Encoding 优先返回 gzip。
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
  - `-D HTTP_MAX_DATA_WAIT=200`
  - `-D HTTP_MAX_POST_WAIT=200`
  - `-D HTTP_MAX_SEND_WAIT=200`

`scripts/patch_webserver_timeout.py` 必须在构建前修补 Arduino `WebServer.h` 的 TCP 超时，作为响应迟滞优化。`scripts/gzip_webui_assets.py` 必须在构建期间生成静态资源的 `.gz` 版本，至少覆盖大型 HTML/CSS/JSON/font 资源。

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
- LED driver：`Adafruit_NeoPixel strip(370, 2, NEO_GRB + NEO_KHZ800)`。
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
| B6 | 42 | 初始化并保留，目前无动作 |

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
physicalIndex(logicalIndex):
  for each row:
    rowStart = ROW_OFFSETS[row]
    rowLength = ROW_LENGTHS[row]
    if logicalIndex in [rowStart, rowStart + rowLength):
      localX = logicalIndex - rowStart
      if row is odd:
        return rowStart + (rowLength - 1 - localX)
      else:
        return logicalIndex
```

启动时必须构建 `uint16_t logicalToPhysicalMap[370]`，渲染时使用该数组把逻辑 bit 写到物理 strip index。

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

当前实现的亮度不是独立渐变动画。`setBrightness(raw)` 直接 clamp 到 `[10, 200]`，写入 `runtimeState().brightness` 并请求渲染。`Adafruit_NeoPixel::setBrightness()` 只在渲染任务中检测到亮度变化时调用，避免重复 rescale。

### 5.5 WS2812/BSS138 时序

因为数据线上可能经过 BSS138 电平转换，必须留出比 WS2812 最小复位时间更长的低电平窗口：

- `LED_SIGNAL_RESET_US = 300`
- `LED_RENDER_MIN_GAP_US = 2500`
- 两次 `strip.show()` 之间必须先补足 `LED_RENDER_MIN_GAP_US`。
- `strip.show()` 前后均 `delayMicroseconds(LED_SIGNAL_RESET_US)`。
- 启动清屏后保持：
  - `LED_BOOT_CLEAR_HOLD_MS = 120`
  - `LED_BOOT_STARTUP_SETTLE_MS = 40`
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

当前 `sync.h` 中三个 `with*Lock` 都是 `void` 返回模板：调用方传入 lambda，模板只负责加锁、执行、解锁，不返回 lambda 的结果。需要返回值的代码应直接使用 `lock*/unlock*` 或在外部变量中接收结果。

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

`hardwareBusMutex` 用于保护 LittleFS 文件操作和 `strip.show()`，避免 flash/FS 与硬件输出并发冲突。

### 6.3 `state.h/.cpp`

必须实现 `RuntimeStore` 单例，集中持有：

- `RuntimeState state_`
- `RuntimeFace autoFaces_[MAX_AUTO_FACES]`（128 个元素）
- `uint16_t autoFaceCount_`
- `uint8_t frameBits_[FRAME_BYTES]`（47 字节）
- `uint8_t fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES]`（PSRAM 不可用时的 SRAM 备份，**类的成员**）
- `uint8_t* scrollFrameBits_`（指向 PSRAM 分配或 fallback 数组首元素）
- `bool scrollFrameBitsInPsram_`
- `bool fsMounted_`

启动时调用 `initRuntimeScrollFrameBuffer()`：

- 目标大小：`MAX_SCROLL_FRAMES * FRAME_BYTES = 3072 * 47 = 144384 bytes`。
- 如果 `ESP.getPsramSize() > 0`，用 `heap_caps_malloc(..., MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)`。
- 失败则回退到内部 SRAM 静态二维数组。
- 清零整个 scroll buffer。
- `runtimeScrollFrameBufferReady()` 当前实现恒返回 `true`；重建时仍保留这个接口，以便 Web/API 统一报告 scroll buffer ready。
- `runtimeScrollFrameBits(index)` 在 `index >= MAX_SCROLL_FRAMES` 时返回 `nullptr`，正常情况下返回 `scrollFrameBits_ + index * FRAME_BYTES`。

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

`RuntimeState` 字段必须覆盖：

- color：`colorHex/colorR/colorG/colorB`
- brightness
- mode：`manual` 或 `auto`
- playback：`idle`、`auto_saved_face`、`scroll`、`scroll_paused`、`scroll_step` 等
- lastM370、lastReason、paused
- stats：framesAccepted、framesRejected、framesQueued、framesDequeued、framesDropped、commandsAccepted、commandsRejected、savedFacesWrites、settingsWrites
- bootMs、stateVersion、slowUiDirty、lastSlowUiPublishMs
- autoIntervalMs、lastAutoSwitchMs、autoFaceIndex
- firmware scroll 状态：active、paused、restoreAutoAfterScroll、frameCount、frameIndex、intervalMs、lastFrameMs
- scrollStopEvent：seq、ms、button、source、reason
- deferred face restore：active、kind（uint8_t，内部用 0/1/2 三种枚举值）、autoMode、dueMs、reason

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

1. `Adafruit_NeoPixel` strip 初始化、清屏、渲染。
2. M370 解析与 packed bits 转换。
3. 370 bit 当前帧操作。
4. M370 帧率限制队列。
5. 颜色、亮度状态设置。
6. ISR-safe render request 标记与 render task 通知。

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

- 如果队列为空且距离上次 apply 已超过 33 ms，立即发布。
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
  - 请求 LED render。

`serviceM370FrameQueue()` 必须在 `loop()` 每次调用，用全局 33 ms 限速出队。

#### 6.4.2 渲染

`renderCurrentFrameToLedStrip()` 只能由 Core 1 render task 或启动同步渲染调用。流程：

1. `frameMutex` 下复制当前 `frameBits`、亮度、RGB 到局部变量。
2. 根据 `lastLedShowUs` 补足 `LED_RENDER_MIN_GAP_US`。
3. 若 brightness 与 static `lastAppliedBrightness` 不同，调用 `strip.setBrightness()`。
4. 对 0..369 每个 logical LED：
   - 如果 local frame bit 为 1，写 `strip.Color(colorR,colorG,colorB)`。
   - 否则写 0。
   - 物理 index 使用 `logicalToPhysicalMap[logical]`。
5. show 前 `delayMicroseconds(300)`。
6. `hardwareBusMutex` 下调用 `strip.show()`。
7. 更新 `lastLedShowUs = micros()`。
8. show 后 `delayMicroseconds(300)`。

`ledStripBegin()` 必须：

- `strip.begin()`
- `strip.setBrightness(DEFAULT_BRIGHTNESS)`
- `strip.clear()`
- show 前 300 us，`hardwareBusMutex` 下 `strip.show()`，show 后 300 us。

### 6.5 `scroll.h/.cpp`

必须创建一个 pin 到 Core 1 的 FreeRTOS task：`led_scroll_render`。

任务循环每 1 ms 醒来，或者被 `notifyScrollRenderTask()` 唤醒。流程：

1. 读取并清除 `consumeLedRenderRequest()`，这是主任务写入帧后的高优先级 render 请求。
2. 如果 firmware scroll active、未 paused、有 frameCount、buffer ready：
   - 检查 `millis() - lastScrollFrameMs >= scrollIntervalMs`。
   - 计算错过步数 `rawSteps = elapsed / interval`。
   - `steps = rawSteps % frameCount`，如果为 0 则改为 1。
   - 更新 `scrollFrameIndex` 和 `lastScrollFrameMs`。
   - 长暂停后如果 drift 超过 `interval * 4`，把 `lastScrollFrameMs = now`。
   - 拷贝下一帧到局部 `nextFrame`，标记有滚动帧。
3. 若有滚动帧，进入 `frameMutex`：
   - 只有当 scroll 仍 active 且没有主任务帧抢占时，才写入 `runtimeFrameBits()`。
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
  - 如持久化，保存 runtime settings。
- `setMode("manual")`：
  - `mode = "manual"`
  - 如果 playback 是 `auto_saved_face`，改回 `idle`
  - 如持久化，保存 runtime settings。

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
  - `clearDisplay=true` 时先 `applyBlankFrame("firmware_text_scroll_stop_clear")`，再安排 deferred startup default face restore。
  - deferred restore 不得在 HTTP handler 中阻塞，必须由 `serviceDeferredFaceRestore()` 在 loop 中等 90 ms 后执行。

### 6.7 `buttons.h/.cpp`

按钮去抖：

- `BUTTON_DEBOUNCE_MS = 25`
- B1/B2 长按：
  - delay：650 ms
  - repeat：350 ms
- B4/B5 长按：
  - delay：450 ms
  - repeat：120 ms

动作：

- B1：停止 scroll/其他活动，`applyRelativeSavedFace(+1, "gpio_B1_next_saved_face")`。
- B2：停止 scroll/其他活动，`applyRelativeSavedFace(-1, "gpio_B2_prev_saved_face")`。
- B3：松开时触发，切换 manual/auto；如果之前在 scroll/custom/parts/debug 类非 face playback，先 blank frame，再 deferred restore 当前 face。
- B4：亮度 `-8`，lastReason=`gpio_B4_brightness_down`。
- B5：亮度 `+8`，lastReason=`gpio_B5_brightness_up`。
- B3+B1：auto interval `-500 ms`。
- B3+B2：auto interval `+500 ms`。

如果 GPIO B1/B2/B3 中断 firmware scroll 或 scroll preview，必须写入：

- `scrollStopEventSeq++`
- `scrollStopEventMs = millis()`
- `scrollStopEventButton`
- `scrollStopEventSource`
- `scrollStopEventReason = lastReason`

WebUI 通过 polling 读取这个事件，同步停止页面中的滚动控件。

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

Runtime settings 文件：

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

Saved faces 文件：

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

单个 face：

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
- 每个 face 的 `order` 必须是 1-based 且 >= 1。
- 必须保留至少一个 `type:"default"` face。
- `type:"default"` 且 id 形如 `face_<number>` 时，number 必须 >= 1。
- 如果 `m370` 非空，必须通过 M370 校验。

加载规则：

- 解析 JSON 时使用 PSRAM 优先的 `PsramJsonDocument`。
- 每个有效 face normalized M370 后进入 `runtimeAutoFaces`。
- 最多加载 `MAX_AUTO_FACES = 128`。
- 稳定排序：先 `order`，再原 JSON index。
- 启动时优先选择 `startupDefaultId` 或 `is_startup_default`，否则第一个 default，否则第一个 face。
- `applyStartupFace=true` 时设置默认亮度、playback idle、paused false，然后 apply 启动 face。

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

Battery：

- `BATTERY_CAL_SCALE = 2.708333`
- `BATTERY_CAL_OFFSET_V = 0.2033`
- `instantVbat = adcMv / 1000.0 * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V`

Charge：

- `CHARGE_CAL_SCALE = 6.684982`
- `CHARGE_CAL_OFFSET_V = 0.0712`
- `instantVcharge = adcMv / 1000.0 * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V`

历史分压电阻常量仍可保留作说明：

- Battery R1=100k, R2=57k
- Charge R1=270k, R2=47k

#### 6.9.2 采样周期

- battery：每 1000 ms。
- charge：每 1000 ms。
- `servicePowerMonitor(force=false)` 每 loop 调用，按周期决定是否采样。
- `initPowerMonitor()`：
  - 加载 `/resources/battery_calib.json`
  - 设置 calibration default
  - 设置 ADC resolution/attenuation
  - force sample 一次。

#### 6.9.3 Battery EMA

Battery 使用按真实时间差计算 alpha 的 EMA。`BATTERY_EMA_TAU_S` 和 `CHARGE_EMA_ALPHA` **定义在 `power_monitor.cpp` 文件作用域**，不在 `config.h`：

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

#### 6.9.4 Charge EMA

Charge 使用固定 alpha（见上方 `CHARGE_EMA_ALPHA = 0.20f` 定义于 `power_monitor.cpp`）。但插入/拔出边沿必须 snap 到 `instantVcharge`，避免充电状态延迟数秒。

`charging = vcharge > CHARGE_PRESENT_V`（即 `> 4.0f`，常量定义于 `config.h`）。

#### 6.9.5 电池断开/未供电检测

常量：

- `BATTERY_UNPOWERED_LOW_V = 5.0`
- `BATTERY_DISCONNECT_ADC_DROP_MV = 1000`
- `BATTERY_DISCONNECT_ADC_LOW_MV = 900`
- `BATTERY_RECONNECT_ADC_MV = 1500`

判定：

- 如果上次 ADC 已知，且 `prevAdcMv - adcMv >= 1000`，并且 `adcMv <= 900`，认为出现巨大原始下跌。
- 如果已经断开且 `adcMv < 1500`，保持 disconnected。
- 只要 charger present，充电状态覆盖视觉“未供电”状态，不进入断开显示。
- 如果 instantVbat < 5.0 且无 charger，认为 lowVoltageUnpowered。
- disconnected 或 lowVoltageUnpowered 时：
  - `vbat = 0.0`
  - `batteryPercent = 0`
  - `batteryValid = true`
  - 标记 Web slow dirty。

#### 6.9.6 电量百分比 LUT

必须使用固定 2S LiPo 分段线性 LUT：

```cpp
{ 8.40, 100 },
{ 8.10,  90 },
{ 7.90,  80 },
{ 7.70,  65 },
{ 7.50,  50 },
{ 7.30,  35 },
{ 7.10,  20 },
{ 6.80,  10 },
{ 6.50,   5 },
{ 6.20,   0 }
```

高于第一点 clamp 到 100，低于最后一点 clamp 到 0，中间线性插值并四舍五入。显示百分比有 1% 死区：只有新值与旧值差超过 1，或首次有效读数，才更新 `batteryPercent`。

#### 6.9.7 Flash calibration 文件

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

当前 `v_min/v_max` 只用于诊断和手动 reset API，不用于动态百分比学习。`reset_battery_min`、`reset_battery_max` 会写入当前安全值或 nominal 值，并立刻保存。

#### 6.9.8 Web 发布节流

- 充电状态变化为 fast dirty，立即 `touchRuntimeState()`。
- 慢字段变化每 10000 ms 发布一次，除非 force。
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

仅用于已知扁平字段和 frames array 手动扫描，不替代通用 JSON parser。

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
- 任意 GET notFound 尝试 `serveStaticFile(server.uri())`。
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
- 尝试 heap malloc 8KB buffer，失败回退 512B stack buffer。
- 每发送 4 个 chunk 后 `vTaskDelay(1)` 喂 watchdog。
- File 操作包裹 `hardwareBusMutex`。

LittleFS 挂载失败：

- LED 前 12 颗显示红色错误 pattern。
- Web 请求返回内联 HTML 503，提示运行 `pio run -t uploadfs`。

#### 6.11.3 CORS/OPTIONS

API headers：

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
| `/api/scroll` | POST/OPTIONS | 接收 RAM-only 滚动帧 chunk |
| `/api/command` | POST/OPTIONS | 统一辅助命令 |
| `/api/saved_faces` | GET/POST/OPTIONS | 表情 JSON 读写 |
| notFound | GET | 静态文件 fallback |

#### 6.11.5 `/api/status`

Query：

- `runtimeOnly=1`：只返回 AP、power、renderer、memory，不返回 matrix/endpoints/storage/stats/lastM370。
- `summary=1` 或 `noFrame=1`：跳过 lastM370，减小响应。
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
- firmwareScrollActive、firmwareScrollPaused、restoreAutoAfterScroll
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
- totalBytes/usedBytes，除非 summary 或 scrolling。

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
- 如果 `faceId` 匹配保存表情，更新 `autoFaceIndex`，保证 B1/B2 后续从当前 face 继续。

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
- `append=false`：停止已有 scroll，清空 frameCount/frameIndex。
- `append=true`：从当前 `scrollFrameCount` 继续写入。
- 手动扫描 frames array，逐个字符串解析为 packed bits，写入 `runtimeScrollFrameBits(targetIndex)`。
- 超过 `MAX_SCROLL_FRAMES=3072` 返回 413。
- 任意 invalid M370 返回 400，并清空 `scrollFrameCount`。
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
| `set_auto_interval` | `{ "ms": 3000 }` | 设置 auto interval |
| `set_scroll_interval` | `{ "intervalMs": 100 }` 或 `{ "fps": 10 }` | 改滚动间隔 |
| `start_scroll` | `{ "intervalMs": 100 }` 或 `{ "fps": 10 }` | 从 RAM 缓存启动滚动 |
| `scroll_step` | `{}` | 手动推进一帧 |
| `pause_scroll` | `{}` | 暂停 firmware scroll |
| `resume_scroll` | `{}` | 恢复 firmware scroll |
| `stop_scroll` | `{ "clear": true, "restoreAuto": true }` | 停止滚动，可清屏和恢复 auto |
| `pause` | `{}` | 暂停当前播放 |
| `resume` | `{}` | 恢复 |
| `button` | `{ "button": "B1" }` | 执行按钮动作 |
| `terminate_other_activities` | `{ "targetMode": "face|scroll|..." }` | 为 WebUI 页面切换清理其他活动 |
| `reset_battery_min` | `{}` | 重置最低电压记录 |
| `reset_battery_max` | `{}` | 重置最高电压记录 |

响应包含当前核心 runtime 状态，字段与 `/api/frame` 类似，并含 scrollStopEvent。电池 reset 命令还必须附带 full power。

#### 6.11.10 `/api/saved_faces`

GET：

- 如果 LittleFS 未挂载，503。
- 如果文件不存在，404。
- 直接流式返回 `/resources/saved_faces.json`。

POST：

请求可以是完整 saved faces document，也可以是：

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

## 7. 启动流程

`setup()` 必须按以下顺序：

1. `Serial.begin(115200)`，`delay(200)`。
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
13. `consumeLedRenderRequest()`，清掉 loadSavedFaces 留下的任务渲染请求，避免 double-render。
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
servicePowerMonitor();
serviceDeferredFaceRestore();
serviceAutoPlayback();
vTaskDelay(pdMS_TO_TICKS(1));
```

## 8. WebUI 架构

当前 WebUI 是单文件 `data/index.html` + 外部 `data/styles.css`，不使用构建工具，不依赖 npm。JavaScript 全部内联在 HTML 的 `<script>` 中。

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
  fpsMax: 120,
  firmwareMaxFramesDefault: 3072,
  uploadChunkFrames: 24,
  maxTextChars: 1000
}
textScroll: {
  fontModel: 'ark_pixel_12px_monospaced_bdf_bitmap_v1',
  fontResource: '/resources/fonts/ark12.json',
  fontFamily: 'Ark Pixel 12px Monospaced',
  browserFontSample: 'RinaChanBoard 370 LED 继续 暂停 こんにちは 璃奈ちゃんボード',
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
  holdMs: 150,
  haloBreathMs: 1620,
  haloPeakRatio: 0.5,
  haloToleranceMs: 24,
  haloContractMs: 300,
  imageReleaseMs: 1300,
  blurDurationMs: 500,
  extraMs: 120,
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

注意：`WEBUI_CONFIG.faces.startupFaceId` 当前 HTML fallback 值是 `face_07_triangle_eyes_frown`，但运行时 `saved_faces.json` 顶层 `startupDefaultId` 是 `face_08_triangle_eyes_frown`，且固件和 WebUI 在已加载 face library 后优先采用文件里的 `startupDefaultId`。

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
  <link rel="stylesheet" href="styles.css">
  <!-- hover image 和 ark12 字体 **不** 在 <head> 预加载，由 JS lazy load -->
</head>
```

`data-boot-phase` 生命周期：`"preload"` → `"ui-ready"` → `"ready"`。

`data-boot-phase="preload"` 期间，CSS 应隐藏所有 app 内容（`body>*:not(.loading-overlay) { visibility: hidden }`）。

`data-ui-font-loaded`（`true|false`）和 `data-scroll-font-loaded`（`true|false|unsupported`）动态写入 `<html>` 元素，供调试和选择器使用。

`data-first-page-reveal` 在 waterfall reveal 准备阶段暂时设为 `"preparing"` 再删除，用于抑制 boot-reveal-item 的过渡动画。

#### 8.2.2 App 壳结构

```html
<body>
  <!-- Loading overlay（必须是 body 的第一个直接子元素） -->
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
        <h1>RinaChanBoard 370 LED</h1>
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
      <!-- Hamburger toggle for nav overlay -->
      <button class="brand-nav-toggle" id="brand-nav-toggle" type="button"
              aria-controls="top-page-nav" aria-expanded="false" aria-label="打开页面切换器">
        <span class="menu-icon" aria-hidden="true">
          <span></span><span></span><span></span>
        </span>
      </button>
    </div>
  </aside>

  <!-- Nav overlay 是 body 的直接子元素，位于 .app 之前，z-index 高于 sidebar 和内容 -->
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
</body>
```

`document.body.dataset.page` 在 `switchPage()` 时设为当前页 id（如 `'basic'`），供 CSS `body[data-page="debug"]` 等选择器使用。

#### 8.2.3 隐藏文件输入

自定义页和部件页的 face manager 面板各需要一个隐藏 file input 用于 JSON 导入：

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

`initNav()` 必须动态生成 `PAGES = [['basic','6.1','基础功能'], ...]` 的按钮，按钮内容为 `<span>${name}</span><span class="num">${num}</span>`。菜单打开时 `.top-page-nav.open`、`.nav.open`、`.brand-nav-toggle.active` 同步，`topNav.inert = !open`，关闭时所有 nav button `tabIndex=-1`。点击文档空白处或按 Escape 关闭菜单。

### 8.4 Loading overlay 动画

HTML 结构见 8.2.2。

#### 8.4.1 动画常量（来自 `WEBUI_CONFIG.boot`）

| 常量 | 值 | 说明 |
|---|---|---|
| `HOLD_MS` | 150 | ring contract + image pop 之后到 final-release 的延迟 |
| `HALO_BREATH_MS` | 1620 | halo 呼吸动画完整周期 (ms)，与 CSS `animation-duration: 1.62s` 对齐 |
| `HALO_PEAK_RATIO` | 0.5 | 峰值在周期的哪个比例处 → peak at 810 ms |
| `HALO_TOL_MS` | 24 | 认为已在峰值的时间窗口 |
| `HALO_CONTRACT_MS` | 300 | 与 CSS `--rina-halo-contract-duration: 300ms` 对齐 |
| `IMG_RELEASE_MS` | 1300 | 与 CSS `--rina-image-release-duration: 1300ms` 对齐 |
| `IMG_SHRINK_MS` | `Math.round(IMG_RELEASE_MS * 0.18)` = 234 | 从 `is-final-release` 到开始 `animateReveal()` 的延迟 |
| `BLUR_DUR_MS` | 500 | 径向渐变 reveal rAF 循环总时长 |
| `EXTRA_MS` | 120 | 两处用到：(1) 在 `max(IMG_RELEASE_MS, IMG_SHRINK_MS + BLUR_DUR_MS)` 后等待隐藏；(2) 在 `is-hidden` 后设置 `overlay.hidden = true` |
| `BOOT_MIN_DISPLAY_MS` | 400 | 最短显示时间（从动画开始） |

#### 8.4.2 loading IIFE 结构

整个 loading overlay 动画封装在一个立即执行的 IIFE 中，暴露以下全局接口：

```js
window.rinaLoaderComplete          // = requestFinish，完成后调用
window.rinaLoadingImagesReadyPromise // resolve(true/false) when default image decoded
window.rinaStartLoaderAnimation    // = initOverlay，启动动画
window.rinaLoaderStartedAt         // performance.now() 时的动画开始时间
```

#### 8.4.3 关键函数

**`lockLoaderCenter()` / `syncLoaderHorizontalCenter()`**：读取 `window.visualViewport` 尺寸，将 `--rina-loader-x` 和 `--rina-loader-y` CSS 变量设为实际视口中心（px）。在 `resize` 和 `visualViewport.resize` 上监听，通过 `scheduleLoaderHorizontalCenterSync()` 在 `requestAnimationFrame` 中更新。

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
- 给 `blurScreen` 加 `is-revealing` 类，给 overlay 加 `is-scroll-passthrough`，调用 `unlockBootPageScroll()`。
- 启动 `requestAnimationFrame` 循环，持续 `BLUR_DUR_MS` ms。
- 用自定义缓动 `eic(t)` = `t<0.5 ? 4t³ : 1 - (-2t+2)³/2`（ease-in-cubic-like）。
- 计算 `maxR = max(hypot from center to each corner) + 90`，`feather = clamp(96, 180, round(maxR*0.12))`。
- 每帧按 progress 更新 7 个 CSS 变量，产生从中心向外扩散且带有 feather 的圆形 reveal：
  - `--rina-reveal-solid`, `--rina-reveal-a/b/c/d/e` (间隔 feather/3)，`--rina-reveal-outer`（无限远）。
- 通过 CSS `mask-image` 的多步 radial-gradient（见 9.5 节）产生平滑渐隐效果。

**`doFinish()`**：
```
1. 等待 hover image decode（preloadAfterLoadingImage()）
2. 同时添加 is-ring-contracting + is-image-pop
3. await HALO_CONTRACT_MS (300ms) → 添加 is-halo-hidden
4. await HOLD_MS (150ms) → 添加 is-final-release
5. await IMG_SHRINK_MS (234ms) → 调用 animateReveal()
6. finishOverlay(): await max(IMG_RELEASE_MS, IMG_SHRINK_MS+BLUR_DUR_MS) + EXTRA_MS
                  → overlay 添加 is-hidden
7. await EXTRA_MS → overlay.hidden = true, 移除 is-animating, unlockBootPageScroll()
```

**`requestFinish()`**：调用 `delayToPeak(performance.now())`，等待到最近的 halo 呼吸峰值后调用 `doFinish()`。

**`initOverlay()`**（`= window.rinaStartLoaderAnimation`）：
- 记录 `window.rinaLoaderStartedAt = performance.now()`。
- 给 overlay 添加 `is-assets-ready is-animating`，移除所有其他动画 class。
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
  └─ runPostBootDeferredReads()              // 页面已显示后加载 face library、同步预览、预热 ark12.woff2
```

waterfall reveal 的元素选取使用 `FIRST_PAGE_REVEAL_SELECTOR`（见 8.1），按 `getBoundingClientRect().top` 排序，再按 `left` 二次排序。

### 8.5 LED preview 矩阵

必须在页面中至少创建以下矩阵：

- `matrix-basic`
- `matrix-custom-edit`
- `matrix-parts`
- `matrix-scroll`
- `matrix-debug`

矩阵使用 DOM cell，不用 canvas。每个有效 LED 生成 cell，无效位置留空或不生成。支持：

- 当前帧显示。
- 自定义页可点击编辑（`attachDrawing()` 挂载 click 事件到 `.matrix` 元素，切换对应 cell 的 `editFrame[index]`）。
- 部件页展示拼脸结果。
- 滚动页展示当前滚动帧。
- 调试页展示测试 pattern。

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

`observeMatrixWraps()` 使用 `ResizeObserver` 监听 `.matrix-wrap,.led-preview-card,.debug-measure-card`，任何矩阵 wrapper、预览卡片或 debug 测量卡片尺寸变化时都调用 `scheduleMatrixFitRender(2)` → 在 `settleFrames` 帧后执行 `fitAllMatrices()` 与 `renderMatrices()`（防抖）。如果浏览器没有 `ResizeObserver`，仍要注册 `resize`、`orientationchange`、`visualViewport.resize` 与 `visualViewport.scroll` 作为 fallback。

注意：`WEBUI_CONFIG.led.previewSize.edgeGap = 12` 是遗留配置字段，当前实现的真实等比边界留白由 CSS 变量 `--led-preview-edge-ratio` 控制；`styles.css` 的默认值为 `.1000`。`fitMatrix()` 每次根据 `cell * edgeRatio` 写回当前 `.matrix-wrap` 的 `--matrix-edge-gap`。

### 8.6 基础页

控件：

- 顶部 badge：见 8.2.2（badge-battery-dot、badge-battery-label、badge-charging-dot、badge-charging-label）
- 颜色：
  - `#color-input`（`<input type="text">` 宽度约 7 字符，`#RRGGBB` 格式）
  - `#color-swatch`（可点击的颜色方块，点击触发 native color picker 或打开颜色选择）
  - `#parent-color-select`（角色大类 `<select>`，包裹在 custom select shell 内）
  - `#child-color-select`（具体颜色 `<select>`，包裹在 custom select shell 内）
- 亮度：
  - `#brightness-range`
  - `#brightness-input`
  - `#brightness-reset-default`
  - `#brightness-minus`
  - `#brightness-plus`
  - preset buttons in `#brightness-presets`
- 表情/模式：
  - `#face-prev`
  - `#face-next`
  - `#mode-toggle`
  - auto interval：`#auto-interval-range`、`#auto-interval`
  - `#interval-down`、`#interval-up`
  - preset buttons in `#auto-interval-presets`
- preview：`#matrix-basic`

按钮点击应优先通过 `/api/command` 的 `button` 命令进入固件按钮逻辑，失败时才做本地 fallback。

#### 颜色预设系统

颜色面板提供两级联动下拉：`#parent-color-select`（角色大类，约 6 组）→ `#child-color-select`（具体颜色，约 90 种）。

数据结构（内联于 JS）：

```js
// 每组：['组名', '#hex_代表色', '#hex_代表色2']
// 每个子色：['颜色名', '#RRGGBB']
const parent_color_groups = [
  ['全部/白', '#ffffff', null],
  ['μ\'s', '#f971d4', '#ff6b9d'],
  // ...约 6 组
];
const child_color_groups = {
  '全部/白': [['白色', '#ffffff'], ['粉白', '#fff0f8'], ...],
  'μ\'s': [['矢澤にこ', '#f971d4'], ['南ことり', '#77d7ff'], ...],
  // ...约 90 个颜色条目
};
```

`syncColorDropdownsToHex(hex)` 在固件状态同步时将 hex 值反查回对应 parent/child 选项；查找失败时不修改下拉状态。

颜色下拉的选项条目具有 `style="--option-color: #RRGGBB"` CSS 变量，custom select 选中项用该变量显示彩色高亮。

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
- face manager 通用控件：读取、打开本地、保存到本地、下载、导入。

行为：

- 点击/拖动画板修改 `editFrame`。
- `sendCustomFrame()` 发送 `/api/frame`，reason 默认 `custom_face_send`。
- live send 打开时，编辑后排队发送，受 WebUI M370 队列限速。
- 保存自定义表情时写入 `userFaces`，type=`custom`，随后 `persistFaceDocuments('save_user_face')`。

### 8.8 部件拼脸页

必须包含内联 `EXPRESSION_PARTS` 数据：

- format：`rina_expression_parts_370_runtime_v4`
- version：4
- matrix：cols 22、rows 18、num_leds 370、row_lengths、row_valid_x_ranges、serpentine。
- layout：
  - left eye：x=2,y=1,w=8,h=8
  - right eye：x=12,y=1,w=8,h=8
  - mouth：x=7,y=9,w=8,h=8
  - cheek left：x=2,y=9,w=4,h=4, mirror_x=true
  - cheek right：x=16,y=9,w=4,h=4
- call fields：`leye`、`reye`、`mouth`、`cheek`
- default_face：
  - leye=101
  - reye=201
  - mouth=301
  - cheek=400
- ids：
  - leye：`0,101..127`
  - reye：`0,201..227`
  - mouth：`0,301..332`
  - cheek：`400..405`
- parts：每个 part 至少包含 `name`、`size`、`row_hex` 或 `preview`。

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
- symmetry 打开时，左右眼同步到同编号序列。
- apply 发送 `/api/frame`，reason `parts_face_apply` 或类似 `parts_` 前缀。
- save 写入 type=`parts`，并在 `call` 字段保存 selectedCall。

### 8.9 文本滚动页

控件：

- `#scroll-text`，maxlength=1000。
- `#scroll-speed`，FPS 输入，整数，仅允许 1..120。
- `#scroll-play`
- `#scroll-pause`
- `#scroll-stop`
- `#scroll-step`
- `#scroll-upload-progress`
- `#scroll-upload-bar`
- `#scroll-upload-label`
- `#scroll-state`
- `#scroll-frame-index`
- preview：`#matrix-scroll`

字体：

- UI 字体：CSS 内联 GNU Unifont subset data URI。
- 滚动字体：`/resources/fonts/ark12.woff2` 与 `/resources/fonts/ark12.json`。
- WebUI 必须 lazy-load `ark12.json`。
- 字体模型 `ark_pixel_12px_monospaced_bdf_bitmap_v1`。
- 缺字 fallback codepoint：`0x25A1`。

文本滚动算法：

1. 输入 text 截断到 1000 字符。
2. 对每个 Unicode char：
   - 查 `arkPixelFont.glyphs`。
   - 缺字使用 missing glyph。
   - space 使用 `spaceColumns = 6`。
3. 构建一个 bitmap：
   - leading blank = `COLS + 4`
   - trailing blank = `COLS + 4`
   - charSpacing = 0
4. 对 offset 从 0 到 `source.width - COLS`：
   - 从 bitmap 提取当前 22x18 非矩形窗口。
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

Pause/resume/stop/step 必须通过 `/api/command` 对应命令。stop 时：

- WebUI 本地先恢复 startup default face preview。
- 固件执行 `stop_scroll` 可 clear display 并 deferred restore。
- 如果 GPIO B1/B2/B3 中断滚动，WebUI polling 到 `scrollStopEventSeq` 变化后必须停止滚动控件，并延迟 20 ms 或 140 ms 进行 full status sync。

### 8.10 调试页

必须包含：

- 状态 KV：`#state-kv`
- 功耗警告：`#dps-warning`，估算超过 40W 显示。
- pattern 按钮：
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
- debug preview：`#matrix-debug`
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
| 当前 AP Domain | `state.apDomain` |
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
| 亮度 raw | `state.brightness` |
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
| 电池 ADC raw | `formatMilliVolts(batteryAdcMv)` |
| 上次电池 ADC raw | `formatMilliVolts(batteryPrevAdcMv)` |
| 断电快速压降 | `dropMv / 阈值 thresholdMv` |
| 断电低 ADC 阈值 | `formatMilliVolts(batteryDisconnectLowThresholdMv)` |
| 恢复 ADC 阈值 | `formatMilliVolts(batteryReconnectThresholdMv)` |
| Vcharge | `formatVolts(chargeV) / formatChargingState(charging)` |
| 充电 ADC raw | `formatMilliVolts(chargeAdcMv)` |
| AP SSID | `DEVICE_AP_SSID` |
| AP 密码 | `DEVICE_AP_PASSWORD` |
| AP Domain | `state.apDomain` |

**`#resource-kv`**（16 行）：

| key | 值 |
|---|---|
| JSON format | `EXPRESSION_PARTS.format` |
| version | `EXPRESSION_PARTS.version` |
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

#### Debug Masonry 布局算法

`setupDebugMasonryLayout(force)` 贪心最短列算法：

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

### 8.11 API client

必须实现：

- `apiUrl(path)`：
  - 如果 path 已是 http(s)，直接返回。
  - file/offline mode 时允许本地 fallback，但 API 请求应显示 offline。
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

API JSON parser：

- 空响应 fallback 到 `{ ok:true }` 或调用者传入 fallback。
- 解析失败时记录 path 和错误。
- network/timeout 更新 `firmware.online=false`、`firmware.lastError`。

### 8.12 WebUI 发送队列

M370 frame queue：

- `WEBUI_M370_SEND_INTERVAL_MS = 45`
- `WEBUI_M370_QUEUE_MAX = 3`
- 如果正在发送，新帧进入队列。
- 队列满时保留最新意图，避免拖动画板时堆积过多旧帧。

Button command queue：

- `WEBUI_BUTTON_COMMAND_INTERVAL_MS = 120`
- `WEBUI_BUTTON_COMMAND_QUEUE_MAX = 4`
- API 失败时执行本地 fallback。

### 8.13 Custom Select 下拉系统

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

`positionSelectMenu(shell, options)` — fixed 定位菜单于 toggle 正下方（或上方若空间不足）：
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

**滚动锁定机制**：dropdown 打开时设 `selectScrollLock = true`（仅标志位，不修改 overflow），通过拦截 `touchmove`/`wheel`/键盘箭头键阻止页面滚动，dropdown 内允许滚动（检查 `menu.scrollHeight > menu.clientHeight`）。

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
- 初始 basic preview 必须在 loader 关闭前初始化；完整当前帧可在 post-boot deferred read 中补齐。

常规：

- `startFirmwareStatusPolling()` 每 500 ms tick。
- 如果固件正在 scroll 且当前是 scroll 页面，用较快 summary polling，最小约 550 ms。
- 否则按固件 `next_poll_ms`，最低约 1000 ms。
- full status 使用 `/api/status`。
- runtime summary 使用 `/api/status?runtimeOnly=1&noFrame=1`。
- 支持 `since=<version>`，如果 unchanged 则不刷新 DOM。

电源：

- `startPowerStatusPolling()` 只在 basic/debug 页面有效。
- 每 1000 ms tick。
- 实际刷新间隔 `POWER_STATUS_REFRESH_MS = 900`。
- 请求 `/api/power`。

### 8.16 Face library 前端规则

WebUI 必须支持：

- 从 `/api/saved_faces` 读取。
- 如果 offline/file 模式，从本地 `saved_faces.json` 或 `/resources/saved_faces.json` fallback。
- 使用 File System Access API 打开本地 saved_faces.json。
- 保存到已打开本地文件。
- 下载完整 saved_faces.json。
- 导入 saved_faces.json。
- 拖拽排序 face。
- 重命名 face。
- 应用 face。
- 删除 user face。
- 默认 face 不可删除。

保存 user face：

- id：`${type}_${Date.now()}`
- name：用户输入，最长 64。
- type：`custom` 或 `parts`。
- m370：当前 frame。
- order：现有最大 order + 1。
- editable/deletable true。
- sourceFile：`saved_faces.json`
- savedAt/updatedAt：ISO string。
- parts face 还保存 `call`。
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
4. 如果同步失败且 face library 可用、当前不是 scroll playback：`bootOk` 为真则 `applyKnownFaceIndexLocal('post_load_face_index_fallback')`，否则 `applyStartupDefaultFaceLocal('post_load_default_face_fallback')`。
5. 重新 `renderSavedFaces()`、`renderMatrices()`、`renderState()`，并 `scheduleMatrixFitRender(3)`。
6. 后台调用 `ensureTextScrollBrowserFontReady()` 预热 `ark12.woff2`；不要在此处加载 1.8MB 左右的 `ark12.json`。

#### 8.17.4 Pattern 与 debug 控件

`makePatternFrame(kind)` 必须支持：

- `checker`：有效 LED 上 `(x + y) & 1` 为 0 时点亮。
- `border`：每行有效 x 范围的左右边界，或 y 为首/末行时点亮。
- `all-off` / `all-on` 由调用者直接传 blank/full frame。

Debug 的“辅助命令”文本框 `#serial-input` 接受 JSON；若可解析为对象且含 `cmd`，通过 `sendAuxCommand(cmd, payload || {}, 'serial_input')` 发送。日志下载使用 `downloadJsonFile('rina_webui_log.txt', logs.join('\n'))`，即虽然函数名是 JSON 下载，也可下载纯文本日志。

### 8.18 当前实现同步补充

本小节是对照当前 `data/index.html`、`data/styles.css`、`src/web_api.cpp` 后补齐的重建清单。若前文 WebUI 描述遗漏细节，以此小节为准。

#### 页面、DOM 与初始化顺序

- WebUI 页面数组必须为：
```js
const PAGES = [
  ['basic', '6.1', '基础功能'],
  ['custom', '6.2', '自定义表情'],
  ['parts', '6.3', '表情部件'],
  ['scroll', '6.4', '文字滚动'],
  ['debug', '6.5', '调试']
];
```
- `<html>` 初始必须带 `data-boot-phase="preload"` 与 `data-scroll-lock="boot"`；boot 完成后移除滚动锁，避免 loading 期间页面抖动。
- `bootstrapWebUi()` 的顺序必须是：记录 boot start -> `preloadInitialLoadingImage()` -> `initOverlay()` -> `preloadFirmwareRuntimeState()` -> `ensureWebUiFontReady()` -> `initFirstPageUiBeforeShow()` -> `renderFirstPageUiBeforeShow()` -> 等待 `minDisplayMs=400` -> `showBootUiBehindLoader()` -> `revealFirstPageWaterfall()` -> `loader.requestFinish()` -> `finishBootVisibility()` -> `runPostBootDeferredReads()`。
- 首屏只取 `/api/status?runtimeOnly=1&noFrame=1`，不得阻塞读取 `saved_faces.json` 或完整 `lastM370`。完整 face library 与矩阵预览由 `runPostBootDeferredReads()` 在页面显示后补齐。

#### 必须保留的 JS 功能簇

- API：`apiUrl()`、`apiGet()`、`apiPost()`、`apiPostWithUploadProgress()`，GET 默认 2500 ms，POST 默认 5000 ms，上传默认 15000 ms，所有 API 请求使用 `no-store` 和 JSON Accept。
- 发送队列：`queueFirmwareFrame()`、`scheduleFrameSendPump()`、`pumpFrameSendQueue()`，M370 队列最多 3 个，45 ms 节流，队列满时丢旧保新；按钮/命令队列最多 4 个，120 ms 节流。
- 固件同步：`preloadFirmwareRuntimeState()`、`syncRuntimeStateFromFirmware()`、`syncRuntimeSummaryFromFirmware()`、`startFirmwareStatusPolling()`、`rememberFirmwareStatusPoll()`，需要支持 `since=<version>`、`runtimeOnly=1&noFrame=1` 和固件返回的 `next_poll_ms`。
- 电源同步：`refreshPowerStatusFromFirmware()`、`startPowerStatusPolling()`、`applyPowerData()`，basic/debug 页进入时强制刷新；顶部 badge 与 debug KV 共用同一份 power state。
- 导航：`initNav()`、`switchPage()`、`setNavMenuOpen()`、`updateCurrentPageLabel()`；切换到 `scroll` 时懒加载 Ark JSON/生成滚动预览，切换到 `debug` 时强制重排 masonry 并刷新电源。
- 字体：`ensureWebUiFontReady()` 等待 GNU Unifont；`applyWebUiFont()` 对新增 DOM 继续写入 UI font 但跳过 `#scroll-text`；`ensureTextScrollBrowserFontReady()` 只预热 `ark12.woff2`；`ensureArkPixelFontReady()` 只在滚动功能需要 rasterize 时加载 `ark12.json`。
- 矩阵：`initMatrix()`、`attachDrawing()`、`fitMatrix()`、`observeMatrixWraps()`、`renderMatrices()`；矩阵可编辑页只允许 valid cell 响应 click，invalid cell 需要保持不可点且视觉为熄灭/弱化。
- 表情库：`loadFaceLibrary()`、`normalizeFaceDocument()`、`buildUnifiedFaceDocument()`、`persistFaceDocuments()`、`renderSavedFaces()`、`attachFaceReorderHandle()`、`saveFace()`；默认 face 不可删除，custom/parts 可删除，排序、重命名、拖拽都必须写回统一 `/api/saved_faces`。
- 部件拼脸：`composePartsFrame()`、`selectPart()`、`syncSymmetricEyesFrom()`、`randomParts()`、`renderPartButtons()`；左右眼 symmetry 打开时按显示序号同步，而不是按原始 ID 字符串硬套。
- 文字滚动：`prepareTextScrollTimelineAsync()`、`buildTextScrollBitmap()`、`buildTextGlyph()`、`extractFrameFromTextImage()`、`uploadFirmwareScrollTimeline()`、`startScroll()`、`pauseScroll()`、`resumeScroll()`、`stopScroll()`、`advanceScroll()`；滚动帧只写 RAM，24 帧一包，全部包上传完成后再发送 `start_scroll` 指令设置最终 fps/interval。
- Debug：`initializeDebugControls()`、`makePatternFrame()`、`setupDebugMasonryLayout()`、`scheduleDebugMasonryLayout()`；pattern 必须支持 `all-off`、`all-on`、`checker`、`border`。

#### 事件与交互细节

- 所有 `<button>` 和 `.part-card` 必须接入按压动画：pointerdown/keyboard Space/Enter 进入 `.is-pressing`，至少保持 90 ms；释放后进入 `.is-releasing` 150 ms；disabled 或 `aria-disabled="true"` 不参与。
- Custom select 必须保留原生 `<select>` 作为 value/change 源，同时创建 `.select-toggle` 和 append 到 `body` 的 fixed `.select-menu`。打开时只用 `selectScrollLock` 标志和事件拦截阻止页面滚动，不直接改页面 overflow；菜单内部可滚动。
- `positionSelectMenu()` 必须考虑 `visualViewport.offsetLeft/offsetTop`、上下可用空间、`verticalOnly` 重定位和滚动条宽度；`window.scroll` 时只做 vertical reposition，`visualViewport.resize/scroll` 时做完整 reposition。
- GPIO B1/B2/B3 中断文字滚动时，WebUI 通过 `scrollStopEvent.seq` 变化识别，只接受 `source === 'gpio'` 且 button 为 B1/B2/B3 的事件；如果固件处于 deferred restore，延迟 140 ms 做 full status sync，否则延迟 20 ms。
- `terminateOtherActivities(targetMode, reason)` 在切换到会输出 LED 的页面/操作前发送 `terminate_other_activities`，`targetMode='scroll'` 时若原模式是 auto，固件要记录 `restoreAutoAfterScroll`。

#### API 合约补齐

- `/api/scroll` 只接受 POST，body 必须含 `frames` 数组，元素是 M370 字符串；支持 `append`、`start`、`chunkIndex`、`totalFrames`、`fps` 或 `intervalMs`。`persist`、`saveToFlash` 或非 `storage:'ram'` 必须返回 400。
- `/api/command` 当前命令集合必须包括：`set_color`、`set_brightness`、`set_mode`、`set_auto_interval`、`set_scroll_interval`、`start_scroll`、`scroll_step`、`pause_scroll`、`resume_scroll`、`stop_scroll`、`pause`、`resume`、`button`、`terminate_other_activities`、`reset_battery_min`、`reset_battery_max`。
- `/api/status` 在 scrolling 或 summary-only 时必须避免返回完整 frame，仍要返回 renderer scroll 状态、scroll stop event、memory scroll buffer 信息与 `next_poll_ms`。完整非滚动状态才返回 `lastM370`/frame 相关预览数据和 LittleFS 容量。
- `/api/saved_faces` GET/POST 操作唯一文件 `/resources/saved_faces.json`；POST 需要校验 unified document，且必须保留至少一个 `type:"default"` face。

#### CSS 与动画补齐

- `styles.css` 的 root 变量必须包含 `--led-preview-edge-ratio:.1000`；matrix 留白通过 `fitMatrix()` 写 `--matrix-edge-gap = cell * edgeRatio`，不是固定 12 px。
- Loading overlay 必须包含 `.blur-screen`、`.loading-box`、`.loader-stage`、`.flash-halo`、`.avatar-circle`、`.avatar-before`、`.avatar-after`、`.loading-text`；状态类必须支持 `is-assets-pending`、`is-animating`、`is-image-pop`、`is-final-release`、`is-ring-contracting`、`is-halo-hidden`、`is-hidden`、`is-scroll-passthrough`。
- Loading keyframes 必须保留：`rinaBoot-pulseRingBreath`、`rinaBoot-haloContractOut`、`rinaBoot-avatarShrinkThenRelease`。reduced motion 下 halo 动画放慢到约 2.6s，瀑布揭示 transition 约 1ms。
- 首屏瀑布揭示使用 `.boot-reveal-item` 与 `.is-revealed`，初始 `visibility:hidden; opacity:0; transform:translateY(10px)`，显示时恢复 visible/opacity/transform。
- 导航 overlay 的 z-index 需要高于 sidebar 但低于 loading overlay：`.top-page-nav` 约 `2147483000`，`.select-menu` 约 `2147482501`，`.sidebar` 约 `2147482999`，loading overlay 约 `2147483000` 且在 DOM 上覆盖。
- `@media (hover:none), (pointer:coarse)` 必须取消 hover 抬升/阴影，仅保留按压状态；`@media (max-width:980px)` 单列布局，`@media (min-width:1471px)` parts/debug 宽布局，`@media (max-width:640px/520px/400px)` 缩小控制高度、字体、padding 和 LED 默认 cell。


### 8.19 WebUI 源码级硬性补遗：DOM、动画、队列、布局锁定（2026-05-23 追加）

本小节用于把第 8 节和第 15 节中的源码片段收束成可直接重建的强制规则。若本小节与更早的概略描述冲突，以本小节为准；但不得据此重构 implementation，只能按当前实现复现。

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

- `safeJsonParse` 的职责是非 API JSON 容错，解析失败直接返回 fallback。
- `parseApiJson` 的职责是 API 响应校验：空响应返回 fallback，非法 JSON 抛出 `invalid JSON from ${path}: ...`，由调用处统一进入错误路径；不要把它改成静默 fallback，否则会掩盖固件返回异常。
- `bindControls` 的 token 必须是 ``${selector}:${eventName}``，并以 `WeakMap` 存每个 DOM 元素已绑定事件集合，防止 `initFirstPageUiBeforeShow`、face library 初始化、debug 初始化重复执行时多次触发。
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

强制约束：进入 custom/parts/debug/scroll 页时必须使用 `requestAnimationFrame` 触发 textarea 高度重算或滚动 UI 重算，原因是隐藏页 `display:none` 下直接测量高度会失真。进入任何页面前必须先调用 `terminateOtherActivities(modeForPage(id), ...)`，避免 text-scroll playback、custom live-send、parts live-send 互相覆盖。

#### 8.19.4 Loading overlay 径向揭示动画

`animateReveal()` 使用 loader 中心点作为 reveal origin，半径和羽化必须按当前公式计算：

```js
function eic(t) {
  return t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}
function getMaxR() {
  syncLoaderHorizontalCenter();
  const o = loaderSurfaceRect();
  const cx = lockedCenterX - o.left, cy = lockedCenterY - o.top;
  return Math.ceil(Math.max(
    Math.hypot(cx, cy),
    Math.hypot(o.width - cx, cy),
    Math.hypot(cx, o.height - cy),
    Math.hypot(o.width - cx, o.height - cy)
  ) + 90);
}
// animateReveal 内部：
const maxR = getMaxR();
const f = Math.max(96, Math.min(180, Math.round(maxR * .12)));
const r = maxR * eic(t);
```

每帧必须写入 `--rina-reveal-solid/a/b/c/d/e/outer`，且数值保留两位小数并带 `px`。`is-revealing` 添加在 `.blur-screen` 上；`is-scroll-passthrough` 添加在 overlay 上并调用 `unlockBootPageScroll()`，保证首屏揭示时页面滚动恢复。

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

这样才能保证文字完整滑入、完整滑出，并且在 10 行 LED 画布中相对当前 Ark Pixel lineHeight 向下偏移 2 行。

#### 8.19.7 按钮按压动画状态机

所有 `button` 必须走全局按压动画系统，不允许各按钮单独实现不同的 pressed 样式。实现要求：

- 常量：`BUTTON_PRESS_DOWN_MS = WEBUI_CONFIG.interaction.buttonPressDownMs`，当前值 90；`BUTTON_PRESS_UP_MS` 当前值 150。
- 状态容器：`buttonPressStates = new WeakMap()`；pointer 捕获表：`activeButtonPointers = new Map()`。
- `pointerdown`：只接受主键；找到最近 `button`；写入 `activeButtonPointers`；调用 `startButtonPressAnimation(button)`；尝试 `button.setPointerCapture(ev.pointerId)`。
- `pointerup` / `pointercancel`：从 `activeButtonPointers` 取回原按钮并释放动画。
- 键盘：`Space` / `Enter` 也必须触发相同动画，不得只依赖 CSS `:active`。
- 快速点击时必须计算 `delay = max(0, BUTTON_PRESS_DOWN_MS - elapsed)`，保证 `.is-pressing` 至少存在 90ms，再进入 `.is-releasing` 150ms。

#### 8.19.8 API client、离线模式和 M370 发送队列

- `isOfflineHtmlMode()` 判断 `location.protocol === 'file:'` 时，API 请求必须短路到模拟结果或 fallback，不向网络发起请求。
- 离线发送状态文本必须包括 `queued offline` / `offline html mode`，并避免把离线模式当作错误刷屏。
- `/api/frame` 不允许并发高频 POST，必须统一通过 `enqueueFrameSend(packet, source)` → `pumpFrameSendQueue()`。
- M370 队列最大长度为 3；超出时丢弃队首最老帧，保留最新用户意图。
- `pumpFrameSendQueue()` 每次发送前必须检查：

```js
const waitMs = Math.max(0, WEBUI_M370_SEND_INTERVAL_MS - (performance.now() - lastFrameSendAt));
if (waitMs > 0) { scheduleFrameSendPump(waitMs); return; }
```

当前 `WEBUI_M370_SEND_INTERVAL_MS = 45`，必须由 `WEBUI_CONFIG.firmwareQueues.m370SendIntervalMs` 派生。

#### 8.19.9 Debug 页电源模拟与 Masonry 布局

Debug 页 `update-adc` 按钮必须手动推导 runtime 电池状态，核心逻辑：

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

Debug masonry 必须读取每张卡片的 `getBoundingClientRect().height`，使用 `columnHeights.indexOf(Math.min(...columnHeights))` 贪心放入当前最短列。无高度时回退到 `index % count`，并且重排前后保持滚动位置。


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
- `@font-face` Ark Pixel 12px Monospaced：`/resources/fonts/ark12.woff2?v=20260511-ark12-merged-trad1`。
- 全局强制 pixel font：body、button、input、select、textarea 等。
- `#scroll-text` 强制 Ark Pixel。
- dark scrollbar。
- loading overlay 动画 class：
  - `is-assets-pending`
  - `is-animating`
  - `is-image-pop`
  - `is-final-release`
  - `is-ring-contracting`
  - `is-halo-hidden`
  - `is-hidden`
  - `is-scroll-passthrough`
- button press animation：
  - `is-pressing`
  - `is-releasing`
  - CSS variables `--button-hover-y`、`--button-press-y`、`--button-press-scale`
- 响应式：
  - <= 980 px 单列布局。
  - >= 1471 px parts/debug 更宽布局。
  - <= 640/520/400 px 调整按钮、矩阵、间距。
- `.matrix-wrap` 使用 CSS variables 控制 cell size、min/max、edge gap。
- `.matrix` 使用 grid，cell 稳定尺寸，不因 hover 或文本改变布局。
- `.face-library-list` 可滚动，face row 有 drag handle、body、actions。
- `.scroll-upload-progress` 支持 progress bar。

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

### 9.3 Custom Select CSS

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
- face library 列表中的 `.saved-face-card` 使用 grid：drag handle、body、action bar 三块；action button 在桌面宽度有固定 `--face-control-size`，移动端可换行。

### 9.5 Loading Overlay CSS 精确要求

Loading 相关 CSS 变量必须包含：

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
--rina-halo-contract-duration: 300ms;
--rina-image-pop-duration: 420ms;
--rina-image-release-duration: 1300ms;
--rina-blur-size: 14px;
--rina-loader-x: 50vw;
--rina-loader-y: 50vh;
--rina-reveal-solid: 0px;
--rina-reveal-a: 0px;
--rina-reveal-b: 0px;
--rina-reveal-c: 0px;
--rina-reveal-d: 0px;
--rina-reveal-e: 0px;
--rina-reveal-outer: 0px;
--rina-reveal-x: 50%;
--rina-reveal-y: 50%;
```

Loading 元素样式：

- `.loading-overlay`：`position:fixed; inset:0; z-index:2147483000; overflow:hidden; pointer-events:auto; background:transparent`。
- `.blur-screen`：铺满 overlay，`backdrop-filter: blur(var(--rina-blur-size))`，通过 `.is-revealing` 的 `mask-image` / `-webkit-mask-image` 多段 radial-gradient 从中心向外揭示。
- `.loading-box`：`position:fixed; left:var(--rina-loader-x); top:var(--rina-loader-y); transform:translate(-50%,-50%)`。
- `.avatar-circle`：白底圆形，尺寸 `var(--rina-avatar-size)`，overflow hidden；`.avatar-before` 默认 opacity 1，`.avatar-after` 默认 opacity 0。
- `.flash-halo`：圆形径向渐变光环，默认执行 `rinaBoot-pulseRingBreath 1.62s cubic-bezier(.42,0,.58,1) infinite both`。
- `.is-assets-pending .loading-box` opacity 为 0；`.is-hidden` opacity 0 且不可点击；`.is-scroll-passthrough` pointer-events none。

必须实现 3 个 keyframes：

- `rinaBoot-pulseRingBreath`：0/100% opacity `.28` scale `.965`，50% opacity `1` scale `1.075`。
- `rinaBoot-haloContractOut`：从 scale `1.075` opacity `1` 到 scale `.65` opacity `0`。
- `rinaBoot-avatarShrinkThenRelease`：0% scale `1.22`，18% scale `1.12`，100% scale `2.35` opacity `0`。

首屏 progressive reveal：

- `.boot-reveal-item` 默认 `visibility:hidden; opacity:0; transform:translateY(10px)`，transition 为 opacity 320ms + transform 360ms。
- `html[data-first-page-reveal="preparing"] .boot-reveal-item` 禁用 transition。
- `.boot-reveal-item.is-revealed` 设 visible、opacity 1、transform 0。
- `@media(prefers-reduced-motion:reduce)` 中 halo 周期放慢到 2.6s，reveal transition duration 1ms。

### 9.6 响应式断点

必须至少保留这些断点行为：

- `@media (min-width:1471px)`：debug/parts 使用更宽内容区，debug masonry 可变 3 列。
- `@media (max-width:980px)`：主要 layout 降为单列，导航 overlay 宽度仍为左右 page gap 内的全宽。
- `@media (min-width:981px)`：矩阵和 saved face row 使用桌面尺寸。
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

`@font-face` 必须保留 GNU Unifont 内联 woff2 data URI 和 Ark Pixel `/resources/fonts/ark12.woff2?v=20260511-ark12-merged-trad1`。`body, button, input, select, textarea` 强制使用 `var(--ui-font)`；`#scroll-text` 强制使用 Ark Pixel。

#### 9.7.2 页面切换动画

必须使用当前 keyframes，不得改成 opacity-only 或 display:none 后无动画：

```css
.page { display: none; animation: fade .16s ease-out; }
.page.active { display: block; }
@keyframes fade {
  from { opacity: .4; transform: translateY(4px); }
  to { opacity: 1; transform: none; }
}
```

#### 9.7.3 导航数字霓虹发光

`.nav .num` 默认无光晕，但必须带当前 easing 过渡：

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

#### 9.7.4 Button、Custom Select 与 `color-mix` 发光

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

Custom select 激活项必须由 JS 注入的 `--option-color` 控制：

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

- `.matrix-wrap` 通过 CSS variables 管理 `--matrix-default-cell`、`--matrix-min-cell`、`--matrix-max-cell`、`--matrix-max-height`、`--matrix-edge-gap`。
- `.matrix` 必须使用 `display:grid` 与 `gap:var(--gap)`；每个 `.led` 必须使用 `width:var(--cell); height:var(--cell)`，不能用百分比反推。
- `.led.invalid` 表示非物理 LED 空洞；`.led.on` 表示点亮；`.editable-matrix .led.editable` 才允许绘制交互。
- hover、`.on`、`.invalid` 状态不得改写 `--cell` 或 grid template，避免实时预览时整块矩阵抖动。

#### 9.7.7 Loading Overlay CSS 与 reduced motion

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

Loading overlay 状态类必须与 JS 一致：`is-assets-pending`、`is-animating`、`is-image-pop`、`is-final-release`、`is-ring-contracting`、`is-halo-hidden`、`is-hidden`、`is-scroll-passthrough`、`is-revealing`。


## 10. 工具函数

`utils.h/.cpp` 必须提供：

- `hexNibble(char)`：返回 0..15 或 -1。
- `parseColorHex(input, r, g, b)`：接受 `#RRGGBB` 或 `RRGGBB`。
- `formatColorHex(r,g,b)`：输出 lowercase 或统一格式 `#rrggbb`。

`psram_json.h` 必须提供一个 PSRAM 优先 JSON document 封装。当前实现使用 ArduinoJson `BasicJsonDocument` 的自定义 allocator，而不是普通 `DynamicJsonDocument` fallback：

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

### 11.1 Loading PNG

必须提供两个 96x96 左右的 loading 图：

- `/resources/loading/rina_icon1_default.png`
- `/resources/loading/rina_icon2_hover.png`

HTML 需要 preload default 图，并把 default 图设为 favicon/shortcut icon。

### 11.2 字体资源

必须提供：

- `/resources/fonts/ark12.woff2`
- `/resources/fonts/ark12.json`
- 可选 `/resources/fonts/ark12.json.gz`
- `/resources/fonts/README.md`

`ark12.json` 必须是 WebUI 可读取的 bitmap glyph table。每个 glyph 至少有：

- codepoint
- width
- height 或 rows length
- rows
- xOffset/yOffset/dstY 可选

### 11.3 gzip

构建后 data 中可出现 `.gz` sibling，例如：

- `index.html.gz`
- `styles.css.gz`
- `resources/fonts/ark12.json.gz`

固件必须自动选择 gzip sibling，不需要 HTML 引用 `.gz`。

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
- `/api/scroll` 分 chunk 上传后 `start_scroll` 可在固件 RAM 中滚动。
- B1/B2/B3/B4/B5 按钮动作正常。
- LittleFS 缺失时显示前 12 颗红色错误 pattern，并返回错误页面。

### 13.2 WebUI

- 首屏 loading 动画结束后显示 basic 页面。
- 颜色、亮度、模式、auto interval 与固件同步。
- 保存表情列表能读取 `/api/saved_faces`。
- 自定义画板能画、导入、复制、发送、保存。
- 部件拼脸能组合眼睛/嘴/脸颊，能发送和保存。
- 文本滚动能生成 <=3072 帧，24 帧一包上传 RAM，完成后固件滚动。
- GPIO B1/B2/B3 中断滚动后，scroll 页面能自动停止并同步当前 face。
- Debug 页能显示状态、电源、日志、pattern、M370 手动应用。

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
2. 再实现 `led_renderer`，用串口测试 M370 parse 和 physical map。
3. 加入 `storage` 和最小 `saved_faces.json`，启动后渲染 startup face。
4. 加入 `scroll` render task，验证主任务帧优先于 scroll 帧。
5. 加入 `power_monitor`，先串口输出 ADC/电压/百分比，再接 API。
6. 加入 `buttons` 和 `faces` 模式逻辑。
7. 加入 `web_api`，先 status/frame/command，再 scroll/saved_faces/static gzip。
8. 最后生成 WebUI：先 basic + matrix preview，再 custom/parts/scroll/debug。

重建时以本文件的常量、路径、API 字段名、JSON schema、M370 编码、锁顺序、启动顺序为准。

## 15. Implementation 对齐补遗：Single Source of Truth 锁定版（2026-05-23）

> 本章节由当前 implementation 逆向抽取生成，用于修正 `plan.md` 与实际代码之间的剩余偏差。后续开发以本章节和前文规格共同作为重建依据；如二者冲突，以本章节中“当前 implementation 锁定值”为准。严禁因为本章节暴露了源代码而重构现有程序：本次任务只允许修改 `plan.md`。

### 15.1 对齐结论与重建口径

- 当前项目是 **ESP32-S3 + Arduino + PlatformIO + LittleFS + AP-only WebUI** 固件。
- WebUI 当前实现是 `data/index.html` 单文件 DOM + 内联 JavaScript，配合 `data/styles.css` 单文件 CSS。没有外置 JS bundle。
- `data/index.html.gz`、`data/styles.css.gz`、`data/resources/fonts/ark12.json.gz` 是构建脚本生成物，不能人工维护。
- `saved_faces.json` 是默认表情和用户表情的唯一统一存储源；默认表情使用 `type: "default"`，可重命名/排序/应用，但前端不得删除。
- Text scroll 使用 `/resources/fonts/ark12.json` 字形表；WebUI 通用字体使用内嵌 GNU Unifont 子集。字体二进制载荷必须由工具链生成并写入 CSS/资源文件，本文档不展开二进制字体字节。
- 如果一个开发者或代码生成 Agent 需要从零重建，必须按以下顺序执行：
  1. 创建本文档列出的目录和文件。
  2. 按第 15.13 的规范源文件片段写入 `platformio.ini`、`src/*`、`scripts/*`、`tools/*`、`data/index.html`、`data/styles.css`、JSON 资源。
  3. 运行字体资源构建链，生成/注入 GNU Unifont 子集和 Ark Pixel 字体资源。
  4. 运行 `scripts/gzip_webui_assets.py` 生成 gzip 静态资源。
  5. 用 PlatformIO `esp32s3` 环境构建并上传 firmware/LittleFS。

### 15.2 当前文件清单、大小与 SHA256

这些哈希用于确认 implementation 没被误改。`.pio/`、`.vscode/`、`.font_cache/` 属于本地/缓存目录，不作为重建源。

| 文件 | bytes | SHA256 |
|---|---:|---|
| `.gitignore` | 238 | `79131ee54ff4c23b707d675c354c4d1a8d4470759dcf367d283373b206c050b1` |
| `README.md` | 22100 | `87e846b727eff53a0391fc4fada8e0fc044920ddbb20ad23b2c6ff72d8e360fa` |
| `data/index.html` | 276737 | `30824961212cad3dd8e7afe66fe4483cbf7f60e8d4ae5254fc850ef783992395` |
| `data/index.html.gz` | 63073 | `64c1481a3b286ce51b3e2d6c068264534c85c04ccd73642ef51c4798bd2a1e8a` |
| `data/resources/battery_calib.json` | 142 | `d273a07a04f8fcf2f5fa0cf640f1224bbce20974befc2264fd05cb9e07b5fb7c` |
| `data/resources/fonts/README.md` | 552 | `accf99968d8e93aeccbf401a2ba38d7cd5c5b2bd56aeaff391b7e09110a43f26` |
| `data/resources/fonts/ark12.json` | 1818009 | `c50be491270e4d7ae6939461c86fa72d0fda6252d88f7dd67bdcbd113bab1917` |
| `data/resources/fonts/ark12.json.gz` | 381310 | `e83ba0b400266382927d6b547665dcabf14225afa3039547f78a6c47e979ad6b` |
| `data/resources/fonts/ark12.woff2` | 593276 | `97ebb9ae2d1d721eb048e025dd885621d566bd6fa9d38c4a3cf4bd56cc2fb175` |
| `data/resources/loading/rina_icon1_default.png` | 41172 | `1bcf186c58b362247cbe9790a168a22f5d7676c20ec3f9fafda0c8df0be44a8d` |
| `data/resources/loading/rina_icon2_hover.png` | 40837 | `f00634186be168a0f0239f1681f99ede614c87882365bccd2084e10011a1b327` |
| `data/resources/runtime_settings.json` | 125 | `b6cc81e8c6229f963a45763299b1a5359f5b201a77810fbc1d45c8215e4e4228` |
| `data/resources/saved_faces.json` | 5716 | `cc4e61fa63cc6de8e746a558319977dfd4cdc935346a57b456f49f18b37a1305` |
| `data/styles.css` | 126721 | `610a32f74672c546de5f8491af5a1632572e57e26488f7cdf931bdf694533376` |
| `data/styles.css.gz` | 61928 | `7c5c58c08756eb396a572bc8a43aba77eab2174ab315a7194fc1a875a6781c43` |
| `licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt` | 561 | `820d5f2a94466306ffe9f9568bc2bbda2b073e5a18f22330a9fb49c6afd48687` |
| `partitions.csv` | 384 | `09e47281e04f4a35c3a30831624384f0d5ecbf430e40cd39aa5d0a09a8da92e3` |
| `pio` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `plan.md` | 109577 | `24f262046e2db93b55d539382d4e693c50c876a840781c1ce54efe49eafb01e9` |
| `platformio.ini` | 1026 | `67f61d746c681b1ee93f82a5ec9dce9ede61741023aab512646cd993948dc749` |
| `run_rinachan_unifont.ps1` | 18616 | `acbb5d665c8d38a9f8c1e401a19494a188ea0be068d33a637a0fc211f9ed9d14` |
| `scripts/gzip_webui_assets.py` | 3033 | `13e0420abfd1d64869d472d1866ef6ef1411eea581f2b8c9bdb8d1043b57e30e` |
| `scripts/patch_webserver_timeout.py` | 2417 | `e4e4ba092769d46c25dce33494354da0316a8991ed73d14a6ae58113c36bac73` |
| `src/buttons.cpp` | 8575 | `fb5c7b4e34594a8e30a9c8bb3471ba7dd32acc599d61fd8506c48e189a0c3d32` |
| `src/buttons.h` | 1176 | `a796efe5fb21f176b799eddf66fa496bd98efbcf874da879c2cd151df2e531c0` |
| `src/config.cpp` | 166 | `108650a5600b0cca3dbcf58d38f60f9e6d6f401bcbf9255a69d6e8888dd72e10` |
| `src/config.h` | 10164 | `562ee4985950fe444913a2cc941502755813dde8f1249108b8c611f44d0a3ece` |
| `src/faces.cpp` | 14564 | `1926683e942d3784211f0bca7e8d9b01bab0cd1f7773b89b0d5306dbe17be201` |
| `src/faces.h` | 3104 | `7a92c914b560184a1c71ca032c084431775691e133fe3d321cc544fc83bf781a` |
| `src/led_renderer.cpp` | 15051 | `56f1c65b2120a270cf93fd9a37a68003bf723fb74d63dc778b82850fee472199` |
| `src/led_renderer.h` | 3814 | `8999399cc233f78d878bc4104f79b12fc10b7717fe265c4a37804b82d347383d` |
| `src/main.cpp` | 2638 | `3e0a49a30b286df4017542d2ff459c75087310b2141fe89522a8f384be46d8ac` |
| `src/power_monitor.cpp` | 19609 | `90779133a88dfbf8e20ecb4f982639eb47bde57ace78640a62f60b78693e167c` |
| `src/power_monitor.h` | 1672 | `86e94b9ba436a373dfa2772323dbdde4168c98d18377f6976961dce25489fce6` |
| `src/psram_json.h` | 716 | `5842b38f230c682b78c8f1abab93513253857134f5c60d45d18693ba4dbf608a` |
| `src/scroll.cpp` | 5190 | `49a68e29c4e9588168454b1bf9e23abda3431a65d19ecdbef7ea75e6ceb8a264` |
| `src/scroll.h` | 471 | `bac3e9ad773b4f1daf367e6406791a32b369b3294db3f156045d8e0671b9c05a` |
| `src/state.cpp` | 3510 | `8070c8c0fac9c3608ffc634b7f8dd91bd180de68db2ee426d73467e0f83c0bf5` |
| `src/state.h` | 5437 | `4724ac885927bf907e4ddc5e64a59b7257e20a966870c6f622f0deb323c951ce` |
| `src/storage.cpp` | 12586 | `cf88e0d2af6ee1bbf02918bc273d6efc1d2707ce2857cf2f5851d7978c918451` |
| `src/storage.h` | 1584 | `0f418b93e1235739a3b6e0e3fd0051aa9db8239263a69f9f4912ea3c1cf33a40` |
| `src/sync.cpp` | 1076 | `bfd7ddee3df792af2e52557433dee083af1f1db4e59c2f32b7a140c7b7dad70a` |
| `src/sync.h` | 989 | `cc532f113d5533dfd8ec28afaea80107f541bc6b113f6f668bb6571663219b2f` |
| `src/utils.cpp` | 1138 | `4c2a7cce6ffce613cf5e63f42977efada7c39e12319bde7bd7748c69ab45ebeb` |
| `src/utils.h` | 582 | `9d2e749fe2b204ec52b2369b86ebf80661eb12bc3502c92d8478c26d29dc6271` |
| `src/web_api.cpp` | 49575 | `0a4b1df12c1c551e46f4744b9f8bd1c5f89c625acf5e5be13f60a8931e800847` |
| `src/web_api.h` | 583 | `647cfdb3230b4b18d9f104b3c32543a0686cd97738ee401ec3aeb37bb4ea56c1` |
| `src/web_json.cpp` | 3877 | `400ad3ec3cbc53816ff350807fa77608009949c90b85eaeaacdfd44573fa7d69` |
| `src/web_json.h` | 484 | `6b204ccf5c6ff9add5cba450b76939645caa1b3dc7fc209188e34525b20a58a9` |
| `tools/build_ark12_merged.py` | 11637 | `c88676e65c762eb74c3e2a3504112b34bcda531bdbd9d92d2de7e644f4aac6ed` |
| `tools/build_unifont_webui_subset_from_png.py` | 15459 | `8003d8da08eb02f38fafdff658880d4b9e9c88f92e9047876a04ef0d9eba4bcb` |
| `tools/compile_ark_bdf.py` | 5005 | `4d5de1156ecc34a681a8fff83acfd25e0340421a9f8775c57468fc284aa7d3b6` |

### 15.3 WebUI DOM、挂载点与页面结构锁定

#### DOM `id` 清单

`loadingOverlay`, `blurScreen`, `avatarBefore`, `avatarAfter`, `badge-battery`, `badge-battery-dot`, `badge-battery-label`, `badge-charging`, `badge-charging-dot`, `badge-charging-label`, `brand-nav-toggle`, `top-page-nav`, `nav-shell`, `nav`, `page-basic`, `color-swatch`, `color-input`, `parent-color-select`, `child-color-select`, `brightness-reset-default`, `brightness-minus`, `brightness-plus`, `brightness-range`, `brightness-input`, `brightness-presets`, `face-prev`, `face-next`, `mode-toggle`, `interval-down`, `interval-up`, `auto-interval-range`, `auto-interval`, `auto-interval-presets`, `matrix-basic`, `page-custom`, `custom-send`, `custom-live-toggle`, `custom-clear`, `custom-fill`, `custom-invert`, `matrix-custom-edit`, `custom-m370`, `custom-copy`, `custom-import`, `custom-save`, `custom-name`, `page-parts`, `parts-apply`, `parts-live-toggle`, `parts-random`, `parts-reset`, `parts-symmetry-toggle`, `parts-preview-card`, `matrix-parts`, `part-groups`, `parts-m370-text`, `parts-copy-m370`, `parts-import-m370`, `parts-save-bottom`, `parts-name`, `page-scroll`, `matrix-scroll`, `scroll-text`, `scroll-speed`, `scroll-play`, `scroll-pause`, `scroll-stop`, `scroll-step`, `scroll-upload-progress`, `scroll-upload-bar`, `scroll-upload-label`, `scroll-state`, `scroll-frame-index`, `page-debug`, `state-kv`, `dps-warning`, `debug-all-off`, `debug-all-on`, `debug-checker`, `debug-border`, `debug-current-face`, `debug-m370`, `debug-apply-m370`, `debug-copy-status`, `debug-reset-storage`, `debug-kv`, `debug-refresh-power`, `debug-reset-battery-min`, `debug-reset-battery-max`, `battery-v`, `charge-v`, `update-adc`, `matrix-debug`, `serial-input`, `serial-send`, `log-clear`, `log-download`, `log`, `firmware-kv`, `firmware-ping`, `firmware-pause`, `resource-kv`, `parts-list-${key}`

#### 静态 class 清单

`loading-overlay`, `is-assets-pending`, `blur-screen`, `loading-box`, `loader-stage`, `flash-halo`, `avatar-circle`, `avatar-before`, `avatar-after`, `loading-text`, `sidebar`, `brand`, `brand-copy`, `row`, `badge`, `mono`, `status-dot`, `dim`, `brand-nav-toggle`, `menu-icon`, `top-page-nav`, `nav-shell`, `nav`, `app`, `content`, `page`, `active`, `hero`, `basic-layout`, `control-panel`, `card`, `control-section`, `flush`, `color-control-row`, `color-swatch`, `field`, `color-dropdown-grid`, `select-shell`, `select-caret`, `slider-step-row`, `compact-btn`, `push-right`, `brightness-row`, `slider-number`, `button-row`, `mode-button-row`, `toggle-button`, `basic-preview-card`, `led-preview-card`, `matrix-wrap`, `fill-column`, `led-preview-wrap`, `matrix`, `primary`, `grid`, `cols-2`, `stack`, `face-manager-panel`, `ok`, `faces-json-load`, `faces-json-open-local`, `faces-json-save-local`, `faces-json-download-all`, `faces-json-import-btn`, `faces-json-import-file`, `list`, `face-library-list`, `parts-outer-layout`, `parts-left-col`, `parts-manager-col`, `scroll-upload-progress`, `scroll-upload-label`, `kv`, `k`, `debug-layout`, `status-merged`, `warning`, `hint`, `danger`, `debug-measure-card`, `debug-measure-grid`, `debug-measure-controls`, `debug-log-card`, `log`, `num`, `select-label`, `face-source-badge`, `part-list`, `part-meta`, `part-display-id`, `part-mini`, `&&`, `rows[y][x]==='#'?'`

#### HTML 结构要求

- `<html>` 初始属性必须为 `data-boot-phase="preload" data-scroll-lock="boot" lang="zh-CN"`。
- `<head>` 必须 preload `/resources/loading/rina_icon1_default.png`，并将 favicon/shortcut icon 指向同一文件。
- `loadingOverlay` 必须位于 `body` 最前，内部包含 `blurScreen`、双层头像 `avatarBefore/avatarAfter`、loader ring、loading text。
- Sidebar/brand 区必须包含电池 badge 和充电 badge，并在首屏揭示前已可根据 boot status 渲染。
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
    fpsMax: 120,
    firmwareMaxFramesDefault: 3072,
    uploadChunkFrames: 24,
    maxTextChars: 1000
  },
  textScroll: {
    fontModel: 'ark_pixel_12px_monospaced_bdf_bitmap_v1',
    fontResource: '/resources/fonts/ark12.json',
    fontFamily: 'Ark Pixel 12px Monospaced',
    browserFontSample: 'RinaChanBoard 370 LED \u7ee7\u7eed \u6682\u505c \u3053\u3093\u306b\u3061\u306f \u7483\u5948\u3061\u3083\u3093\u30dc\u30fc\u30c9',
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
    holdMs: 150,
    haloBreathMs: 1620,
    haloPeakRatio: 0.5,
    haloToleranceMs: 24,
    haloContractMs: 300,
    imageReleaseMs: 1300,
    blurDurationMs: 500,
    extraMs: 120,
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
  const rawChars = Array.from(text || ' ');
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

~~~~text
L2328: el.addEventListener(eventName, handler);
L2401: document.addEventListener('pointerdown', ev => {
L2413: document.addEventListener('pointerup', ev => {
L2421: document.addEventListener('pointercancel', ev => {
L2429: document.addEventListener('keydown', ev => {
L2434: document.addEventListener('keyup', ev => {
L3753: img.addEventListener('load', onLoad, {
L3756: img.addEventListener('error', onError, {
L3902: window.addEventListener('resize', scheduleLoaderHorizontalCenterSync, {
L3905: window.visualViewport?.addEventListener('resize', scheduleLoaderHorizontalCenterSync, {
L4115: window.addEventListener('pagehide', stopPollingTimers);
L4286: document.addEventListener('click', (ev) => {
L4289: document.addEventListener('keydown', (ev) => {
L4539: sel.addEventListener('change', () => requestAnimationFrame(refreshAllCustomSelects));
L4542: document.addEventListener('click', () => closeCustomSelects());
L4543: document.addEventListener('keydown', (ev) => {
L4547: document.addEventListener('touchmove', blockPageTouchMoveWhileSelectOpen, {
L4550: window.addEventListener('wheel', blockPageWheelWhileSelectOpen, {
L4562: window.addEventListener('resize', resizeReposition, {
L4565: window.visualViewport?.addEventListener('resize', reposition, {
L4569: window.visualViewport?.addEventListener('scroll', reposition, {
L4574: window.addEventListener('scroll', () => {
L4735: window.addEventListener('resize', onResize, {
L4738: window.addEventListener('resize', () => scheduleDebugMasonryLayout(true), {
L4741: window.addEventListener('orientationchange', onResize, {
L4744: window.addEventListener('orientationchange', () => scheduleDebugMasonryLayout(true), {
L4748: window.visualViewport.addEventListener('resize', onResize, {
L4751: window.visualViewport.addEventListener('resize', () => scheduleDebugMasonryLayout(), {
L4754: window.visualViewport.addEventListener('scroll', onResize, {
L4775: el.addEventListener('click', ev => {
L4981: input.addEventListener('input', () => {
L4985: input.addEventListener('change', () => {
L5749: handle.addEventListener('pointerdown', ev => {
L5764: handle.addEventListener('pointermove', ev => {
L5790: handle.addEventListener('pointerup', finish);
L5791: handle.addEventListener('pointercancel', finish);
L5835: nameInput.addEventListener('change', commitName);
L5836: nameInput.addEventListener('blur', commitName);
L5837: nameInput.addEventListener('keydown', e => {
L6162: textEl.addEventListener('input', () => {
L6168: textEl.addEventListener('change', () => {
L6173: textEl.addEventListener('paste', () => requestAnimationFrame(() => {
L6181: fpsEl.addEventListener('keydown', ev => {
L6189: fpsEl.addEventListener('beforeinput', ev => {
L6192: fpsEl.addEventListener('input', () => {
L6197: fpsEl.addEventListener('paste', () => requestAnimationFrame(() => {
L6202: fpsEl.addEventListener('change', () => setScrollFps(sanitizeScrollFpsInput(true), 'text_scroll_fps_change'));
L6203: fpsEl.addEventListener('blur', () => setScrollFps(sanitizeScrollFpsInput(true), 'text_scroll_fps_blur'));
L6205: window.addEventListener('resize', () => requestAnimationFrame(autoResizeScrollTextInput));
L7147: document.addEventListener('DOMContentLoaded', bootstrapWebUi, {
~~~~

#### JS 功能完整性要求

- DOM 查询只通过 `$()` 或局部 `document.getElementById/querySelector` 进行，不引入框架。
- `bindControls()` 必须使用 `WeakMap<Element, Set<string>>` 避免重复绑定；`setClickHandlers()` 直接覆盖目标元素 `onclick`，当前 implementation 不使用 `data-click-bound`。
- 所有按钮必须经过按压动画系统：pointerdown 触发 `.is-pressing`，pointerup/cancel/leave 按最小时长补齐释放动画。
- `apiGet/apiPost/apiPostWithTimeout` 必须包含 AbortController 超时、离线 HTML 模式拦截、JSON 解析失败错误、HTTP 非 2xx 错误日志节流。
- `/api/frame` 发送必须通过 `enqueueFrameSend` 队列节流：保留最近帧，避免并发 POST；custom/parts live-send 都走同一队列。
- WebUI 模拟实体按钮命令必须通过 `enqueueButtonCommand` 队列节流：命令间隔、队列长度和 in-flight 状态必须和当前实现一致。
- 当 firmware 进入 text-scroll playback 时，基础页按钮、custom live-send、parts live-send 必须避免覆盖滚动状态；按 B1/B2/B3 后前端必须检测 `scrollStopEventSeq` 并停止/复位 scroll UI。
- `initializeMatrixViews()` 创建所有 LED preview；`fitMatrix()` 必须按 CSS 变量中的 min-width/max-height/edge-ratio 实时缩放，监听 resize/orientationchange/visualViewport。
- text scroll 需同时支持浏览器字体预览和 Ark Pixel JSON 字体表；上传固件时必须按 chunk 发送 `/api/scroll`，首 chunk `append=false`，后续 chunk `append=true`，最后才执行播放命令。
- face library 需按 `type` 分 default/user；保存时写回 `/api/saved_faces`；拖拽排序、重命名、保存当前 face、导入/导出 JSON 必须保留。
- debug 页必须保留 power refresh、battery min/max reset、debug patterns、M370 apply/copy、firmware/resource KV、log clear/download。

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

- 全局背景 `--bg: #0f1117`，panel `#161a24/#1e2430`，accent `#f971d4`，secondary accent `#77d7ff`。
- 所有 UI 控件默认使用 `GNU Unifont`；text scroll 文本输入和预览使用 `Ark Pixel 12px Monospaced`。
- `.loading-overlay` 必须有 pending/ready/revealing/hidden 阶段类；遮罩在 boot 期间锁 body scroll，揭示完成后移除锁。
- Loading 环颜色为 `#f971d4` 系列，背景高斯/遮罩为深灰，不得出现原加载进度条。
- 头像层级必须在 loading ring 之上；切换时如果有空窗期，头像背景下方必须由不透明白色填充，不能露出 loading ring。
- 卡片使用 `border-radius: 16px/18px/20px` 系列、`box-shadow: var(--card-shadow)`；按钮 hover 使用 `--button-hover-color`，active/pressing 有 transform/brightness 反馈。
- LED matrix 不显示外框；缩放只改变 matrix 本体和 card 内部距离，不允许 cutoff 任意 LED cell。
- LED preview 的最小横向适配宽度为 320px，最大 preview 高度为 500px，默认 cell 为 18px，min cell 为 5px，max cell 为 48px，edge ratio 为 0.1000。
- saved face index 不显示外框且字号较大；拖拽条必须是三横/handle 样式，不使用旧的点阵 `⠿`。
- debug page masonry 必须根据 viewport 动态重排；低宽度下一列，高宽度多列，不允许卡片互相重叠。

### 15.6 Firmware HTTP 路由、API 命令与后端状态锁定

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

#### command route table

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

#### WebServer route table

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
- 静态资源必须支持 gzip 优先、正确 Content-Type、Cache-Control 与分块 stream；HTML 禁止长缓存。
- `/api/status` 支持 query：`runtime=1`、`resources=1`、`full=1`、`unchanged=1`、`mode=...`。runtime summary 和 full status 必须分级生成，避免频繁输出大 JSON。
- `/api/power` 返回 ADC/power/battery/charge 相关状态；battery min/max reset 通过 command route 触发。
- `/api/frame` 接收 M370 frame，验证长度和字符，写入 M370 队列/状态，拒绝非法 payload 并递增 rejected 计数。
- `/api/scroll` 同时处理 OPTIONS、POST、DELETE；POST 支持 `frames`、`intervalMs`、`append`、`start`；最大 frame 数以 firmware 上限控制，超限返回错误。
- `/api/command` 只接受 route table 中命令，不允许任意字符串执行。
- `/api/saved_faces` GET 返回当前 face library，POST 进行 schema/format/type/id/m370 校验，原子写入 `saved_faces.json`。

### 15.7 Firmware 隐藏边界条件与实现细节

- RuntimeStore 必须使用 FreeRTOS spinlock 保护状态；scroll frame buffer 优先 PSRAM，失败则 fallback 到静态内部 SRAM。
- M370 render 队列必须限长，满时丢弃最旧帧并记录 dropped；decode 在临界区外执行，降低锁持有时间。
- 渲染优先级：scroll playback > queued M370 > runtime/current frame/pattern；brightness 只有变化时写 strip。
- Button hidden combo 必须按照当前 `buttons.cpp` 的时序与 debounce/long-press 阈值执行；按钮事件应向 RuntimeState 写入 lastReason 并打断 scroll 预览同步。
- PowerMonitor 必须执行 ADC 多采样、排序去极值、EMA、battery disconnect 快速压降检测、低于 5V 的未供电判定、min/max 记录过滤、LUT 百分比映射。
- Storage 写文件必须使用临时文件 + rename 原子更新；JSON 读取失败要 fallback 默认数据而不是崩溃。
- `psram_json.h` 的动态文档分配必须优先 PSRAM，避免大 JSON 文档挤占内部 SRAM。

### 15.8 资源与生成物规范

- 必须保留 loading 图像路径：
  - `/resources/loading/rina_icon1_default.png`
  - `/resources/loading/rina_icon2_hover.png`
- 必须保留字体资源路径：
  - `/resources/fonts/ark12.woff2?v=20260511-ark12-merged-trad1`
  - `/resources/fonts/ark12.json`
  - `/resources/fonts/ark12.json.gz`
- `styles.css` 中的 GNU Unifont 子集为内嵌 data URI，本文档不显示原始二进制字体字节；重建时按工具链生成。不得把字体改成外链。
- gzip 生成脚本必须只压缩可压缩文本资源，不压缩 PNG/WOFF2 原二进制。

### 15.9 当前实现源文件规范片段

以下是当前 implementation 的规范源文件内容。除了 CSS 中的 GNU Unifont 二进制 data URI 被安全占位外，其余文本源文件保持当前实现语义，用于从零重建。

#### `platformio.ini`

~~~~ini
[platformio]
default_envs = esp32s3

[env:esp32s3]
platform = espressif32
board = esp32-s3-devkitc-1
framework = arduino
monitor_speed = 115200
upload_speed = 921600

board_build.filesystem = littlefs
board_build.partitions = partitions.csv
; Change these two lines to psram_type=opi and memory_type=qio_opi
; if the installed ESP32-S3 module uses OPI PSRAM instead of QSPI PSRAM.
board_build.psram_type = qspi
board_build.arduino.memory_type = qio_qspi

lib_deps =
    bblanchon/ArduinoJson@^6.21.5
    adafruit/Adafruit NeoPixel@^1.12.3

extra_scripts =
    pre:scripts/patch_webserver_timeout.py
    scripts/gzip_webui_assets.py

build_flags =
    -D BOARD_HAS_PSRAM
    -D ARDUINO_USB_CDC_ON_BOOT=1
    -D RINACHAN_AP_ONLY=1
    ; WebServer TCP connection timeouts – patched in WebServer.h by
    ; scripts/patch_webserver_timeout.py (pre-build script).
    ; Values here act as a second layer in case the patch is ever reverted.
    -D HTTP_MAX_DATA_WAIT=200
    -D HTTP_MAX_POST_WAIT=200
    -D HTTP_MAX_SEND_WAIT=200
~~~~

#### `partitions.csv`

~~~~csv
# Name,   Type, SubType, Offset,   Size,     Flags
# Ark Pixel Font 12px resources require a large LittleFS partition.
# This layout disables OTA slots and keeps one 2 MB app partition plus ~5.9 MB LittleFS.
nvs,      data, nvs,     0x9000,   0x5000,
otadata,  data, ota,     0xe000,   0x2000,
app0,     app,  factory, 0x10000,  0x200000,
littlefs, data, spiffs,  0x210000, 0x5F0000,
~~~~

#### `README.md`

~~~~markdown
# RinaChanBoard ESP32-S3 Firmware

> ESP32-S3 firmware and offline WebUI for a custom 370-LED WS2812 RinaChanBoard matrix.

RinaChanBoard drives a 370-LED WS2812/NeoPixel display from an ESP32-S3. The board starts its own Wi-Fi access point, serves a complete WebUI from LittleFS, stores face data locally, and exposes REST endpoints for frames, saved faces, color, brightness, auto playback, text scrolling, power status, and diagnostics.

The project is built for fully local use. No router, cloud service, or external server is required after flashing. Connect to the board's access point, open the WebUI, and control the LED matrix from a phone, tablet, computer, or any HTTP client.

## Table of Contents

- [Features](#features)
- [Hardware](#hardware)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Functional Reference](#functional-reference)
- [WebUI Pages](#webui-pages)
- [HTTP API](#http-api)
- [Storage Files](#storage-files)
- [Configuration](#configuration)
- [Project Structure](#project-structure)
- [Build And Asset Pipeline](#build-and-asset-pipeline)
- [Testing](#testing)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)
- [License](#license)

## Features

- ESP32-S3 Wi-Fi access point mode
- Local DNS for `http://rina.io/`
- Offline WebUI served from LittleFS
- Static asset gzip negotiation for faster WebUI loads
- 370-LED WS2812/NeoPixel rendering on `GPIO2`
- Logical M370 frame format mapped to physical serpentine wiring
- Manual and automatic saved-face playback
- Editable default faces, custom faces, and parts-composed faces
- Firmware-side text scrolling from cached frame sequences
- Dedicated FreeRTOS LED scroll/render task pinned to Core 1
- PSRAM-backed scroll frame storage where available
- JSON-heavy workflows designed around ESP32-S3 memory limits
- Hardware button control for faces, mode, brightness, and auto interval
- Battery and charge-voltage monitoring with calibration persistence
- Runtime status, diagnostics, memory, filesystem, and power reporting
- Build-time GNU Unifont WebUI subsetting
- Ark Pixel bitmap font support for LED text-scroll rasterization

## Hardware

Default hardware assumptions:

- ESP32-S3-DevKitC-1 or compatible ESP32-S3 board
- QSPI PSRAM by default
- 370 WS2812/NeoPixel LEDs
- LED data pin: `GPIO2`
- Battery ADC pin: `GPIO10`
- Charge ADC pin: `GPIO1`

Hardware button pins:

| Button | GPIO | Action |
| --- | ---: | --- |
| `B1` | 17 | Next saved face; interrupts firmware scroll |
| `B2` | 16 | Previous saved face; interrupts firmware scroll |
| `B3` | 15 | Toggle manual/auto mode; interrupts firmware scroll |
| `B4` | 40 | Brightness down |
| `B5` | 41 | Brightness up |
| `B6` | 42 | Reserved; initialized but no mapped action currently |
| `B3 + B1` | 15 + 17 | Decrease auto interval |
| `B3 + B2` | 15 + 16 | Increase auto interval |

The LED chain uses serpentine physical wiring. Logical row 0 is forward, logical row 1 is reversed, and so on. M370 bits remain in logical row-major order from `0` to `369`; firmware maps those bits to physical LED indices before writing to the strip.

## Prerequisites

- [PlatformIO Core](https://platformio.org/install) or the PlatformIO VS Code extension
- Python 3.9+
- PowerShell 5+ on Windows
- Python packages for the asset pipeline:

```bash
pip install pillow fonttools brotli
```

PlatformIO libraries are declared in `platformio.ini`:

- `bblanchon/ArduinoJson`
- `adafruit/Adafruit NeoPixel`

## Installation

1. Clone the repository:

```bash
git clone https://github.com/yourusername/Rina-Chan-board-370-leds.git
cd Rina-Chan-board-370-leds/esp32s3_firmware
```

2. Install Python asset-build dependencies:

```bash
pip install pillow fonttools brotli
```

3. Build firmware, prepare WebUI/font assets, upload firmware, and upload LittleFS:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

The PowerShell script prepares offline WebUI assets, regenerates the embedded GNU Unifont subset, verifies Ark Pixel resources, runs PlatformIO, uploads firmware, and uploads the LittleFS image when upload flags are provided.

## Usage

### Build Only

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

### Manual PlatformIO Commands

```bash
pio run
pio run -t upload
pio run -t uploadfs
```

### Connect To The Board

After flashing, connect your device to the board's access point:

| Field | Value |
| --- | --- |
| SSID | `RinaChanBoard-V2` |
| Password | `rinachan` |
| Local DNS URL | `http://rina.io/` |
| IP URL | `http://192.168.1.14/` |

The `rina.io` hostname is resolved by the board's local DNS server and only works while connected to the board's access point.

### Refresh Browser Assets

After uploading a new LittleFS image, force the browser to reload cached assets:

```text
http://rina.io/?v=latest
```

### Default Runtime Behavior

- Startup brightness: `50/255`
- Brightness clamp: raw `10..200`
- WebUI percentage: `raw / 255`, so maximum brightness appears as about `78%`
- Default color: `#f971d4`
- Default mode: `manual`
- Startup face: loaded from `data/resources/saved_faces.json`

If LittleFS is not uploaded or fails to mount, the access point still starts and the root route returns a diagnostic page instead of silently failing. The LEDs also show a short red filesystem-error pattern.

## Functional Reference

### Access Point And Web Server

The firmware starts in AP-only mode:

- AP SSID: `RinaChanBoard-V2`
- AP password: `rinachan`
- IP address: `192.168.1.14`
- Local hostname: `rina.io`
- HTTP port: `80`
- DNS port: `53`

The web server provides:

- Static WebUI files from LittleFS
- Gzip-compressed static assets when the browser sends `Accept-Encoding: gzip`
- CORS headers for API responses
- JSON error replies for missing files, invalid input, and unsupported methods
- A diagnostic page when LittleFS is unavailable

### LED Matrix Rendering

The display format is M370:

- Prefix: `M370:`
- Payload: `93` hexadecimal characters
- Logical bits: `370`
- Storage bytes: `(370 + 7) / 8`
- Bit order: logical row-major
- Physical output: mapped to serpentine WS2812 wiring before `strip.show()`

Renderer behavior:

- Global color and brightness are applied to all lit bits
- Frame writes are rate-limited with a minimum interval
- A small queued-frame buffer smooths rapid WebUI M370 sends
- `strip.show()` is protected by a hardware-bus mutex
- Extra reset/gap timing is inserted for BSS138 level-shifter reliability
- The render task copies frame/color/brightness state under lock, then releases the lock before the physical LED update

### Color And Brightness

Color accepts standard hex input such as:

```text
#f971d4
```

Brightness is stored as raw NeoPixel brightness:

- Minimum: `10`
- Default: `50`
- Maximum: `200`
- Button step: `8`

### Saved Faces

Saved faces live in `data/resources/saved_faces.json`.

Supported face types:

- `default` - shipped faces; locked from deletion but editable/reorderable in the UI
- `custom` - user-created M370 drawings from the custom editor
- `parts` - faces produced by the expression-part composer

Saved face records include IDs, names, type, M370 data, order, and metadata such as `locked`, `editable`, `deletable`, and `is_startup_default`.

Auto/manual behavior:

- Manual mode holds the selected face/frame
- Auto mode cycles through saved faces at `autoIntervalMs`
- Interval range: `500..10000 ms`
- Default interval: `3000 ms`
- Button combo step: `500 ms`

### Text Scroll

The WebUI renders text into a horizontal M370 frame sequence and uploads it to firmware RAM.

Firmware scroll behavior:

- Scroll frames are cached in RAM/PSRAM
- Maximum cached frames: `3072`
- Timing may be supplied as `intervalMs` or `fps`
- Minimum interval: `33 ms`
- Maximum interval: `1000 ms`
- Default interval: `100 ms`
- Scroll rendering runs from a FreeRTOS task pinned to Core 1
- Playback uses elapsed-time compensation, so it catches up after short scheduling delays
- Long uploads can be chunked with `append`, `chunkIndex`, `totalFrames`, and `start`
- Scroll uploads are RAM-only; flash persistence for scroll sequences is rejected by the firmware

Scroll control supports:

- Start cached scroll playback
- Pause scroll
- Resume scroll
- Stop scroll
- Stop and clear display
- Single-frame step
- Restore auto mode after scroll when appropriate

### Hardware Buttons

Buttons are debounced and serviced in the main loop.

Runtime button behavior:

- `B1` and `B2` repeat after a hold delay for face navigation
- `B4` and `B5` repeat faster for brightness changes
- `B3` fires on release so it can be used as a combo modifier
- `B3 + B1` and `B3 + B2` are combo actions
- `B1`, `B2`, and `B3` notify the WebUI when they interrupt firmware scroll

The API can simulate button actions with `/api/command` and `cmd: "button"`.

### Power Monitoring

The firmware samples battery and charge inputs:

- Battery ADC pin: `GPIO10`
- Charge ADC pin: `GPIO1`
- Trimmed ADC samples: `16`
- Trim count: `4`
- Sample interval: `1000 ms`
- Battery disconnect/reconnect detection
- Charge-present detection
- Battery percentage lookup table for a 2S LiPo-style discharge curve
- Calibration min/max persistence in LittleFS
- Reset commands for learned battery minimum and maximum voltage

Power status is reported through `/api/status` and `/api/power`.

### Runtime State And Synchronization

Runtime state tracks:

- Color and RGB channels
- Brightness
- Manual/auto mode
- Playback state
- Current M370 frame
- Auto face list and index
- Scroll activity, pause state, interval, frame count, and frame index
- Deferred face restore after clear-frame operations
- Power status publication state
- Runtime version counters and statistics

Synchronization primitives protect:

- Frame data
- Scroll state
- Hardware bus access

### Diagnostics And Statistics

The status API reports:

- AP SSID, IP, domain, and client count
- Renderer state
- Current auto face metadata
- Scroll state
- Optional current M370 frame
- Matrix geometry
- API endpoint paths
- LittleFS mount and capacity state
- ESP heap and PSRAM state
- Scroll buffer size and PSRAM usage
- Frame, command, settings, and saved-face counters
- Power and battery calibration status

## WebUI Pages

The offline WebUI is implemented in `data/index.html` and `data/styles.css`.

### 6.1 Basic

Basic controls:

- Color picker and color preset dropdowns
- Brightness slider, number input, plus/minus buttons, and default reset
- Saved-face navigation
- Manual/auto mode toggle
- Auto interval controls
- Read-only 370-LED preview
- Battery, charge, and firmware status badges

### 6.2 Custom Face

Custom editor:

- Editable LED matrix paint board
- Clear, fill, and invert tools
- M370 textarea import/export
- Copy current M370
- Save into unified `saved_faces.json`
- Rename, reorder, apply, and delete saved entries where allowed

### 6.3 Expression Parts

Parts composer:

- Choose face parts from grouped expression libraries
- Generate combined M370 output
- Randomize part selection
- Reset to defaults
- Import/export M370
- Save parts-generated faces into the unified face library

### 6.4 Text Scroll

Text-scroll tools:

- Text input for LED scrolling
- Ark Pixel 12 px preview path
- Firmware-frame generation
- FPS/interval control
- Upload cached frame sequence to firmware
- Start, pause/resume, stop/clear, and single-step controls
- Browser preview synchronized with firmware state

### 6.5 Debug

Debug tools:

- Read firmware status
- Send pause/resume commands
- Simulate GPIO button actions
- Apply all-off, all-on, checker, border, and current-face test patterns
- Parse and apply manual M370
- Copy status JSON
- Refresh power state
- Reset battery minimum and maximum calibration
- View ADC/network/system state
- Send auxiliary commands
- Clear or download communication logs

## HTTP API

All endpoints are served from `http://192.168.1.14/` and `http://rina.io/`.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/` | Serve the WebUI root page |
| `GET` | `/index.html` | Serve the WebUI page |
| `GET` | `/api/status` | Read runtime, matrix, storage, memory, power, and statistics state |
| `GET` | `/api/power` | Read battery and charge state |
| `POST` | `/api/frame` | Apply one M370 frame |
| `POST` | `/api/scroll` | Upload cached scroll frames and optionally start playback |
| `POST` | `/api/command` | Run a control command |
| `GET` | `/api/saved_faces` | Read the saved-face library |
| `POST` | `/api/saved_faces` | Validate and replace the saved-face library |
| `OPTIONS` | API endpoints | CORS preflight support |

### `GET /api/status`

Query options:

- `runtimeOnly=1` - return lightweight runtime state
- `summary=1` - skip heavy frame/storage serialization
- `noFrame=1` - skip `lastM370`
- `since=<version>` - return `unchanged: true` if runtime version has not changed
- `fullPower=1` - include slower-changing power details

Important response sections:

- `ap`
- `power`
- `renderer`
- `renderer.scrollStopEvent`
- `memory`
- `matrix`
- `endpoints`
- `storage`
- `stats`

### `POST /api/frame`

Applies a single frame. Color and brightness are not changed here; use `/api/command`.

Example:

```json
{
  "m370": "M370:<93 hex>",
  "reason": "api_frame",
  "playback": "idle",
  "faceId": "face_08_triangle_eyes_frown"
}
```

Behavior:

- Stops firmware scroll unless the frame is scroll-related
- Applies the M370 frame
- Updates playback metadata
- Updates saved-face index when `faceId` matches a loaded face
- Returns accepted/queued state, queue depth, current color, brightness, lit LED count, and current M370

### `POST /api/scroll`

Uploads a sequence of M370 frames to the firmware scroll cache.

Example:

```json
{
  "frames": [
    "M370:<93 hex>",
    "M370:<93 hex>"
  ],
  "fps": 20,
  "append": false,
  "start": true,
  "chunkIndex": 0,
  "totalFrames": 2,
  "source": "webui_text_scroll"
}
```

Supported fields:

- `frames` - array of M370 strings
- `intervalMs` - frame interval in milliseconds
- `fps` - alternative timing input
- `append` - append to existing RAM scroll cache
- `start` - start playback after upload
- `chunkIndex` - upload chunk index
- `totalFrames` - total intended frames
- `source` - metadata string

Rejected fields/behavior:

- `persist: true`
- `saveToFlash: true`
- `storage` other than `ram`

### `POST /api/command`

General command shape:

```json
{
  "cmd": "set_brightness",
  "payload": {
    "raw": 80
  }
}
```

Supported commands:

| Command | Payload |
| --- | --- |
| `set_color` | `{ "hex": "#f971d4" }` |
| `set_brightness` | `{ "raw": 50 }` or `{ "brightness": 50 }` |
| `set_mode` | `{ "mode": "manual" }` or `{ "mode": "auto" }` |
| `set_auto_interval` | `{ "ms": 3000 }` |
| `set_scroll_interval` | `{ "intervalMs": 100 }` or `{ "fps": 10 }` |
| `start_scroll` | Optional `{ "intervalMs": 100 }` or `{ "fps": 10 }`; requires cached frames |
| `scroll_step` | No payload required |
| `pause_scroll` | No payload required |
| `resume_scroll` | No payload required |
| `stop_scroll` | `{ "clear": true, "restoreAuto": true }` |
| `pause` | Pauses scroll if active; otherwise marks runtime playback paused |
| `resume` | Resumes paused scroll if available; otherwise clears runtime pause |
| `button` | `{ "button": "B1" }` |
| `terminate_other_activities` | `{ "targetMode": "face" }`, `{ "targetMode": "scroll" }`, or another mode |
| `reset_battery_min` | No payload required |
| `reset_battery_max` | No payload required |

### `GET /api/saved_faces`

Streams the current `data/resources/saved_faces.json` file from LittleFS.

### `POST /api/saved_faces`

Validates and replaces the saved-face JSON.

Accepted body forms:

```json
{
  "document": {
    "format": "rina_faces_370_v2",
    "version": 2,
    "faces": []
  },
  "reason": "webui_save"
}
```

or the saved-face document directly.

The firmware validates:

- `format`
- matrix metadata
- face array shape
- M370 strings
- default/custom/parts type constraints
- startup/default face metadata

## Storage Files

LittleFS files:

| Path | Purpose |
| --- | --- |
| `/index.html` | WebUI HTML and JavaScript |
| `/styles.css` | WebUI stylesheet |
| `/resources/saved_faces.json` | Unified saved-face library |
| `/resources/runtime_settings.json` | Manual/auto mode and auto interval persistence |
| `/resources/battery_calib.json` | Learned battery min/max calibration |
| `/resources/loading/rina_icon1_default.png` | Loading screen default icon |
| `/resources/loading/rina_icon2_hover.png` | Loading screen hover/finish icon |
| `/resources/fonts/ark12.woff2` | Browser font for text-scroll textarea |
| `/resources/fonts/ark12.json` | Bitmap glyph table for LED text-scroll rasterization |

Generated/managed assets:

- GNU Unifont subset is embedded directly into `data/index.html`
- Ark Pixel files are stored in `data/resources/fonts/`
- Gzipped copies are generated by the build script for LittleFS upload

## Configuration

Most firmware constants live in `src/config.h`. Build and board settings live in `platformio.ini`.

Default PSRAM configuration:

```ini
board_build.psram_type = qspi
board_build.arduino.memory_type = qio_qspi
```

For ESP32-S3 modules with OPI PSRAM:

```ini
board_build.psram_type = opi
board_build.arduino.memory_type = qio_opi
```

Important constants:

| Constant | Default |
| --- | --- |
| `AP_SSID` | `RinaChanBoard-V2` |
| `AP_PASSWORD` | `rinachan` |
| `AP_DOMAIN` | `rina.io` |
| `LED_PIN` | `2` |
| `LED_COUNT` | `370` |
| `DEFAULT_BRIGHTNESS` | `50` |
| `MIN_BRIGHTNESS` | `10` |
| `MAX_BRIGHTNESS` | `200` |
| `DEFAULT_COLOR` | `#f971d4` |
| `DEFAULT_AUTO_INTERVAL_MS` | `3000` |
| `MAX_AUTO_FACES` | `128` |
| `MAX_SCROLL_FRAMES` | `3072` |
| `DEFAULT_SCROLL_INTERVAL_MS` | `100` |
| `LED_RENDER_TASK_CORE` | `1` |

## Project Structure

```text
esp32s3_firmware/
|-- data/              # LittleFS WebUI and runtime resources
|-- licenses/          # Third-party license notices
|-- scripts/           # PlatformIO pre/post build helpers
|-- src/               # Firmware source modules
|-- tools/             # Font and asset generation tools
|-- platformio.ini     # PlatformIO environment
|-- partitions.csv     # ESP32 flash partitions
`-- run_rinachan_unifont.ps1
```

Important firmware modules:

- `src/main.cpp` - setup and service loop
- `src/config.*` - pins, constants, matrix geometry, timing, defaults
- `src/web_api.*` - access point, static file serving, REST API
- `src/led_renderer.*` - M370 parsing, LED mapping, color, brightness, NeoPixel output
- `src/scroll.*` - Core 1 firmware scroll/render task
- `src/faces.*` - saved-face playback, auto/manual mode, scroll restore behavior
- `src/buttons.*` - hardware button debounce, repeat, combos, and actions
- `src/power_monitor.*` - battery/charge ADC sampling and calibration
- `src/storage.*` - LittleFS, runtime settings, saved-face persistence
- `src/state.*` - runtime state, face arrays, frame buffers, scroll buffers
- `src/sync.*` - FreeRTOS mutex helpers
- `src/utils.*` - hex/color/JSON sizing utilities
- `src/web_json.*` - lightweight JSON field extraction for large scroll uploads
- `src/psram_json.h` - PSRAM allocator for ArduinoJson documents

## Build And Asset Pipeline

### `run_rinachan_unifont.ps1`

Root build helper that:

- Checks Python dependencies
- Rebuilds the WebUI GNU Unifont subset from characters used by the current WebUI/resources
- Downloads or reuses source font assets in `.font_cache`
- Builds or verifies Ark Pixel resources
- Runs PlatformIO build/upload commands
- Can upload firmware and/or LittleFS

### `scripts/patch_webserver_timeout.py`

Pre-build PlatformIO script that patches Arduino WebServer timeout values to reduce blocking behavior on the ESP32 web server.

### `scripts/gzip_webui_assets.py`

Build script that prepares compressed WebUI assets for faster delivery from LittleFS.

### `tools/build_unifont_webui_subset_from_png.py`

Builds a GNU Unifont WOFF2 subset for the exact characters used by the WebUI and runtime resources, then embeds it into `data/index.html`.

### `tools/build_ark12_merged.py`

Builds the merged Ark Pixel 12 px resources used by text scrolling.

### `tools/compile_ark_bdf.py`

Compiles Ark Pixel BDF data into the browser/font and bitmap-table resources consumed by the project.

## Testing

There is no separate automated test suite in this firmware folder yet. Current verification is build-based:

```bash
pio run
```

Recommended manual checks after flashing:

- WebUI loads at `http://rina.io/`
- `/api/status` returns JSON
- `/api/power` returns battery/charge JSON
- A saved face renders after boot
- Color and brightness controls update LEDs
- M370 import/export round-trips correctly
- Custom and parts faces save into `saved_faces.json`
- Auto mode cycles through saved faces
- Text-scroll uploads, starts, pauses, resumes, steps, and stops
- Hardware buttons perform the mapped actions
- LittleFS diagnostic appears if filesystem upload is missing

## Contributing

Pull requests are welcome. For larger changes, open an issue or discussion first so implementation details can be agreed on before code is written.

When changing WebUI text, `data/index.html`, `data/styles.css`, or runtime JSON resources, rerun:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

This keeps the embedded GNU Unifont subset in sync with the characters used by the WebUI.

## Acknowledgments

This project builds on:

- ESP32 Arduino core
- PlatformIO
- ArduinoJson
- Adafruit NeoPixel
- GNU Unifont
- Ark Pixel Font

## License

No top-level project license file is currently included in this firmware folder. Until a project license is added, treat the project source as not licensed for redistribution by default.

Third-party font and library components retain their own licenses. The GNU Unifont subset notice is available at `licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt`.
~~~~

#### `src/buttons.cpp`

~~~~cpp
#include "buttons.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "faces.h"

// ---------------------------------------------------------------------------
// Button table
// ---------------------------------------------------------------------------

static ButtonRuntime buttons[] = {
    {"B1", BUTTON_B1_PIN},
    {"B2", BUTTON_B2_PIN},
    {"B3", BUTTON_B3_PIN},
    {"B4", BUTTON_B4_PIN},
    {"B5", BUTTON_B5_PIN},
    {"B6", BUTTON_B6_PIN},
};
static constexpr uint8_t BUTTON_COUNT = sizeof(buttons) / sizeof(buttons[0]);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static ButtonRuntime* buttonByCode(const char* code) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        if (strcmp(buttons[i].code, code) == 0) return &buttons[i];
    }
    return nullptr;
}

static bool isFaceRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
}

static bool isBrightnessRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
}

static bool isHardwareButtonPressed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    return b && b->pressed;
}

static void markButtonComboConsumed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    if (b) b->comboConsumed = true;
}

static void fireHardwareButtonAction(const char* code) {
    if (!runButtonAction(String(code), "gpio")) {
        Serial.printf("GPIO button action ignored: %s\n", code);
    }
}

static bool isScrollInterruptButton(const String& code) {
    return code == "B1" || code == "B2" || code == "B3";
}

static bool isFirmwareScrollOrPreviewActive() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           isScrollPlayback(runtimeState().playback);
}

static void markScrollStoppedByButton(const String& code, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = code;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}

// ---------------------------------------------------------------------------
// runButtonAction  (public)
// ---------------------------------------------------------------------------

bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) return false;

    const bool shouldNotifyScrollStop = isScrollInterruptButton(code) &&
                                        source == "gpio" &&
                                        isFirmwareScrollOrPreviewActive();

    if (code == "B3") {
        const bool handled = toggleModeFromButtonAction(source);
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }

    if (code == "B1" || code == "B2") {
        // Cancel scroll / other active playback first, then navigate faces.
        stopFirmwareScroll(false);
        runtimeState().restoreAutoAfterScroll = false;
    }
    if (code == "B1") {
        const bool handled = applyRelativeSavedFace( 1, source + "_B1_next_saved_face");
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }
    if (code == "B2") {
        const bool handled = applyRelativeSavedFace(-1, source + "_B2_prev_saved_face");
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }

    if (code == "B4") {
        setBrightness(static_cast<int>(runtimeState().brightness) - BRIGHTNESS_BUTTON_STEP);
        runtimeState().lastReason = source + "_B4_brightness_down";
        touchRuntimeStateSlow();
        return true;
    }
    if (code == "B5") {
        setBrightness(static_cast<int>(runtimeState().brightness) + BRIGHTNESS_BUTTON_STEP);
        runtimeState().lastReason = source + "_B5_brightness_up";
        touchRuntimeStateSlow();
        return true;
    }

    if (code == "B3B1") {
        setAutoInterval(runtimeState().autoIntervalMs > AUTO_INTERVAL_BUTTON_STEP_MS
                            ? runtimeState().autoIntervalMs - AUTO_INTERVAL_BUTTON_STEP_MS
                            : MIN_AUTO_INTERVAL_MS);
        runtimeState().lastReason = source + "_B3B1_auto_interval_down";
        touchRuntimeState();
        return true;
    }
    if (code == "B3B2") {
        setAutoInterval(runtimeState().autoIntervalMs + AUTO_INTERVAL_BUTTON_STEP_MS);
        runtimeState().lastReason = source + "_B3B2_auto_interval_up";
        touchRuntimeState();
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// GPIO event handlers
// ---------------------------------------------------------------------------

static void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs   = now;
    button.lastRepeatMs  = now;
    button.comboConsumed = false;

    // Combo: B3 + B1
    if (strcmp(button.code, "B1") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B1");
        return;
    }
    // Combo: B3 + B2
    if (strcmp(button.code, "B2") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B2");
        return;
    }

    // Single press (fire immediately for face nav and brightness)
    if (isFaceRepeatButton(button) || isBrightnessRepeatButton(button)) {
        fireHardwareButtonAction(button.code);
    }
}

static void handleHardwareButtonRelease(ButtonRuntime& button) {
    // B3 fires on release (after ensuring it was not part of a combo)
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    button.comboConsumed = false;
}

static void serviceHardwareButtonRepeats(uint32_t now) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        if (!button.pressed || button.comboConsumed) continue;

        const bool faceButton       = isFaceRepeatButton(button);
        const bool brightnessButton = isBrightnessRepeatButton(button);
        if (!faceButton && !brightnessButton) continue;
        if (faceButton && isHardwareButtonPressed("B3")) continue;

        const uint32_t repeatDelay = faceButton ? FACE_REPEAT_DELAY_MS : BRIGHTNESS_REPEAT_DELAY_MS;
        const uint32_t repeatEvery = faceButton ? FACE_REPEAT_MS       : BRIGHTNESS_REPEAT_MS;
        if (now - button.pressedAtMs  < repeatDelay) continue;
        if (now - button.lastRepeatMs < repeatEvery)  continue;

        button.lastRepeatMs = now;
        fireHardwareButtonAction(button.code);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void initHardwareButtons() {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        pinMode(buttons[i].pin, INPUT_PULLUP);
        buttons[i].rawPressed     = digitalRead(buttons[i].pin) == LOW;
        buttons[i].pressed        = buttons[i].rawPressed;
        buttons[i].lastRawChangeMs = millis();
        buttons[i].pressedAtMs    = buttons[i].pressed ? buttons[i].lastRawChangeMs : 0;
        buttons[i].lastRepeatMs   = buttons[i].pressedAtMs;
        buttons[i].comboConsumed  = false;
    }
}

void serviceHardwareButtons() {
    const uint32_t now = millis();
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button    = buttons[i];
        const bool     rawPressed = digitalRead(button.pin) == LOW;

        if (rawPressed != button.rawPressed) {
            button.rawPressed     = rawPressed;
            button.lastRawChangeMs = now;
        }
        if (now - button.lastRawChangeMs < BUTTON_DEBOUNCE_MS || rawPressed == button.pressed) {
            continue;
        }

        button.pressed = rawPressed;
        if (button.pressed) handleHardwareButtonPress(button, now);
        else                handleHardwareButtonRelease(button);
    }
    serviceHardwareButtonRepeats(now);
}
~~~~

#### `src/buttons.h`

~~~~cpp
#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Hardware button runtime record
// ---------------------------------------------------------------------------
struct ButtonRuntime {
    const char* code;
    uint8_t     pin;
    bool        rawPressed     = false;
    bool        pressed        = false;
    bool        comboConsumed  = false;
    uint32_t    lastRawChangeMs = 0;
    uint32_t    pressedAtMs    = 0;
    uint32_t    lastRepeatMs   = 0;

    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

// Initialize GPIO pins and debounce state.
void initHardwareButtons();

// Poll GPIO, debounce, and fire actions.  Call every loop() iteration.
void serviceHardwareButtons();

// Execute a named button action from any context (GPIO or API).
// Returns false if the action is unknown or preconditions are not met.
bool runButtonAction(const String& button, const String& source);
~~~~

#### `src/config.cpp`

~~~~cpp
#include "config.h"

const IPAddress AP_IP_ADDR(192, 168, 1, 14);
const IPAddress AP_GATEWAY_ADDR(192, 168, 1, 14);
const IPAddress AP_SUBNET_MASK(255, 255, 255, 0);
~~~~

#### `src/config.h`

~~~~cpp
#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Hardware
// ---------------------------------------------------------------------------
constexpr char     AP_SSID[]              = "RinaChanBoard-V2";
constexpr char     AP_PASSWORD[]          = "rinachan";
constexpr char     AP_DOMAIN[]            = "rina.io";
constexpr uint16_t HTTP_PORT             = 80;
constexpr uint16_t DNS_PORT              = 53;

#include <IPAddress.h>

extern const IPAddress AP_IP_ADDR;
extern const IPAddress AP_GATEWAY_ADDR;
extern const IPAddress AP_SUBNET_MASK;

inline const IPAddress& apIP()      { return AP_IP_ADDR; }
inline const IPAddress& apGateway() { return AP_GATEWAY_ADDR; }
inline const IPAddress& apSubnet()  { return AP_SUBNET_MASK; }
constexpr uint16_t LED_PIN               = 2;
constexpr uint16_t LED_COUNT             = 370;
constexpr uint8_t  BUTTON_B1_PIN         = 17;
constexpr uint8_t  BUTTON_B2_PIN         = 16;
constexpr uint8_t  BUTTON_B3_PIN         = 15;
constexpr uint8_t  BUTTON_B4_PIN         = 40;
constexpr uint8_t  BUTTON_B5_PIN         = 41;
constexpr uint8_t  BUTTON_B6_PIN         = 42;

// ---------------------------------------------------------------------------
// Power monitor ADC
// ---------------------------------------------------------------------------
constexpr uint8_t  BATTERY_ADC_PIN       = 10;
constexpr uint8_t  CHARGE_ADC_PIN        = 1;
constexpr float    BATTERY_DIVIDER_R1_K  = 100.0f;
constexpr float    BATTERY_DIVIDER_R2_K  = 57.0f;
constexpr float    CHARGE_DIVIDER_R1_K   = 270.0f;
constexpr float    CHARGE_DIVIDER_R2_K   = 47.0f;
// Calibration: empirical scale and offset corrections derived from two-point
// measurements against a reference multimeter.
// Battery:  adc=2.912V->8.09V, adc=2.864V->7.96V  => scale=2.708333, offset=+0.2033V
// Charge:   adc=0.661V->4.49V, adc=1.753V->11.79V => scale=6.684982, offset=+0.0712V
constexpr float    BATTERY_CAL_SCALE     = 2.708333f;  // replaces dividerScale for battery
constexpr float    BATTERY_CAL_OFFSET_V  = 0.2033f;    // additive offset after scaling
constexpr float    CHARGE_CAL_SCALE      = 6.684982f;  // replaces dividerScale for charge
constexpr float    CHARGE_CAL_OFFSET_V   = 0.0712f;    // additive offset after scaling
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    BATTERY_UNPOWERED_LOW_V = 5.0f;  // below this at boot/run-time is treated as not battery-powered
constexpr float    CHARGE_PRESENT_V      = 4.0f;
constexpr uint8_t  POWER_ADC_SAMPLES     = 16;
constexpr uint8_t  POWER_ADC_TRIM_COUNT  = 4;
constexpr uint32_t BATTERY_SAMPLE_MS     = 1000;
constexpr uint32_t CHARGE_SAMPLE_MS      = 1000;
constexpr uint32_t POWER_WEB_SLOW_PUBLISH_MS = 10000;
constexpr float    POWER_WEB_VBAT_EPS_V      = 0.01f;
constexpr float    POWER_WEB_VCHARGE_EPS_V   = 0.05f;
constexpr uint16_t BATTERY_DISCONNECT_ADC_DROP_MV = 1000;
constexpr uint16_t BATTERY_DISCONNECT_ADC_LOW_MV  = 900;
constexpr uint16_t BATTERY_RECONNECT_ADC_MV       = 1500;
constexpr char     BATTERY_CALIB_PATH[]  = "/resources/battery_calib.json";

// ---------------------------------------------------------------------------
// Battery percentage look-up table (2S LiPo piecewise-linear discharge curve)
// ---------------------------------------------------------------------------
// Each entry is { real-world voltage at the battery terminals (V), percent }.
// Points must be sorted highest-voltage first.  batteryPercentFromVoltage()
// uses piecewise-linear interpolation between adjacent entries; voltages above
// the first entry clamp to 100 % and below the last entry clamp to 0 %.
//
// Derived from a typical 2S (2×3.1 V – 2×4.2 V) lithium-polymer cell:
//   full  ≈ 8.40 V (2×4.20 V)   empty ≈ 6.20 V (2×3.10 V, conservative cutoff)
// The curve is intentionally non-linear to match the flat mid-range plateau
// and the steep drop-off near the bottom that linear arithmetic misses.
struct BatteryLutPoint { float voltage; uint8_t percent; };
constexpr BatteryLutPoint BATTERY_PERCENT_LUT[] = {
    { 8.40f, 100 },
    { 8.10f,  90 },
    { 7.90f,  80 },
    { 7.70f,  65 },
    { 7.50f,  50 },
    { 7.30f,  35 },
    { 7.10f,  20 },
    { 6.80f,  10 },
    { 6.50f,   5 },
    { 6.20f,   0 },
};
constexpr uint8_t BATTERY_PERCENT_LUT_SIZE =
    static_cast<uint8_t>(sizeof(BATTERY_PERCENT_LUT) / sizeof(BATTERY_PERCENT_LUT[0]));
constexpr uint32_t BATTERY_CALIB_SHRINK_TIMEOUT_MS = 7UL * 24UL * 60UL * 60UL * 1000UL;
constexpr uint32_t BATTERY_CALIB_SAVE_DELAY_MS     = 15000;
constexpr float    BATTERY_CALIB_SHRINK_STEP_V     = 0.02f;
constexpr float    BATTERY_CALIB_MIN_SPAN_V        = 0.10f;

// ---------------------------------------------------------------------------
// LED matrix geometry
// ---------------------------------------------------------------------------
constexpr uint16_t M370_HEX_CHARS        = 93;
constexpr uint16_t M370_BITS             = 370;
constexpr uint16_t FRAME_BYTES           = (LED_COUNT + 7) / 8;
constexpr uint8_t  MATRIX_ROWS           = 18;
constexpr bool     SERPENTINE_WIRING             = true;
constexpr bool     SERPENTINE_ODD_ROWS_REVERSED  = true;

constexpr uint8_t  ROW_LENGTHS[MATRIX_ROWS] = {
    18, 20, 20, 20, 22, 22, 22, 22, 22,
    22, 22, 22, 22, 20, 20, 20, 18, 16
};
constexpr uint16_t ROW_OFFSETS[MATRIX_ROWS] = {
    0, 18, 38, 58, 78, 100, 122, 144, 166,
    188, 210, 232, 254, 276, 296, 316, 336, 354
};
static_assert(ROW_OFFSETS[MATRIX_ROWS - 1] + ROW_LENGTHS[MATRIX_ROWS - 1] == LED_COUNT,
              "matrix row layout must cover exactly LED_COUNT logical cells");

// ---------------------------------------------------------------------------
// Brightness
// ---------------------------------------------------------------------------
constexpr uint8_t  DEFAULT_BRIGHTNESS    = 50;
constexpr uint8_t  MIN_BRIGHTNESS        = 10;
constexpr uint8_t  MAX_BRIGHTNESS        = 200;
constexpr int8_t   BRIGHTNESS_BUTTON_STEP = 8;

// ---------------------------------------------------------------------------
// Realtime frame rate limits
// ---------------------------------------------------------------------------
constexpr uint16_t M370_FRAME_MIN_INTERVAL_MS    = 33;
constexpr uint8_t  M370_FRAME_QUEUE_DEPTH        = 3;
constexpr uint8_t  M370_FRAME_REASON_CHARS       = 64;

// ---------------------------------------------------------------------------
// Auto-playback
// ---------------------------------------------------------------------------
constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS      = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS          = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS          = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS  = 500;
constexpr uint16_t MAX_AUTO_FACES                = 128;

// ---------------------------------------------------------------------------
// Scroll
// ---------------------------------------------------------------------------
constexpr uint16_t MAX_SCROLL_FRAMES             = 3072;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = M370_FRAME_MIN_INTERVAL_MS;
constexpr uint16_t MAX_SCROLL_INTERVAL_MS        = 1000;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS    = 100;
constexpr uint8_t  SCROLL_DRIFT_RESET_INTERVALS  = 4;

// ---------------------------------------------------------------------------
// Button debounce / repeat
// ---------------------------------------------------------------------------
constexpr uint32_t BUTTON_DEBOUNCE_MS            = 25;
constexpr uint32_t FACE_REPEAT_DELAY_MS          = 650;
constexpr uint32_t FACE_REPEAT_MS                = 350;
constexpr uint32_t BRIGHTNESS_REPEAT_DELAY_MS    = 450;
constexpr uint32_t BRIGHTNESS_REPEAT_MS          = 120;

// ---------------------------------------------------------------------------
// LED render task (FreeRTOS)
// ---------------------------------------------------------------------------
constexpr uint8_t  LED_RENDER_TASK_CORE          = 1;
constexpr uint32_t LED_RENDER_TASK_STACK_BYTES   = 6144;
constexpr uint8_t  LED_RENDER_TASK_PRIORITY      = 3;

// ---------------------------------------------------------------------------
// LED timing  (BSS138 level-shifter aware)
// ---------------------------------------------------------------------------
// Idle-low window inserted before and after each strip.show() call.
// Deliberately longer than the WS2812 protocol minimum because the BSS138
// has slow pull-up-dependent rising edges that can leave the first LED near
// its timing threshold during rapid refreshes.
constexpr uint16_t LED_SIGNAL_RESET_US           = 300;

// Minimum wall-clock gap enforced between consecutive strip.show() calls.
// Must be > LED_SIGNAL_RESET_US so the post-show reset is always contained
// inside the gap window.
constexpr uint16_t LED_RENDER_MIN_GAP_US         = 2500;

// ---------------------------------------------------------------------------
// Boot / stop-clear timing
// ---------------------------------------------------------------------------
constexpr uint16_t LED_STOP_CLEAR_BLANK_HOLD_MS    = 90;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 120;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 40;

// ---------------------------------------------------------------------------
// Defaults / string constants
// ---------------------------------------------------------------------------
constexpr char DEFAULT_COLOR[]          = "#f971d4";
constexpr char DEFAULT_MODE[]           = "manual";
constexpr char DEFAULT_PLAYBACK[]       = "idle";
constexpr char STARTUP_FACE_REASON[]    = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[]     = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[]       = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[]          = "/resources/runtime_settings.json";
~~~~

#### `src/faces.cpp`

~~~~cpp
#include "faces.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "storage.h"   // for ensureSavedFacesLoaded, saveRuntimeSettings

static constexpr uint8_t DEFERRED_RESTORE_NONE            = 0;
static constexpr uint8_t DEFERRED_RESTORE_STARTUP_DEFAULT = 1;
static constexpr uint8_t DEFERRED_RESTORE_CURRENT_FACE    = 2;

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------

bool isAutoMode() {
    return runtimeState().mode == "auto";
}

String normalizedMode(const char* input) {
    String mode = input ? String(input) : String();
    mode.trim();
    if (mode == "自动" || mode == "A") return "auto";
    if (mode == "手动" || mode == "M") return "manual";
    mode.toLowerCase();
    if (mode == "auto"   || mode == "a") return "auto";
    if (mode == "manual" || mode == "m") return "manual";
    return mode;
}

bool setMode(const char* input, bool persistSettings) {
    const String mode = normalizedMode(input);
    const bool settingsChanged = runtimeState().mode != mode;
    bool changed = false;

    if (mode == "auto") {
        if (runtimeState().mode != "auto") {
            runtimeState().mode = "auto";
            changed = true;
        }
        if (runtimeState().playback != "auto_saved_face") {
            runtimeState().playback = "auto_saved_face";
            changed = true;
        }
        if (runtimeState().paused) {
            runtimeState().paused = false;
            changed = true;
        }
        const uint32_t now = millis();
        if (runtimeState().lastAutoSwitchMs != now) {
            runtimeState().lastAutoSwitchMs = now;
            changed = true;
        }
    } else if (mode == "manual") {
        if (runtimeState().mode != "manual") {
            runtimeState().mode = "manual";
            changed = true;
        }
        if (persistSettings && runtimeState().restoreAutoAfterScroll) {
            runtimeState().restoreAutoAfterScroll = false;
            changed = true;
        }
        if (runtimeState().playback == "auto_saved_face") {
            runtimeState().playback = DEFAULT_PLAYBACK;
            changed = true;
        }
    } else {
        return false;
    }
    if (changed) touchRuntimeState();
    if (persistSettings && settingsChanged) saveRuntimeSettings();
    return true;
}

void setAutoInterval(uint32_t ms, bool persistSettings) {
    const uint32_t nextInterval = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (runtimeState().autoIntervalMs == nextInterval) return;
    runtimeState().autoIntervalMs = nextInterval;
    touchRuntimeState();
    if (persistSettings) saveRuntimeSettings();
}

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

bool playbackIsNonFaceActivity() {
    if (runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused) return true;
    if (isScrollPlayback(runtimeState().playback)) return true;
    if (runtimeState().lastReason.startsWith("text_scroll_") ||
        runtimeState().lastReason.startsWith("custom_") ||
        runtimeState().lastReason.startsWith("parts_") ||
        runtimeState().lastReason.startsWith("debug_")) return true;
    if (runtimeState().playback == DEFAULT_PLAYBACK || runtimeState().playback == "auto_saved_face") return false;
    return true;
}

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback) {
    if (!ensureSavedFacesLoaded()) {
        Serial.println("No saved faces available for button action");
        return false;
    }

    runtimeState().autoFaceIndex = index % runtimeAutoFaceCount();
    if (playback) runtimeState().playback = playback;

    String error;
    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, reason, error)) {
        Serial.printf("saved face apply failed: %s\n", error.c_str());
        return false;
    }
    Serial.printf("Applied saved face %u/%u via %s: %s\n",
                  runtimeState().autoFaceIndex + 1, runtimeAutoFaceCount(),
                  reason.c_str(), runtimeAutoFaces()[runtimeState().autoFaceIndex].id.c_str());
    return true;
}

bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(runtimeState().autoFaceIndex) + delta;
    while (next < 0) next += runtimeAutoFaceCount();
    next %= runtimeAutoFaceCount();
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode) {
    if (!ensureSavedFacesLoaded()) return false;
    const char*    playback = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    const uint16_t index    = runtimeAutoFaceCount() > 0 ? runtimeState().autoFaceIndex % runtimeAutoFaceCount() : 0;
    const bool     applied  = applySavedFaceIndex(index, reason, playback);
    if (applied && autoMode) runtimeState().lastAutoSwitchMs = millis();
    return applied;
}

bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    // B3 also serves as an emergency exit from text scroll / overlays.
    stopFirmwareScroll(false, false);
    runtimeState().restoreAutoAfterScroll = false;

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const String restoreReason = source +
        (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face");

    if (hadOtherPlayback) {
        applyBlankFrame(source + "_B3_clear_before_saved_face");
        scheduleCurrentSavedFaceRestoreAfterBlank(targetAuto, restoreReason);
        return true;
    }

    const bool faceApplied = applyCurrentSavedFaceForMode(restoreReason, targetAuto);
    if (!faceApplied) {
        Serial.println("B3/M-A switched mode but no saved face was available to apply");
    }
    return true;
}

// ---------------------------------------------------------------------------
// Scroll stop / startup face restore
// ---------------------------------------------------------------------------

static int16_t findStartupDefaultFaceIndex() {
    if (!ensureSavedFacesLoaded()) return -1;

    int16_t firstDefaultIndex = -1;
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        if (runtimeAutoFaces()[i].isStartupDefault) return static_cast<int16_t>(i);
        if (runtimeAutoFaces()[i].isDefault && firstDefaultIndex < 0) {
            firstDefaultIndex = static_cast<int16_t>(i);
        }
    }
    return firstDefaultIndex >= 0 ? firstDefaultIndex : 0;
}

static bool applyStartupDefaultFaceAfterScrollStop(bool restoreAutoMode) {
    setMode(restoreAutoMode ? "auto" : "manual", false);
    runtimeState().paused = false;

    const int16_t defaultIndex = findStartupDefaultFaceIndex();
    if (defaultIndex < 0) {
        Serial.println("No saved default face available after text scroll stop; leaving blank frame");
        runtimeState().playback = DEFAULT_PLAYBACK;
        return false;
    }

    const char* playback = restoreAutoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    if (!applySavedFaceIndex(static_cast<uint16_t>(defaultIndex),
                             "firmware_text_scroll_stop_default_saved_face",
                             playback)) {
        return false;
    }
    runtimeState().lastAutoSwitchMs = millis();
    return true;
}

void cancelDeferredFaceRestore() {
    const bool changed = runtimeState().deferredFaceRestoreActive ||
                         runtimeState().deferredFaceRestoreKind != DEFERRED_RESTORE_NONE ||
                         runtimeState().deferredFaceRestoreDueMs != 0;
    runtimeState().deferredFaceRestoreActive   = false;
    runtimeState().deferredFaceRestoreKind     = DEFERRED_RESTORE_NONE;
    runtimeState().deferredFaceRestoreAutoMode = false;
    runtimeState().deferredFaceRestoreDueMs    = 0;
    runtimeState().deferredFaceRestoreReason   = String();
    if (changed) touchRuntimeState();
}

static void scheduleDeferredFaceRestore(uint8_t kind, bool autoMode, const String& reason) {
    runtimeState().deferredFaceRestoreActive   = true;
    runtimeState().deferredFaceRestoreKind     = kind;
    runtimeState().deferredFaceRestoreAutoMode = autoMode;
    runtimeState().deferredFaceRestoreDueMs    = millis() + LED_STOP_CLEAR_BLANK_HOLD_MS;
    runtimeState().deferredFaceRestoreReason   = reason;
    touchRuntimeState();
}

static void scheduleStartupDefaultFaceRestoreAfterBlank(bool autoMode) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_STARTUP_DEFAULT,
                                autoMode,
                                "firmware_text_scroll_stop_default_saved_face");
}

void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_CURRENT_FACE, autoMode, reason);
}

void serviceDeferredFaceRestore() {
    if (!runtimeState().deferredFaceRestoreActive) return;

    const uint32_t now = millis();
    if (static_cast<int32_t>(now - runtimeState().deferredFaceRestoreDueMs) < 0) return;

    const uint8_t kind     = runtimeState().deferredFaceRestoreKind;
    const bool    autoMode = runtimeState().deferredFaceRestoreAutoMode;
    const String  reason   = runtimeState().deferredFaceRestoreReason;

    // Clear the pending marker before applying the face.  If the apply path
    // fails or schedules another render, this service routine will not repeat
    // the same deferred action indefinitely.
    cancelDeferredFaceRestore();

    if (runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused) {
        return;
    }

    if (kind == DEFERRED_RESTORE_STARTUP_DEFAULT) {
        applyStartupDefaultFaceAfterScrollStop(autoMode);
    } else if (kind == DEFERRED_RESTORE_CURRENT_FACE) {
        const bool faceApplied = applyCurrentSavedFaceForMode(reason, autoMode);
        if (!faceApplied) {
            Serial.println("Deferred saved-face restore failed: no saved face available");
        }
    }
}

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();

    bool shouldRestoreAuto = false;
    bool changed = false;
    withScrollLock([&]() {
        changed = runtimeState().firmwareScrollActive ||
                  runtimeState().firmwareScrollPaused ||
                  runtimeState().restoreAutoAfterScroll ||
                  runtimeState().lastScrollFrameMs != 0 ||
                  runtimeState().scrollFrameCount != 0 ||
                  runtimeState().scrollFrameIndex != 0 ||
                  runtimeState().paused ||
                  isScrollPlayback(runtimeState().playback);
        shouldRestoreAuto               = restoreAuto && runtimeState().restoreAutoAfterScroll;
        runtimeState().firmwareScrollActive      = false;
        runtimeState().firmwareScrollPaused      = false;
        runtimeState().restoreAutoAfterScroll    = false;
        runtimeState().lastScrollFrameMs         = 0;
        runtimeState().scrollFrameCount          = 0;
        runtimeState().scrollFrameIndex          = 0;
        runtimeState().paused                    = false;
        if (isScrollPlayback(runtimeState().playback)) {
            runtimeState().playback = DEFAULT_PLAYBACK;
        }
    });
    if (changed) touchRuntimeState();

    if (clearDisplay) {
        // Two-stage visible sequence without blocking the caller:
        // 1) Push an all-off frame so the current scroll frame is cleared.
        // 2) Let loop() restore the default face after the blank frame has
        //    had enough time to latch through the BSS138 / WS2812 chain.
        applyBlankFrame("firmware_text_scroll_stop_clear");
        scheduleStartupDefaultFaceRestoreAfterBlank(shouldRestoreAuto);
    } else if (shouldRestoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().restoreAutoAfterScroll = runtimeState().restoreAutoAfterScroll || isAutoMode();
            if (runtimeState().restoreAutoAfterScroll) runtimeState().mode = "manual";
            runtimeState().scrollIntervalMs   = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeState().scrollFrameIndex   = 0;
            runtimeState().lastScrollFrameMs  = millis();
            runtimeState().firmwareScrollActive  = true;
            runtimeState().firmwareScrollPaused  = false;
            runtimeState().paused             = false;
            runtimeState().playback           = "scroll";
            memcpy(firstFrame, runtimeScrollFrameBits(0), FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) applyPackedFrame(firstFrame, "firmware_text_scroll_start");
}

// ---------------------------------------------------------------------------
// Auto-playback  (called from loop())
// ---------------------------------------------------------------------------

void serviceAutoPlayback() {
    if (!isAutoMode() || runtimeState().paused || runtimeAutoFaceCount() == 0) return;

    const uint32_t now = millis();
    if (runtimeState().lastAutoSwitchMs == 0) {
        runtimeState().lastAutoSwitchMs = now;
        return;
    }
    if (now - runtimeState().lastAutoSwitchMs < runtimeState().autoIntervalMs) return;

    runtimeState().lastAutoSwitchMs  = now;
    runtimeState().autoFaceIndex     = (runtimeState().autoFaceIndex + 1) % runtimeAutoFaceCount();
    runtimeState().playback          = "auto_saved_face";
    String error;
    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, "firmware_auto_saved_face", error)) {
        Serial.printf("auto face apply failed: %s\n", error.c_str());
    }
}
~~~~

#### `src/faces.h`

~~~~cpp
#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------
bool isAutoMode();

// Normalize a mode string: accepts "auto"/"A"/"自动" → "auto",
// "manual"/"M"/"手动" → "manual".
String normalizedMode(const char* input);

// Set the playback mode.  persistSettings=true saves to LittleFS.
bool setMode(const char* input, bool persistSettings = true);

// Set the auto-advance interval.  persistSettings=true saves to LittleFS.
void setAutoInterval(uint32_t ms, bool persistSettings = true);

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

// Apply the saved face at the given index and schedule a render.
bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

// Apply a face at (currentIndex + delta) with wrapping.
bool applyRelativeSavedFace(int8_t delta, const String& reason);

// Apply the face currently pointed to by state.autoFaceIndex for the given mode.
bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

// Toggle manual/auto mode from the B3/M-A action and restore an appropriate face.
bool toggleModeFromButtonAction(const String& source);

// ---------------------------------------------------------------------------
// Scroll stop / startup face restore
// ---------------------------------------------------------------------------

// Cancel / schedule / service deferred restores that must happen after an
// all-off frame has had time to latch.  serviceDeferredFaceRestore() is called
// from loop(), so HTTP handlers never block for the blank-frame hold time.
void cancelDeferredFaceRestore();
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);
void serviceDeferredFaceRestore();

// ---------------------------------------------------------------------------
// Scroll lifecycle
// ---------------------------------------------------------------------------

// Immediately stop the firmware scroll engine.
// clearDisplay=true pushes a blank frame then restores the default face.
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

// Arm and start the firmware scroll engine from scrollFrameBits[].
void startFirmwareScroll(uint16_t intervalMs);

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

// Returns true when playback is some non-face activity (scroll, custom, etc.)
// that should be interrupted before switching faces.
bool isScrollPlayback(const String& playback);
bool playbackIsNonFaceActivity();

// ---------------------------------------------------------------------------
// Auto-playback  (called each loop() iteration)
// ---------------------------------------------------------------------------
void serviceAutoPlayback();
~~~~

#### `src/led_renderer.cpp`

~~~~cpp
#include "led_renderer.h"
#include "state.h"
#include "sync.h"
#include "scroll.h"
#include "utils.h"
#include <Adafruit_NeoPixel.h>

// Strip is owned by this module; other modules interact through the helpers.
static Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

static uint16_t logicalToPhysicalMap[LED_COUNT] = {};
static portMUX_TYPE ledRenderRequestMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool ledRenderRequested = false;
static uint32_t lastLedShowUs = 0;

struct QueuedM370Frame {
    uint8_t bits[FRAME_BYTES] = {};
    char    m370[5 + M370_HEX_CHARS + 1] = "";
    char    reason[M370_FRAME_REASON_CHARS] = "";
    bool    hasM370 = false;
};

static QueuedM370Frame m370FrameQueue[M370_FRAME_QUEUE_DEPTH];
static uint8_t m370FrameQueueHead = 0;
static uint8_t m370FrameQueueCount = 0;
static uint32_t lastM370FrameApplyMs = 0;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

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

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits);

static uint8_t m370FrameQueueTail() {
    return static_cast<uint8_t>((m370FrameQueueHead + m370FrameQueueCount) % M370_FRAME_QUEUE_DEPTH);
}

static bool m370FrameRateReady(uint32_t now) {
    return lastM370FrameApplyMs == 0 || now - lastM370FrameApplyMs >= M370_FRAME_MIN_INTERVAL_MS;
}

static void copyText(char* out, size_t outSize, const char* input) {
    if (outSize == 0) return;
    if (!input) input = "";
    size_t i = 0;
    for (; i + 1 < outSize && input[i] != '\0'; ++i) out[i] = input[i];
    out[i] = '\0';
}

static void publishPackedFrameNow(const uint8_t* packedBits, const char* normalizedM370, const char* reason) {
    withFrameLock([&]() {
        memcpy(runtimeFrameBits(), packedBits, FRAME_BYTES);
        if (normalizedM370 && normalizedM370[0] != '\0') {
            runtimeState().lastM370 = normalizedM370;
        }
        runtimeState().lastReason = reason ? reason : "";
        ++runtimeState().framesAccepted;
        touchRuntimeState();
        showCurrentFrameNoLock();
    });
    lastM370FrameApplyMs = millis();
}

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

// ---------------------------------------------------------------------------
// LED index map
// ---------------------------------------------------------------------------

void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
    }
}

// ---------------------------------------------------------------------------
// Render request  (ISR-safe)
// ---------------------------------------------------------------------------

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

void showCurrentFrameNoLock() { requestLedRender(); }

// ---------------------------------------------------------------------------
// Frame bit helpers
// ---------------------------------------------------------------------------

void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) runtimeFrameBits()[byteIndex] |=  bitMask;
    else    runtimeFrameBits()[byteIndex] &= ~bitMask;
}

bool frameBit(uint16_t index) {
    return (runtimeFrameBits()[index >> 3] & (1U << (index & 7U))) != 0;
}

bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

uint16_t countLitLeds() {
    uint16_t lit = 0;
    for (uint16_t i = 0; i < LED_COUNT; ++i) {
        if (frameBit(i)) ++lit;
    }
    return lit;
}

// ---------------------------------------------------------------------------
// Physical render  (Core 1 render task only)
// ---------------------------------------------------------------------------

void renderCurrentFrameToLedStrip() {
    uint8_t localFrame[FRAME_BYTES];
    uint8_t brightness;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    lockFrame();
    memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
    brightness = runtimeState().brightness;
    colorR     = runtimeState().colorR;
    colorG     = runtimeState().colorG;
    colorB     = runtimeState().colorB;
    unlockFrame();

    // --- Timing: enforce minimum inter-frame gap FIRST ---
    // Wait before touching the pixel buffer so the WS2812 bus has been idle
    // long enough for the previous frame to fully latch.  The BSS138 level
    // shifter has slow pull-up-dependent rising edges; keeping DATA low for at
    // least LED_RENDER_MIN_GAP_US guarantees the reset pulse is seen as a
    // valid latch signal by the first LED in the chain.
    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) {
            delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
        }
    }

    // Build the pixel buffer.
    // setBrightness is called only when the value actually changes to avoid
    // the per-call rescale pass Adafruit_NeoPixel applies to the internal buffer.
    // Initialise to DEFAULT_BRIGHTNESS because ledStripBegin() already called
    // strip.setBrightness(DEFAULT_BRIGHTNESS), so the first render skips a
    // redundant rescale of the freshly-populated pixel buffer.
    static uint8_t lastAppliedBrightness = DEFAULT_BRIGHTNESS;
    if (brightness != lastAppliedBrightness) {
        strip.setBrightness(brightness);
        lastAppliedBrightness = brightness;
    }
    const uint32_t rgb = strip.Color(colorR, colorG, colorB);
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        strip.setPixelColor(
            logicalToPhysicalMap[logical],
            packedFrameBit(localFrame, logical) ? rgb : 0
        );
    }

    // Idle-low reset window before transmitting — deliberately longer than
    // the WS2812 protocol minimum because the BSS138 slow rising edge can
    // otherwise push the first LED's T0H/T1H decision into an ambiguous region
    // during rapid successive refreshes.
    delayMicroseconds(LED_SIGNAL_RESET_US);
    lockHardwareBus();
    strip.show();
    unlockHardwareBus();
    lastLedShowUs = micros();
    // Post-show reset: begin the latch window immediately so that subsequent
    // render requests or the scroll task's wakeup do not accidentally clock a
    // spurious edge before the LEDs have finished latching.
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// Strip boot helpers  (called from setup() only)
// ---------------------------------------------------------------------------

void ledStripBegin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    lockHardwareBus();
    strip.show();
    unlockHardwareBus();
    lastLedShowUs = micros();
    // Post-show reset: mirror the same idle-low window used by
    // renderCurrentFrameToLedStrip() so that the first real frame rendered
    // after boot is guaranteed to see a clean reset pulse even if the
    // LED_BOOT_CLEAR_HOLD_MS delay fires on the same microsecond tick.
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// M370 codec
// ---------------------------------------------------------------------------

bool normalizeM370(const String& input, String& normalized, String& error) {
    String compact;
    compact.reserve(M370_HEX_CHARS);

    String payload = input;
    payload.trim();
    if (payload.length() >= 5 && payload.substring(0, 5).equalsIgnoreCase("M370:")) {
        payload = payload.substring(5);
    }

    for (size_t i = 0; i < payload.length(); ++i) {
        const char c = payload.charAt(i);
        if (c == ' ' || c == '\r' || c == '\n' || c == '\t') continue;
        if (hexNibble(c) < 0) {
            error = "M370 contains a non-hex character";
            return false;
        }
        compact += c;
    }

    if (compact.length() != M370_HEX_CHARS) {
        error = "M370 must be 93 hex chars, optionally prefixed with M370:";
        return false;
    }

    compact.toUpperCase();
    normalized = "M370:" + compact;
    return true;
}

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) return false;

    decodeNormalizedM370ToPackedBits(normalized, outBits);
    return true;
}

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits) {
    memset(outBits, 0, FRAME_BYTES);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int  nibble = hexNibble(normalized.charAt(5 + bit / 4));
        const bool on     = (nibble & (1 << (3 - (bit % 4)))) != 0;
        if (on) outBits[bit >> 3] |= 1U << (bit & 7U);
    }
}

String blankM370() {
    String out = "M370:";
    out.reserve(5 + M370_HEX_CHARS);
    for (uint16_t i = 0; i < M370_HEX_CHARS; ++i) out += '0';
    return out;
}

// ---------------------------------------------------------------------------
// Frame apply helpers
// ---------------------------------------------------------------------------

bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++runtimeState().framesRejected;
        return false;
    }

    // Decode the M370 payload into a temporary packed-bit buffer OUTSIDE the
    // frame mutex.  This keeps the critical section as short as a memcpy so the
    // render task (Core 1) is never blocked for a full 370-iteration decode loop.
    uint8_t packed[FRAME_BYTES];
    decodeNormalizedM370ToPackedBits(normalized, packed);

    enqueuePackedM370Frame(packed, normalized.c_str(), reason);
    return true;
}

void applyPackedFrame(const uint8_t* packedBits, const String& reason) {
    enqueuePackedM370Frame(packedBits, nullptr, reason);
}

void applyBlankFrame(const String& reason) {
    uint8_t blank[FRAME_BYTES] = {};
    char blankM370Text[5 + M370_HEX_CHARS + 1];
    memcpy(blankM370Text, "M370:", 5);
    memset(blankM370Text + 5, '0', M370_HEX_CHARS);
    blankM370Text[5 + M370_HEX_CHARS] = '\0';
    enqueuePackedM370Frame(blank, blankM370Text, reason);
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

uint8_t queuedM370FrameCount() {
    return m370FrameQueueCount;
}

// ---------------------------------------------------------------------------
// Color / brightness
// ---------------------------------------------------------------------------

void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    runtimeState().colorHex = formatColorHex(r, g, b);
    runtimeState().colorR   = r;
    runtimeState().colorG   = g;
    runtimeState().colorB   = b;
}

bool setColor(const String& input, String& error) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) {
        error = "color must be #RRGGBB or RRGGBB (hex)";
        return false;
    }
    withFrameLock([&]() {
        runtimeState().colorHex = formatColorHex(r, g, b);
        runtimeState().colorR   = r;
        runtimeState().colorG   = g;
        runtimeState().colorB   = b;
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
    return true;
}

void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    withFrameLock([&]() {
        runtimeState().brightness = static_cast<uint8_t>(raw);
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
}
~~~~

#### `src/led_renderer.h`

~~~~cpp
#pragma once
#include <Arduino.h>
#include "config.h"

// ---------------------------------------------------------------------------
// M370 frame codec
// ---------------------------------------------------------------------------

// Parse and normalize an M370 hex string.
// Input may optionally be prefixed with "M370:" and may contain whitespace.
// On success, `normalized` is set to "M370:<93 uppercase hex chars>" and
// returns true.  On failure, `error` is populated and returns false.
bool normalizeM370(const String& input, String& normalized, String& error);

// Decode an M370 string into a packed bit array (FRAME_BYTES bytes).
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

// Return a blank M370 string (all zeros).
String blankM370();

// ---------------------------------------------------------------------------
// Frame bit helpers  (operate on frameBits via state.h)
// ---------------------------------------------------------------------------
void setFrameBit(uint16_t index, bool on);
bool frameBit(uint16_t index);
bool packedFrameBit(const uint8_t* bits, uint16_t index);

// Count how many logical LEDs are currently lit in frameBits.
uint16_t countLitLeds();

// ---------------------------------------------------------------------------
// Frame apply helpers  (take frameMutex internally)
// ---------------------------------------------------------------------------

// Apply an M370 string to frameBits and schedule a render.
// Increments framesAccepted / framesRejected on state.
bool applyM370(const String& input, const String& reason, String& error);

// Copy pre-decoded packed bits into frameBits and schedule a render.
void applyPackedFrame(const uint8_t* packedBits, const String& reason);

// Clear frameBits to all-off and schedule a render.
void applyBlankFrame(const String& reason);

// Drain one queued M370/pumped frame when the global frame rate limiter allows it.
void serviceM370FrameQueue();

// Current number of queued frames waiting for the global frame rate limiter.
uint8_t queuedM370FrameCount();

// ---------------------------------------------------------------------------
// Color / brightness  (take frameMutex internally where required)
// ---------------------------------------------------------------------------

// Update color state without scheduling a render (for use during boot).
void setColorStateNoRender(const String& input);

// Update color state and schedule a render.
bool setColor(const String& input, String& error);

// Clamp and apply a new brightness value, then schedule a render.
void setBrightness(int raw);

// ---------------------------------------------------------------------------
// Render request / consume  (ISR-safe via portMUX)
// ---------------------------------------------------------------------------
void requestLedRender();
bool consumeLedRenderRequest();

// Convenience wrapper used inside frameMutex-held sections.
void showCurrentFrameNoLock();

// ---------------------------------------------------------------------------
// Physical render  (called only from the render task on Core 1)
// ---------------------------------------------------------------------------
void renderCurrentFrameToLedStrip();

// ---------------------------------------------------------------------------
// LED index map  (call once at boot before any render)
// ---------------------------------------------------------------------------
void initLedIndexMap();

// ---------------------------------------------------------------------------
// Strip initialization  (call once from setup())
// ---------------------------------------------------------------------------
void ledStripBegin();
~~~~

#### `src/main.cpp`

~~~~cpp
#include <Arduino.h>

#include "config.h"
#include "state.h"
#include "sync.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "scroll.h"
#include "buttons.h"
#include "web_api.h"
#include "power_monitor.h"
#include <freertos/task.h>

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

void setup() {
    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    initRuntimeScrollFrameBuffer();

    // FreeRTOS primitives
    if (!initSyncPrimitives()) {
        Serial.println("Failed to create one or more FreeRTOS mutexes");
    }

    // Build logical→physical LED index map
    initLedIndexMap();

    // Initialize the LED strip: clear, latch, then hold long enough for the
    // BSS138 level shifter to settle before we write the first real frame.
    ledStripBegin();
    delay(LED_BOOT_CLEAR_HOLD_MS);

    // Set the default color without scheduling a render.  During boot, the
    // first physical frame after the all-off latch should be the startup saved
    // face, not an extra task-rendered blank frame that can race on the WS2812
    // bus through the BSS138.
    setColorStateNoRender(DEFAULT_COLOR);

    // Mount filesystem, load settings and saved faces
    if (!mountFilesystem()) {
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadSavedFaces(true);
    }

    // Render the first non-blank boot frame synchronously before starting the
    // render task, then drain the queued request left by loadSavedFaces /
    // applyM370 so the task does not double-render on wakeup.
    renderCurrentFrameToLedStrip();
    consumeLedRenderRequest();
    delay(LED_BOOT_STARTUP_SETTLE_MS);

    // Spawn the Core-1 LED render / scroll task
    startScrollRenderTask();

    // Initialize hardware buttons
    initHardwareButtons();

    // Initialize battery / charge ADC monitoring
    initPowerMonitor();

    // Start networking and HTTP server
    startAccessPoint();
    startWebServer();
}

// ---------------------------------------------------------------------------
// loop  (Core 0)
// ---------------------------------------------------------------------------

void loop() {
    serviceM370FrameQueue();
    webServerTick();
    serviceRuntimeSlowStatePublish();
    serviceHardwareButtons();
    servicePowerMonitor();
    serviceDeferredFaceRestore();
    serviceAutoPlayback();
    vTaskDelay(pdMS_TO_TICKS(1));
}
~~~~

#### `src/power_monitor.cpp`

~~~~cpp
#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "storage.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <math.h>

PowerStatus powerStatus;

// EMA low-pass filters for ADC-derived voltages.
// CHARGE_EMA_ALPHA is a fixed-alpha filter; it only runs during steady-state
// (transitions snap immediately) so call-rate drift is inconsequential.
// Battery EMA uses a time-constant (τ) instead of a fixed alpha so the
// effective smoothing window remains BATTERY_EMA_TAU_S seconds regardless of
// whether the caller runs at 0.5 Hz, 1 Hz, or 2 Hz.
//   α = 1 − exp(−Δt / τ)   →   at exactly 1 Hz this is ≈ 0.0488 ≈ old 0.05
constexpr float BATTERY_EMA_TAU_S = 20.0f;   // target smoothing time-constant
constexpr float CHARGE_EMA_ALPHA  = 0.20f;

static float dividerScale(float r1k, float r2k) {
    return (r1k + r2k) / r2k;
}

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

static float sanitizedCalibMax(float value) {
    if (!isfinite(value)) return BATTERY_FULL_V;
    return max(value, BATTERY_FULL_V);
}

static float sanitizedCalibMin(float value) {
    if (!isfinite(value)) return BATTERY_EMPTY_V;
    return min(value, BATTERY_EMPTY_V);
}

static float jsonFloatOr(JsonVariantConst value, float fallback) {
    if (value.isNull()) return fallback;
    const float parsed = value.as<float>();
    return isfinite(parsed) ? parsed : fallback;
}

static void ensureBatteryCalibrationDefaults(uint32_t now) {
    powerStatus.batteryCalibMaxV = sanitizedCalibMax(powerStatus.batteryCalibMaxV);
    powerStatus.batteryCalibMinV = sanitizedCalibMin(powerStatus.batteryCalibMinV);
    if (powerStatus.batteryCalibMaxV - powerStatus.batteryCalibMinV < BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
        powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    }
    if (powerStatus.lastCalibMaxMs == 0) powerStatus.lastCalibMaxMs = now;
    if (powerStatus.lastCalibMinMs == 0) powerStatus.lastCalibMinMs = now;
}

static void markBatteryCalibrationDirty(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) {
        powerStatus.batteryCalibDirtySinceMs = now;
    }
    powerStatus.batteryCalibDirty = true;
}

static uint8_t batteryPercentFromVoltage(float vbat) {
    if (!isfinite(vbat)) return 0;
    const uint8_t n = BATTERY_PERCENT_LUT_SIZE;
    // Clamp at extremes.
    if (vbat >= BATTERY_PERCENT_LUT[0].voltage)     return 100;
    if (vbat <= BATTERY_PERCENT_LUT[n - 1].voltage) return 0;
    // Find the bracketing segment and interpolate linearly within it.
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

static bool loadBatteryCalibration(uint32_t now) {
    powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    powerStatus.lastCalibMaxMs = now;
    powerStatus.lastCalibMinMs = now;
    powerStatus.batteryCalibLoaded = false;

    bool calibExists = false;
    if (runtimeFsMounted()) {
        lockHardwareBus();
        calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        unlockHardwareBus();
    }
    if (!runtimeFsMounted() || !calibExists) {
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(BATTERY_CALIB_PATH, "r");
    unlockHardwareBus();
    if (!file) return false;

    DynamicJsonDocument doc(512);
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(6));
    file.close();
    unlockHardwareBus();
    if (err) {
        Serial.printf("battery_calib.json parse failed: %s\n", err.c_str());
        return false;
    }

    powerStatus.batteryCalibMaxV = sanitizedCalibMax(jsonFloatOr(doc["v_max"], BATTERY_FULL_V));
    powerStatus.batteryCalibMinV = sanitizedCalibMin(jsonFloatOr(doc["v_min"], BATTERY_EMPTY_V));
    ensureBatteryCalibrationDefaults(now);
    powerStatus.batteryCalibLoaded = true;
    Serial.printf("Battery calibration loaded: v_min=%.3f v_max=%.3f\n",
                  powerStatus.batteryCalibMinV,
                  powerStatus.batteryCalibMaxV);
    return true;
}

static bool saveBatteryCalibration(uint32_t now) {
    if (!runtimeFsMounted()) return false;
    bool resourcesOk = false;
    lockHardwareBus();
    resourcesOk = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    unlockHardwareBus();
    if (!resourcesOk) {
        Serial.println("Failed to ensure /resources for battery calibration");
        return false;
    }

    DynamicJsonDocument doc(512);
    doc["format"] = "rina_battery_calibration_v1";
    doc["version"] = 1;
    doc["v_max"] = powerStatus.batteryCalibMaxV;
    doc["v_min"] = powerStatus.batteryCalibMinV;
    doc["v_max_nominal"] = BATTERY_FULL_V;
    doc["v_min_nominal"] = BATTERY_EMPTY_V;
    doc["last_max_ms"] = powerStatus.lastCalibMaxMs;
    doc["last_min_ms"] = powerStatus.lastCalibMinMs;
    doc["updated_at_ms"] = now;

    size_t written = 0;
    String error;
    if (!writeJsonFileAtomic(BATTERY_CALIB_PATH, doc.as<JsonVariant>(), written, error)) {
        Serial.printf("Failed to write battery_calib.json: %s\n", error.c_str());
        return false;
    }
    powerStatus.batteryCalibDirty = false;
    powerStatus.batteryCalibDirtySinceMs = 0;
    powerStatus.batteryCalibLoaded = true;
    return true;
}

static void updateBatteryCalibration(float vbat, bool freezeCalibration, uint32_t now) {
    // Dynamic min/max learning has been removed.  Battery percentage is now
    // derived from the fixed piecewise-linear LUT (BATTERY_PERCENT_LUT in
    // config.h) which matches the actual 2S LiPo discharge curve.  A learned
    // voltage span is no longer needed and was an anti-pattern: a single deep-
    // discharge or large-current sag event could permanently shift calibMinV,
    // causing the gauge to show non-zero percent at the true empty voltage.
    //
    // ensureBatteryCalibrationDefaults keeps the stored flash values within
    // safe bounds in case legacy calibration data was loaded from flash (the
    // values are still written to flash by the manual-reset API and exported
    // over the web API for diagnostics).
    ensureBatteryCalibrationDefaults(now);
    (void)vbat;
    (void)freezeCalibration;
}

static void serviceBatteryCalibrationSave(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) return;
    if (now - powerStatus.batteryCalibDirtySinceMs < BATTERY_CALIB_SAVE_DELAY_MS) return;
    saveBatteryCalibration(now);
}

static bool batteryHasPoweredVoltage() {
    return powerStatus.batteryValid &&
           !powerStatus.batteryDisconnected &&
           !powerStatus.batteryLowVoltageUnpowered &&
           isfinite(powerStatus.vbat) &&
           powerStatus.vbat >= BATTERY_UNPOWERED_LOW_V;
}

static bool batteryCanRecordMinimumVoltage() {
    return batteryHasPoweredVoltage() && !powerStatus.charging;
}

static void markPowerCalibrationChanged(uint32_t now) {
    markBatteryCalibrationDirty(now);
    saveBatteryCalibration(now);
    powerStatus.webFastDirty = true;
    powerStatus.webSlowDirty = true;
    powerStatus.lastWebSlowPublishMs = now;
    touchRuntimeState();
}

void resetBatteryVoltageMaximum() {
    const uint32_t now = millis();
    ensureBatteryCalibrationDefaults(now);
    const float minV = sanitizedCalibMin(powerStatus.batteryCalibMinV);
    const float currentV = powerStatus.vbat;
    if (batteryHasPoweredVoltage() && currentV > minV + BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMaxV = currentV;
    } else {
        powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    }
    powerStatus.lastCalibMaxMs = now;
    ensureBatteryCalibrationDefaults(now);
    markPowerCalibrationChanged(now);
}

void resetBatteryVoltageMinimum() {
    const uint32_t now = millis();
    ensureBatteryCalibrationDefaults(now);
    const float maxV = sanitizedCalibMax(powerStatus.batteryCalibMaxV);
    const float currentV = powerStatus.vbat;
    if (batteryCanRecordMinimumVoltage() && currentV < maxV - BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMinV = currentV;
    } else {
        powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    }
    powerStatus.lastCalibMinMs = now;
    ensureBatteryCalibrationDefaults(now);
    markPowerCalibrationChanged(now);
}

static bool finiteChanged(float previous, float current, float epsilon) {
    if (!isfinite(previous) && !isfinite(current)) return false;
    if (!isfinite(previous) || !isfinite(current)) return true;
    return fabsf(previous - current) >= epsilon;
}

static void markPowerWebFastDirty() {
    powerStatus.webFastDirty = true;
    touchRuntimeState();
}

static void markPowerWebSlowDirty(uint32_t now) {
    powerStatus.webSlowDirty = true;
    powerStatus.lastWebSlowPublishMs = now;
    powerStatus.webPublishedBatteryValid = powerStatus.batteryValid;
    powerStatus.webPublishedChargeValid = powerStatus.chargeValid;
    powerStatus.webPublishedVbat = powerStatus.vbat;
    powerStatus.webPublishedVcharge = powerStatus.vcharge;
    powerStatus.webPublishedBatteryPercent = powerStatus.batteryPercent;
    touchRuntimeState();
}

static void servicePowerWebPublish(uint32_t now, bool force) {
    if (force || !powerStatus.webPublishedChargingKnown ||
        powerStatus.webPublishedChargeValid != powerStatus.chargeValid ||
        powerStatus.webPublishedCharging != powerStatus.charging) {
        powerStatus.webPublishedChargeValid = powerStatus.chargeValid;
        powerStatus.webPublishedCharging = powerStatus.charging;
        powerStatus.webPublishedChargingKnown = true;
        markPowerWebFastDirty();
        powerStatus.webSlowDirty = true;
    }

    if (!force && now - powerStatus.lastWebSlowPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;

    const bool slowChanged =
        force ||
        powerStatus.webPublishedBatteryValid != powerStatus.batteryValid ||
        powerStatus.webPublishedChargeValid != powerStatus.chargeValid ||
        finiteChanged(powerStatus.webPublishedVbat, powerStatus.vbat, POWER_WEB_VBAT_EPS_V) ||
        finiteChanged(powerStatus.webPublishedVcharge, powerStatus.vcharge, POWER_WEB_VCHARGE_EPS_V) ||
        powerStatus.webPublishedBatteryPercent != powerStatus.batteryPercent;

    if (slowChanged) {
        markPowerWebSlowDirty(now);
    } else {
        powerStatus.lastWebSlowPublishMs = now;
    }
}

static void sampleBattery(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(BATTERY_ADC_PIN);
    const uint16_t prevAdcMv = powerStatus.batteryAdcMv;
    const bool hadPreviousAdc = powerStatus.batteryPrevAdcKnown;
    const bool hugeRawDrop = hadPreviousAdc &&
        prevAdcMv > adcMv &&
        static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
        adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
    const bool stillDisconnected = powerStatus.batteryDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV;

    powerStatus.batteryPrevAdcMv = hadPreviousAdc ? prevAdcMv : adcMv;
    powerStatus.batteryAdcMv = adcMv;
    powerStatus.batteryPrevAdcKnown = true;

    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    const float instantVbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;
    powerStatus.batteryLastInstantVbat = instantVbat;

    // A charger-present state intentionally overrides the visual "unpowered"
    // state: while charging, the WebUI must show the measured battery voltage
    // and a red battery icon, but this reading still must not update v_min.
    const bool chargerPresent = powerStatus.chargeValid && powerStatus.charging;
    const bool rawDropUnpowered = (hugeRawDrop || stillDisconnected) && !chargerPresent;
    const bool lowVoltageUnpowered = !chargerPresent && instantVbat < BATTERY_UNPOWERED_LOW_V;

    if (rawDropUnpowered) {
        if (!powerStatus.batteryDisconnected) {
            powerStatus.batteryDisconnectedSinceMs = now;
            powerStatus.lastBatteryDisconnectEventMs = now;
            powerStatus.batteryDisconnectDropMv = static_cast<uint16_t>(prevAdcMv - adcMv);
        }
        powerStatus.batteryDisconnected = true;
        powerStatus.batteryLowVoltageUnpowered = false;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        powerStatus.lastBatteryMs = now;
        markPowerWebSlowDirty(now);
        return;
    }

    const bool wasDisconnected = powerStatus.batteryDisconnected;
    const bool wasLowVoltageUnpowered = powerStatus.batteryLowVoltageUnpowered;
    if (wasDisconnected) {
        powerStatus.batteryDisconnected = false;
        powerStatus.batteryDisconnectedSinceMs = 0;
        powerStatus.batteryDisconnectDropMv = 0;
        powerStatus.vbat = NAN;
    }

    if (lowVoltageUnpowered) {
        powerStatus.batteryLowVoltageUnpowered = true;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        powerStatus.lastBatteryMs = now;
        updateBatteryCalibration(instantVbat, true, now);
        if (!wasLowVoltageUnpowered) markPowerWebSlowDirty(now);
        return;
    }

    // Unify exit from both zero-voltage states (disconnect and low-voltage
    // unpowered) by resetting the EMA seed to NAN.  Without this, recovery
    // from lowVoltageUnpowered would start the smoothing filter from 0 V
    // instead of from the real current reading.
    //
    // Note: wasDisconnected already set vbat=NAN above; this block mirrors
    // that behaviour for wasLowVoltageUnpowered so both paths are identical.
    if (wasLowVoltageUnpowered) powerStatus.vbat = NAN;
    powerStatus.batteryLowVoltageUnpowered = false;  // safety-belt clear

    // Time-delta-weighted EMA: α = 1 − exp(−Δt / τ).
    // Using a fixed alpha would tie the effective smoothing time-constant to
    // the call interval; if WiFi processing or dense LED animation stalls the
    // loop, α would understate the elapsed time and the filter would become
    // sluggish.  Computing α from the actual Δt keeps τ = BATTERY_EMA_TAU_S
    // (20 s) regardless of call frequency.
    //
    // hugeVoltageDrop was removed: bypassing the EMA on a large drop caused the
    // percent gauge to plummet during WS2812B high-current bursts and then crawl
    // back over ~20 s when the load cleared — exactly the behaviour the filter
    // exists to prevent.
    if (!powerStatus.batteryValid || !isfinite(powerStatus.vbat)) {
        powerStatus.vbat = instantVbat;
    } else {
        // Clamp dt to [1 ms, 10 s] to guard against a stale lastBatteryMs or a
        // pathologically long pause (which would otherwise drive α toward 1.0).
        const float dtS = constrain(
            static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f,
            0.001f, 10.0f);
        const float emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
        powerStatus.vbat = (powerStatus.vbat * (1.0f - emaAlpha)) +
                            (instantVbat * emaAlpha);
    }

    const bool freezeCalibration = chargerPresent ||
        powerStatus.batteryDisconnected ||
        powerStatus.batteryLowVoltageUnpowered ||
        powerStatus.vbat < BATTERY_UNPOWERED_LOW_V;
    updateBatteryCalibration(powerStatus.vbat, freezeCalibration, now);

    // ±1 % integer dead-band: only update batteryPercent when the LUT result
    // differs from the current display value by more than one percentage point.
    // This prevents the displayed integer from toggling between adjacent values
    // (e.g. 49 ↔ 50) when the EMA-smoothed voltage hovers near a LUT segment
    // boundary and sub-LSB ADC noise causes the interpolated result to alternate
    // between the two sides.  On the very first valid reading (!batteryValid)
    // the guard is bypassed so the gauge initialises immediately.
    {
        const uint8_t rawPct = batteryPercentFromVoltage(powerStatus.vbat);
        const int16_t delta  = static_cast<int16_t>(rawPct) -
                                static_cast<int16_t>(powerStatus.batteryPercent);
        if (!powerStatus.batteryValid || delta > 1 || delta < -1) {
            powerStatus.batteryPercent = rawPct;
        }
    }
    powerStatus.batteryValid = true;
    powerStatus.lastBatteryMs = now;
    if (wasDisconnected || wasLowVoltageUnpowered) markPowerWebSlowDirty(now);
}

static void sampleCharge(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;

    const float instantVcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;

    // Snap the EMA seed on either edge of charger presence so that
    // powerStatus.charging always reflects the new hardware state within the
    // same sample cycle.
    //
    // Plug-in  (false→true): without snapping, the EMA would ramp up from the
    //   stale near-zero value, displaying 0 V for several seconds.
    // Unplug   (true→false): without snapping, the slow EMA keeps
    //   powerStatus.charging == true for ~5 s after physical removal.  During
    //   that window sampleBattery sees chargerPresent=true and suppresses the
    //   battery-disconnect check, potentially missing a real event.
    const bool instantCharging    = instantVcharge > CHARGE_PRESENT_V;
    const bool chargerStateChange = (powerStatus.charging != instantCharging);

    if (!powerStatus.chargeValid || !isfinite(powerStatus.vcharge) || chargerStateChange) {
        powerStatus.vcharge = instantVcharge;
    } else {
        powerStatus.vcharge = (powerStatus.vcharge * (1.0f - CHARGE_EMA_ALPHA)) +
                               (instantVcharge * CHARGE_EMA_ALPHA);
    }

    powerStatus.charging = powerStatus.vcharge > CHARGE_PRESENT_V;
    powerStatus.chargeValid = true;
    powerStatus.lastChargeMs = now;
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

void servicePowerMonitor(bool force) {
    const uint32_t now = millis();
    if (force || !powerStatus.chargeValid || now - powerStatus.lastChargeMs >= CHARGE_SAMPLE_MS) {
        sampleCharge(now);
    }
    if (force || !powerStatus.batteryValid || now - powerStatus.lastBatteryMs >= BATTERY_SAMPLE_MS) {
        sampleBattery(now);
    }
    servicePowerWebPublish(now, force);
    serviceBatteryCalibrationSave(now);
}
~~~~

#### `src/power_monitor.h`

~~~~cpp
#pragma once
#include <Arduino.h>

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
    uint8_t  webPublishedBatteryPercent = 0;
    bool     webPublishedBatteryValid   = false;
    bool     webPublishedChargeValid    = false;
    bool     webPublishedCharging       = false;
    bool     webPublishedChargingKnown  = false;
    bool     webFastDirty               = true;
    bool     webSlowDirty               = true;
};

extern PowerStatus powerStatus;

void initPowerMonitor();
void servicePowerMonitor(bool force = false);
void resetBatteryVoltageMinimum();
void resetBatteryVoltageMaximum();
~~~~

#### `src/psram_json.h`

~~~~cpp
#pragma once

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
~~~~

#### `src/scroll.cpp`

~~~~cpp
#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include <freertos/task.h>

// ---------------------------------------------------------------------------
// Scroll render task  (pinned to Core 1)
// ---------------------------------------------------------------------------

static TaskHandle_t sScrollTaskHandle = nullptr;

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        // consumeLedRenderRequest() returns true when the main task (Core 0)
        // has written a new frame via applyM370 / applyBlankFrame / applyPackedFrame
        // and wants it displayed immediately.  We track this separately from the
        // scroll timer so a non-scroll frame always wins over a coincident scroll step.
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender          = mainTaskRenderPending;
        bool hasScrollFrame        = false;

        lockScroll();
        if (runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused &&
            runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint32_t now = millis();
            if (runtimeState().lastScrollFrameMs == 0) runtimeState().lastScrollFrameMs = now;

            const uint16_t intervalMs = constrain(
                runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;

            if (elapsedMs >= intervalMs) {
                const uint32_t rawSteps = elapsedMs / intervalMs;
                uint32_t steps = rawSteps % runtimeState().scrollFrameCount;
                if (steps == 0) steps = 1;

                runtimeState().scrollFrameIndex  = (runtimeState().scrollFrameIndex + steps) % runtimeState().scrollFrameCount;
                runtimeState().lastScrollFrameMs += rawSteps * intervalMs;
                // Reset the scroll clock after a long suspension so playback
                // resumes smoothly instead of chasing stale elapsed time.
                if (now - runtimeState().lastScrollFrameMs >
                    static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) {
                    runtimeState().lastScrollFrameMs = now;
                }
                memcpy(nextFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
                ++runtimeState().framesAccepted;
                hasScrollFrame = true;
                shouldRender   = true;
            }
        }
        unlockScroll();

        if (hasScrollFrame) {
            // Re-check under frameMutex that:
            //   (a) firmware scroll is still the active source, and
            //   (b) the main task has NOT concurrently written a higher-priority
            //       non-scroll frame (mainTaskRenderPending).
            //
            // If the main task called applyM370/applyBlankFrame between
            // unlockScroll() and here it has already written runtimeFrameBits() and either
            // cleared firmwareScrollActive or set mainTaskRenderPending. In either
            // case we must not overwrite it with the stale scroll snapshot —
            // that would cause exactly one garbage/flash frame on the LEDs.
            lockFrame();
            if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
                memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
            } else {
                // Main task frame takes priority; drop this scroll step silently.
                // shouldRender stays true if mainTaskRenderPending so the
                // main-task frame still gets displayed.
                if (!mainTaskRenderPending) shouldRender = false;
            }
            unlockFrame();
        }

        if (shouldRender) {
            renderCurrentFrameToLedStrip();
        }

        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1));
    }
}

// ---------------------------------------------------------------------------
// Task creation
// ---------------------------------------------------------------------------

void startScrollRenderTask() {
    if (sScrollTaskHandle) return;

    const BaseType_t ok = xTaskCreatePinnedToCore(
        scrollRenderTask,
        "led_scroll_render",
        LED_RENDER_TASK_STACK_BYTES,
        nullptr,
        LED_RENDER_TASK_PRIORITY,
        &sScrollTaskHandle,
        LED_RENDER_TASK_CORE
    );

    if (ok != pdPASS) {
        sScrollTaskHandle = nullptr;
        Serial.println("Failed to start LED scroll render task; firmware scroll unavailable");
    }
}

void notifyScrollRenderTask() {
    if (!sScrollTaskHandle) return;

    if (xPortInIsrContext()) {
        BaseType_t higherPriorityTaskWoken = pdFALSE;
        vTaskNotifyGiveFromISR(sScrollTaskHandle, &higherPriorityTaskWoken);
        portYIELD_FROM_ISR(higherPriorityTaskWoken);
    } else {
        xTaskNotifyGive(sScrollTaskHandle);
    }
}
~~~~

#### `src/scroll.h`

~~~~cpp
#pragma once

// ---------------------------------------------------------------------------
// Firmware scroll render task
// ---------------------------------------------------------------------------

// Create and pin the scroll render task to LED_RENDER_TASK_CORE.
// Safe to call multiple times; only the first call has effect.
void startScrollRenderTask();

// Wake the render task after a frame request; no-op before task creation.
void notifyScrollRenderTask();
~~~~

#### `src/state.cpp`

~~~~cpp
#include "state.h"
#include <esp_heap_caps.h>

static constexpr size_t SCROLL_FRAME_BUFFER_BYTES =
    static_cast<size_t>(MAX_SCROLL_FRAMES) * static_cast<size_t>(FRAME_BYTES);

RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

bool RuntimeStore::initScrollFrameBuffer() {
    if (scrollFrameBits_ != nullptr) return true;

    if (ESP.getPsramSize() > 0) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = scrollFrameBits_ != nullptr;
    }

    if (scrollFrameBits_ == nullptr) {
        Serial.printf("WARN: PSRAM scroll buffer unavailable; using original %u-byte internal SRAM fallback\n",
                      static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
        scrollFrameBits_ = &fallbackScrollFrameBits_[0][0];
        scrollFrameBitsInPsram_ = false;
    }

    memset(scrollFrameBits_, 0, SCROLL_FRAME_BUFFER_BYTES);
    Serial.printf("Scroll buffer ready: %u bytes in %s, psram total=%u free=%u\n",
                  static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES),
                  scrollFrameBitsInPsram_ ? "PSRAM" : "original internal SRAM fallback",
                  static_cast<unsigned>(ESP.getPsramSize()),
                  static_cast<unsigned>(ESP.getFreePsram()));
    return true;
}

uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    const uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

RuntimeState& runtimeState() {
    return RuntimeStore::instance().state();
}

RuntimeFace* runtimeAutoFaces() {
    return RuntimeStore::instance().autoFaces();
}

uint16_t& runtimeAutoFaceCount() {
    return RuntimeStore::instance().autoFaceCount();
}

uint8_t* runtimeFrameBits() {
    return RuntimeStore::instance().frameBits();
}

bool initRuntimeScrollFrameBuffer() {
    return RuntimeStore::instance().initScrollFrameBuffer();
}

bool runtimeScrollFrameBufferReady() {
    return RuntimeStore::instance().scrollFrameBufferReady();
}

bool runtimeScrollFrameBufferInPsram() {
    return RuntimeStore::instance().scrollFrameBufferInPsram();
}

size_t runtimeScrollFrameBufferBytes() {
    return SCROLL_FRAME_BUFFER_BYTES;
}

uint8_t* runtimeScrollFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollFrameBits(index);
}

bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0) runtimeState().stateVersion = 1;
}

void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    if (!state.slowUiDirty) return;
    const uint32_t now = millis();
    if (now - state.lastSlowUiPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
~~~~

#### `src/state.h`

~~~~cpp
#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------
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

    // Stats
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

    // Auto-playback
    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    // Scroll
    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // WebUI notification marker for GPIO B1/B2/B3 interrupting firmware scroll.
    // The frontend polls this lightweight sequence while the 6.4 scroll page is active.
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    // Deferred face restore after an explicit all-off clear frame.
    // Used to avoid delay() inside HTTP / button handlers while still
    // giving the LED render task enough time to physically latch blank.
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};

// ---------------------------------------------------------------------------
// Saved face record (runtime copy of one face from saved_faces.json)
// ---------------------------------------------------------------------------
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// ---------------------------------------------------------------------------
// RuntimeStore
// ---------------------------------------------------------------------------
// Centralizes mutable runtime storage so modules no longer link directly
// against exposed extern globals.  Access is still intentionally lightweight:
// locking policy stays in the caller/helper that owns the operation.
class RuntimeStore final {
public:
    static RuntimeStore& instance();

    RuntimeState& state() { return state_; }
    const RuntimeState& state() const { return state_; }

    RuntimeFace* autoFaces() { return autoFaces_; }
    const RuntimeFace* autoFaces() const { return autoFaces_; }

    uint16_t& autoFaceCount() { return autoFaceCount_; }
    const uint16_t& autoFaceCount() const { return autoFaceCount_; }

    uint8_t* frameBits() { return frameBits_; }
    const uint8_t* frameBits() const { return frameBits_; }

    bool initScrollFrameBuffer();
    bool scrollFrameBufferReady() const { return true; }
    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }
    uint8_t* scrollFrameBits(uint16_t index);
    const uint8_t* scrollFrameBits(uint16_t index) const;

    bool& fsMounted() { return fsMounted_; }
    const bool& fsMounted() const { return fsMounted_; }

private:
    RuntimeStore() = default;
    RuntimeStore(const RuntimeStore&) = delete;
    RuntimeStore& operator=(const RuntimeStore&) = delete;

    RuntimeState state_;
    RuntimeFace  autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t     autoFaceCount_ = 0;
    uint8_t      frameBits_[FRAME_BYTES] = {};
    uint8_t      fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
    uint8_t*     scrollFrameBits_ = nullptr;
    bool         scrollFrameBitsInPsram_ = false;
    bool         fsMounted_ = false;
};

RuntimeState& runtimeState();
RuntimeFace* runtimeAutoFaces();
uint16_t& runtimeAutoFaceCount();
uint8_t* runtimeFrameBits();
bool initRuntimeScrollFrameBuffer();
bool runtimeScrollFrameBufferReady();
bool runtimeScrollFrameBufferInPsram();
size_t runtimeScrollFrameBufferBytes();
uint8_t* runtimeScrollFrameBits(uint16_t index);
bool& runtimeFsMounted();
uint32_t runtimeStateVersion();
void touchRuntimeState();
void touchRuntimeStateSlow();
void serviceRuntimeSlowStatePublish();
~~~~

#### `src/storage.cpp`

~~~~cpp
#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
#include "psram_json.h"
#include <LittleFS.h>

// ---------------------------------------------------------------------------
// Filesystem mount
// ---------------------------------------------------------------------------

bool mountFilesystem() {
    runtimeFsMounted() = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    }
    return runtimeFsMounted();
}

static bool ensureResourcesDirectory() {
    if (!runtimeFsMounted()) return false;
    bool ok = false;
    lockHardwareBus();
    ok = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    unlockHardwareBus();
    return ok;
}

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error) {
    written = 0;
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return false;
    }

    const String tempPath = String(path) + ".tmp";

    lockHardwareBus();
    LittleFS.remove(tempPath);
    File file = LittleFS.open(tempPath, "w");
    unlockHardwareBus();

    if (!file) {
        error = String("failed to open temp file for write: ") + tempPath;
        return false;
    }

    lockHardwareBus();
    written = serializeJson(document, file);
    file.flush();
    file.close();
    const bool renamed = written > 0 && LittleFS.rename(tempPath, path);
    if (!renamed) LittleFS.remove(tempPath);
    unlockHardwareBus();

    if (!renamed) {
        error = String("failed to commit temp file for: ") + path;
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Runtime settings
// ---------------------------------------------------------------------------

bool saveRuntimeSettings() {
    if (!runtimeFsMounted()) return false;
    if (!ensureResourcesDirectory()) {
        Serial.println("Failed to ensure /resources for runtime settings");
        return false;
    }

    DynamicJsonDocument doc(384);
    doc["format"]         = "rina_runtime_settings_v1";
    doc["version"]        = 1;
    doc["mode"]           = runtimeState().mode;
    doc["autoIntervalMs"] = runtimeState().autoIntervalMs;
    doc["updatedAtMs"]    = millis();

    size_t written = 0;
    String error;
    if (!writeJsonFileAtomic(SETTINGS_PATH, doc.as<JsonVariant>(), written, error)) {
        Serial.printf("Failed to write runtime_settings.json: %s\n", error.c_str());
        return false;
    }
    ++runtimeState().settingsWrites;
    touchRuntimeState();
    return true;
}

bool loadRuntimeSettings() {
    if (!runtimeFsMounted()) return false;
    bool settingsExists = false;
    lockHardwareBus();
    settingsExists = LittleFS.exists(SETTINGS_PATH);
    unlockHardwareBus();
    if (!settingsExists) {
        Serial.println("runtime_settings.json not found; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(SETTINGS_PATH, "r");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open runtime_settings.json");
        return false;
    }

    DynamicJsonDocument doc(768);
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(8));
    file.close();
    unlockHardwareBus();
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        return false;
    }

    const char* mode = doc["mode"] | DEFAULT_MODE;
    if (!setMode(mode, false)) setMode(DEFAULT_MODE, false);

    if (doc["autoIntervalMs"].is<uint32_t>()) {
        setAutoInterval(doc["autoIntervalMs"].as<uint32_t>(), false);
    }

    Serial.printf("Runtime settings loaded: mode=%s autoIntervalMs=%lu\n",
                  runtimeState().mode.c_str(),
                  static_cast<unsigned long>(runtimeState().autoIntervalMs));
    return true;
}

// ---------------------------------------------------------------------------
// Saved faces -- validate
// ---------------------------------------------------------------------------

static bool defaultFaceIdNumberIsInvalid(const char* id) {
    if (id == nullptr || strncmp(id, "face_", 5) != 0) return false;
    const char* p = id + 5;
    if (*p < '0' || *p > '9') return false;
    uint32_t value = 0;
    while (*p >= '0' && *p <= '9') {
        value = value * 10 + static_cast<uint32_t>(*p - '0');
        ++p;
    }
    return value < 1;
}

bool validateSavedFaces(JsonVariant document, String& error) {
    const char* category = document["category"] | "";
    if (strcmp(category, "unified_saved_faces") != 0) {
        error = "document.category must be unified_saved_faces";
        return false;
    }

    JsonArray faces = document["faces"].as<JsonArray>();
    if (faces.isNull()) {
        error = "document.faces must be an array";
        return false;
    }

    uint16_t defaultCount = 0;
    for (JsonObject face : faces) {
        const char* type = face["type"] | "";
        const char* id   = face["id"] | "";
        const char* m370 = face["m370"] | "";
        if (!face["order"].is<int32_t>() || face["order"].as<int32_t>() < 1) {
            error = "face order must be 1-based and >= 1";
            return false;
        }
        if (strcmp(type, "default") == 0) {
            ++defaultCount;
            if (defaultFaceIdNumberIsInvalid(id)) {
                error = "default face id numbers must start at 1";
                return false;
            }
        }
        if (strlen(m370) > 0) {
            String normalized, faceError;
            if (!normalizeM370(m370, normalized, faceError)) {
                error = String("invalid face m370: ") + faceError;
                return false;
            }
        }
    }

    if (defaultCount == 0) {
        error = "saved_faces.json must keep at least one type:\"default\" face";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Saved faces -- write
// ---------------------------------------------------------------------------

size_t writeSavedFaces(JsonVariant document, String& error) {
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return 0;
    }
    if (!ensureResourcesDirectory()) {
        error = "failed to ensure /resources for saved_faces.json";
        return 0;
    }

    size_t written = 0;
    if (!writeJsonFileAtomic(SAVED_FACES_PATH, document, written, error)) {
        return 0;
    }
    ++runtimeState().savedFacesWrites;
    touchRuntimeState();
    return written;
}

// ---------------------------------------------------------------------------
// Saved faces -- load into runtimeAutoFaces()[]
// ---------------------------------------------------------------------------

bool ensureSavedFacesLoaded() {
    if (runtimeAutoFaceCount() > 0) return true;
    return loadSavedFaces(false) && runtimeAutoFaceCount() > 0;
}

bool loadSavedFaces(bool applyStartupFace) {
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS not mounted; saved faces cannot be loaded");
        return false;
    }
    bool savedFacesExists = false;
    lockHardwareBus();
    savedFacesExists = LittleFS.exists(SAVED_FACES_PATH);
    unlockHardwareBus();
    if (!savedFacesExists) {
        Serial.println("No saved_faces.json; LED output starts blank");
        runtimeAutoFaceCount() = 0;
        touchRuntimeState();
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open saved_faces.json");
        return false;
    }

    lockHardwareBus();
    const size_t savedFacesSize = file.size();
    unlockHardwareBus();

    PsramJsonDocument doc(jsonCapacityFor(savedFacesSize));
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(32));
    file.close();
    unlockHardwareBus();
    if (err) {
        Serial.printf("saved_faces.json parse failed: %s\n", err.c_str());
        runtimeAutoFaceCount() = 0;
        touchRuntimeState();
        return false;
    }

    const String   startupId        = doc["startupDefaultId"] | "";
    JsonArray      faces            = doc["faces"].as<JsonArray>();
    String         previousFaceId;
    const uint16_t previousFaceIndex = runtimeState().autoFaceIndex;
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        previousFaceId = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
    }
    runtimeAutoFaceCount()   = 0;
    uint16_t jsonIndex = 0;

    for (JsonObject face : faces) {
        const char* m370 = face["m370"] | "";
        String normalized, error;
        if (!normalizeM370(m370, normalized, error)) {
            Serial.printf("Skipping invalid saved face: %s\n", error.c_str());
            ++jsonIndex;
            continue;
        }
        if (runtimeAutoFaceCount() >= MAX_AUTO_FACES) break;

        RuntimeFace& runtime     = runtimeAutoFaces()[runtimeAutoFaceCount()++];
        runtime.id               = String(face["id"] | "");
        runtime.name             = String(face["name"] | runtime.id.c_str());
        runtime.m370             = normalized;
        runtime.order            = face["order"].is<int32_t>()
                                       ? face["order"].as<int32_t>()
                                       : static_cast<int32_t>(jsonIndex) + 1;
        runtime.jsonIndex        = jsonIndex;
        runtime.isDefault        = strcmp(face["type"] | "", "default") == 0;
        runtime.isStartupDefault = face["is_startup_default"].as<bool>() ||
                                   (!startupId.isEmpty() && startupId == runtime.id);
        ++jsonIndex;
    }

    if (runtimeAutoFaceCount() == 0) {
        Serial.println("saved_faces.json has no valid faces");
        return false;
    }

    // Stable-sort by (order, jsonIndex)
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        for (uint16_t j = i + 1; j < runtimeAutoFaceCount(); ++j) {
            const bool shouldSwap =
                runtimeAutoFaces()[j].order < runtimeAutoFaces()[i].order ||
                (runtimeAutoFaces()[j].order == runtimeAutoFaces()[i].order &&
                 runtimeAutoFaces()[j].jsonIndex < runtimeAutoFaces()[i].jsonIndex);
            if (shouldSwap) {
                RuntimeFace tmp = runtimeAutoFaces()[i];
                runtimeAutoFaces()[i]    = runtimeAutoFaces()[j];
                runtimeAutoFaces()[j]    = tmp;
            }
        }
    }

    // Select which face index to use
    int selectedIndex     = -1;
    int firstDefaultIndex = -1;
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        if (runtimeAutoFaces()[i].isDefault && firstDefaultIndex < 0) firstDefaultIndex = i;
        if (selectedIndex < 0) {
            if (!applyStartupFace && !previousFaceId.isEmpty() &&
                previousFaceId == runtimeAutoFaces()[i].id) {
                selectedIndex = i;
            } else if (applyStartupFace &&
                       ((!startupId.isEmpty() && startupId == runtimeAutoFaces()[i].id) ||
                        runtimeAutoFaces()[i].isStartupDefault)) {
                selectedIndex = i;
            }
        }
    }
    if (selectedIndex < 0) {
        selectedIndex = (!applyStartupFace && previousFaceIndex < runtimeAutoFaceCount())
                            ? previousFaceIndex
                            : (firstDefaultIndex >= 0 ? firstDefaultIndex : 0);
    }
    runtimeState().autoFaceIndex = static_cast<uint16_t>(selectedIndex);
    touchRuntimeState();
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", runtimeAutoFaceCount());

    if (applyStartupFace) {
        String error;
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        runtimeState().playback   = DEFAULT_PLAYBACK;
        runtimeState().paused     = false;
        if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        Serial.printf("Loaded startup face index: %u\n", runtimeState().autoFaceIndex);
    }

    return true;
}
~~~~

#### `src/storage.h`

~~~~cpp
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// ---------------------------------------------------------------------------
// LittleFS helpers
// ---------------------------------------------------------------------------

// Mount LittleFS and update the global fsMounted flag.
// Returns true on success.
bool mountFilesystem();

// ---------------------------------------------------------------------------
// Runtime settings  (mode, autoIntervalMs)
// ---------------------------------------------------------------------------
bool loadRuntimeSettings();
bool saveRuntimeSettings();

// Write JSON through a temp file and rename it into place after serialization.
bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

// ---------------------------------------------------------------------------
// Saved faces file  (raw JSON pass-through)
// ---------------------------------------------------------------------------

// Parse, validate, and load saved_faces.json into the autoFaces[] table.
// If applyStartupFace is true the startup-default face is rendered immediately.
bool loadSavedFaces(bool applyStartupFace);

// Validate a parsed saved_faces document before writing.
bool validateSavedFaces(JsonVariant document, String& error);

// Write raw JSON to saved_faces.json, then reload autoFaces[].
// Returns the number of bytes written, or 0 on failure.
size_t writeSavedFaces(JsonVariant document, String& error);

// Ensure autoFaces[] is populated (lazy-loads if needed).
bool ensureSavedFacesLoaded();
~~~~

#### `src/sync.cpp`

~~~~cpp
#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

bool initSyncPrimitives() {
    if (!sFrameMutex) sFrameMutex = xSemaphoreCreateMutex();
    if (!sScrollMutex) sScrollMutex = xSemaphoreCreateMutex();
    if (!sHardwareBusMutex) sHardwareBusMutex = xSemaphoreCreateMutex();
    return sFrameMutex && sScrollMutex && sHardwareBusMutex;
}

void lockFrame() {
    if (sFrameMutex) xSemaphoreTake(sFrameMutex, portMAX_DELAY);
}

void unlockFrame() {
    if (sFrameMutex) xSemaphoreGive(sFrameMutex);
}

void lockScroll() {
    if (sScrollMutex) xSemaphoreTake(sScrollMutex, portMAX_DELAY);
}

void unlockScroll() {
    if (sScrollMutex) xSemaphoreGive(sScrollMutex);
}

void lockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
~~~~

#### `src/sync.h`

~~~~cpp
#pragma once

// ---------------------------------------------------------------------------
// FreeRTOS synchronization helpers
// ---------------------------------------------------------------------------
//
// Lock ordering policy for future nested critical sections:
//   HardwareBus -> Frame -> Scroll
//
// Current render paths intentionally avoid holding more than one of these
// mutexes at a time.  If a future change must nest them, always acquire in the
// order above and release in reverse order.

bool initSyncPrimitives();

void lockFrame();
void unlockFrame();
void lockScroll();
void unlockScroll();
void lockHardwareBus();
void unlockHardwareBus();

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
~~~~

#### `src/utils.cpp`

~~~~cpp
#include "utils.h"

int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();
    if (value.startsWith("#")) value = value.substring(1);
    if (value.length() != 6) return false;
    for (size_t i = 0; i < 6; ++i) {
        if (hexNibble(value.charAt(i)) < 0) return false;
    }
    value.toLowerCase();
    r = static_cast<uint8_t>(strtoul(value.substring(0, 2).c_str(), nullptr, 16));
    g = static_cast<uint8_t>(strtoul(value.substring(2, 4).c_str(), nullptr, 16));
    b = static_cast<uint8_t>(strtoul(value.substring(4, 6).c_str(), nullptr, 16));
    return true;
}

String formatColorHex(uint8_t r, uint8_t g, uint8_t b) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    return String(buf);
}
~~~~

#### `src/utils.h`

~~~~cpp
#pragma once
#include <Arduino.h>

// Returns the numeric value of a single hex character, or -1 if invalid.
int hexNibble(char c);

// JSON document capacity heuristic: allocates at least 32 KB or 2× source size.
size_t jsonCapacityFor(size_t sourceBytes);

// Parse and validate a 6-digit hex color string ("#RRGGBB" or "RRGGBB").
// On success writes r/g/b components and returns true.
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

// Format RGB components as a lowercase "#rrggbb" string.
String formatColorHex(uint8_t r, uint8_t g, uint8_t b);
~~~~

#### `src/web_api.cpp`

~~~~cpp
#include "web_api.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include "power_monitor.h"
#include "web_json.h"
#include "psram_json.h"
#include <DNSServer.h>
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <pgmspace.h>
#include <stdlib.h>

static WebServer server(HTTP_PORT);
static DNSServer dnsServer;
static bool dnsServerActive = false;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static const char CONTENT_TYPE_JSON_UTF8[] = "application/json; charset=utf-8";
static const char CONTENT_TYPE_HTML_UTF8[] = "text/html; charset=utf-8";
static const char CONTENT_TYPE_TEXT_PLAIN[] = "text/plain";
static const uint16_t STATIC_STREAM_CHUNK_BYTES = 8192;
static const TickType_t WEB_YIELD_TICKS = pdMS_TO_TICKS(1);
// Yield to the scheduler/watchdog roughly every this many chunks instead of after
// every chunk, so streaming large assets is not throttled by a per-chunk delay.
static const size_t WEB_YIELD_EVERY_CHUNKS = 4;

static const char* contentTypeFor(const String& path) {
    const int dotIdx = path.lastIndexOf('.');
    if (dotIdx < 0 || dotIdx == static_cast<int>(path.length()) - 1) {
        return "application/octet-stream";
    }

    String ext = path.substring(dotIdx + 1);
    ext.toLowerCase();

    if (ext == "html") return CONTENT_TYPE_HTML_UTF8;
    if (ext == "css") return "text/css; charset=utf-8";
    if (ext == "js") return "application/javascript; charset=utf-8";
    if (ext == "json") return CONTENT_TYPE_JSON_UTF8;
    if (ext == "svg") return "image/svg+xml";
    if (ext == "png") return "image/png";
    if (ext == "jpg" || ext == "jpeg") return "image/jpeg";
    if (ext == "ico") return "image/x-icon";
    if (ext == "ttf") return "font/ttf";
    if (ext == "woff2") return "font/woff2";
    if (ext == "otf") return "font/otf";
    return "application/octet-stream";
}

static void addCorsHeaders() {
    server.sendHeader("Access-Control-Allow-Origin",  "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    server.sendHeader("Cache-Control",                "no-store");
}

// Cache policy for static assets served from LittleFS. Unlike API responses
// (which must never cache), the browser is allowed to cache these: HTML uses
// revalidation so firmware/UI updates are always picked up, while the
// version-stamped fonts/images/etc. are treated as immutable and fetched once.
static void addStaticAssetHeaders(const String& path) {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    if (path.endsWith(".html") || path.endsWith(".htm")) {
        server.sendHeader("Cache-Control", "no-cache");
    } else {
        server.sendHeader("Cache-Control", "public, max-age=31536000, immutable");
    }
}

static bool littleFsExistsLocked(const String& path) {
    bool exists = false;
    lockHardwareBus();
    exists = LittleFS.exists(path);
    unlockHardwareBus();
    return exists;
}

static File littleFsOpenLocked(const String& path, const char* mode) {
    lockHardwareBus();
    File file = LittleFS.open(path, mode);
    unlockHardwareBus();
    return file;
}

static size_t fileSizeLocked(File& file) {
    lockHardwareBus();
    const size_t size = file.size();
    unlockHardwareBus();
    return size;
}

static void closeFileLocked(File& file) {
    lockHardwareBus();
    file.close();
    unlockHardwareBus();
}

static void streamFileChunked(File& file, const char* contentType) {
    server.setContentLength(fileSizeLocked(file));
    server.send(200, contentType, "");

    // Use an 8KB heap buffer (too large for the limited task stack). If the heap
    // allocation fails, fall back to a small stack buffer so transfers still work.
    uint8_t* heapBuffer = static_cast<uint8_t*>(malloc(STATIC_STREAM_CHUNK_BYTES));
    uint8_t  stackFallback[512];
    uint8_t* buffer    = heapBuffer ? heapBuffer : stackFallback;
    const size_t chunkBytes = heapBuffer ? STATIC_STREAM_CHUNK_BYTES : sizeof(stackFallback);

    size_t chunksSent = 0;
    while (true) {
        size_t bytesRead = 0;
        bool hasData = false;

        lockHardwareBus();
        hasData = file.available();
        if (hasData) {
            bytesRead = file.read(buffer, chunkBytes);
        }
        unlockHardwareBus();

        if (!hasData || bytesRead == 0) break;
        server.sendContent(reinterpret_cast<const char*>(buffer), bytesRead);
        // Feed the watchdog periodically rather than after every chunk.
        if ((++chunksSent % WEB_YIELD_EVERY_CHUNKS) == 0) vTaskDelay(WEB_YIELD_TICKS);
    }

    if (heapBuffer) free(heapBuffer);
}

static void sendJsonDocument(int status, JsonDocument& doc) {
    String out;
    serializeJson(doc, out);
    addCorsHeaders();
    server.send(status, CONTENT_TYPE_JSON_UTF8, out);
}

static void sendError(int status, const String& message) {
    DynamicJsonDocument doc(512);
    doc["ok"]    = false;
    doc["error"] = message;
    addCorsHeaders();
    String out;
    serializeJson(doc, out);
    server.send(status, CONTENT_TYPE_JSON_UTF8, out);
}

static uint16_t statusNextPollMs(bool scrolling, bool summaryOnly, bool unchanged) {
    if (runtimeState().deferredFaceRestoreActive) return 250;
    if (scrolling) return summaryOnly ? 250 : 1000;
    return unchanged ? 1000 : 1000;
}

static void addPowerStatus(JsonObject power, bool includeSlow = true, bool clearDirty = false) {
    const bool batteryOk = powerStatus.batteryValid;
    const bool chargeOk = powerStatus.chargeValid;
    const bool chargerPresent = chargeOk && powerStatus.charging;
    const bool batteryUnpowered = !chargerPresent &&
        (powerStatus.batteryDisconnected || powerStatus.batteryLowVoltageUnpowered);
    const bool batteryPowered = batteryOk && !batteryUnpowered;
    const char* batteryIconClass = "status-dot dim";
    const char* batteryIconColor = "#9aa6b2";
    const char* batteryStateText = batteryPowered ? "电池" : "未上电";
    if (batteryPowered) {
        if (powerStatus.batteryPercent < 10) {
            batteryIconClass = "status-dot danger";
            batteryIconColor = "#ef4444";
        } else if (powerStatus.batteryPercent < 30) {
            batteryIconClass = "status-dot warn";
            batteryIconColor = "#f59e0b";
        } else {
            batteryIconClass = "status-dot";
            batteryIconColor = "#59d98e";
        }
    }

    const char* chargeIconClass = chargerPresent ? "status-dot" : "status-dot dim";
    const char* chargeIconColor = chargerPresent ? "#59d98e" : "#9aa6b2";

    power["partial"]         = !includeSlow;
    power["chargeGpio"]      = CHARGE_ADC_PIN;
    if (powerStatus.chargeValid)  power["charging"]       = powerStatus.charging;
    else                          power["charging"]       = nullptr;
    power["chargeValid"]      = powerStatus.chargeValid;
    power["chargeIconClass"]  = chargeIconClass;
    power["chargeIconColor"]  = chargeIconColor;
    power["ok"]               = powerStatus.batteryValid || powerStatus.chargeValid;
    power["chargeSampleMs"]   = CHARGE_SAMPLE_MS;
    power["slowPublishMs"]    = POWER_WEB_SLOW_PUBLISH_MS;
    power["batteryPowered"]   = batteryPowered;
    power["batteryDisconnected"] = powerStatus.batteryDisconnected;
    power["batteryLowVoltageUnpowered"] = powerStatus.batteryLowVoltageUnpowered;
    power["batteryStateText"] = batteryStateText;
    power["batteryIconClass"] = batteryIconClass;
    power["batteryIconColor"] = batteryIconColor;

    if (includeSlow) {
        power["batteryGpio"]      = BATTERY_ADC_PIN;
        if (powerStatus.batteryValid) power["vbat"]           = powerStatus.vbat;
        else                          power["vbat"]           = nullptr;
        if (powerStatus.batteryValid) power["batteryPercent"] = powerStatus.batteryPercent;
        else                          power["batteryPercent"] = nullptr;
        if (powerStatus.chargeValid)  power["vcharge"]        = powerStatus.vcharge;
        else                          power["vcharge"]        = nullptr;
        power["batteryAdcMv"]     = powerStatus.batteryAdcMv;
        power["batteryPrevAdcMv"] = powerStatus.batteryPrevAdcMv;
        power["batteryDisconnectDropMv"] = powerStatus.batteryDisconnectDropMv;
        power["batteryDisconnectDropThresholdMv"] = BATTERY_DISCONNECT_ADC_DROP_MV;
        power["batteryDisconnectLowThresholdMv"]  = BATTERY_DISCONNECT_ADC_LOW_MV;
        power["batteryReconnectThresholdMv"]      = BATTERY_RECONNECT_ADC_MV;
        power["batteryUnpoweredLowThreshold"] = BATTERY_UNPOWERED_LOW_V;
        if (isfinite(powerStatus.batteryLastInstantVbat)) power["batteryLastInstantVbat"] = powerStatus.batteryLastInstantVbat;
        else power["batteryLastInstantVbat"] = nullptr;
        power["batteryDisconnectedSinceMs"] = powerStatus.batteryDisconnectedSinceMs;
        power["lastBatteryDisconnectEventMs"] = powerStatus.lastBatteryDisconnectEventMs;
        power["chargeAdcMv"]      = powerStatus.chargeAdcMv;
        power["batteryValid"]     = powerStatus.batteryValid;
        power["batteryRangeMin"]  = powerStatus.batteryCalibMinV;
        power["batteryRangeMax"]  = powerStatus.batteryCalibMaxV;
        power["batteryNominalMin"] = BATTERY_EMPTY_V;
        power["batteryNominalMax"] = BATTERY_FULL_V;
        power["batteryCalibLoaded"] = powerStatus.batteryCalibLoaded;
        power["batteryCalibDirty"] = powerStatus.batteryCalibDirty;
        power["batteryCalibPath"] = BATTERY_CALIB_PATH;
        power["chargeThreshold"]  = CHARGE_PRESENT_V;
        power["batterySampleMs"]  = BATTERY_SAMPLE_MS;
        power["lastBatteryMs"]    = powerStatus.lastBatteryMs;
        power["lastChargeMs"]     = powerStatus.lastChargeMs;
        power["lastCalibMaxMs"]   = powerStatus.lastCalibMaxMs;
        power["lastCalibMinMs"]   = powerStatus.lastCalibMinMs;
    }

    if (clearDirty) {
        powerStatus.webFastDirty = false;
        if (includeSlow) powerStatus.webSlowDirty = false;
    }
}

static String requestBody() {
    return server.hasArg("plain") ? server.arg("plain") : "";
}

static bool parseJsonBody(JsonDocument& doc, String& error) {
    const String body = requestBody();
    if (body.isEmpty()) { error = "empty JSON body"; return false; }
    DeserializationError err = deserializeJson(doc, body);
    if (err) { error = String("invalid JSON: ") + err.c_str(); return false; }
    return true;
}

static void pauseFirmwareScrollIfActive(bool& changed) {
    withScrollLock([&]() {
        if (runtimeState().firmwareScrollActive) {
            runtimeState().firmwareScrollPaused = true;
            runtimeState().paused               = true;
            runtimeState().playback             = "scroll_paused";
            changed                    = true;
        }
    });
    if (changed) touchRuntimeState();
}

static void resumeFirmwareScrollIfCached(bool& changed, bool requirePaused = false) {
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && (!requirePaused || runtimeState().firmwareScrollPaused)) {
            runtimeState().firmwareScrollActive  = true;
            runtimeState().firmwareScrollPaused  = false;
            runtimeState().lastScrollFrameMs     = millis();
            runtimeState().paused                = false;
            runtimeState().playback              = "scroll";
            changed                     = true;
        }
    });
    if (changed) touchRuntimeState();
}

static bool serveStaticFile(String path) {
    if (!runtimeFsMounted()) return false;
    if (path == "/") path = "/index.html";
    if (path.endsWith("/")) path += "index.html";

    // Prefer a precompressed ".gz" sibling when the client accepts gzip. This both
    // shrinks the transfer and cuts the number of streamed chunks dramatically.
    // Fall back to the raw file for non-gzip clients; if only the .gz exists we
    // still serve it (every browser that reaches this WebUI supports gzip).
    const bool clientAcceptsGzip = server.hasHeader("Accept-Encoding") &&
        server.header("Accept-Encoding").indexOf("gzip") >= 0;
    const String gzPath   = path + ".gz";
    const bool   gzExists  = littleFsExistsLocked(gzPath);
    const bool   rawExists = littleFsExistsLocked(path);
    if (!gzExists && !rawExists) return false;

    const bool   useGzip  = gzExists && (clientAcceptsGzip || !rawExists);
    const String diskPath = useGzip ? gzPath : path;

    File file = littleFsOpenLocked(diskPath, "r");
    if (!file) return false;

    addStaticAssetHeaders(path);
    if (useGzip) {
        server.sendHeader("Content-Encoding", "gzip");
        server.sendHeader("Vary",             "Accept-Encoding");
    }
    streamFileChunked(file, contentTypeFor(path));
    closeFileLocked(file);
    return true;
}

static const char FILESYSTEM_ERROR_HTML[] PROGMEM = R"rawliteral(<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LittleFS not mounted</title><style>body{margin:0;padding:28px;background:#0f1117;color:#f4f7fb;font-family:system-ui,-apple-system,Segoe UI,sans-serif;line-height:1.5}code{background:#1e2430;padding:2px 5px;border-radius:5px}.box{max-width:720px;margin:auto;border:1px solid #2b3344;border-radius:12px;padding:20px;background:#161a24}</style></head><body><main class="box"><h1>LittleFS data is not mounted</h1><p>The ESP32-S3 AP is running, but the WebUI files are missing or the filesystem failed to mount.</p><p>Upload the data image, then reboot:</p><p><code>pio run -t uploadfs</code></p><p>Expected files include <code>/index.html</code> and <code>/resources/saved_faces.json</code>.</p></main></body></html>)rawliteral";

static void sendFilesystemErrorPage() {
    addCorsHeaders();
    server.send_P(503, CONTENT_TYPE_HTML_UTF8, FILESYSTEM_ERROR_HTML);
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

static void handleOptions() {
    addCorsHeaders();
    server.send(204, CONTENT_TYPE_TEXT_PLAIN, "");
}

static void handleApiStatus() {
    servicePowerMonitor();

    bool     firmwareScrollActive   = false;
    bool     firmwareScrollPaused   = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount       = 0;
    uint16_t scrollFrameIndex       = 0;
    uint16_t scrollIntervalMs       = DEFAULT_SCROLL_INTERVAL_MS;

    withScrollLock([&]() {
        firmwareScrollActive   = runtimeState().firmwareScrollActive;
        firmwareScrollPaused   = runtimeState().firmwareScrollPaused;
        restoreAutoAfterScroll = runtimeState().restoreAutoAfterScroll;
        scrollFrameCount       = runtimeState().scrollFrameCount;
        scrollFrameIndex       = runtimeState().scrollFrameIndex;
        scrollIntervalMs       = runtimeState().scrollIntervalMs;
    });

    const bool scrolling   = firmwareScrollActive || firmwareScrollPaused;
    const bool runtimeOnly = server.hasArg("runtimeOnly");
    const bool summaryOnly = runtimeOnly || server.hasArg("summary") || server.hasArg("noFrame");
    const uint32_t version = runtimeStateVersion();
    const bool hasSince = server.hasArg("since");
    const bool includeSlowPower = !hasSince || powerStatus.webSlowDirty || server.hasArg("fullPower");

    if (hasSince) {
        const uint32_t since = static_cast<uint32_t>(strtoul(server.arg("since").c_str(), nullptr, 10));
        if (since == version) {
            DynamicJsonDocument unchanged(192);
            unchanged["ok"]           = true;
            unchanged["v"]            = version;
            unchanged["version"]      = version;
            unchanged["unchanged"]    = true;
            unchanged["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly, true);
            sendJsonDocument(200, unchanged);
            return;
        }
    }

    PsramJsonDocument doc((runtimeOnly || scrolling || summaryOnly) ? 4096 : 6144);
    doc["ok"]     = true;
    doc["v"]      = version;
    doc["version"] = version;
    doc["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly, false);
    doc["device"] = "RinaChanBoard";
    doc["uptimeMs"] = millis() - runtimeState().bootMs;
    if (runtimeOnly) doc["runtimeOnly"] = true;

    JsonObject ap = doc.createNestedObject("ap");
    ap["ssid"]    = AP_SSID;
    ap["ip"]      = WiFi.softAPIP().toString();
    ap["domain"]  = AP_DOMAIN;
    ap["url"]     = String("http://") + AP_DOMAIN + "/";
    ap["clients"] = WiFi.softAPgetStationNum();

    addPowerStatus(doc.createNestedObject("power"), includeSlowPower, true);

    JsonObject renderer = doc.createNestedObject("renderer");
    renderer["color"]                   = runtimeState().colorHex;
    renderer["brightness"]              = runtimeState().brightness;
    renderer["brightnessMin"]           = MIN_BRIGHTNESS;
    renderer["brightnessMax"]           = MAX_BRIGHTNESS;
    renderer["mode"]                    = runtimeState().mode;
    renderer["playback"]                = runtimeState().playback;
    renderer["paused"]                  = runtimeState().paused;
    renderer["autoIntervalMs"]          = runtimeState().autoIntervalMs;
    renderer["autoFaceCount"]           = runtimeAutoFaceCount();
    renderer["autoFaceIndex"]           = runtimeState().autoFaceIndex;
    renderer["firmwareScrollActive"]    = firmwareScrollActive;
    renderer["firmwareScrollPaused"]    = firmwareScrollPaused;
    renderer["restoreAutoAfterScroll"]  = restoreAutoAfterScroll;
    renderer["deferredFaceRestoreActive"] = runtimeState().deferredFaceRestoreActive;
    renderer["scrollFrameCount"]        = scrollFrameCount;
    renderer["scrollFrameIndex"]        = scrollFrameIndex;
    renderer["scrollIntervalMs"]        = scrollIntervalMs;
    renderer["scrollMaxFrames"]         = MAX_SCROLL_FRAMES;
    renderer["m370FrameMinIntervalMs"]  = M370_FRAME_MIN_INTERVAL_MS;
    renderer["m370FrameQueueDepth"]     = M370_FRAME_QUEUE_DEPTH;
    renderer["m370FrameQueueCount"]     = queuedM370FrameCount();
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        renderer["autoFaceId"]   = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
        renderer["autoFaceName"] = runtimeAutoFaces()[runtimeState().autoFaceIndex].name;
    }
    if (!scrolling && !summaryOnly) {
        renderer["lastM370"] = runtimeState().lastM370;
        renderer["lit"]      = countLitLeds();
    } else if (summaryOnly) {
        renderer["lastM370Skipped"] = true;
    } else {
        renderer["lastM370Deferred"] = true;
    }
    renderer["lastReason"] = runtimeState().lastReason;

    JsonObject scrollStopEvent = renderer.createNestedObject("scrollStopEvent");
    scrollStopEvent["seq"]    = runtimeState().scrollStopEventSeq;
    scrollStopEvent["ms"]     = runtimeState().scrollStopEventMs;
    scrollStopEvent["button"] = runtimeState().scrollStopEventButton;
    scrollStopEvent["source"] = runtimeState().scrollStopEventSource;
    scrollStopEvent["reason"] = runtimeState().scrollStopEventReason;

    JsonObject memory = doc.createNestedObject("memory");
    memory["freeHeap"]               = static_cast<uint32_t>(ESP.getFreeHeap());
    memory["psramSize"]              = static_cast<uint32_t>(ESP.getPsramSize());
    memory["freePsram"]              = static_cast<uint32_t>(ESP.getFreePsram());
    memory["scrollBufferBytes"]      = static_cast<uint32_t>(runtimeScrollFrameBufferBytes());
    memory["scrollBufferReady"]      = runtimeScrollFrameBufferReady();
    memory["scrollBufferInPsram"]    = runtimeScrollFrameBufferInPsram();

    // runtimeOnly=1&noFrame=1 is the lightweight polling/summary path: return
    // immediately after runtime state so a caller can read current firmware
    // color/brightness/power/mode without paying for matrix, storage, statistics,
    // or last-frame serialization. (The WebUI *boot* path now requests the full
    // status instead, so the first LED frame is included and the basic matrix
    // preview is populated during the loading animation — see
    // preloadFirmwareRuntimeState() in data/index.html.)
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
    storage["mounted"]           = runtimeFsMounted();
    storage["savedFacesPath"]    = SAVED_FACES_PATH;
    storage["savedFacesExists"]  = runtimeFsMounted() && littleFsExistsLocked(SAVED_FACES_PATH);
    storage["settingsPath"]      = SETTINGS_PATH;
    storage["settingsExists"]    = runtimeFsMounted() && littleFsExistsLocked(SETTINGS_PATH);
    if (runtimeFsMounted() && !scrolling && !summaryOnly) {
        lockHardwareBus();
        storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
        storage["usedBytes"]  = static_cast<uint32_t>(LittleFS.usedBytes());
        unlockHardwareBus();
    } else if (summaryOnly) {
        storage["capacitySkippedInSummary"] = true;
    } else if (scrolling) {
        storage["capacityDeferredDuringScroll"] = true;
    }

    JsonObject stats = doc.createNestedObject("stats");
    stats["framesAccepted"]    = runtimeState().framesAccepted;
    stats["framesRejected"]    = runtimeState().framesRejected;
    stats["framesQueued"]      = runtimeState().framesQueued;
    stats["framesDequeued"]    = runtimeState().framesDequeued;
    stats["framesDropped"]     = runtimeState().framesDropped;
    stats["commandsAccepted"]  = runtimeState().commandsAccepted;
    stats["commandsRejected"]  = runtimeState().commandsRejected;
    stats["savedFacesWrites"]  = runtimeState().savedFacesWrites;
    stats["settingsWrites"]    = runtimeState().settingsWrites;

    sendJsonDocument(200, doc);
}

static void handleApiPower() {
    servicePowerMonitor();

    DynamicJsonDocument doc(3072);
    doc["ok"] = true;
    addPowerStatus(doc.createNestedObject("power"), true, true);
    sendJsonDocument(200, doc);
}

static void handleApiFrame() {
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) { sendError(400, error); return; }

    const char* m370 = doc["m370"] | "";
    if (strlen(m370) == 0) {
        ++runtimeState().framesRejected;
        sendError(400, "missing m370");
        return;
    }

    const char* mode = doc["mode"] | "";
    if (strlen(mode) == 0) mode = doc["playback"] | "idle";
    const String reason = doc["reason"] | "api_frame";

    if (!isScrollPlayback(String(mode))) {
        stopFirmwareScroll(false);
    }
    if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
        setMode("manual", false);
    }
    runtimeState().playback = mode;

    if (!applyM370(m370, reason, error)) { sendError(400, error); return; }

    // If the WebUI sent a faceId, find the matching saved face and update
    // autoFaceIndex so that B1/B2 navigation continues from the correct face.
    const char* faceId = doc["faceId"] | "";
    if (strlen(faceId) > 0 && ensureSavedFacesLoaded()) {
        for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
            if (runtimeAutoFaces()[i].id == faceId) {
                if (runtimeState().autoFaceIndex != i) {
                    runtimeState().autoFaceIndex = i;
                    touchRuntimeState();
                }
                break;
            }
        }
    }

    DynamicJsonDocument reply(1024);
    reply["ok"]            = true;
    reply["v"]             = runtimeStateVersion();
    reply["version"]       = runtimeStateVersion();
    reply["next_poll_ms"]  = statusNextPollMs(false, false, false);
    reply["accepted"]      = true;
    reply["queued"]        = queuedM370FrameCount() > 0;
    reply["queueDepth"]    = M370_FRAME_QUEUE_DEPTH;
    reply["queueCount"]    = queuedM370FrameCount();
    reply["frameMinIntervalMs"] = M370_FRAME_MIN_INTERVAL_MS;
    reply["leds"]          = LED_COUNT;
    reply["color"]         = runtimeState().colorHex;
    reply["brightness"]    = runtimeState().brightness;
    reply["reason"]        = runtimeState().lastReason;
    reply["mode"]          = runtimeState().mode;
    reply["autoIntervalMs"] = runtimeState().autoIntervalMs;
    reply["autoFaceIndex"] = runtimeState().autoFaceIndex;
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        reply["autoFaceId"]   = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
        reply["autoFaceName"] = runtimeAutoFaces()[runtimeState().autoFaceIndex].name;
    }
    reply["m370"]          = runtimeState().lastM370;
    reply["lit"]           = countLitLeds();
    sendJsonDocument(200, reply);
}

static void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    uint16_t intervalMs = runtimeState().scrollIntervalMs;
    bool     hasExplicitTiming = false;
    uint32_t intervalValue = 0;
    if (jsonUintField(body, "intervalMs", intervalValue) && intervalValue > 0) {
        intervalMs = static_cast<uint16_t>(intervalValue > 65535UL ? 65535UL : intervalValue);
        hasExplicitTiming = true;
    } else {
        float fps = 0.0f;
        if (jsonFloatField(body, "fps", fps) && fps > 0.0f) {
            intervalMs = static_cast<uint16_t>(roundf(1000.0f / fps));
            hasExplicitTiming = true;
        }
    }

    // Long text scroll uploads are sent in small RAM-only chunks by the WebUI.
    // append=false clears the previous RAM timeline; append=true adds frames.
    // The final chunk sets start=true.
    const bool shouldStart = jsonBoolField(body, "start", true);
    const bool appendFrames = jsonBoolField(body, "append", false);
    const bool persist = jsonBoolField(body, "persist", false);
    const bool saveToFlash = jsonBoolField(body, "saveToFlash", false);
    uint32_t chunkIndex = 0;
    uint32_t totalFrames = 0;
    jsonUintField(body, "chunkIndex", chunkIndex);
    jsonUintField(body, "totalFrames", totalFrames);
    String source;
    String storageTarget;
    jsonStringField(body, "source", source);
    jsonStringField(body, "storage", storageTarget);
    storageTarget.toLowerCase();
    if (persist || saveToFlash || (!storageTarget.isEmpty() && storageTarget != "ram")) {
        sendError(400, "scroll uploads are RAM-only; persist/saveToFlash/storage flash is unsupported");
        return;
    }

    // --- Parse frames array ---
    const int framesKey = body.indexOf("\"frames\"");
    if (framesKey < 0) { sendError(400, "frames must be an array"); return; }
    const int arrayStart = body.indexOf('[', framesKey);
    if (arrayStart < 0) { sendError(400, "frames must be an array"); return; }
    size_t pos = static_cast<size_t>(arrayStart + 1);

    uint16_t baseIndex = 0;
    if (!appendFrames) {
        stopFirmwareScroll(false);
        withScrollLock([]() {
            runtimeState().scrollFrameCount = 0;
            runtimeState().scrollFrameIndex = 0;
        });
    } else {
        withScrollLock([&]() {
            baseIndex = runtimeState().scrollFrameCount;
        });
    }

    uint16_t count = 0;
    String   error;
    while (pos < body.length()) {
        while (pos < body.length()) {
            const char c = body.charAt(pos);
            if (c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == ',') { ++pos; continue; }
            break;
        }
        if (pos >= body.length()) { sendError(400, "unterminated frames array"); return; }
        if (body.charAt(pos) == ']') break;
        if (body.charAt(pos) != '"') {
            sendError(400, String("expected M370 string at frame ") + count); return;
        }

        int endQuote = -1;
        String m370;
        if (!extractJsonStringAt(body, pos, m370, endQuote)) {
            sendError(400, String("unterminated M370 string at frame ") + count); return;
        }

        const uint32_t targetIndex = static_cast<uint32_t>(baseIndex) + count;
        if (targetIndex >= MAX_SCROLL_FRAMES) {
            sendError(413, String("too many scroll frames; firmware cache max is ") + MAX_SCROLL_FRAMES);
            return;
        }
        if (!m370ToPackedBits(m370, runtimeScrollFrameBits(targetIndex), error)) {
            sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
            withScrollLock([]() { runtimeState().scrollFrameCount = 0; });
            return;
        }
        ++count;
        pos = static_cast<size_t>(endQuote + 1);
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame"); return;
    }

    withScrollLock([&]() {
        runtimeState().scrollFrameCount = baseIndex + count;
        runtimeState().scrollFrameIndex = 0;
        if (hasExplicitTiming) {
            runtimeState().scrollIntervalMs = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        }
    });

    if (shouldStart) startFirmwareScroll(intervalMs);

    DynamicJsonDocument reply(768);
    reply["ok"]                   = true;
    reply["frames"]               = runtimeState().scrollFrameCount;
    reply["chunkFrames"]          = count;
    reply["chunkIndex"]           = chunkIndex;
    reply["totalFrames"]          = totalFrames;
    reply["append"]               = appendFrames;
    reply["started"]              = runtimeState().firmwareScrollActive;
    reply["source"]               = source;
    reply["storage"]              = "ram";
    reply["persist"]              = false;
    reply["saveToFlash"]          = false;
    reply["mode"]                 = runtimeState().mode;
    reply["playback"]             = runtimeState().playback;
    reply["restoreAutoAfterScroll"] = runtimeState().restoreAutoAfterScroll;
    reply["scrollIntervalMs"]     = runtimeState().scrollIntervalMs;
    reply["scrollMaxFrames"]      = MAX_SCROLL_FRAMES;
    reply["stepLedPerFrame"]      = 1;
    sendJsonDocument(200, reply);
}


using ApiCommandHandler = bool (*)(JsonDocument& doc, JsonVariant payload, String& error);

static bool commandSetColor(JsonDocument& doc, JsonVariant payload, String& error) {
    const char* hex = payload["hex"] | "";
    if (strlen(hex) == 0) hex = doc["hex"] | "";
    return setColor(hex, error);
}

static bool commandSetBrightness(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    int raw = runtimeState().brightness;
    if      (payload["raw"].is<int>())        raw = payload["raw"].as<int>();
    else if (payload["brightness"].is<int>()) raw = payload["brightness"].as<int>();
    else if (doc["raw"].is<int>())            raw = doc["raw"].as<int>();
    setBrightness(raw);
    return true;
}

static bool commandSetMode(JsonDocument& doc, JsonVariant payload, String& error) {
    cancelDeferredFaceRestore();
    const char* mode = payload["mode"] | "";
    if (strlen(mode) == 0) mode = doc["mode"] | "";
    if (strlen(mode) == 0 || !setMode(mode)) {
        error = "invalid mode";
        return false;
    }
    return true;
}

static bool commandSetAutoInterval(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint32_t ms = runtimeState().autoIntervalMs;
    if      (payload["ms"].is<uint32_t>()) ms = payload["ms"].as<uint32_t>();
    else if (doc["ms"].is<uint32_t>())     ms = doc["ms"].as<uint32_t>();
    setAutoInterval(ms);
    return true;
}

static bool scrollIntervalFromCommand(JsonDocument& doc, JsonVariant payload, uint16_t& intervalMs) {
    uint32_t rawInterval = 0;
    if (payload["intervalMs"].is<uint32_t>()) {
        rawInterval = payload["intervalMs"].as<uint32_t>();
    } else if (doc["intervalMs"].is<uint32_t>()) {
        rawInterval = doc["intervalMs"].as<uint32_t>();
    }

    if (rawInterval > 0) {
        intervalMs = static_cast<uint16_t>(rawInterval > 65535UL ? 65535UL : rawInterval);
        return true;
    }

    float fps = 0.0f;
    if (payload["fps"].is<float>() || payload["fps"].is<int>()) {
        fps = payload["fps"].as<float>();
    } else if (doc["fps"].is<float>() || doc["fps"].is<int>()) {
        fps = doc["fps"].as<float>();
    }

    if (fps > 0.0f) {
        intervalMs = static_cast<uint16_t>(roundf(1000.0f / fps));
        return true;
    }

    return false;
}

static bool commandSetScrollInterval(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint16_t iMs = runtimeState().scrollIntervalMs;
    scrollIntervalFromCommand(doc, payload, iMs);
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
    return true;
}

static bool commandStartScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    uint16_t iMs = runtimeState().scrollIntervalMs;
    scrollIntervalFromCommand(doc, payload, iMs);
    bool hasCachedFrames = false;
    withScrollLock([&]() {
        hasCachedFrames = runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady();
    });
    if (!hasCachedFrames) {
        error = "no cached scroll frames";
        return false;
    }
    startFirmwareScroll(iMs);
    return true;
}

static bool commandScrollStep(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    uint8_t steppedFrame[FRAME_BYTES];
    bool    hasSteppedFrame = false;
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().scrollFrameIndex = (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;
            runtimeState().playback         = "scroll_step";
            memcpy(steppedFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });
    if (hasSteppedFrame) applyPackedFrame(steppedFrame, "firmware_text_scroll_step");
    return true;
}

static bool commandPauseScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    pauseFirmwareScrollIfActive(ignored);
    return true;
}

static bool commandResumeScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    resumeFirmwareScrollIfCached(ignored);
    return true;
}

static bool commandStopScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    bool clearDisplay = true;
    bool restoreAuto  = true;
    if (payload["clear"].is<bool>())         clearDisplay = payload["clear"].as<bool>();
    else if (doc["clear"].is<bool>())        clearDisplay = doc["clear"].as<bool>();
    if (payload["restoreAuto"].is<bool>())   restoreAuto  = payload["restoreAuto"].as<bool>();
    else if (doc["restoreAuto"].is<bool>())  restoreAuto  = doc["restoreAuto"].as<bool>();
    stopFirmwareScroll(restoreAuto, clearDisplay);
    return true;
}

static bool commandPause(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool pausedScroll = false;
    pauseFirmwareScrollIfActive(pausedScroll);
    if (!pausedScroll) {
        runtimeState().paused   = true;
        runtimeState().playback = "paused";
        touchRuntimeState();
    }
    return true;
}

static bool commandResume(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool resumedScroll = false;
    resumeFirmwareScrollIfCached(resumedScroll, true);
    if (!resumedScroll) {
        runtimeState().paused   = false;
        runtimeState().playback = DEFAULT_PLAYBACK;
        touchRuntimeState();
    }
    return true;
}

static bool commandButton(JsonDocument& doc, JsonVariant payload, String& error) {
    const char* button = payload["button"] | "";
    if (strlen(button) == 0) button = doc["button"] | "";
    if (!runButtonAction(String(button), "api_button")) {
        error = "unsupported button or no saved faces available";
        return false;
    }
    return true;
}

static bool commandTerminateOtherActivities(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    const char* targetMode = payload["targetMode"] | "";
    if (strcmp(targetMode, "scroll") != 0) stopFirmwareScroll(false, false);
    if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
        setMode("manual", true);
    } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
        runtimeState().restoreAutoAfterScroll = true;
        runtimeState().mode                   = "manual";
        touchRuntimeState();
    }
    return true;
}

static bool commandResetBatteryMinimum(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    resetBatteryVoltageMinimum();
    return true;
}

static bool commandResetBatteryMaximum(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    resetBatteryVoltageMaximum();
    return true;
}

struct ApiCommandRoute {
    const char*       name;
    ApiCommandHandler handler;
};

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

static const ApiCommandRoute* findApiCommandRoute(const String& cmd) {
    for (const ApiCommandRoute& route : API_COMMAND_ROUTES) {
        if (cmd == route.name) return &route;
    }
    return nullptr;
}

static void handleApiCommand() {
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        ++runtimeState().commandsRejected;
        sendError(400, error);
        return;
    }

    const String  cmd     = doc["cmd"] | "";
    JsonVariant   payload = doc["payload"];
    if (cmd.isEmpty()) {
        ++runtimeState().commandsRejected;
        sendError(400, "missing cmd");
        return;
    }

    const ApiCommandRoute* route = findApiCommandRoute(cmd);
    if (route == nullptr) {
        ++runtimeState().commandsRejected;
        sendError(400, String("unknown command: ") + cmd);
        return;
    }

    if (!route->handler(doc, payload, error)) {
        ++runtimeState().commandsRejected;
        sendError(400, error);
        return;
    }

    ++runtimeState().commandsAccepted;

    PsramJsonDocument reply(3072);
    reply["ok"]                   = true;
    reply["v"]                    = runtimeStateVersion();
    reply["version"]              = runtimeStateVersion();
    reply["next_poll_ms"]         = statusNextPollMs(runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused, false, false);
    reply["cmd"]                  = cmd;
    reply["color"]                = runtimeState().colorHex;
    reply["brightness"]           = runtimeState().brightness;
    reply["mode"]                 = runtimeState().mode;
    reply["autoIntervalMs"]       = runtimeState().autoIntervalMs;
    reply["playback"]             = runtimeState().playback;
    reply["paused"]               = runtimeState().paused;
    reply["autoFaceIndex"]        = runtimeState().autoFaceIndex;
    reply["firmwareScrollActive"] = runtimeState().firmwareScrollActive;
    reply["firmwareScrollPaused"] = runtimeState().firmwareScrollPaused;
    reply["restoreAutoAfterScroll"] = runtimeState().restoreAutoAfterScroll;
    reply["deferredFaceRestoreActive"] = runtimeState().deferredFaceRestoreActive;
    reply["scrollFrameCount"]     = runtimeState().scrollFrameCount;
    reply["scrollFrameIndex"]     = runtimeState().scrollFrameIndex;
    reply["scrollIntervalMs"]     = runtimeState().scrollIntervalMs;
    JsonObject scrollStopEvent = reply.createNestedObject("scrollStopEvent");
    scrollStopEvent["seq"]    = runtimeState().scrollStopEventSeq;
    scrollStopEvent["ms"]     = runtimeState().scrollStopEventMs;
    scrollStopEvent["button"] = runtimeState().scrollStopEventButton;
    scrollStopEvent["source"] = runtimeState().scrollStopEventSource;
    scrollStopEvent["reason"] = runtimeState().scrollStopEventReason;
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        reply["autoFaceId"]   = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
        reply["autoFaceName"] = runtimeAutoFaces()[runtimeState().autoFaceIndex].name;
    }
    reply["m370"]       = runtimeState().lastM370;
    reply["lastReason"] = runtimeState().lastReason;
    if (cmd == "reset_battery_min" || cmd == "reset_battery_max") {
        servicePowerMonitor(true);
        addPowerStatus(reply.createNestedObject("power"), true, true);
    }
    sendJsonDocument(200, reply);
}

static void handleSavedFacesGet() {
    if (!runtimeFsMounted()) { sendError(503, "LittleFS is not mounted; run pio run -t uploadfs"); return; }
    if (!littleFsExistsLocked(SAVED_FACES_PATH)) {
        sendError(404, "saved_faces.json not found; run pio run -t uploadfs"); return;
    }
    File file = littleFsOpenLocked(SAVED_FACES_PATH, "r");
    if (!file) { sendError(500, "failed to open saved_faces.json"); return; }
    addCorsHeaders();
    streamFileChunked(file, CONTENT_TYPE_JSON_UTF8);
    closeFileLocked(file);
}

static void handleSavedFacesPost() {
    if (!runtimeFsMounted()) { sendError(503, "LittleFS is not mounted; cannot write saved_faces.json"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    const size_t capacity = jsonCapacityFor(body.length());
    PsramJsonDocument doc(capacity);
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::NestingLimit(32));
    if (err) { sendError(400, String("invalid JSON: ") + err.c_str()); return; }

    JsonVariant document = doc["document"];
    if (document.isNull()) document = doc.as<JsonVariant>();
    const char* requestPath = doc["path"] | SAVED_FACES_PATH;
    const char* reason      = doc["reason"] | "";

    String error;
    if (!validateSavedFaces(document, error)) { sendError(400, error); return; }

    const size_t written = writeSavedFaces(document, error);
    if (written == 0) { sendError(500, error); return; }

    loadSavedFaces(false);

    DynamicJsonDocument reply(384);
    reply["ok"]     = true;
    reply["v"]      = runtimeStateVersion();
    reply["version"] = runtimeStateVersion();
    reply["path"]   = SAVED_FACES_PATH;
    reply["requestPath"] = requestPath;
    reply["reason"] = reason;
    reply["bytes"]  = written;
    reply["writes"] = runtimeState().savedFacesWrites;
    sendJsonDocument(200, reply);
}

static void handleApiSavedFaces() {
    if      (server.method() == HTTP_GET)     handleSavedFacesGet();
    else if (server.method() == HTTP_POST)    handleSavedFacesPost();
    else if (server.method() == HTTP_OPTIONS) handleOptions();
    else                                       sendError(405, "method not allowed");
}

static void handleNotFound() {
    if (server.method() == HTTP_GET && serveStaticFile(server.uri())) return;
    if (server.method() == HTTP_GET && !runtimeFsMounted()) { sendFilesystemErrorPage(); return; }
    sendError(404, "not found: " + server.uri());
}

// ---------------------------------------------------------------------------
// LittleFS error pattern  (shown before web server is up)
// ---------------------------------------------------------------------------

void showFilesystemErrorPattern() {
    withFrameLock([]() {
        runtimeState().colorHex   = "#ff0000";
        runtimeState().colorR     = 0xff;
        runtimeState().colorG     = 0x00;
        runtimeState().colorB     = 0x00;
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        memset(runtimeFrameBits(), 0, FRAME_BYTES);
        for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) setFrameBit(i, true);
        runtimeState().lastReason = "littlefs_mount_failed";
        showCurrentFrameNoLock();
    });
}

// ---------------------------------------------------------------------------
// Public: Access Point + WebServer startup
// ---------------------------------------------------------------------------

void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(apIP(), apGateway(), apSubnet());
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    const IPAddress currentIp = WiFi.softAPIP();
    dnsServer.setTTL(60);
    dnsServerActive = dnsServer.start(DNS_PORT, AP_DOMAIN, currentIp);
    Serial.printf("AP started: ssid=%s password=%s ip=%s domain=%s dns=%s\n",
                  AP_SSID, AP_PASSWORD, currentIp.toString().c_str(), AP_DOMAIN,
                  dnsServerActive ? "on" : "off");
}

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
    // Needed so serveStaticFile() can read Accept-Encoding for gzip negotiation;
    // the synchronous WebServer only stores headers registered up front.
    static const char* COLLECTED_HEADERS[] = { "Accept-Encoding" };
    server.collectHeaders(COLLECTED_HEADERS, 1);
    server.begin();
    Serial.printf("HTTP server listening on http://%s/ and http://%s/\n",
                  AP_DOMAIN, WiFi.softAPIP().toString().c_str());
}

void webServerTick() {
    if (dnsServerActive) dnsServer.processNextRequest();
    server.handleClient();
}
~~~~

#### `src/web_api.h`

~~~~cpp
#pragma once

// ---------------------------------------------------------------------------
// HTTP server lifecycle
// ---------------------------------------------------------------------------

// Start the Wi-Fi Access Point.
void startAccessPoint();

// Register all routes and start the WebServer.
void startWebServer();

// Call every loop() iteration to service pending HTTP requests.
void webServerTick();

// Light the first 12 LEDs in red to indicate a LittleFS mount failure.
// Called from setup() before the web server is available.
void showFilesystemErrorPattern();
~~~~

#### `src/web_json.cpp`

~~~~cpp
#include "web_json.h"
#include <ctype.h>

static int jsonFieldValuePosition(const String& body, const char* key) {
    const String token = String("\"") + key + "\"";
    const int keyPos = body.indexOf(token);
    if (keyPos < 0) return -1;

    const int colon = body.indexOf(':', keyPos);
    if (colon < 0) return -1;

    int p = colon + 1;
    while (p >= 0 && static_cast<size_t>(p) < body.length() &&
           isspace(static_cast<unsigned char>(body.charAt(p)))) {
        ++p;
    }
    return p;
}

int findJsonStringEnd(const String& body, size_t quotePos) {
    if (quotePos >= body.length() || body.charAt(quotePos) != '"') return -1;

    bool escaped = false;
    for (size_t i = quotePos + 1; i < body.length(); ++i) {
        const char c = body.charAt(i);
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return static_cast<int>(i);
    }
    return -1;
}

bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote) {
    endQuote = findJsonStringEnd(body, quotePos);
    if (endQuote < 0) return false;

    const String raw = body.substring(quotePos + 1, endQuote);
    if (raw.indexOf('\\') < 0) {
        value = raw;
        return true;
    }

    value = "";
    value.reserve(raw.length());
    bool escaped = false;
    for (size_t i = 0; i < raw.length(); ++i) {
        const char c = raw.charAt(i);
        if (!escaped) {
            if (c == '\\') {
                escaped = true;
            } else {
                value += c;
            }
            continue;
        }

        switch (c) {
            case '"': value += '"'; break;
            case '\\': value += '\\'; break;
            case '/': value += '/'; break;
            case 'b': value += '\b'; break;
            case 'f': value += '\f'; break;
            case 'n': value += '\n'; break;
            case 'r': value += '\r'; break;
            case 't': value += '\t'; break;
            default:
                value += c;
                break;
        }
        escaped = false;
    }
    return !escaped;
}

bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (body.substring(p, p + 4) == "true") return true;
    if (body.substring(p, p + 5) == "false") return false;
    return defaultValue;
}

bool jsonUintField(const String& body, const char* key, uint32_t& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    uint32_t parsed = 0;
    bool foundDigit = false;
    while (static_cast<size_t>(p) < body.length() &&
           isdigit(static_cast<unsigned char>(body.charAt(p)))) {
        foundDigit = true;
        parsed = parsed * 10 + static_cast<uint32_t>(body.charAt(p++) - '0');
    }
    if (!foundDigit) return false;
    value = parsed;
    return true;
}

bool jsonFloatField(const String& body, const char* key, float& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    int q = p;
    while (static_cast<size_t>(q) < body.length()) {
        const char c = body.charAt(q);
        if (!(isdigit(static_cast<unsigned char>(c)) || c == '.' || c == '-' ||
              c == '+' || c == 'e' || c == 'E')) {
            break;
        }
        ++q;
    }
    if (q == p) return false;
    value = body.substring(p, q).toFloat();
    return true;
}

bool jsonStringField(const String& body, const char* key, String& value) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0 || static_cast<size_t>(p) >= body.length() || body.charAt(p) != '"') return false;

    int endQuote = -1;
    return extractJsonStringAt(body, static_cast<size_t>(p), value, endQuote);
}
~~~~

#### `src/web_json.h`

~~~~cpp
#pragma once
#include <Arduino.h>

int findJsonStringEnd(const String& body, size_t quotePos);
bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote);
bool jsonBoolField(const String& body, const char* key, bool defaultValue);
bool jsonUintField(const String& body, const char* key, uint32_t& value);
bool jsonFloatField(const String& body, const char* key, float& value);
bool jsonStringField(const String& body, const char* key, String& value);
~~~~

#### `scripts/gzip_webui_assets.py`

~~~~python
"""
gzip_webui_assets.py  –  PlatformIO filesystem pre-build script

Generates precompressed "<file>.gz" siblings for the large, highly compressible
WebUI assets so the firmware can serve them with `Content-Encoding: gzip`
(see serveStaticFile() in src/web_api.cpp). This dramatically shrinks the bytes
transferred over the ESP32 SoftAP link and the number of streamed chunks.

The .gz files are written next to the originals inside data/ and are picked up
automatically when the LittleFS image is built (`pio run -t buildfs` /
`-t uploadfs`). Both the raw file and the .gz are shipped, so non-gzip clients
still work; serveStaticFile() prefers the .gz only when the client sends
`Accept-Encoding: gzip`.

Only text-like assets are compressed. Already-compressed assets (woff2, png,
jpg) are skipped because gzip would not help (and could even grow them).

The script is idempotent: a .gz is regenerated only when it is missing or older
than its source file.
"""

import gzip
import os
import shutil

Import("env")  # noqa: F821  (PlatformIO injects this)

# Paths are relative to the data/ (LittleFS source) directory.
GZIP_TARGETS = [
    "index.html",
    "styles.css",
    "resources/fonts/ark12.json",
]

GZIP_LEVEL = 9


def _gzip_one(src_path):
    dst_path = src_path + ".gz"
    if os.path.isfile(dst_path) and os.path.getmtime(dst_path) >= os.path.getmtime(src_path):
        return False
    with open(src_path, "rb") as f_in, gzip.open(dst_path, "wb", compresslevel=GZIP_LEVEL) as f_out:
        shutil.copyfileobj(f_in, f_out)
    src_size = os.path.getsize(src_path)
    dst_size = os.path.getsize(dst_path)
    pct = (100.0 * dst_size / src_size) if src_size else 0.0
    print(f"[gzip_webui_assets] {os.path.basename(src_path)}: "
          f"{src_size} -> {dst_size} bytes ({pct:.1f}%)")
    return True


def gzip_assets(*args, **kwargs):
    data_dir = os.path.join(env["PROJECT_DIR"], "data")  # noqa: F821
    if not os.path.isdir(data_dir):
        print(f"[gzip_webui_assets] WARNING: data dir not found: {data_dir} - skipping")
        return
    any_done = False
    for rel in GZIP_TARGETS:
        src = os.path.join(data_dir, rel)
        if not os.path.isfile(src):
            print(f"[gzip_webui_assets] skip (missing): {rel}")
            continue
        any_done = _gzip_one(src) or any_done
    if not any_done:
        print("[gzip_webui_assets] all .gz assets already up to date")


# Regenerate the .gz files right before the LittleFS image is assembled.
env.AddPreAction("$BUILD_DIR/littlefs.bin", gzip_assets)  # noqa: F821

# Also allow manual invocation: `pio run -t gzipassets`.
try:
    env.AddCustomTarget("gzipassets", None, gzip_assets,  # noqa: F821
                        title="Gzip WebUI assets",
                        description="Generate .gz siblings for large WebUI assets")
except Exception:
    pass

# Run once at script load too, so a plain `pio run -t uploadfs` on a clean tree
# still has fresh .gz files even if the image-target hook ordering changes.
gzip_assets()
~~~~

#### `scripts/patch_webserver_timeout.py`

~~~~python
"""
patch_webserver_timeout.py  –  PlatformIO pre-build script
Patches the ESP32 Arduino WebServer.h so that the three per-connection
timeout macros use #ifndef guards instead of unconditional #defines.
This lets build_flags -D overrides actually take effect, and lets us
shorten the default 5000 ms timeouts to 200 ms so that half-open TCP
connections left by a disconnected phone do not stall the main loop
(and firmware text-scroll) for seconds at a time.

The patch is idempotent: running it a second time is a no-op.
"""

import os
import re
Import("env")  # noqa: F821  (PlatformIO injects this)

FRAMEWORK_DIR = env.PioPlatform().get_package_dir("framework-arduinoespressif32")
WEBSERVER_H = os.path.join(
    FRAMEWORK_DIR, "libraries", "WebServer", "src", "WebServer.h"
)

TIMEOUT_MS = 200

MACROS = ["HTTP_MAX_DATA_WAIT", "HTTP_MAX_POST_WAIT", "HTTP_MAX_SEND_WAIT"]

def patch():
    if not os.path.isfile(WEBSERVER_H):
        print(f"[patch_webserver_timeout] WARNING: {WEBSERVER_H} not found – skipping patch")
        return

    with open(WEBSERVER_H, "r", encoding="utf-8") as f:
        original = f.read()

    patched = original
    changed = False
    for macro in MACROS:
        # Match an unconditional #define for this macro (not already inside #ifndef)
        pattern = re.compile(
            r'^([ \t]*#define[ \t]+' + re.escape(macro) + r'[ \t]+\d+[^\n]*)$',
            re.MULTILINE,
        )
        replacement = (
            f"#ifndef {macro}\n"
            f"#define {macro} {TIMEOUT_MS}  // patched by patch_webserver_timeout.py\n"
            f"#endif  // {macro}"
        )
        # Only replace if the line is NOT already inside a #ifndef block we added
        if re.search(r'patched by patch_webserver_timeout', patched) is None or \
                macro not in patched.split("patched by patch_webserver_timeout")[0]:
            new_patched, n = pattern.subn(replacement, patched)
            if n:
                patched = new_patched
                changed = True
                print(f"[patch_webserver_timeout] Patched {macro} → {TIMEOUT_MS} ms in WebServer.h")

    if changed:
        with open(WEBSERVER_H, "w", encoding="utf-8") as f:
            f.write(patched)
        print(f"[patch_webserver_timeout] WebServer.h updated: {WEBSERVER_H}")
    else:
        print("[patch_webserver_timeout] WebServer.h already patched – no changes needed")

patch()
~~~~

#### `tools/build_ark12_merged.py`

~~~~python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build a merged Ark Pixel 12px monospaced bitmap JSON for RinaChanBoard.

Default merge priority, low -> high:
  zh_cn  -> simplified Chinese base
  ja     -> Japanese glyphs fill/override simplified where zh_tw does not replace later
  zh_tw  -> traditional Chinese final authority for same Unicode codepoints

The output JSON uses the existing rina_ark_pixel_font_bitmap_v1 structure:
  glyphs[HEX_CODEPOINT] = [advance, width, height, xOffset, yOffset, dstY, "HEX/ROWS"]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

EXPECTED_OFFICIAL_ARK12_MONO_COUNT = 24408  # Ark Pixel 12px monospaced v2026.05.07 public release count.

@dataclass
class BdfGlyph:
    codepoint: int
    dwidth_x: int
    dwidth_y: int
    bbx_w: int
    bbx_h: int
    bbx_xoff: int
    bbx_yoff: int
    rows: List[str]
    source: str

    def to_rina_entry(self, ascent: int = 10) -> List[object]:
        # Compact glyph tuple used by data/index.html:
        # [advance, width, height, xOffset, yOffset, dstY, rowsHex]
        # dstY converts BDF baseline-relative BBX yOffset into top-down LED row coordinates.
        dst_y = int(ascent) - int(self.bbx_yoff) - int(self.bbx_h)
        return [
            self.dwidth_x,
            self.bbx_w,
            self.bbx_h,
            self.bbx_xoff,
            self.bbx_yoff,
            dst_y,
            "/".join(self.rows),
        ]


def _normalize_bitmap_row(raw_hex: str, width: int) -> str:
    """Convert a BDF row to the compact row format used by ark12.json.

    BDF rows are byte-aligned. For a 12-pixel glyph, rows are often 16 bits,
    but the firmware JSON stores only 12 significant bits, e.g. FFE not FFE0.
    """
    raw_hex = raw_hex.strip().upper()
    if width <= 0:
        return ""
    if not raw_hex:
        bits = "0" * width
    else:
        bits = bin(int(raw_hex, 16))[2:].zfill(len(raw_hex) * 4)[:width]
        if len(bits) < width:
            bits = bits.ljust(width, "0")
    out_bits_len = int(math.ceil(width / 4.0) * 4)
    bits = bits.ljust(out_bits_len, "0")
    nibbles = out_bits_len // 4
    if not bits:
        return "0" * max(1, nibbles)
    return f"{int(bits, 2):0{nibbles}X}"


def parse_bdf(path: Path, source_label: str) -> Dict[int, BdfGlyph]:
    glyphs: Dict[int, BdfGlyph] = {}
    lines = path.read_text(encoding="latin-1", errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line != "STARTCHAR":
            # Some BDFs use STARTCHAR <name> on one line.
            if not line.startswith("STARTCHAR"):
                i += 1
                continue
        codepoint: Optional[int] = None
        dwidth_x, dwidth_y = 0, 0
        bbx: Optional[Tuple[int, int, int, int]] = None
        bitmap: List[str] = []
        in_bitmap = False
        i += 1
        while i < len(lines):
            s = lines[i].strip()
            if s.startswith("ENCODING"):
                parts = s.split()
                if len(parts) >= 2:
                    try:
                        codepoint = int(parts[1])
                    except ValueError:
                        codepoint = None
            elif s.startswith("DWIDTH"):
                parts = s.split()
                if len(parts) >= 3:
                    try:
                        dwidth_x, dwidth_y = int(parts[1]), int(parts[2])
                    except ValueError:
                        dwidth_x, dwidth_y = 0, 0
            elif s.startswith("BBX"):
                parts = s.split()
                if len(parts) >= 5:
                    try:
                        bbx = tuple(int(p) for p in parts[1:5])  # type: ignore[assignment]
                    except ValueError:
                        bbx = None
            elif s == "BITMAP":
                in_bitmap = True
                bitmap = []
            elif s == "ENDCHAR":
                if codepoint is not None and codepoint >= 0 and bbx is not None:
                    w, h, xoff, yoff = bbx
                    rows = [_normalize_bitmap_row(r, w) for r in bitmap[:h]]
                    if len(rows) < h:
                        rows.extend(["0" * max(1, math.ceil(w / 4))] * (h - len(rows)))
                    glyphs[codepoint] = BdfGlyph(
                        codepoint=codepoint,
                        dwidth_x=dwidth_x,
                        dwidth_y=dwidth_y,
                        bbx_w=w,
                        bbx_h=h,
                        bbx_xoff=xoff,
                        bbx_yoff=yoff,
                        rows=rows,
                        source=source_label,
                    )
                break
            elif in_bitmap and re.fullmatch(r"[0-9A-Fa-f]+", s):
                bitmap.append(s)
            i += 1
        i += 1
    return glyphs


def find_bdf_for_language(bdf_root: Path, language: str) -> Optional[Path]:
    language = language.lower()
    candidates = sorted(bdf_root.rglob("*.bdf"))
    # Prefer exact language token match in the filename.
    patterns = [
        re.compile(rf"(^|[-_]){re.escape(language)}($|[-_.])", re.IGNORECASE),
        re.compile(re.escape(language), re.IGNORECASE),
    ]
    for pat in patterns:
        matched = [p for p in candidates if pat.search(p.name)]
        if matched:
            # Prefer monospaced 12px path/name if the archive contains multiple styles.
            matched.sort(key=lambda p: (
                0 if "monospaced" in str(p).lower() else 1,
                0 if "12" in str(p).lower() else 1,
                len(str(p)),
                str(p).lower(),
            ))
            return matched[0]
    return None


def merge_sources(source_files: List[Tuple[str, Path]]) -> Tuple[Dict[int, BdfGlyph], Dict[str, object]]:
    merged: Dict[int, BdfGlyph] = {}
    stats = {
        "sources": [],
        "total_overwrites": 0,
        "overwrites_by_source": {},
    }
    for label, path in source_files:
        glyphs = parse_bdf(path, label)
        overwrites = sum(1 for cp in glyphs if cp in merged)
        merged.update(glyphs)
        stats["sources"].append({
            "label": label,
            "path": path.name,
            "glyphs": len(glyphs),
            "overwrites": overwrites,
        })
        stats["total_overwrites"] = int(stats["total_overwrites"]) + overwrites
        stats["overwrites_by_source"][label] = overwrites
    return merged, stats


def hex_key(cp: int) -> str:
    return f"{cp:04X}" if cp <= 0xFFFF else f"{cp:X}"


def write_output_json(merged: Dict[int, BdfGlyph], out_path: Path, stats: Dict[str, object], release_version: str) -> None:
    ascent = 10
    glyph_items = {hex_key(cp): merged[cp].to_rina_entry(ascent=ascent) for cp in sorted(merged)}
    metadata = {
        "format": "rina_ark_pixel_font_bitmap_v1",
        "source": f"merged Ark Pixel 12px Monospaced BDF v{release_version}: zh_cn + ja + zh_tw; zh_tw overrides conflicts",
        "family": "Ark Pixel 12px Monospaced Merged Trad Priority",
        "rows": 12,
        "lineHeight": 12,
        "ascent": ascent,
        "descent": 2,
        "defaultAdvance": 12,
        "mergePolicy": {
            "priorityLowToHigh": [s["label"] for s in stats["sources"]],
            "conflictAuthority": "zh_tw",
            "description": "When the same Unicode codepoint appears in multiple sources, later sources replace earlier sources. Traditional Chinese zh_tw is applied last.",
        },
        "buildStats": stats,
        "glyphs": glyph_items,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(metadata, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def validate_json(path: Path, sample_text: str, strict_sample: bool = False) -> int:
    data = json.loads(path.read_text(encoding="utf-8"))
    glyphs = data.get("glyphs", {})
    missing = []
    for ch in sample_text:
        cp = ord(ch)
        key = hex_key(cp)
        if key not in glyphs:
            missing.append(f"U+{cp:04X} {ch}")
    count = len(glyphs)
    max_rows = max((len(entry[6].split('/')) for entry in glyphs.values()), default=0)
    non_12 = sum(1 for entry in glyphs.values() if len(entry[6].split('/')) != 12)
    print(f"[validate] glyph count: {count}")
    print(f"[validate] expected official Ark 12 mono count: about {EXPECTED_OFFICIAL_ARK12_MONO_COUNT}")
    print(f"[validate] max bitmap rows: {max_rows}; entries with rows != 12: {non_12}")
    if missing:
        print("[validate] sample missing glyphs:")
        for item in missing:
            print(f"  - {item}")
        if strict_sample:
            return 2
        print("[validate] WARNING: sample contains codepoints not covered by official Ark 12; build will continue.")
    else:
        print("[validate] sample text coverage: OK")
    if count < 24000:
        print("[validate] WARNING: glyph count is below 24000; check whether all three BDF sources were selected correctly.")
        return 1
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bdf-root", required=True, help="Folder containing extracted Ark Pixel 12px monospaced BDF files.")
    ap.add_argument("--out", required=True, help="Output merged JSON path.")
    ap.add_argument("--release-version", default="2026.05.07")
    ap.add_argument("--languages", default="zh_cn,ja,zh_tw", help="Merge priority low->high. Default: zh_cn,ja,zh_tw")
    ap.add_argument("--sample", default="English symbols !@#$ 你好 简体 繁體 日本語 こんにちは 璃奈ちゃんボード 國 龍 辺 高 髙")
    ap.add_argument("--strict-sample", action="store_true", help="Fail when any character in --sample is missing. Default is warning-only because Ark 12 is not a complete CJK font.")
    args = ap.parse_args(argv)

    bdf_root = Path(args.bdf_root).resolve()
    languages = [x.strip() for x in args.languages.split(",") if x.strip()]
    source_files: List[Tuple[str, Path]] = []
    missing_langs: List[str] = []
    for lang in languages:
        path = find_bdf_for_language(bdf_root, lang)
        if path is None:
            missing_langs.append(lang)
        else:
            source_files.append((lang, path))

    if missing_langs:
        print(f"[error] missing BDF source(s): {', '.join(missing_langs)}", file=sys.stderr)
        print(f"[error] searched under: {bdf_root}", file=sys.stderr)
        print("[error] available BDF files:", file=sys.stderr)
        for p in sorted(bdf_root.rglob("*.bdf"))[:80]:
            print(f"  - {p}", file=sys.stderr)
        return 10
    if not source_files:
        print("[error] no source BDF files selected", file=sys.stderr)
        return 11

    print("[merge] source order, low -> high priority:")
    for label, path in source_files:
        print(f"  - {label}: {path}")

    merged, stats = merge_sources(source_files)
    out_path = Path(args.out).resolve()
    write_output_json(merged, out_path, stats, args.release_version)
    print(f"[merge] wrote: {out_path}")
    print(f"[merge] glyphs: {len(merged)}")
    print(f"[merge] overwrites total: {stats['total_overwrites']}")
    for source in stats["sources"]:
        print(f"[merge] {source['label']}: glyphs={source['glyphs']} overwrites={source['overwrites']}")

    return validate_json(out_path, args.sample, args.strict_sample)


if __name__ == "__main__":
    raise SystemExit(main())
~~~~

#### `tools/build_unifont_webui_subset_from_png.py`

~~~~python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build and embed the small offline GNU Unifont WebUI WOFF2 subset from an
official GNU Unifont BMP PNG glyph sheet.

Outputs:
    A temporary WOFF2 subset file chosen by --out. The run script embeds the
    generated bytes into data/styles.css and then removes the temporary file.

The WebUI must use the embedded base64 data: URL only; it must not load a
LittleFS /resources/fonts/unifont.woff2 file.

The character set is collected from the current WebUI files, filtered to glyphs
that can actually be produced from the BMP PNG sheet, and verified after build.
Unsupported characters, such as non-BMP emoji, are reported and intentionally
not added to the subset.
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
import unicodedata
from pathlib import Path
from typing import Iterable, Sequence, Set

try:
    from PIL import Image
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import TTFont
except Exception as exc:  # pragma: no cover - user-facing dependency error
    print(
        "[unifont-build] Missing Python dependency. Install with: "
        "python -m pip install --user pillow fonttools brotli",
        file=sys.stderr,
    )
    print(f"[unifont-build] Import error: {exc}", file=sys.stderr)
    raise SystemExit(20)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / ".font_cache/unifont_webui_embedded_tmp.woff2"
DEFAULT_INDEX = ROOT / "data/index.html"
DEFAULT_TEXT_FILES = [
    ROOT / "data/index.html",
    ROOT / "data/styles.css",
    ROOT / "data/resources/saved_faces.json",
    ROOT / "data/resources/runtime_settings.json",
    ROOT / "data/resources/battery_calib.json",
]

# GNU Unifont PNG layout for the BMP sheet published by GNU/Unifoundry.
XOFF = 32
YOFF = 64
CELL = 16
COLS = 256
ROWS = 256
UPM = 16
ASCENT = 14
DESCENT = -2
BMP_MAX = 0xFFFF

# These codepoints intentionally have no ink but still need valid cmap entries
# when they are used by the page.
INTENTIONAL_BLANKS = {
    0x0020,  # space
    0x00A0,  # no-break space
    0x3000,  # ideographic space
}

# Variation selectors only make sense together with emoji/presentation fonts.
# They are not useful in this embedded monochrome WebUI subset.
VARIATION_SELECTOR_RANGES = (
    range(0xFE00, 0xFE10),
)

FONT_DATA_URL_RE = re.compile(r"data:font/woff2;base64,[A-Za-z0-9+/=\r\n]+")
STYLE_OPEN_RE = re.compile(r"(<style[^>]*>\s*)", re.I)
UNIFONT_FACE_BLOCK_RE = re.compile(
    r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])[^{}]*\}",
    re.S,
)
UNIFONT_FACE_DATA_RE = re.compile(
    r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])(?=[^{}]*data:font/woff2;base64,([A-Za-z0-9+/=\r\n]+))[^{}]*\}",
    re.S,
)


def add_range(codepoints: Set[int], start: int, end: int) -> None:
    codepoints.update(range(start, end + 1))


def is_variation_selector(cp: int) -> bool:
    return any(cp in r for r in VARIATION_SELECTOR_RANGES)


def strip_embedded_font_payloads(text: str) -> str:
    return FONT_DATA_URL_RE.sub("data:font/woff2;base64,", text)


def collect_raw_codepoints(text_files: Iterable[Path]) -> Set[int]:
    codepoints: Set[int] = set()

    # Stable UI/basic coverage. These keep ordinary controls, numbers,
    # punctuation and common Japanese/CJK punctuation available even when a
    # future label is added before the subset is regenerated.
    add_range(codepoints, 0x0020, 0x007E)  # ASCII
    add_range(codepoints, 0x00A0, 0x00FF)  # Latin-1 punctuation/symbols
    add_range(codepoints, 0x2000, 0x206F)  # General punctuation
    add_range(codepoints, 0x2100, 0x214F)  # Letterlike symbols
    add_range(codepoints, 0x2190, 0x21FF)  # Arrows
    add_range(codepoints, 0x25A0, 0x25FF)  # Geometric shapes
    add_range(codepoints, 0x2700, 0x27BF)  # Dingbats used by text buttons
    add_range(codepoints, 0x3000, 0x303F)  # CJK punctuation
    add_range(codepoints, 0x3040, 0x309F)  # Hiragana
    add_range(codepoints, 0x30A0, 0x30FF)  # Katakana
    add_range(codepoints, 0x31F0, 0x31FF)  # Katakana phonetic extensions
    add_range(codepoints, 0xFF00, 0xFFEF)  # Fullwidth forms

    for p in text_files:
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        if p.name.lower().endswith((".html", ".css", ".js")):
            text = strip_embedded_font_payloads(text)
        for ch in text:
            cp = ord(ch)
            if cp >= 0x20:
                codepoints.add(cp)

    return codepoints


def glyph_pixel_bounds(cp: int) -> tuple[int, int]:
    row = cp // COLS
    col = cp % COLS
    return XOFF + col * CELL, YOFF + row * CELL


def glyph_runs(px, cp: int):
    x0, y0 = glyph_pixel_bounds(cp)
    runs = []
    max_x = -1
    ink = 0
    for y in range(CELL):
        x = 0
        while x < CELL:
            while x < CELL and px[x0 + x, y0 + y] != 0:
                x += 1
            if x >= CELL:
                break
            start = x
            while x < CELL and px[x0 + x, y0 + y] == 0:
                x += 1
            end = x
            runs.append((start, y, end, y + 1))
            ink += end - start
            max_x = max(max_x, end - 1)
    return runs, max_x, ink


def is_available_from_png(px, cp: int) -> bool:
    if cp < 0 or cp > BMP_MAX:
        return False
    if is_variation_selector(cp):
        return False
    row = cp // COLS
    if row >= ROWS:
        return False
    _runs, _max_x, ink = glyph_runs(px, cp)
    if ink > 0:
        return True
    if cp in INTENTIONAL_BLANKS:
        return True
    # Keep Unicode separator spaces blank if present in actual WebUI text.
    return unicodedata.category(chr(cp)).startswith("Z")


def filter_codepoints_for_png(px, raw: Set[int]) -> tuple[Set[int], Set[int]]:
    supported: Set[int] = set()
    skipped: Set[int] = set()
    for cp in raw:
        if is_available_from_png(px, cp):
            supported.add(cp)
        else:
            skipped.add(cp)
    return supported, skipped


def is_zero_advance_codepoint(cp: int) -> bool:
    # Unicode format controls should not create visible spacing if a future
    # WebUI string accidentally contains one. They are still skipped unless the
    # GNU Unifont PNG actually provides a usable glyph for them.
    return unicodedata.category(chr(cp)) == "Cf"


def is_fullwidth_codepoint(cp: int) -> bool:
    ch = chr(cp)
    if unicodedata.east_asian_width(ch) in {"F", "W"}:
        return True
    # These ranges are always intended to occupy one 16 px grid cell in the
    # WebUI font even if a particular glyph's ink stays in the left/right half.
    return (
        0x3040 <= cp <= 0x30FF  # Hiragana + Katakana
        or 0x31F0 <= cp <= 0x31FF  # Katakana phonetic extensions
        or 0x3400 <= cp <= 0x9FFF  # CJK Unified Ideographs + Extension A
        or 0xF900 <= cp <= 0xFAFF  # CJK Compatibility Ideographs
    )


def glyph_advance_width(cp: int, max_x: int) -> int:
    if is_zero_advance_codepoint(cp):
        return 0
    if cp == 0x3000 or is_fullwidth_codepoint(cp):
        return 16
    return 16 if max_x >= 8 else 8


def make_glyph(px, cp=None):
    pen = TTGlyphPen(None)
    if cp is None:
        return pen.glyph(), 8, 0
    runs, max_x, _ink = glyph_runs(px, cp)
    min_x = min((x1 for x1, _y1, _x2, _y2 in runs), default=0)
    for x1, y1, x2, y2 in runs:
        # Convert image top-left coordinates to TrueType y-up coordinates.
        pen.moveTo((x1, UPM - y1))
        pen.lineTo((x2, UPM - y1))
        pen.lineTo((x2, UPM - y2))
        pen.lineTo((x1, UPM - y2))
        pen.closePath()
    width = glyph_advance_width(cp, max_x)
    # Keep hmtx left side bearings consistent with the outline xMin. Mismatched
    # LSB values can make browser rasterizers place glyphs unevenly even when
    # advance widths are correct.
    lsb = min_x if width > 0 else 0
    return pen.glyph(), width, lsb


def cmap_codepoints(font_path: Path) -> Set[int]:
    font = TTFont(str(font_path))
    found: Set[int] = set()
    for table in font["cmap"].tables:
        found.update(table.cmap.keys())
    return found


def format_codepoints(codepoints: Sequence[int], limit: int = 40) -> str:
    shown = []
    for cp in list(codepoints)[:limit]:
        try:
            ch = chr(cp)
            name = unicodedata.name(ch, "UNNAMED")
            shown.append(f"U+{cp:04X} {ch!r} {name}")
        except ValueError:
            shown.append(f"U+{cp:04X}")
    if len(codepoints) > limit:
        shown.append(f"... +{len(codepoints) - limit} more")
    return "; ".join(shown)


def make_embedded_unifont_face(font_path: Path) -> str:
    encoded = base64.b64encode(font_path.read_bytes()).decode("ascii")
    return (
        '@font-face{font-family:"GNU Unifont";'
        f'src:url("data:font/woff2;base64,{encoded}") format("woff2");'
        'font-weight:400;font-style:normal;font-display:block;}'
    )


def embedded_unifont_bytes_from_html(html: str) -> bytes:
    match = UNIFONT_FACE_DATA_RE.search(html)
    if not match:
        raise RuntimeError("Embedded GNU Unifont data URL was not found in index.html.")
    return base64.b64decode(match.group(1))


def embed_font_in_index(index_path: Path, font_path: Path) -> None:
    html = index_path.read_text(encoding="utf-8")
    face = make_embedded_unifont_face(font_path)
    updated, count = UNIFONT_FACE_BLOCK_RE.subn(lambda _m: face, html, count=1)
    if count == 0:
        updated, count = STYLE_OPEN_RE.subn(lambda m: m.group(1) + face + "\n  ", html, count=1)
    if count != 1:
        raise RuntimeError(
            "Could not locate or insert the GNU Unifont @font-face block in index.html."
        )

    face_match = UNIFONT_FACE_BLOCK_RE.search(updated)
    if not face_match:
        raise RuntimeError("GNU Unifont @font-face block missing after embedding.")
    face_block = face_match.group(0)
    forbidden = ("local(", "resources/fonts/unifont.woff2", "/resources/fonts/unifont.woff2")
    if any(token in face_block for token in forbidden):
        raise RuntimeError("GNU Unifont @font-face still contains a local or external font source.")
    if embedded_unifont_bytes_from_html(updated) != font_path.read_bytes():
        raise RuntimeError("Embedded GNU Unifont bytes do not match the generated WOFF2 file.")

    index_path.write_text(updated, encoding="utf-8", newline="\n")
    print(f"[unifont-build] embedded {font_path.name} into {index_path}")


def build_subset(
    png_path: Path,
    out_path: Path,
    version: str,
    text_files: Iterable[Path],
    embed_index: Path | None,
) -> None:
    if not png_path.exists():
        raise FileNotFoundError(f"GNU Unifont PNG is missing: {png_path}")

    im = Image.open(png_path).convert("1")
    required_width = XOFF + COLS * CELL
    required_height = YOFF + ROWS * CELL
    if im.width < required_width or im.height < required_height:
        raise ValueError(
            f"Unexpected GNU Unifont PNG dimensions {im.width}x{im.height}; "
            f"expected at least {required_width}x{required_height}."
        )
    px = im.load()

    raw = collect_raw_codepoints(text_files)
    codepoints, skipped = filter_codepoints_for_png(px, raw)
    ordered = sorted(codepoints)
    glyph_order = [".notdef"] + [f"u{cp:04X}" for cp in ordered]
    char_map = {cp: f"u{cp:04X}" for cp in ordered}

    glyphs = {}
    metrics = {}
    glyphs[".notdef"], notdef_width, notdef_lsb = make_glyph(px, None)
    metrics[".notdef"] = (notdef_width, notdef_lsb)
    for cp in ordered:
        name = char_map[cp]
        glyphs[name], width, lsb = make_glyph(px, cp)
        metrics[name] = (width, lsb)

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(char_map)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        usWinAscent=16,
        usWinDescent=2,
        sxHeight=8,
        sCapHeight=12,
        ulUnicodeRange1=0xFFFFFFFF,
        ulUnicodeRange2=0xFFFFFFFF,
        ulUnicodeRange3=0xFFFFFFFF,
        ulUnicodeRange4=0xFFFFFFFF,
    )
    fb.setupNameTable(
        {
            "familyName": "GNU Unifont",
            "styleName": "Regular",
            "uniqueFontIdentifier": f"GNU Unifont {version} WebUI Offline Subset",
            "fullName": "GNU Unifont WebUI Offline Subset",
            "psName": "GNUUnifont-WebUIOfflineSubset",
            "version": f"Version {version}-webui-offline-subset",
            "manufacturer": "Unifoundry / WebUI subset generated for RinaChanBoard",
            "licenseDescription": (
                "GNU Unifont is distributed under the SIL Open Font License 1.1 "
                "and GPLv2+ with font embedding exception."
            ),
        }
    )
    fb.setupPost()

    font = fb.font
    font["head"].macStyle = 0
    font["OS/2"].fsSelection = 0x40  # regular
    font.flavor = "woff2"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(out_path))

    built_cmap = cmap_codepoints(out_path)
    missing = sorted(codepoints - built_cmap)
    if missing:
        raise RuntimeError(
            "Generated font is missing supported WebUI codepoints: "
            + format_codepoints(missing)
        )

    if embed_index is not None:
        embed_font_in_index(embed_index, out_path)
        # Verify that the embedded font can be decoded and has the same cmap.
        html = embed_index.read_text(encoding="utf-8")
        probe = out_path.with_suffix(".embedded-check.woff2")
        try:
            probe.write_bytes(embedded_unifont_bytes_from_html(html))
            embedded_cmap = cmap_codepoints(probe)
        finally:
            probe.unlink(missing_ok=True)
        if embedded_cmap != built_cmap:
            raise RuntimeError("Embedded GNU Unifont cmap does not match generated font.")

    print(
        f"[unifont-build] wrote {out_path} glyphs={len(glyph_order)} "
        f"chars={len(codepoints)} size={out_path.stat().st_size} bytes"
    )
    if skipped:
        print(
            "[unifont-build] skipped unsupported/unusable codepoints: "
            + format_codepoints(sorted(skipped))
        )


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", required=True, help="Path to official GNU Unifont BMP PNG sheet.")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="Output WOFF2 path.")
    ap.add_argument("--version", default="17.0.04")
    ap.add_argument(
        "--text-file",
        action="append",
        default=None,
        help="File to scan for WebUI characters. Can be passed multiple times.",
    )
    ap.add_argument(
        "--embed-index",
        default=str(DEFAULT_INDEX),
        help="HTML file whose embedded GNU Unifont data URL should be replaced. Use empty string to disable.",
    )
    args = ap.parse_args(argv)

    text_files = [Path(p).resolve() for p in args.text_file] if args.text_file else DEFAULT_TEXT_FILES
    embed_index = Path(args.embed_index).resolve() if args.embed_index else None
    build_subset(Path(args.png).resolve(), Path(args.out).resolve(), args.version, text_files, embed_index)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
~~~~

#### `tools/compile_ark_bdf.py`

~~~~python
#!/usr/bin/env python3
"""Compile Ark Pixel Font 12px monospaced BDF into a compact WebUI bitmap table.

The WebUI does not render text through Canvas fonts for scrolling.  Instead, it
reads this JSON table and blits the original BDF glyph bitmap bits into the
370-LED text-scroll frame generator.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List, Optional


def hex_to_bits(row_hex: str, width: int) -> str:
    row_hex = "".join(ch for ch in row_hex.strip() if ch in "0123456789abcdefABCDEF")
    bits = "".join(f"{int(ch, 16):04b}" for ch in row_hex)
    return bits[: max(0, width)].ljust(max(0, width), "0")


def bits_to_hex(bits: str) -> str:
    if not bits:
        return ""
    pad = (-len(bits)) % 4
    bits = bits + ("0" * pad)
    out = []
    for i in range(0, len(bits), 4):
        out.append(f"{int(bits[i:i+4], 2):X}")
    return "".join(out)


def parse_bdf(path: Path, max_codepoint: Optional[int] = None) -> dict:
    lines = path.read_text("utf-8", errors="replace").splitlines()
    font = {
        "format": "rina_ark_pixel_font_bitmap_v1",
        "source": path.name,
        "family": "Ark Pixel 12px Monospaced",
        "rows": 12,
        "lineHeight": 12,
        "ascent": 10,
        "descent": 2,
        "defaultAdvance": 12,
        "glyphs": {},
    }

    # Global BDF metadata.
    for line in lines:
        if line.startswith("FONT_ASCENT "):
            font["ascent"] = int(line.split()[1])
        elif line.startswith("FONT_DESCENT "):
            font["descent"] = int(line.split()[1])
        elif line.startswith("PIXEL_SIZE "):
            font["rows"] = int(line.split()[1])
            font["lineHeight"] = int(line.split()[1])
        elif line.startswith("FONTBOUNDINGBOX "):
            parts = line.split()
            if len(parts) >= 3:
                font["rows"] = int(parts[2])
                font["lineHeight"] = int(parts[2])

    glyph_count = 0
    i = 0
    n = len(lines)
    while i < n:
        if not lines[i].startswith("STARTCHAR"):
            i += 1
            continue
        encoding = None
        dwidth = font["defaultAdvance"]
        bbx = [0, 0, 0, 0]  # width, height, xOffset, yOffset
        bitmap_rows: List[str] = []
        i += 1
        while i < n and not lines[i].startswith("ENDCHAR"):
            line = lines[i]
            if line.startswith("ENCODING "):
                try:
                    encoding = int(line.split()[1])
                except Exception:
                    encoding = None
            elif line.startswith("DWIDTH "):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        dwidth = int(parts[1])
                    except Exception:
                        pass
            elif line.startswith("BBX "):
                parts = line.split()
                if len(parts) >= 5:
                    bbx = [int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4])]
            elif line == "BITMAP":
                width, height, _xoff, _yoff = bbx
                bitmap_rows = []
                for j in range(height):
                    if i + 1 + j < n:
                        bitmap_rows.append(hex_to_bits(lines[i + 1 + j], width))
                i += height
            i += 1

        if encoding is not None and encoding >= 0 and (max_codepoint is None or encoding <= max_codepoint):
            width, height, xoff, yoff = bbx
            # BDF BBX yoff is relative to the baseline. Convert to top-down LED row.
            dst_y = int(font["ascent"]) - int(yoff) - int(height)
            packed_rows = "/".join(bits_to_hex(row) for row in bitmap_rows)
            cp_key = f"{encoding:04X}" if encoding <= 0xFFFF else f"{encoding:X}"
            # Compact glyph tuple: [advance,width,height,xOffset,yOffset,dstY,rowsHex]
            font["glyphs"][cp_key] = [int(dwidth), int(width), int(height), int(xoff), int(yoff), int(dst_y), packed_rows]
            glyph_count += 1
        i += 1

    if glyph_count == 0:
        raise RuntimeError(f"No glyphs parsed from {path}")
    return font


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Ark Pixel Font BDF file")
    ap.add_argument("--output", required=True, help="Output compact JSON table")
    ap.add_argument("--max-codepoint", default="0xFFFF", help="Limit output codepoints to keep LittleFS resource size bounded")
    args = ap.parse_args()

    max_cp = None if args.max_codepoint.lower() in {"none", "all"} else int(args.max_codepoint, 0)
    data = parse_bdf(Path(args.input), max_cp)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), "utf-8")
    print(f"[compile_ark_bdf] wrote {out} ({out.stat().st_size} bytes, {len(data['glyphs'])} glyphs)")


if __name__ == "__main__":
    main()
~~~~

#### `data/index.html`

~~~~html
<!doctype html>
<html data-boot-phase="preload" data-scroll-lock="boot" lang="zh-CN">
  <head>
    <meta charset="utf-8">
    <!-- 文档元数据和资源。SYNCTEST_MARKER -->
    <meta
      name="viewport"
      content="width=device-width, initial-scale=1, viewport-fit=cover"
    >
    <title>Rina WebUI V2</title>
    <!-- 启动预加载：这里只预加载第一张加载屏图片。 -->
    <!-- WebUI 字体和悬停加载图片刻意不在这里预加载。 -->
    <!-- 它们会在第 4 阶段首屏揭示后加载。 -->
    <link
      type="image/png"
      href="/resources/loading/rina_icon1_default.png"
      as="image"
      rel="preload"
    >
    <link
      type="image/png"
      href="/resources/loading/rina_icon1_default.png"
      rel="icon"
    >
    <link
      type="image/png"
      href="/resources/loading/rina_icon1_default.png"
      rel="shortcut icon"
    >
    <!-- 全局样式、布局规则和组件状态。 -->
    <link href="styles.css" rel="stylesheet">
  </head>
  <body>
    <!-- 启动/加载遮罩和应用外壳。 -->
    <div
      class="loading-overlay is-assets-pending"
      id="loadingOverlay"
      aria-label="页面加载中"
      aria-live="polite"
      role="status"
    >
      <div class="blur-screen" id="blurScreen" aria-hidden="true"></div>
      <div class="loading-box">
        <div class="loader-stage">
          <div class="flash-halo" aria-hidden="true"></div>
          <div class="avatar-circle">
            <img
              class="avatar-before"
              id="avatarBefore"
              src="./resources/loading/rina_icon1_default.png"
              alt=""
              height="96"
              width="96"
            >
            <img
              class="avatar-after"
              id="avatarAfter"
              data-src="./resources/loading/rina_icon2_hover.png"
              alt=""
              height="96"
              width="96"
            >
          </div>
        </div>
        <div class="loading-text">Loading</div>
      </div>
    </div>
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-copy">
          <h1>RinaChanBoard 370 LED</h1>
          <div class="row">
            <span class="badge mono">
              <span class="status-dot"></span> 运行中</span>
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
        <button
          class="brand-nav-toggle"
          id="brand-nav-toggle"
          type="button"
          aria-controls="top-page-nav"
          aria-expanded="false"
          aria-label="打开页面切换器"
        >
          <span class="menu-icon" aria-hidden="true">
            <span></span>
            <span></span>
            <span></span>
          </span>
        </button>
      </div>
    </aside>
    <!-- 页面选择顶栏由品牌区汉堡按钮打开，但保持在最高 UI 层。
    z-index 值接近实际可用上限，确保它位于
    卡片、矩阵和预览/控制面板之上。 -->
    <div class="top-page-nav" id="top-page-nav" aria-hidden="true">
      <div class="nav-shell" id="nav-shell">
        <div
          class="nav"
          id="nav"
          aria-hidden="true"
          role="menu"
        ></div>
      </div>
    </div>
    <div class="app">
      <!-- 主应用页面。 -->
      <main class="content">
        <section class="page active" id="page-basic">
          <div class="hero">
            <div>
              <h2>6.1 基础功能页面</h2>
            </div>
          </div>
          <div class="basic-layout">
            <div class="control-panel">
              <h3>颜色 / 亮度 / 保存表情 / A-M 模式</h3>
              <div class="card control-section flush">
                <h4>颜色控制</h4>
                <div class="color-control-row">
                  <div class="color-swatch" id="color-swatch"></div>
                  <div class="field">
                    <label>当前颜色</label>
                    <input
                      id="color-input"
                      autocomplete="off"
                      inputmode="text"
                      maxlength="7"
                      pattern="#?[0-9a-fA-F]{6}"
                      spellcheck="false"
                      value="#f971d4"
                    >
                  </div>
                </div>
                <div class="color-dropdown-grid">
                  <div class="field">
                    <label>父颜色</label>
                    <div class="select-shell">
                      <select id="parent-color-select"></select>
                      <span class="select-caret" aria-hidden="true">▾</span>
                    </div>
                  </div>
                  <div class="field">
                    <label>子颜色</label>
                    <div class="select-shell">
                      <select id="child-color-select"></select>
                      <span class="select-caret" aria-hidden="true">▾</span>
                    </div>
                  </div>
                </div>
              </div>
              <div class="card control-section">
                <h4>亮度控制</h4>
                <div class="slider-step-row">
                  <button id="brightness-reset-default" type="button">重置默认亮度</button>
                  <button
                    class="compact-btn push-right"
                    id="brightness-minus"
                    type="button"
                  >
                    −8
                  </button>
                  <button class="compact-btn" id="brightness-plus" type="button">+8</button>
                </div>
                <div class="brightness-row">
                  <input
                    id="brightness-range"
                    type="range"
                    max="200"
                    min="10"
                    step="1"
                    value="50"
                  >
                  <input
                    class="slider-number"
                    id="brightness-input"
                    type="number"
                    aria-label="raw 亮度"
                    max="200"
                    min="10"
                    value="50"
                  >
                </div>
                <div class="button-row" id="brightness-presets"></div>
              </div>
              <div class="card control-section">
                <h4>保存表情切换 / A-M 模式</h4>
                <div class="button-row mode-button-row">
                  <button
                    id="face-prev"
                    type="button"
                    title="上一个"
                    aria-label="上一个"
                  >←</button>
                  <button
                    id="face-next"
                    type="button"
                    title="下一个"
                    aria-label="下一个"
                  >→</button>
                  <button
                    class="toggle-button"
                    id="mode-toggle"
                    type="button"
                    aria-pressed="false"
                  >M 手动</button>
                  <button
                    class="compact-btn push-right"
                    id="interval-down"
                    type="button"
                  >
                    −0.5
                  </button>
                  <button class="compact-btn" id="interval-up" type="button">+0.5</button>
                </div>
                <div class="brightness-row">
                  <input
                    id="auto-interval-range"
                    type="range"
                    max="10"
                    min="0.5"
                    step="0.1"
                    value="3"
                  >
                  <input
                    class="slider-number"
                    id="auto-interval"
                    type="number"
                    aria-label="自动切换间隔 秒"
                    max="10"
                    min="0.5"
                    step="0.1"
                    value="3"
                  >
                </div>
                <div class="button-row" id="auto-interval-presets"></div>
              </div>
            </div>
            <div class="card basic-preview-card led-preview-card">
              <h3>370 LED 只读预览</h3>
              <div class="matrix-wrap fill-column led-preview-wrap">
                <div class="matrix" id="matrix-basic"></div>
              </div>
            </div>
          </div>
        </section>
        <section class="page" id="page-custom">
          <div class="hero">
            <div>
              <h2>6.2 自定义表情页面</h2>
            </div>
            <div class="row">
              <button class="primary" id="custom-send" type="button">发送</button>
              <button
                class="toggle-button"
                id="custom-live-toggle"
                type="button"
                aria-pressed="false"
              >实时</button>
              <button id="custom-clear" type="button">清空</button>
              <button id="custom-fill" type="button">全亮</button>
              <button id="custom-invert" type="button">反转</button>
            </div>
          </div>
          <div class="grid cols-2">
            <div class="card stack led-preview-card">
              <h3>自定义画板</h3>
              <div class="matrix-wrap fill-column led-preview-wrap">
                <div class="matrix" id="matrix-custom-edit"></div>
              </div>
            </div>
            <div class="card stack face-manager-panel" data-manager="custom">
              <h3>M370 / 保存管理</h3>
              <textarea id="custom-m370" spellcheck="false"></textarea>
              <div class="row">
                <button id="custom-copy" type="button">复制 M370</button>
                <button id="custom-import" type="button">从文本导入到画板</button>
                <button class="ok" id="custom-save" type="button">保存自定义表情</button>
                <div class="field">
                  <label>保存名称</label>
                  <input id="custom-name" value="custom_face">
                </div>
              </div>
              <h4>统一 saved_faces.json</h4>
              <div class="row">
                <button class="faces-json-load" type="button">读取 saved_faces.json</button>
                <button class="faces-json-open-local" type="button">打开本地 saved_faces.json</button>
                <button class="faces-json-save-local" type="button">保存到已打开文件</button>
                <button class="faces-json-download-all" type="button">下载 saved_faces.json</button>
                <button class="faces-json-import-btn" type="button">导入 saved_faces.json</button>
                <input
                  class="faces-json-import-file"
                  type="file"
                  accept="application/json"
                  hidden
                >
              </div>
              <h4>统一表情列表</h4>
              <div class="list face-library-list"></div>
            </div>
          </div>
        </section>
        <section class="page" id="page-parts">
          <div class="hero">
            <div>
              <h2>6.3 表情部件组合页面</h2>
            </div>
            <div class="row">
              <button class="primary" id="parts-apply" type="button">发送</button>
              <button
                class="toggle-button"
                id="parts-live-toggle"
                type="button"
                aria-pressed="false"
              >实时</button>
              <button id="parts-random" type="button">随机</button>
              <button id="parts-reset" type="button">默认</button>
              <button
                class="toggle-button"
                id="parts-symmetry-toggle"
                type="button"
                title="开启后左右眼按显示编号同步，手动选择和随机均生效"
                aria-pressed="false"
              >左右眼对称</button>
            </div>
          </div>
          <div class="parts-outer-layout">
            <div class="parts-left-col">
              <div class="card stack led-preview-card" id="parts-preview-card">
                <h3>组合预览</h3>
                <div class="matrix-wrap fill-column led-preview-wrap">
                  <div class="matrix" id="matrix-parts"></div>
                </div>
              </div>
              <div class="grid" id="part-groups"></div>
            </div>
            <div
              class="card stack face-manager-panel parts-manager-col"
              data-manager="parts"
            >
              <h3>M370 / 保存管理</h3>
              <textarea id="parts-m370-text" spellcheck="false"></textarea>
              <div class="row">
                <button id="parts-copy-m370" type="button">复制 M370</button>
                <button id="parts-import-m370" type="button">从文本导入到当前输出</button>
                <button class="ok" id="parts-save-bottom" type="button">保存部件表情</button>
                <div class="field">
                  <label>保存名称</label>
                  <input id="parts-name" value="parts_face">
                </div>
              </div>
              <h4>统一 saved_faces.json</h4>
              <div class="row">
                <button class="faces-json-load" type="button">读取 saved_faces.json</button>
                <button class="faces-json-open-local" type="button">打开本地 saved_faces.json</button>
                <button class="faces-json-save-local" type="button">保存到已打开文件</button>
                <button class="faces-json-download-all" type="button">下载 saved_faces.json</button>
                <button class="faces-json-import-btn" type="button">导入 saved_faces.json</button>
                <input
                  class="faces-json-import-file"
                  type="file"
                  accept="application/json"
                  hidden
                >
              </div>
              <h4>统一表情列表</h4>
              <div class="list face-library-list"></div>
            </div>
          </div>
        </section>
        <section class="page" id="page-scroll">
          <div class="hero">
            <div>
              <h2>6.4 文字滚动页面</h2>
            </div>
          </div>
          <div class="grid cols-2">
            <div class="card stack led-preview-card">
              <h3>文字滚动 370 LED 预览</h3>
              <div class="matrix-wrap fill-column led-preview-wrap">
                <div class="matrix" id="matrix-scroll"></div>
              </div>
            </div>
            <div class="card stack">
              <h3>文字滚动控制</h3>
              <div class="field">
                <label>滚动文字</label>
                <textarea id="scroll-text" maxlength="1000" rows="1" spellcheck="false">RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード</textarea>
              </div>
              <div class="row">
                <div class="field">
                  <label>帧率 fps</label>
                  <input
                    id="scroll-speed"
                    type="number"
                    autocomplete="off"
                    inputmode="numeric"
                    max="120"
                    min="1"
                    pattern="[0-9]*"
                    step="1"
                    value="10"
                  >
                </div>
              </div>
              <div class="row">
                <button class="primary" id="scroll-play" type="button">发送</button>
                <button
                  class="toggle-button"
                  id="scroll-pause"
                  type="button"
                  aria-disabled="true"
                  aria-pressed="false"
                  disabled
                >暂停</button>
                <button id="scroll-stop" type="button">停止/清屏</button>
                <button id="scroll-step" type="button">单帧推进</button>
              </div>
              <div class="scroll-upload-progress" id="scroll-upload-progress" hidden>
                <progress id="scroll-upload-bar" max="100" value="0"></progress>
                <span class="scroll-upload-label" id="scroll-upload-label">等待发送</span>
              </div>
              <div class="kv">
                <span class="k">状态</span>
                <span id="scroll-state">idle</span>
                <span class="k">当前帧</span>
                <span id="scroll-frame-index">0</span>
              </div>
            </div>
          </div>
        </section>
        <section class="page" id="page-debug">
          <div class="hero">
            <div>
              <h2>6.5 调试页面</h2>
            </div>
          </div>
          <div class="debug-layout">
            <div class="card control-panel">
              <h3>主控制 / 状态信息</h3>
              <div class="kv status-merged" id="state-kv"></div>
              <div class="warning" id="dps-warning">⚠ 当前帧功耗估算超过 40W；固件不会自动限流，请手动降低亮度。</div>
              <div class="hint">亮度控制、保存表情切换和 A/M 模式操作控件位于 6.1 基础功能页面；本面板只显示统一状态，不重复主操作入口。</div>
            </div>
            <div class="card stack">
              <h3>GPIO / 按钮辅助指令</h3>
              <div class="row">
                <button data-gpio="B1" type="button">B1 下一个</button>
                <button data-gpio="B2" type="button">B2 上一个</button>
                <button data-gpio="B3" type="button">B3 A/M</button>
                <button data-gpio="B4" type="button">B4 亮度-</button>
                <button data-gpio="B5" type="button">B5 亮度+</button>
                <button data-gpio="B6S" type="button">B6 短按电量</button>
                <button data-gpio="B6L" type="button">B6 长按详情</button>
              </div>
              <div class="row">
                <button data-gpio="B3B1" type="button">B3+B1 间隔-</button>
                <button data-gpio="B3B2" type="button">B3+B2 间隔+</button>
                <button data-gpio="B6B3" type="button">B6+B3 网络信息</button>
              </div>
              <h4>LED / 协议测试</h4>
              <div class="row">
                <button id="debug-all-off" type="button">全黑</button>
                <button id="debug-all-on" type="button">全亮</button>
                <button id="debug-checker" type="button">棋盘</button>
                <button id="debug-border" type="button">边框</button>
                <button id="debug-current-face" type="button">当前保存表情</button>
              </div>
              <textarea id="debug-m370" placeholder="输入 93 hex 或 M370:&lt;93 hex&gt;"></textarea>
              <div class="row">
                <button id="debug-apply-m370" type="button">解析并应用 M370</button>
                <button id="debug-copy-status" type="button">复制状态 JSON</button>
                <button class="danger" id="debug-reset-storage" type="button">清空用户表情</button>
              </div>
            </div>
            <div class="card stack debug-measure-card">
              <h3>状态 / ADC / 网络</h3>
              <div class="debug-measure-grid">
                <div class="debug-measure-controls">
                  <div class="kv" id="debug-kv"></div>
                  <div class="row">
                    <button id="debug-refresh-power" type="button">刷新电池状态</button>
                    <button id="debug-reset-battery-min" type="button">重置最低电压</button>
                    <button id="debug-reset-battery-max" type="button">重置最高电压</button>
                  </div>
                  <div class="row">
                    <div class="field">
                      <label>ADC 调试 Vbat</label>
                      <input
                        id="battery-v"
                        type="number"
                        step="0.01"
                        value="7.42"
                      >
                    </div>
                    <div class="field">
                      <label>ADC 调试 Vcharge</label>
                      <input
                        id="charge-v"
                        type="number"
                        step="0.01"
                        value="5.10"
                      >
                    </div>
                    <button id="update-adc" type="button">更新 ADC 状态</button>
                  </div>
                </div>
                <div class="matrix-wrap fill-column led-preview-wrap">
                  <div class="matrix" id="matrix-debug"></div>
                </div>
              </div>
            </div>
            <div class="card stack debug-log-card">
              <h3>通信日志</h3>
              <div class="row">
                <input
                  id="serial-input"
                  placeholder="辅助命令 JSON，例如 {&quot;cmd&quot;:&quot;pause&quot;}"
                >
                <button id="serial-send" type="button">发送辅助命令</button>
                <button id="log-clear" type="button">清空日志</button>
                <button id="log-download" type="button">下载日志</button>
              </div>
              <div class="log" id="log"></div>
            </div>
            <div class="card stack">
              <h3>固件接口</h3>
              <div class="kv" id="firmware-kv"></div>
              <div class="row">
                <button id="firmware-ping" type="button">读取固件状态</button>
                <button id="firmware-pause" type="button">发送暂停指令</button>
              </div>
              <div class="hint">
                LED 输出只发送 <span class="mono">M370:&lt;93 hex&gt;</span>；颜色、亮度、模式、暂停、按钮、ADC/status 等通过辅助 JSON 指令发送。
              </div>
            </div>
            <div class="card stack">
              <h3>资源 / 系统</h3>
              <div class="kv" id="resource-kv"></div>
              <div class="hint">
                表情部件资源由 HTML 处理并合成为 M370；默认表情和用户保存表情都从同一个 /resources/saved_faces.json 读取，通过 /api/saved_faces 写回固件文件；type:"default" 项不可删除，但可重命名和排序。
              </div>
            </div>
          </div>
        </section>
      </main>
    </div>
    <!-- WebUI 运行时、LED 矩阵数据和固件 API 处理器。 -->
    <script>
'use strict';

/*
 * 可编辑的 WebUI 配置。
 * 优先在这里修改数值；下方运行时常量会从此对象派生。
 */
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
    fpsMax: 120,
    firmwareMaxFramesDefault: 3072,
    uploadChunkFrames: 24,
    maxTextChars: 1000
  },
  textScroll: {
    fontModel: 'ark_pixel_12px_monospaced_bdf_bitmap_v1',
    fontResource: '/resources/fonts/ark12.json',
    fontFamily: 'Ark Pixel 12px Monospaced',
    browserFontSample: 'RinaChanBoard 370 LED \u7ee7\u7eed \u6682\u505c \u3053\u3093\u306b\u3061\u306f \u7483\u5948\u3061\u3083\u3093\u30dc\u30fc\u30c9',
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
    holdMs: 150,
    haloBreathMs: 1620,
    haloPeakRatio: 0.5,
    haloToleranceMs: 24,
    haloContractMs: 300,
    imageReleaseMs: 1300,
    blurDurationMs: 500,
    extraMs: 120,
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
// -----------------------------------------------------------------------------
// 数据：表情/部件库
// -----------------------------------------------------------------------------
// 内嵌 LED 表情/部件库，供预览和固件载荷使用。
const EXPRESSION_PARTS = {
  "format": "rina_expression_parts_370_runtime_v4",
  "version": 4,
  "matrix": {
    "cols": 22,
    "rows": 18,
    "num_leds": 370,
    "row_lengths": [18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16],
    "row_valid_x_ranges": [
      [2, 19],
      [1, 20],
      [1, 20],
      [1, 20],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [1, 20],
      [1, 20],
      [1, 20],
      [2, 19],
      [3, 18]
    ],
    "serpentine": true,
    "serpentine_odd_rows_reversed": true
  },
  "encoding": {
    "row_hex": "local bitmap rows; bit7 is local x=0; use only size[0] bits",
    "m370": "93 hex chars; 370 logical cells scanned row-major by row_lengths and padded to 372 bits",
    "strip_indices": "physical serpentine LED indices mapped back to logical M370 cells when used as fallback"
  },
  "layout": {
    "eye_left": [{
      "x": 2,
      "y": 1,
      "w": 8,
      "h": 8,
      "mirror_x": false,
      "role": "left_eye"
    }],
    "eye_right": [{
      "x": 12,
      "y": 1,
      "w": 8,
      "h": 8,
      "mirror_x": false,
      "role": "right_eye"
    }],
    "mouth": [{
      "x": 7,
      "y": 9,
      "w": 8,
      "h": 8,
      "mirror_x": false,
      "role": "mouth"
    }],
    "cheek": [{
      "x": 2,
      "y": 9,
      "w": 4,
      "h": 4,
      "mirror_x": true,
      "role": "left_cheek"
    }, {
      "x": 16,
      "y": 9,
      "w": 4,
      "h": 4,
      "mirror_x": false,
      "role": "right_cheek"
    }]
  },
  "call": {
    "fields": {
      "leye": "left eye ID",
      "reye": "right eye ID",
      "mouth": "mouth ID",
      "cheek": "cheek ID"
    },
    "default_face": {
      "leye": 101,
      "reye": 201,
      "mouth": 301,
      "cheek": 400
    },
    "ids": {
      "leye": ["0", "101", "102", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112", "113", "114",
        "115", "116", "117", "118", "119", "120", "121", "122", "123", "124", "125", "126", "127"
      ],
      "reye": ["0", "201", "202", "203", "204", "205", "206", "207", "208", "209", "210", "211", "212", "213", "214",
        "215", "216", "217", "218", "219", "220", "221", "222", "223", "224", "225", "226", "227"
      ],
      "mouth": ["0", "301", "302", "303", "304", "305", "306", "307", "308", "309", "310", "311", "312", "313", "314",
        "315", "316", "317", "318", "319", "320", "321", "322", "323", "324", "325", "326", "327", "328", "329",
        "330", "331", "332"
      ],
      "cheek": ["400", "401", "402", "403", "404", "405"]
    },
    "map": {
      "leye": {
        "0": "0",
        "101": "101",
        "102": "102",
        "103": "103",
        "104": "104",
        "105": "105",
        "106": "106",
        "107": "107",
        "108": "108",
        "109": "109",
        "110": "110",
        "111": "111",
        "112": "112",
        "113": "113",
        "114": "114",
        "115": "115",
        "116": "116",
        "117": "117",
        "118": "118",
        "119": "119",
        "120": "120",
        "121": "121",
        "122": "122",
        "123": "123",
        "124": "124",
        "125": "125",
        "126": "126",
        "127": "127"
      },
      "reye": {
        "0": "0",
        "201": "201",
        "202": "202",
        "203": "203",
        "204": "204",
        "205": "205",
        "206": "206",
        "207": "207",
        "208": "208",
        "209": "209",
        "210": "210",
        "211": "211",
        "212": "212",
        "213": "213",
        "214": "214",
        "215": "215",
        "216": "216",
        "217": "217",
        "218": "218",
        "219": "219",
        "220": "220",
        "221": "221",
        "222": "222",
        "223": "223",
        "224": "224",
        "225": "225",
        "226": "226",
        "227": "227"
      },
      "mouth": {
        "0": "0",
        "301": "301",
        "302": "302",
        "303": "303",
        "304": "304",
        "305": "305",
        "306": "306",
        "307": "307",
        "308": "308",
        "309": "309",
        "310": "310",
        "311": "311",
        "312": "312",
        "313": "313",
        "314": "314",
        "315": "315",
        "316": "316",
        "317": "317",
        "318": "318",
        "319": "319",
        "320": "320",
        "321": "321",
        "322": "322",
        "323": "323",
        "324": "324",
        "325": "325",
        "326": "326",
        "327": "327",
        "328": "328",
        "329": "329",
        "330": "330",
        "331": "331",
        "332": "332"
      },
      "cheek": {
        "400": "0",
        "401": "401",
        "402": "402",
        "403": "403",
        "404": "404",
        "405": "405",
        "0": "0"
      }
    },
    "compose": "Resolve call IDs through call.map, OR selected parts by m370 or strip_indices, then apply selected color and global brightness."
  },
  "groups": {
    "empty": ["0"],
    "eye_left": ["101", "102", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112", "113", "114",
      "115", "116", "117", "118", "119", "120", "121", "122", "123", "124", "125", "126", "127"
    ],
    "eye_right": ["201", "202", "203", "204", "205", "206", "207", "208", "209", "210", "211", "212", "213", "214",
      "215", "216", "217", "218", "219", "220", "221", "222", "223", "224", "225", "226", "227"
    ],
    "mouth": ["301", "302", "303", "304", "305", "306", "307", "308", "309", "310", "311", "312", "313", "314", "315",
      "316", "317", "318", "319", "320", "321", "322", "323", "324", "325", "326", "327", "328", "329", "330",
      "331", "332"
    ],
    "cheek": ["401", "402", "403", "404", "405"]
  },
  "counts": {
    "stored_unique_parts": 92,
    "callable_ids": 93,
    "stored_by_group": {
      "empty": 1,
      "eye_left": 27,
      "eye_right": 27,
      "mouth": 32,
      "cheek": 5
    },
    "callable_by_group": {
      "empty": 1,
      "eye_left": 27,
      "eye_right": 27,
      "mouth": 32,
      "cheek": 6
    },
    "deduped_call_ids": ["400"]
  },
  "parts": {
    "0": {
      "id": 0,
      "name": "empty_000",
      "type": "empty",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "00", "00", "00"],
      "preview": ["........", "........", "........", "........", "........", "........", "........", "........"],
      "placement": [],
      "m370": "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [],
      "lit_count": 0,
      "bbox": null
    },
    "101": {
      "id": 101,
      "name": "left_eye_101",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "30", "30", "30", "30", "00"],
      "preview": ["........", "........", "........", "..##....", "..##....", "..##....", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000300000C0000300000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [82, 83, 116, 117, 126, 127, 160, 161],
      "lit_count": 8,
      "bbox": [4, 4, 5, 7]
    },
    "102": {
      "id": 102,
      "name": "left_eye_102",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "40", "30", "30", "30", "30", "00"],
      "preview": ["........", "........", ".#......", "..##....", "..##....", "..##....", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000080000300000C0000300000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [75, 82, 83, 116, 117, 126, 127, 160, 161],
      "lit_count": 9,
      "bbox": [3, 3, 5, 7]
    },
    "103": {
      "id": 103,
      "name": "left_eye_103",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "10", "28", "44", "00", "00"],
      "preview": ["........", "........", "........", "...#....", "..#.#...", ".#...#..", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000100000A000044000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [83, 115, 117, 125, 129],
      "lit_count": 5,
      "bbox": [3, 4, 7, 6]
    },
    "104": {
      "id": 104,
      "name": "left_eye_104",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "18", "24", "42", "00", "00"],
      "preview": ["........", "........", "........", "...##...", "..#..#..", ".#....#.", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000001800009000042000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [83, 84, 114, 117, 125, 130],
      "lit_count": 6,
      "bbox": [3, 4, 8, 6]
    },
    "105": {
      "id": 105,
      "name": "left_eye_105",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "10", "28", "44", "82", "00", "00"],
      "preview": ["........", "........", "...#....", "..#.#...", ".#...#..", "#.....#.", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000200002800011000082000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [73, 82, 84, 114, 118, 124, 130],
      "lit_count": 7,
      "bbox": [2, 3, 8, 6]
    },
    "106": {
      "id": 106,
      "name": "left_eye_106",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "60", "18", "04", "18", "60", "00"],
      "preview": ["........", "........", ".##.....", "...##...", ".....#..", "...##...", ".##.....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000C00001800001000018000180000000000000000000000000000000000000000000000000000000",
      "strip_indices": [74, 75, 83, 84, 114, 127, 128, 161, 162],
      "lit_count": 9,
      "bbox": [3, 3, 7, 7]
    },
    "107": {
      "id": 107,
      "name": "left_eye_107",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "60", "18", "04", "78", "00"],
      "preview": ["........", "........", "........", ".##.....", "...##...", ".....#..", ".####...", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000060000060000040001E0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [81, 82, 115, 116, 129, 159, 160, 161, 162],
      "lit_count": 9,
      "bbox": [3, 4, 7, 7]
    },
    "108": {
      "id": 108,
      "name": "left_eye_108",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "7E", "00", "00"],
      "preview": ["........", "........", "........", "........", "........", ".######.", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000007E000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [125, 126, 127, 128, 129, 130],
      "lit_count": 6,
      "bbox": [3, 6, 8, 6]
    },
    "109": {
      "id": 109,
      "name": "left_eye_109",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "7E", "A0", "40"],
      "preview": ["........", "........", "........", "........", "........", ".######.", "#.#.....", ".#......"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000007E000280000400000000000000000000000000000000000000000000000000",
      "strip_indices": [125, 126, 127, 128, 129, 130, 161, 163, 169],
      "lit_count": 9,
      "bbox": [2, 6, 8, 8]
    },
    "110": {
      "id": 110,
      "name": "left_eye_110",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "40", "3C", "00"],
      "preview": ["........", "........", "........", "........", "........", ".#......", "..####..", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000400000F0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [125, 158, 159, 160, 161],
      "lit_count": 5,
      "bbox": [3, 6, 7, 7]
    },
    "111": {
      "id": 111,
      "name": "left_eye_111",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "44", "38", "00"],
      "preview": ["........", "........", "........", "........", "........", ".#...#..", "..###...", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000440000E0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [125, 129, 159, 160, 161],
      "lit_count": 5,
      "bbox": [3, 6, 7, 7]
    },
    "112": {
      "id": 112,
      "name": "left_eye_112",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "42", "24", "18", "00", "00"],
      "preview": ["........", "........", "........", ".#....#.", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000004200009000018000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [81, 86, 114, 117, 127, 128],
      "lit_count": 6,
      "bbox": [3, 4, 8, 6]
    },
    "113": {
      "id": 113,
      "name": "left_eye_113",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "60", "1E", "00", "00"],
      "preview": ["........", "........", "........", "........", ".##.....", "...####.", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000001800001E000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [117, 118, 127, 128, 129, 130],
      "lit_count": 6,
      "bbox": [3, 5, 8, 6]
    },
    "114": {
      "id": 114,
      "name": "left_eye_114",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "70", "0C", "00", "00"],
      "preview": ["........", "........", "........", "........", ".###....", "....##..", "........", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000001C00000C000000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [116, 117, 118, 128, 129],
      "lit_count": 5,
      "bbox": [3, 5, 7, 6]
    },
    "115": {
      "id": 115,
      "name": "left_eye_115",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "60", "10", "0C", "00"],
      "preview": ["........", "........", "........", "........", ".##.....", "...#....", "....##..", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000018000010000030000000000000000000000000000000000000000000000000000000",
      "strip_indices": [117, 118, 127, 158, 159],
      "lit_count": 5,
      "bbox": [3, 5, 7, 7]
    },
    "116": {
      "id": 116,
      "name": "left_eye_116",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "30", "3C", "18", "00"],
      "preview": ["........", "........", "........", "........", "..##....", "..####..", "...##...", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000C00003C000060000000000000000000000000000000000000000000000000000000",
      "strip_indices": [116, 117, 126, 127, 128, 129, 159, 160],
      "lit_count": 8,
      "bbox": [4, 5, 7, 7]
    },
    "117": {
      "id": 117,
      "name": "left_eye_117",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "08", "10", "70", "30", "30", "00"],
      "preview": ["........", "........", "....#...", "...#....", ".###....", "..##....", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000010000100001C0000300000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [72, 83, 116, 117, 118, 126, 127, 160, 161],
      "lit_count": 9,
      "bbox": [3, 3, 6, 7]
    },
    "118": {
      "id": 118,
      "name": "left_eye_118",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "40", "20", "38", "30", "30", "00"],
      "preview": ["........", "........", ".#......", "..#.....", "..###...", "..##....", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000080000200000E0000300000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [75, 82, 115, 116, 117, 126, 127, 160, 161],
      "lit_count": 9,
      "bbox": [3, 3, 6, 7]
    },
    "119": {
      "id": 119,
      "name": "left_eye_119",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "30", "68", "78", "30", "00"],
      "preview": ["........", "........", "........", "..##....", ".##.#...", ".####...", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000300001A0000780000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [82, 83, 115, 117, 118, 125, 126, 127, 128, 160, 161],
      "lit_count": 11,
      "bbox": [3, 4, 6, 7]
    },
    "120": {
      "id": 120,
      "name": "left_eye_120",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "30", "68", "78", "B0", "40"],
      "preview": ["........", "........", "........", "..##....", ".##.#...", ".####...", "#.##....", ".#......"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000300001A0000780002C0000400000000000000000000000000000000000000000000000000",
      "strip_indices": [82, 83, 115, 117, 118, 125, 126, 127, 128, 160, 161, 163, 169],
      "lit_count": 13,
      "bbox": [2, 4, 6, 8]
    },
    "121": {
      "id": 121,
      "name": "left_eye_121",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "30", "70", "78", "30", "00"],
      "preview": ["........", "........", "........", "..##....", ".###....", ".####...", "..##....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000300001C0000780000C0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [82, 83, 116, 117, 118, 125, 126, 127, 128, 160, 161],
      "lit_count": 11,
      "bbox": [3, 4, 6, 7]
    },
    "122": {
      "id": 122,
      "name": "left_eye_122",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "38", "44", "08", "10", "00", "10"],
      "preview": ["........", "........", "..###...", ".#...#..", "....#...", "...#....", "........", "...#...."],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000700004400002000010000000000100000000000000000000000000000000000000000000000000",
      "strip_indices": [72, 73, 74, 81, 85, 115, 127, 171],
      "lit_count": 8,
      "bbox": [3, 3, 7, 8]
    },
    "123": {
      "id": 123,
      "name": "left_eye_123",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "44", "28", "10", "28", "44", "00"],
      "preview": ["........", "........", ".#...#..", "..#.#...", "...#....", "..#.#...", ".#...#..", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000880002800004000028000110000000000000000000000000000000000000000000000000000000",
      "strip_indices": [71, 75, 82, 84, 116, 126, 128, 158, 162],
      "lit_count": 9,
      "bbox": [3, 3, 7, 7]
    },
    "124": {
      "id": 124,
      "name": "left_eye_124",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "10", "38", "7C", "38", "10", "00"],
      "preview": ["........", "........", "...#....", "..###...", ".#####..", "..###...", "...#....", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000020000380001F000038000040000000000000000000000000000000000000000000000000000000",
      "strip_indices": [73, 82, 83, 84, 114, 115, 116, 117, 118, 126, 127, 128, 160],
      "lit_count": 13,
      "bbox": [3, 3, 7, 7]
    },
    "125": {
      "id": 125,
      "name": "left_eye_125",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "38", "44", "44", "44", "38", "00"],
      "preview": ["........", "........", "..###...", ".#...#..", ".#...#..", ".#...#..", "..###...", "........"],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000007000044000110000440000E0000000000000000000000000000000000000000000000000000000",
      "strip_indices": [72, 73, 74, 81, 85, 114, 118, 125, 129, 159, 160, 161],
      "lit_count": 12,
      "bbox": [3, 3, 7, 7]
    },
    "126": {
      "id": 126,
      "name": "left_eye_126",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "10", "28", "44", "82", "44", "28", "10"],
      "preview": ["........", "...#....", "..#.#...", ".#...#..", "#.....#.", ".#...#..", "..#.#...", "...#...."],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000200005000044000208000440000A0000100000000000000000000000000000000000000000000000000",
      "strip_indices": [42, 72, 74, 81, 85, 113, 119, 125, 129, 159, 161, 171],
      "lit_count": 12,
      "bbox": [2, 2, 8, 8]
    },
    "127": {
      "id": 127,
      "name": "left_eye_127",
      "type": "eye_left",
      "size": [8, 8],
      "row_hex": ["00", "00", "6C", "92", "82", "44", "28", "10"],
      "preview": ["........", "........", ".##.##..", "#..#..#.", "#.....#.", ".#...#..", "..#.#...", "...#...."],
      "placement": [{
        "x": 2,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000D800092000208000440000A0000100000000000000000000000000000000000000000000000000",
      "strip_indices": [71, 72, 74, 75, 80, 83, 86, 113, 119, 125, 129, 159, 161, 171],
      "lit_count": 14,
      "bbox": [2, 3, 8, 8]
    },
    "201": {
      "id": 201,
      "name": "right_eye_201",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "0C", "0C", "0C", "0C", "00"],
      "preview": ["........", "........", "........", "....##..", "....##..", "....##..", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000300000C0000300000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [94, 95, 104, 105, 138, 139, 148, 149],
      "lit_count": 8,
      "bbox": [16, 4, 17, 7]
    },
    "202": {
      "id": 202,
      "name": "right_eye_202",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "02", "0C", "0C", "0C", "0C", "00"],
      "preview": ["........", "........", "......#.", "....##..", "....##..", "....##..", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000010000300000C0000300000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [60, 94, 95, 104, 105, 138, 139, 148, 149],
      "lit_count": 9,
      "bbox": [16, 3, 18, 7]
    },
    "203": {
      "id": 203,
      "name": "right_eye_203",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "08", "14", "22", "00", "00"],
      "preview": ["........", "........", "........", "....#...", "...#.#..", "..#...#.", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000000002000014000088000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [94, 104, 106, 136, 140],
      "lit_count": 5,
      "bbox": [14, 4, 18, 6]
    },
    "204": {
      "id": 204,
      "name": "right_eye_204",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "18", "24", "42", "00", "00"],
      "preview": ["........", "........", "........", "...##...", "..#..#..", ".#....#.", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000000006000024000108000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [93, 94, 104, 107, 135, 140],
      "lit_count": 6,
      "bbox": [13, 4, 18, 6]
    },
    "205": {
      "id": 205,
      "name": "right_eye_205",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "08", "14", "22", "41", "00", "00"],
      "preview": ["........", "........", "....#...", "...#.#..", "..#...#.", ".#.....#", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000400005000022000104000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [62, 93, 95, 103, 107, 135, 141],
      "lit_count": 7,
      "bbox": [13, 3, 19, 6]
    },
    "206": {
      "id": 206,
      "name": "right_eye_206",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "06", "18", "20", "18", "06", "00"],
      "preview": ["........", "........", ".....##.", "...##...", "..#.....", "...##...", ".....##.", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000300006000020000060000060000000000000000000000000000000000000000000000000000",
      "strip_indices": [60, 61, 93, 94, 107, 137, 138, 147, 148],
      "lit_count": 9,
      "bbox": [14, 3, 18, 7]
    },
    "207": {
      "id": 207,
      "name": "right_eye_207",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "06", "18", "20", "1E", "00"],
      "preview": ["........", "........", "........", ".....##.", "...##...", "..#.....", "...####.", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000018000180000800001E0000000000000000000000000000000000000000000000000000",
      "strip_indices": [95, 96, 105, 106, 136, 147, 148, 149, 150],
      "lit_count": 9,
      "bbox": [14, 4, 18, 7]
    },
    "208": {
      "id": 208,
      "name": "right_eye_208",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "7E", "00", "00"],
      "preview": ["........", "........", "........", "........", "........", ".######.", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000001F8000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [135, 136, 137, 138, 139, 140],
      "lit_count": 6,
      "bbox": [13, 6, 18, 6]
    },
    "209": {
      "id": 209,
      "name": "right_eye_209",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "7E", "05", "02"],
      "preview": ["........", "........", "........", "........", "........", ".######.", ".....#.#", "......#."],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000001F8000050000080000000000000000000000000000000000000000000000",
      "strip_indices": [135, 136, 137, 138, 139, 140, 146, 148, 184],
      "lit_count": 9,
      "bbox": [13, 6, 19, 8]
    },
    "210": {
      "id": 210,
      "name": "right_eye_210",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "02", "3C", "00"],
      "preview": ["........", "........", "........", "........", "........", "......#.", "..####..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000080003C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [140, 148, 149, 150, 151],
      "lit_count": 5,
      "bbox": [14, 6, 18, 7]
    },
    "211": {
      "id": 211,
      "name": "right_eye_211",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "00", "22", "1C", "00"],
      "preview": ["........", "........", "........", "........", "........", "..#...#.", "...###..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000880001C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [136, 140, 148, 149, 150],
      "lit_count": 5,
      "bbox": [14, 6, 18, 7]
    },
    "212": {
      "id": 212,
      "name": "right_eye_212",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "42", "24", "18", "00", "00"],
      "preview": ["........", "........", "........", ".#....#.", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000000010800024000060000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [91, 96, 104, 107, 137, 138],
      "lit_count": 6,
      "bbox": [13, 4, 18, 6]
    },
    "213": {
      "id": 213,
      "name": "right_eye_213",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "06", "78", "00", "00"],
      "preview": ["........", "........", "........", "........", ".....##.", ".####...", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000060001E0000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [103, 104, 135, 136, 137, 138],
      "lit_count": 6,
      "bbox": [13, 5, 18, 6]
    },
    "214": {
      "id": 214,
      "name": "right_eye_214",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "0E", "30", "00", "00"],
      "preview": ["........", "........", "........", "........", "....###.", "..##....", "........", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000E0000C0000000000000000000000000000000000000000000000000000000000",
      "strip_indices": [103, 104, 105, 136, 137],
      "lit_count": 5,
      "bbox": [14, 5, 18, 6]
    },
    "215": {
      "id": 215,
      "name": "right_eye_215",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "06", "08", "30", "00"],
      "preview": ["........", "........", "........", "........", ".....##.", "....#...", "..##....", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000006000020000300000000000000000000000000000000000000000000000000000",
      "strip_indices": [103, 104, 138, 150, 151],
      "lit_count": 5,
      "bbox": [14, 5, 18, 7]
    },
    "216": {
      "id": 216,
      "name": "right_eye_216",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "0C", "3C", "18", "00"],
      "preview": ["........", "........", "........", "........", "....##..", "..####..", "...##...", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000C0000F0000180000000000000000000000000000000000000000000000000000",
      "strip_indices": [104, 105, 136, 137, 138, 139, 149, 150],
      "lit_count": 8,
      "bbox": [14, 5, 17, 7]
    },
    "217": {
      "id": 217,
      "name": "right_eye_217",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "10", "08", "0E", "0C", "0C", "00"],
      "preview": ["........", "........", "...#....", "....#...", "....###.", "....##..", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000080000200000E0000300000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [63, 94, 103, 104, 105, 138, 139, 148, 149],
      "lit_count": 9,
      "bbox": [15, 3, 18, 7]
    },
    "218": {
      "id": 218,
      "name": "right_eye_218",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "02", "04", "1C", "0C", "0C", "00"],
      "preview": ["........", "........", "......#.", ".....#..", "...###..", "....##..", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000010000100001C0000300000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [60, 95, 104, 105, 106, 138, 139, 148, 149],
      "lit_count": 9,
      "bbox": [15, 3, 18, 7]
    },
    "219": {
      "id": 219,
      "name": "right_eye_219",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "0C", "16", "1E", "0C", "00"],
      "preview": ["........", "........", "........", "....##..", "...#.##.", "...####.", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000030000160000780000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [94, 95, 103, 104, 106, 137, 138, 139, 140, 148, 149],
      "lit_count": 11,
      "bbox": [15, 4, 18, 7]
    },
    "220": {
      "id": 220,
      "name": "right_eye_220",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "0C", "16", "1E", "0D", "02"],
      "preview": ["........", "........", "........", "....##..", "...#.##.", "...####.", "....##.#", "......#."],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000030000160000780000D0000080000000000000000000000000000000000000000000000",
      "strip_indices": [94, 95, 103, 104, 106, 137, 138, 139, 140, 146, 148, 149, 184],
      "lit_count": 13,
      "bbox": [15, 4, 19, 8]
    },
    "221": {
      "id": 221,
      "name": "right_eye_221",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "0C", "0E", "1E", "0C", "00"],
      "preview": ["........", "........", "........", "....##..", "....###.", "...####.", "....##..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000300000E0000780000C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [94, 95, 103, 104, 105, 137, 138, 139, 140, 148, 149],
      "lit_count": 11,
      "bbox": [15, 4, 18, 7]
    },
    "222": {
      "id": 222,
      "name": "right_eye_222",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "08", "08", "08", "08", "00", "08"],
      "preview": ["........", "........", "....#...", "....#...", "....#...", "....#...", "........", "....#..."],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000400002000008000020000000000200000000000000000000000000000000000000000000000",
      "strip_indices": [62, 94, 105, 138, 182],
      "lit_count": 5,
      "bbox": [16, 3, 16, 8]
    },
    "223": {
      "id": 223,
      "name": "right_eye_223",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "22", "14", "08", "14", "22", "00"],
      "preview": ["........", "........", "..#...#.", "...#.#..", "....#...", "...#.#..", "..#...#.", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000001100005000008000050000220000000000000000000000000000000000000000000000000000",
      "strip_indices": [60, 64, 93, 95, 105, 137, 139, 147, 151],
      "lit_count": 9,
      "bbox": [14, 3, 18, 7]
    },
    "224": {
      "id": 224,
      "name": "right_eye_224",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "08", "1C", "3E", "1C", "08", "00"],
      "preview": ["........", "........", "....#...", "...###..", "..#####.", "...###..", "....#...", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "00000000000000000040000700003E000070000080000000000000000000000000000000000000000000000000000",
      "strip_indices": [62, 93, 94, 95, 103, 104, 105, 106, 107, 137, 138, 139, 149],
      "lit_count": 13,
      "bbox": [14, 3, 18, 7]
    },
    "225": {
      "id": 225,
      "name": "right_eye_225",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "1C", "22", "22", "22", "1C", "00"],
      "preview": ["........", "........", "...###..", "..#...#.", "..#...#.", "..#...#.", "...###..", "........"],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000000E000088000220000880001C0000000000000000000000000000000000000000000000000000",
      "strip_indices": [61, 62, 63, 92, 96, 103, 107, 136, 140, 148, 149, 150],
      "lit_count": 12,
      "bbox": [14, 3, 18, 7]
    },
    "226": {
      "id": 226,
      "name": "right_eye_226",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "08", "14", "22", "41", "22", "14", "08"],
      "preview": ["........", "....#...", "...#.#..", "..#...#.", ".#.....#", "..#...#.", "...#.#..", "....#..."],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000040000A00008800041000088000140000200000000000000000000000000000000000000000000000",
      "strip_indices": [53, 61, 63, 92, 96, 102, 108, 136, 140, 148, 150, 182],
      "lit_count": 12,
      "bbox": [13, 2, 19, 8]
    },
    "227": {
      "id": 227,
      "name": "right_eye_227",
      "type": "eye_right",
      "size": [8, 8],
      "row_hex": ["00", "00", "36", "49", "41", "22", "14", "08"],
      "preview": ["........", "........", "..##.##.", ".#..#..#", ".#.....#", "..#...#.", "...#.#..", "....#..."],
      "placement": [{
        "x": 12,
        "y": 1,
        "mirror_x": false
      }],
      "m370": "000000000000000001B00012400041000088000140000200000000000000000000000000000000000000000000000",
      "strip_indices": [60, 61, 63, 64, 91, 94, 97, 102, 108, 136, 140, 148, 150, 182],
      "lit_count": 14,
      "bbox": [13, 3, 19, 8]
    },
    "301": {
      "id": 301,
      "name": "mouth_301",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "7E", "00", "00", "00"],
      "preview": ["........", "........", "........", "........", ".######.", "........", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000000000000000000001F800000000000000000000",
      "strip_indices": [283, 284, 285, 286, 287, 288],
      "lit_count": 6,
      "bbox": [8, 13, 13, 13]
    },
    "302": {
      "id": 302,
      "name": "mouth_302",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "81", "7E", "00", "00", "00"],
      "preview": ["........", "........", "........", "#......#", ".######.", "........", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000000000000000408001F800000000000000000000",
      "strip_indices": [261, 268, 283, 284, 285, 286, 287, 288],
      "lit_count": 8,
      "bbox": [7, 12, 14, 13]
    },
    "303": {
      "id": 303,
      "name": "mouth_303",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "00", "7E", "81", "00", "00"],
      "preview": ["........", "........", "........", "........", ".######.", "#......#", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000000000000000000001F800204000000000000000",
      "strip_indices": [283, 284, 285, 286, 287, 288, 302, 309],
      "lit_count": 8,
      "bbox": [7, 13, 14, 14]
    },
    "304": {
      "id": 304,
      "name": "mouth_304",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "81", "42", "3C", "00", "00"],
      "preview": ["........", "........", "........", "#......#", ".#....#.", "..####..", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000000000000000000000000000000000040800108000F0000000000000000",
      "strip_indices": [261, 268, 283, 288, 304, 305, 306, 307],
      "lit_count": 8,
      "bbox": [7, 12, 14, 14]
    },
    "305": {
      "id": 305,
      "name": "mouth_305",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "81", "42", "24", "18", "00", "00"],
      "preview": ["........", "........", "#......#", ".#....#.", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000001020002100009000060000000000000000",
      "strip_indices": [239, 246, 262, 267, 284, 287, 305, 306],
      "lit_count": 8,
      "bbox": [7, 11, 14, 14]
    },
    "306": {
      "id": 306,
      "name": "mouth_306",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "42", "24", "18", "00", "00"],
      "preview": ["........", "........", "........", ".#....#.", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000002100009000060000000000000000",
      "strip_indices": [262, 267, 284, 287, 305, 306],
      "lit_count": 6,
      "bbox": [8, 12, 13, 14]
    },
    "307": {
      "id": 307,
      "name": "mouth_307",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "18", "24", "42", "81", "00", "00"],
      "preview": ["........", "........", "...##...", "..#..#..", ".#....#.", "#......#", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000300001200010800204000000000000000",
      "strip_indices": [242, 243, 263, 266, 283, 288, 302, 309],
      "lit_count": 8,
      "bbox": [7, 11, 14, 14]
    },
    "308": {
      "id": 308,
      "name": "mouth_308",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "18", "24", "42", "00", "00"],
      "preview": ["........", "........", "........", "...##...", "..#..#..", ".#....#.", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000000C00009000108000000000000000",
      "strip_indices": [264, 265, 284, 287, 303, 308],
      "lit_count": 6,
      "bbox": [8, 12, 13, 14]
    },
    "309": {
      "id": 309,
      "name": "mouth_309",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "02", "85", "46", "3C", "00", "00"],
      "preview": ["........", "........", "......#.", "#....#.#", ".#...##.", "..####..", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000000000000000000000000000000400042800118000F0000000000000000",
      "strip_indices": [240, 261, 266, 268, 283, 284, 288, 304, 305, 306, 307],
      "lit_count": 11,
      "bbox": [7, 11, 14, 14]
    },
    "310": {
      "id": 310,
      "name": "mouth_310",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "FF", "81", "42", "24", "18", "00"],
      "preview": ["........", "........", "########", "#......#", ".#....#.", "..#..#..", "...##...", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000001FE0004080010800090000600000000000",
      "strip_indices": [239, 240, 241, 242, 243, 244, 245, 246, 261, 268, 283, 288, 304, 307, 325, 326],
      "lit_count": 16,
      "bbox": [7, 11, 14, 15]
    },
    "311": {
      "id": 311,
      "name": "mouth_311",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "FF", "81", "81", "42", "3C", "00"],
      "preview": ["........", "........", "########", "#......#", "#......#", ".#....#.", "..####..", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000001FE0004080020400108000F00000000000",
      "strip_indices": [239, 240, 241, 242, 243, 244, 245, 246, 261, 268, 282, 289, 303, 308, 324, 325, 326, 327],
      "lit_count": 18,
      "bbox": [7, 11, 14, 15]
    },
    "312": {
      "id": 312,
      "name": "mouth_312",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "3C", "42", "42", "24", "18", "00"],
      "preview": ["........", "........", "..####..", ".#....#.", ".#....#.", "..#..#..", "...##...", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000780002100010800090000600000000000",
      "strip_indices": [241, 242, 243, 244, 262, 267, 283, 288, 304, 307, 325, 326],
      "lit_count": 12,
      "bbox": [8, 11, 13, 15]
    },
    "313": {
      "id": 313,
      "name": "mouth_313",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "7E", "42", "24", "18", "00", "00"],
      "preview": ["........", "........", ".######.", ".#....#.", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000FC0002100009000060000000000000000",
      "strip_indices": [240, 241, 242, 243, 244, 245, 262, 267, 284, 287, 305, 306],
      "lit_count": 12,
      "bbox": [8, 11, 13, 14]
    },
    "314": {
      "id": 314,
      "name": "mouth_314",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "3C", "42", "81", "81", "FF", "00"],
      "preview": ["........", "........", "..####..", ".#....#.", "#......#", "#......#", "########", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000780002100020400204003FC0000000000",
      "strip_indices": [241, 242, 243, 244, 262, 267, 282, 289, 302, 309, 322, 323, 324, 325, 326, 327, 328, 329],
      "lit_count": 18,
      "bbox": [7, 11, 14, 15]
    },
    "315": {
      "id": 315,
      "name": "mouth_315",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "3C", "42", "42", "81", "7E", "00"],
      "preview": ["........", "........", "..####..", ".#....#.", ".#....#.", "#......#", ".######.", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000780002100010800204001F80000000000",
      "strip_indices": [241, 242, 243, 244, 262, 267, 283, 288, 302, 309, 323, 324, 325, 326, 327, 328],
      "lit_count": 16,
      "bbox": [7, 11, 14, 15]
    },
    "316": {
      "id": 316,
      "name": "mouth_316",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "18", "24", "42", "42", "24", "18"],
      "preview": ["........", "........", "...##...", "..#..#..", ".#....#.", ".#....#.", "..#..#..", "...##..."],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000000000030000120001080010800090000C000000",
      "strip_indices": [242, 243, 263, 266, 283, 288, 303, 308, 324, 327, 344, 345],
      "lit_count": 12,
      "bbox": [8, 11, 13, 16]
    },
    "317": {
      "id": 317,
      "name": "mouth_317",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "18", "24", "24", "24", "24", "18", "00"],
      "preview": ["........", "...##...", "..#..#..", "..#..#..", "..#..#..", "..#..#..", "...##...", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000000000000000000000000C0000480001200009000090000600000000000",
      "strip_indices": [220, 221, 241, 244, 263, 266, 284, 287, 304, 307, 325, 326],
      "lit_count": 12,
      "bbox": [9, 10, 12, 15]
    },
    "318": {
      "id": 318,
      "name": "mouth_318",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["18", "24", "24", "24", "24", "24", "18", "00"],
      "preview": ["...##...", "..#..#..", "..#..#..", "..#..#..", "..#..#..", "..#..#..", "...##...", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000030000120000480001200009000090000600000000000",
      "strip_indices": [198, 199, 219, 222, 241, 244, 263, 266, 284, 287, 304, 307, 325, 326],
      "lit_count": 14,
      "bbox": [9, 9, 12, 15]
    },
    "319": {
      "id": 319,
      "name": "mouth_319",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "18", "24", "24", "18", "00", "00"],
      "preview": ["........", "........", "...##...", "..#..#..", "..#..#..", "...##...", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000300001200009000060000000000000000",
      "strip_indices": [242, 243, 263, 266, 284, 287, 305, 306],
      "lit_count": 8,
      "bbox": [9, 11, 12, 14]
    },
    "320": {
      "id": 320,
      "name": "mouth_320",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "FF", "81", "FF", "00", "00"],
      "preview": ["........", "........", "........", "########", "#......#", "########", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000007F800204003FC000000000000000",
      "strip_indices": [261, 262, 263, 264, 265, 266, 267, 268, 282, 289, 302, 303, 304, 305, 306, 307, 308, 309],
      "lit_count": 18,
      "bbox": [7, 12, 14, 14]
    },
    "321": {
      "id": 321,
      "name": "mouth_321",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "FF", "81", "7E", "00", "00"],
      "preview": ["........", "........", "........", "########", "#......#", ".######.", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000007F800204001F8000000000000000",
      "strip_indices": [261, 262, 263, 264, 265, 266, 267, 268, 282, 289, 303, 304, 305, 306, 307, 308],
      "lit_count": 16,
      "bbox": [7, 12, 14, 14]
    },
    "322": {
      "id": 322,
      "name": "mouth_322",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "7E", "81", "FF", "00", "00"],
      "preview": ["........", "........", "........", ".######.", "#......#", "########", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000003F000204003FC000000000000000",
      "strip_indices": [262, 263, 264, 265, 266, 267, 282, 289, 302, 303, 304, 305, 306, 307, 308, 309],
      "lit_count": 16,
      "bbox": [7, 12, 14, 14]
    },
    "323": {
      "id": 323,
      "name": "mouth_323",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "7E", "42", "3C", "00", "00"],
      "preview": ["........", "........", "........", ".######.", ".#....#.", "..####..", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000003F000108000F0000000000000000",
      "strip_indices": [262, 263, 264, 265, 266, 267, 283, 288, 304, 305, 306, 307],
      "lit_count": 12,
      "bbox": [8, 12, 13, 14]
    },
    "324": {
      "id": 324,
      "name": "mouth_324",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "3C", "42", "7E", "00", "00"],
      "preview": ["........", "........", "........", "..####..", ".#....#.", ".######.", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000001E000108001F8000000000000000",
      "strip_indices": [263, 264, 265, 266, 283, 288, 303, 304, 305, 306, 307, 308],
      "lit_count": 12,
      "bbox": [8, 12, 13, 14]
    },
    "325": {
      "id": 325,
      "name": "mouth_325",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "7E", "42", "7E", "00", "00"],
      "preview": ["........", "........", "........", ".######.", ".#....#.", ".######.", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000003F000108001F8000000000000000",
      "strip_indices": [262, 263, 264, 265, 266, 267, 283, 288, 303, 304, 305, 306, 307, 308],
      "lit_count": 14,
      "bbox": [8, 12, 13, 14]
    },
    "326": {
      "id": 326,
      "name": "mouth_326",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "81", "42", "7E", "42", "81", "00"],
      "preview": ["........", "........", "#......#", ".#....#.", ".######.", ".#....#.", "#......#", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000000000102000210001F800108002040000000000",
      "strip_indices": [239, 246, 262, 267, 283, 284, 285, 286, 287, 288, 303, 308, 322, 329],
      "lit_count": 14,
      "bbox": [7, 11, 14, 15]
    },
    "327": {
      "id": 327,
      "name": "mouth_327",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "66", "99", "81", "99", "66", "00"],
      "preview": ["........", "........", ".##..##.", "#..##..#", "#......#", "#..##..#", ".##..##.", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000CC0004C80020400264001980000000000",
      "strip_indices": [240, 241, 244, 245, 261, 264, 265, 268, 282, 289, 302, 305, 306, 309, 323, 324, 327, 328],
      "lit_count": 18,
      "bbox": [7, 11, 14, 15]
    },
    "328": {
      "id": 328,
      "name": "mouth_328",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "66", "99", "00", "00", "00"],
      "preview": ["........", "........", "........", ".##..##.", "#..##..#", "........", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000003300026400000000000000000000",
      "strip_indices": [262, 263, 266, 267, 282, 285, 286, 289],
      "lit_count": 8,
      "bbox": [7, 12, 14, 13]
    },
    "329": {
      "id": 329,
      "name": "mouth_329",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "24", "5A", "00", "00", "00"],
      "preview": ["........", "........", "........", "..#..#..", ".#.##.#.", "........", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000001200016800000000000000000000",
      "strip_indices": [263, 266, 283, 285, 286, 288],
      "lit_count": 6,
      "bbox": [8, 12, 13, 13]
    },
    "330": {
      "id": 330,
      "name": "mouth_330",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "42", "5A", "24", "00", "00"],
      "preview": ["........", "........", "........", ".#....#.", ".#.##.#.", "..#..#..", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000000002100016800090000000000000000",
      "strip_indices": [262, 267, 283, 285, 286, 288, 304, 307],
      "lit_count": 8,
      "bbox": [8, 12, 13, 14]
    },
    "331": {
      "id": 331,
      "name": "mouth_331",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "42", "5A", "24", "00", "00", "00"],
      "preview": ["........", "........", ".#....#.", ".#.##.#.", "..#..#..", "........", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000000000000840002D00009000000000000000000000",
      "strip_indices": [240, 245, 262, 264, 265, 267, 284, 287],
      "lit_count": 8,
      "bbox": [8, 11, 13, 13]
    },
    "332": {
      "id": 332,
      "name": "mouth_332",
      "type": "mouth",
      "size": [8, 8],
      "row_hex": ["00", "00", "00", "02", "52", "2C", "00", "00"],
      "preview": ["........", "........", "........", "......#.", ".#.#..#.", "..#.##..", "........", "........"],
      "placement": [{
        "x": 7,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "0000000000000000000000000000000000000000000000000000000000000000001000148000B0000000000000000",
      "strip_indices": [267, 283, 286, 288, 304, 306, 307],
      "lit_count": 7,
      "bbox": [8, 12, 13, 14]
    },
    "401": {
      "id": 401,
      "name": "cheek_401",
      "type": "cheek",
      "size": [4, 4],
      "row_hex": ["00", "60", "00", "00"],
      "preview": ["....", ".##.", "....", "...."],
      "placement": [{
        "x": 2,
        "y": 9,
        "mirror_x": true
      }, {
        "x": 16,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000000000006001800000000000000000000000000000000000",
      "strip_indices": [213, 214, 227, 228],
      "lit_count": 4,
      "bbox": [3, 10, 18, 10]
    },
    "402": {
      "id": 402,
      "name": "cheek_402",
      "type": "cheek",
      "size": [4, 4],
      "row_hex": ["00", "50", "00", "00"],
      "preview": ["....", ".#.#", "....", "...."],
      "placement": [{
        "x": 2,
        "y": 9,
        "mirror_x": true
      }, {
        "x": 16,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000A001400000000000000000000000000000000000",
      "strip_indices": [212, 214, 227, 229],
      "lit_count": 4,
      "bbox": [2, 10, 19, 10]
    },
    "403": {
      "id": 403,
      "name": "cheek_403",
      "type": "cheek",
      "size": [4, 4],
      "row_hex": ["50", "A0", "00", "00"],
      "preview": [".#.#", "#.#.", "....", "...."],
      "placement": [{
        "x": 2,
        "y": 9,
        "mirror_x": true
      }, {
        "x": 16,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000002800505002800000000000000000000000000000000000",
      "strip_indices": [190, 192, 205, 207, 213, 215, 226, 228],
      "lit_count": 8,
      "bbox": [2, 9, 19, 10]
    },
    "404": {
      "id": 404,
      "name": "cheek_404",
      "type": "cheek",
      "size": [4, 4],
      "row_hex": ["A0", "50", "00", "00"],
      "preview": ["#.#.", ".#.#", "....", "...."],
      "placement": [{
        "x": 2,
        "y": 9,
        "mirror_x": true
      }, {
        "x": 16,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "000000000000000000000000000000000000000000000001400A0A001400000000000000000000000000000000000",
      "strip_indices": [191, 193, 204, 206, 212, 214, 227, 229],
      "lit_count": 8,
      "bbox": [2, 9, 19, 10]
    },
    "405": {
      "id": 405,
      "name": "cheek_405",
      "type": "cheek",
      "size": [4, 4],
      "row_hex": ["00", "70", "00", "70"],
      "preview": ["....", ".###", "....", ".###"],
      "placement": [{
        "x": 2,
        "y": 9,
        "mirror_x": true
      }, {
        "x": 16,
        "y": 9,
        "mirror_x": false
      }],
      "m370": "00000000000000000000000000000000000000000000000000000E001C000000E001C000000000000000000000000",
      "strip_indices": [212, 213, 214, 227, 228, 229, 256, 257, 258, 271, 272, 273],
      "lit_count": 12,
      "bbox": [2, 10, 19, 12]
    }
  }
};

// -----------------------------------------------------------------------------
// 配置别名和导航元数据
// -----------------------------------------------------------------------------
// 顶部导航使用的页面元数据。
const PAGES = [
  ['basic', '6.1', '基础功能'],
  ['custom', '6.2', '自定义表情'],
  ['parts', '6.3', '表情部件'],
  ['scroll', '6.4', '文字滚动'],
  ['debug', '6.5', '调试']
];

// 矩阵几何和固件/API 常量。
const MATRIX = EXPRESSION_PARTS.matrix;
const ROW_RANGES = MATRIX.row_valid_x_ranges;
const TOTAL_LEDS = MATRIX.num_leds;
const COLS = MATRIX.cols;
const ROWS = MATRIX.rows;
const FACE_LIBRARY_RESOURCE = WEBUI_CONFIG.faces.resourcePath;
const FACE_LIBRARY_FILENAME = WEBUI_CONFIG.faces.localFilename;
const FACE_SCHEMA_FORMAT = WEBUI_CONFIG.faces.schemaFormat;
const DEFAULT_STARTUP_FACE_ID = WEBUI_CONFIG.faces.startupFaceId;
const DEFAULT_LED_COLOR = WEBUI_CONFIG.led.defaultColor;
const LED_PREVIEW_SIZE = Object.freeze(WEBUI_CONFIG.led.previewSize);
const DEFAULT_LED_BRIGHTNESS = WEBUI_CONFIG.led.defaultBrightness;
const LED_ESTIMATED_WATTS_PER_CHANNEL = WEBUI_CONFIG.led.estimatedWattsPerChannel;
const LED_CHANNEL_COUNT = WEBUI_CONFIG.led.channelCount;
const LED_FULL_BRIGHTNESS = WEBUI_CONFIG.led.fullBrightness;
const LED_POWER_WARNING_WATTS = WEBUI_CONFIG.led.powerWarningWatts;
const MIN_LED_BRIGHTNESS = WEBUI_CONFIG.led.minBrightness;
const MAX_LED_BRIGHTNESS = WEBUI_CONFIG.led.maxBrightness;
const MAX_SCROLL_TEXT_CHARS = WEBUI_CONFIG.scroll.maxTextChars;
const DEVICE_AP_SSID = WEBUI_CONFIG.device.apSsid;
const DEVICE_AP_PASSWORD = WEBUI_CONFIG.device.apPassword;
const DEVICE_AP_DOMAIN = WEBUI_CONFIG.device.apDomain;
const DEFAULT_AP_IP = WEBUI_CONFIG.device.defaultApIp;
const AUTO_INTERVAL_MIN_MS = WEBUI_CONFIG.autoInterval.minMs;
const AUTO_INTERVAL_MAX_MS = WEBUI_CONFIG.autoInterval.maxMs;
const AUTO_INTERVAL_BUTTON_STEP_MS = WEBUI_CONFIG.autoInterval.buttonStepMs;
const AUTO_INTERVAL_PRESETS_MS = WEBUI_CONFIG.autoInterval.presetsMs;
const POWER_STATUS_REFRESH_MS = WEBUI_CONFIG.power.statusRefreshMs;
const API_GET_TIMEOUT_MS = WEBUI_CONFIG.api.getTimeoutMs;
const API_POST_TIMEOUT_MS = WEBUI_CONFIG.api.postTimeoutMs;
const API_UPLOAD_TIMEOUT_MS = WEBUI_CONFIG.api.uploadTimeoutMs;
const LAYOUT_ONE_COLUMN_MAX_PX = WEBUI_CONFIG.layout.oneColumnMaxPx;
const LAYOUT_THREE_COLUMNS_MIN_PX = WEBUI_CONFIG.layout.threeColumnsMinPx;
const API_ENDPOINTS = Object.freeze(WEBUI_CONFIG.api.endpoints);
const MATRIX_VIEW_CONFIGS = [
  ['matrix-basic', () => currentFrame, false, null, false],
  ['matrix-custom-edit', () => editFrame, true, editCell, false],
  ['matrix-parts', () => partsFrame, false, null, false],
  ['matrix-scroll', () => scrollFrame, false, null, false],
  ['matrix-debug', () => currentFrame, false, null, false]
];
const DEFAULT_SCROLL_FPS = WEBUI_CONFIG.scroll.defaultFps;
const SCROLL_FPS_MIN = WEBUI_CONFIG.scroll.fpsMin;
const SCROLL_FPS_MAX = WEBUI_CONFIG.scroll.fpsMax;
const FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT = WEBUI_CONFIG.scroll.firmwareMaxFramesDefault;
let firmwareScrollMaxFrames = FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT;
const SCROLL_UPLOAD_CHUNK_FRAMES = WEBUI_CONFIG.scroll.uploadChunkFrames;
const RUNTIME_STATUS_QUERY = WEBUI_CONFIG.api.runtimeStatusQuery;
const SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS = WEBUI_CONFIG.firmwareQueues.scrollButtonStopFullSyncDelayMs;
const WEBUI_M370_SEND_INTERVAL_MS = WEBUI_CONFIG.firmwareQueues.m370SendIntervalMs;
const WEBUI_M370_QUEUE_MAX = WEBUI_CONFIG.firmwareQueues.m370QueueMax;
const WEBUI_BUTTON_COMMAND_INTERVAL_MS = WEBUI_CONFIG.firmwareQueues.buttonCommandIntervalMs;
const WEBUI_BUTTON_COMMAND_QUEUE_MAX = WEBUI_CONFIG.firmwareQueues.buttonCommandQueueMax;

// -----------------------------------------------------------------------------
// 数据：颜色预设库
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// 矩阵几何以及物理/逻辑 LED 映射
// -----------------------------------------------------------------------------
const XY_TO_INDEX = Array.from({
  length: ROWS
}, () => Array(COLS).fill(-1));
const INDEX_TO_XY = [];
let ledIndex = 0;
for (let y = 0; y < ROWS; y++) {
  const [x0, x1] = ROW_RANGES[y];
  for (let x = x0; x <= x1; x++) {
    XY_TO_INDEX[y][x] = ledIndex;
    INDEX_TO_XY[ledIndex] = [x, y];
    ledIndex++;
  }
}
const SERPENTINE_WIRING = !!MATRIX.serpentine;
const SERPENTINE_ODD_ROWS_REVERSED = MATRIX.serpentine_odd_rows_reversed !== false;
const PHYSICAL_TO_LOGICAL_INDEX = Array(TOTAL_LEDS).fill(-1);

function logicalToPhysicalIndex(index) {
  const xy = INDEX_TO_XY[index];
  if (!xy || !SERPENTINE_WIRING) return index;
  const [x, y] = xy;
  if (!SERPENTINE_ODD_ROWS_REVERSED || (y & 1) === 0) return index;
  const [x0, x1] = ROW_RANGES[y];
  return XY_TO_INDEX[y][x0 + x1 - x];
}

function physicalToLogicalIndex(index) {
  return PHYSICAL_TO_LOGICAL_INDEX[index] ?? index;
}
for (let logical = 0; logical < TOTAL_LEDS; logical++) {
  PHYSICAL_TO_LOGICAL_INDEX[logicalToPhysicalIndex(logical)] = logical;
}

// -----------------------------------------------------------------------------
// 运行时状态
// -----------------------------------------------------------------------------
// WebUI 控件和固件之间同步的运行时状态。
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
  batteryV: null,
  batteryPercent: null,
  batteryPowered: true,
  batteryStateText: '电池',
  batteryMinV: null,
  batteryMaxV: null,
  batteryNominalMin: null,
  batteryNominalMax: null,
  batteryAdcMv: null,
  batteryPrevAdcMv: null,
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
let currentFrame = blankFrame();
let editFrame = blankFrame();
let partsFrame = blankFrame();
let scrollFrame = blankFrame();
let selectedCall = {
  leye: '101',
  reye: '201',
  mouth: '301',
  cheek: '400'
};
let partsSymmetry = false;
let liveSendEnabled = false;
let defaultFaces = [];
let userFaces = [];
let faceLibraryDocument = null;
let faceLibraryFileHandle = null;
let pointerFaceDrag = null;
let logs = [];
let frameSendInFlight = false;
let pendingFramePacket = null;
let frameSendQueue = [];
let frameSendTimer = 0;
let lastFrameSendAt = 0;
let buttonCommandQueue = [];
let buttonCommandInFlight = false;
let buttonCommandTimer = 0;
let lastButtonCommandAt = 0;
let lastApiErrorLogAt = 0;
let brightnessChangedByUser = false;
let firmwareStatusPollTimer = null;
let lastFirmwareStatusPollAt = 0;
let firmwareStatusVersion = null;
let firmwareNextPollMs = 1000;
let lastScrollStopEventSeq = 0;
let firmwareScrollStopFullSyncTimer = null;
let firmwareRuntimeSummaryInFlight = false;
let firmwareFullStatusInFlight = false;
let powerStatusPollTimer = null;
let lastPowerStatusRefreshAt = 0;
let powerStatusRefreshInFlight = false;
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
  sentFrames: 0,
  sentCommands: 0,
  droppedFrames: 0,
  droppedCommands: 0,
  frameQueue: 0,
  buttonQueue: 0,
  savedFacesSync: 'not loaded'
};
let matrixViews = [];
let scroll = {
  timer: null,
  active: false,
  paused: false,
  firmwareBacked: false,
  uploading: false,
  uploadProgress: 0,
  uploadLabel: '',
  offset: 0,
  frameIndex: 0,
  frames: [],
  signature: '',
  dirty: true,
  dirtyNoticeLogged: false,
  frameCounter: 0,
  fpsStarted: performance.now(),
  measuredFps: 0
};

// -----------------------------------------------------------------------------
// 共享辅助函数和 DOM 绑定
// -----------------------------------------------------------------------------
function safeJsonParse(text, fallback = {}) {
  try {
    return JSON.parse(text);
  } catch (e) {
    return fallback;
  }
}

function parseApiJson(text, path, fallback = {}) {
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`invalid JSON from ${path}: ${err.message || err}`);
  }
}
const boundControls = new WeakMap();

function bindControls(selector, eventName, handler) {
  document.querySelectorAll(selector).forEach(el => {
    const token = `${selector}:${eventName}`;
    let bound = boundControls.get(el);
    if (!bound) {
      bound = new Set();
      boundControls.set(el, bound);
    }
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
// -----------------------------------------------------------------------------
// 按钮按压反馈
// -----------------------------------------------------------------------------
const BUTTON_PRESS_DOWN_MS = WEBUI_CONFIG.interaction.buttonPressDownMs;
const BUTTON_PRESS_UP_MS = WEBUI_CONFIG.interaction.buttonPressUpMs;
let buttonPressAnimationsReady = false;
const buttonPressStates = new WeakMap();
const activeButtonPointers = new Map();

function pressableButtonFromTarget(target) {
  const button = target?.closest?.('button');
  if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return null;
  return button;
}

function clearButtonPressTimers(state) {
  if (!state) return;
  if (state.releaseTimer) clearTimeout(state.releaseTimer);
  if (state.cleanupTimer) clearTimeout(state.cleanupTimer);
}

function startButtonPressAnimation(button) {
  if (!button) return;
  const existing = buttonPressStates.get(button);
  clearButtonPressTimers(existing);
  const state = {
    startedAt: performance.now(),
    releaseTimer: 0,
    cleanupTimer: 0
  };
  buttonPressStates.set(button, state);
  button.classList.remove('is-releasing');
  button.classList.add('is-pressing');
}

function releaseButtonPressAnimation(button) {
  if (!button) return;
  const state = buttonPressStates.get(button);
  if (!state) {
    startButtonPressAnimation(button);
    return releaseButtonPressAnimation(button);
  }
  const elapsed = performance.now() - state.startedAt;
  const delay = Math.max(0, BUTTON_PRESS_DOWN_MS - elapsed);
  if (state.releaseTimer) clearTimeout(state.releaseTimer);
  state.releaseTimer = setTimeout(() => {
    button.classList.remove('is-pressing');
    button.classList.add('is-releasing');
    state.cleanupTimer = setTimeout(() => {
      button.classList.remove('is-releasing');
      if (buttonPressStates.get(button) === state) buttonPressStates.delete(button);
    }, BUTTON_PRESS_UP_MS);
  }, delay);
}

function cancelButtonPressAnimation(button) {
  if (!button) return;
  releaseButtonPressAnimation(button);
}

function initButtonPressAnimations() {
  if (buttonPressAnimationsReady) return;
  buttonPressAnimationsReady = true;
  document.addEventListener('pointerdown', ev => {
    if (ev.button !== undefined && ev.button !== 0) return;
    const button = pressableButtonFromTarget(ev.target);
    if (!button) return;
    activeButtonPointers.set(ev.pointerId, button);
    startButtonPressAnimation(button);
    try {
      button.setPointerCapture?.(ev.pointerId);
    } catch (_) {}
  }, {
    passive: true
  });
  document.addEventListener('pointerup', ev => {
    const button = activeButtonPointers.get(ev.pointerId);
    if (!button) return;
    activeButtonPointers.delete(ev.pointerId);
    releaseButtonPressAnimation(button);
  }, {
    passive: true
  });
  document.addEventListener('pointercancel', ev => {
    const button = activeButtonPointers.get(ev.pointerId);
    if (!button) return;
    activeButtonPointers.delete(ev.pointerId);
    cancelButtonPressAnimation(button);
  }, {
    passive: true
  });
  document.addEventListener('keydown', ev => {
    if (ev.repeat || (ev.key !== ' ' && ev.key !== 'Enter')) return;
    const button = pressableButtonFromTarget(ev.target);
    if (button) startButtonPressAnimation(button);
  });
  document.addEventListener('keyup', ev => {
    if (ev.key !== ' ' && ev.key !== 'Enter') return;
    const button = ev.target?.closest?.('button');
    if (button) releaseButtonPressAnimation(button);
  });
}
// -----------------------------------------------------------------------------
// 字体加载
// -----------------------------------------------------------------------------
const UI_WEB_FONT_FAMILY = WEBUI_CONFIG.fonts.uiFamily;
let uiFontObserverStarted = false;

function applyWebUiFont(root = document) {
  const nodes = [];
  if (root && root.nodeType === 1) nodes.push(root);
  const scope = root && root.querySelectorAll ? root : document;
  const selector = root === document ? 'body, body *' : '*';
  scope.querySelectorAll(selector).forEach(el => nodes.push(el));
  for (const el of nodes) {
    if (!el || el.id === 'scroll-text') continue;
    el.style.setProperty('font-family', `"${UI_WEB_FONT_FAMILY}"`, 'important');
  }
  applyTextScrollInputFont();
}
async function ensureWebUiFontReady() {
  document.documentElement.style.setProperty('--ui-font', `"${UI_WEB_FONT_FAMILY}"`);
  if (document.fonts && document.fonts.load) {
    try {
      await document.fonts.load(`16px "${UI_WEB_FONT_FAMILY}"`, 'RinaChanBoard 网页字体 继续 暂停 发送 停止 清屏 370 LED こんにちは');
      const loaded = document.fonts.check(`16px "${UI_WEB_FONT_FAMILY}"`,
        'RinaChanBoard 网页字体 继续 暂停 发送 停止 清屏 370 LED こんにちは');
      document.documentElement.dataset.uiFontLoaded = loaded ? 'true' : 'false';
    } catch (err) {
      document.documentElement.dataset.uiFontLoaded = 'false';
      console.warn('GNU Unifont WebUI font load failed', err);
    }
  }
  applyWebUiFont();
  // GNU Unifont 影响 textarea 字符的实际宽高，加载完成后必须重新测量，
  // 否则会保留用备用字体或字体未加载时算出的旧高度（最糟糕的情况
  // 是页面当时是 display:none，scrollHeight=0，导致 height:0px 装不下文字）。
  if (typeof autoResizeM370Textareas === 'function') autoResizeM370Textareas();
  if (typeof autoResizeScrollTextInput === 'function') autoResizeScrollTextInput();
}

function observeWebUiFont() {
  if (uiFontObserverStarted || !document.body || !window.MutationObserver) return;
  uiFontObserverStarted = true;
  new MutationObserver(records => {
    for (const rec of records) {
      rec.addedNodes && rec.addedNodes.forEach(node => {
        if (node && node.nodeType === 1) applyWebUiFont(node);
      });
    }
  }).observe(document.body, {
    childList: true,
    subtree: true
  });
}
// -----------------------------------------------------------------------------
// 文字滚动字体模型
// -----------------------------------------------------------------------------
const TEXT_SCROLL_FONT_MODEL = WEBUI_CONFIG.textScroll.fontModel;
const TEXT_SCROLL_FONT_RESOURCE = WEBUI_CONFIG.textScroll.fontResource;
const TEXT_SCROLL_FONT_FAMILY = WEBUI_CONFIG.textScroll.fontFamily;
const TEXT_SCROLL_BROWSER_FONT_SAMPLE = WEBUI_CONFIG.textScroll.browserFontSample;
let textScrollBrowserFontLoading = null;

function applyTextScrollInputFont() {
  const el = document.getElementById('scroll-text');
  if (!el) return;
  document.documentElement.style.setProperty('--scroll-font', `"${TEXT_SCROLL_FONT_FAMILY}"`);
  el.style.setProperty('font-family', `"${TEXT_SCROLL_FONT_FAMILY}"`, 'important');
  el.style.setProperty('font-size', '12px', 'important');
  el.style.setProperty('line-height', '1.2', 'important');
  el.style.setProperty('font-synthesis', 'none', 'important');
}

function ensureTextScrollBrowserFontReady() {
  applyTextScrollInputFont();
  if (textScrollBrowserFontLoading) return textScrollBrowserFontLoading;
  if (!(document.fonts && document.fonts.load)) {
    document.documentElement.dataset.scrollFontLoaded = 'unsupported';
    return Promise.resolve(false);
  }
  textScrollBrowserFontLoading = document.fonts.load(`12px "${TEXT_SCROLL_FONT_FAMILY}"`,
      TEXT_SCROLL_BROWSER_FONT_SAMPLE)
    .then(() => {
      const loaded = document.fonts.check(`12px "${TEXT_SCROLL_FONT_FAMILY}"`, TEXT_SCROLL_BROWSER_FONT_SAMPLE);
      document.documentElement.dataset.scrollFontLoaded = loaded ? 'true' : 'false';
      applyTextScrollInputFont();
      requestAnimationFrame(autoResizeScrollTextInput);
      return loaded;
    })
    .catch(err => {
      document.documentElement.dataset.scrollFontLoaded = 'false';
      console.warn('Ark Pixel 12px text-scroll textarea font load failed', err);
      applyTextScrollInputFont();
      return false;
    });
  return textScrollBrowserFontLoading;
}
const TEXT_SCROLL_CHAR_SPACING = WEBUI_CONFIG.textScroll.charSpacing;
const TEXT_SCROLL_SPACE_COLUMNS = WEBUI_CONFIG.textScroll.spaceColumns;
const TEXT_SCROLL_MISSING_GLYPH_CP = WEBUI_CONFIG.textScroll.missingGlyphCodePoint; // 不使用系统字体回退。
const arkPixelFont = {
  ready: false,
  loading: null,
  error: '',
  glyphs: new Map(),
  ascent: 10,
  descent: 2,
  lineHeight: 12,
  defaultAdvance: 12,
  source: ''
};

function textScrollVerticalOffset() {
  return Math.min(Math.max(0, ROWS - 1), Math.max(0, Math.floor((ROWS - Math.max(1, arkPixelFont.lineHeight || 12)) /
    2)) + 2);
}

function codePointOfChar(ch) {
  return ch.codePointAt(0) || 0;
}

function clearTextScrollCaches() {
  buildTextScrollBitmap.cacheKey = '';
  buildTextScrollBitmap.cache = null;
  buildTextGlyph.cache = new Map();
}
async function ensureArkPixelFontReady() {
  if (arkPixelFont.ready) return arkPixelFont;
  if (arkPixelFont.loading) return arkPixelFont.loading;
  arkPixelFont.loading = fetch(TEXT_SCROLL_FONT_RESOURCE, {
      cache: 'no-store'
    })
    .then(async res => {
      if (!res.ok) throw new Error(`${res.status} ${res.statusText || 'font resource missing'}`.trim());
      return res.json();
    })
    .then(data => loadArkPixelFontTable(data))
    .catch(err => {
      arkPixelFont.error = err.message || String(err);
      arkPixelFont.ready = false;
      arkPixelFont.loading = null;
      throw err;
    });
  return arkPixelFont.loading;
}

function decodePackedGlyphRows(rowsHex, width) {
  if (!rowsHex) return [];
  const nibbles = Math.max(1, Math.ceil(Math.max(0, width) / 4));
  return String(rowsHex).split('/').map(rowHex => {
    let bits = '';
    const clean = String(rowHex || '').replace(/[^0-9a-fA-F]/g, '').padStart(nibbles, '0').slice(-nibbles);
    for (const ch of clean) bits += parseInt(ch, 16).toString(2).padStart(4, '0');
    return bits.slice(0, Math.max(0, width));
  });
}

function loadArkPixelFontTable(data) {
  if (!data || data.format !== 'rina_ark_pixel_font_bitmap_v1') throw new Error(
    'Ark Pixel bitmap table format mismatch');
  arkPixelFont.glyphs = new Map();
  const rows = Number(data.rows || data.lineHeight || 12);
  arkPixelFont.ascent = Number(data.ascent || 10);
  arkPixelFont.descent = Number(data.descent || Math.max(0, rows - arkPixelFont.ascent));
  arkPixelFont.lineHeight = rows;
  arkPixelFont.defaultAdvance = Number(data.defaultAdvance || 12);
  arkPixelFont.source = data.source || TEXT_SCROLL_FONT_RESOURCE;
  const glyphs = data.glyphs || {};
  for (const [cpHex, g] of Object.entries(glyphs)) {
    const cp = parseInt(cpHex, 16);
    if (!Number.isFinite(cp) || !g) continue;
    let packed = null;
    if (Array.isArray(g)) {
      packed = {
        advance: g[0],
        width: g[1],
        height: g[2],
        xOffset: g[3],
        yOffset: g[4],
        dstY: g[5],
        rows: decodePackedGlyphRows(g[6] || '', Number(g[1] || 0))
      };
    } else {
      packed = {
        ...g,
        rows: Array.isArray(g.rows) ? g.rows.map(String) : decodePackedGlyphRows(g.rowsHex || '', Number(g.width ||
          0))
      };
    }
    arkPixelFont.glyphs.set(cp, {
      cp,
      advance: Math.max(1, Number(packed.advance || data.defaultAdvance || 12)),
      width: Math.max(0, Number(packed.width || 0)),
      height: Math.max(0, Number(packed.height || 0)),
      xOffset: Number(packed.xOffset || 0),
      yOffset: Number(packed.yOffset || 0),
      dstY: Number(packed.dstY || 0),
      rows: Array.isArray(packed.rows) ? packed.rows.map(String) : []
    });
  }
  if (!arkPixelFont.glyphs.size) throw new Error('Ark Pixel bitmap table contains no glyphs');
  arkPixelFont.ready = true;
  arkPixelFont.error = '';
  arkPixelFont.loading = null;
  clearTextScrollCaches();
  return arkPixelFont;
}

// -----------------------------------------------------------------------------
// 通用工具函数
// -----------------------------------------------------------------------------
function $(id) {
  return document.getElementById(id)
}

function clamp(n, min, max) {
  return Math.max(min, Math.min(max, Number(n) || 0));
}

function clampBrightness(v) {
  return clamp(v, MIN_LED_BRIGHTNESS, MAX_LED_BRIGHTNESS);
}

function isScrollPlaybackValue(value) {
  return value === 'scroll' || value === 'scroll_paused' || value === 'scroll_step';
}

function blankFrame() {
  return Array(TOTAL_LEDS).fill(false);
}

function cloneFrame(frame) {
  return frame.slice(0, TOTAL_LEDS).map(Boolean);
}

function onCount(frame) {
  let c = 0;
  for (const v of frame)
    if (v) c++;
  return c;
}

function normalizeHexColor(v) {
  v = String(v || '').trim();
  if (!v.startsWith('#')) v = '#' + v;
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
  return null;
}

function hexToRgb(hex) {
  hex = normalizeHexColor(hex) || '#000000';
  return {
    r: parseInt(hex.slice(1, 3), 16),
    g: parseInt(hex.slice(3, 5), 16),
    b: parseInt(hex.slice(5, 7), 16)
  };
}

function frameToM370(frame) {
  let bits = frame.slice(0, TOTAL_LEDS).map(v => v ? '1' : '0').join('') + '00';
  let out = '';
  for (let i = 0; i < bits.length; i += 4) out += parseInt(bits.slice(i, i + 4), 2).toString(16).toUpperCase();
  return 'M370:' + out.padEnd(93, '0').slice(0, 93);
}

function m370ToFrame(text) {
  let s = String(text || '').trim();
  if (s.toUpperCase().startsWith('M370:')) s = s.slice(5);
  s = s.replace(/\s+/g, '');
  if (!/^[0-9a-fA-F]{93}$/.test(s)) throw new Error('M370 必须是 93 个 hex 字符，或 M370:<93 hex>');
  let bits = '';
  for (const ch of s) bits += parseInt(ch, 16).toString(2).padStart(4, '0');
  return bits.slice(0, TOTAL_LEDS).split('').map(b => b === '1');
}

function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).catch(() => fallbackCopy(
  text));
  else fallbackCopy(text);
}

function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  document.execCommand('copy');
  ta.remove();
}

function log(msg) {
  const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
  logs.push(line);
  if (logs.length > 500) logs.shift();
  renderLog();
}

function renderLog() {
  const el = $('log');
  if (el) {
    el.textContent = logs.join('\n');
    el.scrollTop = el.scrollHeight;
  }
}

function isOfflineHtmlMode() {
  return location.protocol === 'file:' || location.origin === 'null';
}

function setFirmwareStatus(patch) {
  Object.assign(firmware, patch || {});
  if (typeof renderState === 'function') renderState();
}

function isScrollPageActive() {
  return document.body?.dataset?.page === 'scroll';
}

function apiUrl(path) {
  const p = String(path || '');
  if (/^https?:\/\//i.test(p)) return p;
  if (isOfflineHtmlMode()) {
    // file:// 无法访问 ESP32 的相对 API。保留这些调用为无操作失败，
    // 这样用户导入或打开 saved_faces.json 后，HTML 仍可离线使用。
    return null;
  }
  return p.startsWith('/') ? p : '/' + p;
}
// -----------------------------------------------------------------------------
// 固件 API 客户端
// -----------------------------------------------------------------------------
async function apiGet(path, options = {}) {
  const url = apiUrl(path);
  firmware.lastRequest = `GET ${path}`;
  renderState();
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = 'offline html mode';
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const timeoutMs = options.timeoutMs || API_GET_TIMEOUT_MS;
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: 'GET',
      cache: 'no-store',
      headers: {
        'Accept': 'application/json'
      },
      signal: controller?.signal
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ''}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {});
  } catch (err) {
    const message = err?.name === 'AbortError' ? `GET ${path} timeout after ${timeoutMs}ms` : (err.message || String(
      err));
    firmware.online = false;
    firmware.lastError = message;
    throw new Error(message);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
async function apiPost(path, payload, options = {}) {
  const url = apiUrl(path);
  firmware.lastRequest = `POST ${path}`;
  renderState();
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = 'offline html mode';
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const timeoutMs = options.timeoutMs || API_POST_TIMEOUT_MS;
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      body: JSON.stringify(payload || {}),
      signal: controller?.signal
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ''}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {
      ok: true
    });
  } catch (err) {
    const message = err?.name === 'AbortError' ? `POST ${path} timeout after ${timeoutMs}ms` : (err.message || String(
      err));
    firmware.online = false;
    firmware.lastError = message;
    throw new Error(message);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function apiPostWithUploadProgress(path, payload, onProgress = () => {}) {
  const url = apiUrl(path);
  const body = JSON.stringify(payload || {});
  firmware.lastRequest = `POST ${path}`;
  setFirmwareStatus({
    lastRequest: firmware.lastRequest,
    lastStatus: 'uploading'
  });
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = 'offline html mode';
    firmware.lastError = `offline: ${path}`;
    return Promise.reject(new Error(`offline html mode: ${path}`));
  }
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.timeout = API_UPLOAD_TIMEOUT_MS;
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.upload.onprogress = ev => {
      if (ev.lengthComputable && ev.total > 0) onProgress(ev.loaded / ev.total);
    };
    xhr.onload = () => {
      firmware.online = xhr.status >= 200 && xhr.status < 300;
      firmware.lastStatus = `${xhr.status} ${xhr.statusText || ''}`.trim();
      if (!firmware.online) {
        firmware.lastError = firmware.lastStatus;
        reject(new Error(firmware.lastStatus));
        return;
      }
      try {
        resolve(parseApiJson(xhr.responseText, path, {
          ok: true
        }));
      } catch (err) {
        firmware.lastError = err.message;
        reject(err);
      }
    };
    xhr.onerror = () => {
      firmware.online = false;
      firmware.lastStatus = 'network error';
      firmware.lastError = `POST ${path} failed`;
      reject(new Error(firmware.lastError));
    };
    xhr.ontimeout = () => {
      firmware.online = false;
      firmware.lastStatus = 'timeout';
      firmware.lastError = `POST ${path} timeout after ${API_UPLOAD_TIMEOUT_MS}ms`;
      reject(new Error(firmware.lastError));
    };
    xhr.send(body);
  });
}

function shouldLogApiError() {
  const now = performance.now();
  if (now - lastApiErrorLogAt > 2500) {
    lastApiErrorLogAt = now;
    return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// 电源和固件状态同步
// -----------------------------------------------------------------------------
function finitePowerNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function powerIconClass(value, fallback = 'status-dot dim') {
  const text = String(value || '').trim();
  return /^status-dot( (dim|warn|danger))?$/.test(text) ? text : fallback;
}

function powerIconColor(value, fallback = '#9aa6b2') {
  const text = String(value || '').trim();
  return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback;
}

function batteryIconForPercent(powered, percent) {
  if (!powered) return {
    cls: 'status-dot dim',
    color: '#9aa6b2'
  };
  const pct = finitePowerNumber(percent);
  if (pct !== null && pct < 10) return {
    cls: 'status-dot danger',
    color: '#ef4444'
  };
  if (pct !== null && pct < 30) return {
    cls: 'status-dot warn',
    color: '#f59e0b'
  };
  return {
    cls: 'status-dot',
    color: '#59d98e'
  };
}

function setPowerStateField(key, value) {
  if (state[key] === value) return false;
  state[key] = value;
  return true;
}

function setFinitePowerField(key, value) {
  const n = finitePowerNumber(value);
  if (n === null) return false;
  return setPowerStateField(key, n);
}

function applyPowerData(powerData) {
  if (!powerData || typeof powerData !== 'object') return false;
  let stateChanged = false;
  const batteryValid = powerData.batteryValid !== false;
  const chargeValid = powerData.chargeValid !== false;
  const batteryPowered = powerData.batteryPowered !== false;
  const vbat = finitePowerNumber(powerData.vbat);
  const pct = finitePowerNumber(powerData.batteryPercent);
  const vcharge = finitePowerNumber(powerData.vcharge);
  if (typeof powerData.batteryPowered === 'boolean') stateChanged = setPowerStateField('batteryPowered',
    batteryPowered) || stateChanged;
  if (typeof powerData.batteryDisconnected === 'boolean') stateChanged = setPowerStateField('batteryDisconnected',
    powerData.batteryDisconnected) || stateChanged;
  if (typeof powerData.batteryLowVoltageUnpowered === 'boolean') stateChanged = setPowerStateField(
    'batteryLowVoltageUnpowered', powerData.batteryLowVoltageUnpowered) || stateChanged;
  if (typeof powerData.batteryStateText === 'string' && powerData.batteryStateText) stateChanged = setPowerStateField(
    'batteryStateText', powerData.batteryStateText) || stateChanged;
  stateChanged = setFinitePowerField('batteryMinV', powerData.batteryRangeMin) || stateChanged;
  stateChanged = setFinitePowerField('batteryMaxV', powerData.batteryRangeMax) || stateChanged;
  stateChanged = setFinitePowerField('batteryNominalMin', powerData.batteryNominalMin) || stateChanged;
  stateChanged = setFinitePowerField('batteryNominalMax', powerData.batteryNominalMax) || stateChanged;
  stateChanged = setFinitePowerField('batteryAdcMv', powerData.batteryAdcMv) || stateChanged;
  stateChanged = setFinitePowerField('batteryPrevAdcMv', powerData.batteryPrevAdcMv) || stateChanged;
  stateChanged = setFinitePowerField('batteryDisconnectDropMv', powerData.batteryDisconnectDropMv) || stateChanged;
  stateChanged = setFinitePowerField('batteryDisconnectDropThresholdMv', powerData.batteryDisconnectDropThresholdMv) ||
    stateChanged;
  stateChanged = setFinitePowerField('batteryDisconnectLowThresholdMv', powerData.batteryDisconnectLowThresholdMv) ||
    stateChanged;
  stateChanged = setFinitePowerField('batteryReconnectThresholdMv', powerData.batteryReconnectThresholdMv) ||
    stateChanged;
  stateChanged = setFinitePowerField('batteryUnpoweredLowThreshold', powerData.batteryUnpoweredLowThreshold) ||
    stateChanged;
  stateChanged = setFinitePowerField('batteryLastInstantVbat', powerData.batteryLastInstantVbat) || stateChanged;
  stateChanged = setFinitePowerField('chargeAdcMv', powerData.chargeAdcMv) || stateChanged;
  if (batteryValid) {
    if (batteryPowered) {
      if (vbat !== null) {
        state.batteryV = vbat;
        stateChanged = true;
      }
      if (pct !== null) {
        state.batteryPercent = pct;
        stateChanged = true;
      }
    } else {
      if (state.batteryV !== 0 || state.batteryPercent !== 0) {
        state.batteryV = 0;
        state.batteryPercent = 0;
        stateChanged = true;
      }
    }
  } else {
    if (state.batteryV !== null || state.batteryPercent !== null) {
      state.batteryV = null;
      state.batteryPercent = null;
      stateChanged = true;
    }
  }
  if (chargeValid) {
    if (vcharge !== null) {
      state.chargeV = vcharge;
      stateChanged = true;
    }
    if (typeof powerData.charging === 'boolean') {
      state.charging = powerData.charging;
      stateChanged = true;
    }
  } else {
    if (state.chargeV !== null || state.charging !== null) {
      state.chargeV = null;
      state.charging = null;
      stateChanged = true;
    }
  }
  const nextBatteryIconClass = powerIconClass(powerData.batteryIconClass);
  if (state.batteryIconClass !== nextBatteryIconClass) {
    state.batteryIconClass = nextBatteryIconClass;
    stateChanged = true;
  }
  const nextBatteryIconColor = powerIconColor(powerData.batteryIconColor);
  if (state.batteryIconColor !== nextBatteryIconColor) {
    state.batteryIconColor = nextBatteryIconColor;
    stateChanged = true;
  }
  const nextChargeIconClass = powerIconClass(powerData.chargeIconClass);
  if (state.chargeIconClass !== nextChargeIconClass) {
    state.chargeIconClass = nextChargeIconClass;
    stateChanged = true;
  }
  const nextChargeIconColor = powerIconColor(powerData.chargeIconColor);
  if (state.chargeIconColor !== nextChargeIconColor) {
    state.chargeIconColor = nextChargeIconColor;
    stateChanged = true;
  }
  return stateChanged;
}

function shouldApplyPowerFromStatusSource(source) {
  return source === 'page_load' || source === 'firmware_ping' || String(source || '').startsWith('power_') || String(
    source || '').startsWith('basic_');
}

function scrollStopEventFromStatus(data, renderer) {
  const event = renderer?.scrollStopEvent || data?.scrollStopEvent || null;
  if (!event || typeof event !== 'object') return null;
  const seq = Number(event.seq || 0);
  if (!Number.isFinite(seq) || seq <= 0) return null;
  return {
    seq,
    ms: Number(event.ms || 0),
    button: String(event.button || '').toUpperCase(),
    source: String(event.source || ''),
    reason: String(event.reason || '')
  };
}

function scheduleFirmwareScrollStopFullSync(source = 'firmware_scroll_stop_full_status', delayMs =
  SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS) {
  if (isOfflineHtmlMode()) return;
  if (firmwareScrollStopFullSyncTimer) clearTimeout(firmwareScrollStopFullSyncTimer);
  firmwareScrollStopFullSyncTimer = setTimeout(() => {
    firmwareScrollStopFullSyncTimer = null;
    syncRuntimeStateFromFirmware(source);
  }, Math.max(0, Number(delayMs) || 0));
}

function applyFirmwareRuntimeState(data, source = 'firmware_status', options = {}) {
  if (!data || typeof data !== 'object') return;
  const skipFrame = !!options.skipFrame;
  const renderer = data.renderer || data;
  let stateChanged = false;
  let faceChanged = false;
  let frameChanged = false;
  const wasScrollBeforeFirmwareSync = state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state
    .playback);

  if (data.ap?.ip) {
    state.apIp = data.ap.ip;
    stateChanged = true;
  }
  if (data.ap?.domain) {
    state.apDomain = data.ap.domain;
    stateChanged = true;
  }

  const nestedPowerPayload = data.power && typeof data.power === 'object' ? data.power : null;
  const flatPowerPayload = (
    data.vbat !== undefined || data.batteryPercent !== undefined || data.vcharge !== undefined || data.charging !==
    undefined ?
    data :
    null
  );
  const powerPayload = nestedPowerPayload || flatPowerPayload;
  if (powerPayload && (nestedPowerPayload || shouldApplyPowerFromStatusSource(source))) {
    stateChanged = applyPowerData(powerPayload) || stateChanged;
  }

  const modeValue = renderer.mode ?? data.mode;
  if (modeValue) {
    const nextMode = isAutoModeValue(modeValue) ? 'auto' : 'manual';
    if (state.mode !== nextMode) {
      state.mode = nextMode;
      stateChanged = true;
    }
  }

  const intervalValue = Number(renderer.autoIntervalMs ?? data.autoIntervalMs);
  if (Number.isFinite(intervalValue)) {
    const nextInterval = normalizeAutoIntervalMs(intervalValue);
    if (state.autoInterval !== nextInterval) {
      state.autoInterval = nextInterval;
      stateChanged = true;
    }
  }

  if (typeof renderer.restoreAutoAfterScroll === 'boolean') {
    state.restoreAutoAfterScroll = renderer.restoreAutoAfterScroll;
  }

  const playbackValue = renderer.playback ?? data.playback;
  if (typeof playbackValue === 'string' && playbackValue) {
    state.playback = playbackValue;
    const firmwareScrollActive = Boolean(renderer.firmwareScrollActive ?? data.firmwareScrollActive);
    const firmwareScrollPaused = Boolean(renderer.firmwareScrollPaused ?? data.firmwareScrollPaused);
    scroll.firmwareBacked = firmwareScrollActive || firmwareScrollPaused;
    const playbackIsScroll = isScrollPlaybackValue(playbackValue);
    scroll.paused = playbackValue === 'scroll_paused' || firmwareScrollPaused;
    scroll.active = playbackValue === 'scroll' && !scroll.paused;
    state.textScrollActive = playbackIsScroll || firmwareScrollActive || firmwareScrollPaused;
    if (!playbackIsScroll && !firmwareScrollActive && !firmwareScrollPaused) {
      scroll.active = false;
      scroll.paused = false;
      state.textScrollActive = false;
    }
    stateChanged = true;
  }

  const scrollMaxFramesValue = Number(renderer.scrollMaxFrames ?? data.scrollMaxFrames);
  if (Number.isFinite(scrollMaxFramesValue) && scrollMaxFramesValue > 0) {
    firmwareScrollMaxFrames = Math.floor(scrollMaxFramesValue);
  }

  const scrollFrameCountValue = Number(renderer.scrollFrameCount ?? data.scrollFrameCount);
  if (Number.isFinite(scrollFrameCountValue) && scrollFrameCountValue === 0 && !isScrollPlaybackValue(state.playback)) {
    scroll.firmwareBacked = false;
  }
  const scrollFrameIndexValue = Number(renderer.scrollFrameIndex ?? data.scrollFrameIndex);
  if (Number.isFinite(scrollFrameIndexValue) && scroll.frames.length) {
    scroll.frameIndex = clamp(scrollFrameIndexValue, 0, Math.max(0, scroll.frames.length - 1));
  }

  const brightnessValue = Number(renderer.brightness ?? data.brightness);
  if (Number.isFinite(brightnessValue)) {
    const nextBrightness = clampBrightness(brightnessValue);
    if (!brightnessChangedByUser) state.defaultBrightness = nextBrightness;
    if (state.brightness !== nextBrightness) {
      state.brightness = nextBrightness;
      if ($('brightness-range')) $('brightness-range').value = state.brightness;
      if ($('brightness-input')) $('brightness-input').value = state.brightness;
      updateDps();
      stateChanged = true;
    }
  }

  const firmwareColor = normalizeHexColor(renderer.color ?? data.color);
  if (firmwareColor) {
    setColor(firmwareColor, 'firmware_sync');
  }

  const faceIndexValue = Number(renderer.autoFaceIndex ?? data.autoFaceIndex);
  if (Number.isFinite(faceIndexValue)) {
    const library = getAllFaces();
    const maxIndex = Math.max(0, library.length - 1);
    const nextFaceIndex = clamp(faceIndexValue, 0, maxIndex);
    if (state.faceIndex !== nextFaceIndex) {
      state.faceIndex = nextFaceIndex;
      stateChanged = true;
      faceChanged = true;
    }
  }

  const firmwareIsScrolling = state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);
  const firmwareM370 = renderer.lastM370 || renderer.m370 || data.m370;
  if (!skipFrame && !firmwareIsScrolling && typeof firmwareM370 === 'string' && firmwareM370.trim()) {
    try {
      currentFrame = m370ToFrame(firmwareM370);
      if (!firmwareIsScrolling) scrollFrame = cloneFrame(currentFrame);
      state.lastRefreshReason = renderer.lastReason || data.lastReason || source;
      frameChanged = true;
      stateChanged = true;
    } catch (e) {}
  }

  syncAutoIntervalUi();
  if (faceChanged) renderSavedFaces();
  if (frameChanged) {
    renderMatrices();
    updateM370Views();
  }

  const firmwareReason = String(renderer.lastReason || data.lastReason || '');
  const event = scrollStopEventFromStatus(data, renderer);
  const newButtonStopEvent = !!event &&
    event.seq > lastScrollStopEventSeq &&
    event.source === 'gpio' && ['B1', 'B2', 'B3'].includes(event.button);
  if (event && event.seq > lastScrollStopEventSeq) lastScrollStopEventSeq = event.seq;

  const fallbackButtonStop = wasScrollBeforeFirmwareSync &&
    firmwareReason.startsWith('gpio_') &&
    /(^|_)B[123](_|$)/.test(firmwareReason);
  const stoppedAfterScroll = wasScrollBeforeFirmwareSync && !state.textScrollActive && !scroll.firmwareBacked;
  const shouldStopScrollPreview = isScrollPageActive() &&
    String(source).startsWith('firmware_poll') &&
    (newButtonStopEvent || stoppedAfterScroll || fallbackButtonStop);

  if (shouldStopScrollPreview) {
    const hasCurrentFacePreview = frameChanged && !state.textScrollActive && !scroll.firmwareBacked;
    resetScrollControlsAfterButton(newButtonStopEvent ? `firmware_gpio_${event.button}` : 'firmware_gpio_button', {
      preserveCurrentFrame: hasCurrentFacePreview
    });
    if (!hasCurrentFacePreview) {
      const delay = renderer.deferredFaceRestoreActive ? SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS : 20;
      scheduleFirmwareScrollStopFullSync('firmware_poll_scroll_stop_full_status', delay);
    }
  }
  if (stateChanged) renderState();
}

// -----------------------------------------------------------------------------
// 固件命令队列
// -----------------------------------------------------------------------------
function sendAuxCommand(cmd, payload = {}, source = 'webui') {
  firmware.sentCommands++;
  const packet = {
    cmd,
    payload
  };
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: isOfflineHtmlMode() ? 'queued offline' : 'queued'
  });
  packet.promise = apiPost(API_ENDPOINTS.command, packet)
    .then(data => {
      applyFirmwareRuntimeState(data, source);
      return data;
    })
    .catch(err => {
      setFirmwareStatus({
        lastStatus: isOfflineHtmlMode() ? 'offline html mode' : 'command failed',
        lastError: err.message
      });
      if (!isOfflineHtmlMode() && shouldLogApiError()) log(`辅助指令发送失败: ${err.message}`);
    });
  return packet;
}

function scheduleButtonCommandPump(delay = 0) {
  if (buttonCommandTimer) clearTimeout(buttonCommandTimer);
  buttonCommandTimer = setTimeout(() => {
    buttonCommandTimer = 0;
    pumpButtonCommandQueue();
  }, Math.max(0, delay));
}

function pumpButtonCommandQueue() {
  if (buttonCommandInFlight) return;
  if (!buttonCommandQueue.length) {
    firmware.buttonQueue = 0;
    renderState();
    return;
  }
  const now = performance.now();
  const waitMs = Math.max(0, WEBUI_BUTTON_COMMAND_INTERVAL_MS - (now - lastButtonCommandAt));
  if (waitMs > 0) {
    scheduleButtonCommandPump(waitMs);
    return;
  }
  const queued = buttonCommandQueue.shift();
  firmware.buttonQueue = buttonCommandQueue.length;
  buttonCommandInFlight = true;
  lastButtonCommandAt = performance.now();
  firmware.sentCommands++;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: `queued button (${buttonCommandQueue.length}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX})`
  });
  apiPost(API_ENDPOINTS.command, queued.request)
    .then(data => {
      applyFirmwareRuntimeState(data, queued.source);
      queued.resolve(data);
      return data;
    })
    .catch(err => {
      setFirmwareStatus({
        lastStatus: 'button command failed',
        lastError: err.message
      });
      if (shouldLogApiError()) log(`button command failed; using local fallback: ${err.message}`);
      if (queued.fallback) queued.fallback();
      queued.resolve(null);
      return null;
    })
    .finally(() => {
      buttonCommandInFlight = false;
      firmware.buttonQueue = buttonCommandQueue.length;
      scheduleButtonCommandPump(0);
    });
  renderState();
}

function sendButtonCommand(button, source = 'webui_button', fallback = null) {
  if (isScrollPageActive() && ['B1', 'B2', 'B3'].includes(String(button).toUpperCase())) {
    resetScrollControlsAfterButton(source);
  }
  if (isOfflineHtmlMode()) {
    if (fallback) fallback();
    return {
      cmd: 'button',
      source,
      payload: {
        button
      },
      offline: true
    };
  }
  const packet = {
    cmd: 'button',
    payload: {
      button
    }
  };
  const queued = {
    request: packet,
    source,
    fallback,
    promise: null,
    resolve: null
  };
  queued.promise = new Promise(resolve => {
    queued.resolve = resolve;
  });
  if (buttonCommandQueue.length >= WEBUI_BUTTON_COMMAND_QUEUE_MAX) {
    const dropped = buttonCommandQueue.shift();
    if (dropped && typeof dropped.resolve === 'function') dropped.resolve(null);
    firmware.droppedCommands++;
  }
  buttonCommandQueue.push(queued);
  firmware.buttonQueue = buttonCommandQueue.length;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: `queued button (${buttonCommandQueue.length}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX})`
  });
  scheduleButtonCommandPump(0);
  packet.promise = queued.promise;
  return packet;
}

function scheduleFrameSendPump(delay = 0) {
  if (frameSendTimer) clearTimeout(frameSendTimer);
  frameSendTimer = setTimeout(() => {
    frameSendTimer = 0;
    pumpFrameSendQueue();
  }, Math.max(0, delay));
}

function pumpFrameSendQueue() {
  if (frameSendInFlight) return;
  if (!frameSendQueue.length) {
    firmware.frameQueue = 0;
    renderState();
    return;
  }
  const now = performance.now();
  const waitMs = Math.max(0, WEBUI_M370_SEND_INTERVAL_MS - (now - lastFrameSendAt));
  if (waitMs > 0) {
    scheduleFrameSendPump(waitMs);
    return;
  }
  const packet = frameSendQueue.shift();
  firmware.frameQueue = frameSendQueue.length;
  frameSendInFlight = true;
  lastFrameSendAt = performance.now();
  firmware.sentFrames++;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.frame}`,
    lastStatus: isOfflineHtmlMode() ? 'queued offline' :
      `queued frame (${frameSendQueue.length}/${WEBUI_M370_QUEUE_MAX})`
  });
  apiPost(API_ENDPOINTS.frame, packet)
    .catch(err => {
      setFirmwareStatus({
        lastStatus: isOfflineHtmlMode() ? 'offline html mode' : 'frame failed',
        lastError: err.message
      });
      if (!isOfflineHtmlMode() && shouldLogApiError()) log(`M370 帧发送失败: ${err.message}`);
    })
    .finally(() => {
      frameSendInFlight = false;
      firmware.frameQueue = frameSendQueue.length;
      scheduleFrameSendPump(0);
    });
  renderState();
}

function queueFirmwareFrame(frame, reason = 'frame_update', playback = 'idle') {
  const m370 = frameToM370(frame);
  pendingFramePacket = {
    type: 'm370_frame',
    m370,
    reason,
    mode: playback,
    at: Date.now()
  };
  if (frameSendQueue.length >= WEBUI_M370_QUEUE_MAX) {
    frameSendQueue.shift();
    firmware.droppedFrames++;
  }
  frameSendQueue.push(pendingFramePacket);
  firmware.frameQueue = frameSendQueue.length;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.frame}`,
    lastStatus: isOfflineHtmlMode() ? 'queued offline' :
      `queued frame (${frameSendQueue.length}/${WEBUI_M370_QUEUE_MAX})`
  });
  scheduleFrameSendPump(0);
}

function setScrollPreviewFrame(frame, reason = 'text_scroll_preview', playback = 'scroll') {
  scrollFrame = cloneFrame(frame);
  currentFrame = cloneFrame(frame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updateM370Views();
}

function orFrameIntoFrame(targetFrame, sourceFrame) {
  for (let i = 0; i < TOTAL_LEDS; i++)
    if (sourceFrame[i]) targetFrame[i] = true;
}

function orPartIntoFrame(frame, part) {
  // 标准 WebUI/M370 路径：使用 part.m370，因为它是按逻辑行优先排列的数据。
  // 旧版 strip_indices 是物理蛇形位置，因此需要映射回逻辑单元。
  if (part && typeof part.m370 === 'string') {
    orFrameIntoFrame(frame, m370ToFrame(part.m370));
    return;
  }
  // 仅作为畸形旧资源的兜底。
  for (const idx of (part?.strip_indices || [])) {
    const logical = physicalToLogicalIndex(idx);
    if (logical >= 0 && logical < TOTAL_LEDS) frame[logical] = true;
  }
}

function composePartsFrame() {
  const frame = blankFrame();
  for (const key of ['leye', 'reye', 'mouth', 'cheek']) {
    const requested = String(selectedCall[key] ?? '0');
    const resolved = resolvePartId(key, requested);
    const part = EXPRESSION_PARTS.parts[resolved] || EXPRESSION_PARTS.parts['0'];
    orPartIntoFrame(frame, part);
  }
  partsFrame = frame;
  renderMatrices();
  return frame;
}

function sendPartsFrame(reason = 'parts_compose_send', writeLog = true) {
  updateM370Views();
  setCurrentFrame(partsFrame, reason, 'idle');
  if (writeLog) log('M370 已发送到固件接口');
}

function sendPartsFrameIfLive(reason = 'parts_live_send') {
  if (liveSendEnabled) sendPartsFrame(reason, false);
}

function resolvePartId(callKey, id) {
  const normalized = String(id ?? '0');
  const resolved = callKey === 'cheek' && normalized === '400' ? '0' : normalized;
  return EXPRESSION_PARTS.parts[resolved] ? resolved : '0';
}

function classifyOutputMode(reason = '', playback = null) {
  const p = String(playback || '');
  const r = String(reason || '');
  if (p === 'scroll' || p === 'scroll_step' || r.startsWith('text_scroll_')) return 'scroll';
  if (r.startsWith('custom_')) return 'custom';
  if (r.startsWith('parts_')) return 'parts';
  if (r.startsWith('debug_')) return 'debug';
  if (r.includes('saved_face') || r.includes('B1') || r.includes('B2')) return 'face';
  return p || 'static';
}

function terminateOtherActivities(targetMode = 'static', reason = 'mode_change') {
  const ended = [];
  const previousPlayback = state.playback;

  // 单向保护规则：
  // 启动/发送另一种模式是硬中断，不是临时暂停。
  // 这里停止的内容不会在新模式结束后自动恢复。
  if (targetMode !== 'face' && isAutoModeValue(state.mode)) {
    state.restoreAutoAfterScroll = targetMode === 'scroll';
    state.mode = 'manual';
    ended.push('auto_saved_face');
  } else if (targetMode !== 'scroll') {
    state.restoreAutoAfterScroll = false;
  }

  if (targetMode !== 'scroll' && (scroll.timer || scroll.active || state.textScrollActive || isScrollPlaybackValue(
      previousPlayback))) {
    if (scroll.timer) clearInterval(scroll.timer);
    scroll.timer = null;
    scroll.active = false;
    scroll.paused = false;
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    state.textScrollActive = false;
    if (isScrollPlaybackValue(state.playback)) state.playback = 'idle';
    ended.push('text_scroll');
  }

  if (ended.length) {
    state.refreshPolicy = targetMode === 'scroll' ? 'text_scroll_fps_interval' : 'dirty-frame / 按需刷新';
    updateScrollUi();
    renderState();
    log(`防冲突：${reason} 前终止 ${ended.join(' / ')}；不会自动恢复`);
    sendAuxCommand('terminate_other_activities', {
      targetMode,
      ended
    }, reason);
  }
  return ended;
}

function guardBeforeOutput(reason = 'mode_change', playback = null) {
  return terminateOtherActivities(classifyOutputMode(reason, playback), reason);
}

function setCurrentFrame(frame, reason = 'manual_update', playback = null) {
  guardBeforeOutput(reason, playback);
  currentFrame = cloneFrame(frame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updateM370Views();
  queueFirmwareFrame(currentFrame, reason, state.playback);
}

function updateDps() {
  const rgb = hexToRgb(state.color);
  const colorFactor = (rgb.r + rgb.g + rgb.b) / (LED_FULL_BRIGHTNESS * 3);
  const estimatedW = onCount(currentFrame) * LED_ESTIMATED_WATTS_PER_CHANNEL * LED_CHANNEL_COUNT * (state.brightness /
    LED_FULL_BRIGHTNESS) * colorFactor;
  state.dpsActive = estimatedW > LED_POWER_WARNING_WATTS;
  const warn = $('dps-warning');
  if (warn) warn.classList.toggle('show', state.dpsActive);
}

function setColor(hex, source = 'color_change') {
  const c = normalizeHexColor(hex);
  if (!c) {
    alert('颜色必须是 #RRGGBB 或 RRGGBB');
    return;
  }
  const unchangedFirmwareSync = source === 'firmware_sync' && state.color === c;
  state.color = c;
  document.documentElement.style.setProperty('--led-color', c);
  if ($('color-input')) $('color-input').value = c;
  if ($('color-swatch')) $('color-swatch').style.background = c;
  syncColorDropdownsToHex(c);
  updateDps();
  renderMatrices();
  renderState();
  if (unchangedFirmwareSync) return;
  log(`颜色更新 ${c} (${source})`);
  if (source !== 'firmware_sync') sendAuxCommand('set_color', {
    hex: c
  }, source);
}

function applyBrightnessLocal(v) {
  state.brightness = clampBrightness(v);
  if ($('brightness-range')) $('brightness-range').value = state.brightness;
  if ($('brightness-input')) $('brightness-input').value = state.brightness;
  updateDps();
  renderState();
}

function setBrightness(v, source = 'brightness_change') {
  brightnessChangedByUser = true;
  applyBrightnessLocal(v);
  log(`亮度更新 raw=${state.brightness} (${source})`);
  sendAuxCommand('set_brightness', {
    raw: state.brightness
  }, source);
}

// -----------------------------------------------------------------------------
// 启动加载器和初始固件同步
// -----------------------------------------------------------------------------
const BOOT_STATUS_ENDPOINT = `${API_ENDPOINTS.status}${RUNTIME_STATUS_QUERY}`;
const BOOT_STATUS_TIMEOUT_MS = WEBUI_CONFIG.api.bootStatusTimeoutMs;
let bootRuntimeSnapshot = {
  attempted: false,
  ok: false,
  error: '',
  data: null
};

function unlockBootPageScroll() {
  if (document.documentElement.dataset.scrollLock === 'boot') {
    document.documentElement.removeAttribute('data-scroll-lock');
  }
}
// ── Rina 加载遮罩动画 ─────────────────────────────────
(function() {
  const ICON_BEFORE = WEBUI_CONFIG.boot.loadingIconBefore;
  const ICON_AFTER = WEBUI_CONFIG.boot.loadingIconAfter;
  const HOLD_MS = WEBUI_CONFIG.boot.holdMs,
    HALO_BREATH_MS = WEBUI_CONFIG.boot.haloBreathMs,
    HALO_PEAK_RATIO = WEBUI_CONFIG.boot.haloPeakRatio,
    HALO_TOL_MS = WEBUI_CONFIG.boot.haloToleranceMs,
    HALO_CONTRACT_MS = WEBUI_CONFIG.boot.haloContractMs;
  const IMG_RELEASE_MS = WEBUI_CONFIG.boot.imageReleaseMs,
    IMG_SHRINK_MS = Math.round(IMG_RELEASE_MS * .18),
    BLUR_DUR_MS = WEBUI_CONFIG.boot.blurDurationMs,
    EXTRA_MS = WEBUI_CONFIG.boot.extraMs;
  const overlay = document.getElementById('loadingOverlay');
  const blurScreen = document.getElementById('blurScreen');
  const avatarBefore = document.getElementById('avatarBefore');
  const avatarAfter = document.getElementById('avatarAfter');
  if (!overlay || !blurScreen || !avatarBefore || !avatarAfter) {
    unlockBootPageScroll();
    return;
  }
  let finished = false,
    finishPending = false,
    finishQueued = false,
    started = false,
    haloCycleStart = 0;
  let peakTimer = null,
    haloTimer = null,
    holdTimer = null,
    removeTimer = null,
    blurTimer = null,
    rafId = null;
  let afterImageReadyPromise = null;
  let loaderHorizontalRaf = 0;
  let lockedCenterX = 0,
    lockedCenterY = 0;

  function firstViewportCenter() {
    const vv = window.visualViewport;
    const left = Number(vv?.offsetLeft) || 0;
    const top = Number(vv?.offsetTop) || 0;
    const width = Number(vv?.width) || window.innerWidth || document.documentElement.clientWidth || 0;
    const height = Number(vv?.height) || window.innerHeight || document.documentElement.clientHeight || 0;
    return {
      x: left + width / 2,
      y: top + height / 2
    };
  }

  function lockLoaderCenter() {
    const center = firstViewportCenter();
    lockedCenterX = center.x;
    lockedCenterY = center.y;
    document.documentElement.style.setProperty('--rina-loader-x', lockedCenterX.toFixed(2) + 'px');
    document.documentElement.style.setProperty('--rina-loader-y', lockedCenterY.toFixed(2) + 'px');
  }

  function syncLoaderHorizontalCenter() {
    const center = firstViewportCenter();
    lockedCenterX = center.x;
    document.documentElement.style.setProperty('--rina-loader-x', lockedCenterX.toFixed(2) + 'px');
  }

  function scheduleLoaderHorizontalCenterSync() {
    if (!started || overlay.hidden) return;
    if (loaderHorizontalRaf) return;
    loaderHorizontalRaf = requestAnimationFrame(() => {
      loaderHorizontalRaf = 0;
      syncLoaderHorizontalCenter();
      if (blurScreen.classList.contains('is-revealing')) setOrigin();
    });
  }

  function loaderSurfaceRect() {
    return (blurScreen || overlay).getBoundingClientRect();
  }

  function decodeLoadedImage(img) {
    if (typeof img.decode !== 'function') return Promise.resolve();
    return img.decode().catch(err => {
      if (img.complete && img.naturalWidth > 0) return;
      throw err;
    });
  }

  function waitForImage(img, src) {
    img.src = src;
    if (img.complete && img.naturalWidth > 0) return decodeLoadedImage(img);
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        img.removeEventListener('load', onLoad);
        img.removeEventListener('error', onError);
      };
      const onLoad = () => {
        cleanup();
        resolve(decodeLoadedImage(img));
      };
      const onError = () => {
        cleanup();
        reject(new Error(`failed to load ${src}`));
      };
      img.addEventListener('load', onLoad, {
        once: true
      });
      img.addEventListener('error', onError, {
        once: true
      });
    });
  }

  function preloadInitialLoadingImage() {
    return waitForImage(avatarBefore, ICON_BEFORE);
  }

  function preloadAfterLoadingImage() {
    if (!afterImageReadyPromise) afterImageReadyPromise = waitForImage(avatarAfter, ICON_AFTER);
    return afterImageReadyPromise;
  }

  function eic(t) {
    return t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function getMaxR() {
    syncLoaderHorizontalCenter();
    const o = loaderSurfaceRect();
    const cx = lockedCenterX - o.left,
      cy = lockedCenterY - o.top;
    return Math.ceil(Math.max(Math.hypot(cx, cy), Math.hypot(o.width - cx, cy), Math.hypot(cx, o.height - cy), Math
      .hypot(o.width - cx, o.height - cy)) + 90);
  }

  function setOrigin() {
    syncLoaderHorizontalCenter();
    const o = loaderSurfaceRect();
    blurScreen.style.setProperty('--rina-reveal-x', (lockedCenterX - o.left).toFixed(2) + 'px');
    blurScreen.style.setProperty('--rina-reveal-y', (lockedCenterY - o.top).toFixed(2) + 'px');
  }

  function animateReveal() {
    setOrigin();
    const start = performance.now(),
      maxR = getMaxR(),
      f = Math.max(96, Math.min(180, Math.round(maxR * .12)));
    blurScreen.classList.add('is-revealing');
    overlay.classList.add('is-scroll-passthrough');
    unlockBootPageScroll();

    function fr(now) {
      const t = Math.min(1, (now - start) / BLUR_DUR_MS),
        r = maxR * eic(t);
      [
        ['--rina-reveal-solid', Math.max(0, r - f)],
        ['--rina-reveal-a', Math.max(0, r - f * .72)],
        ['--rina-reveal-b', Math.max(0, r - f * .42)],
        ['--rina-reveal-c', Math.max(0, r - f * .12)],
        ['--rina-reveal-d', Math.max(0, r + f * .22)],
        ['--rina-reveal-e', Math.max(0, r + f * .56)],
        ['--rina-reveal-outer', Math.max(0, r + f)]
      ].forEach(([p, v]) => blurScreen.style.setProperty(p, v.toFixed(2) + 'px'));
      if (t < 1) rafId = requestAnimationFrame(fr);
    }
    rafId = requestAnimationFrame(fr);
  }

  function finishOverlay() {
    const wait = Math.max(IMG_RELEASE_MS, IMG_SHRINK_MS + BLUR_DUR_MS);
    removeTimer = window.setTimeout(() => {
      overlay.classList.add('is-hidden');
      removeTimer = window.setTimeout(() => {
        overlay.hidden = true;
        overlay.classList.remove('is-animating');
        unlockBootPageScroll();
      }, EXTRA_MS);
    }, wait + EXTRA_MS);
  }

  function delayToPeak(now = performance.now()) {
    const phase = ((now - haloCycleStart) % HALO_BREATH_MS + HALO_BREATH_MS) % HALO_BREATH_MS;
    let d = HALO_BREATH_MS * HALO_PEAK_RATIO - phase;
    if (Math.abs(d) <= HALO_TOL_MS) return 0;
    if (d < 0) d += HALO_BREATH_MS;
    return Math.max(0, Math.round(d));
  }

  function requestFinish() {
    if (!started) {
      finishQueued = true;
      return;
    }
    if (finished || finishPending) return;
    finishPending = true;
    peakTimer = window.setTimeout(doFinish, delayToPeak());
  }
  async function doFinish() {
    if (finished) return;
    finished = true;
    finishPending = false;
    avatarBefore.src = ICON_BEFORE;
    try {
      await preloadAfterLoadingImage();
    } catch (err) {
      console.warn('Rina loading hover image failed', err);
    }
    overlay.classList.add('is-ring-contracting', 'is-image-pop');
    overlay.setAttribute('aria-label', '页面加载完成');
    haloTimer = window.setTimeout(() => overlay.classList.add('is-halo-hidden'), HALO_CONTRACT_MS);
    holdTimer = window.setTimeout(() => {
      overlay.classList.add('is-final-release');
      blurTimer = window.setTimeout(animateReveal, IMG_SHRINK_MS);
      finishOverlay();
    }, HOLD_MS);
  }

  function initOverlay() {
    if (started) return;
    finished = false;
    finishPending = false;
    haloCycleStart = performance.now();
    [peakTimer, haloTimer, holdTimer, removeTimer, blurTimer].forEach(t => window.clearTimeout(t));
    if (rafId) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
    overlay.hidden = false;
    lockLoaderCenter();
    overlay.classList.add('is-assets-ready', 'is-animating');
    overlay.classList.remove('is-assets-pending', 'is-ring-contracting', 'is-halo-hidden', 'is-image-pop',
      'is-final-release', 'is-hidden', 'is-scroll-passthrough');
    blurScreen.classList.remove('is-revealing');
    ['--rina-reveal-solid', '--rina-reveal-a', '--rina-reveal-b', '--rina-reveal-c', '--rina-reveal-d',
      '--rina-reveal-e', '--rina-reveal-outer'
    ].forEach(p => blurScreen.style.setProperty(p, '0px'));
    setOrigin();
    overlay.setAttribute('aria-label', '页面加载中');
    started = true;
    window.rinaLoaderStartedAt = haloCycleStart;
    // 悬停加载图片刻意不在这里（第 3 阶段）预加载。它会在
    // doFinish() 中延迟加载，也就是第 4 阶段首屏揭示之后，以保持初始预加载最小。
    if (finishQueued) {
      finishQueued = false;
      requestAnimationFrame(requestFinish);
    }
  }
  window.rinaLoaderComplete = requestFinish;
  window.rinaLoadingImagesReadyPromise = preloadInitialLoadingImage();
  window.rinaStartLoaderAnimation = async function() {
    await window.rinaLoadingImagesReadyPromise;
    initOverlay();
  };
  window.addEventListener('resize', scheduleLoaderHorizontalCenterSync, {
    passive: true
  });
  window.visualViewport?.addEventListener('resize', scheduleLoaderHorizontalCenterSync, {
    passive: true
  });
})();

function finishBootVisibility() {
  document.documentElement.dataset.bootPhase = 'ready';
  if (window.rinaLoaderComplete) window.rinaLoaderComplete();
}
async function waitForBootLoaderMinimum(bootStart) {
  if (window.rinaStartLoaderAnimation) await window.rinaStartLoaderAnimation();
  const startedAt = Number(window.rinaLoaderStartedAt) || bootStart;
  const elapsed = performance.now() - startedAt;
  if (elapsed < BOOT_MIN_DISPLAY_MS) await new Promise(r => setTimeout(r, BOOT_MIN_DISPLAY_MS - elapsed));
}

function showBootUiBehindLoader() {
  if (document.documentElement.dataset.bootPhase === 'preload') {
    document.documentElement.dataset.bootPhase = 'ui-ready';
  }
}
async function bootFastJsonGet(path, timeoutMs = BOOT_STATUS_TIMEOUT_MS) {
  const url = apiUrl(path);
  firmware.lastRequest = `GET ${path}`;
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = 'offline html mode';
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: 'GET',
      cache: 'no-store',
      headers: {
        'Accept': 'application/json'
      },
      signal: controller?.signal
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ''}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {});
  } catch (err) {
    if (err?.name === 'AbortError') throw new Error(`status timeout after ${timeoutMs}ms`);
    throw err;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function rememberFirmwareStatusPoll(data) {
  const version = Number(data?.version ?? data?.v);
  if (Number.isFinite(version)) firmwareStatusVersion = version;
  const next = Number(data?.next_poll_ms);
  if (Number.isFinite(next) && next > 0) firmwareNextPollMs = Math.max(250, Math.min(10000, next));
}

function firmwareStatusPath(summaryOnly = false) {
  const params = [];
  if (summaryOnly) params.push('runtimeOnly=1', 'noFrame=1');
  if (firmwareStatusVersion !== null) params.push(`since=${encodeURIComponent(firmwareStatusVersion)}`);
  return params.length ? `${API_ENDPOINTS.status}?${params.join('&')}` : API_ENDPOINTS.status;
}
async function preloadFirmwareRuntimeState() {
  bootRuntimeSnapshot = {
    attempted: true,
    ok: false,
    error: '',
    data: null
  };
  if (isOfflineHtmlMode()) {
    setFirmwareStatus({
      online: false,
      lastStatus: 'offline html mode',
      lastError: 'offline: firmware runtime read skipped'
    });
    bootRuntimeSnapshot.error = 'offline html mode';
    return bootRuntimeSnapshot;
  }
  try {
    lastFirmwareStatusPollAt = performance.now();
    // 获取完整状态（包含 renderer.lastM370 中的第一帧 LED），
    // 而不是 runtimeOnly/noFrame 摘要，并用 skipFrame:false 应用它，
    // 让基础矩阵预览在加载动画期间就由第一帧填充。
    const data = await bootFastJsonGet(firmwareStatusPath(false));
    rememberFirmwareStatusPoll(data);
    bootRuntimeSnapshot = {
      attempted: true,
      ok: true,
      error: '',
      data
    };
    applyFirmwareRuntimeState(data, 'page_boot_runtime', {
      skipFrame: false
    });
    setFirmwareStatus({
      lastStatus: 'firmware runtime read ok'
    });
    return bootRuntimeSnapshot;
  } catch (err) {
    bootRuntimeSnapshot.error = err.message || String(err);
    setFirmwareStatus({
      online: false,
      lastStatus: 'firmware runtime read failed',
      lastError: bootRuntimeSnapshot.error
    });
    if (shouldLogApiError()) log(`启动读取固件状态失败: ${bootRuntimeSnapshot.error}`);
    return bootRuntimeSnapshot;
  }
}
async function syncRuntimeStateFromFirmware(source = 'webui_load') {
  if (firmwareFullStatusInFlight) return false;
  firmwareFullStatusInFlight = true;
  try {
    lastFirmwareStatusPollAt = performance.now();
    const data = await apiGet(firmwareStatusPath(false));
    rememberFirmwareStatusPoll(data);
    if (!data?.unchanged) {
      applyFirmwareRuntimeState(data, source);
      renderState();
    }
    return true;
  } catch (err) {
    if (!isOfflineHtmlMode() && shouldLogApiError()) log(`读取固件运行/预览状态失败: ${err.message}`);
    return false;
  } finally {
    firmwareFullStatusInFlight = false;
  }
}
async function syncRuntimeSummaryFromFirmware(source = 'firmware_poll_runtime_summary') {
  if (firmwareRuntimeSummaryInFlight) return false;
  firmwareRuntimeSummaryInFlight = true;
  try {
    lastFirmwareStatusPollAt = performance.now();
    const data = await apiGet(firmwareStatusPath(true));
    rememberFirmwareStatusPoll(data);
    if (!data?.unchanged) applyFirmwareRuntimeState(data, source, {
      skipFrame: true
    });
    return true;
  } catch (err) {
    if (!isOfflineHtmlMode() && shouldLogApiError()) log(`读取固件轻量状态失败: ${err.message}`);
    return false;
  } finally {
    firmwareRuntimeSummaryInFlight = false;
  }
}

function startFirmwareStatusPolling() {
  if (firmwareStatusPollTimer || isOfflineHtmlMode()) return;
  firmwareStatusPollTimer = setInterval(() => {
    const firmwareIsScrolling = state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state
      .playback);
    const scrollPageNeedsFastStopNotice = firmwareIsScrolling && isScrollPageActive();
    const minInterval = scrollPageNeedsFastStopNotice ? Math.min(550, firmwareNextPollMs) : Math.max(1000,
      firmwareNextPollMs);
    if (performance.now() - lastFirmwareStatusPollAt < minInterval) return;
    if (firmwareIsScrolling) {
      syncRuntimeSummaryFromFirmware(scrollPageNeedsFastStopNotice ? 'firmware_poll_scroll_runtime' :
        'firmware_poll_scroll_summary');
    } else {
      syncRuntimeStateFromFirmware('firmware_poll');
    }
  }, 500);
}
async function refreshPowerStatusFromFirmware(source = 'power_timer', force = false) {
  if (isOfflineHtmlMode() || powerStatusRefreshInFlight || firmwareFullStatusInFlight ||
    firmwareRuntimeSummaryInFlight) return;
  const now = performance.now();
  if (!force && now - lastPowerStatusRefreshAt < POWER_STATUS_REFRESH_MS) return;
  powerStatusRefreshInFlight = true;
  try {
    lastPowerStatusRefreshAt = now;
    const data = await apiGet(API_ENDPOINTS.power);
    const powerPayload = data?.power && typeof data.power === 'object' ? data.power : data;
    applyPowerData(powerPayload);
    renderState();
  } catch (err) {
    if (shouldLogApiError()) log(`power status refresh failed: ${err.message}`);
  } finally {
    powerStatusRefreshInFlight = false;
  }
}

function startPowerStatusPolling() {
  if (powerStatusPollTimer || isOfflineHtmlMode()) return;
  refreshPowerStatusFromFirmware('basic_power_start', true);
  powerStatusPollTimer = setInterval(() => {
    if (!['basic', 'debug'].includes(document.body?.dataset?.page)) return;
    refreshPowerStatusFromFirmware('power_timer');
  }, 1000);
}

function stopPollingTimers() {
  if (firmwareStatusPollTimer) {
    clearInterval(firmwareStatusPollTimer);
    firmwareStatusPollTimer = null;
  }
  if (powerStatusPollTimer) {
    clearInterval(powerStatusPollTimer);
    powerStatusPollTimer = null;
  }
}
window.addEventListener('pagehide', stopPollingTimers);

function setNavMenuOpen(open) {
  const nav = $('nav');
  const toggle = $('brand-nav-toggle');
  const topNav = $('top-page-nav');
  if (!nav || !toggle || !topNav) return;
  topNav.classList.toggle('open', open);
  nav.classList.toggle('open', open);
  toggle.classList.toggle('active', open);
  toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  topNav.setAttribute('aria-hidden', open ? 'false' : 'true');
  nav.setAttribute('aria-hidden', open ? 'false' : 'true');
  topNav.inert = !open;
  nav.querySelectorAll('button').forEach(btn => {
    btn.tabIndex = open ? 0 : -1;
  });
  updateCurrentPageLabel(document.body.dataset.page || 'basic');
}

function updateCurrentPageLabel(id) {
  const item = PAGES.find(([pid]) => pid === id);
  const pageText = item ? `${item[1]} ${item[2]}` : '';
  const toggle = $('brand-nav-toggle');
  if (pageText && toggle) {
    const open = toggle.getAttribute('aria-expanded') === 'true';
    toggle.title = pageText;
    toggle.setAttribute('aria-label', `${open ? '关闭' : '打开'}页面切换器：${pageText}`);
  }
}

function modeForPage(id) {
  if (id === 'scroll') return 'scroll';
  if (id === 'custom') return 'custom';
  if (id === 'parts') return 'parts';
  if (id === 'debug') return 'debug';
  return 'face';
}
let debugLayoutCards = [];
let debugLayoutColumnCount = 0;
let debugLayoutRaf = 0;

function responsiveColumnCount() {
  const width = window.innerWidth || document.documentElement.clientWidth || 0;
  if (width <= LAYOUT_ONE_COLUMN_MAX_PX) return 1;
  if (width >= LAYOUT_THREE_COLUMNS_MIN_PX) return 3;
  return 2;
}

function scheduleDebugMasonryLayout(force = false) {
  if (document.body?.dataset?.page !== 'debug') return;
  if (debugLayoutRaf) cancelAnimationFrame(debugLayoutRaf);
  debugLayoutRaf = requestAnimationFrame(() => {
    debugLayoutRaf = 0;
    setupDebugMasonryLayout(force);
  });
}

function setupDebugMasonryLayout(force = false) {
  const layout = document.querySelector('#page-debug .debug-layout');
  if (!layout) return;
  const currentCards = [...layout.querySelectorAll('.debug-column > .card, :scope > .card')];
  if (!debugLayoutCards.length) {
    debugLayoutCards = currentCards;
    debugLayoutCards.forEach((card, index) => {
      card.dataset.debugOrder = String(index);
    });
  }
  const cards = debugLayoutCards.filter(card => card && layout.contains(card));
  const count = responsiveColumnCount();
  if (!force && debugLayoutColumnCount === count && layout.querySelectorAll(':scope > .debug-column').length === count)
    return;
  const scrollEl = document.scrollingElement || document.documentElement;
  const prevScrollTop = scrollEl ? scrollEl.scrollTop : 0;
  const prevScrollLeft = scrollEl ? scrollEl.scrollLeft : 0;
  const columns = Array.from({
    length: count
  }, (_, index) => {
    const column = document.createElement('div');
    column.className = 'debug-column';
    column.dataset.debugColumn = String(index + 1);
    return column;
  });
  const columnHeights = Array.from({
    length: count
  }, () => 0);
  cards.sort((a, b) => Number(a.dataset.debugOrder || 0) - Number(b.dataset.debugOrder || 0))
    .forEach((card, index) => {
      const measuredHeight = card.getBoundingClientRect().height || 0;
      const shortest = columnHeights.indexOf(Math.min(...columnHeights));
      const columnIndex = measuredHeight > 0 ? shortest : index % count;
      columns[columnIndex].appendChild(card);
      columnHeights[columnIndex] += measuredHeight;
    });
  layout.replaceChildren(...columns);
  debugLayoutColumnCount = count;
  scheduleMatrixFitRender(2);
  if (force && prevScrollTop > 0 && scrollEl) {
    requestAnimationFrame(() => {
      scrollEl.scrollTop = prevScrollTop;
      scrollEl.scrollLeft = prevScrollLeft;
    });
  }
}

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
    requestAnimationFrame(() => {
      autoResizeScrollTextInput();
      updateScrollUi();
    });
  }
  if (id === 'custom') requestAnimationFrame(() => {
    const a = $('custom-m370');
    if (a) autoResizeTextarea(a);
  });
  if (id === 'parts') requestAnimationFrame(() => {
    const a = $('parts-m370-text');
    if (a) autoResizeTextarea(a);
  });
  if (id === 'debug') {
    requestAnimationFrame(() => {
      setupDebugMasonryLayout(true);
      const a = $('debug-m370');
      if (a) autoResizeTextarea(a);
    });
    refreshPowerStatusFromFirmware('debug_page_enter', true);
  }
  if (id === 'basic') {
    syncRuntimeStateFromFirmware('basic_page_enter');
    refreshPowerStatusFromFirmware('basic_page_enter', true);
  }
}

// -----------------------------------------------------------------------------
// 导航、响应式布局和自定义选择器
// -----------------------------------------------------------------------------
function initNav() {
  const nav = $('nav');
  nav.innerHTML = '';
  const toggle = $('brand-nav-toggle');
  if (toggle) toggle.onclick = (ev) => {
    ev.stopPropagation();
    setNavMenuOpen(!nav.classList.contains('open'));
  };
  nav.onclick = (ev) => ev.stopPropagation();
  for (const [id, num, name] of PAGES) {
    const b = document.createElement('button');
    b.type = 'button';

    b.dataset.page = id;
    b.setAttribute('role', 'menuitem');
    b.innerHTML = `<span>${name}</span><span class="num">${num}</span>`;
    if (id === 'basic') b.classList.add('active');
    b.onclick = () => switchPage(id);
    nav.appendChild(b);
  }
  updateCurrentPageLabel('basic');
  document.body.dataset.page = 'basic';
  setNavMenuOpen(false);
  document.addEventListener('click', (ev) => {
    if (!$('nav-shell')?.contains(ev.target)) setNavMenuOpen(false);
  });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') setNavMenuOpen(false);
  });
}

function viewportBoundsForFixedMenu() {
  const vv = window.visualViewport;
  const left = Math.floor(vv?.offsetLeft || 0);
  const top = Math.floor(vv?.offsetTop || 0);
  const width = Math.floor(vv?.width || document.documentElement.clientWidth || window.innerWidth || 0);
  const height = Math.floor(vv?.height || document.documentElement.clientHeight || window.innerHeight || 0);
  return {
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height
  };
}
let selectScrollLock = null;
const SELECT_MENU_HIDE_DELAY_MS = WEBUI_CONFIG.interaction.selectMenuHideDelayMs;

function lockPageScrollForSelects() {
  if (selectScrollLock) return;
  // 只是一个标记：通过拦截事件阻止滚动，保持
  // 滚动条可见且布局不变（不修改 overflow）。
  selectScrollLock = true;
}

function unlockPageScrollForSelects() {
  selectScrollLock = null;
}

function syncSelectPageScrollLock() {
  if (document.querySelector('.select-shell.open')) lockPageScrollForSelects();
  else unlockPageScrollForSelects();
}
// 阻止下拉菜单外的 touchmove（触摸滚动）
function selectMenuCanScroll(menu) {
  return !!menu && getComputedStyle(menu).overflowY !== 'hidden' && menu.scrollHeight > menu.clientHeight + 1;
}

function blockPageTouchMoveWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.('.select-menu');
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
// 阻止下拉菜单外的 wheel 事件（鼠标/触控板滚动）
function blockPageWheelWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.('.select-menu');
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
// 阻止下拉菜单外的键盘滚动键
const PAGE_SCROLL_KEYS = new Set(WEBUI_CONFIG.interaction.pageScrollKeys);

function blockPageKeyScrollWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.('.select-menu');
  if (selectMenuCanScroll(menu)) return;
  if (PAGE_SCROLL_KEYS.has(ev.key)) ev.preventDefault();
}

function positionSelectMenu(shell, options = {}) {
  const toggle = shell.querySelector('.select-toggle');
  const menu = shell._selectMenu;
  if (!toggle || !menu) return;
  const r = toggle.getBoundingClientRect();
  const viewport = viewportBoundsForFixedMenu();
  const viewportPadding = 8;
  const menuGap = 8;
  // verticalOnly：跳过宽度/左偏移重算（用于窗口滚动事件，防止水平跳动）
  if (!options.verticalOnly) {
    // 镜像切换按钮的精确宽度和左边缘，不做舍入或夹取。
    shell._selectMenuWidth = r.width; // 保持为真值，让“已打开”标记持续有效
    menu.style.width = r.width + 'px';
    menu.style.left = r.left + 'px';
  }
  // 默认放在下方；空间不足时翻到上方
  const spaceBelow = Math.max(0, viewport.bottom - r.bottom - menuGap - viewportPadding);
  const spaceAbove = Math.max(0, r.top - viewport.top - menuGap - viewportPadding);
  const openBelow = spaceBelow >= 96 || spaceBelow >= spaceAbove;
  // 可用高度等于所选方向的完整空间，不设置任意上限。
  // 菜单会尽量展开以显示所有按钮；只有放不下时才进行不可见滚动。
  const availableHeight = Math.max(48, openBelow ? spaceBelow : spaceAbove);
  const menuStyle = getComputedStyle(menu);
  const borderY = parseFloat(menuStyle.borderTopWidth || '0') + parseFloat(menuStyle.borderBottomWidth || '0');
  const naturalH = menu.scrollHeight; // 内容完整高度，包含内边距但不含边框
  const naturalOuterH = Math.ceil(naturalH + borderY);
  const fitsAllOptions = naturalOuterH <= availableHeight + 1;
  const menuH = fitsAllOptions ? naturalOuterH : availableHeight;
  menu.style.maxHeight = menuH + 'px';
  menu.style.overflowY = fitsAllOptions ? 'hidden' : 'auto';
  const desiredTop = openBelow ? r.bottom + menuGap : r.top - menuGap - menuH;
  menu.style.top = Math.max(viewport.top + viewportPadding, Math.min(desiredTop, viewport.bottom - menuH -
    viewportPadding)) + 'px';
  menu.style.bottom = 'auto';
}

function closeOneCustomSelect(shell) {
  if (!shell) return;
  shell.classList.remove('open');
  const btn = shell.querySelector('.select-toggle');
  const menu = shell._selectMenu;
  if (btn) btn.setAttribute('aria-expanded', 'false');
  if (menu) {
    menu.setAttribute('aria-hidden', 'true');
    menu.classList.remove('open');
    clearTimeout(menu._hideTimer);
    menu._hideTimer = setTimeout(() => {
      if (!shell.classList.contains('open')) {
        menu.style.display = 'none';
        shell._selectMenuWidth = 0;
      }
    }, SELECT_MENU_HIDE_DELAY_MS);
  } else {
    shell._selectMenuWidth = 0;
  }
}

function closeCustomSelects(exceptShell = null) {
  document.querySelectorAll('.select-shell.open').forEach(shell => {
    if (shell !== exceptShell) {
      closeOneCustomSelect(shell);
    }
  });
  syncSelectPageScrollLock();
}

function splitDropdownLabel(text) {
  const raw = String(text || '').trim();
  const match = raw.match(/^(.*?)\s{2,}(.+)$/);
  if (match) return [match[1].trim(), match[2].trim()];
  return [raw, ''];
}

function ensureCustomSelect(select) {
  if (!select) return null;
  const shell = select.closest('.select-shell');
  if (!shell) return null;
  let toggle = shell.querySelector('.select-toggle');
  let menu = shell.querySelector('.select-menu');
  if (!toggle) {
    toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'select-toggle';
    toggle.setAttribute('aria-haspopup', 'menu');
    toggle.setAttribute('aria-expanded', 'false');
    toggle.innerHTML = '<span class="select-label"></span><span class="select-caret" aria-hidden="true">▾</span>';
    shell.insertBefore(toggle, select.nextSibling);
    const oldCaret = shell.querySelector(':scope > .select-caret');
    if (oldCaret && oldCaret !== toggle.querySelector('.select-caret')) oldCaret.remove();
    toggle.onclick = (ev) => {
      ev.stopPropagation();
      const willOpen = !shell.classList.contains('open');
      closeCustomSelects(shell);
      shell.classList.toggle('open', willOpen);
      toggle.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
      const m = shell._selectMenu;
      if (m) {
        m.setAttribute('aria-hidden', willOpen ? 'false' : 'true');
        if (willOpen) {
          lockPageScrollForSelects();
          clearTimeout(m._hideTimer);
          m.style.display = 'grid';
          m.classList.remove('open');
          positionSelectMenu(shell, {
            recalcWidth: true
          });
          requestAnimationFrame(() => {
            if (shell.classList.contains('open')) m.classList.add('open');
          });
        } else {
          closeOneCustomSelect(shell);
          syncSelectPageScrollLock();
        }
      }
    };
  }
  if (!shell._selectMenu) {
    menu = document.createElement('div');
    menu.className = 'select-menu';
    menu.setAttribute('role', 'menu');
    menu.setAttribute('aria-hidden', 'true');
    menu.style.display = 'none';
    document.body.appendChild(menu);
    shell._selectMenu = menu;
    menu._shell = shell;
    menu.onclick = (ev) => ev.stopPropagation();
  } else {
    menu = shell._selectMenu;
  }
  return {
    shell,
    toggle,
    menu
  };
}

function refreshSelectDropdown(idOrSelect) {
  const select = typeof idOrSelect === 'string' ? $(idOrSelect) : idOrSelect;
  const ui = ensureCustomSelect(select);
  if (!select || !ui) return;
  const selected = select.options[select.selectedIndex] || select.options[0];
  const label = ui.toggle.querySelector('.select-label');
  if (label) label.textContent = selected ? selected.textContent.trim() : '选择';
  ui.menu.innerHTML = '';
  Array.from(select.options).forEach((opt) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'select-option';
    b.setAttribute('role', 'menuitem');
    b.dataset.value = opt.value;
    const [main, detail] = splitDropdownLabel(opt.textContent);
    const detailColor = detail && detail.match(/#[0-9a-fA-F]{6}\b/);
    if (detailColor) b.style.setProperty('--option-color', detailColor[0]);
    const mainSpan = document.createElement('span');
    mainSpan.textContent = main;
    b.appendChild(mainSpan);
    if (detail) {
      const detailSpan = document.createElement('span');
      detailSpan.className = 'num';
      detailSpan.textContent = detail;
      b.appendChild(detailSpan);
    }
    b.classList.toggle('active', opt.value === select.value);
    b.onclick = (ev) => {
      ev.stopPropagation();
      select.value = opt.value;
      select.dispatchEvent(new Event('change', {
        bubbles: true
      }));
      closeOneCustomSelect(ui.shell);
      syncSelectPageScrollLock();
      refreshAllCustomSelects();
    };
    ui.menu.appendChild(b);
  });
}

function refreshAllCustomSelects() {
  document.querySelectorAll('.select-shell select').forEach(sel => refreshSelectDropdown(sel));
}

function initCustomSelectDropdowns() {
  document.querySelectorAll('.select-shell select').forEach(sel => {
    ensureCustomSelect(sel);
    sel.addEventListener('change', () => requestAnimationFrame(refreshAllCustomSelects));
  });
  refreshAllCustomSelects();
  document.addEventListener('click', () => closeCustomSelects());
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') closeCustomSelects();
    blockPageKeyScrollWhileSelectOpen(ev);
  });
  document.addEventListener('touchmove', blockPageTouchMoveWhileSelectOpen, {
    passive: false
  });
  window.addEventListener('wheel', blockPageWheelWhileSelectOpen, {
    passive: false
  });
  // 滚动或调整尺寸时重新定位已打开的菜单
  const reposition = () => {
    document.querySelectorAll('.select-shell.open').forEach(shell => positionSelectMenu(shell));
  };
  const resizeReposition = () => {
    document.querySelectorAll('.select-shell.open').forEach(shell => positionSelectMenu(shell, {
      recalcWidth: true
    }));
  };
  window.addEventListener('resize', resizeReposition, {
    passive: true
  });
  window.visualViewport?.addEventListener('resize', reposition, {
    passive: true
  });
  // visualViewport 滚动（双指缩放后的平移）：需要完整重定位
  window.visualViewport?.addEventListener('scroll', reposition, {
    passive: true
  });
  // 窗口滚动：只更新垂直位置，避免水平宽度/左偏移跳动。
  // 滚动锁定时完全跳过（页面并未真正滚动，这些事件是冗余的）。
  window.addEventListener('scroll', () => {
    if (selectScrollLock) return;
    document.querySelectorAll('.select-shell.open').forEach(shell => positionSelectMenu(shell, {
      verticalOnly: true
    }));
  }, {
    passive: true,
    capture: true
  });
}

// -----------------------------------------------------------------------------
// LED 矩阵渲染和编辑
// -----------------------------------------------------------------------------
function initMatrix(id, frameProvider, editable = false, editHandler = null, compact = false) {
  const el = $(id);
  if (!el) return;
  el.innerHTML = '';
  if (compact) el.classList.add('compact');
  for (let y = 0; y < ROWS; y++) {
    for (let x = 0; x < COLS; x++) {
      const idx = XY_TO_INDEX[y][x];
      const cell = document.createElement('div');
      cell.className = 'led' + (idx < 0 ? ' invalid' : '') + (editable && idx >= 0 ? ' editable' : '');
      if (idx >= 0) {
        cell.dataset.idx = idx;
        cell.dataset.x = x;
        cell.dataset.y = y;
      }
      el.appendChild(cell);
    }
  }
  const view = {
    el,
    frameProvider,
    compact: !!compact
  };
  matrixViews.push(view);
  if (editable) {
    el.classList.add('editable-matrix');
    attachDrawing(el, editHandler);
  }
  fitMatrix(view);
}

function matrixSizeNumber(style, name, fallback) {
  const v = parseFloat(style.getPropertyValue(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

function elementOuterBlockSize(el) {
  if (!el || el.hidden) return 0;
  const st = getComputedStyle(el);
  if (st.display === 'none') return 0;
  const r = el.getBoundingClientRect();
  return r.height + (parseFloat(st.marginTop) || 0) + (parseFloat(st.marginBottom) || 0);
}

function matrixMaxContentHeight(wrap, configuredMaxHeight) {
  if (!(configuredMaxHeight > 0)) return Infinity;
  const card = wrap.closest('.led-preview-card,.debug-measure-card');
  if (!card) return configuredMaxHeight;
  const cardStyle = getComputedStyle(card);
  const cardChrome =
    (parseFloat(cardStyle.paddingTop) || 0) +
    (parseFloat(cardStyle.paddingBottom) || 0) +
    (parseFloat(cardStyle.borderTopWidth) || 0) +
    (parseFloat(cardStyle.borderBottomWidth) || 0);
  let reserved = cardChrome;
  if (wrap.parentElement === card) {
    for (const child of card.children) {
      if (child === wrap) continue;
      reserved += elementOuterBlockSize(child);
    }
    const rowGap = parseFloat(cardStyle.rowGap || cardStyle.gap) || 0;
    if (card.children.length > 1) reserved += rowGap * (card.children.length - 1);
  }
  return Math.max(1, configuredMaxHeight - reserved);
}

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

function fitAllMatrices() {
  matrixViews.forEach(fitMatrix);
}
let matrixResizeObserver = null;
let matrixFitRaf = 0;
let matrixFitSettleFrames = 0;

function runMatrixFitRender() {
  matrixFitRaf = 0;
  fitAllMatrices();
  renderMatrices();
  if (matrixFitSettleFrames > 0) {
    matrixFitSettleFrames--;
    matrixFitRaf = requestAnimationFrame(runMatrixFitRender);
  }
}

function scheduleMatrixFitRender(settleFrames = 1) {
  matrixFitSettleFrames = Math.max(matrixFitSettleFrames, settleFrames);
  if (matrixFitRaf) return;
  matrixFitRaf = requestAnimationFrame(runMatrixFitRender);
}

function observeMatrixWraps() {
  if (matrixResizeObserver) return;
  const onResize = () => scheduleMatrixFitRender(2);
  if (typeof ResizeObserver !== 'undefined') {
    matrixResizeObserver = new ResizeObserver(onResize);
    document.querySelectorAll('.matrix-wrap,.led-preview-card,.debug-measure-card').forEach(el => matrixResizeObserver
      .observe(el));
  } else {
    matrixResizeObserver = {
      disconnect() {}
    };
  }
  window.addEventListener('resize', onResize, {
    passive: true
  });
  window.addEventListener('resize', () => scheduleDebugMasonryLayout(true), {
    passive: true
  });
  window.addEventListener('orientationchange', onResize, {
    passive: true
  });
  window.addEventListener('orientationchange', () => scheduleDebugMasonryLayout(true), {
    passive: true
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', onResize, {
      passive: true
    });
    window.visualViewport.addEventListener('resize', () => scheduleDebugMasonryLayout(), {
      passive: true
    });
    window.visualViewport.addEventListener('scroll', onResize, {
      passive: true
    });
  }
}

function renderMatrices() {
  for (const view of matrixViews) {
    const frame = view.frameProvider();
    const cells = view.el.children;
    for (let y = 0, n = 0; y < ROWS; y++) {
      for (let x = 0; x < COLS; x++, n++) {
        const idx = XY_TO_INDEX[y][x];
        if (idx >= 0) cells[n].classList.toggle('on', !!frame[idx]);
      }
    }
  }
}

function attachDrawing(el, editHandler) {
  const getCell = target => target && target.closest && target.closest('.led.editable');
  el.addEventListener('click', ev => {
    const cell = getCell(ev.target);
    if (!cell || !cell.dataset.idx) return;
    ev.stopPropagation();
    const idx = Number(cell.dataset.idx);
    editHandler(idx, !editFrame[idx], 'toggle');
  });
}

function formatVolts(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${n.toFixed(2)} V` : 'n/a';
}

function formatBatteryPercent(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${Math.round(n)}%` : 'n/a';
}

function formatChargingState(value) {
  return typeof value === 'boolean' ? (value ? '充电中' : '未充电') : 'n/a';
}

function formatChargingBadge(value) {
  return typeof value === 'boolean' ? (value ? '充电中' : '未充电') : '充电 --';
}

function formatMilliVolts(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${Math.round(n)} mV` : 'n/a';
}

function batteryPowerText() {
  return state.batteryPowered === false ? '未上电' : (state.batteryStateText || '电池');
}

// -----------------------------------------------------------------------------
// UI 渲染器
// -----------------------------------------------------------------------------
function renderState() {
  const library = getAllFaces();
  const currentFace = library[state.faceIndex] || {
    name: '—',
    type: '—'
  };
  updateModeToggleUi();
  const kv = $('state-kv');
  if (kv) kv.innerHTML = kvRows([
    ['当前模式', state.mode],
    ['当前表情序号', `${library.length ? state.faceIndex+1 : 0} / ${library.length}`],
    ['当前表情名称', currentFace.name],
    ['当前表情属性', faceTypeLabel(currentFace.type)],
    ['当前亮度', `${state.brightness}/255`],
    ['当前颜色', state.color],
    ['当前播放状态', state.playback],
    ['当前 AP Domain', state.apDomain],
    ['当前 AP IP', state.apIp],
    ['刷新策略', state.refreshPolicy],
    ['最近刷新原因', state.lastRefreshReason],
    ['刷新计数', state.refreshCount]
  ]);
  const dk = $('debug-kv');
  if (dk) dk.innerHTML = kvRows([
    ['LED 数量', TOTAL_LEDS],
    ['矩阵', `${COLS}x${ROWS} / 不规则 370`],
    ['M370 长度', '93 hex + M370:'],
    ['亮度 raw', `${state.brightness}`],
    ['DPS 状态', state.dpsActive ? 'active' : 'inactive'],
    ['播放状态', state.playback],
    ['文字滚动', state.textScrollActive ? 'active' : 'inactive'],
    ['实际 FPS', state.actualFps.toFixed(1)],
    ['电池状态', batteryPowerText()],
    ['低压未上电锁定', state.batteryLowVoltageUnpowered ? '是' : '否'],
    ['Vbat', `${formatVolts(state.batteryV)} / ${formatBatteryPercent(state.batteryPercent)}`],
    ['电池瞬时电压', formatVolts(state.batteryLastInstantVbat)],
    ['未上电电压阈值', formatVolts(state.batteryUnpoweredLowThreshold)],
    ['电池最低电压记录', formatVolts(state.batteryMinV)],
    ['电池最高电压记录', formatVolts(state.batteryMaxV)],
    ['电池 ADC raw', formatMilliVolts(state.batteryAdcMv)],
    ['上次电池 ADC raw', formatMilliVolts(state.batteryPrevAdcMv)],
    ['断电快速压降',
      `${formatMilliVolts(state.batteryDisconnectDropMv)} / 阈值 ${formatMilliVolts(state.batteryDisconnectDropThresholdMv)}`
    ],
    ['断电低 ADC 阈值', formatMilliVolts(state.batteryDisconnectLowThresholdMv)],
    ['恢复 ADC 阈值', formatMilliVolts(state.batteryReconnectThresholdMv)],
    ['Vcharge', `${formatVolts(state.chargeV)} / ${formatChargingState(state.charging)}`],
    ['充电 ADC raw', formatMilliVolts(state.chargeAdcMv)],
    ['AP SSID', DEVICE_AP_SSID],
    ['AP 密码', DEVICE_AP_PASSWORD],
    ['AP Domain', state.apDomain],
    ['AP IP', state.apIp]
  ]);
  const battDot = $('badge-battery-dot'),
    battLabel = $('badge-battery-label');
  if (battDot && battLabel) {
    const pct = state.batteryPercent,
      vbat = state.batteryV;
    battLabel.textContent = state.batteryPowered === false ?
      `未上电 ${formatVolts(vbat)}` :
      `电池 ${formatVolts(vbat)}  ${formatBatteryPercent(pct)}`;
    battDot.className = state.batteryIconClass || 'status-dot dim';
    battDot.style.backgroundColor = state.batteryIconColor || '';
  }
  const chgDot = $('badge-charging-dot'),
    chgLabel = $('badge-charging-label');
  if (chgDot && chgLabel) {
    chgDot.className = state.chargeIconClass || 'status-dot dim';
    chgDot.style.backgroundColor = state.chargeIconColor || '';
    chgLabel.textContent = state.charging === true ?
      `充电中 ${formatVolts(state.chargeV)}` :
      formatChargingBadge(state.charging);
  }
  const rk = $('resource-kv');
  if (rk) rk.innerHTML = kvRows([
    ['JSON format', EXPRESSION_PARTS.format],
    ['version', EXPRESSION_PARTS.version],
    ['stored_unique_parts', EXPRESSION_PARTS.counts.stored_unique_parts],
    ['callable_ids', EXPRESSION_PARTS.counts.callable_ids],
    ['eye_left', EXPRESSION_PARTS.counts.stored_by_group.eye_left],
    ['eye_right', EXPRESSION_PARTS.counts.stored_by_group.eye_right],
    ['mouth', EXPRESSION_PARTS.counts.stored_by_group.mouth],
    ['cheek', EXPRESSION_PARTS.counts.callable_by_group.cheek],
    ['default_faces', defaultFaces.length],
    ['user_saved_faces', userFaces.length],
    ['interface_mode', 'HTML generates M370 / firmware receives commands'],
    ['face_library_json', firmware.savedFacesPath],
    ['physical_wiring', SERPENTINE_WIRING ? 'serpentine / odd rows reversed' : 'linear'],
    ['parts_compose', 'm370 logical row-major canonical'],
    ['parts_eye_symmetry', partsSymmetry ? 'on / same display index' : 'off'],
    ['preview_scale', 'smooth fractional --cell live scaling / card horizontal-min vertical-max fit'],
    ['basic_layout', 'wide side-by-side']
  ]);
  const fk = $('firmware-kv');
  if (fk) fk.innerHTML = kvRows([
    ['online', firmware.online ? '✓ connected' : '✗ offline'],
    ['lastRequest', firmware.lastRequest],
    ['lastStatus', firmware.lastStatus],
    ['lastError', firmware.lastError],
    ['sentFrames', String(firmware.sentFrames)],
    ['sentCommands', String(firmware.sentCommands)],
    ['frameQueue', `${firmware.frameQueue}/${WEBUI_M370_QUEUE_MAX}`],
    ['buttonQueue', `${firmware.buttonQueue}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX}`],
    ['droppedFrames', String(firmware.droppedFrames)],
    ['droppedCommands', String(firmware.droppedCommands)],
    ['savedFacesSync', firmware.savedFacesSync]
  ]);
  scheduleDebugMasonryLayout();
}

function kvRows(rows) {
  return rows.map(([k, v]) => `<span class="k">${escapeHtml(k)}</span><span>${escapeHtml(String(v))}</span>`).join('');
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  } [c]));
}

function autoResizeTextarea(el) {
  if (!el) return;
  // 如果元素（或任一祖先）是 display:none，offsetParent 会是 null，
  // scrollHeight 也会返回 0。此时直接退出，避免把高度压成 0px；
  // 页面显示后 switchPage() 会再次调用这里。
  if (el.offsetParent === null && el !== document.body) {
    el.dataset.pendingAutoresize = '1';
    return;
  }
  el.style.overflow = 'visible';
  el.style.height = 'auto';
  const h = el.scrollHeight;
  el.style.overflow = 'hidden';
  el.style.height = Math.max(h, 1) + 'px';
  delete el.dataset.pendingAutoresize;
}

function autoResizeM370Textareas() {
  const a = $('custom-m370');
  if (a) autoResizeTextarea(a);
  const b = $('parts-m370-text');
  if (b) autoResizeTextarea(b);
  const c = $('debug-m370');
  if (c) autoResizeTextarea(c);
}

function updateM370Views() {
  if ($('custom-m370')) {
    $('custom-m370').value = frameToM370(editFrame);
    requestAnimationFrame(() => autoResizeTextarea($('custom-m370')));
  }
  if ($('parts-m370-text')) {
    $('parts-m370-text').value = frameToM370(partsFrame);
    requestAnimationFrame(() => autoResizeTextarea($('parts-m370-text')));
  }
}

// -----------------------------------------------------------------------------
// 颜色、亮度和模式控制
// -----------------------------------------------------------------------------
function initColorInput() {
  const input = $('color-input');
  if (!input) return;
  input.addEventListener('input', () => {
    const raw = input.value.trim();
    if (/^#?[0-9a-fA-F]{6}$/.test(raw)) setColor(raw, 'color_text_input');
  });
  input.addEventListener('change', () => {
    const normalized = normalizeHexColor(input.value);
    input.value = normalized || state.color;
  });
}

function initColors() {
  initColorInput();
  const parentSelect = $('parent-color-select');
  if (!parentSelect) return;
  parentSelect.innerHTML = '';
  for (const g of parent_color_groups) {
    const opt = document.createElement('option');
    opt.value = String(g.id);
    opt.textContent = `${g.id}. ${g.name}  #${g.color.toUpperCase()}`;
    parentSelect.appendChild(opt);
  }
  parentSelect.value = String(state.parentColorId ?? 0);
  parentSelect.onchange = () => {
    state.parentColorId = Number(parentSelect.value);
    setColorSelection('parent');
    const parentColor = parent_color_groups.find(g => g.id === state.parentColorId)?.color || parent_color_groups[0]
      .color;
    setColor('#' + parentColor, 'parent_color_dropdown');
    renderChildColors();
  };
  renderChildColors();
  refreshSelectDropdown('parent-color-select');
}

function renderParentColorButtons() {
  const parentSelect = $('parent-color-select');
  if (parentSelect) parentSelect.value = String(state.parentColorId ?? 0);
  refreshSelectDropdown('parent-color-select');
}

function setColorSelection(selection, childColor = null) {
  state.colorSelection = selection;
  state.selectedChildColor = childColor;
}

function syncColorDropdownsToHex(hex) {
  const normalized = normalizeHexColor(hex);
  if (!normalized) return;
  for (const group of parent_color_groups) {
    if (normalizeHexColor(group.color) === normalized) {
      state.parentColorId = group.id;
      setColorSelection('parent');
      renderParentColorButtons();
      renderChildColors();
      return;
    }
  }
  for (const group of parent_color_groups) {
    for (const [, color] of(child_color_groups[group.id] || [])) {
      const childHex = normalizeHexColor(color);
      if (childHex === normalized) {
        state.parentColorId = group.id;
        setColorSelection('child', childHex);
        renderParentColorButtons();
        renderChildColors();
        return;
      }
    }
  }
  setColorSelection('custom');
  renderParentColorButtons();
  renderChildColors();
}

function renderChildColors() {
  const childSelect = $('child-color-select');
  if (!childSelect) return;
  childSelect.innerHTML = '';
  const parent = parent_color_groups.find(g => g.id === state.parentColorId) || parent_color_groups[0];
  const useParent = document.createElement('option');
  useParent.value = '__parent__';
  useParent.textContent = `使用父颜色：${parent.name}  #${parent.color.toUpperCase()}`;
  childSelect.appendChild(useParent);
  const rows = child_color_groups[state.parentColorId] || [];
  for (const [name, color] of rows) {
    const opt = document.createElement('option');
    opt.value = ('#' + color).toLowerCase();
    opt.textContent = `${name}  #${color.toUpperCase()}`;
    childSelect.appendChild(opt);
  }
  childSelect.value = (state.colorSelection === 'child' && state.selectedChildColor) ? state.selectedChildColor :
    '__parent__';
  childSelect.onchange = () => {
    const v = childSelect.value;
    if (v === '__parent__') {
      setColorSelection('parent');
      setColor('#' + parent.color, 'child_dropdown_use_parent');
    } else {
      setColorSelection('child', v);
      setColor(v, 'child_color_dropdown');
    }
    renderParentColorButtons();
    refreshAllCustomSelects();
  };
  refreshSelectDropdown('child-color-select');
}

function renderPresetButtons(containerId, values, labelForValue, onSelect) {
  const box = $(containerId);
  if (!box) return;
  box.innerHTML = '';
  for (const value of values) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = labelForValue(value);
    button.onclick = () => onSelect(value);
    box.appendChild(button);
  }
}

function initBrightness() {
  setClickHandlers([
    ['brightness-minus', () => setBrightness(state.brightness - 8, 'B4/WebUI -')],
    ['brightness-plus', () => setBrightness(state.brightness + 8, 'B5/WebUI +')],
    ['brightness-reset-default', resetBrightnessDefault]
  ]);
  $('brightness-range').oninput = e => setBrightness(e.target.value, 'slider');
  $('brightness-input').onchange = e => setBrightness(e.target.value, 'raw_input');
  renderPresetButtons(
    'brightness-presets',
    [10, 25, 50, 80, 128, 160, 200],
    value => String(value),
    value => setBrightness(value, 'preset')
  );
}

function resetBrightnessDefault() {
  const value = Number.isFinite(Number(state.defaultBrightness)) ? state.defaultBrightness : DEFAULT_LED_BRIGHTNESS;
  setBrightness(value, 'default_brightness_reset');
}

function initBasicControls() {
  setClickHandlers([
    ['face-prev', prevFace],
    ['face-next', nextFace],
    ['mode-toggle', () => toggleMode('WebUI B3')],
    ['interval-down', () => adjustInterval(-AUTO_INTERVAL_BUTTON_STEP_MS)],
    ['interval-up', () => adjustInterval(AUTO_INTERVAL_BUTTON_STEP_MS)]
  ]);
  $('auto-interval-range').oninput = e => setAutoIntervalSeconds(e.target.value, 'auto_interval_slider');
  $('auto-interval').onchange = e => setAutoIntervalSeconds(e.target.value, 'auto_interval_input');
  renderPresetButtons(
    'auto-interval-presets',
    AUTO_INTERVAL_PRESETS_MS,
    ms => `${formatIntervalSeconds(ms)} 秒`,
    ms => setAutoIntervalMs(ms, 'auto_interval_preset')
  );
  syncAutoIntervalUi();

}

function isAutoModeValue(v) {
  return v === '自动' || v === 'auto' || v === 'A';
}

function modePayloadValue() {
  return isAutoModeValue(state.mode) ? 'auto' : 'manual';
}

function updateModeToggleUi() {
  const btn = $('mode-toggle');
  if (!btn) return;
  const isAuto = isAutoModeValue(state.mode);
  btn.classList.toggle('active', isAuto);
  btn.setAttribute('aria-pressed', isAuto ? 'true' : 'false');
  btn.textContent = isAuto ? 'A 自动' : 'M 手动';
}

function toggleModeLocal(source) {
  guardBeforeOutput('am_mode_toggle', 'face');
  state.mode = isAutoModeValue(state.mode) ? 'manual' : 'auto';
  renderState();
  log(`A/M 模式切换为 ${state.mode} (${source})`);
  sendAuxCommand('set_mode', {
    mode: modePayloadValue(),
    label: state.mode
  }, source);
}

function toggleMode(source) {
  sendButtonCommand('B3', source, () => toggleModeLocal(source));
}

function formatIntervalSeconds(ms) {
  return (ms / 1000).toFixed(ms % 1000 ? 1 : 0);
}

function normalizeAutoIntervalMs(ms) {
  return Math.round(clamp(ms, AUTO_INTERVAL_MIN_MS, AUTO_INTERVAL_MAX_MS) / 100) * 100;
}

function syncAutoIntervalUi() {
  const ms = normalizeAutoIntervalMs(state.autoInterval);
  const seconds = formatIntervalSeconds(ms);
  if ($('auto-interval-range')) $('auto-interval-range').value = seconds;
  if ($('auto-interval')) $('auto-interval').value = seconds;
}

function setAutoIntervalMs(ms, source = 'auto_interval_change') {
  state.autoInterval = normalizeAutoIntervalMs(ms);
  syncAutoIntervalUi();
  renderState();
  log(`自动切换间隔设置为 ${formatIntervalSeconds(state.autoInterval)} 秒 (${state.autoInterval} ms)`);
  sendAuxCommand('set_auto_interval', {
    ms: state.autoInterval
  }, source);
}

function setAutoIntervalSeconds(seconds, source = 'auto_interval_input') {
  setAutoIntervalMs(Number(seconds) * 1000, source);
}

function adjustInterval(delta) {
  setAutoIntervalMs(state.autoInterval + delta, 'auto_interval_change');
}

function nextFaceLocal() {
  const library = getAllFaces();
  if (!library.length) return;
  state.faceIndex = (state.faceIndex + 1) % library.length;
  applySavedFace(state.faceIndex, 'B1/WebUI next');
}

function prevFaceLocal() {
  const library = getAllFaces();
  if (!library.length) return;
  state.faceIndex = (state.faceIndex - 1 + library.length) % library.length;
  applySavedFace(state.faceIndex, 'B2/WebUI prev');
}

function nextFace() {
  sendButtonCommand('B1', 'B1/WebUI next', nextFaceLocal);
}

function prevFace() {
  sendButtonCommand('B2', 'B2/WebUI prev', prevFaceLocal);
}

function applySavedFace(i, reason = 'saved_face_apply') {
  const library = getAllFaces();
  const face = library[i];
  if (!face) return;
  state.faceIndex = i;
  setCurrentFrame(m370ToFrame(face.m370), reason, 'idle');
  renderSavedFaces();
  log(`应用表情 #${i+1}: ${face.name} / ${faceTypeLabel(face.type)}`);
}

function initCustom() {
  $('custom-clear').onclick = () => {
    editFrame = blankFrame();
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive('custom_live_clear');
    log('自定义画板清空');
  };
  $('custom-fill').onclick = () => {
    editFrame = blankFrame().map(() => true);
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive('custom_live_fill');
    log('自定义画板全亮');
  };
  $('custom-invert').onclick = () => {
    editFrame = editFrame.map(v => !v);
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive('custom_live_invert');
    log('自定义画板反转');
  };
  $('custom-send').onclick = () => sendCustomFrame('custom_face_send', true);
  $('custom-live-toggle').onclick = () => toggleLiveSend('实时发送');
  $('custom-copy').onclick = () => {
    copyText(frameToM370(editFrame));
    log('复制自定义 M370');
  };
  $('custom-import').onclick = () => {
    try {
      editFrame = m370ToFrame($('custom-m370').value);
      renderMatrices();
      updateM370Views();
      log('导入自定义 M370 成功');
    } catch (e) {
      alert(e.message);
    }
  };
  $('custom-save').onclick = () => saveFace($('custom-name').value || 'custom_face', editFrame, 'custom');
  updateLiveToggles();
  initFaceManagerControls();
}

function toggleLiveSend(label = '实时发送') {
  liveSendEnabled = !liveSendEnabled;
  updateLiveToggles();
  log(`${label} ${liveSendEnabled?'开启':'关闭'}`);
}

function updateLiveToggles() {
  ['custom-live-toggle', 'parts-live-toggle'].forEach(id => {
    const btn = $(id);
    if (!btn) return;
    btn.classList.toggle('active', liveSendEnabled);
    btn.setAttribute('aria-pressed', liveSendEnabled ? 'true' : 'false');
    btn.textContent = '实时';
  });
}

function sendCustomFrame(reason = 'custom_face_send', writeLog = true) {
  updateM370Views();
  setCurrentFrame(editFrame, reason, 'idle');
  if (writeLog) log('自定义 M370 已发送到固件接口');
}

function sendCustomFrameIfLive(reason = 'custom_live_send') {
  if (liveSendEnabled) sendCustomFrame(reason, false);
}

function editCell(idx, value, tool) {
  editFrame[idx] = !!value;
  renderMatrices();
  updateM370Views();
  sendCustomFrameIfLive('custom_live_send');
}

function preferredStartupDefaultId(faces) {
  const list = Array.isArray(faces) ? faces : [];
  return list.find(f => f.id === DEFAULT_STARTUP_FACE_ID)?.id || list.find(f => f.is_startup_default)?.id || list.find(
    f => f.type === 'default')?.id || list[0]?.id || null;
}

function startupDefaultFaceIndex() {
  const library = getAllFaces();
  if (!library.length) return -1;
  const startupId = faceLibraryDocument?.startupDefaultId || DEFAULT_STARTUP_FACE_ID;
  let idx = startupId ? library.findIndex(f => f.id === startupId) : -1;
  if (idx < 0) idx = library.findIndex(f => f.is_startup_default);
  if (idx < 0) idx = library.findIndex(f => f.type === 'default');
  return idx >= 0 ? idx : 0;
}

function applyStartupDefaultFaceLocal(reason = 'text_scroll_stop_default_saved_face') {
  const index = startupDefaultFaceIndex();
  if (index < 0) return false;
  const face = getAllFaces()[index];
  if (!face) return false;
  state.faceIndex = index;
  currentFrame = m370ToFrame(face.m370);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  renderMatrices();
  updateM370Views();
  renderSavedFaces();
  return true;
}

function applyKnownFaceIndexLocal(reason = 'firmware_face_index_preview') {
  const library = getAllFaces();
  if (!library.length) return false;
  const index = clamp(Number(state.faceIndex) || 0, 0, library.length - 1);
  const face = library[index];
  if (!face || typeof face.m370 !== 'string') return false;
  state.faceIndex = index;
  currentFrame = m370ToFrame(face.m370);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  renderMatrices();
  updateM370Views();
  renderSavedFaces();
  return true;
}
// -----------------------------------------------------------------------------
// 已保存表情库持久化
// -----------------------------------------------------------------------------
async function loadFaceLibrary() {
  const doc = await loadUnifiedFacesDocument();
  faceLibraryDocument = normalizeFaceDocument(doc, 'custom');
  splitFaceLibraryDocument(faceLibraryDocument);
  const library = getAllFaces();
  if (library.length) {
    const startupId = faceLibraryDocument?.startupDefaultId;
    const startupIndex = startupId ? library.findIndex(f => f.id === startupId) : -1;
    state.faceIndex = startupIndex >= 0 ? startupIndex : clamp(state.faceIndex, 0, library.length - 1);
  } else {
    state.faceIndex = 0;
  }
  renderSavedFaces();
  renderState();
  return library;
}
async function fetchJsonDocument(path) {
  const res = await fetch(path, {
    cache: 'no-store'
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText || ''}`.trim());
  return res.json();
}
async function loadUnifiedFacesDocument() {
  const empty = {
    format: FACE_SCHEMA_FORMAT,
    version: 2,
    category: 'unified_saved_faces',
    matrix: {
      leds: TOTAL_LEDS,
      m370HexChars: 93
    },
    startupDefaultId: DEFAULT_STARTUP_FACE_ID,
    updatedAt: null,
    faces: []
  };
  try {
    const apiDoc = await apiGet(API_ENDPOINTS.savedFaces);
    setFirmwareStatus({
      savedFacesSync: 'loaded from /api/saved_faces'
    });
    return apiDoc;
  } catch (apiErr) {
    const candidates = location.protocol === 'file:' ? [FACE_LIBRARY_FILENAME] : [FACE_LIBRARY_RESOURCE,
      FACE_LIBRARY_FILENAME
    ];
    for (const path of candidates) {
      try {
        const doc = await fetchJsonDocument(path);
        setFirmwareStatus({
          savedFacesSync: `loaded from ${path}`
        });
        return doc;
      } catch (fileErr) {}
    }
    setFirmwareStatus({
      savedFacesSync: location.protocol === 'file:' ? 'file:// cannot auto-read JSON; import saved_faces.json' :
        'saved_faces.json not found'
    });
    log(location.protocol === 'file:' ? '浏览器 file:// 通常不能自动读取旁边的 saved_faces.json；请点击“导入 saved_faces.json”。' :
      'saved_faces.json 未读取到，使用空表情库。');
    return empty;
  }
}

function splitFaceLibraryDocument(doc) {
  const faces = Array.isArray(doc?.faces) ? doc.faces : [];
  defaultFaces = faces.filter(f => f.type === 'default').map((f, i) => ({
    ...f,
    type: 'default',
    editable: true,
    deletable: false,
    locked: true,
    is_startup_default: !!f.is_startup_default || f.id === DEFAULT_STARTUP_FACE_ID,
    sourceFile: FACE_LIBRARY_FILENAME,
    order: Number.isFinite(Number(f.order)) ? Number(f.order) : i + 1
  }));
  userFaces = faces.filter(f => f.type !== 'default').map((f, i) => ({
    ...f,
    type: normalizeFaceType(f.type),
    editable: true,
    deletable: true,
    locked: false,
    is_startup_default: false,
    sourceFile: FACE_LIBRARY_FILENAME,
    order: Number.isFinite(Number(f.order)) ? Number(f.order) : 10001 + i
  }));
}

function faceOrderFromIndex(index) {
  return Math.max(1, Number(index) + 1);
}

function normalizeFaceDocument(doc, fallbackType = 'custom') {
  const out = (doc && typeof doc === 'object' && !Array.isArray(doc)) ? {
    ...doc
  } : {
    format: FACE_SCHEMA_FORMAT,
    version: 2,
    faces: Array.isArray(doc) ? doc : []
  };
  out.format = FACE_SCHEMA_FORMAT;
  out.version = Number(out.version || 2);
  out.category = 'unified_saved_faces';
  out.matrix = out.matrix || {
    leds: TOTAL_LEDS,
    m370HexChars: 93
  };
  out.faces = Array.isArray(out.faces) ? out.faces : [];
  out.faces = out.faces.map((f, i) => normalizeFace(f, i, fallbackType)).filter(Boolean);
  out.startupDefaultId = preferredStartupDefaultId(out.faces);
  out.updatedAt = out.updatedAt || null;
  return out;
}

function displayNameFromId(id) {
  return String(id || 'face').replace(/^face_?/, '').replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}

function normalizeFace(f, i = 0, fallbackType = 'custom') {
  if (!f || typeof f !== 'object') return null;
  const m370 = String(f.m370 || '').trim();
  try {
    m370ToFrame(m370)
  } catch (e) {
    return null;
  }
  const type = normalizeFaceType(f.type || f.source || fallbackType);
  const id = String(f.id || `${type}_${i+1}`);
  return {
    id,
    name: String(f.name || displayNameFromId(id)).slice(0, 64),
    type,
    m370: frameToM370(m370ToFrame(m370)),
    order: Number.isFinite(Number(f.order)) ? Number(f.order) : faceOrderFromIndex(i),
    editable: true,
    deletable: type !== 'default',
    locked: type === 'default' ? true : !!f.locked,
    is_startup_default: !!f.is_startup_default || id === DEFAULT_STARTUP_FACE_ID,
    sourceFile: FACE_LIBRARY_FILENAME,
    savedAt: f.savedAt || f.createdAt || null,
    updatedAt: f.updatedAt || null,
    call: f.call || null
  };
}

function normalizeFaceType(v) {
  const s = String(v || 'custom').toLowerCase();
  if (s.includes('default')) return 'default';
  if (s.includes('part')) return 'parts';
  if (s.includes('custom')) return 'custom';
  return 'custom';
}

function faceTypeLabel(type) {
  return type === 'default' ? '默认表情' : type === 'parts' ? '部件表情' : type === 'custom' ? '自定义表情' : '保存表情';
}

function getAllFaces() {
  return [...defaultFaces, ...userFaces].map((f, idx) => ({
    ...f,
    _stableIndex: idx
  })).sort((a, b) => (Number(a.order) || 0) - (Number(b.order) || 0) || String(a.id).localeCompare(String(b.id)));
}

function reassignOrderFromLibrary(library) {
  const defaultById = new Map(defaultFaces.map(f => [f.id, f]));
  const userById = new Map(userFaces.map(f => [f.id, f]));
  library.forEach((f, i) => {
    const target = f.type === 'default' ? defaultById.get(f.id) : userById.get(f.id);
    if (target) target.order = faceOrderFromIndex(i);
  });
  defaultFaces = [...defaultFaces].sort((a, b) => a.order - b.order);
  userFaces = [...userFaces].sort((a, b) => a.order - b.order);
}

function buildUnifiedFaceDocument() {
  const faces = getAllFaces().map((f, i) => {
    const normalized = normalizeFace({
      ...f,
      order: faceOrderFromIndex(i)
    }, i, f.type || 'custom');
    if (!normalized) return null;
    normalized.editable = true;
    normalized.deletable = normalized.type !== 'default';
    normalized.sourceFile = FACE_LIBRARY_FILENAME;
    return normalized;
  }).filter(Boolean);
  return {
    format: FACE_SCHEMA_FORMAT,
    version: 2,
    category: 'unified_saved_faces',
    matrix: {
      leds: TOTAL_LEDS,
      m370HexChars: 93
    },
    startupDefaultId: preferredStartupDefaultId(faces),
    updatedAt: new Date().toISOString(),
    faces
  };
}
async function saveFaceLibraryToLocalFile() {
  if (!faceLibraryFileHandle) throw new Error('尚未打开本地 saved_faces.json。请先点击“打开本地 saved_faces.json”，或使用下载/导入流程。');
  if (!window.showOpenFilePicker && !faceLibraryFileHandle.createWritable) throw new Error(
    '当前浏览器不支持 File System Access API。请使用“下载 saved_faces.json”。');
  const writable = await faceLibraryFileHandle.createWritable();
  await writable.write(JSON.stringify(faceLibraryDocument || buildUnifiedFaceDocument(), null, 2));
  await writable.close();
  setFirmwareStatus({
    savedFacesSync: 'saved to opened local saved_faces.json'
  });
  log('已保存到已打开的本地 saved_faces.json');
}
async function openLocalFaceLibraryFile() {
  if (!window.showOpenFilePicker) {
    alert('当前浏览器不支持直接打开并写回本地文件。请使用“导入 saved_faces.json”与“下载 saved_faces.json”。');
    return;
  }
  const [handle] = await window.showOpenFilePicker({
    multiple: false,
    types: [{
      description: 'Rina saved_faces.json',
      accept: {
        'application/json': ['.json']
      }
    }]
  });
  faceLibraryFileHandle = handle;
  const file = await handle.getFile();
  await importFacesJsonText(await file.text(), 'open_local_saved_faces_json');
  setFirmwareStatus({
    savedFacesSync: `opened local ${file.name}`
  });
  log(`已打开本地 ${file.name}；之后排序/重命名会优先写回这个文件。`);
}
async function persistFaceDocuments(reason = 'save_faces') {
  faceLibraryDocument = buildUnifiedFaceDocument();
  splitFaceLibraryDocument(faceLibraryDocument);
  if (faceLibraryFileHandle) {
    try {
      await saveFaceLibraryToLocalFile();
    } catch (localErr) {
      setFirmwareStatus({
        savedFacesSync: 'local save failed; trying firmware API'
      });
      log(`本地 saved_faces.json 写入失败：${localErr.message}`);
    }
  }
  setFirmwareStatus({
    savedFacesSync: 'saving unified saved_faces.json'
  });
  return apiPost(API_ENDPOINTS.savedFaces, {
      path: FACE_LIBRARY_RESOURCE,
      document: faceLibraryDocument,
      reason
    })
    .then(() => setFirmwareStatus({
      savedFacesSync: 'saved to firmware saved_faces.json'
    }))
    .catch(() => setFirmwareStatus({
      savedFacesSync: faceLibraryFileHandle ? 'saved locally; firmware offline' :
        'save failed/offline; use JSON download/import'
    }))
    .finally(() => {
      log(`saved_faces.json 已同步：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
      renderState();
    });
}

function downloadJsonFile(filename, doc) {
  const blob = new Blob([JSON.stringify(doc, null, 2)], {
    type: 'application/json'
  });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

function downloadFacesJson() {
  downloadJsonFile('saved_faces.json', buildUnifiedFaceDocument());
  log('已导出统一 saved_faces.json');
}
async function importFacesJsonText(text, reason = 'import_saved_faces_json') {
  faceLibraryDocument = normalizeFaceDocument(JSON.parse(text), 'custom');
  splitFaceLibraryDocument(faceLibraryDocument);
  state.faceIndex = 0;
  renderSavedFaces();
  renderState();
  await persistFaceDocuments(reason);
  log(`已导入统一 saved_faces.json：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
}
async function importFacesJsonFile(file) {
  await importFacesJsonText(await file.text(), 'import_saved_faces_json');
}

function initFaceManagerControls() {
  bindControls('.faces-json-load', 'click', () => loadFaceLibrary());
  bindControls('.faces-json-open-local', 'click', () => openLocalFaceLibraryFile().catch(err => alert(err.message)));
  bindControls('.faces-json-save-local', 'click', () => {
    faceLibraryDocument = buildUnifiedFaceDocument();
    saveFaceLibraryToLocalFile().catch(err => alert(err.message));
  });
  bindControls('.faces-json-download-all', 'click', downloadFacesJson);
  bindControls('.faces-json-import-btn', 'click', e => e.currentTarget.parentElement.querySelector(
    '.faces-json-import-file')?.click());
  bindControls('.faces-json-import-file', 'change', e => {
    const file = e.currentTarget.files?.[0];
    if (file) importFacesJsonFile(file).catch(err => alert(err.message));
    e.currentTarget.value = '';
  });
}

function saveFace(name, frame, type) {
  const faceType = normalizeFaceType(type);
  if (faceType === 'default') throw new Error('不能通过保存按钮新建默认表情；默认表情只能来自 saved_faces.json 的 type:"default" 项。');
  const clean = String(name || 'face').trim().slice(0, 64) || 'face';
  const nextOrder = Math.max(0, ...getAllFaces().map(f => Number(f.order) || 0)) + 1;
  userFaces.push({
    id: `${faceType}_${Date.now()}`,
    name: clean,
    type: faceType,
    m370: frameToM370(frame),
    order: nextOrder,
    editable: true,
    deletable: true,
    sourceFile: FACE_LIBRARY_FILENAME,
    savedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    call: faceType === 'parts' ? {
      ...selectedCall
    } : null
  });
  state.faceIndex = getAllFaces().findIndex(f => f.id === userFaces[userFaces.length - 1].id);
  renderSavedFaces();
  renderState();
  log(`保存${faceTypeLabel(faceType)}: ${clean}`);
  persistFaceDocuments('save_user_face');
}

function renderSavedFaces() {
  const lists = document.querySelectorAll('.face-library-list');
  if (!lists.length) return;
  const library = getAllFaces();
  lists.forEach(box => {
    box.innerHTML = '';
    if (!library.length) return;
    library.forEach((f, i) => {
      const row = createFaceRow(f, i, library.length);
      row.classList.toggle('active', i === state.faceIndex);
      box.appendChild(row);
    });
  });
  renderState();
}

function clearFaceDragOver(scope = document) {
  scope.querySelectorAll('.saved-row.drag-over').forEach(x => x.classList.remove('drag-over'));
}

function faceRowIndexFromPoint(clientX, clientY, list) {
  const target = document.elementFromPoint(clientX, clientY);
  const row = target && target.closest && target.closest('.saved-row');
  if (!row || row.closest('.face-library-list') !== list) return null;
  const index = Number(row.dataset.index);
  return Number.isInteger(index) ? index : null;
}

function autoScrollFaceList(clientY) {
  const margin = 76;
  const step = 18;
  if (clientY < margin) window.scrollBy({
    top: -step,
    behavior: 'auto'
  });
  else if (clientY > window.innerHeight - margin) window.scrollBy({
    top: step,
    behavior: 'auto'
  });
}

function attachFaceReorderHandle(handle, row, index) {
  handle.draggable = false;
  handle.addEventListener('pointerdown', ev => {
    if (ev.button !== undefined && ev.button !== 0) return;
    const list = row.closest('.face-library-list');
    if (!list) return;
    ev.preventDefault();
    pointerFaceDrag = {
      from: index,
      to: index,
      list,
      row,
      pointerId: ev.pointerId
    };
    row.classList.add('dragging', 'drag-over');
    handle.setPointerCapture?.(ev.pointerId);
  });
  handle.addEventListener('pointermove', ev => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    autoScrollFaceList(ev.clientY);
    const to = faceRowIndexFromPoint(ev.clientX, ev.clientY, pointerFaceDrag.list);
    if (to === null) return;
    pointerFaceDrag.to = to;
    clearFaceDragOver(pointerFaceDrag.list);
    const targetRow = pointerFaceDrag.list.querySelector(`.saved-row[data-index="${to}"]`);
    if (targetRow) targetRow.classList.add('drag-over');
  });
  const finish = ev => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    const {
      from,
      to,
      list,
      row: dragRow
    } = pointerFaceDrag;
    handle.releasePointerCapture?.(ev.pointerId);
    clearFaceDragOver(list);
    dragRow.classList.remove('dragging');
    pointerFaceDrag = null;
    if (from !== to) reorderFace(from, to);
  };
  handle.addEventListener('pointerup', finish);
  handle.addEventListener('pointercancel', finish);
}

function createFaceRow(f, i, total) {
  const row = document.createElement('div');
  row.className = 'saved-row';
  row.dataset.index = i;
  row.dataset.faceId = f.id;
  const index = document.createElement('div');
  index.className = 'saved-index';
  index.textContent = String(i + 1);
  const item = document.createElement('div');
  item.className = 'list-item saved-face-card';

  // 拖拽手柄
  const handle = document.createElement('button');
  handle.className = 'drag-handle';
  handle.type = 'button';
  handle.draggable = false;
  handle.title = '拖拽排序';
  handle.setAttribute('aria-label', '拖拽排序');
  attachFaceReorderHandle(handle, row, i);

  // 中间：命名框 + 元数据徽章
  const body = document.createElement('div');
  body.className = 'saved-face-body';
  const nameInput = document.createElement('input');
  nameInput.className = 'saved-name-input';
  nameInput.value = f.name || `face_${i+1}`;
  nameInput.maxLength = 64;
  nameInput.title = f.type === 'default' ? '默认表情可重命名、可排序，但不可删除；回车或失焦保存' : '直接编辑名称后回车或失焦保存';
  const commitName = () => {
    const next = nameInput.value.trim().slice(0, 64) || f.name || `face_${i+1}`;
    const list = f.type === 'default' ? defaultFaces : userFaces;
    const target = list.find(x => x.id === f.id);
    if (target && target.name !== next) {
      target.name = next;
      target.updatedAt = new Date().toISOString();
      persistFaceDocuments(f.type === 'default' ? 'rename_default_face' : 'rename_user_face');
      renderState();
      log(`重命名${faceTypeLabel(target.type)} #${i+1}: ${next}`);
    }
    nameInput.value = next;
  };
  nameInput.addEventListener('change', commitName);
  nameInput.addEventListener('blur', commitName);
  nameInput.addEventListener('keydown', e => {
    if (e.key === 'Enter') nameInput.blur();
  });
  const meta = document.createElement('div');
  meta.className = 'small saved-meta';
  const badgeClass = f.type === 'default' ? 'default' : f.type === 'parts' ? 'parts' : 'custom';
  meta.innerHTML =
    `<span class="face-source-badge ${badgeClass}">${faceTypeLabel(f.type)}</span> · ${onCount(m370ToFrame(f.m370))} LED`;
  body.appendChild(nameInput);
  body.appendChild(meta);

  // 右侧操作栏：应用 / 上移 / 下移 / 重命名 / 删除
  const actions = document.createElement('div');
  actions.className = 'face-action-bar';

  const mkBtn = (label, title, cls, fn, disabled) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.title = title;
    b.setAttribute('aria-label', title);
    b.className = 'icon-btn' + (cls ? ' ' + cls : '');
    b.textContent = label;
    b.disabled = !!disabled;
    b.onclick = fn;
    return b;
  };

  actions.appendChild(mkBtn('↑', '上移', '', () => moveFace(i, -1), i <= 0));
  actions.appendChild(mkBtn('↓', '下移', '', () => moveFace(i, 1), i >= total - 1));
  actions.appendChild(mkBtn('✏️', '重命名', '', () => {
    nameInput.focus();
    nameInput.select();
  }));
  if (f.type !== 'default') {
    actions.appendChild(mkBtn('🗑️', '删除', 'btn-delete', () => deleteFace(i)));
  } else {
    const nd = mkBtn('🗑️', '默认表情不可删除', 'btn-delete', () => {}, true);
    nd.style.opacity = '.35';
    actions.appendChild(nd);
  }
  actions.appendChild(mkBtn('💡', '上传到固件（应用表情）', 'btn-apply', () => applySavedFace(i, 'face_library_list')));

  item.appendChild(handle);
  item.appendChild(body);
  item.appendChild(actions);
  row.appendChild(index);
  row.appendChild(item);
  return row;
}

function moveFace(i, d) {
  reorderFace(i, i + d);
}

function reorderFace(from, to) {
  const library = getAllFaces();
  from = Number(from);
  to = Number(to);
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < 0 || from >= library.length || to >= library
    .length || from === to) return;
  const [moved] = library.splice(from, 1);
  library.splice(to, 0, moved);
  reassignOrderFromLibrary(library);
  state.faceIndex = to;
  persistFaceDocuments('reorder_faces');
  renderSavedFaces();
  log(`表情排序 ${from+1} -> ${to+1}`);
}

function deleteFace(i) {
  const library = getAllFaces();
  const face = library[i];
  if (!face) return;
  if (face.type === 'default') {
    alert('默认表情不可删除，但可以排序和重命名。');
    return;
  }
  if (!confirm(`删除该${faceTypeLabel(face.type)}？`)) return;
  userFaces = userFaces.filter(f => f.id !== face.id);
  state.faceIndex = getAllFaces().length ? clamp(state.faceIndex, 0, getAllFaces().length - 1) : 0;
  persistFaceDocuments('delete_user_face');
  renderSavedFaces();
  log(`删除${faceTypeLabel(face.type)} #${i+1}`);
}

// -----------------------------------------------------------------------------
// 表情部件组合器
// -----------------------------------------------------------------------------
function initParts() {
  const groups = $('part-groups');
  groups.innerHTML = '';
  const labels = {
    leye: 'leye 左眼',
    reye: 'reye 右眼',
    mouth: 'mouth 嘴巴',
    cheek: 'cheek 脸颊'
  };
  for (const key of ['leye', 'reye', 'mouth', 'cheek']) {
    const card = document.createElement('div');
    card.className = 'card stack';
    card.innerHTML = `<h3>${labels[key]}</h3><div class="part-list" id="parts-list-${key}"></div>`;
    groups.appendChild(card);
    const list = card.querySelector('.part-list');
    EXPRESSION_PARTS.call.ids[key].forEach((id, displayIndex) => {
      const resolved = resolvePartId(key, id);
      const part = EXPRESSION_PARTS.parts[resolved] || EXPRESSION_PARTS.parts['0'];
      const assetName = part.name || `asset_${resolved}`;
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'part-card' + (key === 'cheek' ? ' cheek-card' : '');
      btn.dataset.key = key;
      btn.dataset.id = id;
      btn.title = `显示编号 ${displayIndex} / 调用 ID ${id} / asset ${assetName}`;
      const metaHtml = `<div class="part-meta"><b class="part-display-id">${displayIndex}</b></div>`;
      btn.innerHTML = `${miniPreviewHtml(part)}${metaHtml}`;
      btn.onclick = () => selectPart(key, String(id));
      list.appendChild(btn);
    });
  }
  $('parts-apply').onclick = () => sendPartsFrame();
  $('parts-live-toggle').onclick = () => toggleLiveSend('实时发送');
  $('parts-random').onclick = () => {
    randomParts();
    sendPartsFrame('parts_random_send');
  };
  $('parts-symmetry-toggle').onclick = () => {
    partsSymmetry = !partsSymmetry;
    if (partsSymmetry) syncSymmetricEyesFrom('leye');
    composePartsFrame();
    renderPartButtons();
    sendPartsFrameIfLive('parts_live_symmetry');
    log(`左右眼对称 ${partsSymmetry?'开启':'关闭'}`);
  };
  $('parts-reset').onclick = () => {
    selectedCall = {
      leye: '101',
      reye: '201',
      mouth: '301',
      cheek: '400'
    };
    if (partsSymmetry) syncSymmetricEyesFrom('leye');
    composePartsFrame();
    renderPartButtons();
    sendPartsFrameIfLive('parts_live_reset');
    log('表情部件恢复默认');
  };
  const _copyPartsM370 = () => {
    copyText(frameToM370(partsFrame));
    log('复制 M370');
  };
  $('parts-copy-m370').onclick = _copyPartsM370;
  $('parts-save-bottom').onclick = () => saveFace($('parts-name').value ||
    `parts_${selectedCall.leye}_${selectedCall.reye}_${selectedCall.mouth}_${selectedCall.cheek}`, partsFrame, 'parts'
    );
  $('parts-import-m370').onclick = () => {
    try {
      setCurrentFrame(m370ToFrame($('parts-m370-text').value), 'parts_m370_import', 'idle');
      log('部件页 M370 文本已应用到当前输出');
    } catch (e) {
      alert(e.message);
    }
  };
  initFaceManagerControls();
  composePartsFrame();
  renderPartButtons();
  updateLiveToggles();
}

function getPartDisplayIndex(key, id) {
  return EXPRESSION_PARTS.call.ids[key].findIndex(x => String(x) === String(id));
}

function callIdAtDisplayIndex(key, index) {
  const ids = EXPRESSION_PARTS.call.ids[key] || [];
  return String(ids[clamp(index, 0, ids.length - 1)] ?? ids[0] ?? '0');
}

function syncSymmetricEyesFrom(sourceKey) {
  const src = sourceKey === 'reye' ? 'reye' : 'leye';
  const idx = getPartDisplayIndex(src, selectedCall[src]);
  const safeIdx = idx >= 0 ? idx : 0;
  selectedCall.leye = callIdAtDisplayIndex('leye', safeIdx);
  selectedCall.reye = callIdAtDisplayIndex('reye', safeIdx);
}

function selectPart(key, id) {
  selectedCall[key] = String(id);
  if (partsSymmetry && (key === 'leye' || key === 'reye')) syncSymmetricEyesFrom(key);
  composePartsFrame();
  renderPartButtons();
  sendPartsFrameIfLive('parts_live_select');
}

function miniPreviewHtml(part) {
  const rows = previewRows(part);
  let s = '<div class="part-mini">';
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      s += `<span class="pix${rows[y] && rows[y][x]==='#'?' on':''}"></span>`;
    }
  }
  return s + '</div>';
}

function previewRows(part) {
  const size = part.size || [8, 8];
  const w = clamp(size[0] || 8, 1, 8),
    h = clamp(size[1] || 8, 1, 8);
  const out = Array.from({
    length: 8
  }, () => '.'.repeat(8).split(''));
  const ox = Math.floor((8 - w) / 2),
    oy = Math.floor((8 - h) / 2);
  if (part.preview && part.preview.length >= h && part.preview.every(r => String(r).length >= w)) {
    for (let y = 0; y < h; y++) {
      const row = String(part.preview[y] || '').padEnd(w, '.').slice(0, w);
      for (let x = 0; x < w; x++)
        if (row[x] === '#') out[oy + y][ox + x] = '#';
    }
    return out.map(r => r.join(''));
  }
  for (let y = 0; y < h; y++) {
    const raw = (part.row_hex || [])[y] || '00';
    const bits = parseInt(raw, 16);
    for (let x = 0; x < w; x++)
      if (bits & (1 << (7 - x))) out[oy + y][ox + x] = '#';
  }
  return out.map(r => r.join(''));
}

function renderPartButtons() {
  for (const key of ['leye', 'reye', 'mouth', 'cheek']) {
    document.querySelectorAll(`[data-key="${key}"]`).forEach(b => b.classList.toggle('active', b.dataset.id === String(
      selectedCall[key])));
  }
  const sym = $('parts-symmetry-toggle');
  if (sym) {
    sym.classList.toggle('active', !!partsSymmetry);
    sym.setAttribute('aria-pressed', partsSymmetry ? 'true' : 'false');
  }
}

function randomParts() {
  if (partsSymmetry) {
    const maxEyeIndex = Math.min(EXPRESSION_PARTS.call.ids.leye.length, EXPRESSION_PARTS.call.ids.reye.length) - 1;
    const eyeIndex = 1 + Math.floor(Math.random() * Math.max(1, maxEyeIndex));
    selectedCall.leye = callIdAtDisplayIndex('leye', eyeIndex);
    selectedCall.reye = callIdAtDisplayIndex('reye', eyeIndex);
  } else {
    for (const key of ['leye', 'reye']) {
      let arr = EXPRESSION_PARTS.call.ids[key].filter(id => String(id) !== '0');
      selectedCall[key] = String(arr[Math.floor(Math.random() * arr.length)]);
    }
  }
  for (const key of ['mouth', 'cheek']) {
    let arr = EXPRESSION_PARTS.call.ids[key].slice();
    if (key !== 'cheek') arr = arr.filter(id => String(id) !== '0');
    // cheek=400 表示明确的空脸颊调用，在随机模式中仍然有效。
    selectedCall[key] = String(arr[Math.floor(Math.random() * arr.length)]);
  }
  composePartsFrame();
  renderPartButtons();
  log(partsSymmetry ? '随机选择表情部件（左右眼同编号，嘴巴不选 0，脸颊允许 400）' : '随机选择表情部件（眼睛/嘴巴不选 0，脸颊允许 400）');
}

// -----------------------------------------------------------------------------
// 文字滚动时间线
// -----------------------------------------------------------------------------
function truncateScrollText(text) {
  return Array.from(String(text ?? '')).slice(0, MAX_SCROLL_TEXT_CHARS).join('');
}

function sanitizeScrollTextInput(commit = false) {
  const el = $('scroll-text');
  const raw = el ? String(el.value ?? '') : '';
  const clean = truncateScrollText(raw);
  if (commit && el && raw !== clean) {
    el.value = clean;
    log(`滚动文字超过 ${MAX_SCROLL_TEXT_CHARS} 字，已自动截断。`);
  }
  return clean;
}

function autoResizeScrollTextInput() {
  const el = $('scroll-text');
  if (!el) return;
  el.style.height = 'auto';
  const minHeight = parseFloat(getComputedStyle(el).getPropertyValue('--scroll-text-min-height')) || 42;
  el.style.height = Math.max(minHeight, el.scrollHeight + 2) + 'px';
}

let scrollBitmapFontLazyStarted = false;
// 仅在实际使用文字滚动功能时，才延迟获取较大的 Ark Pixel 文字滚动资源
// （约 593KB 浏览器 woff2 + 约 1.8MB 位图字形表），
// 让约 2.4MB 资源避开启动/启动后瀑布流。底层两个加载器都会缓存
// 各自的承诺对象，因此重复调用（例如每次进入滚动页面）成本很低。
function ensureScrollFontsLoaded() {
  ensureTextScrollBrowserFontReady().then(loaded => {
    if (loaded) autoResizeScrollTextInput();
  });
  if (scrollBitmapFontLazyStarted) return;
  scrollBitmapFontLazyStarted = true;
  ensureArkPixelFontReady()
    .then(() => log('Ark Pixel Font 12px bitmap table loaded'))
    .catch(err => log(`Ark Pixel Font bitmap table load failed: ${err.message}`));
}

function initScroll() {
  applyTextScrollInputFont();
  autoResizeScrollTextInput();
  // 较大的 Ark Pixel 资源不会在这里随启动获取。它们会在
  // 首次进入文字滚动页面时延迟加载（见 switchPage -> ensureScrollFontsLoaded），
  // 而滚动启动路径也会等待 ensureArkPixelFontReady()，因此即使用户直接播放也安全。
  $('scroll-play').onclick = startScroll;
  $('scroll-pause').onclick = togglePauseScroll;
  $('scroll-stop').onclick = stopScroll;
  $('scroll-step').onclick = async () => {
    guardBeforeOutput('text_scroll_manual_step', 'scroll');
    await prepareTextScrollTimelineAsync(false);
    advanceScroll(true);
    sendAuxCommand('scroll_step', {}, 'text_scroll_manual_step');
  };
  const textEl = $('scroll-text');
  if (textEl) {
    textEl.maxLength = MAX_SCROLL_TEXT_CHARS;
    textEl.addEventListener('input', () => {
      sanitizeScrollTextInput(true);
      applyTextScrollInputFont();
      autoResizeScrollTextInput();
      markScrollTextDirty();
    });
    textEl.addEventListener('change', () => {
      sanitizeScrollTextInput(true);
      autoResizeScrollTextInput();
      markScrollTextDirty();
    });
    textEl.addEventListener('paste', () => requestAnimationFrame(() => {
      sanitizeScrollTextInput(true);
      autoResizeScrollTextInput();
      markScrollTextDirty();
    }));
  }
  const fpsEl = $('scroll-speed');
  if (fpsEl) {
    fpsEl.addEventListener('keydown', ev => {
      if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
      const allowed = ['Backspace', 'Delete', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End',
        'Tab', 'Enter'
      ];
      if (allowed.includes(ev.key)) return;
      if (!/^\d$/.test(ev.key)) ev.preventDefault();
    });
    fpsEl.addEventListener('beforeinput', ev => {
      if (ev.data && /\D/.test(ev.data)) ev.preventDefault();
    });
    fpsEl.addEventListener('input', () => {
      const fps = sanitizeScrollFpsInput(false);
      if (fpsEl.value !== '') setScrollFps(fps, 'text_scroll_fps_input');
      else updateScrollUi();
    });
    fpsEl.addEventListener('paste', () => requestAnimationFrame(() => {
      const fps = sanitizeScrollFpsInput(false);
      if (fpsEl.value !== '') setScrollFps(fps, 'text_scroll_fps_paste');
      else updateScrollUi();
    }));
    fpsEl.addEventListener('change', () => setScrollFps(sanitizeScrollFpsInput(true), 'text_scroll_fps_change'));
    fpsEl.addEventListener('blur', () => setScrollFps(sanitizeScrollFpsInput(true), 'text_scroll_fps_blur'));
  }
  window.addEventListener('resize', () => requestAnimationFrame(autoResizeScrollTextInput));
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(autoResizeScrollTextInput).catch(() => {});
}

function parseScrollFpsValue(raw, fallback = DEFAULT_SCROLL_FPS) {
  const digits = String(raw ?? '').replace(/\D/g, '');
  if (!digits) return clamp(fallback, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  return clamp(parseInt(digits, 10), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
}

function sanitizeScrollFpsInput(commit = false) {
  const el = $('scroll-speed');
  if (!el) return clamp(DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  const raw = String(el.value ?? '');
  const digits = raw.replace(/\D/g, '');
  if (!digits) {
    const fallback = clamp(DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
    if (commit) el.value = String(fallback);
    return fallback;
  }
  const clean = clamp(parseInt(digits, 10), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  const next = String(clean);
  if (raw !== next) el.value = next;
  return clean;
}

function getScrollFps() {
  return parseScrollFpsValue($('scroll-speed')?.value, DEFAULT_SCROLL_FPS);
}

function getScrollFrameIntervalMs() {
  return Math.max(1, Math.round(1000 / getScrollFps()));
}

function restartScrollPreviewTimer() {
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  if (scroll.active && !scroll.paused) {
    scroll.timer = setInterval(() => advanceScroll(false), getScrollFrameIntervalMs());
  }
}

function setScrollFps(fps, source = 'text_scroll_fps_change') {
  const clean = clamp(fps, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  if ($('scroll-speed')) $('scroll-speed').value = clean;
  state.refreshPolicy = `text_scroll_${clean}fps_interval_${getScrollFrameIntervalMs()}ms`;
  restartScrollPreviewTimer();
  if (scroll.active || scroll.firmwareBacked || scroll.paused) {
    sendAuxCommand('set_scroll_interval', {
      fps: clean,
      intervalMs: getScrollFrameIntervalMs()
    }, source);
  }
  updateScrollUi();
  renderState();
}

function markScrollTextDirty() {
  scroll.dirty = true;
  scroll.signature = '';
  if ((scroll.active || scroll.firmwareBacked || state.textScrollActive) && !scroll.dirtyNoticeLogged) {
    scroll.dirtyNoticeLogged = true;
    log('文字已修改；当前滚动继续使用已上传缓存，下一次点击发送才重新生成并上传。');
  }
  updateScrollUi();
}

function setScrollUploadProgress(progress, label) {
  scroll.uploadProgress = clamp(progress, 0, 1);
  scroll.uploadLabel = label || '';
  updateScrollUi();
}

function completeScrollUploadProgress(label = '发送完成，滚动帧仅在固件 RAM 中运行') {
  scroll.uploadProgress = 1;
  scroll.uploadLabel = label;
  updateScrollUi();
  setTimeout(() => {
    if (!scroll.uploading && scroll.uploadProgress >= 1) {
      scroll.uploadProgress = 0;
      scroll.uploadLabel = '';
      updateScrollUi();
    }
  }, 1400);
}

function resetScrollUploadProgress() {
  scroll.uploadProgress = 0;
  scroll.uploadLabel = '';
  updateScrollUi();
}

function nextUiFrame() {
  return new Promise(resolve => requestAnimationFrame(resolve));
}

function sleepMs(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function resetScrollPreviewToFirstFrame(reason = 'text_scroll_start_reset_preview', playback = 'scroll') {
  scroll.frameIndex = 0;
  scroll.offset = 0;
  scrollFrame = cloneFrame(scroll.frames[0] || blankFrame());
  setScrollPreviewFrame(scrollFrame, reason, playback);
  updateScrollUi();
}

function resetScrollControlsAfterButton(reason = 'gpio_button', options = {}) {
  const preserveCurrentFrame = !!options.preserveCurrentFrame;
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.active = false;
  scroll.paused = false;
  scroll.firmwareBacked = false;
  scroll.uploading = false;
  scroll.offset = 0;
  scroll.frameIndex = 0;
  state.textScrollActive = false;
  if (isScrollPlaybackValue(state.playback)) state.playback = 'idle';
  state.lastRefreshReason = `${reason}_reset_scroll_ui`;
  resetScrollUploadProgress();
  if (preserveCurrentFrame) {
    scrollFrame = cloneFrame(currentFrame);
  } else {
    scrollFrame = blankFrame();
  }
  renderMatrices();
  updateScrollUi();
  renderState();
}
async function buildFirmwareScrollFrames(onProgress = () => {}) {
  const source = scroll.frames;
  if (!source.length) return [];
  if (source.length > firmwareScrollMaxFrames) {
    throw new Error(`文字滚动帧数 ${source.length} 超过固件缓存上限 ${firmwareScrollMaxFrames}；请缩短文本或提高固件上限。`);
  }
  const frames = [];
  for (let i = 0; i < source.length; i++) {
    frames.push(frameToM370(source[i]));
    if (i === 0 || i === source.length - 1 || i % 32 === 0) {
      onProgress((i + 1) / source.length);
      await nextUiFrame();
    }
  }
  return frames;
}
async function uploadFirmwareScrollTimeline() {
  setScrollUploadProgress(0.04, '准备滚动帧');
  const frames = await buildFirmwareScrollFrames(progress => {
    setScrollUploadProgress(0.04 + progress * 0.30, `编码 ${Math.round(progress * 100)}%`);
  });
  if (!frames.length) throw new Error('no scroll frames');
  const totalChunks = Math.ceil(frames.length / SCROLL_UPLOAD_CHUNK_FRAMES);
  let data = null;
  setScrollUploadProgress(0.36, `分批上传到固件 RAM 0/${totalChunks}`);
  for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
    const start = chunkIndex * SCROLL_UPLOAD_CHUNK_FRAMES;
    const chunkFrames = frames.slice(start, start + SCROLL_UPLOAD_CHUNK_FRAMES);
    const isFirstChunk = chunkIndex === 0;
    data = await apiPostWithUploadProgress(API_ENDPOINTS.scroll, {
      frames: chunkFrames,
      stepLedPerFrame: 1,
      start: false,
      append: !isFirstChunk,
      chunkIndex,
      chunkFrames: chunkFrames.length,
      totalFrames: frames.length,
      source: 'webui_text_scroll_frames_only',
      storage: 'ram',
      persist: false,
      saveToFlash: false
    }, progress => {
      const chunkProgress = (chunkIndex + progress) / totalChunks;
      setScrollUploadProgress(
        0.36 + chunkProgress * 0.50,
        `分批上传到固件 RAM ${chunkIndex + 1}/${totalChunks}`
      );
    });
    await sleepMs(20);
  }

  const fps = getScrollFps();
  const intervalMs = Math.max(1, Math.round(1000 / fps));
  setScrollUploadProgress(0.90, `帧数据已完成，设置 ${fps} fps`);
  data = await apiPost(API_ENDPOINTS.command, {
    cmd: 'start_scroll',
    payload: {
      fps,
      intervalMs,
      source: 'webui_text_scroll_after_frames'
    }
  });
  applyFirmwareRuntimeState(data, 'text_scroll_upload_start_after_frames');
  setScrollUploadProgress(0.98, '启动滚动播放');
  return Object.assign({
    frames: frames.length,
    fps,
    scrollIntervalMs: intervalMs
  }, data || {});
}
async function startScroll() {
  const text = sanitizeScrollTextInput(true);
  if (!text.trim()) {
    alert('空文本不进入文字滚动播放');
    return;
  }
  resetScrollUploadProgress();
  setScrollUploadProgress(0.02, '准备发送');
  try {
    await prepareTextScrollTimelineAsync(false);
  } catch (err) {
    resetScrollUploadProgress();
    return;
  }
  if (!scroll.frames.length) {
    resetScrollUploadProgress();
    alert('没有可播放的文字帧');
    return;
  }
  guardBeforeOutput('text_scroll_start', 'scroll');
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  resetScrollPreviewToFirstFrame('text_scroll_start_reset_preview', 'scroll');
  scroll.active = true;
  scroll.paused = false;
  scroll.firmwareBacked = false;
  scroll.uploading = true;
  scroll.dirtyNoticeLogged = false;
  state.textScrollActive = true;
  state.playback = 'scroll';
  state.refreshPolicy = `text_scroll_${getScrollFps()}fps_interval_${getScrollFrameIntervalMs()}ms`;
  scroll.fpsStarted = performance.now();
  scroll.frameCounter = 0;
  try {
    const data = await uploadFirmwareScrollTimeline();
    scroll.firmwareBacked = true;
    scroll.uploading = false;
    completeScrollUploadProgress('发送完成，滚动帧仅在固件 RAM 中运行');
    log(
      `文字滚动已上传到固件 RAM 并独立运行：${data?.frames || scroll.frames.length} 帧，${getScrollFps()} fps，每帧推进 1 LED；不会写入 saved_faces.json 或闪存。`);
  } catch (err) {
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    scroll.active = false;
    state.textScrollActive = false;
    state.playback = 'idle';
    resetScrollUploadProgress();
    log(`文字滚动固件上传失败；已停止，未启用 WebUI 逐帧发送：${err.message}`);
    alert(`文字滚动上传失败：${err.message}`);
    updateScrollUi();
    renderState();
    return;
  }
  restartScrollPreviewTimer();
  log(`文字滚动开始：${getScrollFps()} fps / ${getScrollFrameIntervalMs()} ms，预生成 ${scroll.frames.length} 帧，逐帧 1 LED`);
  updateScrollUi();
  renderState();
}

function togglePauseScroll() {
  if (scroll.paused || state.playback === 'scroll_paused') resumeScroll();
  else pauseScroll();
}

function pauseScroll() {
  if (!scroll.active && !state.textScrollActive && !scroll.firmwareBacked) {
    log('文字滚动未播放，无需暂停');
    updateScrollUi();
    renderState();
    return;
  }
  sendAuxCommand('pause_scroll', {}, 'text_scroll_paused');
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.paused = true;
  scroll.active = false;
  state.textScrollActive = true;
  state.refreshPolicy = 'dirty-frame / 按需刷新';
  state.playback = 'scroll_paused';
  state.lastRefreshReason = 'text_scroll_paused';
  log('文字滚动已暂停，固件停在当前帧；WebUI 不逐帧发送');
  updateScrollUi();
  renderState();
}

function resumeScroll() {
  if (!scroll.frames.length) {
    log('没有已生成/上传的文字滚动帧，改为重新发送并播放');
    startScroll();
    return;
  }
  sendAuxCommand('resume_scroll', {}, 'text_scroll_resumed');
  scroll.paused = false;
  scroll.active = true;
  state.textScrollActive = true;
  state.playback = 'scroll';
  state.refreshPolicy = `text_scroll_${getScrollFps()}fps_interval_${getScrollFrameIntervalMs()}ms`;
  state.lastRefreshReason = 'text_scroll_resumed';
  scroll.fpsStarted = performance.now();
  scroll.frameCounter = 0;
  restartScrollPreviewTimer();
  log('文字滚动继续播放，固件从当前缓存继续运行');
  updateScrollUi();
  renderState();
}

function stopScroll() {
  const shouldRestoreAuto = state.restoreAutoAfterScroll || isAutoModeValue(state.mode);
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.active = false;
  scroll.paused = false;
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

function advanceScroll(manual = false) {
  prepareTextScrollTimeline(false);
  if (!scroll.frames.length) return;
  scroll.frameIndex = (scroll.frameIndex + 1) % scroll.frames.length;
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(scroll.frames[scroll.frameIndex]);
  setScrollPreviewFrame(scrollFrame, manual ? 'text_scroll_manual_step_preview' : 'text_scroll_firmware_preview',
    manual ? 'scroll_step' : 'scroll');
  scroll.frameCounter++;
  const now = performance.now();
  if (now - scroll.fpsStarted >= 1000) {
    scroll.measuredFps = scroll.frameCounter * 1000 / (now - scroll.fpsStarted);
    state.actualFps = scroll.measuredFps;
    scroll.frameCounter = 0;
    scroll.fpsStarted = now;
  }
  updateScrollUi();
}

function scrollSignature() {
  return JSON.stringify({
    text: sanitizeScrollTextInput(true),
    model: TEXT_SCROLL_FONT_MODEL,
    source: arkPixelFont.source,
    verticalOffset: textScrollVerticalOffset()
  });
}
async function prepareTextScrollTimelineAsync(force) {
  try {
    await ensureArkPixelFontReady();
    prepareTextScrollTimeline(force);
  } catch (err) {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = true;
    updateScrollUi();
    alert(`Ark Pixel Font 12px bitmap table 未加载，无法准备文字滚动帧序列：${err.message}`);
    throw err;
  }
}

function prepareTextScrollTimeline(force) {
  const text = sanitizeScrollTextInput(true);
  if (!text.trim()) {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = false;
    updateScrollUi();
    return;
  }
  const sig = scrollSignature();
  if (!force && !scroll.dirty && scroll.signature === sig && scroll.frames.length) return;
  const source = buildTextScrollBitmap(text);
  const maxOffset = Math.max(1, source.width - COLS);
  const frames = [];
  for (let offset = 0; offset <= maxOffset; offset++) {
    const frame = extractFrameFromTextImage(source, offset);
    frames.push(frame);
  }
  scroll.frames = frames;
  scroll.signature = sig;
  scroll.dirty = false;
  scroll.frameIndex = Math.min(scroll.frameIndex, Math.max(0, frames.length - 1));
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(frames[scroll.frameIndex] || blankFrame());
  setScrollPreviewFrame(scrollFrame, 'text_scroll_generated_m370_timeline', isScrollPlaybackValue(state.playback) ?
    'scroll' : 'idle');
  log(
    `文字滚动已生成：${frames.length} 帧，逐帧推进 1 LED，垂直居中偏移 ${textScrollVerticalOffset()} 行，约 ${(frames.length*47/1024).toFixed(1)} KB packed`);
  updateScrollUi();
}

function buildTextScrollBitmap(text) {
  const key = `${text}@@${TEXT_SCROLL_FONT_MODEL}@@${arkPixelFont.source}@@centerY${textScrollVerticalOffset()}`;
  if (buildTextScrollBitmap.cacheKey === key && buildTextScrollBitmap.cache) return buildTextScrollBitmap.cache;
  if (!arkPixelFont.ready) throw new Error('Ark Pixel Font bitmap table is not ready');
  const rawChars = Array.from(text || ' ');
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

function getArkGlyph(cp) {
  const codepoint = Number(cp) || 0;
  let g = arkPixelFont.glyphs.get(codepoint);
  if (g) return g;
  const missing = arkPixelFont.glyphs.get(TEXT_SCROLL_MISSING_GLYPH_CP);
  if (missing) return {
    ...missing,
    missingFor: codepoint
  };
  throw new Error(`Ark Pixel Font 缺少 U+${codepoint.toString(16).toUpperCase().padStart(4,'0')}`);
}

function normalizeGlyphRows(rows, width, height) {
  const out = [];
  const w = Math.max(0, Number(width) || 0);
  const h = Math.max(0, Number(height) || 0);
  const source = Array.isArray(rows) ? rows : [];
  for (let y = 0; y < h; y++) {
    let row = String(source[y] || '');
    if (/^[01]+$/.test(row)) {
      out.push(row.padEnd(w, '0').slice(0, w));
      continue;
    }
    // 防御性兜底：兼容可能仍是十六进制字符串的旧版压缩行。
    let bits = '';
    const clean = row.replace(/[^0-9a-fA-F]/g, '');
    for (const ch of clean) bits += parseInt(ch, 16).toString(2).padStart(4, '0');
    out.push(bits.padEnd(w, '0').slice(0, w));
  }
  return out;
}

function buildTextGlyph(ch) {
  if (!buildTextGlyph.cache) buildTextGlyph.cache = new Map();
  const cp = codePointOfChar(ch || ' ');
  if (buildTextGlyph.cache.has(cp)) return buildTextGlyph.cache.get(cp);

  if (!String(ch || '').trim()) {
    const spaceGlyph = {
      cp,
      char: ch,
      isSpace: true,
      advance: TEXT_SCROLL_SPACE_COLUMNS,
      width: 0,
      height: 0,
      xOffset: 0,
      yOffset: 0,
      dstY: 0,
      rows: []
    };
    buildTextGlyph.cache.set(cp, spaceGlyph);
    return spaceGlyph;
  }

  const raw = getArkGlyph(cp);
  const width = Math.max(0, Number(raw.width) || 0);
  const height = Math.max(0, Number(raw.height) || (Array.isArray(raw.rows) ? raw.rows.length : arkPixelFont
    .lineHeight || 12));
  const glyph = {
    cp,
    char: ch,
    isSpace: false,
    advance: Math.max(1, Number(raw.advance) || arkPixelFont.defaultAdvance || width || 12),
    width,
    height,
    xOffset: Number(raw.xOffset || 0),
    yOffset: Number(raw.yOffset || 0),
    dstY: Number(raw.dstY || 0),
    rows: normalizeGlyphRows(raw.rows, width, height),
    missingFor: raw.missingFor
  };
  buildTextGlyph.cache.set(cp, glyph);
  return glyph;
}

function glyphPixel(glyph, x, y) {
  if (!glyph || !glyph.rows || y < 0 || y >= glyph.rows.length) return false;
  const row = String(glyph.rows[y] || '');
  return row[x] === '1';
}

function blitGlyphBitmap(bitmap, x0, glyph) {
  if (!bitmap || !bitmap.length || !glyph || glyph.isSpace) return;
  const baseY = textScrollVerticalOffset() + (Number(glyph.dstY) || 0) + (Number(glyph.yOffset) || 0);
  const baseX = Math.round(x0 + (Number(glyph.xOffset) || 0));
  for (let gy = 0; gy < glyph.height; gy++) {
    const y = baseY + gy;
    if (y < 0 || y >= ROWS) continue;
    const row = bitmap[y];
    for (let gx = 0; gx < glyph.width; gx++) {
      if (!glyphPixel(glyph, gx, gy)) continue;
      const x = baseX + gx;
      if (x >= 0 && x < row.length) row[x] = true;
    }
  }
}

function extractFrameFromTextImage(source, offset) {
  const frame = blankFrame();
  if (!source || !Array.isArray(source.bitmap)) return frame;
  const start = Math.max(0, Number(offset) || 0);
  for (let y = 0; y < ROWS; y++) {
    const srcRow = source.bitmap[y] || [];
    const [x0, x1] = ROW_RANGES[y];
    for (let x = x0; x <= x1; x++) {
      const idx = XY_TO_INDEX[y][x];
      if (idx < 0) continue;
      const srcX = start + x;
      frame[idx] = !!srcRow[srcX];
    }
  }
  return frame;
}

function updateScrollUi() {
  const stateEl = $('scroll-state');
  const indexEl = $('scroll-frame-index');
  const pauseBtn = $('scroll-pause');
  const playBtn = $('scroll-play');
  const progressWrap = $('scroll-upload-progress');
  const progressBar = $('scroll-upload-bar');
  const progressLabel = $('scroll-upload-label');

  const firmwarePlaying = scroll.firmwareBacked || state.textScrollActive || isScrollPlaybackValue(state.playback);
  const label = scroll.uploading ? 'uploading' :
    (scroll.paused || state.playback === 'scroll_paused') ? 'paused' :
    (scroll.active || state.playback === 'scroll') ? 'playing' :
    scroll.dirty ? 'dirty/idle' :
    'idle';

  if (stateEl) stateEl.textContent = label;
  if (indexEl) indexEl.textContent = `${scroll.frameIndex || 0} / ${scroll.frames?.length || 0}`;
  if (pauseBtn) {
    const enabled = firmwarePlaying || scroll.active || scroll.paused;
    pauseBtn.disabled = !enabled;
    pauseBtn.setAttribute('aria-disabled', enabled ? 'false' : 'true');
    const isPaused = scroll.paused || state.playback === 'scroll_paused';
    pauseBtn.classList.toggle('active', !isPaused && enabled);
    pauseBtn.setAttribute('aria-pressed', (!isPaused && enabled) ? 'true' : 'false');
    pauseBtn.textContent = isPaused ? '继续' : '暂停';
  }
  if (playBtn) {
    playBtn.disabled = !!scroll.uploading;
    playBtn.textContent = scroll.uploading ? '发送中…' : '发送';
  }
  if (progressWrap) {
    const visible = !!scroll.uploading || (scroll.uploadProgress > 0 && scroll.uploadProgress < 1.001) || !!scroll
      .uploadLabel;
    progressWrap.hidden = !visible;
  }
  if (progressBar) progressBar.value = Math.round(clamp(scroll.uploadProgress || 0, 0, 1) * 100);
  if (progressLabel) progressLabel.textContent = scroll.uploadLabel || '等待发送';
}

// 矩阵预览共用同一条初始化路径，确保尺寸和渲染保持一致。
// -----------------------------------------------------------------------------
// 调试控件和延迟初始化
// -----------------------------------------------------------------------------
function initializeMatrixViews() {
  matrixViews = [];
  initMatrix('matrix-basic', () => currentFrame, false, null, false);
  initMatrix('matrix-custom-edit', () => editFrame, true, editCell, false);
  initMatrix('matrix-parts', () => partsFrame, false, null, false);
  initMatrix('matrix-scroll', () => scrollFrame, false, null, false);
  initMatrix('matrix-debug', () => currentFrame, false, null, false);
}

function resetBatteryVoltageRecord(kind) {
  const isMax = String(kind) === 'max';
  const cmd = isMax ? 'reset_battery_max' : 'reset_battery_min';
  const label = isMax ? '最高电压' : '最低电压';
  if (isOfflineHtmlMode()) {
    alert('离线 HTML 模式无法重置固件电池记录。');
    return;
  }
  const packet = sendAuxCommand(cmd, {}, `debug_reset_battery_${kind}`);
  packet.promise?.then(data => {
    const powerPayload = data?.power && typeof data.power === 'object' ? data.power : null;
    if (powerPayload) applyPowerData(powerPayload);
    return refreshPowerStatusFromFirmware(`debug_reset_battery_${kind}_refresh`, true);
  }).then(() => {
    log(`已重置电池${label}记录`);
    renderState();
  }).catch(err => {
    log(`重置电池${label}记录失败: ${err.message}`);
  });
}

// 调试控件会发送诊断命令和本地测试图案。
function initializeDebugControls() {
  setClickHandlers([
    ['debug-all-off', () => setCurrentFrame(blankFrame(), 'debug_all_off', 'idle')],
    ['debug-all-on', () => setCurrentFrame(blankFrame().map(() => true), 'debug_all_on', 'idle')],
    ['debug-checker', () => setCurrentFrame(makePatternFrame('checker'), 'debug_checker', 'idle')],
    ['debug-border', () => setCurrentFrame(makePatternFrame('border'), 'debug_border', 'idle')],
    ['debug-current-face', () => applySavedFace(state.faceIndex, 'debug_current_face')],
    ['debug-apply-m370', () => {
      try {
        setCurrentFrame(m370ToFrame($('debug-m370')?.value || ''), 'debug_apply_m370', 'idle');
      } catch (err) {
        alert(err.message);
      }
    }],
    ['debug-copy-status', () => navigator.clipboard?.writeText(JSON.stringify(state, null, 2))],
    ['debug-reset-storage', () => {
      if (confirm('清空用户表情？默认 type:default 表情不会删除。')) {
        userFaces = [];
        persistFaceDocuments('debug_reset_user_faces');
        renderSavedFaces();
        renderState();
      }
    }],
    ['debug-refresh-power', () => refreshPowerStatusFromFirmware('debug_refresh_power', true)],
    ['debug-reset-battery-min', () => resetBatteryVoltageRecord('min')],
    ['debug-reset-battery-max', () => resetBatteryVoltageRecord('max')],
    ['update-adc', () => {
      state.batteryLastInstantVbat = Number($('battery-v')?.value || state.batteryV);
      state.chargeV = Number($('charge-v')?.value || state.chargeV);
      state.charging = Number(state.chargeV || 0) > 4.0;
      state.batteryLowVoltageUnpowered = !state.charging && Number(state.batteryLastInstantVbat || 0) < Number(
        state.batteryUnpoweredLowThreshold || 5.0);
      state.batteryPowered = state.charging || !state.batteryLowVoltageUnpowered;
      state.batteryV = state.batteryPowered ? state.batteryLastInstantVbat : 0;
      state.batteryPercent = null;
      state.batteryStateText = state.batteryPowered ? '电池' : '未上电';
      const icon = batteryIconForPercent(state.batteryPowered, state.batteryPercent);
      state.batteryIconClass = icon.cls;
      state.batteryIconColor = icon.color;
      renderState();
    }],
    ['serial-send', () => {
      const raw = $('serial-input')?.value || '{}';
      try {
        sendAuxCommand('manual_json', JSON.parse(raw), 'debug_manual_json');
      } catch (err) {
        alert(`JSON 格式错误：${err.message}`);
      }
    }],
    ['log-clear', () => {
      logs = [];
      renderLog();
    }],
    ['log-download', () => downloadJsonFile('rina_webui_log.txt', logs.join('\n'))],
    ['firmware-ping', () => syncRuntimeStateFromFirmware('firmware_ping')],
    ['firmware-pause', () => sendAuxCommand('pause_scroll', {}, 'debug_firmware_pause')]
  ]);
}

let deferredUiInitialized = false;
let basicPreviewMatrixInitialized = false;
let firstPageRevealPrepared = false;
let firstPageRevealStarted = false;
const FIRST_PAGE_REVEAL_SELECTOR = WEBUI_CONFIG.boot.firstPageRevealSelector.join(',');

function initializeBasicPreviewMatrix() {
  if (basicPreviewMatrixInitialized) return;
  basicPreviewMatrixInitialized = true;
  if (!matrixViews.some(view => view.el?.id === 'matrix-basic')) {
    initMatrix('matrix-basic', () => currentFrame, false, null, false);
  }
}

function firstPageRevealItems() {
  return Array.from(document.querySelectorAll(FIRST_PAGE_REVEAL_SELECTOR))
    .filter(el => el && !el.hidden)
    .sort((a, b) => {
      const ar = a.getBoundingClientRect(),
        br = b.getBoundingClientRect();
      const dy = ar.top - br.top;
      if (Math.abs(dy) > 1) return dy;
      return ar.left - br.left;
    });
}

function prepareFirstPageProgressiveReveal() {
  if (firstPageRevealPrepared) return;
  firstPageRevealPrepared = true;
  document.documentElement.dataset.firstPageReveal = 'preparing';
  firstPageRevealItems().forEach(el => {
    el.classList.add('boot-reveal-item');
    el.classList.remove('is-revealed');
  });
}

function settleFirstPageProgressiveReveal() {
  document.querySelectorAll('.boot-reveal-item').forEach(el => {
    el.classList.remove('boot-reveal-item', 'is-revealed');
  });
}

async function revealFirstPageWaterfall() {
  if (firstPageRevealStarted) return;
  firstPageRevealStarted = true;
  prepareFirstPageProgressiveReveal();
  await new Promise(resolve => requestAnimationFrame(resolve));
  delete document.documentElement.dataset.firstPageReveal;
  await new Promise(resolve => requestAnimationFrame(resolve));
  for (const el of firstPageRevealItems()) {
    el.classList.add('is-revealed');
    await new Promise(resolve => setTimeout(resolve, 115));
  }
  await new Promise(resolve => setTimeout(resolve, 260));
  settleFirstPageProgressiveReveal();
}

function initFirstPageUiBeforeShow() {
  initButtonPressAnimations();
  observeWebUiFont();
  initNav();
  initColors();
  initBrightness();
  initBasicControls();
  initCustomSelectDropdowns();
}

function renderFirstPageUiBeforeShow() {
  applyBrightnessLocal(state.brightness);
  setColor(state.color, 'firmware_sync');
  syncAutoIntervalUi();
  setFirmwareStatus({
    savedFacesSync: 'waiting for firmware runtime read'
  });
  renderState();
}

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

function makePatternFrame(kind) {
  const frame = blankFrame();
  for (let y = 0; y < ROWS; y++) {
    const [x0, x1] = ROW_RANGES[y];
    for (let x = x0; x <= x1; x++) {
      const idx = XY_TO_INDEX[y][x];
      if (idx < 0) continue;
      if (kind === 'checker') frame[idx] = ((x + y) & 1) === 0;
      else if (kind === 'border') frame[idx] = y === 0 || y === ROWS - 1 || x === x0 || x === x1;
    }
  }
  return frame;
}

let postBootDeferredReadStarted = false;
async function runPostBootDeferredReads(bootOk = false) {
  if (postBootDeferredReadStarted) return;
  postBootDeferredReadStarted = true;
  await new Promise(resolve => requestAnimationFrame(resolve));
  await new Promise(resolve => setTimeout(resolve, 0));

  const bootPlaybackIsScroll = state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state
    .playback);
  try {
    setFirmwareStatus({
      savedFacesSync: 'loading after WebUI ready'
    });
    log('WebUI 已显示：开始异步读取 saved_faces.json 与 LED 预览矩阵。');
    await loadFaceLibrary();
  } catch (err) {
    setFirmwareStatus({
      savedFacesSync: 'deferred load failed'
    });
    if (shouldLogApiError()) log(`延后读取 saved_faces.json 失败：${err.message}`);
  }

  const matrixSynced = await syncRuntimeStateFromFirmware('post_load_matrix_preview');
  if (!matrixSynced && getAllFaces().length && !bootPlaybackIsScroll) {
    if (bootOk) applyKnownFaceIndexLocal('post_load_face_index_fallback');
    else applyStartupDefaultFaceLocal('post_load_default_face_fallback');
  }
  renderSavedFaces();
  renderMatrices();
  renderState();
  scheduleMatrixFitRender(3);

  // 关键启动读取（运行时状态 + saved_faces + 预览）完成后，且加载动画仍在屏幕上时，
  // 在后台预热文字滚动浏览器字体（ark12.woff2，约 593KB）。这样文字滚动页面
  // 会提前拥有字体，用户打开后就不会再过几秒才替换字体。
  // 它会在关键读取之后启动，避免与这些读取竞争单线程 ESP Web 服务器。
  // 较大的 1.8MB ark12.json 位图字形表仍保持延迟加载，首次进入文字滚动页面时加载；见 switchPage。
  ensureTextScrollBrowserFontReady().catch(() => {});
}

const BOOT_MIN_DISPLAY_MS = WEBUI_CONFIG.boot.minDisplayMs;
// -----------------------------------------------------------------------------
// 应用启动
// -----------------------------------------------------------------------------
async function bootstrapWebUi() {
  const bootStart = performance.now();
  let bootOk = false;
  try {
    if (window.rinaStartLoaderAnimation) await window.rinaStartLoaderAnimation();
    prepareFirstPageProgressiveReveal();
    // UI 字体（GNU Unifont，内嵌 data URI）必须在第 4 阶段
    // 瀑布揭示前完全就绪，这样首屏揭示时就已经显示正确字体。
    // 它是内嵌的（无网络请求），因此这个 await 很快。ark12 滚动字体保持
    // 延后，并在第 4 阶段之后通过 initScroll 加载。
    await ensureWebUiFontReady().catch(err => console.warn('WebUI font bootstrap failed', err));
    initFirstPageUiBeforeShow();
    initializeBasicPreviewMatrix();
    renderFirstPageUiBeforeShow();
    showBootUiBehindLoader();
    await new Promise(resolve => requestAnimationFrame(resolve));
    const firstPageRevealPromise = revealFirstPageWaterfall();

    // 先处理第 4 阶段：等待首屏瀑布揭示完成。
    await firstPageRevealPromise;

    // 在最短显示窗口开始时启动固件启动读取（现在包含第一帧 LED），
    // 让它与原本空闲的等待时间重叠。第一帧矩阵 + 运行时状态会在
    // 加载动画仍显示时应用，因此加载器关闭/揭示页面时，
    // 基础矩阵预览已经填充完成，同时不会让关闭过程等待网络。
    const runtimePingPromise = preloadFirmwareRuntimeState().then(() => {
      bootOk = !!bootRuntimeSnapshot.ok;
      applyBrightnessLocal(state.brightness);
      syncAutoIntervalUi();
      updateM370Views();
      updateScrollUi();
      setFirmwareStatus({
        savedFacesSync: 'deferred until WebUI ready'
      });
      renderSavedFaces();
      renderMatrices();
      renderState();
      fitAllMatrices();
    }).catch(err => {
      if (shouldLogApiError()) log(`runtime 状态读取失败：${err.message || err}`);
    });

    await waitForBootLoaderMinimum(bootStart);
    await new Promise(resolve => requestAnimationFrame(resolve));

    finishBootVisibility();
    scheduleMatrixFitRender(4);
    initDeferredUiAfterShow();

    // 确保运行时快照（以及 bootOk）先稳定下来，
    // 再启动依赖它的延迟读取和状态轮询。
    await runtimePingPromise;

    startFirmwareStatusPolling();
    startPowerStatusPolling();
    runPostBootDeferredReads(bootOk).catch(err => {
      if (shouldLogApiError()) log(`延后读取 saved_faces/预览矩阵失败：${err.message}`);
    });
    log(bootOk ?
      'WebUI 启动：先初始化 UI，再读取 runtime-only 固件运行状态；读取完成后触发加载动画结束。saved_faces 与 LED 预览矩阵会在页面显示后异步读取。' :
      'WebUI 启动：先初始化 UI；固件状态读取失败/离线后使用本地默认页面结束加载动画。saved_faces 与预览矩阵会在页面显示后尝试读取。');
  } catch (err) {
    console.error('WebUI bootstrap failed', err);
    const msg = `WebUI 初始化失败：${err.message || err}`;
    try {
      log(msg);
    } catch (_) {
      console.error(msg);
    }
    const logEl = $('log');
    if (logEl) logEl.textContent = msg;
    showBootUiBehindLoader();
    await revealFirstPageWaterfall().catch(() => {});
    await waitForBootLoaderMinimum(bootStart);
    await new Promise(resolve => requestAnimationFrame(resolve));
    finishBootVisibility();
    scheduleMatrixFitRender(4);
    initDeferredUiAfterShow();
    runPostBootDeferredReads(bootOk).catch(() => {});
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', bootstrapWebUi, {
    once: true
  });
} else {
  bootstrapWebUi();
}
</script>
  </body>
</html>
~~~~

#### `data/resources/runtime_settings.json`

~~~~json
{
  "format": "rina_runtime_settings_v1",
  "version": 1,
  "mode": "manual",
  "autoIntervalMs": 3000,
  "updatedAtMs": 0
}
~~~~

#### `data/resources/battery_calib.json`

~~~~json
{
  "format": "rina_battery_calibration_v1",
  "version": 1,
  "v_max": 8.0,
  "v_min": 6.2,
  "v_max_nominal": 8.0,
  "v_min_nominal": 6.2
}
~~~~

#### `data/resources/saved_faces.json`

~~~~json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": {
    "leds": 370,
    "m370HexChars": 93
  },
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": "2026-05-15T03:12:06.486Z",
  "faces": [
    {
      "id": "face_01_surprised_winking_with_mouth",
      "name": "surprised / winking with mouth",
      "type": "default",
      "m370": "M370:0000000000700408804044020020080100200000001002000000006180027900080400402004F20030C0000000000",
      "order": 1,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_02_glasses_eyed_square_mouth",
      "name": "glasses-eyed, square mouth",
      "type": "default",
      "m370": "M370:00000000000000000000300301A0160780780C00E000014000020000000000000FFC00402003FC000000000000000",
      "order": 2,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_03_confused_raised_eyebrows",
      "name": "confused / raised eyebrows",
      "type": "default",
      "m370": "M370:0000000000000000000000000000000800041E01E000000000000A00140000000408001F800000000000000000000",
      "order": 3,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_04_sad_diagonal_eyes_downturned_mouth",
      "name": "sad diagonal eyes, downturned mouth",
      "type": "default",
      "m370": "M370:000000000000000000003000C0C00C0300400C00C00000C000000A001401FE0004080010800090000600000000000",
      "order": 4,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_05_neutral_blocky_eyes_smirk",
      "name": "neutral blocky eyes, smirk",
      "type": "default",
      "m370": "M370:00000000000000000000300300C00C0300300C00C000000000000A00140201000408001F800000000000000000000",
      "order": 5,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_06_squinting_happy",
      "name": "squinting happy",
      "type": "default",
      "m370": "M370:00000000000000000000000000C00C03C0F006018000000000000540A800840003F00010800204000000000000000",
      "order": 6,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_07_wide_eyebrows_tiny_mouth",
      "name": "wide eyebrows, tiny mouth",
      "type": "default",
      "m370": "M370:0000000000000000000000000000000FC0FC000028000040000000000000780002100020400204003FC0000000000",
      "order": 7,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_08_triangle_eyes_frown",
      "name": "triangle eyes, frown",
      "type": "default",
      "m370": "M370:00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000",
      "order": 8,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": true,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_09_stoic_vertical_eyes_frown",
      "name": "stoic vertical eyes, frown",
      "type": "default",
      "m370": "M370:000000000000000000001806006018018060060180000000000005002801FE0004080010800090000600000000000",
      "order": 9,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_10_x_eyes_frown",
      "name": "X-eyes, frown",
      "type": "default",
      "m370": "M370:00000000000000000000C000C0C00C0080400C00C0C000C0000005002829FE5004080010800090000600000000000",
      "order": 10,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    },
    {
      "id": "face_11_qiangqiang",
      "name": "qiangqiang",
      "type": "default",
      "m370": "M370:0000000001C423A242451212208844042108108420000001084200000000FC0004080040200402004020040801F80",
      "order": 11,
      "editable": true,
      "deletable": false,
      "locked": true,
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "2026-05-09T08:51:53+00:00",
      "updatedAt": null,
      "call": null
    }
  ]
}
~~~~

#### `data/resources/fonts/README.md`

~~~~markdown
# Font resources

- `ark12.woff2` and `ark12.json` are LittleFS runtime resources for the text-scroll input/browser preview and LED bitmap rasterizer.
- GNU Unifont is **not** stored here as `unifont.woff2`. The WebUI Unifont subset is embedded directly inside `data/index.html` as a `data:font/woff2;base64,...` URL.
- `run_rinachan_unifont.ps1` rebuilds the modified GNU Unifont subset from the GNU Unifont BMP sheet, embeds it into `index.html`, removes any forbidden external `unifont.woff2`, and validates that no external Unifont source is used.
~~~~

#### `data/styles.css`

> CSS 中原始 GNU Unifont WOFF2 data URI 不写入本规格；重建时必须由 `tools/build_unifont_webui_subset_from_png.py`/字体构建链生成并注入，不能从文档复制二进制字体载荷。除此之外，本段保留当前 CSS 的选择器、变量、动画、断点和交互状态。

~~~~css
/* Rina WebUI 样式：主题令牌、布局规则和组件状态。 */

/* 内嵌字体资源和 WebUI 主题令牌。 */
  /* 保持内嵌备用字体 data URI 不变，确保 CSS 解析器读取准确载荷。 */
  @font-face{font-family:"GNU Unifont";src:url("<GENERATED_UNIFONT_WOFF2_DATA_URI>") format("woff2");font-weight:normal;font-style:normal;font-display:block}

  @font-face {
    font-family: "Ark Pixel 12px Monospaced";
    src: url("/resources/fonts/ark12.woff2?v=20260511-ark12-merged-trad1") format("woff2");
    font-weight: 400;
    font-style: normal;
    font-display: block;
  }


  /* 布局和控件共享的主题令牌。 */
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


  /* 文档和表单控件的基础默认值。 */
  * {
    box-sizing: border-box
  }

  html {
    min-width: var(--page-min-width);
    overflow-x: auto;
    overflow-y: auto;
    scrollbar-gutter: stable;
    scrollbar-color: var(--line) var(--bg);
    color-scheme: dark;
  }

  html::-webkit-scrollbar {
    width: 12px;
    height: 12px;
    background: var(--bg);
  }

  html::-webkit-scrollbar-track {
    background: var(--bg);
  }

  html::-webkit-scrollbar-thumb {
    background: var(--line);
    border: 3px solid var(--bg);
    border-radius: 999px;
  }

  html,
  body {
    margin: 0;
    min-height: 100%;
    background: var(--bg);
    color: var(--text);
    font-family: var(--ui-font) !important;
    font-size: 16px;
    font-synthesis: none;
    -webkit-text-size-adjust: 100%;
    -webkit-font-smoothing: none;
    text-rendering: geometricPrecision;
  }

  body {
    min-width: var(--page-min-width);
    padding: 0;
    overscroll-behavior-x: none;
    overflow-y: visible;
  }

  html[data-scroll-lock="boot"] {
    overflow-y: scroll;
    scrollbar-gutter: stable;
    scrollbar-width: auto;
  }

  html[data-scroll-lock="boot"] body {
    position: fixed;
    inset: 0;
    width: 100%;
    overflow-y: clip;
    overscroll-behavior: none;
    touch-action: none;
  }

  html[data-scroll-lock="boot"] body,
  html[data-scroll-lock="boot"] body * {
    scrollbar-width: none;
  }

  html[data-scroll-lock="boot"] body::-webkit-scrollbar,
  html[data-scroll-lock="boot"] body *::-webkit-scrollbar {
    display: none;
    width: 0;
    height: 0;
  }

  button,
  input,
  select,
  textarea,
  option,
  optgroup,
  label,
  summary,
  dialog,
  [role="button"],
  [role="menu"],
  [role="menuitem"] {
    font-family: var(--ui-font) !important;
    font-size: inherit;
    font-weight: inherit;
    line-height: inherit;
    color: var(--text);
    font-synthesis: none;
  }

  button,
  input,
  select,
  textarea,
  .brand-nav-toggle,
  .select-toggle {
    touch-action: manipulation;
  }

  html,
  body,
  body *,
  body *::before,
  body *::after,
  .brand-nav-toggle,
  .select-toggle,
  .select-menu,
  .select-option,
  .select-label,
  .select-caret,
  .toggle-button,
  .face-source-badge,
  .saved-name-input,
  .small,
  .hint,
  .kv,
  .k,
  .v,
  .num,
  .log,
  .mono {
    font-family: var(--ui-font) !important;
  }

  body #scroll-text {
    font-family: var(--scroll-font) !important;
    font-size: 12px !important;
    line-height: 1.2;
    font-synthesis: none;
  }

  body #scroll-text::before,
  body #scroll-text::after {
    font-family: var(--scroll-font) !important;
  }

  button {
    --button-hover-color: var(--accent2);
    --button-hover-y: 0px;
    --button-press-y: 0px;
    --button-press-scale: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--line);
    background: var(--panel2);
    border-radius: var(--button-radius);
    padding: var(--button-padding-y) var(--button-padding-x);
    min-height: var(--control-height);
    font-size: var(--button-font-size);
    line-height: var(--control-line-height);
    cursor: pointer;
    overflow: visible;
    transform: translateY(calc(var(--button-hover-y) + var(--button-press-y))) scale(var(--button-press-scale));
    transition: transform 140ms cubic-bezier(.2, .8, .2, 1), border-color .12s, background .12s, box-shadow .12s, filter 120ms cubic-bezier(.2, .8, .2, 1);
    -webkit-tap-highlight-color: transparent;
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

  .part-card.is-pressing .part-mini {
    transform: scale(.93);
    border-color: var(--button-hover-color);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent), 0 0 14px color-mix(in srgb,
      var(--button-hover-color) 22%, transparent);
    transition: 90ms transform cubic-bezier(.2, .8, .2, 1), border-color .12s, box-shadow .12s;
  }

  .part-card.is-releasing .part-mini {
    transform: scale(1);
    transition: 150ms transform cubic-bezier(.2, .8, .2, 1), border-color .15s, box-shadow .15s;
  }

  button.compact-btn {
    min-width: var(--control-height);
    padding: var(--control-padding-y) var(--control-compact-padding-x);
    font-size: var(--control-font-size);
    font-weight: 800;
  }

  button:hover:not(:disabled) {
    --button-hover-y: -1px;
    border-color: var(--button-hover-color);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent);
  }

  button.is-pressing:hover:not(:disabled),
  button.is-releasing:hover:not(:disabled) {
    --button-hover-y: 0px;
  }

  button.primary {
    --button-hover-color: var(--accent);
    background: var(--primary-gradient);
    border-color: transparent;
    color: #fff;
    font-weight: 700
  }

  button.ok {
    --button-hover-color: #59d98e;
    background: #163824;
    border-color: #216b3f;
    color: #b8ffd4
  }

  button.danger {
    --button-hover-color: #ff7890;
    background: #3a1820;
    border-color: #7b2b3b;
    color: #ffd0d8
  }

  button.active {
    --button-hover-color: var(--accent);
    border-color: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent)
  }

  button:disabled {
    opacity: .42;
    cursor: not-allowed;
    filter: grayscale(.45);
  }

  input,
  select,
  textarea {
    background: #0c0f15;
    border: 1px solid var(--line);
    border-radius: var(--control-radius);
    padding: var(--control-padding-y) var(--control-padding-x);
    min-height: var(--control-height);
    font-size: var(--control-font-size);
    line-height: var(--control-line-height);
    outline: none;
  }

  input:not([type="range"]):not([type="file"]):not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not([type="color"]) {
    height: var(--control-height);
  }

  input:focus,
  select:focus,
  textarea:focus {
    border-color: var(--accent2);
  }

  input[type="range"] {
    padding: 0;
    width: 100%;
    height: var(--control-height);
    accent-color: var(--accent);
    touch-action: pan-y;
  }

  textarea {
    width: 100%;
    min-height: 90px;
    resize: vertical;
    font-family: var(--ui-font) !important;
    font-size: var(--control-font-size);
  }

  #custom-m370,
  #parts-m370-text,
  #debug-m370 {
    min-height: 0;
    resize: none;
    overflow: hidden;
    white-space: pre-wrap;
    word-break: break-all;
  }

  #scroll-text {
    --scroll-text-min-height: 42px;
    min-height: var(--scroll-text-min-height);
    max-height: none;
    resize: none;
    overflow: hidden;
    line-height: 1.2;
    padding-top: calc((var(--scroll-text-min-height) - 2px - 1.2em) / 2);
    padding-bottom: calc((var(--scroll-text-min-height) - 2px - 1.2em) / 2);
    white-space: pre-wrap;
    word-break: break-word;
    font-family: var(--scroll-font) !important;
    font-size: 12px !important;
    font-synthesis: none;
  }

  a {
    color: var(--accent2)
  }

  .sidebar {
    position: relative;
    z-index: 2147482999;
    overflow: visible;
    border-right: 0;
    border-bottom: 1px solid var(--line);
    background: linear-gradient(180deg, #151927, #0f1117);
    padding: var(--sidebar-padding-y) var(--sidebar-padding-x);
    display: grid;
    grid-template-columns: 1fr;
    gap: 14px;
    align-items: center;
  }

  .top-page-nav {
    position: absolute;
    top: calc(var(--control-height) + var(--sidebar-padding-y) * 2 + var(--page-edge-gap));
    right: var(--page-edge-gap);
    left: var(--page-edge-gap);
    width: auto;
    z-index: 2147483000;
    isolation: isolate;
    display: grid;
    gap: 8px;
    max-height: min(60vh, 380px);
    overflow: visible;
    opacity: 0;
    transform: translateY(-8px);
    pointer-events: none;
    border: 1px solid transparent;
    border-radius: var(--control-radius);
    background: #141926;
    padding: 10px;
    box-shadow: none;
    transition: opacity .18s cubic-bezier(.33, 1, .68, 1), transform .24s cubic-bezier(.16, 1, .3, 1),
      border-color .24s cubic-bezier(.16, 1, .3, 1), box-shadow .24s cubic-bezier(.16, 1, .3, 1);
    will-change: opacity, transform;
  }

  .top-page-nav.open {
    opacity: 1;
    transform: translateY(0);
    pointer-events: auto;
    border-color: var(--line);
    box-shadow: 0 18px 46px #00000090;
    overflow: visible;
  }

  .top-page-nav .nav-shell {
    width: 100%;
    margin: -2px;
    padding: 2px;
    max-height: calc(min(60vh, 380px) - 22px);
    overflow: hidden;
  }

  .top-page-nav.open .nav-shell {
    overflow: auto;
    scrollbar-width: thin;
  }

  .app {
    display: block;
    min-height: calc(100vh - 160px);
  }

  .brand {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-bottom: 0;
    min-width: 0;
    flex-wrap: nowrap;
  }

  .brand-copy>.row {
    display: flex;
    align-items: center;
    justify-content: flex-start;
    gap: 4px;
    min-width: 0;
    white-space: nowrap;
    overflow: visible;
    margin-top: 3px;
  }

  .brand-copy>.row .badge {
    flex: 0 0 auto;
    margin: 0;
    padding: 5px 6px;
    font-size: 11px;
    line-height: 1;
    gap: 4px;
    white-space: nowrap;
  }

  .brand-copy {
    flex: 1 1 0;
    min-width: 0;
    overflow: hidden;
  }

  .brand h1 {
    font-size: 17px;
    margin: 0;
    line-height: 1.25;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .brand-nav-toggle {
    margin-left: auto;
    flex: 0 0 var(--control-height);
    width: var(--control-height);
    height: var(--control-height);
    display: inline-grid;
    place-items: center;
    padding: 0;
    border-radius: var(--button-radius);
    background: linear-gradient(180deg, #1a2030, #111722);
    box-shadow: 0 12px 30px #00000035;
    color: var(--text);
    outline: none;
  }

  .brand-nav-toggle:hover:not(:disabled) {
    background: linear-gradient(180deg, #20283a, #121a27);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent), 0 12px 30px #00000035;
  }

  .brand-nav-toggle:focus-visible {
    border-color: var(--accent2);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent2) 25%, transparent), 0 18px 46px #00000060;
  }

  .brand-nav-toggle.active {
    --button-hover-color: var(--accent);
    border-color: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent), 0 12px 30px #00000035;
  }

  .nav-shell {
    position: relative;
    margin-top: 12px;
    z-index: 2147483001;
  }

  .select-toggle {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    min-height: var(--control-height);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    text-align: left;
    padding: var(--button-padding-y) var(--button-padding-x);
    border: 1px solid var(--line);
    border-radius: var(--button-radius);
    background: #141926;
    box-shadow: 0 12px 30px #00000035;
    color: var(--text);
    font-size: var(--button-font-size);
    font-weight: 700;
    outline: none;
  }

  .select-toggle:hover:not(:disabled) {
    background: #1c2438;
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent), 0 12px 30px #00000035;
  }

  .select-toggle:focus-visible {
    border-color: var(--accent2);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent2) 25%, transparent), 0 18px 46px #00000060;
  }

  .select-label {
    flex: 1;
    min-width: 0;
    overflow: visible;
    word-break: break-word;
    font-weight: 700;
    font-size: inherit;
  }

  .menu-icon {
    display: inline-grid;
    gap: 4px;
    flex: 0 0 auto;
  }

  .menu-icon span {
    display: block;
    width: 18px;
    height: 2px;
    border-radius: 999px;
    background: currentColor;
  }

  .select-caret {
    color: var(--muted);
    transition: .12s transform, .12s color;
    position: static;
    right: auto;
    top: auto;
    pointer-events: none;
    font-size: 13px;
    line-height: 1;
  }

  .select-shell:hover .select-caret,
  .select-shell:focus-within .select-caret {
    color: var(--accent2);
  }

  .select-shell.open .select-caret {
    transform: rotate(180deg);
  }

  .nav {
    display: grid;
    gap: 8px;
    padding: 2px;
    position: static;
    z-index: 2147483002;
    grid-template-columns: 1fr;
    max-height: none;
    overflow: visible;
  }

  .select-menu {
    display: none;
    gap: 8px;
    padding: 8px;
    border: 1px solid transparent;
    border-radius: var(--control-radius);
    background: #141926;
    box-shadow: none;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: none;
    position: fixed;
    top: 0;
    left: 0;
    z-index: 2147482501;
    max-height: none;
    box-sizing: border-box;
    overscroll-behavior: contain;
    touch-action: pan-y;
    -webkit-overflow-scrolling: touch;
    opacity: 0;
    transform: translateY(-8px);
    pointer-events: none;
    transition: opacity .18s cubic-bezier(.33, 1, .68, 1), transform .24s cubic-bezier(.16, 1, .3, 1),
      border-color .24s cubic-bezier(.16, 1, .3, 1), box-shadow .24s cubic-bezier(.16, 1, .3, 1);
    will-change: opacity, transform;
  }

  .select-menu.open {
    opacity: 1;
    transform: translateY(0);
    pointer-events: auto;
    border-color: var(--line);
    box-shadow: 0 18px 46px #00000090;
  }

  .select-menu::-webkit-scrollbar {
    display: none;
  }

  .nav button {
    min-height: var(--control-height);
    text-align: left;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: var(--button-padding-y) var(--button-padding-x);
    border: 1px solid var(--line);
    border-radius: var(--button-radius);
    background: #111520;
    box-shadow: 0 8px 22px #00000028;
    color: var(--text);
    font-size: var(--button-font-size);
    line-height: var(--control-line-height);
    font-weight: 700;
    outline: none;
  }

  .nav button:hover:not(:disabled) {
    background: #273040;
  }

  .nav button:focus-visible {
    outline: 2px solid color-mix(in srgb, var(--accent2) 45%, transparent);
    outline-offset: 2px;
  }

  .nav button.active {
    --button-hover-color: var(--accent);
    background: var(--primary-gradient);
    border-color: transparent;
    box-shadow: none;
    color: #fff;
  }

  .nav.open button.active:hover:not(:disabled),
  .nav button.active:hover:not(:disabled) {
    background: var(--primary-gradient);
    border-color: var(--button-hover-color);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent);
    color: #fff;
  }

  .select-option {
    min-height: var(--control-height);
    text-align: left;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: var(--button-padding-y) var(--button-padding-x);
    border: 1px solid var(--line);
    border-radius: var(--button-radius);
    background: #111520;
    box-shadow: 0 8px 22px #00000028;
    color: var(--text);
    font-size: var(--button-font-size);
    line-height: var(--control-line-height);
    font-weight: 700;
    outline: none;
  }

  .select-option:hover:not(:disabled) {
    background: #1c2438;
  }

  .select-option:focus-visible {
    border-color: var(--accent2);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent2) 25%, transparent), 0 14px 32px #00000055;
  }

  .select-option.active {
    --button-hover-color: var(--option-color, var(--accent));
    border-color: var(--option-color, var(--accent));
    background: linear-gradient(180deg, #172033, #111827);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--option-color, var(--accent)) 28%, transparent), 0 8px 22px #00000028;
  }

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

  .select-shell {
    position: relative;
    width: 100%;
    min-width: 0;
    z-index: 50;
  }

  .select-shell.open {
    z-index: 2147482500;
  }

  .select-shell select {
    position: absolute !important;
    left: 0;
    top: 0;
    width: 1px !important;
    height: 1px !important;
    min-height: 1px !important;
    opacity: 0 !important;
    pointer-events: none !important;
    appearance: none;
    -webkit-appearance: none;
  }

  .select-option span:first-child {
    min-width: 0;
    overflow: clip;
    overflow-clip-margin: 3px;
    text-overflow: ellipsis;
    white-space: nowrap;
    line-height: inherit;
  }

  .select-option .num {
    color: var(--muted);
    font-size: 12px;
    font-weight: 700;
    white-space: nowrap;
    line-height: inherit;
  }

  .select-option.active .num {
    color: var(--option-color, var(--accent));
    text-shadow: 0 0 9px color-mix(in srgb, var(--option-color, var(--accent)) 72%, transparent),
      0 0 18px color-mix(in srgb, var(--option-color, var(--accent)) 36%, transparent);
  }

  .content {
    padding: 18px;
    max-width: 1480px;
    width: 100%;
    margin: 0 auto;
    min-width: 0;
    overflow-x: hidden;
  }


  /* 响应式布局调整。 */
  @media (min-width:1471px) {

    body[data-page="parts"] .content,
    body[data-page="debug"] .content {
      max-width: 2209px;
    }

    .parts-outer-layout {
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr);
    }

    .parts-left-col {
      display: contents;
    }

    #parts-preview-card {
      grid-column: 1;
      grid-row: 1;
    }

    #part-groups {
      grid-column: 2;
      grid-row: 1;
    }

    .parts-manager-col {
      grid-column: 3;
      grid-row: 1;
    }
  }

  .page {
    display: none;
    animation: fade .16s ease-out;
  }

  .page.active {
    display: block;
  }

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

  .hero {
    display: flex;
    gap: 16px;
    align-items: center;
    justify-content: space-between;
    min-height: 56px;
    margin-bottom: 8px;
  }

  .hero>div:first-child {
    display: flex;
    align-items: center;
    justify-content: flex-start;
    align-self: stretch;
    min-height: 56px;
    text-align: left;
  }

  .hero h2 {
    font-size: 26px;
    margin: 0;
    line-height: 1.25;
    display: flex;
    align-items: center;
    justify-content: flex-start;
    min-height: 100%;
    text-align: left;
  }

  .hero p {
    margin: 0;
    color: var(--muted);
    line-height: 1.55
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 6px 10px;
    background: var(--panel);
    font-size: 12px;
    color: #ccd7e5;
    margin: 3px;
    white-space: nowrap;
  }

  .grid {
    display: grid;
    gap: 14px;
    align-items: start;
    min-width: 0;
  }

  .cols-2 {
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  }

  .card {
    background: linear-gradient(180deg, var(--panel), #121621);
    border: 1px solid var(--line);
    border-radius: 18px;
    padding: 15px;
    box-shadow: var(--card-shadow);
    min-width: 320px;
  }

  .card h3 {
    margin: 0 0 12px;
    font-size: 16px;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .card h4 {
    margin: 14px 0 8px;
    font-size: 14px;
    color: #dfe7f3;
  }

  .row {
    display: flex;
    align-items: flex-end;
    gap: 10px;
    flex-wrap: wrap;
  }

  .toggle-button {
    white-space: nowrap;
  }

  .toggle-button.active {
    --button-hover-color: var(--accent);
    border-color: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .control-panel {
    display: grid;
    gap: 14px;
    min-width: 0;
  }

  .basic-layout {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 14px;
    align-items: start;
    container-type: inline-size;
  }

  .basic-layout>.control-panel {
    order: 2;
  }

  .basic-layout>.basic-preview-card {
    order: 1;
  }

  .basic-preview-card {
    min-width: 0;
  }

  .basic-preview-card .matrix-wrap {
    min-height: 0;
  }

  .control-panel>h3 {
    display: none;
  }

  .control-section {
    display: grid;
    gap: 10px;
  }

  .control-section.card {
    min-width: 0;
  }

  .control-section h3,
  .control-section h4 {
    margin: 0 0 2px;
    font-size: 16px;
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text);
  }

  .slider-step-row {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    align-items: center;
  }

  .slider-step-row button {
    white-space: nowrap;
  }

  .slider-step-row .compact-btn {
    min-width: 74px;
  }

  .slider-step-row .push-right {
    margin-left: auto;
  }

  .brightness-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 68px;
    gap: 10px;
    align-items: center;
  }

  .brightness-row input[type="range"] {
    min-width: 0;
  }

  .brightness-row .slider-number {
    width: 100%;
    min-width: 0;
    text-align: center;
  }

  .equal-fields {
    display: grid;
    grid-template-columns: repeat(2, minmax(120px, 160px));
    gap: 10px;
    align-items: end;
  }

  .equal-fields .field {
    min-width: 0;
  }

  .equal-fields input {
    width: 100%;
  }

  .button-row {
    display: flex;
    align-items: flex-end;
    gap: 10px;
    flex-wrap: wrap;
  }

  .button-row button {
    white-space: nowrap;
  }

  .mode-button-row {
    justify-content: flex-start;
    flex-wrap: wrap;
    overflow: visible;
    scrollbar-width: auto;
  }

  .mode-button-row button {
    min-height: var(--control-height);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    padding: var(--control-padding-y) var(--control-padding-x);
    font-size: var(--control-font-size);
    line-height: var(--control-line-height);
  }

  .mode-button-row #face-prev,
  .mode-button-row #face-next {
    width: var(--control-height);
    min-width: var(--control-height);
    padding: 0;
    font-size: calc(var(--control-font-size) + 3px);
  }

  .mode-button-row .compact-btn {
    min-width: 74px;
    padding: 0 var(--control-compact-padding-x);
  }

  .mode-button-row .push-right {
    margin-left: auto;
  }

  .mode-button-row .toggle-button {
    min-width: 68px;
    padding-left: 8px;
    padding-right: 8px;
  }

  .status-merged {
    max-height: 260px;
    overflow: auto;
  }

  .stack {
    display: grid;
    gap: 10px;
    overflow-x: auto;
    overflow-y: visible;
    max-width: 100%;
    scrollbar-width: thin;
  }

  .parts-outer-layout {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 14px;
    align-items: start;
  }

  .parts-left-col {
    display: grid;
    gap: 14px;
    align-content: start;
    min-width: 0;
  }

  .parts-manager-col {
    min-width: 0;
  }

  #part-groups {
    min-width: 0;
  }

  @media (max-width:980px) {
    .parts-outer-layout {
      grid-template-columns: 1fr;
    }

    .basic-layout {
      grid-template-columns: 1fr;
    }

    .basic-layout>.control-panel,
    .basic-layout>.basic-preview-card {
      order: unset;
    }

    :root {
      --page-edge-gap: 12px;
      --sidebar-padding-y: 10px;
      --sidebar-padding-x: 10px;
      --control-height: 42px;
      --control-font-size: 15px;
      --control-padding-y: 9px;
      --control-padding-x: 13px;
    }

    .top-page-nav {
      top: calc(var(--control-height) + var(--sidebar-padding-y) * 2 + var(--page-edge-gap));
      right: var(--page-edge-gap);
      left: var(--page-edge-gap);
      width: auto;
      padding: 8px;
    }

    .top-page-nav.open {
      padding: 8px;
    }

    .app {
      min-height: 0;
    }

    .sidebar {
      grid-template-columns: 1fr;
      padding: var(--sidebar-padding-y) var(--sidebar-padding-x);
    }

    .nav {
      position: static;
      max-height: min(70vh, 420px);
    }

    .content {
      padding: 8px;
    }

    .cols-2 {
      grid-template-columns: 1fr;
    }

    .hero {
      display: grid;
      align-items: center;
      min-height: 48px;
    }

    .hero>div:first-child {
      display: flex;
      align-items: center;
      justify-content: flex-start;
      align-self: stretch;
      min-height: 48px;
      text-align: left;
    }

    :root {
      --led-preview-default-cell: 14px;
      --led-preview-max-cell: 22px;
      --cell: var(--led-preview-default-cell);
      --gap: 3px;
    }

    /* 卡片在手机端允许缩到屏幕宽度，不强制320px */
    .card {
      min-width: 0;
    }

    /* 亮度行最小列宽放宽，防止在窄屏溢出 */
    .brightness-row {
      grid-template-columns: minmax(0, 1fr) 68px;
    }

    /* 字段最小宽度放宽 */
    .field {
      min-width: 0;
    }

    /* 滑块步进行允许换行 */
    .slider-step-row {
      flex-wrap: wrap;
    }

    /* 按钮行紧凑按钮最小宽度适配 */
    .slider-step-row .compact-btn {
      min-width: 60px;
    }

    /* 主视觉区域文字防溢出 */
    .hero h2 {
      font-size: 20px;
      word-break: break-word;
    }

    /* 键值区键宽缩减 */
    .kv {
      grid-template-columns: 120px 1fr;
    }
  }

  body[data-page="debug"] {
    overflow-y: auto;
  }

  body[data-page="debug"] .content {
    overflow-y: visible;
    padding-bottom: 40px;
  }

  .debug-layout {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
    align-items: start;
    overflow: visible;
    padding-bottom: 24px;
  }

  .debug-column {
    display: grid;
    gap: 14px;
    align-content: start;
    min-width: 0;
    height: max-content;
  }

  .debug-layout .card {
    min-width: 0;
    width: auto;
    margin: 0;
    overflow: visible;
  }

  .debug-layout .card.stack {
    overflow: visible;
    max-width: none;
  }

  .debug-layout .status-merged {
    max-height: none;
    overflow: visible;
  }

  .debug-layout .row,
  .debug-layout .kv,
  .debug-layout textarea,
  .debug-layout input {
    min-width: 0;
    max-width: 100%;
  }

  .debug-layout .row {
    width: 100%;
  }

  .debug-layout .kv span {
    min-width: 0;
    overflow-wrap: anywhere;
    word-break: break-word;
  }

  .debug-log-card .row input {
    flex: 1 1 260px;
    min-width: 0;
  }

  .debug-log-card .log {
    height: clamp(180px, 30vh, 320px);
    min-height: 180px;
    overflow: auto;
  }

  .debug-measure-grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 14px;
    align-items: start;
    min-width: 0;
  }

  .debug-measure-controls {
    display: grid;
    gap: 10px;
    min-width: 0;
    align-content: start;
  }

  .debug-measure-card .matrix-wrap {
    justify-self: stretch;
    max-width: 100%;
  }

  @media (min-width:1471px) {

    .parts-outer-layout,
    .debug-layout {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }
  }

  @media (max-width:980px) {

    .parts-outer-layout,
    .debug-layout {
      grid-template-columns: 1fr;
    }
  }

  .field {
    display: grid;
    gap: 6px;
    min-width: 120px;
  }

  .field label {
    font-size: 12px;
    color: var(--muted)
  }

  .kv {
    display: grid;
    grid-template-columns: 170px 1fr;
    gap: 8px 10px;
    font-size: 13px;
    align-items: center;
  }

  .kv .k {
    color: var(--muted)
  }

  .mono {
    font-family: var(--ui-font) !important;
  }

  .small {
    font-size: 12px;
    color: var(--muted);
    line-height: 1.45
  }

  .hint {
    font-size: 12px;
    color: #d7e0ee;
    background: #111827;
    border: 1px solid #2c3448;
    border-radius: 12px;
    padding: 10px;
    line-height: 1.5
  }

  .warning {
    display: none;
    border: 1px solid #80621b;
    background: #2b210f;
    color: #ffe5a4;
    border-radius: 12px;
    padding: 9px 10px;
    font-size: 12px;
  }

  .warning.show {
    display: block;
  }

  .color-swatch {
    width: var(--control-height);
    height: var(--control-height);
    flex: 0 0 var(--control-height);
    border-radius: var(--control-radius);
    border: 1px solid rgba(255, 255, 255, .35);
    background: var(--led-color);
    box-shadow: 0 0 24px color-mix(in srgb, var(--led-color) 55%, transparent)
  }

  .color-control-row {
    display: grid;
    grid-template-columns: max-content var(--control-height);
    align-items: end;
    gap: 10px;
    max-width: 100%;
  }

  .color-control-row .color-swatch {
    order: 2;
  }

  .color-control-row .field {
    order: 1;
    min-width: 0;
  }

  .color-control-row #color-input {
    width: calc(7ch + var(--button-padding-x) + var(--button-padding-x) + 2px);
    min-width: calc(7ch + var(--button-padding-x) + var(--button-padding-x) + 2px);
    height: var(--control-height);
    padding: 0 var(--button-padding-x);
    text-align: left;
    font-size: var(--button-font-size);
    font-weight: 700;
    line-height: calc(var(--control-height) - 2px);
    letter-spacing: 0;
    font-variant-numeric: normal;
  }

  .color-dropdown-grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 10px;
    align-items: stretch;
    max-width: 420px;
  }

  .color-dropdown-grid .select-shell {
    min-height: var(--control-height);
  }

  .matrix-wrap {
    overflow: hidden;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    padding: var(--matrix-edge-gap, calc(var(--led-preview-default-cell) * var(--led-preview-edge-ratio)));
    margin: 0;
    border: 0;
    border-radius: 0;
    background: transparent;
    box-shadow: none;
    box-sizing: border-box;
    --matrix-default-cell: var(--led-preview-default-cell);
    --matrix-min-cell: var(--led-preview-min-cell);
    --matrix-max-cell: var(--led-preview-max-cell);
    --matrix-max-height: var(--led-preview-max-height);
    --matrix-edge-gap: calc(var(--led-preview-default-cell) * var(--led-preview-edge-ratio));
  }

  .matrix-wrap.fill-column {
    display: grid;
    place-items: center;
    width: 100%;
    min-width: 0;
    min-height: 0;
  }

  .led-preview-card {
    min-inline-size: min(var(--led-preview-min-width), 100%);
    display: flex;
    flex-direction: column;
    align-items: stretch;
    height: auto;
    max-height: var(--led-preview-max-height);
    overflow: hidden;
  }

  .led-preview-card>h3 {
    flex: 0 0 auto;
  }

  .led-preview-card .matrix-wrap {
    flex: 0 1 auto;
    min-height: 0;
  }

  .led-preview-card .matrix-wrap.fill-column {
    width: 100%;
  }

  .debug-measure-card {
    min-inline-size: min(var(--led-preview-min-width), 100%);
    max-height: none;
    overflow: visible;
  }

  .debug-measure-card .debug-measure-grid {
    min-height: 0;
  }

  .debug-measure-card .matrix-wrap {
    border: 0;
    background: transparent;
    box-shadow: none;
    overflow: hidden;
    min-height: 0;
    --matrix-max-height: 360px;
  }

  .matrix {
    display: grid;
    grid-template-columns: repeat(22, var(--cell));
    grid-template-rows: repeat(18, var(--cell));
    gap: var(--gap);
    width: fit-content;
    max-width: 100%;
    margin: 0 auto;
    touch-action: pan-y;
    user-select: none;
    -webkit-user-select: none;
    box-sizing: border-box;
    will-change: contents;
  }

  .led {
    width: var(--cell);
    height: var(--cell);
    box-sizing: border-box;
    border-radius: max(2px, calc(var(--cell) * .28));
    background: #202635;
    border: 1px solid #30394c;
    box-shadow: inset 0 0 3px #000;
  }

  .led.on {
    background: var(--led-color);
    border-color: color-mix(in srgb, var(--led-color) 75%, #fff);
    box-shadow: 0 0 10px color-mix(in srgb, var(--led-color) 80%, transparent), inset 0 0 4px #fff8;
  }

  .led.invalid {
    visibility: hidden;
    pointer-events: none;
  }

  .led.editable {
    cursor: pointer;
  }

  .matrix.editable-matrix {
    touch-action: manipulation;
  }

  .part-list {
    display: flex;
    flex-wrap: nowrap;
    gap: 8px;
    max-height: none;
    overflow-x: auto;
    overflow-y: hidden;
    padding: 8px 8px 12px;
    scrollbar-width: thin;
  }

  .part-card {
    display: grid;
    grid-template-columns: 1fr;
    grid-template-rows: auto auto;
    gap: 5px;
    justify-items: center;
    align-items: center;
    text-align: center;
    padding: 0 !important;
    border: 0 !important;
    background: transparent !important;
    border-radius: 0 !important;
    min-width: 60px;
    width: 60px;
    max-width: 60px;
    min-height: 0 !important;
    overflow: visible;
    flex: 0 0 60px;
    box-shadow: none !important;
  }

  .part-card:hover:not(:disabled) {
    --button-hover-y: -1px;
    border-color: transparent !important;
    background: transparent !important;
  }

  .part-card:hover:not(:disabled) .part-mini {
    border-color: var(--button-hover-color);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--button-hover-color) 34%, transparent), 0 0 14px color-mix(in srgb,
      var(--button-hover-color) 22%, transparent);
  }

  .part-card.active {
    border: 0 !important;
    background: transparent !important;
    box-shadow: none !important;
  }

  .part-card.active .part-mini {
    border-color: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 35%, transparent), 0 0 16px color-mix(in srgb, var(--accent) 25%, transparent);
  }

  .part-card .part-meta {
    min-width: 0;
    overflow: visible;
    display: grid;
    place-items: center;
    gap: 0;
    align-content: center;
    line-height: 1;
  }

  .part-card .part-display-id {
    display: block;
    font-size: 16px;
    line-height: 1.05;
    font-weight: 700;
    white-space: nowrap;
    overflow: visible;
    text-overflow: clip;
    margin: 0;
    padding: 0;
  }

  .part-card .small {
    display: none !important;
  }

  .part-mini {
    display: grid;
    grid-template-columns: repeat(8, 5px);
    grid-template-rows: repeat(8, 5px);
    gap: 1px;
    background: #07090d;
    padding: 5px;
    border-radius: 8px;
    border: 1px solid #2b3344;
    flex: 0 0 58px;
    width: 58px;
    height: 58px;
    align-content: center;
    justify-content: center;
    box-sizing: border-box;
    overflow: visible;
  }

  .pix {
    width: 5px;
    height: 5px;
    border-radius: 1px;
    background: #18202d;
  }

  .pix.on {
    background: var(--led-color);
    box-shadow: 0 0 6px var(--led-color)
  }

  .list {
    display: grid;
    gap: 8px;
  }

  .face-manager-panel {
    container-type: inline-size;
    --face-control-size: var(--control-height);
  }

  .face-library-list {
    overscroll-behavior: contain;
  }

  .saved-row {
    display: grid;
    grid-template-columns: 42px minmax(0, 1fr);
    gap: 8px;
    align-items: stretch;
  }

  .saved-index {
    display: flex;
    align-items: center;
    justify-content: center;
    border: 0;
    background: transparent;
    border-radius: 0;
    color: #dbe7f5;
    font-size: 20px;
    line-height: 1;
    font-weight: 900;
    font-variant-numeric: tabular-nums;
  }

  .list-item {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 10px;
    align-items: center;
    border: 1px solid var(--line);
    background: #10141d;
    border-radius: 12px;
    padding: 10px;
    min-width: 0;
  }

  .saved-face-card {
    grid-template-columns: auto minmax(0, 1fr);
    grid-template-areas: "drag body" "drag actions";
    gap: 8px 10px;
  }

  .saved-face-card>.drag-handle {
    grid-area: drag;
  }

  .saved-face-card>.saved-face-body {
    grid-area: body;
  }

  .saved-face-card>.face-action-bar {
    grid-area: actions;
  }

  .saved-face-body {
    min-width: 0;
  }

  .face-action-bar {
    display: flex;
    gap: 5px;
    align-items: center;
    flex-wrap: nowrap;
    flex-shrink: 1;
    min-width: 0;
    width: 100%;
    padding: 2px 0;
    overflow-x: auto;
    overflow-y: visible;
    scrollbar-width: none;
  }

  .face-action-bar::-webkit-scrollbar {
    display: none;
  }

  .face-action-bar button {
    min-height: var(--control-height);
    padding: var(--button-padding-y) var(--button-padding-x);
    font-size: var(--button-font-size);
    line-height: var(--control-line-height);
    border-radius: var(--button-radius);
    white-space: nowrap;
  }

  .face-action-bar .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    width: var(--face-control-size);
    height: var(--face-control-size);
    min-width: var(--face-control-size);
    min-height: var(--face-control-size);
    padding: 0;
    font-size: var(--button-font-size);
    border-radius: var(--button-radius);
    flex: 0 0 var(--face-control-size);
    box-sizing: border-box;
  }

  .face-action-bar .btn-apply {
    --button-hover-color: #ffe36e;
    margin-left: auto;
  }

  .face-action-bar .btn-delete {
    --button-hover-color: #ff7890;
    border-color: #7b2b3b;
    color: #ffd0d8;
    background: #3a1820;
  }

  .face-action-bar .btn-delete:active:not(:disabled) {
    background: #5a1a24;
  }

  .face-action-bar button:disabled {
    opacity: .38;
    pointer-events: none;
  }

  .saved-row.drag-over .list-item {
    border-color: var(--accent2);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent2) 20%, transparent);
  }

  .saved-row.active .list-item {
    border-color: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 28%, transparent), 0 0 18px color-mix(in srgb, var(--accent) 16%, transparent);
  }

  .drag-handle {
    align-self: start;
    width: var(--face-control-size);
    height: var(--face-control-size);
    min-width: var(--face-control-size);
    min-height: var(--face-control-size);
    padding: 0;
    cursor: grab;
    color: #dbe7f5;
    background: var(--panel2);
    border-radius: var(--button-radius);
    touch-action: none;
    user-select: none;
    -webkit-user-select: none;
    display: flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    flex: 0 0 var(--face-control-size);
  }

  .drag-handle::before {
    content: "";
    display: block;
    width: 18px;
    height: 12px;
    background: linear-gradient(to bottom, currentColor 0 2px, transparent 2px 5px, currentColor 5px 7px, transparent 7px 10px, currentColor 10px 12px);
    border-radius: 1px;
  }

  .drag-handle:active {
    cursor: grabbing;
  }

  .saved-row.dragging .list-item {
    opacity: .9;
    border-color: var(--accent);
  }

  .saved-name-input {
    width: 100%;
    height: var(--control-height);
    min-height: var(--control-height);
    padding: var(--control-padding-y) var(--control-padding-x);
    border-radius: var(--control-radius);
    font-size: var(--control-font-size);
    line-height: var(--control-line-height);
    font-weight: inherit;
    background: #0c0f15;
  }

  .saved-meta {
    margin-top: 4px;
  }

  .face-source-badge {
    display: inline-flex;
    align-items: center;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 3px 8px;
    font-size: 12px;
    font-weight: 800;
    background: #111827;
    color: #d9e4f2;
    white-space: nowrap;
  }

  .face-source-badge.default {
    border-color: #7a6220;
    color: #ffe3a1;
    background: #2b210f;
  }

  .face-source-badge.custom {
    border-color: #216b3f;
    color: #b8ffd4;
    background: #163824;
  }

  .face-source-badge.parts {
    border-color: #4f3a87;
    color: #ded1ff;
    background: #211838;
  }

  .saved-name-input[readonly] {
    opacity: .85;
    cursor: not-allowed;
    border-style: dashed;
  }

  .log {
    height: 270px;
    overflow: auto;
    background: #070a0f;
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 10px;
    font-family: var(--ui-font);
    font-size: 16px;
    white-space: pre-wrap;
    color: #b8c5d6;
  }

  .scroll-upload-progress {
    display: grid;
    gap: 6px;
  }

  .scroll-upload-progress[hidden] {
    display: none;
  }

  .scroll-upload-progress progress {
    width: 100%;
    height: 14px;
    accent-color: var(--accent);
    border: 1px solid var(--line);
    border-radius: 999px;
    background: #0b0e14;
    overflow: hidden;
  }

  .scroll-upload-progress progress::-webkit-progress-bar {
    background: #0b0e14;
    border-radius: 999px;
  }

  .scroll-upload-progress progress::-webkit-progress-value {
    background: var(--primary-gradient);
    border-radius: 999px;
  }

  .scroll-upload-progress progress::-moz-progress-bar {
    background: var(--accent);
    border-radius: 999px;
  }

  .scroll-upload-label {
    font-size: 12px;
    color: var(--muted);
    line-height: 1.35;
  }

  .status-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--ok);
    display: inline-block;
    box-shadow: 0 0 10px var(--ok)
  }

  .status-dot.dim {
    background: var(--muted);
    box-shadow: none;
  }

  .status-dot.warn {
    background: #f59e0b;
    box-shadow: 0 0 8px #f59e0b;
  }

  .status-dot.danger {
    background: #ef4444;
    box-shadow: 0 0 8px #ef4444;
  }

  @media (min-width:981px) {
    .matrix-wrap {
      --matrix-max-height: var(--led-preview-max-height);
    }
  }

  @container (max-width:560px) {
    .saved-row {
      grid-template-columns: 38px minmax(0, 1fr);
      gap: 8px;
    }

    .saved-index {
      font-size: 18px;
    }

    .saved-face-card {
      grid-template-columns: var(--face-control-size) minmax(0, 1fr);
      grid-template-areas: "drag body" "actions actions";
      gap: 8px;
    }

    .saved-face-card>.drag-handle {
      grid-area: drag;
      width: var(--face-control-size);
      height: var(--face-control-size);
    }

    .saved-face-card>.saved-face-body {
      grid-area: body;
    }

    .saved-face-card>.face-action-bar {
      grid-area: actions;
      width: 100%;
    }

    .saved-face-card>.face-action-bar .icon-btn {
      width: var(--face-control-size);
      min-width: var(--face-control-size);
    }

    .saved-face-card .saved-meta {
      display: none;
    }

    .saved-name-input {
      min-height: var(--control-height);
    }
  }

  @media (max-width:520px) {
    .kv {
      grid-template-columns: 1fr
    }

    .color-dropdown-grid {
      grid-template-columns: 1fr
    }

    .equal-fields {
      grid-template-columns: repeat(2, minmax(0, 1fr))
    }

    .brightness-row {
      grid-template-columns: minmax(0, 1fr) 64px;
      gap: 8px
    }

    .slider-step-row {
      gap: 8px
    }

    :root {
      --led-preview-default-cell: 12px;
      --cell: var(--led-preview-default-cell);
      --gap: 2px;
    }
  }

  @media (hover:none),
  (pointer:coarse) {

    button:hover:not(:disabled):not(.is-pressing),
    .brand-nav-toggle:hover:not(:disabled):not(.is-pressing),
    .select-toggle:hover:not(:disabled):not(.is-pressing),
    .nav button:hover:not(:disabled):not(.is-pressing),
    .select-option:hover:not(:disabled):not(.is-pressing),
    .part-card:hover:not(:disabled):not(.is-pressing) {
      --button-hover-y: 0px;
    }

    button:hover:not(:disabled):not(.is-pressing):not(.active) {
      border-color: var(--line);
      box-shadow: none;
    }

    button.primary:hover:not(:disabled):not(.is-pressing):not(.active) {
      border-color: transparent;
      background: var(--primary-gradient);
    }

    button.ok:hover:not(:disabled):not(.is-pressing):not(.active) {
      border-color: #216b3f;
      background: #163824;
    }

    button.danger:hover:not(:disabled):not(.is-pressing):not(.active) {
      border-color: #7b2b3b;
      background: #3a1820;
    }

    .brand-nav-toggle:hover:not(:disabled):not(.is-pressing):not(.active) {
      background: linear-gradient(180deg, #1a2030, #111722);
      box-shadow: 0 12px 30px #00000035;
    }

    .select-toggle:hover:not(:disabled):not(.is-pressing) {
      background: #141926;
      border-color: var(--line);
      box-shadow: 0 12px 30px #00000035;
    }

    .select-shell:hover .select-caret {
      color: var(--muted);
    }

    .select-shell:focus-within .select-caret {
      color: var(--accent2);
    }

    .nav button:hover:not(:disabled):not(.is-pressing):not(.active),
    .select-option:hover:not(:disabled):not(.is-pressing):not(.active) {
      background: #111520;
      border-color: var(--line);
      box-shadow: 0 8px 22px #00000028;
    }

    .nav.open button.active:hover:not(:disabled):not(.is-pressing),
    .nav button.active:hover:not(:disabled):not(.is-pressing) {
      background: var(--primary-gradient);
      border-color: transparent;
      box-shadow: none;
      color: #fff;
    }

    .part-card:hover:not(:disabled):not(.is-pressing):not(.active) .part-mini {
      border-color: var(--line);
      box-shadow: none;
    }

    .part-card.active:hover:not(:disabled):not(.is-pressing) .part-mini {
      border-color: var(--accent);
      box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 35%, transparent), 0 0 16px color-mix(in srgb, var(--accent) 25%, transparent);
    }
  }

  @media (max-width:640px) {
    :root {
      --control-height: 40px;
      --control-font-size: 14px;
      --control-padding-y: 8px;
      --control-padding-x: 11px;
      --control-compact-padding-x: 10px;
    }

    .part-list {
      display: flex;
      flex-wrap: nowrap
    }

    .part-card {
      grid-template-columns: 1fr;
      width: 60px;
      min-width: 60px;
      max-width: 60px;
    }
  }

  /* ── 320px 最小宽度适配：确保所有元素在最窄屏幕下正常显示 ── */

  @media (max-width:400px) {

    /* 在接近320px时进一步压缩 */
    .content {
      padding: 6px;
    }

    :root {
      --sidebar-padding-y: 8px;
      --sidebar-padding-x: 8px;
    }

    .sidebar {
      padding: var(--sidebar-padding-y) var(--sidebar-padding-x);
    }

    .card {
      padding: 10px;
      border-radius: 14px;
    }

    .kv {
      grid-template-columns: 1fr;
      gap: 4px 0;
    }

    .kv .k {
      font-weight: 700;
    }

    .hero,
    .hero>div:first-child {
      min-height: 44px;
    }

    .hero h2 {
      font-size: 18px;
    }

    .brand h1 {
      font-size: 14px;
    }

    /* 按钮组允许换行 */
    .mode-button-row {
      gap: 6px;
    }

    .mode-button-row button {
      padding: var(--control-padding-y) var(--control-padding-x);
    }

    .button-row {
      gap: 6px;
    }

    /* 行内元素换行 */
    .row {
      gap: 6px;
    }

    /* 表单控件高度紧凑 */

    /* 亮度行保持滑动条 + 短数字框双列 */
    .brightness-row {
      grid-template-columns: minmax(0, 1fr) 64px;
      gap: 8px;
    }

    .brightness-row .slider-number {
      text-align: center;
    }

    /* 等宽字段保持双列但允许缩 */
    .equal-fields {
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 6px;
    }

    /* 颜色下拉网格确保不超出 */
    .color-dropdown-grid {
      max-width: 100%;
    }

    /* 日志高度压缩 */
    .log {
      height: 180px;
    }

    /* 矩阵单元格缩小 */
    :root {
      --control-height: 36px;
      --control-font-size: 13px;
      --control-padding-y: 6px;
      --control-padding-x: 9px;
      --control-compact-padding-x: 8px;
      --led-preview-default-cell: 10px;
      --cell: var(--led-preview-default-cell);
      --gap: 2px
    }
  }

  :root {
    --rina-icon-size: 96px;
    --rina-avatar-frame-width: 5px;
    --rina-avatar-size: calc(var(--rina-icon-size) + var(--rina-avatar-frame-width) * 2);
    --rina-halo-spread: 18px;
    --rina-halo-size: calc(var(--rina-avatar-size) + var(--rina-halo-spread) * 2);
    --rina-icon-pop-scale: 1.22;
    --rina-icon-shrink-scale: 1.12;
    --rina-icon-release-scale: 2.35;
    --rina-halo-contract-scale: 0.65;
    --rina-halo-contract-duration: 300ms;
    --rina-image-pop-duration: 420ms;
    --rina-image-release-duration: 1300ms;
    --rina-blur-size: 14px;
    --rina-loader-x: 50vw;
    --rina-loader-y: 50vh;
    --rina-reveal-solid: 0px;
    --rina-reveal-a: 0px;
    --rina-reveal-b: 0px;
    --rina-reveal-c: 0px;
    --rina-reveal-d: 0px;
    --rina-reveal-e: 0px;
    --rina-reveal-outer: 0px;
    --rina-reveal-x: 50%;
    --rina-reveal-y: 50%;
  }

  .loading-overlay {
    position: fixed;
    inset: 0;
    z-index: 2147483000;
    display: block;
    overflow: hidden;
    pointer-events: auto;
    opacity: 1;
    background: transparent;
  }

  .loading-overlay.is-animating .flash-halo,
  .loading-overlay.is-animating .avatar-circle,
  .loading-overlay.is-animating .avatar-before,
  .loading-overlay.is-animating .avatar-after {
    will-change: transform, opacity;
    backface-visibility: hidden;
  }

  .loading-overlay.is-animating .blur-screen {
    will-change: mask-image, -webkit-mask-image, opacity;
    transform: translateZ(0);
  }

  .blur-screen {
    position: absolute;
    inset: 0;
    z-index: 1;
    background: transparent;
    backdrop-filter: blur(var(--rina-blur-size));
    -webkit-backdrop-filter: blur(var(--rina-blur-size));
    opacity: 1;
    pointer-events: none;
    will-change: opacity, -webkit-mask-image, mask-image;
  }

  .blur-screen.is-revealing {
    -webkit-mask-image: radial-gradient(circle at var(--rina-reveal-x) var(--rina-reveal-y), transparent 0,
      transparent var(--rina-reveal-solid), rgba(0, 0, 0, .03) var(--rina-reveal-a), rgba(0, 0, 0,
      .10) var(--rina-reveal-b), rgba(0, 0, 0, .26) var(--rina-reveal-c), rgba(0, 0, 0, .52) var(--rina-reveal-d),
      rgba(0, 0, 0, .78) var(--rina-reveal-e), #000 var(--rina-reveal-outer), #000 100%);
    mask-image: radial-gradient(circle at var(--rina-reveal-x) var(--rina-reveal-y), transparent 0,
      transparent var(--rina-reveal-solid), rgba(0, 0, 0, .03) var(--rina-reveal-a), rgba(0, 0, 0,
      .10) var(--rina-reveal-b), rgba(0, 0, 0, .26) var(--rina-reveal-c), rgba(0, 0, 0, .52) var(--rina-reveal-d),
      rgba(0, 0, 0, .78) var(--rina-reveal-e), #000 var(--rina-reveal-outer), #000 100%);
    -webkit-mask-repeat: no-repeat;
    mask-repeat: no-repeat;
    -webkit-mask-size: 100% 100%;
    mask-size: 100% 100%;
  }

  .loading-overlay.is-hidden {
    opacity: 0;
    pointer-events: none;
  }

  .loading-overlay.is-scroll-passthrough {
    pointer-events: none;
  }

  .loading-box {
    position: fixed;
    left: var(--rina-loader-x);
    top: var(--rina-loader-y);
    transform: translate(-50%, -50%);
    z-index: 20;
    display: grid;
    place-items: center;
    gap: 20px;
    opacity: 1;
    transition: opacity 120ms ease;
  }

  .loading-overlay.is-assets-pending .loading-box {
    opacity: 0;
  }

  .loader-stage {
    position: relative;
    z-index: 0;
    isolation: isolate;
    width: var(--rina-halo-size);
    height: var(--rina-halo-size);
    display: grid;
    place-items: center;
    overflow: visible;
  }

  .avatar-circle {
    position: relative;
    z-index: 200;
    width: var(--rina-avatar-size);
    height: var(--rina-avatar-size);
    overflow: hidden;
    border-radius: 50%;
    background: #fff;
    box-shadow: none;
    opacity: 1;
    transform: scale(1);
    transition: transform var(--rina-image-pop-duration) cubic-bezier(.16, 1.25, .3, 1), opacity 260ms cubic-bezier(.4, 0, .2, 1);
    will-change: transform, opacity;
  }

  .avatar-circle::before {
    display: none;
  }

  .avatar-circle img {
    position: absolute;
    left: 0;
    top: 0;
    display: block;
    width: var(--rina-avatar-size);
    height: var(--rina-avatar-size);
    object-fit: contain;
    object-position: center center;
    border-radius: 50%;
    user-select: none;
    -webkit-user-drag: none;
    pointer-events: none;
    transform: scale(1);
    transition: transform var(--rina-image-pop-duration) cubic-bezier(.16, 1.25, .3, 1), opacity 180ms ease;
  }

  .avatar-before {
    z-index: 220;
    opacity: 1;
  }

  .avatar-after {
    z-index: 230;
    opacity: 0;
  }

  .loading-overlay.is-image-pop .avatar-circle {
    transform: scale(var(--rina-icon-pop-scale));
    box-shadow: none;
  }

  .loading-overlay.is-image-pop .avatar-before {
    opacity: 0;
    transform: scale(1.025);
    transition: opacity 0s linear 180ms, transform var(--rina-image-pop-duration) cubic-bezier(.16, 1.25, .3, 1);
  }

  .loading-overlay.is-image-pop .avatar-after {
    opacity: 1;
    transform: scale(1.025);
  }

  .loading-overlay.is-final-release .avatar-circle {
    animation: rinaBoot-avatarShrinkThenRelease var(--rina-image-release-duration) forwards;
  }

  .flash-halo {
    position: absolute;
    inset: 0;
    z-index: 10;
    width: var(--rina-halo-size);
    height: var(--rina-halo-size);
    border-radius: 50%;
    pointer-events: none;
    opacity: .28;
    transform: scale(.965);
    transform-origin: center center;
    backface-visibility: hidden;
    background: radial-gradient(circle at 50% 50%, transparent 0, transparent calc(50% - var(--rina-halo-spread)),
      rgba(255, 255, 255, 0) calc(50% - var(--rina-halo-spread)), rgba(255, 255, 255,
      .55) calc(50% - var(--rina-halo-spread) + 3px), rgba(249, 113, 212, .72) calc(50% - var(--rina-halo-spread) + 7px),
      rgba(249, 113, 212, .40) calc(50% - var(--rina-halo-spread) + 12px), rgba(249, 113, 212,
      .13) calc(50% - var(--rina-halo-spread) + 17px), transparent 100%);
    filter: blur(2.4px) drop-shadow(0 0 10px rgba(249, 113, 212, .36));
    animation: rinaBoot-pulseRingBreath 1.62s cubic-bezier(.42, 0, .58, 1) infinite both;
    transition: opacity var(--rina-halo-contract-duration) cubic-bezier(.4, 0, .2, 1),
      transform var(--rina-halo-contract-duration) cubic-bezier(.55, .085, .68, .53),
      filter var(--rina-halo-contract-duration) cubic-bezier(.4, 0, .2, 1);
    will-change: transform, opacity;
  }

  .loading-overlay.is-ring-contracting .flash-halo {
    animation: rinaBoot-haloContractOut var(--rina-halo-contract-duration) cubic-bezier(.55, .085, .68, .53) forwards;
  }

  .loading-overlay.is-halo-hidden .flash-halo {
    visibility: hidden;
    opacity: 0;
    transform: scale(0);
    filter: blur(0);
    animation: none;
    transition: none;
  }

  .loading-text {
    color: rgba(249, 200, 240, .85);
    font-size: 15px;
    font-weight: 700;
    letter-spacing: .12em;
    text-transform: uppercase;
    transition: opacity 220ms ease, transform 220ms ease;
  }

  .loading-overlay.is-ring-contracting .loading-text {
    opacity: 0;
    transform: translateY(6px);
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

  .boot-reveal-item {
    visibility: hidden;
    opacity: 0;
    transform: translateY(10px);
    transition: opacity 320ms ease, transform 360ms cubic-bezier(.16, 1, .3, 1);
  }

  html[data-first-page-reveal="preparing"] .boot-reveal-item {
    transition: none;
  }

  .boot-reveal-item.is-revealed {
    visibility: visible;
    opacity: 1;
    transform: translateY(0);
  }

  @media(prefers-reduced-motion:reduce) {
    .flash-halo {
      animation-duration: 2.6s;
    }

    .boot-reveal-item {
      transition-duration: 1ms;
      transform: none;
    }
  }

  html[data-boot-phase="preload"] body>*:not(.loading-overlay) {
    visibility: hidden;
    pointer-events: none;
  }
~~~~


### 15.10 重建验收清单

- `plan.md` 必须能说明所有文件、资源、路由、状态、动画、布局和 JS 功能；不能依赖聊天上下文。
- 从本规格重建的项目必须能通过 PlatformIO `esp32s3` 环境编译。
- 首次进入 AP 页面时 loading overlay 必须完成资源预加载、status ping、首屏 progressive reveal、延迟加载 debug/parts/scroll 资源。
- WebUI 必须在 320px 视宽下无水平破坏性裁切；LED cell 可以缩小，但任何 LED 不得被边框 cutoff。
- custom/parts/basic/debug/scroll 五页所有按钮、输入、拖拽、上传、保存、API 同步逻辑必须可用。
- Firmware 在 Wi-Fi AP-only、DNS captive portal、LittleFS 静态资源、API routes、LED render、buttons、power monitor、storage 原子写入方面必须符合第 15.6/15.7 和源代码片段。
