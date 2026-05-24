# 6.4 帧率 fps card 外框右边缘对齐最终修复报告

## 修改目标

用户要求 `class="field scroll-fps-control"` 内部的右对齐目标不是 `button-row` / subdiv 的最右端，而是独立 card：

```html
<div class="card stack scroll-fps-card">
```

的右边框。

## 已修改文件

- `data/index.html`
- `data/index.html.gz`
- `data/styles.css`
- `data/styles.css.gz`
- `plan.md`
- `SCROLL_FPS_CARD_BORDER_ALIGNMENT_FINAL_REPORT.md`

## 关键修复

`.card` 的默认 padding 是 `15px`。如果只设置 `.scroll-fps-control { width: 100%; }`，右侧按钮最多只能对齐到 card 内容区右边缘，仍然离 card 外框右边缘有 `15px`。

本次最终修复使用：

```css
#page-scroll .scroll-fps-card > .field.scroll-fps-control {
  width: calc(100% + (var(--scroll-fps-card-edge-padding) * 2)) !important;
  margin-left: calc(-1 * var(--scroll-fps-card-edge-padding)) !important;
  margin-right: calc(-1 * var(--scroll-fps-card-edge-padding)) !important;
}
```

其中：

```css
--scroll-fps-card-edge-padding: 15px;
```

因此 `−5`、`+5` 和 `#scroll-speed` 数字输入框的右边缘会对齐到 `scroll-fps-card` 的 card 外框右边缘。

## 其它同步修复

- 删除了滚动文字输入 textarea 上方重复的 `滚动文字输入` label。
- `index.html.gz`、`styles.css.gz` 已重新生成。

## 上传命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```
