# 1.4.4 bootanim-off-faces

## 改动

- 取消 Pico LED 开机动画：不再显示原版 initLED / WIFI / UDP / READY 启动画面。
- 上电后直接显示当前保存表情列表中的当前表情。
- `rina_protocol.boot_animation()` 保留为兼容空函数，不再写 LED、不再延时。
- 使用上传的 `demo_faces.py` 重新生成默认保存表情。
- `demo_faces.py` 中全部 11 个 22×18 画面已转换为 370 真实矩阵 `M370` 格式。
- 自定义表情页和表情部件页继续共用同一个保存表情列表。

## 生成/同步文件

- `pico_firmware/demo_faces.py`
- `pico_firmware/saved_faces_370.py`
- `webui/default_saved_faces_370.json`
- `webui/index.html`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
