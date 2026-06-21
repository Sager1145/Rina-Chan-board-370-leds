# WS2812 timing vs. Wi-Fi + data load — root causes and fixes

问题：ESP32-S3 同时刷新 370 颗 WS2812、跑 Wi-Fi AP、还通过 HTTP 上传/读取大量数据时，
LED 出现乱码/错色/闪烁。已做的 RMT 迁移没有完全解决。本文档分析根因、对照开源库
的做法、并给出针对本仓库的具体修法。

---

## 1. 有两个**不同**的根因，别混为一谈

### 根因 A：Wi-Fi 中断抢占，打断 LED 时序
WS2812 是严格自定时协议（每 bit 1.25µs，容差约 ±150ns）。无论 bit-bang 还是 RMT，
都需要 CPU/ISR 按时“喂”数据：

- **bit-bang（旧 Adafruit 路径）**：发送时关中断，靠 CPU 死等。Wi-Fi 一来要么时序被破坏，要么 Wi-Fi 被饿死。
- **RMT 非 DMA**：硬件 FIFO 很小（一块约 48–64 symbol），发送中途必须靠 **refill ISR** 不断补符号。实测在轻量 Wi-Fi 活动下，本应每 ~35µs 触发的 ISR 会抖动到 **40–50µs**，FIFO 被掏空 → 时序越界 → 乱码。([ESP32 Forum][2], [FastLED #2082][1])
- **RMT + DMA**：整块/大块缓冲由 DMA 喂，CPU refill 压力大幅下降。**但若 DMA 缓冲装不下整帧，一帧内仍会有若干次 refill 事件**，这些事件被 Wi-Fi 推迟时仍可能乱码。这正是 FastLED 在 RMT5 上仍遇到闪烁的原因：refill 被组件接管、缓冲默认偏小。([FastLED #2082][1])

> 关键点：**DMA 不是“开了就免疫”**。免疫程度取决于 DMA 缓冲够不够大（够大→一帧不再 refill）、ISR 优先级够不够高、以及热路径在不在 IRAM。

### 根因 B：Flash cache 关闭，拖死 ISR / PSRAM 访问
你“加载大量数据”时，LittleFS 在 flash 上读/写/擦，期间 **flash cache 会被关闭**
（`spi_flash_disable_caches`）。在这个窗口内：

- 任何**不在 IRAM** 的 ISR/编码函数都会 cache miss 卡住——RMT 的 refill/encode 如果在这时被调用，要么延迟要么直接 panic。Espressif 官方明确：cache 关闭时 RMT 中断默认被推迟，可能产生不可预测结果；并有真实 issue「flash 访问期间 RMT 发送导致 panic」。([ESP-IDF RMT 文档][3], [esp-idf #12271][4])
- 任何放在 **PSRAM** 的缓冲（你的 scroll buffer 默认在 PSRAM）在 cache 关闭期间访问也会停顿。

---

## 2. 你的代码**已经做对**的部分（别动）

- ✅ **核心隔离**：Wi-Fi/HTTP/按钮/电源在 Core 0，LED render/scroll task 在 Core 1（`scroll.cpp`、`platformio.ini` 的 `ARDUINO_RUNNING_CORE=0`）。这正是所有资料的第一条建议。
- ✅ **HardwareBus 锁**：`sync.cpp` 让 LittleFS flash 操作与 LED 发送互斥。**这恰好缓解根因 B**——发送 LED 的整个窗口内不会有 flash 操作去关 cache。这是你这套架构最关键的保护，必须保留。
- ✅ **帧节流 / queue**：`PACKED_FRAME_MIN_INTERVAL_MS`、render gap 限制，避免过密刷新。
- ✅ **HTTP 低内存准入**：`HTTP_MIN_FREE_HEAP_BYTES` 等，避免上传把堆压爆。

---

## 3. 为什么“现在的修复没解决”——最可能的几个原因

按可能性排序，请逐一排查：

1. **你测的是默认固件（仍是 Adafruit 后端）。**
   迁移后默认 `env:esp32s3` 仍然是 Adafruit（故意留作安全回退）。RMT+DMA 只有在
   `esp32s3-rmt-dma` 环境才生效。请确认烧的是：
   ```
   pio run -e esp32s3-rmt-dma -t upload
   ```
   串口 `status` 应显示 `ledBackend=rmt-dma dma=1`。如果显示 `adafruit`，迁移根本没启用。

2. **发送期间还有 refill 中断（乱码主因）。**
   `mem_block_symbols` 越小，一帧发送途中 refill 次数越多；这些 refill 中断被 Wi-Fi
   推迟就乱码。**注意：实测 RMT DMA 缓冲硬上限是 2047 且必须偶数**（驱动报错
   `can't exceed 2047 / must be even`），所以 RMT 上**无法**把整帧（8880 symbol）一次装下
   ——只能取最大 2046（一帧约 5 次 refill）。配合 IRAM 编码器 + intr_priority=3 +
   关 Wi-Fi 省电，实测已不再乱码。若要彻底零 refill，只有 I2S/LCD（无此上限）。

3. **DMA 缓冲太小，一帧仍多次 refill。**
   370 LED 一帧 = 8880 个 symbol。之前默认 `mem_block_symbols=1024`，意味着一帧要
   refill ~9 次，每次都可能被 Wi-Fi 推迟。已改默认为 2048，并支持调到装下整帧
   （`-D RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS=9216`，约 70KB 内部 RAM）。装下整帧时
   发送期间几乎不再 refill，接近免疫。

4. **编码函数不在 IRAM。**（已修）
   `ws2812_encode` / `ws2812_encoder_reset` 现已加 `IRAM_ATTR`。否则 flash cache 关闭
   时它们会卡。官方明确要求把 encode/reset 放进 IRAM。([ESP-IDF RMT 文档][3])

5. **RMT 中断优先级没拉满 + Wi-Fi 省电尖峰。**（已修）
   已设 `intr_priority=3`（驱动允许的最高）；并在 AP 启动时 `WiFi.setSleep(false)` 关省电。

6. **可能根本不是时序，是供电/压降。** 370 颗 WS2812 全亮可达十几安培，电源/走线压降会
   让末端 LED 颜色发飘、首颗误码。先用低亮度、纯色全亮测一下，排除电气问题。

---

## 4. 开源库都怎么解决（对照表）

| 方案 | 机制 | 抗 Wi-Fi 抖动 | 抗 flash-cache | 代价 |
| --- | --- | --- | --- | --- |
| Adafruit_NeoPixel (bit-bang) | 关中断死等 | 差（会和 Wi-Fi 互相伤害） | 差 | 简单 |
| **RMT 非 DMA** (esp-idf led_strip 默认) | 小 FIFO + refill ISR | 中（实测仍闪） | 需 IRAM ISR | 低 |
| **RMT + DMA + 大缓冲 + IRAM + prio3** | 大 DMA 缓冲，几乎不 refill | **好**（FastLED 实测 600 LED/10min 零闪） | 好（IRAM 编码 + 你的锁） | 中 |
| **I2S / LCD 外设 + DMA** (NeoPixelBus `NeoEsp32I2s*`, FastLED I2S) | 整帧 DMA，硬件自走，**零 CPU refill** | **最好（基本免疫）** | 好 | 中（占用 I2S/LCD 外设） |
| RMT4 手动 ping-pong / 自写 L5 汇编 ISR | 手动半缓冲补填 | 最好 | 最好 | 高（复杂、难维护） |

要点提炼：
- **NeoPixelBus 的 DMA 方法（I2S）之所以免疫**：数据填进 DMA 缓冲后，I2S 硬件独立产生波形，**完全不依赖 CPU 中断**，所以 Wi-Fi 怎么抖都不影响。([NeoPixelBus / ESP32 Forum][5])
- **FastLED RMT5 的结论**：`intr_priority=3` + 全程 `IRAM_ATTR` + 加倍 `mem_block_symbols`，在 S3/C3 上做到 600 LED、10 req/s Wi-Fi、10 分钟零可见闪烁。([FastLED #2082][1])
- **官方 led_strip / RMT 文档**：缓解手段就是「按 64 递增 `mem_block_symbols` + 把 encode 放 IRAM」，并提供 `CONFIG_RMT_TX_ISR_CACHE_SAFE`（开了必须把 encoder 放 IRAM）。([ESP-IDF RMT 文档][3])

---

## 5. 给你的具体修法（按性价比排序）

### Tier 1：先确认 + 用满 RMT-DMA（已基本就绪，0 风险）
1. 烧 `esp32s3-rmt-dma`，串口确认 `ledBackend=rmt-dma dma=1`。
2. 已默认 `intr_priority=3` + 编码函数 `IRAM_ATTR` + `mem_block_symbols=2048`。
3. 若仍闪，把缓冲调到装下整帧再测：
   ```ini
   build_flags = ${env:esp32s3.build_flags}
       -D RINACHAN_LED_BACKEND=1
       -D RINACHAN_LED_RMT_WITH_DMA=1
       -D RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS=9216
   ```
   用串口 `status` 看 `refreshMaxUs` / `refreshFail` 是否稳定。
4. **保留 HardwareBus 锁**（它在替你挡 flash-cache 那条路）。

### Tier 2：如果 Tier 1 还不够（中等改动）
5. **上传期间降帧/降负载**：上传 scroll 大数据时，Web 端只同步
   `sourceText + frameIndex + speed`，不要回读全部帧；继续保持 `/api/scroll` 分块。
   目标是减少 Core 0 的 Wi-Fi+flash 突发，给 Core 1 让路。
6. **scroll 源缓冲考虑放内部 RAM**：当前在 PSRAM，flash-cache 关闭期间 Core 1 读它会停顿。
   若内部 RAM 够，优先放内部 RAM 可消除这一路停顿（代价是占内部 RAM）。
7. **`CONFIG_RMT_TX_ISR_CACHE_SAFE=y`**（让 RMT ISR 在 cache 关闭时仍能跑）。pioarduino
   下需通过自定义 sdkconfig；配合已加的 IRAM 编码函数才有效。

### Tier 3：要“基本免疫”就换 I2S/LCD DMA 后端（较大改动，但最稳）
8. 新增第三个后端 `RINACHAN_LED_BACKEND=2`，用 **I2S（或 S3 的 LCD 外设）+ DMA** 驱动
   WS2812（参考 NeoPixelBus `NeoEsp32I2s1Ws2812xMethod` 或 ESP-IDF I2S/LCD 示例）。
   整帧 DMA、硬件自走、零 refill ISR → Wi-Fi 抖动基本无关。
   抽象层 `leddrv::*` 已经为此预留，业务代码不用动。
   代价：占用一个 I2S/LCD 外设；DMA 缓冲放内部 RAM。

> 建议路线：**先把 Tier 1 做透并实测**（多数情况 RMT-DMA + 大缓冲 + IRAM + prio3 就够了）。
> 真到极端负载仍闪，再上 Tier 3 的 I2S/LCD DMA。

---

## 6. 怎么验证（量化，而不是“看着好像好了”）
- 串口 `status`：盯 `refreshUs`、`refreshMaxUs`、`refreshFail`。`refreshFail` 应恒为 0，
  `refreshMaxUs` 不应远超单帧 ~11ms。
- 压测场景：AP 连一个客户端，循环刷 WebUI + 上传大 scroll 文本，同时 LED 全亮滚动，
  跑 10 分钟，数可见乱码次数。
- 三组对比固件：`esp32s3`(Adafruit) vs `esp32s3-rmt`(无DMA) vs `esp32s3-rmt-dma`，
  同场景比乱码率，定位收益来源。
- 用手机 120/240fps 慢动作录像数闪烁，比肉眼可靠。

---

## 7. 已改的代码（按轮次）

### 第一轮（RMT 后端硬化）
- `src/led_driver.cpp`：`ws2812_encode` / `ws2812_encoder_reset` 加 `IRAM_ATTR`；channel 配置加 `intr_priority`。
- `src/config.h`：新增 `RINACHAN_LED_RMT_INTR_PRIORITY`(默认3)；DMA `mem_block_symbols` 默认 1024→2048，并加注释说明如何调到整帧。

### 第二轮（Wi-Fi 抢占）
- **`src/web_api.cpp`：`startAccessPoint()` 加 `WiFi.setSleep(false)`（WIFI_PS_NONE）。**
  关闭 modem-sleep，消除周期性中断延迟尖峰（这种尖峰会推迟 LED refill ISR）。
- ~~曾尝试用 `esp_ipc_call_blocking` 把 RMT 通道建到 Core 1 以隔离 ISR~~ —— **已撤销**：
  IPC 任务栈只有 ~1KB，`rmt_new_tx_channel` 在里面跑会撑爆栈，开机即 panic
  （`Stack canary watchpoint triggered (ipc1)`）。见第四轮修复。

### 第四轮（这次 —— 修开机 panic）
- **`src/led_driver.cpp`：去掉 `esp_ipc`，在当前任务栈（loopTask，8KB）上正常创建 RMT 通道。**
  这修掉了上面那个开机重启循环。**ISR 核亲和性不再追求**：第三轮的整帧 DMA 缓冲已经让
  发送期间几乎没有 refill 中断，ISR 在哪个核都无所谓（trans-done 中断被推迟只影响延迟，
  不污染时序）。`begin` 日志的 `isr_core` 现在如实打印实际核（通常是 0）。

### 第三/五轮（DMA 缓冲拉到合法最大值 2046）
- **`src/config.h`：DMA `mem_block_symbols` 默认设为 2046。**
  曾试 9216（整帧），但驱动报 `mem_block_symbols can't exceed 2047 / must be even`
  ——**RMT DMA 缓冲硬上限 2047 且必须偶数，整帧装不下**。2046 是合法最大值，
  一帧约 5 次 refill；配合 IRAM/prio3/关省电实测已不乱码。
- **`src/led_driver.cpp`：begin() 自动降级重试 2046→1024→512→256→64**，
  并对 DMA 候选自动夹到 ≤2046 且取偶数，避免再刷 RMT 报错。
  启动日志打印实际 `mem_sym`（DMA 下 `whole_frame` 恒为 0，因为整帧装不下，属正常）。

### ⚠️ 最重要：先确认你烧的是 RMT-DMA 后端，不是默认 Adafruit
你贴的日志用的是 `pio device monitor -e esp32s3` —— **`esp32s3` 是默认环境 = Adafruit 后端**，
本文档所有修复都不在这个固件里。必须用 RMT-DMA 环境烧录 **并** 监视：
```bash
pio run -e esp32s3-rmt-dma -t upload
pio device monitor -e esp32s3-rmt-dma -b 115200
```
启动后日志应出现这一行（重点看 `backend=rmt-dma`、`mem_sym=2046`，且**不再 `Rebooting...` 循环**）：
```
LEDDRV event=begin backend=rmt-dma dma=1 ready=1 isr_core=0 ... mem_sym=2046 frame_sym=8881 whole_frame=0 prio=3
```
说明：`whole_frame=0` 是正常的——RMT DMA 缓冲上限 2047，装不下整帧。`isr_core` 现为
实际核（通常 0），不再追求 Core 1（整帧装不下、且之前 IPC 方案会 panic）。
若看到 `backend=adafruit`，说明还在跑老后端，之前的修复一律无效。

### 关于缓冲放置（已分析，无需改）
- LED DMA 暂存缓冲 `sPixels` 是普通静态数组 → 在内部 SRAM(DRAM)，本身 DMA 可用，**不在 PSRAM**，正确。
- scroll 大缓冲（~141KB）在 PSRAM 是合理的：强行放内部 RAM 装不下，且它只在 scroll lock 下被读、
  不在 refresh 期间，flash 操作最多让这次读**变慢**（随后数据仍有效），**不会污染** RMT 发送。
  所以这不是乱码源，保持 PSRAM。

（Tier 3 的 I2S/LCD DMA 后端尚未实现，等本轮实测结果再决定是否需要。）

---

## 参考来源
- [FastLED #2082 — Improved RMT5 to resist WiFi flickering][1]
- [ESP32 Forum — RMT transaction corrupted by WiFi interrupts (40–50µs jitter)][2]
- [ESP-IDF RMT 文档 — IRAM-safe encoder / mem_block_symbols / cache-safe ISR][3]
- [esp-idf #12271 — flash access during RMT transmission causes panic][4]
- [ESP32 Forum / NeoPixelBus — 为什么 I2S DMA 不受 Wi-Fi 中断影响][5]

[1]: https://github.com/FastLED/FastLED/issues/2082
[2]: https://esp32.com/viewtopic.php?t=41170
[3]: https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/rmt.html
[4]: https://github.com/espressif/esp-idf/issues/12271
[5]: https://esp32.com/viewtopic.php?t=3980
