# 按钮 LED 动画重建规格（指定规格版：无 IP 滚动、无电池时间页）

本文件用于让另一个 Agent 仅根据本文档重建按钮 LED overlay / animation 行为。本文保留旧固件的动画结构、bitmap、颜色和刷新节奏，但按当前需求覆盖亮度数值规格，并删除 IP 滚动与电池时间页。范围只包含：

- 亮度加减 overlay
- auto interval 加减 overlay
- M/A 切换 overlay
- B6 电池页面与充电动画：百分比、电池电压、充电输入电压；不包含使用时间 / 充电时间页

明确排除：IP/SSID 滚动、默认表情、固定 saved face 示例、BadApple、matrix demo、WebUI 图片切换动画、电池使用时间页、电池充电时间页。

## 0. 对当前 MD 的一致性检查结论

原文件 `button_animation_source_exact_no_ip.md` 仍然包含旧源码的亮度百分比模型和电池时间页。按当前需求，必须做以下覆盖：

| 项目 | 旧文件写法 | 当前指定规格 | 本文件处理 |
|---|---|---|---|
| B4/B5 亮度步进 | `±5` UI 百分比 | raw brightness `±8` | 已改为每次 `8 / 255` 原始亮度步进 |
| 亮度范围 | `5..100%` UI 百分比，再映射到 cap `0..170` | raw brightness `0..200`；`0/255 = 0%`，`200/255 = 100%` | 已改为 clamp `0..200`，显示百分比 `round(raw * 100 / 200)` |
| B4/B5 方向 | 源码中 B4 加、B5 减 | 按新按钮表：B4 减，B5 加 | 已改为 B4 `-8`，B5 `+8` |
| IP/SSID 滚动 | 已排除 | 继续排除 | 不包含 `_SCROLL_FONT` / `render_scrolling_text_window` / `check_ip_combo` |
| 电池使用时间 / 充电时间 | 长按电池循环中包含时间页 | 删除全部使用时间和充电时间动画 | 非充电只循环百分比 / 电池电压；充电循环百分比 / 电池电压 / 充电输入电压 |

> 说明：本文不是旧源码逐字复刻版，而是“旧源码动画资源 + 当前指定按钮/亮度/电池页面规格”的重建规格。Agent 应以本文为准。

## 1. 硬件与全局显示基础

| 项目 | 值 |
|---|---:|
| LED data GPIO | `GPIO2` |
| LED 数量 | `370` |
| 逻辑画布 | `22 × 18` |
| `COLS` | `22` |
| `ROWS` | `18` |
| 行长度 `ROW_LENGTHS` | `[18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16]` |
| 走线 | serpentine，奇数行反向 |
| `FLIP_X` / `FLIP_Y` | `False` / `False` |
| 主循环/渲染调度 | Core 0 `loop()` 约每 `1 ms` 服务按钮、电源、队列与自动播放；Core 1 LED render task 约每 `1 ms` 等待唤醒/滚动步进 |

### 1.1 逻辑坐标到 LED index

```python
def logical_to_led_index(x, y):
    if x < 0 or x >= 22 or y < 0 or y >= 18:
        return None

    row_width = ROW_LENGTHS[y]
    left_pad = (22 - row_width) // 2
    if x < left_pad or x >= left_pad + row_width:
        return None

    local_x = x - left_pad
    if y % 2 == 1:               # SERPENTINE
        local_x = row_width - 1 - local_x

    return ROW_STARTS[y] + local_x
```

### 1.2 有效 LED mask

```text
row 00: ..##################..
row 01: .####################.
row 02: .####################.
row 03: .####################.
row 04: ######################
row 05: ######################
row 06: ######################
row 07: ######################
row 08: ######################
row 09: ######################
row 10: ######################
row 11: ######################
row 12: ######################
row 13: .####################.
row 14: .####################.
row 15: .####################.
row 16: ..##################..
row 17: ...################...
```

### 1.3 亮度缩放与百分比显示

本文使用 raw brightness 作为 LED 通道上限。raw brightness 范围为 `0..200`。

- `0 / 255` 定义为显示 `0%`。
- `200 / 255` 定义为显示 `100%`。
- `201..255` 不作为按钮亮度范围使用。

显示百分比：

```python
def brightness_raw_to_percent(raw):
    raw = max(0, min(200, int(raw)))
    return int(round(raw * 100 / 200))
```

所有 overlay 颜色在写入 LED 前都经过 `scale_color(rgb)`，其中 `MAX_BRIGHTNESS = brightness_raw`：

```python
def scale_color(rgb):
    r, g, b = rgb
    m = max(r, g, b)
    cap = max(0, min(200, int(MAX_BRIGHTNESS)))
    if m <= cap:
        return (clamp(r,0,255), clamp(g,0,255), clamp(b,0,255))
    if cap <= 0:
        return (0, 0, 0)
    s = cap / m
    return (int(r * s), int(g * s), int(b * s))
```

