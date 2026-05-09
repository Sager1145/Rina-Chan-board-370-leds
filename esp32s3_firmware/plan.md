# RinaChanBoard ESP32-S3 370 LED 固件与 WebUI 总计划

> 文档状态：固件接口重构版（统一 saved_faces.json 表情库 / HTML 主处理 / 仅发送 M370 与辅助指令 / 已删除媒体页）
> 目标：以当前 `rina_370_webui_single_saved_faces.html` 为准，将 HTML 重构为主要数据处理层；默认表情、自定义表情、部件表情全部保存在同一个 `/resources/saved_faces.json` 中，默认表情以 `type:"default"` 标识且不可删除但可排序和重命名；固件只接收 `M370:<93 hex>` LED 帧和亮度、颜色、模式、暂停、按钮、保存 JSON 等辅助指令。
> 对齐原则：若旧计划与当前 HTML 冲突，以当前 HTML 的接口、控件、状态字段和保存文件结构为准；删除旧 demo、placeholder 数据、浏览器缓存保存源和已废弃旧播放页路径。

---


## 最新覆盖规则：单一 saved_faces.json 表情库

本轮以后以单一文件 `/resources/saved_faces.json` 作为唯一表情库：

1. 默认表情不写入 HTML。
2. 默认表情不再使用独立 `default_faces.json`。
3. 默认表情不再使用独立顺序文件。
4. 默认表情、自定义表情、部件表情全部位于同一个 `faces[]`。
5. 默认表情仅通过 `type: "default"` 标识。
6. `type: "default"` 的表情不可删除，但可以重命名、上移、下移、拖拽排序。
7. 用户手动排序写回同一个 `saved_faces.json` 的 `order` 字段。
8. 默认表情重命名写回同一个 `saved_faces.json` 的 `name` 字段。
9. 默认启动表情固定为 `face_07_triangle_eyes_frown`（来源默认表情 index/id=7）。
10. 用户保存的自定义表情使用 `type: "custom"`。
11. 用户保存的部件组合使用 `type: "parts"`。
12. HTML 只处理表情数据、生成 M370，并通过 `/api/saved_faces` 写回同一个表情库文件。
13. 电脑本地打开 HTML 时，浏览器若支持 File System Access API，可用“打开本地 saved_faces.json”绑定同一个文件并直接保存排序/重命名；否则使用导入/下载流程。


### 默认 faces 写入规则

- 默认 faces 不写入 HTML。
- 默认 faces 不使用单独 `default_faces.json` 或 `face_order.json`。
- 默认 faces 与用户保存表情统一写入 `/resources/saved_faces.json`。
- `type:"default"` 是默认表情的唯一标识。
- `type:"default"` 项不可删除，但可以重命名。
- 用户手动排序保存在同一个 `saved_faces.json` 的 `order` 字段。
- 自定义表情使用 `type:"custom"`，部件表情使用 `type:"parts"`。

## 0. 总体目标

本项目实现一个运行在 **ESP32-S3** 上的 RinaChanBoard 370 LED 固件与本机 WebUI。当前重构版的核心边界是：**HTML 是主要数据处理层，固件是执行层**。

核心目标：

1. ESP32-S3 仅作为 **AP WiFi Host**，直接提供 WebUI 和静态资源。
2. HTML 负责：
   - 370 LED 虚拟矩阵编辑。
   - 表情部件组合。
   - 文字滚动 rasterize 与 30fps 帧序列生成。
   - M370 编码 / 解码。
   - saved faces JSON 管理。
   - 颜色、亮度、模式、按钮等 UI 状态管理。
3. 固件只接收两类输入：
   - LED 帧：`M370:<93 hex>`。
   - 辅助 JSON 指令：颜色、亮度、模式、暂停、按钮、保存文件、状态读取等。
4. LED 输出统一使用 **370 颗真实 LED** 的 `M370:<93 hex>` 协议。
5. 所有显示功能都通过同一个 LED 输出管线：
   - 保存表情
   - 自定义表情
   - 表情部件组合
   - 文字滚动
   - 电池 / 网络 / 调试 overlay
6. 颜色和亮度是全局状态：
   - WebUI 颜色选择器是普通显示功能的唯一全局颜色来源。
   - GPIO B4 / B5 与 WebUI 亮度按钮、滑条控制同一个 brightness raw 值。
7. 除文字滚动外，普通模式采用 dirty-frame / frame-changed 按需刷新。
8. 文字滚动播放期间必须以 30fps 连续输出 M370 帧。
9. 任意模式开始发送或播放前，必须终止其它模式 activity，且不自动恢复旧模式。
10. 保存表情不再使用浏览器本地缓存作为数据源；必须读取/写入独立 JSON 文件：

```text
/resources/saved_faces.json
```

11. WebUI 当前页面为：
   - 6.1 基础功能
   - 6.2 自定义表情
   - 6.3 表情部件
   - 6.4 文字滚动
   - 6.5 调试

旧媒体旧播放页面已完全删除，不再作为功能、API、状态或验收项出现。

## 1. 硬件规格

### 1.1 主控与连接

| 项目 | 要求 |
|---|---|
| MCU | ESP32-S3 |
| WiFi 模式 | AP-only |
| AP SSID | `RinaChanBoard-ESP32S3` |
| AP 密码 | `rinachan` |
| AP IP | `192.168.1.14` |
| 禁止功能 | STA 配网、WiFi 扫描、外部 SSID/密码保存、路由器连接 |

### 1.2 LED 矩阵

| 项目 | 要求 |
|---|---|
| 虚拟矩阵 | `22×18` |
| 物理 LED 数量 | `370` |
| 行长度 | `[18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16]` |
| 有效 x 范围 | `[[2,19],[1,20],[1,20],[1,20],[0,21],[0,21],[0,21],[0,21],[0,21],[0,21],[0,21],[0,21],[0,21],[1,20],[1,20],[1,20],[2,19],[3,18]]` |
| LED 协议 | `M370:<93 hex>` |
| 有效 bit | 370 bit |
| padding | 最后 2 bit 固定为 0，解码时忽略 |
| 单颗 LED 估算 | 60mA @ 5V |
| 供电保护预算 | 40W |
| 默认亮度 | `50/255` |
| 亮度范围 | `10/255` 到 `200/255` |
| 亮度步进 | `8/255` |

### 1.3 M370 编码规则

`M370` 是 370 LED 的逻辑画面输出协议，不再使用 16×18 FaceString 作为最终下位机协议；固件在写入 NeoPixel 前负责把逻辑 row-major bit 映射到物理蛇形走线。

```text
M370:<93 hex>
```

编码要求：

1. 数据区必须是 93 个 hex 字符。
2. 93 hex = 372 bit。
3. 前 370 bit 对应 370 个有效 LED。
4. 最后 2 bit 是 padding，必须为 0。
5. bit=1 表示该 LED 按全局颜色点亮。
6. bit=0 表示该 LED 熄灭。
7. M370 不携带颜色，不携带亮度。
8. 颜色、亮度、DPS 由统一 LED renderer 在输出阶段处理。

M370 扫描顺序：

```text
for row in 0..17:
  for x in row_valid_x_ranges[row].start .. row_valid_x_ranges[row].end:
    append bit at virtual cell (x, row)
append two 0 padding bits
pack to 93 hex chars
```

---

## 2. GPIO 与 ADC

### 2.1 GPIO 按钮

所有按钮均为 GPIO 到 GND，按下为低电平，固件启用内部上拉。

| 按钮 | GPIO | 短按功能 |
|---|---:|---|
| B1 | 17 | 下一个保存表情 |
| B2 | 16 | 上一个保存表情 |
| B3 | 15 | 自动 / 手动保存表情模式切换 |
| B4 | 40 | 亮度 -8 |
| B5 | 41 | 亮度 +8 |
| B6 | 42 | 显示 2 秒电池电量 |

组合键：

| 组合键 | 功能 |
|---|---|
| B3 长按 + B1 短按 | 自动切换间隔减少 |
| B3 长按 + B2 短按 | 自动切换间隔增加 |
| B6 长按 + B3 长按 | 显示网络信息页面 |

按键参数：

| 参数 | 值 |
|---|---:|
| debounce | 25ms |
| repeat 初始延迟 | 400ms |
| repeat 周期 | 140ms |
| 支持 repeat | B1 / B2 / B4 / B5 |

### 2.2 电池 ADC

| 项目 | 要求 |
|---|---|
| ADC GPIO | GPIO10 |
| 分压 | R1=100kΩ，R2=57kΩ |
| 公式 | `Vbat = Vadc × (100kΩ + 57kΩ) / 57kΩ` |
| 采样数 | 16 |
| 滤波 | 排序后去最高 4 个和最低 4 个，平均中间 8 个 |
| 电压范围 | 6.2V ~ 8.0V |
| 端点吸附容差 | 0.12V |
| 检测间隔 | 10s |

### 2.3 充电 ADC

| 项目 | 要求 |
|---|---|
| ADC GPIO | GPIO1 |
| 分压 | R1=270kΩ，R2=47kΩ |
| 公式 | `Vcharge = Vadc × (270kΩ + 47kΩ) / 47kΩ` |
| 充电阈值 | 4.0V |
| 判定 | `Vcharge > 4.0V` 为充电 |
| 检测间隔 | 1s |

---

## 3. 软件架构

### 3.1 模块划分

```text
esp32s3_firmware/
├── include/
│   ├── Config.hpp
│   ├── MatrixMap.hpp
│   ├── M370.hpp
│   ├── StateStore.hpp
│   ├── ActivityManager.hpp
│   ├── LedRenderer.hpp
│   ├── FaceStore.hpp
│   ├── SavedFacesJson.hpp
│   ├── BatteryMonitor.hpp
│   └── WebApi.hpp
├── src/
│   ├── main.cpp
│   ├── MatrixMap.cpp
│   ├── M370.cpp
│   ├── StateStore.cpp
│   ├── ActivityManager.cpp
│   ├── LedRenderer.cpp
│   ├── FaceStore.cpp
│   ├── SavedFacesJson.cpp
│   ├── BatteryMonitor.cpp
│   └── WebApi.cpp
├── data/
│   ├── index.html
│   ├── app.css
│   ├── app.js
│   └── resources/
│       ├── saved_faces.json
│       └── fonts/
└── plan.md
```

重构边界：

1. HTML 负责生成全部 M370 帧。
2. 固件不得重新实现表情部件组合、画板编辑或文字 rasterize。
3. 固件只需要提供：
   - 静态文件服务。
   - `/api/frame`：接收 M370 帧。
   - `/api/command`：接收辅助指令。
   - `/api/saved_faces`：读写 `/resources/saved_faces.json`，作为默认表情、自定义表情、部件表情的唯一统一表情库。
   - `/api/status`：返回固件状态。
4. 最终实现必须避免把旧 interface 的临时兼容代码继续复制到正式固件中。

### 3.2 单一 LED 输出管线

