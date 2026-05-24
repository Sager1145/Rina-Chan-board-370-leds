# 6.4 帧率控件 card 边缘对齐 v3 修复报告

## 问题

`class="field scroll-fps-control"` 内部虽然已经设置了全宽和 grid，但在实际页面里，`-5 / +5` 按钮、滑动条和数字输入框仍可能只对齐到内部 field/subdiv 的右边缘，而不是整张 `文字滚动控制` card 的内容边缘。

## 根本修复

本次不再只修 `.scroll-fps-control` 自身，而是给文字滚动控制 card 增加专用 class：

```html
<div class="card stack scroll-control-card">
```

并把这张 card 明确设为单列全宽 grid：

```css
#page-scroll .scroll-control-card {
  display: grid !important;
  grid-template-columns: minmax(0, 1fr) !important;
  justify-items: stretch !important;
  align-items: stretch !important;
  width: 100% !important;
  max-width: 100% !important;
  min-width: 0 !important;
  overflow-x: visible !important;
  box-sizing: border-box !important;
}
```

同时强制 `.scroll-fps-control`、按钮行、滑条行全部拉满同一条 card 内容轨道。

## 结果

- `重置默认帧率` 位于左侧。
- `-5 / +5` 的右边缘对齐到文字滚动控制 card 的内容右边缘。
- `scroll-speed` 数字输入框右边缘与 `+5` 按钮右边缘一致。
- `scroll-speed-range` 滑条宽度填满 card 可用内容宽度。
- 不再依赖 `.field.scroll-fps-control` 自己推导宽度。

## 同步文件

- `data/index.html`
- `data/index.html.gz`
- `data/styles.css`
- `data/styles.css.gz`
- `plan.md`
