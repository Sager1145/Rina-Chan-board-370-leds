# 双板测试遗留问题修复记录

对应 `stress-dual-run1/REPORT.md` 中的低优先级与待验证问题。2026-09-13 第二轮：补修复、独立审查、刷板真机验证。

## 结果一览

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| FW-ADC-ATTEN | 启动时用全局 `analogSetAttenuation(ADC_11db)` 取代单引脚设置 | 真机 PASS：A、B 刷机后开机日志不再出现 `Pin is not configured as analog channel` |
| 开机 NVS 报错（新发现） | 电池待定低点用 IDF `nvs_open(NVS_READONLY)` 静默读取；`wifi_manager.cpp` 读凭据前 `isKey()` | 真机 PASS：A、B 开机不再出现 `nvs_open failed` 与 7 条 `getString … NOT_FOUND` |
| TEXT-STALE-TIMELINE | 连接代次或当前会话变化时清除旧时间轴、进度、预览，保留草稿与速度 | 真机 PASS（A）：30 fps 滚动中复位 → 文字页「閒置」、进度 00:00、预览空白、草稿保留；点播放重新 `set_scroll_loop` → `start count=151 interval_ms=33`，面板实测 30.3 fps |
| FACE-SAVE-STALE-GEN | 保存目标按物理板身份判断，同板重连保留更新 ID，无法确认归属时拒绝 | 真机 PASS（A，写 flash）：新建 `parts_face` → faceCount 11→12；复位重连后再保存 → `face_upsert`，faceCount 仍 12（更新而非重复）；测试表情已删除，faceCount 回到 11 |
| HOTSPOT-SESSION | 按实际加入的 SSID 分配会话，不再按共享 IP | 主机测试 PASS；双板热点切换未在真机复测 |

## 审查后追加的 iOS 修复

- 握手身份读取全部失败时，只对同一 BLE 外设（`ble:` 键）沿用上次确认的板身份，避免同板重连时丢弃表情草稿。Wi‑Fi/热点地址可能被不同板共用，不沿用。
- App 从后台回到前台只做同步读取，不再取消正在上传的文字时间轴。
- 板端在滚动但 App 未绑定时间轴时，每代连接最多每 5 秒重试一次恢复；只在板端确认滚动中、且输出未被影片/演出占用时才接管。
- 控制中心和「忘记板子」的热点判断优先使用当前会话的 SSID。
- 连接变化同步逻辑抽到 `BoardSyncCoordinator`，补根视图级测试。

## 电池电量自动校准（新功能）

- 最高电压：EMA 电压持续高于当前最高值 60 s 才学习，取窗口内最小值；充电时不学习（避免学到充电 CV 平台），但 ADC 已削顶时例外。
- 截止电压：放电进入低区（按固定 6.20 V 下限算）后，把最低电压写入 NVS（每下降 ≥0.05 V 才写）；下次开机复位原因为上电/欠压时才采纳，且必须在截止值上方 15% 跨度内，已学习后每次最多上调 0.05 V，防止关机开关误教。持续充电 30 s 或电压回升后清除 NVS 记录。
- 百分比：把 [截止, 最高] 映射到查表的 6.20–8.40 V，修正旧版满电只显示约 80% 的问题。v1 校准文件中 8.0 V 默认值迁移为 8.40 V。
- `reset_battery_max/min` 仍可手动覆盖；`status.power` 新增 `battCalibMaxV`、`battCalibCutoffV`、`battCalibMaxLearned`、`battCalibCutoffLearned`、`batteryAdcSaturated`。
- 纯逻辑在 `battery_calibration.{h,cpp}`，主机测试 13 项。

## B 板读数

- B 板电池与充电两路 ADC 常卡在 3147 mV（ESP32‑S3 11 dB 满量程），A 板从不接近。读数削顶，不是换算系数问题。
- 刷新固件后，B 板已自动学到最高电压 8.726 V（削顶值），电量按该值计算。
- B 板充电通道几乎一直判定为「充电中」，因此 B 板学不到截止电压。仍需用万用表检查 B 板分压电阻与接地。

## 验证

- 固件 `pio run -e esp32s3-rmt-dma` 编译通过（RAM 30.6%，Flash 17.0%），已刷入 A、B（仅 `-t upload`，未覆盖 LittleFS）。
- 固件主机测试：battery_calibration、ble_frame_sender、stream_transport 与 8 个 Python 测试全部通过。其中 `stress_findings_test.py` 起初卡死：流式加固改动让超长帧回 ERR 413 并断开连接，旧 harness（`docs/stress-20260912-211559/tools/firmware/stress_f5_f7_blob.cpp` F7-TEXT-WIRE-4096）仍在已释放的槽位上分片发送而死循环。harness 改为断言收到 ERR 413 且连接关闭、再重连后，重跑 12 s 完成：F4 pass=14、F5F7 pass=67、fail=0。
- RinaCore `swift test` 180/180。iOS 定向套件 55/55；全量 RinaBoardTests 234 项中 1 项失败（`BoardConnectionOutputTests.testLiteStatusEventPreservesFullSnapshotFields`，审查判断与本次修复无关）。
- 真机串流：A 上演出 TOKIMEKI Runners 循环约 106 s，无断开/报错/重启，串流后控制正常。
- 仍存在的开机报错：2 条 `esp_core_dump_flash: No core dump partition found!`（ESP-IDF 框架，分区表无 coredump 分区，非本次引入）。