所有功能最后都输出一个 370-bit on/off frame：

```text
功能模块
  ↓
M370Frame / bool[370]
  ↓
ActivityManager 防冲突终止
  ↓
LedRenderer 套用全局颜色、亮度、DPS
  ↓
NeoPixelBus / LED driver show()
```

要求：

1. 功能模块不得直接写 LED strip。
2. 功能模块不得自己计算亮度衰减。
3. 功能模块不得自己绕过 DPS。
4. 普通显示功能只传 on/off bitmap。
5. 电池、网络等 overlay 允许有自己的固定颜色逻辑，但仍必须经过统一 renderer。

---

## 4. Activity 防冲突终止策略

### 4.1 核心原则

当任何模式准备发送或播放 LED 内容之前，必须先终止其它模式 activity。

这是 **单向终止**，不是临时暂停：

```text
新模式准备输出
  ↓
ActivityManager.terminateOtherActivities(targetMode, reason)
  ↓
停止其它模式 timer / playback 状态
  ↓
不记录恢复任务
  ↓
新模式输出 frame
```

### 4.2 不自动恢复规则

| 原活动 | 新模式触发后 | 新模式结束后 |
|---|---|---|
| 自动切换保存表情 | 切回手动保存表情模式 | 不自动恢复自动模式 |
| 文字滚动 | 停止 30fps scroll timer，active=false | 不自动继续滚动 |
| overlay | 被新输出替换 | 不自动重显 |

### 4.3 触发点

以下动作必须先经过 ActivityManager：

- 切换页面后发送内容
- 保存表情上一张 / 下一张
- 自定义表情发送
- 表情部件组合发送
- 文字滚动生成、播放、单帧推进
- Debug 全黑 / 全亮 / 棋盘 / 边框 / M370 测试
- 电池 overlay
- 网络信息 overlay

### 4.4 禁止保留旧兼容入口

最终代码中不得保留：

- 已不再调用的暂停式兼容函数
- 会在新模式结束后恢复旧 activity 的逻辑
- 自动恢复文字滚动的任务
- 自动恢复保存表情自动模式的任务
- 同时存在多个播放 timer 的结构

正式入口只保留一个：

```cpp
ActivityManager::terminateOtherActivities(TargetMode target, const char* reason);
```

WebUI JS 也只保留一个同等语义入口：

```js
terminateOtherActivities(targetMode, reason)
```

---

## 5. LED 刷新策略

### 5.1 内部刷新策略

| 模式 | 策略 |
|---|---|
| 保存表情 / 手动表情 | dirty-frame / 按需刷新 |
| 自动切换保存表情 | 只在切到新表情时刷新 |
| 自定义表情发送 | 收到新 frame 后刷新一次 |
| 表情部件组合 | 合成后刷新一次 |
| overlay | 内容变化、倒计时结束、退出时刷新 |
| 调试测试帧 | 收到命令后刷新 |
| 文字滚动 | 播放期间强制 30fps 连续刷新 |

### 5.2 UI 显示要求（以 HTML 为准）

当前 HTML 把状态分成两类：普通页面只保留操作必需内容，调试页面集中显示接口、刷新、状态和日志。

| 页面 | 允许显示 | 不应额外增加 |
|---|---|---|
| 6.1 基础功能 | AP-only Firmware API badge、IP badge、颜色、亮度、保存表情控制、只读预览 | 不增加刷新策略、最后刷新原因、当前 M370 长文本 |
| 6.2 自定义表情 | M370 输入/导入/复制/导出文本、统一 saved_faces.json 默认表情 / saved_faces.json 读取与下载、用户 JSON 导入、统一表情列表 | 不使用浏览器缓存作为保存源；type:"default" 的默认表情不可删除但可重命名 |
| 6.3 表情部件 | 组合调用文本 `leye=..., reye=..., mouth=..., cheek=...`、复制组合 M370、页面底部 M370 / 保存管理 panel、统一表情列表 | 不增加旧库名说明 |
| 6.4 文字滚动 | 状态、当前帧进度、速度输入、370 LED 预览 | 不显示完整帧序列、offset、复制当前 M370 按钮 |
| 6.5 调试 | 刷新策略、最近刷新原因、刷新计数、文字 30fps、实际 FPS、ADC、网络、资源、固件接口状态、状态 JSON、日志下载 | 不把这些调试字段复制回普通主页面 |

保留说明：

1. header 说明必须表明当前为固件接口模式：HTML 生成 M370，固件接收 M370/辅助指令。
2. 6.5 调试页必须保留固件接口状态、资源字段、通信日志字段。
3. 不得重新加入旧媒体旧播放页。

## 6. WebUI 总体布局

### 6.1 顶部结构

页面最顶部固定显示 header：

```html
<aside class="sidebar">
  <div class="brand">...</div>
  <div class="offline">...</div>
</aside>
```

页面选择 dropdown 放在 header 下方：

```html
<div class="top-page-nav">
  <div class="nav-shell">
    <button class="nav-toggle">...</button>
    <div class="nav" role="menu">...</div>
  </div>
</div>
```

页面内容放在 dropdown 下方：

```html
<div class="app">
  <main class="content">...</main>
</div>
```

### 6.2 页面选择 dropdown

要求：

1. 使用三横按钮 toggle。
2. 只有按下按钮后才显示页面菜单。
3. 点击菜单外部关闭。
4. 按 `Esc` 关闭。
5. 点击页面项后切换页面并自动关闭菜单。
6. dropdown 必须在最上图层显示，不被 card、matrix、panel、canvas 覆盖。
7. 页面选择 dropdown 位于顶部 header 下方。
8. 按钮文字显示当前页面。

页面项：

| 编号 | 页面 |
|---|---|
| 6.1 | 基础功能 |
| 6.2 | 自定义表情 |
| 6.3 | 表情部件 |
| 6.4 | 文字滚动 |
| 6.5 | 调试 |

### 6.3 dropdown 图层

建议 z-index：

```css
.sidebar      { z-index: 2147482999; }
.top-page-nav { z-index: 2147483000; isolation: isolate; }
.nav-shell    { z-index: 2147483001; }
.nav          { z-index: 2147483002; }
```

要求：

- `.top-page-nav` 使用 `position: sticky; top: 0;`
- `.nav` 使用绝对定位脱离普通文档流。
- 展开菜单必须覆盖页面内所有内容。

### 6.4 所有 dropdown 的统一样式与 HTML 实现策略

页面内 dropdown 的视觉层必须统一为自定义 button menu，不显示浏览器原生 select 外观。

适用对象：

- 页面选择 dropdown
- 父颜色 dropdown
- 子颜色 dropdown
- 后续新增 dropdown

HTML 当前实现策略以 `select-shell + hidden select + generated button menu` 为准：

```html
<div class="select-shell">
  <select id="..."></select>
  <button class="select-toggle" aria-haspopup="menu" aria-expanded="false">...</button>
  <div class="select-menu" role="menu" aria-hidden="true">...</div>
</div>
```

要求：

1. 原生 `<select>` 可以作为 HTML 的状态桥接层，但必须完全不可见：`width:1px; height:1px; opacity:0; pointer-events:none; appearance:none;`。
2. 用户只能看到 `.select-toggle` 和 `.select-option`。
3. `ensureCustomSelect(select)` 负责把隐藏 select 转换为可见 dropdown。
4. `refreshSelectDropdown(idOrSelect)` 负责根据 select 当前值刷新按钮文本和 option active 状态。
5. `refreshAllCustomSelects()` 必须在 select option 变化后统一刷新。
6. 点击 dropdown 外部关闭全部 `.select-shell.open`。
7. 按 `Esc` 关闭全部自定义 dropdown。
8. 展开一个 dropdown 前，必须关闭其它 dropdown。
9. option 的主文本和右侧辅助文本通过多个空格切分：`splitDropdownLabel(text)`。
10. dropdown 状态可以同步到 JS state，但冲突时以 HTML 当前 select/value 行为为准。

每个 dropdown toggle 要求：

| 项目 | 要求 |
|---|---|
| 元素 | `button.select-toggle` |
| 高度 | `46px` |
| 圆角 | `14px` |
| 背景 | `linear-gradient(180deg,#1a2030,#111722)` |
| 阴影 | `0 12px 30px #00000035` |
| 右侧 | 统一 `▾` caret |
| hover | 轻微上浮，边框变为 `--accent2` |
| focus-visible | 高亮边框和 glow |
| open | caret 旋转 `180deg` |

每个 dropdown option 要求：

| 项目 | 要求 |
|---|---|
| 元素 | `button.select-option` |
| 高度 | `46px` |
| 圆角 | `14px` |
| 背景 | `linear-gradient(180deg,#192030,#101622)` |
| 布局 | 左侧主文本，右侧 `.num` 辅助文本 |
| hover | 轻微上浮，边框高亮 |
| focus-visible | 高亮边框和 glow |
| active | 使用 `--accent` 高亮外框 |

### 6.5 HTML/CSS 全局视觉 token

以 HTML 的 CSS 变量为准：

| token | 默认值 |
|---|---|
| `--bg` | `#0f1117` |
| `--panel` | `#161a24` |
| `--panel2` | `#1e2430` |
| `--text` | `#f4f7fb` |
| `--muted` | `#9aa6b2` |
| `--line` | `#2b3344` |
| `--accent` | `#f971d4` |
| `--accent2` | `#77d7ff` |
| `--danger` | `#ff5b6e` |
| `--ok` | `#59d98e` |
| `--warn` | `#ffd166` |
| `--cell` | `18px` |
| `--gap` | `4px` |
| `--led-color` | `#f971d4` |

通用控件样式：

1. 所有元素使用 `box-sizing:border-box`。
2. 页面禁止横向溢出：`html, body { overflow-x:hidden; }`。
3. button 默认 `min-height:40px`、`border-radius:12px`、hover 上浮。
4. `.primary` 使用粉紫渐变。
5. `.ok`、`.warn`、`.danger` 使用 HTML 当前色彩语义。
6. `.active` 使用 `--accent` 外框和 glow。
7. `.card` 使用深色渐变、`18px` 圆角、`0 12px 32px #00000035` 阴影。
8. `.hint`、`.warning`、`.badge` 样式按 HTML 保留。

### 6.6 响应式布局与矩阵自适应

HTML 的响应式行为必须作为正式 WebUI 要求：

| 断点 | 行为 |
|---|---|
| `max-width:1100px` | `.basic-layout` 从左右两列变成单列 |
| `max-width:980px` | header 单列，内容 padding 缩小，所有 `.cols-2/.cols-3/.cols-4` 变单列，默认 cell 约 `14px` |
| `max-width:640px` | 保存表情行布局压缩，部件卡片保持横向滚动 |
| `max-width:520px` | KV 单列，颜色按钮满宽，亮度行压缩，默认 cell 约 `12px` |

矩阵自适应要求：

