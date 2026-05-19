## 2026-05-15 电池低压未上电与充电显示规则

1. 电池 ADC 换算出的瞬时电池电压低于 5.0V 且未检测到充电输入时，固件进入低压未上电状态。
2. 低压未上电状态下，WebUI 显示 `未上电 0.00 V`，电池圆点为灰色；该读数不会写入最低电压记录，也不会触发自动 min/max 校准收缩。
3. 检测到充电输入时，即使电池电压低于 5.0V，也退出未上电视图：WebUI 显示当前电池电压；电池圆点按正常电量阈值显示，不再因充电输入强制变为红色。
4. 充电状态下冻结最低电压记录；`reset_battery_min` 也不会把充电/低压状态下的当前电压保存为最低值。
5. 调试页新增低压未上电锁定、电池瞬时电压、未上电电压阈值，方便确认低压/充电状态切换。

## 2026-05-15 WebUI GNU Unifont 严格内嵌 / 禁止外置 Unifont

1. `data/index.html` 中的 GNU Unifont `@font-face` 只允许 `data:font/woff2;base64,...`。
2. 删除 `data/resources/fonts/unifont.woff2`，LittleFS 运行资源中不再保存任何可被 WebUI 加载的外置 Unifont 文件。
3. `run_rinachan_unifont.ps1` 构建修改后的 GNU Unifont 子集时只使用临时 WOFF2，嵌入 `index.html` 后立即删除临时文件。
4. 运行脚本会校验：GNU Unifont `@font-face` 数量必须为 1；不得出现 `local()`、`resources/fonts/unifont.woff2`、`/resources/fonts/unifont.woff2` 或 `unifont.woff2` 外置源；`data/resources/fonts/unifont.woff2` 不得存在。
5. Ark12 文字滚动资源保持独立，仍可作为 LittleFS 外置资源使用；本规则仅禁止 WebUI 使用外置 GNU Unifont。

## 2026-05-15 WebUI GNU Unifont 完全内嵌 / 修改版字体同步

本次覆盖规则：

1. 普通 WebUI 页面字体仍统一使用 `font-family: "GNU Unifont"`，文字滚动输入框和 LED rasterizer 继续使用 Ark Pixel 12px。
2. `data/index.html` 中的 GNU Unifont `@font-face` 只允许使用 base64 `data:font/woff2`，禁止 `local()`、`/resources/fonts/unifont.woff2` 或其它外部字体源。
3. 修改后的 `data/resources/fonts/unifont.woff2` 是规范构建产物；运行脚本每次重建后都会把同一份 WOFF2 字节重新嵌入 `data/index.html`。
4. `tools/build_unifont_webui_subset_from_png.py` 现在会替换或插入完整的 GNU Unifont `@font-face` 块，而不是只替换旧 base64 片段；即使 HTML 里曾回退成外部 URL，也会被强制改回内嵌字体。
5. `run_rinachan_unifont.ps1` 新增内嵌校验：检查 GNU Unifont `@font-face` 数量、禁止外部源、解码 base64，并要求内嵌字体 SHA256 与 `data/resources/fonts/unifont.woff2` 完全一致。
6. `data/resources/fonts/README.md` 明确说明 `unifont.woff2` 是参考/校验用的修改版字体文件，实际 WebUI 字体由 `index.html` 内嵌 data URL 提供。

## 2026-05-14 WebUI GNU Unifont 子集完整字符覆盖检查

本次修复点：

1. `tools/build_unifont_webui_subset_from_png.py` 改为从当前 WebUI 文件、`saved_faces.json`、运行配置和电池校准配置收集字符，并在生成后校验字体 cmap。
2. 生成 `data/resources/fonts/unifont.woff2` 后，同步把同一个 WOFF2 以 base64 `data:font/woff2` 形式重新嵌入 `data/index.html`，保持 WebUI 字体内嵌。
3. 无法从 GNU Unifont BMP PNG 生成的字符只记录并跳过，不强行加入 subset；本轮实际 WebUI 可见/运行文字全部可覆盖。
4. 保存表情操作栏恢复使用原图标按钮：`✏️`、`🗑️`、`💡`；GNU Unifont subset 构建仍会跳过 PNG/BMP 表无法生成的 emoji / variation selector，不强行加入。
5. `run_rinachan_unifont.ps1` 每次准备字体时都会重新同步 WebUI GNU Unifont subset，避免 HTML 文字变化后继续使用旧 subset。

## 2026-05-11 停止/清屏非阻塞恢复默认表情修复

本次修复点：

1. `stopFirmwareScroll(..., clearDisplay=true)` 不再在 HTTP/API 调用路径里执行 `delay(LED_STOP_CLEAR_BLANK_HOLD_MS)`；现在只写入空帧并登记 deferred restore。
2. `loop()` 新增 `serviceDeferredFaceRestore()`，在空帧锁存等待时间到达后恢复启动默认保存表情。
3. WebUI/API 的 `stop_scroll` 返回不再被 90ms 空帧等待阻塞；状态里新增 `deferredFaceRestoreActive` 便于确认是否处于空帧后恢复等待阶段。
4. 网页或 GPIO 的 M/A 按钮退出文字滚动/覆盖显示时，也改为“空帧 -> 延后恢复当前保存表情”，不再在 `runButtonAction()` / HTTP button 命令路径里阻塞 90ms。
5. 新滚动上传、切换模式、停止滚动或启动滚动时会取消旧的 deferred restore，避免旧的延后恢复动作覆盖新的用户操作。
6. 根目录只保留唯一运行脚本 `run_rinachan_unifont.ps1`，删除旧的字体专用 runner，避免用户运行错误脚本。

## 2026-05-11 文字滚动 Ark12 合并字体 / 繁体优先 / 冗余字体清理

本次覆盖规则：

1. 普通 WebUI 页面字体继续使用 LittleFS 内的 `data/resources/fonts/unifont.woff2`，不改为 Ark。
2. 仅 6.4 文字滚动功能使用 Ark Pixel Font 12px：`#scroll-text` textarea 使用 `ark12.woff2`，LED rasterizer 使用 `ark12.json`。
3. `ark12.json` 改为合并 Ark12 位图表，合并顺序为 `zh_cn -> ja -> zh_tw`；相同 Unicode codepoint 由后者覆盖，最终以繁体 `zh_tw` 为最高优先级。
4. `run_rinachan_unifont.ps1` 改为唯一根目录 PowerShell 运行脚本；字体准备逻辑会验证或重建合并 Ark12 资源。
5. `tools/build_ark12_merged.py` 输出统一 compact tuple：`[advance, width, height, xOffset, yOffset, dstY, rowsHex]`，与 WebUI rasterizer 读取格式一致。
6. `data/resources/fonts/` 只保留实际 LittleFS 需要的 `unifont.woff2`、`ark12.woff2`、`ark12.json` 和说明文件。
7. 删除冗余字体文件：重复的 `ark12_merged_trad_priority.json`、报告文件、展开的 per-language BDF/WOFF2 目录、重复 `.font_cache/bdf` / `.font_cache/woff2`、旧 u8g2/rinafont/长文件名 Unifont 资源。

## 2026-05-11 文字滚动输入框 Ark Pixel 12px 字体修正

问题：文字滚动页面的 `#scroll-text` textarea 被全局 GNU Unifont CSS/JS 覆盖，浏览器实际输入文字显示为 GNU Unifont，而不是 Ark Pixel Font 12px。

修改：

1. `data/index.html` 新增 `@font-face("Ark Pixel 12px Monospaced")`，从 LittleFS 的 `resources/fonts/ark12.woff2` / `/resources/fonts/ark12.woff2` 加载。
2. 新增 `--scroll-font:"Ark Pixel 12px Monospaced"`，并把 `#scroll-text` CSS 强制为 `font-family:var(--scroll-font)!important`、`font-size:12px!important`、`line-height:1.2`。
3. `applyWebUiFont()` 不再给 `#scroll-text` 写入 GNU Unifont inline important 样式。
4. `TEXT_SCROLL_FONT_FAMILY` 改回 `Ark Pixel 12px Monospaced`，`applyTextScrollInputFont()` 运行时也会把 textarea inline important 强制为 Ark 12px。
5. `ensureTextScrollBrowserFontReady()` 使用 Ark 12px 进行 `document.fonts.load/check`，避免字体就绪检测误用 GNU Unifont。

结果：页面其他文字仍使用 GNU Unifont；文字滚动输入框内用户输入的文字显示为 Ark Pixel Font 12px，并与文字滚动位图 rasterizer 的 Ark 资源保持一致。

# 2026-05-11 停止/清屏返回默认保存表情修复

1. 固件 `stop_scroll` / `stopFirmwareScroll()` 现在在清除文字滚动缓存后会先写入空帧，再应用启动默认保存表情。
2. 文字滚动开始前如果处于 M 手动模式，停止/清屏后保持 M 模式，显示默认表情但不自动切换。
3. 文字滚动开始前如果处于 A 自动模式，停止/清屏后恢复 A 模式，并把 `autoFaceIndex` 重置到启动默认表情，从默认表情开始继续循环。
4. 固件加载 `saved_faces.json` 时会同时识别 `startupDefaultId` 与 `is_startup_default`，确保默认表情索引可用于停止/清屏恢复。
5. WebUI 的停止/清屏本地状态同步改为：立即空帧刷新预览，再切换到启动默认表情；随后发送 `stop_scroll` 给固件并等待固件状态回写。
6. 保存表情列表新增当前表情高亮，停止/清屏回到默认表情时列表边框同步高亮。

# 2026-05-11 文字滚动卡顿全链路修复

