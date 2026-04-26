# ESP32-S3 RinaChanBoard 固件外置注释

- 源 ZIP：`esp32s3_firmware_modular_1_7_0.zip`
- 注释生成时间：2026-04-26
- 固件版本：`1.7.0-modular`
- 注释方式：源码内只保留必要说明；本文件集中记录模块职责、控制流和本次改动。
- 根目录要求：ZIP 解压后根目录必须是 `esp32s3_firmware/`，不能再套版本目录。

## 1. 本次重构结论

本版按用户给定架构做模块化重构：

1. **电池显示归属独立电池模块**：`battery_module.py` 负责电池电量、电压、剩余/充电时间、充电动画、B6 电池显示入口和 `requestBattery` JSON。
2. **保留独立协议层**：`rina_protocol.py` 仍然是 UDP/HTTP 文本/二进制协议路由层，不把协议处理分散到功能模块。
3. **模块间通信采用回调/门面委托**：`main.py` 作为组合根和主循环门面；`rina_protocol.py` 通过 `set_callbacks(...)` 调用应用功能；各功能模块通过 `AppModule.__getattr__()` 回到 `LinaBoardApp` 门面，避免模块互相直接 import。

## 2. 当前模块结构

```text
main.py
  ├─ rina_protocol.py          # 协议路由层：UDP/HTTP 文本与二进制命令
  ├─ face_module.py            # 表情/保存表情/370 物理 face 绘制
  ├─ color_module.py           # Web/协议颜色与亮度同步
  ├─ scroll_module.py          # B2+B6 IP/SSID 滚动显示
  ├─ wifi_module.py            # ESP32-S3 原生 Wi-Fi/UDP/HTTP 轮询连接
  ├─ gpio_module.py            # 实体 GPIO 按键路由
  ├─ home_module.py            # Home、A/M、亮度、间隔、边缘闪烁
  ├─ battery_module.py         # 电池采样显示、充电动画、battery JSON
  └─ unity_module.py           # WebUI runtime/Unity timeline 桥接

共享文件：
  board.py, config.py, app_state.py, display_num.py, settings_store.py,
  brightness_modes.py, buttons.py, battery_monitor.py, battery_runtime.py,
  saved_faces_370.py, emoji_db.py, webui_runtime.py, esp32s3_network.py
```

## 3. 主控制流

```text
boot.py
  ↓
main.py / LinaBoardApp.__init__
  ↓  创建 state、BatteryState、ButtonBank、BatteryMonitor、WebUIRuntime
  ↓  创建 8 个功能模块
main()
  ↓  启动 ESP32S3Network(AP/STA + HTTP + UDP)
  ↓  创建 RinaProtocol(app=app)
  ↓  proto.set_callbacks(...)
  ↓  app.attach_network(link, proto)
  ↓
app.run() 主循环
  ├─ service_network()         # Wi-Fi/UDP/HTTP 包转交 rina_protocol.py
  ├─ check_*_combo()           # B2+B6、B3+B6 等组合键
  ├─ buttons.poll()            # GPIO 按键事件
  ├─ service_battery_overlay() # 电池页面/动画
  ├─ service_ip_display()      # IP/SSID 滚动文字
  ├─ web_runtime.service()     # WebUI scroll / Unity timeline 固件侧播放
  ├─ update_calibration()      # 电池校准/历史
  └─ auto face cycle           # A 模式自动换脸
```

## 4. 文件职责索引