1. 所有矩阵都在 `.matrix-wrap` 内渲染。
2. `.matrix-wrap` 必须 `overflow:hidden; width:100%; max-width:100%`。
3. `.matrix` 使用 22 列 × 18 行 CSS grid。
4. `fitMatrix(view)` 必须根据容器宽度计算 `--cell`。
5. 普通矩阵 cell 范围：`5px` 到 `22px`。
6. compact 矩阵 cell 范围：`4px` 到 `12px`。
7. `ResizeObserver` 监听 `.matrix-wrap`，变化时调用 `fitAllMatrices()` 和 `renderMatrices()`。
8. fallback 使用 `window.resize`。
9. 缩放只改变显示尺寸，不改变 22×18 虚拟坐标、370 LED 索引、M370 编码顺序。

---

## 7. WebUI 页面要求（按 HTML 补齐）

### 7.1 页面初始化与 boot 流程

HTML 初始化流程必须保持以下顺序或等效语义：

```text
initNav()
initMatrix(basic/custom/parts/scroll/debug)
observeMatrixWraps()
fitAllMatrices()
initBrightness()
initColors()
initBasicControls()
initCustom()
initParts()
initScroll()
initDebug()
initCustomSelectDropdowns()
compose default parts frame
currentFrame = partsFrame
editFrame = partsFrame
updateAdc()
setColor('#f971d4','boot') -> POST /api/command set_color
setBrightness(50,'boot') -> POST /api/command set_brightness
loadFaceLibrary() -> GET /api/saved_faces 或 /resources/saved_faces.json -> 解析同一个 faces[] 中的 default/custom/parts
startup sequence complete -> apply startupDefaultId/default face -> POST /api/frame M370
render all UI/state/log/matrices/M370 views/firmware status
```

启动默认状态：

| 状态 | 默认值 |
|---|---|
| 当前页面 | `6.1 基础功能` |
| 模式 | `手动` |
| playback | `idle` |
| 亮度 | `50` |
| 颜色 | `#f971d4` |
| 父颜色组 | `0` |
| 子颜色 | `null` / 使用父颜色 |
| 自动切换间隔 | `3000ms` |
| 当前组合表情 | `leye=101, reye=201, mouth=301, cheek=400` |
| 表情库来源 | `/resources/saved_faces.json` |
| 默认表情来源 | 同一个 `saved_faces.json` 中 `type:"default"` 的 face 项 |
| 默认表情列表 | 不可删除，可排序，可重命名，排序保存在 `order` 字段 |
| 用户保存表情默认列表 | 同一个 `saved_faces.json` 中 `type:"custom"` / `type:"parts"` 的 face 项 |
| ADC 调试初始值 | `Vbat=7.42V`, `Vcharge=5.10V` |
| AP IP | `192.168.1.14` |

统一 `saved_faces.json` 为空或未读取时，保存列表显示提示并提供“导入 saved_faces.json”和“下载 saved_faces.json”操作。

### 7.2 6.1 基础功能页面

页面标题：`6.1 基础功能页面`。

页面布局：

1. 顶部 hero 左侧只显示标题。
2. 右侧显示 `AP-only Firmware API` badge 和 `192.168.1.14` badge。
3. 主体使用 `.basic-layout`：宽屏为左控制 panel + 右预览 panel；`max-width:1100px` 后变成上下堆叠。
4. 左侧卡片标题为：`颜色 / 亮度 / 保存表情 / A-M 模式`。
5. 右侧卡片标题为：`370 LED 只读预览`。

保留功能：

- 颜色输入框 `#RRGGBB` / `RRGGBB`
- 当前颜色 swatch
- `应用颜色` 按钮
- 父颜色 dropdown
- 子颜色 dropdown
- 亮度 slider
- raw 亮度 number input
- 百分比参考 readonly input
- 亮度 `−8` / `+8` 按钮
- 亮度 presets 按钮
- B1/B2 上一个/下一个保存表情
- B3 自动/手动切换
- B3+B1 / B3+B2 自动间隔调整
- 自动切换间隔 number input
- 370 LED 只读预览矩阵

颜色输入规则：

1. `normalizeHexColor()` 接受 `#RRGGBB` 或 `RRGGBB`。
2. 非法颜色弹出提示：`颜色必须是 #RRGGBB 或 RRGGBB`。
3. `setColor(hex, source)` 更新：
   - `state.color`
   - CSS `--led-color`
   - `#color-input`
   - `#color-swatch`
   - DPS 状态
   - 所有矩阵预览
   - 状态面板
   - 日志
4. 预览矩阵只显示 on/off 形状和当前颜色，不随 raw 亮度变暗。

父颜色组必须按 HTML 保留：

| id | 名称 | hex | 说明 |
|---:|---|---|---|
| 0 | 默认璃奈粉色 | `#f971d4` | 父级颜色按钮，仅提供父级色 |
| 1 | μ's-洋红色 | `#e4007f` | μ's 子颜色组 |
| 2 | Aqours-水蓝色 | `#00a1e8` | Aqours / Saint Snow / 子团体颜色组 |
| 3 | 虹咲学园-金色 | `#f8b656` | 虹咲 / 子团体颜色组 |
| 4 | Liella!-紫色 | `#a5469b` | Liella! / 子团体颜色组 |
| 5 | 蓮ノ空-粉色 | `#fb8a9b` | 蓮ノ空 子颜色组 |

子颜色组必须完整保留 HTML 中的成员色：

| 父组 id | 子颜色 |
|---:|---|
| 1 | 高坂穗乃果 `#f38500`；绚濑绘里 `#7aeeff`；南小鸟 `#cebfbf`；园田海未 `#1769ff`；星空凛 `#fff832`；西木野真姬 `#ff503e`；东条希 `#c455f6`；小泉花阳 `#6ae673`；矢泽妮可 `#ff4f91` |
| 2 | 高海千歌 `#ff9547`；樱内梨子 `#ff9eac`；松浦果南 `#27c1b7`；黑泽黛雅 `#db0839`；渡边曜 `#66c0ff`；津岛善子 `#c1cad4`；国木田花丸 `#ffd010`；小原鞠莉 `#c252c6`；黑泽露比 `#ff6fbe`；CYaRon! `#ffa434`；AZALEA `#ff5a79`；Guilty Kiss `#825deb`；YYY `#53ab7f`；鹿角圣良 `#00ccff`；鹿角理亚 `#bbbbbb`；Saint Snow `#cb3935` |
| 3 | 上原步梦 `#ed7d95`；中须霞 `#e7d600`；樱坂雫 `#01b7ed`；朝香果林 `#485ec6`；宫下爱 `#ff5800`；近江彼方 `#a664a0`；优木雪菜 `#d81c2f`；艾玛·维尔德 `#84c36e`；天王寺璃奈 `#9ca5b9`；三船栞子 `#37b484`；米雅·泰勒 `#a9a898`；钟岚珠 `#f8c8c4`；DiverDiva `#ab76f7`；A·ZU·NA `#ff0042`；QU4RTZ `#d9db83`；R3BIRTH `#424a9d` |
| 4 | 涩谷香音 `#ff7f27`；唐可可 `#a0fff9`；岚千砂都 `#ff6e90`；平安名堇 `#74f466`；叶月恋 `#0000a0`；樱小路希奈子 `#fff442`；米女芽衣 `#ff3535`；若菜四季 `#b2ffdd`；鬼冢夏美 `#ff51c4`；薇恩·玛格丽特 `#e49dfd`；鬼冢冬毬 `#4cd2e2`；CatChu! `#e8243c`；KALEIDOSCORE `#bcbcde`；5yncri5e! `#ffe840` |
| 5 | 日野下花帆 `#f8b500`；村野沙耶香 `#5383c3`；乙宗梢 `#68be8d`；夕雾缀理 `#ba2636`；大泽瑠璃乃 `#e7609e`；藤岛慈 `#c8c2c6`；百生吟子 `#a2d7dd`；徒町小铃 `#fad764`；安养寺姬芽 `#9d8de2`；Cerise Bouquet `#da645f`；DOLLCHESTRA `#163bca`；Mira-Cra Park! `#f3b171` |

颜色 dropdown 行为：

1. 父颜色变化时：更新 `state.parentColorId`，清空子颜色，`colorSelection='parent'`，实际颜色变为父颜色。
2. 子颜色 dropdown 第一项必须是：`使用父颜色：<父颜色名> #<父颜色 HEX>`。
3. 选择子颜色时：`colorSelection='child'`，`selectedChildColor=<hex>`，实际颜色变为子颜色。
4. 选择“使用父颜色”时：`selectedChildColor=null`，实际颜色回到父颜色。
5. 父颜色仍保持高亮/选中状态，子颜色只是覆盖实际输出色。

亮度规则：

1. raw 范围：`10..200`。
2. `−8` / `+8` 按钮调用 `setBrightness(state.brightness ± 8)`。
3. slider 与 number input 双向同步。
4. 百分比参考为 `Math.round(raw / 255 * 100) + '%'`。
5. GPIO B4/B5 与 WebUI 调用同一个 `setBrightness()`。
6. DPS warning 只显示限制状态，不反向改写 slider 值。

### 7.3 6.2 自定义表情页面

页面标题：`6.2 自定义表情页面`。

页面布局：

```text
cols-2
├── 自定义画板
└── M370 / 保存管理
```

自定义画板要求：

- 22×18 画板，只允许 370 个有效 LED 被编辑。
- 无效格必须隐藏：`.led.invalid { visibility:hidden; pointer-events:none; }`。
- 移动端 drag-to-draw 必须阻止浏览器默认滚动：`.matrix { touch-action:none; }`，pointer/touch move 中 `preventDefault()`。
- 工具按钮：
  - 画亮
  - 擦除
  - 切换
  - 清空
  - 全亮
  - 反转
- `发送 M370 到固件`：将当前 editFrame 编码为 M370，通过 `/api/frame` 发送。
- `复制 M370`：复制当前 editFrame 的 `M370:<93 hex>`。
- `更新导出文本`：刷新 M370 textarea。

M370 / 保存管理要求：

- textarea `custom-m370` 可输入 `93 hex` 或 `M370:<93 hex>`。
- `从文本导入到画板` 必须校验 93 hex 并更新 editFrame。
- `保存自定义表情` 不写浏览器缓存，必须写入用户保存 JSON 数据模型并通过 `/api/saved_faces` 同步到固件。
- 保存名称 input：`custom-name`。
- 自定义表情页面最底部必须保留 `M370 / 保存管理` panel。
- 保存管理必须同时显示和管理：
  - 默认表情：来自 `/resources/saved_faces.json` 中 `type:"default"` 的 face 项，属性显示为 `默认表情`，不可删除，但允许排序和重命名。
  - 自定义表情：来自同一个 `/resources/saved_faces.json` 中 `type:"custom"` 的 face 项，属性显示为 `自定义表情`，可重命名、排序、删除。
  - 部件表情：来自同一个 `/resources/saved_faces.json` 中 `type:"parts"` 的 face 项，属性显示为 `部件表情`，可重命名、排序、删除。
