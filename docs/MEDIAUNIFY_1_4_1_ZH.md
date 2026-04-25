# v1.4.1 MEDIAUNIFY

## 本版改动

- 自定义表情页面和表情部件页面继续共用同一个保存列表：`rina_custom_faces_matrix370_v2`。
- 首页状态同步保留 version/color/bright/battery 显示，但去掉 face 矩阵预览。
- 去掉自定义表情页面的 370 Matrix 大预览；保留自定义表情编辑器本身。
- Unity 语音、歌曲、影像合并到一个“Unity媒体”页面。
- Unity媒体页面新增与滚动文字页面相同的真实 370 Matrix shape 预览。
- Unity媒体页面支持 VoiceTimeLineDb、MusicTimeLineDb、VideoTimeLineDb，支持本地媒体文件、URL、静默时间轴同步、Loop。
- 按钮模式和 Web 模式继续使用同一 Pico 保存表情列表：B1/B2 与 A/M 循环的对象和 Web 保存/删除/载入的对象一致。

## 按钮/Web 模式融合检查

- Web 保存：写入浏览器 localStorage，并通过 `saveFace370|name|M370:<93 hex>` 同步到 Pico。
- Web 删除：通过 `deleteFace370|name` 同步到 Pico。
- Pico B1/B2：在 Pico 保存表情列表中前后循环。
- Pico A/M：自动/手动循环同一个保存表情列表。
- Web 载入：可从同一个保存列表载入到自定义表情/表情部件页面。
