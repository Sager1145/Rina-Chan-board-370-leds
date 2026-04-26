# ESP32-S3 RinaChanBoard 固件外置注释

- 源 ZIP：`esp32s3_firmware_mobile_compact_controls.zip`
- 注释生成时间：2026-04-26
- 注释方式：**不改动源码文件**；所有解释都集中在本 `.md` 文件。
- 行号说明：下面的行号基于本次上传 ZIP 解压后的当前源码。

## 1. 总览

这套固件是一个运行在 ESP32-S3 MicroPython 上的 370 颗 WS2812 LED 矩阵控制程序。主功能包括：实体按键换脸/调亮度/调间隔、电池电量和充电状态显示、AP/STA 网络、HTTP Web 控制台、UDP/文本协议兼容、M370 真实矩阵表情管理、WebUI 固件侧滚动文字与 Unity 时间轴播放。

**本次 M/A 修复**：新增 `LinaBoardApp.force_m_mode()`，所有实际 Web/网络控制都会把保存表情自动轮播 `auto` 置为 `False`，即回到 M 模式；此动作会保存到 `linaboard_settings.json`，但不会绘制大号 `M` 覆盖层，避免盖掉网页刚发送的表情/颜色/滚动文字/时间轴画面。

当前 `main.py` 的启动横幅写明本构建是 **no MatrixDemo / no BadApple**：相关文件和配置仍保留在项目中，但主启动路径不导入 `matrix_demos.py`、`demo_faces.py` 或 BadApple part 模块，以降低启动时堆内存压力。

## 2. 文件职责索引

| 文件 | 行数/大小 | 外置注释摘要 |
|---|---:|---|
| `boot.py` | 16 行 | MicroPython 启动阶段执行的最小启动脚本；只做垃圾回收和启动日志，避免在 boot 阶段占用堆。 |
| `config.py` | 140 行 | 全局配置中心：按键轮询、亮度、动画、Battery ADC、充电检测、边缘闪烁、BadApple/演示相关常量。 |
| `app_state.py` | 121 行 | 运行期状态对象：AppState 保存界面/按键/覆盖层/网络控制状态，BatteryState 保存电池校准和历史。 |
| `settings_store.py` | 106 行 | 持久化设置读写层：将亮度、自动播放、间隔、电池校准和电量历史写入 JSON。 |
| `brightness_modes.py` | 58 行 | 把 UI 百分比亮度换算成物理 LED 每通道亮度上限。 |
| `buttons.py` | 221 行 | 实体按键输入层：GPIO 上拉、低电平有效、消抖、长按重复触发。 |
| `board.py` | 660 行 | 主硬件抽象层：ESP32-S3 GPIO2 驱动 370 颗 WS2812，定义不规则 22×18 虚拟矩阵映射和绘图基础函数。 |
| `board_370.py` | 164 行 | 较精简的 370 LED 板卡驱动备用实现；当前 main.py 使用 board.py，不直接使用本文件。 |
| `display_num.py` | 256 行 | 数码/图标/滚动文字渲染器：间隔、亮度、电池百分比/电压/时间、A/M、大号字、IP/SSID 滚动显示。 |
| `battery_runtime.py` | 140 行 | 电池续航/充电时间估算器：记录百分比变化速率，并按亮度/模式加权估算剩余时间。 |
| `battery_monitor.py` | 310 行 | 电池采样和校准逻辑：ADC 电压读取、1 秒均值窗口、百分比曲线、充电检测、颜色映射。 |
| `emoji_db.py` | 130 行 | 原版 RinaChanBoard 表情部件数据库：左右眼、嘴巴、脸颊 bitpack 数据和布局常量。 |
| `saved_faces_370.py` | 344 行 | 370 物理矩阵表情库：默认表情、WebUI 保存/重命名/删除/排序/锁定，JSON 作为固件端真值。 |
| `rina_protocol.py` | 744 行 | 协议兼容层：支持原版二进制 UDP、微信小程序文本协议、M370 物理矩阵扩展、WebUI 管理命令；WebUI runtime/manual-mode 控制也会触发 M/A 回 M。 |
| `esp32s3_network.py` | 620 行 | ESP32-S3 原生网络层：同时启用 AP/STA、UDP 服务、HTTP 控制台/API，状态接口版本更新为 1.6.1。 |
| `webui_runtime.py` | 384 行 | WebUI 动画运行时：把滚动文字和 Unity 时间轴播放从浏览器计时迁移到固件主循环；启动滚动/时间轴时强制 A/M 回 M。 |
| `main.py` | 1119 行 | 主应用入口和调度循环：连接状态、按键路由、显示覆盖层、电池服务、WebUI、协议、自动换脸；新增 force_m_mode() 统一处理网页控制回 M。 |
| `demo_faces.py` | 298 行 | 旧版内置 ASCII 表情帧；当前 no-demo 构建不在主启动路径导入，用于保留/迁移参考。 |
| `matrix_demos.py` | 473 行 | 旧版矩阵演示动画控制器；当前 main.py 中演示模式被禁用，不在主启动路径导入。 |
| `wifi_config.py` | 16 行 | Wi-Fi/AP 配置文件：STA SSID/密码、AP SSID/密码、HTTP/UDP 端口。 |
| `webui_index.html.gz` | 5203 行（解压后） | 压缩的内置 Web 控制台：HTML/CSS/JS 合并后 gzip，由 HTTP 根路径直接返回。 |
| `upload_esp32s3_firmware.ps1` | 114 行 | Windows PowerShell 上传脚本：解压本 ZIP，使用 mpremote 上传固件源码并 reset ESP32-S3；默认不上传本脚本和外置注释。 |
| `__pycache__/` | 目录 | CPython 运行缓存，不属于 MicroPython 固件逻辑；烧录到 ESP32-S3 时通常不需要。 |

## 3. 硬件与 IO 注释

| 功能 | 引脚/接口 | 注释 |
|---|---|---|
| WS2812 数据 | `GPIO2` | 370 颗 LED，虚拟 22×18，不规则行长 |
| 电池 ADC | `GPIO10` | 100 kΩ / 57 kΩ 分压，2S 电池电压反算 |
| 充电检测 ADC | `GPIO1` | 270 kΩ / 47 kΩ 分压，>4.0 V 判定充电，<=3.0 V 判定未充电 |
| 按键 | `GPIO17/16/15/40/41/42` | 内部上拉，按下接 GND，低电平有效 |
| Wi-Fi | `ESP32-S3 内置` | AP + 可选 STA，同时提供 UDP 1234 和 HTTP 80 |

### 3.1 370 LED 矩阵几何

- 真实 LED 数：`370`。
- 虚拟坐标：`22 × 18`。
- 不规则行长：`18, 20, 20, 20, 22×9, 20, 20, 20, 18, 16`。
- `board.logical_to_led_index(x, y)` 是核心映射函数；虚拟坐标中没有实体 LED 的 padding 点返回 `None`。
- 原版 RinaChanBoard 16×18 face 会用 `SRC_TO_DST_ROW_OFFSET=1`、`SRC_TO_DST_COL_OFFSET=2` 居中映射到 370 LED 板。

## 4. 实体按键行为注释

| 按键 | GPIO | 行为 |
|---|---:|---|
| B1 | `GPIO17` | 普通：上一个表情；按住 B3：间隔 +0.5 s |
| B2 | `GPIO16` | 普通：下一个表情；按住 B3：间隔 -0.5 s；与 B6：滚动显示 IP/SSID |
| B3 | `GPIO15` | 松开切换自动/手动；与 B1/B2 调间隔；与 B6 被消费但演示模式禁用 |
| B4 | `GPIO40` | 亮度 +5%；与 B5：重置亮度 |
| B5 | `GPIO41` | 亮度 -5%；与 B4：重置亮度 |
| B6 | `GPIO42` | 短按显示电量 2 s；长按 700 ms 进入电池页面；与 B2 显示 IP/SSID |

按键输入为内部上拉、低电平有效：未按下读 `1`，按下读 `0`。`ButtonBank.poll()` 只返回“按下事件”和“长按重复事件”，释放事件由 `main.py` 的 `check_b3_release()` / `check_b6_release()` 另行判断。

## 5. 持久化文件注释

| 文件 | 保存内容 |
|---|---|
| `linaboard_settings.json` | 自动模式、间隔、亮度、电池校准 min/max、充/放电历史 |
| `saved_faces_370.json` | 370 LED 表情列表、顺序、锁定状态、类型 |
| `saved_faces_370_names.json` | 旧版默认表情重命名迁移文件，存在时读取 |
| `wifi_config.py` | STA/AP Wi-Fi 配置，作为源码配置文件保存 |
| `upload_esp32s3_firmware.ps1` | PC 端辅助脚本，不是 MicroPython 运行依赖；上传脚本会排除自己 |

## 6. 主控制流注释

```text
boot.py
  -> main.main()
     -> 创建 LinaBoardApp
     -> 创建 ESP32S3Network 并启动 AP/STA + UDP + HTTP
     -> 创建 RinaProtocol 并绑定 network sender
     -> app.attach_network()
     -> app.run()
        -> initialize(): 读取设置、应用亮度、画当前表情、启动电池采样
        -> while True:
           - service_network(): UDP/HTTP 收包并交给 RinaProtocol
           - check_*_combo(): 检查 B2+B6、B3+B6 等组合键
           - buttons.poll(): 处理实体按键事件
           - service_battery_overlay(): 电池显示和充电动画
           - service_ip_display(): IP/SSID 滚动
           - web_runtime.service(): WebUI 滚动/时间轴播放
           - update_calibration(): 电池校准/历史记录
           - auto face cycling: 自动换脸
           - sleep(POLL_PERIOD_MS)
```

## 7. 逐文件外置注释

### `boot.py`

MicroPython 启动阶段执行的最小启动脚本；只做垃圾回收和启动日志，避免在 boot 阶段占用堆。

- 此文件应保持极小，避免 boot 阶段导入大量模块导致内存碎片。
- 真正硬件初始化在 main.main() 与 LinaBoardApp.initialize() 中完成。

### `config.py`

全局配置中心：按键轮询、亮度、动画、Battery ADC、充电检测、边缘闪烁、BadApple/演示相关常量。

- 修改 GPIO、阈值、计时、亮度范围时优先改本文件。
- BATTERY_CAL_VERSION 改变会让 settings_store.py 在下次启动重置旧电池校准。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 7 | `POLL_PERIOD_MS` | 值：10 |
| 8 | `SETTINGS_FILE` | 值："linaboard_settings.json" |
| 10 | `DEFAULT_FACE` | 值：0 |
| 11 | `NUM_FACES` | 值：11 |
| 13 | `DEFAULT_INTERVAL_S` | 值：1.0 |
| 14 | `INTERVAL_STEP_S` | 值：0.5 |
| 15 | `INTERVAL_MIN_S` | 值：0.5 |
| 16 | `INTERVAL_MAX_S` | 值：10.0 |
| 18 | `DEMO_DEFAULT_INTERVAL_S` | 值：5.0 |
| 19 | `DEMO_DEFAULT_AUTO` | 值：True |
| 25 | `DEFAULT_BRIGHTNESS` | 值：30 |
| 26 | `BRIGHTNESS_STEP` | 值：5 |

### `app_state.py`

运行期状态对象：AppState 保存界面/按键/覆盖层/网络控制状态，BatteryState 保存电池校准和历史。