- 保存管理 JSON 操作：
  - `读取 saved_faces.json`：读取 `/api/saved_faces`，失败时 fallback `/resources/saved_faces.json` / `resources/saved_faces.json`。
  - `下载 saved_faces.json`：导出当前内存中的完整统一表情库。
  - `导入 saved_faces.json`：选择外部 JSON 后校验 `faces[]`，保留 `type:"default"` 标识并写回 `/api/saved_faces`。
  - 不再提供“下载默认 JSON / 下载用户 JSON”的拆分入口。

统一 face schema：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "default_faces|user_saved_faces",
  "matrix": {"leds": 370, "m370HexChars": 93},
  "startupDefaultId": "face_07_triangle_eyes_frown",
  "updatedAt": "ISO-8601|null",
  "faces": [
    {
      "id": "face_or_user_id",
      "name": "display name",
      "type": "default|custom|parts",
      "m370": "M370:<93 hex>",
      "order": 0,
      "editable": true,
      "deletable": true,
      "sourceFile": "saved_faces.json|saved_faces.json",
      "savedAt": "ISO-8601|null",
      "updatedAt": "ISO-8601|null",
      "call": null
    }
  ]
}
```

表情列表行为：

1. 以 `defaultFaces + userFaces` 的合并结果渲染，排序依据为 `order`。
2. 每项显示序号、名称、属性 badge、来源 JSON、点亮 LED 数量。
3. 默认表情：显示 `默认表情`，名称可编辑，删除按钮禁用或显示 `不可删除`，允许上移、下移、拖拽排序。
4. 自定义表情：显示 `自定义表情`，允许应用、上移、下移、拖拽、重命名、删除。
5. 部件表情：显示 `部件表情`，允许应用、上移、下移、拖拽、重命名、删除。
6. 任何排序都必须重新分配 `order`，并 POST 到 `/api/saved_faces` 写回同一个 `/resources/saved_faces.json`。
7. 用户表情的保存、重命名、删除、导入都只写 `/resources/saved_faces.json`。
8. 默认表情不得被删除；`type:"default"` 的默认表情、名称覆盖、排序、M370 基准数据全部保存在同一个 `saved_faces.json` 中。
9. 若固件写入失败，UI 必须保留内存数据，并允许用户下载 JSON 手动导入。
10. 不允许重新加入旧浏览器缓存保存表情数据源。

### 7.4 6.3 表情部件组合页面

页面标题：`6.3 表情部件组合页面`。

页面底部必须新增并保留 `M370 / 保存管理` panel：

- textarea `parts-m370-text` 显示当前组合 `partsFrame` 的 `M370:<93 hex>`。
- `从文本导入到当前输出` 校验 93 hex 后应用为当前输出 frame。
- `保存部件表情` 将当前 `partsFrame` 写入用户保存 JSON，face `type` 必须为 `parts`，属性显示为 `部件表情`。
- `复制组合 M370` 复制当前组合帧。
- 该 panel 的 JSON 读取/下载/导入按钮和统一表情列表必须与 6.2 自定义表情页面保持同一行为。


hero 右侧按钮顺序必须为：

```text
发送组合 M370 / 保存组合 / 随机 / 默认 / 左右眼对称
```

布局：

1. 第一行两列 grid，目前左侧为 `组合预览` 卡片。
2. 预览卡片包含 370 LED 矩阵、组合调用 badge、`复制组合 M370`。
3. 下方 `part-groups` 动态生成四组 card：`leye 左眼`、`reye 右眼`、`mouth 嘴巴`、`cheek 脸颊`。
4. 每组使用横向滚动 `.part-list`，不换行。
5. 每个部件卡片宽度固定约 `60px`。
6. 每个部件显示 8×8 mini preview 和显示编号。
7. active 部件只高亮 `.part-mini` 外框，不给整个卡片加大背景。

调用字段：

| 字段 | 含义 | 默认值 |
|---|---|---:|
| `leye` | 左眼 | `101` |
| `reye` | 右眼 | `201` |
| `mouth` | 嘴巴 | `301` |
| `cheek` | 脸颊 | `400` |

调用 ID 规则：

1. `EXPRESSION_PARTS.call.ids` 给出可显示/可选 ID 列表。
2. `EXPRESSION_PARTS.call.map` 负责从调用 ID 解析到真实 asset ID。
3. `cheek=400` 是显式空脸颊调用，映射到 empty part。
4. 组合时优先使用 `part.m370` 作为 WebUI/M370 canonical 数据。
5. `strip_indices` 只作为 malformed legacy asset fallback，不能作为正常 WebUI M370 生成路径。
6. 四类部件按 OR 规则合成到同一个 370-bit frame。

部件数量按 JSON 保留：

| 类别 | 数量/范围 |
|---|---|
| empty | `0` |
| eye_left | `101..127`，共 27 个 |
| eye_right | `201..227`，共 27 个 |
| mouth | `301..332`，共 32 个 |
| cheek | `400..405`，其中 `400` 为空调用 |
| stored_unique_parts | `92` |
| callable_ids | `93` |

左右眼对称行为：

1. toggle 外观与普通按钮一致。
2. on 时使用 `active` 高亮外框，并设置 `aria-pressed="true"`。
3. off 时取消高亮，并设置 `aria-pressed="false"`。
4. 开启后，手动选择 `leye` 或 `reye` 时通过显示编号同步另一只眼。
5. 随机时左右眼选择同一个显示编号。
6. 随机时眼睛不选择 `0`。
7. 随机时嘴巴不选择 `0`。
8. 随机时脸颊允许 `400`。
9. 默认按钮恢复 `101/201/301/400`，若对称开启则按左眼编号同步右眼。


### 7.5 6.4 文字滚动页面

页面标题：`6.4 文字滚动页面`。

控件：

- textarea：`scroll-text`
- 默认文本：`RinaChanBoard 370 LED DEMO 中文 こんにちは 璃奈ちゃんボード`
- 速度输入：`scroll-speed`
- 速度单位：`px/s`
- 速度范围：`1..120`
- 默认速度：`18`
- `生成文字滚动`
- `播放`
- `暂停`
- `停止/清屏`
- `单帧推进`
- 状态显示：`idle / playing / paused`
- 当前帧进度：`current / total`
- 370 LED 预览矩阵

textarea 要求：

```html
<textarea id="scroll-text" rows="1" spellcheck="false"></textarea>
```

CSS：

```css
#scroll-text {
  min-height: 42px;
  resize: none;
  overflow: hidden;
  line-height: 1.45;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: DotGothic16, "Fusion Pixel 16px", "WenQuanYi Bitmap Song", "Shinonome16", "GNU Unifont", system-ui, sans-serif;
  font-size: 16px;
}
```

自动增高行为：

1. 初始化时调用 `autoResizeScrollTextInput()`。
2. input 时重新计算高度。
3. change 时重新计算高度。
4. paste 后使用 `requestAnimationFrame(autoResizeScrollTextInput)`。
5. window resize 后重新计算高度。
6. `document.fonts.ready` 后重新计算高度。
7. 切换进入页面后必须重新计算高度。
8. 高度算法：先 `height='auto'`，再设为 `max(42, scrollHeight + 2) + 'px'`。

播放行为：

1. 生成、播放、单帧推进前调用 Activity guard。
2. 空文本播放时提示：`空文本不进入 30fps 刷新循环`。
3. 没有可播放帧时提示：`没有可播放的文字帧`。
4. 播放时创建 `setInterval(()=>advanceScroll(1/30,false), FRAME_PERIOD_MS)`。
5. 播放时：`scroll.active=true`、`paused=false`、`state.textScrollActive=true`、`state.playback='scroll'`、`refreshPolicy='text_scroll_30fps'`。
6. 暂停时清 timer，保留当前帧，`state.playback='scroll_paused'`。
7. 停止时清 timer，`offset=0`，`frameIndex=0`，清空 `scrollFrame`，当前输出清屏。
8. 单帧推进时额外 `scroll.offset += 1`。
9. offset 超过总帧数时循环回到开头。
10. speed 改变或文本改变时标记 dirty；若正在播放则重新生成 timeline。
11. UI 不显示完整 M370、帧序列、offset、复制当前 M370 按钮。

### 7.6 6.5 调试页面

页面标题：`6.5 调试页面`。

调试页是唯一集中显示接口状态、系统状态和通信日志的页面。普通页面不得重复这些字段。

页面卡片：

1. 主控制 / 状态信息
2. GPIO / 按钮辅助指令
3. 状态 / ADC / 网络
4. 通信日志
5. 固件接口
6. 资源 / 系统

主状态字段必须包括：

- 当前模式
- 当前保存表情序号
- 当前保存表情名称
- 当前亮度
- 当前颜色
- 当前播放状态
- 当前 AP IP
- 刷新策略
- 最近刷新原因
- 刷新计数

固件接口字段必须包括：

- 连接状态
- 最后请求
- 最后状态
- 最后错误
- M370 endpoint：`/api/frame`
- Command endpoint：`/api/command`
- 保存文件：`/resources/saved_faces.json`
- 保存同步状态
- 已发送帧
- 已发送辅助指令

按钮辅助指令：

| UI 按钮 | 前端行为 | 固件辅助指令 |
|---|---|---|
| B1 下一个 | 应用下一保存表情 | `POST /api/command {cmd:'button', payload:{button:'B1'}}` |
| B2 上一个 | 应用上一保存表情 | `button:B2` |
| B3 A/M | 切换自动/手动 | `set_mode` + `button:B3` |
| B4 亮度- | raw brightness -8 | `set_brightness` + `button:B4` |
| B5 亮度+ | raw brightness +8 | `set_brightness` + `button:B5` |
| B6 短按电量 | battery overlay 状态 | `button:B6S` |
| B6 长按详情 | battery detail overlay 状态 | `button:B6L` |
| B3+B1 / B3+B2 | 调整自动间隔 | `set_auto_interval` + button |
| B6+B3 | 网络信息 overlay | `button:B6B3` |

LED / 协议测试：

- 全黑
- 全亮
- 棋盘
- 边框
- 当前保存表情
- 解析并应用 M370
- 复制状态 JSON
- 清空 saved_faces.json

ADC 调试：

- `battery-v` 与 `charge-v` 为调试覆写输入。
- `更新 ADC 状态` 更新 WebUI 状态，并发送辅助指令：`adc_debug_override`。

通信日志：

- 不使用浏览器持久缓存。
- 日志只保存在当前页面内存。
- 可下载为：`rina_370_firmware_log.txt`。
- 辅助命令输入框接受 JSON，例如：`{"cmd":"pause"}`。

固件接口：

- `读取固件状态`：GET `/api/status`。
- `发送暂停指令`：POST `/api/command`，`cmd:'pause'`。

资源 / 系统：

- 显示 expression parts format / version / part counts。
- 显示 `interface_mode = HTML generates M370 / firmware receives commands`。
- 显示 `default_faces_source = saved_faces.json` 和 `saved_faces_json = /resources/saved_faces.json`。
- hint 必须说明：表情部件资源由 HTML 合成为 M370；保存表情从 JSON 读取并通过 API 写回固件。

### 7.7 页面切换与 Activity guard 映射

页面切换时：

1. 点击页面菜单项后关闭菜单。
2. 更新 `current-page-label` 为 `<编号> <页面名>`。
3. nav item active 状态同步。
4. 页面 section active 状态同步。
5. 切换到 scroll 页面后重新计算 textarea 高度。
6. 页面切换本身可根据目标页进入对应模式分类，但真正发送/播放前仍必须执行 guard。

`modeForPage(id)` 映射：

| page id | mode |
|---|---|
| `scroll` | `scroll` |
| `custom` | `custom` |
| `parts` | `parts` |
| `debug` | `debug` |
| 其它 | `face/static` |

`classifyOutputMode(reason, playback)` 映射：

1. `playback==='scroll'` / `scroll_step` 或 reason 以 `text_scroll_` 开头 → `scroll`。
2. reason 以 `custom_` 开头 → `custom`。
3. reason 以 `parts_` 开头 → `parts`。
4. reason 以 `debug_` 开头 → `debug`。
5. reason 包含 `saved_face`、`B1`、`B2` → `face`。
6. 其它返回 playback 或 `static`。

### 7.8 M370 与矩阵渲染细节

HTML 必须维护以下映射：

1. `XY_TO_INDEX[ROWS][COLS]`：无效格为 `-1`。
2. `INDEX_TO_XY[370]`：每个 LED index 对应 `(x,y)`。
3. 生成顺序按照 `row_valid_x_ranges` 行优先扫描。
4. `renderMatrices()` 遍历所有 matrix views，根据 frameProvider 返回的 bool frame 切换 `.led.on`。
5. `matrix-basic` 使用 `currentFrame`。
6. `matrix-custom-edit` 使用 `editFrame`，可编辑。
7. `matrix-parts` 使用 `partsFrame`。
8. `matrix-scroll` 使用 `scrollFrame`。
9. `matrix-debug` 使用 `currentFrame` 且 compact。

---

## 8. 文字滚动最终实现

### 8.1 总体结构

文字滚动采用 **WebUI 预生成 M370 帧序列 + ESP32 30fps packed frame player**。

```text
WebUI textarea 输入 UTF-8 文本
  ↓