| 文件 | 行数 | 职责 |
|---|---:|---|
| `main.py` | 423 | 主循环、模块组合根、协议回调注册、对外门面方法。 |
| `app_module_base.py` | 23 | 功能模块基类；通过 `__getattr__()` 把未知调用转回 `LinaBoardApp`。 |
| `rina_protocol.py` | 919 | 独立协议路由层；支持原版二进制 UDP、文本协议、M370、WebUI 管理命令；新增 `set_callbacks()` 回调桥。 |
| `face_module.py` | 79 | 当前保存表情绘制、B1/B2 换脸、WebUI 选择/同步保存表情。 |
| `color_module.py` | 56 | 协议颜色、Web 亮度到实体亮度百分比同步。 |
| `scroll_module.py` | 75 | B2+B6 显示 STA IP/SSID，滚动窗口刷新与到期恢复表情。 |
| `wifi_module.py` | 52 | 连接 `ESP32S3Network` 与 `RinaProtocol`，每轮最多处理 4 个包，避免动画卡死。 |
| `gpio_module.py` | 79 | 实体按钮事件路由：换脸、间隔、亮度、亮度复位、B6 电池入口、B3 A/M 释放判断。 |
| `home_module.py` | 285 | Home 运行模式、A/M 状态、亮度/间隔 overlay、边缘闪烁、网络控制回 M。 |
| `battery_module.py` | 391 | 独立电池显示：均值采样、百分比、电压、充电电压、剩余/充电时间、充电动画、B6 长短按、JSON。 |
| `unity_module.py` | 24 | WebUI runtime 命令代理：`scrollText370`、`timeline370*`、`runtimeStop` 等转到 `webui_runtime.py`。 |
| `webui_runtime.py` | 393 | 固件侧滚动文字和 Unity timeline 播放运行时。 |
| `esp32s3_network.py` | 674 | ESP32-S3 原生 AP/STA、HTTP API、UDP 收发、静态文件服务。 |
| `webui_index.html.gz` | 5381 解压行 | 内置 Web 控制台；Unity asset shard 按需 fetch、停止时 unload。 |
| `assets/` | 160 文件 | `color_info.json.gz`、`unity_core.json.gz`、voice/music/video 单项目 shard。 |
| `board.py` | 659 | 370 LED 物理矩阵、GPIO2 WS2812 驱动、22×18 不规则映射、绘图基础。 |
| `board_370.py` | 163 | 备用/旧版 370 LED 矩阵驱动。 |
| `config.py` | 139 | 全局常量：GPIO、亮度、间隔、电池 ADC、刷新周期、闪烁时间。 |
| `app_state.py` | 120 | `AppState` 与 `BatteryState` 运行期状态。 |
| `settings_store.py` | 105 | 保存/读取亮度、A/M、间隔、电池校准和电量历史。 |
| `brightness_modes.py` | 57 | UI 百分比亮度到 LED 最大通道值换算。 |
| `buttons.py` | 220 | GPIO 按键消抖、重复触发、低电平有效输入。 |
| `display_num.py` | 255 | 数字、文字、模式、电池图标和滚动文字渲染。 |
| `battery_monitor.py` | 309 | ADC 初始化、采样窗口、电压换算、百分比曲线、充电检测阈值。 |
| `battery_runtime.py` | 139 | 电池续航/充电时间估算历史模型。 |
| `saved_faces_370.py` | 343 | 370 LED 表情库和 WebUI 保存/删除/排序/重命名。 |
| `emoji_db.py` | 129 | 原版 lite face 眼睛/嘴/脸颊数据库。 |
| `demo_faces.py` | 297 | 旧版 demo 表情，当前 no-demo 主路径不导入。 |
| `matrix_demos.py` | 472 | 旧版矩阵 demo，当前主路径禁用。 |
| `boot.py` | 12 | 最小启动脚本，只做 GC 和启动日志。 |
| `wifi_config.py` | 15 | STA/AP SSID 与密码配置；AP 密码为空时应为 open AP。 |
| `upload_esp32s3_firmware.ps1` | 143 | Windows 上传脚本：解压 ZIP、清理旧文件、递归上传固件、reset。 |

## 5. 关键行为说明

### 5.1 电池显示

- B6 短按：显示电量百分比约 2 秒。
- B6 长按约 700 ms：进入循环电池页面。
- 未充电循环：百分比 → 电池电压 → 剩余时间。
- 充电循环：百分比 → 电池电压 → 充满剩余时间 → 充电输入电压。
- 充电动画由 `battery_module.py` 调用 `display_num.render_battery_*()` 完成。
- `requestBattery` / `requestState` 的电池 JSON 由 `battery_module.py::battery_status_json()` 生成。

### 5.2 协议层

`rina_protocol.py` 继续只负责“收到什么命令、应该路由到哪里、怎样回复”。它不会直接拥有电池、GPIO、Wi-Fi、Unity 的状态。当前版本新增：

```python
proto.set_callbacks(
    network_control=app.on_network_control,
    set_manual_control_mode=app.set_manual_control_mode,
    handle_webui_runtime_command=app.handle_webui_runtime_command,
    battery_status_json=app.battery_status_json,
    ...
)
```

为兼容旧调用，`RinaProtocol(app=app)` 仍保留 fallback；如果 callback 不存在，会回退到旧的 `app.method()` 路径。

### 5.3 A/M 控制

- 实体按钮操作进入本地手动控制。
- WebUI / UDP / HTTP 控制会退出实体手动锁，并强制保存表情自动循环回 M。
- B3 的 A/M 切换仍在释放时计算，避免按下瞬间被强制 M 导致只能切到 A。

### 5.4 Unity / WebUI runtime

- 浏览器不再一次加载大 Unity 数据包；每个 voice/music/video 项目按需 fetch 对应 shard。
- 播放新 Unity timeline 前会先停止旧 timeline，避免旧动画在新 chunk 上传期间继续显示。
- 停止播放、切换类型、离开页面时清理浏览器端 timeline 缓存。

## 6. 上传脚本说明

`upload_esp32s3_firmware.ps1` 默认 ZIP 名已更新为：

```powershell
.\esp32s3_firmware_modular_1_7_0.zip
```

清理列表已包含新增模块文件：

```text
app_module_base.py, battery_module.py, color_module.py, face_module.py,
gpio_module.py, home_module.py, scroll_module.py, unity_module.py, wifi_module.py
```

脚本上传时会排除自身和本注释文件，不会把 `EXTERNAL_CODE_COMMENTS.md` / `.ps1` 烧进 ESP32-S3。

## 7. 验证记录

- 已对所有 `.py` 文件执行 CPython 语法编译检查：`python3 -m py_compile *.py`。
- 未在真实 ESP32-S3 硬件上执行运行验证；MicroPython 的 `time.ticks_*`、`network.WLAN`、`machine.ADC` 等硬件路径仍需上板测试。
- ZIP 顶层目录保持为 `esp32s3_firmware/`。
