# WebUI Hardware Control Fix 1.5.8

## 修复的问题

Pico 端 MicroPython 运行时不支持 `str.zfill()`，导致接收 WebUI 发来的 `M370:`、保存表情、Unity timeline 帧时在 `rina_protocol.update_physical_face_hex()` 抛出：

```text
'str' object has no attribute 'zfill'
```

结果表现为网页可以连接 ESP bridge，但发到 Pico 的绘制命令失败，硬件 LED 不变化。

## 修复方式

将 4-bit nibble 字符串补零逻辑从：

```python
bin(int(h, 16))[2:].zfill(4)
```

改为 Pico 兼容的固定查表：

```python
_NIBBLE_BITS[int(h, 16)]
```

这样不依赖 CPython-only / 非 MicroPython 子集的字符串方法。

## 已验证

- `M370:` 370 LED 物理帧解析
- `selectFace370|index` 保存表情选择
- `timeline370Begin / timeline370Chunk / timeline370Play` 固件侧时间轴播放
- `scrollText370|speed|text` 固件侧滚动文字
- Python 语法检查
- JavaScript 语法检查
- gzip WebUI 文件完整性
- ZIP 完整性