Canvas 按 16×16 字体栅格化每个 Unicode 字符
  ↓
按字形实际宽度 + 固定间距拼成长 bitmap
  ↓
按 22×18 可视窗口逐列切片
  ↓
只采样 370 个有效 LED 坐标
  ↓
编码为 M370 packed frames
  ↓
ESP32 TextScrollPlayer 以 30fps 播放
```

ESP32 不实时渲染 TTF，不实时做 Unicode 字形排版。

### 8.2 字体要求

所有文字滚动字体源统一为 **16×16**。

| 字符类型 | 字体要求 |
|---|---|
| 英文 / 数字 / ASCII 符号 | 优先 DotGothic16 |
| 中文 | 16×16 CJK 像素字体 fallback |
| 日文假名 | 16×16 CJK / Japanese pixel fallback |
| 日文汉字 | 16×16 CJK / Japanese pixel fallback |
| 未命中字符 | 16×16 fallback 或 tofu 方框 |

推荐字体栈：

```css
DotGothic16,
Fusion Pixel 16px,
WenQuanYi Bitmap Song,
Shinonome,
GNU Unifont,
Unifont JP,
Noto Sans CJK SC,
Noto Sans CJK JP,
Microsoft YaHei,
Yu Gothic,
Meiryo,
sans-serif
```

字体文件目录：

```text
esp32s3_firmware/data/resources/fonts/
```

允许放入：

```text
DotGothic16-Regular.ttf
```

字体打包原则：

1. 只打包授权允许分发的字体。
2. DotGothic16 可作为英文默认字体。
3. 不把授权不明确的字体打进固件 ZIP。
4. WebUI 可以通过 `@font-face` 优先加载项目资源字体，也可以 fallback 到本机字体。


### 8.2.1 HTML 字体与 glyph 常量

HTML 文字滚动模型以以下常量为准：

```js
const TEXT_SCROLL_FONT_MODEL = 'font_fusion_v3_fixed_16x16_dotgothic_tight_spacing';
const TEXT_SCROLL_GLYPH_CELL = 16;
const TEXT_SCROLL_GLYPH_TOP = 1;
const TEXT_SCROLL_GLYPH_Y = TEXT_SCROLL_GLYPH_TOP + TEXT_SCROLL_GLYPH_CELL / 2;
const TEXT_SCROLL_CHAR_SPACING = 2;
const TEXT_SCROLL_SPACE_COLUMNS = 4;
const TEXT_SCROLL_ALPHA_THRESHOLD = 32;
const TEXT_SCROLL_LUMA_THRESHOLD = 32;
```

字符分类：

| 类别 | Unicode 范围 / 条件 | 字体栈 |
|---|---|---|
| space | `' '` | latin stack，但宽度固定 4 columns |
| ASCII-like | `0x20..0x7E` | latin stack |
| kana | Hiragana/Katakana/Halfwidth Kana | kana stack |
| CJK | CJK Unified / Extension / Compatibility / Supplement | cjk stack |
| fallback | 其它字符 | fallback stack |

HTML 当前字体栈必须保留：

```js
latin:    '"DotGothic16","DotGothic16 Regular","Fusion Pixel 16px Monospaced","Fusion Pixel 16px Proportional","GNU Unifont","Unifont JP",ui-monospace,Menlo,Consolas,monospace'
kana:     '"DotGothic16","Fusion Pixel 16px Proportional","Shinonome","GNU Unifont","Unifont JP","Yu Gothic","Meiryo",sans-serif'
cjk:      '"DotGothic16","Fusion Pixel 16px Proportional","WenQuanYi Bitmap Song","Shinonome","GNU Unifont","Unifont JP","Noto Sans CJK SC","Noto Sans CJK JP","Microsoft YaHei","Yu Gothic","Meiryo",sans-serif'
fallback: '"DotGothic16","GNU Unifont","Unifont JP","Noto Sans CJK SC","Noto Sans CJK JP","Microsoft YaHei","Yu Gothic","Meiryo",system-ui,sans-serif'
```

### 8.3 字形栅格化

每个字符先渲染到 16×16 cell：

| 参数 | 值 |
|---|---:|
| glyph cell width | 16 |
| glyph cell height | 16 |
| virtual matrix height | 18 |
| y offset | 1 |
| 显示行 | 第 1 到第 16 行 |
| 顶部空行 | 第 0 行 |
| 底部空行 | 第 17 行 |

Canvas 栅格化要求：

1. 使用 1-bit 结果，不使用半透明灰阶输出到 M370。
2. alpha 阈值建议 `32`。
3. luma 阈值建议 `32`。
4. 每个 glyph 在 16×16 cell 内渲染。
5. Latin / 数字 / ASCII 符号渲染后裁剪左右空白边界，避免字符间距过大。
6. CJK / Kana 默认使用 16×16 cell；如有边界裁剪，也不得破坏 16px 高度和整体可读性。

### 8.4 字符间距

间距规则必须固定：

| 场景 | 要求 |
|---|---:|
| 两个非空字符之间 | 2 columns |
| 空格 U+0020 | 4 columns |
| 连续空格 | 每个空格 4 columns |
| 行首 / 行尾 | 不额外添加 2 columns |
| 左侧滚入 padding | 22 columns |
| 右侧滚出 padding | 22 columns |

示例：

```text
AB      = A + 2 columns + B
中文    = 中 + 2 columns + 文
A中     = A + 2 columns + 中
A B     = A + 4 columns + B
A  B    = A + 4 columns + 4 columns + B
```

### 8.5 滚动帧生成

可视窗口：

| 项目 | 值 |
|---|---:|
| width | 22 columns |
| height | 18 rows |
| valid LED | 370 cells |

帧生成：

```text
for offset in 0 .. textBitmapWidth - 22:
  window = textBitmap[offset : offset + 22, 0 : 18]
  m370 = encodeValidCellsOnly(window)
  append frame
