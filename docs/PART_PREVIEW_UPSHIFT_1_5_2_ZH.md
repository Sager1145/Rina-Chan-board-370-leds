# RinaChanBoard 1.5.2-part-preview-upshift

## 修改内容

- 表情部件完整预览和“上传当前组合”的 M370 输出整体上移 1 行 LED。
- 表情部件映射从 1.5.1 的 `row+2 / col+2` 改为 `row+1 / col+2`。
- Unity 语音 / 歌曲 / 影像时间轴不变，仍按原版 18×16 matrix 居中到 22×18 matrix：`row+1 / col+2`。
- 自定义 370 LED 编辑器仍与表情部件预览隔离。
- 继续使用单一稳定 Web 模块，避免旧补丁叠加导致崩溃。
