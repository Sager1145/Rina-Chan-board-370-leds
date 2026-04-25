# 1.4.5-preview-timeline-scrollfix

## 修复内容

- 表情部件页面重新加入 22×18 真实 Matrix shape 的组合预览。
- 表情部件选择下拉、随机组合、载入保存表情后，预览会跟随当前 370 矩阵内容刷新。
- Unity 语音 / 歌曲 / 影像时间轴播放改为按旧 16×18 脸坐标整体偏移到 22×18 物理矩阵中心：row + 1, col + 2。
- Unity 时间轴预览与实际发送到 Pico 的 `M370:` 数据使用同一套居中映射，避免左侧/上侧裁切。
- 重写滚动文字 / AsciiDb 的开始、停止逻辑，停止按钮同时清除旧版闭包计时器、全局计时器和新版计时器。
- 滚动文字预览和发送都统一使用 370 真实物理矩阵 `M370:` 格式。

## 重新生成

- `webui/index.html`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
