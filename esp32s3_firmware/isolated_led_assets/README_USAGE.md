# Isolated LED Assets for ESP32-S3 RinaChanBoard

本包把固件里所有会直接/间接写入 LED 的显示数据从程序逻辑中隔离出来。

## 目录

```text
esp32s3_firmware/
  isolated_led_assets/
    manifest.json                         # 人读索引，包含所有资产路径与来源
    manifest.min.json                     # ESP32 读取用紧凑索引
    README_RNT_FORMAT.txt                 # RNT2 时间轴格式说明
    resources/
      colors/*.rgb                        # 每个颜色一个 6 位 RGB hex 文件
      faces/default/*.m370                # 默认 faces，每个文件 93 hex 字符
      icons/*.rbitmap.json                # 图标源 bitmap
      icons/m370/*.m370                   # 可直接显示的 22x18 图标帧
      text/ascii_5x7/*.rbitmap.json       # 738NGX Unity ASCII 字库
      text/display_num_base_font/*.json   # 固件数字/状态字库
      text/scroll_font_5x7/*.json         # IP/SSID 滚动文字字库
      face_modules/**/*.json              # 738NGX FaceModuleDb 拆分后的眼/嘴/腮红部件
      legacy_flyakari_components/**/*.json# flyAkari/旧协议部件兼容资源
      voice/*.rnt                         # 语音口型/表情时间轴
      music/*.rnt                         # 歌曲时间轴
      video/*.rnt                         # 视频时间轴
```

## 格式选择

### `.m370`

最省 RAM 的单帧格式。文件内容只有：

```text
93_HEX_CHARS
```

- 370 个真实 LED bit，按 22x18 逻辑矩阵逐行扫描。
- 每行两侧不存在的补位 LED 不写入。
- 370 bit 需要 92.5 个 hex，因此保留 93 个 hex 字符，最后 2 bit 为 nibble 对齐填充。
- ESP32 读取时只需要 `readline()`，不需要 JSON 解析。

### `.rnt`

RNT2 时间轴格式，用于 Unity voice/music/video。

```text
RNT2|kind=voice|key=voice_0|fps=30|count=9|last=24|format=hex370
# start_frame|hold_frames|hold_ms|m370_hex
3|1|33|...
```

ESP32 应逐行读取，不要一次性把整个 timeline 载入 RAM。

### `.rbitmap.json`

小型图标/字体/部件格式。每一行按 MSB-first 压成 hex 字节。

```json
{"format":"rbitmap1","encoding":"row_hex_msb_first","w":5,"h":7,"row_hex":["70","88",...]}
```

这个格式比二维 `0/1` 数组小，ESP32 解析成本也低。

## ESP32 使用示例

### 读取 `.m370`

```python
def load_m370_hex(path):
    with open(path, 'r') as f:
        s = f.readline().strip().upper()
    if len(s) != 93:
        raise ValueError('bad M370 length')
    return s

# 发送给现有协议层
proto.update_physical_face_hex(load_m370_hex('/isolated_led_assets/resources/faces/default/rina370_default_face_01_惊讶眨眼大嘴.m370'))
```

### 流式播放 `.rnt`

```python
def stream_rnt(path, draw_hex, sleep_ms):
    with open(path, 'r') as f:
        header = f.readline()
        for line in f:
            if not line or line[0] == '#':
                continue
            start, hold_frames, hold_ms, hx = line.strip().split('|')
            draw_hex(hx)
            sleep_ms(int(hold_ms))
```

## 命名规则

- `voice_*.rnt`、`music_*.rnt`、`video_*.rnt` 按 738NGX Unity `Assets/Resources/Voice|Music|Video` 的资源命名方式整理。
- `face_modules`、`ascii_5x7` 对应 738NGX `Assets/Resources/Database` 中的 `FaceModuleDb` / `AsciiDb` 概念。
- `legacy_flyakari_components` 对应 flyAkari Arduino 源码中的 `EYES`、`MOUTHES`、`CHEEKS` 等部件数组。

## 统计

- 颜色：53
- 默认 face：11
- ASCII 字符：95
- 738NGX face module：93
- flyAkari legacy component：95
- display/font/icon 字形：66
- RNT 时间轴：158

