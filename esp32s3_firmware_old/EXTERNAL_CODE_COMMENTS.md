# External Code Comments - 1.7.4 RNT command-only playback / AP non-blocking send

## Why this update exists

The previous 1.7.3 stream loader proved that the firmware could play one RNT timeline, but the AP became unresponsive before a second playback. The uploaded log shows the first asset loading and playing successfully, then after `runtimeStop|media` the next browser request for `/assets/unity_core.json` hit `[Errno 116] ETIMEDOUT`. This points to the browser still doing static asset reloads after playback, and the firmware HTTP sender blocking long enough to starve the single main loop.

## Main changes

- WebUI Unity playback is now command-only:
  - `timeline370LoadRnt|kind|key|loop`
  - `timeline370Play`
  - optional `runtimeStop|media` only for manual early stop
- Browser no longer fetches `.rnt` files for normal media preview/playback.
- Browser no longer polls `runtimeStatus` during playback.
- Stop/play no longer unloads and immediately reloads `unity_core.json`.
- Firmware HTTP send path now uses short send slices, a short socket timeout, and yields between slices so a slow/disconnected phone cannot block the AP loop for seconds.
- Static file chunk size reduced from 1024 to 512 bytes.
- HTTP wait-reply timeout reduced from 5000 ms to 1500 ms.

## Expected serial log for repeat playback

```text
>>> [API Command] 收到前端指令: timeline370LoadRnt|music|solo0|0
webui runtime: RNT stream asset ready assets/unity_music/solo0.rnt count=320 last=968 fps=30 loop=False heap_free=...
>>> [API Command] 收到前端指令: timeline370Play
webui runtime: timeline play source=rnt frames=320 last=968 fps=30 loop=False heap_free=...
```

A second play should show another `timeline370LoadRnt` and `timeline370Play` without first fetching `/assets/unity_core.json` or `/assets/unity_music/*.rnt` from the browser.

## Files changed

- `webui_index.html.gz`
- `esp32s3_network.py`
- `rina_protocol.py`
- `main.py`
- `assets/README_RNT_FORMAT.txt`
- `EXTERNAL_CODE_COMMENTS.md`