注意：`scale_color()` 是 peak limiter / ceiling cap，不是全局亮度乘法。若输入颜色最大通道 `m <= brightness_raw`，颜色原样保留；只有当某个通道超过当前 brightness cap 时，才按比例压低到 cap。不要把它实现成 `rgb * brightness_raw / 200`，除非刻意改变旧固件的视觉语义。

示例：`raw=0 -> 0%`，`raw=8 -> 4%`，`raw=40 -> 20%`，`raw=100 -> 50%`，`raw=200 -> 100%`。

## 2. 按钮输入、组合键、repeat 参数

| 名称 | GPIO | 源码注释 / 用途 |
|---|---:|---|
| B1 / `BTN_PREV` | `17` | previous face；B3 held 时 interval 减少 |
| B2 / `BTN_NEXT` | `16` | next face；B3 held 时 interval 增加 |
| B3 / `BTN_AUTO` | `15` | A/M toggle；组合键 modifier |
| B4 / `BTN_BRIGHT_DN` | `40` | 当前规格：raw brightness `-8` |
| B5 / `BTN_BRIGHT_UP` | `41` | 当前规格：raw brightness `+8` |
| B6 / `BTN_BRIGHT_RST` | `42` | 电池短显/长显；B4+B5 reset 逻辑在本目标范围外 |

| 参数 | 值 |
|---|---:|
| active level | active-low，按下为 `0` |
| debounce | `25 ms` |
| autorepeat buttons | B1, B2, B4, B5 |
| repeat initial delay | `400 ms` |
| repeat period | `140 ms` |
| B3 repeat | 无 |
| B6 repeat | 无 |

### 2.1 本文件范围内的按钮行为

| 输入 | 触发时机 | 源程序行为 | 对应 LED overlay / animation |
|---|---|---|---|
| B3 | 松开触发，且未被组合键消费 | `auto = not old_auto` | 显示大号 `A` 或 `M`，紫色，保持 1000ms |
| B3+B1 | 按住 B3 后按 B1；repeat 也生效 | `interval_s -= 0.5`，clamp 到 `0.5s` | 显示 `x.xS` + clock icon，紫色；到下限时 bottom edge flash |
| B3+B2 | 按住 B3 后按 B2；repeat 也生效 | `interval_s += 0.5`，clamp 到 `10.0s` | 显示 `x.xS` 或 `10S` + clock icon，紫色；到上限时 top edge flash |
| B4 | 按下立即；repeat 也生效 | `brightness_raw -= 8`，clamp 到 `0` | 显示 `NN%` + sun icon，蓝色；到下限时 bottom edge flash |
| B5 | 按下立即；repeat 也生效 | `brightness_raw += 8`，clamp 到 `200` | 显示 `NN%` + sun icon，蓝色；到上限时 top edge flash |
| B6 短按 | B6 按下后在 700ms 前释放 | 显示电池百分比 | `BATTERY_ICON + NN%`，2000ms，不播放充电 sweep |
| B6 长按 | B6 按住达到 700ms | 进入电池详细循环 | 非充电：百分比 / 电池电压；充电：百分比 / 电池电压 / 充电输入电压，并播放充电动画 |

### 2.2 排除项

不得实现以下内容：

- IP/SSID 滚动显示
- `_SCROLL_FONT`
- `render_scrolling_text_window()`
- `check_ip_combo()` / B2+B6 IP 组合键
- 默认表情 bitmap / 默认 saved face 示例

## 3. overlay 通用生命周期

| 参数 | 值 |
|---|---:|
| `FLASH_HOLD_MS` | `1000 ms` |
| overlay types | `mode`, `interval`, `brightness` |
| 电池 overlay 是否使用 `FLASH_HOLD_MS` | 否，电池使用自己的 active/expires/phase 状态 |

### 3.1 普通 overlay 启动

亮度、interval、M/A 都调用等价逻辑：

```python
flash_active = True
flash_kind = kind
flash_value = value
flash_expires_ms = now + 1000
```

### 3.2 普通 overlay 到期

每个主循环 tick 检查：

```python
if flash_active and now >= flash_expires_ms:
    flash_active = False
    flash_kind = None
    flash_value = None
    render_current_visual(force=True)   # 恢复当前 face
```

如果 `battery_display_active == True`，不会执行普通 flash 到期恢复逻辑。

## 4. 颜色常量

