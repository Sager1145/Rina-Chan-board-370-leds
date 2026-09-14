# RinaBoard stress run RUNBOOK (2026-09-12)

## Environment

| Item | Value |
| --- | --- |
| Repo HEAD | `1e81ff08ad3405298116ad8c9ddf09bbaa1e4bd6` + 28 uncommitted changes (`hashes/git_state.txt`, `hashes/worktree.diff`) |
| Source snapshot | rsync copy taken at 21:15 into the session scratchpad (`snap/`); 131 files hashed in `hashes/source_sha256.txt` |
| macOS | 27.0 (26A428) |
| Xcode | Xcode-beta 27.0 (27A5237l), always used via `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` |
| Swift | 6.4 |
| PlatformIO | 6.2.0 (`~/.platformio-venv/bin/pio`), env `esp32s3-rmt-dma` |
| Host C++ | Apple clang 21.0.0 |
| Board | ESP32-S3, USB serial `/dev/cu.usbmodem5AE70745091` @115200, BLE name `RinaBoard-80B54EF48E09`, backend `rmt-dma`, brightness 50 (unchanged) |
| iPhone | iPhone 13 mini, UDID `00008110-000E38321AA2801E`, iOS 27, RinaBoard `com.rinachan.board` 2.0.0 (1) already installed (the installed build was **not** rebuilt from the snapshot; see REPORT limitations) |
| UI driver | Device Hub (`/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app`) mirroring the iPhone on the external monitor, controlled with Claude computer-use |

## Baseline (host)

Run against the snapshot; logs in `logs/baseline/`, summary `logs/baseline/summary.csv`.

```sh
swift test --package-path snap/ios/Packages/RinaCore --scratch-path <scratch>/rinacore
c++ -std=c++17 -Wall -Wextra -Werror -Isnap/esp32s3_firmware/src snap/esp32s3_firmware/test/host/stream_transport_test.cpp -o <scratch>/stream && <scratch>/stream
c++ -std=c++17 -Wall -Wextra -Werror -Isnap/esp32s3_firmware/src snap/esp32s3_firmware/test/host/ble_frame_sender_test.cpp -o <scratch>/ble && <scratch>/ble
python3 snap/esp32s3_firmware/test/host/<each>_test.py
cd snap/esp32s3_firmware && ~/.platformio-venv/bin/pio run -e esp32s3-rmt-dma   # build only, never uploaded
```

## Real hardware (connection tests)

1. Serial telemetry logger (sends `log level debug`, then `status` every 10 s; extra commands can be appended to `<log>.cmd`):

   ```sh
   python3 tools/device/serial_logger.py /dev/cu.usbmodem5AE70745091 logs/device/serial_realhw.log 5400
   ```

2. UI disconnect/reconnect cycles, driven in Device Hub: Settings → Connection → "中斷連線", then tap the saved board row. Taps were batched with fixed waits (cycles 1–5: 3 s after disconnect / 5 s after reconnect; cycles 6–15: 1.2 s / 4.5 s). The board-side latency is computed from the serial log:

   ```sh
   python3 tools/device/ble_events.py logs/device/serial_realhw.log metrics/device/ui_cycles
   ```

   `gap_ms` = board `disconnect` → next `tx_subscribed value=1`; it includes the fixed wait before the reconnect tap.

3. Force-quit / relaunch cycles (seed 20260912, dwell drawn from {0, 0.2, 0.5, 1, 2, 3} s, deadline 15 s per reconnect):

   ```sh
   python3 tools/device/relaunch_loop.py 00008110-000E38321AA2801E logs/device/serial_realhw.log 100 metrics/device/relaunch_cycles.csv 20260912
   ```

   Attempt 1 failed in cycle 0 because of a harness bug (options after `process launch <bundle>` were passed to the app as arguments); log kept as `logs/device/relaunch_loop_attempt1_launch_arg_bug.log`, not counted.

## Real hardware, session 2 (after the app restart)

4. Serial logger restarted into `logs/device/serial_realhw2.log`; `log level trace` appended to `serial_realhw2.log.cmd` to get the firmware's 1/s `SCROLL event=tick idx=` samples.
5. Live-preview floods on the Faces tab (Device Hub): 20 rapid drags across the grid, then 40 rapid 反轉 taps; byte ranges in `logs/device/flood1_range.txt` and `flood2_range.txt`. Draft then restored with 70 復原 taps.
6. Firmware text scroll (325 frames, 100 ms, loop) started from the 文字滾動 tab, then a 15-minute battery-guarded soak:

   ```sh
   python3 tools/device/soak_guard.py logs/device/serial_realhw2.log <start_offset> 900 30 metrics/device/soak_status.csv
   python3 tools/device/scroll_drift.py logs/device/serial_realhw2.log 279741 100 metrics/device/soak_scroll_drift.csv
   ```

   Disturbances during the soak: 10 pause/play taps, 10 step-forward + 10 step-back taps, one Settings › Connection disconnect/reconnect, two SIGKILL + relaunch (`logs/device/killrelaunch_scroll.txt`, `draft_repro.txt`). `soak_guard.py` prints each anomaly line 2–3 times (tail re-scan); count distinct board timestamps.
7. HW-DRAFT-ADOPT reproduction: on Faces send the draft (傳送 → 已同步), start text scroll, return to Faces, then `devicectl device process terminate --pid <pid> --kill` and `devicectl device process launch --device <udid> com.rinachan.board`, and compare the restored draft. **This destroys the current drawing.**

Case table: `python3 tools/merge_cases.py .` → `CASES.csv`.

## Cleanup / restore

- Stop the serial logger (Ctrl-C or kill its PID). `log level debug` is not persisted and resets at reboot.
- Relaunch RinaBoard on the phone if a loop was interrupted: `xcrun devicectl device process launch --device <udid> com.rinachan.board`.
- No factory reset, no library deletion, no flashing and no brightness change was done on the board.
- Delete the stress simulator created by the iOS agent if it still exists: `xcrun simctl delete RinaStress-iOS`.
