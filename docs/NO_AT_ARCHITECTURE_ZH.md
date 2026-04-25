# No-AT 架构说明

## 为什么不用 ESP-AT

ESP-AT 的优点是不用自己维护 ESP 端网络固件；缺点是 UART 上是文本命令和 `+IPD` 混合流，状态机复杂，错误恢复慢，而且 HTTP 配网和 UDP 模式容易受不同 AT 固件版本影响。

本版本改为 ESP8258 自定义桥接固件：

1. ESP8258 只负责 Wi-Fi、UDP、配网页。
2. Pico 只负责 RinaChanBoard-main 协议和 LED timing。
3. 两者之间只传 UDP datagram 和状态/log，不传 AT 命令。
4. UART 帧有固定头、长度和 CRC，可以从 ESP boot 噪声中自动重新同步。

## UART 帧格式

所有多字节字段使用 little-endian。

| 字段 | 长度 | 值 |
|---|---:|---|
| SOF0 | 1 | `0xA5` |
| SOF1 | 1 | `0x5A` |
| Version | 1 | `0x01` |
| Type | 1 | 帧类型 |
| Length | 2 | payload 长度 |
| Payload | N | 数据 |
| CRC | 1 | `Version ^ Type ^ LenLo ^ LenHi ^ Payload...` |

## 帧类型

| Type | 方向 | Payload |
|---:|---|---|
| `0x01` UDP_RX | ESP → Pico | `ipv4[4] + port_le[2] + udp_payload` |
| `0x02` UDP_TX | Pico → ESP | `ipv4[4] + port_le[2] + udp_payload` |
| `0x03` LOG | ESP → Pico | UTF-8/ASCII log |
| `0x04` STATUS | ESP → Pico | UTF-8/ASCII network status |
| `0x05` PING | Pico → ESP | empty |
| `0x06` PONG | ESP → Pico | empty |

## 最优化分工

- WS2812 对时序敏感，所以由 Pico 直接驱动，不让 ESP 在 Wi-Fi 中断期间同时 bit-bang LED。
- UDP 网络栈留在 ESP8258，避免在 Pico 上实现 TCP/IP/Wi-Fi。
- UART 只传短 datagram，115200 baud 足够处理 RinaChanBoard-main 的 36-byte/16-byte/4-byte 控制包。
- Pico USB serial 仍然作为总调试口，可以看到 ESP bridge 的 framed log/status。

## 115200 baud 与 ESP activity log

此版本将 Pico ↔ ESP8258 runtime UART 固定为 **115200 baud**。ESP 端不会输出 ESP-AT，也不会输出裸文本日志；所有日志都被封装成 no-AT binary frame，再由 Pico 解析后打印到 Pico USB 串口窗口。

ESP 会主动上报：

- boot/reset/chip/flash/SDK/core/free heap；
- EEPROM Wi-Fi 配置读取、保存、清除；
- Wi-Fi 连接进度、连接成功后的 `sta_ip/gateway/subnet/dns/mac/rssi/channel/bssid`；
- AP 配网页启动信息：`ap_ssid/ap_ip/ap_mac/ap_clients`；
- HTTP 配网页访问、保存、清除、状态查询；
- UDP RX/TX 的 IP、port、长度、前若干 byte preview；
- UART frame、PING/PONG、CRC/长度错误；
- 每 5 秒一次完整状态帧。