1. 固件新增独立 FreeRTOS 文字滚动渲染任务 `led_scroll_render`，pinned 到 Core 1；主 `loop()` 不再调用 `serviceFirmwareScroll()`，HTTP/WebUI 请求不会直接决定滚动帧输出时机。
2. 滚动任务使用 `millis()` 时间轴与跳帧补偿：如果 HTTP、WiFi 或其它任务造成短暂延迟，固件按 elapsed interval 推进到正确帧，而不是永远只前进 1 帧。
3. 新增 `frameMutex` / `scrollMutex`：LED 帧缓冲、NeoPixel `show()`、滚动缓存和滚动状态更新被序列化，避免 WebServer、按钮、自动表情和滚动任务同时写 LED。
4. `showCurrentFrame()` 改用启动时预计算的 `logicalToPhysicalMap[]`，每帧输出不再逐 LED 扫描行表计算物理索引。
5. `/api/status` 在文字滚动播放/暂停期间返回轻量状态：不再返回旧 `lastM370` 覆盖网页预览，也延后 LittleFS 容量统计，减少状态轮询造成的阻塞。
6. WebUI 状态轮询改为动态节流：普通状态约 2s，同步文字滚动时降到约 10s；滚动期间不会每 2s 打断固件。
7. WebUI 在固件滚动播放/暂停期间不再使用固件旧 `lastM370` 覆盖 `currentFrame`，避免预览窗口每隔几秒跳回旧表情。
8. 编辑滚动文字时不再自动重新上传完整帧序列；当前播放继续使用已上传缓存，下一次点击“发送”才重新生成并上传，避免输入时造成播放停顿。

# 2026-05-11 文字滚动按钮行为修复

1. 6.4 文字滚动页面删除旧的 `生成文字滚动` 按钮。
2. `发送` 按钮现在负责准备 Ark Pixel 位图帧、上传完整 M370 帧序列到 `/api/scroll`，并让固件立即播放；WebUI 不逐帧发送。
3. `暂停` 按钮改为 pause/resume toggle：播放中发送 `pause_scroll`，暂停中发送 `resume_scroll`。按钮仅在播放状态高亮，暂停状态不高亮。
4. `停止/清屏` 按钮发送 `stop_scroll`，payload 包含 `clear:true` 与 `restoreAuto:true`。固件实际写入空帧，停止并清空文字滚动缓存，然后恢复保存表情的 M/A 模式。
5. 固件 `stopFirmwareScroll()` 增加 `clearDisplay` 参数；清屏时会更新 `lastM370` 为全 0 M370，避免 LED 停在最后一个滚动文字帧。
6. 固件 `startFirmwareScroll()` 保留已有的 `restoreAutoAfterScroll` 标志，避免 guard 命令与 `/api/scroll` 上传到达顺序不同导致 A 自动模式无法恢复。

# 2026-05-11 文字滚动默认 20fps / Ark textarea 字体提前加载

## 本次修复

1. `data/index.html` 的文字滚动 fps 输入框默认值从 `30` 改为 `20`。
2. `DEFAULT_SCROLL_FPS` 从 `30` 改为 `20`，因此空输入、blur/change 归一化和首次播放都会回到 20fps。
3. `src/main.cpp` 的 `DEFAULT_SCROLL_INTERVAL_MS` 从 `33` 改为 `50`，固件在缺省 `fps/intervalMs` 时也按 20fps 播放。
4. HTML `<head>` 新增 `/resources/fonts/ark12.woff2` 预加载，让浏览器在页面解析阶段就请求文字滚动输入框字体。
5. WebUI 启动时主动执行 `document.fonts.load()` 加载 `Ark Pixel 12px Monospaced`，并在字体加载完成后重新计算 `#scroll-text` 高度。
6. `#scroll-text` 仍强制使用 `Ark Pixel 12px Monospaced` 和 12px；LED rasterizer 仍使用 `/resources/fonts/ark12.json`，没有改回浏览器/system fallback。

---

# 2026-05-11 uploadfs 修复：离线 Unifont 文件名缩短

## 背景

`uploadfs` 在打包 LittleFS 时对文件名组件长度更敏感。上一版离线字体文件名过长，可能导致 mklittlefs 在 `/resources/fonts/...` 上报 `unable to open`。

## 本次修复

1. WebUI 离线 GNU Unifont 字体文件改名为 `data/resources/fonts/unifont.woff2`。
2. `data/index.html` 的 `@font-face("GNU Unifont")` 只加载 `resources/fonts/unifont.woff2` 与 `/resources/fonts/unifont.woff2`。
3. `run_rinachan_unifont.ps1` 新增上传前检查：`data/` 下所有文件/目录名必须小于或等于 31 个字符。
4. 文字滚动字体链路保持 Ark Pixel 12px，不改 textarea 和 LED rasterizer 字体规则。

# RinaChanBoard ESP32-S3 370 LED 固件与 WebUI 总计划

## 2026-05-11 完全离线 GNU Unifont WebUI 字体强制方案

本次覆盖规则：

1. 普通 WebUI 字体只使用 LittleFS 内的 `data/resources/fonts/unifont.woff2`。
2. `@font-face("GNU Unifont")` 不再包含 `local()`，也不再包含任何外部字体 URL；浏览器不需要安装 GNU Unifont，也不需要 Internet。
3. 全局页面、按钮、普通输入框、选择框、日志、标签等仍通过 `--ui-font` 强制继承 `"GNU Unifont"`。
4. 文字滚动输入框和 LED rasterizer 保持 `Ark Pixel 12px Monospaced`，仍读取 `ark12.woff2` / `ark12.json`。
5. 右侧表情操作按钮恢复使用原图标 `💡`、`✏️`、`🗑️`；这些 emoji 不强行加入 GNU Unifont subset，浏览器可按系统 fallback 显示。
6. 新增 `tools/build_unifont_webui_subset_from_png.py` 与 `tools/assets/unifont-17.0.04.png`，可从 GNU Unifont PNG 重新生成当前 WebUI 子集 WOFF2。

> 文档状态：固件接口重构版（统一 saved_faces.json 表情库 / HTML 主处理 / 仅发送 M370 与辅助指令 / 已删除媒体页）
> 目标：以当前 `rina_370_webui_single_saved_faces.html` 为准，将 HTML 重构为主要数据处理层；默认表情、自定义表情、部件表情全部保存在同一个 `/resources/saved_faces.json` 中，默认表情以 `type:"default"` 标识且不可删除但可排序和重命名；固件只接收 `M370:<93 hex>` LED 帧和亮度、颜色、模式、暂停、按钮、保存 JSON 等辅助指令。
> 对齐原则：若旧计划与当前 HTML 冲突，以当前 HTML 的接口、控件、状态字段和保存文件结构为准；删除旧 demo、placeholder 数据、浏览器缓存保存源和已废弃旧播放页路径。

---




## 最新覆盖规则：GNU Unifont WebUI / Ark Pixel 12px 文字滚动输入框 / BDF 位图 rasterizer

本轮以后 WebUI 与文字滚动字体规则以此为准：

1. 普通网页 CSS/JS 全局页面字体使用 `font-family: "GNU Unifont"`。
2. `data/index.html` 的 `@font-face` 只保留 GNU Unifont：仅加载 LittleFS 内的 `unifont.woff2`，不使用 `local()` 或外部 URL。
3. 普通页面、按钮、输入框、选择框、日志、标签等均继承 GNU Unifont。
4. `#scroll-text` 文字滚动输入框保持 `font-family: "Ark Pixel 12px Monospaced"` 和 `font-size: 12px` 不变。
5. 文字滚动 rasterizer 不使用 Canvas `fillText()` / `getImageData()` / alpha threshold 采样。
6. 文字滚动 rasterizer 使用由官方 Ark Pixel Font 12px Monospaced BDF 编译出的 `/resources/fonts/ark12.json` 位图表。
7. 每个字形像素直接映射为 `0/1` 点阵，再拼接为 22×18 window，最终编码为 M370 帧序列。
8. 缺字只允许使用 Ark 字体表内的 `□` 字形或报错；不得自动调用浏览器/system fallback 字体参与文字滚动 rasterizer。
9. 字体资源通过根目录唯一 PowerShell 脚本 `run_rinachan_unifont.ps1` 生成或补齐；脚本只生成 Ark 文字滚动资源，不再生成旧 WebUI 字体资源。
10. 旧 WebUI 字体文件、嵌入式 base64 字体、转换工具和脚本命名均已移除。


## 最新覆盖规则：单一 saved_faces.json 表情库

本轮以后以单一文件 `/resources/saved_faces.json` 作为唯一表情库：

1. 默认表情不写入 HTML。
2. 默认表情不再使用独立 `default_faces.json`。
3. 默认表情不再使用独立顺序文件。
4. 默认表情、自定义表情、部件表情全部位于同一个 `faces[]`。
5. 默认表情仅通过 `type: "default"` 标识。
6. `type: "default"` 的表情不可删除，但可以重命名、上移、下移、拖拽排序。
7. 用户手动排序写回同一个 `saved_faces.json` 的 `order` 字段，`order` 按 WebUI 列表编号使用 1-based 编号。
8. 默认表情重命名写回同一个 `saved_faces.json` 的 `name` 字段。
9. 默认启动表情固定为 `face_08_triangle_eyes_frown`（来源默认表情 WebUI 编号/id=8）。
10. `order` 与默认表情 ID 编号必须从 1 开始。
11. 用户保存的自定义表情使用 `type: "custom"`。
12. 用户保存的部件组合使用 `type: "parts"`。
13. HTML 只处理表情数据、生成 M370，并通过 `/api/saved_faces` 写回同一个表情库文件。
14. 电脑本地打开 HTML 时，浏览器若支持 File System Access API，可用“打开本地 saved_faces.json”绑定同一个文件并直接保存排序/重命名；否则使用导入/下载流程。


### 默认 faces 写入规则

- 默认 faces 不写入 HTML。
- 默认 faces 不使用单独 `default_faces.json` 或 `face_order.json`。
- 默认 faces 与用户保存表情统一写入 `/resources/saved_faces.json`。
- `type:"default"` 是默认表情的唯一标识。
- `type:"default"` 项不可删除，但可以重命名。
- 用户手动排序保存在同一个 `saved_faces.json` 的 `order` 字段，`order` 与 WebUI 显示编号一致，从 1 开始。
- 自定义表情使用 `type:"custom"`，部件表情使用 `type:"parts"`。

