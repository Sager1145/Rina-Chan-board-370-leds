# LED 后端迁移：Adafruit_NeoPixel → ESP-IDF RMT (+DMA)

本次改动把 LED 物理传输后端从 `Adafruit_NeoPixel` 迁移到 ESP-IDF 5.x 新 RMT TX
驱动（可选 DMA），同时**完整保留**现有的 Core1 渲染 task、Frame/Scroll/Storage/
HardwareBus 互斥锁、以及 HTTP 低内存保护。后端通过编译开关选择，默认仍是
Adafruit，保证默认构建行为与历史版本一致、可随时回滚。

## 改了哪些文件

| 文件 | 改动 |
| --- | --- |
| `src/led_driver.h` (新增) | LED 抽象层接口：`leddrv::begin/setBrightness/setPixel/clear/refresh` + 诊断 |
| `src/led_driver.cpp` (新增) | 两个后端实现：Adafruit（默认/回退）与 RMT(+DMA)；自定义 WS2812 编码器；亮度缩放 |
| `src/led_renderer.cpp` | 移除 `Adafruit_NeoPixel` 直接依赖，改调用 `leddrv::*`；语义不变 |
| `src/config.h` | 新增 `RINACHAN_LED_BACKEND` / `RINACHAN_LED_RMT_WITH_DMA` / 分辨率 / mem_block 配置 |
| `platformio.ini` | 新增 `esp32s3-rmt` 与 `esp32s3-rmt-dma` 两个构建环境 |
| `src/sync.cpp` / `src/sync.h` | 更新注释：`strip.show()` → `leddrv::refresh()`；说明 DMA 不免除 flash-cache 干扰 |
| `src/serial_console.cpp` | `status` 命令新增 `ledBackend/dma/refreshUs/refreshMaxUs/refreshFail/heapFree/largestBlock` |
| `src/web_api.cpp` | `/api/status` 的 `renderer` 对象新增 `ledBackend/ledDma/ledRefreshUs/ledRefreshMaxUs/ledRefreshFail` |

## 三个构建环境

| 环境 | 后端 | 用途 |
| --- | --- | --- |
| `esp32s3` (默认) | Adafruit_NeoPixel | baseline / 安全回退，行为不变 |
| `esp32s3-rmt` | RMT，无 DMA | 验证 API、颜色顺序、亮度、370 映射、scroll、按钮动画 |
| `esp32s3-rmt-dma` | RMT + DMA | 主收益固件 |

```bash
pio run -e esp32s3            # baseline（默认）
pio run -e esp32s3-rmt -t upload
pio run -e esp32s3-rmt-dma -t upload
```

也可在任意环境用 build flag 覆盖，例如 `-D RINACHAN_LED_BACKEND=1 -D RINACHAN_LED_RMT_WITH_DMA=1`。

## 关键设计点

- **亮度缩放**：Adafruit 在 `show()` 内部统一缩放；RMT 后端在 `setPixel()` 里按
  `分量 * brightness / 255` 缩放每个 R/G/B。按钮/电池 overlay 也走 `setPixel`，所以
  同样被缩放，与旧行为一致。
- **颜色顺序**：两后端都是 GRB。RMT 后端在缓冲区里按 G,R,B 排列。
- **同步语义**：`leddrv::refresh()` 在 RMT 后端里 `rmt_transmit()` 后调用
  `rmt_tx_wait_all_done()`，保持与 `strip.show()` 一样的“阻塞到发送完成”语义，
  现有 `LED_SIGNAL_RESET_US` / `LED_RENDER_MIN_GAP_US` / `lastLedShowUs` 节流逻辑
  原样保留。
- **互斥保留**：`refresh()` 仍在 `withHardwareBusLock()` 内调用；Storage 锁仍同时
  持有 HardwareBus。DMA 只降低 RMT refill/ISR 压力，**不**消除 flash-cache 干扰，
  所以这层锁继续有效。
- **WS2812 编码器** 与 Espressif `led_strip` 的 RMT 编码器一致：bytes 编码器
  (T0H=0.3µs/T0L=0.9µs/T1H=0.9µs/T1L=0.3µs, MSB-first) + copy 编码器发 ≥50µs 复位码。
- **失败可见**：`begin()` 失败会 `RLOG_ERROR` 并把 `ledReady=0`，不静默继续。

## 为什么是“自带 RMT 驱动”而不是引入 led_strip 组件

PlatformIO 的 **Arduino framework** 无法干净地消费 ESP-IDF 的 managed component
（`idf_component.yml` 仅在 ESP-IDF framework 生效）。因此这里直接用 `driver/rmt_tx.h`
新 RMT 驱动实现，机制与 `espressif/led_strip` 的 RMT 后端**完全相同**（同样的 bytes
编码器 + DMA flag），收益一致，且无外部组件耦合、更易审阅与回滚。若坚持用官方组件，
可把其源码 vendoring 到 `lib/led_strip/` 再切换 `leddrv` 实现。

## 前置条件 / 待确认

- **平台已锁定**：`platformio.ini` 的 `[env:esp32s3]` 已 pin 到 pioarduino fork
  `55.03.39`（Arduino-esp32 3.3.9 / ESP-IDF 5.5.4），提供新 RMT 驱动
  `driver/rmt_tx.h` + DMA。升级改那一行的 tag 即可。
- **首次切换平台请清干净再编译**：从官方 espressif32 切到 pioarduino 后，旧的
  `.pio/` 缓存会失配，先 `pio run -t clean`（或删除 `.pio/`）再 `pio run`。
- **WebServer 超时 patch 脚本**：`scripts/patch_webserver_timeout.py` 针对的
  `WebServer.h` 在 core 3.x 下路径/内容可能变化，切换后请确认该 pre 脚本仍能命中目标，
  否则 `HTTP_MAX_*_WAIT` 不会生效。
- **DMA 的 `mem_block_symbols`**：当前 DMA 默认 1024（非 DMA 64）。如遇 DMA 缓冲/通道
  分配失败，先调小或确认 S3 RMT DMA 资源；可用 `-D RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS=...` 覆盖。
- **未在本机编译验证**：此环境无 PlatformIO 工具链，未做实机编译/烧录。请在本地跑
  `pio run -e esp32s3`（确认默认仍编译通过）和 `pio run -e esp32s3-rmt-dma`。

## 物理发送时间（不变）

DMA 不会缩短 WS2812 协议本身：370 × 24bit × 1.25µs ≈ **11.1ms / 帧**。DMA 降低的是
CPU/ISR refill 压力，从而减少 Wi-Fi/HTTP 活跃时的乱码/错色概率。

## 验证清单（建议按 Adafruit → RMT no-DMA → RMT DMA 三组对比）

- 开机默认表情无首帧乱码
- Manual 点击：LED 实时刷新且 WebUI 不断链
- Auto 模式切换期间 WebUI 刷新不乱码
- Scroll 长时间播放不闪烁；播放中刷新 WebUI 硬件继续滚、预览能恢复
- Scroll 大文本上传：不重启、不断链、不乱码
- LittleFS 上传/读取期间 LED 不错色
- 连续刷新网页不 panic
- 低内存时返回 503 而非 crash
- 串口 `status`：确认 `ledBackend` / `dma` / `refreshUs` / `refreshMaxUs` / `refreshFail` / `heapFree`
- 对比三组固件的乱码/错色发生率
