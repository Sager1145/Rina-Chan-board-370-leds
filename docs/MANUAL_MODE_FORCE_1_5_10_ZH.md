# v1.5.10 强制刷入/版本校验版

用户日志仍显示 `Firmware version: 1.5.7-pico-webui-firmware-full-checked`，说明 Pico 上实际运行的仍是旧固件。

本版继续保留 v1.5.9 的手动控制模式，并增加强制安装脚本：上传前删除同名 `.py` 与 `.mpy`，上传后打印 `VERIFY_VERSION=`。

刷入后串口应显示：

```text
Firmware version: 1.5.10-pico-webui-manual-mode-force-zfillfix
```