```

要求：

1. 无效格不编码为 LED。
2. 无效格不显示、不发送。
3. 每帧编码为 47 bytes packed binary 或 93 hex M370 字符串。
4. WebUI 可以内部保存 packed frames，避免大量 hex string 占用内存。
5. 发送到 ESP32 时优先发送 packed binary chunk。
6. 调试时可以生成 M370 hex，但普通 UI 不显示。

### 8.6 TextScrollPlayer

ESP32 侧播放器只负责 packed frame playback。

常量：

```cpp
M370_LED_COUNT = 370;
M370_BYTES_PER_FRAME = 47;
TEXT_SCROLL_FPS = 30;
TEXT_SCROLL_FRAME_MS = 1000 / 30;
TEXT_SCROLL_MAX_FRAMES_DEFAULT = 1800;
```

状态：

```cpp
enum class TextScrollState {
    Idle,
    Loading,
    Ready,
    Playing,
    Paused,
};
```

接口：

```cpp
bool beginUpload(const TextScrollConfig& cfg);
bool writeChunk(uint16_t startFrame, const uint8_t* data, size_t len);
bool finishUpload();
void play(uint32_t nowMs = 0);
void pause();
void stop(bool clearFrame);
bool tick(uint32_t nowMs, M370Frame& outFrame);
bool currentFrame(M370Frame& outFrame) const;
```

播放器要求：

1. 只接受 30fps。
2. 只接受 `47 bytes/frame`。
3. 上传期间状态为 `Loading`。
4. `finishUpload()` 后状态为 `Ready`。
5. `play()` 后状态为 `Playing`。
6. `tick()` 只在需要输出新 30fps frame 时返回 true。
7. 最后 2 padding bits 必须强制清零。
8. `stop(true)` 清空 frames 并释放内存。
9. 切换到非文字模式时必须调用 stop 或等效终止逻辑。
10. 不保留自动恢复滚动逻辑。

### 8.7 文字滚动 API

建议 API：

```text
POST /api/text-scroll/begin
POST /api/text-scroll/chunk
POST /api/text-scroll/finish
POST /api/text-scroll/play
POST /api/text-scroll/pause
POST /api/text-scroll/stop
GET  /api/text-scroll/status
```

`begin` payload：

```json
{
  "fps": 30,
  "frame_count": 123,
  "bytes_per_frame": 47,
  "loop": true,
  "max_frames": 1800
}
```

`chunk` payload：

- `start_frame`
- binary body 或 base64 packed data
- 长度必须是 `47 × N`

错误处理：

| 情况 | 行为 |
|---|---|
| fps 不是 30 | 拒绝 |
| bytes_per_frame 不是 47 | 拒绝 |
| frame_count 为 0 | 拒绝 |
| frame_count 超过限制 | 拒绝 |
| chunk 起点越界 | 拒绝 |
| chunk 长度不是 47 的倍数 | 拒绝 |
| 上传未 finish 就播放 | 拒绝 |
| 其它模式抢占 | 终止文字滚动，不自动恢复 |

---

## 9. 状态模型

### 9.1 HTML 全局 state

以 HTML 的 `state` 为准：

```json
{
  "mode": "手动",
  "faceIndex": 0,
  "brightness": 50,
  "color": "#f971d4",
  "parentColorId": 0,
  "selectedChildColor": null,
  "colorSelection": "parent",
  "playback": "idle",
  "apIp": "192.168.1.14",
  "autoInterval": 3000,
  "refreshPolicy": "dirty-frame / 按需刷新",
  "lastRefreshReason": "init",
  "refreshCount": 0,
  "textScrollActive": false,
  "actualFps": 0,
  "dpsActive": false,
  "batteryV": 7.42,
  "batteryPercent": 68,
  "chargeV": 5.10,
  "charging": true
}
```

固件 API 可以使用英文 snake_case 字段，但 WebUI 内部必须兼容以上字段名或提供一一映射。

### 9.2 其它运行时对象

```js
currentFrame = bool[370]
editFrame    = bool[370]
partsFrame   = bool[370]
scrollFrame  = bool[370]
selectedTool = 'on' | 'off' | 'toggle'
selectedCall = { leye:'101', reye:'201', mouth:'301', cheek:'400' }
partsSymmetry = false
defaultFaces = []
userFaces = []
getAllFaces() = defaultFaces + userFaces sorted by order
logs = loadLogs()
matrixViews = []
```


文字滚动对象：

```js
scroll = {
  timer: null,
  active: false,
  paused: false,
  offset: 0,
  frameIndex: 0,
  frames: [],
  m370: [],
  signature: '',
  dirty: true,
  frameCounter: 0,
  fpsStarted: performance.now(),
  measuredFps: 0
}
```

### 9.3 playback 枚举与显示值

WebUI 允许出现以下 playback 值：

```text
idle
face
custom
parts
scroll
scroll_paused
scroll_step
battery
battery_detail
network_info
overlay
debug
```

显示规则：

1. 文字滚动页：`state.textScrollActive ? (scroll.paused ? 'paused' : 'playing') : 'idle'`。
2. Debug 页显示原始 `state.playback`。

### 9.4 状态要求

1. 任意时刻只有一个 active playback owner。
2. 新 owner 输出前必须终止旧 owner。
3. owner 终止后不恢复。
4. GPIO 操作和 WebUI 操作必须更新同一份 state。
5. 颜色/亮度变化必须立即刷新预览和 DPS 状态。
6. `refreshCount` 在 `setCurrentFrame()` 后递增。
7. `lastRefreshReason` 必须记录最近一次输出原因。
8. `refreshPolicy` 在文字滚动播放时为 `text_scroll_30fps`，其它情况下为 dirty-frame / 按需刷新。
9. Debug 页可以显示 refreshPolicy/lastRefreshReason/actualFps；普通页面不新增这些字段。

---

## 10. API 规划

当前重构版 API 原则：**HTML 做数据处理，固件做接收、保存和 LED 执行**。

### 10.1 固件接口总表

| Endpoint | Method | 用途 |
|---|---|---|
| `/api/frame` | POST | 接收单帧 M370 LED 输出 |
| `/api/command` | POST | 接收颜色、亮度、模式、暂停、按钮、ADC 调试等辅助指令 |
| `` | GET | 可选读取默认表情 order/name 覆盖数据；统一 saved_faces.json 默认表情仍为基准数据 |
| `` | POST | 写回默认表情 order/name 覆盖数据；用于排序和重命名，禁止删除默认表情 |
| `/api/saved_faces` | GET | 读取用户保存表情 JSON |
| `/api/saved_faces` | POST | 写回用户保存表情 JSON 到 `/resources/saved_faces.json` |
| `/api/status` | GET | 读取固件状态 |

### 10.2 `/api/frame`

请求：

```json
{
  "type": "m370_frame",
  "m370": "M370:<93 hex>",
  "reason": "custom_face_send|parts_compose_send|text_scroll_30fps|debug_m370_apply|...",
  "mode": "idle|scroll|scroll_step|battery|network_info|...",
  "at": 1710000000000
}
```

要求：

1. 固件只解析 `m370`。
2. `m370` 必须是 `M370:<93 hex>` 或可被规范化为此格式。
3. 固件不得从该 payload 读取颜色或亮度；颜色/亮度由 `/api/command` 更新全局 renderer 状态。
4. 固件必须将 M370 解码为 370-bit on/off frame 后进入统一 LedRenderer。
5. 文字滚动播放期间 HTML 以 30fps 调用该接口。

### 10.3 `/api/command`

通用格式：

```json
{
  "cmd": "set_brightness|set_color|set_mode|set_auto_interval|terminate_other_activities|pause|button|adc_debug_override|raw_aux_command",
  "reason": "ui source / debug source",
  "payload": {},
  "at": 1710000000000
}
```

命令要求：

| cmd | payload | 固件行为 |
|---|---|---|
| `set_brightness` | `{raw:50}` | 更新全局 brightness raw，范围 10~200 |
| `set_color` | `{hex:'#f971d4'}` | 更新全局普通显示颜色 |
| `set_mode` | `{mode:'手动'|'自动'}` | 更新保存表情 A/M 模式 |
| `set_auto_interval` | `{ms:3000}` | 更新自动保存表情间隔 |
| `terminate_other_activities` | `{targetMode, ended:[...]}` | 停止非目标 activity，不自动恢复 |
| `pause` | `{target:'all'}` | 停止所有播放/滚动/自动 activity |
| `button` | `{button:'B1'|'B2'|'B3'|'B4'|'B5'|'B6S'|'B6L'|'B3B1'|'B3B2'|'B6B3'}` | 与物理按钮同语义 |
| `adc_debug_override` | `{vbat:7.42, vcharge:5.10}` | 仅用于调试覆写 / 测试状态 |
| `raw_aux_command` | 任意 JSON | 调试入口，正式固件可拒绝或记录 |

### 10.4 `/api/saved_faces`

只保留一个表情库接口：

```text
GET  /api/saved_faces
POST /api/saved_faces
```

该接口读写同一个文件：

```text
/resources/saved_faces.json
```

统一文件中的 `faces[]` 同时包含：

| face type | 用途 | 删除规则 | 排序/重命名 |
|---|---|---|---|
| `default` | 默认表情，默认启动项为 `face_07_triangle_eyes_frown` | 不可删除 | 可排序、可重命名，写回同一文件 |
| `custom` | 用户自定义画板保存表情 | 可删除 | 可排序、可重命名 |
| `parts` | 表情部件组合保存表情 | 可删除 | 可排序、可重命名 |

GET 返回：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": {"leds":370,"m370HexChars":93},
  "startupDefaultId": "face_07_triangle_eyes_frown",
  "updatedAt": "ISO-8601|null",
  "faces": []
}
```

POST 请求：

```json
{
  "path": "/resources/saved_faces.json",
  "reason": "reorder_faces|save_user_face|rename_default_face|rename_user_face|delete_user_face|import_saved_faces_json|clear_user_saved_faces",
  "document": {
    "format": "rina_faces_370_v2",
    "version": 2,
    "category": "unified_saved_faces",
    "matrix": {"leds":370,"m370HexChars":93},
    "startupDefaultId": "face_07_triangle_eyes_frown",
    "faces": []
  }
}
```

固件校验要求：

1. `document.format == rina_faces_370_v2`。
2. `document.category == unified_saved_faces`。
3. `faces` 必须是数组。
4. 每个 face 必须包含 `id`、`name`、`type`、`m370`、`order`。
5. 每个 `m370` 必须能解析为 370-bit frame。
6. `type:"default"` 项必须保留，不能因删除、自定义保存、导入或清空用户表情而缺失。
7. `type:"default"` 项允许更新 `name`、`order`、`updatedAt`；不可通过删除操作移除。
8. `type:"custom"` / `type:"parts"` 允许保存、重命名、排序、删除和导入。
9. 固件返回保存结果和 face 数量。
10. WebUI 写入失败时允许用户下载同一个完整 `saved_faces.json` 手动备份。

### 10.5 `/api/status`

返回建议：

```json
{
  "ap": {"ssid":"RinaChanBoard-ESP32S3", "ip":"192.168.1.14"},
  "renderer": {"brightness":50, "color":"#f971d4", "lastFrameReason":"...", "refreshCount":0},
  "activity": {"mode":"手动", "playback":"idle", "textScrollActive":false},
  "power": {"vbat":7.42, "batteryPercent":68, "vcharge":5.10, "charging":true},
  "storage": {"defaultFacesSource":"saved_faces.json", "defaultFacesCount":11, "savedFacesPath":"/resources/saved_faces.json", "savedFacesCount":0}
}
```

### 10.6 禁止 API

不得重新引入：

- `/api/media/*`
- `/api/faces/reset-local-interface-storage`
- 旧 16×18 FaceString 输出接口
- 会绕过 M370 的 LED 直接写入接口
- 需要固件重新处理表情部件组合或文字 rasterize 的接口

## 11. 资源、保存 JSON 与字体文件

### 11.1 字体资源

```text
data/resources/fonts/
├── DotGothic16-Regular.ttf
└── README.md
```

`@font-face` 按 HTML 保留：

```css
@font-face {
  font-family: "DotGothic16";
  src: local("DotGothic16"),
       local("DotGothic16 Regular"),
       url("../resources/fonts/DotGothic16-Regular.ttf") format("truetype"),
       url("/resources/fonts/DotGothic16-Regular.ttf") format("truetype");
  font-display: swap;
}
```

`README.md` 必须说明：

1. 英文默认字体为 DotGothic16。
2. 所有文字滚动字体源按 16×16 处理。
3. CJK fallback 取决于浏览器可用字体或已放入资源目录的授权字体。
4. 不在 ESP32 上实时渲染 TTF。
5. WebUI 生成 M370 frame 后上传给 ESP32 播放。

### 11.2 expression parts 资源

正式资源路径：

```text
data/resources/expression_parts_370_deduped.json
```

HTML 当前内嵌 `EXPRESSION_PARTS`，正式固件可改为从资源 JSON 加载，但数据结构必须兼容：

- `format`
- `version`
- `matrix`
- `encoding`
- `layout`
- `call`
- `groups`
- `counts`
- `parts`

关键要求：

1. `parts[*].m370` 是 WebUI 组合 canonical 数据。
2. `strip_indices` 只做 fallback。
3. `preview` / `row_hex` 用于 mini preview。
4. `call.ids` 决定显示顺序和显示编号。
5. `call.map` 决定调用 ID 到真实 asset 的解析。
6. `cheek=400` 必须作为空脸颊调用保留。