**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 10–93 | `class AppState` | 主程序状态容器，使用 __slots__ 节省 MicroPython 堆内存；不包含复杂逻辑，只保存可变状态。 |
| 39–93 | `AppState.__init__(self)` | 初始化默认表情、自动切换、亮度、覆盖层、电池显示、组合键、IP 滚动等运行状态。 |
| 95–121 | `class BatteryState` | 电池校准和历史容器，保存 learned min/max、最近电压、充/放电历史速率。 |
| 103–121 | `BatteryState.__init__(self)` | 初始化默认 2S 电池电压范围 6.2–8.0 V、校准计数器和历史数组。 |

### `settings_store.py`

持久化设置读写层：将亮度、自动播放、间隔、电池校准和电量历史写入 JSON。


**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 14–19 | `clamp_interval(value)` | 把自动换脸间隔限制到配置范围，并保留 0.1 秒精度。 |
| 21–26 | `clamp_brightness(value)` | 把用户亮度百分比限制到 5–100。 |
| 28–51 | `save_settings(app_state, battery_state)` | 把 AppState/BatteryState 中需要跨重启保留的数据写入 linaboard_settings.json。 |
| 53–106 | `load_settings(app_state, battery_state)` | 读取 JSON 设置；校验电池校准版本，不匹配时重置校准和历史，避免旧曲线污染新版本。 |

### `brightness_modes.py`

把 UI 百分比亮度换算成物理 LED 每通道亮度上限。


**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 27–33 | `clamp_ui_brightness(value)` | 限制 UI 百分比亮度到合法范围。 |
| 36–57 | `effective_brightness(ui_brightness, badapple_mode, demo_mode)` | 把 UI 百分比换算为 board.py 的每通道亮度 cap；当前演示模式禁用，因此 demo_mode 不再降亮度。 |

### `buttons.py`