| 名称 | RGB | Hex | 用途 |
|---|---:|---:|---|
| `BRIGHTNESS_COLOR` | `(0, 120, 255)` | `#0078FF` | 亮度百分比、太阳图标 |
| `MODE_COLOR` | `(180, 0, 255)` | `#B400FF` | M/A、interval、clock icon、interval edge flash |
| `EDGE_FLASH_COLOR` | `(0, 120, 255)` | `#0078FF` | 亮度 clamp edge flash |
| `DEFAULT_COLOR` | `(0, 120, 255)` | `#0078FF` | 默认数字/电池 fallback |
| charge-voltage text | `(255, 255, 255)` | `#FFFFFF` | 充电输入电压页面文字 |
| battery fallback | `(255, 0, 0)` | `#FF0000` | 电池百分比为空时显示 `0%` |

## 5. 字符、图标、bitmap 资源

### 5.1 7×5 / 特殊字符 glyph

这些 glyph 被亮度、interval、电池数字页共用。`_render_string()` 字符间隔为 1 列；带图标时文字 y 起点为 `9`，无图标时文字 y 起点为 `(18 - 7)//2 = 5`。

### `_FONT[0]`

```text
.###.
#...#
#..##
#.#.#
##..#
#...#
.###.
```

### `_FONT[1]`

```text
.##..
#.#..
..#..
..#..
..#..
..#..
#####
```

### `_FONT[2]`

```text
.###.
#...#
....#
...#.
..#..
.#...
#####
```

### `_FONT[3]`

```text
####.
....#
....#
.###.
....#
....#
####.
```

### `_FONT[4]`

```text
...#.
..##.
.#.#.
#..#.
#####
...#.
...#.
```

### `_FONT[5]`

```text
#####
#....
####.
....#
....#
#...#
.###.
```

### `_FONT[6]`

```text
.###.
#...#
#....
####.
#...#
#...#
.###.
```

### `_FONT[7]`

```text
#####
....#
...#.
..#..
.#...
.#...
.#...
```

### `_FONT[8]`

```text
.###.
#...#
#...#
.###.
#...#
#...#
.###.
```

### `_FONT[9]`

```text
.###.
#...#
#...#
.####
....#
#...#
.###.
```


### `_FONT[S]`

```text
.####
#....
#....
.###.
....#
....#
####.
```

### `_FONT[V]`

```text
#...#
#...#
#...#
.#.#.
.#.#.
..#..
..#..
```

### `_DOT`

```text
.
.
.
.
.
.
#
```

### `_PCT_3`

```text
#.#
..#
.#.
.#.
#..
#.#
...
```


### 5.2 `CLOCK_ICON` 22×18

```text
......................
.........####.........
........#...##........
........#..#.#........
........#....#........
........#....#........
.........####.........
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### 5.3 `SUN_ICON_1` 22×18

源码 `_sun_icon_rows(percent)` 始终返回 `SUN_ICON_1`。`SUN_ICON_2` / `SUN_ICON_3` 在当前源码中不会被亮度 overlay 使用。

```text
......................
.......#......#.##....
....##.#......#.......
........#....#........
.........####..#......
.......#........#.....
......#....#..........
...........#..........
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### 5.4 `_BIG_A` 原始 10×13 bitmap

```text
...####...
..######..
.##....##.
.##....##.
.##....##.
.##....##.
.########.
.########.
.##....##.
.##....##.
.##....##.
.##....##.
.##....##.
```

### 5.5 `_BIG_M` 原始 10×13 bitmap

```text
##......##
###....###
####..####
##.####.##
##..##..##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
```

### 5.6 `_BIG_A` 居中到 22×18 后的实际画面

```text
......................
......................
.........####.........
........######........
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
.......########.......
.......########.......
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
.......##....##.......
......................
......................
......................
```

### 5.7 `_BIG_M` 居中到 22×18 后的实际画面

```text
......................
......................
......##......##......
......###....###......
......####..####......
......##.####.##......
......##..##..##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......##......##......
......................
......................
......................
```

### 5.8 `BATTERY_ICON` 基础 22×18 bitmap

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

## 6. `_render_string()` 精确布局规则

所有 `NN%`、`x.xS`、`N.NV`、`NM`、`N.NH`、`N.N` 页面都使用同一个文本布局规则。

```python
gap = 1
glyphs = [_glyph_for(ch) for ch in text]
total_w = sum(width(g) for g in glyphs) + gap * (len(glyphs) - 1)
x0 = (22 - total_w) // 2
y0 = 9 if icon_rows is not None else 5
```

绘制流程：

1. `clear()` 清空整个 LED buffer。
2. 如果有 icon：从 `(x0=0, y0=0)` 绘制完整 22×18 icon bitmap。
3. 文本使用 `color` 绘制到 `(x0, y0)`。
4. 每个字符之间空 1 列。
5. 任何落在无效物理 LED 位置的像素由 `logical_to_led_index()` 丢弃。
6. 绘制完成后 `show()`。

