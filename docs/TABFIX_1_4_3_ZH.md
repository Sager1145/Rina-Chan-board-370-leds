# TABFIX 1.4.3

## 修复内容

- 修复顶栏所有 Tab 无法点击的问题。
- 新增独立的顶栏 Tab 绑定脚本，不依赖旧初始化流程是否成功。
- 顶栏按钮统一标记为 `lock-allowed`，避免播放 / 滚动锁定逻辑误拦截导航。
- `window.showTab` / `window.rinaShowTab` 可供后续脚本复用。
- 保留 1.4.2-webfix 的改动：Unity 媒体合并、共享自定义表情、移除旧入口和减少初始化跳动。

## 涉及文件

- `webui/index.html`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