## 0. 总体目标

本项目实现一个运行在 **ESP32-S3** 上的 RinaChanBoard 370 LED 固件与本机 WebUI。当前重构版的核心边界是：**HTML 是主要数据处理层，固件是执行层**。

核心目标：

1. ESP32-S3 仅作为 **AP WiFi Host**，直接提供 WebUI 和静态资源。
2. HTML 负责：
   - 370 LED 虚拟矩阵编辑。
   - 表情部件组合。
   - 文字滚动 rasterize 与 20fps 帧序列生成。
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
8. 文字滚动播放期间必须以 20fps 连续输出 M370 帧。
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
| 文字滚动 | 停止 20fps scroll timer，active=false | 不自动继续滚动 |
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
| 文字滚动 | 播放期间强制 20fps 连续刷新 |

### 5.2 UI 显示要求（以 HTML 为准）

当前 HTML 把状态分成两类：普通页面只保留操作必需内容，调试页面集中显示接口、刷新、状态和日志。

| 页面 | 允许显示 | 不应额外增加 |
|---|---|---|
| 6.1 基础功能 | AP-only Firmware API badge、IP badge、颜色、亮度、保存表情控制、只读预览 | 不增加刷新策略、最后刷新原因、当前 M370 长文本 |
| 6.2 自定义表情 | M370 输入/导入/复制/导出文本、统一 saved_faces.json 默认表情 / saved_faces.json 读取与下载、用户 JSON 导入、统一表情列表 | 不使用浏览器缓存作为保存源；type:"default" 的默认表情不可删除但可重命名 |
| 6.3 表情部件 | 组合调用文本 `leye=..., reye=..., mouth=..., cheek=...`、复制组合 M370、页面底部 M370 / 保存管理 panel、统一表情列表 | 不增加旧库名说明 |
| 6.4 文字滚动 | 状态、当前帧进度、速度输入、370 LED 预览 | 不显示完整帧序列、offset、复制当前 M370 按钮 |
| 6.5 调试 | 刷新策略、最近刷新原因、刷新计数、文字 20fps、实际 FPS、ADC、网络、资源、固件接口状态、状态 JSON、日志下载 | 不把这些调试字段复制回普通主页面 |

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
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": "ISO-8601|null",
  "faces": [
    {
      "id": "face_or_user_id",
      "name": "display name",
      "type": "default|custom|parts",
      "m370": "M370:<93 hex>",
      "order": 1,
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
6. 任何排序都必须按 WebUI 显示编号重新分配 1-based `order`，并 POST 到 `/api/saved_faces` 写回同一个 `/resources/saved_faces.json`。
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
- 默认文本：`RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード`
- 帧率输入：`scroll-speed`
- 帧率单位：`fps`
- 帧率范围：`1..120`
- 默认帧率：`20`
- `发送`：上传完整 M370 帧序列到固件并立即播放
- `暂停`：pause/resume toggle，播放时高亮，暂停时不高亮
- `停止/清屏`：固件实际清空当前显示并返回保存表情 M/A 模式
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
  font-family: Ark Pixel 12px Monospaced, "Ark Pixel 12px Monospaced", "Ark Pixel 12px Monospaced", "Shinonome16", "Ark Pixel 12px Monospaced", "Ark Pixel 12px Monospaced";
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

1. 发送、暂停/继续、停止/清屏、单帧推进前调用 Activity guard 或固件控制命令。
2. 空文本发送时提示：`空文本不进入文字滚动播放`。
3. 没有可播放帧时提示：`没有可播放的文字帧`。
4. 发送时 WebUI 预生成完整 M370 帧序列，并通过 `/api/scroll` 一次上传到固件缓存，`start:true` 让固件立即播放。
5. 播放时：`scroll.active=true`、`paused=false`、`state.textScrollActive=true`、`state.playback='scroll'`、`refreshPolicy='text_scroll_20fps_interval_50ms'`。
6. 暂停时清 WebUI 预览 timer，保留当前帧，发送 `pause_scroll`，`state.playback='scroll_paused'`。再次点击同一按钮发送 `resume_scroll`。
7. 暂停按钮 UI：播放时加 `.active` 高亮，暂停时移除高亮并显示 `继续`。
8. 停止时清 timer、清空 scroll cache 状态、当前输出清屏，并发送 `stop_scroll {clear:true, restoreAuto:true}`。
9. 单帧推进时使用已有缓存帧，并通知固件 `scroll_step`。
10. offset 超过总帧数时循环回到开头。
11. fps 改变或文本改变时标记 dirty；正在播放时重新上传完整帧序列，仍不逐帧发送。
12. UI 不显示完整 M370、帧序列、offset、复制当前 M370 按钮。

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

文字滚动采用 **WebUI 预生成 M370 帧序列 + ESP32 20fps packed frame player**。

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
ESP32 TextScrollPlayer 以 20fps 播放
```

ESP32 不实时渲染 TTF，不实时做 Unicode 字形排版。

### 8.2 字体要求

所有文字滚动字体源统一为 **16×16**。

| 字符类型 | 字体要求 |
|---|---|
| 英文 / 数字 / ASCII 符号 | 优先 Ark Pixel 12px Monospaced |
| 中文 | 16×16 CJK 像素字体 fallback |
| 日文假名 | 16×16 CJK / Japanese pixel fallback |
| 日文汉字 | 16×16 CJK / Japanese pixel fallback |
| 未命中字符 | 16×16 fallback 或 tofu 方框 |

推荐字体栈：

```css
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Shinonome,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
Ark Pixel 12px Monospaced,
"Ark Pixel 12px Monospaced"
```

字体文件目录：

```text
esp32s3_firmware/data/resources/fonts/
```

允许放入：

```text
ark12.woff2
```

字体打包原则：

1. 只打包授权允许分发的字体。
2. Ark Pixel 12px Monospaced 可作为英文默认字体。
3. 不把授权不明确的字体打进固件 ZIP。
4. WebUI 可以通过 `@font-face` 优先加载项目资源字体，不再 fallback 到本机字体。


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
latin:    '"Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced Regular","Ark Pixel 12px Monospaced Monospaced","Ark Pixel 12px Monospaced Proportional","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced"'
kana:     '"Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced Proportional","Shinonome","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced"'
cjk:      '"Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced Proportional","Ark Pixel 12px Monospaced","Shinonome","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced"'
fallback: '"Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced","Ark Pixel 12px Monospaced",system-ui,"Ark Pixel 12px Monospaced"'
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
TEXT_SCROLL_FPS = 20;
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

1. 只接受 20fps。
2. 只接受 `47 bytes/frame`。
3. 上传期间状态为 `Loading`。
4. `finishUpload()` 后状态为 `Ready`。
5. `play()` 后状态为 `Playing`。
6. `tick()` 只在需要输出新 20fps frame 时返回 true。
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
  "fps": 20,
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
8. `refreshPolicy` 在文字滚动播放时为 `text_scroll_20fps`，其它情况下为 dirty-frame / 按需刷新。
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
  "reason": "custom_face_send|parts_compose_send|text_scroll_20fps|debug_m370_apply|...",
  "mode": "idle|scroll|scroll_step|battery|network_info|...",
  "at": 1710000000000
}
```

要求：

1. 固件只解析 `m370`。
2. `m370` 必须是 `M370:<93 hex>` 或可被规范化为此格式。
3. 固件不得从该 payload 读取颜色或亮度；颜色/亮度由 `/api/command` 更新全局 renderer 状态。
4. 固件必须将 M370 解码为 370-bit on/off frame 后进入统一 LedRenderer。
5. 文字滚动播放期间 HTML 以 20fps 调用该接口。

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
| `default` | 默认表情，默认启动项为 `face_08_triangle_eyes_frown` | 不可删除 | 可排序、可重命名，写回同一文件 |
| `custom` | 用户自定义画板保存表情 | 可删除 | 可排序、可重命名 |
| `parts` | 表情部件组合保存表情 | 可删除 | 可排序、可重命名 |

GET 返回：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": {"leds":370,"m370HexChars":93},
  "startupDefaultId": "face_08_triangle_eyes_frown",
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
    "startupDefaultId": "face_08_triangle_eyes_frown",
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
├── ark12.woff2
└── README.md
```

`@font-face` 按 HTML 保留：

```css
@font-face {
  font-family: "Ark Pixel 12px Monospaced";
  src: local("Ark Pixel 12px Monospaced"),
       local("Ark Pixel 12px Monospaced Regular"),
       url("../resources/fonts/ark12.woff2") format("woff2"),
       url("/resources/fonts/ark12.woff2") format("woff2");
  font-display: swap;
}
```

`README.md` 必须说明：

1. 英文默认字体为 Ark Pixel 12px Monospaced。
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
4. 用户手动排序：每个 face 的 `order` 字段，使用与 WebUI 编号一致的 1-based 编号。
5. 用户重命名：每个 face 的 `name` 字段。

统一 face schema：

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "m370HexChars": 93 },
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": "ISO-8601|null",
  "faces": [
    {
      "id": "face_08_triangle_eyes_frown",
      "name": "08 Triangle Eyes Frown",
      "type": "default",
      "m370": "M370:<93 hex>",
      "order": 8,
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
8. 排序结果直接写回同一个 `saved_faces.json` 的 1-based `order` 字段。
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
4. `order` 必须可排序、从 1 开始且写回同一个 JSON。

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
2. 英文和数字使用 Ark Pixel 12px Monospaced 或等效 fallback。
3. 所有 glyph 按 16×16 源 cell 栅格化。
4. 英文和数字不会出现 16 列全宽导致的大空隙。
5. 两个非空字符之间固定 2 columns。
6. 空格固定 4 columns。
7. 文字在 18 行中垂直位置为上 1 行空白、下 1 行空白。
8. 播放期间 20fps 连续推进。
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
- 接入 Ark Pixel 12px Monospaced。
- 实现 glyph 裁剪、2 column 字距、4 column 空格。
- 实现 M370 packed frame 生成。
- 实现上传和 20fps 播放。

### Phase 5：页面功能

- 6.1 基础控制。
- 6.2 自定义表情。
- 6.3 表情部件组合和左右眼对称。
- 6.4 文字滚动：速度输入、自动增高、20fps 播放、单帧推进。
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
4. 不再使用外置注释文件；代码说明必须以对应语言的正确注释格式直接写入代码文件。
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
4. 用户手动排序：每个 face 的 `order` 字段，使用与 WebUI 编号一致的 1-based 编号
5. 用户重命名：每个 face 的 `name` 字段

### 统一 schema

```json
{
  "format": "rina_faces_370_v2",
  "version": 2,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "m370HexChars": 93 },
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": null,
  "faces": [
    {
      "id": "face_08_triangle_eyes_frown",
      "name": "08 Triangle Eyes Frown",
      "type": "default",
      "m370": "M370:<93 hex>",
      "order": 8,
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
- 排序结果直接写回同一个 `saved_faces.json` 的 1-based `order` 字段。

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

---

## 2026-05-11 文字滚动居中 / FPS 帧间隔修复

### 目标

- 文字滚动在 370 LED matrix 内垂直居中显示。
- 每一帧只推进 1 个 LED 列，不再按 `px/s` 与 20fps 组合跳帧。
- 速度输入框改为 `帧率 fps`；改变速度时只改变帧时间间隔 `intervalMs = round(1000 / fps)`。
- WebUI 页面本体使用 GNU Unifont web font；文字滚动 textarea 与实际 LED rasterizer 继续使用 Ark Pixel Font 12px。

### 已实施

1. `data/index.html`
   - 新增 `@font-face("GNU Unifont")`，普通页面、按钮、输入框、日志、标签改用 GNU Unifont。
   - `#scroll-text` 保持 `Ark Pixel 12px Monospaced`，确保输入框预览与 LED 实际滚动字体一致。
   - `scroll-speed` 标签改为 `帧率 fps`，默认 20，可在 1..120 fps 调整。
   - `prepareTextScrollTimeline()` 始终按 offset `+1` 生成 M370 帧，保证每帧移动 1 LED。
   - Ark 12px glyph line 通过 `textScrollVerticalOffset()` 垂直居中到 18 行矩阵。
   - 上传到 `/api/scroll` 的数据为完整 M370 帧序列 + `fps` + `intervalMs` + `stepLedPerFrame:1`。
   - 自动播放预览不再通过 `/api/frame` 逐帧发送；上传失败时停止播放并提示错误。

2. `src/main.cpp`
   - `MAX_SCROLL_FRAMES` 从 512 提升到 3072，适配更长文字的逐列 M370 序列；WebUI 默认上限同步为 3072，并会优先使用固件 `/api/status` 返回的 `scrollMaxFrames`。
   - `/api/scroll` 改为手动扫描 JSON 中的 `frames` 字符串数组，避免为大帧序列分配巨大的 ArduinoJson document。
   - 固件缓存完整帧序列，每到 `scrollIntervalMs` 只推进一个帧索引。
   - 新增 `set_scroll_interval` 命令，运行中改变 fps 时只更新固件播放间隔。
   - 新增 `scroll_step` 命令，单帧推进也是一个缓存帧。
   - `serviceFirmwareScroll()` 使用增量式时间基准，减少 `millis()` 循环抖动导致的帧间隔不稳定。

3. `tools/prepare_ark_pixel_font.ps1`
   - 继续准备 Ark Pixel Font 12px 的 `ark12.woff2` 与 `ark12.json`。
   - 新增随包提供 GNU Unifont PNG 资源并生成 `unifont.woff2`。

4. `legacy WebUI font converter removed`
   - 新增 BDF -> pixel-outline WOFF2 转换器。
   - 将每个 BDF lit pixel 转为 TrueType 方块轮廓，供浏览器通过 CSS `@font-face` 使用。

### 预期行为

- 点击播放：WebUI 生成完整帧序列并一次上传，固件缓存后独立播放。
- 修改 fps：不会重新采样或跳帧，只改变固件 frame interval。
- 每个缓存帧之间的画面差异为水平滚动 1 LED。
- 手机/浏览器断开后，固件仍可继续按缓存序列播放。

---

## 2026-05-11 全局 GNU Unifont 字体资源打包 / FPS 输入限制补强

### 目标

- 整个 WebUI 页面字体使用上传的 `unifont.woff2`。
- 文字滚动输入框 `#scroll-text` 的 Ark Pixel Font 12px 显示规则保持不变。
- 文字滚动 fps 输入框限制为整数 `1..120`，避免 `e`、小数、负数、超过 120 等无效输入进入状态。

### 已实施

1. `data/resources/fonts/unifont.woff2`
   - 将上传的 GNU Unifont WebFont 直接打包进 LittleFS 资源目录。

2. `data/index.html`
   - `@font-face("GNU Unifont")` 同时支持 `resources/fonts/unifont.woff2` 与 `/resources/fonts/unifont.woff2`，便于 ESP32 服务和本地打开 HTML 两种场景加载。
   - 全局页面字体、普通 textarea、日志、`.mono` 均使用 `"GNU Unifont"`。
   - `#scroll-text` 保持 `"Ark Pixel 12px Monospaced"` 与 12px，不随全局字体变化。
   - `scroll-speed` 增加 `inputmode="numeric"`、`pattern="[0-9]*"`、`autocomplete="off"`。
   - 新增 `parseScrollFpsValue()` / `sanitizeScrollFpsInput()`，对键盘、beforeinput、input、paste、change、blur 都进行数字清洗和 `1..120` clamp。

3. 根目录 `run_rinachan_unifont.ps1`
   - 输出包只保留这一个 PowerShell 脚本。
   - 脚本只在已解压后的 `esp32s3_firmware` 项目目录内运行，不包含 ZIP 解压逻辑。
   - 脚本内部负责准备 Ark Pixel 12px 的 `ark12.woff2` 与 `ark12.json`。
   - 若 `data/resources/fonts/unifont.woff2` 已存在，则只校验该文件存在，不联网下载或覆盖 GNU Unifont 字体。

### 预期行为

- 普通 WebUI 全部显示为 GNU Unifont。
- 文字滚动输入框仍显示为 Ark Pixel Font 12px。
- fps 输入 `0` 会归一为 `1`，`121` 或更大值会归一为 `120`，非数字输入会被阻止或清洗。


---

## 2026-05-11 全局 GNU Unifont 字体加载强制修复

### 问题

- 上一版只通过 LittleFS 内的 `unifont.woff2` 加载 WebUI 字体。
- 如果浏览器命中旧缓存，或某些表单控件继续使用 UA 默认字体，页面实际显示可能仍不是指定 GNU Unifont 字体。

### 已实施

1. `data/index.html`
   - 将上传的 `unifont.woff2` 直接以LittleFS 本地 WOFF2 形式写入 `@font-face`。
   - 新字体族命名为 `GNU Unifont`，避免浏览器把旧的 `GNU Unifont` font-face 缓存在同名族下。
   - `@font-face` 仍保留 `/resources/fonts/unifont.woff2?v=20260511-font2` 与 `resources/fonts/unifont.woff2?v=20260511-font2` 作为外部 fallback。
   - 增加 `--ui-font` 与 `--scroll-font` CSS 变量。
   - 增加 `body, body * { font-family: var(--ui-font) !important; }`，强制覆盖按钮、输入框、选择器、日志、标签和普通文本。
   - 增加 `body #scroll-text { font-family: var(--scroll-font) !important; }`，确保文字滚动输入框不被全局覆盖影响。
   - 增加 `font-synthesis:none`，避免浏览器伪造粗体/斜体导致像素字体观感变化。

2. `data/resources/fonts/unifont.woff2`
   - 继续保留字体文件，供外部 fallback 与后续调试使用。


3. PowerShell 脚本整理
   - 删除独立 `tools/prepare_ark_pixel_font.ps1`。
   - 字体准备逻辑合并进根目录唯一脚本 `run_rinachan_unifont.ps1`。

### 预期行为

- WebUI 页面打开后通过 LittleFS WOFF2 请求使用 GNU Unifont 显示。
- 普通控件和页面文字都使用 GNU Unifont。
- `#scroll-text` 仍使用 Ark Pixel Font 12px。
- 如浏览器仍显示旧字体，应清除页面缓存或在地址后添加临时查询串重新加载，例如 `http://192.168.1.14/?v=font2`。


## 2026-05-11 WebUI GNU Unifont 字体二次强制修复

### 目标

- 解决浏览器仍未显示指定 WebUI 字体的问题。
- 保持文字滚动输入框 `#scroll-text` 继续使用 Ark Pixel Font 12px，不受全局字体覆盖影响。
- 保持 FPS 输入限制为 1–120。

### 修改

1. `data/resources/fonts/unifont.woff2`
   - 从上传的 `unifont.woff2` 生成 WebUI 专用副本。
   - 字体族名称改为 `GNU Unifont`，避免浏览器旧字体族缓存。

2. `data/resources/fonts/unifont.woff2`
   - 增加 TTF fallback，避免个别浏览器拒绝 WOFF2 时无法套用字体。

3. `data/index.html`
   - `@font-face` 改用 `GNU Unifont`。
   - `@font-face` 同时提供LittleFS 内 WOFF2。
   - 增加 JS 运行时 `ensureWebUiFontReady()` / `applyWebUiFont()`，通过 `document.fonts.load/check` 与 inline important style 双重强制普通 WebUI 元素使用该字体。
   - 增加 MutationObserver，对后续动态生成的按钮、选项、日志等元素继续套用 WebUI 字体。
   - `#scroll-text` 保持 `Ark Pixel 12px Monospaced`。

4. `run_rinachan_unifont.ps1`
   - 启动时校验原始 GNU Unifont 字体、WebUI WOFF2 副本、WebUI TTF fallback 均存在。

### 验证

- `node --check` 通过。
- WebUI WOFF2/TTF 字体副本可被 fontTools 正常读取。
- ZIP 根目录保持为 `esp32s3_firmware/`。
- 根目录只保留一个 PowerShell 脚本。


## 2026-05-11 LED 乱码闪帧 / BSS138 电平转换时序修复

### 问题判断

- GPIO 到 LED 数据线之间使用 BSS138 电平转换器。BSS138 更适合低速双向总线，驱动 WS2812/NeoPixel 800 kHz 单线协议时，上升沿依赖上拉电阻，边沿可能偏慢。
- 原固件虽然有 `frameMutex`，但 `applyM370()`、`applyPackedFrame()`、`applyBlankFrame()`、`setColor()`、`setBrightness()`、文件系统错误图案、滚动渲染任务等路径都会直接或间接调用 `strip.show()`。
- 在频繁刷新或 Web/API 同时操作时，物理 LED 输出可能从不同路径触发，虽然逻辑上互斥，但对 ESP32 RMT/NeoPixel 输出和边沿裕量不够友好，可能表现为偶发一帧乱码。

### 修改

1. `src/main.cpp`
   - 新增 `requestLedRender()` / `consumeLedRenderRequest()`，用临界区保护渲染请求标志。
   - 将 `showCurrentFrameNoLock()` 和 `showCurrentFrame()` 改为只提交渲染请求，不再直接输出到 LED。
   - 新增 `renderCurrentFrameToLedStrip()`，只有 `led_scroll_render` 任务会调用实际 `strip.show()`。
   - LED 输出前先在 `frameMutex` 内复制本地帧快照、亮度和颜色，然后释放锁，再进行物理输出，避免渲染过程中帧缓存被修改。
   - `scrollRenderTask()` 同时负责滚动帧推进和所有 LED 实体刷新。滚动帧到期时先更新 `frameBits`，然后在同一任务内输出。
   - 增加 `LED_SIGNAL_RESET_US = 300`，在 `strip.show()` 前后保持更长 reset/latch 空闲窗口。
   - 增加 `LED_RENDER_MIN_GAP_US = 2500`，避免连续过密刷新压缩 WS2812 latch 时间。
   - `showFilesystemErrorPattern()` 改为在 `frameMutex` 内更新错误图案，再提交渲染请求。
   - 启动时初始化清屏仍直接执行一次 `strip.show()`，随后立即启动渲染任务；后续显示输出统一由任务处理。

### 预期行为

- 文字滚动、保存表情切换、颜色/亮度修改、停止/清屏都不再从 WebServer/API 路径直接驱动 LED。
- 频繁刷新时，多个更新会合并成稳定的实体刷新，降低偶发一帧乱码概率。
- 对 BSS138 边沿较慢导致的硬件裕量不足有软件缓解，但如果仍在高亮度/长线/高 FPS 下闪乱码，建议硬件改为 74AHCT125 / 74HCT245 / SN74AHCT1G125 等单向 5V TTL 兼容缓冲器。

## 2026-05-11 stop/clear default-face and Unifont enforcement update

- Stop/clear for firmware text scroll is now a deterministic two-stage sequence: clear the active LED frame first, yield to the LED render task, then apply the startup default saved face.
- After stop/clear, M mode stays manual on the startup default face; A mode resumes saved-face auto playback from that same startup default face.
- WebUI stop/clear mirrors the startup default face into both the normal matrix and the text-scroll preview matrix, so the page no longer remains on a blank scroll preview.
- All visible WebUI text, including dynamically created custom select/toggle labels and menu options, is force-bound to GNU Unifont. Text-scroll LED bitmap generation remains separate from the WebUI display font.

## 2026-05-11 - Pause/Continue button Unifont glyph fix

- Rebuilt the offline GNU Unifont WebUI subset after confirming the dynamic `继续` label was missing from the shipped cmap.
- Added `继续` / `暂停` to the browser font readiness sample so the UI does not report font-ready while those dynamic glyphs are absent.
- Bumped the WebUI font cache-buster query string to force browsers to fetch the rebuilt `unifont.woff2`.
- Added an explicit important `font-family: GNU Unifont` assignment to the dynamic pause/resume button label update path.


## 2026-05-11 M/A 退出滚动立即恢复 + 开机首帧稳定化

### 目标

- 当当前处于文字滚动或其他非保存表情显示状态时，点击 WebUI 的 M/A 按钮或按下 GPIO 的 B3/M-A 按钮，应等价于先执行清屏：停止滚动，实体 LED 显示空帧，然后立即进入保存表情的 M/A 显示状态。
- 如果目标是 A 自动模式，应马上显示当前保存表情并从当前保存表情位置继续自动循环，而不是等待默认 3 秒自动间隔后才开始可见切换。
- 修复开机第一个保存表情偶发乱码/错帧。

### 固件修改

1. `src/main.cpp`
   - 新增 `handleModeButtonAction()`，将 B3/M-A 从普通 `setMode()` 切换改为专用流程。
   - 新增 `playbackIsNonFaceActivity()`，用于判断当前是否处于文字滚动、暂停滚动、自定义输出、部件输出、调试输出或 overlay 等非保存表情显示状态。
   - B3/M-A 在非保存表情状态下执行：
     1. 停止固件滚动播放与滚动缓存状态；
     2. 渲染全灭空帧；
     3. 等待 `LED_STOP_CLEAR_BLANK_HOLD_MS`，确保 Core 1 LED 渲染任务实际锁存空帧；
     4. 切换目标 M/A 模式；
     5. 立即应用当前 `autoFaceIndex` 对应的保存表情。
   - 进入 A 自动模式时，立即显示当前保存表情，并重置 `lastAutoSwitchMs`，下一次自动切换从这一帧开始计时。
   - B3/M-A 不再使用 stop/clear 的启动默认表情路径；启动默认表情仍保留给“停止/清屏”按钮使用。

2. `src/main.cpp` 开机渲染流程
   - 新增 `LED_BOOT_CLEAR_HOLD_MS` 与 `LED_BOOT_STARTUP_SETTLE_MS`。
   - 开机先直接向 LED 锁存全灭帧并保持一段时间。
   - 新增 `setColorStateNoRender()`，启动阶段只设置默认颜色状态，不额外排队渲染空帧。
   - 读取 LittleFS、runtime settings、saved_faces 后，先同步输出启动保存表情一次，再启动独立 LED 渲染任务。
   - 这样可以避免启动阶段“空帧渲染请求”和“启动表情渲染请求”被任务合并或时序挤压，降低 BSS138 电平转换边沿较慢时的首帧乱码概率。

### 行为结果

- 文字滚动中点击 M/A：实体 LED 先灭一帧，再立即显示当前保存表情。
- 如果切到 A 自动模式：不再等 3 秒才开始显示/恢复，而是马上显示当前保存表情，然后按设定间隔继续自动循环。
- 如果切到 M 手动模式：马上显示当前保存表情并停留。
- “停止/清屏”按钮原有行为保持：清屏后回到启动默认表情，并按进入滚动前的 M/A 状态处理。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json` 与 `data/resources/runtime_settings.json` 已通过 JSON 解析。
- 根目录只保留一个 PowerShell 脚本：`run_rinachan_unifont.ps1`。
- 当前环境没有安装 PlatformIO (`pio`)，因此未在本地执行 `pio run`。

## 2026-05-11 Ark12 merged text-scroll + runtime font builder distribution

### 目标

- 文字滚动输入框与 LED 文字滚动 rasterizer 使用合并 Ark Pixel Font 12px。
- 合并顺序为 `zh_cn -> ja -> zh_tw`，同一 Unicode codepoint 冲突时以繁体 `zh_tw` 为最终优先。
- WebUI 页面本身继续使用 GNU Unifont，不被 Ark12 替换。
- 分发包不携带字体二进制；根目录唯一 PowerShell 脚本负责下载官方源资源并在本地生成 LittleFS 所需字体文件。

### 修改

1. `run_rinachan_unifont.ps1`
   - 保留为唯一根目录运行脚本。
   - 若 `data/resources/fonts/unifont.woff2` 缺失，自动下载官方 GNU Unifont BMP PNG 到 `.font_cache`，再生成 WebUI 子集 WOFF2。
   - 自动检测并安装 Python 字体构建依赖：`pillow`、`fonttools`、`brotli`。
   - 若 Ark12 资源缺失或 `ark12.json` 不是 `zh_cn,ja,zh_tw` 合并版本，下载/复用官方 Ark12 BDF 与 WOFF2 包并重建。
   - 清理冗余字体文件与展开缓存目录，只保留运行所需的 `unifont.woff2`、`ark12.woff2`、`ark12.json`。

2. `tools/build_unifont_webui_subset_from_png.py`
   - 新增随包分发的 WebUI Unifont 子集构建器。
   - 从官方 GNU Unifont PNG 提取当前 WebUI 文本与稳定 UI 字符范围，输出 `data/resources/fonts/unifont.woff2`。
   - 避免随 ZIP 分发字体文件，同时修复缺失 `unifont.woff2` 时脚本直接失败的问题。

3. `tools/build_ark12_merged.py`
   - 继续输出 `data/resources/fonts/ark12.json`，用于 LED 文字滚动点阵生成。
   - 保持 `zh_cn -> ja -> zh_tw` 低到高优先级。

4. `data/index.html`
   - `html/body` 与普通控件继续强制使用 `GNU Unifont`。
   - 仅 `#scroll-text` 及文字滚动 LED rasterizer 使用 Ark12。

### 验证

- `tools/build_unifont_webui_subset_from_png.py` 已使用原工程 GNU Unifont PNG 进行本地生成测试，能输出有效 `unifont.woff2`。
- `tools/build_ark12_merged.py` 已使用原工程 Ark12 BDF 展开目录进行合并测试，输出 glyph count 24408，且示例简体、繁体、日文字符覆盖正常。
- 补丁 ZIP 不包含 `.font_cache`、`.pio` 或字体二进制文件。

## 2026-05-14 WebUI 启动前固件状态预读取

### 目标

- WebUI 首次显示之前，先读取固件运行状态，再按固件当前状态初始化页面。
- 首次预读取只获取颜色、亮度、电池/充电状态、A/M 模式、播放状态、自动切换间隔和当前保存表情序号。
- 启动阶段不读取 LED 预览/M370，避免页面为了显示预览而拉取或套用固件当前帧。

### 修改

1. `data/index.html`
   - `<html>` 增加 `data-boot-phase="preload"`，并新增全屏启动遮罩。
   - 页面主体在预读取完成前不可见、不可点击；预读取结束并完成初始化后才切换为 `data-boot-phase="ready"`。
   - 新增 `preloadFirmwareRuntimeState()`，首次请求 `/api/status?runtimeOnly=1&noFrame=1`。
   - 首次预读取调用 `applyFirmwareRuntimeState(..., {skipFrame:true})`，明确跳过 `lastM370/m370` 帧同步。
   - `bootstrapWebUi()` 调整为：先预读取固件状态，再初始化导航、矩阵、颜色、亮度、A/M、滚动、调试控件。
   - 启动时不再把默认颜色通过 `set_color` 发送回固件；颜色只作为本地 UI 状态同步。
   - 保存表情库加载后，如果固件状态预读取成功，则用固件返回的 `autoFaceIndex` 本地构造当前保存表情预览；如果预读取失败或离线，才使用启动默认表情本地预览。

2. `src/web_api.cpp`
   - `/api/status` 支持 `summary`、`noFrame` 或 `runtimeOnly` 查询参数。
   - summary/noFrame 模式下返回运行状态，但不返回 `renderer.lastM370` 和 `renderer.lit`。
   - runtimeOnly 模式下只返回启动必需运行状态，不输出 matrix/endpoints/storage/stats/full frame 字段，减少首屏状态读取的 JSON 体积和序列化开销。
   - summary 模式下也跳过 LittleFS 容量统计，减少首次页面加载时的额外文件系统操作。

### 行为结果

- 首次打开 WebUI 时，页面不会先显示默认亮度/默认颜色/默认 M 模式再跳变。
- 页面初始控件会直接反映固件当前颜色、亮度、电池/充电状态、A/M 模式、播放状态和自动切换间隔。
- 首次启动请求不会读取 LED 预览/M370。
- 后续正常状态轮询仍可在非滚动状态下同步完整状态，用于调试和普通运行刷新。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。


## 2026-05-14 WebUI 启动读取进度条与 runtime-only 加速

### 目标

- WebUI 启动遮罩需要显示真正的确定进度条，而不是无限循环动画。
- 读取信息窗口必须在整个 WebUI 可视窗口中居中。
- 首次读取固件状态要更快，同时继续保证启动阶段不读取 LED 预览/M370。

### 修改

1. `data/index.html`
   - 启动遮罩改为 `fixed` + `100dvw/100dvh` + flex 居中，确保读取信息窗口相对于整个 WebUI 窗口居中，而不是受页面内容或滚动区域影响。
   - 原来的动画进度条替换为确定进度条：`#boot-progress-fill`、`#boot-percent`、`#boot-step` 会按实际启动阶段更新。
   - 启动阶段按顺序显示：DOM 就绪、固件 runtime-only 状态请求、状态同步、页面控件初始化、保存表情读取、首屏渲染、完成。
   - 新增 `bootFastJsonGet()`：启动预读取使用直接 `fetch`，不触发普通 `apiGet()` 的中间 `renderState()`，减少首屏隐藏阶段的无效 DOM 刷新。
   - 启动预读取改为 `/api/status?runtimeOnly=1&noFrame=1`，并加入 2500ms 超时；超时或失败时显示 fallback 阶段并继续加载本地默认 UI。

2. `src/web_api.cpp`
   - `/api/status?runtimeOnly=1` 现在只序列化首屏所需的 `ap`、`power`、`renderer` 等运行状态。
   - runtime-only 响应会立即返回，不再生成 `matrix`、`endpoints`、`storage`、`stats` 字段，也不会生成 `renderer.lastM370` / `renderer.lit`。
   - 普通 `/api/status` 行为保持不变，后续轮询仍可读取完整调试状态。

### 行为结果

- 打开 WebUI 时能看到百分比递增的正确读取进度。
- 读取状态窗口始终在整个浏览器/WebUI 视窗中居中。
- 首屏固件状态读取的数据量更小，隐藏阶段少一次普通状态渲染，因此页面进入可用状态更快。
- 首次加载仍不会读取 LED 预览/M370。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `src/web_api.cpp` 已检查 runtime-only 分支不会影响普通 `/api/status` 的完整字段输出。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。


## 2026-05-14 统一所有 LED 预览窗尺寸规则

### 目标

- 所有 LED 预览窗的最大、最小、默认尺寸都参考 6.1 基础功能页面的 `370 LED 只读预览`。
- 避免隐藏页面在启动初始化时因为 `display:none` / 0px 宽度被计算成最小尺寸，切换页面后出现预览窗过小。

### 修改

1. `data/index.html`
   - 新增统一 LED 预览尺寸 CSS 变量：
     - `--led-preview-default-cell`
     - `--led-preview-min-cell`
     - `--led-preview-max-cell`
     - `--led-preview-max-height`
   - `.matrix-wrap` 统一继承这些变量作为 `--matrix-default-cell`、`--matrix-min-cell`、`--matrix-max-cell`。
   - 所有主要 LED 预览/编辑矩阵容器都套用同一套预览尺寸 profile：
     - 6.1 `matrix-basic`
     - 6.2 `matrix-custom-edit`
     - 6.3 `matrix-parts`
     - 6.4 `matrix-scroll`
     - 6.5 `matrix-debug`
   - 新增 `.led-preview-card` / `.led-preview-wrap` 标记，确保所有 LED 预览窗与 6.1 只读预览窗使用一致的 min-width、min-height 和宽度规则。
   - `fitMatrix()` 改为从 CSS profile 读取默认 / 最小 / 最大 cell 尺寸，而不是在函数内分散硬编码。
   - 隐藏页面初始化时，如果预览容器宽度为 0 或不可见，先使用与 6.1 只读预览相同的默认 cell 尺寸，不再坍缩到最小值。
   - `switchPage()` 在页面切换后执行 `fitAllMatrices()` 和 `renderMatrices()`，确保新显示页面立即按真实容器宽度重新计算预览尺寸。
   - 宽屏仍使用 600px 最大预览高度；窄屏继承 6.1 原有的紧凑默认 cell 和最大 cell 限制。

### 行为结果

- 6.1、6.2、6.3、6.4、6.5 的 LED 预览窗尺寸规则统一。
- 页面切换后，之前隐藏的 LED 预览不会保持过小尺寸。
- 所有预览窗仍会通过 `ResizeObserver` 跟随窗口宽度自动适配，不产生横向溢出。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。


## 2026-05-14 文字滚动下移与 LED 预览框自适应边框修正

### 目标

- 文字滚动功能的 LED 显示位置整体向下移动 2 行。
- 所有主 LED 预览框继续统一代码路径，同时增加统一边框、高度和缩放规则。
- 预览框必须随窗口大小等比例适配；在 320px 视窗宽度下仍可完整显示，不裁切任何 LED 格子。
- 预览框边框高度限制为最小 280px、最大 500px。

### 修改

1. `data/index.html`
   - `textScrollVerticalOffset()` 在原有垂直居中基础上增加 2 行偏移；滚动帧签名仍包含该 offset，因此修改后会重新生成滚动帧缓存。
   - 新增统一 CSS 变量 `--led-preview-min-height:280px`，并将 `--led-preview-max-height` 从 600px 调整为 500px。
   - `.matrix-wrap.fill-column` 不再移除边框/背景，所有主 LED 预览框统一使用同一套边框、padding、圆角、背景和高度 clamp：`280px <= height <= 500px`。
   - `.led` 设置 `box-sizing:border-box`，确保 LED 的 border 计入 grid cell 尺寸，避免边框把 LED 格子挤出或裁切。
   - `LED_PREVIEW_SIZE` 增加 `minHeight:280`，并将 `maxHeight` 同步为 `500`。
   - `fitMatrix()` 改为同时读取容器真实宽度和真实高度，扣除 padding/border 后计算 cell 尺寸；宽度和高度两侧都会参与限制，保证矩阵不会超出预览框边框。
   - 隐藏页面启动阶段仍保留 6.1 只读预览的默认 cell 尺寸，等页面显示后由 `ResizeObserver`/`switchPage()` 重新按实际尺寸 refit。

### 行为结果

- 文字滚动显示比原来低 2 行。
- 6.1、6.2、6.3、6.4、6.5 的主 LED 预览框使用一致的边框和缩放实现。
- 320px 视窗宽度下，预览矩阵会缩小到可完整显示的 cell 尺寸，不会因为 LED 自身 border 被裁切。
- 宽屏下预览框边框最高 500px；所有尺寸下最低保持 280px 高度。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。


## 2026-05-14 LED 预览框改为 card-only 尺寸限制并移除矩阵外框

### 目标

- 不再给 LED 矩阵本身套可见外框；LED 周围不显示额外的 `.matrix-wrap` 边框、背景、圆角或 padding。
- `280px` 最小高度、`500px` 最大高度的限制只作用在 `.card.led-preview-card` 上，而不是作用在 LED 矩阵 wrapper 上。
- 缩放时必须改变 LED cell 自身的 `--cell` 尺寸，不能只改变外层容器尺寸。
- 在 320px 视窗宽度下仍保持矩阵完整显示，不裁切 LED 格子。

### 修改

1. `data/index.html`
   - `.matrix-wrap` / `.matrix-wrap.fill-column` 改为透明、无边框、无背景、无圆角、无 padding 的布局容器。
   - `.led-preview-card` 改为唯一承担预览高度限制的 card：`height: clamp(280px, 72vw, 500px)`，并保留 `min-height:280px`、`max-height:500px`。
   - `.led-preview-card` 使用 flex column；标题固定占位，矩阵区域自动填充 card 剩余空间。
   - 新增 `matrixAvailableContentBox()` 与 `matrixReservedHeight()`，让 `fitMatrix()` 以 card 的真实 content box 和矩阵 wrapper 的实际可用空间共同计算 LED cell 尺寸。
   - `fitMatrix()` 继续直接更新矩阵 CSS 变量 `--cell`，因此缩放时 `.led` 元素自身宽高同步变化。
   - `ResizeObserver` 同时观察 `.matrix-wrap`、`.led-preview-card` 和 `.debug-measure-card`，窗口或 card 尺寸变化时立即重新计算 LED cell。

### 行为结果

- LED 预览周围不再出现额外外框；可见边界只来自外层 card。
- 尺寸限制不再绑在 LED wrapper 上，避免只缩放外框而 LED cell 不跟随缩放。
- 所有主预览矩阵继续走统一 `initMatrix()` / `fitMatrix()` / `ResizeObserver` 实现。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。

## 2026-05-14 matrix 缩放恢复为历史 HTML 方式
- 所有主矩阵预览继续共用 `.matrix-wrap` + `.matrix` + `.led` 结构。
- 缩放逻辑恢复为历史 HTML 的 `fitMatrix()` 模式：从 `.matrix-wrap` 的可用内容宽度/高度计算 `--cell`，缩放 LED cell 本身，而不是缩放外框。
- `.matrix-wrap` 保持透明、无 border、无 padding、无 background；尺寸上限/下限继续只作用在外层 preview card。
- `ResizeObserver` 恢复为只观察 `.matrix-wrap`，与历史实现一致，避免 card/reserved-height 额外推导导致尺寸异常。

## 2026-05-14 LED matrix 预览实时缩放修复

- 修复 `observeMatrixWraps()` 定义后没有被启动的问题；WebUI 初始化矩阵后立即注册实时缩放观察。
- 新增 `scheduleMatrixFitRender()`，用 `requestAnimationFrame` 节流 `fitAllMatrices()` + `renderMatrices()`，窗口拖动/旋转/视觉视窗变化时逐帧更新 `--cell`。
- `ResizeObserver` 同时观察 `.matrix-wrap`、`.led-preview-card` 和 `.debug-measure-card`，card 尺寸变化时不需要刷新页面即可重新缩放 LED 本身。
- `switchPage()` 与 boot overlay 关闭后都会排队多帧 refit，避免隐藏页面或初次显示时使用旧尺寸。

## 2026-05-14 LED matrix 预览顺滑缩放 / 横向最小与竖向最大限制

### 目标

- LED matrix 预览在窗口拖动、视窗变化、card 尺寸变化时顺滑连续缩放。
- LED matrix 到预览 card 内部边界的透明留白保持等距。
- 不恢复 LED 外框；可见边界仍然只来自外层 card。
- `min` 尺寸只作为横向约束；不再强制 280px 最小高度。
- `max` 尺寸只作为竖向约束；继续使用 500px 最大高度。

### 修改

1. `data/index.html`
   - 移除 `--led-preview-min-height` 与 `LED_PREVIEW_SIZE.minHeight`。
   - 新增 `--led-preview-min-width:320px`，preview card 使用 `min-inline-size:min(var(--led-preview-min-width),100%)`，因此最小限制只影响横向且不会破坏 320px 视窗适配。
   - 保留 `--led-preview-max-height:500px`，preview card 只保留竖向 `max-height`。
   - `.matrix-wrap` 继续无 border / background / shadow，但增加统一透明 padding 作为 LED matrix 与 card 内部边界之间的等距留白。
   - `fitMatrix()` 使用 `getBoundingClientRect()` 的浮点宽度和浮点 cell 计算，不再用 `Math.floor()`，从而避免缩放时按 1px 台阶跳变。
   - `fitMatrix()` 继续直接更新 `.matrix` 的 `--cell`，因此实际 `.led` 元素本身会缩放。
   - 竖向最大高度由 card 的可用高度预算参与计算，防止矩阵超过 card 的 500px 最大高度。

### 验证

- `data/index.html` 内联 JavaScript 已通过 `node --check`。
- `data/resources/saved_faces.json`、`data/resources/runtime_settings.json`、`data/resources/battery_calib.json` 已通过 JSON 解析。
- 本地环境没有安装 PlatformIO (`pio`)，因此未在容器内执行固件编译。

## 2026-05-14 LED matrix 预览边界留白随缩放同比例变化

### 目标
- LED matrix 到预览 card 内部边界的距离必须四边等距。
- 缩小预览 card 时，这个边界距离也必须跟随 LED cell 一起缩小，不能保持固定 px 值。
- 不能恢复 LED 外框；可见边界仍只来自外层 card。

### 实现
- 新增 `--led-preview-edge-ratio:.6667`，用比例描述 matrix 边界留白，而不是固定 `12px`。
- `.matrix-wrap` 使用 `--matrix-edge-gap` 作为透明 padding。
- `fitMatrix()` 在计算 `--cell` 时把 `2 * edgeRatio * cell` 一并纳入宽高预算：
  - 横向分母为 `COLS + 2 * edgeRatio`
  - 竖向分母为 `ROWS + 2 * edgeRatio`
- `fitMatrix()` 每次设置 `.matrix` 的 `--cell` 后，同时设置当前 `.matrix-wrap` 的 `--matrix-edge-gap = cell * edgeRatio`。

### 结果
- 预览缩放时 LED cell 与 matrix 外侧透明留白同步连续缩放。
- matrix 到容器边缘的距离保持四边一致，不再出现缩小时留白过大的问题。

Firmware text-scroll RAM cache limit update:
- src/config.h
  - Raises MAX_SCROLL_FRAMES from 2048 to 3072. With FRAME_BYTES = 47 bytes for 370 packed LEDs, the scroll frame cache is about 144 KB instead of about 96 KB.
  - Keeps the cache RAM-only and does not add flash persistence for scroll timelines.
- data/index.html
  - Raises the WebUI default text-scroll firmware-frame limit to 3072.
  - Adds firmwareScrollMaxFrames as a runtime value and updates it from /api/status renderer.scrollMaxFrames when available, preventing WebUI and firmware limit mismatch.
- tools/build_unifont_webui_subset_from_png.py
  - Removes EXTERNAL_CODE_COMMENTS.txt from generated-font text scanning because external comment files are no longer part of code/project outputs.
- Delivery hygiene
  - Removes EXTERNAL_CODE_COMMENTS.txt and PATCH_CONTENTS.txt from the output package. Explanatory comments should live directly in code using the relevant language's comment syntax.

## 2026-05-14 WebUI 首屏加载不等待 saved_faces / LED 预览矩阵

### 目标
- WebUI 首屏加载阶段只读取轻量 runtime 状态：颜色、亮度、电池/充电、A/M 模式、播放状态和滚动缓存上限。
- 首屏显示前不读取 `saved_faces.json`。
- 首屏显示前不读取完整 `/api/status` 中的 LED 预览矩阵 / `lastM370`。
- `saved_faces.json` 和 LED 预览矩阵在页面显示完成后异步读取，不阻塞 boot overlay 关闭。

### 实现
- `bootstrapWebUi()` 保留 `preloadFirmwareRuntimeState()` 的 `GET /api/status?runtimeOnly=1&noFrame=1`。
- 删除首屏阶段的 `await loadFaceLibrary()`，改为 `runPostBootDeferredReads()` 在 `finishBootVisibility()` 后异步执行。
- `runPostBootDeferredReads()` 页面可见后依次执行：
  1. `loadFaceLibrary()` 读取 `/api/saved_faces` 或本地 `saved_faces.json`。
  2. `syncRuntimeStateFromFirmware('post_load_matrix_preview')` 读取完整 status，用于同步 LED 预览矩阵 / `lastM370`。
  3. 如果完整 status 读取失败且不是滚动播放状态，则按固件 face index 或默认表情做本地 fallback。
- `syncRuntimeStateFromFirmware()` 现在返回 `true/false`，便于 deferred loader 判断矩阵预览是否读取成功。

### 结果
- 首屏 WebUI 更快显示。
- 大文件 `saved_faces.json` 与完整 status 的 M370/矩阵内容不会阻塞页面加载。
- 页面显示后仍会自动补齐保存表情列表和当前 LED 预览。

## 2026-05-14 文字滚动上传完成后再设置帧率

### 目标
- 修复文字滚动上传过程中修改/输入帧率不生效的问题。
- 帧数据上传阶段只负责把 M370 帧写入固件 RAM 缓存。
- 帧率/间隔数据必须在全部帧 chunk 上传完成并得到固件确认后，再作为单独控制指令发送。

### 实现
- `data/index.html`
  - `uploadFirmwareScrollTimeline()` 上传 `/api/scroll` chunk 时不再携带 `fps` / `intervalMs`。
  - 所有 chunk 都使用 `start:false`，最后一个 chunk 也不会直接启动播放。
  - 全部帧上传完成后，重新读取当前帧率输入框，计算最终 `intervalMs`。
  - 之后发送 `POST /api/command` 的 `start_scroll` 指令，payload 中携带最终 `fps` / `intervalMs`，再启动固件滚动。
- `src/web_api.cpp`
  - `/api/scroll` 只有在请求体显式包含 `fps` 或 `intervalMs` 时才更新 `scrollIntervalMs`，避免帧 chunk 上传阶段覆盖已设置的播放间隔。
  - 新增 `start_scroll` API command，用于在 RAM 帧缓存写入完成后按最终帧率启动播放。
  - 新增 `scrollIntervalFromCommand()`，统一解析 `fps` / `intervalMs`，并同时兼容 JSON 整数与浮点 fps。

### 结果
- 上传大段文字时，即使用户在上传期间修改 fps，最终生效的是帧上传完成后输入框中的最新帧率。
- 固件不会在最后一个帧 chunk 到达时用旧帧率提前开始滚动。
- 帧数据上传与播放参数上传解耦，后续扩展更多播放参数时也可以沿用这个顺序。

## 2026-05-14 保存表情列表拖拽柄/编号/操作按钮样式调整

### 目标
- 保存表情列表中的拖拽柄从盲文点阵符号改成三条横线的拖拽样式。
- 保存表情序号不显示外框，字号增大，提高可读性。
- 操作按钮使用图标化 emoji：应用使用灯泡，重命名使用铅笔，删除使用垃圾桶。
- 操作按钮始终保持同一行，应用按钮靠右，其余按钮靠左。

### 实现
- `data/index.html`
  - `.drag-handle` 改为纯 CSS 三横线：使用 `::before` 和 `linear-gradient` 绘制，不再依赖 `⠿` 文本字符。
  - `.saved-index` 移除 border/background/border-radius，设置更大的 `font-size` 和 `font-weight`。
  - `.face-action-bar` 改为不换行 flex 行，必要时横向滚动，避免窄宽度下按钮断行。
  - `.btn-apply` 使用 `margin-left:auto`，让应用按钮在操作栏最右侧。
  - `createFaceRow()` 中按钮文本改为 `💡`、`✏️`、`🗑️`，并保留 `title` / `aria-label` 作为可访问说明。

### 结果
- 拖拽柄视觉上是标准三横线样式。
- 保存表情编号更像列表序号，不再像一个按钮/徽章。
- 上移、下移、重命名、删除保留在左侧；应用按钮独立靠右。
- 操作按钮不会因为排列变化自动换到第二行。

## 2026-05-14 GPIO B1/B2/B3 中断文字滚动后同步 WebUI 6.4 预览

### 目标
- 当实体 GPIO B1/B2/B3 在文字滚动模式中被按下时，固件停止文字滚动并切换到对应保存表情/当前表情。
- WebUI 6.4 文字滚动页面需要收到这个停止信息，立即停止本地预览计时器和上传/播放状态。
- 6.4 的 LED 预览矩阵不能停留在文字滚动帧或空白帧，应显示固件当前表情预览。

### 实现
- `src/state.h`
  - 新增 `scrollStopEventSeq`、`scrollStopEventMs`、`scrollStopEventButton`、`scrollStopEventSource`、`scrollStopEventReason`。
  - 这些字段作为轻量事件序号，不保存到 flash，只用于 WebUI 轮询识别实体按钮打断滚动。
- `src/buttons.cpp`
  - B1/B2/B3 从 GPIO 来源触发，并且触发前处于 firmware scroll/scroll preview 状态时，动作成功后递增 `scrollStopEventSeq`。
  - B1/B2 仍然停止滚动后切换上一个/下一个保存表情。
  - B3 仍然停止滚动后切换 A/M，并通过原有延迟恢复逻辑显示当前保存表情。
- `src/web_api.cpp`
  - `/api/status` 的 `renderer.scrollStopEvent` 返回上述事件信息，runtime-only 状态也会包含该轻量事件。
  - `/api/command` 回复也返回 `scrollStopEvent`，便于调试和保持返回结构一致。
- `data/index.html`
  - 6.4 页面在文字滚动运行中使用 `GET /api/status?runtimeOnly=1&noFrame=1` 做较高频轻量轮询，不读取 `lastM370`，避免增加矩阵/flash 负载。
  - 检测到新的 GPIO B1/B2/B3 scroll stop event 后，先停止 WebUI 的本地滚动预览状态。
  - 再延迟读取一次完整 `/api/status`，获取固件当前 `lastM370`，并把 6.4 预览矩阵切换到当前表情。
  - `resetScrollControlsAfterButton()` 新增 `preserveCurrentFrame` 选项，避免完整状态已经同步表情帧后又被清成空白。

### 结果
- 实体 B1/B2/B3 按钮可以可靠打断文字滚动。
- WebUI 6.4 不需要等 10 秒完整轮询才知道滚动已停止。
- 6.4 页面停止预览后会显示固件当前表情，而不是继续显示旧滚动帧或空白帧。

## 2026-05-14 WebUI GNU Unifont subset 全角间距修复

### 目标
- 修复当前 GNU Unifont WebUI subset 中 `日`、`白`、`ノ` 等中日文字在浏览器内显示时左右间距不稳定的问题。
- 不回退 WebUI，不更换为外部在线字体，继续保持 GNU Unifont subset 内嵌到 `index.html`。
- 继续跳过 GNU Unifont BMP PNG 无法生成的字符，不强行加入 unsupported codepoint。

### 实现
- `tools/build_unifont_webui_subset_from_png.py`
  - 新增 `is_fullwidth_codepoint()`，使用 Unicode East Asian Width 的 `F/W` 属性判断全角/宽字符。
  - 平假名、片假名、片假名音标扩展、CJK 统一表意文字、CJK 兼容表意文字固定使用 16 px advance。
  - 不再只依赖“墨迹是否超过 8 px”推断宽度，避免全角标点、小片假名或窄墨迹字形被误判成半宽。
  - `hmtx` 的 left side bearing 改为与 glyph outline 的 `xMin` 保持一致，避免浏览器 rasterizer 因 metrics 不一致产生视觉偏移。
  - Unicode format control 保持 0 advance，避免隐藏控制字符产生额外间距。
- `data/index.html`
  - WebUI 主字体和控件字体增加 `font-kerning:none`、`font-variant-ligatures:none`、`font-feature-settings:"kern" 0`、`letter-spacing:0`。
  - 文字滚动输入框同样禁用 kerning/ligature，并保持 Ark12 字体设置不变。
  - 重新内嵌修复后的 `data/resources/fonts/unifont.woff2`。

### 验证
- 实际 WebUI/resource 字符数：700。
- 修复后的 GNU Unifont subset 字符数：1869。
- 实际 WebUI/resource 字符缺失数：0。
- 内嵌字体 cmap 与 `data/resources/fonts/unifont.woff2` cmap 一致。
- Unicode East Asian Width 为 `F/W` 的 subset 字符均为 16 px advance。
- 重点字符 metrics：
  - `日`：advance 16，LSB 3。
  - `白`：advance 16，LSB 2。
  - `ノ`：advance 16，LSB 3。
  - `。`、`、`、`！`、`）` 等全角标点：advance 16。

### 结果
- WebUI 中 CJK / 日文字符不再因为 subset 字体宽度误判出现半宽占位。
- 字形横向 metrics 与轮廓边界一致，浏览器显示更稳定。
- 字体仍完全离线，并继续内嵌在 HTML 中。

## 2026-05-15 调试页电池最低/最高电压与断电检测

### 目标
- 调试页面显示当前电池最低电压记录和最高电压记录。
- 调试页面提供重置最低电压记录、重置最高电压记录按钮。
- 如果电池 ADC 原始数据出现巨大快速压降，固件停止电压 EMA / 校准算法，直接向 WebUI 输出 `vbat=0`，表示电池已断开。
- 电池断开时，顶部电池状态圆点变为灰色，并把“电池”文案改为“未上电”。

### 实现
- `src/config.h`
  - 新增 `BATTERY_DISCONNECT_ADC_DROP_MV=1000`、`BATTERY_DISCONNECT_ADC_LOW_MV=900`、`BATTERY_RECONNECT_ADC_MV=1500`。
  - 判定逻辑基于电池 ADC 原始毫伏值：连续采样出现大于 1000 mV 的快速下降，且当前 ADC 低于 900 mV 时进入断电状态。
  - 断电后只有 ADC 恢复到 1500 mV 以上才退出断电状态，避免插拔临界抖动。
- `src/power_monitor.h` / `src/power_monitor.cpp`
  - 新增 `batteryDisconnected`、`batteryPrevAdcMv`、`batteryDisconnectDropMv`、`batteryDisconnectedSinceMs` 等状态字段。
  - 断电状态下不再运行电池电压 EMA，不更新最低/最高电压校准记录，直接保持 `vbat=0.0`、`batteryPercent=0`。
  - 新增 `resetBatteryVoltageMinimum()` / `resetBatteryVoltageMaximum()`，用于按钮重置当前最低/最高电压记录，并立即保存到 `battery_calib.json`。
- `src/web_api.cpp`
  - `/api/power` 和 `/api/status` 的 `power` 对象新增 `batteryPowered`、`batteryDisconnected`、`batteryStateText`、`batteryRangeMin`、`batteryRangeMax`、`batteryAdcMv`、`batteryPrevAdcMv`、断电阈值等字段。
  - 电池断开时 `batteryIconClass=status-dot dim`、`batteryIconColor=#9aa6b2`、`batteryStateText=未上电`。
  - `/api/command` 新增 `reset_battery_min` 和 `reset_battery_max` 指令。
- `data/index.html`
  - 调试页“状态 / ADC / 网络”区新增“刷新电池状态”“重置最低电压”“重置最高电压”按钮。
  - 调试信息新增电池状态、最低/最高电压记录、电池 ADC raw、上次 ADC raw、快速压降值和阈值。
  - 顶部电池 badge 在 `batteryPowered=false` 时显示“未上电 0.00 V”，圆点保持灰色。
  - 调试页进入后也主动刷新 `/api/power`，并与基础页共享 1s 电源状态轮询。

### 结果
- 调试页可以直接查看并重置当前电池最低/最高电压记录。
- 电池被拔掉或电池 ADC 线路突然掉到低电平时，WebUI 不会继续显示 EMA 滞后的旧电压。
- 断电状态以 0V 和灰色“未上电”明确显示，避免误判为低电量或仍在供电。


### Battery icon percentage thresholds update

- Battery badge color thresholds are now:
  - `batteryPowered=false` / 未上电: gray (`status-dot dim`, `#9aa6b2`).
  - `batteryPercent < 10`: red (`status-dot danger`, `#ef4444`).
  - `batteryPercent < 30`: yellow (`status-dot warn`, `#f59e0b`).
  - `batteryPercent >= 30`: green (`status-dot`, `#59d98e`).
- Charging status no longer forces the battery badge to red; only battery percentage and unpowered state control the battery badge color.
