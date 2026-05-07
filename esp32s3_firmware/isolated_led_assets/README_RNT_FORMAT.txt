Rina Native Timeline (RNT2) text asset format
================================================

This build stores Unity voice/music/video timelines as plain text files.

Header:
RNT2|kind=<voice|music|video>|key=<asset_key>|fps=30|count=<rows>|last=<last_frame>|format=hex370

Rows:
start_frame|hold_frames|hold_ms|m370_hex

Notes:
- m370_hex is a 93-character uppercase hex string for the physical 370-LED matrix.
- The final two padded bits are kept inside the 93 hex nibbles for protocol compatibility.
- Playback no longer uploads every keyframe from the browser.
- The WebUI sends timeline370LoadRnt|<kind>|<key>|<loop> and timeline370Play only; the ESP32-S3 opens the matching .rnt file from flash and streams it directly. Browser-side .rnt fetching is disabled for normal playback.
- The browser still fetches the .rnt file for preview/progress UI only.

Example:
RNT2|kind=voice|key=voice_0|fps=30|count=9|last=24|format=hex370
# start_frame|hold_frames|hold_ms|m370_hex
3|1|33|00000000000000000000300300C00C0300300C00C00000000000000000000000040800108000F0000000000000000


1.7.3 note: firmware streams RNT2 files line-by-line from flash; it does not allocate the full frame list in RAM.