## 7. M/A overlay 完整逻辑

### 7.1 触发

B3 按下时不切换；B3 释放时切换。B3 如果被组合键消费，则释放时不切换。

```python
# Persistent button state.
b3_consumed_by_combo = False

# On B3 press.
b3_consumed_by_combo = False

# On B3+B1 or B3+B2 interval action, including repeat.
b3_consumed_by_combo = True

# On B3 release.
if not b3_consumed_by_combo:
    old_auto = bool(state.auto)
    state.auto = not old_auto
    render_mode(state.auto)
    start_or_extend_flash("mode", state.auto)

b3_consumed_by_combo = False
```

### 7.2 显示

| auto 状态 | glyph | 颜色 | 持续 |
|---|---|---|---:|
| `True` | `_BIG_A` | `MODE_COLOR #B400FF` | `1000 ms` |
| `False` | `_BIG_M` | `MODE_COLOR #B400FF` | `1000 ms` |

位置：

```python
x0 = (22 - 10) // 2 = 6
y0 = (18 - 13) // 2 = 2
```

## 8. interval overlay 完整逻辑

### 8.1 参数

| 参数 | 值 |
|---|---:|
| 默认 interval | `1.0 s` |
| 步进 | `0.5 s` |
| 最小值 | `0.5 s` |
| 最大值 | `10.0 s` |
| overlay hold | `1000 ms` |
| 颜色 | `MODE_COLOR #B400FF` |

### 8.2 按钮方向

```python
# B3 held + B1
interval_s = clamp_interval(interval_s - 0.5)

# B3 held + B2
interval_s = clamp_interval(interval_s + 0.5)
```

### 8.3 clamp

```python
if value < 0.5:
    value = 0.5
elif value > 10.0:
    value = 10.0
value = round(value * 10) / 10.0
```

### 8.4 文本格式

```python
tenths = int(round(seconds * 10))
whole = tenths // 10
frac = tenths % 10
text = "10" if whole == 10 and frac == 0 else f"{whole}.{frac}"
render_text = text + "S"
```

例：

| interval | text |
|---:|---|
| `0.5` | `0.5S` |
| `1.0` | `1.0S` |
| `9.5` | `9.5S` |
| `10.0` | `10S` |

### 8.5 渲染

```python
render_interval(interval_s):
    _render_string(format_interval(interval_s) + "S", MODE_COLOR, icon_rows=CLOCK_ICON)
```

### 8.6 interval clamp edge flash

| 条件 | edge | 颜色 |
|---|---|---|
| B3+B1 继续减少且已到 `0.5s` | bottom row `y=17` | `MODE_COLOR #B400FF` |
| B3+B2 继续增加且已到 `10.0s` | top row `y=0` | `MODE_COLOR #B400FF` |

源码在 `adjust_interval()` 中先 `render_interval()`，再 `start_or_extend_flash("interval")`，最后执行一次 `overlay_edge_flash()`，主循环后续会继续叠加 edge flash 直到 305ms 结束。

## 9. brightness overlay 完整逻辑

### 9.1 参数

| 参数 | 值 |
|---|---:|
| brightness 存储单位 | raw LED brightness / channel cap |
| 默认 raw brightness | `60`，显示为 `30%` |
| 步进 | `8` raw units |
| 最小 raw brightness | `0`，显示为 `0%` |
| 最大 raw brightness | `200`，显示为 `100%` |
| LED 通道理论满量程 | `255` |
| overlay hold | `1000 ms` |
| 颜色 | `BRIGHTNESS_COLOR #0078FF` |

### 9.2 按钮方向

```python
# B4 / GPIO40 / BTN_BRIGHT_DN
brightness_raw = clamp_brightness_raw(brightness_raw - 8)

# B5 / GPIO41 / BTN_BRIGHT_UP
brightness_raw = clamp_brightness_raw(brightness_raw + 8)
```

### 9.3 clamp 与百分比换算

```python
def clamp_brightness_raw(value):
    if value < 0:
        return 0
    if value > 200:
        return 200
    return int(value)

def brightness_raw_to_percent(raw):
    raw = clamp_brightness_raw(raw)
    return int(round(raw * 100 / 200))
```

显示关系：

| raw brightness | 对应 LED 通道比例 | 显示百分比 |
|---:|---:|---:|
| `0` | `0 / 255` | `0%` |
| `8` | `8 / 255` | `4%` |
| `40` | `40 / 255` | `20%` |
| `100` | `100 / 255` | `50%` |
| `160` | `160 / 255` | `80%` |
| `200` | `200 / 255` | `100%` |

### 9.4 渲染

```python
def render_brightness_raw(raw):
    percent = brightness_raw_to_percent(raw)
    _render_string(str(int(percent)) + "%", BRIGHTNESS_COLOR, icon_rows=SUN_ICON_1)
```

