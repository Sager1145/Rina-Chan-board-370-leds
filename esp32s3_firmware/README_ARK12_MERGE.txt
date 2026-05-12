RinaChanBoard Ark12 merged text-scroll font patch
================================================

This patch changes only the text-scroll font path:

- WebUI global font remains GNU Unifont.
- Text-scroll input uses Ark Pixel Font 12px Monospaced.
- LED text-scroll rasterizer uses data/resources/fonts/ark12.json.
- Ark12 bitmap merge priority is zh_cn -> ja -> zh_tw; zh_tw has final priority.

The patch does not distribute font binaries. The root PowerShell script prepares them:

- downloads the official Ark Pixel Font 12px BDF/WOFF2 release if needed;
- builds data/resources/fonts/ark12.json from zh_cn + ja + zh_tw BDF files;
- copies the zh_tw WOFF2 to data/resources/fonts/ark12.woff2 for the textarea;
- downloads the official GNU Unifont PNG sheet if needed;
- builds data/resources/fonts/unifont.woff2 locally as a small WebUI subset.

Run from the extracted esp32s3_firmware directory:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS

Use -NoDownload only when .font_cache already contains the required official source archives/assets and Python packages are already installed.
