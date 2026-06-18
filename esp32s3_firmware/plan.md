# Rina-Chan Board Master Plan

> Consolidated on 2026-06-18 from all project Markdown files in this repository. This file is the canonical planning, requirements, architecture, refactor, bug, and test document for the ESP32-S3 Rina-Chan board firmware and WebUI.
>
> Scope rule: when new Markdown notes are created, fold their durable project knowledge back into this file and remove or archive temporary duplicates when appropriate.

## 0. Consolidation Status

This `plan.md` intelligently integrates the repository Markdown inventory instead of appending files in raw discovery order. The original `plan.md` specification is preserved in full under Section 2 so legacy requirements are not lost, while newer project reports are grouped by meaning:

- Architecture, runtime flow, API ownership, and data flow are grouped in Section 3.
- Audit findings, known bugs, and verified risks are grouped in Section 4.
- Broad firmware/WebUI refactor work is grouped in Section 5.
- Scroll-session refactor design, audit corrections, stage status, and the latest step-direction decision are grouped in Section 6.
- Automated WebUI/firmware test coverage is grouped in Section 7.
- Serial-console, structured logging, GPIO emulation, and no-Wi-Fi automation planning are grouped in Section 8.
- Page 6.5 diagnostics/debug-console rewrite planning is grouped in Section 9.
- Font/resource tooling notes are grouped in Section 10.
- Archive notes and historical retained context are grouped in Section 11.
- Ongoing maintenance rules for this master plan are grouped in Section 12.

### Integrated Markdown Sources

- `plan.md` (previous canonical specification, preserved)
- `ARCHITECTURE_REPORT.md`
- `AUDIT_REPORT.md`
- `refactor_plan.md`
- `SCROLL_SESSION_REFACTOR_PLAN.md`
- `SCROLL_SESSION_REFACTOR_AUDIT.md`
- `SCROLL_WEBUI_TEST_PLAN.md`
- `SERIAL_TEST_CONSOLE_PLAN.md`
- `PAGE_6_5_DEBUG_REWRITE_PLAN.md`
- `data/resources/fonts/README.md`
- `tools/font_fusion/README.md`
- `archive/NOTES.md`

Excluded generated/dependency areas remain excluded by policy: `.git/`, `node_modules/`, PlatformIO build output, cache folders, and generated package/license files unless they contain project-specific planning information.

The previous `plan.md` may contain older merge-ledger notes inside the preserved legacy section. Those are historical context only; the inventory and section mapping above are the current authoritative consolidation status.

## 1. Canonical Project Summary

The Rina-Chan board is an ESP32-S3 firmware and WebUI project for a 370-LED display board. The project combines firmware animation/rendering, Wi-Fi/WebServer control, persistent face/scroll settings, a browser-based WebUI, font/asset tooling, and hardware-specific button/LED behavior.

### Primary Product Surfaces

- ESP32-S3 firmware controls LED rendering, face animation, scroll text, battery overlay behavior, buttons, Wi-Fi, and HTTP APIs.
- WebUI in `data/` controls faces, scroll text, debug/diagnostic views, and animation settings through firmware API routes.
- SPIFFS/LittleFS-style web assets and generated font data are deployed through the upload script and PlatformIO tasks.
- Hardware validation relies on the physical board, direct `/api/*` probes, and browser automation against the AP-hosted WebUI.

### Durable Decisions and Constraints

- Scroll sessions now have explicit session-style ownership: browser edits are staged locally, while firmware state remains authoritative after explicit sync/apply paths.
- `FW_SYNC` is the authority mode for reloading WebUI state from firmware.
- Browser draft state must not silently overwrite firmware state during unrelated refreshes.
- Battery-overlay pause must remain composable with user pause: a battery pause cannot accidentally clear a user-initiated pause.
- Step-direction controls are visual text movement controls, not numeric frame-index controls. Increasing `scrollFrameIndex` increases the source bitmap offset, so the rendered text appears to move left. Decreasing `scrollFrameIndex` makes the whole text appear to move right. Therefore the left arrow sends `+1` and the right arrow sends `-1`. Future code, comments, and tests must preserve this user-facing visual contract and must not reclassify it as a bug because the frame number moves in the opposite direction.
- `/api/status` is the standard reachability probe. A healthy connected board responds with JSON including `ok: true` and `device: "RinaChanBoard"`.
- Uploads should use the repository upload script when requested, especially `run_rinachan_unifont.ps1` for firmware/filesystem workflows.

### Standard Validation Gates

- Firmware compile: `pio run`
- Filesystem build: `pio run -t buildfs`
- Web asset syntax checks where applicable, especially `node --check data/app.js`
- Device status probe: `GET http://192.168.4.1/api/status` while connected to the board AP
- WebUI smoke testing against the physical board for scroll, face, diagnostics, and persistence workflows

## 2. Legacy Core Specification from Previous plan.md

_Source: previous `plan.md`, preserved in full to avoid losing requirements, TODOs, constants, API notes, firmware/WebUI details, and historical decisions._

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
- `data/styles.css` 负责全部视觉、布局、动画和字体声明。GNU Unifont 备用字体现在是**独立 LittleFS 文件** `/resources/fonts/unifont.woff2`（带缓存破坏 query，例如 `?v=17.0.04-webui`），其 `@font-face` 通过 `url()` 引用该文件、`font-display:block`；**不再以内联 `data:font/woff2;base64,...` 形式写在 CSS 内**（历史上曾内联，已于本次改为独立文件）。`index.html` 在 `<head>` 用 `<link rel="preload" as="font" type="font/woff2" crossorigin>` 把它作为第一个资源最先加载。文字滚动字体 Ark Pixel 浏览器字体 `/resources/fonts/ark12.woff2` 同样以独立文件注册（带缓存破坏 query，例如 `?v=20260612-emoji-input-v3`，该 token 每次发布会变化）；早期的 `ark12_fallback.woff2` 回退/别名注册已移除，对应文件也已从项目中删除。生成/校验链见 `tools/build_unifont_webui_subset_from_png.py` 的 `--external-css` / `--external-href` 模式与 `run_rinachan_unifont.*` 的 standalone 校验。
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

## 3. Architecture and Data Flow

### Repository Architecture Report

_Source: `ARCHITECTURE_REPORT.md`_

> Project: **RinaChanBoard 370 V2** — ESP32-S3 firmware driving a 370-pixel WS2812 LED face matrix, with a captive-portal WebUI for control, editing, and diagnostics.
> Method: every file under `src/` and `data/` was read in full; build config, scripts, resources and the existing `AUDIT_REPORT.md` were read; claims below cite concrete files, functions, and line-level behavior. Build artifacts under `.pio/` and font-tooling under `tools/`, `archive/`, `scripts/` were inspected for runtime relevance only.

---

## 1. Executive Summary

This is a **two-process system joined by a single-threaded HTTP/JSON API over a SoftAP**:

1. **Firmware** (C++/Arduino, `src/*.cpp`) on an ESP32-S3. It owns the LED hardware, buttons, battery ADC, persistent storage (LittleFS), and a `WebServer` on port 80. It is the **source of truth for hardware state**: current frame, brightness, color, mode (manual/auto), auto-playback index, firmware text-scroll playback, and battery.
2. **WebUI** (vanilla JS, `data/app.js` ~10.8k lines + `data/index.html` + `data/styles.css`) served from LittleFS. It is a **rich client that mirrors and re-derives firmware state**, renders local LED previews, edits/saves faces, and generates text-scroll frame sequences which it uploads to firmware RAM.

The architecture style is best described as **"firmware-authoritative state with an optimistic, self-correcting browser mirror."** The browser issues commands and frames through two rate-limited queues, then reconciles by polling `/api/status` and merging the response through one central function, `applyFirmwareRuntimeState()` (`app.js:4586`). Almost every firmware mutation bumps a monotonic `stateVersion` (`state.cpp:150 touchRuntimeState`), and the browser polls with `?since=<version>` for cheap "unchanged" short-circuits (`web_api.cpp:460`).

Concurrency on the firmware is **two-core**: Core 0 runs a cooperative super-loop (HTTP, DNS, buttons, power, frame queue, auto-playback, deferred restores) and Core 1 runs a dedicated **LED render/scroll task** (`scroll.cpp:scrollRenderTask`). Four FreeRTOS mutexes (`sync.cpp`) plus three `portMUX` spinlocks (`sPowerStatusMux` in `power_monitor.cpp`, `sAnimMux` in `button_animations.cpp`, `ledRenderRequestMux` in `led_renderer.cpp:12`) guard the shared `RuntimeStore` singleton (`state.h`).

The most important and most fragile subsystem is **text scrolling** (Phase 6.4): it spans a hand-rolled streaming JSON parser, a chunked timeline-upload protocol with `timelineId`/`chunkIndex` integrity rules, a PSRAM frame cache, an independent Core-1 playback timer, and a browser-side preview that re-generates frames from source text and tries to re-sync by frame index. This is where the highest desynchronization risk lives.

**Notable findings up front:**
- `applyPackedFrame()` (the non-immediate queued variant, `led_renderer.cpp:357`) is **dead code** — declared and defined, never called.
- `DEFAULT_STARTUP_FACE_ID = "face_07_triangle_eyes_frown"` (`app.js`, from `WEBUI_CONFIG.faces.startupFaceId`) is **stale/incorrect**: no such face id exists (face_07 is `face_07_wide_eyebrows_tiny_mouth`; the real startup default is `face_08_triangle_eyes_frown`). It is masked by fallback logic, so it currently causes no visible bug.
- The repo's own `AUDIT_REPORT.md` lists three bugs (C1 array overflow, M1 nested spinlocks, L1 `lastReason` truncation) that the **current source already fixes** — the audit doc is stale relative to the code.
- `updateBatteryCalibration()` (`power_monitor.cpp:170`) is intentionally a **no-op** (auto min/max calibration disabled); only manual reset commands move the calibration window.
- The browser scroll preview runs a **free-running local timer** independent of firmware frame advance, so the on-screen preview and the physical LEDs can drift during active playback (acknowledged design limitation).

---

## 2. Repository Map

### 2.1 Firmware source (`src/`) — runs on ESP32-S3

| Path | Type | Purpose | Key symbols | Used by |
|---|---|---|---|---|
| `src/main.cpp` | firmware entry | `setup()` init order + Core-0 cooperative `loop()` | `setup`, `loop`, `g_syncReady` | boot |
| `src/config.h` | firmware config | All compile-time constants: pins, matrix layout, timings, limits, paths | `LED_PIN`, `LED_COUNT=370`, `ROW_LENGTHS/OFFSETS`, `M370_HEX_CHARS=93`, `MAX_SCROLL_FRAMES=3072`, battery cal | everything |
| `src/config.cpp` | firmware config | Defines the 3 AP `IPAddress` constants | `AP_IP_ADDR`, `AP_GATEWAY_ADDR`, `AP_SUBNET_MASK` | `web_api` |
| `src/state.h` / `state.cpp` | shared state | `RuntimeStore` singleton; `RuntimeState`, `ScrollTimelineMeta`, `RuntimeFace`, `FrameStateSnapshot`; frame & scroll buffers; version cursor | `runtimeState()`, `runtimeScrollFrameBits()`, `touchRuntimeState()`, `serviceRuntimeSlowStatePublish()` | all firmware |
| `src/sync.h` / `sync.cpp` | concurrency | 4 FreeRTOS mutexes + scoped-lock helpers; documented lock order | `withFrameLock`, `withScrollLock`, `withStorageLock`, `withHardwareBusLock`, `initSyncPrimitives` | render, storage, faces |
| `src/led_renderer.h` / `.cpp` | LED output + M370 | Serpentine map, M370 decode/encode, frame queue, render to strip, color/brightness | `applyM370`, `applyPackedFrameImmediate`, `serviceM370FrameQueue`, `renderCurrentFrameToLedStrip`, `setBrightness`, `setColor` | faces, scroll, web_api, buttons |
| `src/scroll.h` / `.cpp` | scroll task | Core-1 `scrollRenderTask`, advances firmware scroll frame index on interval | `startScrollRenderTask`, `notifyScrollRenderTask`, `getRestoreAutoAfterScroll` | main, led_renderer |
| `src/faces.h` / `.cpp` | mode + faces + scroll FSM | Manual/auto mode, auto-playback, saved-face apply, deferred restore, firmware-scroll start/stop/pause | `setMode`, `serviceAutoPlayback`, `applySavedFaceIndex`, `startFirmwareScroll`, `stopFirmwareScroll`, `serviceDeferredFaceRestore` | web_api, buttons, storage |
| `src/storage.h` / `.cpp` | persistence | LittleFS mount, atomic JSON read/write, load/validate/write saved faces, runtime settings | `mountFilesystem`, `loadSavedFaces`, `validateSavedFaces`, `writeSavedFaces`, `saveRuntimeSettings` | main, web_api, power |
| `src/power_monitor.h` / `.cpp` | battery/charge | ADC sampling (trimmed mean), EMA filters, % LUT, disconnect detection, calibration, web-dirty publishing | `servicePowerMonitor`, `readPowerStatusSnapshot`, `resetBatteryVoltageMin/Max` | main, web_api, button_animations |
| `src/buttons.h` / `.cpp` | GPIO input | Debounce, combos (B3+B1/B2), repeat, dispatch to `runButtonAction` | `initHardwareButtons`, `serviceHardwareButtons`, `runButtonAction` | main, web_api |
| `src/button_animations.h` / `.cpp` | LED overlays | Mode/interval/brightness/battery overlays with bitmap glyphs; B6 battery page | `startButtonAnimationForGpioAction`, `showBatteryOverlay`, `copyButtonAnimationOverlay`, `serviceButtonAnimations` | led_renderer, buttons, web_api |
| `src/web_api.h` / `.cpp` | HTTP server | `WebServer` + captive DNS; all route handlers; gzip static serving; AP startup | `startWebServer`, `handleApiStatus/Power/Frame/Scroll/ScrollMeta/Command/SavedFaces`, `serveStaticFile` | main |
| `src/web_json.h` / `.cpp` | streaming JSON | Hand-rolled, allocation-light JSON field extraction + whole-object validation for scroll bodies | `jsonValidateCompleteObject`, `jsonStringField`, `jsonUintField`, `extractJsonStringAt`, `jsonFieldValueOffset` | web_api (scroll) |
| `src/utils.h` / `.cpp` | helpers | Hex nibble, millis math, color parse/format, UTF-8 + meta-id validation | `hexNibble`, `parseColorHex`, `validateScrollSourceText`, `millisElapsed` | many |
| `src/psram_json.h` | helper | ArduinoJson allocator that prefers PSRAM | `PsramJsonDocument`, `SpiRamAllocator` | storage, web_api |

### 2.2 WebUI (`data/`) — runs in the browser

| Path | Type | Purpose | Key symbols | Used by |
|---|---|---|---|---|
| `data/index.html` | WebUI markup | 5 pages (6.1 basic, 6.2 custom, 6.3 parts, 6.4 scroll, 6.5 debug); loading overlay; all control ids | `#page-basic/custom/parts/scroll/debug`, `#matrix-*`, `#scroll-*`, `.debug-sim` | app.js binds by id |
| `data/app.js` | WebUI logic | Entire client: state, API client, sync, rendering, faces, scroll, debug | `state`, `firmware`, `scroll`, `applyFirmwareRuntimeState`, `bootstrapWebUi`, `WEBUI_CONFIG`, `EXPRESSION_PARTS` | self / DOM |
| `data/styles.css` | WebUI styling | Layout, responsive breakpoints, loading animation, embedded UI font face | — | index.html |
| `data/resources/saved_faces.json` | data/persistent | Unified face library (11 default faces); `startupDefaultId=face_08...` | schema `rina_faces_370_v2` | firmware load + WebUI |
| `data/resources/runtime_settings.json` | data/persistent | Persisted `mode` + `autoIntervalMs` | schema `rina_runtime_settings_v1` | `loadRuntimeSettings` |
| `data/resources/battery_calib.json` | data/persistent | Battery voltage window `v_min`/`v_max` | schema `rina_battery_calibration_v1` | `loadBatteryCalibration` |
| `data/resources/fonts/ark12.json` | data asset | ~2.5 MB Ark Pixel 12px bitmap glyph table (lazy-loaded for scroll generation) | — | `loadArkPixelFontTable` |
| `data/resources/fonts/*.woff2` | data asset | Browser display fonts (unifont UI font, ark12 scroll font) | — | CSS / scroll input |
| `data/resources/loading/*.png` | data asset | Loading-screen avatar images | — | index.html |

### 2.3 Build / tooling / docs

| Path | Type | Purpose |
|---|---|---|
| `platformio.ini` | build | ESP32-S3 env, LittleFS, PSRAM (OPI/qio_opi), core affinity flags, lib deps (ArduinoJson 6.21.5, Adafruit NeoPixel 1.12.3), HTTP timeout flags |
| `partitions.csv` | build | No-OTA layout: 2 MB app + ~5.9 MB LittleFS |
| `scripts/gzip_webui_assets.py` | build hook | Pre-build gzips `index.html/app.js/styles.css/ark12.json` into `.gz` sidecars; post-build removes them |
| `scripts/patch_webserver_timeout.py` | build hook | Patches Arduino `WebServer.h` HTTP timeout macros to be overridable (200 ms) |
| `tools/*.py`, `archive/`, `.font_cache/` | tooling | Font fusion / BDF compile pipeline that produced `ark12.json` — offline, not runtime |
| `tools/test_m370_boundary.js` | test | Node unit test of M370 normalize/pack boundary behavior |
| `AUDIT_REPORT.md` | doc | Prior audit (partly stale — see §14) |
| `plan.md`, `refactor_plan.md`, `PAGE_6_5_DEBUG_REWRITE_PLAN.md` | doc | Large design/planning docs |

### 2.4 Entry points, targets, runtime spine
- **Firmware entry:** `setup()` → `loop()` in `main.cpp`. Build target `esp32s3` (`platformio.ini`).
- **Firmware main loop (Core 0):** `loop()` calls, in order, `serviceM370FrameQueue`, `webServerTick`, `serviceRuntimeSlowStatePublish`, `serviceHardwareButtons`, `serviceButtonAnimations`, `servicePowerMonitor`, `serviceDeferredFaceRestore`, `serviceAutoPlayback`, then `vTaskDelay(1)`.
- **Firmware render loop (Core 1):** `scrollRenderTask` (`scroll.cpp:22`), pinned to `LED_RENDER_TASK_CORE=1`.
- **WebUI entry:** `bootstrapWebUi()` (`app.js:10717`), invoked at script end.
- **Static assets served to browser:** anything in LittleFS, via `serveStaticFile` + `handleNotFound`; gzip-preferred.
- **API endpoints:** `/api/status`, `/api/power`, `/api/frame`, `/api/scroll`, `/api/scroll/meta`, `/api/command`, `/api/saved_faces`, plus `/` and catch-all static.
- **Hardware abstraction boundary:** `led_renderer.cpp` (LED bus via Adafruit_NeoPixel), `power_monitor.cpp` (ADC), `buttons.cpp` (GPIO). All other modules touch hardware only through these.

---

## 3. Major Systems

| System | Responsibility | Firmware files/functions | WebUI files/functions | Shared state/API/protocol |
|---|---|---|---|---|
| Boot/init | Bring-up order, FS mount, load state, start AP+server+tasks | `main.cpp setup()` | `bootstrapWebUi`, `preloadFirmwareRuntimeState` | — |
| LED render | Pack→serpentine→WS2812 output, brightness/color, overlay compositing | `led_renderer.cpp renderCurrentFrameToLedStrip`, `scroll.cpp scrollRenderTask` | local preview `renderMatrices`/`initMatrix` | `frameBits[FRAME_BYTES]`, `frameMutex` |
| M370 frame protocol | Parse/normalize/decode 93-hex frames, rate-limit queue | `led_renderer.cpp normalizeM370`, `applyM370`, `serviceM370FrameQueue` | `frameToM370`/`m370ToFrame` | `M370:`+93 hex |
| Saved faces / storage | Load/validate/persist face library + settings | `storage.cpp`, `faces.cpp applySavedFaceIndex` | `loadFaceLibrary`, `persistFaceDocuments`, `saveFace` | `/api/saved_faces`, `saved_faces.json` |
| Manual/Auto playback | Mode FSM, auto cycle through faces | `faces.cpp setMode`, `serviceAutoPlayback` | `toggleMode`, `applyFirmwareRuntimeState` | `mode`, `autoIntervalMs`, `autoFaceIndex` |
| Scroll text (firmware) | Cache uploaded frames, play on Core-1 timer, pause/step/stop | `faces.cpp startFirmwareScroll/stopFirmwareScroll`, `scroll.cpp scrollRenderTask` | scroll generation + upload + restore (`startScroll`, `uploadFirmwareScrollTimeline`) | `/api/scroll`, `/api/scroll/meta`, `ScrollTimelineMeta` |
| Button input | Debounce/combo/repeat, dispatch actions | `buttons.cpp` | debug page GPIO simulator (`runDebugSimCommand`) | `runButtonAction`, `/api/command cmd:button` |
| Button overlays | Transient LED feedback (mode/interval/brightness/battery) | `button_animations.cpp` | — (firmware-only) | `sAnim`, `sAnimMux` |
| Battery/power | ADC sample, EMA, %, disconnect, calibration | `power_monitor.cpp` | `applyPowerData`, debug power panel | `/api/power`, `/api/status` power object |
| Wi-Fi/server | SoftAP + captive DNS + HTTP routing | `web_api.cpp startAccessPoint/startWebServer/webServerTick` | `apiGet/apiPost`, captive portal | AP `RinaChanBoard-V2` / `rina.io` |
| Web API | Route handlers, JSON build, command dispatch table | `web_api.cpp handleApi*`, `API_COMMAND_ROUTES` | `sendAuxCommand`, `frameSendPump`, `buttonCommandPump` | JSON over HTTP |
| WebUI state mgmt | Mirror firmware, reconcile, busy flags | — | `state`, `firmware`, `scroll`, `applyFirmwareRuntimeState` | `stateVersion`/`since` |
| WebUI preview/render | 370-cell matrix views, fit/scale, DPS estimate | — | `initMatrix`, `fitMatrix`, `renderMatrices`, `estimateFrameWatts` | local frames |
| WebUI transport | Rate-limited frame/command queues, upload progress | — | `makeRateLimitedQueue`, `apiPostWithUploadProgress` | `/api/frame`, `/api/command` |
| Parts composer | Combine eye/mouth/cheek parts into M370 | — | `composePartsFrame`, `EXPRESSION_PARTS` | local M370 |
| Debug console | Diagnostics, GPIO sim, M370 lab, raw command, danger zone | (consumes existing endpoints) | `initializeDebugControls`, `renderDebug*` | all endpoints |

---

## 4. Runtime Lifecycle

### 4.1 Firmware power-on → operation (`main.cpp setup()`)

```
Power on
→ pinMode(LED_PIN, OUTPUT); drive LOW; hold; reset pulse   // quench floating WS2812 data
→ Serial.begin(115200)
→ runtimeState().bootMs = millis()
→ initRuntimeScrollFrameBuffer()      // alloc 3072*47B scroll cache (PSRAM preferred) + 4KB source-text buf
→ g_syncReady = initSyncPrimitives()  // 4 FreeRTOS mutexes; if fail → single-core fallback + FS error pattern
→ initLedIndexMap()                   // precompute logical→physical serpentine map
→ ledStripBegin()                     // strip.begin, clear, show (under HardwareBus lock)
→ setColorStateNoRender(DEFAULT_COLOR)// #f971d4 without racing a render
→ mountFilesystem()                   // LittleFS; on fail → showFilesystemErrorPattern() (12 red LEDs)
   └ loadRuntimeSettings()            // mode + autoIntervalMs (writes defaults if missing/corrupt)
   └ loadSavedFaces(true)             // parse saved_faces.json, sort by order, pick startup face, apply it
→ renderCurrentFrameToLedStrip(); consumeLedRenderRequest()  // show first frame once, clear pending flag
→ startScrollRenderTask()             // Core 1 LED render/scroll task (only if g_syncReady)
→ initHardwareButtons()               // INPUT_PULLUP on 6 pins, sample initial state
→ initPowerMonitor()                  // load battery_calib.json, set ADC res/atten, force one sample
→ startAccessPoint()                  // WIFI_AP, softAPConfig, softAP, DNS captive on rina.io
→ startWebServer()                    // register 7 API routes + static, server.begin()
```

Pins/peripherals initialized: LED data `GPIO2`; buttons `GPIO17,16,15,40,41,42` (B1..B6, INPUT_PULLUP); battery ADC `GPIO10`, charge ADC `GPIO1` (12-bit, 11 dB atten). State loaded from storage: `mode`, `autoIntervalMs` (settings), the full face table + startup face (saved_faces), battery calibration window. Default UI/LED state: brightness `DEFAULT_BRIGHTNESS=50`, color `#f971d4`, playback `idle` (or `auto_saved_face` if mode=auto), startup default face frame on the LEDs.

### 4.2 Firmware steady state (Core 0 `loop()` + Core 1 task)

Core 0 each iteration: drain at most one due M370 frame from the queue (`serviceM370FrameQueue`, gated to ≥`M370_FRAME_MIN_INTERVAL_MS=33ms`), service HTTP/DNS (`webServerTick`), publish slow UI dirty bit (`serviceRuntimeSlowStatePublish`, every 10 s), poll buttons (`serviceHardwareButtons`), tick overlays (`serviceButtonAnimations`), sample power (`servicePowerMonitor`, every 1 s), run any due deferred face restore, advance auto playback if in auto mode, then `vTaskDelay(1)`.

Core 1 `scrollRenderTask` loops: consume any pending render request; if firmware scroll is active+unpaused and the interval elapsed, advance `scrollFrameIndex` and copy the next cached scroll frame into `frameBits` (under scroll+frame locks); render to strip if anything changed; block on task-notify with 1 ms timeout. **All physical `strip.show()` happens here** (plus the boot/error paths), serialized by `HardwareBus` lock.

### 4.3 Browser open → operation (`bootstrapWebUi` `app.js:10717`)

```
Browser loads index.html (data-boot-phase="preload", loading overlay shown)
→ bootstrapWebUi()
   → rinaStartLoaderAnimation()
   → prepareFirstPageProgressiveReveal()
   → ensureWebUiFontReady()                  // embedded UI font (unifont) ready before reveal
   → initFirstPageUiBeforeShow(); initializeBasicPreviewMatrix(); renderFirstPageUiBeforeShow()
   → revealFirstPageWaterfall()              // staged 6.1 reveal
   → preloadFirmwareRuntimeState()           // GET /api/status (FULL, skipFrame:false) → first LED frame fills basic preview
        └ applyFirmwareRuntimeState(data, "page_boot_runtime")
   → waitForBootLoaderMinimum(); finishBootVisibility()   // data-boot-phase="ready"
   → initDeferredUiAfterShow()
   → kickPostBootScrollMetaRestore()         // enable + GET /api/scroll/meta restore
   → startFirmwareStatusPolling()            // adaptive 0.5–10 s, since=version
   → startPowerStatusPolling()               // 1 s on basic/debug pages
   → runPostBootDeferredReads()              // loadFaceLibrary() → syncRuntimeStateFromFirmware → render
```

First fetch is the **full** `/api/status` (so the boot loader can paint the first real LED frame). Local state is initialized from `WEBUI_CONFIG`, then overwritten field-by-field by `applyFirmwareRuntimeState`. Face library (`saved_faces.json`) is loaded **after** the UI is revealed to avoid contending with the single-threaded ESP server. The heavy 2.5 MB `ark12.json` scroll font is lazy — loaded the first time the scroll page is opened (`switchPage`) or warmed in the background after critical reads.

---

## 5. Hardware-to-Firmware-to-WebUI Flow

### 5.1 Hardware interaction table

| Hardware source | Pin/peripheral | Read/write fn | Data transformation | State updated | WebUI/API exposure | User-visible effect |
|---|---|---|---|---|---|---|
| Buttons B1–B6 | GPIO 17/16/15/40/41/42, INPUT_PULLUP | `serviceHardwareButtons` (`buttons.cpp:220`) | debounce 25 ms; edge→press/release; combos; repeat | dispatch via `runButtonAction` | `scrollStopEvent`, `lastReason`, mode/brightness/index in `/api/status` | face change, brightness, mode toggle, overlay |
| Battery voltage | ADC `GPIO10` | `readTrimmedAdcMilliVolts`+`sampleBattery` (`power_monitor.cpp:292`) | 16 samples, drop 4 hi/4 lo, mean; `mV/1000*2.708333+0.2033`; EMA τ=20 s; LUT→% | `powerStatus.vbat/batteryPercent` (under `sPowerStatusMux`) | `/api/power`, `/api/status` power obj | battery badge + debug panel |
| Charger presence | ADC `GPIO1` | `sampleCharge` (`power_monitor.cpp:398`) | `mV/1000*6.684982+0.0712`; EMA α=0.2; `>4.0V`→charging | `powerStatus.vcharge/charging` | same | charging badge |
| Battery disconnect | derived from ADC drop | `detectBatteryDisconnect` (`power_monitor.cpp:285`) | huge raw drop ≥1000 mV & ≤900 mV, reconnect <1500 mV | `batteryDisconnected/LowVoltageUnpowered` | power obj flags | "未上电" state |
| LED output | WS2812 on GPIO2 via RMT/NeoPixel | `renderCurrentFrameToLedStrip` (`led_renderer.cpp:211`) | logical→physical serpentine; bit→color or overlay RGB; min-gap pacing | reads `frameBits`+color+brightness | `lit`/`lastM370` in status | the physical face |
| LED render request | `portMUX` flag + task notify | `requestLedRender`/`consumeLedRenderRequest` | ISR-safe flag set; notify Core-1 task | `ledRenderRequested` | — | render scheduling |

### 5.2 End-to-end trace: button press → LEDs (+ optional WebUI)

```
GPIO falling edge on B1
→ serviceHardwareButtons() debounce (25ms) detects press   // buttons.cpp:220
→ handleHardwareButtonPress(): B3-combo check; B1 is face-repeat → fireHardwareButtonAction("B1")
→ runButtonAction("B1","gpio")                             // buttons.cpp:100
   → (B1/B2) stopFirmwareScroll(false); setRestoreAutoAfterScroll(false)
   → applyRelativeSavedFace(+1, "gpio_B1_next_saved_face")  // faces.cpp:148
       → applySavedFaceIndex(): autoFaceIndex++; applyM370(face.m370,...)
           → enqueuePackedM370Frame → publishPackedFrameNow (if rate-ready)
               → withFrameLock { memcpy frameBits; lastM370; ++framesAccepted; touchRuntimeState(); showCurrentFrameNoLock() }
   → if scroll was active: markScrollStoppedByButton() bumps scrollStopEventSeq
   → finishButtonAction(): startButtonAnimationForGpioAction("B1")  // no overlay for B1, but sets press feedback
→ Core-1 scrollRenderTask wakes on notify → renderCurrentFrameToLedStrip() → strip.show()  // LEDs update
→ (later) WebUI poll GET /api/status?since=v → version changed → applyFirmwareRuntimeState
   → autoFaceIndex/lastReason/scrollStopEvent merged → renderSavedFaces / preview update
```

### 5.3 End-to-end trace: battery voltage → WebUI indicator

```
Core-0 loop: servicePowerMonitor() every ~1s              // power_monitor.cpp:435
→ sampleBattery(): readTrimmedAdcMilliVolts(GPIO10)
   → instantVbat = vadc*2.708333 + 0.2033
   → disconnect/low-voltage edge detection
   → EMA: nextVbat = vbat*(1-α)+instant*α, α from dt/τ(20s)
   → batteryPercent via BATTERY_PERCENT_LUT interpolation (±1% hysteresis)
   → commit vbat/percent/valid under sPowerStatusMux
→ servicePowerWebPublish(): set webFastDirty/webSlowDirty + touchRuntimeState() on meaningful change
→ WebUI GET /api/power (1s) or /api/status power obj
   → addPowerStatus() builds JSON (icon class/color, state text, thresholds)
   → applyPowerData() in browser → state.battery* → renderState() → #badge-battery + debug panel
```

---

## 6. WebUI-to-Firmware-to-Hardware Flow

The browser never writes hardware directly. Three transport paths exist:
1. **`frameSendPump`** → `POST /api/frame` (rate `WEBUI_M370_SEND_INTERVAL_MS=45ms`, depth 3) for raw M370 frames (custom/parts/debug/manual draw).
2. **`buttonCommandPump`** → `POST /api/command {cmd:"button"}` (rate 120 ms, depth 4) for simulated buttons.
3. **`sendAuxCommand`** → `POST /api/command` directly (no queue) for everything else (mode, color, brightness, scroll control, battery resets, overlays).

Command responses are fed back through `applyFirmwareRuntimeState()` so the browser reconciles to firmware truth — but **`/api/frame` replies are not**. `buttonCommandPump` sets `onResult: applyFirmwareRuntimeState` (`app.js:4999`), whereas `frameSendPump` has **no `onResult`** (`app.js:5009`); raw frame sends therefore rely on optimistic local state plus the next `/api/status` poll to reconcile, and the frame reply's `color`/`brightness`/`mode`/`lit`/`m370` fields are effectively ignored.

### 6.1 Feature flow: change brightness

```
User drags #brightness-range or clicks +8/−8
→ setBrightness(v,"brightness_change")            // app.js:5235
   → applyBrightnessLocal(v) (instant local preview + DPS)
   → lastUserBrightnessMs = now  (suppresses stale firmware echo for 2s)
   → sendAuxCommand("set_brightness",{raw:v})
→ POST /api/command {cmd:"set_brightness",payload:{raw}}
→ handleApiCommand → commandSetBrightness → setBrightness(raw)   // led_renderer.cpp:421
   → constrain 10..200; withFrameLock { brightness=raw; touchRuntimeStateSlow(); showCurrentFrameNoLock() }
→ Core-1 render applies strip.setBrightness on next show
→ reply JSON (buildCommandReply) → applyFirmwareRuntimeState("webui")
   → brightness echo skipped if within 2s of lastUserBrightnessMs (anti-jitter)
```

Note: brightness uses `touchRuntimeStateSlow()` (only publishes a new version after the 10 s slow window or another fast change), so the slider value is authoritative locally and reconciled lazily.

### 6.2 Feature flow: custom/parts frame send

```
User draws on #matrix-custom-edit / picks parts
→ composePartsFrame()/editFrame edits → setCurrentFrame(frame,"custom_face_send","idle")  // app.js:5180
   → guardBeforeOutput() → terminateOtherActivities("custom") (stops scroll/auto, sends terminate_other_activities)
   → queueFirmwareFrame(frame,reason,playback) → frameSendPump.enqueue
→ POST /api/frame {m370,reason,mode}
→ handleApiFrame: normalizeM370; if reason custom_/parts_ → setMode("manual",false);
   playback=mode; applyM370 → frame queue → render
→ reply (color/brightness/mode/lit/lastM370) returned but NOT merged (frameSendPump has no onResult);
   browser reconciles via the next /api/status poll
```

### 6.3 Feature flow: mode toggle (manual↔auto)

```
User clicks #mode-toggle → toggleMode("ui_mode_toggle")        // app.js:6844
→ toggleModeLocal (optimistic) + sendAuxCommand("set_mode",{mode})
→ commandSetMode → cancelDeferredFaceRestore(); setMode(mode,true)  // faces.cpp:29
   → auto: mode=auto, playback=auto_saved_face, paused=false, lastAutoSwitchMs=now
   → manual: playback→idle if was auto; clear restoreAutoAfterScroll
   → persist runtime_settings.json if mode changed
→ Core-0 serviceAutoPlayback() then cycles faces on autoIntervalMs when mode=auto
→ reply → applyFirmwareRuntimeState
```

---

## 7. API Endpoint Map

| Endpoint | Method | Called by WebUI fn | Firmware handler | Parameters | State changed | Hardware effect | Response (key fields) |
|---|---|---|---|---|---|---|---|
| `/` | GET | browser nav | `serveRoot`→`serveStaticFile` | — | — | — | index.html (gzip) |
| `/api/status` | GET (HTTP_ANY) | `preloadFirmwareRuntimeState`, `syncRuntime*FromFirmware` | `handleApiStatus` (`web_api.cpp:446`) | `since`, `runtimeOnly`, `summary`/`noFrame`, `fullPower`, `runtimeOnly` | none (read) | none | `v/version`, `next_poll_ms`, `renderer.*`, `power.*`, `matrix`, `endpoints`, `storage`, `stats`, `scrollStopEvent`, `unchanged` |
| `/api/power` | GET | `refreshPowerStatusFromFirmware` | `handleApiPower` (`:584`) | — | none | none | `power.*` (full) |
| `/api/frame` | POST | `frameSendPump` via `queueFirmwareFrame` | `handleApiFrame` (`:596`) | `m370`, `mode`/`playback`, `reason`, `faceId` | frame, playback, mode, autoFaceIndex | LED frame | `accepted`, `queueCount`, `color`, `brightness`, `mode`, `lit`, `m370` |
| `/api/scroll` | POST | `uploadScrollTimelineAttempt` (chunks) | `handleApiScroll` (`:670`) | `frames[]`, `append`, `start`, `chunkIndex`, `totalFrames`, `timelineId`, `sourceText`, `fontId`, `generatorVersion`, `fps`/`intervalMs`, `storage` | scroll cache, scroll meta, playback | LED scroll (on start) | `frames`, `chunkFrames`, `chunkIndex`, `uploadComplete`, `timelineId`, `started` |
| `/api/scroll/meta` | GET | `restoreScrollTextFromFirmware`, `fetchLatestScrollFrameMetaAfterPreview` | `handleApiScrollMeta` (`:988`) | — | none | none | `scrollTimelineId`, `sourceText`, `fontId`, `generatorVersion`, `uiFps`, `frameCount`, `frameIndex`, `uploadComplete`, scroll active/paused flags |
| `/api/command` | POST | `sendAuxCommand`, `buttonCommandPump` | `handleApiCommand` (`:1388`) | `cmd`, `payload{...}` | per-command | per-command | `cmd`, full renderer echo, scroll state, optional `power` |
| `/api/saved_faces` | GET/POST | `loadUnifiedFacesDocument`, `persistFaceDocuments` | `handleApiSavedFaces` (`:1489`) | GET: none; POST: `document`, `path`, `reason` | saved face table (reloaded) | LEDs on reload of current face | GET: raw JSON; POST: `bytes`, `writes`, `path` |
| (catch-all) | GET | static fetches | `handleNotFound`→`serveStaticFile` | URI | none | none | static asset or 503 FS-error page |

### 7.1 `/api/command` command table (`API_COMMAND_ROUTES`, `web_api.cpp:1336`)

`set_color`, `set_brightness`, `set_mode`, `set_auto_interval`, `set_scroll_interval`, `start_scroll`, `scroll_step`, `pause_scroll`, `resume_scroll`, `stop_scroll`, `pause`, `resume`, `button`, `terminate_other_activities`, `reset_battery_min`, `reset_battery_max`, `battery_overlay`.

Each handler returns `bool`; failures set `sCommandErrorStatus` (400 default, 409 for scroll timeline conflicts) and are reported via `sendError`. `commandWantsPower()` augments the reply with a fresh power snapshot for the battery commands.

---

## 8. State Ownership and Synchronization

### 8.1 Sync field table

| State field | Firmware variable/source | API endpoint | WebUI variable | UI element | Poll/event trigger | Risk |
|---|---|---|---|---|---|---|
| Color | `runtimeState().colorHex/R/G/B` (frameMutex) | status/command | `state.color` | swatch/input | command echo + poll | low |
| Brightness | `runtimeState().brightness` | status/command | `state.brightness` | range+input | command echo (2 s echo-suppress) | medium (stale echo during drag) |
| Mode | `runtimeState().mode` | status/command/settings | `state.mode` | mode toggle | command + poll | low |
| Auto interval | `runtimeState().autoIntervalMs` | status/command/settings | `state.autoInterval` | interval slider | command + poll | low |
| Auto face index | `runtimeState().autoFaceIndex` | status/frame | `state.faceIndex` | face list highlight | poll/frame reply | medium (clamped to local library length) |
| Current frame | `frameBits` / `lastM370` (frameMutex) | status (`lastM370`) | `currentFrame` | matrices | full poll only (skipped while scrolling) | medium |
| Playback | `runtimeState().playback` | status/command | `state.playback` | scroll/mode UI | poll/command | medium |
| Scroll active/paused | `firmwareScrollActive/Paused/User/System` (scrollMutex) | status/command/meta | `scroll.active/paused/user/systemPaused` | scroll buttons | poll/command | **high** |
| Scroll frame index | `runtimeState().scrollFrameIndex` (scrollMutex) | status/meta | `scroll.frameIndex` | "当前帧" | poll/meta; local timer overrides | **high (drift)** |
| Scroll source text | `scrollSourceText` + meta (scrollMutex) | `/api/scroll/meta` | `scroll.restoredSourceText`, input box | textarea | restore flow | high (truncation/edit guard) |
| Scroll stop event | `scrollStopEvent*` seq | status | `lastScrollStopEventSeq` | (drives preview reset) | poll | medium |
| Battery | `powerStatus.*` (sPowerStatusMux) | power/status | `state.battery*` | badges/debug | 1 s power poll | low |
| Saved faces | `autoFaces_[]` (Core-0) + LittleFS file | `/api/saved_faces` | `defaultFaces/userFaces/faceLibraryDocument` | face list | explicit load/save | medium (two copies) |
| Settings (mode/interval) | `runtime_settings.json` | (loaded at boot) | — | — | boot | low |
| stateVersion | `runtimeState().stateVersion` | status `v` | `firmwareStatusVersion` | — | every poll | low |

### 8.2 Source-of-truth analysis
- **Firmware is authoritative** for: current frame, color, brightness, mode, auto interval, auto face index, all scroll playback state, battery, and the persisted face library/settings/calibration files.
- **Browser-derived/cached**: `state.*` and `scroll.*` mirror firmware; `currentFrame/scrollFrame/partsFrame/editFrame/debugPreviewFrame` are **locally reconstructed** from M370 or generated bitmaps.
- **Duplicated**: the face library lives both in firmware RAM (`autoFaces_`) and in the browser (`faceLibraryDocument`/`defaultFaces`/`userFaces`); scroll frames live in firmware PSRAM cache and (separately, re-generated) in `scroll.frames`.
- **Survives page reload**: everything firmware-side (frame, mode, scroll cache + source text via `/api/scroll/meta`, battery). The browser re-derives by polling + scroll-meta restore.
- **Survives power reboot**: only what is in LittleFS — `saved_faces.json`, `runtime_settings.json` (mode + interval), `battery_calib.json`. Scroll cache is **RAM-only** (explicitly rejects persist/flash, `web_api.cpp:705`) and is lost on reboot.
- **Can desynchronize**: scroll frame index (independent timers), scroll preview vs. LEDs (font/generator mismatch → `framesTimelineId` left unbound), brightness during active drag (echo-suppressed), face index when the browser's library differs from firmware's file.

---

## 9. Feature-by-Feature Implementation

### Feature: Manual mode
- **Behavior:** static face shown; B1/B2 or WebUI next/prev change face; no auto cycling.
- **Firmware:** `setMode("manual")` (`faces.cpp:29`), `applySavedFaceIndex`/`applyRelativeSavedFace`.
- **WebUI:** `toggleMode`, `nextFace/prevFace` → `sendButtonCommand("B1"/"B2")`; local `nextFaceLocal/prevFaceLocal` for optimistic preview.
- **Persistence:** `mode` saved to `runtime_settings.json`.
- **Risks:** browser face index clamps to its own library length (`applyFirmwareRuntimeState:4743`); if libraries differ, highlight can mismatch.

### Feature: Auto playback mode
- **Behavior:** cycles faces every `autoIntervalMs`.
- **Firmware:** `serviceAutoPlayback` (`faces.cpp:380`) — increments `autoFaceIndex` and `applyM370("firmware_auto_saved_face")` on interval; `paused` and `autoFaceCount==0` short-circuit.
- **WebUI:** mode toggle + interval slider; relies on polling to follow index.
- **Persistence:** `autoIntervalMs` + `mode` in settings.
- **Risks:** the browser does not run its own auto timer; the displayed face lags one poll behind hardware.

### Feature: Saved faces / library
- **Behavior:** unified `saved_faces.json` of default + user faces; reorder/rename/delete; startup default.
- **Firmware:** `loadSavedFaces` (sort by `order`, choose startup/previous face, cap at `MAX_AUTO_FACES=128`), `validateSavedFaces` (category, ≤128, ≥1 default, valid M370), `writeSavedFaces` (atomic temp+rename).
- **WebUI:** `loadFaceLibrary`, `buildUnifiedFaceDocument`, `persistFaceDocuments` (→ optional local File System Access write + `POST /api/saved_faces`), `createFaceRow`/`reorderFace`/`deleteFace`.
- **Persistence:** LittleFS file; reload after POST re-applies current face.
- **Risks:** two divergent copies; ordering re-assigned client-side (`reassignOrderFromLibrary`); local-file vs firmware write can disagree on failure.

### Feature: Face/frame upload (custom + parts)
- **Firmware:** `handleApiFrame` normalizes and applies; `custom_`/`parts_` reasons force manual mode.
- **WebUI:** `setCurrentFrame`→`queueFirmwareFrame`→`frameSendPump`; live-send toggles re-send on each edit.
- **Risks:** frame queue depth 3 both sides; rapid edits drop frames (counted in `droppedFrames`).

### Feature: LED matrix preview
- **WebUI:** `initMatrix` builds 370 cells using the same serpentine/row geometry as firmware (`MATRIX_VIEW_CONFIGS`, `XY_TO_INDEX`, `ROW_RANGES`); `fitMatrix`/`renderMatrices` size and paint. Five independent views (basic, custom-edit, parts, scroll, debug) each with their own frame buffer.
- **Risks:** preview is browser-rendered; correctness depends on row geometry matching `config.h` (it does — same `ROW_LENGTHS/OFFSETS`).

### Feature: Brightness control
- See §6.1. Firmware `setBrightness` clamps 10–200; overlay shows percent relative to `MAX_BRIGHTNESS=200`. Anti-jitter via `lastUserBrightnessMs`.

### Feature: Color control
- **Firmware:** `setColor` (parse hex, store RGB, `touchRuntimeStateSlow`, request render).
- **WebUI:** `setColor`, parent/child color dropdowns (`renderParentColorButtons`/`renderChildColors`), hex input. Color applies as the "on" pixel color in `renderCurrentFrameToLedStrip`.

### Feature: Scroll text generation (browser)
- **WebUI:** `buildTextScrollBitmap` (Ark Pixel 12px glyphs via `buildTextGlyph`/`getArkGlyph`), `extractFrameFromTextImage` slices a 1-LED-per-frame window across the rendered bitmap into M370 frames; `prepareTextScrollTimeline*` builds `scroll.frames`.
- **Encoding identity:** `SCROLL_GENERATOR_VERSION="webui-scrollgen-6.4.2"` + `fontId` gate whether a restored preview can bind to firmware frames exactly.

### Feature: Scroll upload to firmware
- **WebUI:** `uploadFirmwareScrollTimeline`→`uploadScrollTimelineAttempt` chunks frames (first chunk sized to ≤12 KB body, rest 24 frames), each chunk carries `timelineId`+`chunkIndex`; first chunk carries `sourceText`+`fontId`+`generatorVersion`+`totalFrames`. 409 → one full retry with a fresh `timelineId` (`C10`).
- **Firmware:** `handleApiScroll` validates strictly (pre-flight validates all first-chunk frames before clearing state), enforces timeline integrity (`D1/D2/E1/E2/E3`), writes packed frames into `scrollFrameBits(targetIndex)`, sets `uploadComplete` when `framesReceived≥totalFramesExpected`.

### Feature: Scroll play/pause/resume/stop/step
- **Firmware:** `startFirmwareScroll`, `setFirmwareScrollUserPaused`/`SystemPaused` (effective pause = user OR system, `recomputeEffectivePauseLocked`), `stopFirmwareScroll` (optional clear + deferred default-face restore), `commandScrollStep` (manual index step, immediate frame).
- **WebUI:** `startScroll`, `togglePauseScroll`/`pauseScroll`/`resumeScroll`, `stopScroll`, `setScrollStepHandler`; busy flags (`commandBusy/startBusy/pauseBusy/stopBusy/stepBusy`) and `pauseToggleLocked` serialize user actions.
- **System pause:** battery overlay pauses firmware scroll as "system paused" so it auto-resumes when the overlay ends (`button_animations.cpp pauseScrollForOverlay`/`resumeScrollAfterOverlayIfNeeded`).

### Feature: Scroll preview sync after reload
- **WebUI:** `kickPostBootScrollMetaRestore`→`restoreScrollTextFromFirmware` (GET `/api/scroll/meta`) refills the textarea (never overwriting unsent edits — `C5`), then `restoreScrollPreviewIfNeeded` regenerates frames and re-syncs `frameIndex`. Frame identity (`framesTimelineId`) is bound only when text not truncated + generator matches exactly + frame count equals firmware's (`D5/E4`).
- **Risks:** the core desync surface — see §13.

### Feature: Button controls / GPIO simulator
- **Firmware:** `runButtonAction` maps B1 next, B2 prev, B3 mode toggle, B4/B5 brightness ∓8, B3+B1/B3+B2 interval ∓0.5 s, B6 battery overlay (short/long), B6+B3 (network info path exists in UI labels). Repeat for face/brightness buttons.
- **WebUI:** debug page `.debug-sim` buttons → `runDebugSimCommand` → `/api/command {cmd:"button"}` or specific commands (`battery_overlay`, `pause_scroll`).

### Feature: Battery display / charging detection
- See §5.3. `addPowerStatus` precomputes icon classes/colors and Chinese state text (`电池`/`未上电`/`充电`). Browser `applyPowerData` consumes them directly.

### Feature: Default-face behavior
- **Firmware:** startup default selected by `is_startup_default` or `startupDefaultId` in `loadSavedFaces`; after a scroll stop with restore, `applyStartupDefaultFaceAfterScrollStop` re-applies it.
- **WebUI:** `startupDefaultFaceIndex`/`preferredStartupDefaultId` (note stale `DEFAULT_STARTUP_FACE_ID`, §14).

### Feature: Loading animation / init
- HTML loading overlay + staged reveal (`revealFirstPageWaterfall`); first LED frame painted into basic preview before the loader closes (`preloadFirmwareRuntimeState` full status).

### Feature: Import/export / persistence
- **WebUI:** `downloadFacesJson`, `importFacesJsonText/File`, File System Access `openLocalFaceLibraryFile`/`saveFaceLibraryToLocalFile`. All converge on `buildUnifiedFaceDocument` + `persistFaceDocuments`.

### Feature: Hidden/debug endpoints
- No hidden firmware endpoints beyond the 7 registered. The debug page exposes a **raw `/api/command`** textarea (`#debug-raw-json`) gated by a confirm checkbox, and a "danger zone" clear-user-faces. The `battery_overlay`, `terminate_other_activities`, `reset_battery_min/max` commands are firmware-real and UI-reachable.

---

## 10. Function-Level Call Graphs

### 10.1 Firmware boot
```
setup()
 → initRuntimeScrollFrameBuffer() → RuntimeStore::initScrollFrameBuffer()
 → initSyncPrimitives()
 → initLedIndexMap() → logicalToPhysicalLedIndex()
 → ledStripBegin() → strip.show() [HardwareBus]
 → mountFilesystem()
 → loadRuntimeSettings() → setMode()/setAutoInterval()
 → loadSavedFaces(true) → normalizeM370 / std::sort / applyM370()
 → renderCurrentFrameToLedStrip()
 → startScrollRenderTask() → xTaskCreatePinnedToCore(scrollRenderTask, core1)
 → initHardwareButtons()
 → initPowerMonitor() → loadBatteryCalibration / servicePowerMonitor(true)
 → startAccessPoint() → WiFi.softAP / dnsServer.start
 → startWebServer() → server.on(...) ×8 / server.begin
```

### 10.2 Firmware Core-0 loop
```
loop()
 → serviceM370FrameQueue() → publishPackedFrameNow() → showCurrentFrameNoLock() → requestLedRender()
 → webServerTick() → dnsServer.processNextRequest() / server.handleClient() → handleApi*()
 → serviceRuntimeSlowStatePublish() → touchRuntimeState()
 → serviceHardwareButtons() → handleHardwareButtonPress/Release → runButtonAction() → applyRelativeSavedFace/setMode/setBrightness/adjustAutoInterval
                            → serviceButtonAnimationButtonInputs()
 → serviceButtonAnimations() → readPowerStatusSnapshot() / requestLedRender() / stopOverlay()
 → servicePowerMonitor() → sampleBattery()/sampleCharge()/servicePowerWebPublish()
 → serviceDeferredFaceRestore() → applyStartupDefaultFaceAfterScrollStop / applyCurrentSavedFaceForMode
 → serviceAutoPlayback() → applyM370()
```

### 10.3 Firmware Core-1 render task
```
scrollRenderTask()
 → consumeLedRenderRequest()
 → withScrollLock { advance scrollFrameIndex; memcpy nextFrame }
 → withFrameLock { memcpy frameBits; ++framesAccepted }
 → renderCurrentFrameToLedStrip()
      → withFrameLock { snapshot frame/color/brightness }
      → copyButtonAnimationOverlay()  (overlay path)
      → withHardwareBusLock { strip.show() }
 → ulTaskNotifyTake(1ms)
```

### 10.4 Firmware HTTP command dispatch
```
handleApiCommand()
 → parseJsonBody()
 → findApiCommandRoute(cmd) → route->handler(doc,payload,error)
      commandSetColor → setColor()
      commandSetBrightness → setBrightness()
      commandSetMode → cancelDeferredFaceRestore() + setMode()
      commandStartScroll → withScrollLock checks → startFirmwareScroll()
      commandScrollStep → withScrollLock step → applyPackedFrameImmediate()
      commandPause/Resume[Scroll] → setFirmwareScrollUserPaused()/runtimeState.paused
      commandStopScroll → stopFirmwareScroll()
      commandButton → runButtonAction(...,"api_button")
      commandTerminateOtherActivities → stopFirmwareScroll()/setMode()
      commandResetBatteryMin/Max → resetBatteryVoltage*()
      commandBatteryOverlay → showBatteryOverlay()
 → buildCommandReply() [+ addPowerStatus if commandWantsPower]
 → sendJsonDocument()
```

### 10.5 WebUI initialization
```
bootstrapWebUi()
 → ensureWebUiFontReady()
 → initFirstPageUiBeforeShow() / initializeBasicPreviewMatrix() / renderFirstPageUiBeforeShow()
 → revealFirstPageWaterfall()
 → preloadFirmwareRuntimeState() → bootFastJsonGet(/api/status) → applyFirmwareRuntimeState()
 → finishBootVisibility() / initDeferredUiAfterShow()
 → kickPostBootScrollMetaRestore() → restoreScrollTextFromFirmware()
 → startFirmwareStatusPolling() / startPowerStatusPolling()
 → runPostBootDeferredReads() → loadFaceLibrary() → syncRuntimeStateFromFirmware()
```

### 10.6 WebUI sync + transport
```
applyFirmwareRuntimeState(data,source)        ← onResult of buttonCommandPump, sendAuxCommand, polls
 → applyPowerData() / setColor() / syncAutoIntervalUi()
 → scroll.* reconciliation / state.* / renderMatrices / renderSavedFaces / renderState
 → scrollStopEventFromStatus() → resetScrollControlsAfterButton() / scheduleFirmwareScrollStopFullSync()
 → (timeline mismatch) restoreScrollTextFromFirmware() → restoreScrollPreviewIfNeeded()

setCurrentFrame() → guardBeforeOutput() → terminateOtherActivities() → queueFirmwareFrame() → frameSendPump.enqueue() → apiPost(/api/frame)
sendAuxCommand() → apiPost(/api/command) → applyFirmwareRuntimeState()
sendButtonCommand() → buttonCommandPump.enqueue() → apiPost(/api/command)
```

### 10.7 Reverse usage of hot functions
- `applyFirmwareRuntimeState` is called by: `preloadFirmwareRuntimeState`, `syncRuntimeStateFromFirmware`, `syncRuntimeSummaryFromFirmware`, `sendAuxCommand`, `buttonCommandPump.onResult`, `startScroll`, `pauseScroll`, `resumeScroll`, `stopScroll`, `uploadScrollTimelineAttempt`.
- `touchRuntimeState` (firmware version bump) is called by ~all mutators: `publishPackedFrameNow`, `setMode`, `setAutoInterval`, `saveRuntimeSettings`, `writeSavedFaces`, `loadSavedFaces`, button handlers, scroll FSM, power publish.
- `renderCurrentFrameToLedStrip` is called by: Core-1 task (normal), `setup()` (boot), `loop()` single-core fallback.

### 10.8 Apparently unused / dead
- `applyPackedFrame()` (non-immediate, `led_renderer.cpp:357`) — defined + declared, **no callers** (verified by grep). The immediate variant is used everywhere instead.

---

## 11. Protocols and Data Encoding

### 11.1 M370 frame format
- **Form:** `M370:` + exactly 93 uppercase hex chars (`M370_HEX_CHARS=93`). 93×4 = 372 bits, of which the first 370 are LED states (`M370_BITS=370`); top 2 bits ignored.
- **Generated:** browser `frameToM370` (and firmware `blankM370`); **parsed:** `normalizeM370`→`decodeNormalizedM370ToPackedBits` (`led_renderer.cpp:280/323`). Bit order: logical row-major; nibble `nib` covers bits `nib*4..nib*4+3`, MSB-first within nibble.
- **Validation:** non-hex char → reject; wrong length → reject. `applyM370` increments `framesRejected` on failure.
- **Packed storage:** `FRAME_BYTES = (370+7)/8 = 47` bytes, bit i at `byte i>>3`, mask `1<<(i&7)`.
- **Example (from saved_faces.json):** `M370:00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000` (face_08, startup default).

### 11.2 Scroll upload protocol (`/api/scroll`)
- **Body fields:** `frames:[m370,...]`, `append:bool`, `start:bool`, `chunkIndex:uint`, `totalFrames:uint`, `timelineId/fontId/generatorVersion:string`, `sourceText:string`, `fps`/`intervalMs`, `storage:"ram"`, `source`.
- **Integrity rules (firmware-enforced):**
  - First chunk (`append:false`): pre-flight validate **all** frames before clearing state; `totalFrames≤MAX_SCROLL_FRAMES`; if `timelineId` present then `totalFrames>0` required (`E2`); `sourceText` requires `timelineId`+`fontId`+`generatorVersion` (`D1`) and valid UTF-8 (`validateScrollSourceText`); meta ids must match `[A-Za-z0-9._:-]` (`validateMetaIdString`).
  - Append chunks: must match cached `timelineId`, `chunkIndex==nextChunkIndex`, reject if `uploadComplete` (`D3`).
  - Over-count → 409 + cache invalidation but `sourceText` preserved (`EH-A`).
- **Failure behavior:** 400 (malformed/invalid frame), 409 (timeline/chunk conflict), 413 (too many frames), 507 (buffer alloc). On conflict the browser retries once with a new `timelineId`.
- **Streaming parse:** `handleApiScroll` doesn't fully deserialize frames into ArduinoJson; it scans the `frames` array region directly (`jsonFieldValueOffset` + `extractJsonStringAt`) to avoid large allocations.

### 11.3 Scroll meta (`/api/scroll/meta`)
- Read-side counterpart: returns `scrollTimelineId`, `sourceText`, `fontId`, `generatorVersion`, `uiFps`, `frameCount`, `frameIndex`, `uploadComplete`, scroll active/paused. Copies meta + source text **under `scrollMutex`** into a heap buffer, serializes outside the lock; alloc failure → 507.

### 11.4 Status JSON (`/api/status`)
- `renderer` (color, brightness, mode, playback, paused, autoInterval, autoFaceCount/Index, scroll fields, `lastM370` [omitted while scrolling/summary], `lit`, `lastReason`, `scrollStopEvent`), `power`, `ap`, `matrix`, `endpoints`, `storage`, `stats`, `memory`. Supports `since`/`runtimeOnly`/`summary`/`noFrame`/`fullPower` query knobs and `unchanged:true` short-circuit.

### 11.5 Persistence formats (LittleFS)
- `saved_faces.json`: `{format:"rina_faces_370_v2", category:"unified_saved_faces", startupDefaultId, faces:[{id,name,type,m370,order,...}]}`. Atomic write via temp+rename (`writeStringToFileLocked`).
- `runtime_settings.json`: `{format:"rina_runtime_settings_v1", mode, autoIntervalMs}`.
- `battery_calib.json`: `{format:"rina_battery_calibration_v1", v_min, v_max, ...}`.
- **Browser-side**: no localStorage/IndexedDB; the only persistence is via firmware POST or File System Access local file. (The widget guidance against browser storage matches actual code — none is used.)

### 11.6 Color / brightness encoding
- Color: `#RRGGBB` (or `RRGGBB`), parsed by `parseColorHex`, stored as 3 bytes + hex string. Brightness: raw 10–200 (Adafruit scale), button step 8, overlay shows % of 200.

---

## 12. WebUI Structure

### 12.1 Page / section map (`index.html`)
Five `<section class="page">`: `#page-basic` (color/brightness/auto-interval/mode + read-only preview), `#page-custom` (draw board + M370 + face manager), `#page-parts` (eye/mouth/cheek composer + manager), `#page-scroll` (text input, fps, play controls, preview), `#page-debug` (11 cards: device summary, firmware health, power/ADC, network, GPIO simulator, M370 protocol lab, debug preview, resources, comms log, raw command, danger zone). Loading overlay + hamburger page nav are outside `.app`.

### 12.2 UI element → handler map (representative)

| UI element | DOM id/class | Handler | Calls API? | Updates state? | Firmware effect |
|---|---|---|---|---|---|
| Color input | `#color-input` | `initColorInput`/`setColor` | `set_color` | `state.color` | LED color |
| Brightness slider | `#brightness-range` | `initBrightness`/`setBrightness` | `set_brightness` | `state.brightness` | LED brightness |
| Mode toggle | `#mode-toggle` | `toggleMode` | `set_mode` | `state.mode` | auto/manual |
| Next/Prev face | `#face-next/#face-prev` | `nextFace/prevFace` | button | `state.faceIndex` | face change |
| Interval ± | `#interval-up/down` | `adjustInterval` | `set_auto_interval` | `state.autoInterval` | cycle speed |
| Custom send | `#custom-send` | `sendCustomFrame`→`setCurrentFrame` | `/api/frame` | frame | LED frame |
| Parts apply | `#parts-apply` | `sendPartsFrame` | `/api/frame` | frame | LED frame |
| Scroll play | `#scroll-play` | `startScroll` | `/api/scroll`+`start_scroll` | scroll.* | LED scroll |
| Scroll pause/stop/step | `#scroll-pause/stop/step-*` | `togglePauseScroll/stopScroll/setScrollStepHandler` | command | scroll.* | scroll control |
| GPIO sim | `.debug-sim[data-gpio]` | `runDebugSimCommand` | command/button | per-action | per-button |
| Save faces | `.faces-json-*` | `persistFaceDocuments` etc. | `/api/saved_faces` | library | reload faces |
| Raw command | `#debug-raw-send` | raw `/api/command` | command | per | per |

### 12.3 WebUI variable map (key globals, `app.js:3454+`)

| Variable | Purpose | Updated by | Read by | Mirrors firmware? | Risk |
|---|---|---|---|---|---|
| `state` | UI mirror of device runtime + battery + network | `applyFirmwareRuntimeState`, local setters | render fns | yes | medium |
| `firmware` | Connection/queue diagnostics (browser-side counters) | api wrappers, pumps | `renderDebugFirmwareHealth` | partly (online/status real) | low |
| `scroll` | Scroll playback/upload/restore state machine | scroll fns, sync | scroll UI | partly | high |
| `currentFrame`/`scrollFrame`/`partsFrame`/`editFrame`/`debugPreviewFrame` | local LED buffers | edits/sync | `renderMatrices` | reconstructed | medium |
| `defaultFaces`/`userFaces`/`faceLibraryDocument` | face library copy | load/import/persist | list UI | duplicate | medium |
| `firmwareStatusVersion`/`firmwareNextPollMs` | poll cursor + adaptive cadence | `rememberFirmwareStatusPoll` | pollers | yes | low |
| `pendingScrollMeta` | in-flight restore meta | restore flow | preview restore | n/a | high |
| busy flags (`scroll.*Busy`, `pauseToggleLocked`, `uploadGeneration`) | re-entrancy guards | scroll actions | scroll actions | n/a | medium |

### 12.4 Rendering flow
`renderMatrices` repaints all matrix views from their frame buffers; `fitMatrix`/`scheduleMatrixFitRender` recompute cell size on resize (ResizeObserver). `renderState` updates badges/diagnostics. `updateScrollUi` recomputes scroll button enable/labels from `scroll.*`. DPS (`updateDps`/`estimateFrameWatts`) warns >40 W.

### 12.5 Performance / desync risks (WebUI)
- 5 matrix views × 370 DOM cells; `renderMatrices` repaints frequently. `setDom*IfChanged` helpers minimize layout thrash for scroll UI but matrices repaint wholesale.
- `ark12.json` is ~2.5 MB JSON parsed in the browser (lazy) — first scroll-page entry can jank.
- Scroll preview timer (`advanceScroll` via `setInterval`) free-runs and can diverge from firmware index.

---

## 13. Concurrency, Timing, and Race Conditions

### 13.1 Mechanisms
- **FreeRTOS mutexes** (`sync.cpp`): `Frame`, `Scroll`, `Storage`, `HardwareBus`. Documented global order **Scroll → Frame → Storage → HardwareBus**; code intentionally avoids nesting.
- **Spinlocks** (`portMUX`): `sPowerStatusMux` (tear-free power snapshot), `sAnimMux` (overlay state), `ledRenderRequestMux` (ISR-safe render flag).
- **Task notify**: Core-0 wakes Core-1 render task via `notifyScrollRenderTask`.
- **Core affinity**: build flags pin Arduino/event/WebServer/buttons/power to Core 0; render/scroll to Core 1 — explicitly to protect WS2812/RMT timing from network load.

### 13.2 Concurrency table

| System | Timing mechanism | Shared state | Protection | Possible race/desync | Evidence |
|---|---|---|---|---|---|
| LED render | Core-1 task, `LED_RENDER_MIN_GAP_US=2500` pacing | `frameBits`, color, brightness | `frameMutex` snapshot + `HardwareBus` for show | none observed (snapshot under lock) | `led_renderer.cpp:211` |
| M370 queue | Core-0 only, ≥33 ms | `m370FrameQueue` | **no lock** — Core-0 invariant | corruption if ever called off Core 0 | `led_renderer.cpp:27` comment |
| Scroll playback | Core-1 interval | scroll meta + index | `scrollMutex` | browser preview drift (different timer) | `scroll.cpp:31` |
| Power | Core-0 1 s | `powerStatus` | `sPowerStatusMux` for consumer fields | minor (some fields written outside lock) | `power_monitor.cpp:318` |
| Overlay | Core-0 service + Core-1 read | `sAnim` | `sAnimMux` | power read correctly hoisted out of lock | `button_animations.cpp:543` |
| WebUI frame/cmd | browser `setTimeout` queues | `state`/`scroll` | busy flags, `uploadGeneration` | stale upload, pause/resume races | `app.js:4898` |
| Status poll | adaptive `setInterval` | `state`/`scroll` | in-flight guards | overlapping summary vs full | `app.js:5734` |

### 13.3 Specific questions
- **Can WebUI commands modify frame state while the LED task renders?** Yes, but safely: writers hold `frameMutex`; the render task snapshots `frameBits`+color+brightness under the same lock before output (`renderCurrentFrameToLedStrip:220`).
- **Can scroll text and manual/auto playback conflict?** They are mutually exclusive by design: starting scroll forces manual and sets `restoreAutoAfterScroll`; manual/auto face actions call `stopFirmwareScroll` first (`buttons.cpp:117`, `web_api.cpp commandTerminateOtherActivities`). Browser `terminateOtherActivities` mirrors this.
- **Can stop/pause/resume race?** On firmware, all run on Core 0 cooperatively (no overlap). On the browser, `scroll.commandBusy`/`pauseToggleLocked`/`stopBusy` serialize them; an unconfirmed command keeps prior state and waits for the next poll.
- **Can brightness change during a show?** The render task reads brightness under `frameMutex` before `strip.setBrightness`; no partial application.
- **Can the WebUI preview differ from firmware?** Yes — the strongest desync point. During active scroll the browser advances its own preview timer; the firmware advances independently; only periodic `scrollFrameIndex` from polling nudges the browser. After reload, exact frame binding requires generator+fontId+frame-count match, else the preview is "reference only" with a warning.
- **Can a reload lose state firmware still has?** Browser-only state (busy flags, unsent textarea edits) yes; firmware state is recovered by polling + `/api/scroll/meta`. Scroll cache itself is RAM-only and survives reload but not reboot.
- **Can button input and WebUI command conflict?** Both mutate `runtimeState` on Core 0 cooperatively, so no torn state; logically the last writer wins and the browser reconciles on next poll.
- **Critical sections correctly scoped?** Mostly. The previously-reported nested-spinlock (audit M1) is fixed: `serviceButtonAnimations` snapshots power **outside** `sAnimMux` (`button_animations.cpp:543-549`). The HTTP-path scroll handlers do follow the "serialize outside the lock" rule (e.g. `commandStartScroll` extracts `timelineId` to a stack buffer before locking). **However, the "no heap `String` writes inside `frameMutex`/`scrollMutex`" contract is not fully honored in `faces.cpp`:** `setFirmwareScrollPauseFlag` copies/compares Arduino `String` values inside `withScrollLock` (`faces.cpp:304`, `oldPlayback = runtimeState().playback`), and `startFirmwareScroll` assigns `runtimeState().mode`/`playback` String literals inside `withScrollLock` (`faces.cpp:362,371`). These run only on Core 0 and the strings are short (SSO-eligible), so it is not a known live bug, but it does violate the documented lock contract and could allocate under the lock. This should be flagged as a P2 cleanup.

---

## 14. Hidden, Dead, Duplicate, or Unclear Code

| Issue type | File/function | Evidence | Impact | Recommendation |
|---|---|---|---|---|
| Dead function | `applyPackedFrame` (`led_renderer.cpp:357`) | grep: only definition+declaration, no callers; `applyPackedFrameImmediate` used everywhere | none (harmless) | remove or document why retained |
| Stale constant | `DEFAULT_STARTUP_FACE_ID="face_07_triangle_eyes_frown"` (`WEBUI_CONFIG.faces.startupFaceId`) | no face has that id; real startup is `face_08_triangle_eyes_frown`; face_07 id is `face_07_wide_eyebrows_tiny_mouth` | none today (fallbacks mask it) | fix to `face_08...` or remove; rely on file's `startupDefaultId` |
| Stale audit doc | `AUDIT_REPORT.md` C1/M1/L1 | C1 overflow guarded at `storage.cpp:289`+`validateSavedFaces:193`; L1 `lastReason` now `[M370_FRAME_REASON_CHARS=64]` (`state.h:84`); M1 hoisted (`button_animations.cpp:543`) | misleading to readers | re-run/refresh audit; mark fixed items |
| Intentional no-op | `updateBatteryCalibration` (`power_monitor.cpp:170`) | body discards `vbat`/`freezeCalibration`; comment says auto-calibration disabled | dead params; only manual reset moves window | keep but drop unused params or comment clearly (it does comment) |
| Minor display bug | battery overlay phase 2 (`button_animations.cpp:318`) | charge voltage drawn as `"%.1f"` with no unit, unlike phase 1 `"%.1fV"` | cosmetic | add `V`/distinct unit |
| Duplicated state | face library (firmware `autoFaces_` vs browser `faceLibraryDocument`) | both hold full list; orders re-assigned client-side | drift if writes fail mid-way | single canonical save path + post-write reload (already partially done) |
| Duplicated frame logic | M370 encode/decode in both C++ and JS | `led_renderer.cpp` vs `frameToM370/m370ToFrame` + scroll gen | must stay bit-compatible | covered by `tools/test_m370_boundary.js`; add JS↔C++ golden vectors |
| UI-only / simulated | debug ADC inputs (`#battery-v/#charge-v`) | label says "浏览器本地模拟,不读取真实硬件" | could confuse | clearly labeled already |
| Unclear ownership | `scroll.framesTimelineId` binding rules (`D5/E4/C5`) | spread across `restoreScrollPreviewIfNeeded`, `applyFirmwareRuntimeState`, `prepareTextScrollTimelineForRestoreAsync` | high cognitive load | extract a documented state machine |
| Large planning docs | `plan.md` (347 KB), `refactor_plan.md` (163 KB), `PAGE_6_5_DEBUG_REWRITE_PLAN.md` (79 KB) | not runtime | repo bloat | move to `docs/` or archive |

No firmware endpoint is un-called by the WebUI, and no WebUI call targets a missing endpoint — the 7 endpoints + command table are fully matched (`API_ENDPOINTS` in `app.js` mirror `server.on` registrations). `terminate_other_activities` and `battery_overlay` are firmware-real and UI-reachable.

---

## 15. Text Architecture Diagrams

### 15.1 High-level
```
┌────────────────────────── Browser (data/app.js) ──────────────────────────┐
│  state{}  scroll{}  firmware{}   matrices×5   face library copy            │
│  applyFirmwareRuntimeState()  ⇄  frameSendPump / buttonCommandPump / aux   │
└──────────────▲───────────────────────────────────────────────┬───────────┘
               │ HTTP/JSON over SoftAP (rina.io, 192.168.x)     │
        GET /api/status?since=v, /api/power, /api/scroll/meta   │ POST /api/frame,
               │                                                │ /api/command, /api/scroll,
┌──────────────┴────────────────────────────────────────────────▼───────────┐
│                      Firmware WebServer (web_api.cpp, Core 0)               │
│  handleApiStatus/Power/Frame/Scroll/ScrollMeta/Command/SavedFaces          │
└───────┬───────────────────────┬───────────────────────┬───────────────────┘
        │ touchRuntimeState()    │                       │
┌───────▼─────────┐   ┌──────────▼──────────┐   ┌────────▼─────────┐
│ RuntimeStore     │   │ faces/scroll FSM    │   │ storage (LittleFS)│
│ (state.h)        │   │ (faces.cpp)         │   │ saved_faces/json  │
│ frameBits, meta, │   └──────────┬──────────┘   └──────────────────┘
│ scroll cache     │              │ mutex-guarded shared state
└───────┬──────────┘              │
        │ frameMutex/scrollMutex  │
┌───────▼──────────────────────────▼─────────────────────────────────────────┐
│ Core 1 LED render/scroll task (scroll.cpp) → renderCurrentFrameToLedStrip   │
│ Core 0 drivers: buttons.cpp (GPIO) · power_monitor.cpp (ADC) · overlays     │
└───────┬───────────────────┬───────────────────────┬────────────────────────┘
        ▼ WS2812 (GPIO2)     ▼ ADC GPIO10/1           ▼ Buttons GPIO17..42
```

### 15.2 WebUI command flow
```
User action → DOM event → JS handler (e.g. setBrightness)
 → optimistic local apply (applyBrightnessLocal)
 → sendAuxCommand / pump.enqueue → apiPost(/api/command|/api/frame)
 → handleApiCommand → route handler → setBrightness()/setColor()/setMode()...
 → withFrameLock mutate runtimeState → touchRuntimeState() → showCurrentFrameNoLock()
 → Core-1 render → strip.show()  (hardware)
 → JSON reply → applyFirmwareRuntimeState() → state.* → renderState/renderMatrices
```

### 15.3 Hardware event flow
```
Button/ADC event
 → Core-0 service (serviceHardwareButtons / servicePowerMonitor)
 → runButtonAction / sampleBattery → mutate runtimeState/powerStatus (+ touchRuntimeState)
 → LED effect (face/brightness/overlay) via requestLedRender → Core-1 show
 → status version bumped
 → WebUI poll /api/status|/api/power → applyFirmwareRuntimeState/applyPowerData → UI refresh
```

### 15.4 Scroll text flow
```
Text input (#scroll-text)
 → buildTextScrollBitmap (Ark Pixel glyphs) → extractFrameFromTextImage → scroll.frames[]
 → uploadFirmwareScrollTimeline → chunked POST /api/scroll (timelineId, chunkIndex, sourceText@chunk0)
 → handleApiScroll: validate → write scrollFrameBits[] → uploadComplete when framesReceived≥total
 → POST /api/command start_scroll → startFirmwareScroll → playback="scroll"
 → Core-1 scrollRenderTask advances scrollFrameIndex on interval → strip.show()
 → reload: GET /api/scroll/meta → restoreScrollTextFromFirmware (refill text, guard unsent edits)
          → restoreScrollPreviewIfNeeded (regenerate frames; bind framesTimelineId iff exact match)
          → re-sync by frameIndex
```

### 15.5 Saved face flow
```
Create/edit/reorder/delete in 6.2/6.3
 → buildUnifiedFaceDocument → persistFaceDocuments
     ├ (optional) File System Access write to local saved_faces.json
     └ POST /api/saved_faces {document}
 → validateSavedFaces (category, ≤128, ≥1 default, valid M370)
 → writeSavedFaces (atomic temp+rename) → ++savedFacesWrites → touchRuntimeState
 → loadSavedFaces(false) reloads table, re-applies current face
 → reply → WebUI renderSavedFaces (list refresh)
```

---

## 16. Risks and Refactor Recommendations

| Priority | Area | Problem | Evidence | Recommended fix |
|---|---|---|---|---|
| P1 | Scroll sync | Browser preview timer free-runs vs firmware index; after reload exact binding is fragile (generator/fontId/count gates) | `advanceScroll` (`app.js:8729`), `restoreScrollPreviewIfNeeded` (`:9198`) | Make firmware push current `scrollFrameIndex` in summary polls authoritative for the preview during active playback; or drive preview purely from polled index when `firmwareBacked` |
| P1 | Scroll FSM complexity | `scroll{}` has ~30 fields + many busy flags; restore/identity logic split across 5 functions | `app.js:3565`, `4837`, `9055`, `9198` | Extract an explicit, documented scroll state machine module with one transition function |
| P1 | State duplication | Face library duplicated in firmware RAM and browser; order reassigned client-side; partial-failure divergence | `buildUnifiedFaceDocument`/`autoFaces_` | Always reload from firmware after a successful POST; treat firmware file as canonical, browser as view |
| P2 | Brightness echo | 2 s echo-suppression window can show stale value if a real change arrives mid-window | `applyFirmwareRuntimeState:4726` | Use a per-control "last local intent" token compared to firmware version instead of a wall-clock window |
| P2 | Rendering cost | 5×370 DOM matrices repainted wholesale; 2.5 MB font parse on first scroll entry | `renderMatrices`, `loadArkPixelFontTable` | Diff-based cell updates; stream/precompute glyph table or ship a compact binary font |
| P2 | Frame queue lock | `m370FrameQueue` is lock-free by Core-0 invariant only | `led_renderer.cpp:27` | Add a static-assert/comment guard or a lightweight lock if any caller might move off Core 0 |
| P2 | Lock contract violation | `String` copies/assignments inside `withScrollLock` despite the "serialize outside the lock" contract | `faces.cpp:304` (`oldPlayback`), `:362/:371` (`mode`/`playback`) | Move String reads/writes outside the scroll lock (snapshot scalars under lock, mutate Strings after), or relax the documented contract |
| P3 | Dead/stale code | `applyPackedFrame` unused; `DEFAULT_STARTUP_FACE_ID` wrong; stale `AUDIT_REPORT.md` | §14 | Remove dead fn, fix constant, refresh audit |
| P3 | Cosmetic | Battery overlay phase-2 voltage missing unit | `button_animations.cpp:318` | Add unit suffix |
| P3 | Docs/bloat | 590 KB of planning markdown at repo root | `plan.md` etc. | Move to `docs/`/archive |
| P3 | Protocol parity | M370 + scroll-frame encoding duplicated in C++ and JS | §14 | Shared golden test vectors covering both decoders |

**Missing abstraction boundaries:** a single "scroll session" object on each side; a "device state mirror" reducer in the browser instead of one 280-line `applyFirmwareRuntimeState`. **Suggested module boundaries:** firmware `scroll_session.cpp` (split scroll FSM out of `faces.cpp`), browser `scrollMachine.js` + `deviceMirror.js`. **Suggested naming:** distinguish `firmwareScroll*` (device) from `scroll.*` (browser) consistently; rename `applyPackedFrame`/`applyPackedFrameImmediate` to make the queued vs immediate distinction obvious (or delete the unused one). **Suggested tests:** loader fixture with >128 faces (regression for the formerly-critical overflow), JS↔C++ M370 golden vectors, scroll upload conflict (409 retry) integration test, battery LUT boundary test. **Suggested logging:** structured scroll-restore trace already exists (`logScrollRestoreDebug`); add a firmware-side counter for scroll cache invalidations and a `scrollFrameIndex` sample in summary status (already present) used to detect drift.

---

## 17. Files to Read First (for a new engineer)

1. `src/config.h` — every constant, pin, and matrix-geometry fact lives here.
2. `src/state.h` — the shared `RuntimeStore` and the lock/ownership contract comments.
3. `src/main.cpp` — exact bring-up order and the Core-0 loop.
4. `src/web_api.cpp` — the entire HTTP contract and command dispatch table.
5. `src/faces.cpp` + `src/scroll.cpp` — the mode/scroll state machine and Core-1 render task.
6. `src/led_renderer.cpp` — M370 encoding, the frame queue, and the actual pixel output.
7. `data/app.js` in this order: `WEBUI_CONFIG` (top), `state/firmware/scroll` objects (`:3454`), `applyFirmwareRuntimeState` (`:4586`), `makeRateLimitedQueue` (`:4898`), `bootstrapWebUi` (`:10717`), then the scroll cluster (`:8271`–`:9304`).
8. `src/power_monitor.cpp` — the most self-contained subsystem, good warm-up.

---

## 18. Open Questions / Things the Code Does Not Make Clear

1. **Scroll preview drift policy.** The code accepts that the browser preview and physical LEDs run on independent timers during active scroll, but there is no explicit spec for how much drift is acceptable or when a re-sync is forced. The summary poll carries `scrollFrameIndex`, but `advanceScroll` overwrites it every local tick — is the local timer meant to be cosmetic only?
2. **`B6+B3` network-info action is WebUI-only.** The debug UI exposes a `B6B3` button (`app.js:10553`) that merely calls `syncRuntimeStateFromFirmware("debug_gpio_B6B3_network_info")` — i.e. it re-fetches `/api/status` to refresh the network panel. There is **no** corresponding firmware GPIO combo or LED overlay (`button_animations.cpp` only has mode/interval/brightness/battery kinds; `buttons.cpp` only wires `B3B1`/`B3B2`). So the on-device hardware combo does nothing network-related; it is unclear whether a physical network-info overlay was ever intended.
3. **`MAX_AUTO_FACES` vs UI.** Firmware caps at 128 faces and now rejects more; the browser does not appear to warn the user before a save that would exceed this. Intended UX on overflow is unspecified.
4. **`updateBatteryCalibration` future intent.** It is a deliberate no-op with unused params — is auto min/max calibration meant to return, or should the scaffolding be removed?
5. **Single-core fallback fidelity.** If `initSyncPrimitives()` fails, the design drops to single-core (`loop()` renders directly) and disables the scroll task. The behavioral differences (scroll unavailable, timing) are not documented for the user/UI.
6. **`faceId` echo in `/api/frame`.** `handleApiFrame` accepts an optional `faceId` to sync `autoFaceIndex`, but the browser's normal custom/parts sends don't pass it; it's unclear which client path (if any) uses this.
7. **Stale `AUDIT_REPORT.md`.** Because the doc lists already-fixed bugs, it is unclear whether there is a newer audit of record or whether the fixes were validated against the same reproduction steps.


## 4. Code Audit Findings and Known Bugs

### Audit Report

_Source: `AUDIT_REPORT.md`_

Scope: full repo audit for real bugs, UB, data races, memory corruption, protocol/API mismatches, build/parse failures, and hardware-safety edge cases. Files read in full: `platformio.ini`, all `src/*.h` and `src/*.cpp`, `data/index.html`, `data/app.js` (verified parse only — 352 KB), `data/resources/*.json`, `tools/test_m370_boundary.js`, and the matrix config in `data/app.js`.

Checks run:

Second-pass verification (2026-06-18):
- Codex bundled Node runtime: `node --check data/app.js` **pass**.
- Codex bundled Node runtime: `node tools/test_m370_boundary.js` **pass** ("M370 boundary tests passed").
- `pio run` **pass** (RAM 17.3%, flash 42.5%).
- `pio run -t buildfs` **pass** (LittleFS image built; gzip asset hooks completed).
- `data/resources/*.json` parse with PowerShell `ConvertFrom-Json`: **pass** for `battery_calib.json`, `runtime_settings.json`, and `saved_faces.json`.

Original check notes from the first audit:
- `node --check data/app.js` → **pass** (clean parse, no unterminated strings; the "mojibake" is valid UTF-8 Chinese in string/comment literals).
- `node tools/test_m370_boundary.js` → **pass** ("M370 boundary tests passed").
- `index.html`: balanced `<script>`/`</script>`, valid DOCTYPE, 30.7 KB.
- All three `data/resources/*.json` parse; `saved_faces.json` has 11 valid default faces (`category=unified_saved_faces`).
- `pio run` / `pio run -t buildfs`: **not runnable in this environment** (no PlatformIO toolchain/SDK). Recommended to run locally — see notes per finding.

---

## CRITICAL

### C1 — `loadSavedFaces()` writes past the fixed `autoFaces_[MAX_AUTO_FACES]` array (heap/data corruption)

> **Status (2026-06-18): FIXED in current source.** The load loop now caps at `MAX_AUTO_FACES` (`src/storage.cpp:289-293`, `break` on overflow) and the POST validator rejects oversized documents (`src/storage.cpp:193-196`, `faces.size() > MAX_AUTO_FACES`). The original analysis below is retained for history.

- Severity: **Critical** (memory corruption; persistent; remotely reachable)
- Files / lines:
  - `src/storage.cpp:284-305` (the load loop, write at `:293`)
  - `src/storage.cpp:181-224` (`validateSavedFaces` — missing the same limit)
  - Backing storage: `src/state.h:177` (`RuntimeFace autoFaces_[MAX_AUTO_FACES]`, `MAX_AUTO_FACES = 128`, `config.h:112`)

Why it is a real bug
The load loop iterates over *every* element of the JSON `faces` array and, for each face whose `m370` normalizes, writes:
```cpp
RuntimeFace& runtime = runtimeAutoFaces()[runtimeAutoFaceCount()++];   // storage.cpp:293
```
There is no `runtimeAutoFaceCount() < MAX_AUTO_FACES` guard. `autoFaces_` is a fixed array of 128 `RuntimeFace`. `RuntimeFace` contains three heap-backed `String` members (`id`, `name`, `m370`). Once the index reaches 128, the code constructs/assigns `String`s into memory beyond the array — directly into adjacent `RuntimeStore` members (`autoFaceCount_`, `frameBits_`, `scrollFrameBits_` pointer, `scrollMeta_`, …) and then past the object. This is out-of-bounds write of String objects (writes heap pointers/lengths) → memory corruption, and on the `m370` assignment can free/overwrite arbitrary heap.

`validateSavedFaces()` (the gate for `POST /api/saved_faces`) also enforces no upper bound, so the corrupt file is accepted, **persisted to LittleFS**, then immediately loaded:
`web_api.cpp:1462` validate → `:1464` `writeSavedFaces` → `:1467` `loadSavedFaces(false)` → overflow. Because it is persisted, the device then **overflows on every subsequent boot** (`main.cpp:56 loadSavedFaces(true)`).

Minimal repro
`POST /api/saved_faces` with a body containing 129+ faces, each with `type:"default"`, a valid `order>=1`, and a valid 93-hex `m370` (at least one `type:"default"` already required). Validation passes, the file is written, `loadSavedFaces` runs, and the 129th valid face writes past `autoFaces_[127]`.

Expected vs actual
Expected: loader caps at `MAX_AUTO_FACES` (drop/reject extras), validator rejects > `MAX_AUTO_FACES`. Actual: unbounded write → corruption / crash / persisted brick.

Suggested fix
```cpp
// storage.cpp load loop:
for (JsonObject face : faces) {
    if (runtimeAutoFaceCount() >= MAX_AUTO_FACES) {
        Serial.printf("saved_faces.json exceeds MAX_AUTO_FACES=%u; extra faces ignored\n", MAX_AUTO_FACES);
        break;
    }
    ...
}
```
And reject at validation time so nothing over the limit is ever persisted:
```cpp
// validateSavedFaces(): count faces, then
if (faceCount > MAX_AUTO_FACES) { error = "too many faces; max is 128"; return false; }
```

Caught by a test/build check? Not by `pio run`. Would be caught by a unit/integration test that loads a >128-face `saved_faces.json`, or by an on-device POST of 129+ faces. Recommend adding such a fixture test.

---

## MEDIUM

### M1 — Nested spinlocks: `readPowerStatusSnapshot()` called while holding `sAnimMux`

> **Status (2026-06-18): FIXED in current source.** `serviceButtonAnimations()` now snapshots power state **outside** the `sAnimMux` critical section (`src/button_animations.cpp:543-549`: `needPower` is read under the lock, the lock is released, `readPowerStatusSnapshot()` is called, then the lock is re-taken to update `sAnim`). No nested spinlock remains. The original analysis below is retained for history.

- Severity: **Medium** (no deadlock, but violates the project's own locking rules; long interrupts-disabled window on the WiFi/HTTP core)
- File / line: `src/button_animations.cpp:537-572`, offending call at `:542`

Why it is a real bug
`serviceButtonAnimations()` opens a critical section on `sAnimMux` at line 537, and inside it (battery-overlay-active branch) calls:
```cpp
const PowerStatus power = readPowerStatusSnapshot();   // :542
```
`readPowerStatusSnapshot()` (`power_monitor.cpp:451-461`) itself does `portENTER_CRITICAL(&sPowerStatusMux)` and copies the entire ~120-byte `PowerStatus` struct. So a second `portMUX` is taken nested inside the first, and a sizeable struct copy runs with interrupts disabled on Core 0 — the core that also runs WiFi/HTTP/DNS. `state.h`/`sync.h` explicitly document "Existing code intentionally avoids nested mutexes"; this is the spinlock analogue and the exact pattern the audit brief calls out ("critical sections that … lock another spinlock").

It is not a deadlock today (both spinlocks are only ever taken in this order, both on Core 0, and `power_monitor` never takes `sAnimMux`), so the impact is increased ISR/latency jitter, which can perturb the very WS2812/WiFi timing this design tries to protect.

Repro / trigger
Long-press B6 to start the repeating battery overlay (`batterySingleShot == false`); `serviceButtonAnimations()` then runs the nested-lock branch every loop iteration while the overlay is live.

Expected vs actual
Expected: snapshot power data *before* entering the `sAnimMux` critical section, then only copy small scalars under the lock. Actual: full power snapshot taken under two nested spinlocks.

Suggested fix
Hoist the read out of the critical section:
```cpp
PowerStatus power;
bool needPower = false;
portENTER_CRITICAL(&sAnimMux);
needPower = sAnim.active && sAnim.kind == OverlayKind::Battery && !sAnim.batterySingleShot;
portEXIT_CRITICAL(&sAnimMux);
if (needPower) power = readPowerStatusSnapshot();   // outside any spinlock
portENTER_CRITICAL(&sAnimMux);
// ...use `power` to update sAnim fields...
portEXIT_CRITICAL(&sAnimMux);
```

Caught by a test/build check? No — compiles and usually "works." Needs design review / lock-order lint.

---

## LOW

### L1 — `/api/status` truncates `lastReason` to 15 chars (`FrameStateSnapshot.lastReason[16]`)

> **Status (2026-06-18): FIXED in current source.** `FrameStateSnapshot.lastReason` is now sized `[M370_FRAME_REASON_CHARS]` = 64 (`src/state.h:84`, `src/config.h:106`), long enough for the longest runtime reason strings, so `/api/status` no longer truncates `renderer.lastReason`. The original analysis below is retained for history.

- Severity: **Low** (no corruption — `strlcpy` is bounds-safe — but a silent API-contract drift)
- Files / lines: `src/state.h:81` (`char lastReason[16]`), `src/led_renderer.cpp:204` (`strlcpy(s.lastReason, … , sizeof(s.lastReason))`), consumed at `src/web_api.cpp:518`.

Why it matters
Runtime reasons are frequently far longer than 15 chars (e.g. `firmware_text_scroll_stop_default_saved_face`, `startup_sequence_complete_saved_face`, `..._B3_clear_before_saved_face`). In `/api/status` the `renderer.lastReason` field is therefore truncated (to `"firmware_text_s"`), while the same value is sent **untruncated** elsewhere (`buildCommandReply` → `reply["lastReason"]` and `scrollStopEvent.reason`, both raw `String`). Any UI logic that prefix-matches `lastReason` from `/api/status` (the app matches reason prefixes like `text_scroll_`, `custom_`, `debug_`) sees a different value than from `/api/command`.

Expected vs actual
Expected: consistent reason string across endpoints. Actual: `/api/status` value is silently clipped to 15 chars.

Suggested fix
Enlarge the snapshot buffer to cover the longest reason actually used (e.g. `char lastReason[48];`), or serialize `runtimeState().lastReason` directly in the status handler under the frame lock as the command path does.

Caught by a build check? No. Caught by an API contract test comparing `lastReason` from `/api/status` vs `/api/command`.

### L2 — `HTTP_ANY` routes don't reject inappropriate methods (degrade-only)

- Severity: **Low** (AP-only device; safe degradation, but inconsistent with the brief's expectation)
- File / lines: `src/web_api.cpp:1533-1539`. `/api/status`, `/api/power`, `/api/frame`, `/api/command` are registered `HTTP_ANY` and never check `server.method()`.

`/api/scroll` (`:665-666`), `/api/scroll/meta` (`:983-984`), and `/api/saved_faces` (`:1482-1486`) *do* validate the method and return 405/handle OPTIONS. The four that don't will still behave safely: a `GET /api/frame` or `GET /api/command` hits `parseJsonBody` and returns `400 "empty JSON body"`; `POST /api/status` just returns full status. No state corruption, but a `DELETE`/`PUT` to `/api/status` returns 200 and there is no CORS preflight (`OPTIONS`) handling on these four (OPTIONS falls through to the handler instead of `handleOptions`).

Suggested fix: add the same `method()==HTTP_OPTIONS → handleOptions()` / non-GET-or-POST → 405 guard used by the other routes, for consistency and correct CORS preflight.

---

## Checked and OK (suspected issues disproven)

- **M370 93-hex / 372-bit vs 370-LED boundary.** Decode (`led_renderer.cpp:323-337`) guards `if (bit < M370_BITS)`; encode in firmware never sets bits 370/371; browser `frameToM370`/`m370ToFrame` (`app.js:4138-4163`) pad the last two bits to `0` and slice to `TOTAL_LEDS`. `tools/test_m370_boundary.js` passes, including the explicit 369/370/371 padding cases. Consistent end-to-end.
- **`ROW_LENGTHS`/`ROW_OFFSETS` coverage.** Sum = 370; `static_assert` at `config.h:96` holds; `app.js` `EXPRESSION_PARTS.matrix.row_lengths` (`:203`) and `num_leds:370` (`:202`) match `config.h` byte-for-byte, including serpentine flags.
- **Mutex ordering Scroll→Frame→Storage→HardwareBus.** No nested *mutex* found; all multi-domain sequences release one lock before taking the next (`led_renderer.cpp:220/261`, `scroll.cpp:31/60`, `faces.cpp`, `web_api.cpp` scroll upload). The only true cross-core concurrency (Core 1 scroll task vs Core 0 HTTP) is correctly partitioned.
- **Scroll append writes the frame buffer outside `scrollMutex` (`web_api.cpp:909`).** Safe: appended frames go to indices `>= scrollFrameCount`, while Core 1 only reads `< scrollFrameCount` (mod count); `scrollFrameCount` is published last under the lock (`:930`). Buffer base pointer is allocated once at boot and never realloced.
- **`normalizeM370` `compact[94]` buffer (`led_renderer.cpp:285-304`).** Writes are guarded by `if (compactLen < M370_HEX_CHARS)`; over-length input is rejected (`compactLen != M370_HEX_CHARS`).
- **`web_json.cpp` custom scanner.** Depth-limited (`JSON_MAX_DEPTH=32`), integer overflow-guarded (`:350`), string escape/`\u` surrogate handling and UTF-8 emission are bounds-checked; `extractJsonStringAt` indices stay in range.
- **`validateScrollSourceText` / `validateMetaIdString` (`utils.cpp`).** Correct UTF-8 validation (overlong, surrogate, >U+10FFFF, truncation) and length/charset caps; `sourceText` memcpy (`web_api.cpp:828`) is bounded by the prior `length() <= MAX_SCROLL_TEXT_BYTES` check and the `+1` buffer.
- **`handleApiScrollMeta` heap pairing (`web_api.cpp:982-1060`).** Every early-return path frees `textCopy`; `const char*` assigned to the doc stays valid until after `serializeJson` (freed only after `sendJsonDocument`).
- **"All LEDs on" debug path.** Gated by a `confirm()` power-warning in the UI (`app.js:10364-10377`) *and* firmware clamps brightness to `MAX_BRIGHTNESS=200` (`led_renderer.cpp:421`), so the worst case is bounded below full-white draw. Not a firmware hazard.
- **`PowerStatus` partial-field tearing.** Consumer-visible fields (`vbat`, `charging`, percent, valid/disconnected flags) are committed under `sPowerStatusMux`; only benign debug fields update outside it, and float reads/writes are single-word aligned.
- **Saved-faces / scroll-meta fixed char fields.** `strncpy` + explicit NUL (`web_api.cpp:816-825`), `memcpy` of `timelineId` into equally-sized buffers, and `commandStartScroll`'s pre-lock length check (`:1136`) all respect `MAX_SCROLL_*_CHARS`.
- **`data/app.js` parse & `data/index.html`.** Clean parse; the apparent corrupted regex/attributes are display artifacts of UTF-8 Chinese + CRLF, not actual breakage.

---

## Recommended checks to add to CI
Second-pass note: `pio run` and `pio run -t buildfs` both pass locally as of 2026-06-18; keep them in CI as regression gates rather than treating them as unverified.
1. `pio run` and `pio run -t buildfs` (could not run here — no toolchain).
2. `node --check data/app.js` and `node tools/test_m370_boundary.js` (both pass today).
3. New fixture test: load a `saved_faces.json` with >128 valid faces and assert the loader caps at 128 (guards C1).
4. API-contract test asserting `lastReason` is identical between `/api/status` and `/api/command` (guards L1).


## 5. Audit-Level Refactor and Bug-Fix Plan

### Refactor Plan

_Source: `refactor_plan.md`_

> Scope: full project — ESP32-S3 firmware (`src/*.cpp/.h`), Web UI (`data/app.js`, `data/index.html`, `data/styles.css`), and the WebUI↔firmware sync/protocol boundary.
> Status: **plan + concrete diffs**. Every bug item carries a reproduction path, a validation test, and a `Code change:` block with the actual current snippet and the proposed replacement. Every refactor item states what must remain unchanged and shows representative before/after code. (The "do not output replacement code" rule from the original brief is intentionally superseded here at the maintainer's request.)
> This document is independent of `plan.md` (which is a reconstruction spec, not a refactor plan).
>
> **Implementation status legend:** 🟢 = already applied to the codebase · ⬜ = proposed, not yet applied.

---

## 0. Consolidation update after `prompt.txt`

`prompt.txt` changes the interpretation of this plan: the audit remains useful, but the addendum is no longer optional background. Addendum bugs that can mutate state destructively or hide live scroll progress must be promoted into the canonical priority order before broad refactors.

### 0.1 Canonical priority corrections

| Priority | Canonical item | Source items merged | Reason |
|---|---|---|---|
| P0 | Protocol mutation gate | A3, A4, A5 | Invalid `/api/frame`, failed replacement `/api/scroll`, and malformed JSON escapes/trailing data must be rejected before state mutation. |
| P0 | Active-scroll status freshness | A1, A12 | `/api/status?since=` must not report `unchanged:true` while scroll-observable state changed, unless that behavior is deliberately documented and excluded from freshness semantics. |
| P1 | Cross-core snapshots | Bug 1 + A8, Bug 8 + A2 | Frame/status and power overlay reads need one canonical snapshot story and one severity each. |
| P1 | Lock fail-safe | Bug 7 + A9 | Mutex creation failure must not silently continue into unsynchronized dual-core operation. |
| P2 | Low-risk UI/firmware fixes | Bugs 2, 4, 5, 6, 9, 10, 11, 13, 14, A10, A11 | Valuable and mostly contained, now mostly applied; no longer the top of the remaining backlog. |
| Test-only | Codec padding invariant | Bug 12 | Keep as a round-trip/static-invariant test, not a runtime bug. |
| Hardening | EMA long-wrap edge | Bug 14 | 🟢 Applied; very low-probability robustness work. |

### 0.2 Applied since this plan was drafted

The following items are now applied in the codebase and should be treated as closed unless validation finds a regression:

- 🟢 Bug 2: scroll frame copy no longer depends on `!mainTaskRenderPending`; scroll active state is still rechecked under `Frame`.
- 🟢 Bug 4: WebUI default brightness is derived from `brightnessDefault` when present, otherwise firmware default `50`; the sticky `brightnessChangedByUser` latch was removed.
- 🟢 Bug 5: unchanged firmware color sync returns before DOM/render side effects after the first DOM sync.
- 🟢 Bug 6: corrupt `runtime_settings.json` is rewritten with defaults after parse failure.
- 🟢 Bug 11: `serviceM370FrameQueue` publishes from the queue slot instead of copying the whole queue item.
- 🟢 Bug 13: default face IDs with more than 9 numeric digits are rejected before integer multiplication.
- 🟢 A3: `/api/frame` normalizes/validates M370 before stopping scroll or mutating playback/mode.
- 🟢 A10: debug `data-gpio` buttons bind supported firmware button commands.
- 🟢 A11: manual debug JSON posts the raw `/api/command` object and requires a string `cmd`.
- 🟢 Bug 15: scroll-button flash fix was already applied; code evidence is in `data/app.js::updateButtonState`, where `aria-disabled` is kept in sync with `disabled`, and `updateScrollUi`, where scroll buttons are updated through that helper.
- 🟢 Bug 9: pause fallback no longer invents a user pause when split flags are absent; `/api/scroll/meta` now carries split pause flags.
- 🟢 Bug 10: first scroll-upload chunk sizing uses an estimate plus verification instead of brute-force full re-encoding.
- 🟢 Bug 14: battery EMA snaps to the instant sample after an implausibly large elapsed interval.

### 0.3 Gates before more refactoring

1. **Protocol mutation gate:** invalid `/api/frame` and failed `/api/scroll` replacement must leave active scroll and existing cache untouched.
2. **Status freshness gate:** active firmware scroll must be observable through `/api/status?since=` via either a dedicated scroll cursor or an explicit bypass of the `unchanged:true` shortcut.
3. **Storage/LED contention gate:** do not move LittleFS I/O off `HardwareBus` as a blind refactor. Any Storage-lock split requires hardware proof that simultaneous LittleFS writes and `strip.show()` do not corrupt LEDs or files.
4. **UI replay gate:** recorded status sequences must produce equivalent `state`/`scroll`/DOM results after `applyFirmwareRuntimeState` extraction.

---

## 1. Scope of analysis

### 1.1 Firmware (C++, PlatformIO / Arduino / FreeRTOS)

| File | Why relevant |
|---|---|
| `src/main.cpp` | Entry points `setup()`/`loop()`. Defines the boot ordering and the Core-0 cooperative service order. Any reordering risk lives here. |
| `src/state.h` / `src/state.cpp` | `RuntimeStore` singleton, `RuntimeState`, scroll buffers, `stateVersion` publish cursor. Central mutable state; lock-ownership contract documented in headers. |
| `src/config.h` / `src/config.cpp` | All hardware pins, matrix geometry, timing constants, defaults, battery LUT. Source of magic numbers and `static_assert` invariants. |
| `src/sync.h` / `src/sync.cpp` | FreeRTOS mutex wrappers (`Frame`, `Scroll`, `HardwareBus`) and lock ordering contract (`Scroll → Frame → HardwareBus`). Governs every cross-core access. |
| `src/led_renderer.cpp/.h` | M370 codec, frame bit helpers, frame queue, color/brightness, ISR-safe render-request flag, physical render to `Adafruit_NeoPixel`. The timing-critical core. |
| `src/scroll.cpp/.h` | Core-1 FreeRTOS scroll/render task; drift compensation; the only place that drives continuous frame output. |
| `src/faces.cpp/.h` | Mode (auto/manual), saved-face apply, deferred face restore state machine, firmware scroll lifecycle (`start/stop/pause`). High state-coupling. |
| `src/buttons.cpp/.h` | GPIO debounce, combos (B3+B1/B2), repeat, semantic button dispatch shared by GPIO and API. |
| `src/button_animations.cpp/.h` | Overlay state machine (mode/interval/brightness/battery), `portMUX`-guarded `sAnim`, scroll system-pause coupling. |
| `src/power_monitor.cpp/.h` | ADC sampling, EMA, battery LUT, disconnect detection, calibration persistence, fast/slow web publish dirty flags. |
| `src/storage.cpp/.h` | LittleFS mount, atomic JSON write, settings + saved-faces load/save, validation. All file I/O holds `HardwareBus`. |
| `src/web_api.cpp/.h` | SoftAP/DNS, all HTTP routes, JSON serialization, the 277-line `/api/scroll` upload handler and the command dispatch table. Largest single file (1491 lines). |
| `src/web_json.cpp/.h` | Hand-rolled JSON field extraction over the raw request body (used to avoid full ArduinoJson parse for scroll uploads). |
| `src/psram_json.h` | PSRAM-first ArduinoJson allocator. |
| `src/utils.cpp/.h` | hex/color/millis helpers, UTF-8 + meta-id validators. |

### 1.2 Web UI (vanilla JS/CSS/HTML, no build step)

| File / region | Why relevant |
|---|---|
| `data/index.html` | DOM IDs/classes consumed by `app.js` and `styles.css`. The contract surface for any DOM refactor. |
| `data/app.js` lines 27–3190 | `WEBUI_CONFIG` + `EXPRESSION_PARTS` (≈3000 lines of static data: parts/colors/matrix geometry). Pure data; rarely the bug source but dominates file size. |
| `app.js` 3191–3630 | Derived constants, matrix index maps, the global `state` / `scroll` / `firmware` objects. Central UI state. |
| `app.js` 4255–4441 | `apiUrl` / `apiGet` / `apiPost` / `apiPostWithUploadProgress` — the only firmware transport entry points. |
| `app.js` 4450–4923 | Power apply + `applyFirmwareRuntimeState` (260-line merge of `/api/status` into UI state). The sync hub. |
| `app.js` 4933–5160 | Button-command and frame-send queues (rate-limited, drop-on-overflow). |
| `app.js` 5222–5361 | `terminateOtherActivities` / `guardBeforeOutput` / `setCurrentFrame` / `setColor` / `setBrightness` — mode mutual-exclusion + local echo. |
| `app.js` 5378–5956 | Boot sequence, status polling, power polling, timer lifecycle. |
| `app.js` 8331–9765 | Scroll subsystem: text→bitmap→frames, chunked timeline upload, start/pause/resume/stop/step, source-text restore from firmware. The most complex async region. |
| `app.js` 9937–10150 | `updateScrollUi` and DOM-diff helpers. |
| `app.js` 10150–10520 | UI init, first-page reveal, `bootstrapWebUi`. |
| `data/styles.css` | 3246 lines; layout/animation. Reviewed structurally; not the source of logic bugs but a refactor/maintainability surface. |

### 1.3 Sync / protocol boundary

`/api/status` (+`since`/`runtimeOnly`/`noFrame`/`summary`/`fullPower` query flags), `/api/power`, `/api/frame`, `/api/scroll`, `/api/scroll/meta`, `/api/command` (16-command dispatch table), `/api/saved_faces`. JSON field names, the `stateVersion`/`since` long-poll cursor, the `scrollStopEvent` sequence, and the timeline-upload state machine (`append`, `chunkIndex`, `totalFrames`, `uploadComplete`, `timelineId`).

---

## 2. Current behavior map

### 2.1 Startup / init flow (firmware)

`setup()` runs on Core 0 in this exact order (semantics depend on it):

1. Drive `LED_PIN` LOW, hold `LED_BOOT_DATA_LOW_HOLD_MS`, then `delayMicroseconds(LED_SIGNAL_RESET_US)` — prevents WS2812 latching floating data before the bus is driven.
2. `Serial.begin(115200)`, `delay(200)`, record `runtimeState().bootMs = millis()` (used later for `uptimeMs`).
3. `initRuntimeScrollFrameBuffer()` — allocates the ≈140 KB scroll frame buffer and the source-text buffer (PSRAM first, internal SRAM fallback). Allocation failure is non-fatal: text uploads later return 507.
4. `initSyncPrimitives()` — creates the three mutexes. Failure prints a warning but boot continues (locks then become no-ops — see Bug 7).
5. `initLedIndexMap()` — precomputes logical→physical serpentine map.
6. `ledStripBegin()` — `strip.begin()`, brightness default, clear, `show()` once under `HardwareBus`. Then `delay(LED_BOOT_CLEAR_HOLD_MS)`.
7. `setColorStateNoRender(DEFAULT_COLOR)` — updates color fields only, no render queued.
8. Mount LittleFS. On failure → `showFilesystemErrorPattern()` (12 red LEDs). On success → `loadRuntimeSettings()` then `loadSavedFaces(true)` (applies startup face via `applyM370`).
9. `renderCurrentFrameToLedStrip()` once synchronously (Core 0), then `consumeLedRenderRequest()` to drain the request the load just queued, then `delay(LED_BOOT_STARTUP_SETTLE_MS)`.
10. `startScrollRenderTask()` — pins the render/scroll task to Core 1.
11. `initHardwareButtons()` — reads initial pin levels (debounce baseline).
12. `initPowerMonitor()` — loads calibration, configures ADC, samples once (`force`).
13. `startAccessPoint()` then `startWebServer()` — AP/DNS/HTTP last, so a connecting client sees a fully-initialized state.

### 2.2 Main loop (firmware, Core 0)

`loop()` calls, in order, every ~1 ms (`vTaskDelay(1)`):
`serviceM370FrameQueue()` → `webServerTick()` → `serviceRuntimeSlowStatePublish()` → `serviceHardwareButtons()` → `serviceButtonAnimations()` → `servicePowerMonitor()` → `serviceDeferredFaceRestore()` → `serviceAutoPlayback()`.

Order is intentional: dequeue/publish frame first, then HTTP, then publish the slow UI cursor, then react to buttons/API for this tick, then run deferred restore and auto-advance.

### 2.3 Render task (firmware, Core 1)

`scrollRenderTask` loops:
1. `consumeLedRenderRequest()` → `mainTaskRenderPending`.
2. Under `Scroll` lock: if scroll active+not paused+frames>0+buffer ready, and the per-frame interval elapsed, advance `scrollFrameIndex` (mod count), apply drift compensation (`lastScrollFrameMs += interval` unless drift > 4 intervals, then resync to `now`), `memcpy` the new frame to a local stack buffer, set `hasScrollFrame`.
3. If `hasScrollFrame`: under `Frame` lock, re-check a render request; if no pending main render and scroll still active, copy the local scroll frame into `runtimeFrameBits()` and `++framesAccepted`; otherwise drop it.
4. If `shouldRender`, `renderCurrentFrameToLedStrip()`.
5. `ulTaskNotifyTake(pdTRUE, 1ms)` — wakes on `notifyScrollRenderTask()` or times out.

`renderCurrentFrameToLedStrip()`: snapshot frame bits + color + brightness under `Frame` lock into locals; enforce `LED_RENDER_MIN_GAP_US` since last `show`; apply brightness if changed; if a button-animation overlay is active, fill `overlayRgb` per-pixel, else map frame bits → color; `delayMicroseconds(reset)`, `strip.show()` under `HardwareBus`, record `lastLedShowUs`, `delayMicroseconds(reset)`.

### 2.4 User interaction flow (hardware buttons)

`serviceHardwareButtons()` (Core 0) debounces each pin (`BUTTON_DEBOUNCE_MS`), edges → `handleHardwareButtonPress/Release`. Press handles combos (B3+B1 / B3+B2 fire `B3B1`/`B3B2` and mark B3 consumed), and immediate fire for repeatable buttons (B1/B2 face, B4/B5 brightness). Release fires B3 (mode toggle) only if not combo-consumed, and drives B6 overlay (short = battery page, long = continuous battery). `serviceHardwareButtonRepeats()` re-fires held face/brightness buttons after delay. `runButtonAction()` is the shared semantic dispatcher for both `gpio` and `api_button` sources.

### 2.5 Data generation / transmission / preview (Web UI)

- Color/brightness/mode/interval: local echo via `state` + DOM, then `sendAuxCommand` to `/api/command`.
- Custom & parts pages: compose a `currentFrame`/`partsFrame`, `queueFirmwareFrame` → `frameToM370` → rate-limited POST `/api/frame`.
- Scroll page: text → `buildTextScrollBitmap` (Ark pixel font) → frames; chunked upload to `/api/scroll` (`append:false` first chunk carries `timelineId`+`sourceText`+`fontId`+`generatorVersion`+`totalFrames`; subsequent chunks `append:true`+`chunkIndex`); then `start_scroll` command. A local `setInterval` advances the WebUI preview independently of firmware.

### 2.6 State synchronization flow

- WebUI long-polls `/api/status?since=<version>` (interval driven by `next_poll_ms`, faster when scrolling+on scroll page). `applyFirmwareRuntimeState` merges `renderer`/`power`/`ap`/`stats` into `state`/`scroll`/`firmware` and conditionally re-renders.
- Firmware bumps `stateVersion` via `touchRuntimeState()` on every meaningful change; `slowUiDirty` + `serviceRuntimeSlowStatePublish()` coalesce high-frequency power changes to one publish per `POWER_WEB_SLOW_PUBLISH_MS`.
- GPIO scroll interruptions publish a `scrollStopEvent{seq,ms,button,source,reason}`; the WebUI detects `seq` increase + `gpio` + B1/B2/B3 to mirror the stop and schedule a full resync.

### 2.7 Error / retry flow

- Firmware: validation failures return 400/405/409/413/507 with `{ok:false,error}`. Bad scroll frame data calls `invalidateScrollUploadLocked()` (keeps source text). Atomic JSON writes use temp+rename and remove temp on failure.
- WebUI: `apiGet/apiPost` add `AbortController` timeouts; `apiPostWithUploadProgress` uses `XMLHttpRequest`. Scroll upload retries once with a fresh `timelineId` on any 409. API errors are log-throttled (`shouldLogApiError`, 2.5 s). Button commands have a local `fallback`.

### 2.8 Stop / reset / cleanup

- `stopFirmwareScroll(restoreAuto, clearDisplay)`: cancel deferred restore, reset scroll state under lock (keep or clear timeline meta per `clearDisplay`), clear queued frames, optionally blank + schedule default-face restore, else optionally restore auto mode.
- `serviceDeferredFaceRestore()` fires after `LED_STOP_CLEAR_BLANK_HOLD_MS` so the blank frame physically latches before the saved face replaces it (no `delay()` in handlers).
- WebUI `stopScroll` clears its preview timer, sends `stop_scroll`, and resets scroll controls.
- `stopPollingTimers()` on `pagehide`.

### 2.9 Persistence

`runtime_settings.json` (mode, autoIntervalMs), `saved_faces.json` (unified default+user faces), `battery_calib.json` (manual min/max only — auto calibration is intentionally disabled). All via `writeJsonFileAtomic`. Scroll uploads are RAM-only by contract (any `persist`/`saveToFlash`/non-`ram` storage → 400).

---

## 3. State model audit

### 3.1 Firmware `RuntimeState` (defined `state.h`)

| Field(s) | Represents | Readers | Writers | Lock owner | Risk |
|---|---|---|---|---|---|
| `colorHex/R/G/B`, `brightness` | Active display color/brightness | render task (C1), web handlers (C0) | `setColor`/`setColorStateNoRender`/`setBrightness`, boot | `Frame` | Read unlocked in `handleApiStatus` (C0 vs C1 writes) — torn read (Bug 1). |
| `lastM370` (String) | Last applied frame text | `handleApiStatus` (C0) | `publishPackedFrameNow` under `Frame` (C0 + C1) | `Frame` | Heap `String` written under lock from two cores, read unlocked → torn read of a `String` (Bug 1, higher severity for String). |
| `lastReason` (String) | Last operation reason | status/handlers (C0) | many (C0); `publishPackedFrameNow` (C0+C1) | `Frame` partial | Mostly C0; `publishPackedFrameNow` path touches it on C1 too. |
| `mode`, `playback`, `paused` | Mode/playback state machine | C0 everywhere, render task reads `firmwareScroll*` not these | faces/web/buttons (C0) | Core-0 cooperative | `playback` overlaps `firmwareScroll*` booleans (redundant encoding). |
| `framesAccepted/Rejected/Queued/Dequeued/Dropped`, `commandsAccepted/Rejected`, `savedFacesWrites`, `settingsWrites` | Debug counters | `handleApiStatus` (C0) | enqueue/publish (C0); `framesAccepted` also C1 | mixed | `framesAccepted` incremented on C1 under `Frame`, read unlocked on C0 (Bug 1). |
| `stateVersion`, `slowUiDirty`, `lastSlowUiPublishMs` | UI publish cursor | WebUI via status; `serviceRuntimeSlowStatePublish` | `touchRuntimeState`/`...Slow` (C0); but `touchRuntimeState` is also reachable from C1? No — C1 only `++framesAccepted`. | Core-0 | Must stay monotonic non-zero (wrap handled). OK. |
| `autoIntervalMs`, `lastAutoSwitchMs`, `autoFaceIndex` | Auto playback | `serviceAutoPlayback`, faces, status (C0) | faces/web/buttons (C0) | Core-0 | `autoFaceIndex` also written in `loadSavedFaces`. Bounded by mod count. |
| `firmwareScrollActive/Paused/UserPaused/SystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount/Index/IntervalMs`, `lastScrollFrameMs` | Firmware scroll playback | render task (C1) + web/faces/buttons (C0) | same | `Scroll` | Correctly guarded in most paths. `restoreAutoAfterScroll` is written in a few places without `Scroll` (e.g. `buttons.cpp` `runButtonAction` line 134, `web_api` `commandTerminateOtherActivities`) — minor inconsistency (Refactor 7). |
| `scrollStopEvent{Seq,Ms,Button,Source,Reason}` | Lightweight GPIO-stop event for WebUI | `addScrollStopEvent` (C0) | `markScrollStoppedByButton` (C0) | Core-0 | String fields; single-core OK. |
| `deferredFaceRestore*` | Deferred restore timer | `serviceDeferredFaceRestore` (C0) | faces (C0) | Core-0 | OK. |

`ScrollTimelineMeta` and the source-text buffer: guarded by `Scroll`; invariant EH-C documented (`timelineId[0]!=0` ⇒ timeline-backed, `totalFramesExpected>0`, `uploadComplete` authoritative). `RuntimeFace[]` autoFaces + `autoFaceCount`: written by `loadSavedFaces` (C0), read by faces/status (C0). `frameBits_[FRAME_BYTES]`: guarded by `Frame`. `scrollFrameBits_` (heap): guarded by `Scroll`.

#### Firmware state findings
- **Redundant state**: `playback` string vs `firmwareScrollActive/Paused` booleans encode overlapping truth; `firmwareScrollPaused` is derived from `User||System` (`applyFirmwareScrollPauseIntentLocked`). `paused` duplicates `firmwareScrollPaused` during scroll. → consolidate (Refactor 6); do **not** change wire values.
- **Derived-not-stored candidates**: `firmwareScrollPaused` (= user||system) is computed and stored; acceptable for snapshot atomicity but documented as derived.
- **Missing state**: none required; the lock-ownership contract is the main gap and it is documented, not enforced.
- **Should be centralized**: cross-core reads in `handleApiStatus` should go through a single locked snapshot (Refactor 1) like `readScrollStateSnapshot()` already does for scroll.

### 3.2 Web UI `state` / `scroll` / `firmware` (app.js 3467–3613)

| Object | Key fields | Notes |
|---|---|---|
| `state` | mode, faceIndex, brightness, defaultBrightness, color, playback, autoInterval, textScrollActive, battery*/charge* | Mirror of firmware renderer+power. `defaultBrightness` is now derived from firmware/default status instead of the old user-change latch (Bug 4 applied). |
| `scroll` | timer, active/paused/userPaused/systemPaused, firmwareBacked, uploading/commandBusy/startBusy/pauseBusy/stopBusy/restoring/stepBusy, frames[], timelineId, framesTimelineId, uploadGeneration, returnMode, restored* | Large flat bag; many overlapping booleans. `firmwareBacked` + `active` + `paused` + `state.textScrollActive` + `state.playback` partially duplicate firmware truth. |
| `firmware` | online, last*, counters, queue depths | Diagnostics + transport status. |

#### Web UI state findings
- **Redundant**: `scroll.active/paused/userPaused/systemPaused` + `state.textScrollActive` + `state.playback` overlap; a single derived predicate set would remove drift risk (Refactor 9).
- **Derived-not-stored**: `state.textScrollActive` is fully derivable from `playback`+firmware scroll flags; it is recomputed in several places already.
- **Stale risk**: the old `brightnessChangedByUser` one-way latch is removed; Bug 4 is now tracked as a regression risk around default-brightness echo handling. `lastFwScrollTimelineId`/`lastFwScrollHasSourceText` module globals still shadow `scroll.*`.
- **Should remain local**: DOM-diff caches, upload progress token — correctly local.

---

## 4. Side-effect audit

| # | Side effect | Where | Trigger | Safe? | Ordering / multiplicity / cleanup |
|---|---|---|---|---|---|
| S1 | `strip.show()` (WS2812 bus) | `led_renderer.cpp renderCurrentFrameToLedStrip`, `ledStripBegin` | render task tick / boot | Yes under `HardwareBus` + min-gap | Single-caller invariant at runtime (C1 only after boot). Must not run concurrently with file I/O which shares the same lock (Bug 3). |
| S2 | `runtimeFrameBits()` mutation | `setFrameBit`, `publishPackedFrameNow`, scroll task, `showFilesystemErrorPattern` | frame apply | Mostly under `Frame` | `setFrameBit` in `showFilesystemErrorPattern` runs under `Frame` (OK). `countLitLeds` reads it unlocked (Bug 1). |
| S3 | Render-request flag + task notify | `requestLedRender`/`consumeLedRenderRequest`/`notifyScrollRenderTask` | color/brightness/frame/overlay change | Yes (`portMUX` + ISR variant) | Can coalesce; double-consume in scroll task drops a scroll frame (Bug 2). |
| S4 | LittleFS read/write | `storage.cpp`, `power_monitor.cpp`, `web_api.cpp` static serving | settings/faces/calib save+load, static files | Functionally yes | Serialize/deserialize executed **inside** `HardwareBus` lock → blocks `strip.show()` (Bug 3, perf). |
| S5 | Timers/intervals (firmware) | none (cooperative `millis()` scheduling) | — | Yes | No OS timers; all polled. |
| S6 | `portMUX` critical sections | `button_animations.cpp` `sAnimMux`, `led_renderer.cpp` `ledRenderRequestMux` | overlay state, render flag | Yes | Short, no nested locks. OK. |
| S7 | WiFi/DNS/HTTP | `web_api.cpp` start/tick | boot + loop | Yes | `server.handleClient()` is blocking per request; long handlers stall loop (`/api/scroll`, large saved-faces). |
| S8 | Serial logging | throughout | events/errors | Yes | High-volume `Serial.printf` in hot paths (auto/scroll apply) — minor perf (Refactor 12). |
| S9 | Global mutation `powerStatus` | `power_monitor.cpp` | sampling | Mostly C0 | `powerStatus` read by overlay code on… C0 (`copyButtonAnimationOverlay` runs on C1 via render task and reads `powerStatus.*`!) → cross-core unlocked read (Bug 8). |
| S10 | DOM updates | `app.js` render*/update* | state change | Yes | `applyFirmwareRuntimeState` re-renders matrices + color dropdowns even when unchanged (Bug 5). |
| S11 | `fetch`/`XHR` | `apiGet/apiPost/apiPostWithUploadProgress` | user actions + polling | Yes | Multiple in-flight guarded by `*InFlight` flags. Color echo can loop visually (Bug 5). |
| S12 | `setInterval`/`setTimeout` (UI) | polling, scroll preview, button anim, full-sync | various | Mostly | Cleared on `pagehide`; scroll preview timer cleared on stop/pause. `firmwareScrollStopFullSyncTimer` cleared before reschedule (OK). |
| S13 | `localStorage` | — | — | n/a | Not used (consistent with environment constraints). |
| S14 | Clipboard / file download / File System Access | copy/save/open faces | user | Yes | `openLocalFaceLibraryFile` handle persists; benign. |

---

## 5. Bug list

> Severity reflects user-visible/operational impact on this single-user AP device. Concurrency items are real but mostly low-probability due to the cooperative Core-0 design.

### Bug 1: Unlocked cross-core reads of frame/state in `handleApiStatus` 🟢 APPLIED
**Severity:** Medium
**Type:** state / async (data race)
**Location:** `src/web_api.cpp` `handleApiStatus` (`countLitLeds()` call ~line 519; `renderer.color/brightness/lastM370` reads 500–525; `stats.*` 576–584); `src/led_renderer.cpp` `countLitLeds` (198) reads `runtimeFrameBits()` with no lock; `renderCurrentFrameToLedStrip` (226) writes nothing to frameBits but scroll task (`scroll.cpp` 60) and `publishPackedFrameNow` write under `Frame`.
**Current behavior:** Core-0 HTTP handler reads `runtimeFrameBits()`, `colorHex` (heap `String`), `lastM370` (heap `String`), and `framesAccepted` while the Core-1 render task may be writing them under `Frame`. For `String` fields this is a read of a possibly-reallocating object.
**Expected behavior:** Status reads of frame-lock-owned data should be taken from an atomic snapshot under `Frame` (mirroring the existing `readScrollStateSnapshot()` pattern for scroll).
**Root cause:** No snapshot helper for frame/color/stat fields; the lock contract in `state.h` is documented but not applied at the status path.
**Reproduction path:** Start firmware scroll (continuous Core-1 writes). Poll `/api/status` (non-summary) at high frequency from two browser tabs. Under load, `lit`/`lastM370` can momentarily reflect a torn value; in the worst case the `String` read races a reallocation. Hard to crash deterministically but observable as flicker in reported `lit` and rare malformed `lastM370`.
**Risk if not fixed:** Rare corrupted status JSON; theoretical heap read during `String` realloc → crash under sustained dual-tab polling while scrolling.
**Fix strategy:** Add `FrameStateSnapshot readFrameStateSnapshot()` that copies `colorHex` (to a fixed `char[8]`), `brightness`, `lastM370` (to `char[5+93+1]`), `lastReason`, and the lit count (computed under lock from a local copy of frameBits) inside one `withFrameLock`. Serialize from the snapshot outside the lock. Keep all JSON field names identical.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/led_renderer.cpp) — Core-0 reads frameBits with no Frame lock:
uint16_t countLitLeds() {
    const uint8_t* bits = runtimeFrameBits();   // Core-1 render task may be writing this
    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) { /* popcount */ }
    return lit;
}
// --- CURRENT (src/web_api.cpp handleApiStatus) — direct reads of Frame-owned fields:
renderer["color"]    = runtimeState().colorHex;     // heap String, written under Frame on C0+C1
renderer["brightness"] = runtimeState().brightness;
renderer["lastM370"] = runtimeState().lastM370;     // heap String — realloc-during-read risk
renderer["lit"]      = countLitLeds();
```
```cpp
// --- PROPOSED (src/state.h): one atomic snapshot type
struct FrameStateSnapshot {
    char     colorHex[8] = {0};
    uint8_t  brightness  = 0;
    char     lastM370[5 + M370_HEX_CHARS + 1] = {0};
    char     lastReason[M370_FRAME_REASON_CHARS] = {0};
    uint16_t litLeds        = 0;
    uint32_t framesAccepted = 0;
};

// --- PROPOSED (src/led_renderer.cpp): copy everything under ONE Frame lock
FrameStateSnapshot readFrameStateSnapshot() {
    FrameStateSnapshot s;
    withFrameLock([&]() {
        copyText(s.colorHex,  sizeof(s.colorHex),  runtimeState().colorHex.c_str());
        s.brightness = runtimeState().brightness;
        copyText(s.lastM370,  sizeof(s.lastM370),  runtimeState().lastM370.c_str());
        copyText(s.lastReason,sizeof(s.lastReason),runtimeState().lastReason.c_str());
        s.litLeds        = countLitLedsLocked();   // counts from the held buffer (no extra lock)
        s.framesAccepted = runtimeState().framesAccepted;
    });
    return s;
}

// --- PROPOSED (src/web_api.cpp handleApiStatus): serialize from the snapshot, no lock held
const FrameStateSnapshot fs = readFrameStateSnapshot();
renderer["color"]      = fs.colorHex;     // identical JSON field names + value types
renderer["brightness"] = fs.brightness;
renderer["lastM370"]   = fs.lastM370;
renderer["lit"]        = fs.litLeds;
```

**Tests required:** (a) Unit: snapshot returns consistent color+lit for a known frame. (b) Stress: 2-tab `/api/status` polling during scroll for 5 min with heap-integrity logging (`heap_caps_check_integrity`) — no corruption. (c) Field-name diff of status JSON before/after = identical.

### Bug 2: Scroll frame silently dropped when a render request is pending 🟢 APPLIED
**Severity:** Low
**Type:** async / rendering
**Location:** `src/scroll.cpp` `scrollRenderTask` lines 52–66.
**Current behavior:** After advancing `scrollFrameIndex` and copying the next scroll frame to a local buffer, the task re-checks the render-request flag under `Frame`. If a main render request arrived (e.g. color/brightness/overlay change), it does **not** copy the scroll frame into `runtimeFrameBits()` but still renders — showing the previous frame's bits with the new color. The advanced `scrollFrameIndex` is lost, so that timeline frame is skipped.
**Expected behavior:** A concurrent color/brightness change should re-render the *current* scroll frame, not skip it; index should not advance past an undisplayed frame, or the new frame should still be applied.
**Root cause:** The "main render takes priority" branch discards the freshly-decoded scroll frame instead of applying it; index was already incremented before the priority check.
**Reproduction path:** Start scroll at low fps (e.g. 5 fps). Rapidly drag the brightness slider (each emits a render request). Observe the scroll text momentarily skips a column/frame on each brightness tick.
**Risk if not fixed:** Minor visual stutter during simultaneous scroll + color/brightness edits. No data loss beyond the visual.
**Fix strategy:** Apply the scroll frame to `runtimeFrameBits()` whenever `firmwareScrollActive` regardless of `mainTaskRenderPending` (the main request and the scroll frame are not mutually exclusive — both want a render of the latest bits). Concretely: drop the `&& !mainTaskRenderPending` guard on the memcpy; keep `shouldRender = true`. Verify ordering vs `publishPackedFrameNow` (which also writes frameBits under `Frame`) — last writer wins, acceptable since a queued M370 frame during active scroll is already an exceptional path.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/scroll.cpp scrollRenderTask, inside withFrameLock):
if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
    ++runtimeState().framesAccepted;
} else {
    if (!mainTaskRenderPending) shouldRender = false;   // scroll frame discarded; index already advanced
}
```
```cpp
// --- PROPOSED: a pending main render and the new scroll frame are NOT mutually
// exclusive — both want the latest bits shown, so apply the scroll frame regardless.
if (runtimeState().firmwareScrollActive) {
    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
    ++runtimeState().framesAccepted;
    shouldRender = true;
} else if (!mainTaskRenderPending) {
    shouldRender = false;
}
```

**Tests required:** Manual hardware: 5 fps scroll + brightness sweep → no skipped columns (capture with phone slow-mo). Bench: instrument `framesAccepted` delta vs `scrollFrameIndex` advances over 100 frames with periodic render requests — equal counts.

### Bug 3: File serialization/deserialization holds the LED `HardwareBus` lock ⚠️ HARDWARE-GATED
**Severity:** Medium
**Type:** performance / timing
**Location:** `src/storage.cpp` `writeJsonFileAtomic` (56–62: `serializeJson` + `flush` + `close` + `rename` inside `withHardwareBusLock`), `loadSavedFaces` (270–273: `deserializeJson` inside lock), `web_api.cpp streamFileChunked` (153–158 reads inside lock per chunk).
**Current behavior:** `HardwareBus` is the same mutex that gates `strip.show()`. Writing/loading a large `saved_faces.json` (or streaming a large static asset) holds it for the full serialize/parse, blocking the Core-1 render task's `show()` for tens of ms.
**Expected behavior:** LED refresh cadence should not stall during flash I/O; only the genuinely shared hardware window needs the lock.
**Root cause:** Coarse-grained lock scope: the lock protects "LittleFS + LED bus" together (a deliberate simplification), but serialize/parse do not touch the LED bus and need not be inside it.
**Reproduction path:** While a firmware scroll plays, POST a large `saved_faces.json` to `/api/saved_faces`. Observe a visible scroll hitch (frame gap) for the duration of the write. Same on boot `loadSavedFaces`.
**Risk if not fixed:** Visible stutter on saves and large static transfers; worsens as the face library grows.
**Fix strategy:** Keep LittleFS file *open/close/rename* under the lock unless hardware testing proves flash I/O and WS2812 `strip.show()` are independent on this board. If proven independent, introduce a separate `Storage` mutex for file content I/O and reserve `HardwareBus` strictly for `strip.show()`. **Do not let an automated agent apply this as a blind refactor**: it changes a real timing/contention assumption and needs hardware evidence. Do not change atomic-write semantics (temp+rename).
**Code change:** ⚠️ HARDWARE-GATED; proposed implementation only until the hardware proof is recorded.
```cpp
// --- CURRENT (src/storage.cpp writeJsonFileAtomic): serialize runs under the LED-bus lock
bool renamed = false;
withHardwareBusLock([&]() {
    written = serializeJson(document, file);   // multi-KB serialize blocks strip.show()
    file.flush();
    file.close();
    renamed = written > 0 && LittleFS.rename(tempPath, path);
    if (!renamed) LittleFS.remove(tempPath);
});
```
```cpp
// --- PROPOSED: reserve HardwareBus strictly for strip.show(); guard flash content I/O
// with a dedicated Storage lock (only after confirming WS2812/RMT and flash do not
// share hardware — see Risk table). Atomic temp+rename semantics unchanged.
bool renamed = false;
withStorageLock([&]() {
    written = serializeJson(document, file);   // heavy work OFF the LED-bus lock
    file.flush();
    file.close();
    renamed = written > 0 && LittleFS.rename(tempPath, path);
    if (!renamed) LittleFS.remove(tempPath);
});
```
```cpp
// --- PROPOSED (src/sync.h): extend the domain enum + helper
enum class SyncDomain : uint8_t { Frame, Scroll, HardwareBus, Storage };
template <typename Fn> auto withStorageLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Storage); return fn();
}
// Global order extended to: Scroll -> Frame -> HardwareBus -> Storage (no reverse nesting).
```

**Tests required:** (a) Measure scroll frame gap (logic-analyzer or `micros()` delta around `show()`) during a 64 KB saved-faces write — before vs after. (b) Power-loss-during-write test still leaves either old or new file intact (atomicity preserved). (c) Confirm no concurrent `strip.show()` + LittleFS corruption over 1000 write cycles.

### Bug 4: Old brightness user-change latch froze `defaultBrightness` 🟢 APPLIED
**Severity:** Low
**Type:** logic / state
**Location:** `data/app.js` `setBrightness` (5351 sets latch true), `applyFirmwareRuntimeState` (4785 `if (!brightnessChangedByUser) state.defaultBrightness = ...`), `resetBrightnessDefault` (7144 uses `state.defaultBrightness`).
**Current behavior before fix:** Once the user changed brightness, `brightnessChangedByUser` stayed `true` for the whole session. `state.defaultBrightness` therefore stopped tracking firmware/default brightness, so "重置默认亮度" could revert to whatever default was synced before the first manual change.
**Expected behavior:** "Reset default brightness" should restore the firmware's current notion of default (50), or the latch semantics should be explicitly documented and bounded.
**Root cause:** A latch used to prevent polling from overwriting the user's brightness also permanently disables default-tracking; no reset on firmware-confirmed brightness or on reset action.
**Reproduction path:** Load page (default 50). Move slider to 120. Click "重置默认亮度" → goes to 50 (ok this time). Now imagine firmware reloads saved faces (brightness→50) and a new default scheme; UI still treats the pre-edit value as default. More concretely: the field is dead state that can desync.
**Risk if not fixed:** Confusing reset behavior; low impact.
**Fix strategy:** Choose strategy (b) only: drive `defaultBrightness` from `renderer.brightnessDefault`/`data.brightnessDefault` when present, otherwise from the firmware default constant (`DEFAULT_LED_BRIGHTNESS`, currently 50). Do not implement strategy (a); clearing the old latch after a firmware echo is not the chosen design. The user-edit protection is now the short `lastUserBrightnessMs` stale-echo window for `state.brightness`, while `state.defaultBrightness` is updated independently from the firmware/default field.
**Code change:** 🟢 APPLIED
```js
// --- CURRENT (data/app.js): latch set true on first user change, never cleared
function setBrightness(v, source = "brightness_change") {
  brightnessChangedByUser = true;            // sticky for the whole session
  applyBrightnessLocal(v);
  log(`亮度更新 raw=${state.brightness} (${source})`);
  sendAuxCommand("set_brightness", { raw: state.brightness }, source);
}
// applyFirmwareRuntimeState():
if (!brightnessChangedByUser) state.defaultBrightness = nextBrightness;  // frozen after first edit
```
```js
// --- APPLIED (data/app.js applyFirmwareRuntimeState): derive the reset target
// from an explicit/default firmware value instead of a sticky user-change latch.
const nextBrightness = clampBrightness(brightnessValue);
state.defaultBrightness = clampBrightness(
  Number(renderer.brightnessDefault ?? data.brightnessDefault ?? DEFAULT_LED_BRIGHTNESS),
);
```

**Tests required:** UI test: change brightness, trigger a poll cycle, click reset → returns to firmware default. Verify polling does not stomp an in-progress slider drag.

### Bug 5: Status polling re-renders matrices and resets color dropdowns even when color is unchanged 🟢 APPLIED
**Severity:** Medium
**Type:** UI / performance
**Location:** `data/app.js` `setColor` (5313–5338): it mutates DOM, calls `syncColorDropdownsToHex`, `renderMatrices`, `renderState` **before** the `if (unchangedFirmwareSync) return;` early-out; `applyFirmwareRuntimeState` (4795–4798) calls `setColor(firmwareColor,"firmware_sync")` on every poll that includes a color.
**Current behavior:** Each `/api/status` poll that carries `renderer.color` runs full matrix re-render + `syncColorDropdownsToHex` even when the color equals the current one. If the user has the parent/child color dropdown open or is mid-selection, the poll resets the dropdown selection to match the hex.
**Expected behavior:** When the firmware color equals `state.color`, the sync should be a no-op (no DOM writes, no dropdown reset, no matrix re-render).
**Root cause:** The unchanged-case early return is placed after the rendering side effects rather than before them.
**Reproduction path:** On the basic page, open the child-color dropdown and hover/select; within ~1 s a status poll arrives and `syncColorDropdownsToHex` snaps the dropdown back. Also: continuous matrix re-renders every second waste CPU/battery on the client.
**Risk if not fixed:** Janky color picker; unnecessary per-second re-render churn.
**Fix strategy:** In `setColor`, when `source === "firmware_sync" && state.color === c`, return immediately before any DOM/render side effects. Keep the non-sync path (user-initiated) fully rendering. Verify `--led-color` CSS var and swatch still update on genuine changes.
**Code change:** 🟢 APPLIED
```js
// --- CURRENT (data/app.js setColor): unchanged-case early-return sits AFTER the
// DOM writes + dropdown sync + matrix re-render, so a no-op poll still churns.
function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) { alert("颜色必须是 #RRGGBB 或 RRGGBB"); return; }
  const unchangedFirmwareSync = source === "firmware_sync" && state.color === c;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input"))  $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);     // <-- resets an open/in-progress dropdown
  updateDps();
  renderMatrices();               // <-- per-second re-render churn
  renderState();
  if (unchangedFirmwareSync) return;
  log(`颜色更新 ${c} (${source})`);
  if (source !== "firmware_sync") sendAuxCommand("set_color", { hex: c }, source);
}
```
```js
// --- PROPOSED: move the no-op short-circuit ABOVE all side effects.
function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) { alert("颜色必须是 #RRGGBB 或 RRGGBB"); return; }
  // A firmware poll re-asserting the colour we already show must be a true no-op:
  // no DOM writes, no dropdown reset, no matrix re-render.
  if (source === "firmware_sync" && state.color === c) return;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input"))  $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);
  updateDps();
  renderMatrices();
  renderState();
  log(`颜色更新 ${c} (${source})`);
  if (source !== "firmware_sync") sendAuxCommand("set_color", { hex: c }, source);
}
```

**Tests required:** UI: open color dropdown, let 3 polls pass with identical firmware color → dropdown selection unchanged, no matrix re-render (assert via render counter). Genuine firmware color change still updates swatch + matrices.

### Bug 6: Corrupt runtime settings file is not repaired 🟢 APPLIED
**Severity:** Low
**Type:** persistence / edge case
**Location:** `src/storage.cpp` `loadRuntimeSettings` (106–110): if `SETTINGS_PATH` doesn't exist it calls `saveRuntimeSettings()` (writes defaults) and returns false; parse failure (127–130) returns false without writing.
**Current behavior:** Missing file → defaults written (intended). But a parse failure (corrupt file) silently keeps current in-RAM defaults and does **not** repair the file, so the corrupt file persists and every boot re-parses+fails.
**Expected behavior:** A corrupt settings file should be repaired (rewritten with current/default values) so the corruption doesn't persist indefinitely.
**Root cause:** Asymmetric handling of "missing" vs "corrupt".
**Reproduction path:** Manually corrupt `runtime_settings.json` (truncate). Reboot → log shows parse failure every boot; file never repaired.
**Risk if not fixed:** Permanent log noise; settings never persist again until a setting changes (which does rewrite). Low impact because any mode/interval change rewrites.
**Fix strategy:** On parse failure, call `saveRuntimeSettings()` to rewrite a valid file after applying defaults. Keep success/missing paths unchanged.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/storage.cpp loadRuntimeSettings): corrupt file is left in place
if (err) {
    Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
    return false;
}
```
```cpp
// --- PROPOSED: repair the corrupt file so the failure does not persist every boot.
if (err) {
    Serial.printf("runtime_settings.json parse failed; rewriting defaults: %s\n", err.c_str());
    saveRuntimeSettings();   // current in-RAM mode/interval are already defaults here
    return false;
}
```

**Tests required:** Corrupt the file → boot → assert file is rewritten to valid JSON and parses on next boot.


### Bug 13: Face ID bounds/overflow on parsing 🟢 APPLIED
**Severity:** Low
**Type:** logic / edge case
**Location:** `src/storage.cpp` `defaultFaceIdNumberIsInvalid` (149–159).
**Current behavior:** Extremely long default face IDs (e.g. `face_42949672960`) can overflow the 32-bit integer parser `value = value * 10 + ...` and wrap to `0`, causing `value < 1` to be true and rejecting the faces, or wrapping to a valid positive number and being incorrectly accepted.
**Expected behavior:** Prevent overflow during ID parsing or bound the length strictly.
**Root cause:** Naive parsing loop without length or overflow guards.
**Reproduction path:** Save a face with ID `face_42949672960` and reboot.
**Risk if not fixed:** Malicious or malformed faces could break JSON load logic silently.
**Fix strategy:** Add a character-length limit (e.g., maximum 9 digits) inside the `while` loop before multiplying by 10.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/storage.cpp defaultFaceIdNumberIsInvalid):
uint32_t value = 0;
while (*p >= '0' && *p <= '9') {
    value = value * 10 + static_cast<uint32_t>(*p - '0');
    ++p;
}
return value < 1;
```
```cpp
// --- PROPOSED: cap digit count (9 digits fits in uint32_t without wrap)
uint32_t value = 0;
uint8_t digits = 0;
while (*p >= '0' && *p <= '9') {
    if (++digits > 9) return true; // implausibly long -> invalid
    value = value * 10 + static_cast<uint32_t>(*p - '0');
    ++p;
}
return value < 1;
```

**Tests required:** Unit: `defaultFaceIdNumberIsInvalid("face_42949672960")` returns true.

### Bug 7: Mutex creation failure degrades silently to unsynchronized operation 🟢 APPLIED
**Severity:** Medium
**Type:** async / error handling
**Location:** `src/main.cpp` (42–44 logs but continues); `src/sync.cpp` `lockFrame`/`lockScroll`/`lockHardwareBus` (each `if (mutex) take(...)`). If creation failed, the handle is null and every lock/unlock becomes a no-op.
**Current behavior:** If any `xSemaphoreCreateMutex()` returns null (heap exhaustion), boot continues and all critical sections silently run without protection across both cores — a latent corruption source with no runtime signal beyond one boot log line.
**Expected behavior:** Either fail safe (do not start the Core-1 render task, run single-core) or make the failure loud and persistent (e.g. dedicated error LED pattern), rather than running cross-core without locks.
**Root cause:** Defensive `if (mutex)` guards make missing mutexes invisible at the call sites.
**Reproduction path:** Hard to trigger naturally; force by making `initSyncPrimitives` return false (stub) → system runs but locks are no-ops; under scroll + status polling, frame corruption appears.
**Risk if not fixed:** Silent data races if RAM is ever exhausted at boot.
**Fix strategy:** If `initSyncPrimitives()` fails, do not call `startScrollRenderTask()` (keep all rendering on Core 0 where the cooperative loop serializes access), and surface a distinct diagnostic (reuse `showFilesystemErrorPattern`-style indicator or a dedicated pattern). Document that locks must exist before the Core-1 task starts.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/main.cpp setup): logs but continues; Core-1 task starts anyway
if (!initSyncPrimitives()) {
    Serial.println("Failed to create one or more FreeRTOS mutexes");
}
// ... later, unconditionally:
startScrollRenderTask();
```
```cpp
// --- PROPOSED: fail safe — keep everything on Core 0 (cooperative loop serializes
// access) and surface a loud, persistent diagnostic when locks are unavailable.
const bool syncReady = initSyncPrimitives();
if (!syncReady) {
    Serial.println("FATAL: FreeRTOS mutexes unavailable; render task disabled, running single-core");
    showFilesystemErrorPattern();   // reuse or add a dedicated diagnostic LED pattern
}
// ... later:
if (syncReady) startScrollRenderTask();   // never start Core-1 access without locks
// loop(): when !syncReady, drive renderCurrentFrameToLedStrip() inline after frame service.
```

**Tests required:** Fault-injection unit: force `initSyncPrimitives` false → assert scroll task not created and a diagnostic raised; no Core-1 access to shared state.

### Bug 8: `powerStatus` read on Core 1 (overlay) without synchronization 🟢 APPLIED
**Severity:** Low
**Type:** async (data race)
**Location:** `src/button_animations.cpp` `drawBatteryPage` (300–322), `serviceButtonAnimations` (530–538), `startBatteryOverlay` (431) read `powerStatus.batteryValid/percent/charging/vbat/vcharge`. `copyButtonAnimationOverlay` runs on the **Core-1** render task; `powerStatus` is written by `servicePowerMonitor` on **Core 0**.
**Current behavior:** Battery overlay (drawn on C1) reads multi-field `powerStatus` while C0 sampling may be mid-update. Fields are scalar (`float`/`uint8`/`bool`), so tears are partial-struct inconsistencies (e.g. `percent` from new sample, `vbat` from old).
**Expected behavior:** Overlay should read a consistent power snapshot.
**Root cause:** `powerStatus` is a shared global with no lock; the overlay was likely assumed Core-0 but `copyButtonAnimationOverlay` is invoked from `renderCurrentFrameToLedStrip` (C1).
**Reproduction path:** Hold B6 (battery overlay) while charging state toggles; rare frame may show mismatched percent vs voltage. Visual only.
**Risk if not fixed:** Cosmetic inconsistency in the battery overlay; no crash (POD scalars).
**Fix strategy:** Add a small `PowerSnapshot` copied under a short `portMUX` (or reuse a dedicated critical section) in `servicePowerMonitor` write and overlay read; or compute the overlay's power-derived values on Core 0 and pass them into `sAnim` (which is already `portMUX`-guarded). Prefer the latter: stage battery percent/vbat/charging into `sAnim` fields under `sAnimMux` when starting/refreshing the battery overlay.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/button_animations.cpp drawBatteryPage, runs on Core 1):
const bool    batteryValid = powerStatus.batteryValid;   // powerStatus written on Core 0
const uint8_t pct          = batteryValid ? powerStatus.batteryPercent : 0;
const bool    charging     = powerStatus.chargeValid && powerStatus.charging;
const float   v            = isfinite(powerStatus.vbat) ? powerStatus.vbat : 0.0f;
```
```cpp
// --- PROPOSED: stage power fields into the sAnimMux-guarded sAnim on Core 0 when the
// battery overlay starts/refreshes; Core 1 reads only the copied snapshot.
// AnimationState (add):
bool    batValid = false, batCharging = false;
uint8_t batPercent = 0;
float   batVbat = NAN, batVcharge = NAN;

// startBatteryOverlay()/serviceButtonAnimations() on Core 0, under portENTER_CRITICAL(&sAnimMux):
next.batValid    = powerStatus.batteryValid;
next.batPercent  = powerStatus.batteryPercent;
next.batCharging = powerStatus.chargeValid && powerStatus.charging;
next.batVbat     = powerStatus.vbat;
next.batVcharge  = powerStatus.vcharge;

// drawBatteryPage() on Core 1 reads state.batValid/batPercent/... (the copied snapshot),
// never powerStatus directly → consistent percent/voltage pairing.
```

**Tests required:** Stress: toggle charger input while B6 overlay active for 2 min; assert no struct-tear via logged snapshot consistency check.


### Bug 14: `powerStatus` EMA filtering edge case (dtS constrained but unsigned wrap) 🟢 APPLIED
**Severity:** Low
**Type:** edge case
**Location:** `src/power_monitor.cpp` `sampleBattery` (348).
**Current behavior:** The EMA filtering constraint uses `static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f`. While `now - last` handles 32-bit wrap, if the device hangs or misses a sample for > 49 days, the delta might wrap around to a very small positive number instead of hitting the 10.0f clamp.
**Expected behavior:** If the last sample was an extremely long time ago, the filter should snap to the instant value or correctly clamp.
**Root cause:** The `constrain` operates on the `float` output *after* the `uint32_t` subtraction, which already wraps modulo $2^{32}$.
**Reproduction path:** Keep board on for 49.7 days without sampling battery.
**Risk if not fixed:** Negligible. One wrong EMA sample every 50 days.
**Fix strategy:** Just before `constrain`, if `now < lastBatteryMs` and `now - lastBatteryMs > 0x7FFFFFFF` (a massive negative jump representing wrap or huge delay), just snap `vbat = instantVbat` and bypass EMA.
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/power_monitor.cpp sampleBattery):
const float dtS = constrain(
    static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f, 0.001f, 10.0f);
```
```cpp
// --- PROPOSED: detect an implausible elapsed time (wrap / long stall) and snap.
const uint32_t elapsedMs = now - powerStatus.lastBatteryMs;
if (elapsedMs > 0x7FFFFFFFu) {
    powerStatus.vbat = instantVbat;
} else {
    const float dtS = constrain(static_cast<float>(elapsedMs) * 0.001f, 0.001f, 10.0f);
    // ...
}
```

**Tests required:** Unit: fake `now` wrap and assert `vbat` snaps to `instantVbat`.

### Bug 9: WebUI mirrors firmware scroll pause as user-pause when split flags are absent 🟢 APPLIED
**Severity:** Low
**Type:** state / sync
**Location:** `data/app.js` `applyFirmwareRuntimeState` 4740–4748. When `hasSplitPauseFlags` is false (older/summary payloads), `scroll.userPaused` is set from `playbackValue==="scroll_paused" || firmwareScrollPaused`, conflating a **system** pause (B6 overlay) with a **user** pause.
**Current behavior:** During a B6 battery overlay (firmware system-pause), a status payload lacking split flags would mark the WebUI `userPaused`, changing the pause button's semantics and potentially letting the user "resume" a system-paused scroll out of band.
**Expected behavior:** System pause must not be presented as user pause. Firmware status always includes the split flags in the current code (`addScrollStateFields` always emits them), so this path is currently dormant — but it is a latent contradiction if any summary path omits them.
**Root cause:** Backward-compat fallback that cannot distinguish user vs system pause.
**Reproduction path:** Force a status response without `firmwareScrollUserPaused/SystemPaused` (e.g. a future trimmed summary) while B6 overlay active → pause toggle mislabeled.
**Risk if not fixed:** Latent; only triggers if the wire contract drops the split flags. Document + guard.
**Fix strategy:** When split flags are absent, treat `firmwareScrollPaused` as **systemPaused=unknown** and prefer leaving `userPaused` unchanged rather than inferring it; or assert that all status/summary payloads always include split flags (and add a firmware test that guarantees it). Keep current behavior when flags present.
**Code change:** 🟢 APPLIED
```js
// --- CURRENT (data/app.js applyFirmwareRuntimeState): without split flags, a SYSTEM
// pause (B6 overlay) is mis-attributed to the USER.
scroll.userPaused = hasSplitPauseFlags
  ? firmwareScrollUserPaused
  : playbackValue === "scroll_paused" || firmwareScrollPaused;   // conflates system pause
scroll.systemPaused = hasSplitPauseFlags ? firmwareScrollSystemPaused : false;
```
```js
// --- PROPOSED: when split flags are absent, do not invent a user pause; leave the
// previous userPaused untouched and treat the effective pause as system-origin.
if (hasSplitPauseFlags) {
  scroll.userPaused   = firmwareScrollUserPaused;
  scroll.systemPaused = firmwareScrollSystemPaused;
} else {
  // Cannot distinguish user vs system → keep last known userPaused, attribute the
  // effective pause to "system" so the pause button is never wrongly made resumable.
  scroll.systemPaused = (playbackValue === "scroll_paused" || firmwareScrollPaused) && !scroll.userPaused;
}
// PLUS firmware contract test: addScrollStateFields() always emits both split flags
// in every /api/status variant (already true today — lock it with a test).
```

**Tests required:** Contract test: every `/api/status` variant (`runtimeOnly`, `noFrame`, `summary`, full) includes both split pause flags. UI test with flags omitted → user-pause not asserted.

### Bug 10: First-chunk size search re-encodes the whole payload per candidate (upload latency) 🟢 APPLIED
**Severity:** Low
**Type:** performance
**Location:** `data/app.js` `chooseFirstChunkFrames` (8768–8784): loops `count` down from `SCROLL_UPLOAD_CHUNK_FRAMES`, each iteration `JSON.stringify` + `TextEncoder().encode` of the full first-chunk payload to measure bytes.
**Current behavior:** For long text the first-chunk fit search can stringify+encode a multi-KB payload many times (O(n) re-encodes), adding client-side latency before the first byte uploads.
**Expected behavior:** Estimate chunk size from per-frame byte cost + fixed meta overhead, then verify once.
**Root cause:** Brute-force shrink loop with full re-serialization each step.
**Reproduction path:** Enter the maximum scroll text; click 发送; observe a measurable pause (hundreds of ms on a phone) before the progress bar moves past "准备".
**Risk if not fixed:** Sluggish send for long text; not a correctness issue.
**Fix strategy:** Compute `metaBytes` once (payload with `frames:[]`), compute average frame string bytes, derive an initial `count` from `(LIMIT - metaBytes)/avgFrameBytes`, then do at most one or two verify/adjust steps. Keep the D4 "too long for one chunk" error path.
**Code change:** 🟢 APPLIED
```js
// --- CURRENT (data/app.js): re-stringifies + re-encodes the full payload per candidate
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  let count = SCROLL_UPLOAD_CHUNK_FRAMES;
  while (count > 1) {
    const bytes = new TextEncoder().encode(JSON.stringify(firstChunkPayloadBuilder(count))).length;
    if (bytes <= SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) return count;
    count--;                                  // O(n) full re-encodes for long text
  }
  const oneFrameBytes = new TextEncoder().encode(JSON.stringify(firstChunkPayloadBuilder(1))).length;
  if (oneFrameBytes > SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) throw new Error("滚动文字过长，元数据无法放入首个上传分块");
  return 1;
}
```
```js
// --- PROPOSED: estimate from per-frame cost + fixed meta, then verify at most a few times.
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  const enc = new TextEncoder();
  const metaBytes = enc.encode(JSON.stringify(firstChunkPayloadBuilder(0))).length;  // frames:[]
  const oneFrame  = enc.encode(JSON.stringify(firstChunkPayloadBuilder(1))).length;
  const perFrame  = Math.max(1, oneFrame - metaBytes);
  let count = Math.min(
    SCROLL_UPLOAD_CHUNK_FRAMES,
    Math.max(0, Math.floor((SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES - metaBytes) / perFrame)),
  );
  while (count > 1 &&
         enc.encode(JSON.stringify(firstChunkPayloadBuilder(count))).length > SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) {
    count--;                                  // JSON overhead is near-constant → 0–2 iterations
  }
  if (count < 1) throw new Error("滚动文字过长，元数据无法放入首个上传分块");  // D4 preserved
  return count;
}
```

**Tests required:** Bench: encode count for representative texts before/after = same chosen size; measure wall-clock of `chooseFirstChunkFrames` (≥10× faster for max text).

### Bug 11: `serviceM370FrameQueue` copies a ~210-byte queue item by value every serviced frame 🟢 APPLIED
**Severity:** Low
**Type:** performance
**Location:** `src/led_renderer.cpp serviceM370FrameQueue` (395–401) `memcpy(&item, &m370FrameQueue[head], sizeof(item))` then publishes from the copy.
**Current behavior:** Each dequeue copies the full `QueuedM370Frame` (47-byte bits + 98-byte m370 text + 64-byte reason ≈ 210 bytes) to a stack temp before publishing, then publish memcpy's bits again into frameBits. Two copies per frame.
**Expected behavior:** Publish directly from the queue slot, then advance head.
**Root cause:** Defensive copy to allow advancing head before publishing; not required since publish reads bits synchronously.
**Reproduction path:** N/A (perf only); visible only under sustained max frame rate.
**Risk if not fixed:** Negligible; listed for completeness and because it interacts with Refactor 2.
**Fix strategy:** Publish from `m370FrameQueue[head]` directly (publish copies bits under lock), then advance head/count. Confirm no re-entrancy (publish does not enqueue).
**Code change:** 🟢 APPLIED
```cpp
// --- CURRENT (src/led_renderer.cpp serviceM370FrameQueue): copies the ~210-byte item
QueuedM370Frame item;
memcpy(&item, &m370FrameQueue[m370FrameQueueHead], sizeof(item));
m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
// --- PROPOSED test (Node/JS harness reusing the WebUI + a mirror of the firmware decode):
for (const led of [0, 17, 369]) {
  const f = blankFrame(); f[led] = true;
  const m = frameToM370(f);                 // WebUI encoder: 370 bits + "00" → 93 hex
  const back = m370ToFrame(m);              // decoder drops padding bits 370/371
  assert(back[led] === true);
  assert(onCount(back) === 1);
}
// Firmware side: assert the existing invariant holds and pin it:
//   static_assert(M370_HEX_CHARS == (M370_BITS + 3U) / 4U, ...);  // already in config.h
```

**Tests required:** Round-trip unit test for LEDs {0, 17, 369}.

---

### Bug 15: 6.4 scroll buttons flash disabled→enabled on every click  🟢 APPLIED
**Severity:** Medium
**Type:** UI
**Location:** `data/app.js` `updateScrollUi` (`anyCommandBusy` definition + the `pause`/`stop`/`step`/`speed` `disabled` expressions). Handlers `setScrollFps` (8557), `setScrollStepHandler` (9154), `pauseScroll`/`resumeScroll`/`stopScroll`.
**Current behavior (before fix):** Each scroll command handler set a transient busy flag (`scroll.commandBusy` plus `pauseBusy`/`stepBusy`/`fpsBusy`/`stopBusy`), called `updateScrollUi()`, awaited one HTTP round-trip, cleared the flag, and called `updateScrollUi()` again. Because `anyCommandBusy = hardBusy || scroll.commandBusy` was folded into **every** button's `disabled`, a quick command disabled the whole button row and then re-enabled it — a visible flash on every click.
**Expected behavior:** A button's enabled/disabled state should change only when its *real* availability changes; a normal click must not flash the row. Only genuinely long operations (upload/restore) should visibly disable controls.
**Root cause:** Short-lived single-round-trip re-entrancy flags were reflected into the DOM `disabled` attribute, even though each handler already blocks re-entry at its own entry (`if (scroll.commandBusy || scroll.*Busy) return;`).
**Reproduction path:** On 6.4, click 暂停/继续/停止/逐帧/帧率 — every click briefly greys out all buttons.
**Risk if not fixed:** Janky control row; perceived unresponsiveness.
**Fix strategy (applied):** Drop the transient flags from the visual `disabled` computation; keep them only as handler re-entrancy guards. `anyCommandBusy` now equals `hardBusy` (upload/restore) only.
**Code evidence:** `data/app.js::updateButtonState` calls `setDomAttrIfChanged(el, "aria-disabled", nextState.disabled ? "true" : "false")`, and `updateScrollUi` routes pause/stop/step/speed controls through the scroll button UI helpers instead of leaving the initial HTML `aria-disabled="true"` stuck.
**Code change:** 🟢 applied to `data/app.js`
```js
// --- BEFORE:
const anyCommandBusy = hardBusy || scroll.commandBusy;
applyScrollButtonUiState("pause", pauseBtn, {
  disabled: anyCommandBusy || scroll.pauseBusy || nonResumableSystemPause || !scrollLiveOrPaused,
  text: effectivePaused ? "继续" : "暂停", pressed: scrollPlayingNow,
});
applyScrollButtonUiState("stop", stopBtn, { disabled: anyCommandBusy || scroll.stopBusy || !hasFrameCache });
const stepDisabled = anyCommandBusy || scroll.stepBusy || scrollPlayingNow || !hasFramesForStep;
const speedDisabled = anyCommandBusy || scroll.fpsBusy;
```
```js
// --- AFTER: only long upload/restore disable controls; re-entrancy stays in the handlers.
const anyCommandBusy = hardBusy;
applyScrollButtonUiState("pause", pauseBtn, {
  disabled: anyCommandBusy || nonResumableSystemPause || !scrollLiveOrPaused,
  text: effectivePaused ? "继续" : "暂停", pressed: scrollPlayingNow,
});
applyScrollButtonUiState("stop", stopBtn, { disabled: anyCommandBusy || !hasFrameCache });
const stepDisabled = anyCommandBusy || scrollPlayingNow || !hasFramesForStep;
const speedDisabled = anyCommandBusy;
```
**Tests required:** Manual: click each scroll button rapidly → no whole-row flash; pause/继续 label flips only on real state change; send/upload still disables the row while uploading. The `*Busy` flags still gate their handlers (no double-submit).

---

## 6. Refactor opportunities

### Refactor 1: Extract a locked status snapshot for frame/color/stat fields 🟢 APPLIED
**Category:** extraction / state cleanup
**Location:** `src/web_api.cpp` `handleApiStatus`, `handleApiFrame`, `handleApiCommand`; `src/led_renderer.cpp`.
**Current problem:** Status handlers read `Frame`-owned fields (`colorHex`, `brightness`, `lastM370`, `lastReason`, `framesAccepted`, lit count) without taking `Frame`. Mirrors the missing-snapshot half of Bug 1.
**Why this is safe (as pure refactor of the read pattern):** Introducing a snapshot that copies fields under `withFrameLock` does not change any emitted JSON values in the single-threaded common case; it only makes reads atomic. (The behavior-changing part — fixing the race — is Bug 1; this refactor provides the seam.)
**What should change:** Add `struct FrameStateSnapshot` + `readFrameStateSnapshot()` next to `readScrollStateSnapshot()`. Status code reads from the snapshot.
**What must not change:** JSON field names, value formatting (`colorHex` string form, `lit` semantics), order is irrelevant to clients.
**Dependencies:** Bug 1 fix builds on this seam.
**Implementation steps:** (1) Define snapshot struct. (2) Implement reader copying under `withFrameLock` (compute lit from a local frameBits copy). (3) Replace direct reads in `handleApiStatus`/`handleApiFrame`/`handleApiCommand`. (4) Diff JSON output.
**Regression risk:** Low.
**Code change:** ⬜ (mirrors the existing `readScrollStateSnapshot()` pattern)
```cpp
// --- EXISTING pattern to copy (src/web_api.cpp readScrollStateSnapshot):
static ScrollStateSnapshot readScrollStateSnapshot() {
    ScrollStateSnapshot snapshot;
    withScrollLock([&]() { /* copy scroll fields + memcpy timelineId under lock */ });
    return snapshot;
}
// --- PROPOSED sibling for Frame-owned fields (see Bug 1 for the struct + reader):
const FrameStateSnapshot fs = readFrameStateSnapshot();
renderer["color"] = fs.colorHex; renderer["lit"] = fs.litLeds; /* etc. — same field names */
```

**Validation method:** Byte-diff of `/api/status` JSON for a fixed state before/after.

### Refactor 2: Split the 277-line `/api/scroll` handler into named phases
**Category:** extraction / modularization
**Location:** `src/web_api.cpp handleApiScroll` (660–937).
**Current problem:** One function performs: method/body guards, timing parse, flag parse, meta-id validation, first-chunk vs append branching, frame stream parse, completion bookkeeping, autostart decision, and reply build. Very hard to modify safely.
**Why this is safe:** Pure extraction of contiguous blocks into `static` helpers with the same locals passed by reference; no logic reordered.
**What should change:** Extract `parseScrollUploadHeader(body, …)`, `beginFirstChunkLocked(…)`, `validateAppendChunkLocked(…)`, `parseAndStoreFrames(body, pos, …)`, `finalizeScrollChunkLocked(…)`, `buildScrollReply(…)`.
**What must not change:** Lock acquisition points and ordering (`Scroll` snapshot/commit boundaries), all HTTP status codes (400/409/413/507) and their messages, the EH-A/EH-B/EH-C/D1–D8 invariants encoded in comments, and the exact field set of the reply.
**Dependencies:** None; do before Bug-fix work in this handler.
**Implementation steps:** Extract one block at a time, compile + run the scroll upload integration test after each extraction.
**Regression risk:** Medium (lock boundaries are subtle) → enforce "one block per commit + test".
**Code change:** ⬜ (illustrative target shape — extract contiguous blocks, no logic moved)
```cpp
// --- CURRENT: one 277-line function (src/web_api.cpp handleApiScroll, 660–937).
// --- PROPOSED orchestrator over phase helpers (locks/order/status codes unchanged):
static void handleApiScroll() {
    if (!scrollMethodAndBufferOk()) return;          // method/body/buffer-ready guards (sends its own errors)
    ScrollUploadHeader h;
    if (!parseScrollUploadHeader(body, h)) return;   // timing, flags, meta-id validation → 400/413/507
    if (!h.appendFrames) { if (!beginFirstChunkLocked(h)) return; }   // clear meta + store first-chunk meta under Scroll
    else                 { if (!validateAppendChunkLocked(h)) return; } // EH-B/D3 chunk-order checks → 409
    ScrollParseResult r;
    if (!parseAndStoreFrames(body, h, r)) return;    // stream frames into buffer; E1/EH-A invalidation
    finalizeScrollChunkLocked(h, r);                 // frame count, uploadComplete, autostart decision
    buildScrollReply(h, r);                          // identical reply field set
}
```

**Validation method:** Full scroll upload/restore integration test (single chunk, multi chunk, 409 retry, oversize, bad frame) green after each step.

### Refactor 3: Unify the two near-identical send queues (frame + button command) 🟢 APPLIED
**Category:** deduplication
**Location:** `data/app.js` 4959–5141 (`scheduleButtonCommandPump`/`pumpButtonCommandQueue`/`sendButtonCommand` vs `scheduleFrameSendPump`/`pumpFrameSendQueue`/`queueFirmwareFrame`).
**Current problem:** Two copies of the same rate-limited, drop-on-overflow, in-flight-guarded pump differing only in endpoint/interval/queue-max/counter names.
**Why this is safe:** Behavior is identical modulo parameters; a parameterized `makeRateLimitedQueue({endpoint, intervalMs, maxDepth, onResult, …})` reproduces both.
**What should change:** Introduce one factory; instantiate for frames and buttons.
**What must not change:** `WEBUI_M370_SEND_INTERVAL_MS`/`WEBUI_BUTTON_COMMAND_INTERVAL_MS`, queue maxes, drop semantics (shift oldest, bump `dropped*`), `firmware.frameQueue/buttonQueue` reporting, fallback invocation, `applyFirmwareRuntimeState` on success.
**Dependencies:** None.
**Implementation steps:** (1) Write factory matching current button pump exactly. (2) Swap button queue to it; test. (3) Swap frame queue; test. (4) Remove dead duplicates.
**Regression risk:** Medium → keep both during transition behind the factory.
**Code change:** ⬜
```js
// --- CURRENT: two near-identical pumps (data/app.js 4959–5141), differing only in
// endpoint / interval / queue-max / counter names (buttonCommand* vs frameSend*).
```
```js
// --- PROPOSED: one factory; instantiate twice with the existing constants.
function makeRateLimitedQueue({ endpoint, intervalMs, maxDepth, onResult /* optional */ }) {
  let queue = [], inFlight = false, timer = 0, lastAt = 0;
  function schedule(delay = 0) { /* clearTimeout + setTimeout(pump, max(0,delay)) */ }
  function pump() {
    if (inFlight) return;
    if (!queue.length) { /* report depth 0 */ return; }
    const wait = Math.max(0, intervalMs - (performance.now() - lastAt));
    if (wait > 0) return schedule(wait);
    const q = queue.shift(); inFlight = true; lastAt = performance.now();
    apiPost(endpoint, q.request)
      .then((d) => { if (onResult) onResult(d, q.source); q.resolve?.(d); })
      .catch((e) => { q.fallback?.(); q.resolve?.(null); })
      .finally(() => { inFlight = false; schedule(0); });
  }
  return { enqueue(request, { source, fallback } = {}) {
    if (queue.length >= maxDepth) { queue.shift()?.resolve?.(null); /* ++dropped */ }
    /* push {request, source, fallback, promise/resolve}; schedule(0); return promise */
  }};
}
const frameQueue  = makeRateLimitedQueue({ endpoint: API_ENDPOINTS.frame,   intervalMs: WEBUI_M370_SEND_INTERVAL_MS,      maxDepth: WEBUI_M370_QUEUE_MAX });
const buttonQueue = makeRateLimitedQueue({ endpoint: API_ENDPOINTS.command, intervalMs: WEBUI_BUTTON_COMMAND_INTERVAL_MS, maxDepth: WEBUI_BUTTON_COMMAND_QUEUE_MAX, onResult: applyFirmwareRuntimeState });
```

**Validation method:** Burst test (queue overflow) shows identical drop counts and ordering before/after.

### Refactor 4: Centralize firmware lock contract enforcement via scoped accessors 🟢 APPLIED
**Category:** structure / state cleanup
**Location:** `src/state.*`, all writers of `RuntimeState`.
**Current problem:** The lock-owner contract is documented in `state.h` comments but enforced by convention. Several writes to `restoreAutoAfterScroll` and scroll fields happen outside `Scroll` in `buttons.cpp`/`web_api.cpp`.
**Why this is safe:** Wrapping existing access in `withScrollLock`/`withFrameLock` where the contract already requires it does not change behavior on the cooperative Core-0 path; it closes latent gaps.
**What should change:** Audit each `runtimeState().<lock-owned field>` write; ensure it is inside the correct lock or explicitly Core-0-only with a comment.
**What must not change:** No new nested-lock orderings (preserve `Scroll → Frame → HardwareBus`).
**Dependencies:** Interacts with Bug 1/Refactor 1.
**Implementation steps:** Grep each field; classify; wrap or annotate.
**Regression risk:** Medium (over-locking could deadlock if ordering violated) → review every wrap against the global order.
**Code change:** ⬜
```cpp
// --- CURRENT: lock-owned fields written ad hoc, some outside their lock, e.g.
runtimeState().restoreAutoAfterScroll = false;            // buttons.cpp (no Scroll lock)
runtimeState().scrollFrameCount = 0;                      // various
```
```cpp
// --- PROPOSED: route lock-owned writes through scoped setters that assert/take the lock.
// (Example; see Refactor 6/7 for the concrete pause + restoreAuto setters.)
static inline void withScrollState(const std::function<void()>& fn) { withScrollLock(fn); }
// All callers: withScrollState([]{ runtimeState().restoreAutoAfterScroll = false; });
// Preserve global order Scroll -> Frame -> HardwareBus(-> Storage); never nest in reverse.
```

**Validation method:** Static review checklist + scroll/status stress test.

### Refactor 5: Decompose `applyFirmwareRuntimeState` (260 lines) into field-group appliers
**Category:** extraction
**Location:** `data/app.js` 4664–4923.
**Current problem:** One function merges AP, power, mode, interval, playback/scroll flags, brightness, color, face index, frame, scroll-stop detection, and timeline-mismatch re-fetch. Hard to reason about; central to most UI bugs (4, 5, 9).
**Why this is safe:** Pure extraction into `applyApFields`, `applyPowerFields`, `applyModeInterval`, `applyScrollFlags`, `applyBrightnessColor`, `applyFaceAndFrame`, `detectScrollStop`, `maybeRestoreTimeline`, each returning a `changed` boolean OR'd together.
**What should change:** Function bodies move; the orchestrator calls them in the same order and aggregates `stateChanged`.
**What must not change:** Order of application (later fields depend on earlier, e.g. `firmwareIsScrolling` computed after playback flags), the single trailing `if (stateChanged) renderState()`, and all source-string semantics.
**Dependencies:** Do before Bug 4/5/9 fixes so each fix lands in a focused helper.
**Implementation steps:** Extract bottom-up, preserving shared locals; test polling after each extraction.
**Regression risk:** Medium → snapshot UI state transitions for a recorded status sequence before/after.
**Code change:** ⬜
```js
// --- CURRENT: one 260-line function (data/app.js 4664–4923).
// --- PROPOSED thin orchestrator; field-group appliers keep the SAME order (later
// groups depend on earlier — e.g. firmwareIsScrolling is computed after scroll flags).
function applyFirmwareRuntimeState(data, source = "firmware_status", options = {}) {
  if (!data || typeof data !== "object") return;
  const ctx = { data, renderer: data.renderer || data, source, options, changed: false };
  applyApFields(ctx);
  applyPowerFields(ctx);
  applyModeInterval(ctx);
  applyScrollFlags(ctx);        // sets ctx.firmwareIsScrolling, scroll.* booleans
  applyBrightnessColor(ctx);    // Bug 4 + Bug 5 land here
  applyFaceAndFrame(ctx);
  detectScrollStop(ctx);        // newButtonStopEvent / fallbackButtonStop heuristics
  maybeRestoreTimeline(ctx);    // /api/scroll/meta re-fetch on timeline mismatch
  if (ctx.changed) renderState();
}
```

**Validation method:** Replay a captured `/api/status` sequence through the function and diff resulting `state`/`scroll` objects.

### Refactor 6: Model firmware scroll pause as one source-of-truth + derived effective flag 🟢 APPLIED
**Category:** state cleanup
**Location:** `src/faces.cpp` `applyFirmwareScrollPauseIntentLocked`, `state.h` scroll fields.
**Current problem:** `firmwareScrollPaused` (effective) is stored alongside `User`/`System` and `paused`, with derivation logic spread across functions.
**Why this is safe:** `firmwareScrollPaused` and `paused` are already computed from `User||System`; making the derivation a single helper does not change outputs.
**What should change:** A single `recomputeEffectivePauseLocked()` that sets `firmwareScrollPaused` and `playback` from the two intents; callers only set intents.
**What must not change:** Wire fields (`firmwareScrollUserPaused/SystemPaused/Paused`) must still be emitted; `playback` strings (`scroll`/`scroll_paused`) unchanged.
**Dependencies:** None.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT (src/faces.cpp applyFirmwareScrollPauseIntentLocked): derivation inline,
// mixed with the early-out for the no-frames case.
runtimeState().firmwareScrollActive = true;
runtimeState().firmwareScrollPaused = effectivePaused;   // = user || system
runtimeState().paused = effectivePaused;
if (effectivePaused) runtimeState().playback = "scroll_paused";
else { runtimeState().lastScrollFrameMs = millis(); runtimeState().playback = "scroll"; }
```
```cpp
// --- PROPOSED: single source-of-truth derivation; callers set only the two intents.
static void recomputeEffectivePauseLocked() {
    const bool eff = runtimeState().firmwareScrollUserPaused ||
                     runtimeState().firmwareScrollSystemPaused;
    runtimeState().firmwareScrollPaused = eff;
    runtimeState().paused               = eff;
    runtimeState().playback             = eff ? "scroll_paused" : "scroll";
    if (!eff) runtimeState().lastScrollFrameMs = millis();
}
// setFirmwareScrollPauseFlag(): set user/system intent, then recomputeEffectivePauseLocked().
// Wire fields (firmwareScrollUserPaused/SystemPaused/Paused) + playback strings unchanged.
```

**Validation method:** Pause matrix test: user-pause, system-pause (B6), both, neither → identical emitted flags before/after.

### Refactor 7: Consolidate `restoreAutoAfterScroll` writes under `Scroll` lock + one setter 🟢 APPLIED
**Category:** state cleanup / deduplication
**Location:** `buttons.cpp` (134, 183), `faces.cpp` (62–65, 384), `web_api.cpp` (1248).
**Current problem:** Written from several call sites, some outside `Scroll`.
**Why this is safe:** A single `setRestoreAutoAfterScroll(bool)` that takes the lock centralizes the (already Core-0) writes.
**What must not change:** The semantic that B1/B2/mode-toggle clear it and `terminate_other_activities targetMode=scroll` sets it.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT: scattered (buttons.cpp 134/183, faces.cpp 62–65/384, web_api.cpp 1248),
// some outside the Scroll lock:
runtimeState().restoreAutoAfterScroll = false;
runtimeState().restoreAutoAfterScroll = true;
```
```cpp
// --- PROPOSED: one setter under Scroll lock; all call sites use it.
void setRestoreAutoAfterScroll(bool v) {
    withScrollLock([&]() { runtimeState().restoreAutoAfterScroll = v; });
}
// Semantics preserved: B1/B2/mode-toggle clear it; terminate_other_activities(scroll) sets it.
```

**Validation method:** Mode/scroll transition tests assert the flag matches today.

### Refactor 8: Extract repeated `withHardwareBusLock` file primitives 🟢 APPLIED
**Category:** deduplication
**Location:** `src/web_api.cpp` (`littleFsExistsLocked`/`littleFsOpenLocked`/`fileSizeLocked`/`closeFileLocked`) vs `storage.cpp`/`power_monitor.cpp` which inline the same pattern.
**Current problem:** The locked-LittleFS helpers exist only in `web_api.cpp`; `storage.cpp` and `power_monitor.cpp` re-inline `withHardwareBusLock([&]{ LittleFS… })`.
**Why this is safe:** Moving the helpers to a shared `storage`-level header and reusing them is mechanical.
**What must not change:** Lock domain (`HardwareBus`) — unless Bug 3 reassigns file I/O to a `Storage` lock, in which case do Bug 3 first and route these helpers to the new lock.
**Dependencies:** Coordinate with Bug 3.
**Regression risk:** Low–Medium (ordering vs Bug 3).
**Code change:** ⬜
```cpp
// --- CURRENT: helpers live only in web_api.cpp; storage.cpp & power_monitor.cpp re-inline:
withHardwareBusLock([&]() { exists = LittleFS.exists(SETTINGS_PATH); });   // storage.cpp
withHardwareBusLock([&]() { calibExists = LittleFS.exists(BATTERY_CALIB_PATH); }); // power_monitor.cpp
```
```cpp
// --- PROPOSED: promote to storage.h and reuse everywhere (route to the new Storage
// lock if Bug 3 lands; otherwise keep HardwareBus — do Bug 3 first).
bool   littleFsExistsLocked(const String& path);
File   littleFsOpenLocked(const String& path, const char* mode);
size_t fileSizeLocked(File& f);
void   closeFileLocked(File& f);
// storage.cpp / power_monitor.cpp: exists = littleFsExistsLocked(SETTINGS_PATH);  // one domain
```

**Validation method:** File ops unit tests; ensure single lock domain per call.


### Refactor 13: Extract LittleFS logic from `loadSavedFaces` 🟢 APPLIED
**Category:** modularization
**Location:** `src/storage.cpp` `loadSavedFaces` (238–364).
**Current problem:** `loadSavedFaces` does file I/O, parses JSON under the hardware bus lock, extracts fields, normalizes M370, populates the runtime array directly, and triggers apply/startup logic.
**Why this is safe:** Splitting into `parseAndValidateFaces` and `applyFacesToState` makes the function testable in isolation.
**What must not change:** The startup face default precedence logic and sorting.
**Regression risk:** Medium.
**Code change:** ⬜
```cpp
// --- CURRENT (src/storage.cpp loadSavedFaces): one huge function does everything
bool loadSavedFaces(bool applyStartupFace) { /* ... */ }
```
```cpp
// --- PROPOSED: split into pure-ish parser and state-applier
static bool parseAndValidateFaces(JsonArrayConst faces, const String& startupId, RuntimeFace* out, uint16_t& count);
static void applyFacesToState(uint16_t selectedIndex, bool applyStartupFace);

bool loadSavedFaces(bool applyStartupFace) {
    // 1. I/O and parse under lock
    // 2. parseAndValidateFaces(...)
    // 3. std::sort(...)
    // 4. applyFacesToState(...)
}
```

**Validation method:** Unit tests for `parseAndValidateFaces` with various JSON structures.

### Refactor 9: Replace overlapping WebUI scroll booleans with derived predicates
**Category:** state cleanup
**Location:** `data/app.js` `scroll` object + `isScrollPlaybackValue`, `state.textScrollActive`.
**Current problem:** `scroll.active/paused/userPaused/systemPaused/firmwareBacked` + `state.textScrollActive` + `state.playback` overlap; updated in multiple places (drift risk behind Bug 9).
**Why this is safe:** Introduce pure predicates (`isScrolling()`, `isUserPaused()`, `isSystemPaused()`) derived from the firmware-truth fields; keep storing only the firmware-provided flags.
**What should change:** Replace scattered boolean writes with derivations where possible; keep only fields that the firmware authoritatively provides.
**What must not change:** `updateScrollUi` outputs (button enabled/labels), upload/restore gating booleans (`uploading/startBusy/restoring` are local control flags, keep them).
**Dependencies:** After Refactor 5.
**Regression risk:** Medium → cover with `updateScrollUi` snapshot tests.
**Code change:** ⬜
```js
// --- CURRENT: overlapping stored booleans recomputed in many places
scroll.active; scroll.paused; scroll.userPaused; scroll.systemPaused; scroll.firmwareBacked;
state.textScrollActive; state.playback;   // partially duplicate firmware truth
```
```js
// --- PROPOSED: store only firmware-provided truth; derive the rest via pure predicates.
function isScrolling()   { return scroll.firmwareBacked || isScrollPlaybackValue(state.playback); }
function isUserPaused()  { return scroll.userPaused; }
function isSystemPaused(){ return scroll.systemPaused && !scroll.userPaused; }
function isEffectivePaused() { return isUserPaused() || isSystemPaused() || state.playback === "scroll_paused"; }
// updateScrollUi() reads the predicates; control flags (uploading/startBusy/restoring) stay as fields.
```

**Validation method:** For a matrix of firmware scroll states, assert identical button DOM state before/after.

### Refactor 10: Name and table-drive the command dispatch reply assembly 🟢 APPLIED
**Category:** structure
**Location:** `web_api.cpp handleApiCommand` reply block (1335–1360) + per-command handlers.
**Current problem:** The shared reply is hand-assembled; battery commands special-case power. Adding a command requires editing multiple spots.
**Why this is safe:** Extract `buildCommandReply(cmd, scrollState)` and a `commandWantsPower(cmd)` predicate; no field changes.
**What must not change:** Reply field set and the `sCommandErrorStatus` 400/409 mapping.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT (src/web_api.cpp handleApiCommand): reply hand-assembled inline + battery special-case
reply["color"] = runtimeState().colorHex; /* ...~20 fields... */
if (cmd == "reset_battery_min" || cmd == "reset_battery_max") {
    servicePowerMonitor(true);
    addPowerStatus(reply.createNestedObject("power"), true, true);
}
```
```cpp
// --- PROPOSED: extract builder + predicate; identical field set + 400/409 mapping kept.
static void buildCommandReply(JsonObject reply, const String& cmd, const ScrollStateSnapshot& s) {
    /* exactly today's fields */
}
static bool commandWantsPower(const String& cmd) {
    return cmd == "reset_battery_min" || cmd == "reset_battery_max";
}
// handleApiCommand(): buildCommandReply(...); if (commandWantsPower(cmd)) { servicePowerMonitor(true); addPowerStatus(...); }
```

**Validation method:** Reply JSON diff per command.


### Refactor 14: Extract `sampleBattery` disconnect logic into helper 🟢 APPLIED
**Category:** structure / extraction
**Location:** `src/power_monitor.cpp` `sampleBattery` (281–372).
**Current problem:** A single 90-line function implements EMA filtering, large-drop disconnect detection, recovery, calibration updates, and JSON field dirtying.
**Why this is safe:** Extracting pure logic (e.g., `detectBatteryDisconnect(adcMv, prevMv)`) keeps side-effects in the caller.
**What must not change:** The hysteresis values (`BATTERY_DISCONNECT_ADC_DROP_MV`, `BATTERY_RECONNECT_ADC_MV`).
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT (src/power_monitor.cpp sampleBattery): disconnect detection inlined
const bool hugeRawDrop = hadPreviousAdc && prevAdcMv > adcMv &&
    static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
    adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
```
```cpp
// --- PROPOSED: pure helper
struct BatteryEdge { bool hugeRawDrop; bool stillDisconnected; };
static BatteryEdge detectBatteryDisconnect(uint16_t adcMv, uint16_t prevAdcMv, bool hadPrev, bool wasDisconnected) {
    const bool drop = hadPrev && prevAdcMv > adcMv &&
        static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
        adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
    return { drop, wasDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV };
}
```

**Validation method:** Hardware disconnect test (pulling battery during operation).

### Refactor 11: Comment/identifier cleanup (auto-generated Chinese boilerplate) 🟢 APPLIED
**Category:** comments
**Location:** Throughout `src/*` and `data/*` — repeated template comments like `// 中文块：执行对应逻辑 X 相关逻辑，连接 WebUI 状态、DOM 和固件 API。` and `// 说明 … 中当前代码块的职责和维护约束。`
**Current problem:** Many comments are auto-generated placeholders adding noise without information; some functions have a generic banner that doesn't describe behavior.
**Why this is safe:** Comments only; zero behavior impact.
**What should change:** Replace placeholder banners with one-line behavioral descriptions or delete; keep the genuinely informative invariant comments (EH-A/B/C, D1–D8, lock contracts, drift logic).
**What must not change:** The invariant/contract comments and the `SYNCTEST_MARKER`/cache-version markers in HTML.
**Regression risk:** Low (avoid touching `?v=` cache-busting strings and any string-matched markers).
**Code change:** ⬜
```cpp
// --- CURRENT: auto-generated placeholder banners add noise, e.g.
// 中文块：执行对应逻辑 logicalToPhysicalIndex 相关逻辑，连接 WebUI 状态、DOM 和固件 API。
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
```
```cpp
// --- PROPOSED: replace with a one-line behavioral description, or delete.
// logical→physical serpentine index for one LED (odd rows reversed).
// KEEP the informative invariant comments verbatim: EH-A/B/C, D1–D8, E1–E6, lock order,
// scroll drift logic, and the HTML "?v=..." cache markers / SYNCTEST_MARKER.
```

**Validation method:** Build + grep that protected markers still present.

### Refactor 12: Gate hot-path `Serial.printf` behind a log-level switch 🟢 APPLIED
**Category:** performance
**Location:** `faces.cpp serviceAutoPlayback`/`applySavedFaceIndex`, `scroll.cpp`, `power_monitor.cpp`.
**Current problem:** Per-frame/per-apply `Serial.printf` runs even in normal operation; blocking UART writes add jitter on Core 0.
**Why this is safe:** Wrapping in a compile-time/runtime verbosity guard preserves messages when enabled.
**What must not change:** Error/warning messages on failure paths remain by default; default-on messages users may rely on for diagnostics should stay unless clearly redundant.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT: unconditional hot-path logging (src/faces.cpp serviceAutoPlayback / applySavedFaceIndex):
Serial.printf("Applied saved face %u/%u via %s: %s\n", ...);   // every auto switch
```
```cpp
// --- PROPOSED: gate verbose logs; keep error/warning paths on by default.
#ifndef RINA_LOG_VERBOSE
#define RINA_LOG_VERBOSE 0
#endif
#define LOGV(...) do { if (RINA_LOG_VERBOSE) Serial.printf(__VA_ARGS__); } while (0)
// hot path: LOGV("Applied saved face %u/%u via %s: %s\n", ...);
// failure path stays: Serial.printf("auto face apply failed: %s\n", error.c_str());
```

**Validation method:** Measure Core-0 loop jitter with logging off vs on.

---

## 7. Proposed target architecture

The change is **organizational**, not a rewrite. Module boundaries are already good; the goal is clearer seams between **state**, **transport**, **rendering**, **protocol**, and **persistence**, plus enforced locking.

### 7.1 Firmware modules (proposed)
- `state` (unchanged role): owns `RuntimeStore`; add `readFrameStateSnapshot()`/`readScrollStateSnapshot()` as the **only** sanctioned cross-core read path. Add `setRestoreAutoAfterScroll()` and `recomputeEffectivePauseLocked()` setters so writers go through one place.
- `sync` (unchanged): keep the three mutexes and global order. Consider a fourth `Storage` mutex **only if** Bug 3 confirms flash and LED do not share hardware (then `HardwareBus` ⇒ strictly LED bus).
- `led_renderer`: keep render/codec/queue. Frame queue stays Core-0-owned (documented). Publish directly from queue slot (Bug 11).
- `scroll`: render task; fix frame-apply (Bug 2).
- `faces`: mode + deferred-restore + scroll lifecycle; pause derivation centralized (Refactor 6).
- `storage`: owns the locked-LittleFS primitives (Refactor 8); repair-on-corrupt (Bug 6).
- `power_monitor`: stage overlay-relevant fields into `sAnim` under `sAnimMux` (Bug 8).
- `web_api`: split `handleApiScroll` into phase helpers (Refactor 2); table-driven command reply (Refactor 10); read state via snapshots (Refactor 1).
- `web_json`, `psram_json`, `utils`, `config`: unchanged.

### 7.2 Web UI structure (proposed, still single-file unless asked)
- **Transport layer**: `apiGet/apiPost/apiPostWithUploadProgress` (unchanged) + one `makeRateLimitedQueue` factory powering both send queues (Refactor 3).
- **Sync layer**: `applyFirmwareRuntimeState` becomes a thin orchestrator over pure-ish field appliers (Refactor 5); `setColor` short-circuits firmware-sync no-ops (Bug 5).
- **Scroll subsystem**: keep upload/restore state machine; isolate chunk-size estimation (Bug 10).
- **State layer**: keep `state`/`firmware`; reduce `scroll` booleans to firmware-truth + derived predicates (Refactor 9).
- **Render layer**: `renderMatrices`/`renderState`/`updateScrollUi` unchanged outputs.

### 7.3 Pure functions vs side-effect owners
- **Pure (no I/O/DOM):** M370 codec (`m370ToFrame`/`frameToM370`/firmware codec), color/hex/utf-8 validators, battery LUT, `chooseFirstChunkFrames` (after Bug 10), field appliers that only mutate the passed snapshot.
- **Side-effect owners:** the queues (network), `renderCurrentFrameToLedStrip` (LED bus), `writeJsonFileAtomic` (flash), `service*` loop functions, DOM `render*`.

### 7.4 Centralize vs keep local
- **Centralize:** cross-core firmware reads (snapshots), firmware pause derivation, `restoreAutoAfterScroll`, WebUI scroll truth.
- **Keep local:** UI control flags (`uploading/startBusy/restoring/pauseToggleLocked`), DOM-diff caches, upload progress token, firmware frame queue (Core-0 only).
- **Derive, don't store:** `state.textScrollActive` (from playback + flags); WebUI effective pause.

No code is written in this section — names are proposals only.

---

## 8. Step-by-step implementation plan

Ordering principle after the `prompt.txt` reconsideration: destructive-state correctness first, then live-status freshness and cross-core snapshots, then low-risk UI/firmware fixes, then extraction refactors, and timing/perf last. The detailed phase inventory below remains useful, but the execution order is superseded by this revised sequence:

1. **Phase 0 — Consolidate + baseline:** merge addendum bugs into the canonical backlog, remove duplicate severity calls, and capture protocol/status/UI fixtures.
2. **Phase 1 — Protocol mutation fixes:** invalid `/api/frame` and failed replacement `/api/scroll` are guarded before mutation. A3 and A4 are applied; keep regression fixtures for destructive-state checks.
3. **Phase 2 — Status freshness:** A1/A12 is applied so active scroll progress and counter-only changes participate in `/api/status?since=...` freshness semantics.
4. **Phase 3 — Cross-core snapshots:** Bug 1/A8 frame/status snapshot and Bug 8/A2 power snapshot are applied; keep snapshot reads as the pattern for future handlers.
5. **Phase 4 — Remaining low-risk fixes:** Bugs 2/4/5/6/9/10/11/13/14 and A10/A11 are now applied.
6. **Phase 5 — Refactors:** split `handleApiScroll`, command replies, queues, storage helpers, and `applyFirmwareRuntimeState` only after protocol mutation ordering is fixed.
7. **Phase 6 — Performance/timing:** hot-path log gating is applied. Bug 3 remains hardware-gated; do not move file I/O off `HardwareBus`/change lock topology without recorded hardware proof.

The historical phase notes below are retained as implementation detail, but if they conflict with the revised order above, the revised order wins.

### Phase 1: Baseline behavior documentation
**Goal:** Freeze current observable behavior as a test baseline.
**Allowed changes:** Test/harness files, captured fixtures (status JSON samples, scroll upload transcripts). No `src/`/`data/` logic edits.
**Forbidden changes:** Any firmware/UI logic.
**Files affected:** new `test/` fixtures, a Node script to replay status JSON through a copy of `applyFirmwareRuntimeState` (or DOM-less harness).
**Exact steps:** (1) Capture `/api/status` (all query variants), `/api/scroll` request/response transcripts, `/api/command` replies for each command. (2) Record LED `show()` cadence during idle/scroll/save via `micros()` logging. (3) Snapshot `updateScrollUi` DOM state for the pause matrix.
**Expected behavior after phase:** Unchanged.
**Tests after phase:** Baseline fixtures committed and reproducible.
**Rollback:** Delete test artifacts.

### Phase 2: Comment / identifier cleanup (Refactor 11)
**Goal:** Remove auto-generated placeholder comments; keep invariant comments.
**Allowed:** Comments only; whitespace.
**Forbidden:** Any token that is string-matched (`?v=` cache versions, `SYNCTEST_MARKER`, command names, JSON keys, DOM ids).
**Files affected:** `src/*`, `data/app.js`, `data/index.html` (comments only).
**Exact steps:** Replace/delete placeholder banners; preserve EH-/D-/lock/drift comments.
**Expected behavior:** Identical build output (only comments differ).
**Tests:** Firmware builds; UI loads; protected-marker grep passes.
**Rollback:** `git revert`.

### Phase 3: Extract pure helpers (Refactors 2, 3, 5, 10) — no behavior change
**Goal:** Break up the three giant functions and the duplicated queues.
**Allowed:** Function extraction with identical logic/ordering/lock points.
**Forbidden:** Reordering lock acquisitions; changing JSON fields, status codes, intervals.
**Files affected:** `web_api.cpp`, `app.js`.
**Exact steps:** One extraction per commit, each followed by the Phase-1 regression suite. Do `handleApiScroll` (R2) and command reply (R10) on firmware; queue factory (R3) and `applyFirmwareRuntimeState` decomposition (R5) on UI.
**Expected behavior:** Byte-identical API responses; identical queue drop behavior; identical UI transitions on replay.
**Tests:** Phase-1 fixtures green after every commit.
**Rollback:** Revert the offending extraction commit.

### Phase 4: State snapshot + lock-contract seams (Refactors 1, 4, 6, 7, 8)
**Goal:** Route cross-core reads/writes through sanctioned snapshots/setters.
**Allowed:** Adding snapshot readers/setters; wrapping existing accesses in the already-required lock.
**Forbidden:** New nested-lock orders; changing the global lock order.
**Files affected:** `state.*`, `web_api.cpp`, `faces.cpp`, `buttons.cpp`, `storage.cpp`, `power_monitor.cpp`.
**Exact steps:** (1) Add `readFrameStateSnapshot()` and switch status/frame/command reads to it. (2) Centralize `restoreAutoAfterScroll` + pause derivation. (3) Move locked-LittleFS helpers to `storage`.
**Expected behavior:** Identical JSON; no functional change in single-threaded use; reads now atomic.
**Tests:** API JSON diff = identical; dual-tab polling-during-scroll heap-integrity check passes.
**Rollback:** Revert; snapshots are additive.

### Phase 5: Separate side effects (part of Refactor 9 prep + Bug 5 seam)
**Goal:** Make `setColor` firmware-sync a true no-op when unchanged; isolate WebUI scroll-truth derivation.
**Allowed:** Reordering the early-return in `setColor`; adding derived predicates.
**Forbidden:** Changing user-initiated color behavior; changing emitted commands.
**Files affected:** `app.js`.
**Exact steps:** Move `unchangedFirmwareSync` early-return above DOM/render side effects (Bug 5); add `isScrolling()/isUserPaused()/isSystemPaused()` predicates without removing fields yet.
**Expected behavior:** No dropdown reset / matrix re-render on unchanged color polls; everything else identical.
**Tests:** Bug 5 UI tests; render-counter assertions.
**Rollback:** Revert.

### Phase 6: Fix confirmed bugs (2, 4, 5, 6, 9, 11, 12 round-trip)
**Goal:** Land the focused, low-risk correctness fixes.
**Allowed:** The specific edits in each bug's Fix strategy.
**Forbidden:** Touching timing (Phase 8) or lock topology (Phase 7).
**Files affected:** `scroll.cpp` (B2), `app.js` (B4, B5, B9), `storage.cpp` (B6), `led_renderer.cpp` (B11), tests (B12).
**Exact steps:** One bug per commit + its validation test.
**Expected behavior:** Each bug's "Expected behavior" met; no other change.
**Tests:** Per-bug validation tests (Section 10).
**Rollback:** Per-commit revert.

### Phase 7: Lock-safety hardening (Bug 7) and overlay power snapshot (Bug 8)
**Goal:** Fail safe if mutex creation fails; remove overlay cross-core power read.
**Allowed:** Skip Core-1 task on mutex failure + diagnostic; stage power fields into `sAnim`.
**Forbidden:** Changing the lock order.
**Files affected:** `main.cpp`, `sync.cpp`, `button_animations.cpp`, `power_monitor.cpp`.
**Exact steps:** (1) `if (!initSyncPrimitives()) { /* diagnostic; do not startScrollRenderTask */ }` and route rendering on Core 0. (2) Populate battery overlay fields under `sAnimMux`.
**Expected behavior:** Normal boot unchanged; fault-injection runs single-core safely.
**Tests:** Fault-injection (Bug 7), overlay consistency stress (Bug 8).
**Rollback:** Revert; both are additive guards.

### Phase 8: Performance-sensitive paths (Bug 3, Refactor 12)
**Goal:** Stop file I/O from stalling LED refresh; gate hot logs. Bug 10 first-chunk sizing is already applied.
**Allowed:** Reassign storage I/O off `HardwareBus` (after hardware confirmation); estimate chunk size; log gating.
**Forbidden:** Changing atomic-write semantics; changing wire protocol.
**Files affected:** `storage.cpp`, `web_api.cpp` (streaming), `app.js` (B10), hot-path logs.
**Exact steps:** (1) Confirm WS2812 (RMT/GPIO) vs LittleFS (flash) independence; if independent, remove `HardwareBus` from file content I/O or add a `Storage` mutex. (2) Replace shrink-loop with estimate+verify. (3) Gate logs.
**Expected behavior:** No scroll hitch during saves; faster long-text send; identical outputs.
**Tests:** Bug 3 timing test, Bug 10 bench, atomicity test.
**Rollback:** Revert; keep `HardwareBus`-over-IO if any corruption observed.

### Phase 9: Reduce overlapping WebUI scroll state (Refactor 9 completion)
**Goal:** Remove now-derivable booleans.
**Allowed:** Delete fields fully replaced by predicates.
**Forbidden:** Changing `updateScrollUi` outputs.
**Files affected:** `app.js`.
**Exact steps:** Replace remaining reads with predicates; delete dead fields; keep control flags.
**Expected behavior:** Identical UI.
**Tests:** `updateScrollUi` snapshot matrix green.
**Rollback:** Revert.

### Phase 10: Final cleanup and full regression
**Goal:** Remove dead code, re-run everything.
**Allowed:** Dead-code removal, final doc updates.
**Forbidden:** New behavior.
**Files affected:** any with leftovers.
**Tests:** Full Section 11 regression plan + manual hardware pass.
**Rollback:** Revert.

---

## 9. Behavior preservation checklist

Must remain unchanged through Phases 1–10 (except where a bug fix explicitly and justifiably changes it — Bug 3 changes timing contention, Bugs 5/4 change UI-render cadence, and A1/A12 may change `/api/status?since=` freshness behavior during active scroll or counter-only updates):

- **Public HTTP routes & methods:** `/`, `/index.html`, `/api/status` (GET/OPTIONS), `/api/power` (GET/OPTIONS), `/api/frame` (POST/OPTIONS), `/api/scroll`, `/api/scroll/meta` (GET/OPTIONS), `/api/command` (POST/OPTIONS), `/api/saved_faces` (GET/POST/OPTIONS), static fallback.
- **JSON request fields:** scroll upload (`frames`, `append`, `start`, `chunkIndex`, `totalFrames`, `timelineId`, `sourceText`, `fontId`, `generatorVersion`, `fps`, `intervalMs`, `source`, `storage`, `persist`, `saveToFlash`, `stepLedPerFrame`); command (`cmd`, `payload`, per-command keys); frame (`m370`, `mode`, `playback`, `reason`, `faceId`).
- **JSON response fields:** every key in `handleApiStatus`/`handleApiFrame`/`handleApiCommand`/`handleApiScroll`/`handleApiScrollMeta`/`handleApiPower` replies (e.g. `ok`, `v`, `version`, `next_poll_ms`, `renderer.*`, `power.*`, `stats.*`, `scrollStopEvent.*`, `uploadComplete`, `timelineId`, `lit`, `lastM370`). Field **names and value types**.
- **Status codes & messages:** 200/204/400/404/405/409/413/500/503/507 and their exact error strings (E1/E2/E3/D1–D8 paths).
- **`stateVersion`/`since` long-poll contract:** monotonic non-zero, `unchanged` short response shape, except for the documented active-scroll/counter freshness fix where changed scroll-observable state must not be hidden behind `unchanged:true`.
- **DOM IDs/classes:** all in `index.html` consumed by `app.js`/`styles.css` (`matrix-*`, `scroll-*`, `brightness-*`, `color-*`, `mode-toggle`, `data-gpio` values, `face-library-list`, etc.).
- **Event names / button semantics:** B1 next, B2 prev, B3 mode, B4/B5 brightness ∓8, B3+B1/B2 interval ∓500 ms, B6 short=battery / long=continuous; combo-consume rule; repeat timings.
- **Timing behavior:** `M370_FRAME_MIN_INTERVAL_MS=33`, queue depth 3, scroll drift reset = 4 intervals, `LED_RENDER_MIN_GAP_US=2500`, `LED_SIGNAL_RESET_US=300`, boot hold/settle constants, debounce/repeat constants, `POWER_WEB_SLOW_PUBLISH_MS=10000`. (Bug 3 changes only the *contention window*, not these constants.)
- **Default values:** color `#f971d4`, brightness 50 (min10/max200), mode `manual`, playback `idle`, auto interval 3000 (min500/max10000), scroll interval 100 ms (fps default), `MAX_SCROLL_FRAMES=3072`, `MAX_AUTO_FACES=128`, `MAX_SCROLL_TEXT_BYTES=4096`.
- **Storage keys / file formats:** `saved_faces.json` (`category:"unified_saved_faces"`, `faces[]` with `order≥1`, ≥1 `type:"default"`), `runtime_settings.json` (`format:"rina_runtime_settings_v1"`, `mode`, `autoIntervalMs`), `battery_calib.json` (`rina_battery_calibration_v1`, `v_max`/`v_min`). Atomic temp+rename.
- **Protocol/hardware formats:** `M370:` + 93 hex (370 bits + 2 padding); serpentine odd-rows-reversed mapping; row lengths/offsets; WS2812 GRB.
- **User-visible text:** Chinese UI labels, error/log strings users may match on, the LittleFS-error HTML page.
- **Startup behavior:** boot LED quiet window, startup face application, AP SSID/password/IP/domain, DNS captive portal.
- **Stop/reset behavior:** blank-then-deferred-restore timing, `restoreAutoAfterScroll` semantics, scroll RAM-only contract.
- **Rendering output:** identical lit pixels/colors for identical frames; overlay glyph bitmaps unchanged.
- **Edge cases:** empty body 400, oversize 413, timeline mismatch/incomplete 409, buffer unavailable 507.

---

## 10. Bug-fix validation checklist

| Test | Mode | Setup | Steps | Expected result | Protects |
|---|---|---|---|---|---|
| BV-1 status race | Manual+instrumented | Firmware scrolling; `heap_caps_check_integrity` enabled | Two browser tabs poll `/api/status` (non-summary) for 5 min | No heap corruption; `lit`/`lastM370` never malformed | Bug 1 |
| BV-2 scroll frame skip | Manual hardware | 5 fps scroll running | Sweep brightness slider for 20 s; record with slow-mo | No skipped scroll columns; `framesAccepted` advances == index advances | Bug 2 |
| BV-3 save no-stall | Instrumented | Scroll running; 64 KB `saved_faces.json` | POST it; log `micros()` gap around `show()` | Max inter-`show` gap unchanged (no multi-ms spike); file written atomically | Bug 3 |
| BV-4 reset brightness | UI | Page loaded (default 50) | Set 120 via slider; pass ≥2 poll cycles; click 重置默认亮度 | Returns to firmware default; in-progress drag not stomped by polls | Bug 4 |
| BV-5 color no-op poll | UI | Basic page, color dropdown open | Let 3 polls pass with identical firmware color | Dropdown selection unchanged; matrix render counter does not increment | Bug 5 |
| BV-6 settings repair | Manual | Corrupt `runtime_settings.json` | Reboot | File rewritten to valid JSON; next boot parses cleanly | Bug 6 |
| BV-7 mutex fail-safe | Fault injection | Stub `initSyncPrimitives`→false | Boot | Core-1 task not started; diagnostic shown; no cross-core access | Bug 7 |
| BV-8 overlay power | Stress | B6 battery overlay held | Toggle charger input repeatedly 2 min | No percent/voltage struct-tear (logged snapshot consistent) | Bug 8 |
| BV-9 pause flags | Contract+UI | — | Inspect every `/api/status` variant; then simulate omitted split flags | All variants include split flags; with flags omitted, user-pause not inferred | Bug 9 |
| BV-10 chunk sizing | Bench | Max-length scroll text | Time `chooseFirstChunkFrames`; compare chosen count | Same chosen count; ≥10× faster | Bug 10 |
| BV-11 dequeue copy | Bench | Max frame rate | Run 1000 frames | `framesDequeued` identical; throughput ≥ before | Bug 11 |
| BV-12 m370 round-trip | Unit | — | Encode/decode frames with LEDs {0,17,369} set | Exact round-trip; padding bits ignored | Bug 12 |

---

## 11. Regression test plan

For each test, what it proves is stated.

### Unit tests
- **M370 codec round-trip** (`m370ToPackedBits`↔`frameToM370`, boundary LEDs): proves frame encoding unchanged after Refactor 1/2 and Bug 11.
- **UTF-8 / meta-id validators** (`validateScrollSourceText`, `validateMetaIdString`): proves scroll upload acceptance/rejection unchanged.
- **Battery LUT + percent interpolation**: proves power math untouched.
- **JSON field extractors** (`web_json.cpp`): proves raw-body parsing unchanged (critical for scroll uploads).
- **`chooseFirstChunkFrames`**: proves Bug 10 estimate matches brute-force result.

### Integration tests (firmware ↔ HTTP)
- **`/api/status` field/shape snapshot** for all query variants: proves Refactors 1/5/10 and Bugs 1/5 preserve the wire contract.
- **`/api/scroll` upload state machine**: single-chunk, multi-chunk, `append` ordering, 409 retry, oversize 413, bad-frame invalidate, timeline-backed incomplete block: proves Refactor 2 preserves all EH-/D- invariants.
- **`/api/command` dispatch**: each of 16 commands returns the same reply shape and status mapping: proves Refactor 10.
- **`/api/saved_faces` validate+write+reload**: proves validation and atomic write unchanged after Bug 3/Refactor 8.

### UI tests (DOM-level, replay-based)
- **`applyFirmwareRuntimeState` replay**: feed a recorded status sequence, diff resulting `state`/`scroll`: proves Refactor 5 + Bugs 4/5/9.
- **`updateScrollUi` pause matrix**: button enabled/labels for {idle, scrolling, user-paused, system-paused, both}: proves Refactor 6/9.
- **Color picker stability**: proves Bug 5.

### API/protocol tests
- **Long-poll `since` cursor**: unchanged stable state → `unchanged` response; changed state or active-scroll/counter freshness cursor → full doc: proves `stateVersion` semantics and the A1/A12 freshness exception.
- **`scrollStopEvent` detection**: GPIO B1/B2/B3 stop raises seq and WebUI mirrors: proves sync boundary intact.

### Timing / async tests
- **LED `show()` cadence** idle/scroll/save: proves Bug 3 fix removes save-stall without violating `LED_RENDER_MIN_GAP_US`.
- **Frame/button queue rate limit + overflow drop**: proves Refactor 3 preserves limiter.
- **Scroll drift compensation**: long-run index vs wall-clock: proves Bug 2 fix didn't disturb timing.

### State-consistency tests
- **Dual-tab polling during scroll + heap integrity**: proves Bug 1/Refactor 1.
- **Pause source-of-truth**: user vs system pause never conflated: proves Bug 9 / Refactor 6.

### Persistence tests
- **Power-loss-during-write**: old or new file intact: proves atomicity after Bug 3.
- **Corrupt settings repair**: proves Bug 6.
- **Saved-faces reload after write** selects correct index: proves `loadSavedFaces` untouched.

### Performance tests
- **Long-text send latency** (Bug 10), **dequeue throughput** (Bug 11), **Core-0 loop jitter with logs off** (Refactor 12).

### Manual hardware tests
- All 6 buttons + combos; B6 short/long battery overlay during scroll; mode toggle during scroll; brightness sweep during scroll; large saved-faces save during scroll; boot quiet window (no stray pixels).

### Failure-mode tests
- Mutex creation failure (Bug 7); scroll buffer unavailable → 507; LittleFS unmounted → error page + 503s; offline `file://` mode no-ops.

---

## 12. Risk analysis

| Risk | Why risky | What could break | Minimize | Test | Delay? |
|---|---|---|---|---|---|
| Splitting `handleApiScroll` (R2) | Subtle lock snapshot/commit boundaries + many error invariants | Wrong 409/413/507 handling; partial upload corruption | One block per commit; keep lock points identical | BV/scroll integration suite | No (Phase 3, but gated by tests) |
| Reassigning storage I/O off `HardwareBus` (Bug 3) | Changes a real timing/contention assumption | LED corruption or flash/LED contention if they *do* share a resource | Confirm WS2812 (RMT/GPIO) vs flash independence on hardware first; fall back to a `Storage` mutex | BV-3 + 1000-cycle write+show | **Yes — Phase 8**, after correctness fixes |
| Lock-contract wrapping (R4/R7) | Over-locking can deadlock if order violated | Boot hang / watchdog reset | Review every wrap against `Scroll→Frame→HardwareBus`; never nest in reverse | Scroll+status stress | Phase 4 |
| `applyFirmwareRuntimeState` decomposition (R5) | Field order dependencies | Wrong derived scroll/face state | Bottom-up extraction + replay diff | UI replay | Phase 3 |
| Reducing WebUI scroll booleans (R9) | Many call sites read them | Mislabeled pause/stop buttons | Keep predicates equivalent; snapshot matrix | `updateScrollUi` matrix | **Yes — Phase 9**, last |
| Mutex fail-safe (Bug 7) | Alters boot topology on failure | Could disable rendering if misdetected | Only trigger on genuine null handle; keep normal path identical | BV-7 fault injection | Phase 7 |
| Comment cleanup (R11) | Risk of touching string-matched markers | Broken cache-busting / sync markers | Protect `?v=`, `SYNCTEST_MARKER`, keys, ids via grep gate | marker grep | Phase 2 |

Riskiest overall: **Bug 3** (timing/hardware assumption) and **R2** (protocol-critical lock boundaries). Both are gated behind the Phase-1 baseline and dedicated tests, and Bug 3 is deferred until after all correctness fixes.

---

## 13. Things not to change

- **Wire protocol & field names** for all routes (Section 9) — unless a bug item explicitly lists a change (Bug 5/4 UI cadence and A1/A12 status freshness are the currently documented exceptions).
- **`stateVersion`/`since` long-poll semantics** and the `unchanged` short response, except where A1/A12 deliberately make active scroll or counter-only changes observable.
- **M370 format** (`M370:`+93 hex, 370+2 padding) and the serpentine mapping / row tables / `static_assert`s in `config.h`.
- **Lock order** `Scroll → Frame → HardwareBus`; no new nested locks.
- **Timing constants** in `config.h` (frame interval, queue depth, render gap, reset window, boot holds, debounce/repeat, slow-publish). Bug 3 changes only the *file-I/O contention window*, not these values.
- **Scroll upload invariants** EH-A/EH-B/EH-C and D1–D8 / E1–E6 encoded in `web_api.cpp`/`state.cpp` comments — preserve exactly; only re-home them during extraction.
- **Atomic write semantics** (temp + rename + remove-temp-on-fail).
- **Battery auto-calibration stays disabled** (manual reset only) — do not re-enable.
- **Excluded hardware** (I2C PMIC / PD / temperature) — do not add.
- **Boot LED quiet-window sequence** in `setup()` — order is timing-sensitive; do not reorder.
- **DOM IDs/classes/`data-gpio` values** and `?v=` cache markers in `index.html`.
- **Working-but-ugly code where behavior is unclear:** the drift-compensation math in `scrollRenderTask`, the EMA/disconnect heuristics in `power_monitor.cpp`, and the `applyFirmwareRuntimeState` scroll-stop heuristics (`fallbackButtonStop` regex) — refactor *structure* only, keep logic byte-for-byte until covered by tests.
- **The Core-0 service order** in `loop()` (semantic per its comment).

---

# Addendum: Additional Audit Pass From `prompt.txt`

> Added without removing existing content.
> This addendum records a second pass over the runtime firmware/WebUI paths, plus validation results from `node --check data/app.js` and `pio run`.

## A1. Scope of Additional Analysis

Reviewed these runtime paths:

- `src/main.cpp`: setup order, Core-0 loop scheduling, service order.
- `src/state.h` / `src/state.cpp`: `RuntimeState`, `RuntimeStore`, scroll frame/source buffers, version publishing.
- `src/sync.cpp`: mutex creation and null-handle behavior.
- `src/led_renderer.cpp`: M370 codec, frame queue, render requests, NeoPixel output, lit-count helper.
- `src/scroll.cpp`: Core-1 scroll/render task, scroll frame advancement, render request consumption.
- `src/faces.cpp`: mode handling, saved-face apply, auto playback, scroll lifecycle, deferred face restore.
- `src/web_api.cpp`: status, power, frame, scroll upload, scroll meta, command, saved-face, static file routes.
- `src/storage.cpp`: settings and saved-face persistence.
- `src/buttons.cpp`: GPIO button dispatch and scroll interruption behavior.
- `src/button_animations.cpp`: overlay state and scroll system-pause coupling.
- `src/power_monitor.cpp`: ADC sampling, global power status, calibration persistence.
- `src/web_json.cpp`: partial raw JSON field extraction used by scroll uploads.
- `data/index.html`: DOM controls, especially debug `data-gpio` buttons and manual command input.
- `data/app.js`: global UI state, API transport, queues, firmware status merge, scroll upload/restore, debug controls.
- `data/styles.css`: UI state classes for progress, matrix, disabled controls, warnings, and loader.

Validation performed:

- `node --check data/app.js`: passed with bundled Node.
- `pio run`: passed with bundled PlatformIO. Reported RAM 17.3% and flash 42.2%.

## A2. Additional Current Behavior Notes

- Firmware startup allocates scroll buffers before mounting LittleFS, then starts the render task after an initial frame render.
- Core 0 owns HTTP, button, power, auto-playback, deferred-restore, and M370 queue service.
- Core 1 owns continuous scroll frame advancement and physical LED rendering.
- `/api/status?since=<version>` returns a short `unchanged:true` response when `stateVersion` matches, even during scroll.
- Core 1 scroll frame advancement updates `scrollFrameIndex` and `framesAccepted`, but does not update `stateVersion`.
- `/api/frame` now validates the M370 payload before stopping scroll/changing playback (A3 applied).
- `/api/scroll` first-chunk uploads clear/stop existing scroll state before all incoming frames are parsed and validated.
- WebUI has three transport styles: direct aux command, queued button command, and queued frame command.
- WebUI scroll restore uses `/api/scroll/meta` and local regeneration, tracked by `pendingScrollMeta`, `lastFwScrollTimelineId`, `lastFwScrollHasSourceText`, and `lastFwScrollFrameCount`.
- Debug buttons with `data-gpio` now bind supported firmware button commands (A10 applied), including B6 short/long battery overlay commands and B6+B3 status/network refresh.
- The debug manual JSON input now posts raw `/api/command` objects with a required string `cmd` field (A11 applied).

## A3. Additional State Model Findings

- `RuntimeState::colorHex` duplicates `colorR/colorG/colorB`; these can diverge if code bypasses color helpers.
- Firmware `mode`, `playback`, `paused`, `restoreAutoAfterScroll`, and WebUI `state.mode`, `state.playback`, `state.textScrollActive`, `scroll.active`, `scroll.paused`, `scroll.firmwareBacked` represent overlapping playback truth.
- `RuntimeState::stateVersion` is a general publish cursor, but not all status-visible state changes touch it.
- `RuntimeState::scrollFrameIndex` is a live runtime cursor that should either have its own version or bypass the `since` short-circuit while active.
- `PowerStatus powerStatus` is globally read/written without a lock; Core 1 overlay rendering reads it while Core 0 updates it.
- WebUI `scroll` object mixes frame cache, firmware mirror, upload progress, command locks, restore metadata, dirty tracking, and UI flags.
- WebUI restore cursors should be grouped as a dedicated scroll-restore model rather than spread across globals.

## A4. Additional Bug List

### Addendum Bug A1: Active scroll polling can return unchanged while frame index changed 🟢 APPLIED

**Severity:** High  
**Type:** state / async / UI sync  
**Location:** `src/scroll.cpp` scroll frame advancement; `src/web_api.cpp` status `since` shortcut  
**Current behavior:** Core 1 advances `scrollFrameIndex` and `framesAccepted` without touching `stateVersion`; `/api/status?since=v` can return `unchanged:true`.  
**Expected behavior:** While firmware scroll is active, status summary polling should return updated scroll frame progress or explicitly exclude it by design.  
**Root cause:** `stateVersion` is not updated by Core-1 scroll ticks.  
**Reproduction path:** Start firmware scroll; repeatedly poll `/api/status?runtimeOnly=1&noFrame=1&since=<current version>`; observe unchanged responses while LEDs advance.  
**Risk if not fixed:** WebUI scroll preview/pause/step state can drift from firmware.  
**Fix strategy:** Low-risk option: bypass the `since == version` unchanged shortcut while `scrolling == true`. More explicit option: add a scroll status cursor updated on frame-index change and include it in the status freshness comparison.  
**Tests required:** API polling test during active scroll; manual WebUI scroll page open while firmware scroll runs.

### Addendum Bug A2: Power status data race between Core 0 and Core 1 overlay 🟢 APPLIED

**Severity:** High  
**Type:** race / firmware  
**Location:** `src/power_monitor.cpp`, `src/button_animations.cpp`  
**Current behavior:** `powerStatus` floats/booleans are written by Core 0 and read by Core 1 overlay rendering without a lock or coherent snapshot.  
**Expected behavior:** Overlay and API should read a coherent power snapshot.  
**Root cause:** No synchronization domain or snapshot helper for power state.  
**Reproduction path:** Hold B6 long overlay while forcing frequent power samples; inspect inconsistent battery/charge values or rare instability.  
**Risk if not fixed:** Torn float reads, inconsistent battery display, rare cross-core instability.  
**Fix strategy:** Add a small `PowerStatusSnapshot` helper guarded by a mutex/critical section. Writers update under the same guard or publish a copied snapshot; readers use copies only.  
**Tests required:** B6 overlay stress test while `servicePowerMonitor(true)` runs frequently.

### Addendum Bug A3: Invalid `/api/frame` can stop scroll before M370 validation 🟢 APPLIED

**Severity:** High  
**Type:** protocol / state  
**Location:** `src/web_api.cpp::handleApiFrame`  
**Current behavior:** Handler can stop firmware scroll and change playback before `applyM370()` validates the submitted frame.  
**Expected behavior:** Invalid frame requests should reject without changing active scroll/playback state.  
**Root cause:** Side effects occur before full payload validation.  
**Reproduction path:** Start scroll, POST `/api/frame` with invalid `m370` and non-scroll mode; response is 400 but scroll may already be stopped.  
**Risk if not fixed:** Malformed client packets can interrupt playback.  
**Fix strategy:** Normalize/decode M370 into a local packed buffer before stopping scroll or mutating playback. Commit state only after validation succeeds.  
**Tests required:** Invalid frame during active scroll leaves scroll active.

### Addendum Bug A4: Failed first scroll upload can destroy existing scroll cache 🟢 APPLIED

**Severity:** High  
**Type:** protocol / edge case  
**Location:** `src/web_api.cpp::handleApiScroll` first-chunk path  
**Current behavior:** `append:false` upload stops firmware scroll and clears metadata before all incoming frames are parsed and validated.  
**Expected behavior:** A bad replacement upload should not destroy a currently running/cached scroll sequence.  
**Root cause:** The handler commits destructive state changes before the incoming upload is proven valid.  
**Reproduction path:** Start scroll A, POST first chunk for scroll B with an invalid M370 frame; firmware stops A and invalidates cache, then returns 400.  
**Risk if not fixed:** One bad upload can wipe active scroll playback.  
**Fix strategy:** Use a two-phase upload path. Validate metadata and all frames in the chunk before clearing existing state. If memory does not allow full staging, at least validate every frame string before writing/committing shared cache metadata.  
**Tests required:** Invalid first chunk while existing scroll runs; existing scroll remains active.

### Addendum Bug A5: Partial JSON scanner accepts ambiguous or invalid JSON forms 🟢 APPLIED

**Severity:** Medium  
**Type:** protocol / edge case  
**Location:** `src/web_json.cpp`, `src/web_api.cpp::handleApiScroll`  
**Current behavior:** Scroll upload parsing scans raw fields manually, accepts unknown string escapes, does not fully validate trailing JSON, and integer parsing can overflow silently.  
**Expected behavior:** Malformed JSON should return 400 before state mutation.  
**Root cause:** Custom partial JSON extraction rather than strict token parsing.  
**Reproduction path:** POST scroll JSON with invalid escapes, trailing garbage, or huge numeric fields.  
**Risk if not fixed:** Protocol ambiguity and possible state corruption on edge-case inputs.  
**Fix strategy:** Keep memory-conscious parsing but reject unknown escapes, validate trailing content, add integer overflow checks, and limit accepted fields to intended top-level keys.  
**Tests required:** Protocol tests for invalid escapes, trailing garbage, huge numbers, and deceptive nested keys.

### Addendum Bug A6: Startup auto mode does not mark startup face as auto playback 🟢 APPLIED

**Severity:** Medium  
**Type:** state / persistence  
**Location:** `src/storage.cpp::loadSavedFaces`, `src/faces.cpp::setMode`  
**Current behavior:** If settings load `mode:auto`, startup face application still sets playback to idle before the first auto interval.  
**Expected behavior:** Persisted auto mode should boot with startup face shown as `auto_saved_face`.  
**Root cause:** `loadSavedFaces(true)` ignores current mode when choosing startup playback label.  
**Reproduction path:** Save auto mode, reboot, read `/api/status`; mode is auto but playback may be idle.  
**Risk if not fixed:** WebUI mode/playback mismatch after boot.  
**Fix strategy:** In startup apply path, set playback from `isAutoMode()` and initialize `lastAutoSwitchMs`.  
**Tests required:** Persistence boot test with auto mode and saved faces.

### Addendum Bug A7: B3 GPIO during active scroll is handled but does nothing 🟢 APPLIED

**Severity:** Medium  
**Type:** UI / firmware / state  
**Location:** `src/buttons.cpp::runButtonAction`  
**Current behavior:** B3 press during active unpaused firmware scroll returns handled immediately, without stopping scroll, toggling mode, or publishing a scroll-stop event.  
**Expected behavior:** Either B3 should be documented/represented as ignored during scroll, or it should interrupt scroll consistently with the WebUI stop-event logic.  
**Root cause:** Early return conflicts with later `isScrollInterruptButton()` handling.  
**Reproduction path:** Start scroll, press GPIO B3, observe scroll continues and no stop event is published.  
**Risk if not fixed:** User and WebUI expectations diverge.  
**Fix strategy:** Decide intended UX. If B3 should interrupt, call `stopFirmwareScroll(...)` and mark stop event. If ignored, remove B3 from interrupt assumptions in firmware/WebUI.  
**Tests required:** Manual B3 active-scroll test and status event sequence check.

### Addendum Bug A8: Status lit count reads current frame without frame lock 🟢 APPLIED

**Severity:** Medium  
**Type:** race / API  
**Location:** `src/led_renderer.cpp::countLitLeds`, `src/web_api.cpp::handleApiStatus`  
**Current behavior:** `countLitLeds()` reads `runtimeFrameBits()` without `frameMutex`.  
**Expected behavior:** API status should count a coherent frame snapshot.  
**Root cause:** Helper has no locking/snapshot contract.  
**Reproduction path:** Poll full status while Core 1 updates frame bits during scroll.  
**Risk if not fixed:** Incorrect lit counts or torn reads.  
**Fix strategy:** Add a locked/snapshot-based lit-count helper and keep expensive frame details skipped during active scroll as today.  
**Tests required:** Concurrent scroll/status stress test.

### Addendum Bug A9: Mutex creation failure leaves firmware running without full locking 🟢 APPLIED

**Severity:** Medium  
**Type:** firmware / race / error handling  
**Location:** `src/main.cpp::setup`, `src/sync.cpp::initSyncPrimitives`  
**Current behavior:** Setup logs mutex creation failure but continues; null mutex handles make lock calls no-ops for that domain.  
**Expected behavior:** Firmware should fail safe or disable dependent services if synchronization primitives are unavailable.  
**Root cause:** `initSyncPrimitives()` result is not enforced.  
**Reproduction path:** Fault-injection build where `xSemaphoreCreateMutex()` fails.  
**Risk if not fixed:** Rare boot heap failure creates unsynchronized runtime.  
**Fix strategy:** Render fatal pattern and avoid starting WebServer/scroll task, or reboot after a delay, when required mutexes fail.  
**Tests required:** Fault-injection build/test.

### Addendum Bug A10: Debug GPIO buttons have no WebUI handler 🟢 APPLIED

**Severity:** Low  
**Type:** UI  
**Location:** `data/index.html` debug `data-gpio` buttons, `data/app.js` debug initialization  
**Current behavior:** Debug GPIO buttons exist in HTML but are never bound in JS.  
**Expected behavior:** Supported debug GPIO buttons should send button commands or be disabled/removed if unsupported.  
**Root cause:** Missing event binding.  
**Reproduction path:** Open debug page and click B1/B2/B3/B4/B5; no command is sent.  
**Risk if not fixed:** Debug tools are misleading.  
**Fix strategy:** Add a debug binding map. B1/B2/B3/B4/B5/B3B1/B3B2 should call `sendButtonCommand`; unsupported B6 variants should be implemented or disabled with clear UI behavior.  
**Tests required:** Browser click test verifies command queue/API call.

### Addendum Bug A11: Manual JSON debug input sends unsupported `manual_json` 🟢 APPLIED

**Severity:** Low  
**Type:** UI / protocol  
**Location:** `data/app.js` debug `serial-send` handler  
**Current behavior:** Placeholder suggests entering `{"cmd":"pause"}`, but handler sends `cmd:"manual_json"` with parsed JSON as payload. Firmware does not support `manual_json`.  
**Expected behavior:** Raw debug JSON should be posted directly to `/api/command`, or the UI should expose structured command fields.  
**Root cause:** Debug helper wraps user input incorrectly.  
**Reproduction path:** Enter `{"cmd":"pause_scroll"}` and send; firmware returns unknown command.  
**Risk if not fixed:** Debug command path is broken.  
**Fix strategy:** Parse raw JSON and POST it directly if it has a `cmd`; otherwise show validation error.  
**Tests required:** Debug command sends `pause_scroll` successfully.

### Addendum Bug A12: Counter-only changes may not publish status changes 🟢 APPLIED

**Severity:** Low  
**Type:** state / API  
**Location:** frame/command rejection and queue counters  
**Current behavior:** Some counter-only changes do not call `touchRuntimeState()`.  
**Expected behavior:** Status consumers using `since` should eventually observe changed stats, or counters should be documented as excluded from versioning.  
**Root cause:** Diagnostic counters are inconsistently included in status versioning.  
**Reproduction path:** Poll status with `since`, send invalid command/frame, poll again.  
**Risk if not fixed:** Debug stats can appear stale.  
**Fix strategy:** Either call `touchRuntimeStateSlow()` for counter-only changes or explicitly exclude counters from `since` freshness semantics.  
**Tests required:** API stats visibility test.

## A5. Additional Refactor Opportunities

- Split `web_api.cpp` by route domain into status, frame, scroll, command, static, and saved-face handlers while preserving routes and JSON fields.
- Create a firmware scroll controller module to own start/stop/pause/resume/step, metadata invalidation, first-frame apply, and restore policy.
- Define typed playback/mode constants in firmware and WebUI while preserving serialized string values.
- Add status snapshot helpers for renderer, scroll, power, and storage before serialization.
- Separate the M370 codec from LED rendering into a pure module.
- Split WebUI `app.js` conceptually into API, state, matrix, faces, scroll, power, debug, and boot units, with bundled output preserved if needed for LittleFS.
- Separate WebUI scroll generation, upload, restore, and control rendering.
- Centralize WebUI transport queues so frames, buttons, and aux commands share consistent rate-limit/error semantics.

## A6. Additional Implementation Order

1. Add baseline tests/protocol notes.
2. Fix active-scroll status freshness.
3. Add coherent power snapshots.
4. Reorder validation before side effects in `/api/frame` (A3).
5. Protect existing scroll cache from failed replacement uploads (A4).
6. Reject invalid/unknown JSON escapes and trailing garbage in raw scroll parsing (A5).
7. Repair debug UI controls.
8. Extract M370/status helpers.
9. Centralize firmware scroll lifecycle.
10. Split WebUI scroll logic only after the scroll regression suite exists.

## A7. Additional Preservation Checklist

- Preserve all public routes and JSON field names.
- Preserve M370 format, bit order, and normalization behavior.
- Preserve scroll upload RAM-only behavior and timeline validation rules.
- Preserve LED timing constants and render task core.
- Preserve GPIO/ADC pins and AP credentials.
- Preserve LittleFS paths and saved-face schema.
- Preserve DOM IDs/classes and existing page structure.
- Preserve default color, brightness, mode, auto interval, and scroll FPS defaults.
- Preserve button repeat/debounce timing.
- Preserve stop-clear/deferred-restore timing.
- Preserve user-visible text unless doing a dedicated copy/encoding cleanup pass.

## A8. Additional Validation Checklist

- Active-scroll `since` polling returns updated scroll status.
- Invalid `/api/frame` during scroll returns 400 and leaves scroll active.
- Invalid replacement `/api/scroll` first chunk leaves existing scroll active.
- B6 overlay remains stable under forced power sampling.
- Full status `lit` count is coherent during frame updates.
- Persisted auto mode boots with `auto_saved_face`.
- B3 active-scroll behavior matches documented expected behavior.
- Debug `data-gpio` buttons send commands.
- Manual JSON debug input sends raw `cmd` payload successfully.
- PlatformIO build and `node --check` pass after each phase.

## A9. Concrete Implementation Snippets

> These are proposed code-change snippets for a later implementation pass.
> They are intentionally included in the plan only; no firmware/WebUI source files are changed by this document update.

### Snippet A1: Bypass `since` short response while firmware scroll is active

Target: `src/web_api.cpp`, inside `handleApiStatus()`.

Current risk: `/api/status?since=<version>` can return `unchanged:true` while `scrollFrameIndex` advances on Core 1.

Planned change:

```cpp
if (hasSince) {
    const uint32_t since = static_cast<uint32_t>(strtoul(server.arg("since").c_str(), nullptr, 10));
    const bool allowUnchangedShortcut = !scrolling;
    if (allowUnchangedShortcut && since == version) {
        DynamicJsonDocument unchanged(192);
        unchanged["ok"]           = true;
        unchanged["v"]            = version;
        unchanged["version"]      = version;
        unchanged["unchanged"]    = true;
        unchanged["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly);
        sendJsonDocument(200, unchanged);
        return;
    }
}
```

Validation:

- Start firmware scroll.
- Poll `/api/status?runtimeOnly=1&noFrame=1&since=<last version>`.
- Confirm response includes updated `renderer.scrollFrameIndex` instead of `unchanged:true`.

### Snippet A2: Validate `/api/frame` M370 before stopping scroll

Target: `src/web_api.cpp`, inside `handleApiFrame()`.

Current risk: applied; retained as implementation reference for A3.

Applied change:

```cpp
String normalizedM370;
if (!normalizeM370(String(m370), normalizedM370, error)) {
    ++runtimeState().framesRejected;
    sendError(400, error);
    return;
}

if (!isScrollPlayback(String(mode))) {
    stopFirmwareScroll(false);
}
if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
    setMode("manual", false);
}
runtimeState().playback = mode;

if (!applyM370(normalizedM370, reason, error)) { sendError(400, error); return; }
```

Implementation note:

- The applied code reuses `applyM370(normalizedM370, ...)`, so `lastM370` preservation stays identical to the normal frame path.

Validation:

- Start scroll.
- POST invalid M370 to `/api/frame`.
- Confirm HTTP 400 and scroll remains active.
- POST valid M370 and confirm previous behavior is preserved.

### Snippet A3: Add locked power snapshot helper

Target: `src/power_monitor.h` / `src/power_monitor.cpp`.

Current risk: Core 1 overlay reads `powerStatus` while Core 0 updates it.

Planned API:

```cpp
struct PowerStatusSnapshot {
    float    vbat;
    float    vcharge;
    uint8_t  batteryPercent;
    bool     charging;
    bool     batteryValid;
    bool     chargeValid;
    bool     batteryDisconnected;
    bool     batteryLowVoltageUnpowered;
};

PowerStatusSnapshot powerStatusSnapshot();
```

Planned implementation shape:

```cpp
static portMUX_TYPE sPowerStatusMux = portMUX_INITIALIZER_UNLOCKED;

PowerStatusSnapshot powerStatusSnapshot() {
    PowerStatusSnapshot snapshot;
    portENTER_CRITICAL(&sPowerStatusMux);
    snapshot.vbat                         = powerStatus.vbat;
    snapshot.vcharge                      = powerStatus.vcharge;
    snapshot.batteryPercent               = powerStatus.batteryPercent;
    snapshot.charging                     = powerStatus.charging;
    snapshot.batteryValid                 = powerStatus.batteryValid;
    snapshot.chargeValid                  = powerStatus.chargeValid;
    snapshot.batteryDisconnected          = powerStatus.batteryDisconnected;
    snapshot.batteryLowVoltageUnpowered   = powerStatus.batteryLowVoltageUnpowered;
    portEXIT_CRITICAL(&sPowerStatusMux);
    return snapshot;
}
```

Writer-side planned pattern:

```cpp
portENTER_CRITICAL(&sPowerStatusMux);
powerStatus.vbat = nextVbat;
powerStatus.batteryPercent = nextPercent;
powerStatus.batteryValid = true;
powerStatus.lastBatteryMs = now;
portEXIT_CRITICAL(&sPowerStatusMux);
```

Validation:

- Render B6 battery overlay while forcing frequent power sampling.
- Confirm no inconsistent charge/battery combination appears.

### Snippet A4: Use power snapshot in button overlay rendering

Target: `src/button_animations.cpp`, inside battery overlay drawing.

Current risk: overlay reads global `powerStatus` directly.

Planned change:

```cpp
void drawBatteryPage(uint8_t* out, const AnimationState& state, uint32_t now) {
    clearOverlay(out);

    const PowerStatusSnapshot power = powerStatusSnapshot();
    const bool batteryValid = power.batteryValid;
    const bool chargeValid = power.chargeValid;
    const uint8_t pct = batteryValid ? power.batteryPercent : 0;
    const bool charging = chargeValid && power.charging;
    const Rgb iconColor = batteryValid ? batteryColor(pct) : RED_COLOR;
    const bool animate = !state.batterySingleShot && charging;
    const uint32_t phaseMs = now - state.batteryDisplayStartedMs;

    drawBatteryIcon(out, iconColor, pct, animate, phaseMs);
    // Existing text formatting logic continues using `power.vbat` and `power.vcharge`.
}
```

Validation:

- B6 short press shows battery percent.
- B6 long press cycles percent/battery voltage/charge voltage without scroll desync.

### Snippet A5: Locked lit-count helper

Target: `src/led_renderer.cpp` / `src/led_renderer.h`.

Current risk: `countLitLeds()` reads `runtimeFrameBits()` without `frameMutex`.

Planned helper:

```cpp
uint16_t countLitLedsLocked() {
    uint8_t snapshot[FRAME_BYTES];
    withFrameLock([&]() {
        memcpy(snapshot, runtimeFrameBits(), FRAME_BYTES);
    });

    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) {
        uint8_t value = snapshot[byteIndex];
        const uint16_t firstBit = static_cast<uint16_t>(byteIndex) << 3;
        if (firstBit + 8U > LED_COUNT) {
            const uint8_t validBits = static_cast<uint8_t>(LED_COUNT - firstBit);
            value &= static_cast<uint8_t>((1U << validBits) - 1U);
        }
        lit += static_cast<uint16_t>(__builtin_popcount(value));
    }
    return lit;
}
```

Planned status use:

```cpp
if (!scrolling && !summaryOnly) {
    renderer["lastM370"] = runtimeState().lastM370;
    renderer["lit"]      = countLitLedsLocked();
}
```

Validation:

- Poll full status during frame updates.
- Confirm `lit` remains plausible and no race-sensitive behavior appears.

### Snippet A6: Make mutex init failure fail safe

Target: `src/main.cpp`, immediately after `initSyncPrimitives()`.

Current risk: firmware can continue with missing locks.

Planned change:

```cpp
if (!initSyncPrimitives()) {
    Serial.println("Fatal: failed to create one or more FreeRTOS mutexes");
    pinMode(LED_PIN, OUTPUT);
    for (;;) {
        digitalWrite(LED_PIN, LOW);
        delay(250);
        digitalWrite(LED_PIN, HIGH);
        delay(250);
    }
}
```

Implementation note:

- A nicer later version can render a specific NeoPixel fatal pattern if the hardware bus mutex exists. The initial fail-safe should avoid depending on locks that may not exist.

Validation:

- Fault-injection build forces `initSyncPrimitives()` false.
- Firmware does not start WebServer or render task.

### Snippet A7: Bind debug `data-gpio` buttons in WebUI

Target: `data/app.js`, inside `initializeDebugControls()`.

Current risk: applied; retained as implementation reference for A10.

Applied change:

```js
document.querySelectorAll("[data-gpio]").forEach((button) => {
  button.addEventListener("click", () => {
    const code = String(button.dataset.gpio || "").toUpperCase();
    if (["B1", "B2", "B3", "B4", "B5", "B3B1", "B3B2"].includes(code)) {
      sendButtonCommand(code, `debug_gpio_${code}`);
      return;
    }
    log(`Unsupported debug GPIO simulation: ${code}`);
  });
});
```

Validation:

- Click B1/B2/B3/B4/B5/B3B1/B3B2 on debug page.
- Confirm `/api/command` receives `cmd:"button"` with the expected payload.

### Snippet A8: Send raw manual debug JSON directly

Target: `data/app.js`, `serial-send` debug handler.

Current risk: applied; retained as implementation reference for A11.

Applied change:

```js
[
  "serial-send",
  () => {
    const raw = $("serial-input")?.value || "{}";
    try {
      const packet = JSON.parse(raw);
      if (!packet || typeof packet !== "object" || typeof packet.cmd !== "string") {
        throw new Error("Command JSON must be an object with a string cmd field");
      }
      apiPost(API_ENDPOINTS.command, packet)
        .then((data) => applyFirmwareRuntimeState(data, "debug_manual_json"))
        .catch((err) => {
          setFirmwareStatus({
            lastStatus: "manual command failed",
            lastError: err.message,
          });
          log(`manual command failed: ${err.message}`);
        });
    } catch (err) {
      alert(`JSON format error: ${err.message}`);
    }
  },
]
```

Validation:

- Enter `{"cmd":"pause_scroll"}`.
- Confirm firmware command is accepted or returns a meaningful command-specific error.

### Snippet A9: Preserve existing scroll until replacement upload validates

Target: `src/web_api.cpp`, `handleApiScroll()`.

Current risk: first replacement chunk clears active scroll before validation finishes.

Planned shape:

```cpp
struct ParsedScrollFrame {
    uint16_t index;
    uint8_t bits[FRAME_BYTES];
};

ParsedScrollFrame parsedFrames[MAX_SAFE_CHUNK_FRAMES];
uint16_t parsedCount = 0;

// Parse and validate all incoming frames into parsedFrames first.
// Do not call stopFirmwareScroll(false) or clearScrollTimelineMetaLocked() yet.
while (pos < body.length()) {
    // Existing frame-string extraction stays here.
    if (!m370ToPackedBits(m370, parsedFrames[parsedCount].bits, error)) {
        sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
        return;
    }
    parsedFrames[parsedCount].index = static_cast<uint16_t>(targetIndex);
    ++parsedCount;
}

// Only after validation succeeds, commit destructive state changes.
if (!appendFrames) {
    stopFirmwareScroll(false);
    withScrollLock([&]() {
        runtimeState().scrollFrameCount = 0;
        runtimeState().scrollFrameIndex = 0;
        clearScrollTimelineMetaLocked();
        // Reapply validated metadata here.
    });
}

withScrollLock([&]() {
    for (uint16_t i = 0; i < parsedCount; ++i) {
        memcpy(runtimeScrollFrameBits(parsedFrames[i].index), parsedFrames[i].bits, FRAME_BYTES);
    }
    runtimeState().scrollFrameCount = baseIndex + parsedCount;
});
```

Implementation note:

- If stack size is a concern, allocate the staging array from PSRAM/internal heap and cap it by chunk size. The key requirement is validation before destructive commit.

Validation:

- Start scroll A.
- Send invalid first chunk for scroll B.
- Confirm scroll A remains active and cached.

### Snippet A10: Startup face playback should respect persisted auto mode

Target: `src/storage.cpp`, startup face apply block in `loadSavedFaces(true)`.

Current risk: persisted auto mode boots with `playback` set to idle.

Planned change:

```cpp
if (applyStartupFace) {
    String error;
    const bool autoMode = isAutoMode();
    runtimeState().brightness = DEFAULT_BRIGHTNESS;
    runtimeState().playback   = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    runtimeState().paused     = false;
    if (autoMode) runtimeState().lastAutoSwitchMs = millis();

    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
        Serial.printf("startup M370 failed: %s\n", error.c_str());
        return false;
    }
}
```

Validation:

- Persist `mode:auto`.
- Reboot.
- Confirm `/api/status` reports `mode:auto` and `playback:auto_saved_face`.

### Snippet A11: Strict unknown escape rejection in JSON string extraction

Target: `src/web_json.cpp::extractJsonStringAt`.

Current risk: unknown JSON escapes are accepted as literal characters.

Planned change:

```cpp
switch (c) {
    case '"': value += '"'; break;
    case '\\': value += '\\'; break;
    case '/': value += '/'; break;
    case 'b': value += '\b'; break;
    case 'f': value += '\f'; break;
    case 'n': value += '\n'; break;
    case 'r': value += '\r'; break;
    case 't': value += '\t'; break;
    case 'u':
        // Existing unicode handling remains here.
        break;
    default:
        return false;
}
```

Validation:

- POST scroll JSON containing `"sourceText":"bad\\xescape"`.
- Confirm 400 response and no scroll state mutation.

## A10. Consolidated Workstreams

> This section organizes related findings, snippets, validation steps, and refactor targets together.
> It does not replace the detailed bug/refactor/phase sections above; it is an implementation-oriented map for a later coding pass.

### Workstream 1: Firmware status freshness and state publishing

Related findings:

- Addendum Bug A1: active scroll polling can return `unchanged:true` while `scrollFrameIndex` changed.
- Addendum Bug A12: counter-only changes may not publish status changes.
- Existing plan items that discuss `stateVersion`, `since`, status snapshots, slow UI publishing, and status response cadence.

Relevant files:

- `src/state.h`
- `src/state.cpp`
- `src/scroll.cpp`
- `src/web_api.cpp`
- `data/app.js`

Concrete snippets:

- Snippet A1: bypass `since` short response while firmware scroll is active.

Implementation order:

1. Add a status polling regression test for active scroll.
2. Apply Snippet A1 or introduce a dedicated scroll-status cursor.
3. Decide whether diagnostic counters are included in `stateVersion` or documented as best-effort.
4. Add snapshot helpers before broader status refactoring.

Validation:

- Start firmware scroll and poll `/api/status?runtimeOnly=1&noFrame=1&since=<last version>`.
- Confirm `renderer.scrollFrameIndex` updates.
- Send invalid frame/command and confirm stats are visible according to the chosen counter policy.

Preserve:

- Existing JSON field names.
- `unchanged:true` response shape when no scroll/progress-sensitive state changed.
- `next_poll_ms` behavior.

### Workstream 2: Cross-core safety for frame and power reads

Related findings:

- Addendum Bug A2: power status data race between Core 0 and Core 1 overlay.
- Addendum Bug A8: status lit count reads current frame without frame lock.
- Existing bug/refactor items around overlay power reads, status snapshots, and lock fail-safe behavior.

Relevant files:

- `src/power_monitor.h`
- `src/power_monitor.cpp`
- `src/button_animations.cpp`
- `src/led_renderer.h`
- `src/led_renderer.cpp`
- `src/web_api.cpp`
- `src/sync.cpp`

Concrete snippets:

- Snippet A3: add locked power snapshot helper.
- Snippet A4: use power snapshot in button overlay rendering.
- Snippet A5: locked lit-count helper.
- Snippet A6: make mutex init failure fail safe.

Implementation order:

1. Add `PowerStatusSnapshot` and snapshot reader.
2. Replace overlay direct `powerStatus` reads with the snapshot.
3. Replace API direct lit-count path with a locked/snapshot helper.
4. Harden mutex creation failure after the above behavior is tested.

Validation:

- Hold B6 battery overlay while power sampling runs.
- Poll full status while frames update.
- Fault-injection build for `initSyncPrimitives()` failure.

Preserve:

- ADC thresholds and calibration math.
- LED timing and render task cadence.
- Existing power JSON field names.

### Workstream 3: Scroll upload, metadata, and cache commit safety

Related findings:

- Addendum Bug A4: failed first scroll upload can destroy existing scroll cache.
- Addendum Bug A5: partial JSON scanner accepts ambiguous or invalid JSON forms.
- Existing scroll upload invariants EH-A/EH-B/EH-C and D/E/H notes.
- Refactor opportunity: centralize firmware scroll controller.

Relevant files:

- `src/web_api.cpp`
- `src/web_json.cpp`
- `src/state.cpp`
- `src/state.h`
- `src/faces.cpp`
- `src/scroll.cpp`
- `data/app.js`

Concrete snippets:

- Snippet A9: preserve existing scroll until replacement upload validates.
- Snippet A11: strict unknown escape rejection in JSON string extraction.

Implementation order:

1. Add protocol tests for invalid frame strings, invalid escapes, huge numbers, out-of-order chunks, and trailing garbage.
2. Make JSON string extraction reject unknown escapes.
3. Reorder `/api/scroll` first-chunk handling into validate-then-commit.
4. Only after behavior is protected, move lifecycle logic into a scroll controller module.

Validation:

- Start scroll A, send invalid first chunk for scroll B, confirm scroll A remains active.
- Send valid chunked upload and confirm timeline metadata, frame count, and start behavior remain unchanged.
- Confirm `/api/scroll/meta` still returns source text and frame metadata after valid upload.

Preserve:

- RAM-only scroll behavior.
- Timeline ID format and validation.
- `sourceText` all-or-nothing metadata requirements.
- Existing start-scroll 409 behavior.

### Workstream 4: Frame command validation and M370 codec boundaries

Related findings:

- Addendum Bug A3: invalid `/api/frame` can stop scroll before M370 validation. 🟢 APPLIED
- Existing refactor opportunity to separate M370 codec from LED renderer.
- Existing behavior preservation requirement for M370 format and bit order.

Relevant files:

- `src/led_renderer.h`
- `src/led_renderer.cpp`
- `src/web_api.cpp`
- future `src/m370_codec.h`
- future `src/m370_codec.cpp`

Concrete snippets:

- Snippet A2: validate `/api/frame` M370 before stopping scroll.

Implementation order:

1. Add M370 unit tests for valid, invalid, lowercase, whitespace, and prefix/no-prefix forms.
2. Extract pure M370 codec helpers.
3. Reorder `/api/frame` to validate before side effects.
4. Add a helper that can apply packed bits while preserving normalized `lastM370`.

Validation:

- Invalid `/api/frame` during scroll leaves scroll active.
- Valid `/api/frame` still updates LEDs, `lastM370`, `lastReason`, counters, and status.
- Known M370 patterns roundtrip unchanged.

Preserve:

- `M370:` + 93 hex normalized format.
- Logical row-major bit order.
- Existing error messages unless tests are updated explicitly.

### Workstream 5: Startup mode, saved faces, and persistence consistency

Related findings:

- Addendum Bug A6: startup auto mode does not mark startup face as auto playback.
- Existing saved-face validation, settings repair, default brightness/default face startup findings.
- Persistence behavior around `runtime_settings.json`, `saved_faces.json`, and battery calibration.

Relevant files:

- `src/storage.cpp`
- `src/faces.cpp`
- `src/state.h`
- `data/app.js`
- `data/resources/saved_faces.json`
- `data/resources/runtime_settings.json`

Concrete snippets:

- Snippet A10: startup face playback should respect persisted auto mode.

Implementation order:

1. Add boot/persistence test notes for manual mode and auto mode.
2. Apply startup playback fix.
3. Confirm `lastAutoSwitchMs` is initialized when booting into auto mode.
4. Keep saved-face sort/default selection behavior unchanged.

Validation:

- Persist `mode:auto`, reboot, confirm status reports `mode:auto` and `playback:auto_saved_face`.
- Persist `mode:manual`, reboot, confirm existing manual startup behavior.
- Reload saved faces and confirm selected/default face remains stable.

Preserve:

- Saved-face schema.
- Startup default selection priority.
- Atomic settings/saved-face writes.

### Workstream 6: GPIO, debug controls, and manual command tooling

Related findings:

- Addendum Bug A7: B3 GPIO during active scroll is handled but does nothing.
- Addendum Bug A10: debug GPIO buttons have no WebUI handler. 🟢 APPLIED
- Addendum Bug A11: manual JSON debug input sends unsupported `manual_json`. 🟢 APPLIED
- Existing button behavior preservation requirements.

Relevant files:

- `src/buttons.cpp`
- `src/faces.cpp`
- `data/index.html`
- `data/app.js`

Concrete snippets:

- Snippet A7: bind debug `data-gpio` buttons in WebUI.
- Snippet A8: send raw manual debug JSON directly.

Implementation order:

1. Decide intended B3 behavior during active scroll.
2. Update firmware/WebUI assumptions consistently for B3.
3. Bind supported debug GPIO buttons. 🟢 APPLIED
4. Replace `manual_json` wrapping with direct raw command POST. 🟢 APPLIED
5. Disable or implement unsupported B6 debug variants.

Validation:

- Press real GPIO B1/B2/B3 during scroll and confirm documented behavior.
- Click debug B1/B2/B3/B4/B5/B3B1/B3B2 and confirm command payloads.
- Enter `{"cmd":"pause_scroll"}` in debug input and confirm firmware receives that command directly.

Preserve:

- GPIO debounce/repeat timings.
- Existing B1/B2/B3/B4/B5 production behavior unless explicitly fixing B3 active-scroll semantics.
- DOM `data-gpio` values.

### Workstream 7: WebUI transport and scroll-state structure

Related findings:

- WebUI has direct aux commands, queued button commands, and queued frame commands with different behavior.
- WebUI `scroll` state mixes model, firmware mirror, cache, progress, locks, and restore metadata.
- Addendum refactor opportunities A6 and A7.

Relevant files:

- `data/app.js`
- `data/index.html`
- `scripts/gzip_webui_assets.py`

Concrete snippets:

- Snippet A7 and A8 apply to debug transport.
- Scroll upload snippets A9/A11 inform frontend protocol tests but are firmware-side changes.

Implementation order:

1. Add browser smoke tests for transport and scroll controls.
2. Extract an API client/transport queue helper.
3. Split scroll logic into generator, uploader, restorer, and view/controller sections.
4. Preserve generated/bundled output behavior for LittleFS.

Validation:

- Node syntax check.
- Browser smoke test.
- Frame queue saturation test.
- Button command queue saturation test.
- Scroll upload/restore test.

Preserve:

- Endpoint paths.
- DOM IDs/classes.
- Upload chunk sizing and progress semantics unless separately changed.

### Workstream 8: Module extraction and long-term architecture

Related findings:

- `web_api.cpp` is too broad.
- `led_renderer.cpp` mixes codec, queueing, state mutation, and physical output.
- `faces.cpp` owns both face playback and scroll lifecycle.
- `app.js` is a monolithic frontend runtime.

Relevant files:

- `src/web_api.cpp`
- `src/led_renderer.cpp`
- `src/faces.cpp`
- `src/scroll.cpp`
- `data/app.js`

Concrete snippets:

- Snippets A1-A11 show target behavior for the most important seams before extraction.

Implementation order:

1. Extract pure M370 codec.
2. Extract status snapshots.
3. Split Web API route domains.
4. Create firmware scroll controller.
5. Split WebUI scroll modules.
6. Clean comments/encoding after behavior tests are stable.

Validation:

- `pio run`.
- `node --check data/app.js`.
- API contract tests.
- Manual hardware smoke test.

Preserve:

- Public APIs and protocol formats.
- Hardware timing.
- User-visible behavior unless a bug fix explicitly changes it.

---

## 14. Final recommendation

**Reconsidered verdict:** use this plan only after consolidation. The audit depth and test strategy are strong, but the addendum changes the priority order: destructive-state bugs and live status freshness now outrank broad refactors and the older low-risk-first list.

**Already shipped:** Bug 15 was already applied; see `data/app.js::updateButtonState` and `updateScrollUi` for the scroll-button `disabled`/`aria-disabled` evidence. Since this reconsideration pass, Bugs 2/4/5/6/9/10/11/13/14 and Addendum A1/A2/A3/A4/A5/A8/A10/A11 are also applied in the codebase. Treat them as closed unless validation finds a regression.

**Open bugs to fix first:** No correctness bug from the verified list remains open after this pass. Bug 3 is the remaining hardware-gated timing/perf item: keep it as a validation checkpoint and do not apply/reapply lock-topology changes without board-level proof.

**Refactors to delay until after those fixes:** `handleApiScroll` extraction, command reply extraction, `applyFirmwareRuntimeState` decomposition, storage helper extraction, and WebUI scroll-boolean reduction. Extraction is still valuable, but validate-before-mutate ordering should be correct before helpers make the existing behavior look cleaner than it is.

**Timing/perf changes:** hot-path log gating is applied. Bug 3 file-I/O/LED lock reassignment remains hardware-gated in this plan; LittleFS/LED lock topology must stay behind explicit hardware validation and rollback notes.

**Safest remaining implementation order:** verified correctness bug queue complete; next work should be deliberate refactors only, plus Bug 3 hardware validation if timing/perf work resumes.


## 6. Scroll Session Refactor

The scroll-session work is the active canonical plan for making scroll editing predictable across firmware, WebUI, hardware buttons, battery overlay behavior, and automated tests.

### Latest Step-Direction Decision

Step arrows are visual text movement controls, not numeric cursor controls. Right moves the whole rendered text right by one visual frame, and left moves the whole rendered text left by one visual frame. Because the scroll renderer maps frame index to source bitmap offset, that means right decrements the frame index and left increments it. This is intentionally documented strongly in code and test plans so it is not rediscovered as an apparent sign bug later.

### Scroll Session Refactor Plan

_Source: `SCROLL_SESSION_REFACTOR_PLAN.md`_

> Status: IMPLEMENTED (phases 1A-4) + audit fixes applied. See "Implementation status" below.
> Owner: TBD | Date: 2026-06-18
> Scope: Extract the text-scroll state machine into a dedicated module on both sides -- firmware `scroll_session.{h,cpp}` (split out of `faces.cpp`) and a browser scroll-machine module (inline in `data/app.js`). Behavior-preserving refactor that also makes the later preview-vs-LED anti-drift fix a one-line change.
> Non-goals: No new user-facing features. No protocol/wire changes to `/api/scroll`, `/api/scroll/meta`, `/api/command`, or `/api/status`. No bundler/ES-module adoption.
>
> Note: this document is intentionally ASCII-only (no Unicode arrows, section signs, set symbols, or emoji) so it renders identically in every editor and can serve as the review contract.

---

## 0. Implementation status (reconciled 2026-06-18)

This document was originally written as a forward-looking draft ("no code moved yet").
The work is now implemented in the tree and this section reconciles the plan with the
shipped code. See `SCROLL_SESSION_REFACTOR_AUDIT.md` for the full audit.

Implemented:
- Firmware phases 1A + 1B + 1C + 2 in `src/scroll_session.{h,cpp}`; `faces.cpp`, `faces.h`,
  `scroll.cpp`, `scroll.h`, `buttons.cpp`, `button_animations.cpp`, `web_api.cpp` rewired.
- Browser phases 3 + 4: the `scrollMachine` IIFE in `data/app.js` (epoch + per-domain
  tokens, composable `pauseReasons`, FW_SYNC-authoritative cursor, `cache.identityBound`).
- Phase 5 (delete dead `scroll{}` fields/globals) is NOT done yet and remains future work.

Signature deltas (the shipped signatures are authoritative; the sketches in sec 4.1/13 are
historical):
- `scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) -> ScrollStartResult`
  (not the `ScrollStartContext` struct sketch).
- `scrollSessionStop(bool restoreAuto, bool clearDisplay) -> ScrollStopResult`.
- `scrollSessionCommitUpload(const ScrollUploadTxn&, uint16_t count, bool hasExplicitTiming, uint16_t intervalMs) -> ScrollUploadResult`.
- `scrollSessionBeginAppend()` exists in addition to `scrollSessionBeginUpload(meta)`.
- New: `scrollSessionStep(int8_t direction, uint8_t* outFrameBits) -> bool` (manual step;
  not in the original sec 13.1 "what moves" table). It latches an effective pause so the
  Core-1 render task holds on the stepped frame.

Audit fixes applied on top of the refactor (see audit doc, "Required Corrections"):
1. Anti-drift: the browser local `advanceScroll` timer is now a display-only tween
   (`scroll.displayIndex`) that never writes the canonical `scroll.frameIndex` while
   `device.hasSession`; FW_SYNC is the sole canonical-cursor writer (sec 7 now true).
2. `scrollSessionStep` latches `firmwareScroll*Paused` so a step holds its frame; the
   WebUI step handler mirrors this (PAUSE_USER + stop local timer).
4. FW_SYNC pause mirroring is routed through `PAUSE_USER/RESUME_USER/PAUSE_SYSTEM/RESUME_SYSTEM`
   dispatch events (single mutation path; the `*_SYSTEM` events are no longer dead).
5. The browser reducer now enforces an `ALLOWED_FROM` source-phase guard table (sec 5.2
   is now enforced, not just documented).
6. `scrollSessionMarkStoppedByButton` is documented as intentionally lockless (Core-0-only
   stop-event fields; locking it would reintroduce a String-under-lock violation).

Note: all `app.js:NNNN` / `faces.cpp:NNNN` line references below point at the PRE-refactor
baseline and are retained for historical context only; they no longer match current files.

---

## 1. Why

The scroll subsystem is the highest-risk area in the codebase (see `ARCHITECTURE_REPORT.md` sec 13). Its state is implicit:

- Browser: `scroll{}` carries ~30 fields (`data/app.js:3565`) plus module globals (`pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, `data/app.js:3609`). "What state are we in" is inferred by reading combinations of booleans, and the same combinations are re-derived in `startScroll`, `pauseScroll`, `resumeScroll`, `stopScroll`, `togglePauseScroll`, `restoreScrollTextFromFirmware`, `restoreScrollPreviewIfNeeded`, and `applyFirmwareRuntimeState`.
- Firmware: the scroll FSM is interleaved with mode/auto-playback/face logic in `faces.cpp` (`startFirmwareScroll:352`, `stopFirmwareScroll:331`, `setFirmwareScrollPauseFlag:290`, `recomputeEffectivePauseLocked:281`, `resetFirmwareScrollStateLocked`, deferred-restore machinery), while `/api/scroll` mutates scroll state directly in `web_api.cpp` (`:817`, `:936`), `set_scroll_interval` writes `scrollIntervalMs`/`lastScrollFrameMs` (`web_api.cpp:1120`), buttons write `scrollStopEvent*` (`buttons.cpp:67`), `get/setRestoreAutoAfterScroll` live in `scroll.cpp`, and the Core-1 render task mutates the playback cursor (`scroll.cpp:42`).

Goal: one explicit state machine per side, with a single transition path, so pause/step/restore/upload races are reasoned about in one place.

### 1.1 Goals
1. Single transition function per side; explicit, named states.
2. One ownership boundary for firmware scroll-state writes (control plane + interval + stop-event + restore-auto + upload plane + render-plane cursor).
3. Preserve the composable pause semantics (user AND/OR system paused).
4. Preserve async-race protection via per-domain operation tokens plus cross-domain cancellation.
5. Make FW_SYNC-authoritative preview index a reducer policy (kills drift; see sec 7).
6. Invert the scroll -> face dependency so there is no circular ownership.

### 1.2 Non-goals
- No change to the wire protocol or JSON shapes.
- No new file served by the ESP unless it earns its keep (default: inline, see sec 6).
- No behavior change in phases 1-3 (strangler pattern). The one intentional behavior change (FW_SYNC authority over the preview cursor) lands in phase 4.

---

## 2. Reviewer-driven design corrections (baked in)

### 2.1 Round-1 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | Pause states are composable, not exclusive | `ACTIVE` state + `pauseReasons: Set<"user"\|"system">`; `isPlaying = ACTIVE && pauseReasons empty` (sec 5.1) |
| P1 | Firmware boundary must include upload/cache mutations | Upload transaction API in `scroll_session` (sec 4.1) |
| P1 | Core-1 render also mutates scroll state | Render-plane `scrollSessionTickCursorLocked()` under the lock the task already holds (sec 4.2) |
| P1 | Single `busy` flag hides concurrent flows | Per-domain generation tokens; `busy` is UI-affordance only (sec 5.3) |
| P2 | No bundler / file:// / single-threaded server | Scroll machine ships inline in `app.js` as an IIFE; no ES modules (sec 6) |
| P2 | Circular ownership with default-face restore | `scrollSessionStop()` returns a result struct; `faces.cpp` performs face restore (sec 4.3) |

### 2.2 Round-2 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | `UPLOAD_DONE -> ACTIVE` marks playback active before `start_scroll` is confirmed | Split into `UPLOAD_COMMIT_DONE` (frames committed, not playing) -> `STARTING`, then `START_CONFIRMED` -> `ACTIVE` (sec 5.2) |
| P1 | Upload must keep partial frames invisible | Explicit invariant: count/`framesReceived`/`uploadComplete` never expose a chunk until fully written; `scrollSessionWriteFrame` rejects writes into visible indexes unless stopped/invalidated first (sec 4.1) |
| P1 | `firmwareBacked` derived from the UI enum is too coarse | Replace with explicit `device.hasSession` and `cache.identityBound` (sec 5.1) |
| P2 | Transition table too restrictive for replacement flows | `GENERATE`/`RESTORE_BEGIN` allowed from any non-busy state with explicit cleanup effects (sec 5.2) |
| P2 | One generic snapshot risks huge/stack source-text copies | Two APIs: small-scalar `scrollSessionSnapshot()` for `/api/status`; `scrollSessionCopyMeta(textBuf, cap)` for `/api/scroll/meta` (sec 4.1) |
| P2 | Phase 1 bundles three risky moves | Split into 1A start/stop/pause/step, 1B upload/cache txn, 1C render cursor tick (sec 8) |

### 2.3 Round-3 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | Ownership rule needs more APIs: `set_scroll_interval`, `scrollStopEvent*`, `restoreAutoAfterScroll` also write scroll fields | Add `scrollSessionSetInterval`, `scrollSessionMarkStoppedByButton`, `scrollSessionGet/SetRestoreAuto` to the public surface (sec 4.1) |
| P1 | `scrollSessionStart(uint16_t)` under-specified: start captures auto-mode restore intent and flips mode/playback | Context-in / result-out: `scrollSessionStart(ScrollStartContext)` -> `ScrollStartResult`; `faces.cpp` owns mode/playback String writes (sec 4.1, 4.5) |
| P1 | First-chunk upload must preserve preflight: validate-then-clear, or a malformed first chunk erases a working timeline | Frame validation stays in the transport layer and completes before `scrollSessionBeginUpload` clears anything (sec 4.1, 4.4) |
| P1 | "Transaction" lifetime unclear | `ScrollUploadTxn` is a stack-local per-request context derived from a locked meta snapshot; never persisted across HTTP requests (sec 4.4) |
| P1 | STOP/GENERATE/RESTORE must cancel other async domains, not just their own token | Cross-domain cancellation via a monotonic `epoch`; replacement events bump it and stale replies from any domain are dropped (sec 5.3) |
| P1 | `cache.identityBound` must include timeline binding, not just generator + frame count | Formula includes `framesTimelineId === fw.scrollTimelineId` (the `localTimelineMatchesMeta` check at `app.js:8897`) (sec 5.1) |
| P2 | "Reference only" is a user-facing behavior; conflicts with "no behavior change" if introduced early | The warning already exists today; only its rewiring through `cache.identityBound` lands in phase 4. Clarified in sec 5.1 / sec 8 |
| P2 | Plan file had mojibake / broken arrows | Rewritten ASCII-only (this revision) |

---

## 3. Target architecture

```
Firmware (Core 0 control + Core 1 render)
  web_api.cpp  --(transport: parse + validate)-->  scroll_session.cpp
  buttons.cpp  -------------------------------->   (owns ALL RuntimeState scroll-field writes)
  faces.cpp    --(start/stop/pause/step)------->         |
       ^  (start/stop result: mode + restore intent) ----+
  scroll.cpp (Core 1) --(tick cursor, lock held)-->  scrollSessionTickCursorLocked()

Browser (data/app.js)
  UI handlers ----> scrollMachine.dispatch(event, payload, token)
  pollers/restore-> dispatch(FW_SYNC | UPLOAD_COMMIT_DONE | RESTORE_DONE, ..., token)
  scrollMachine ---> renderMatrices / updateScrollUi (read-only consumers)
```

Dependency edges are one-directional: `faces.cpp -> scroll_session` (never back); `web_api.cpp -> scroll_session`; `buttons.cpp -> scroll_session`; `scroll.cpp -> scroll_session` (render-plane only).

---

## 4. Firmware: `scroll_session.{h,cpp}`

`RuntimeState` scroll fields stay in `state.h` (shared with the render task), but only `scroll_session.cpp` may write them. All control-plane functions take `withScrollLock` internally; the render-plane function is the documented exception (called with the lock already held).

### 4.1 Public surface

```cpp
// --- control plane (Core 0: HTTP handlers, buttons, faces) ---
ScrollStartResult   scrollSessionStart(const ScrollStartContext& ctx);  // intent in, result out; no face/mode/String writes here
ScrollStopResult    scrollSessionStop(bool restoreAuto, bool clearDisplay);
bool                scrollSessionSetUserPaused(bool paused);
bool                scrollSessionSetSystemPaused(bool paused);          // battery overlay
bool                scrollSessionStep(int8_t direction);
void                scrollSessionSetInterval(uint16_t intervalMs);      // set_scroll_interval: writes scrollIntervalMs + lastScrollFrameMs (was web_api.cpp:1120)
void                scrollSessionMarkStoppedByButton(const char* button, const char* source); // owns scrollStopEvent* (was buttons.cpp:67)
bool                scrollSessionGetRestoreAuto();                      // was get/setRestoreAutoAfterScroll in scroll.cpp
void                scrollSessionSetRestoreAuto(bool value);

// --- read plane: two distinct contracts (do NOT merge) ---
ScrollSessionSnapshot scrollSessionSnapshot();                         // small scalars only; for /api/status (tear-free)
bool                scrollSessionCopyMeta(ScrollMetaOut&, char* textBuf, size_t cap); // timeline meta + optional source-text copy; for /api/scroll/meta

// --- upload plane (Core 0: /api/scroll) ---
ScrollUploadTxn     scrollSessionBeginUpload(const ScrollUploadMeta& meta); // first chunk; clears+sets meta under lock AFTER caller preflight
bool                scrollSessionWriteFrame(ScrollUploadTxn&, uint16_t index, const uint8_t* packedBits);
bool                scrollSessionAppendChunk(ScrollUploadTxn&, uint16_t chunkIndex /*, ... */);
ScrollUploadResult  scrollSessionCommitUpload(ScrollUploadTxn&);       // publishes count/framesReceived/uploadComplete under lock
void                scrollSessionInvalidateCache();                    // EH-A: drop frames, keep sourceText
void                scrollSessionClearTimeline();                      // full clear incl. sourceText

// --- render plane (Core 1: scrollRenderTask, lock already held) ---
bool                scrollSessionTickCursorLocked(uint32_t now, uint8_t* outFrameBits);
```

Types:

```cpp
struct ScrollStartContext { uint16_t intervalMs; bool callerIsAutoMode; };
struct ScrollStartResult  { bool started; bool engagedRestoreAuto; };  // caller (faces.cpp) sets mode/playback Strings from this
struct ScrollStopResult   { bool stopped; bool cleared; bool shouldRestoreDefault; bool restoreAuto; };
struct ScrollUploadResult { uint16_t frameCount; bool uploadComplete; char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1]; };
```

Upload performance contract preserved: frames are written into the PSRAM buffer outside the lock (`scrollSessionWriteFrame` writes the buffer directly); only counts + meta are committed under the lock in `scrollSessionBeginUpload`/`scrollSessionCommitUpload`. This is exactly today's shape (`web_api.cpp:817`, `:936`), just behind a named boundary instead of inlined `clearScrollTimelineMetaLocked()` etc.

Ownership completeness: with the round-3 additions, every current direct writer of a scroll field routes through `scroll_session`: `/api/scroll` (upload plane), `set_scroll_interval` (`scrollSessionSetInterval`), button stop events (`scrollSessionMarkStoppedByButton`), restore-auto (`scrollSessionGet/SetRestoreAuto`), and the Core-1 cursor (`scrollSessionTickCursorLocked`). The "only scroll_session writes scroll fields" invariant is then actually true.

### 4.2 Render-plane cursor (the Core-1 exception)

`scrollRenderTask` (`scroll.cpp`) keeps its existing `withScrollLock` block but calls one function instead of inlining the advance:

```cpp
withScrollLock([&]{
    dueFrame = scrollSessionTickCursorLocked(millis(), nextFrame);  // advances scrollFrameIndex, returns "new frame?"
});
```

Invariant statement that is true on day one:
> All scroll-state mutation goes through `scroll_session` functions. Control-plane functions acquire `scrollLock`; the render-plane `...Locked` function is invoked by the render task with `scrollLock` already held. No other code writes `RuntimeState` scroll fields.

### 4.3 Dependency inversion for default-face restore

Today `stopFirmwareScroll(clearDisplay=true)` schedules the default-face restore and calls `setMode` (`faces.cpp`). To avoid `scroll_session` depending back on face selection, the session reports intent and `faces.cpp` acts:

```cpp
// in faces.cpp
ScrollStopResult r = scrollSessionStop(restoreAuto, clearDisplay);
if (r.cleared && r.shouldRestoreDefault)
    scheduleStartupDefaultFaceRestoreAfterBlank(r.restoreAuto);
else if (r.restoreAuto)
    setMode("auto", false);
```

`scroll_session.cpp` includes nothing from `faces.h`. The deferred-restore machinery and `setMode` stay in `faces.cpp`.

### 4.4 Upload transaction: preflight and lifetime

Two rules that preserve today's behavior:

1. Validate-then-clear. The transport layer (`web_api.cpp`) keeps its first-chunk preflight: every frame of the first chunk is decoded/validated before any state is touched, exactly as today (`web_api.cpp:782` preflight, then `stopFirmwareScroll(false)` and clear at `:815`). `scrollSessionBeginUpload` is only called after that preflight succeeds, so a malformed first chunk can never erase a working timeline. `scrollSessionBeginUpload` is the commit point of "we are now replacing the cache," not the validation point.
2. Transaction lifetime is request-local. `ScrollUploadTxn` is a stack/local context for one HTTP request, constructed from a locked snapshot of meta (`nextChunkIndex`, `framesReceived`, `baseIndex`, `timelineId`). It is not persistent state held across requests -- chunked uploads are separate HTTP requests, and the durable per-timeline state lives in `ScrollTimelineMeta` under the lock. The txn just carries the validated, in-request working values between `Begin/Write/Append/Commit`.

Partial-frames-invisible invariant (mandatory):
- `scrollFrameCount`, `framesReceived`, and `uploadComplete` MUST NOT advance to expose any frame in a chunk/transaction until every frame of that chunk is fully written. Publication happens only in `scrollSessionCommitUpload`, atomically under the lock.
- `scrollSessionWriteFrame` MUST reject (return false) a write into a frame index currently visible to playback (within `[0, scrollFrameCount)`) unless playback has first been stopped or the cache invalidated. Appends beyond the visible range are allowed; the first-chunk path clears state (post-preflight) before writing.

### 4.5 scrollSessionStart context/result (no face dependency, no String-under-lock)

`startFirmwareScroll` today captures auto-mode restore intent and flips `mode`/`playback` Strings inside `withScrollLock` (`faces.cpp:352-378`). The refactor moves the decision out:

- Caller passes `ScrollStartContext{ intervalMs, callerIsAutoMode }`.
- `scrollSessionStart` sets only scroll scalars under the lock and returns `ScrollStartResult{ started, engagedRestoreAuto }`.
- `faces.cpp` (the caller) performs any `mode`/`playback` String assignment after the lock is released, from the result -- which also resolves the sec 4.6 String-under-lock issue by construction.

### 4.6 Side cleanup (free win)
While moving these functions, fix the documented lock-contract violation: the `String` assignments to `mode`/`playback` inside `withScrollLock` (`faces.cpp:362`, `:371`) and the `String` copy at `:304`. Snapshot scalars under the lock; do String work after release. With sec 4.5 this falls out naturally for the start path.

---

## 5. Browser: scroll machine (inline in `app.js`)

### 5.1 States and pause model

```
state in { IDLE, GENERATING, UPLOADING, STARTING, ACTIVE, STEPPING, RESTORING, STOPPING }
ACTIVE.pauseReasons : Set<"user" | "system">
isPlaying = (state === ACTIVE) && pauseReasons.size === 0
```

The coarse `firmwareBacked = state in {...}` derivation is rejected -- it conflates two independent facts and is wrong during `RESTORING` (firmware can already have a live session while the browser has not regenerated/bound frames). Two explicit derived subfields are tracked from FW_SYNC, independent of the UI `state`:

```
device.hasSession   : bool   // firmware reports a real scroll session (active OR paused OR cached+startable)
cache.identityBound : bool   // local scroll.frames are pixel-exact to the firmware timeline
                             //   = !restoredTextTruncated
                             //     && exactGeneratorMatch(meta)               // fontId + generatorVersion
                             //     && scroll.frames.length === fw.frameCount
                             //     && scroll.framesTimelineId === fw.scrollTimelineId   // timeline binding (app.js:8897)
```

- `device.hasSession` may be true while `state === RESTORING` or even `IDLE` (e.g. second browser / timeline-mismatch at `app.js:4845`); it drives "is there something on the device to control/restore."
- `cache.identityBound` drives "may we treat the local preview as pixel-exact." It must include the timeline-id binding, not just generator match + frame count, matching today's `localTimelineMatchesMeta` (`app.js:8897`). "Active local preview" and "firmware-backed exact identity" are separate concepts.
- "Reference only" preview labeling already exists in current code (`setScrollRestoreWarning`). This plan does not introduce that behavior; it only rewires the gate to `cache.identityBound`, which lands in phase 4 (the one intentional behavior change).

Pause model mirrors firmware `firmwareScrollUserPaused`/`firmwareScrollSystemPaused` and `recomputeEffectivePauseLocked` (`faces.cpp:281`): `PAUSE_USER`/`PAUSE_SYSTEM` add a reason, `RESUME_USER`/`RESUME_SYSTEM` delete one, and playback only resumes when the set empties. Exclusive `PAUSED_USER`/`PAUSED_SYSTEM` states are rejected -- they break "user paused, then battery overlay system-paused, then overlay ends."

### 5.2 Events and transition table

"Non-busy state" = any state where no `gen.*` operation is in flight for the relevant domain (`IDLE`, `ACTIVE`, plus `RESTORING`/`STOPPING` only where noted). Replacement flows (`GENERATE`, `RESTORE_BEGIN`) are allowed from any non-busy state and run an explicit cleanup-first effect, mirroring today's `startScroll()` terminate/reset and the timeline-mismatch restore trigger (`app.js:4845`).

| Event | From | To | Effect / notes |
|---|---|---|---|
| `GENERATE` | any non-busy (IDLE, ACTIVE) | GENERATING | cleanup first: bump epoch (cancel other domains), `terminateOtherActivities`, clear restore state, reset cache; then build frames |
| `UPLOAD_BEGIN` | GENERATING | UPLOADING | captures `gen.upload` |
| `UPLOAD_PROGRESS` | UPLOADING | UPLOADING | UI only; token-checked |
| `UPLOAD_COMMIT_DONE` | UPLOADING | STARTING | all chunks committed on device; not yet playing; token-checked |
| `START_CONFIRMED` | STARTING | ACTIVE | `/api/command start_scroll` returned ok; playback active; token-checked |
| `START_FAIL` | STARTING | IDLE | token-checked; cache may remain for retry |
| `UPLOAD_FAIL` | UPLOADING | IDLE | token-checked |
| `PAUSE_USER` | ACTIVE | ACTIVE | `pauseReasons.add("user")` |
| `RESUME_USER` | ACTIVE | ACTIVE | `pauseReasons.delete("user")` |
| `PAUSE_SYSTEM` | ACTIVE | ACTIVE | `pauseReasons.add("system")` |
| `RESUME_SYSTEM` | ACTIVE | ACTIVE | `pauseReasons.delete("system")` |
| `STEP` | ACTIVE | STEPPING | captures `gen.step` |
| `STEP_DONE` | STEPPING | ACTIVE | token-checked |
| `STOP` | any | STOPPING | bump epoch (cancel other domains); captures intent |
| `STOP_DONE` | STOPPING | IDLE | clears cache + restore state |
| `RESTORE_BEGIN` | any non-busy (IDLE, ACTIVE) | RESTORING | cleanup first if replacing; bump epoch; captures `gen.restore`; allowed when `device.hasSession` even if browser holds other state |
| `RESTORE_DONE` | RESTORING | ACTIVE / IDLE | token-checked; sets `cache.identityBound` only on full match (sec 5.1) |
| `FW_SYNC` | any | (same) | updates `device.hasSession`; authoritative cursor when `device.hasSession` (sec 7) |
| `TEXT_EDITED` | any | (same) | sets `restore.textEdited`; blocks auto-overwrite (C5) |

`UPLOAD_COMMIT_DONE` and `START_CONFIRMED` are deliberately separate: today the browser uploads all chunks, then issues `/api/command start_scroll`, then applies runtime state (`app.js:8405`). Going straight from upload to `ACTIVE` would mark playback active before the device confirms start. `STARTING` is the gap.

### 5.3 Operation tokens + cross-domain cancellation

`busy` becomes UI-affordance only (what controls to disable). State commits are gated two ways:

```js
machine.epoch = 0;                                   // monotonic; bumped by STOP / GENERATE / RESTORE_BEGIN
machine.gen   = { upload: 0, restore: 0, step: 0, statusPoll: 0 };

// async op capture:
const t = { epoch: machine.epoch, dom: ++machine.gen.upload };
... await apiPost("/api/scroll", ...) ...
dispatch("UPLOAD_COMMIT_DONE", data, t);
// reducer drops the event if t.epoch !== machine.epoch  (a newer STOP/GENERATE/RESTORE happened)
//                       or t.dom   !== machine.gen.upload (a newer op in the same domain happened)
```

- Per-domain token (`gen.*`) drops a stale reply from the same domain (e.g. an old upload chunk).
- Epoch drops a stale reply from a different domain: a late upload/start/meta completion can no longer call `applyFirmwareRuntimeState` and clobber a newer `STOP`/`GENERATE`/`RESTORE`. This is the cross-domain cancellation the flag soup lacked.
- `gen.upload` is today's `uploadGeneration` (`app.js:8338`), renamed; `gen.restore` guards the `/api/scroll/meta` + preview-regen pipeline (today races via `pendingScrollMeta` + `scrollMetaFetchInFlight`); `gen.step`/`gen.statusPoll` cover step and polls.

### 5.4 Field migration map (`scroll{}` -> machine)

| Group | Absorbs |
|---|---|
| `machine.state` + `pauseReasons` | `active`, `paused`, `userPaused`, `systemPaused` |
| `machine.device.hasSession` + `machine.cache.identityBound` | `firmwareBacked` (split; no longer one derived bool) |
| `machine.cache` | `frames`, `signature`, `dirty`, `timelineId`, `framesTimelineId`, `frameIndex`, `offset` |
| `machine.upload` | `uploading`, `uploadProgress/Label/Token`, `uploadGeneration`, all `*Busy` -> `busy` |
| `machine.restore` | `pendingScrollMeta`, `restoredSourceText`, `restoredFromFirmwareMeta`, `restoreWarning`, `restoredTextTruncated`, `textEdited`, `scrollMetaFetchInFlight`, `lastFwScroll*` |
| `machine.metrics` | `frameCounter`, `fpsStarted`, `measuredFps` |
| `machine.returnMode` | unchanged |

---

## 6. No-bundler integration

The WebUI is a single vanilla `<script src="app.js">` served gzip'd by a single-threaded ESP, and must still run from `file://` offline.

- Default: the scroll machine is an IIFE section inside `app.js` -- `const scrollMachine = (function(){ ... return { dispatch, snapshot, get state }; })();`. No `import`/`export`, no `type="module"`, no extra HTTP round-trip, no CSP change.
- If ever split into its own file, it would be a plain global-exposing `<script>` ordered before `app.js`, and `scripts/gzip_webui_assets.py` `GZIP_TARGETS` would need it added. Avoid unless it earns its keep.
- The name "scrollMachine.js" is aspirational; in practice it is the scroll-machine module within `app.js`.

---

## 7. FW_SYNC authority (the anti-drift policy)

Decision: FW_SYNC is the sole writer of the canonical playback cursor whenever `device.hasSession` is true. Baked into the reducer because it is the main architectural win and is the anti-drift fix. The gate is `device.hasSession` (a real firmware session), not the coarse UI `state` -- so it also holds during `RESTORING`.

- While `device.hasSession`: every FW_SYNC (poll or `/api/scroll/meta`) snaps `cache.frameIndex` to the firmware `scrollFrameIndex`.
- The local `advanceScroll` timer is demoted to a display-only tween that never writes `cache.frameIndex` and is discarded on each sync.
- Tween rendering is only pixel-trustworthy when `cache.identityBound`; otherwise the preview is labeled "reference only" and the canonical index still comes from firmware.
- While paused/stepping, FW_SYNC is likewise authoritative.

Today both firmware sync and the local timer write `scroll.frameIndex` (`app.js:4714` and `app.js:8729`), which is why drift is structurally possible. Result after this change: preview and LEDs cannot drift by construction, and the "make firmware the single clock" task is done -- it lives entirely in the FW_SYNC handler.

---

## 8. Phased migration (strangler; behavior-identical until phase 4)

Phase 0 -- Design sign-off. This document approved.

Phase 1 -- Firmware extraction, behavior-identical (three independent rollback boundaries).

- Phase 1A -- control plane. Move start/stop/pause/step + interval + stop-event + restore-auto into `scroll_session.cpp` behind the sec 4.1 control API; `scrollSessionStart` uses context/result (sec 4.5) and `scrollSessionStop` returns the result struct (sec 4.3); `faces.cpp` consumes both. Fix the sec 4.6 String-under-lock issue here. The `/api/scroll` upload writes, the `scrollSessionSnapshot` reader (Phase 2), and the Core-1 advance (Phase 1C) stay where they are for now. Exact code: section 13.
  - Checkpoint: `pio run` clean; on-device parity for pause(user)+overlay(system), step at boundaries, stop+restore-auto, set_scroll_interval, button stop-event.
- Phase 1B -- upload/cache plane. Move the `/api/scroll` direct writes (`web_api.cpp:817`, `:936`) behind the upload transaction API (sec 4.1/4.4), preserving transport-layer preflight (validate-then-clear), enforcing the partial-frames-invisible invariant and visible-index write rejection. Add `scrollSessionCopyMeta` and route `/api/scroll/meta` through it.
  - Checkpoint: `pio run -t buildfs` clean; start/append/409-retry parity; malformed first chunk does NOT erase an existing timeline; oversized upload -> 413 with sourceText preserved (EH-A).
- Phase 1C -- render cursor. Move the Core-1 advance (`scroll.cpp:42`) into `scrollSessionTickCursorLocked()`, called inside the render task's existing `withScrollLock`.
  - Checkpoint: timing parity (no WS2812 glitch under load); scroll playback smooth; reboot drops RAM cache.

Phase 2 -- Route reads through the snapshot.
- `/api/status` reads `scrollSessionSnapshot()` (small scalars). Per open item 3, also route `/api/command` replies (`buildCommandReply`, `web_api.cpp:1367`) through the snapshot so all three read paths converge. (`/api/scroll/meta` already moved to `scrollSessionCopyMeta` in 1B.)
  - Checkpoint: status/command JSON byte-identical to pre-refactor for representative states.

Phase 3 -- Browser machine as a compatibility wrapper.
- Introduce the inline `scrollMachine` with `scroll{}` still the backing store; `dispatch` delegates to existing functions. No behavior change.
  - Checkpoint: manual run of all 6.4 flows + reload-restore matrix shows no diff.

Phase 4 -- Move logic into the reducer, one event at a time.
- Order: PLAY (GENERATE/UPLOAD/START) -> PAUSE/RESUME (reason set) -> STOP -> STEP -> FW_SYNC/restore (hairiest, last). Introduce `gen.*` tokens + epoch with the async events. Land the sec 7 FW_SYNC authority and the `cache.identityBound` rewiring here (the one intentional behavior change).
  - Checkpoint after each event: targeted tests green (sec 9).

Phase 5 -- Delete dead `scroll{}` fields + module globals.
- Remove migrated fields, `pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, the `*Busy` flags, `pauseToggleLocked`.
  - Checkpoint: grep shows no residual references; full regression pass.

---

## 9. Testing

Firmware (integration against the HTTP API where possible):
- Scroll start / chunked append / 409 conflict -> fresh-timeline retry.
- pause(user) then battery_overlay (system) then overlay end -> stays paused (composable-pause regression).
- Step at index 0 and at `frameCount-1` (wrap both directions).
- stop_scroll with `restoreAuto` true/false and `clear` true/false -> correct face restore via `faces.cpp`.
- set_scroll_interval -> `scrollIntervalMs`/`lastScrollFrameMs` updated via session API only.
- Malformed first chunk -> existing timeline/cache preserved (preflight validate-then-clear).
- Reboot -> RAM cache lost, `/api/scroll/meta` reports no frames.
- Oversized upload (> MAX_SCROLL_FRAMES) -> 413, cache invalidated, sourceText preserved (EH-A).

Browser (unit + scripted; host-mocked, no DOM):
- One assertion per transition-table row: `dispatch(state, event) -> state` incl. `pauseReasons` set ops.
- STARTING gap: `UPLOAD_COMMIT_DONE` does not set `isPlaying`; only `START_CONFIRMED` does; `START_FAIL` returns to IDLE.
- Token-staleness (same domain): a late `UPLOAD_COMMIT_DONE`/`RESTORE_DONE`/`STEP_DONE`/`START_CONFIRMED` with an old `gen.*` is dropped.
- Cross-domain cancellation (epoch): a late reply from any domain after a STOP/GENERATE/RESTORE is dropped (does not call `applyFirmwareRuntimeState`).
- Derived fields: `device.hasSession` true during RESTORING; `cache.identityBound` true only on `!truncated && generatorMatch && frameCount match && framesTimelineId === fw timeline`.
- Replacement flow: GENERATE/RESTORE_BEGIN from ACTIVE runs cleanup (terminate + reset + epoch bump) first.
- FW_SYNC authority: local tween never advances canonical `cache.frameIndex` while `device.hasSession`.

Keep existing: `tools/test_m370_boundary.js` still passes (encoding unchanged).

---

## 10. Risks and rollback

| Risk | Mitigation |
|---|---|
| Largest/most-coupled area; regressions | Strangler phasing; behavior-identical phases 1-3; checkpoints |
| Upload hot path slowed by API indirection | Frames still written to PSRAM outside the lock; only counts/meta under lock |
| Core-1 timing perturbed | Render-plane tick is one ...Locked call inside the existing critical section; no new locks |
| Malformed first chunk erases timeline | Transport-layer preflight stays; BeginUpload commits only after validation (sec 4.4) |
| Stale cross-domain completion | Epoch + per-domain tokens added with each async event (sec 5.3) |
| file:// / offline breakage | Inline IIFE, no module system, no new request |

Rollback: each phase is an independent commit; phases 1-3 are behavior-identical, so reverting any single phase restores prior behavior without data migration.

---

## 11. What this does NOT fix
- Clarity/maintainability + correctness-of-races refactor. The drift fix is included only because sec 7 bakes FW_SYNC authority into the reducer; without phase 4 that policy is not active.
- Does not change the scroll wire protocol, the M370 encoding, or the PSRAM cache size/limits.
- Does not address the 2.5 MB `ark12.json` font-parse jank (separate P2 in `ARCHITECTURE_REPORT.md`).

---

## 12. Open items (with recommended resolutions)
1. Review cadence. Recommended: one PR per phase for 1A/1B/1C/2/3/5, and per-event within phase 4 (the only behavior-changing phase). Pending sign-off.
2. Firmware test harness. Recommended: host-mocked HTTP for protocol parity + browser reducer unit tests; a short on-device smoke checklist for 1C timing, PSRAM behavior, and reboot/RAM-cache. Pending sign-off.
3. `/api/command` consistency. Resolved: yes -- route `buildCommandReply` (`web_api.cpp:1367`) through `scrollSessionSnapshot()` in phase 2, so `/api/status`, `/api/command`, and `/api/scroll/meta` share one read path.

---

## 13. Phase 1A implementation (exact code)

This section gives exact, copy-pasteable code for Phase 1A only (the firmware
control-plane move into a new `scroll_session` module). It is behavior-identical: no
wire/JSON/protocol change, no browser change. Phases 1B (upload/cache), 1C (render
cursor), and 2 (snapshot) follow in later PRs and are previewed in 13.12. Everything
below was cross-checked against the current source (verification table in 13.10).

### 13.1 What moves in 1A

| Symbol (current) | Current location | Destination |
|---|---|---|
| `isScrollPlayback` | `faces.cpp:81` / `faces.h:34` | `scroll_session.{h,cpp}` |
| `firmwareScrollHasRuntimeStateLocked` (static) | `faces.cpp:98` | `scroll_session.cpp` (static) |
| `resetFirmwareScrollStateLocked` (static) | `faces.cpp:109` | `scroll_session.cpp` (static) |
| `recomputeEffectivePauseLocked` (static) | `faces.cpp:281` | inlined into pause fn, removed |
| `setFirmwareScrollPauseFlag` (static) | `faces.cpp:290` | `scroll_session.cpp` (static) |
| `setFirmwareScrollUserPaused` -> `scrollSessionSetUserPaused` | `faces.cpp:323` / `faces.h:30` | `scroll_session.{h,cpp}` |
| `setFirmwareScrollSystemPaused` -> `scrollSessionSetSystemPaused` | `faces.cpp:327` / `faces.h:32` | `scroll_session.{h,cpp}` |
| scroll-state body of `stopFirmwareScroll` -> `scrollSessionStop` | `faces.cpp:331` | `scroll_session.{h,cpp}` (faces keeps thin wrapper) |
| scroll-state body of `startFirmwareScroll` -> `scrollSessionStart` | `faces.cpp:352` | `scroll_session.{h,cpp}` (faces keeps thin wrapper) |
| `markScrollStoppedByButton` (static) -> `scrollSessionMarkStoppedByButton` | `buttons.cpp:67` | `scroll_session.{h,cpp}` |
| `set_scroll_interval` body -> `scrollSessionSetInterval` | `web_api.cpp:1120` | `scroll_session.{h,cpp}` |
| `getRestoreAutoAfterScroll` -> `scrollSessionGetRestoreAuto` | `scroll.cpp:10` / `scroll.h:3` | `scroll_session.{h,cpp}` |
| `setRestoreAutoAfterScroll` -> `scrollSessionSetRestoreAuto` | `scroll.cpp:16` / `scroll.h:4` | `scroll_session.{h,cpp}` |

Face-side glue that STAYS in `faces.cpp` (so `scroll_session` never includes
`faces.h`): `cancelDeferredFaceRestore`, `setMode`, `isAutoMode`,
`scheduleStartupDefaultFaceRestoreAfterBlank`. Dependency inversion (sec 4.3) is what
makes this possible. Three documented lock-contract fixes (the flagged
`faces.cpp:304/362/371` String writes under `withScrollLock`) fall out of this move
and are shown inline.

### 13.2 New file: `src/scroll_session.h`

```cpp
#pragma once
#include <Arduino.h>
#include "config.h"

// Result of a scroll start request. faces.cpp owns the mode/face glue and acts on
// engagedRestoreAuto after the call (outside the scroll lock).
struct ScrollStartResult {
    bool started            = false;  // a cached timeline existed and playback began
    bool engagedRestoreAuto = false;  // auto-mode restore intent was (re)engaged this start
};

// Result of a scroll stop request. faces.cpp performs any face restore from this.
struct ScrollStopResult {
    bool stopped             = false; // there was runtime scroll state to clear
    bool cleared             = false; // display was blanked (clearDisplay)
    bool shouldRestoreDefault = false; // caller should schedule the startup-default face
    bool restoreAuto         = false; // restore to auto mode
};

// Pure scroll-playback predicate (moved from faces.cpp).
bool isScrollPlayback(const String& playback);

// --- control plane (Core 0). Each acquires withScrollLock internally. ---
ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode);
ScrollStopResult  scrollSessionStop(bool restoreAuto, bool clearDisplay);
bool scrollSessionSetUserPaused(bool paused);
bool scrollSessionSetSystemPaused(bool paused);
void scrollSessionSetInterval(uint16_t intervalMs);
void scrollSessionMarkStoppedByButton(const String& button, const String& source);

// Restore-auto flag (moved from scroll.cpp).
bool scrollSessionGetRestoreAuto();
void scrollSessionSetRestoreAuto(bool value);
```

### 13.3 New file: `src/scroll_session.cpp`

```cpp
#include "scroll_session.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"

// Pure predicate (was faces.cpp:81).
bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

bool scrollSessionGetRestoreAuto() {
    bool value = false;
    withScrollLock([&]() { value = runtimeState().restoreAutoAfterScroll; });
    return value;
}

void scrollSessionSetRestoreAuto(bool value) {
    withScrollLock([&]() {
        runtimeState().restoreAutoAfterScroll = value;
    });
}

// Was faces.cpp:98.
static bool firmwareScrollHasRuntimeStateLocked() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           runtimeState().restoreAutoAfterScroll ||
           runtimeState().lastScrollFrameMs != 0 ||
           runtimeState().scrollFrameCount != 0 ||
           runtimeState().scrollFrameIndex != 0 ||
           runtimeState().paused ||
           isScrollPlayback(runtimeState().playback);
}

// Was faces.cpp:109. Moved verbatim (its playback write at the tail is the one
// String-under-lock the reviewer did NOT flag; left as-is to stay behavior-identical).
static void resetFirmwareScrollStateLocked(bool clearTimelineMeta = false) {
    runtimeState().firmwareScrollActive       = false;
    runtimeState().firmwareScrollPaused       = false;
    runtimeState().firmwareScrollUserPaused   = false;
    runtimeState().firmwareScrollSystemPaused = false;
    runtimeState().restoreAutoAfterScroll     = false;
    runtimeState().lastScrollFrameMs          = 0;
    runtimeState().scrollFrameCount           = 0;
    runtimeState().scrollFrameIndex           = 0;
    runtimeState().paused                     = false;
    if (clearTimelineMeta) clearScrollTimelineMetaLocked();
    else invalidateScrollUploadLocked();
    if (isScrollPlayback(runtimeState().playback)) {
        runtimeState().playback = DEFAULT_PLAYBACK;
    }
}

// Was faces.cpp:290 + recomputeEffectivePauseLocked (faces.cpp:281), merged.
// Fix: the old `const String oldPlayback = runtimeState().playback;` heap copy is
// removed; playback-change is detected with a non-allocating String != const char*
// compare, and the playback String is written OUTSIDE the lock (sec 4.6).
static bool setFirmwareScrollPauseFlag(bool userFlag, bool paused) {
    bool changed = false;
    bool applyPlaybackOutside = false;
    const char* playbackOutside = "scroll";
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount == 0 && !runtimeState().firmwareScrollActive &&
            !runtimeState().firmwareScrollPaused) {
            runtimeState().firmwareScrollUserPaused = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().firmwareScrollPaused = false;
            return;
        }

        const bool oldUser      = runtimeState().firmwareScrollUserPaused;
        const bool oldSystem    = runtimeState().firmwareScrollSystemPaused;
        const bool oldEffective = runtimeState().firmwareScrollPaused;
        const bool oldPaused    = runtimeState().paused;

        if (userFlag) runtimeState().firmwareScrollUserPaused = paused;
        else          runtimeState().firmwareScrollSystemPaused = paused;
        runtimeState().firmwareScrollActive = true;

        const bool eff = runtimeState().firmwareScrollUserPaused ||
                         runtimeState().firmwareScrollSystemPaused;
        // No String temporary: compare current (still old) playback to the target.
        const bool playbackChanges =
            runtimeState().playback != (eff ? "scroll_paused" : "scroll");

        runtimeState().firmwareScrollPaused = eff;
        runtimeState().paused               = eff;
        if (!eff) runtimeState().lastScrollFrameMs = millis();

        applyPlaybackOutside = true;
        playbackOutside      = eff ? "scroll_paused" : "scroll";

        changed = oldUser != runtimeState().firmwareScrollUserPaused ||
                  oldSystem != runtimeState().firmwareScrollSystemPaused ||
                  oldEffective != eff ||
                  playbackChanges ||
                  oldPaused != runtimeState().paused;
    });
    if (applyPlaybackOutside) runtimeState().playback = playbackOutside;  // outside lock
    if (changed) touchRuntimeState();
    return changed;
}

bool scrollSessionSetUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

bool scrollSessionSetSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

// Scroll-state portion of the old stopFirmwareScroll (faces.cpp:331). cancelDeferredFaceRestore /
// scheduleStartupDefaultFaceRestoreAfterBlank / setMode stay in the faces.cpp wrapper (sec 4.3).
ScrollStopResult scrollSessionStop(bool restoreAuto, bool clearDisplay) {
    ScrollStopResult r;
    r.restoreAuto = restoreAuto;
    r.cleared     = clearDisplay;

    bool changed = false;
    withScrollLock([&]() {
        changed = firmwareScrollHasRuntimeStateLocked();
        resetFirmwareScrollStateLocked(clearDisplay);
    });
    r.stopped = changed;
    if (changed) touchRuntimeState();
    if (changed || clearDisplay) clearQueuedM370Frames();

    if (clearDisplay) {
        applyBlankFrame("firmware_text_scroll_stop_clear");
        if (restoreAuto) r.shouldRestoreDefault = true;
    }
    return r;
}

// Scroll-state portion of the old startFirmwareScroll (faces.cpp:352). isAutoMode() is
// supplied by the caller as callerIsAutoMode; the mode="manual" write moves to the
// faces.cpp wrapper (outside the lock); playback="scroll" is written outside the lock.
ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) {
    ScrollStartResult result;
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().restoreAutoAfterScroll =
                runtimeState().restoreAutoAfterScroll || callerIsAutoMode;
            result.engagedRestoreAuto = runtimeState().restoreAutoAfterScroll;
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeState().scrollFrameIndex           = 0;
            runtimeState().lastScrollFrameMs          = millis();
            runtimeState().firmwareScrollActive       = true;
            runtimeState().firmwareScrollPaused       = false;
            runtimeState().firmwareScrollUserPaused   = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().paused                     = false;
            memcpy(firstFrame, runtimeScrollFrameBits(0), FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) {
        runtimeState().playback = "scroll";  // Core-0 field; String write outside the lock
        result.started = true;
        applyPackedFrameImmediate(firstFrame, "firmware_text_scroll_start");
    }
    return result;
}

void scrollSessionSetInterval(uint16_t intervalMs) {
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs =
            constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
}

// Was buttons.cpp:67 (static markScrollStoppedByButton).
void scrollSessionMarkStoppedByButton(const String& button, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = button;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}
```

### 13.4 Edit `src/faces.cpp`

Add the include (top, with the other includes):
```cpp
#include "scroll_session.h"
```
Delete `isScrollPlayback` (faces.cpp:81-85); it now lives in `scroll_session.cpp`
(`playbackIsNonFaceActivity` just below keeps calling it -- resolved via the include).
Delete the moved statics `firmwareScrollHasRuntimeStateLocked` (98-107) and
`resetFirmwareScrollStateLocked` (109-126).

Delete `recomputeEffectivePauseLocked` (281-288), `setFirmwareScrollPauseFlag`
(290-321), `setFirmwareScrollUserPaused`/`setFirmwareScrollSystemPaused` (323-329),
`stopFirmwareScroll` (331-350), and `startFirmwareScroll` (352-378). The pause fns are
now `scrollSessionSet*Paused` with no faces wrapper -- their call sites are updated in
13.8 and 13.9. Replace the stop/start pair with these wrappers:

```cpp
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();
    const ScrollStopResult r = scrollSessionStop(restoreAuto, clearDisplay);
    if (r.cleared) {
        if (r.shouldRestoreDefault) scheduleStartupDefaultFaceRestoreAfterBlank(r.restoreAuto);
    } else if (r.restoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    const ScrollStartResult r = scrollSessionStart(intervalMs, isAutoMode());
    if (r.engagedRestoreAuto) runtimeState().mode = "manual";  // Core-0 field; no scroll lock needed
}
```

Update the internal restore-auto calls (faces.cpp:57-58 in `setMode`, 170 in
`toggleModeFromButtonAction`):
```cpp
-        if (persistSettings && getRestoreAutoAfterScroll()) {
-            setRestoreAutoAfterScroll(false);
+        if (persistSettings && scrollSessionGetRestoreAuto()) {
+            scrollSessionSetRestoreAuto(false);
...
-    setRestoreAutoAfterScroll(false);
+    scrollSessionSetRestoreAuto(false);
```
`scheduleStartupDefaultFaceRestoreAfterBlank` stays a `static` in faces.cpp and is in
scope for the wrapper. No header change for it.

### 13.5 Edit `src/faces.h`

Remove the three declarations now owned by `scroll_session.h`:
```cpp
-bool setFirmwareScrollUserPaused(bool paused);
-
-bool setFirmwareScrollSystemPaused(bool paused);
-
-bool isScrollPlayback(const String& playback);
```
Keep `stopFirmwareScroll`, `startFirmwareScroll`, and `playbackIsNonFaceActivity`.

### 13.6 Edit `src/scroll.h` and `src/scroll.cpp`

`src/scroll.h` -- remove the restore-auto declarations (lines 3-4):
```cpp
-bool getRestoreAutoAfterScroll();
-void setRestoreAutoAfterScroll(bool value);
-
 void startScrollRenderTask();
```
`src/scroll.cpp` -- delete `getRestoreAutoAfterScroll`/`setRestoreAutoAfterScroll`
(lines 10-20). The render task stays; `scroll.cpp` does not call these, so no other
change and no new include is needed.

### 13.7 Edit `src/buttons.cpp`

Add `#include "scroll_session.h"`. Remove the static `markScrollStoppedByButton`
(lines 67-74). Update the three call sites (lines 112, 123, 128):
```cpp
-        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
+        if (handled && shouldNotifyScrollStop) scrollSessionMarkStoppedByButton(code, source);
```
Update the restore-auto call (line 118):
```cpp
-        setRestoreAutoAfterScroll(false);
+        scrollSessionSetRestoreAuto(false);
```
`isScrollPlayback` (buttons.cpp:57) now resolves via the include.

### 13.8 Edit `src/web_api.cpp`

Add `#include "scroll_session.h"`. Delegate `commandSetScrollInterval`
(lines 1120-1130):
```cpp
 static bool commandSetScrollInterval(JsonDocument& doc, JsonVariant payload, String& error) {
     (void)error;
     uint16_t iMs = runtimeState().scrollIntervalMs;
     scrollIntervalFromCommand(doc, payload, iMs);
-    withScrollLock([&]() {
-        runtimeState().scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
-        runtimeState().lastScrollFrameMs = millis();
-    });
-    touchRuntimeState();
+    scrollSessionSetInterval(iMs);
     return true;
 }
```
Pause/resume helpers (lines 393-404):
```cpp
-    changed = setFirmwareScrollUserPaused(true);
+    changed = scrollSessionSetUserPaused(true);
...
-    if (canResume) changed = setFirmwareScrollUserPaused(false);
+    if (canResume) changed = scrollSessionSetUserPaused(false);
```
`commandStopScroll` restore-auto read (line 1246) and
`commandTerminateOtherActivities` write (line 1299):
```cpp
-    bool restoreAuto  = getRestoreAutoAfterScroll();
+    bool restoreAuto  = scrollSessionGetRestoreAuto();
...
-        setRestoreAutoAfterScroll(true);
+        scrollSessionSetRestoreAuto(true);
```
`isScrollPlayback` (web_api.cpp:623) resolves via the include.

### 13.9 Edit `src/button_animations.cpp`

Add `#include "scroll_session.h"`. Update the two system-pause calls (lines 364, 378):
```cpp
-    if (shouldPause && setFirmwareScrollSystemPaused(true)) {
+    if (shouldPause && scrollSessionSetSystemPaused(true)) {
...
-    setFirmwareScrollSystemPaused(false);
+    scrollSessionSetSystemPaused(false);
```

### 13.10 Verification against current source

| Claim | Verified against |
|---|---|
| restore-auto defined `scroll.cpp:10/16`, declared `scroll.h:3/4` | grep confirmed |
| restore-auto callers: `faces.cpp:57,58,170`; `buttons.cpp:118`; `web_api.cpp:1246,1299` | grep confirmed (exactly these 6) |
| `setFirmwareScrollUserPaused` callers: `web_api.cpp:394,403` | read confirmed |
| `setFirmwareScrollSystemPaused` callers: `button_animations.cpp:364,378` | read confirmed |
| `markScrollStoppedByButton` static `buttons.cpp:67`, 3 call sites | read confirmed |
| `commandSetScrollInterval` body `web_api.cpp:1120-1130` | read confirmed |
| `start/stopFirmwareScroll` bodies `faces.cpp:352/331` | read confirmed (verbatim above) |
| `mode`/`playback` are Core-0 cooperative fields (safe outside scroll lock) | `state.h:13-19` lock/owner contract |
| `isScrollPlayback` consumers: `faces.cpp`, `buttons.cpp:57`, `web_api.cpp:623` | grep/read confirmed; all 3 get the include |

Behavior-equivalence arguments (the only non-mechanical changes):
1. Pause-flag playback detection. Old code captured `const String oldPlayback` and
   compared after `recomputeEffectivePauseLocked`. New code computes
   `playbackChanges = currentPlayback != (eff ? "scroll_paused" : "scroll")` before the
   write. Since `recompute` set playback purely as a function of `eff`, the two
   booleans are identical; only the heap String copy is removed.
2. playback written outside the lock. `playback` is Core-0 cooperative state
   (`state.h:16-19`) and is not read by the Core-1 render task. On Core 0 there is no
   yield between lock release and the assignment, so no observer sees an intermediate
   value. Same for `mode="manual"` in the start wrapper.
3. Order of `mode="manual"` vs frame publish in start. `publishPackedFrameNow` takes
   only the frame lock and does not read `mode`, and Core 0 does not yield between, so
   the reorder is unobservable.
4. `resetFirmwareScrollStateLocked` is moved verbatim (including its tail `playback`
   write under the lock, not in the flagged set), preserving stop semantics exactly.

### 13.11 Build + checkpoint

```
pio run                       # compile firmware
pio run -t buildfs            # (optional in 1A) LittleFS image still builds
```
On-device parity checklist:
- Pause (user) then battery overlay (system) then end overlay -> still paused.
- B1/B2 face step at list ends; B3 mode toggle; B3+B1/B3+B2 interval.
- Start scroll, stop with clear+restore-auto -> returns to auto and shows default face.
- `set_scroll_interval` via `/api/command` updates fps with no visual glitch.
- Button-triggered scroll stop still produces a `scrollStopEvent` in `/api/status`.

This is one self-contained, behavior-identical PR. Revert = restore prior behavior
with no data migration.

### 13.12 Next PRs (previews)
- Phase 1B (upload/cache): `ScrollUploadTxn` + `scrollSessionBeginUpload/WriteFrame/
  AppendChunk/CommitUpload/InvalidateCache/ClearTimeline` over the `web_api.cpp:817/936`
  writes; keep the transport-layer first-chunk preflight (`web_api.cpp:782`); add
  `scrollSessionCopyMeta` and route `/api/scroll/meta`.
- Phase 1C (render cursor): move the `scroll.cpp:42` advance into
  `scrollSessionTickCursorLocked(now, outFrameBits)`, called inside the render task's
  existing `withScrollLock`.
- Phase 2 (snapshot): `scrollSessionSnapshot()` backing `/api/status` and
  `buildCommandReply` (`web_api.cpp:1367`).

---

## Appendix A -- Code references (current source)
- Pause OR-semantics: `src/faces.cpp:281` (`recomputeEffectivePauseLocked`), `:290` (`setFirmwareScrollPauseFlag`).
- Scroll start/stop: `src/faces.cpp:352` / `:331`.
- String-under-lock: `src/faces.cpp:304`, `:362`, `:371`.
- Direct `/api/scroll` state writes: `src/web_api.cpp:817`, `:936`; first-chunk preflight `:782`.
- set_scroll_interval writes: `src/web_api.cpp:1120`. Command reply builder: `src/web_api.cpp:1367`.
- Button stop-event writes: `src/buttons.cpp:67`.
- restore-auto get/set: `src/scroll.cpp`. Core-1 cursor advance: `src/scroll.cpp:42`.
- Browser scroll state + globals: `data/app.js:3565`, `:3609`; upload generation `:8338`; start_scroll send `:8405`; frameIndex writers `:4714`, `:8729`; timeline match `:8897`; timeline-mismatch restore `:4845`.
- Endpoint/contract baseline: `ARCHITECTURE_REPORT.md` sec 7, sec 11, sec 13.


### Scroll Session Refactor Audit

_Source: `SCROLL_SESSION_REFACTOR_AUDIT.md`_

Audited document: `SCROLL_SESSION_REFACTOR_PLAN.md`
Codebase: `esp32s3_firmware/` (firmware `src/`, WebUI `data/app.js`, `data/index.html`)
Date of audit: 2026-06-18

## Executive Summary

**Verdict: PASS WITH REQUIRED FIXES.**

The plan is architecturally sound and, with one exception, the changes it describes are correct, internally consistent, and safe. The firmware side is the strongest part: the ownership-boundary design (everything routes through `scroll_session`) is well-specified and the behavior-equivalence arguments in sec 13.10 hold up against the source.

However, the audit surfaced one fact that dominates everything else and **must be corrected in the plan before it is used as a review contract**:

1. **The plan's status line is false.** It says *"Status: Draft for review -- no code moved yet"* and *"no behavior change in phases 1-3."* In reality the work is **already implemented in the live tree**, and substantially *beyond* Phase 1A:
   - Firmware: `src/scroll_session.{h,cpp}` exist and implement Phases **1A + 1B + 1C + 2** (control plane, upload transaction, render-cursor tick, snapshot/meta readers) plus an extra `scrollSessionStep()` that is **not described anywhere in the Phase 1A code section (sec 13)**. `faces.cpp`, `faces.h`, `scroll.cpp`, `scroll.h`, `buttons.cpp`, `button_animations.cpp`, `web_api.cpp` are all already rewired.
   - WebUI: `data/app.js` already contains the full `scrollMachine` IIFE (Phases **3 + 4**), including the epoch/token machinery and the FW_SYNC reducer.

   So this is no longer an audit of an unimplemented design; it is an audit of an implemented refactor whose plan document was never updated. The plan must either be marked "implemented" with the deltas reconciled, or the team must be told the code already diverged from it.

2. **The plan's headline goal — "preview and LEDs cannot drift by construction" (sec 7) — is NOT achieved in the implemented code.** The local `advanceScroll` timer (`app.js:8931`) still writes `scroll.frameIndex` *unconditionally* while it runs, and `restartScrollPreviewTimer()` (`app.js:8270`) keeps that timer running during firmware-backed active playback (`scroll.active && !scroll.paused`). FW_SYNC (`applyFirmwareCursor`, `app.js:3717`) also writes `scroll.frameIndex`. That is exactly the two-writer condition the plan said it would eliminate; drift is merely bounded by the poll interval and snapped back on each sync, not removed.

Everything else is either correct or a minor consistency nit (dead `PAUSE_SYSTEM`/`RESUME_SYSTEM` events, an unguarded transition table, firmware step-while-running, a stray `app.js.mine` file). Details below.

---

## Stage-by-Stage Audit

The plan's "stages" are its phases (sec 8) plus the detailed Phase 1A spec (sec 13). Each is audited against the actual implemented code.

### Stage Phase 1A: Firmware control-plane extraction
Status: **PASS**

Planned changes (sec 13): move `isScrollPlayback`, the pause statics, `start/stopFirmwareScroll` bodies, `markScrollStoppedByButton`, `set_scroll_interval` body, and restore-auto get/set into `scroll_session.{h,cpp}`; leave face glue in `faces.cpp` via dependency inversion; fix the `String`-under-lock contract violations.

Verified code locations:
- `src/scroll_session.cpp`: `isScrollPlayback` (8), `scrollSessionGetRestoreAuto`/`SetRestoreAuto` (14-24), `firmwareScrollHasRuntimeStateLocked` (26), `resetFirmwareScrollStateLocked` (37), `setFirmwareScrollPauseFlag` (54-99), `scrollSessionSetUserPaused`/`SetSystemPaused` (101-107), `scrollSessionStop` (129), `scrollSessionStart` (151), `scrollSessionSetInterval` (185), `scrollSessionMarkStoppedByButton` (194).
- `src/faces.cpp`: thin wrappers `stopFirmwareScroll` (244-252), `startFirmwareScroll` (254-258); restore-auto callers rewired (56-57, 133); old statics deleted.
- `src/faces.h`: `setFirmwareScrollUserPaused`/`SystemPaused`/`isScrollPlayback` removed (confirmed absent).
- `src/scroll.cpp`/`.h`: `get/setRestoreAutoAfterScroll` removed from header (scroll.h now only declares `startScrollRenderTask`/`notifyScrollRenderTask`).
- `src/buttons.cpp`: `scrollSessionMarkStoppedByButton` (103, 113, 118), `scrollSessionSetRestoreAuto` (109).
- `src/button_animations.cpp`: `scrollSessionSetSystemPaused` (365, 379).
- `src/web_api.cpp`: `scrollSessionSetUserPaused` (361, 370), `scrollSessionSetInterval` (1015), `scrollSessionGetRestoreAuto` (1121), `scrollSessionSetRestoreAuto` (1174).

Findings:
- Correct. The `setFirmwareScrollPauseFlag` rewrite in `scroll_session.cpp:54-99` matches sec 13.3 verbatim, including the no-heap-`String` `playbackChanges` compare (80) and the out-of-lock `playback` write (96). The behavior-equivalence argument in sec 13.10 (#1) is valid: `recompute` set playback purely as a function of `eff`, so the pre-write compare is identical.
- The `String`-under-lock fixes (sec 4.6) are present: `playback` written outside the lock in both pause (`scroll_session.cpp:96`) and start (`:178`); `mode="manual"` outside the lock in the faces wrapper (`faces.cpp:257`).
- `resetFirmwareScrollStateLocked` moved verbatim including its tail `playback` write under the lock (`scroll_session.cpp:49-51`) — consistent with sec 13.10 (#4).
- No leftover duplicate definitions of any moved symbol (grep across `src/` confirms the old names exist only as `scrollSession*` variants).

Required fixes: none for 1A itself. Update sec 13's "no browser change / behavior-identical" framing since the browser was also changed (see Phase 3/4).

### Stage Phase 1B: Upload / cache transaction plane
Status: **PASS**

Planned changes (sec 4.1, 4.4, 8): route `/api/scroll` writes behind `scrollSessionBeginUpload/BeginAppend/WriteFrame/CommitUpload/InvalidateCache/ClearTimeline`; preserve transport-layer first-chunk preflight (validate-then-clear); enforce partial-frames-invisible + visible-index write rejection; add `scrollSessionCopyMeta` for `/api/scroll/meta`.

Verified code locations:
- `src/web_api.cpp` `handleApiScroll`: preflight loop (745-776) decodes/validates *every* first-chunk frame before any mutation; `stopFirmwareScroll(false)` + `scrollSessionBeginUpload` only after preflight (784-793); append path `scrollSessionBeginAppend` + 409 checks (796-810); per-frame `scrollSessionWriteFrame` (854) with `scrollSessionInvalidateCache` on bad frame / overflow (836, 850); `scrollSessionCommitUpload` (867).
- `src/scroll_session.cpp`: `scrollSessionBeginUpload` (203), `scrollSessionBeginAppend` (243), `scrollSessionWriteFrame` (261) with visible-index rejection (266-267), `scrollSessionCommitUpload` (277) publishing counts under lock, `scrollSessionCopyMeta` (321).
- `src/web_api.cpp` `handleApiScrollMeta` (904) → `scrollSessionCopyMeta` (920), PSRAM text copy, 507 on alloc/overflow.

Findings:
- Correct and faithful to sec 4.4. Validate-then-clear is intact: a malformed first chunk fails at `:765` before `stopFirmwareScroll`/`BeginUpload`, so it cannot erase a working timeline.
- Partial-frames-invisible invariant holds: `scrollFrameCount` is only advanced in `scrollSessionCommitUpload` under the lock (`scroll_session.cpp:282`); `scrollSessionWriteFrame` rejects writes into `[0, scrollFrameCount)` unless first-chunk-clearing (`:266`).
- EH-A (bad/oversized frames invalidate cache but keep sourceText): `scrollSessionInvalidateCache` zeroes `scrollFrameCount` + `invalidateScrollUploadLocked()` but does **not** clear sourceText (`scroll_session.cpp:306-311`). Correct.

Required fixes: none. (Note `scrollSessionCommitUpload`'s implemented signature `(txn, count, hasExplicitTiming, intervalMs)` differs from the sec 4.1 sketch `scrollSessionCommitUpload(ScrollUploadTxn&)`; the implementation is the better one. Reconcile sec 4.1.)

### Stage Phase 1C: Render-cursor tick (Core 1)
Status: **PASS**

Planned changes (sec 4.2): move the Core-1 advance into `scrollSessionTickCursorLocked(now, outFrameBits)`, called inside the render task's existing `withScrollLock`.

Verified code locations:
- `src/scroll.cpp` `scrollRenderTask` (11-47): single `withScrollLock` block calling `scrollSessionTickCursorLocked(millis(), nextFrame)` (21); frame published under `withFrameLock` (27-38).
- `src/scroll_session.cpp` `scrollSessionTickCursorLocked` (367-392): returns false unless active && !paused && frames present; drift-compensated `lastScrollFrameMs` advance (384-388).

Findings:
- Correct. The tick is one `...Locked` call inside the existing critical section; no new lock introduced, matching the sec 10 risk mitigation. The function only writes scroll fields and reads `scrollIntervalMs` under the held lock.

Required fixes: none.

### Stage Phase 2: Route reads through the snapshot
Status: **PASS**

Planned changes (sec 8, open item 3): `/api/status`, `/api/command` reply (`buildCommandReply`), and `/api/scroll/meta` share one read path.

Verified code locations:
- `readScrollStateSnapshot()` → `scrollSessionSnapshot()` (`web_api.cpp:168-170`).
- `/api/status` `handleApiStatus` uses snapshot (`:418`) → `addScrollStateFields` (`:472`).
- `buildCommandReply(reply, cmd, scrollState)` (`:1242`) → `addScrollStateFields` (`:1255`); called from the command handler with a snapshot (`:1303-1306`).
- Upload reply also reads the snapshot (`:878`).

Findings: correct; all three read paths converge on `scrollSessionSnapshot()` + `addScrollStateFields`, exactly as open item 3 promised. JSON field names are produced in one place, eliminating the contract-drift risk.

Required fixes: none.

### Stage Phase 3: Browser machine as compatibility wrapper
Status: **PASS (already in place, beyond a pure wrapper)**

Planned changes (sec 5, 6, 8): introduce inline `scrollMachine` IIFE with `scroll{}` still backing; `dispatch` delegating; no behavior change.

Verified code locations:
- `data/app.js:3643-3817` — `scrollMachine` IIFE with `state`, `pauseReasons:Set`, `epoch`, `gen{upload,restore,step,statusPoll}`, `device.hasSession`, `cache.identityBound/frameIndex`; `token`, `isCurrent`, `bumpEpoch`, `dispatch`, `snapshot`.
- Dispatch call sites wired across upload/start (`:8514,8584,8597,8601`), generate (`:8637`), pause/resume (`:8747,8781`), stop (`:8811,8828`), step (`:8899,8918`), restore (`:9256` + many `RESTORE_DONE`), FW_SYNC (`:4890`), text edit (`:8308`).

Findings:
- The machine is real, not a thin pass-through; it already carries Phase-4 logic. `scroll{}` is still the backing store (`syncPauseBacking` writes `scroll.userPaused/systemPaused/paused`, `setPhase` writes `scroll.active/restoring/uploading`), so the compatibility-wrapper intent is honored.
- **Risk:** `dispatch` does **not** validate the `From` state. The plan's sec 5.2 transition table specifies `From`→`To` constraints (e.g. `STEP` only from `ACTIVE`, `START_CONFIRMED` only from `STARTING`). The reducer applies effects regardless of current state (`app.js:3730-3803`). In practice the UI gates these via `commandBusy`/disabled buttons, but the state-machine invariant the plan advertises is not enforced in code.

Required fixes: see Cross-Stage and Required Corrections.

### Stage Phase 4: FW_SYNC authority + identityBound rewiring (the one intended behavior change)
Status: **NEEDS FIX**

Planned changes (sec 5.1, 7): FW_SYNC becomes the *sole* writer of the canonical cursor whenever `device.hasSession`; local `advanceScroll` timer demoted to display-only tween that never writes `cache.frameIndex` and is discarded on each sync; `cache.identityBound` (incl. timeline-id binding) gates "reference only".

Verified code locations:
- `applyFirmwareCursor` (`app.js:3693-3728`): snaps `scroll.frameIndex`/`machine.cache.frameIndex` to firmware index when `device.hasSession` (3717-3721); skips during GENERATING/UPLOADING/STARTING ("FIX 4", 3695).
- `deriveIdentityBound` (`:3683-3691`): includes `!restoredTextTruncated && exactGeneratorMatch(meta) && frames.length===frameCount && framesTimelineId===meta.scrollTimelineId` — matches sec 5.1 formula incl. timeline binding.
- `advanceScroll` (`:8927-8944`): writes `scroll.frameIndex` unconditionally (8931).
- `restartScrollPreviewTimer` (`:8270-8276`): starts the `advanceScroll` interval whenever `scroll.active && !scroll.paused`.

Findings:
- `identityBound` is correctly derived and includes the timeline-id binding (matches the `localTimelineMatchesMeta` gate the plan cited).
- **The core anti-drift policy is incomplete.** FW_SYNC writes the cursor, but so does the still-running local timer during firmware-backed ACTIVE playback. Both `applyFirmwareCursor` (3718) and `advanceScroll` (8931) write `scroll.frameIndex`. The plan's promise ("preview and LEDs cannot drift by construction", sec 7) is therefore not met; drift is only bounded by the FW_SYNC poll cadence (`statusNextPollMs`: 250 ms while scrolling+summary, else 1000 ms — `web_api.cpp:162-166`) and corrected with a visible snap. The plan explicitly listed the two-writer condition (`app.js:4714` and `:8729` historically) as the thing to remove; it persists.

Required fixes: demote the timer (see Required Corrections #1).

### Stage Phase 5: Delete dead `scroll{}` fields + module globals
Status: **NOT DONE (expected) — but note coexistence**

Planned changes: remove migrated fields, `pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, `*Busy` flags, `pauseToggleLocked`.

Findings: `pendingScrollMeta`, `lastFwScroll*` (e.g. `lastFwScrollFrameCount` at `app.js:8845`), and the per-control `*Busy` flags (`scroll.commandBusy/pauseBusy/stepBusy/stopBusy/fpsBusy`) are still present and live. This is consistent with Phase 5 being future work. No defect, but the audit goal "no conflicting definitions of scroll session state" is only partially met while both the machine and the legacy `scroll{}` booleans are authoritative in parallel.

Required fixes: none yet; track for Phase 5.

---

## Cross-Stage Consistency Check

- **Names / JSON fields are consistent firmware↔WebUI.** Status/meta producers emit `firmwareScrollActive`, `firmwareScrollPaused`, `firmwareScrollUserPaused`, `firmwareScrollSystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount`, `scrollFrameIndex`, `scrollIntervalMs`, `scrollTimelineId`, `scrollUploadComplete`, `scrollHasSourceText` (`web_api.cpp:172-184`). The WebUI consumes exactly these keys in `applyFirmwareCursor` (`app.js:3698-3705`) and `applyFirmwareRuntimeState` (`:9170-9186`). No mismatches found.
- **Missing dependencies:** none. Every WebUI dispatch target exists in the reducer; every firmware session function called by `web_api/faces/buttons/scroll/button_animations` is declared in `scroll_session.h`.
- **Dead transitions (defined, never dispatched):** `PAUSE_SYSTEM` and `RESUME_SYSTEM` reducer cases (`app.js:3760-3767`) have no `dispatch(...)` callers. System pause is instead applied directly inside `applyFirmwareCursor` (`:3707-3713`), which mutates `pauseReasons` without going through the reducer event. Functionally correct (battery overlay is firmware-driven and mirrored by FW_SYNC), but it contradicts sec 5.2's event model and leaves two ways to mutate system-pause.
- **Transition table not enforced (sec 5.2 vs `dispatch`):** the implemented reducer ignores the `From` column. This is a documentation/contract mismatch, not a live bug given UI gating.
- **Signature drift plan↔code:** `scrollSessionStart(ScrollStartContext)` / `scrollSessionStop(...) ` / `scrollSessionStep(int8_t)` / `scrollSessionCommitUpload(ScrollUploadTxn&)` as sketched in sec 4.1 differ from the (better) implemented signatures. The plan should be reconciled to the code so it can serve as a contract.
- **Extra surface not in the plan:** `scrollSessionStep(int8_t, uint8_t*)` (`scroll_session.{h,cpp}`) and the `scroll_step` command (`web_api.cpp:1084,1218`) are implemented but absent from sec 13's "what moves" list. The Step row in sec 5.2 exists on the browser side but the firmware function was never specified.
- **Stale line references:** every `app.js:NNNN` and `faces.cpp:NNNN` reference in the plan points at the *pre-refactor* baseline and no longer matches the current files (e.g. plan cites `scroll{}` at `app.js:3565`; the machine is now at `:3643`). Acceptable as historical context only.

---

## API Contract Verification

| Endpoint | Method | Request | Response | Firmware owner fn | WebUI caller | Status | Issues |
|---|---|---|---|---|---|---|---|
| `/api/scroll` | POST | JSON: `frames[]` (M370 strings), optional `timelineId`, `fontId`, `generatorVersion`, `sourceText`, `totalFrames`, `chunkIndex`, `append`, `start`, `fps`, `intervalMs` | `ok`, `frames`, `chunkFrames`, `chunkIndex`, `totalFrames`, `append`, `started`, `timelineId`, `uploadComplete`, `scrollIntervalMs`, `scrollMaxFrames`, `mode`, `playback`, `restoreAutoAfterScroll` | `handleApiScroll` (`web_api.cpp:~700-901`) → `scrollSessionBeginUpload/BeginAppend/WriteFrame/CommitUpload/InvalidateCache` | upload pipeline (`app.js:8513-8601`) | PASS | Preflight + invariants verified |
| `/api/scroll/meta` | GET | — | `ok`, `scrollTimelineId`, `hasSourceText`, `sourceText`, `sourceTextBytes`, `fontId`, `generatorVersion`, frame count/index, pause flags | `handleApiScrollMeta` (`:904`) → `scrollSessionCopyMeta` (`:920`) | restore pipeline (`app.js:9256+`) | PASS | 507 on PSRAM alloc/overflow handled |
| `/api/status` | GET | optional `summary` | full state incl. `addScrollStateFields` + `scrollStopEvent{seq,ms,button,source,reason}` | `handleApiStatus` (`:413`) → `scrollSessionSnapshot` | poller → `dispatch("FW_SYNC")` (`app.js:4890`) | PASS | Poll cadence 250/1000 ms (`:162`) |
| `/api/command` `start_scroll` | POST | `{intervalMs?, timelineId?}` | command reply via `buildCommandReply` | `commandStartScroll` (`:1019`) → `startFirmwareScroll` | start flow (`app.js:8601`) | PASS | Timeline-mismatch→409, incomplete→409, no frames→400 |
| `/api/command` `scroll_step` | POST | `{direction}` | reply | `commandScrollStep` (`:1084`) → `scrollSessionStep` | step handler (`app.js:8906`) | NEEDS FIX | Does not require/keep paused; render tick can overwrite when running (see Firmware Safety) |
| `/api/command` `pause_scroll` | POST | — | reply | `commandPauseScroll` → `scrollSessionSetUserPaused(true)` | `pauseScroll` (`app.js:8744`) | PASS | Composable user-pause |
| `/api/command` `resume_scroll` | POST | — | reply | `commandResumeScroll` → `resumeFirmwareScrollIfCached` | `resumeScroll` (`app.js:8778`) | PASS | `requirePaused` only for `resume` (not `resume_scroll`) — intentional |
| `/api/command` `stop_scroll` | POST | `{clear?, restoreAuto?}` | reply incl. `deferredFaceRestoreActive` | `commandStopScroll` (`:1118`) → `stopFirmwareScroll` | `stopScroll` (`app.js:8814`) | PASS | Restore handled in `faces.cpp` |
| `/api/command` `set_scroll_interval` | POST | `{fps?\|intervalMs?}` | reply | `commandSetScrollInterval` (`:1015`) → `scrollSessionSetInterval` | `setScrollFps` (`app.js:8282+`) | PASS | — |
| `/api/command` `terminate_other_activities` | POST | `{targetMode}` | reply | `commandTerminateOtherActivities` (`:1166`) → `scrollSessionSetRestoreAuto` | mode switches | PASS | Sets `restoreAuto` + `mode="manual"` for scroll target in auto |

Failure cases checked: malformed first chunk → 400 pre-mutation (timeline preserved); oversized → 413, cache invalidated, sourceText kept; chunk out of order / timeline mismatch / upload complete → 409; PSRAM alloc fail on meta → 507. All present.

---

## State Machine Verification

Reconstructed scroll session state (firmware authoritative; browser mirrors):

| State | Firmware representation | Browser `machine.state` |
|---|---|---|
| no session | `!active && !paused && frameCount==0` | `IDLE`, `device.hasSession=false` |
| uploaded, stopped/startable | `frameCount>0`, `uploadComplete`, `!active` | `IDLE`, `device.hasSession=true` (via frameCount+uploadComplete) |
| starting | n/a (commit→start is two ops) | `STARTING` |
| running | `firmwareScrollActive && !firmwareScrollPaused` | `ACTIVE`, `pauseReasons={}` |
| paused | `firmwareScrollPaused`, reasons in `firmwareScrollUserPaused`/`SystemPaused` | `ACTIVE`, `pauseReasons⊇{user|system}` |
| stepping | index nudged, `playback="scroll_step"` | `STEPPING` |
| stopped→restored mode | `resetFirmwareScrollStateLocked` + face restore in `faces.cpp` | `IDLE` after `STOP_DONE` |
| cleared | `scrollSessionStop(clearDisplay=true)` blanks + schedules default face | `IDLE`, cache cleared |
| manual/auto takeover | `stopFirmwareScroll(false,false)` from `toggleModeFromButtonAction` / `setMode` | FW_SYNC drives `device.hasSession=false` |

Transition checks:

| Trigger | Firmware action | WebUI action | Expected | Issue |
|---|---|---|---|---|
| Upload commit | `scrollSessionCommitUpload` publishes counts | `UPLOAD_COMMIT_DONE`→STARTING | not playing yet | OK — STARTING gap honored |
| start_scroll ok | `startFirmwareScroll` | `START_CONFIRMED`→ACTIVE, clear pauseReasons | playing | OK |
| pause(user) | `SetUserPaused(true)` | `PAUSE_USER`, stop local timer | stays paused | OK |
| +battery overlay | `SetSystemPaused(true)` | FW_SYNC adds "system" | stays paused after overlay ends only if user reason remains | OK — composable preserved (`scroll_session.cpp:77`) |
| step (paused) | `scrollSessionStep` holds frame (tick returns false) | `STEP`→`STEP_DONE` | frame holds | OK |
| step (running) | index changes but tick keeps advancing | `STEP`→`STEP_DONE` | **frame does not hold** | NEEDS FIX — firmware does not pause/latch on step |
| stop/clear | `scrollSessionStop` + face restore | `STOP` (bump epoch) → await → `STOP_DONE` | LEDs and UI clear together | OK — UI does not clear until confirm; on no-confirm it restarts preview (`app.js:8824`) |
| B1/B2/B3 hardware | `stopFirmwareScroll` + `scrollSessionMarkStoppedByButton` | next FW_SYNC clears `device.hasSession`, shows face | scroll stops, face shows | OK |
| reload while scrolling | state persists in RAM | `RESTORE_BEGIN`→meta fetch→`RESTORE_DONE`, FW_SYNC authoritative | preview rebuilt + synced | OK (subject to drift caveat) |
| mode→manual/auto | `setMode` clears restore-auto | FW_SYNC | scroll stops cleanly | OK |

---

## Firmware Safety Review

- **Shared variables / locking:** every `RuntimeState` scroll-field write goes through `scroll_session` functions that take `withScrollLock` internally; the render-plane `scrollSessionTickCursorLocked` is the single documented exception, called by `scrollRenderTask` with the lock already held (`scroll.cpp:20-23`). The invariant in sec 4.2 is true in the code.
- **Core0/Core1:** Core-1 only mutates `scrollFrameIndex`/`lastScrollFrameMs` and reads `scrollIntervalMs`/`scrollFrameCount` under the held lock; frame bytes are published under a separate `withFrameLock` (`scroll.cpp:27`). No unlocked cross-core access found.
- **String-under-lock:** fixed. `playback`/`mode` String writes occur outside the lock (`scroll_session.cpp:96,178`; `faces.cpp:257`). `state.h:13-19` documents these as Core-0 cooperative fields not read by Core 1, so the out-of-lock writes are safe (sec 13.10 #2/#3).
- **Memory lifetime:** `ScrollUploadTxn` is a stack-local per-request struct; durable per-timeline meta lives under the lock in `ScrollTimelineMeta`. `scrollSessionCopyMeta` copies sourceText into a caller-provided PSRAM buffer; no dangling pointers. `ScrollUploadMeta` holds `const char*` into request-scoped `String`s that outlive the synchronous `scrollSessionBeginUpload` call — OK because copy happens immediately under the lock.
- **Frame buffers:** `scrollSessionWriteFrame` guards `index < MAX_SCROLL_FRAMES`, `runtimeScrollFrameBufferReady()`, and the visible-index rule before `memcpy`. `scrollSessionTickCursorLocked` guards `scrollFrameCount==0` and buffer-ready. Safe.
- **Buttons:** `scrollSessionMarkStoppedByButton` (`scroll_session.cpp:194-201`) writes `scrollStopEvent*` and `lastReason` **without** taking `withScrollLock`, unlike every other control-plane function. These fields are Core-0-only event fields, so it is consistent with current behavior (it was already lockless at `buttons.cpp:67`), but it contradicts the sec 4.1 statement that "each [control-plane fn] acquires `withScrollLock` internally." Document the exception or add the lock for uniformity. Low risk.
- **Step:** `scrollSessionStep` (`scroll_session.cpp:109-127`) advances the index and sets `playback="scroll_step"` but never sets `firmwareScrollPaused`. If invoked while running, `scrollSessionTickCursorLocked` continues auto-advancing, so the stepped frame is transient. Either require paused at the command layer or latch pause inside step.

## WebUI Safety Review

- **State variables:** machine state + `scroll{}` backing coexist; `syncPauseBacking`/`setPhase` keep them aligned. Acceptable until Phase 5.
- **Command busy flags:** `scroll.commandBusy` plus per-control `*Busy` serialize scroll commands against each other (pause/resume/step/stop/fps) and guard re-entrancy on rapid clicks (`app.js:8739,8773,8804,8893`). They do **not** block unrelated UI (brightness, battery, mode) — they are scoped to scroll controls, satisfying the "no global busy" goal. Token/epoch machinery (`scrollMachine.token/isCurrent`) provides the correctness layer the plan wanted.
- **Reload recovery:** `RESTORE_BEGIN`/`RESTORE_DONE` rebuild preview from `/api/scroll/meta` sourceText; `device.hasSession` can be true during `RESTORING` (FW_SYNC sets it independent of UI state), so FW_SYNC stays authoritative during restore — matches sec 7.
- **Stop/clear:** does not wipe local preview until the firmware confirms; on unconfirmed stop it logs and restarts the preview timer (`app.js:8823-8826`). Good — satisfies "Stop/Clear should not leave WebUI empty while hardware still scrolls."
- **Pause/resume/step:** synchronized via dispatch + `applyFirmwareRuntimeState`/`applyFirmwareScrollFrameIndex`; step is token-guarded (`isCurrent(stepToken)`, `:8914`).
- **Disabled/enabled states:** driven by `updateScrollUi()` (called in every handler's `finally`).
- **Drift:** see Phase 4 — local timer still writes the cursor while firmware-backed.
- **Housekeeping:** `data/app.js.mine` (a stray merge-conflict copy, *older* content despite newer mtime, lacking `scrollMachine`) sits next to the served `app.js`. `index.html` loads only `app.js?v=20260613-...`. The `.mine` file is dead weight and a footgun if anyone copies it over `app.js`; delete it.

---

## Regression Risks

1. **Preview/LED drift during firmware-backed playback** (Phase 4 gap) — visible frame snap every poll; the very symptom the refactor was meant to fix. Highest-value regression to close.
2. **Step while running** — stepped frame is immediately overwritten by the render tick; "Step Prev/Next while running" test will look broken unless step latches pause.
3. **Manual face display / Auto playback / saved faces / M/A toggle / default face** — preserved: `setMode`, `toggleModeFromButtonAction`, `serviceAutoPlayback`, deferred-restore all intact in `faces.cpp`; scroll stop routes face restore back through `faces.cpp` (sec 4.3 inversion verified at `faces.cpp:244-258`).
4. **Brightness buttons / battery animation during scroll** — brightness path (`buttons.cpp:122-131`) and battery overlay (`button_animations.cpp:365,379` via `scrollSessionSetSystemPaused`) are independent of the scroll lock writers; not blocked by scroll busy flags. Low risk.
5. **M370 upload/apply** — `clearQueuedM370Frames`/`applyPackedFrameImmediate` still used in start/step/stop; `tools/test_m370_boundary.js` parity claim (sec 9) should be re-run to confirm encoding unchanged.
6. **WebUI loading sequence / preview scaling** — unaffected by the machine; render path unchanged.
7. **Stray `app.js.mine`** — risk only if mis-deployed; it lacks the machine and would regress everything.

---

## Required Corrections Before Implementation

> Note: most of these are corrections to *already-written code*, not to an unstarted plan.

1. **Demote the local preview timer (the actual sec-7 fix).**
   - File/fn: `data/app.js` `advanceScroll` (`:8927`) and `restartScrollPreviewTimer` (`:8270`).
   - Problem: both `advanceScroll` (8931) and `applyFirmwareCursor` (3718) write `scroll.frameIndex`; the timer runs during firmware-backed ACTIVE playback, so preview drifts and is snapped on each FW_SYNC.
   - Fix: when `scrollMachine.snapshot().device.hasSession` is true, either (a) do not start the `advanceScroll` interval in `restartScrollPreviewTimer`, or (b) make `advanceScroll` a display-only tween that renders an interpolated frame without writing `scroll.frameIndex`/`scroll.offset`/`machine.cache.frameIndex`. Keep the local timer writing the index only for purely-local (non-firmware-backed) preview.
   - Why: it is the plan's single intended behavior change and headline win; as shipped it is not achieved.

2. **Make `scroll_step` latch a held frame.**
   - File/fn: `web_api.cpp` `commandScrollStep` (`:1084`) and/or `scroll_session.cpp` `scrollSessionStep` (`:109`).
   - Problem: stepping while `firmwareScrollActive && !firmwareScrollPaused` lets the render tick overwrite the stepped frame.
   - Fix: require `firmwareScrollPaused` before stepping (reject otherwise), or set `firmwareScrollUserPaused=true` (effective pause) inside `scrollSessionStep` so the cursor holds. Mirror the gate on the WebUI (only enable step when paused).
   - Why: "Step Prev/Next must stay synchronized with firmware state" — a running step does not.

3. **Reconcile the plan document with the implemented code.**
   - File: `SCROLL_SESSION_REFACTOR_PLAN.md` header + sec 4.1, 8, 13.
   - Problem: "no code moved yet" / "behavior-identical phases 1-3" is false; signatures (`scrollSessionStart`, `scrollSessionStop`, `scrollSessionCommitUpload`, `scrollSessionStep`) and the omitted firmware step function diverge from code; all line numbers are stale.
   - Fix: mark phases 1A-4 as implemented, update signatures to match `scroll_session.h`, add the `scrollSessionStep` row to sec 13.1, and refresh references.
   - Why: the document is meant to be the review contract; a stale contract is worse than none.

4. **Resolve the dead `PAUSE_SYSTEM`/`RESUME_SYSTEM` events.**
   - File/fn: `app.js` reducer (`:3760-3767`) vs `applyFirmwareCursor` (`:3707-3713`).
   - Problem: system pause is mutated directly in FW_SYNC, never via the documented events; the two reducer cases are unreachable.
   - Fix: either route the FW_SYNC system-pause update through `dispatch("PAUSE_SYSTEM"/"RESUME_SYSTEM")`, or delete the dead cases and note in the plan that system-pause is FW_SYNC-driven only.
   - Why: removes a second, undocumented mutation path for the same state (sec 1.3 "single transition path").

5. **Enforce or relax the transition table.**
   - File/fn: `app.js` `dispatch` (`:3730`).
   - Problem: `From`-state constraints in sec 5.2 are not checked; effects apply from any state.
   - Fix: add a `From`-state guard table (drop/ignore events not valid from the current state) so the machine matches its contract; or downgrade sec 5.2 to "effects, not guards" and rely on UI gating explicitly.
   - Why: prevents illegal transitions (e.g. `START_CONFIRMED` arriving in `IDLE`) from silently corrupting `scroll.active`.

6. **Document or unify the lockless `scrollSessionMarkStoppedByButton`.**
   - File/fn: `scroll_session.cpp:194-201`.
   - Problem: it writes runtime fields without `withScrollLock`, contradicting sec 4.1's blanket claim.
   - Fix: either wrap the writes in `withScrollLock` or add an explicit comment + amend sec 4.1 that stop-event fields are Core-0-only and intentionally lockless.
   - Why: keeps the "all control-plane fns take the lock" invariant honest.

7. **Delete `data/app.js.mine`.**
   - Problem: stale merge artifact without `scrollMachine`; deployment footgun.
   - Fix: remove it (and confirm the gzip asset pipeline only targets `app.js`).

---

## Final Implementation Checklist

Run after the corrections above. Firmware: build with `pio run` and `pio run -t buildfs` (the audit did not compile on-device; the sandbox has no ESP toolchain — this must be confirmed locally).

- [ ] `pio run` and `pio run -t buildfs` clean; no duplicate-symbol/link errors.
- [ ] Upload scroll text (single chunk + chunked append): `/api/scroll` returns `uploadComplete` only after all frames; partial chunk never visible.
- [ ] Pause → Resume: `firmwareScrollUserPaused` toggles; local timer stops on pause, restarts on resume (unless system-paused).
- [ ] Step Prev/Next while **paused**: frame holds, index moves by ±1, wraps at 0 and `frameCount-1`.
- [ ] Step Prev/Next while **running**: frame holds (after fix #2) or is explicitly disabled.
- [ ] Reload WebUI while **scrolling**: preview rebuilt from `/api/scroll/meta` sourceText; cursor matches LEDs; **no visible drift/snap** (validates fix #1).
- [ ] Reload WebUI while **paused**: preview restored at the paused index; pause reasons reflected.
- [ ] Stop/Clear: LEDs blank + UI clears together; on dropped command UI keeps preview and resyncs (no empty-UI-while-scrolling).
- [ ] Switch to Manual during scroll (B3/M-A and `/api/command`): scroll stops, current saved face shows.
- [ ] Switch to Auto during scroll: scroll stops, `restoreAutoAfterScroll` engaged, auto playback resumes.
- [ ] Press B1/B2 during scroll: scroll stops, next/prev saved face shows, `scrollStopEvent` recorded in `/api/status`.
- [ ] Press B3 during scroll: mode toggles, scroll stops, `scrollStopEvent` recorded.
- [ ] Network failure during pause/resume/step/stop: command logged as unconfirmed; state recovered on next FW_SYNC; no UI lockup.
- [ ] Rapid repeated clicks on pause/step/stop: serialized by `*Busy`; stale replies dropped by epoch/token (`isCurrent`).
- [ ] Saved-face apply during/after scroll: applies cleanly; no scroll residue.
- [ ] Brightness buttons during scroll: adjust without pausing/interrupting scroll.
- [ ] Battery animation (overlay) during scroll: system-pause composes with user-pause; overlay end does not resume a user-paused scroll.
- [ ] `tools/test_m370_boundary.js` passes (encoding unchanged).
- [ ] Reboot: RAM cache lost; `/api/scroll/meta` reports no frames.


## 7. Automated WebUI and Firmware Test Plan

### Scroll WebUI Test Plan

_Source: `SCROLL_WEBUI_TEST_PLAN.md`_

Target: an autonomous AI agent that joins the board's Wi-Fi, opens the WebUI, exercises
every function, and verifies results against firmware ground truth.

This plan is written to be executed by an agent with:
- An OS-control tool (to join Wi-Fi) -- e.g. computer-use.
- A browser-automation tool (to drive the WebUI DOM) -- e.g. Claude in Chrome.
- An HTTP client (to read `/api/status` etc. as the source of truth) -- e.g. fetch/curl.

Core principle: **drive the UI, assert on the firmware.** Every UI action is verified by
polling `/api/status` (and `/api/scroll/meta`) and comparing explicit JSON fields. The LED
matrix preview is a `<canvas>` and cannot be pixel-asserted reliably, so correctness is
judged by firmware state + DOM state, not by reading pixels.

---

## 1. Device facts (from firmware source)

| Item | Value | Source |
|---|---|---|
| Wi-Fi mode | SoftAP (the board IS the access point) | `web_api.cpp:1392` |
| SSID | `RinaChanBoard-V2` | `config.h:4` |
| Password | `rinachan` | `config.h:5` |
| Board IP / gateway | `192.168.1.14` | `config.cpp:3-4` |
| Subnet | `255.255.255.0` | `config.cpp:5` |
| Captive domain | `rina.io` | `config.h:6` |
| WebUI base URL | `http://192.168.1.14/` (or `http://rina.io/`) | static server |

### 1.1 HTTP API surface (all JSON, CORS-enabled)

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/status` | GET | Full runtime state (poll for assertions). `?summary` for the light payload. |
| `/api/scroll` | POST | Upload scroll frame sequence (chunked). |
| `/api/scroll/meta` | GET | Timeline meta + `sourceText` (reload-restore path). |
| `/api/command` | POST | All commands (body `{ "cmd": "...", ...payload }`). |
| `/api/power` | GET | Battery/power telemetry. |
| `/api/frame` | POST | Direct frame push (M370). |

Command names (`cmd` field): `start_scroll`, `scroll_step`, `pause_scroll`,
`resume_scroll`, `stop_scroll`, `set_scroll_interval`, `pause`, `resume`, `button`,
`set_mode`, `set_brightness`, `set_color`, `set_auto_interval`,
`terminate_other_activities`, `battery_overlay`, `reset_battery_min`, `reset_battery_max`.

### 1.2 Status fields used as assertion ground truth

From `/api/status` (and echoed in every `/api/command` reply):
`firmwareScrollActive`, `firmwareScrollPaused`, `firmwareScrollUserPaused`,
`firmwareScrollSystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount`,
`scrollFrameIndex`, `scrollIntervalMs`, `scrollTimelineId`, `scrollUploadComplete`,
`scrollHasSourceText`, `mode` (`"manual"`/`"auto"`), `playback`
(`"scroll"`/`"scroll_paused"`/`"scroll_step"`/`"auto_saved_face"`/`"idle"`/...),
`brightness`, and `scrollStopEvent{ seq, ms, button, source, reason }`.

From `/api/scroll/meta`: `ok`, `hasSourceText`, `sourceText`, `sourceTextBytes`,
`scrollTimelineId`, `fontId`, `generatorVersion`, `frameCount`, `frameIndex`, `uiFps`,
`firmwareScrollActive`, `firmwareScrollPaused`.

### 1.3 WebUI DOM handles (verified in `index.html`)

Navigation/pages: `#nav`, pages `#page-basic`, `#page-scroll`, `#page-custom`,
`#page-parts`, `#page-debug`.

Scroll page (`#page-scroll`): input `#scroll-text`; controls `#scroll-play` (start),
`#scroll-pause`, `#scroll-stop`, `#scroll-step-prev`, `#scroll-step-next`; speed
`#scroll-speed`, `#scroll-speed-range`, `#scroll-speed-minus`, `#scroll-speed-plus`,
`#scroll-speed-presets`, `#scroll-speed-reset-default`; readouts `#scroll-state`,
`#scroll-frame-index`, `#scroll-restore-warning`; progress `#scroll-upload-progress`,
`#scroll-upload-bar`, `#scroll-upload-label`; preview canvas `#matrix-scroll`.

Basic page: `#mode-toggle` (M/A), `#face-prev`, `#face-next`, `#brightness-input`,
`#brightness-range`, `#brightness-minus`, `#brightness-plus`,
`#brightness-reset-default`, `#auto-interval`, `#badge-battery*`.

Debug page GPIO simulator (drives the same code path as physical buttons):
elements with `data-gpio` = `B1`, `B2`, `B3`, `B4`, `B5`, `B3B1`, `B3B2`, `B6S`
(battery overlay single-shot), `B6L`, `B6B3`.

Hardware button semantics: B1 = next saved face, B2 = prev saved face, B3 = M/A mode
toggle, B4 = brightness down, B5 = brightness up, B3+B1 / B3+B2 = auto-interval down/up,
B6 = battery overlay. B1/B2/B3 must stop an active scroll and record a `scrollStopEvent`.

---

## 2. Test harness contract

### 2.1 Connect to the board (OS action)

1. Use the OS-control tool to open Wi-Fi settings and join SSID `RinaChanBoard-V2`
   with password `rinachan`.
2. Confirm association: the host gets an IP on `192.168.1.x` and `GET http://192.168.1.14/api/status`
   returns HTTP 200 with `{ "ok": true, ... }`.
3. If the host cannot script OS Wi-Fi, require the operator to pre-join the AP; the agent
   then starts at step 2. Do NOT proceed to UI tests until step 2 passes.

> Note: a browser-automation tool alone cannot join Wi-Fi (that is an OS-level action).
> Joining must come from computer-use or a pre-connected host. The captive-portal redirect
> to `rina.io` may appear on join; dismiss it and navigate to `http://192.168.1.14/`.

### 2.2 Open the WebUI

1. Navigate the browser to `http://192.168.1.14/`.
2. Wait for boot: poll until `document.body.dataset.page` is set and `#nav` is visible
   (the first-page reveal waterfall has run). Allow up to 15 s (fonts + runtime read).
3. Sanity: `GET /api/status` `ok===true`; record `mode`, `playback`, `brightness`,
   `scrollFrameCount` as the baseline.

### 2.3 Assertion helpers (pseudocode the agent implements)

```
getStatus()            -> JSON of GET /api/status
cmd(name, payload={})  -> POST /api/command {cmd:name, ...payload}; returns reply JSON
meta()                 -> JSON of GET /api/scroll/meta
click(sel)             -> browser click on CSS selector
type(sel, text)        -> browser set input value + fire 'input'

waitFor(fn, timeoutMs=4000, pollMs=250):
    repeat until fn(getStatus()) truthy or timeout; return last status

assert(cond, msg): record PASS/FAIL with msg and the status snapshot
```

Timing: the scroll status poll on the device runs ~500 ms while on the scroll page, so
allow >=1 s (>=2 poll cycles) before asserting UI-reflected state. Always re-read
`/api/status` directly for ground truth rather than trusting DOM text alone.

### 2.4 Standard reusable payloads

- Upload a known 8-frame timeline (single chunk) for deterministic tests:
  `POST /api/scroll` with `{ "frames": [ ...8 valid M370 strings... ], "timelineId":"T-TEST",
  "fontId":"ark12", "generatorVersion":"test", "sourceText":"TEST", "totalFrames":8,
  "fps":10, "start":false }`. (Reuse a known-good M370 frame string from
  `tools/test_m370_boundary.js`.) Easiest path: enter text in `#scroll-text` and click
  `#scroll-play`, then read back `scrollFrameCount` to learn the real frame count `N`.

---

## 3. Test suites

Each test lists: precondition, action (UI), assertion (firmware/DOM), and pass criteria.
Run suites in order; T1 establishes a session reused by later tests. Reset between
independent tests with `cmd("stop_scroll", {clear:true, restoreAuto:false})`.

### T0 -- Connectivity & boot
- T0.1 `GET /api/status` returns 200 `ok:true`. PASS if reachable.
- T0.2 WebUI loads; `#page-basic` content visible; no uncaught console errors
  (read browser console). PASS if page renders and console has no `SyntaxError`/`TypeError`.
- T0.3 Baseline capture: store `mode`, `playback`, `brightness`.

### T1 -- Upload scroll text
- Pre: on `#page-scroll` (click nav to scroll page).
- Action: `type("#scroll-text", "HELLO RINA")`; `click("#scroll-play")`.
- Assert (poll `/api/status`):
  - `scrollFrameCount > 0`, `scrollUploadComplete === true`, `scrollHasSourceText === true`.
  - `firmwareScrollActive === true`, `firmwareScrollPaused === false`, `playback === "scroll"`.
  - `meta().sourceText === "HELLO RINA"`, `meta().scrollTimelineId` non-empty.
  - `#scroll-state` text shows a running/playing state; `#scroll-upload-progress` completes.
- Pass: all true. Record `N = scrollFrameCount` and `TID = scrollTimelineId`.
- Negative: re-`click("#scroll-play")` does not error; partial frames never visible
  (`scrollFrameCount` only ever equals 0 or `N`, never an intermediate during upload).

### T2 -- Pause / Resume
- Pre: T1 running.
- T2.1 Pause: `click("#scroll-pause")`. Assert `firmwareScrollUserPaused === true`,
  `firmwareScrollPaused === true`, `playback === "scroll_paused"`. `scrollFrameIndex`
  stops advancing across 2 polls (read twice ~1 s apart; value unchanged).
- T2.2 Resume: `click("#scroll-pause")` (or `#scroll-play`). Assert
  `firmwareScrollUserPaused === false`, `firmwareScrollPaused === false`,
  `playback === "scroll"`, and `scrollFrameIndex` advances again across 2 polls.
- Pass: both transitions verified.

### T3 -- Step Left / Right  (verifies audit fix #2: step latches a held frame)
- T3.1 Step while paused: from T2.1 paused state, read `scrollFrameIndex = i`.
  `click("#scroll-step-next")` (right arrow). Assert new `scrollFrameIndex === (i+N-1) % N`,
  because the right arrow means **the text moves right visually**, not "increase the
  frame number". Increasing `scrollFrameIndex` moves the source window right, which makes
  the text appear to move left. Assert `playback === "scroll_step"` and frame index is
  **stable** across 2 polls (held). `click("#scroll-step-prev")` (left arrow) -> index
  back to `i`.
- T3.2 Boundary wrap: right arrow at index 0 -> `N-1`; left arrow at index `N-1` -> `0`.
- T3.3 Step while running: resume (T2.2), then `click("#scroll-step-next")`. Assert the
  step now **latches pause**: `firmwareScrollUserPaused === true`,
  `firmwareScrollPaused === true`, and the stepped `scrollFrameIndex` is stable across
  2 polls (does NOT keep auto-advancing). This is the corrected behavior; a regression
  would show the index still incrementing on its own.
- Pass: stepping moves exactly one frame and the frame holds in all cases.

### T4 -- Reload WebUI while scrolling / paused  (restore + anti-drift, fix #1)
- T4.1 Reload while running: with T1 running, reload the browser tab
  (`navigate http://192.168.1.14/`, go to scroll page). Assert:
  - `#scroll-text` is repopulated from `meta().sourceText`.
  - `scrollFrameCount === N`, `scrollTimelineId === TID`.
  - No `#scroll-restore-warning` for an exact-match restore (same font/generator).
  - Preview resumes; firmware remains `firmwareScrollActive === true`.
- T4.2 Anti-drift: while running and on the scroll page, sample `scrollFrameIndex` from
  `/api/status` 5 times at ~600 ms intervals; it must be **monotonic mod N** (only
  forward, wrapping), never jumping backward. The local preview must not race ahead and
  snap back. (Ground-truth firmware index is the reference; the preview is a display-only
  tween re-anchored each sync.)
- T4.3 Reload while paused: pause (T2.1), reload, go to scroll page. Assert restored
  state shows `firmwareScrollPaused === true` and the preview holds at `meta().frameIndex`.
- Pass: text/preview restored; index never moves backward; paused restore holds frame.

### T5 -- Stop / Clear  (UI must not blank while hardware still scrolls)
- Pre: T1 running.
- Action: `click("#scroll-stop")`.
- Assert: after the command confirms, `firmwareScrollActive === false`,
  `firmwareScrollPaused === false`, `scrollFrameCount === 0`, `playback` becomes
  `"idle"` or `"auto_saved_face"` (depending on restoreAuto), display blanked then face
  restored. The WebUI preview must NOT be cleared *before* the firmware confirms (observe
  that `#matrix-scroll` keeps the last frame until the stop reply arrives).
- Negative (dropped command): simulate by stopping with the network briefly blocked
  (see T8); UI keeps the local preview and logs "unconfirmed", does not blank.
- Pass: LEDs and UI clear together on success; no empty-UI-while-scrolling.

### T6 -- Switch to Manual / Auto during scroll
- Pre: T1 running.
- T6.1 To Manual: go to `#page-basic`, `click("#mode-toggle")` to Manual (or
  `cmd("set_mode",{mode:"manual"})`). Assert scroll stops
  (`firmwareScrollActive === false`), `mode === "manual"`, current saved face shows
  (`playback === "idle"`/face), and the matrix shows a face not a scroll.
- T6.2 To Auto: start scroll again (T1), toggle to Auto. Assert `mode === "auto"`,
  scroll stopped, `restoreAutoAfterScroll` handled, auto playback resumes
  (`playback === "auto_saved_face"`, `scrollFrameCount` 0).
- Pass: clean mode takeover, scroll cleared, correct face/auto behavior.

### T7 -- Hardware buttons B1 / B2 / B3 (via Debug GPIO simulator)
- Pre: T1 running. Open `#page-debug`.
- T7.1 B1 during scroll: click `[data-gpio="B1"]`. Assert scroll stops
  (`firmwareScrollActive === false`), a **new** `scrollStopEvent.seq` (greater than before)
  with `scrollStopEvent.button === "B1"`, and the next saved face is shown.
- T7.2 B2 during scroll: restart scroll, click `[data-gpio="B2"]`. Assert stop +
  `scrollStopEvent.button === "B2"` + previous saved face.
- T7.3 B3 during scroll: restart scroll, click `[data-gpio="B3"]`. Assert mode toggled,
  scroll stopped, `scrollStopEvent.button === "B3"`.
- T7.4 (optional, physical) Repeat T7.1-3 with real GPIO presses if a tester is present;
  expect identical `scrollStopEvent`s with `source` = `"gpio"`.
- Pass: each button stops scroll, records the stop event, and applies the correct action.

### T8 -- Network failure during a command
- Pre: T1 running.
- Action: issue a command (e.g. pause) with connectivity briefly interrupted (disable the
  host Wi-Fi for ~3 s right after the click, or point the browser at a dead port for one
  request). 
- Assert: the WebUI logs the command as unconfirmed, does NOT lock the UI, keeps the
  current preview, and recovers correct state on the next successful `/api/status` poll
  after reconnect (state matches firmware).
- Pass: graceful degradation, no stuck busy state, eventual convergence.

### T9 -- Rapid repeated clicks (idempotency / token guard)
- Pre: T1 running.
- Action: click `#scroll-pause` 5 times within 1 s; then `#scroll-step-next` 5 times fast;
  then `#scroll-stop` twice fast.
- Assert: no error toasts; final firmware state is consistent (e.g. ends paused once, not
  oscillating); `scrollFrameIndex` advanced by at most the number of accepted steps; only
  one effective stop. Stale replies are dropped (no backward index jumps).
- Pass: commands serialize cleanly; state is deterministic and consistent.

### T10 -- Saved face apply during / after scroll
- T10.1 During scroll: while running, on `#page-basic` click `#face-next`. Assert scroll
  stops and the selected saved face is applied (`playback` not a scroll value,
  `scrollFrameCount === 0`).
- T10.2 After stop: from cleared state, `#face-next`/`#face-prev` cycle saved faces;
  `mode` stays manual; no scroll residue.
- Pass: face apply is clean before/after scroll.

### T11 -- Brightness during scroll (must not interrupt scroll)
- Pre: T1 running.
- Action: on `#page-basic` adjust `#brightness-range` / click `#brightness-plus` /
  `#brightness-minus`.
- Assert: `brightness` changes in `/api/status`; scroll keeps running
  (`firmwareScrollActive` stays true, `scrollFrameIndex` keeps advancing). Brightness does
  not pause or stop scroll.
- Pass: brightness independent of scroll.

### T12 -- Battery overlay (system pause composability, fix #4)
- Pre: T1 running, then pause via user (T2.1) so `firmwareScrollUserPaused === true`.
- T12.1 Trigger overlay: on `#page-debug` click `[data-gpio="B6S"]` (battery overlay
  single-shot) or `cmd("battery_overlay",{singleShot:true})`. During overlay assert
  `firmwareScrollSystemPaused === true` and `firmwareScrollPaused === true`.
- T12.2 Overlay ends: after it finishes, assert `firmwareScrollSystemPaused === false`
  but, because the user pause is still set, `firmwareScrollUserPaused === true` and
  `firmwareScrollPaused === true` (scroll stays paused -- composable pause did not
  collapse). Resume (T2.2) then clears both.
- T12.3 Overlay while running (no user pause): from running, trigger overlay; assert
  system-pause during, and full resume to running after (`firmwareScrollPaused` back to
  false). 
- Pass: system and user pause compose; overlay end never resumes a user-paused scroll.

### T13 -- State-machine / transition guards (fix #5)
- T13.1 Start gap: during upload-then-start, observe that playback is not marked active
  until start is confirmed (no window where `playback==="scroll"` while
  `scrollUploadComplete===false`).
- T13.2 Illegal/stale events: after a stop, a late upload/start completion must not revive
  scroll (verify by rapid stop immediately after a start; final state stays stopped).
- Pass: no illegal transition revives or corrupts scroll state.

### T14 -- Regression sweep (must still work)
- T14.1 Manual face display: in manual mode, faces show and persist.
- T14.2 Auto playback: in auto mode with multiple saved faces, faces rotate at
  `autoIntervalMs`.
- T14.3 Default face after stop: stop+clear with restoreAuto -> default/startup face shows.
- T14.4 Auto-interval buttons: `[data-gpio="B3B1"]`/`[data-gpio="B3B2"]` change
  `autoIntervalMs` down/up.
- T14.5 M370 direct: `POST /api/frame` with a valid M370 renders without disturbing an
  idle scroll cache.
- T14.6 Battery telemetry: `GET /api/power` returns voltage; `#badge-battery` updates.
- Pass: all baseline features unaffected by the refactor.

---

## 4. Reporting format

For each test, the agent emits:

```
[T<id>] <name>: PASS | FAIL
  action:   <what was clicked/posted>
  expected: <field=value, ...>
  observed: <field=value, ...>   (from /api/status or /api/scroll/meta)
  note:     <timing, retries, anomalies>
```

End with a summary table (test id, status, key observed fields) and an overall verdict.
Attach the raw `/api/status` JSON captured at each assertion point for traceability.

### 4.1 Pass/fail gate
- All of T0-T7, T10-T12, T14 must PASS for a release-candidate build.
- T8, T9, T13 are robustness gates; a FAIL is a high-priority bug, not a hard blocker.
- Any FAIL in T3.3 (step latch), T4.2 (anti-drift), or T12.2 (pause composability) is a
  regression of an audit fix and must block.

---

## 5. Notes, limits, and prerequisites

- **Wi-Fi join is an OS action.** A browser tool cannot do it; use computer-use or a
  pre-joined host. The board is the AP, so the host loses internet while connected.
- **Single-threaded server.** The ESP serves one request at a time; keep concurrency low
  (no parallel floods) or expect 503/timeouts that are not bugs.
- **Preview is a canvas.** Do not assert pixels; assert firmware state + DOM text
  (`#scroll-state`, `#scroll-frame-index`) instead.
- **Frame-exact drift checks** rely on `/api/status` `scrollFrameIndex` as truth; the
  on-screen preview is a display-only tween and may differ by a frame between polls by
  design (it re-anchors on each sync) -- only a *backward* jump in the firmware index, or
  preview that diverges and never re-anchors, is a failure.
- **Physical-only items** (true GPIO presses, real battery sag) need a human or a rig; the
  Debug GPIO simulator (`data-gpio`) covers the same firmware code paths for automation.
- **Determinism:** always reset between independent tests with
  `cmd("stop_scroll",{clear:true,restoreAuto:false})` and re-verify `scrollFrameCount===0`.
- **Build/parse precheck (host-side, before flashing):** run `node --check data/app.js`
  and `pio run` locally; the WebUI must parse and the firmware must compile before any
  on-device run.
```


## 8. Serial Test Console, Logging, and GPIO Emulation

This section captures the serial-console automation plan: USB serial command parsing, structured logs, GPIO button emulation, live status dumps, host-side testing, build flags, and acceptance criteria. It is additive and must preserve normal board behavior when compiled out.

### Serial Test Console Implementation Plan

_Source: `SERIAL_TEST_CONSOLE_PLAN.md`_

Goal: make the board fully testable over the USB serial line -- emulate every GPIO button,
read detailed live data (voltage, LED frame buffer, LED commands, scroll/face/mode state),
and emit a structured serial log of every operation (button press, auto face change, scroll
events, brightness, battery, etc.). All additive: **no existing behavior changes**.

This is a plan, not yet code. It is grounded in the current source (symbols and line
numbers below are real). Each phase is an independent, revertable commit.

---

## 0. Constraints (hard requirements)

1. **Zero behavior change** when the feature is compiled out, and no logic change when
   compiled in -- serial button emulation must reuse the exact same code path as real
   GPIO/HTTP so the board behaves identically.
2. **Machine-parseable** output so an AI agent (or `pyserial` script) can drive and assert.
3. **Comment every command in the code** (the parser table doubles as documentation).
4. **Non-blocking**: the serial reader must never stall the Core-0 cooperative loop or the
   Core-1 WS2812 render task.
5. A dedicated **"Automated Testing (Serial)"** section in the repo `README.md`.

---

## 1. Current state (verified findings)

- `Serial.begin(115200)` in `setup()` (`src/main.cpp:29`). **No serial input is read
  anywhere today** (`grep` for `Serial.read/available/serialEvent` = none), so a console is
  purely additive.
- Cooperative Core-0 loop (`src/main.cpp:81-95`) already calls a tidy list of `service*()`
  functions; a `serviceSerialConsole()` call slots in with no restructuring.
- Logging exists but is sparse and ad-hoc: `LOGV(...)` macro gated by `RINACHAN_VERBOSE_LOGS`
  (default `0`) -> `Serial.printf` when on, no-op when off (`src/config.h:155-164`), plus
  scattered `Serial.println` calls.
- Button entry point is already source-tagged: `runButtonAction(const String& button,
  const String& source)` (`src/buttons.cpp:91`). Calling it with `source="serial"` reuses
  the identical action path used by `"gpio"` and `"api_button"`. Combos `B3B1`/`B3B2` are
  valid codes; battery overlay is the `battery_overlay` command.
- Data accessors already exist:
  - LED frame: `runtimeFrameBits()` (`state.h:198`), `countLitLeds()`,
    `readFrameStateSnapshot()` (`led_renderer.h:18-19`), last command in
    `runtimeState().lastReason` / `lastM370` (`state.h:30-31`), color `colorR/G/B`,
    `brightness`.
  - Power/voltage: `readPowerStatusSnapshot()` -> full `PowerStatus` (vbat, vcharge,
    batteryPercent, adcMv, charging, ...) (`power_monitor.h:48`).
  - Scroll: `scrollSessionSnapshot()` (`scroll_session.h:95`).
  - Counters: `framesAccepted/Rejected/Queued`, `commandsAccepted/Rejected` (`state.h:34-40`).
- Matrix geometry for an ASCII LED dump: `LED_COUNT=370`, `FRAME_BYTES=47`,
  `MATRIX_ROWS=18`, `ROW_LENGTHS[]`, `ROW_OFFSETS[]` (`config.h:22,81,84-96`).
- Build envs in `platformio.ini`; logging is already behind a `-D` flag pattern.

---

## 2. Architecture

Two new, self-contained modules plus thin additive hooks:

```
src/serial_log.{h,cpp}       <- structured, categorized, runtime-toggleable logger
src/serial_console.{h,cpp}   <- line-based command reader + dispatch (Core-0, non-blocking)
```

Wiring (the only edits to existing files):
- `main.cpp`: `#include "serial_console.h"`; call `initSerialConsole()` in `setup()` (after
  `Serial.begin`) and `serviceSerialConsole()` once per `loop()`.
- Event-site files get **one log line added** per event (output-only; see sec 6).
- `platformio.ini`: add feature `-D` flags to a test env (sec 10).

Dependency direction: `serial_console -> {everything it reports/drives}` (it is a leaf
consumer; nothing depends back on it). `serial_log` depends on nothing project-specific.

---

## 3. Module A -- `serial_log` (structured logging)

### 3.1 Design

- Categories (bitmask, so each can be toggled independently):
  `SYS, BTN, FACE, MODE, SCROLL, LED, PWR, NET, CMD, TEST`.
- One macro used everywhere:
  ```cpp
  // Emits: "[<ms>] <CAT> <event> k=v k=v ..."  (one line, parseable)
  RLOG(CAT, fmt, ...);
  ```
  Expands to a guarded call: `if (serialLogEnabled(CAT)) serialLogf("CAT", fmt, ...);`
- **Compile gate**: wrap the whole logger in `#if ENABLE_SERIAL_LOG`. When `0`, `RLOG`
  becomes `do {} while (0)` -- byte-for-byte the same as today's disabled `LOGV`, so a
  production build is unchanged. Keep `LOGV` working (alias it to `RLOG(SYS, ...)`).
- **Runtime control** (via console, sec 5): enable/disable categories and a global level
  (`0=off, 1=event, 2=verbose`). Default for the test env: all categories on at level 1.
- **Format contract** (so the agent can parse):
  `^\[(\d+)\] ([A-Z]+) (\S+)( (?:\w+=\S+ ?)*)$`
  - field 1 = `millis()`, field 2 = category, field 3 = event name, rest = `key=value`
    pairs. Values with spaces are quoted.

### 3.2 Thread safety (Core-0 vs Core-1)

- The Core-1 render/scroll task (`scroll.cpp`) is the only non-Core-0 writer. Logging the
  per-tick cursor advance there would (a) interleave bytes with Core-0 prints and (b) flood
  the line. Policy:
  - Core-1 logs only **rate-limited** SCROLL ticks (e.g. >=1/sec) or nothing by default;
    full per-frame logging is a level-2 opt-in.
  - Use a tiny `portMUX`/`Serial` is already mutex-internally safe on ESP32 Arduino, but to
    avoid interleaved lines, route Core-1 log requests through a lock-free single-producer
    ring buffer drained by `serviceSerialConsole()` on Core-0. (Simpler v1: Core-1 logs at
    most one line/sec directly; upgrade to the ring buffer if interleaving is observed.)

### 3.3 LED command ring buffer (for `get ledcmd`)

Add a small in-RAM ring (e.g. 16 entries) of recent LED applies:
`{ ms, reason[24], litLeds, source }`. The LED apply functions push one entry (output-only).
`get ledcmd` / `get ledcmd N` prints the last N. This gives the "LED commands" history the
request asks for without touching render logic.

---

## 4. Module B -- `serial_console` (command interface)

### 4.1 Reader (non-blocking)

```cpp
void serviceSerialConsole() {
    while (Serial.available()) {              // drain only what's buffered; never blocks
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') { if (lineLen) dispatchSerialCommand(lineBuf); lineLen = 0; }
        else if (lineLen < SERIAL_CMD_MAX) lineBuf[lineLen++] = c;
        else lineLen = 0;                     // overflow -> drop the oversized line
    }
}
```
- Fixed `char lineBuf[SERIAL_CMD_MAX]` (e.g. 192) -- no heap, no `String` growth in the hot
  path.
- One command per line; tokenized by spaces. Echo is optional (`echo on/off`).
- Every reply is single-line and prefixed: `OK <cmd> ...` / `ERR <cmd> <reason>` / for dumps
  a tagged block delimited by `=== <tag> BEGIN ===` ... `=== <tag> END ===`.

### 4.2 Dispatch table (self-documenting)

The parser is a table of `{ name, handler, "one-line help" }`. The help string IS the inline
comment required by the task, and `help` prints the table. Example skeleton:

```cpp
// Each row: command keyword, handler, and the human/agent-facing description.
// `help` prints this table; the descriptions are the authoritative command docs.
static const SerialCmd CMDS[] = {
  { "help",   cmdHelp,   "list all commands" },
  { "btn",    cmdBtn,    "btn <B1|B2|B3|B4|B5|B3B1|B3B2|B6S|B6L> : emulate a GPIO button (source=serial)" },
  { "get",    cmdGet,    "get <status|power|leds|ledcmd|scroll|faces|stats> : dump live data" },
  { "scroll", cmdScroll, "scroll <start|stop|pause|resume|step -1|+1> : drive text scroll" },
  { "set",    cmdSet,    "set <mode m|a | bright 0-255 | color #RRGGBB> : control (parity w/ buttons)" },
  { "frame",  cmdFrame,  "frame <M370> : push one frame immediately (test pattern)" },
  { "log",    cmdLog,    "log <cat on|off | all on|off | level 0-2> : control serial logging" },
  { "selftest", cmdSelfTest, "run the built-in non-destructive self-test sequence" },
  { "stats",  cmdStats,  "reset|show firmware counters" },
  { "reboot", cmdReboot, "ESP.restart() (test teardown)" },
};
```

---

## 5. Command reference (full)

| Command | Reuses | Output (parseable) | Notes |
|---|---|---|---|
| `help` | -- | command list | also the in-code docs |
| `btn <CODE>` | `runButtonAction(CODE, "serial")` | `OK btn <CODE> handled=<bool>` | CODE in B1,B2,B3,B4,B5,B3B1,B3B2; identical path to GPIO |
| `btn B6S` / `btn B6L` | `battery_overlay` cmd | `OK btn B6S` | short/long B6 = battery overlay (single-shot/long) |
| `get status` | status builder (sec 7.1) | `STATUS k=v ...` block | mode, playback, brightness, scroll*, counters |
| `get power` | `readPowerStatusSnapshot()` | `POWER vbat=.. vcharge=.. pct=.. adcMv=.. charging=..` | voltages + battery % |
| `get leds` | `runtimeFrameBits()`+geometry | ASCII matrix + `hex=<47 bytes>` + `lit=<n>` | full LED frame |
| `get ledcmd [N]` | LED ring buffer (sec 3.3) | `LEDCMD ms=.. reason=.. lit=.. src=..` xN | recent LED applies |
| `get scroll` | `scrollSessionSnapshot()` | `SCROLL active=.. paused=.. user=.. system=.. idx=.. count=.. interval=.. timeline=..` | full scroll FSM |
| `get faces` | saved-face store | `FACE i=.. id=.. name=..` list + `count=..` | library summary |
| `get stats` | `runtimeState()` counters | `STATS framesAccepted=.. ... commandsAccepted=..` | health counters |
| `scroll start` | `startFirmwareScroll()` | `OK scroll start started=<bool>` | uses cached frames |
| `scroll stop` | `stopFirmwareScroll(restoreAuto,true)` | `OK scroll stop` | clear+restore |
| `scroll pause|resume` | `scrollSessionSetUserPaused()` | `OK scroll pause paused=<bool>` | composable user pause |
| `scroll step -1|+1` | `scrollSessionStep()` | `OK scroll step idx=..` | latches pause (per recent fix) |
| `set mode m|a` | `setMode()` | `OK set mode <m/a>` | parity with B3 |
| `set bright N` | `setBrightness()` | `OK set bright <N>` | parity with B4/B5 |
| `set color #RRGGBB` | `setColor()` | `OK set color #..` | -- |
| `frame <M370>` | `applyM370(.,"serial_frame",.)` | `OK frame lit=..` / `ERR frame <why>` | test pattern push |
| `log <cat> on|off` | `serial_log` | `OK log <cat>=<state>` | cat in SYS,BTN,FACE,...,all |
| `log level <0-2>` | `serial_log` | `OK log level=<n>` | global verbosity |
| `selftest` | sec 12 | `TEST <name> PASS|FAIL ...` + `TEST DONE pass=.. fail=..` | non-destructive |
| `stats reset` | -- | `OK stats reset` | zero counters |
| `reboot` | `ESP.restart()` | `OK reboot` | -- |

All `get` dumps also echo a trailing `END` marker so a reader knows the block is complete.

---

## 6. Event log hook points (additive, one line each)

Each is a single `RLOG(...)` added at an existing event site -- no control-flow change.

| Event | File:function | Log line (example) |
|---|---|---|
| Button action (any source) | `buttons.cpp:runButtonAction` | `BTN action code=B1 src=gpio handled=1` |
| Raw press/release/repeat | `buttons.cpp:handleHardwareButton*` | `BTN press code=B3` / `BTN release code=B3` |
| Scroll-stop event mark | `scroll_session.cpp:scrollSessionMarkStoppedByButton` | `BTN scrollstop btn=B1 src=gpio seq=12` |
| Auto face change | `faces.cpp:serviceAutoPlayback` | `FACE auto idx=3/8 reason=firmware_auto_saved_face` |
| Saved-face apply | `faces.cpp:applySavedFaceIndex` | `FACE apply idx=3 id=happy reason=..` |
| Mode change | `faces.cpp:setMode` / `toggleModeFromButtonAction` | `MODE set mode=manual persist=1` |
| Scroll start/stop | `scroll_session.cpp:scrollSessionStart/Stop` | `SCROLL start count=42 interval=80` / `SCROLL stop cleared=1 restoreAuto=0` |
| Scroll pause/resume | `scroll_session.cpp:setFirmwareScrollPauseFlag` | `SCROLL pause user=1 system=0 eff=1` |
| Scroll step | `scroll_session.cpp:scrollSessionStep` | `SCROLL step idx=5 dir=+1 latchedPause=1` |
| Scroll tick (rate-limited) | `scroll_session.cpp:scrollSessionTickCursorLocked` | `SCROLL tick idx=5 (<=1/s)` |
| LED apply | `led_renderer.cpp:applyM370/applyPackedFrameImmediate/applyBlankFrame` | `LED apply reason=.. lit=120 src=..` |
| Brightness/color | `led_renderer.cpp:setBrightness/setColor` | `LED bright v=140` / `LED color #f971d4` |
| Battery event / overlay | `power_monitor.cpp` / `button_animations.cpp` | `PWR vbat=3.92 pct=74 charging=0` / `PWR overlay start` |
| Command accepted/rejected | `web_api.cpp` command dispatch | `CMD ok cmd=start_scroll` / `CMD rej cmd=.. err=..` |
| Boot milestones | `main.cpp:setup` | `SYS boot fs=ok faces=8 ip=192.168.1.14` |

Because these are behind `RLOG` (compiled out when `ENABLE_SERIAL_LOG=0`), a release build is
identical to today.

---

## 7. Data dump formats

### 7.1 `get status`
Reuse the existing snapshot sources (`scrollSessionSnapshot`, `readFrameStateSnapshot`,
`runtimeState`) and print `key=value` pairs -- NOT the web JSON builder (keep serial cheap
and avoid pulling in the HTTP doc). Same field names as `/api/status` so tooling is
consistent.

### 7.2 `get power` (voltage)
```
=== POWER BEGIN ===
POWER vbat=3.921 vcharge=4.870 pct=74 charging=0 batValid=1 adcMv=1960 calibMin=3.30 calibMax=4.20
=== POWER END ===
```

### 7.3 `get leds` (LED data)
Render the 18-row irregular matrix from `runtimeFrameBits()` using `ROW_LENGTHS/ROW_OFFSETS`:
```
=== LEDS BEGIN ===
LEDS lit=120 bright=140 color=#f971d4
ROW00 ..##....##..
ROW01 .#..#..#..#.
...
hex=00ff2a...(47 bytes)
=== LEDS END ===
```
`#` = lit, `.` = off. The `hex` line is the packed `FRAME_BYTES` buffer for exact assertions.

### 7.4 `get ledcmd` (LED commands)
Dumps the ring buffer (sec 3.3): recent `applyM370/applyPackedFrame/applyBlank` calls with
`ms`, `reason`, `lit`, `src`.

### 7.5 `get scroll`
Direct print of `scrollSessionSnapshot()` fields (active/paused/user/system/idx/count/
interval/timeline/uploadComplete/hasSourceText).

---

## 8. GPIO button emulation

`btn <CODE>` calls `runButtonAction(String(CODE), "serial")` -- the **same** function the
GPIO ISR path and the HTTP `button` command call. This guarantees identical behavior
(face cycling, scroll-stop side effects, `scrollStopEvent` recording, mode toggle, combos).
For combos that depend on simultaneous hold (`B3B1`/`B3B2`), expose them as discrete codes
(already supported) rather than trying to simulate timing. Optional `press <CODE>` /
`release <CODE>` can drive `buttons[]` state directly for hold-based tests if needed later.

`btn B6S`/`B6L` map to the `battery_overlay` command (short=single-shot, long=sustained),
matching the WebUI Debug simulator's `B6S`/`B6L`.

---

## 9. Non-invasiveness & safety

- **Compile gates**: `ENABLE_SERIAL_CONSOLE` and `ENABLE_SERIAL_LOG` (independent). Both
  default `0` in production envs; `1` in a dedicated `env:esp32s3-test`. With both `0`, the
  only residual change is two no-op calls in `loop()`/`setup()` that the compiler elides --
  effectively zero.
- **Reuse, don't fork**: every control command calls the existing function; no duplicated
  state machine, so no divergence risk.
- **Bounded, non-blocking I/O**: fixed-size line buffer, drain-only reader, no `delay()`.
- **Timing**: high-frequency events (scroll tick, render) are rate-limited or level-gated so
  logging cannot swamp the 115200 line or perturb WS2812 timing. Core-1 logging uses the
  ring-buffer drain (sec 3.2) to avoid interleaving and bus jitter.
- **No new locks** on the render hot path; `get leds` reads `runtimeFrameBits()` under the
  existing frame lock (snapshot copy), consistent with current readers.

---

## 10. Build configuration

Add a test env in `platformio.ini` (leave existing envs untouched):
```ini
[env:esp32s3-test]
extends = env:esp32s3
build_flags =
    ${env:esp32s3.build_flags}
    -D ENABLE_SERIAL_CONSOLE=1
    -D ENABLE_SERIAL_LOG=1
    -D RINACHAN_VERBOSE_LOGS=1
```
Production `env:esp32s3` stays at the current flags (feature absent). Flash test builds with
`pio run -e esp32s3-test -t upload`.

---

## 11. Phased rollout (independent commits)

- **P1 -- logger core.** Add `serial_log.{h,cpp}` + `RLOG`/category gating; alias `LOGV`.
  No hooks yet. Build clean both gate states. (Behavior-identical.)
- **P2 -- event hooks.** Insert the sec-6 `RLOG` lines at each event site. Output-only.
- **P3 -- console reader + `get*` dumps.** Add `serial_console.{h,cpp}`, wire into
  `main.cpp`, implement `help` + all read-only `get` commands + `log` control.
- **P4 -- control + emulation.** `btn`, `scroll`, `set`, `frame`, `stats`, `reboot`.
- **P5 -- selftest + README + host harness.** Built-in `selftest`, the README section
  (Appendix A), and the `pyserial` harness (sec 12).

Each phase reverts independently; P1-P2 are pure additions; P3+ are gated by
`ENABLE_SERIAL_CONSOLE`.

---

## 12. Host-side automated harness (no Wi-Fi needed)

A `tools/serial_test.py` (pyserial) opens the port at 115200, sends commands, parses the
`key=value` lines, and asserts -- a serial twin of the WebUI test plan, usable in CI on a
bench rig:

```python
# pseudo
s = serial.Serial(port, 115200, timeout=2)
def cmd(line): s.write((line+"\n").encode()); return read_block(s)
assert "handled=1" in cmd("btn B1")            # B1 cycles a face
st = parse(cmd("get scroll"))
cmd("frame <known M370>"); assert int(parse(cmd("get leds"))["lit"]) == EXPECTED
cmd("scroll pause"); assert parse(cmd("get scroll"))["paused"] == "1"
```

Self-test (`selftest`) runs a non-destructive sequence on-device and prints
`TEST <name> PASS|FAIL` lines, ending with `TEST DONE pass=N fail=M`, so an agent only needs
to send one command and read the result. Suggested coverage mirrors
`SCROLL_WEBUI_TEST_PLAN.md`: button cycle, mode toggle, scroll start/pause/step/stop,
brightness change, battery-overlay system pause, LED frame integrity -- each restoring prior
state at the end.

Tie-in: this serial path is the recommended automation when Wi-Fi join (an OS action) is not
scriptable; the WebUI plan's assertions map 1:1 onto `get status`/`get scroll`/`get power`.

---

## 13. Acceptance criteria

- Production build (`env:esp32s3`) binary behavior unchanged; diff of behavior = none.
- `env:esp32s3-test`: `help` lists all commands; every `btn`/`set`/`scroll` command produces
  the same firmware state as the equivalent GPIO/WebUI action (cross-checked via `get status`
  and `/api/status`).
- Every event in sec 6 produces exactly one parseable log line; no interleaved/garbled lines
  under load; WS2812 shows no glitch with logging on.
- `get leds` ASCII + hex matches a known test frame bit-for-bit.
- `selftest` returns deterministic PASS for all sub-tests on a healthy board.

---

## 14. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Log volume perturbs WS2812 timing | Rate-limit/level-gate high-freq logs; Core-1 via ring buffer drained on Core-0 |
| Interleaved lines from two cores | Single-producer ring buffer; Core-0 is the only `Serial` writer |
| Serial RX buffer overflow on long input | Fixed line buffer, drop oversized lines, drain-only reader |
| Feature creep into production build | Two independent compile gates, default off; only no-op calls remain |
| `get leds` racing the render task | Read under existing frame lock (snapshot copy), like current readers |
| Divergent behavior from a parallel command path | All commands reuse existing functions; no forked logic |

---

## Appendix A -- README section (ready to paste)

> The parent-repo `README.md` (`Rina-Chan-board-370-leds/README.md`) is OUTSIDE the connected
> `esp32s3_firmware` folder, so it cannot be edited from this session. Paste the block below
> under a new heading, or connect the parent folder and I will insert it.

```markdown
## Automated Testing (Serial Console)

The firmware exposes a USB-serial test console (test builds only). It lets a script or AI
agent emulate every button, drive scroll/face/mode, and read live voltage / LED / scroll
data -- no Wi-Fi required.

### Build & connect
- Flash the test build: `pio run -e esp32s3-test -t upload`
- Open the port at **115200 8N1** (e.g. `pio device monitor -b 115200`, or pyserial).
- Send `help` for the full command list.

### Output format
Every event log line is: `[<ms>] <CAT> <event> key=value ...`
Command replies are `OK <cmd> ...` / `ERR <cmd> <reason>`; data dumps are wrapped in
`=== <TAG> BEGIN ===` ... `=== <TAG> END ===`.

### Commands
| Command | Description |
|---|---|
| `help` | list all commands |
| `btn B1\|B2\|B3\|B4\|B5\|B3B1\|B3B2\|B6S\|B6L` | emulate a GPIO button (same path as hardware) |
| `get status` | full runtime state (mode, playback, brightness, scroll, counters) |
| `get power` | battery/charger voltages and percent |
| `get leds` | current LED frame as ASCII matrix + packed hex + lit count |
| `get ledcmd [N]` | recent LED command history |
| `get scroll` | scroll state machine snapshot |
| `get faces` | saved-face library summary |
| `get stats` | firmware health counters |
| `scroll start\|stop\|pause\|resume\|step -1\|+1` | drive text scroll |
| `set mode m\|a` / `set bright 0-255` / `set color #RRGGBB` | direct controls |
| `frame <M370>` | push one frame immediately |
| `log <cat> on\|off` / `log all on\|off` / `log level 0-2` | control serial logging |
| `selftest` | run the built-in non-destructive test sequence |
| `stats reset` / `reboot` | counters reset / restart |

### Logging categories
`SYS BTN FACE MODE SCROLL LED PWR NET CMD TEST` -- each toggleable via `log <cat> on|off`.
All operations (button presses, automatic face changes, scroll/pause/step, brightness,
battery events, LED applies, accepted/rejected commands) emit a log line.

### Example agent session
```
> btn B1
[12840] BTN action code=B1 src=serial handled=1
[12841] FACE apply idx=4 id=wink reason=serial_B1_next_saved_face
OK btn B1 handled=1
> get power
=== POWER BEGIN ===
POWER vbat=3.921 vcharge=0.000 pct=74 charging=0
=== POWER END ===
> selftest
TEST btn_cycle PASS
TEST scroll_pause_step PASS
TEST battery_overlay_pause PASS
TEST DONE pass=8 fail=0
```
```

---

## Appendix B -- In-code comment style for commands

The dispatch table's help strings are the canonical per-command docs (sec 4.2). In addition,
each handler gets a short block comment stating: purpose, which existing function it reuses,
expected reply, and that it is test-only/non-destructive. Example:

```cpp
// btn <CODE> -- emulate a hardware button over serial.
// Reuses runButtonAction(code, "serial"); identical to a real GPIO press, so all side
// effects (face cycle, scroll-stop + scrollStopEvent, mode toggle) are exercised.
// Reply: "OK btn <CODE> handled=<0|1>". Non-destructive (no flash writes beyond normal).
static void cmdBtn(int argc, char** argv) { ... }
```

## 9. Page 6.5 Diagnostics and Debug Console Rewrite

### Page 6.5 Debug Rewrite Plan

_Source: `PAGE_6_5_DEBUG_REWRITE_PLAN.md`_

**Status:** Plan only. No code changed. Audit before implementation.
**Target files:** `data/index.html` (`#page-debug`, currently ~lines 531–642), `data/app.js` (~10,214 lines), `data/styles.css` (~3,250 lines).
**Constraint:** Implementable with **zero firmware changes**. All data already comes from existing endpoints (`/api/status`, `/api/power`, `/api/saved_faces`, `/api/command`, `/api/frame`) and existing JS objects (`state`, `firmware`, `currentFrame`, `EXPRESSION_PARTS`, resource constants).

---

## Audit Corrections (v2 — verified against code)

This section is the **authoritative source of truth**. Where any detail below conflicts with §1–§15, this section wins. Every rule here was re-verified against `data/app.js` at the cited lines.

### Critical implementation rules (must hold)

1. **Separate debug preview buffer — do not reuse `currentFrame`.** `MATRIX_VIEW_CONFIGS` (app.js:3235) points **both** `matrix-basic` and `matrix-debug` at `() => currentFrame`, and `updateDps()` (app.js:~5172) computes from `currentFrame`. Mutating `currentFrame` for a preview would pollute the 6.1 basic preview, DPS state, copied M370, and any later "send current frame" action. Introduce:
   ```js
   let debugPreviewFrame = blankFrame();
   let debugPreviewSource = "none";   // local | firmware | saved face | M370 input | debug pattern
   let debugPreviewReason = "init";
   let debugPreviewUpdatedAt = null;
   ```
   Re-point the debug matrix at the new buffer: change `MATRIX_VIEW_CONFIGS` entry (app.js:3235) and the `initMatrix("matrix-debug", …)` call (app.js:~9814) from `() => currentFrame` to `() => debugPreviewFrame`.
   - **Preview-only** actions update **only** `debugPreviewFrame` + preview metadata, then call `renderMatrices()` to repaint `#matrix-debug` (verified: `renderMatrices()` at app.js:6515 iterates `matrixViews`, reads each `frameProvider()`, dirty-diffs, and skips hidden matrices — since `currentFrame` is untouched, `matrix-basic` will not change). They must **not** call `setCurrentFrame()`, **not** `queueFirmwareFrame()`, **not** `updateDps()` (DPS reflects firmware output, not preview), and **not** touch `currentFrame`. The `() => debugPreviewFrame` closure reads the live `let`, so reassigning `debugPreviewFrame = cloneFrame(frame)` is picked up on next repaint.
   - **Send-to-firmware** actions call the existing `setCurrentFrame(frame, reason, playback)` (which already queues), then mirror the frame into `debugPreviewFrame` and set source = `firmware`.

2. **Do not infer source from label text. Replace `getDebugValueSource(label)` with explicit per-row metadata.** Labels repeat across panels and a label alone cannot distinguish live firmware / config fallback / stale-last-known. Use a row builder:
   ```js
   buildDebugRow({ label, value, source, stale = false, note = "" })
   // source ∈ "Firmware" | "Browser" | "Resource" | "Config" | "Computed" | "Fallback"
   ```
   `renderDebugKvList(targetId, rows)` consumes these objects and renders the value + a source chip + optional stale marker. `getDebugValueSource` is **removed** from §8.

3. **AP source must be tracked, not guessed.** `state.apIp`/`state.apDomain` start as config defaults (app.js:3464 region) and are overwritten by `/api/status` inside `applyFirmwareRuntimeState` (app.js:~4582, the `data.ap?.ip` / `data.ap?.domain` block). Add explicit flags set at those exact assignment sites:
   ```js
   state.apIpSource = "Config";      // → "Firmware" when set from data.ap.ip
   state.apDomainSource = "Config";  // → "Firmware" when set from data.ap.domain
   ```
   Pass `source: state.apIpSource` (and `stale: !firmware.online`) into the Network panel rows.

4. **Render boundary — `renderState()` must not rebuild interactive debug controls.** Both `apiGet` (app.js:4210) and `apiPost` (app.js:4252) call `renderState()` *before* every request, and `syncRuntimeStateFromFirmware` (app.js:5681) calls it after full responses. If `renderState()` rebuilt the M370 textarea, raw-JSON textarea, or confirmation checkbox, every poll/command would wipe user input. Rule:
   - Interactive controls (`#debug-m370`, `#debug-raw-json`, the raw-command checkbox, log filter) are **static HTML built once**, wired in `initializeDebugControls()`, and **never** re-`innerHTML`'d by a render function.
   - `renderState()` may only call **read-out renderers** that rewrite `.kv`/badge/preview-meta containers: `renderDebugDeviceSummary`, `renderDebugFirmwareHealth`, `renderDebugPowerPanel` (readout rows only), `renderDebugNetworkPanel` (value spans only, not the input), `renderDebugResourcePanel`, `renderDebugPreviewPanel` (meta + matrix). Validation lines and result lines are written by their own action handlers, not by `renderState()`.
   - Guard: read-out renderers run only when `document.body.dataset.page === "debug"` to avoid wasted work (verified necessary — `renderState()` has **44 call sites** across the app).
   - **Shared, non-debug UI stays in `renderState()` unconditionally:** the battery/charge header badges (`#badge-battery-dot`/`#badge-battery-label`/`#badge-charging-dot`/`#badge-charging-label`, index.html:96–101, in the shared header — visible on every page) and `updateModeToggleUi()` are NOT page-gated and must continue to update on every `renderState()`. Do **not** move them into the debug-gated readouts.
   - **Hard rule:** after migration `renderState()` may call `renderDebugReadouts()` (page-gated) but must never directly rebuild an individual interactive debug panel's controls.

5. **`applySavedFace()` is a send path — do not use it for preview.** `applySavedFace(i)` (app.js:7037) sets `state.faceIndex`, calls `setCurrentFrame()` (queues a firmware frame), and re-renders saved faces. Add a pure helper and use it for preview:
   ```js
   function getSavedFaceFrame(i) {
     const face = getAllFaces()[i];
     return face ? m370ToFrame(face.m370) : blankFrame();
   }
   ```
   Preview-only → `applyDebugFrame(getSavedFaceFrame(state.faceIndex), "saved face", {send:false})`. Send → `setCurrentFrame(getSavedFaceFrame(state.faceIndex), "debug_send_saved_face", "idle")` (or keep `applySavedFace` for the send button, which is acceptable since it queues intentionally).

6. **DPS / all-on warning uses a shared, parameterized estimator.** `updateDps()` currently hardcodes `onCount(currentFrame)` against `LED_POWER_WARNING_WATTS` (=40, config `powerWarningWatts`) using `LED_ESTIMATED_WATTS_PER_CHANNEL`, `LED_CHANNEL_COUNT`, `LED_FULL_BRIGHTNESS` (app.js:~5172). Refactor the math into:
   ```js
   function estimateFrameWatts(frame, colorHex, brightness) { … same formula … }
   ```
   `updateDps()` calls it with `currentFrame`. The all-on send handler calls it with an all-on frame at current color/brightness:
   ```text
   Before sending all-on: if estimateFrameWatts(allOnFrame, state.color, state.brightness) >= LED_POWER_WARNING_WATTS,
   show a power-warning banner and require an explicit "Send all-on anyway" confirm.
   If firmware is offline, allow preview-only but block send-to-firmware with an offline error.
   ```

7. **DPS banner — resolve the duplicate-ID ambiguity.** The current single `#dps-warning` is toggled by `updateDps()` via `classList.toggle("show", …)`. Use **two distinct banner IDs** and a helper instead of a shared id:
   ```html
   <div class="warning" id="debug-summary-dps-warning">…</div>
   <div class="warning" id="debug-power-dps-warning">…</div>
   ```
   ```js
   function renderDpsWarning() {
     ["debug-summary-dps-warning","debug-power-dps-warning"].forEach(id =>
       $(id)?.classList.toggle("show", state.dpsActive));
   }
   ```
   Update `updateDps()` to call `renderDpsWarning()` instead of touching `#dps-warning`. The old `#dps-warning` element is removed.

8. **Staged migration must not create duplicate live IDs.** Preserved IDs (`#matrix-debug`, `#debug-m370`, `#log`, `#debug-refresh-power`, `#firmware-ping`, `[data-gpio]`) must appear **exactly once** in the DOM at all times — `$()` and `initMatrix` bind the first match. Therefore §12 step 3 is revised: **do not** render old and new structure simultaneously. Instead, replace `#page-debug`'s inner markup in one edit, and during the build keep the masonry functions as no-op stubs (rule 9) so no call site breaks. There is no "both visible" intermediate state.

9. **Masonry retirement — stub, then delete.** `setupDebugMasonryLayout` / `scheduleDebugMasonryLayout` (app.js:~5854) and the sizing code that `closest(".debug-measure-card")` (app.js:6375, 6483) are still referenced. Migration:
   - First make `setupDebugMasonryLayout()` and `scheduleDebugMasonryLayout()` no-op stubs (keeps `switchPage`/`renderState` call sites valid).
   - Give the new preview card (`#debug-preview-panel`) a sizing-compatible class so matrix fitting still works: include `.debug-measure-card` (or `.led-preview-card`) on the card, **or** add `#debug-preview-panel` to the two `querySelectorAll`/`closest` selectors at app.js:6375 and :6483. Do not remove `.debug-measure-card` from those selectors until `#matrix-debug`'s new wrapper carries an equivalent class.
   - Delete masonry functions and `.debug-layout`/`.debug-measure-*` CSS only in step 12, after the grid is confirmed working.

10. **Diagnostics copy — scopes + password exclusion.** `copyDebugDiagnostics(scope)` replaces `#debug-copy-status` (which copied raw `state`). Scopes:
    - `"summary"` — mode, face, brightness, color, playback, AP IP/domain (with source), battery summary.
    - `"firmware"` — `firmware` object + queue/dropped/sent counters + last request/status/error + `firmwareLastSyncAt`.
    - `"full"` — summary + firmware + power + resource metadata + debug-preview metadata.
    **Never include `DEVICE_AP_PASSWORD` in any scope.** Show the "may contain SSID/IP/domain" notice on copy.

### Useful-information improvements (adopted)

- **Diagnostic conclusion rows** in Device Summary (panel 1), above the raw value rows — derived one-line verdicts: Firmware Link (Online/Offline/Error), Output State (Showing face / Scrolling text / Paused / Unknown), Power State (Battery / Charging / Unpowered-lock / Unknown), Frame Pipeline (Local preview only / Firmware frame sent / Queue dropping — from `firmware.droppedFrames`/`droppedCommands`), Network (Firmware IP known / Config fallback — from `state.apIpSource`).
- **Per-panel "Last updated" timestamps.** Set in `applyFirmwareRuntimeState` (on success → `firmwareLastSyncAt` / `state.lastStatusSyncAt`, and AP block → `state.lastNetworkSyncAt`) and in `applyPowerData`/`refreshPowerStatusFromFirmware` (→ `state.lastPowerSyncAt`). Show on panels 1, 2, 3, 4. Without these, stale values look current.

### Offline behavior per action (authoritative table)

| Action | Offline behavior |
|---|---|
| Refresh firmware status | Allowed; shows failure + sets stale |
| Refresh power status | Allowed; shows failure |
| GPIO simulator (B1…B6+B3) | Button stays enabled. Two distinct offline cases (verified app.js:4852/5001): **(a) offline HTML mode** — `sendButtonCommand` returns a synchronous packet with no `.promise` and runs its local fallback; `sendAuxCommand` always POSTs, its `apiPost` rejects, and the `.catch` sets `lastStatus:"offline html mode"`. **(b) ordinary network failure (`firmware.online===false`)** — neither helper short-circuits; the `apiPost` promise rejects and surfaces as `command failed`. The result line must therefore handle: missing promise (offline-html button) → show "offline (local fallback)"; rejected/failed promise → show the error; resolved → success. Do not assume a clean offline short-circuit for aux commands. |
| LED preview-only | Allowed (local buffer only) |
| LED send-to-firmware | Disabled when `firmware.online === false` or `isOfflineHtmlMode()`; show offline error |
| M370 parse-preview | Allowed |
| M370 parse-send | Disabled offline |
| Raw command send | Disabled offline (already errors via `apiPost` offline path) |
| Reset battery min/max | Disabled offline — `resetBatteryVoltageRecord` already alerts and returns on `isOfflineHtmlMode()` (app.js:9817) |
| Clear user faces | Allowed (verified) — `userFaces` is browser state; `persistFaceDocuments` (app.js:7457) is offline-tolerant: it attempts local-file save and a firmware POST but `.catch`es failure, setting `savedFacesSync` to "saved locally; firmware offline" / "save failed/offline; use JSON download/import". The in-memory clear always succeeds; no live firmware write is required. |

### Corrections to specific findings

- **`syncRuntimeSummaryFromFirmware` exists** (app.js:5701; used by poller at :5732). The §7 page-enter call is valid as written — no rename or wrapper needed. (Auditor finding #1 does not apply.)
- **Reset battery min/max are Firmware-backed** (verified app.js:9817 → `reset_battery_min`/`reset_battery_max` aux commands, offline-guarded). Tag them **Firmware** in §3, not Browser.
- **`#firmware-pause` lands in panel 5 (GPIO/Button Simulator)** as a labelled "Pause scroll" command button (it is a real one-click control sending `sendAuxCommand("pause_scroll")`), with the same busy/result feedback as other simulator commands. It is **not** a health-panel control and is **not** demoted to raw-command-only.
- **Raw command examples are hardcoded safe samples** (no dynamic listing claim — firmware exposes no command-list endpoint): `{"cmd":"pause_scroll"}`, `{"cmd":"battery_overlay","singleShot":true}`, `{"cmd":"button","button":"B1"}`.

### Minor wording corrections

- Panel 2 (Firmware Health): controls "do not mutate device output; they refresh/read firmware or clear local error state" (not "mutate browser state only").
- "Refresh runtime summary only" means specifically: call `syncRuntimeSummaryFromFirmware(reason)` and let its read-out renderers update panels 1/2; do not call full `syncRuntimeStateFromFirmware` after lightweight commands.
- "Copy log" and "Copy diagnostic JSON (scopes)" are **new** conveniences, not preserved behavior.
- Log "category filter" is **optional/deferred** — current `logs[]` are plain timestamped strings (app.js:`log()`), so filtering needs either a category prefix convention or is skipped for v1.
- Clear-user-faces uses **typed confirmation** (e.g. type `CLEAR`) via `confirmDangerAction`, not a plain `confirm()`. Test must assert default-face count is unchanged after clearing.

---

## Grounding: what exists today (verified from source)

**HTML** — `#page-debug` is a `.debug-layout` masonry of 6 `.card`s:
- "主控制 / 状态信息" → `#state-kv` + `#dps-warning`
- "GPIO / 按钮辅助指令" + "LED / 协议测试" (same card) → `[data-gpio]` buttons, `#debug-all-off/-all-on/-checker/-border/-current-face`, `#debug-m370`, `#debug-apply-m370`, `#debug-copy-status`, `#debug-reset-storage`
- "状态 / ADC / 网络" → `#debug-kv`, `#debug-refresh-power`, `#debug-reset-battery-min/-max`, `#battery-v`, `#charge-v`, `#update-adc`, `#matrix-debug`
- "通信日志" → `#serial-input`, `#serial-send`, `#log-clear`, `#log-download`, `#log`
- "固件接口" → `#firmware-kv`, `#firmware-ping`, `#firmware-pause`
- "资源 / 系统" → `#resource-kv`

**JS** — one `renderState()` (app.js ~6586–6712) fills `#state-kv`, `#debug-kv`, battery/charge badges, `#resource-kv`, `#firmware-kv` in a single block, then calls `scheduleDebugMasonryLayout()`. Controls wired in `initializeDebugControls()` (~9845) and a `[data-gpio]` loop. `switchPage("debug")` (~5955) already runs `setupDebugMasonryLayout(true)` and `refreshPowerStatusFromFirmware("debug_page_enter", true)`.

**Reusable primitives already present:** `kvRows()`, `escapeHtml()`, `$()`, `setClickHandlers()`, `m370ToFrame()`, `frameToM370()`, `setCurrentFrame()`, `makePatternFrame()`, `blankFrame()`, `onCount()`, `sendButtonCommand()`, `sendAuxCommand()`, `apiPost()`/`apiGet()`, `applyFirmwareRuntimeState()`, `refreshPowerStatusFromFirmware()`, `syncRuntimeStateFromFirmware()`, `log()`/`renderLog()`, `formatVolts()`/`formatMilliVolts()`/`formatBatteryPercent()`/`batteryPowerText()`/`formatChargingState()`, `initMatrix()`.

**Reusable CSS already present:** `.card`, `.card h3/h4`, `.kv`/`.kv .k`, `.row`, `.stack`, `.control-panel`, `.badge`, `.status-dot{.dim|.warn|.danger}`, `.warning`/`.warning.show`, `button.danger`, `button:disabled`, `.hint`, `.mono`, `.matrix`/`.matrix-wrap`, `.field`.

The rewrite **reuses all of the above** and adds a small, contained set of helpers and CSS. No new visual language.

---

## 1. Executive Summary

**Why current 6.5 is hard to use.** A single `renderState()` builds five unrelated key-value blocks at once, so live device state, browser-side queue counters, raw ADC millivolts, AP credentials, hardcoded resource metadata, and protocol constants all render as visually identical `.kv` rows. Destructive "清空用户表情" sits in the same button row as harmless test patterns. The AP password is printed in plaintext by default. There is no labelling of whether a value is live firmware data, a browser-local guess, or a hardcoded constant — so a value like `当前 AP IP` looks authoritative even when it's a config fallback. Buttons give no per-action success/error feedback and can be spammed. The "LED/协议测试" group does not distinguish a local preview from a frame actually pushed to firmware. Diagnosing a single real problem (e.g. "is the board charging-detecting wrong?") means scanning the entire dump.

**What the new page accomplishes.** A purpose-ordered set of panels, most-useful-first: device summary → firmware link health → power/battery/ADC → network → button simulator → LED/M370 lab → debug preview → resources → log → raw command → danger zone. Every displayed value carries a source tag (Firmware / Browser / Resource / Config / Computed / Fallback). Read-only status is separated from state-mutating controls, which are separated again from destructive actions. M370 is validated before any send; LED tests label preview-only vs send-to-firmware; "all on" warns about power. Each command shows pending/success/error feedback and disables its button while in flight. The page stays usable and clearly "stale" when firmware is offline, and never polls full LED frames.

**What stays.** Every current data point and control is preserved (see §3 mapping) — nothing useful is deleted. Mode/face/brightness/color/playback/AP/battery summary, the GPIO simulator set, LED test patterns, M370 textarea, copy-status, firmware health counters, power/ADC values, AP info, resource metadata, communication log, raw command sender, and clear-user-faces all remain.

**What moves / becomes advanced.** Raw ADC millivolts and protection thresholds move under an "Advanced ADC details" collapsible. Resource/matrix/protocol metadata moves near the bottom (rarely needed for live diagnosis). The raw `/api/command` JSON sender moves out of the main log card into a near-bottom "Advanced Raw Command" panel behind a confirmation checkbox. The ADC simulation inputs (`#battery-v`/`#charge-v`/`#update-adc`) move into the Advanced ADC block and are clearly labelled as a browser-local simulation, not live data.

**What becomes safer.** Clear-user-faces moves to an isolated, danger-styled "Danger Zone" with typed/explicit confirmation. AP password masked by default with a show/hide toggle. Raw command requires valid JSON containing a string `cmd` plus an "I understand" checkbox. "All on" shows a power warning. All command buttons disable while busy. Copy-diagnostics/logs warn that output may contain network info (SSID/IP/domain).

---

## 2. New Panel Layout

Panel order (top → bottom). All panels are `.card` blocks inside `#page-debug`. The existing JS masonry (`setupDebugMasonryLayout`) is **replaced by a deterministic single-column-on-mobile / two-column-on-desktop CSS grid** (see §10) so panel order is predictable and "most useful first" is honoured top-to-bottom in source order.

| # | Panel | Container ID | Auto-refresh | Mutates state? |
|---|-------|--------------|--------------|----------------|
| 1 | Device Summary | `debug-device-summary` | On enter + low-rate timer (summary only) | Read-only |
| 2 | Firmware Link / API Health | `debug-firmware-health` | On enter + low-rate timer | Controls mutate (refresh/clear-error) |
| 3 | Power / Battery / ADC | `debug-power-panel` | On enter + low-rate power timer | Refresh read-only; ADC sim is browser-local |
| 4 | Network / Access Point | `debug-network-panel` | On enter | Refresh read-only; reveal toggle browser-local |
| 5 | GPIO / Button Simulator | `debug-button-simulator` | No | Sends firmware commands |
| 6 | LED Test / M370 Protocol Lab | `debug-protocol-lab` | No | Preview-only OR sends frames |
| 7 | Debug LED Preview | `debug-preview-panel` | Event-driven only | Read-only render |
| 8 | Resource / Matrix / Face Library | `debug-resource-panel` | On enter (from loaded resources) | Read-only |
| 9 | Communication Log | `debug-log-panel` | Append-on-event | Browser-local only |
| 10 | Advanced Raw Command | `debug-raw-command-panel` | Never | Sends raw `/api/command` |
| 11 | Danger Zone | `debug-danger-zone` | Never | Destructive |

### Panel detail

**1. Device Summary — `debug-device-summary`**
*Purpose:* the at-a-glance live state.
*Fields:* firmware online/offline (badge); mode Manual/Auto/Scroll/Unknown (badge); current face index `n / total`; face name; face type (`faceTypeLabel`); playback state (badge); brightness `b/255`; current color (swatch + hex); text scroll active/inactive (badge); actual FPS (`state.actualFps`); AP IP; battery percent / powered state (badge). DPS warning shown as a banner here if active.
*Controls:* none (read-only). Operational controls live on 6.1.
*Data source:* `state` (firmware-synced via `applyFirmwareRuntimeState`) + `getAllFaces()`.
*Refresh:* on page enter (`syncRuntimeSummaryFromFirmware`) + low-rate timer while page active.
*Read-only.* *Useful because:* answers "is it on, what mode, what face, what frame brightness/colour" in one glance with no noise.

**2. Firmware Link / API Health — `debug-firmware-health`**
*Purpose:* is the browser talking to firmware correctly.
*Fields:* firmware online (badge); last request (`firmware.lastRequest`); last HTTP/status result (`firmware.lastStatus`); last error (`firmware.lastError`); last successful sync time (new timestamp, see §8); sent frames (`firmware.sentFrames`); sent commands (`firmware.sentCommands`); frame queue depth (`firmware.frameQueue/WEBUI_M370_QUEUE_MAX`); button/command queue depth (`firmware.buttonQueue/WEBUI_BUTTON_COMMAND_QUEUE_MAX`); dropped frames (`firmware.droppedFrames`); dropped commands (`firmware.droppedCommands`); saved-faces sync status (`firmware.savedFacesSync`).
*Controls:* Refresh firmware status (`syncRuntimeStateFromFirmware`); Refresh power status (`refreshPowerStatusFromFirmware`); Clear local API error (resets `firmware.lastError` + `lastApiErrorLogAt`); Copy firmware/API diagnostic JSON (`copyDebugDiagnostics("firmware")`).
*Data source:* `firmware` object. **Queue/sent/dropped counters are explicitly labelled "Browser queue diagnostics"** — they are WebUI-side pump counters, not firmware counters. `online`/`lastStatus` reflect actual HTTP results.
*Refresh:* on enter + low-rate timer. No GPIO/LED actions here.
*Controls mutate browser state only (and trigger reads).* *Useful because:* shows dropped frames/commands and queue backpressure — the clearest signal the browser↔firmware link is degraded.

**3. Power / Battery / ADC — `debug-power-panel`**
*Purpose:* diagnose power/battery/charging/undervoltage/DPS.
*Subgroups:*
- *Battery State (friendly, shown first):* powered/not powered (badge); battery display text (`batteryPowerText()`); battery percent; Vbat filtered (`state.batteryV`); Vbat instant (`state.batteryLastInstantVbat`); Vbat min (`state.batteryMinV`); Vbat max (`state.batteryMaxV`).
- *Advanced ADC details (collapsible `<details>`, collapsed by default):* battery ADC raw/current (`state.batteryAdcMv`); previous battery ADC raw (`state.batteryPrevAdcMv`); charge ADC raw (`state.chargeAdcMv`); Vcharge (`state.chargeV`); charging state (`formatChargingState`); low-voltage unpowered lock (`state.batteryLowVoltageUnpowered`); unpowered low threshold (`state.batteryUnpoweredLowThreshold`); disconnect drop + threshold (`state.batteryDisconnectDropMv` / `...ThresholdMv`); disconnect low ADC threshold (`state.batteryDisconnectLowThresholdMv`); reconnect ADC threshold (`state.batteryReconnectThresholdMv`); DPS active (`state.dpsActive`); estimated power-warning state. Also hosts the **ADC simulation** inputs `#battery-v`/`#charge-v`/`#update-adc`, labelled "Browser-local ADC simulation (does not read hardware)".
*Controls:* Refresh power status (`refreshPowerStatusFromFirmware("debug_refresh_power", true)`); Reset battery min/max (`resetBatteryVoltageRecord`); ADC simulation update.
*Data source:* `/api/power` + `state.battery*`/`state.charge*`. *Refresh:* on enter + low-rate power timer.
*Rules:* friendly values first; raw/thresholds collapsed; **DPS warning shown as a banner** when `state.dpsActive`; unpowered state shown clearly via badge.
*Refresh read-only; ADC sim is explicitly browser-local.* *Useful because:* separates "what's the battery doing" (top) from calibration internals (collapsed), so wrong charge detection is visible without wading through millivolts.

**4. Network / Access Point — `debug-network-panel`**
*Fields:* AP SSID (`DEVICE_AP_SSID`); AP password (`DEVICE_AP_PASSWORD`) **masked by default** (`••••••••`); show/hide toggle; AP domain (`state.apDomain`); AP IP (`state.apIp`).
*Controls:* Network info refresh (`syncRuntimeStateFromFirmware("debug_network_refresh")`); show/hide password.
*Data source:* `state.apIp`/`state.apDomain` are **firmware-backed when `applyFirmwareRuntimeState` populated them from `/api/status` `data.ap`**, otherwise **Config fallback** (`DEFAULT_AP_IP`/`DEVICE_AP_DOMAIN`). SSID/password are **Config** constants. The source tag flips to "Firmware" only after a successful status sync set `ap.ip`/`ap.domain`.
*Refresh:* on enter only.
*Rules:* password masked by default; small warning that copied logs/diagnostics may include network info; firmware-vs-config-fallback labelled per-row.
*Refresh read-only; reveal is browser-local.* *Useful because:* confirms the AP the phone should join, and whether IP/domain are live or guessed.

**5. GPIO / Button Simulator — `debug-button-simulator`**
*Purpose:* simulate physical button input.
*Single Button Actions:* B1 next face, B2 previous face, B3 Manual/Auto toggle, B4 brightness down, B5 brightness up, B6 short battery overlay.
*Combo / Special Actions:* B3+B1 interval down, B3+B2 interval up, B6 long battery details, B6+B3 network information.
*(Existing `data-gpio` codes: `B1 B2 B3 B4 B5 B6S B6L B3B1 B3B2 B6B3`.)*
*Controls:* the buttons above, in two labelled subgroups, under a heading "Simulated hardware button input".
*Data source:* sends via `sendButtonCommand` (B1/B2/B3/B4/B5/B3B1/B3B2) or `sendAuxCommand("battery_overlay", …)` (B6S/B6L) / `syncRuntimeStateFromFirmware` (B6B3).
*Refresh:* none on timer; after each command, refresh runtime summary only.
*Rules:* visually distinct from normal user controls (muted/secondary styling + section label); per-action result line shows command sent / success|failure / last response or error / whether runtime state was refreshed; button disabled while its command is in flight (`setDebugActionBusy`); on success refresh only runtime summary fields, not heavy data.
*Mutates device state via firmware.* *Useful because:* lets you exercise real button logic without the physical board and see the exact firmware response.

**6. LED Test / M370 Protocol Lab — `debug-protocol-lab`**
*Purpose:* controlled LED/protocol tests.
*Safe LED Test Patterns:*
- Preview only: all off / checker / border / current saved face — apply to the debug preview via `applyDebugFrame(frame, source, {send:false})`, **no firmware write**.
- Send to firmware: all off / all on / checker / border / current saved face — `applyDebugFrame(frame, source, {send:true})` → `setCurrentFrame`/`queueFirmwareFrame`.
*M370 Input:* `#debug-m370` textarea; validation result line (valid/invalid, normalized length, expected length = 93, whether `M370:` prefix detected); buttons Parse to preview only / Parse and send to firmware / Clear input / Copy debug preview as M370 (`frameToM370(debugPreviewFrame)`).
*Controls:* the above. *Data source:* `debugPreviewFrame` (preview/parse) + `m370ToFrame`/`frameToM370`; send path routes through `setCurrentFrame` → existing frame queue.
*Refresh:* updates preview source label; refresh status only if needed.
*Rules:* preview-only vs send-to-firmware visually separated into two sub-blocks; **"All on" shows a power warning banner** (full matrix at current brightness/colour → DPS risk) before sending; any full-frame send shows clear feedback; M370 validated before send via `validateM370Input` — invalid input never sends and shows the exact error; accepted format `93` hex chars or `M370:<93 hex>`; preview source label set to one of `M370 input | test pattern | saved face | firmware status | local current frame`.
*Preview-only is read-only; send mutates output.* *Useful because:* lets you isolate "is it the data or the hardware" — preview the frame the browser would send, then optionally push it.

**7. Debug LED Preview — `debug-preview-panel`**
*Purpose:* show the current debug frame clearly, distinct from the 6.2 editor preview.
*Fields:* LED matrix preview (`#matrix-debug` re-pointed at `debugPreviewFrame`, same `initMatrix` scale rules as other previews); source label (`debugPreviewSource`: `local frame | firmware last frame | saved face | M370 input | debug pattern`); last update reason (`debugPreviewReason`); last update timestamp (`debugPreviewUpdatedAt`); debug preview M370 length/status (`frameToM370(debugPreviewFrame)`); optional "Copy debug preview M370" button.
*Controls:* copy debug preview M370 (optional). *Data source:* `debugPreviewFrame` (Computed) + `applyDebugFrame` metadata.
*Refresh:* event-driven only — when a local debug action changes the frame, or when `/api/status` supplies a last frame. **No full-frame polling.**
*Read-only render.* *Useful because:* shows exactly what the debug pipeline is rendering, labelled so it is never confused with the editor.

**8. Resource / Matrix / Face Library — `debug-resource-panel`**
*Purpose:* static / semi-static configuration metadata. Placed low because rarely needed live.
*Matrix / Protocol:* LED count (`TOTAL_LEDS`); matrix cols×rows (`COLS`×`ROWS`); irregular-370 layout note; M370 length (`93 hex + M370:`); physical wiring mode (`SERPENTINE_WIRING`); compose mode.
*Resource JSON:* JSON format (`EXPRESSION_PARTS.format`); version; stored unique parts; callable ids; stored group counts eye_left/eye_right/mouth; callable group count cheek.
*Face Library:* default face count (`defaultFaces.length`); user saved face count (`userFaces.length`); saved face source path (`firmware.savedFacesPath`); saved face sync status (`firmware.savedFacesSync`); parts symmetry flag (`partsSymmetry`).
*Controls:* none. *Data source:* mix of **Config/hardcoded** (matrix/protocol constants, layout notes) and **Resource-derived** (`EXPRESSION_PARTS`, face counts). Each row tagged accordingly.
*Refresh:* on enter, from already-loaded resources (no fetch).
*Read-only.* *Useful because:* confirms the board's geometry/protocol assumptions and face inventory when a face renders wrong.

**9. Communication Log — `debug-log-panel`**
*Fields:* local log display (`#log`); optional category filter (API / frame / command / saved faces / power / error).
*Controls:* Clear log (`#log-clear`), Download log (`#log-download`), Copy log (new).
*Data source:* browser-local `logs[]`. *Refresh:* appends on event; never auto-clears.
*Rules:* labelled browser-side; note that logs may contain IP/domain/SSID; **the raw `/api/command` sender is removed from this card** (moves to panel 10); scrollable, readable.
*Browser-local only.* *Useful because:* the timeline of WebUI activity for bug reports.

**10. Advanced Raw Command — `debug-raw-command-panel`**
*Purpose:* manual `/api/command` testing. Collapsed by default / near bottom.
*Fields:* JSON textarea (was `#serial-input`); example format (`{"cmd":"pause_scroll"}`); last raw command result line.
*Controls:* Validate JSON; Send raw command (disabled until "I understand this hits /api/command directly" checkbox is ticked); the existing parse/POST logic from `#serial-send`.
*Data source:* posts to `API_ENDPOINTS.command`. *Refresh:* never auto.
*Rules:* must be valid JSON; object must contain string `cmd` (existing guard); invalid never sends and shows the parse error; warning text + confirmation checkbox; styled as advanced, not a normal control.
*Mutates device state via raw firmware command.* *Useful because:* power-user escape hatch, safely gated.

**11. Danger Zone — `debug-danger-zone`**
*Purpose:* isolate destructive actions.
*Fields/Controls:* Clear user faces (was `#debug-reset-storage`); placeholder for future reset/destructive actions.
*Data source:* mutates `userFaces` + `persistFaceDocuments`. *Refresh:* never auto.
*Rules:* visually separated (danger border/heading); danger button styling (`button.danger`); confirmation via `confirmDangerAction` stating exactly what changes ("This permanently clears all user-saved faces. Default faces are not affected."); Cancel does nothing; on success refresh saved-face/resource metadata + show result.
*Destructive.* *Useful because:* keeps the one irreversible action far from everyday test buttons.

---

## 3. Field-by-Field Mapping

Type legend: **FW** firmware-backed · **BR** browser-local · **CMP** computed · **RES** resource-derived · **CFG** config/hardcoded · **DES** destructive.
Decision legend: keep · redesign · move · advanced · danger · remove.

### Main State (current `#state-kv`)
| Old label/control | Old section | New panel | Source / function | Type | Decision | Notes |
|---|---|---|---|---|---|---|
| 当前模式 | Main State | 1 Device Summary | `state.mode` via `applyFirmwareRuntimeState` | FW | redesign | Render as badge; map auto/manual/scroll/unknown |
| 当前表情序号 | Main State | 1 | `state.faceIndex`+`getAllFaces()` | FW | keep | `n / total` |
| 当前表情名称 | Main State | 1 | `getAllFaces()[idx].name` | FW/RES | keep | |
| 当前表情属性 | Main State | 1 | `faceTypeLabel(type)` | RES | keep | |
| 当前亮度 | Main State | 1 | `state.brightness` | FW | keep | `b/255` |
| 当前颜色 | Main State | 1 | `state.color` | FW | redesign | Add colour swatch |
| 当前播放状态 | Main State | 1 | `state.playback` | FW | redesign | Badge |
| 当前 AP Domain | Main State | 4 Network | `state.apDomain` | FW/CFG | move | Source tag flips on status sync |
| 当前 AP IP | Main State | 1 + 4 | `state.apIp` | FW/CFG | keep/move | Summary shows IP; full detail in panel 4 |
| 刷新策略 | Main State | 7 Preview (meta) | `state.refreshPolicy` | BR | move | Demoted from summary |
| 最近刷新原因 | Main State | 7 Preview | `state.lastRefreshReason` | BR/CMP | move | "Last update reason" |
| 刷新计数 | Main State | 2 FW Health (advanced) | `state.refreshCount` | BR | advanced | Browser counter |
| DPS warning (`#dps-warning`) | Main State | 1 + 3 banner | `state.dpsActive`/`updateDps`→`renderDpsWarning()` | CMP | redesign | Old id removed; split into `#debug-summary-dps-warning` + `#debug-power-dps-warning` (v2 rule 7) |

### GPIO / Buttons
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| B1 下一个 | 5 Simulator (Single) | `sendButtonCommand("B1")` | FW | keep | + result feedback, busy-disable |
| B2 上一个 | 5 (Single) | `sendButtonCommand("B2")` | FW | keep | |
| B3 A/M | 5 (Single) | `sendButtonCommand("B3")` | FW | keep | |
| B4 亮度- | 5 (Single) | `sendButtonCommand("B4")` | FW | keep | |
| B5 亮度+ | 5 (Single) | `sendButtonCommand("B5")` | FW | keep | |
| B6 短按电量 | 5 (Single) | `sendAuxCommand("battery_overlay",{singleShot:true})` | FW | keep | |
| B3+B1 间隔- | 5 (Combo) | `sendButtonCommand("B3B1")` | FW | keep | |
| B3+B2 间隔+ | 5 (Combo) | `sendButtonCommand("B3B2")` | FW | keep | |
| B6 长按详情 | 5 (Combo) | `sendAuxCommand("battery_overlay",{singleShot:false})` | FW | keep | |
| B6+B3 网络信息 | 5 (Combo) | `syncRuntimeStateFromFirmware` | FW | keep | |

### LED / Protocol
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| 全黑 | 6 Lab (preview + send) | `blankFrame()` | CMP | redesign | Split preview-only vs send |
| 全亮 | 6 (send, warn) | `blankFrame().map(()=>true)` | CMP | redesign | Power warning before send |
| 棋盘 | 6 (preview + send) | `makePatternFrame("checker")` | CMP | redesign | |
| 边框 | 6 (preview + send) | `makePatternFrame("border")` | CMP | redesign | |
| 当前保存表情 | 6 (preview + send) | preview: `getSavedFaceFrame(state.faceIndex)` (pure, v2 rule 5); send: `setCurrentFrame(getSavedFaceFrame(...))` or `applySavedFace` | RES/CMP | redesign | **Do NOT use `applySavedFace` for preview — it queues a frame (app.js:7041)** |
| M370 textarea `#debug-m370` | 6 (M370 Input) | `m370ToFrame` | CMP | keep | + validation line |
| 解析并应用 M370 | 6 → 2 buttons | `validateM370Input`→`applyDebugFrame` | CMP | redesign | Split parse-preview vs parse-send |
| 复制状态 JSON `#debug-copy-status` | 2 FW Health | `copyDebugDiagnostics` | BR | move | Becomes "Copy diagnostic JSON" |
| 清空用户表情 `#debug-reset-storage` | 11 Danger Zone | `confirmDangerAction`→reset | DES | danger | Isolated + explicit confirm |

### Debug Status / ADC / Network (current `#debug-kv`)
| Old label | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| LED 数量 | 8 Resource | `TOTAL_LEDS` | CFG | move | |
| 矩阵 | 8 | `COLS`×`ROWS` | CFG | move | |
| M370 长度 | 8 | const | CFG | move | |
| 亮度 raw | 1 Summary | `state.brightness` | FW | keep | Merged into brightness row |
| DPS 状态 | 3 Power (advanced) | `state.dpsActive` | CMP | keep | + banner |
| 播放状态 | 1 Summary | `state.playback` | FW | keep | Dedup with main state |
| 文字滚动 | 1 Summary | `state.textScrollActive` | FW | keep | Badge |
| 实际 FPS | 1 Summary | `state.actualFps` | FW/CMP | keep | |
| 电池状态 | 1 + 3 | `batteryPowerText()` | FW | keep | Badge in summary |
| 低压未上电锁定 | 3 (advanced) | `state.batteryLowVoltageUnpowered` | FW | advanced | |
| Vbat | 3 Battery State | `state.batteryV`/percent | FW | keep | Friendly group |
| 电池瞬时电压 | 3 Battery State | `state.batteryLastInstantVbat` | FW | keep | |
| 未上电电压阈值 | 3 (advanced) | `state.batteryUnpoweredLowThreshold` | FW/CFG | advanced | |
| 电池最低电压记录 | 3 Battery State | `state.batteryMinV` | FW | keep | |
| 电池最高电压记录 | 3 Battery State | `state.batteryMaxV` | FW | keep | |
| 电池 ADC raw | 3 (advanced) | `state.batteryAdcMv` | FW | advanced | |
| 上次电池 ADC raw | 3 (advanced) | `state.batteryPrevAdcMv` | FW | advanced | |
| 断电快速压降 | 3 (advanced) | `state.batteryDisconnectDropMv`/threshold | FW | advanced | |
| 断电低 ADC 阈值 | 3 (advanced) | `state.batteryDisconnectLowThresholdMv` | FW | advanced | |
| 恢复 ADC 阈值 | 3 (advanced) | `state.batteryReconnectThresholdMv` | FW | advanced | |
| Vcharge | 3 (advanced) | `state.chargeV`/`formatChargingState` | FW | advanced | |
| 充电 ADC raw | 3 (advanced) | `state.chargeAdcMv` | FW | advanced | |
| AP SSID | 4 Network | `DEVICE_AP_SSID` | CFG | move | |
| AP 密码 | 4 Network | `DEVICE_AP_PASSWORD` | CFG | redesign | Masked + toggle |
| AP Domain | 4 Network | `state.apDomain` | FW/CFG | move | dedup |
| AP IP | 4 Network | `state.apIp` | FW/CFG | move | dedup |
| `#battery-v`/`#charge-v`/`#update-adc` | 3 (advanced) | local sim | BR | move | Labelled "browser-local simulation" |
| `#debug-refresh-power` | 3 controls | `refreshPowerStatusFromFirmware` | FW | keep | |
| `#debug-reset-battery-min/-max` | 3 controls | `resetBatteryVoltageRecord` → `reset_battery_min`/`max` aux cmd | FW | keep | Verified firmware-backed + offline-guarded (app.js:9817) |
| `#matrix-debug` | 7 Preview | `initMatrix(...debugPreviewFrame)` | CMP | redesign | Re-parented to preview panel; frame provider re-pointed `currentFrame`→`debugPreviewFrame` (v2 rule 1) |

### Firmware Interface (current `#firmware-kv`)
| Old label | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| online | 2 FW Health + 1 Summary | `firmware.online` | FW | keep | Badge |
| lastRequest | 2 | `firmware.lastRequest` | BR/FW | keep | |
| lastStatus | 2 | `firmware.lastStatus` | FW | keep | |
| lastError | 2 | `firmware.lastError` | FW | keep | + Clear-error control |
| sentFrames | 2 | `firmware.sentFrames` | BR | keep | Label "Browser queue diag" |
| sentCommands | 2 | `firmware.sentCommands` | BR | keep | Browser counter |
| frameQueue | 2 | `firmware.frameQueue/MAX` | BR | keep | Browser counter |
| buttonQueue | 2 | `firmware.buttonQueue/MAX` | BR | keep | Browser counter |
| droppedFrames | 2 | `firmware.droppedFrames` | BR | keep | Browser counter |
| droppedCommands | 2 | `firmware.droppedCommands` | BR | keep | Browser counter |
| savedFacesSync | 2 + 8 | `firmware.savedFacesSync` | FW/BR | keep | |
| 读取固件状态 `#firmware-ping` | 2 control | `syncRuntimeStateFromFirmware` | FW | keep | "Refresh firmware status" |
| 发送暂停指令 `#firmware-pause` | 5 Simulator | `sendAuxCommand("pause_scroll")` | FW | move | Lands in panel 5 as "Pause scroll" with busy/result feedback (v2). Not a health control |

### Communication / Raw command
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| `#serial-input` | 10 Raw Command | textarea | BR | move | Renamed `debug-raw-json` |
| `#serial-send` | 10 | `apiPost(command)` w/ `cmd` guard | FW | move | Behind checkbox |
| `#log` | 9 Log | `logs[]` | BR | keep | |
| `#log-clear` | 9 | `logs=[]` | BR | keep | |
| `#log-download` | 9 | `downloadJsonFile` | BR | keep | + Copy log |

### Resource / System (current `#resource-kv`)
All move to panel 8, tagged Config or Resource:
JSON format, version, stored_unique_parts, callable_ids, eye_left/eye_right/mouth, cheek, default_faces, user_saved_faces (RES, keep) · interface_mode, face_library_json, physical_wiring, parts_compose, parts_eye_symmetry, preview_scale, basic_layout (CFG, keep — tag hardcoded). `preview_scale`/`basic_layout`/`interface_mode` are descriptive constants → keep but tag clearly as config notes.

---

## 4. Useful Information Rules

The page must, top-first, let the operator answer:
1. Is firmware online? — panel 1 + 2 online badge.
2. What mode is the board actually in? — panel 1 mode badge (firmware-synced).
3. What face/frame is shown? — panel 1 face rows + panel 7 preview with source label.
4. Is battery/charging detection wrong? — panel 3 friendly group, charging badge, advanced ADC for calibration.
5. Is AP/network info correct? — panel 4, with firmware-vs-fallback tag.
6. Can I simulate buttons safely? — panel 5 with per-action feedback + busy-disable.
7. Can I test LED output safely? — panel 6 preview-vs-send split + all-on warning.
8. Can I validate/send M370 safely? — panel 6 validation gate.
9. Are browser queues dropping data? — panel 2 dropped/queue counters.
10. Can I export logs/diagnostics for bug reports? — panel 2 copy-diagnostics, panel 9 copy/download log.

De-prioritised (moved down / collapsed / removed from summary): unlabelled internal counters; hardcoded values mixed with live values; raw ADC before human-readable power; destructive actions near normal buttons; AP password shown by default; the raw command sender in the main workflow.

**Source-of-truth labelling is mandatory:** every row renders a small source chip. Live firmware reads (FW) must never be visually identical to browser-local (BR), config (CFG), resource (RES) or computed (CMP) values.

---

## 5. UI/UX Rules

Reuse the existing system; add nothing that conflicts.
- **Card layout:** each panel is a `.card`; multi-control panels add `.stack`. New `.debug-grid` wrapper replaces `.debug-layout` masonry (deterministic order).
- **Section headings:** existing `.card h3` for panel titles; `.card h4` for subgroups (Battery State, Advanced ADC details, Single/Combo, Safe Patterns/M370 Input).
- **Key-value rows:** reuse `.kv`/`.kv .k` two-column grid via `kvRows()`/`renderDebugKvList`. Each row optionally carries a trailing source chip.
- **Badges:** reuse `.badge` + `.status-dot{.dim|.warn|.danger}` for online/offline, mode, playback, scroll, battery powered/unpowered, DPS. New helper `renderDebugBadge(value, type)` returns badge markup using these classes only.
- **Button groups:** reuse `.row` flex-wrap groups. Simulator buttons get a `.debug-sim` secondary style (muted) so they don't read as primary user controls.
- **Danger buttons:** reuse `button.danger`; Danger Zone card gets a `.debug-danger` red-tinted border.
- **Warning banners:** reuse `.warning`/`.warning.show` (already amber). New `.warning.danger` modifier (red) for all-on power warning if a stronger signal is wanted; otherwise reuse amber.
- **Collapsible advanced:** use native `<details><summary>` styled minimally (existing `summary` rule at styles.css ~347) for Advanced ADC details and Advanced Raw Command.
- **Textarea:** reuse existing `textarea` styling for `#debug-m370` and `#debug-raw-json`; keep `autoResizeTextarea` wiring.
- **Log display:** reuse `.log`/`.debug-log-card .log` scroll styling.
- **Mobile layout:** single column under existing breakpoint (~980px). Panels stack in source order so "most useful first" holds. Button groups wrap.
- **Spacing:** inherit `.card` padding (15px) + `.stack` gaps; no custom margins beyond existing.
- **Disabled/busy:** reuse `button:disabled` (opacity .42, grayscale). `setDebugActionBusy` toggles `disabled` + a `.busy` class.
- **Success/error feedback:** per-action result line uses a new `.debug-result{.ok|.err|.pending}` small text style (green/red/muted) — minimal, three colours only.

No separate design language. New CSS limited to grid, source chip, sim-button tint, danger card border, result line, and reuse of everything else.

---

## 6. Data Source Rules

Source of truth per value:
- `/api/status` (via `applyFirmwareRuntimeState`) → mode, faceIndex/name/type, brightness, color, playback, textScrollActive, actualFps, AP ip/domain, last frame. **FW**
- `/api/power` (via `refreshPowerStatusFromFirmware`/`applyPowerData`) → all `state.battery*`/`state.charge*`. **FW**
- `/api/saved_faces` / `/resources/saved_faces.json` → face library counts, `firmware.savedFacesSync`. **FW/RES**
- local `state` written only by browser actions (refreshPolicy, refreshCount, lastRefreshReason). **BR/CMP**
- local `firmware` pump counters (sent/dropped/queue). **BR**
- `currentFrame` (app-wide firmware output frame) and `debugPreviewFrame` (debug-only preview buffer) + `frameToM370`/`onCount`. Panel 7 and the M370 lab read/copy `debugPreviewFrame`; only send paths touch `currentFrame`. **CMP**
- `EXPRESSION_PARTS`, `TOTAL_LEDS`, `COLS`, `ROWS`, `SERPENTINE_WIRING`. **RES/CFG**
- `DEVICE_AP_SSID`/`DEVICE_AP_PASSWORD`/`DEFAULT_AP_IP`/`DEVICE_AP_DOMAIN`. **CFG**

Every displayed value is categorised **Firmware / Browser / Resource / Config / Computed / Unknown-Fallback** via the explicit `source` field on each `buildDebugRow({label,value,source,stale,note})` object (v2 rule 2 — never inferred from label text), rendered as the row's source chip. AP rows pass `source: state.apIpSource`/`state.apDomainSource`.

**When firmware is offline** (`firmware.online === false` or `isOfflineHtmlMode()`):
- Panels 1–4 show a "stale / last known" badge on FW rows; AP IP/domain show their Config-fallback tag.
- Do not relabel local values as live firmware. The mode/face/power rows keep their last synced value but the panel header shows an "Offline — values may be stale" notice.
- Local diagnostics (preview, M370 validation, log, queue counters, resource panel) remain fully usable.

---

## 7. Refresh Strategy

**On entering page 6.5** (extend existing `switchPage("debug")` block):
- `syncRuntimeSummaryFromFirmware("debug_page_enter")` (lightweight runtime status, already exists).
- `refreshPowerStatusFromFirmware("debug_page_enter", true)` (already called).
- Update firmware/API health from `firmware` object (no fetch).
- Update resource/face counts from already-loaded resources (no fetch).
- Do **not** force a heavy full-frame sync.

**After a GPIO/button command:** send → set button busy (`setDebugActionBusy`) → on success refresh runtime summary + show result via `showDebugActionResult` → on failure show error → do not refresh unrelated large data.

**After LED/M370 send:** validate frame → send → set preview source label → refresh status only if needed.

**On timer (only while page 6.5 active):** reuse/extend existing low-rate `firmwareStatusPollTimer`/`powerStatusPollTimer` to refresh API-health + power at their existing low rate. No full page rerender — call only the affected `renderDebug*` sub-renderers. **No LED bitmap/frame polling.**

**Never auto-refresh:** raw command panel, logs, destructive actions, AP password reveal state.

---

## 8. JavaScript Refactor Plan

Replace the debug portion of the monolithic `renderState()` with a dispatcher + per-panel renderers. `renderState()` keeps responsibility only for **non-debug** UI it still drives (mode toggle, badges shared with 6.1); its debug-only blocks (`#state-kv`, `#debug-kv`, `#resource-kv`, `#firmware-kv` population) are extracted into `renderDebugPage()` and its children, called from `renderState()` (or directly) only when `#page-debug` is active.

| Function | Purpose | Inputs | Output | DOM target | Side effects | Replaces | On failure |
|---|---|---|---|---|---|---|---|
| `renderDebugPage()` | Dispatcher; calls all panel renderers | none (reads `state`,`firmware`) | void | `#page-debug` | none | debug blocks of `renderState()` | guard each child in try/catch; never throw to caller |
| `renderDebugDeviceSummary()` | Panel 1 | `state`,`getAllFaces()` | void | `#debug-device-summary` | none | `#state-kv` block | render "—" on missing data |
| `renderDebugFirmwareHealth()` | Panel 2 | `firmware` | void | `#debug-firmware-health` | none | `#firmware-kv` block | show offline labels |
| `renderDebugPowerPanel()` | Panel 3 (+advanced) | `state.battery*`/`charge*` | void | `#debug-power-panel` | toggles DPS banner | `#debug-kv` battery rows | render "—" |
| `renderDebugNetworkPanel()` | Panel 4 | `state.apIp/apDomain`,AP consts | void | `#debug-network-panel` | respects mask flag | `#debug-kv` AP rows | Config-fallback tag |
| `renderDebugButtonSimulator()` | Panel 5 (static + result lines) | action state | void | `#debug-button-simulator` | none | `[data-gpio]` group | n/a |
| `renderDebugProtocolLab()` | Panel 6 (validation line) | `#debug-m370` value | void | `#debug-protocol-lab` | none | LED/M370 group | show validation error |
| `renderDebugPreviewPanel()` | Panel 7 meta | `debugPreviewFrame`,`debugPreviewSource`,`debugPreviewReason`,`debugPreviewUpdatedAt` | void | `#debug-preview-panel` | none | matrix-debug meta | "—" |
| `renderDebugResourcePanel()` | Panel 8 | `EXPRESSION_PARTS`,counts,consts | void | `#debug-resource-panel` | none | `#resource-kv` block | "—" |
| `renderDebugLogPanel()` | Panel 9 | `logs[]`,filter | void | `#debug-log-panel` | none | `renderLog` (debug view) | empty |
| `renderDebugRawCommandPanel()` | Panel 10 | last result | void | `#debug-raw-command-panel` | none | `#serial-*` | n/a |
| `renderDebugDangerZone()` | Panel 11 | none | void | `#debug-danger-zone` | none | reset button | n/a |
| `buildDebugKvRows()` | Build `[label,value,source]` arrays | data | rows[] | n/a | none | inline `kvRows` arrays | returns [] |
| `renderDebugKvList(target, rows)` | Render kv rows + source chips | id, rows | void | given id | sets innerHTML | extends `kvRows` | no-op if target missing |
| `renderDebugBadge(value, type)` | Badge markup | value,type | html string | n/a | none | inline badge code | "—" badge |
| `buildDebugRow({label,value,source,stale,note})` | Build one kv row with explicit source metadata (replaces label-inference; see v2 rule 2) | row spec | row object | n/a | none | (new) | renders "—" + "Unknown" source |
| `estimateFrameWatts(frame,color,brightness)` | Shared power estimate for DPS + all-on warning (v2 rule 6) | frame,hex,brightness | watts | n/a | none | inline `updateDps` math | returns 0 |
| `getSavedFaceFrame(index)` | Pure saved-face → frame, no side effects (v2 rule 5) | index | frame | n/a | none | (new) | `blankFrame()` |
| `renderDpsWarning()` | Toggle both DPS banners (v2 rule 7) | none | void | `#debug-summary-dps-warning`,`#debug-power-dps-warning` | none | `#dps-warning` toggle in `updateDps` | no-op |
| `renderDebugReadouts()` | Render-boundary wrapper: calls only read-out renderers when page active (v2 rule 4) | none | void | kv/badge/meta containers | none | debug blocks of `renderState()` | guarded |
| `setDebugActionBusy(actionId, busy)` | Toggle button busy/disabled | id,bool | void | button | disabled+`.busy` | (new) | no-op |
| `showDebugActionResult(actionId, result)` | Show ok/err/pending line | id,{ok,msg} | void | result span | sets text+class | (new) | no-op |
| `validateM370Input(text)` | Validate before send | string | {valid,normalizedLen,expectedLen:93,hadPrefix,error} | n/a | none | inline `m370ToFrame` try | returns invalid+error |
| `parseM370ToFrameOrError(text)` | Parse or structured error | string | {frame}|{error} | n/a | none | `m370ToFrame` | returns error, no throw |
| `applyDebugFrame(frame, source, options)` | Set debug preview ± send | frame,sourceLabel,{send} | void | `#matrix-debug`+preview meta | **preview-only (send=false): writes ONLY `debugPreviewFrame`+preview meta+matrix; never touches `currentFrame`/`setCurrentFrame`/`queueFirmwareFrame` (v2 rule 1)**. send=true: `setCurrentFrame(...)` then mirror into `debugPreviewFrame`, source="firmware" | (new) | guard + result line |
| `confirmDangerAction(options)` | Explicit destructive confirm | {title,body,confirmLabel} | bool | modal/`confirm` | none | inline `confirm()` | returns false |
| `copyDebugDiagnostics(scope)` | Copy diag/firmware JSON | "firmware"/"all" | void | clipboard | warns about network info | `#debug-copy-status` | toast error |

`applyDebugFrame` is the single chokepoint and the core preview/send distinction. **Per v2 rule 1, preview-only paths write ONLY the dedicated `debugPreviewFrame` buffer — never `currentFrame`** — because `matrix-basic` and `matrix-debug` both currently read `currentFrame` (app.js:3235) and `updateDps` computes from it. Send paths route through existing `setCurrentFrame` (which already queues), then mirror into `debugPreviewFrame`.

New tracking fields (browser-local): `debugPreviewFrame` (frame buffer, matrix-debug re-pointed here), `debugPreviewSource`, `debugPreviewReason`, `debugPreviewUpdatedAt`; `firmwareLastSyncAt`/`state.lastStatusSyncAt`/`state.lastNetworkSyncAt` (set in `applyFirmwareRuntimeState` on success), `state.lastPowerSyncAt` (set in power refresh); `state.apIpSource`/`state.apDomainSource` (set at the AP-assignment sites, app.js:~4582). These feed panels 1/2/3/4/7.

---

## 9. HTML Refactor Plan

New `#page-debug` body: replace `.debug-layout` masonry with `<div class="debug-grid">` containing eleven `.card` panels in the order of §2, each with the IDs:
`debug-device-summary`, `debug-firmware-health`, `debug-power-panel`, `debug-network-panel`, `debug-button-simulator`, `debug-protocol-lab`, `debug-preview-panel`, `debug-resource-panel`, `debug-log-panel`, `debug-raw-command-panel`, `debug-danger-zone`.

**Preserve these existing IDs** (JS/CSS already bind them — keep to avoid breakage):
- `#matrix-debug` — re-parent into `#debug-preview-panel`; keep the id, but **re-point its frame provider from `() => currentFrame` to `() => debugPreviewFrame`** in both `MATRIX_VIEW_CONFIGS` (app.js:3235) and the `initMatrix("matrix-debug", …)` call (app.js:~9814) per v2 rule 1. Give the new card a sizing-compatible class (v2 rule 9) so matrix fitting still works.
- `#debug-m370` — keep (validation + autoresize bindings).
- `#dps-warning` — **removed** (v2 rule 7). Replace with two distinct banners `#debug-summary-dps-warning` (panel 1) and `#debug-power-dps-warning` (panel 3); `updateDps()` calls the new `renderDpsWarning()` helper which toggles `.show` on both. No shared/ambiguous id remains.
- `#log` — keep (`renderLog`).
- `[data-gpio]` buttons — keep the attribute + codes; the existing delegated loop in `initializeDebugControls` still binds them.
- `#debug-refresh-power`, `#debug-reset-battery-min`, `#debug-reset-battery-max`, `#firmware-ping` — keep ids; move into new panels.

**Replace / rename:**
- `#state-kv`,`#debug-kv`,`#resource-kv`,`#firmware-kv` → removed; content rebuilt by panel renderers into new ids. Update `renderState()` to stop targeting them.
- `#serial-input`/`#serial-send` → `#debug-raw-json`/`#debug-raw-send` in panel 10 (update `initializeDebugControls`).
- `#debug-copy-status` → `#debug-copy-diag` in panel 2.
- `#debug-reset-storage` → `#debug-clear-user-faces` in panel 11.
- `#debug-all-off/-all-on/-checker/-border/-current-face` → split into preview + send variants (e.g. `#debug-preview-checker` / `#debug-send-checker`).
- `#battery-v`/`#charge-v`/`#update-adc` → keep ids, move into Advanced ADC `<details>`.

**Migrate event bindings safely:** all bindings live in `initializeDebugControls()` and the `[data-gpio]` loop. Update the `setClickHandlers([...])` array to the new ids in one place. Because `$()` returns null safely and `setClickHandlers` should skip missing ids, partial migration won't crash. Keep `initializeDebugControls` idempotent.

**Avoid breaking init:** `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (app.js ~5854–5912) reference `#page-debug .debug-layout` and `.debug-layout .card`. After switching to `.debug-grid`, either (a) point these at `.debug-grid` and make them no-ops (CSS grid handles layout), or (b) delete the masonry calls from `switchPage` and `renderState`. Recommended: gut the masonry to a no-op stub first (keeps call sites valid), remove later in step 12.

---

## 10. CSS / Style Plan

Reuse existing classes (§5). Add only:
- `.debug-grid` — `display:grid; gap:14px;` one column default; `@media(min-width:981px){ grid-template-columns: minmax(0,1fr) minmax(0,1fr); align-items:start; }`. Panels 1/5/6/7 may span both columns via `.debug-span-2{ grid-column:1/-1; }` where wider is clearer (summary, simulator, lab, preview).
- `.debug-source` — small inline source chip: muted, 10–11px, rounded, reuse `.badge` sizing tokens; colour variants `.src-fw/.src-br/.src-res/.src-cfg/.src-cmp/.src-fallback` (subtle tint only).
- `.debug-sim` — secondary/muted button tint so simulator buttons don't read as primary.
- `.debug-danger` — red-tinted card border for Danger Zone (reuse `button.danger` palette).
- `.debug-result{.ok|.err|.pending}` — small status text (green/red/muted).
- `details.debug-advanced > summary` — minimal disclosure styling (reuse existing `summary` rule).
- `.debug-masked` — masked password row (monospace dots).
- `.debug-validation{.ok|.err}` — M370 validation message line.
- `.debug-log` (or reuse `.debug-log-card .log`) — console block.

No new colour system; all colours pulled from existing CSS variables / existing status colours. **Do not remove `.debug-measure-card` until `#matrix-debug`'s new wrapper carries an equivalent sizing class** — matrix fitting special-cases it at app.js:6375 (`closest(".led-preview-card,.debug-measure-card")`) and :6483 (`querySelectorAll(".matrix-wrap,.led-preview-card,.debug-measure-card")`). Either keep `.debug-measure-card` on `#debug-preview-panel` or add `#debug-preview-panel`/its wrapper to those two selectors (v2 rule 9). Remove obsolete `.debug-layout`, `.debug-measure-grid`, `.debug-measure-controls` rules in step 12 once unused.

---

## 11. Safety Plan

- **All-on LED test:** before send, compute `estimateFrameWatts(allOnFrame, state.color, state.brightness)` (the shared helper refactored out of `updateDps`, v2 rule 6); if `>= LED_POWER_WARNING_WATTS` (=40) show the power-warning banner and require an explicit "Send all-on anyway" click; never auto-send; blocked entirely when offline (send path disabled).
- **Clear user faces:** Danger Zone only; `confirmDangerAction` with body "This permanently clears all user-saved faces. Default faces are not affected."; Cancel = no-op; on success refresh saved-face/resource panels + result line.
- **Raw command sender:** valid JSON required; object must include string `cmd` (existing guard kept); "I understand this hits /api/command directly" checkbox gates the send button; invalid → no send + parse error shown.
- **Invalid M370:** `validateM370Input` gates both parse-preview and parse-send; invalid never sends; exact error displayed (wrong length / bad chars / prefix note).
- **AP password visibility:** masked by default; show/hide is browser-local and never persisted; reveal state not auto-refreshed.
- **Command spam:** `setDebugActionBusy` disables the in-flight button until its promise settles; existing pump queues (`buttonCommandPump`/`frameSendPump`) still cap depth.
- **Firmware offline:** FW rows tagged stale; local diagnostics stay usable. Note only `isOfflineHtmlMode()` (file://) gives a clean short-circuit; ordinary network-down (`firmware.online===false`) surfaces as a failed `apiPost` promise — result lines must handle both (see §7 offline table). Send-to-firmware controls are disabled when `firmware.online===false || isOfflineHtmlMode()`.
- **Stale-as-live:** mandatory source chips + offline header notice prevent mistaking last-known values for live reads.
- **Sensitive logs:** copy-log / copy-diagnostics / download-log show a one-line "may contain SSID/IP/domain" notice; **`DEVICE_AP_PASSWORD` is never written into any log or any `copyDebugDiagnostics` scope** (summary/firmware/full), per v2 rule 10.

---

## 12. Implementation Migration Steps

Each step ends with a test gate; do not proceed until it passes.
1. **Snapshot** current behaviour + all IDs/handlers (this doc's grounding section). *Test:* confirm every current control still works on a baseline build.
2. **Add reusable helpers** (`renderDebugKvList`, `buildDebugRow`, `renderDebugBadge`, `estimateFrameWatts`, `getSavedFaceFrame`, `renderDpsWarning`, `setDebugActionBusy`, `showDebugActionResult`, `validateM370Input`, `parseM370ToFrameOrError`, `applyDebugFrame`, `confirmDangerAction`, `copyDebugDiagnostics`) with no UI wired yet. *Test:* unit-call each from console; no regressions on existing page.
3. **Replace `#page-debug` inner markup in one edit** with the new grid + panels, masonry stubbed to no-op (v2 rule 8 — **no "both visible" state**, to avoid duplicate live IDs like `#matrix-debug`/`#debug-m370`/`#log`). *Test:* page loads; preserved-id handlers fire; `#matrix-debug` binds the single new node.
4. **Migrate Device Summary** (panel 1) + retire `#state-kv`. *Test:* mode/face/brightness/colour/playback/scroll/battery/AP IP/FPS all correct online; "—"/stale offline.
5. **Migrate Firmware Health** (panel 2) + retire `#firmware-kv`; wire refresh/clear-error/copy-diag. *Test:* counters update; clear-error works; copy produces JSON with network-info warning.
6. **Migrate Power/Battery/ADC (panel 3) + Network (panel 4)**; move ADC sim + thresholds into advanced; mask AP password. *Test:* friendly battery rows correct; advanced collapsed; DPS banner toggles; password masked; show/hide works; firmware-vs-fallback tag correct.
7. **Migrate GPIO simulator** (panel 5) with busy-disable + result lines. *Test:* every B-code sends, shows result, disables while busy, refreshes summary on success.
8. **Migrate LED/M370 lab** (panel 6) with preview/send split + validation + all-on warning. *Test:* preview-only does not queue a frame (verify via `firmware.sentFrames` unchanged); send increments it; invalid M370 blocked; all-on warns.
9. **Migrate Debug Preview** (panel 7); re-parent `#matrix-debug`; wire source label/reason/timestamp. *Test:* matrix renders; source label matches last action; no frame polling (watch network).
10. **Migrate Resource (panel 8) + Log (panel 9)**; retire `#resource-kv`; move raw sender out of log card. *Test:* resource rows correct + tagged; log clear/download/copy work; raw sender no longer in log card.
11. **Move destructive action to Danger Zone** (panel 11) + Advanced Raw Command (panel 10). *Test:* clear-faces confirm/cancel; raw send gated by checkbox + JSON/`cmd` validation.
12. **Remove obsolete render paths/CSS** (`#state-kv`/`#debug-kv` blocks from `renderState()`, masonry functions, `.debug-layout`/`.debug-measure-*` CSS). *Test:* no console errors; no dead ids referenced; other pages unaffected.
13. **Final visual polish** (spacing, source-chip alignment, mobile stacking, span-2 panels). *Test:* desktop + mobile screenshots match WebUI style.
14. **Regression test other pages** (6.1 basic, 6.2 editor, 6.3 parts, 6.4 scroll). *Test:* `renderState()` still drives shared badges/mode toggle; matrices on all pages render; no broken bindings.

---

## 13. Manual Test Checklist

Layout/nav: desktop layout; mobile layout (<980px single column, source order preserved); switching to/from 6.5 and back; matrices fit on switch.
Firmware link: online; offline (`isOfflineHtmlMode`); `/api/status` success; `/api/status` failure (lastError + stale tags); `/api/power` success; `/api/power` failure.
Summary: current mode display (manual/auto/scroll/unknown badge); current face index/name/type; brightness + colour swatch; text scroll active badge; battery powered/unpowered badge; charging display; DPS warning banner.
Network: AP password masked by default; show/hide toggle; AP IP/domain firmware-vs-config-fallback tag.
Simulator: B1/B2/B3/B4/B5 each send + result + busy-disable; B3+B1/B3+B2; B6 short/long; B6+B3 network; result line shows success/failure + whether refreshed.
LED/M370: all-off preview (no frame queued); all-off send; all-on warning then send; checker/border preview + send; current-saved-face preview + send; valid M370 parse-preview; valid M370 parse-send; invalid M370 blocked with exact error; copy debug preview M370 (copies `debugPreviewFrame`, not `currentFrame`).
Diagnostics: copy diagnostic JSON (firmware scope) + network-info warning; queue counters (sent/dropped/frame/button) update and labelled browser-side.
Raw command: valid JSON sends; invalid JSON blocked; object without string `cmd` blocked; send disabled until checkbox ticked.
Log: clear; download; copy; (optional) category filter.
Danger: clear user faces — cancel does nothing; confirm clears user faces only, refreshes panels, shows result.
Preview isolation (v2 rule 1): after any preview-only action, confirm `matrix-basic` (page 6.1) is unchanged, `currentFrame` is unchanged, `firmware.sentFrames` is unchanged, and DPS state did not shift from the preview; only `#matrix-debug`/`debugPreviewFrame` changed.
Render boundary (v2 rule 4): type text into `#debug-m370` and `#debug-raw-json`, trigger a status/power poll (or any `apiGet`/`apiPost`), and confirm the textareas and the raw-command checkbox are NOT cleared/rebuilt.
Saved-face preview (v2 rule 5): preview "current saved face" does not increment `firmware.sentFrames`; the send variant does.
Stale/perf: stale/fallback labels when offline; per-panel "Last updated" timestamps present; no full-frame polling on timer (verify via network panel); page does not heavy-rerender on low-rate timer.

---

## 14. Risk Analysis

| Risk | Mitigation |
|---|---|
| Breaking existing event bindings | All debug bindings centralised in `initializeDebugControls` + `[data-gpio]` loop; migrate id list in one edit; `$()`/`setClickHandlers` skip missing ids so partial states don't crash |
| Changing ids used by JS | Preserve `#matrix-debug`,`#debug-m370`,`#log`,`[data-gpio]`,`#debug-refresh-power`,`#firmware-ping`; `#dps-warning` is intentionally replaced by `#debug-summary-dps-warning`+`#debug-power-dps-warning` (update `updateDps`→`renderDpsWarning` same-commit); rename others deliberately and update bindings same-commit |
| `renderState()` renders multiple debug sections | Extract debug blocks into `renderDebug*`; `renderState()` keeps only shared non-debug UI; call `renderDebugPage()` when `#page-debug` active |
| Confusing browser-local vs firmware values | Mandatory source chips via explicit `buildDebugRow({source})` metadata (never label inference); `state.apIpSource`/`apDomainSource` flags; offline header notice; distinct chip colours |
| Stale status after command | After commands refresh runtime summary; result line states whether refreshed |
| Command spam | `setDebugActionBusy` disables in-flight buttons; existing pump queues cap depth |
| Accidental destructive action | Danger Zone isolation + `confirmDangerAction` explicit body + Cancel no-op |
| AP password exposure | Masked default; reveal browser-local, never logged or in diagnostics JSON |
| Excessive firmware traffic | Reuse existing low-rate pollers; only summary+power on timer; no per-render fetches |
| LED frame sync too heavy | `applyDebugFrame` preview path never queues; no full-frame polling; send path uses existing single-frame queue |
| Inconsistent style | Reuse `.card`/`.kv`/`.badge`/`.warning`/`button.danger`; minimal additive CSS only |
| Mobile crowding | `.debug-grid` single column; collapsible advanced; span-2 only where helpful |

---

## 15. Acceptance Criteria

- [ ] 6.5 organised into the eleven clear panels in §2 order.
- [ ] Most useful diagnostics (online, mode, face/frame, battery, network) appear at the top.
- [ ] Raw ADC/thresholds, resource metadata, and raw command moved to advanced/lower sections.
- [ ] Destructive clear-user-faces isolated in a danger zone with explicit confirmation.
- [ ] AP password masked by default with show/hide.
- [ ] M370 validated before any send; invalid never sends.
- [ ] GPIO simulation gives per-action command/success/error/refreshed feedback.
- [ ] LED tests clearly distinguish preview-only from send-to-firmware; all-on warns.
- [ ] Every value tagged Firmware / Browser / Resource / Config / Computed / Fallback.
- [ ] Page works and is honestly labelled "stale" when firmware is offline.
- [ ] No full LED-frame polling; firmware traffic stays at existing low-rate poll.
- [ ] Visual style matches other WebUI pages (existing card/kv/badge/danger classes).
- [ ] All current functionality preserved or explicitly replaced (per §3 — nothing useful removed).
- [ ] Implemented with no firmware changes (only `data/index.html`, `data/app.js`, `data/styles.css`).

---

## Integration Verification Appendix (full recheck vs. current code)

Every existing hook the plan depends on was re-verified in `data/app.js` / `data/index.html` / `data/styles.css`. **Result: the plan is integrable with no firmware changes and no missing dependencies.**

### Existing functions the plan reuses (all confirmed present)
`kvRows`, `escapeHtml`, `$`, `setClickHandlers` (3646 — safely skips missing ids: only sets `onclick` when `$(id)` exists, so partial id migration cannot throw), `m370ToFrame` (4139), `frameToM370` (4125), `blankFrame` (4095), `cloneFrame`, `onCount` (4103), `makePatternFrame` (10059), `setCurrentFrame` (5159, calls `guardBeforeOutput`+`queueFirmwareFrame`), `queueFirmwareFrame` (5017), `applySavedFace` (7037, **queues** — preview must use new `getSavedFaceFrame`), `sendButtonCommand` (5001), `sendAuxCommand` (4852), `apiGet` (4210)/`apiPost` (4252) (both call `renderState()` before fetch — drives the render-boundary rule), `applyFirmwareRuntimeState` (4572, AP-assignment block ~4582 is the hook for `apIpSource`/`apDomainSource`), `applyPowerData` (4421)/`refreshPowerStatusFromFirmware` (5742) (hooks for `lastPowerSyncAt`), `syncRuntimeStateFromFirmware` (5681), `syncRuntimeSummaryFromFirmware` (5701 — **exists**), `resetBatteryVoltageRecord` (9817, firmware-backed + offline-guarded), `persistFaceDocuments` (7457, offline-tolerant), `downloadJsonFile` (7496), `log`/`renderLog` (4167/4174), `updateDps` (5172; `$("dps-warning")` toggle at 5182 → swap to `renderDpsWarning()`), `renderMatrices` (6515), `initMatrix` (6322, `frameProvider` closure), `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (5854 — stub then delete), `formatVolts`/`formatBatteryPercent`/`formatChargingState`/`batteryPowerText`/`formatMilliVolts`, `getAllFaces`/`faceTypeLabel`/`renderSavedFaces`, `updateModeToggleUi`.

### Existing constants/objects (confirmed)
`state` (3454), `firmware` (3533), `currentFrame` (let), `API_ENDPOINTS` (3229: frame/command/savedFaces/power/status), `MATRIX_VIEW_CONFIGS` (3235: `matrix-debug → () => currentFrame`, the re-point target), `EXPRESSION_PARTS`/`MATRIX`/`TOTAL_LEDS`/`COLS`/`ROWS`, `SERPENTINE_WIRING`, `DEVICE_AP_SSID`/`DEVICE_AP_PASSWORD`/`DEVICE_AP_DOMAIN`/`DEFAULT_AP_IP` (3215–3218), `WEBUI_M370_QUEUE_MAX`/`WEBUI_BUTTON_COMMAND_QUEUE_MAX` (3256/3258), `LED_POWER_WARNING_WATTS`/`LED_ESTIMATED_WATTS_PER_CHANNEL`/`LED_CHANNEL_COUNT`/`LED_FULL_BRIGHTNESS` (3208–3211, config `powerWarningWatts:40`), `firmwareStatusPollTimer`/`powerStatusPollTimer` (low-rate pollers exist), `PAGES`/`switchPage` (5921, already has a `debug` branch calling `setupDebugMasonryLayout(true)`+`refreshPowerStatusFromFirmware("debug_page_enter", true)`).

### Existing CSS classes reused (confirmed in styles.css)
`.card`/`.card h3`/`.card h4` (1213+), `.kv`/`.kv .k`, `.row`, `.stack`, `.control-panel`, `.badge` (1178), `.status-dot{.dim|.warn|.danger}` (2467+), `.warning`/`.warning.show` (1796/1807 — amber; the two new DPS banners reuse this), `button.danger` (509), `button:disabled` (opacity .42 grayscale), `.hint`, `.mono`, `.matrix`/`.matrix-wrap`, `.field`, `summary` (347). Matrix fitting special-cases `.debug-measure-card` at 6375 (`closest`) and 6483 (`querySelectorAll`) — handled by v2 rule 9.

### New code to add (none conflict with existing names)
State/buffers: `debugPreviewFrame`, `debugPreviewSource`, `debugPreviewReason`, `debugPreviewUpdatedAt`, `firmwareLastSyncAt`, `state.lastStatusSyncAt`, `state.lastPowerSyncAt`, `state.lastNetworkSyncAt`, `state.apIpSource`, `state.apDomainSource`. Functions: `renderDebugPage`/`renderDebugReadouts` + the eleven `renderDebug*` panel renderers, `buildDebugRow`, `renderDebugKvList`, `renderDebugBadge`, `estimateFrameWatts`, `getSavedFaceFrame`, `renderDpsWarning`, `setDebugActionBusy`, `showDebugActionResult`, `validateM370Input`, `parseM370ToFrameOrError`, `applyDebugFrame`, `confirmDangerAction`, `copyDebugDiagnostics`. (`getDebugValueSource` is **not** added — removed per v2 rule 2.)

### Touch points in existing functions (small, localized edits)
1. `MATRIX_VIEW_CONFIGS` (3235) + `initMatrix("matrix-debug", …)` (9814): provider `() => currentFrame` → `() => debugPreviewFrame`.
2. `updateDps` (5182): replace `$("dps-warning")` toggle with `renderDpsWarning()`; extract math into `estimateFrameWatts`.
3. `applyFirmwareRuntimeState` (~4582): set `apIpSource`/`apDomainSource`/`lastStatusSyncAt`/`firmwareLastSyncAt`/`lastNetworkSyncAt` at the existing `data.ap?.ip`/`data.ap?.domain`/success points.
4. `applyPowerData`/`refreshPowerStatusFromFirmware`: set `state.lastPowerSyncAt`.
5. `renderState`: remove the `#state-kv`/`#debug-kv`/`#resource-kv`/`#firmware-kv` blocks and the `scheduleDebugMasonryLayout()` call; keep the shared header battery/charge badge updates + `updateModeToggleUi()`; add a page-gated `renderDebugReadouts()` call.
6. `initializeDebugControls` (9845) + `[data-gpio]` loop: update the `setClickHandlers` id list to the new ids; add busy/result wrappers.
7. `switchPage` debug branch (5955): keep the page-enter refresh; replace masonry call with grid (stub masonry first).
8. `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (5854): stub to no-op, delete in step 12.

### Confirmed behavioral facts that shaped the plan
- Both `apiGet` and `apiPost` call `renderState()` **before** the request → any debug rendering reachable from `renderState()` must be page-gated and must not rebuild interactive inputs (render boundary, v2 rule 4).
- `matrix-basic` **and** `matrix-debug` both read `currentFrame` today → separate `debugPreviewFrame` is mandatory (v2 rule 1).
- `applySavedFace` and `setCurrentFrame` queue firmware frames → preview must use pure `getSavedFaceFrame` (v2 rule 5).
- `sendAuxCommand` always POSTs (no offline short-circuit); only `sendButtonCommand` short-circuits `isOfflineHtmlMode()` and only for file:// mode → result lines handle missing-promise vs rejected-promise (v2 §7 offline table).
- `persistFaceDocuments` is offline-tolerant → clear-user-faces works offline.
- Header battery/charge badges are shared across pages → stay in `renderState()`.

### Residual risks / decisions for the implementer (none blocking)
- **Log category filter** stays optional: `logs[]` are plain timestamped strings (`log()` at 4167), so filtering needs a category-prefix convention added to `log()` or is deferred to v1+1. Not required for acceptance.
- **`estimateFrameWatts` color factor:** the existing DPS math multiplies by a color factor derived from `state.color`; the all-on warning should pass `state.color` so the estimate matches `updateDps` exactly.
- **`firmware-pause` placement** is decided (panel 5). If you prefer it under Advanced Raw Command instead, that is a one-line move; either is consistent with the plan.


## 10. Font and Asset Resource Notes

### Bundled WebUI Font Resources

_Source: `data/resources/fonts/README.md`_

- `ark12.json` is the fused Ark Pixel 12px bitmap glyph table for LittleFS LED text rasterization. It keeps the original `rina_ark_pixel_font_bitmap_v1` structure and includes patched CJK glyphs such as `然 / 燃 / 滚 / 滾` plus Mona12 monochrome emoji (one 12x12 glyph per codepoint, same cell/advance as a kanji).
- `ark12.json.gz` is generated temporarily during LittleFS upload/image creation and deleted afterward. Keep edits in `ark12.json`.
- `ark12.woff2` is the single merged browser font for the text-scroll input/browser preview: Ark Pixel 12px base + fused fallback CJK glyphs + Mona12 emoji, all in one CFF webfont. No separate `ark12_fallback.woff2` exists anymore; its glyphs are merged in, and the base `@font-face` unicode-range in `styles.css` is regenerated from the merged cmap.
- Emoji glyphs are forced to the full-width kanji advance (1200/1200 em). Emoji format controls (VS15/VS16, ZWJ, skin-tone modifiers, tag characters) are zero-width.
- GNU Unifont is not stored here as `unifont.woff2`. The WebUI Unifont subset is embedded directly inside `data/styles.css` as a `data:font/woff2;base64,...` URL.
- `run_rinachan_unifont.ps1` (Windows) / `run_rinachan_unifont.sh` (macOS) validate the fused Ark12 resources before upload and copy the bundled files from `tools/font_fusion` if needed.
- To re-merge addon glyphs into both the JSON table and the webfont, use `tools/merge_mona12_emoji.py` (see its docstring; supports `--extra-addon path:prefix`).


### Font Fusion Tooling

_Source: `tools/font_fusion/README.md`_

These files are the fused Ark Pixel 12px resources used by `run_rinachan_unifont.ps1` / `run_rinachan_unifont.sh`.

- `ark12_fusion.json`: strict-format bitmap glyph table for LittleFS LED text rasterization, including patched CJK glyphs (然 / 燃 / 滚 / 滾) and Mona12 monochrome emoji.
- `ark12_base.woff2`: single merged browser font layer (Ark Pixel 12px base + fused fallback CJK glyphs + Mona12 emoji in one CFF webfont).

The previous split `ark12_fallback.woff2` layer no longer exists; its glyphs were merged into `ark12_base.woff2` and the base `@font-face` unicode-range in `data/styles.css` is generated from the merged cmap.

The upload script copies these into `data/resources/fonts` when needed and validates the target characters before upload.


## 11. Archive and Historical Notes

### Archive Notes

_Source: `archive/NOTES.md`_

本目录存放从项目根目录整理出来的**一次性字体处理脚本与中间产物**。它们：

- 不被 `platformio.ini`、构建 `extra_scripts`、`run_rinachan_unifont.ps1/.sh`、`src/`、`data/` 或 `README.md` / `plan.md` 引用；
- 不参与固件构建、LittleFS 上传或运行时；
- 仅在历史上用于字体补丁/调试，保留以备参考。

未直接删除，是为了可回滚与保留参考价值（符合“可能有用 → archive”原则）。

## font_ttx_patching/
- `ark12.ttx`（≈58MB）：Ark 字体的 TTX(XML) 转储，`patch_ttx*.py` 的输入。
- `ark12_patched.ttx`、`ark12_patched_all.ttx`（各≈55MB）：由 `patch_ttx.py` / `patch_ttx_all.py` 生成的补丁中间产物，可由脚本重新生成。
- `patch_ttx.py`、`patch_ttx_all.py`：读取 `ark12.ttx`、写出 patched TTX。脚本使用**当前工作目录相对路径**（如 `ET.parse("ark12.ttx")`），已与对应 `.ttx` 同目录存放；如需重跑请在本目录内执行。

> 提示：这三个 `.ttx` 合计约 168MB 且为可再生中间产物；若确认不再需要，可安全删除（见 plan.md 待确认事项）。

## font_dev_scripts/
- `inspect_font.py`、`inspect_font2.py`、`test_cff.py`：只读字体检查/实验脚本，硬编码读取 `./data/resources/fonts/ark12.woff2`。
- `patch_font.py`：一次性把 `./tools/font_fusion/ark12_fusion.json` 与 `./data/resources/fonts/ark12.json` 的数字字形 `dstY` 调整脚本。

> 这两组脚本里的 `./data/...`、`./tools/...` 路径是**相对项目根**的；如需重跑须从项目根目录执行，而非本归档目录。


## 12. Master Plan Maintenance Rules

- Treat this file as the durable project knowledge base for planning and implementation notes.
- When a task creates a temporary audit, refactor plan, test plan, or bug note, merge durable information back into the relevant section here.
- Keep source-specific reports only when they remain useful as working artifacts; otherwise, prefer this file as the long-term source of truth.
- Preserve hardware-specific, firmware-specific, WebUI-specific, API-specific, and test-specific details rather than compressing them into vague summaries.
- When duplicate notes disagree, keep the version confirmed by code, tests, or physical-device validation and record the decision in the relevant section.
- Do not remove known issues, TODOs, or acceptance criteria until the code and validation evidence show they are obsolete.
- Keep scroll direction language tied to visual movement, not frame-number arithmetic.