显示内容永远是百分比文字，不直接显示 raw brightness。

### 9.5 brightness clamp edge flash

| 条件 | edge | 颜色 |
|---|---|---|
| B4 继续降低且已到 raw `0` | bottom row `y=17` | `EDGE_FLASH_COLOR #0078FF` |
| B5 继续升高且已到 raw `200` | top row `y=0` | `EDGE_FLASH_COLOR #0078FF` |

执行顺序：

```python
apply_brightness_raw()
render_brightness_raw(brightness_raw)
start_or_extend_flash("brightness", brightness_raw)
overlay_edge_flash_if_clamped()
```

`start_or_extend_flash("brightness", brightness_raw)` 必须先于 `overlay_edge_flash_if_clamped()` 执行，使触发 tick 的首帧也拥有正确的 `flash_kind`。brightness clamp 使用 `EDGE_FLASH_COLOR`；interval clamp 使用 `MODE_COLOR`，同样必须先设置 `flash_kind = "interval"` 再叠加 edge flash。

## 10. edge flash 完整动画逻辑

edge flash 用于 brightness / interval 到达 clamp 边界时的顶边/底边反馈。它不是独立 bitmap，而是在当前 overlay 上叠加一条渐变边缘。

| 参数 | 值 |
|---|---:|
| attack | `45 ms` |
| decay | `260 ms` |
| total | `305 ms` |
| top edge row | `y = 0` |
| bottom edge row | `y = 17` |
| x center | `(22 - 1) / 2 = 10.5` |
| max distance | `10.5` |
| minimum spatial factor | `0.20` |

### 10.1 时间 envelope

```python
if elapsed_ms < 0 or elapsed_ms > 305:
    factor = 0.0
elif elapsed_ms <= 45:
    factor = elapsed_ms / 45.0
else:
    t = (elapsed_ms - 45) / 260.0
    factor = 1.0 - t
```

### 10.2 空间 envelope

```python
for x in range(22):
    dist = abs(x - 10.5)
    spatial = 1.0 - (dist / 10.5)
    if spatial < 0.20:
        spatial = 0.20
    level = factor * spatial
```

### 10.3 颜色合成

```python
flash_color = MODE_COLOR if flash_kind == "interval" else EDGE_FLASH_COLOR
pixel_rgb = scale_color((
    int(flash_color[0] * level),
    int(flash_color[1] * level),
    int(flash_color[2] * level),
))
```

只对 `logical_to_led_index(x, y) != None` 的有效 LED 写入。

### 10.4 edge 有效行 mask

```text
top y=0:    ..##################..
bottom y=17:...################...
```

## 11. B6 电池页面与充电动画完整逻辑

### 11.1 B6 短按

| 项目 | 值 |
|---|---:|
| 长按阈值 | `700 ms` |
| 短显持续 | `2000 ms` |
| phase count | `1` |
| phase index | `0` |
| 页面 | `percent_short` |
| 充电 sweep | 禁用，即使当前正在充电 |
| 到期行为 | `stop_battery_display()`，恢复当前 face |

启动逻辑：

```python
battery_display_active = True
battery_display_single_shot = True
flash_active = False
battery_next_refresh_ms = 0
battery_visual_next_refresh_ms = 0
refresh_battery_overlay_cache(force=True)
battery_display_toggle_started_ms = now
battery_display_phase_index = 0
battery_display_phase_count = 1
battery_display_next_phase_ms = 0
battery_display_expires_ms = now + 2000
render_battery_overlay(refresh_phase=False, refresh_cache=False)
```

### 11.2 B6 长按

B6 按住达到 700ms，并且 B3 / B2 未按住时，进入长显。

| 项目 | 非充电 | 充电 |
|---|---:|---:|
| phase count | `2` | `3` |
| phase 0 | 百分比 `NN%` | 百分比 `NN%` |
| phase 1 | 电池电压 `N.NV` | 电池电压 `N.NV` |
| phase 2 | 不存在 | 充电输入电压 `N.N` |
| phase 切换周期 | `2000 ms` | `2000 ms` |
| 充电动画刷新 | 无 | 每 `50 ms` 尝试重绘 |

启动逻辑：

```python
b6_long_fired = True
battery_display_active = True
flash_active = False
flash_kind = None
flash_value = None
battery_next_refresh_ms = 0
battery_visual_next_refresh_ms = 0
refresh_battery_overlay_cache(force=True)
battery_display_toggle_started_ms = now
battery_display_phase_index = 0
battery_display_phase_count = 3 if cached_is_charging else 2
battery_display_next_phase_ms = now + 2000
render_battery_overlay(refresh_phase=False, refresh_cache=False)
```

