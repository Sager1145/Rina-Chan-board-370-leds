# v1.3.3 SLEEPFIX 修复说明

- 修复 v1.3.2 启动时在原版三段 boot face 动画处崩溃的问题：`AttributeError: module object has no attribute sleep_ms`。
- 在 `board.py` 增加 `sleep_ms()` / `ticks_ms()`。
- 在 `rina_protocol.py` 增加 `_sleep_ms()` fallback。
- 保留 v1.3.2 的自动同步、Mutex、滚动文字、ASCII DB、Voice/Music/Video timeline、370 LED 电池/充电检测、B2+B6 显示 IP、WebUI。