### 11.3 统一 `saved_faces.json` 表情库

表情库只使用一个文件，不再拆分默认表情文件、用户表情文件或顺序文件：

```text
/resources/saved_faces.json
```

该文件同时保存：

1. 默认表情：`type: "default"`。
2. 自定义表情：`type: "custom"`。
3. 部件组合表情：`type: "parts"`。
4. 用户手动排序：每个 face 的 `order` 字段。
5. 用户重命名：每个 face 的 `name` 字段。

统一 face schema：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "m370HexChars": 93 },
  "startupDefaultId": "face_07_triangle_eyes_frown",
  "updatedAt": "ISO-8601|null",
  "faces": [
    {
      "id": "face_07_triangle_eyes_frown",
      "name": "07 Triangle Eyes Frown",
      "type": "default",
      "m370": "M370:<93 hex>",
      "order": 0,
      "editable": true,
      "deletable": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "ISO-8601|null",
      "updatedAt": "ISO-8601|null",
      "call": null
    }
  ]
}
```

规则：

1. 默认表情不写入 HTML。
2. 默认表情不使用独立 `default_faces.json`。
3. 默认表情不使用单独 `face_order.json`。
4. 默认表情由 `type:"default"` 标识。
5. `type:"default"` 表情不可删除。
6. `type:"default"` 表情可以重命名。
7. `type:"default"` 表情可以和 `custom` / `parts` 一起排序。
8. 排序结果直接写回同一个 `saved_faces.json` 的 `order` 字段。
9. 保存新自定义表情时追加 `type:"custom"`。
10. 保存新部件组合表情时追加 `type:"parts"`，并可记录 `call`。
11. WebUI 列表必须显示属性 badge：`默认表情` / `自定义表情` / `部件表情`。

#### 11.3.1 `file://` 本地文件模式

很多浏览器会阻止 `file://` 页面自动读取旁边的 JSON 文件。因此正式 WebUI 必须提供：

- `导入 saved_faces.json`：手动选择统一表情库文件并加载。
- `下载 saved_faces.json`：导出当前内存中的完整统一表情库。

在 ESP32 或本地静态服务器环境中，HTML 可以自动读取 `/resources/saved_faces.json`；在纯 `file://` 环境中，手动导入是可靠路径。

#### 11.3.2 固件接口

只保留一个表情库接口：

```text
GET  /api/saved_faces
POST /api/saved_faces
```

`POST /api/saved_faces` 保存完整统一文档，不区分默认表情文件和用户表情文件。固件端建议校验：

1. `format === "rina_faces_370_v2"`。
2. 所有 `m370` 均为 `M370:<93 hex>`。
3. `type:"default"` 项不可被删除；至少不得接受 UI 发出的删除默认项操作。
4. `order` 必须可排序且写回同一个 JSON。

### 11.4 assets 总原则

表情、文字滚动生成帧最终都应转换为 M370-compatible frame。

资源格式原则：

1. 尽量使用 packed binary。
2. 不重复保存可从 M370 恢复的信息。
3. 不保存颜色和亮度到普通 frame。
4. 颜色和亮度由全局状态决定。

---

## 12. 需要删除或不得重新引入的内容（HTML 对齐版）

最终 `plan.md` 和实现中不得包含：

1. 旧的 5×7 ASCII-only 滚动文字实现作为当前路径。
2. 12px / 14px / 16px 混合字号策略。
3. 文字滚动字号调整 UI。
4. 左侧常驻页面按钮列表。
5. 可见原生 select dropdown。
6. 与 HTML 当前 dropdown 冲突的另一套 dropdown 组件。
7. 会自动恢复旧模式的暂停逻辑。
8. 多个模式同时运行 timer。
9. ESP32 运行时 TTF 渲染路径。
10. STA WiFi、WiFi 扫描、外部路由器配置功能。
11. 使用 `strip_indices` 作为正常 WebUI M370 组合路径。
12. 绕过 `setCurrentFrame()` / Activity guard 直接刷新 LED 的功能入口。
13. 让 preview brightness 跟随 raw 亮度变暗的 UI 行为。
14. 在文字滚动页显示完整帧序列、offset、当前 M370、复制当前 M370。
15. 在普通主页面新增 refreshPolicy / lastRefreshReason / actualFps 等调试字段。

以下 HTML 当前存在的内容必须保留，不再列为删除项：

1. hidden select 作为自定义 dropdown 的状态桥接层。
2. 6.2 自定义表情页的 M370 textarea、复制 M370、导出文本。
3. 6.3 表情部件页的组合调用文本和复制组合 M370。
4. 6.5 调试页的 hint、资源状态、状态 JSON、日志下载、saved_faces.json 保存清空。

---

## 13. 验收标准

### 13.1 构建验收

1. PlatformIO Arduino Core 编译通过。
2. LittleFS / data 上传脚本可用。
3. WebUI HTML / JS 无语法错误。
4. 固件启动后创建 AP：`RinaChanBoard-ESP32S3`。
5. 浏览器访问 `192.168.1.14` 可打开 WebUI。

### 13.2 M370 验收

1. 任意 M370 输入必须严格校验 93 hex。
2. 370 个有效 bit 正确映射到 22×18 有效格。
3. 最后 2 个 padding bit 不点亮任何 LED。
4. 预览和实际 LED 输出一致。
5. 无效格隐藏且不可点击。

### 13.3 文字滚动验收

测试文本：

```text
RinaChanBoard 370 LED DEMO 中文 こんにちは 璃奈ちゃんボード
```

必须满足：

1. 中日英混合显示正常。
2. 英文和数字使用 DotGothic16 或等效 fallback。
3. 所有 glyph 按 16×16 源 cell 栅格化。
4. 英文和数字不会出现 16 列全宽导致的大空隙。
5. 两个非空字符之间固定 2 columns。
6. 空格固定 4 columns。
7. 文字在 18 行中垂直位置为上 1 行空白、下 1 行空白。
8. 播放期间 30fps 连续推进。
9. 切换到其它模式时文字滚动立即终止。
10. 其它模式结束后文字滚动不自动恢复。

### 13.4 UI 验收

1. Header 在最顶部。
2. 页面选择 dropdown 在 header 下方。
3. 页面选择 dropdown 点击三横按钮后才展开。
4. dropdown 展开后在最上图层，不被任何 panel 或 matrix 覆盖。
5. 所有 dropdown toggle 和 option 统一 46px 高度、14px 圆角、深色渐变、右侧 caret、hover 上浮、focus glow。
6. 普通页面不显示已删除说明段落。
7. 文字输入框可自动增高并显示所有文字。
8. 移动端矩阵拖动绘制不会触发页面滚动。


补充 HTML 对齐验收：

1. 页面 selector 位于 header 下方，z-index 高于所有 card/matrix/dropdown。
2. 页面 selector 支持点击外部关闭和 Esc 关闭。
3. 所有 dropdown 视觉上为 button menu；原生 select 不可见。
4. 父/子颜色 dropdown 完整包含 HTML 当前全部颜色。
5. 6.1 宽屏左右排列，窄屏上下堆叠。
6. 所有矩阵随容器宽度缩放，不能横向溢出。
7. 无效 LED 格完全隐藏且不可点击。
8. 移动端拖动画板不触发页面滚动。
9. 统一表情列表支持应用、上下移动、拖拽排序；type:"default" 的默认表情不可删除但可重命名，用户表情可重命名/删除。
10. 6.3 部件列表横向滚动，mini preview 和显示编号正确。
11. 左右眼对称对手动选择和随机选择均有效。
12. 6.4 textarea 自动增高，速度输入影响滚动 offset。
13. 6.5 状态 JSON、日志下载、清空用户 saved_faces.json、ADC 调试可用；默认表情不被清空。

### 13.5 Activity guard 验收

1. 自动保存表情模式中启动文字滚动：自动模式切为手动，文字结束后不恢复自动。
2. 文字滚动中发送自定义表情：文字滚动停止，发送表情，之后不恢复滚动。
3. 文字滚动中发送 debug 全亮：文字滚动停止，debug 全亮输出，之后不恢复滚动。
4. 任意时刻最多一个 active timer 输出 LED。

---

## 14. 实现优先级

### Phase 0：清理和常量收拢

- 建立 PlatformIO Arduino Core 项目。
- 收拢 Config / MatrixMap / M370 常量。
- 删除旧兼容代码和旧 UI 文案。
- 建立统一状态模型。

### Phase 1：LED 输出管线

- 实现 M370 编解码。
- 实现 LedRenderer。
- 实现 DPS 估算。
- 实现 dirty-frame 刷新。

### Phase 2：ActivityManager

- 实现单 owner playback 状态。
- 实现 one-way terminate guard。
- 接入所有发送入口。

### Phase 3：WebUI 基础结构

- Header 顶部化。
- 三横按钮页面 dropdown。
- 所有 dropdown 改为统一自定义 menu。
- 按 HTML 保留 hidden select 桥接式自定义 dropdown、hint、调试状态；只移除 HTML 不再使用的旧导航和旧兼容路径。

### Phase 4：文字滚动

- 实现自动增高 textarea。
- 实现 16×16 字体栅格化。
- 接入 DotGothic16。
- 实现 glyph 裁剪、2 column 字距、4 column 空格。
- 实现 M370 packed frame 生成。
- 实现上传和 30fps 播放。

### Phase 5：页面功能

- 6.1 基础控制。
- 6.2 自定义表情。
- 6.3 表情部件组合和左右眼对称。
- 6.4 文字滚动：速度输入、自动增高、30fps 播放、单帧推进。
- 6.5 调试：GPIO、ADC、M370、状态 JSON、日志下载、用户 saved_faces.json 清空，默认表情保留。

### Phase 6：验收和回归

- JS 语法检查。
- PlatformIO build。
- WebUI 手动测试。
- ESP32 AP 连接测试。
- LED 实机输出测试。
- Activity guard 互斥测试。

---

## 15. 最终交付要求

每次交付必须包含：

1. 完整 ZIP。
2. ZIP 根目录必须是：

```text
esp32s3_firmware/
```

3. 根目录包含最新 `plan.md`。
4. 如果包含代码更新，必须同步更新 `EXTERNAL_CODE_COMMENTS.txt`。
5. 如提供 PowerShell 脚本，必须同时提供可下载 `.ps1` 和完整运行命令。
6. 不得在 ZIP 中混入旧版本 HTML、旧计划、旧兼容文档或不再调用的实验文件。


---

## 追加修订：统一 `saved_faces.json` 表情库（当前实现）

本轮以用户最新要求为准，覆盖旧的“HTML 内置默认表情”、“单独默认表情 JSON”和“单独默认顺序 JSON”方案。

### 数据源

只保留一个表情库文件：

```text
/resources/saved_faces.json
```

该文件同时保存：

