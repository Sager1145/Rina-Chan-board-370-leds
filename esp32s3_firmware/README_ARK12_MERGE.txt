RinaChanBoard Ark12 merged text-scroll font resources
=====================================================

WebUI font rules:

- WebUI global font is GNU Unifont.
- The GNU Unifont WebUI subset is generated from the official GNU Unifont BMP PNG sheet and embedded directly into data/index.html as a base64 data:font/woff2 URL.
- A copy of the generated subset is also kept at data/resources/fonts/unifont.woff2 for verification and LittleFS resource consistency.
- Text-scroll input uses Ark Pixel Font 12px Monospaced.
- LED text-scroll rasterizer uses data/resources/fonts/ark12.json.
- Ark12 bitmap merge priority is zh_cn -> ja -> zh_tw; zh_tw has final priority.

The root PowerShell script prepares or re-synchronizes the font resources:

- downloads or reuses the official Ark Pixel Font 12px BDF/WOFF2 release if needed;
- builds data/resources/fonts/ark12.json from zh_cn + ja + zh_tw BDF files;
- copies the zh_tw WOFF2 to data/resources/fonts/ark12.woff2 for the textarea;
- downloads or reuses the official GNU Unifont BMP PNG sheet if needed;
- builds data/resources/fonts/unifont.woff2 locally as a small WebUI subset;
- embeds the same generated GNU Unifont subset into data/index.html;
- reports and skips characters that cannot be generated from the BMP PNG sheet instead of forcing them into the subset.

Run from the extracted esp32s3_firmware directory:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS

Use -NoDownload only when .font_cache already contains the required official source archives/assets and Python packages are already installed.
