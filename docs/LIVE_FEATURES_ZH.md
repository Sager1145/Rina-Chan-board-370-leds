# Live 功能移植：口型同步 + 预设演出

iOS App 原本有一个名为 "Live" 的占位 tab（`LiveVideoView`，内容是「实时视频 · 即将推出」）。本次把它替换成两个真正的功能，分别移植自 README / 关于页「致谢」中列出的两个上游项目：

| tab | 上游来源 | 上游名称 | 许可证 |
|---|---|---|---|
| **口型** | [738NGX/RinaChanBoard](https://github.com/738NGX/RinaChanBoard) | 口型同步 | AGPL-3.0（其 LipSync 改自 MIT 的 [hecomi/uLipSync](https://github.com/hecomi/uLipSync)） |
| **演出** | [flyAkari/RinaChanBoard](https://github.com/flyAkari/RinaChanBoard) | `PresetLiveActivity`（预设直播） | GPL-3.0 |

本仓库同为 GPL-3.0，两者移植在许可上兼容。两个功能都是**重新用 Swift 实现**，不含上游代码或素材的逐行拷贝。

上游并不存在「实时视频 / 摄像头转 LED」这种功能——占位 tab 的文案是凭空写的，本次一并删除。

---

## 1. 口型同步（Lip Sync）

### 1.1 用户视角

对着手机说话，璃奈板的嘴巴实时跟着动。眼睛和脸颊在同步期间保持不变（由用户在「口型与造型」里选定）。

- 识别模型：标准 / 男声 / 女声 / 动画（上游同名的四个预设）
- 麦克风灵敏度：判定为静音的音量下限，低于它就闭嘴
- 刷新速率：10–60 Hz，分析窗口的分类频率
- 防抖帧数：取最近若干次识别结果的众数，1 表示不防抖
- 校准：对每个元音录约 1.5 秒自己的声音，替换该元音的参考向量

同步或校准进行中，所有识别选项会被锁住——对应上游那个「进行中禁止改选项/离开页面」的互斥锁。

### 1.2 信号链

`RinaCore/LipSync.swift`，纯 Swift，不依赖 Accelerate / AVFoundation，因此可以离线单测。顺序与上游 `Documents/附录1-口型同步.md` 第 2、5.8.2 节一致：

```
麦克风缓冲
  → RMS → dBFS，低于灵敏度阈值即判静音（直接闭嘴，不做分类）
  → 窗口化的 sinc 低通（31 taps，Hamming 窗，截止 = 目标奈奎斯特 × 0.9）
  → 线性插值重采样到 16 kHz
  → 预加重  y[n] = x[n] − 0.97·x[n−1]
  → Hamming 窗  w(n) = 0.53836 − 0.46164·cos(2πn/(N−1))
  → 1024 点 radix-2 FFT → 幅度谱（513 bin）
  → 24 路三角 Mel 滤波器组，Mel(f) = 2595·log10(1 + f/700)
  → 功率转 dB
  → DCT-II，取系数 1…12（丢掉 c0，即整体响度）
  → L2 归一化 → 与五个元音参考向量比欧氏距离，取最近
  → 最近 N 次结果取众数（防抖）
  → 元音 → 嘴巴部件 → PartsLibrary.compose → 47 字节 M370 帧
```

关键常数：目标采样率 16 kHz、FFT 1024 点（64 ms 窗）、Mel 24 路、MFCC 12 维、预加重 0.97、默认灵敏度 −42 dBFS、默认防抖 6 帧、默认刷新 30 Hz。

### 1.3 与上游唯一的实质差异：默认声音模型

uLipSync 随包附带用真人录音标定出来的参考 MFCC（`LipSyncProfile/*.asset`），这些数据没法照搬。这里改成**运行时合成**：用声源–滤波器模型（基频冲激串 → 每个共振峰一个双极点谐振器 `y[n] = x[n] + 2r·cosθ·y[n−1] − r²·y[n−2]`，`r = e^(−πB/fs)`）按 Peterson & Barney 的共振峰值生成五个元音，再走同一条分析链得到参考向量。

四个预设就是声道长度缩放 + 基频：

| 预设 | 共振峰缩放 | 基频 |
|---|---:|---:|
| 标准 | 1.08 | 150 Hz |
| 男声 | 1.00 | 110 Hz |
| 女声 | 1.17 | 200 Hz |
| 动画 | 1.30 | 260 Hz |

好处是开箱即用、不需要任何录音素材，而且完全确定，可以被单测断言。用户校准会逐个元音覆盖掉合成出来的参考。

### 1.4 默认嘴型映射

按 `expression_parts.json` 里 8×8 的 `preview` 点阵挑的：

| 状态 | 部件 | 形状 |
|---|---|---|
| 静音 | 301 | 一条平嘴 |
| あ a | 311 | 最大的张口 |
| い i | 302 | 宽而扁 |
| う u | 319 | 小圆口 |
| え e | 313 | 中等张口 |
| お o | 316 | 竖长椭圆 |

每一项都可以在「口型与造型」里改，存 `UserDefaults`；保存的映射在载入时会按当前部件库校验一遍，失效 ID 会退回到库里的第一个嘴巴部件。

### 1.5 发帧策略

只在**识别结果发生变化**时才 `setFrame(..., reason: "lipsync")`——与上游 `RinaLipSyncFaceManager.Apply()` 的 "only send if phoneme changed" 一致。30 Hz 逐帧发既会灌满 20 ms 的帧泵（`RatePump`，深度 6），板子也只是在重画同一张嘴。

---

## 2. 预设演出（Preset Live）

### 2.1 用户视角

选一首本地音频 + 一份关键帧脚本，按播放，板子按脚本做表情。附带一份 23 关键帧 / 约 7 秒的演示脚本 `preset_live_demo.rinalive`（只有脚本，没有音频——不便随包附带上游的 MP3）。

### 2.2 脚本格式

兼容 flyAkari 的行格式，并做了扩展：

```
# 注释
#fps 10
#title 演示
0!101,201,301,400
3!102,202,305,401
```

- `#fps` 1–60，缺省 **10**（flyAkari 的 `private final static int fps = 10;`）
- `#title` 可选
- 关键帧行 `<帧号>!<左眼>,<右眼>,<嘴巴>,<脸颊>`，容忍行尾多余的逗号（上游发到线上的是 `"3,3,7,1,"`）与空白
- 帧号必须严格递增；`时间(ms) = 帧号 × 1000 / fps`
- 四个取值的解析顺序：先当作本项目的部件 ID（`101`/`301`/`400` 这一套），不匹配再当作该组的序号（flyAkari 那套小整数 sprite 索引）。因此两种脚本都能直接导入

### 2.3 播放时钟

对时用的是 `AVAudioPlayer.currentTime`，不是自由跑的定时器——这正是上游的做法（`mMediaPlayer.getCurrentPosition()` 与 `next_ms` 比较）。约 8 ms 轮询一次，只在关键帧切换时向板子发一帧（`reason: "live_preset"`）。每个关键帧的合成帧在脚本载入时一次性算好，播放热路径上不做合成。

播放到结尾：开了循环就回到 0（并重置关键帧游标，使首帧重新触发），否则停止并**保留板子上的最后一帧**——板子确实停在了演出结束时的表情，清屏或恢复默认表情都是在替用户做决定。

---

## 2.4 内置演出与音频素材

演出 tab 内置 9 份关键帧时间轴，用一个下拉选择：

| 脚本 | 曲目 | 关键帧 | 时长 | 来源 |
|---|---|---:|---:|---|
| `performance_tkmk` | TOKIMEKI Runners | 262 | 87.1s | 738NGX |
| `performance_lumf` | Love U my friends | 171 | 103.1s | 738NGX |
| `performance_solo0` | ツナガルコネクト | 317 | 96.8s | 738NGX |
| `performance_solo1` | ドキピポ☆エモーション | 273 | 90.1s | 738NGX |
| `performance_solo2` | テレテレパシー | 278 | 112.0s | 738NGX |
| `performance_solo3` | アナログハート | 299 | 103.9s | 738NGX |
| `performance_solo4` | First Love Again | 197 | 119.1s | 738NGX |
| `performance_solo5` | 私はマグネット | 238 | 91.2s | 738NGX |
| `performance_poppin_up` | Poppin' Up! | 316 | 87.3s | flyAkari |

### 转换

- **738NGX**（`tools/convert_upstream_timelines.py`）：直接转写。上游的部件 ID 与我们的是同一套编号，转换器仍会逐个对照 `expression_parts.json` 校验，遇到未知 ID 直接拒绝写出。上游按帧号建字典、同帧后者覆盖，所以转换时按帧排序并合并重复帧（`solo0` 有 3 处重复）。
- **flyAkari**（`tools/convert_flyakari_script.py`）：脚本里存的是其 ESP8266 固件中 `EYES[21]`/`MOUTHES[15]`/`CHEEKS[5]` 的**精灵索引**，与我们的编号无关。转换器按 `main.cpp` 自己的 blit 函数解码位图（第 i 行 = 第 i 个字节、低字节在前；第 j 位 = 第 j 列、LSB 在最左；嘴巴和脸颊左右镜像，右眼是左眼精灵的镜像），再用 IoU 与我们的部件逐一比对。**32 个被用到的精灵里 29 个是 IoU = 1.00 的精确匹配**——两个项目画的是同一套美术。剩下 3 个记在 `OVERRIDES` 里并写明理由。低于 `MIN_IOU = 0.85` 且无 override 会中止转换而不是默默产出错脸。
- 上游数据里的一处乱序帧（639 夹在 692 和 694 之间）按时间戳排序修正；上游播放器顺序读行，那一帧本来永远不会触发。

### 音频不随仓库分发

两个上游仓库的音频/视频都是 Love Live! 的商业录音，且都没有任何授权声明。本仓库**不提交、不分发**这些文件：

- `tools/fetch_preset_live_audio.sh` 在本地拉取并转码，落到 `.gitignore` 的路径。
- iOS 不支持 Ogg Vorbis，738NGX 的 8 首 `.ogg` 用 `afconvert` 转成 AAC/M4A；flyAkari 的 mp3 原样拷贝。
- Xcode 工程用的是 synchronized group，所以没有这些文件的 clone 照样能编译，演出 tab 只是把对应曲目标为「无音频」。

### 对齐验证

`tools/verify_preset_live_alignment.py` 查两件事：

1. **转码是否移位**。AAC 会加 2112 个 priming 采样，解码端处理不当会让整条时间轴晚约 44 ms。脚本把原始 ogg 和转码后的 m4a 都解回 PCM 做互相关，要求 lag **恰好为 0 个采样**（10 fps 下一个关键帧是 100 ms）。8 首实测全部 lag = 0，相关系数 0.998–0.9998。
2. **时间轴是否超出音轨**。`lumf` 的末帧比音轨长 1.0 秒——上游用 `floor(time*10)` 精确匹配轮询，那一帧本来也到不了，属于继承的上游数据而非转换问题。

播放语义与上游的等价性由 `BundledPerformanceTests.testLookupMatchesUpstreamExactFramePolling` 钉住：它按 `MusicPage.cs:31` 的算法（`floor(audioTime*10)` + 字典精确匹配 + 保持上一张脸）重放每一份内置脚本，以 10 ms 步长走完全程，断言与我们的二分查找结果永不分歧。我们的实现还严格更稳——上游若某次 `Update()` 跨过了一个帧号就会整帧漏掉，而"取当前时刻之前最后一个关键帧"不会。

## 3. 改动的文件

新增：

- `ios/Packages/RinaCore/Sources/RinaCore/LipSync.swift` + `Tests/RinaCoreTests/LipSyncTests.swift`
- `ios/Packages/RinaCore/Sources/RinaCore/LivePerformanceScript.swift` + `Tests/RinaCoreTests/LivePerformanceScriptTests.swift`
- `ios/RinaBoard/Features/LipSync/{LipSyncAudioCapture,LipSyncModel,LipSyncView}.swift`
- `ios/RinaBoard/Features/PresetLive/{PresetLiveModel,PresetLiveView}.swift`
- `ios/RinaBoard/Resources/preset_live_demo.rinalive`
- `ios/RinaBoard/Resources/performance_*.rinalive` + `preset_live_catalog.json`（9 份内置演出）
- `tools/convert_upstream_timelines.py`、`tools/convert_flyakari_script.py`
- `tools/fetch_preset_live_audio.sh`、`tools/verify_preset_live_alignment.py`

修改：

- `ios/RinaBoard/App/RinaBoardApp.swift`：注入两个新 model
- `ios/RinaBoard/App/RootTabView.swift`：`AppTab` 由 4 个变 5 个（`.liveVideo` → `.lipSync` + `.presetLive`；旧的 `-initialTab liveVideo` 仍映射到演出 tab）
- `ios/RinaBoard/Info.plist`：`NSMicrophoneUsageDescription`
- `ios/RinaBoard/Resources/Localizable.xcstrings` / `InfoPlist.xcstrings`：新字符串的四语翻译（由本地化会话统一维护，流程见 `tools/i18n/README.md`）
- `.gitignore`：排除 `ios/RinaBoard/Resources/audio_*` 与 `build/`

删除：

- `ios/RinaBoard/Features/LiveVideo/LiveVideoView.swift`（占位 tab）

固件侧无改动：两个功能都走既有的 `SET_FRAME`（`0x10`）。
