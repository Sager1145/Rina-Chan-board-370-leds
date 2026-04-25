# RinaChanBoard 1.5.1-web-stable-clean

## 修复目标

- 修复网页崩溃、卡死、加载后反复刷新问题。
- 整理 Web UI 运行时代码，删除旧版本逐层叠加的补丁脚本。
- 保留 1.5.0 的表情部件整体下移 1 行 LED 和 Unity 18×16 居中到 22×18 行为。

## 主要修改

1. 删除旧运行时脚本：`matrixshape-script`、`uifix-1-3-5`、`websync-1-3-6`、`colorsync-1-3-7`、`savedparts-*`、`customsave-*`、`mediaunify-1-4-1`、`tab-nav-clickfix-*`、旧 `rina-stable-clean-1-4-9`。
2. 新增单一稳定模块：`webui/rina_webui_stable_1_5_1.js`。
3. 取消旧补丁中的自动延迟 `autoSyncAll()` 与多重 DOM/预览刷新计时器，避免浏览器不断请求和卡死。
4. 顶栏导航、UI lock、滚动文字、Unity 媒体、保存列表、表情部件预览、亮度同步、电池显示由单一模块统一接管。
5. 修复保存/重命名时取消弹窗仍会写入 `custom` 的问题。

## 保留功能

- 表情部件完整预览在页面顶部。
- 表情部件 M370 预览/上传整体下移 1 行：`row+2 / col+2`。
- Unity 原版时间轴按 18×16 居中到 22×18：`row+1 / col+2`。
- Unity 播放时间条显示 `分:秒 / 分:秒`。
- 默认保存表情禁止删除，但可重命名。
- 自定义 370 LED 编辑器不被表情部件预览、滚动文字、Unity 预览覆盖。
