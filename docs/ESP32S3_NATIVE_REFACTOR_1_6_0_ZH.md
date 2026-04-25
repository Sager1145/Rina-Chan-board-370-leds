# RinaChanBoard ESP32-S3 Native Refactor v1.6.0

## 目标

将原来的 Pico + ESP8258 双芯片架构重构为单 ESP32-S3 架构：

- ESP32-S3 直接驱动 370 个 WS2812 LED。
- ESP32-S3 直接读取按钮与 ADC。
- ESP32-S3 直接提供 Wi-Fi、HTTP WebUI 与 UDP 协议。
- 不再使用 Pico UART，也不再使用 ESP8258 bridge。

## 引脚配置

| 功能 | ESP32-S3 GPIO |
|---|---:|
| CHG_ADC | GPIO1 |
| LED WS2812 DATA | GPIO2 |
| B1 / 上一个表情 | GPIO15 |
| B2 / 下一个表情 | GPIO16 |
| B3 / A/M 自动/手动 | GPIO17 |
| B4 / 亮度 + | GPIO42 |
| B5 / 亮度 - | GPIO41 |
| B6 / 电池/组合键 | GPIO40 |
| BATT_ADC | GPIO10 |

## 主要改动

- 新增 `esp32s3_firmware/esp32s3_network.py`：原 ESP8258 的 HTTP/UDP 转发功能改为 ESP32-S3 本机运行。
- 新增 `esp32s3_firmware/wifi_config.py`：配置 STA Wi-Fi 与 fallback AP。
- `board.py`：LED pin 改为 GPIO2。
- `buttons.py`：按钮 GPIO 改为 `15,16,17,42,41,40`。
- `config.py`：`BATT_ADC=10`，`CHG_ADC=1`。
- `battery_monitor.py`：ADC 改为 `ADC(Pin(gpio))` 并在可用时设置 `ATTN_11DB`，避免 ESP32 默认 ADC 范围过低导致分压采样被截断。
- `main.py`：移除 UART bridge，改为 `ESP32S3Network`。
- `rina_protocol.py`：版本更新为 `1.6.0-esp32s3-native`。

## Wi-Fi

默认开启 AP：

```text
SSID: RinaChanBoard-ESP32S3
IP:   192.168.4.1 通常为默认 SoftAP IP
```

如果要接入路由器，编辑 ESP32-S3 文件系统里的：

```text
wifi_config.py
```

设置：

```python
WIFI_SSID = "你的WiFi名"
WIFI_PASSWORD = "你的WiFi密码"
```

## WebUI/API

ESP32-S3 本机提供：

```text
/              WebUI
/api/status    网络/固件状态
/api/send      发送文本命令
/api/request   发送并等待文本回复
/api/binary    发送二进制命令
/i             文字状态页
/r             重启
```

## 上传

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rina_esp32s3_native_1_6_0.ps1 -Port COMx
```

如果没有 mpremote：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rina_esp32s3_native_1_6_0.ps1 -Port COMx -InstallDeps
```

## 成功启动版本

串口日志应显示：

```text
Firmware version: 1.6.0-esp32s3-native
ESP32-S3 native: Wi-Fi + HTTP + UDP + LED in one firmware
```