释放 B6：如果 `battery_display_active` 或 `b6_long_fired`，调用 `stop_battery_display()`，立即恢复当前 face。

### 11.3 电池页面刷新调度

| 参数 | 值 |
|---|---:|
| 电池显示缓存刷新周期 | `100 ms` |
| 动画视觉刷新周期 | `50 ms` |
| 平均窗口 | `1000 ms` |
| 平均窗口采样间隔 | `20 ms` |
| 校准/历史日志周期 | `30000 ms` |

长显 active 时，每个主循环 tick 执行：

```python
cache_due = now >= battery_next_refresh_ms
visual_due = now >= battery_visual_next_refresh_ms
phase_due = now >= battery_display_next_phase_ms

instant_charge_v = read_charge_voltage()
charging_instant = is_charging_voltage(instant_charge_v, previous=cached_is_charging)
if charging_instant != cached_is_charging:
    cache_due = True

if cache_due:
    cache_changed = refresh_battery_overlay_cache(force=charge_state_flipped)

if phase_due:
    update_battery_display_phase()

animate_due = cached_is_charging and visual_due

if cache_changed or phase_changed or animate_due:
    render_battery_overlay(refresh_phase=False, refresh_cache=False)
    battery_visual_next_refresh_ms = now + 50
```

短显 active 时：

- 先检查 `now >= battery_display_expires_ms`，到期则停止显示。
- 每个 tick 都读一次 instant charge ADC。
- 若充电状态改变，强制刷新缓存并重绘。
- 不做 phase 切换，不做 charging sweep 动画。

### 11.4 充电状态判定

| 项目 | 值 |
|---|---:|
| 充电检测 GPIO | `GPIO1` |
| ADC 参考 | `3.3 V` |
| 单次采样数 | `16` |
| R1 | `270000 Ω` |
| R2 | `47000 Ω` |
| 进入充电 | `Vcharge > 4.0 V` |
| 退出充电 | `Vcharge <= 3.0 V` |
| 中间区 | 保持 previous 状态 |

```python
Vcharge = Vadc * (270000 + 47000) / 47000
```

```python
def is_charging_voltage(charge_v, previous=False):
    if charge_v is None:
        return bool(previous)
    if charge_v > 4.0:
        return True
    if charge_v <= 3.0:
        return False
    return bool(previous)
```

当充电状态变化时：

```python
target_phase_count = 3 if charging else 2
if battery_display_phase_count != target_phase_count:
    battery_display_phase_count = target_phase_count
    battery_display_phase_index = 0
    battery_display_toggle_started_ms = now
    battery_display_next_phase_ms = now + 2000
```

## 12. 电池 ADC 与百分比换算

### 12.1 电池电压读取

| 项目 | 值 |
|---|---:|
| 电池 ADC GPIO | `GPIO10` |
| ADC 参考 | `3.3 V` |
| 单次采样数 | `16` |
| R1 | `100000 Ω` |
| R2 | `57000 Ω` |
| 固件校准 scale | `2.708333` |
| 固件校准 offset | `+0.2033 V` |

```python
instant_vbat = Vadc * 2.708333 + 0.2033
```

### 12.2 百分比换算

当前程序不再用 `min_v/max_v` 线性区间和 `0.12 V` 端点吸附计算百分比。电池百分比来自固定 2S LiPo 分段 LUT；`battery_calib.json` 的 `v_min/v_max` 仍保留给诊断和手动 reset API，但不参与百分比映射。

```python
BATTERY_PERCENT_LUT = [
    (8.40, 100),
    (8.10,  90),
    (7.90,  80),
    (7.70,  65),
    (7.50,  50),
    (7.30,  35),
    (7.10,  20),
    (6.80,  10),
    (6.50,   5),
    (6.20,   0),
]

def battery_percent_from_voltage(vbat):
    if not isfinite(vbat):
        return 0
    if vbat >= BATTERY_PERCENT_LUT[0][0]:
        return 100
    if vbat <= BATTERY_PERCENT_LUT[-1][0]:
        return 0
    for (v_hi, p_hi), (v_lo, p_lo) in adjacent_pairs(BATTERY_PERCENT_LUT):
        if vbat < v_hi and vbat >= v_lo:
            t = (vbat - v_lo) / (v_hi - v_lo)
            return round(p_lo + t * (p_hi - p_lo))
    return 0
```

采样显示值先经过基于真实时间间隔的 EMA。目标时间常数为 `20 s`：

```python
alpha = 1.0 - exp(-dt_s / 20.0)
vbat = previous_vbat * (1.0 - alpha) + instant_vbat * alpha
```

百分比整数带 `±1%` dead-band：只有首次有效读数，或 LUT 结果和当前显示值相差超过 1 个百分点时，才更新显示百分比。

