# WebUI 功能集成到 Pico 固件 v1.5.6

本版在 v1.5.5 的“滚动文字 / Unity 时间轴由 Pico 固件播放”基础上，继续把保存表情管理迁移为 Pico 固件侧状态。

## 新增集成点

- WebUI 启动时先向 Pico 发送 `requestSavedFaces370`，用固件中的保存表情列表作为主数据源。
- 保存、删除、锁定、属性切换、拖拽排序后，WebUI 会把完整有序列表通过 `saveFaces370Json|...` 同步给 Pico。
- 点击保存表情行时，WebUI 会发送 `selectFace370|index`，Pico 立即切换当前表情；B1/B2 和 A/M 自动/手动循环使用同一排序。
- Pico 固件侧保存列表统一使用从上到下的可见编号：普通表情 `01..99`，默认表情 `*01..*99`。
- 固件新增按 index 操作接口，WebUI 可以不依赖浏览器本地缓存完成排序/锁定/删除/选择。

## 新增 / 扩展文本协议

```text
requestSavedFaces370
saveFaces370Json|JSON_LIST
selectFace370|index
deleteFace370Index|index
moveFace370|from|to
lockFace370|index|0_or_1
typeFace370|index|custom_or_part
renameFace370Index|index|new_name
updateFace370|index|name|type|locked
```

## 仍然保留在浏览器中的部分

音频/视频文件本身仍由浏览器播放；Pico 固件只负责 370 LED 时间轴播放。原因是 Pico MicroPython 固件没有浏览器式音视频解码/播放栈。

## 修改文件

- `pico_firmware/saved_faces_370.py`
- `pico_firmware/main.py`
- `pico_firmware/rina_protocol.py`
- `webui/rina_webui_stable_1_5_2.js`
- `webui/index.html`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
