# v1.3.1 WEBUI_BUTTONS 集成说明

本版采用最佳双芯片分工：ESP8258 负责 Wi-Fi、UDP、HTTP/WebUI、原版 WiFiManager 配网页；Pico/RP2040 负责 RinaChanBoard 协议、微信小程序文本协议、flyAkari 旧协议、按钮、本地状态、370 LED 排列、默认 faces、矩阵 demo、充电检测、电池电压检测、运行/充电时间估算和 WS2812 输出。

## 从 Rina-Chan-board-370-leds 合入

- `board.py`: GP15、370 LEDs、22x18 虚拟矩阵、18 行不等长排列、蛇形走线、亮度上限。
- `demo_faces.py`: 默认 22x18 faces，默认启动 face = index 7。
- `buttons.py`: B1..B6 默认 GPIO 和 debounce/autorepeat。
- `brightness_modes.py`: 5%..100% UI 亮度映射到 170 通道上限，demo 模式亮度 1/3。
- `matrix_demos.py`: RGB、fire、hacker、hello-world demo。
- `battery_monitor.py` / `battery_runtime.py`: 电池电压 ADC、充电检测 ADC、百分比曲线、校准、剩余时间/充电时间估算。
- `display_num.py`: 间隔、亮度、模式、电池百分比、电压、时间、充电电压显示。
- `settings_store.py`: 保存亮度、间隔、auto、demo、电池校准和历史记录。

## 排除

- Bad Apple 模式与 `badapple_part*.py` 数据没有合入。B2+B6 组合不触发 Bad Apple。

## 按钮功能

- B1: 上一个 face；按住 B3 时增加自动切换间隔。
- B2: 下一个 face；按住 B3 时减少自动切换间隔。
- B3: 松开切换自动 face；按住作为间隔调节 modifier。
- B4: 亮度增加 5%。
- B5: 亮度减少 5%。
- B4+B5: 重置亮度。
- B6 短按: 临时显示电池百分比。
- B6 长按: 电池显示循环，包含百分比、电池电压、剩余/充电时间、充电电压。
- B3+B6 长按: 进入/退出矩阵 demo。

## ADC

- 电池电压: GP26 / ADC0，分压 100k + 57k。
- 充电检测: GP27 / ADC1，分压 270k + 47k。

## 网络协议

保留原 RinaChanBoard-main 二进制协议、微信小程序文本协议和 flyAkari 旧文本协议。`requestBattery` 现在返回电池/充电 JSON。

## v1.3.1 WEBUI_BUTTONS 追加改动

- WebUI 的自定义表情编辑器改为圆角矩形 LED；单击同一个格子即可开/关切换。
- 自定义表情页新增浏览器本地保存、载入、删除功能，数据保存在 localStorage。
- 表情部件页新增左眼、右眼、嘴巴、脸颊全部部件预览；点击任意预览即可选中并组合。
- 预设歌曲播放逻辑改为基于 audio.currentTime 的 50 ms 定时同步，修复选择歌曲后不同步、重播卡住、滑条跳转不同步的问题。
- Pico 硬件按钮新增 B2 + B6 显示当前 ESP STA IP。LED 会按顺序显示四个 IPv4 octet，例如 192 -> 168 -> 0 -> 150。串口同时打印完整 IP。
- Bad Apple 仍然不包含。
