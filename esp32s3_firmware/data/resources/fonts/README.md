# WebUI font resources

- `DotGothic16-Regular.woff2` is the browser-loaded WebUI font used by the text-scroll rasterizer.
- The previous TTF payload was removed from LittleFS because it exceeded the old filesystem partition.
- The ESP32 firmware does not render font files directly; the browser renders/rasterizes text and sends M370 frames to the firmware.
- Keep the upstream font license with any external redistribution of this project.
