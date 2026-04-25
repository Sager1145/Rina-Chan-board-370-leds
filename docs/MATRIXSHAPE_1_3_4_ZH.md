# v1.3.4 MATRIXSHAPE 修复说明

## 改动

- WebUI 自定义表情页面从原来的 16×18 编辑器改为真实 370 LED 物理矩阵编辑器。
- Matrix shape: `18 / 20*3 / 22*9 / 20*3 / 18 / 16`。
- 虚拟 22×18 网格中不存在的 LED 点位会隐藏，不能点击，也不会被编码发送。
- 真实 LED 显示为 18×18 px 圆角正方形。
- 点击真实 LED：开 / 关。
- `Matrix370 Hex` 使用 `M370:` + 93 位 hex，编码顺序为每一行只包含真实 LED 的 row-major 顺序。
- 仍兼容原版 72 位 16×18 hex：载入时自动居中到 370 LED 真实矩阵。
- “按原版 36-byte 二进制上传”会从当前 370 矩阵中抽取居中的 16×18 legacy 区域发送。

## Pico 协议扩展

新增文本命令：

```text
M370:<93 hex>
requestFace370
```

`requestState` 新增字段：

```json
"face370": "M370:<93 hex>"
```

原版命令仍保留：

```text
requestFace
72-char legacy face hex
36-byte binary Face_Full
```
