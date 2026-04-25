# 网络部分逐项对比：RinaChanBoardHardware vs Pico+ESP8258 wifiparity

目标：让配网页面与 `RinaChanBoardHardware` 完全相同，同时保留 Pico + ESP8258 + UART bridge 架构。

## 1. 已替换回原版 WiFiManager 页面

本版本把原版文件直接复制到 ESP8258 工程：

- `RinaChanBoardHardware/RinaChanBoardHardware/include/WiFiManager.h`
- `RinaChanBoardHardware/RinaChanBoardHardware/src/WiFiManager.cpp`

因此配网页面的 HTML/CSS/Logo/按钮/表单/路由与原版一致，不再使用旧 Pico/ESP 版自制页面。

## 2. 页面与路由对比

| 项目 | 原版 RinaChanBoardHardware | 旧 Pico/ESP 版 | v1.2.6 wifiparity |
|---|---|---|---|
| 根页面 `/` | WiFiManager Options 页面 | 自制 `RinaChanBoard WiFi 配网` 页面 | 已恢复原版 WiFiManager Options 页面 |
| 扫描配网页 `/wifi` | 存在 | 不存在 | 已恢复 |
| 手动配网页 `/0wifi` | 存在 | 不存在 | 已恢复 |
| 保存路径 `/wifisave` | 使用参数 `s` / `p` | `/save`，参数 `ssid` / `pass` | 已恢复 `/wifisave` 和 `s` / `p` |
| 信息页 `/i` | 存在 | `/status` 文本页 | 已恢复 `/i` |
| 重启页 `/r` | 存在 | 不存在 | 已恢复 |
| Microsoft captive route `/fwlink` | 映射到根页面 | 不存在 | 已恢复 |
| 404 / captive redirect | 原版 WiFiManager 行为 | 自制返回首页 | 已恢复 |
| 页面标题/按钮/中文文本/logo | 原版 | 不同 | 已恢复 |

## 3. 原版 configwifi.cpp 参数对齐

| 原版设置 | v1.2.6 状态 |
|---|---|
| `wifiManager.setConnectTimeout(30)` | 已对齐 |
| `wifiManager.setMinimumSignalQuality(30)` | 已对齐 |
| `setAPStaticIPConfig(192.168.11.13, 192.168.4.1, 255.255.255.0)` | 已对齐 |
| `setAPCallback(configModeCallback)` | 已对齐 |
| `setSaveConfigCallback(saveConfigCallback)` | 已对齐 |
| `setBreakAfterConfig(true)` | 已对齐 |
| `setRemoveDuplicateAPs(true)` | 已对齐 |
| `autoConnect("RinaChanBoard")` | 已对齐 |
| 连接失败 `ESP.restart()` | 已对齐 |
| 连接成功打印 `local ip` | 已对齐为 framed log |

## 4. 唯一保留的工程性差异

`setDebugOutput(true)` 在原版中会把 WiFiManager 调试文本直接写到 `Serial`。

本项目的 ESP8258 `Serial` 同时也是 Pico 二进制 UART bridge。如果直接输出未封装文本，会污染 Pico 的 UART 帧流。因此 v1.2.6 使用：

```cpp
wifiManager.setDebugOutput(false);
```

这不会改变网页 HTML、路由、提交参数或 Wi-Fi 配置行为。ESP activity 仍通过 `TYPE_LOG` / `TYPE_STATUS` framed log 发给 Pico，再显示在 Pico USB 串口窗口。

## 5. 原版与本版网络职责区别

| 部分 | 原版 | 本版 |
|---|---|---|
| Wi-Fi 配网 UI | ESP8266 上的 WiFiManager | ESP8258 上同一份 WiFiManager |
| UDP 收包 | ESP8266 直接处理 LED 协议 | ESP8258 收 UDP 后转发给 Pico |
| UDP 回包端口 | 固定 4321 | 固定 4321 |
| UDP 本地端口 | 1234 | 1234 |
| LED 协议处理 | ESP8266 内部处理 | Pico 内部处理 |
| LED 输出 | ESP8266 FastLED | Pico PIO/NeoPixel |

## 6. 刷完后页面测试

未连接 Wi-Fi 或清除 Wi-Fi 后，连接 AP：

```text
RinaChanBoard
```

打开：

```text
http://192.168.11.13
```

应该看到原版页面：

- 页面标题为 `RinaChanBoard`
- 副标题包含 `自主配网系统by738NGX`
- 按钮：`配置WiFi(扫描WiFi)`
- 按钮：`配置WiFi(输入WiFi名)`
- 按钮：`查看信息`
- 按钮：`重启璃奈板`

保存 Wi-Fi 的路径应为：

```text
/wifisave?s=<SSID>&p=<PASSWORD>
```