```python
raw_percent = battery_percent_from_voltage(vbat)
if first_valid_reading or abs(raw_percent - battery_percent) > 1:
    battery_percent = raw_percent
```

### 12.3 已删除：使用时间 / 充电时间页

当前规格不实现任何使用时间或充电时间动画。Agent 不得实现以下内容：

- 剩余使用时间页。
- 充电完成时间页。
- `remaining_h` / `charge_time_h` 页面计算。
- `0M`、`1.5H`、`--` 等时间文本显示。

## 13. 电池颜色逻辑

```python
p = max(0, min(100, int(percent)))
if p <= 10:
    color = (255, 0, 0)
elif p <= 30:
    t = (p - 10) / 20.0
    color = (255, int(165 * t), 0)
elif p <= 50:
    t = (p - 30) / 20.0
    color = (int(255 * (1.0 - t)), int(165 + (90 * t)), 0)
else:
    color = (0, 255, 0)
```

| 百分比 | RGB | Hex |
|---:|---:|---:|
| 0 | `(255, 0, 0)` | `#FF0000` |
| 10 | `(255, 0, 0)` | `#FF0000` |
| 20 | `(255, 82, 0)` | `#FF5200` |
| 30 | `(255, 165, 0)` | `#FFA500` |
| 40 | `(127, 210, 0)` | `#7FD200` |
| 50 | `(0, 255, 0)` | `#00FF00` |
| 100 | `(0, 255, 0)` | `#00FF00` |

页面颜色：

| 页面 | 图标颜色 | 文字颜色 |
|---|---|---|
| 百分比 | battery color | battery color |
| 电池电压 | battery color | battery color |
| 充电输入电压 | battery color | white `#FFFFFF` |
| percent 为 `None` fallback | red `#FF0000` | red `#FF0000` |

## 14. 电池图标填充与充电动画

### 14.1 电池内部填充区域

| 项目 | 值 |
|---|---:|
| 内部填充行 | `y = 2, 3, 4` |
| 内部起始列 | `x = 7` |
| 内部列数 | `8` |
| 可填充列编号 | `0..7` |

### 14.2 非动画填充列

```python
p = max(0, min(100, int(percent)))
if p < 10:
    filled_cols = 0
elif p > 90:
    filled_cols = 8
else:
    filled_cols = ((p - 10) * 8 + 79) // 80
```

| percent 条件 | filled_cols |
|---|---:|
| `< 10` | `0` |
| `10..20` | `1` |
| `21..30` | `2` |
| `31..40` | `3` |
| `41..50` | `4` |
| `51..60` | `5` |
| `61..70` | `6` |
| `71..80` | `7` |
| `81..90` | `8` |
| `> 90` | `8` |

### 14.3 非动画填充 bitmap 帧

### `BATTERY_FILL_0_COLS`

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_1_COLS`

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_2_COLS`

```text
......................
......#########.......
......###......#......
......###......#......
......###......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_3_COLS`

```text
......................
......#########.......
......####.....#......
......####.....#......
......####.....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_4_COLS`

```text
......................
......#########.......
......#####....#......
......#####....#......
......#####....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_5_COLS`

```text
......................
......#########.......
......######...#......
......######...#......
......######...#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_6_COLS`

```text
......................
......#########.......
......#######..#......
......#######..#......
......#######..#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_7_COLS`

```text
......................
......#########.......
......########.#......
......########.#......
......########.#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_FILL_8_COLS`

```text
......................
......#########.......
......##########......
......##########......
......##########......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```


### 14.4 充电动画规则

只有长显模式且 `charging == True` 时播放图标动画：

```python
animate_icon = (not battery_display_single_shot) and charging
```

短显模式永远：

```python
animate_icon = False
```

充电动画 phase time：

```python
charging_phase_ms = now - battery_display_toggle_started_ms
charge_step_interval_s = 0.2
```

#### A. `percent < 10`

低于 10% 时不 sweep，只闪烁第 1 个内部列：

```python
flash_period_ms = 300
on = ((charging_phase_ms // 300) % 2) == 0
lit_cols = 1 if on else 0
```

低电量充电闪烁 ON：

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

低电量充电闪烁 OFF：

```text
......................
......#########.......
......#........#......
......#........#......
......#........#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

#### B. `percent >= 10`

```python
filled_cols = _battery_fill_cols(percent)
target_cols = 8 if percent > 90 else max(1, filled_cols)
step_ms = int(0.2 * 1000)  # 200
anim_step = charging_phase_ms // step_ms
lit_cols = (anim_step % target_cols) + 1
```

这意味着：

- `10%..20%`：只显示 1 列，视觉上不移动。
- `21%..30%`：1 → 2 → 1 → 2。
- `31%..40%`：1 → 2 → 3 → 1 ...
- `>90%`：1 → 2 → ... → 8 → 1 ...

#### C. sweep bitmap 帧

### `BATTERY_CHARGE_SWEEP_1_COLS`

```text
......................
......#########.......
......##.......#......
......##.......#......
......##.......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_2_COLS`

