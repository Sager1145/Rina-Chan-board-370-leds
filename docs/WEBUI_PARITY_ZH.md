# WebUI 集成功能说明

## 来源

- `RinaChanBoardOperationCenter.wechatapp`：首页、颜色、亮度、自定义表情、预设语音、预设歌曲、关于页。
- `RinaChanBoardHardware`：二进制 UDP 协议与 WiFiManager 配网页。
- `flyAkari/RinaChanBoard`：旧 ESP8266 UDP 协议，包含 `RinaBoardUdpTest` 与 `eyeL,eyeR,mouth,cheek,` 格式。

## 浏览器通信方式

浏览器没有普通 UDP socket，因此网页不能直接复用微信小程序的 UDP API。此版本在 ESP8258 上增加 HTTP 控制 API：

- `/api/send`：发送文本协议，例如 `#ff0000`、`B016`、72 位 hex、`requestFace`。
- `/api/request`：发送文本 request 并等待 Pico 回包。
- `/api/binary`：发送十六进制二进制包，支持等待回包。
- `/api/flyakari/test`：旧版测试包。
- `/api/flyakari/face`：旧版逗号分隔 face 包。

HTTP API 收到命令后模拟一帧 UDP_RX 发给 Pico。Pico 如果回包，ESP 会捕获目标为 `127.0.0.1:0xF0F0` 的 UART UDP_TX frame，并作为 HTTP response 返回给浏览器。