实体按键输入层：GPIO 上拉、低电平有效、消抖、长按重复触发。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 22 | `BTN_PREV` | 值：17 |
| 23 | `BTN_NEXT` | 值：16 |
| 24 | `BTN_AUTO` | 值：15 |
| 25 | `BTN_BRIGHT_DN` | 值：40 |
| 26 | `BTN_BRIGHT_UP` | 值：41 |
| 27 | `BTN_BRIGHT_RST` | 值：42 |
| 32 | `DEFAULT_BUTTON_PINS` | 值：(     BTN_PREV,     BTN_NEXT,     BTN_AUTO,     BTN_BRIGHT_DN,     BTN_BRIGHT_UP,     B... |
| 47 | `DEFAULT_REPEAT_GPIOS` | 值：(     BTN_PREV,     BTN_NEXT,     BTN_BRIGHT_DN,     BTN_BRIGHT_UP, ) |
| 58 | `DEBOUNCE_MS` | 值：25 |
| 65 | `REPEAT_INITIAL_MS` | 值：400 |
| 66 | `REPEAT_PERIOD_MS` | 值：140 |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 73–221 | `class ButtonBank` | 统一管理 6 个低电平有效按键；poll() 输出本轮触发的 GPIO。 |
| 92–115 | `ButtonBank.__init__(self, gpios, debounce_ms, repeat_gpios, repeat_initial_ms...` | 配置 GPIO 为 Pin.IN/PULL_UP，并创建消抖、重复触发计时状态。 |
| 127–183 | `ButtonBank.poll(self)` | 读取所有按键，进行 25 ms 消抖；新按下立即触发，B1/B2/B4/B5 支持长按重复。 |
| 194–195 | `ButtonBank.is_down(self, gpio)` | 返回消抖后的稳定按下状态，组合键判断应使用此方法。 |
| 201–205 | `ButtonBank.is_down_raw(self, gpio)` | 返回未经消抖的原始电平，主要用于诊断。 |
| 211–215 | `ButtonBank.any_down(self)` | 检查是否有任意按键按下。 |
| 220–221 | `ButtonBank.gpios(self)` | 返回当前管理的 GPIO 列表，启动日志会打印。 |

### `board.py`

主硬件抽象层：ESP32-S3 GPIO2 驱动 370 颗 WS2812，定义不规则 22×18 虚拟矩阵映射和绘图基础函数。

- 当前主程序导入的是 board.py，不是 board_370.py。
- ROW_LENGTHS 合计必须等于 NUM_LEDS=370；logical_to_led_index() 是所有绘图正确性的核心。
- NeoPixel 初始化后立即写入全黑帧，用于抑制电平转换/WS2812 初始化毛刺。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 52 | `LED_PIN` | WS2812 数据输出 GPIO。 |
| 53 | `NUM_LEDS` | 真实 LED 总数。 |
| 60 | `TARGET_FPS` | 值：60 |
| 61 | `FRAME_TIME_S` | 值：1.0 / TARGET_FPS |
| 62 | `FRAME_TIME_MS` | 值：1000.0 / TARGET_FPS |
| 84 | `MAX_BRIGHTNESS_HARD_CAP` | 值：170 |
| 85 | `MAX_BRIGHTNESS_FLOOR` | 值：1 |
| 86 | `MAX_BRIGHTNESS_DEFAULT` | 值：51 |
| 87 | `MAX_BRIGHTNESS` | 值：MAX_BRIGHTNESS_DEFAULT |
| 119 | `ROW_LENGTHS` | 每一行真实 LED 数，决定不规则矩阵几何。 |
| 133 | `ROWS` | 值：len(ROW_LENGTHS) |
| 134 | `COLS` | 值：max(ROW_LENGTHS) |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 31–34 | `ticks_ms()` | 跨平台毫秒计时包装；MicroPython 优先用 time.ticks_ms。 |
| 37–45 | `sleep_ms(ms)` | 跨平台毫秒休眠包装。 |
| 95–102 | `set_max_brightness(value)` | 设置全局物理亮度上限，限制在 1–170。 |
| 108–109 | `get_max_brightness()` | 读取当前物理亮度上限。 |
| 196–249 | `class FramePacer` | 帧率调度器，用于动画按目标 FPS 渲染。 |
| 206–214 | `FramePacer.__init__(self, fps)` | 建立帧间隔和下一帧时间点。 |
| 219–233 | `FramePacer.tick(self)` | 等待到下一帧时间点。 |
| 238–241 | `FramePacer.elapsed_s(self)` | 返回从创建以来经过的秒数。 |
| 246–249 | `FramePacer.done(self, duration_s)` | 判断指定持续时间是否结束。 |
| 258–271 | `scale_color(rgb)` | 按当前亮度上限等比例缩放 RGB，保持色相。 |
| 278–286 | `wheel(pos)` | 彩虹色轮函数，给 demo/动画使用。 |
| 293–316 | `hsv_to_rgb(h, s, v)` | HSV 转 RGB 辅助函数。 |
| 324–351 | `logical_to_led_index(x, y)` | 核心坐标映射：把 22×18 虚拟坐标转成真实 WS2812 串行索引；无实体 LED 的 padding 返回 None。 |
| 358–363 | `clear(write)` | 清空整条 LED 缓冲区，可选择立即 write。 |
| 369–370 | `show()` | 把当前 np 缓冲发送到 LED。 |
| 377–381 | `set_pixel(x, y, rgb)` | 设置单个逻辑像素，会跳过无效 padding 点。 |
| 387–390 | `fill(rgb)` | 填充全部 370 个物理 LED。 |
| 397–403 | `fill_logical(rgb)` | 只填充虚拟矩阵内的真实 LED 点。 |
| 410–415 | `lerp(a, b, t)` | 标量线性插值。 |
| 421–430 | `blend(c1, c2, t)` | RGB 颜色插值。 |
| 438–447 | `dim(rgb, factor)` | 按比例压暗 RGB。 |
| 454–460 | `gamma_correct(rgb, gamma)` | 简单 Gamma 校正函数，当前主流程未强制使用。 |
| 467–481 | `radial_factor(x, y, cx, cy, radius)` | 计算中心到边缘的径向衰减，用于柔和动画。 |
| 492–518 | `draw_bitmap(bitmap, on_color, dim_color, off_color, do_show)` | 把 ASCII bitmap 渲染到矩阵，# 为亮、+ 为暗、其他为灭。 |
| 525–561 | `draw_bitmap_blend(bitmap_a, bitmap_b, t, on_color, dim_color, off_color, do_s...` | 在两个 ASCII bitmap 之间按 t 混合渲染。 |
| 573–590 | `draw_pixel_grid(grid, palette, do_show)` | 按 palette 渲染二维键值网格，是协议物理矩阵绘制的基础。 |
| 605–608 | `hardware_summary()` | 返回硬件布局字符串，用于启动日志。 |
| 611–617 | `src_to_led_index(row, col)` | 把原版 16×18 源坐标映射到居中的 370 板物理坐标。 |
| 620–628 | `_fastled_byte_scale(rgb, bright)` | 模拟 FastLED 亮度缩放：RGB × bright / 255。 |
| 631–644 | `draw_src_face_matrix(face, color, bright, write)` | 渲染原版 16×18 face 到 370 LED 板中心区域。 |
| 647–648 | `draw_face_matrix(face, color, bright, write)` | draw_src_face_matrix 的兼容别名。 |
| 651–659 | `fill_valid(rgb, bright, write)` | 以 FastLED 亮度规则填充所有真实逻辑点。 |

### `board_370.py`

较精简的 370 LED 板卡驱动备用实现；当前 main.py 使用 board.py，不直接使用本文件。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 19 | `LED_PIN` | WS2812 数据输出 GPIO。 |
| 20 | `NUM_LEDS` | 真实 LED 总数。 |
| 22 | `ROW_LENGTHS` | 每一行真实 LED 数，决定不规则矩阵几何。 |
| 30 | `ROWS` | 值：len(ROW_LENGTHS) |
| 31 | `COLS` | 值：22 |
| 32 | `SERPENTINE` | 值：True |
| 33 | `FLIP_X` | 值：False |
| 34 | `FLIP_Y` | 值：False |
| 39 | `SRC_ROWS` | 值：16 |
| 40 | `SRC_COLS` | 值：18 |
| 41 | `SRC_TO_DST_ROW_OFFSET` | 值：1 |
| 42 | `SRC_TO_DST_COL_OFFSET` | 值：2 |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 60–61 | `ticks_ms()` | 毫秒计时包装。 |
| 64–65 | `sleep_ms(ms)` | 毫秒休眠包装。 |
| 68–84 | `logical_to_led_index(x, y)` | 精简版 22×18 虚拟坐标到 LED 索引映射。 |
| 87–93 | `src_to_led_index(row, col)` | 精简版 16×18 源坐标映射。 |
| 96–105 | `_scale_uniform_to_cap(rgb, cap)` | 按 170 通道上限缩放颜色。 |
| 108–120 | `apply_brightness(rgb, bright)` | 按 FastLED bright 叠加 170 safety cap。 |
| 123–128 | `clear(write)` | 清空 LED。 |
| 131–132 | `show()` | 写入 LED。 |
| 135–149 | `draw_face_matrix(face, color, bright, write)` | 渲染 16×18 face 到 370 板。 |
| 152–157 | `fill_valid(rgb, bright, write)` | 填充真实点。 |
| 160–163 | `hardware_summary()` | 返回简短硬件字符串。 |

### `display_num.py`

数码/图标/滚动文字渲染器：间隔、亮度、电池百分比/电压/时间、A/M、大号字、IP/SSID 滚动显示。

- 该文件使用紧凑写法降低源码体积；外置注释在本 Markdown 中解释各函数职责。
- 电池图标内部 8 列填充；充电时根据 charging_phase_ms 生成扫动/闪烁。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 4 | `_FONT` | 值：{     "0": [".###.","#...#","#..##","#.#.#","##..#","#...#",".###."],     "1": [".##.."... |
| 20 | `_DOT` | 值：[".",".",".",".",".",".","#"] |
| 21 | `_PCT_3` | 值：["#.#","..#",".#.",".#.","#..","#.#","..."] |
| 22 | `GLYPH_H` | 值：7 |
| 23 | `DEFAULT_COLOR` | 值：(0,120,255) |
| 24 | `BRIGHTNESS_COLOR` | 值：(0,120,255) |
| 25 | `MODE_COLOR` | 值：(180,0,255) |
| 26 | `_BIG_A` | 值：["...####...","..######..",".##....##.",".##....##.",".##....##.",".##....##.",".######... |
| 27 | `_BIG_M` | 值：["##......##","###....###","####..####","##.####.##","##..##..##","##......##","##........ |
| 28 | `_BIG_W` | 值：len(_BIG_A[0]) |
| 28 | `_BIG_H` | 值：len(_BIG_A) |
| 29 | `CLOCK_ICON` | 值：["......................",".........####.........","........#...##........","........#.... |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 37–37 | `_blank_bitmap(h, w)` | 返回空白字形。 |
| 38–42 | `_glyph_for(ch)` | 根据字符找到 5×7 字形；支持点号和百分号特殊宽度。 |
| 44–55 | `_draw_bitmap_rows(rows, color, dim_color, x0, y0)` | 在指定位置绘制图标/bitmap 行。 |
| 57–76 | `_render_string(text, color, icon_rows, char_extra_x, icon_color)` | 居中渲染一串数字/字符，可选上方图标。 |
| 78–80 | `_format_interval(seconds)` | 把秒数转成 0.5S、1.0S、10S 这类短文本。 |
| 82–83 | `_sun_icon_rows(percent)` | 返回亮度图标帧；当前固定使用第一帧。 |
| 85–92 | `_battery_fill_cols(percent)` | 把电量百分比转换成电池图标内部填充列数。 |
| 94–140 | `_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval...` | 生成电池图标帧；充电时根据时间相位做柱状动画/闪烁。 |
| 142–142 | `render_interval(seconds, color)` | 显示自动换脸间隔，使用时钟图标和紫色 MODE_COLOR。 |
| 143–143 | `render_brightness_percent(percent, color)` | 显示亮度百分比，使用太阳图标和蓝色。 |
| 144–145 | `render_battery_percent(percent, color, charging, charging_phase_ms, charge_st...` | 显示电池百分比和电池图标。 |
| 146–146 | `render_percent(percent, color)` | 纯百分比显示。 |
| 147–147 | `render_ip_octet(octet, color)` | 显示单个 IP 八位组；旧逻辑保留。 |
| 148–156 | `_render_big_glyph(rows, w, h, color)` | 渲染大号 A/M 字形。 |
| 157–157 | `render_mode(auto, color)` | 显示 A 或 M，代表自动/手动。 |
| 158–167 | `render_battery_voltage(voltage, percent, color, charging, charging_phase_ms, ...` | 显示电池电压，格式 x.xV。 |
| 168–181 | `render_battery_time(hours_remaining, percent, color, charging, charging_phase...` | 显示剩余运行/充满时间，单位 M 或 H。 |
| 182–188 | `render_charge_voltage(voltage, percent, icon_color, charging, charging_phase_...` | 显示充电检测电压，文字固定白色，图标沿用电量颜色。 |
| 227–237 | `_scroll_columns(text)` | 把字符串转换成滚动列数据。 |
| 239–255 | `render_scrolling_text_window(text, offset, color)` | 在完整 22×18 真实矩阵中渲染滚动文字窗口。 |

### `battery_runtime.py`

电池续航/充电时间估算器：记录百分比变化速率，并按亮度/模式加权估算剩余时间。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 8 | `MODE_FACE` | 值：0 |
| 9 | `MODE_DEMO` | 值：1 |
| 10 | `MODE_BADAPPLE` | 值：2 |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 12–17 | `current_mode_code(app_state)` | 把 app_state 当前模式压缩成 FACE/DEMO/BADAPPLE 三类编号。 |
| 19–33 | `clamp_history_entry(entry)` | 校验并清洗一条历史速率样本。 |
| 35–45 | `sanitize_history(history)` | 清洗历史列表并保留最新 BATTERY_HISTORY_MAX_SAMPLES 条。 |
| 47–51 | `_history_distance(entry, brightness, mode)` | 计算历史样本与当前亮度/模式的距离，用于丢弃最不相关样本。 |
| 53–66 | `trim_history_for_current_context(history, app_state)` | 历史满时删除与当前使用场景最不相关的一条。 |
| 68–83 | `_record_sample(history, last_percent_attr, battery_state, app_state, percent_...` | 根据百分比变化和时间间隔记录放电/充电速率。 |
| 85–86 | `record_discharge_sample(battery_state, app_state, percent_float, dt_hours)` | 记录放电速度样本。 |
| 88–89 | `record_charge_sample(battery_state, app_state, percent_float, dt_hours)` | 记录充电速度样本。 |
| 91–109 | `_weighted_average_rate(entries, brightness, mode)` | 按新近程度、模式匹配和亮度接近度加权平均速度。 |
| 111–127 | `_estimate_from_history(history, app_state, percent_float, inverse)` | 用历史速度估算剩余运行或充满小时数。 |
| 129–132 | `estimate_remaining_hours(battery_state, app_state, percent_float)` | 估算剩余运行时间。 |
| 134–139 | `estimate_charge_hours(battery_state, app_state, percent_float)` | 估算充满时间。 |

### `battery_monitor.py`

电池采样和校准逻辑：ADC 电压读取、1 秒均值窗口、百分比曲线、充电检测、颜色映射。

- 电池百分比不是线性电压映射，而是按 BATTERY_PERCENT_CURVE 分段插值。
- 充电状态用充电检测 ADC 的滞回阈值判断，避免在边界电压附近闪烁。
- 均值采样器是非阻塞的；主循环每轮调用 service_mean_sampler()，每 1 秒结算平均值。

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 26–41 | `_make_adc(gpio)` | 创建 ADC 并设置 ESP32-S3 11 dB 衰减和 12-bit 宽度，扩大输入范围。 |
| 43–310 | `class BatteryMonitor` | 电池监控器，拥有电池 ADC、充电检测 ADC 和均值采样窗口。 |
| 52–64 | `BatteryMonitor.__init__(self)` | 初始化 ADC 和 1 秒均值采样状态。 |
| 65–72 | `BatteryMonitor._read_adc_voltage(self, adc, ref_v, samples)` | 对 ADC 读取多次平均，并换算成 ADC 引脚电压。 |
| 73–77 | `BatteryMonitor.read_voltage(self)` | 读取电池分压后的 ADC 电压，并反算到电池包电压。 |
| 78–79 | `BatteryMonitor.read_charge_voltage_adc(self)` | 读取充电检测 ADC 引脚电压。 |
| 80–84 | `BatteryMonitor.read_charge_voltage(self)` | 把充电检测分压反算成外部 VBUS/充电检测电压。 |
| 85–96 | `BatteryMonitor.reset_mean_sampler(self, preserve_last)` | 重置均值采样窗口，可选择保留上次完整均值。 |
| 98–109 | `BatteryMonitor._finalize_mean_window(self, now)` | 结束当前均值窗口，保存最后 1 秒平均值并开启新窗口。 |
| 111–134 | `BatteryMonitor.service_mean_sampler(self, force_sample)` | 非阻塞均值采样服务，每 20 ms 取样，每 1000 ms 结算。 |
| 136–144 | `BatteryMonitor.get_mean_voltage_pair(self, allow_partial)` | 返回电池/充电检测均值；允许当前窗口局部平均。 |
| 146–159 | `BatteryMonitor.read_voltage_mean(self, window_ms, sample_delay_ms)` | 阻塞式电池均值读取，主要用于兼容/诊断。 |
| 160–162 | `BatteryMonitor.read_charge_voltage_mean(self, window_ms, sample_delay_ms)` | 阻塞式充电检测均值读取。 |
| 164–188 | `BatteryMonitor.read_voltage_pair_mean(self, window_ms, sample_delay_ms)` | 阻塞式同时读取电池和充电检测均值。 |
| 190–200 | `BatteryMonitor.inward_adjust_calibration(battery_state)` | 长期未刷新极值时，把 min/max 向内收窄 0.05 V，避免百分比长期漂移。 |
| 202–228 | `BatteryMonitor.percent_float_from_voltage(v_bat, battery_state)` | 把电池电压映射到 0–100% 曲线，带端点容差。 |
| 229–279 | `BatteryMonitor.update_calibration(self, battery_state, app_state, save_cb, fo...` | 每 30 秒记录电池状态、历史速率、极值学习，并在变化时保存设置。 |
| 281–283 | `BatteryMonitor.percent_from_voltage(v_bat, battery_state)` | 返回四舍五入整数电量百分比。 |
| 285–295 | `BatteryMonitor.is_charging_voltage(charge_v, previous)` | 带滞回的充电检测：>4.0 V 为充电，<=3.0 V 为未充电，中间保持上一状态。 |
| 297–298 | `BatteryMonitor.charge_animation_step_interval_s(percent)` | 返回充电图标动画步进时间；当前固定 0.2 秒。 |
| 300–310 | `BatteryMonitor.color(percent)` | 把电量映射为红/橙/黄绿/绿渐变：10% 红、30% 橙、50% 转绿、50% 以上全绿。 |

### `emoji_db.py`

原版 RinaChanBoard 表情部件数据库：左右眼、嘴巴、脸颊 bitpack 数据和布局常量。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 4 | `EMPTY8` | 值：(0, 0, 0, 0, 0, 0, 0, 0) |
| 6 | `LEYE` | 值：(     (0, 0, 0, 0, 0, 0, 0, 0),  # 0     (0, 0, 0, 48, 48, 48, 48, 0),  # 1     (0, 0, ... |
| 37 | `REYE` | 值：(     (0, 0, 0, 0, 0, 0, 0, 0),  # 0     (0, 0, 0, 12, 12, 12, 12, 0),  # 1     (0, 0, ... |
| 68 | `MOUTH` | 值：(     (0, 0, 0, 0, 0, 0, 0, 0),  # 0     (0, 0, 0, 0, 126, 0, 0, 0),  # 1     (0, 0, 0,... |
| 104 | `CHEEK` | 值：(     (0, 0, 0, 0),  # 0     (0, 6, 0, 0),  # 1     (0, 5, 0, 0),  # 2     (5, 10, 0, 0... |
| 113 | `MAX_LEYE_COUNT` | 值：27 |
| 114 | `MAX_REYE_COUNT` | 值：27 |
| 115 | `MAX_MOUTH_COUNT` | 值：32 |
| 116 | `MAX_CHEEK_COUNT` | 值：5 |
| 117 | `L_EYE_START_ROW` | 值：0 |
| 118 | `L_EYE_START_COL` | 值：0 |
| 119 | `R_EYE_START_ROW` | 值：0 |

**数据表注释**：以 bit-packed tuple 保存原版表情部件，避免运行时从 JSON 解析。LEYE/REYE/MOUTH/CHEEK 与布局常量共同供 rina_protocol.update_lite_face 使用。

### `saved_faces_370.py`

370 物理矩阵表情库：默认表情、WebUI 保存/重命名/删除/排序/锁定，JSON 作为固件端真值。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 9 | `STORE_PATH` | 值："saved_faces_370.json" |
| 10 | `RENAME_PATH` | 值："saved_faces_370_names.json" |
| 11 | `MAX_FACES` | 值：99 |
| 12 | `DEFAULT_FACES` | 默认 370 LED 表情列表。 |
| 13 | `DEFAULT_HEXES` | 值：set([it.get("hex", "") for it in DEFAULT_FACES]) |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 17–27 | `_clean_hex(face_hex)` | 清洗 M370/hex 输入，强制为 93 位大写 hex，不足补 0。 |
| 29–39 | `_clean_name(name, fallback)` | 清洗显示名称，去掉换行/管道符，并移除旧版“默认 01”前缀。 |
| 41–46 | `_as_bool(v, default)` | 把字符串/布尔值转换成 locked 等布尔字段。 |
| 48–57 | `_type_of(item, is_default)` | 把 type/kind/source 字段归一化为 default/part/custom。 |
| 59–76 | `_load_name_overrides()` | 读取旧版重命名迁移文件，缓存默认表情名称覆盖。 |
| 78–79 | `_default_by_hex()` | 建立默认表情 hex 到 item 的映射。 |
| 81–84 | `_default_item(item)` | 把 DEFAULT_FACES 项变成完整带 locked/default/type 字段的条目。 |
| 86–106 | `_normalize_item(item, fallback_name)` | 标准化任意存储项，识别默认表情并保护 locked/type。 |
| 108–126 | `_renumber(items)` | 给列表按当前顺序生成 rowNumber、number、typeNumber。 |
| 128–149 | `_merge_defaults(items)` | 把默认表情和用户表情合并去重，保证默认项存在。 |
| 151–164 | `load(force)` | 读取 saved_faces_370.json 并缓存；失败时使用默认表情。 |
| 166–174 | `save(items)` | 标准化并保存完整表情列表。 |
| 176–184 | `save_json(json_text)` | 从 WebUI 上传的 JSON 字符串替换整个表情列表。 |
| 186–187 | `all_faces()` | 返回当前全部表情。 |
| 189–190 | `is_default_hex(face_hex)` | 判断一个 hex 是否为默认表情。 |
| 192–193 | `count()` | 返回表情数量。 |
| 195–203 | `get(index)` | 按索引返回表情，支持循环取模。 |
| 205–219 | `add_or_update(name, face_hex, kind, locked)` | 新增或更新一个 custom/part/default 表情。 |
| 221–232 | `rename_by_name(old_name, new_name)` | 按名称重命名第一个匹配表情。 |
| 234–249 | `delete_by_name(name)` | 按名称删除非默认且未锁定表情。 |
| 251–252 | `json_list()` | 以 JSON 文本返回当前列表。 |
| 255–268 | `_coerce_index(index, allow_end)` | 把传入索引限制到合法范围。 |
| 270–277 | `get_by_number(number)` | 按界面编号取表情。 |
| 279–299 | `update_by_index(index, name, typ, locked)` | 按索引更新名称、类型、锁定状态。 |
| 301–302 | `set_lock_by_index(index, locked)` | 更新锁定状态。 |
| 304–305 | `set_type_by_index(index, typ)` | 更新类型。 |
| 307–308 | `rename_by_index(index, new_name)` | 按索引重命名。 |
| 310–320 | `delete_by_index(index)` | 按索引删除非默认且未锁定表情。 |
| 322–340 | `move_index(from_index, to_index)` | 调整表情顺序。 |
| 342–343 | `replace_all(items)` | 替换全部列表并保存。 |

### `rina_protocol.py`

协议兼容层：支持原版二进制 UDP、微信小程序文本协议、M370 物理矩阵扩展、WebUI 管理命令。

- 同时支持二进制长度分发和文本命令分发；文本命令优先。
- M370: 后面的 93 位 hex 只编码真实 LED，不编码虚拟矩阵 padding。
- requestBattery 的二进制 0x1005 保持原版无回包；文本 requestBattery 返回 JSON 扩展状态。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 17 | `VERSION` | 协议/固件版本字符串。 |
| 19 | `LOCAL_UDP_PORT` | 本机 UDP 监听端口。 |
| 20 | `REMOTE_UDP_PORT` | 标准回包端口。 |
| 21 | `HTTP_PSEUDO_IP` | 值："127.0.0.1" |
| 22 | `HTTP_PSEUDO_PORT` | 值：0xF0F0 |
| 25 | `FACE_FULL_LEN` | 值：36 |
| 26 | `FACE_TEXT_LITE_LEN` | 值：16 |
| 27 | `FACE_LITE_LEN` | 值：4 |
| 28 | `COLOR_LEN` | 值：3 |
| 29 | `REQUEST_LEN` | 值：2 |
| 30 | `BRIGHT_LEN` | 值：1 |
| 31 | `TEXT_CENTER_ALIGN_OFFSET_ROWS` | 值：4 |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 58–59 | `_empty_face()` | 创建 16×18 legacy face 空矩阵。 |
| 73–74 | `_empty_physical()` | 创建 22×18 physical 空矩阵。 |
| 77–87 | `_legacy_to_physical(face)` | 把 legacy face 居中映射到 370 物理矩阵。 |
| 90–98 | `_is_hex_string(s, length)` | 校验 hex 字符串和可选长度。 |
| 101–102 | `_hex_to_bytes(s)` | hex 字符串转 bytes。 |
| 105–112 | `_json_escape(value)` | 最小 JSON 字符串转义。 |
| 115–130 | `_sleep_ms(ms)` | boot 动画兼容休眠包装。 |
| 133–734 | `class RinaProtocol` | 协议状态机，保存当前 face/physical/color/bright，并根据收到的数据更新 LED 或回包。 |
| 134–142 | `RinaProtocol.__init__(self, sender, log_provider, app)` | 初始化空 face、默认颜色 #f971d4、默认 brightness=16 和 app/network hooks。 |
| 147–157 | `RinaProtocol._reply_port(self, remote_ip, remote_port)` | 决定回包端口；普通 UDP 回 4321，HTTP 伪端点回内部等待端口。 |
| 159–160 | `RinaProtocol.reply(self, remote_ip, remote_port, data, link_id)` | 统一发送回包。 |
| 165–170 | `RinaProtocol._notify_external_control(self)` | 通知主应用网络/WebUI 接管显示，退出手动控制状态。 |
| 172–177 | `RinaProtocol._bright_color(self)` | 用 FastLED bright 值缩放当前颜色。 |
| 179–180 | `RinaProtocol._draw_physical_matrix(self, write)` | 绘制 22×18 physical bit matrix。 |
| 182–189 | `RinaProtocol.redraw(self, notify)` | 根据 display_mode 重绘 physical 或 legacy face。 |
| 191–192 | `RinaProtocol.set_sender(self, sender)` | 绑定网络发送函数。 |
| 194–199 | `RinaProtocol.show_hex_face(self, hex_string, delay_ms)` | 显示 72 位 legacy face hex，可选延时。 |
| 201–204 | `RinaProtocol.boot_animation(self)` | 兼容旧接口；当前 no-op。 |
| 207–208 | `RinaProtocol.decode_hex_string(hex_string)` | 72 位 face hex 转 16×18 矩阵。 |
| 211–223 | `RinaProtocol.decode_face_bytes(data, offset_rows)` | 原版 MSB-first、row-major 解码 face bytes。 |
| 225–240 | `RinaProtocol.encode_face_bytes(self)` | 把当前 legacy face 编码成 36 bytes，padding 列固定为 0。 |
| 242–243 | `RinaProtocol.encode_face_hex_text(self)` | 当前 legacy face 以 72 位 hex 返回。 |
| 245–256 | `RinaProtocol.encode_physical_hex_text(self)` | 当前 370 物理矩阵以 93 位 hex 返回。 |
| 258–278 | `RinaProtocol.update_physical_face_hex(self, hex_text, notify)` | 解析 M370 93 位 hex，更新 physical matrix 并重绘。 |
| 280–283 | `RinaProtocol.update_full_face(self, data, offset_rows)` | 处理 36-byte Face_Full。 |
| 285–286 | `RinaProtocol.update_text_lite(self, data)` | 处理 16-byte 文本居中 face。 |
| 289–290 | `RinaProtocol._bitpacked_get(rows, y, x, width)` | 从 bit-packed 部件数据中取某像素。 |
| 293–300 | `RinaProtocol._draw_part(face, bitmap, start_row, start_col, height, width, xf...` | 把眼睛/嘴/脸颊部件画入 face。 |
| 303–306 | `RinaProtocol._valid_lite_index(index, max_index)` | 校验部件索引；默认允许最高有效索引。 |
| 308–332 | `RinaProtocol.update_lite_face(self, leye, reye, mouth, cheek)` | 处理 4-byte Face_Lite，组合左右眼、嘴巴和脸颊。 |
| 334–341 | `RinaProtocol.update_color(self, data)` | 设置当前颜色，并触发 app 颜色同步。 |
| 343–350 | `RinaProtocol.update_brightness(self, bright)` | 设置协议 brightness，并同步到 app 百分比亮度。 |
| 352–367 | `RinaProtocol.set_physical_from_ascii_bitmap(self, bitmap)` | 从 ASCII bitmap 同步物理矩阵状态，便于 requestFace370 返回真实画面。 |
| 372–397 | `RinaProtocol.handle_packet(self, data, remote_ip, remote_port, link_id)` | 入口分发：先尝试文本协议，再按 payload 长度处理二进制协议。 |
| 399–424 | `RinaProtocol.handle_request(self, request, remote_ip, remote_port, link_id)` | 处理二进制 requestFace/requestColor/requestBright/requestVersion/requestBattery/requestEspLog。 |
| 426–428 | `RinaProtocol.send(self, remote_ip, remote_port, data, link_id)` | 通过外部 sender 发送数据。 |
| 433–734 | `RinaProtocol._handle_text_packet(self, data, remote_ip, remote_port, link_id)` | 处理 WebUI/微信小程序/调试文本命令，包括颜色、亮度、保存表情、M370、状态查询等。 |

### `esp32s3_network.py`

ESP32-S3 原生网络层：同时启用 AP/STA、UDP 服务、HTTP 控制台/API，替代旧 UART Wi-Fi 桥。

- HTTP 的 /api/request 和 /api/binary 使用 HTTP_PSEUDO_IP/PORT 伪端点把浏览器请求送进 RinaProtocol，再把协议回包转换成 HTTP 响应。
- AP 密码为空时会强制使用默认 WPA2 密码 rinachan，以避免手机拒绝开放热点。
- HTTP body 限制为 32 KB；Unity timeline 大数据通过多 chunk 发送。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 24 | `MAX_UDP_PAYLOAD` | 值：1472 |
| 25 | `MAX_HTTP_BODY` | HTTP 请求体最大字节数。 |
| 26 | `WEBUI_GZIP_FILE` | 值："webui_index.html.gz" |
| 27 | `HTTP_TIMEOUT_MS` | 值：1500 |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 30–31 | `_ticks_ms()` | 毫秒计时包装。 |
| 34–35 | `_ticks_diff(a, b)` | ticks 差值包装。 |
| 38–39 | `_ticks_add(a, b)` | ticks 加法包装。 |
| 42–46 | `_safe_str(v)` | 安全字符串转换。 |
| 49–79 | `_url_decode(s)` | 解析 URL 百分号编码和 + 空格。 |
| 82–94 | `_parse_query(qs)` | 解析 query string 或 form body。 |
| 97–101 | `_json_escape(s)` | JSON 文本转义。 |
| 104–117 | `_hex_to_bytes(hex_text)` | HTTP API hex 参数转 bytes，并限制 UDP 最大 payload。 |
| 120–125 | `_bytes_to_hex(data)` | bytes 转大写空格分隔 hex 字符串。 |
| 128–620 | `class ESP32S3Network` | 网络服务对象：持有 STA/AP/UDP/HTTP socket、日志、HTTP 等待回包状态。 |
| 136–155 | `ESP32S3Network.__init__(self, log_limit)` | 初始化网络状态、日志队列、计数器、HTTP pending 客户端。 |
| 157–162 | `ESP32S3Network._remember(self, prefix, text)` | 记录带时间戳的网络日志，并同步打印。 |
| 164–165 | `ESP32S3Network.recent_log(self)` | 返回最近 60 条日志。 |
| 167–168 | `ESP32S3Network.get_ip(self)` | 返回 STA IP；没有 STA 时返回 AP IP。 |
| 170–171 | `ESP32S3Network.get_ssid(self)` | 返回 STA SSID 或 AP 标签。 |
| 173–177 | `ESP32S3Network._cfg(self, name, default)` | 从 wifi_config.py 安全读取配置。 |
| 179–185 | `ESP32S3Network.start(self)` | 启动 Wi-Fi、UDP、HTTP，并打印状态。 |
| 193–273 | `ESP32S3Network._start_wifi(self)` | 开启 AP，尝试 STA 连接；无 AP 密码时强制默认 WPA2 密码 rinachan。 |
| 275–284 | `ESP32S3Network._start_udp(self)` | 创建非阻塞 UDP socket 监听 1234。 |
| 286–296 | `ESP32S3Network._start_http(self)` | 创建非阻塞 HTTP socket 监听 80。 |
| 298–300 | `ESP32S3Network._status_log(self)` | 打印当前网络状态和堆余量。 |
| 302–307 | `ESP32S3Network._free_heap(self)` | 读取 gc.mem_free()。 |
| 309–317 | `ESP32S3Network.poll(self)` | 服务 HTTP timeout、UDP 接收和一个 HTTP accept；每 30 秒打印状态。 |
| 319–323 | `ESP32S3Network.get_packet(self)` | poll 后弹出一个待处理协议包。 |
| 325–341 | `ESP32S3Network._poll_udp(self)` | 读取所有 UDP 包并排入 packets 队列。 |
| 343–364 | `ESP32S3Network._poll_http_once(self)` | 接受并处理一个 HTTP 客户端。 |
| 366–411 | `ESP32S3Network._read_http_request(self, client)` | 读取 HTTP 请求头/body，限制 body 32 KB。 |
| 413–484 | `ESP32S3Network._handle_http_client(self, client, addr)` | HTTP 路由：WebUI、status、send/request/binary、info/restart。 |
| 486–500 | `ESP32S3Network._queue_http_command(self, client, data, wait_reply, fmt)` | 把 HTTP 请求伪装成协议包送入主协议，并挂起浏览器连接等待回包。 |
| 502–516 | `ESP32S3Network._service_pending_timeout(self)` | HTTP 等待协议回包超时则返回 504。 |
| 518–540 | `ESP32S3Network._serve_webui(self, client)` | 分块发送 webui_index.html.gz，并声明 Content-Encoding:gzip。 |
| 542–549 | `ESP32S3Network._send_response(self, client, code, ctype, body)` | 发送基本 HTTP 响应。 |
| 551–554 | `ESP32S3Network.status_text(self)` | 生成文本状态行。 |
| 556–578 | `ESP32S3Network._api_status(self, client)` | 生成 /api/status JSON。 |
| 580–616 | `ESP32S3Network.send_udp(self, data, remote_ip, remote_port, link_id)` | 发送 UDP 回包；对 HTTP 伪端点则转换为浏览器 HTTP 响应。 |
| 618–620 | `ESP32S3Network.ping(self)` | 记录 native network alive 日志。 |

### `webui_runtime.py`

WebUI 动画运行时：把滚动文字和 Unity 时间轴播放从浏览器计时迁移到固件主循环。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 12 | `MAX_TIMELINE_FRAMES` | WebUI timeline 最大缓存帧数。 |
| 13 | `PHYSICAL_HEX_LEN` | 值：93 |
| 15 | `_HEX` | 值："0123456789abcdefABCDEF" |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 18–22 | `_ticks_ms()` | 毫秒计时包装。 |
| 25–29 | `_ticks_add(a, b)` | ticks 加法包装。 |
| 32–36 | `_ticks_diff(a, b)` | ticks 差值包装。 |
| 39–49 | `_clean_hex(value)` | 清洗 M370 hex 并裁剪/补齐到 93 位。 |
| 52–55 | `_clean_text(value, limit)` | 清洗滚动文字/时间轴名称，移除分隔符和控制字符。 |
| 58–62 | `_json_escape(value)` | JSON 文本转义。 |
| 65–377 | `class WebUIRuntime` | 固件侧 WebUI 动画运行时，管理 scroll 和 timeline 两种模式。 |
| 73–89 | `WebUIRuntime.__init__(self, app)` | 初始化滚动文字状态和 timeline 缓存状态。 |
| 91–92 | `WebUIRuntime.active(self)` | 判断运行时是否正在占用显示。 |
| 94–112 | `WebUIRuntime._prepare(self)` | 网络/WebUI 开始控制前清理主应用覆盖层、自动模式、组合键和手动模式。 |
| 114–127 | `WebUIRuntime.stop(self, redraw)` | 停止 scroll/timeline，必要时恢复当前保存表情。 |
| 132–149 | `WebUIRuntime.start_scroll(self, text, speed_ms)` | 启动固件侧滚动文字，速度限制 40–1000 ms/帧。 |
| 151–160 | `WebUIRuntime._render_scroll(self)` | 渲染当前滚动窗口，优先使用 app 当前颜色。 |
| 162–167 | `WebUIRuntime._service_scroll(self, now)` | 按 scroll_speed_ms 推进滚动 offset。 |
| 172–203 | `WebUIRuntime.begin_timeline(self, fps, last_frame, loop, expected, name)` | 初始化 M370 时间轴上传会话，限制 FPS 1–60。 |
| 205–228 | `WebUIRuntime.add_timeline_chunk(self, chunk)` | 解析 frame,HEX;frame,HEX chunk，最多缓存 800 帧。 |
| 230–241 | `WebUIRuntime.play_timeline(self)` | 开始按固件时钟播放 timeline。 |
| 243–254 | `WebUIRuntime.preview_timeline(self, frame)` | 预览某一帧，不进入播放。 |
| 256–269 | `WebUIRuntime._find_timeline_index(self, frame)` | 寻找当前时间应显示的最近 frame。 |
| 271–281 | `WebUIRuntime._draw_hex(self, hx)` | 通过协议对象把 93 位 hex 画到矩阵。 |
| 283–291 | `WebUIRuntime._render_timeline_frame(self, frame, force)` | 按 frame 选择并绘制对应 M370 帧。 |
| 293–306 | `WebUIRuntime._service_timeline(self, now)` | 根据 elapsed_ms 和 fps 推进播放，支持 loop。 |
| 308–315 | `WebUIRuntime.service(self)` | 主循环周期调用入口。 |
| 320–363 | `WebUIRuntime.handle_command(self, command)` | 解析 runtimeStatus/runtimeStop/scrollText370/timeline370* 等文本命令。 |
| 365–377 | `WebUIRuntime.status_json(self)` | 返回 runtime 当前状态 JSON。 |

### `main.py`

主应用入口和调度循环：连接状态、按键路由、显示覆盖层、电池服务、WebUI、协议、自动换脸。

- 本版本启动横幅标明 no MatrixDemo / no BadApple；matrix_demos.py 和 BadApple part 模块没有被主路径导入。
- 主循环是协作式轮询，没有线程；所有功能必须尽快返回，否则会影响按键、网络、电池动画刷新。
- network_poll 每轮最多处理 4 个 packet，避免网络请求长期占用主循环。

**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 62 | `FIRMWARE_BANNER` | 值："RinaChanBoard ESP32-S3 370LED native WebUI 1.6.0 no bridge no MatrixDemo no BadApple n... |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 69–1080 | `class LinaBoardApp` | 主控制对象，封装所有运行状态、按键、显示、电池、网络协议和 WebUI runtime。 |
| 72–81 | `LinaBoardApp.__init__(self)` | 创建 AppState、BatteryState、ButtonBank、BatteryMonitor、WebUIRuntime。 |
| 86–87 | `LinaBoardApp.save_settings(self)` | 保存运行设置和电池校准。 |
| 89–94 | `LinaBoardApp.apply_brightness(self)` | 把 state.brightness 应用到 board.py 物理亮度 cap。 |
| 96–102 | `LinaBoardApp._current_home_color(self)` | 读取协议当前颜色，失败时使用默认粉色。 |
| 104–110 | `LinaBoardApp._dimmed_home_color(self, color)` | 生成当前颜色的暗色版本。 |
| 112–131 | `LinaBoardApp.draw_current_face(self)` | 从 saved_faces_370 取当前表情并通过 RinaProtocol 绘制 M370 face。 |
| 133–134 | `LinaBoardApp.render_current_visual(self, force)` | 当前仅调用 draw_current_face，保留 force 参数兼容。 |
| 139–142 | `LinaBoardApp.start_edge_flash(self, edge)` | 启动顶部/底部边缘闪烁，用于亮度/间隔到达上下限提示。 |
| 144–150 | `LinaBoardApp.edge_flash_factor(self, elapsed_ms)` | 计算边缘闪烁攻击/衰减包络。 |
| 152–186 | `LinaBoardApp.overlay_edge_flash(self)` | 在当前覆盖层上叠加渐变边缘闪烁。 |
| 188–194 | `LinaBoardApp.render_flash_overlay_base(self)` | 根据 flash_kind 渲染 interval/brightness/mode 文本。 |
| 196–200 | `LinaBoardApp.render_flash_overlay_with_edge(self)` | 先重绘文字覆盖层，再叠加边缘闪。 |
| 202–206 | `LinaBoardApp.start_or_extend_flash(self, kind, value)` | 启动或延长 1 秒提示覆盖层。 |
| 208–217 | `LinaBoardApp.end_flash_if_expired(self)` | 提示到期后恢复当前表情。 |
| 219–223 | `LinaBoardApp.cancel_flash_and_redraw(self)` | 取消提示覆盖层并恢复表情。 |
| 225–232 | `LinaBoardApp.stop_battery_display(self)` | 关闭电池覆盖层并恢复表情。 |
| 234–235 | `LinaBoardApp.service_battery_sampling(self, force_sample)` | 把电池均值采样器接入主循环。 |
| 240–245 | `LinaBoardApp.is_charging(self, charge_v, previous)` | 使用 BatteryMonitor 的滞回判断是否充电。 |
| 247–262 | `LinaBoardApp.show_battery_percent_short(self)` | 短按 B6 时显示 2 秒电池百分比。 |
| 264–339 | `LinaBoardApp.refresh_battery_overlay_cache(self, force)` | 刷新电池/充电检测均值、百分比、剩余时间、充电状态缓存。 |
| 341–354 | `LinaBoardApp.update_battery_display_phase(self)` | 长按电池页面时在 percent/voltage/time/charge_v 间轮换。 |
| 356–421 | `LinaBoardApp.service_battery_overlay(self)` | 电池覆盖层服务：处理到期、相位、动画刷新、充电状态快速变化。 |
| 423–508 | `LinaBoardApp.render_battery_overlay(self, refresh_phase, refresh_cache, log_s...` | 按当前 phase 渲染电池百分比、电压、剩余/充满时间或充电检测电压。 |
| 510–513 | `LinaBoardApp.start_b6_press(self)` | 记录 B6 按下时间，等待短按/长按判定。 |
| 515–541 | `LinaBoardApp.check_b6_hold(self)` | B6 单独长按 700 ms 进入循环电池显示。 |
| 543–563 | `LinaBoardApp.check_b6_release(self, prev_b6_down)` | B6 松开时处理短按显示/关闭电池显示，并过滤组合键。 |
| 570–597 | `LinaBoardApp.start_ip_display(self)` | B2+B6 触发 IP/SSID 滚动显示。 |
| 599–611 | `LinaBoardApp.service_ip_display(self)` | 按 120 ms 步进滚动 IP/SSID，结束后恢复表情。 |
| 613–624 | `LinaBoardApp.check_ip_combo(self)` | 检测 B2+B6 组合并启动 IP/SSID 显示。 |
| 629–632 | `LinaBoardApp.apply_demo_runtime_settings(self, refresh_timer)` | 演示模式已禁用，保留 no-op 兼容。 |
| 634–640 | `LinaBoardApp.stop_special_demo_mode(self, redraw_face)` | 退出演示模式并恢复亮度/表情；当前演示模式不会真正启动。 |
| 642–645 | `LinaBoardApp.start_special_demo_mode(self)` | 演示模式已禁用，强制 state.special_demo_mode=False。 |
| 647–649 | `LinaBoardApp.toggle_special_demo_mode(self)` | B3+B6 被消费但不进入演示模式。 |
| 651–667 | `LinaBoardApp.check_special_demo_combo(self)` | 检测 B3+B6，阻止其误触发 B3/B6 单独行为。 |
| 669–673 | `LinaBoardApp.check_badapple_combo(self)` | BadApple 被排除，组合键逻辑 no-op。 |
| 678–683 | `LinaBoardApp.cycle_face(self, delta)` | B1/B2 切换保存表情，停止 WebUI runtime 和覆盖层。 |
| 685–701 | `LinaBoardApp.adjust_interval(self, delta)` | B3+B1/B2 调整自动换脸间隔，保存设置并显示紫色间隔覆盖层。 |
| 704–710 | `LinaBoardApp.sync_protocol_brightness_from_buttons(self)` | 实体按键改亮度后，同步协议 bright 状态。 |
| 712–726 | `LinaBoardApp.adjust_brightness(self, delta)` | B4/B5 调整亮度百分比，保存设置，显示亮度覆盖层。 |
| 728–737 | `LinaBoardApp.reset_brightness(self)` | B4+B5 重置亮度为默认 30%。 |
| 739–758 | `LinaBoardApp.set_manual_control_mode(self, enabled, redraw, source)` | 进入/退出手动控制模式；进入时清除 WebUI runtime、自动和覆盖层。 |
| 760–764 | `LinaBoardApp.enter_manual_control_from_button(self, gp)` | 任意实体按键把控制权切回本地手动。 |
| 766–770 | `LinaBoardApp.exit_manual_control_from_network(self, source)` | 网络/WebUI 控制时退出手动模式。 |
| 772–773 | `LinaBoardApp.manual_control_status_json(self)` | 返回手动模式状态 JSON。 |
| 775–784 | `LinaBoardApp.toggle_auto(self)` | B3 松开时切换自动换脸 A/M。 |
| 789–828 | `LinaBoardApp.handle_press(self, gp)` | 实体按键事件总路由，处理组合键、换脸、间隔、亮度、B6。 |
| 830–839 | `LinaBoardApp.check_b3_release(self, prev_b3_down)` | B3 松开时若未被组合键消费，则切换自动模式。 |
| 844–845 | `LinaBoardApp.handle_webui_runtime_command(self, command)` | 把 WebUI runtime 文本命令转交 WebUIRuntime。 |
| 847–861 | `LinaBoardApp.select_saved_face(self, index, redraw)` | WebUI 选择某个保存表情，更新索引并可重绘。 |
| 863–874 | `LinaBoardApp.on_saved_faces_changed(self, selected_index, redraw)` | 保存表情列表改变后修正当前索引并可重绘。 |
| 876–881 | `LinaBoardApp.stop_webui_runtime(self, redraw)` | 停止固件侧 WebUI 动画。 |
| 886–906 | `LinaBoardApp.attach_network(self, link, proto)` | 绑定网络和协议对象，构建最多每轮处理 4 个 packet 的 network_poll。 |
| 908–910 | `LinaBoardApp.service_network(self)` | 主循环调用网络服务。 |
| 912–924 | `LinaBoardApp.on_network_control(self)` | 协议/WebUI 控制接管时清理本地状态。 |
| 926–933 | `LinaBoardApp.on_protocol_color_updated(self, color)` | Web/协议改颜色后，让 button face 使用新颜色重绘。 |
| 935–950 | `LinaBoardApp.on_protocol_brightness_updated(self, bright)` | 协议 raw bright 映射回 UI 亮度百分比并保存。 |
| 952–980 | `LinaBoardApp.battery_status_json(self)` | 生成 WebUI 用电池状态 JSON。 |
| 985–1001 | `LinaBoardApp.print_startup_info(self)` | 打印版本、GPIO、ADC、模式等启动信息。 |
| 1003–1018 | `LinaBoardApp.initialize(self)` | 加载设置、应用亮度、画当前表情、启动首次电池采样。 |
| 1020–1080 | `LinaBoardApp.run(self)` | 无限主循环：网络、组合键、按键、电池、IP/WebUI、覆盖层、校准、自动换脸。 |
| 1087–1098 | `main()` | 固件入口：创建 LinaBoardApp、ESP32S3Network、RinaProtocol，绑定 sender 并进入 app.run()。 |

### `demo_faces.py`

旧版内置 ASCII 表情帧；当前 no-demo 构建不在主启动路径导入，用于保留/迁移参考。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 19 | `PINK` | 值：(66, 0, 36) |
| 20 | `DIM` | 值：(24, 0, 14) |
| 26 | `FRAMES` | 值：[     # -----------------------------------------------------------------------     # 0... |
| 298 | `DEFAULT_FACE_INDEX` | 值：7 |

**数据表注释**：保存旧版 demo ASCII 表情帧 FRAMES，每帧使用 22×18 字符串。当前主启动路径不用它，避免占用堆。

### `matrix_demos.py`

旧版矩阵演示动画控制器；当前 main.py 中演示模式被禁用，不在主启动路径导入。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 29 | `DEFAULT_DEMO_INTERVAL_MS` | 值：5000 |
| 30 | `FPS` | 值：30 |
| 31 | `FRAME_MS` | 值：1000 // FPS |
| 33 | `_ALL_COORDS` | 值：[] |
| 34 | `_ALL_COLUMNS` | 值：[] |
| 51 | `DEMO_NAMES` | 值：(     "rgb",     "fire",     "hacker",     "hello_world", ) |
| 58 | `_FONT` | 值：{     "A": [         ".###.",         "#...#",         "#...#",         "#####",       ... |
| 142 | `_TEXT` | 值：" HELLO WORLD " |
| 143 | `_TEXT_H` | 值：7 |
| 169 | `_TEXT_COLS` | 值：_build_text_columns(_TEXT) |
| 170 | `_TEXT_WIDTH` | 值：len(_TEXT_COLS) |
| 472 | `DEMOS` | 值：DemoController() |

**符号/函数注释**

| 行号 | 符号 | 外置注释 |
|---:|---|---|
| 146–147 | `_clear_all()` | 清空真实 LED 点。 |
| 150–151 | `_glyph_rows(ch)` | 返回滚动文本用字形。 |
| 154–166 | `_build_text_columns(text)` | 构建 HELLO WORLD 滚动列。 |
| 173–469 | `class DemoController` | 旧版演示动画控制器，支持 rgb/fire/hacker/hello_world；当前主构建禁用。 |
| 191–206 | `DemoController.__init__(self)` | 初始化演示模式状态。 |
| 208–221 | `DemoController._reset_demo_state(self)` | 为当前 demo 重置动画内部状态。 |
| 223–231 | `DemoController.enter(self)` | 进入演示模式。 |
| 233–236 | `DemoController.exit(self)` | 退出演示模式并清屏。 |
| 238–243 | `DemoController.toggle(self)` | 切换演示模式开关。 |
| 245–246 | `DemoController.demo_name(self)` | 返回当前 demo 名称。 |
| 248–251 | `DemoController.set_interval_ms(self, interval_ms)` | 设置自动切换 demo 间隔。 |
| 253–254 | `DemoController.set_auto(self, enabled)` | 设置是否自动切换 demo。 |
| 256–259 | `DemoController.next_demo(self, now_ms)` | 切到下一个 demo。 |
| 261–270 | `DemoController.prev_demo(self, now_ms)` | 切到上一个 demo。 |
| 272–275 | `DemoController.refresh_timer(self, now_ms)` | 刷新 demo 自动切换计时。 |
| 277–284 | `DemoController._advance_demo(self, now_ms)` | 推进到指定 demo 并重置状态。 |
| 286–287 | `DemoController.force_render(self, now_ms)` | 强制下一帧刷新。 |
| 289–321 | `DemoController.render(self, now_ms, force)` | 按当前 demo 分发到 rgb/fire/hacker/hello_world 渲染。 |
| 323–332 | `DemoController._rgb(self, t)` | RGB 彩虹/流动效果。 |
| 334–343 | `DemoController._fire_color(self, heat)` | 火焰强度到 RGB 的映射。 |
| 345–380 | `DemoController._fire(self, dt)` | 火焰动画。 |
| 382–424 | `DemoController._hacker(self, now_ms)` | 绿色字符雨/扫描效果。 |
| 426–469 | `DemoController._hello_world(self, now_ms)` | HELLO WORLD 全屏滚动。 |

### `wifi_config.py`

Wi-Fi/AP 配置文件：STA SSID/密码、AP SSID/密码、HTTP/UDP 端口。


**关键常量/全局数据**

| 行号 | 名称 | 注释/值 |
|---:|---|---|
| 5 | `WIFI_SSID` | 路由器 STA SSID，空字符串表示不连接路由器。 |
| 6 | `WIFI_PASSWORD` | 值："" |
| 8 | `AP_SSID` | 设备热点名称。 |
| 9 | `AP_PASSWORD` | 值："" |
| 10 | `AP_CHANNEL` | 值：6 |
| 11 | `AP_AUTHMODE` | 值：0 |
| 13 | `HTTP_PORT` | 值：80 |
| 14 | `UDP_PORT` | 值：1234 |
| 15 | `REMOTE_UDP_PORT` | 标准回包端口。 |

### `webui_index.html.gz`

压缩的内置 Web 控制台：HTML/CSS/JS 合并后 gzip，由 HTTP 根路径直接返回。

- 这是已压缩网页，不建议在设备上直接编辑；应在开发端改源 HTML/JS 后重新 gzip。
- 浏览器页面通过 /api/send、/api/request、/api/binary 与固件协议层交互。

**文件级注释**：内置网页控制台的 gzip 压缩产物。HTTP 服务器原样发送，浏览器解压后提供首页、表情编辑、部件选择、Unity 时间轴、滚动文字、二进制协议、Wi-Fi 配网和日志页面。

### `__pycache__/`

CPython 运行缓存，不属于 MicroPython 固件逻辑；烧录到 ESP32-S3 时通常不需要。

- 这些 .pyc 是 PC 端 CPython 缓存，不是 MicroPython 必需文件。上传固件时建议排除。

## 7.1 本次 M/A 修复说明

### 修改目标

当 B3 切换到 A 自动换脸后，只要网页控制端发送实际控制命令，固件必须立即退出自动换脸，回到 M 模式，避免网页刚发送的画面被自动轮播覆盖。

### 修改点

| 文件 | 修改内容 |
|---|---|
| `main.py` | 新增 `force_m_mode(source, persist=True)`；`on_network_control()`、`select_saved_face()` 和实体手动控制入口统一调用它。 |
| `webui_runtime.py` / `rina_protocol.py` | `scrollText370`、Unity/M370 时间轴 begin/chunk/play/preview/stop/clear 等固件侧运行时控制进入前调用 `force_m_mode()`；`runtimeStatus` 只读取状态，不改变 M/A。 |
| `rina_protocol.py` | WebUI 的 `manualMode|0` / 退出手动控制锁也视作网页控制动作，会调用 `on_network_control()`，保证 A/M 回 M。版本号更新为 `1.6.1-esp32s3-native-mafix`。 |
| `esp32s3_network.py` | `/api/status` 中 `firmware` 字段同步更新为 `1.6.1-esp32s3-native-mafix`。 |

### 行为结果

- 网页发送表情、M370 画面、颜色、亮度、保存表情选择、滚动文字、Unity 时间轴控制后，`app_state.auto=False`。
- 如果之前处于 A 模式，固件会保存设置，因此重启后也保持 M 模式。
- 不额外显示大号 `M` 覆盖层，避免覆盖网页控制端刚画出的内容。
- 单纯读取状态的命令，例如 `requestState`、`requestBattery`、`requestColor`、`/api/status`，不改变 M/A。

## 8. 协议命令外置注释

### 8.1 二进制 UDP 协议

| Payload 长度/请求 | 处理函数 | 行为 |
|---|---|---|
| 36 bytes | `RinaProtocol.update_full_face()` | 原版 16×18 full face，MSB-first、row-major。 |
| 16 bytes | `RinaProtocol.update_text_lite()` | 文本区域/居中 face。 |
| 4 bytes | `RinaProtocol.update_lite_face()` | 左眼、右眼、嘴、脸颊四个部件索引。 |
| 3 bytes | `RinaProtocol.update_color()` | RGB 颜色更新。 |
| 1 byte | `RinaProtocol.update_brightness()` | 原版 FastLED bright 0–255。 |
| 0x1001 | `handle_request()` | requestFace，返回 36 bytes。 |
| 0x1002 | `handle_request()` | requestColor，返回 RGB 三字节。 |
| 0x1003 | `handle_request()` | requestBright，返回 1 byte。 |
| 0x1004 | `handle_request()` | requestVersion，返回版本字符串。 |
| 0x1005 | `handle_request()` | 保持原版 TODO 行为，不回包；文本 `requestBattery` 才返回 JSON。 |

### 8.2 文本/WebUI 扩展命令

| 命令格式 | 行为 |
|---|---|
| `#rrggbb` 或 `rrggbb` | 更新颜色。 |
| `B000`–`B255` | 更新原版协议亮度。 |
| `requestFace` / `requestFace370` | 返回 legacy face hex 或 `M370:` 物理矩阵 hex。 |
| `M370:<93 hex>` | 直接更新 370 真实矩阵，只编码真实 LED。 |
| `requestSavedFaces370` | 返回固件端保存的表情列表 JSON。 |
| `saveFace370|...`、`saveFaces370Json|...` | 保存单个表情或同步完整表情列表。 |
| `deleteFace370Index|...`、`moveFace370|...`、`renameFace370Index|...` | 表情管理命令。 |
| `requestBattery` | 返回电池/充电 JSON。 |
| `requestState` | 返回版本、颜色、亮度、控制模式、face、battery 的综合 JSON。 |
| `scrollText370|speed|text` | 启动固件侧滚动文字。 |
| `timeline370Begin|fps|last|loop|count|name` | 初始化 Unity/M370 时间轴。 |
| `timeline370Chunk|frame,HEX;...` | 上传时间轴帧 chunk。 |
| `timeline370Play` / `timeline370Preview|frame` / `timeline370Stop` | 播放、预览、停止时间轴。 |

## 9. 内存与烧录备注

- `__pycache__/` 中的 `.pyc` 文件来自 PC 端 CPython，不需要上传到 MicroPython 设备。
- 当前 `main.py` 通过延迟/避免导入大型 demo 和 BadApple 模块来降低启动内存压力。
- `webui_index.html.gz` 约 75 KB，属于静态资源；HTTP 分块发送，每次读 1024 bytes。
- 如果再次出现 `MemoryError`，优先检查设备上是否存在旧的 BadApple part 文件、`__pycache__`、未使用的大型 `.py`/`.json` 文件。
- 建议上传固件时只放必要源码、`webui_index.html.gz`、配置文件和持久化 JSON，不上传 PC 缓存。

## 10. 快速定位索引

| 想改的功能 | 主要文件 |
|---|---|
| LED 矩阵坐标/亮度上限 | `board.py`, `brightness_modes.py`, `config.py` |
| 按键 GPIO/消抖/重复速度 | `buttons.py`, `config.py`, `main.py` |
| B1/B2/B3/B4/B5/B6 行为 | `main.py` 的 `handle_press()`、`check_b3_release()`、`check_b6_hold()`、`check_b6_release()` |
| 电池百分比曲线 | `config.py` 的 `BATTERY_PERCENT_CURVE`, `battery_monitor.py` |
| 充电检测阈值 | `config.py` 的 `CHARGE_DETECT_*`, `battery_monitor.py` |
| WebUI HTTP/API | `esp32s3_network.py`, `webui_index.html.gz` |
| UDP/文本协议 | `rina_protocol.py` |
| 保存表情管理 | `saved_faces_370.py`, `rina_protocol.py` |
| 滚动文字/Unity 时间轴 | `webui_runtime.py`, `display_num.py`, `rina_protocol.py` |
| 自动换脸 | `main.py`, `settings_store.py`, `saved_faces_370.py` |

---

本文件是外置注释，不是运行时依赖。可以随固件一起保存，上传到设备也不会影响主程序，除非设备存储空间紧张。
---

## 11. 2026-04-26 WebUI 无响应、静态文件日志、TXS0108E 一帧闪烁修复说明

### 11.1 WebUI 无反应的直接原因

本次检查发现 `webui_index.html.gz` 内嵌 JavaScript 有一处字符串引号错误：Wi-Fi 扫描列表行的 `onmouseover="this.style.background='#1e2535'"` 被放在单引号 JS 字符串中，导致浏览器解析脚本时直接 SyntaxError，后续所有 WebUI 初始化函数都不会运行。

已修复为 HTML attribute 内使用 `&quot;` 转义，并重新压缩 `webui_index.html.gz`。修复后已用 PC 端 `node --check` 对解压出来的内嵌 JS 做语法检查。

### 11.2 WebUI/HTTP 诊断日志

`esp32s3_network.py` 增加了以下串口日志，方便定位“页面加载一半卡住”或“无反应”：

| 日志类型 | 触发位置 | 示例 |
|---|---|---|
| GET 路径日志 | 每次 HTTP GET 请求进入时 | `>>> [HTTP GET] 请求路径: /webui/rina_webui_stable_1_5_1.js` |
| 静态文件成功日志 | 文件打开成功后 | `>>> [File] 成功打开文件: webui_index.html.gz` |
| 404 文件日志 | 文件不存在或读取失败 | `!!! [404 Error] 文件不存在或读取失败: ...` |
| 发送前内存 | 静态文件分块发送前 | `>>> [Memory] 发送 webui_index.html.gz 前剩余内存: ... bytes` |
| 发送后内存 | 静态文件发送结束/断开后 | `>>> [Memory] 发送完成，剩余内存: ... bytes` |
| Socket 异常 | `socket.send()` 出错 | `!!! [Socket Error] 发送数据给客户端时断开，错误码: ...` |
| API 指令日志 | `/api/request`、`/api/send`、二进制 API、runtime 命令 | `>>> [API Command] 收到前端指令: ...` |
| API 解析/崩溃日志 | POST 解析、binary hex、Wi-Fi scan/save、runtime command 异常 | `!!! [API Parse] ...` / `!!! [API Crash] ...` |

静态资源发送仍然使用 1024-byte 分块读取，不把 `.gz` 大文件一次性读入 RAM。

### 11.3 静态文件与 Wi-Fi API 兼容

`esp32s3_network.py` 增加了静态路径 fallback：

- `/`、`/fwlink`、`/wifi`、`/0wifi` 仍返回 `webui_index.html.gz`。
- 未知的 `GET` / `HEAD` 路径会尝试按静态文件路径打开。
- `/webui/...` 前缀会映射到设备根目录下对应文件。
- 找不到文件时会打印 404 文件日志，而不是静默失败。

同时补齐 WebUI 需要的 Wi-Fi 配置接口：

| 接口 | 行为 |
|---|---|
| `/api/wifi/status` | 返回 STA/AP 状态、IP、SSID、RSSI、是否允许配置。 |
| `/api/wifi/scan` | 扫描附近 Wi-Fi，返回 SSID/RSSI/channel/auth。 |
| `/api/wifi/save` | 保存 `wifi_config.py`，返回 JSON 后重启。 |

### 11.4 去除电池串口日志

已去除/静默以下电池相关串口输出，避免干扰 WebUI/HTTP 调试：

- 周期性 `battery log: ...`
- 电池显示 overlay 的 `battery display: ...`
- `battery monitor unavailable`
- 启动阶段 battery ADC、learned min/max、mean update、charge detect ADC 等配置日志
- 电池校准版本变化的 settings 读取日志

电池功能本身没有移除；只是关闭串口打印。

### 11.5 TXS0108E 导致 LED 一帧闪烁的判断

当前固件保留 `board.py` 里的启动黑帧：初始化 NeoPixel/RMT 后立即写入全黑一帧，用来清掉 GPIO/RMT 初始化时经过 TXS0108E 可能产生的瞬态毛刺。

硬件层面，TXS0108E 是自动方向、one-shot 边沿加速型电平转换器，不是专为 WS2812/NeoPixel 这种严格时序单线 LED 数据链路设计的强推挽 buffer。LED DIN、线缆、电平转换器输出电容/负载、上电时 OE/IO 浮空、以及 ESP32-S3 RMT/GPIO 初始化瞬间的窄脉冲，都可能被第一颗 LED 锁存成一帧随机数据。

固件缓解：

- 保留启动后立即发送全黑 reset frame。
- 不在 AP_IF 上调用可能引发 ESP32-S3 Wi-Fi hard-crash 的 power-save `config(pm=...)`。

硬件建议：

- 最稳方案：用单向 3.3V→5V buffer，例如 74AHCT/74HCT 系列，而不是 TXS0108E。
- 如果继续使用 TXS0108E：确保 OE 在 ESP32-S3 GPIO/RMT 初始化完成前保持关闭；数据线尽量短；LED DIN 旁加入约 100–330 Ω 串联电阻；LED 电源端加足够 bulk capacitor；ESP32 和 LED 电源必须共地。

---

## 12. 2026-04-26 颜色与 Unity Assets 按需加载修复说明

### 12.1 资源补齐范围

本次补齐的是 WebUI 需要的颜色 preset 与 Unity/上位机帧序列数据库，不导入任何音频、视频或封面媒体文件。

新增设备端静态资源目录：

| 文件 | 内容 | 运行时用途 |
|---|---|---|
| `assets/color_info.json.gz` | 颜色 preset 列表，共 53 项 | 主页颜色下拉菜单，页面启动时按需加载 |
| `assets/unity_core.json.gz` | `AsciiDb` 与 `FaceModuleDb` | 滚动文字、Unity 帧 ID → 370 LED 矩阵转换 |
| `assets/unity_voice_timeline.json.gz` | VoiceTimeLineDb 帧序列，共 143 项 | Unity 语音类表情帧序列 |
| `assets/unity_music_timeline.json.gz` | MusicTimeLineDb 帧序列，共 8 项 | Unity 歌曲类帧序列 |
| `assets/unity_video_timeline.json.gz` | VideoTimeLineDb 帧序列，共 7 项 | Unity 影像类帧序列 |

`window.RINA_UNITY_DB` 现在只在 HTML 内保留索引数据：`voiceDb` / `musicDb` / `videoDb`。大型 `AsciiDb`、`FaceModuleDb` 和时间轴帧数据全部移出到 `assets/*.json.gz`。

### 12.2 按需加载 / 卸载策略

`webui_index.html.gz` 新增 `RINA_ASSETS`：

| 函数 | 行为 |
|---|---|
| `RINA_ASSETS.ensureColor()` | 加载 `assets/color_info.json.gz`，失败时保留内置默认粉色。 |
| `RINA_ASSETS.ensureUnity('core')` | 只加载 `AsciiDb` + `FaceModuleDb`。 |
| `RINA_ASSETS.ensureUnity('voice')` | 加载 core + voice 时间轴。 |
| `RINA_ASSETS.ensureUnity('music')` | 加载 core + music 时间轴。 |
| `RINA_ASSETS.ensureUnity('video')` | 加载 core + video 时间轴。 |
| `RINA_ASSETS.unloadUnity()` | 删除浏览器内 Unity/ASCII 帧序列缓存，释放内存。 |

WebUI 行为：

- 打开“滚动文字”页时加载 `unity_core.json.gz`。
- 打开“语音/歌曲/影像时间轴”页时，只加载当前类型需要的时间轴。
- 切换 voice/music/video 时卸载前一个类型的时间轴，只保留 core。
- 点击停止、播放结束、或离开 media/scroll 页面时卸载 Unity/ASCII 缓存。
- `mediaSource()` 已改为始终返回空字符串，所以不会加载用户选择的音频/视频文件，也不会把媒体文件打包到固件里；播放逻辑使用静默帧计数同步。

### 12.3 HTTP 静态资源支持

`esp32s3_network.py` 之前已经支持未知 `GET` / `HEAD` 路径按静态文件打开，并且 `.json.gz` 会返回：

- `Content-Type: application/json; charset=utf-8`
- `Content-Encoding: gzip`
- `Cache-Control: no-store`

因此 `/assets/color_info.json.gz` 与 `/assets/unity_*.json.gz` 可以直接由浏览器 `fetch()` 读取。串口会打印：

```text
>>> [HTTP GET] 请求路径: /assets/unity_core.json.gz
>>> [File] 成功打开文件: assets/unity_core.json.gz
```

如果上传脚本没有递归上传 `assets/`，WebUI 会在串口看到 `404 Error`。本版本已同步修改上传脚本。

### 12.4 上传脚本变化

`upload_esp32s3_firmware.ps1` 改为递归上传 `esp32s3_firmware/` 下的运行文件，因此会上传：

- 根目录 `.py` / `webui_index.html.gz`
- `assets/*.json.gz`

仍然不会上传：

- `upload_esp32s3_firmware.ps1`
- `EXTERNAL_CODE_COMMENTS.md`

默认 ZIP 名称更新为：

```powershell
.\esp32s3_firmware_mobile_layout.zip
```

### 12.5 本次资源统计

| 资源 | 数量 |
|---|---:|
| 颜色 preset | 53 |
| ASCII 字符 | 95 |
| Face module | 93 |
| Voice 条目 / 时间轴 | 143 / 143 |
| Music 条目 / 时间轴 | 8 / 8 |
| Video 条目 / 时间轴 | 7 / 7 |

压缩后 WebUI 主文件从原先的大型内嵌 Unity DB 改为约 59 KB 的 `webui_index.html.gz`；Unity 帧序列资源被拆成多个小型 `.json.gz`，只在需要时加载。

---

## 13. v1.6.4 手机端布局修复

本次只修改 WebUI 布局与注释，不改 ESP32-S3 网络、UDP、LED、按钮或资源按需加载逻辑。

### 13.1 修改文件

| 文件 | 修改 |
|---|---|
| `webui_index.html.gz` | 解包后修改 HTML/CSS，再重新 gzip 压缩。 |
| `EXTERNAL_CODE_COMMENTS.md` | 添加本节说明。 |

### 13.2 移动端 CSS 规则

在页面主 `<style>` 内添加 `MOBILE_LAYOUT_FIX_1_6_4`，核心规则：

- `html, body { overflow-x:hidden; max-width:100vw; }`，防止手机端出现横向滚动条。
- `@media (max-width:600px)` 下强制 `.grid2` 变成单列：`grid-template-columns:1fr!important`。
- 手机端 `.row` 改成纵向排列并拉伸内部控件，密集按钮群不再横向挤压。
- 手机端 `input/select/textarea` 使用 `min-width:0!important; width:100%!important; max-width:100%!important`，覆盖固定宽度与行内宽度导致的溢出。
- 手机端 `.saveList`、`.wideSelect` 同样强制 `min-width:0` 与 `width:100%`。

### 13.3 行内 `min-width` 修复

以下行内样式已从固定最小宽度改成可收缩宽度：

| 元素 | 原样式 | 新样式 |
|---|---|---|
| `#scrollText` | `min-width:320px` | `min-width:0; width:100%` |
| `#unityMediaSelect.wideSelect` | `min-width:320px` | `min-width:0; width:100%` |
| `#unityMediaUrl` | `min-width:300px` | `min-width:0; width:100%` |

同样修改了 `buildMediaTab()` 动态重建 Unity 媒体页面时使用的字符串模板，避免切换页面后固定宽度样式重新出现。

### 13.4 LED 矩阵缩放

手机端 `#grid` 与 `.miniGrid370` 都使用 22 列自适应 cell：

```css
--mobile-matrix-cell: max(7px, calc((100vw - 112px) / 22));
```

这里使用 `112px` 而不是更小余量，是为了同时扣除页面 padding、卡片 padding、矩阵自身 padding 与 21 个列间 gap，确保 320px 级别手机屏幕也不会溢出。

### 13.5 动态样式补丁

`ensureStableCss()` 会在页面加载后再插入一段带 `!important` 的 `.miniGrid370` 固定 12px 样式。为避免它覆盖主 `<style>` 中的手机端修复，本次在 `ensureStableCss()` 注入的动态 CSS 中同步加入 `MOBILE_LAYOUT_FIX_1_6_4_DYNAMIC` 媒体查询。

这保证以下场景均保持手机适配：

- 自定义 370 LED 编辑器。
- 表情部件完整预览。
- Unity voice/music/video 时间轴预览。
- Unity 媒体页面被 JS 动态重建后。

### 13.6 版本显示

WebUI 可见标题与资源版本从 `1.6.3-assets-lazyload` 更新为 `1.6.4-mobile-layout`，用于确认手机布局修复版已加载。

### 13.7 上传脚本默认 ZIP 名称

`upload_esp32s3_firmware.ps1` 的默认 `ZipPath` 已同步更新为：

```powershell
.\esp32s3_firmware_mobile_layout.zip
```

因此把本 ZIP 与脚本放在同一目录时，可以直接运行脚本上传；也可以手动传入 `-ZipPath` 指向其它文件名。

---

## 14. v1.6.5 手机端控件紧凑排列修复

本次只修改 WebUI 布局与注释，不改 ESP32-S3 网络、UDP、LED、按钮、资源按需加载或固件播放逻辑。

### 14.1 修改目标

上一版 `v1.6.4-mobile-layout` 为了防止手机端横向溢出，把移动端 `.row` 改为纵向排列，并把 `input/select/textarea` 与 `.row .btn` 大量设置为 `width:100%` 或拉伸到整列宽度。这样虽然不会溢出，但按钮、输入框、下拉菜单都变成和 column 一样宽，视觉上过大且排列不够紧凑。

本版改为：

- `.grid2` 在手机端继续保持单列，保证每张 `.card` 占满可用宽度。
- `.row` 在手机端恢复横向 flex + wrap：控件按内容宽度排列，空间不够时自动换行。
- 按钮恢复内容宽度：`flex:0 0 auto; width:auto!important`。
- 普通输入框和下拉菜单恢复内容宽度，同时保留 `max-width:100%` 防止撑破卡片。
- 较长输入框如 `#ipInput`、`#scrollText`、`#unityMediaUrl` 使用 `width:min(320px,100%)` 与 `flex:0 1 320px`，在宽屏/横屏时接近原大小，在窄屏时自动收缩。
- `.wideSelect`、`#unityMediaSelect`、`.saveList` 使用可收缩的 320px flex-basis，不再强制撑满整列。
- `input[type="range"]` 改为 `flex:0 1 220px`，不再强制整行 100%。
- `textarea` 继续保持 `width:100%`，因为多行文本框按卡片宽度显示更符合编辑场景。

### 14.2 行内样式回收

以下元素上一版被改成 `style="min-width:0; width:100%"`，本版改成 `style="min-width:0; max-width:100%"`，具体宽度交给移动端 CSS 控制：

| 元素 | v1.6.4 样式 | v1.6.5 样式 |
|---|---|---|
| `#scrollText` | `min-width:0; width:100%` | `min-width:0; max-width:100%` |
| `#unityMediaSelect.wideSelect` | `min-width:0; width:100%` | `min-width:0; max-width:100%` |
| `#unityMediaUrl` | `min-width:0; width:100%` | `min-width:0; max-width:100%` |

`buildMediaTab()` 动态重建 Unity 媒体页面时使用的字符串模板也同步修改，避免切换页面或重建 tab 后回到整列宽度。

### 14.3 保留的手机端修复

以下 v1.6.4 的修复继续保留：

- `html, body { overflow-x:hidden; max-width:100vw; }`。
- 手机端 `.grid2 { grid-template-columns:1fr!important; }`。
- `#grid` 370 LED 编辑矩阵自适应 cell 缩放。
- `.miniGrid370` 预览矩阵自适应 cell 缩放。
- `ensureStableCss()` 动态 CSS 中同步的手机端矩阵缩放规则。

### 14.4 版本显示

WebUI 可见标题与资源版本从 `1.6.4-mobile-layout` 更新为：

```text
1.6.5-mobile-compact-controls
```

用于确认当前加载的是“手机端紧凑控件排列”版本。

### 14.5 上传脚本默认 ZIP 名称

`upload_esp32s3_firmware.ps1` 的默认 `ZipPath` 已同步更新为：

```powershell
.\esp32s3_firmware_mobile_compact_controls.zip
```