1. 默认表情：`type: "default"`
2. 自定义表情：`type: "custom"`
3. 部件组合表情：`type: "parts"`
4. 用户手动排序：每个 face 的 `order` 字段
5. 用户重命名：每个 face 的 `name` 字段

### 统一 schema

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "m370HexChars": 93 },
  "startupDefaultId": "face_07_triangle_eyes_frown",
  "updatedAt": null,
  "faces": [
    {
      "id": "face_07_triangle_eyes_frown",
      "name": "07 Triangle Eyes Frown",
      "type": "default",
      "m370": "M370:<93 hex>",
      "order": 7,
      "editable": true,
      "deletable": false,
      "sourceFile": "saved_faces.json"
    }
  ]
}
```

### 默认表情规则

- 默认表情不再写入 HTML。
- 默认表情不再使用 ``。
- 默认表情不再使用独立顺序 JSON。
- 默认表情通过 `type: "default"` 标识。
- `type: "default"` 表情不可删除。
- `type: "default"` 表情可以重命名。
- `type: "default"` 表情可以和用户保存表情一起排序。
- 排序结果直接写回同一个 `saved_faces.json` 的 `order` 字段。

### WebUI 行为

6.2 自定义表情页和 6.3 表情部件页底部的 `M370 / 保存管理` panel 必须读取并渲染同一个统一表情库。保存新自定义表情或部件表情时，只向 `faces[]` 追加 `type:"custom"` 或 `type:"parts"` 项，不得写入默认表情类型。

浏览器以 `file://` 直接打开 HTML 时，很多浏览器会阻止自动读取旁边的 JSON 文件。WebUI 必须提供 `导入 saved_faces.json` 和 `下载 saved_faces.json` 按钮作为本地文件模式的读写路径；在 ESP32 或本地静态服务器模式下，WebUI 可自动读取 `/resources/saved_faces.json` 并通过 `/api/saved_faces` 写回。

### 固件接口

只需要一个表情库接口：

```text
GET  /api/saved_faces
POST /api/saved_faces
```

`POST /api/saved_faces` 保存完整统一文档，不区分默认表情和用户表情文件。固件端必须拒绝删除或缺失 `type:"default"` 项的异常写入，或至少在写入前校验默认项不可被 UI 删除。

---

## 追加修订：2026-05-09 当前落地实现记录

本节只记录本轮已经写入工作区的实现与验证结果，不重复前文的协议定义和页面需求。

### 固件与工程文件

1. 已建立最小 PlatformIO Arduino Core 工程：
   - `platformio.ini`
   - `partitions.csv`
   - `src/main.cpp`
   - `README.md`
2. 当前固件为单文件最小实现，先满足 AP WebServer、M370 接收、LED 输出和统一表情库读写；后续如继续模块化，可再拆为前文规划的 `M370`、`LedRenderer`、`WebApi` 等模块。
3. LED 当前使用 `Adafruit NeoPixel` 驱动，370 颗 WS2812/NeoPixel 串接在 `GPIO2`，物理走线为蛇形：逻辑第 0 行正向，第 1 行反向，后续交替。`M370` bit `0..369` 保持逻辑 row-major 顺序，固件输出时再映射到物理蛇形 LED index。
4. AP 配置已落地：
   - SSID：`RinaChanBoard-ESP32S3`
   - 密码：`rinachan`
   - IP/Gateway：`192.168.1.14`
5. LittleFS 静态文件服务已落地，`data/` 作为文件系统根目录上传后提供：
   - `/index.html`
   - `/resources/saved_faces.json`
6. 当前 `data/` 实际大小为 `160472` bytes，小于 `partitions.csv` 中 `0x1A0000` LittleFS 分区；本轮不需要扩容分区。

### 固件 API 当前行为

1. `/api/frame` 已实现单帧 M370 输出：
   - 只解析 `m370`
   - 读取 `reason`
   - 优先读取 `mode`，兼容旧字段 `playback`
   - 不从 frame payload 读取颜色或亮度
2. `/api/command` 已实现全局 renderer 辅助指令：
   - `set_color`
   - `set_brightness`
   - `set_mode`
   - `pause`
   - `resume`
   - `button`
   - 兼容记录 `set_auto_interval`、`terminate_other_activities`、`adc_debug_override`、`raw_aux_command`
3. 亮度 raw 范围已在固件侧 clamp 到 `10..200`，与 WebUI 和本计划一致；`/api/status` 返回 `brightnessMin` 与 `brightnessMax`。
   - WebUI 的百分比参考仍按 `raw / 255` 显示，因此最大 raw `200` 显示约为 `78%`；这是亮度上限/功率保护语义，不应改成 `raw / 200` 的 100% 显示。
4. `/api/saved_faces` 已实现统一表情库读写，并校验：
   - `category === "unified_saved_faces"`
   - `faces` 是数组
   - 每个非空 `m370` 可规范化为 `M370:<93 hex>`
   - 至少保留一个 `type:"default"` face
5. `/api/status` 已返回 AP、matrix、renderer、endpoint、storage、stats 基本状态。
6. LittleFS 挂载失败时，AP 仍启动；根页面和 `/index.html` 返回明确的 `uploadfs` 诊断页，同时 LED 显示红色错误提示，避免静默 404。

### WebUI 当前改动

1. 当前工作区只有一个 HTML 文件：`data/index.html`。
2. 已清理 `data/index.html` 中确认无效或重复的代码：
   - 合并重复的导航/选择下拉 CSS
   - 删除重复 CSS 声明
   - 删除空壳函数和死函数
   - 删除 `apiPost` 未使用参数
   - 删除未读取的 `scroll.m370`
   - 删除不存在 DOM 元素 `m370-short` 的残留引用
   - 合并重复的 `saved_faces.json` 常量用途
3. WebUI 发送 `/api/frame` 的 packet 已对齐为纯帧语义：
   ```json
   {"type":"m370_frame","m370":"M370:<93 hex>","reason":"...","mode":"...","at":0}
   ```
4. 颜色和亮度继续通过 `/api/command` 更新，不再夹带在普通 frame payload 中。

### 当前验证结果

1. `data/index.html` 内联脚本语法检查通过。
2. `data/resources/saved_faces.json` JSON 解析通过。
3. 默认表情中的 M370 格式检查通过。
4. `git diff --check` 对本轮修改文件无空白错误。
5. 当前环境未安装或未暴露 `pio/platformio` 命令，`pio run` 尚未能在本机执行；PlatformIO 编译、上传和实机 LED 输出仍需在具备 PlatformIO 的环境中验证。

### 已知未覆盖项

1. 当前固件是最小帧接收器，尚未实现物理按钮扫描、ADC 采样、DPS 电流限制、自动表情切换或文字滚动 packed binary 上传播放器。
2. `button` 指令当前只记录到状态中；实际 LED 变化仍由 WebUI 生成 M370 后通过 `/api/frame` 输出。
3. README 已记录当前烧录流程、AP 信息、GPIO2 LED 输出、亮度范围、frame/command 边界和 LittleFS 故障提示。


---

## LED 画板映射验证报告（自动生成）

> 验证时间：2026-05-09
> 验证范围：`data/index.html` 画板编辑器 ↔ M370 编码 ↔ 固件解码 ↔ 物理 LED 输出的完整链路

### 验证结论：逻辑 M370 映射正确，物理蛇形输出映射已修复

---

### 1. row_lengths 与 row_valid_x_ranges 一致性 ✓

每行的 `row_lengths[y]` 值与 `row_valid_x_ranges[y]` 的 `x1 - x0 + 1` 完全一致，18 行全部通过。
`sum(row_lengths) = 18+20+20+20+(22x9)+20+20+20+18+16 = 370 = TOTAL_LEDS` ✓

### 2. XY_TO_INDEX 构建顺序 ✓

逻辑扫描顺序：row 0->17，每行 x0->x1 正向；物理蛇形翻转只在固件 NeoPixel 输出层执行。
构建后 ledIndex = 370 ✓，无效格数量 = 396-370 = 26 ✓

### 3. 画板编辑器 -> M370 编码链路 ✓

```
用户点击画板 (x,y) 格子
  -> cell.dataset.idx = XY_TO_INDEX[y][x]
  -> editFrame[idx] = true
  -> frameToM370: bits[idx] = '1'  (MSB-first 打包)
  -> M370 第 idx 个 bit = 1
```

frame[idx] 直接对应 M370 的第 idx 个 bit，不存在二次映射或偏移。

### 4. 固件端解码链路 ✓

```cpp
// applyM370(): bit[n] = (nibble[n/4] >> (3 - n%4)) & 1  (MSB-first 展开)
// showCurrentFrame(): strip.setPixelColor(logicalToPhysicalLedIndex(i), frameBit(i) ? rgb : 0)
```

HTML 编码与固件解码保持逻辑 row-major 对称；固件输出层负责逻辑到物理蛇形走线的最终映射 ✓

### 5. 已修复：物理 LED 蛇形走线映射

**位置**：`src/main.cpp` 的 `logicalToPhysicalLedIndex()`、`data/index.html` 的 `EXPRESSION_PARTS.matrix.serpentine = true`

**处理**：
- M370 仍作为逻辑画面协议：370 个有效格按 row-major 编码，93 hex，MSB-first。
- 固件写入 NeoPixel 前调用 `logicalToPhysicalLedIndex()`，将逻辑索引映射到蛇形物理索引。
- 蛇形规则为 0 基奇数行反向，也就是第 2、4、6... 行反向。
- WebUI 的 legacy `strip_indices` fallback 会把物理蛇形索引映射回逻辑 M370 cell。

**影响评估**：既修复实物显示方向，又不需要迁移现有 `saved_faces.json` 与部件 `m370` 数据。

**修复结果**：已将 `serpentine` 恢复为 `true`，并在固件输出层实际使用蛇形物理映射。

### 6. 物理接线前提（代码层无法验证）

整个映射正确性关键前提：物理 LED strip 的接线顺序必须是从 row 0 开始蛇形连续焊接。
即：LED #0 = (x=2, y=0)，LED #17 = (x=19, y=0)，LED #18 = (x=20, y=1)，LED #37 = (x=1, y=1)，后续逐行交替。

### 7. 汇总

| 检查项 | 结论 |
|-------|------|
| row_lengths 与 x_ranges 一致 | ✓ 正确 |
| sum(row_lengths) = 370 | ✓ 正确 |
| 无效格数量 = 26 | ✓ 正确 |
| XY_TO_INDEX 构建顺序 | ✓ 逻辑 row-major |
| frameToM370 编码 | ✓ MSB-first，无偏移 |
| 固件 applyM370 解码 | ✓ 与 HTML 编码对称 |
| 画板点击->物理 LED 映射 | ✓ 经固件蛇形映射后一一对应 |
| `serpentine: true` 元数据 | ✓ 与物理走线一致 |
| 物理接线顺序 | 🔲 需实机确认 |
