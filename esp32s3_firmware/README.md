# RinaChanBoard ESP32-S3 AP WebServer

This PlatformIO firmware starts an ESP32-S3 AP, serves `data/index.html` and `data/resources/saved_faces.json` from LittleFS, and accepts the WebUI firmware API:

- `POST /api/frame` with `M370:<93 hex>` frame data.
- `POST /api/command` for `set_color`, `set_brightness`, `pause`, mode, and debug commands.
- `GET/POST /api/saved_faces` for the unified `saved_faces.json`.
- `GET /api/status` for runtime state.

LED output is a simple 370 LED WS2812/NeoPixel chain on `GPIO2`. M370 bit `0..369` maps directly to LED `0..369`. Brightness is clamped to the project raw range `10..200`; the WebUI percentage is still `raw / 255`, so the capped maximum displays as about `78%`.

`/api/frame` only applies the M370 mask plus `reason` / `playback`. Color and brightness are global renderer state and should be changed through `/api/command`.

## Build / Upload

```sh
pio run
pio run -t upload
pio run -t uploadfs
```

If `uploadfs` is skipped or LittleFS fails to mount, the AP still starts and the root page returns a diagnostic message instead of a silent 404.

After boot, connect to:

- SSID: `RinaChanBoard-ESP32S3`
- Password: `rinachan`
- URL: `http://192.168.1.14/`

Default startup face: `face_07_triangle_eyes_frown`.
