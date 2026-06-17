# RinaChanBoard ESP32-S3 Firmware

> 基于 ESP32-S3 的 370 颗 WS2812B LED 表情板固件与离线 WebUI。设备启动后自建 Wi‑Fi 热点，通过 LittleFS 提供完整网页控制界面，并用 REST API 控制表情、颜色、亮度、自动轮播、文字滚动、电池状态和调试功能。

# 模型文件
https://makerworld.com/zh/models/2569348-rina-chan-board-rina-board-rina-chan-board#profileId-2832058

RinaChanBoard 是一个完全本地运行的 LED 表情显示系统。烧录固件与 LittleFS 后，用户只需要连接设备热点 `RinaChanBoard-V2`，打开 `http://rina.io/`，即可在手机、平板或电脑浏览器中控制 370 颗 LED。项目不依赖路由器、云服务或外部服务器；所有表情、运行设置和电池校准数据都保存在设备本地 LittleFS 中。

---

## 目录

- [1. 功能概览](#1-功能概览)
- [2. 硬件与引脚](#2-硬件与引脚)
- [3. 技术栈与系统组成](#3-技术栈与系统组成)
- [4. 快速开始](#4-快速开始)
- [5. WebUI 使用说明](#5-webui-使用说明)
- [6. 物理按钮操作](#6-物理按钮操作)
- [7. HTTP API](#7-http-api)
- [8. 数据文件与持久化](#8-数据文件与持久化)
- [9. 配置项](#9-配置项)
- [10. 项目结构](#10-项目结构)
- [11. 构建与资源流水线](#11-构建与资源流水线)
- [12. 调试与验证](#12-调试与验证)
- [13. 已知限制与开发者注意](#13-已知限制与开发者注意)
- [14. 第三方组件与许可证](#14-第三方组件与许可证)

---

## 1. 功能概览

### 1.1 核心功能

- ESP32-S3 自建 Wi‑Fi 热点，默认 SSID 为 `RinaChanBoard-V2`。
- 本地域名 `http://rina.io/`，无需外网即可访问 WebUI。
- LittleFS 内置离线 WebUI：`index.html`、`styles.css`、`app.js`、字体和资源文件。
- 370 颗 WS2812B / NeoPixel LED 控制。
- 逻辑 M370 帧格式，支持 370 bit LED 状态导入、导出和 API 控制。
- 主颜色、亮度、手动/自动模式、自动轮播间隔控制。
- 默认表情、用户自定义表情、部件组合表情统一管理。
- 自定义 LED 点阵绘制、全亮、全灭、反选、复制/导入 M370。
- 表情部件组合：左眼、右眼、嘴巴、脸颊，可随机组合并保存。
- 文字滚动：WebUI 生成滚动帧，固件缓存到 RAM/PSRAM 后独立播放。
- 文字滚动支持发送、暂停、继续、停止清屏、逐格控制和 FPS 设置。
- B1–B6 物理按钮控制表情、模式、亮度、自动间隔和电池显示。
- 电池电压、充电状态、百分比、最低/最高记录和校准数据保存。
- Debug 页面提供测试图案、状态 JSON、ADC/电源状态和日志工具。

### 1.2 运行方式

本项目不是传统的“前端 + 独立后端 + 数据库”架构。ESP32-S3 固件同时承担：

1. Wi‑Fi AP 和 DNS 服务。
2. HTTP 静态文件服务器。
3. REST API 后端。
4. LED 渲染与滚动播放任务。
5. 物理按钮扫描。
6. 电池/充电 ADC 采样。
7. LittleFS JSON 文件读写。

---

## 2. 硬件与引脚

### 2.1 默认硬件

| 项目 | 默认值 |
|---|---|
| 主控 | ESP32-S3 DevKitC / ESP32-S3-WROOM 兼容板 |
| 框架 | Arduino on PlatformIO |
| LED | 370 × WS2812B / NeoPixel |
| LED 数据脚 | `GPIO2` |
| 电池 ADC | `GPIO10` |
| 充电检测 ADC | `GPIO1` |
| 默认 PSRAM | QSPI PSRAM |
| 文件系统 | LittleFS |

### 2.2 按钮引脚

| 按钮 | GPIO | 默认行为 |
|---|---:|---|
| B1 | 17 | 下一张 saved face；滚动中按下会停止滚动并切回表情模式 |
| B2 | 16 | 上一张 saved face；滚动中按下会停止滚动并切回表情模式 |
| B3 | 15 | 松开时切换 Manual / Auto；也作为组合键修饰键 |
| B4 | 40 | 亮度降低，每次 `-8`，长按连续降低 |
| B5 | 41 | 亮度增加，每次 `+8`，长按连续增加 |
| B6 | 42 | 电池/充电状态覆盖层相关硬件入口；部分行为需要真机验证 |
| B3 + B1 | 15 + 17 | 自动轮播间隔 `-500 ms`，最小 `500 ms` |
| B3 + B2 | 15 + 16 | 自动轮播间隔 `+500 ms`，最大 `10000 ms` |

### 2.3 LED 矩阵几何

| 项目 | 值 |
|---|---|
| LED 总数 | `370` |
| 逻辑行数 | `18` |
| M370 bit 数 | `370` |
| M370 hex 长度 | `93` |
| 帧存储字节 | `(370 + 7) / 8 = 47 bytes` |
| 走线 | 蛇形 serpentine |
| 奇数行方向 | 反向 |

逻辑行长度：

```text
18, 20, 20, 20, 22, 22, 22, 22, 22,
22, 22, 22, 22, 20, 20, 20, 18, 16
```

M370 始终使用逻辑 row-major 顺序；固件在输出到 WS2812B 前负责转换到实际蛇形物理 LED 顺序。

---

## 3. 技术栈与系统组成

| 层级 | 技术 / 文件 | 说明 |
|---|---|---|
| 固件框架 | PlatformIO + Arduino | `platformio.ini` 定义 ESP32-S3 构建环境 |
| LED 驱动 | Adafruit NeoPixel | 控制 WS2812B LED 链 |
| JSON | ArduinoJson | 状态、配置、表情库和 API 请求/响应 |
| Web 后端 | Arduino `WebServer` | 固件内置 HTTP API 和静态资源服务 |
| 前端 | 原生 HTML / CSS / JS | `data/index.html`、`data/styles.css`、`data/app.js` |
| 存储 | LittleFS | 保存 WebUI、表情库、运行设置、电池校准 |
| 网络 | ESP32 SoftAP + DNS | 默认 `192.168.1.14` 和 `rina.io` |
| 任务 | FreeRTOS | Core 0 处理 Web/按钮/电源，Core 1 处理 LED 渲染/滚动 |
| 字体 | Ark Pixel + GNU Unifont subset | 文字滚动输入与 WebUI 字体显示 |

---

## 4. 快速开始

### 4.1 环境要求

- PlatformIO Core 或 PlatformIO VS Code 插件。
- Python 3.9+。
- Windows PowerShell 5+，如果使用项目内置构建脚本。
- USB 数据线和 ESP32-S3 串口驱动。

Python 依赖：

```bash
pip install pillow fonttools brotli
```

PlatformIO 依赖由 `platformio.ini` 自动安装：

- `bblanchon/ArduinoJson@^6.21.5`
- `adafruit/Adafruit NeoPixel@^1.12.3`

### 4.2 克隆项目

```bash
git clone https://github.com/yourusername/Rina-Chan-board-370-leds.git
cd Rina-Chan-board-370-leds/esp32s3_firmware
```

### 4.3 一键构建、烧录固件和上传文件系统

Windows / PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

该脚本会执行以下工作：

1. 检查 Python 依赖。
2. 生成或验证 WebUI 字体资源。
3. 生成 GNU Unifont WebUI 子集。
4. 验证 Ark Pixel 12px 字体资源。
5. 构建 PlatformIO 固件。
6. 上传固件。
7. 上传 LittleFS 文件系统。

### 4.4 仅构建

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

### 4.5 手动 PlatformIO 命令

```bash
pio run
pio run -t upload
pio run -t uploadfs
```

> 注意：只上传固件不够。WebUI、表情库、字体和 JSON 资源位于 LittleFS 中，必须执行 `pio run -t uploadfs` 或使用 `-UploadFS`。

### 4.6 连接设备

烧录完成后，连接设备热点：

| 字段 | 默认值 |
|---|---|
| Wi‑Fi SSID | `RinaChanBoard-V2` |
| Wi‑Fi 密码 | `rinachan` |
| 本地域名 | `http://rina.io/` |
| IP 地址 | `http://192.168.1.14/` |

如果浏览器缓存旧资源，可以强制刷新：

```text
http://rina.io/?v=latest
```

---

## 5. WebUI 使用说明

WebUI 共有 5 个主要页面：

| 页面 | 功能 |
|---|---|
| 6.1 Basic / 基础功能 | 颜色、亮度、表情切换、Manual/Auto、自动间隔、状态显示 |
| 6.2 Custom Face / 自定义表情 | LED 点阵绘制、M370 导入导出、保存表情 |
| 6.3 Expression Parts / 表情部件 | 左右眼、嘴巴、脸颊组合，随机生成并保存 |
| 6.4 Text Scroll / 文字滚动 | 输入文字，生成滚动帧，上传到固件 RAM 播放 |
| 6.5 Debug / 调试 | 测试图案、状态 JSON、电源 ADC、按钮模拟、日志工具 |

### 5.1 6.1 基础功能

基础页面用于日常控制：

- 选择主颜色。
- 使用预设颜色。
- 调整亮度。
- 切换上一张 / 下一张 saved face。
- 切换 Manual / Auto 模式。
- 设置自动轮播间隔。
- 查看当前 LED 预览、电池状态、连接状态和固件状态。

亮度范围：

| 项目 | 值 |
|---|---:|
| 最小亮度 | `10` |
| 默认亮度 | `50` |
| 最大亮度 | `200` |
| 按钮步进 | `8` |

自动轮播间隔：

| 项目 | 值 |
|---|---:|
| 最小 | `500 ms` |
| 默认 | `3000 ms` |
| 最大 | `10000 ms` |
| 按钮组合步进 | `500 ms` |

### 5.2 6.2 自定义表情

自定义表情页面提供一个可编辑的 370 LED 矩阵。

用户可以：

- 点击或拖动 LED 格子绘制表情。
- 清空当前画面。
- 全部点亮。
- 反选当前 LED 状态。
- 将当前画面转换为 M370。
- 粘贴 M370 并导入到编辑器。
- 复制当前 M370。
- 将当前画面保存到统一表情库。
- 对表情库中的用户表情进行改名、排序、应用和删除。

表情保存到：

```text
/resources/saved_faces.json
```

### 5.3 6.3 表情部件

表情部件页面用于通过已有部件快速组合表情。

可选部件类型：

- 左眼。
- 右眼。
- 嘴巴。
- 脸颊。

支持操作：

- 应用当前部件组合。
- 随机生成组合。
- 恢复默认组合。
- 开启/关闭左右眼对称。
- 导出组合后的 M370。
- 保存为 saved face。

固件后端不保存“眼睛/嘴巴”等语义结构；前端会先组合成完整 370 bit frame，再通过 `/api/frame` 发送最终 M370。

### 5.4 6.4 文字滚动

文字滚动流程：

1. 用户输入文字。
2. WebUI 使用 Ark Pixel 12px bitmap 字体生成 LED 滚动帧。
3. WebUI 将多帧 M370 分块上传到 `/api/scroll`。
4. 固件将帧序列缓存到 RAM/PSRAM。
5. 固件 Core 1 渲染任务独立播放滚动动画。
6. WebUI 只同步状态和帧序号，不逐帧推送硬件。

支持控制：

- 发送。
- 暂停。
- 继续。
- 停止 / 清屏。
- 逐格前进。
- FPS 设置和预设。

文字滚动限制：

| 项目 | 默认 / 限制 |
|---|---:|
| 最大输入长度 | `1000` 字符 |
| FPS 范围 | `1..60` |
| 默认滚动间隔 | `100 ms` |
| 最小滚动间隔 | `33 ms` |
| 最大滚动间隔 | `1000 ms` |
| 最大缓存帧数 | `3072` |
| 存储位置 | RAM / PSRAM |
| 是否写入 flash | 否 |

固件会拒绝将滚动帧持久化到 flash。滚动帧属于运行时缓存，断电后消失。

### 5.5 6.5 调试

调试页面用于开发和硬件验证。

主要功能：

- 刷新 `/api/status`。
- 刷新 `/api/power`。
- 复制状态 JSON。
- 下载或清空通信日志。
- 发送全灭、全亮、棋盘、边框测试图案。
- 应用当前表情。
- 粘贴并应用 M370。
- 模拟部分按钮命令。
- 重置电池最低/最高记录。
- 查看 ADC、电池、充电、网络和系统状态。

> 开发者注意：Debug 页面中的部分高级命令可能依赖当前固件命令表。若某个调试按钮返回 `unknown command`，应以 `src/web_api.cpp` 中实际注册的 `/api/command` 命令为准。

---

## 6. 物理按钮操作

### 6.1 单键操作

| 操作 | 行为 |
|---|---|
| B1 短按 | 下一张 saved face |
| B2 短按 | 上一张 saved face |
| B3 松开 | 切换 Manual / Auto |
| B4 短按 | 亮度降低 8 |
| B5 短按 | 亮度增加 8 |
| B6 短按 | 电池/充电覆盖层相关行为，需硬件验证 |

### 6.2 长按操作

| 操作 | 行为 |
|---|---|
| B1 长按 | 连续下一张表情 |
| B2 长按 | 连续上一张表情 |
| B4 长按 | 连续降低亮度 |
| B5 长按 | 连续增加亮度 |

默认长按参数：

| 项目 | 值 |
|---|---:|
| B1/B2 长按触发 | `650 ms` 后开始 |
| B1/B2 连发间隔 | `350 ms` |
| B4/B5 长按触发 | `450 ms` 后开始 |
| B4/B5 连发间隔 | `120 ms` |

### 6.3 组合键

| 操作 | 行为 |
|---|---|
| B3 + B1 | 自动轮播间隔减少 `500 ms` |
| B3 + B2 | 自动轮播间隔增加 `500 ms` |

### 6.4 滚动播放中的按钮行为

当文字滚动正在播放时：

- B1/B2/B3 会中断滚动。
- 固件会通知 WebUI 滚动已被硬件按钮停止。
- WebUI 应停止本地滚动预览并显示当前表情状态。

---

## 7. HTTP API

所有 API 默认通过以下地址访问：

```text
http://rina.io/
http://192.168.1.14/
```

### 7.1 Endpoint 总览

| 方法 | Endpoint | 用途 |
|---|---|---|
| GET | `/` | WebUI 根页面 |
| GET | `/index.html` | WebUI 页面 |
| GET | `/api/status` | 获取运行状态、矩阵、存储、内存、电源和统计信息 |
| GET | `/api/power` | 获取电池和充电状态 |
| POST | `/api/frame` | 应用单帧 M370 |
| POST | `/api/scroll` | 上传滚动帧序列并可启动播放 |
| POST | `/api/command` | 执行控制命令 |
| GET | `/api/saved_faces` | 读取 saved face 表情库 |
| POST | `/api/saved_faces` | 校验并替换 saved face 表情库 |
| OPTIONS | API endpoints | CORS preflight |

### 7.2 `GET /api/status`

读取设备运行状态。

可选查询参数：

| 参数 | 作用 |
|---|---|
| `runtimeOnly=1` | 只返回轻量运行态 |
| `summary=1` | 跳过较重的 frame/storage 序列化 |
| `noFrame=1` | 不返回当前 `lastM370` |
| `since=<version>` | 若状态版本未变，返回 `unchanged: true` |
| `fullPower=1` | 返回更完整的电源状态 |

典型返回内容：

- `ap`：SSID、IP、domain、客户端数量。
- `power`：电池、充电和校准状态。
- `renderer`：颜色、亮度、模式、滚动状态、当前表情。
- `memory`：heap、PSRAM、scroll buffer。
- `matrix`：LED 几何和 M370 格式。
- `storage`：LittleFS 挂载、容量和文件路径。
- `stats`：frame、command、settings、saved faces 计数。

### 7.3 `POST /api/frame`

应用一个 M370 frame。

请求示例：

```json
{
  "m370": "M370:<93 hex>",
  "reason": "api_frame",
  "playback": "idle",
  "faceId": "face_01_surprised_winking_with_mouth"
}
```

字段说明：

| 字段 | 必填 | 说明 |
|---|---|---|
| `m370` | 是 | `M370:` + 93 个 hex 字符 |
| `reason` | 否 | 调用来源，例如 `custom_editor`、`parts_apply`、`debug_pattern` |
| `playback` / `mode` | 否 | 运行态标记 |
| `faceId` | 否 | 若匹配 saved face，会同步当前 auto face index |

行为：

- 应用单帧 M370。
- 非 scroll 来源通常会停止当前滚动播放。
- 返回当前颜色、亮度、队列状态、点亮 LED 数和当前 M370。

### 7.4 `POST /api/scroll`

上传文字滚动帧序列到固件 RAM/PSRAM。

请求示例：

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
  "source": "webui_text_scroll",
  "storage": "ram",
  "persist": false,
  "saveToFlash": false
}
```

支持字段：

| 字段 | 说明 |
|---|---|
| `frames` | M370 字符串数组 |
| `intervalMs` | 每帧间隔，单位 ms |
| `fps` | 替代 `intervalMs` 的速度输入 |
| `append` | 是否追加到已有缓存 |
| `start` | 上传后是否启动播放 |
| `chunkIndex` | 当前分块序号 |
| `totalFrames` | 总帧数 |
| `source` | 来源标记 |
| `storage` | 当前只支持 `ram` |

会被拒绝的行为：

- `persist: true`
- `saveToFlash: true`
- `storage` 不为 `ram`
- 总帧数超过 `MAX_SCROLL_FRAMES`
- 任意 frame 的 M370 格式无效

### 7.5 `POST /api/command`

通用命令格式：

```json
{
  "cmd": "set_brightness",
  "payload": {
    "raw": 80
  }
}
```

支持命令：

| 命令 | Payload | 说明 |
|---|---|---|
| `set_color` | `{ "hex": "#f971d4" }` | 设置主颜色 |
| `set_brightness` | `{ "raw": 50 }` 或 `{ "brightness": 50 }` | 设置亮度 |
| `set_mode` | `{ "mode": "manual" }` / `{ "mode": "auto" }` | 设置 M/A 模式 |
| `set_auto_interval` | `{ "ms": 3000 }` | 设置自动轮播间隔 |
| `set_scroll_interval` | `{ "intervalMs": 100 }` 或 `{ "fps": 10 }` | 设置滚动速度 |
| `start_scroll` | 可选 `{ "intervalMs": 100 }` / `{ "fps": 10 }` | 启动已缓存滚动帧 |
| `scroll_step` | `{}` | 滚动逐格前进 |
| `pause_scroll` | `{}` | 暂停滚动 |
| `resume_scroll` | `{}` | 继续滚动 |
| `stop_scroll` | `{ "clear": true, "restoreAuto": true }` | 停止滚动，可清屏/恢复自动模式 |
| `pause` | `{}` | 通用暂停 |
| `resume` | `{}` | 通用恢复 |
| `button` | `{ "button": "B1" }` | 模拟部分物理按钮 |
| `terminate_other_activities` | `{ "targetMode": "face" }` 等 | 切换工作流前终止其他活动 |
| `reset_battery_min` | `{}` | 重置电池最低记录 |
| `reset_battery_max` | `{}` | 重置电池最高记录 |

### 7.6 `GET /api/power`

获取电池与充电状态。返回信息包括：

- 电池电压。
- 电池百分比。
- 是否检测到电池。
- 是否检测到充电输入。
- ADC 原始/处理状态。
- 校准最高/最低记录。

### 7.7 `GET /api/saved_faces`

读取当前表情库文件：

```text
/resources/saved_faces.json
```

### 7.8 `POST /api/saved_faces`

替换 saved face 表情库。

支持两种 body：

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

或直接提交 saved face document。

固件会校验：

- `format`。
- `version`。
- `matrix` 元数据。
- `faces` 数组。
- 每个 face 的 M370 格式。
- default/custom/parts 类型约束。
- 默认表情保留规则。
- startup default 元数据。

---

## 8. 数据文件与持久化

### 8.1 LittleFS 文件

| 路径 | 用途 |
|---|---|
| `/index.html` | WebUI HTML |
| `/app.js` | WebUI 主逻辑 |
| `/styles.css` | WebUI 样式 |
| `/resources/saved_faces.json` | 统一表情库 |
| `/resources/runtime_settings.json` | Manual/Auto 模式和自动间隔 |
| `/resources/battery_calib.json` | 电池最低/最高校准记录 |
| `/resources/loading/rina_icon1_default.png` | 加载页默认图标 |
| `/resources/loading/rina_icon2_hover.png` | 加载页 hover/结束图标 |
| `/resources/fonts/ark12.woff2` | Ark Pixel 浏览器字体 |
| `/resources/fonts/ark12_fallback.woff2` | Ark Pixel fallback 字体 |
| `/resources/fonts/ark12.json` | LED 文字滚动 bitmap glyph 表 |

### 8.2 saved_faces.json

表情库格式：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "...",
  "matrix": {
    "ledCount": 370
  },
  "startupDefaultId": "...",
  "updatedAt": "...",
  "faces": []
}
```

单个 face 示例：

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
  "is_startup_default": false
}
```

face 类型：

| 类型 | 说明 |
|---|---|
| `default` | 出厂/内置表情；通常不可删除 |
| `custom` | 用户在 6.2 自定义点阵中保存的表情 |
| `parts` | 用户在 6.3 表情部件中组合保存的表情 |

### 8.3 runtime_settings.json

保存运行设置：

```json
{
  "mode": "manual",
  "autoIntervalMs": 3000
}
```

### 8.4 battery_calib.json

保存电池学习/校准数据，例如：

```json
{
  "v_min": 6.2,
  "v_max": 8.4,
  "updatedAt": 0
}
```

实际字段以固件版本输出为准。

---

## 9. 配置项

主要配置位于：

```text
src/config.h
platformio.ini
partitions.csv
```

### 9.1 网络配置

| 常量 | 默认值 |
|---|---|
| `AP_SSID` | `RinaChanBoard-V2` |
| `AP_PASSWORD` | `rinachan` |
| `AP_DOMAIN` | `rina.io` |
| `AP_IP_ADDR` | `192.168.1.14` |
| `AP_GATEWAY_ADDR` | `192.168.1.14` |
| `AP_SUBNET_MASK` | `255.255.255.0` |

### 9.2 LED 与显示配置

| 常量 | 默认值 |
|---|---:|
| `LED_PIN` | `2` |
| `LED_COUNT` | `370` |
| `M370_HEX_CHARS` | `93` |
| `M370_BITS` | `370` |
| `MATRIX_ROWS` | `18` |
| `SERPENTINE_WIRING` | `true` |
| `SERPENTINE_ODD_ROWS_REVERSED` | `true` |
| `LED_RENDER_TASK_CORE` | `1` |

### 9.3 亮度与颜色

| 常量 | 默认值 |
|---|---:|
| `DEFAULT_BRIGHTNESS` | `50` |
| `MIN_BRIGHTNESS` | `10` |
| `MAX_BRIGHTNESS` | `200` |
| `BRIGHTNESS_BUTTON_STEP` | `8` |
| `DEFAULT_COLOR` | `#f971d4` |

### 9.4 自动轮播

| 常量 | 默认值 |
|---|---:|
| `DEFAULT_MODE` | `manual` |
| `DEFAULT_AUTO_INTERVAL_MS` | `3000` |
| `MIN_AUTO_INTERVAL_MS` | `500` |
| `MAX_AUTO_INTERVAL_MS` | `10000` |
| `AUTO_INTERVAL_BUTTON_STEP_MS` | `500` |
| `MAX_AUTO_FACES` | `128` |

### 9.5 文字滚动

| 常量 | 默认值 |
|---|---:|
| `MAX_SCROLL_FRAMES` | `3072` |
| `DEFAULT_SCROLL_INTERVAL_MS` | `100` |
| `MIN_SCROLL_INTERVAL_MS` | `33` |
| `MAX_SCROLL_INTERVAL_MS` | `1000` |

### 9.6 PlatformIO PSRAM 配置

默认 QSPI PSRAM：

```ini
board_build.psram_type = qspi
board_build.arduino.memory_type = qio_qspi
```

如果使用 OPI PSRAM 模块，可改为：

```ini
board_build.psram_type = opi
board_build.arduino.memory_type = qio_opi
```

### 9.7 分区配置

`partitions.csv` 当前关闭 OTA，保留一个 factory app 和较大的 LittleFS：

| 分区 | 类型 | 大小 | 说明 |
|---|---|---:|---|
| `nvs` | data/nvs | `0x5000` | NVS |
| `otadata` | data/ota | `0x2000` | OTA 元数据占位 |
| `app0` | app/factory | `0x200000` | 固件 |
| `littlefs` | data/spiffs | `0x5F0000` | WebUI、字体、JSON 资源 |

---

## 10. 项目结构

```text
esp32s3_firmware/
├─ data/                         # LittleFS WebUI 与资源
│  ├─ index.html                  # WebUI DOM 结构
│  ├─ app.js                      # WebUI 状态、API、页面逻辑
│  ├─ styles.css                  # WebUI 样式
│  └─ resources/                  # 表情库、运行设置、电池校准、字体、图片
├─ src/                          # 固件源码
│  ├─ main.cpp                    # setup 和主 loop
│  ├─ config.*                    # 引脚、常量、矩阵几何、默认值
│  ├─ web_api.*                   # AP、DNS、WebServer、REST API、静态文件服务
│  ├─ led_renderer.*              # M370 解析、LED 映射、NeoPixel 输出
│  ├─ scroll.*                    # Core 1 滚动/渲染任务
│  ├─ faces.*                     # saved face、manual/auto、滚动恢复
│  ├─ buttons.*                   # 按钮扫描、消抖、长按、组合键
│  ├─ button_animations.*         # 按钮触发的覆盖层/动画
│  ├─ power_monitor.*             # 电池与充电 ADC 采样、百分比、校准
│  ├─ storage.*                   # LittleFS、settings、saved_faces 读写校验
│  ├─ state.*                     # 全局运行状态、buffer、计数器
│  ├─ sync.*                      # FreeRTOS mutex / critical section
│  ├─ utils.*                     # hex、颜色、JSON 辅助函数
│  ├─ web_json.*                  # 大 JSON 请求的轻量字段读取
│  └─ psram_json.h                # ArduinoJson PSRAM allocator
├─ scripts/                       # PlatformIO 构建脚本
│  ├─ patch_webserver_timeout.py   # WebServer timeout patch
│  └─ gzip_webui_assets.py         # LittleFS WebUI gzip 资源生成
├─ tools/                         # 字体与资源生成工具
├─ licenses/                      # 第三方 license notice
├─ platformio.ini                 # PlatformIO 配置
├─ partitions.csv                 # ESP32 flash 分区
├─ run_rinachan_unifont.ps1        # 一键构建/字体/上传脚本
└─ README.md
```

---

## 11. 构建与资源流水线

### 11.1 `run_rinachan_unifont.ps1`

项目主构建脚本。主要职责：

- 检查 Python 依赖。
- 扫描 WebUI 和资源中实际使用的字符。
- 构建 GNU Unifont WebUI 子集。
- 验证 Ark Pixel 12px 字体和 bitmap glyph 表。
- 运行 PlatformIO 构建。
- 可选上传固件。
- 可选上传 LittleFS。

### 11.2 `scripts/patch_webserver_timeout.py`

PlatformIO pre-build 脚本，用于降低 Arduino WebServer 阻塞等待时间，减少 ESP32 WebServer 在大请求或断连时对主循环造成的影响。

### 11.3 `scripts/gzip_webui_assets.py`

PlatformIO 构建脚本，用于为 WebUI 静态资源生成 `.gz` 文件。固件静态服务器会根据浏览器 `Accept-Encoding: gzip` 优先返回压缩资源。

### 11.4 字体工具

| 工具 | 用途 |
|---|---|
| `tools/build_unifont_webui_subset_from_png.py` | 生成 WebUI 使用的 GNU Unifont 子集 |
| `tools/build_ark12_merged.py` | 生成合并 Ark Pixel 12px 资源 |
| `tools/compile_ark_bdf.py` | 将 BDF 字体编译为浏览器字体和 bitmap 表 |

### 11.5 Ark12 字体资源

当前项目使用 fused Ark12 字体资源：

| 文件 | 用途 |
|---|---|
| `/resources/fonts/ark12.json` | LED 文字滚动 bitmap glyph 表 |
| `/resources/fonts/ark12.woff2` | Ark12 基础浏览器字体 |
| `/resources/fonts/ark12_fallback.woff2` | CJK fallback 字体 |

已知需要覆盖/验证的补字包括：

```text
然 / 燃 / 滚 / 滾
```

修改 WebUI 文案、字体、`data/index.html`、`data/styles.css` 或 runtime JSON 后，应重新运行构建脚本，避免 LittleFS 上传旧的 gzip 资源。

---

## 12. 调试与验证

### 12.1 串口监视器

```bash
pio device monitor -b 115200
```

### 12.2 API 手动检查

连接设备热点后：

```bash
curl http://rina.io/api/status
curl http://rina.io/api/power
curl http://rina.io/api/saved_faces
```

发送命令示例：

```bash
curl -X POST http://rina.io/api/command \
  -H "Content-Type: application/json" \
  -d '{"cmd":"set_brightness","payload":{"raw":80}}'
```

发送全灭帧示例：

```bash
curl -X POST http://rina.io/api/frame \
  -H "Content-Type: application/json" \
  -d '{"m370":"M370:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","reason":"manual_test"}'
```

### 12.3 烧录后检查清单

建议每次烧录后按顺序检查：

- [ ] 串口输出正常，无反复重启。
- [ ] 能看到 Wi‑Fi 热点 `RinaChanBoard-V2`。
- [ ] 浏览器可打开 `http://rina.io/`。
- [ ] `/api/status` 返回 JSON。
- [ ] `/api/power` 返回电池/充电状态。
- [ ] WebUI 6.1 可控制颜色和亮度。
- [ ] saved face 可上一张/下一张切换。
- [ ] Auto 模式按设定间隔轮播。
- [ ] 6.2 自定义表情可发送和保存。
- [ ] 6.3 部件表情可组合、随机和保存。
- [ ] 6.4 文字滚动可发送、暂停、继续、停止、逐格。
- [ ] B1/B2/B3/B4/B5 按钮行为正确。
- [ ] B6 电池覆盖层行为符合硬件预期。
- [ ] 6.5 测试图案正常。
- [ ] 重启后 saved_faces、runtime_settings 和 battery_calib 能正确加载。

### 12.4 LittleFS 缺失诊断

如果只上传了固件、没有上传 LittleFS：

- AP 仍可能启动。
- 根页面会显示 LittleFS 诊断页。
- LED 会显示短红色文件系统错误图案。

恢复方法：

```bash
pio run -t uploadfs
```

或：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFS
```

---

## 13. 已知限制与开发者注意

### 13.1 无 OTA 回滚分区

当前 `partitions.csv` 使用一个 factory app 分区和较大的 LittleFS 分区，没有可用的双 OTA app 槽。远程 OTA、自动回滚和 A/B 更新不在当前分区设计范围内。

### 13.2 文字滚动只缓存到 RAM/PSRAM

`/api/scroll` 明确拒绝 flash 持久化。滚动帧序列断电后不会保存，需要 WebUI 重新生成并上传。

### 13.3 B6 的 API 模拟不等同于真实硬件行为

B6 与电池/充电覆盖层相关，真实行为依赖按钮扫描和动画模块。普通 `/api/command` 的 `button` 模拟主要覆盖 B1/B2/B3/B4/B5 和部分组合键，不应假设完全等价于 B6 硬件按下。

### 13.4 Debug 手动 JSON 命令需要核对固件命令表

WebUI Debug 页面存在高级调试入口。开发时应以 `src/web_api.cpp` 中实际支持的 `/api/command` 命令为准。如果某个 Debug 命令返回 `unknown command`，说明 UI 入口与当前固件命令表未完全对齐。

### 13.5 ESP32 WebServer 是同步模型

Arduino `WebServer` 为同步处理模型。前端已经对高频帧发送做了队列和节流，固件也有 timeout patch；开发新功能时仍应避免高频、大体积、阻塞型 API 请求。

### 13.6 电池百分比需要真实硬件校准

电池百分比基于 2S LiPo 风格 LUT、ADC 分压、去极值采样和 EMA 平滑。不同电池、分压电阻误差、负载电流和充电状态会影响实际显示，需要真机验证。

### 13.7 字体和 gzip 资源可能出现缓存问题

如果修改了 WebUI、字体或 JSON 资源，但浏览器仍显示旧页面：

1. 重新运行构建脚本。
2. 确认 `uploadfs` 已执行。
3. 使用 `http://rina.io/?v=latest` 强制刷新。
4. 必要时清除浏览器缓存。

---

## 14. 第三方组件与许可证

本项目使用：

- ESP32 Arduino core。
- PlatformIO。
- ArduinoJson。
- Adafruit NeoPixel。
- GNU Unifont。
- Ark Pixel Font。

GNU Unifont 子集 notice 位于：

```text
licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt
```

当前固件目录中未发现顶层项目 license 文件。添加正式项目 license 前，不应默认假设项目源码可自由再分发。第三方组件仍遵循各自许可证。

---

## 维护建议

后续维护 README 时，建议同步更新以下内容：

- 新增或删除 WebUI 页面控件时，同步更新 [WebUI 使用说明](#5-webui-使用说明)。
- 新增 `/api/command` 命令时，同步更新 [HTTP API](#7-http-api)。
- 修改 `src/config.h` 常量时，同步更新 [配置项](#9-配置项)。
- 修改按钮逻辑时，同步更新 [物理按钮操作](#6-物理按钮操作)。
- 修改 LittleFS 文件路径或 JSON schema 时，同步更新 [数据文件与持久化](#8-数据文件与持久化)。