```text
......................
......#########.......
......###......#......
......###......#......
......###......#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_3_COLS`

```text
......................
......#########.......
......####.....#......
......####.....#......
......####.....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_4_COLS`

```text
......................
......#########.......
......#####....#......
......#####....#......
......#####....#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_5_COLS`

```text
......................
......#########.......
......######...#......
......######...#......
......######...#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_6_COLS`

```text
......................
......#########.......
......#######..#......
......#######..#......
......#######..#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_7_COLS`

```text
......................
......#########.......
......########.#......
......########.#......
......########.#......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```

### `BATTERY_CHARGE_SWEEP_8_COLS`

```text
......................
......#########.......
......##########......
......##########......
......##########......
......#########.......
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
......................
```


### 14.5 源码中 `flash_last_column`

`render_battery_overlay()` 总是设置：

```python
flash_last_column = False
```

因此非充电状态下不会闪烁最后一列。`_battery_icon_rows()` 虽然支持 `flash_last_column`，但当前按钮电池页面不使用。

## 15. 电池页面 render 函数对应关系

### 15.1 百分比页

```python
render_battery_percent(
    pct,
    color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    animate=animate_icon,
)
```

文本：`f"{int(pct)}%"`

### 15.2 电池电压页

```python
render_battery_voltage(
    v_bat,
    percent=pct,
    color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    text_color=None,
    animate=animate_icon,
)
```

文本：

```python
if voltage is None:
    text = "0.0V"
else:
    text = "{:.1f}V".format(voltage)
```

特殊布局：

```python
char_extra_x = {3: 1}
```

也就是第 4 个字符额外右移 1 列，用于 `N.NV` 中的 `V`。


### 15.3 充电输入电压页

```python
render_charge_voltage(
    charge_v,
    percent=pct,
    icon_color=battery_color,
    charging=charging,
    charging_phase_ms=charging_phase_ms,
    charge_step_interval_s=0.2,
    flash_last_column=False,
    animate=animate_icon,
)
```

文本：

```python
text = "0.0" if charge_v is None else "{:.1f}".format(charge_v)
text_color = (255, 255, 255)
icon_color = battery_color
```

## 16. 实现校验清单

Agent 重建时必须满足：

- [ ] 不实现 IP/SSID 滚动，不包含 `_SCROLL_FONT`。
- [ ] B3 按下不切换，B3 释放才切换 A/M。
- [ ] B3 被 B1/B2 interval 组合键消费后，释放 B3 不切换 A/M。
- [ ] 普通 overlay 保持 1000ms，到期恢复当前 face。
- [ ] interval 使用 `MODE_COLOR #B400FF`，格式为 `0.5S` 到 `9.5S`，`10.0s` 显示为 `10S`。
- [ ] B3+B1 是 interval `-0.5s`，B3+B2 是 interval `+0.5s`。
- [ ] brightness 使用 `BRIGHTNESS_COLOR #0078FF`，显示 `round(raw * 100 / 200)%` + `SUN_ICON_1`。
- [ ] B4/GPIO40 是 raw brightness `-8`，B5/GPIO41 是 raw brightness `+8`，clamp 范围 `0..200`。
- [ ] 所有 B1/B2/B4/B5 repeat 都是先等 400ms，再每 140ms 触发一次。
- [ ] edge flash attack 45ms、decay 260ms，总 305ms，空间中心 10.5，最低空间强度 0.20。
- [ ] interval edge flash 用 `MODE_COLOR`，brightness edge flash 用 `EDGE_FLASH_COLOR`。
- [ ] B6 短按释放后显示电池百分比 2000ms，不播放 charging sweep。
- [ ] B6 长按 700ms 后进入电池循环；非充电 2 页，充电 3 页。
- [ ] 长显释放 B6 立即停止电池页面并恢复当前 face。
- [ ] 充电状态每个主循环 tick 读取 charge ADC 以快速切换动画状态。
- [ ] 充电图标动画每 50ms 尝试刷新，但 sweep 每 200ms 改变一列。
- [ ] `percent < 10` 充电时只闪烁第 1 列，300ms 半周期，不做 sweep。
- [ ] 充电输入电压页面文字固定白色，图标仍使用电池百分比颜色。
- [ ] 不实现电池使用时间页和充电时间页，不显示 `0M` / `1H` / `1.5H` / `--` 时间文本。
- [ ] 所有绘制都遵守 22×18 不规则矩阵 mask 和 serpentine 坐标映射。
