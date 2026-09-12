#!/usr/bin/env python3
"""Verify that the 演出 (Preset Live) audio still lines up with its timeline.

Two independent things can silently desync the board from the music, and this
checks both against the upstream source rather than assuming:

1. **The transcode.** Upstream ships Ogg Vorbis, which iOS cannot decode, so
   `tools/fetch_preset_live_audio.sh` re-encodes to AAC. AAC prepends 2112
   priming samples; if a decoder failed to strip them the whole performance
   would sit ~44 ms late, and a bad transcode could shift it further. This
   decodes the original Ogg and the transcoded M4A back to PCM and
   cross-correlates them. The lag must be exactly 0 samples — one keyframe at
   upstream's 10 fps is 100 ms, so anything non-zero is worth knowing about.

2. **Timeline vs track length.** A timeline whose last keyframe falls past the
   end of its audio can never fully play. Upstream polls
   `Mathf.FloorToInt(musicSource.time * 10)` (`MusicPage.cs:31`) so it simply
   never reaches those frames; the same is true for us, but it should be
   reported rather than discovered on stage.

Requires the intermediate Ogg files, so run the fetch script with
`--keep-intermediate` first:

    ./tools/fetch_preset_live_audio.sh --keep-intermediate
    python3 tools/verify_preset_live_alignment.py
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
RESOURCES = REPO_ROOT / "ios/RinaBoard/Resources"
WORK = REPO_ROOT / "build/preset_live_audio"
CATALOG = RESOURCES / "preset_live_catalog.json"

# One keyframe at upstream's fixed 10 fps. A lag anywhere near this would be
# visible on the board; we expect exactly 0.
KEYFRAME_MS = 100.0


def decode_to_wav(source: Path, destination: Path) -> None:
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", str(source), str(destination)],
                   check=True, capture_output=True)


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    """Minimal RIFF reader — Python's `wave` rejects WAVE_FORMAT_EXTENSIBLE,
    which is what afconvert writes for multi-channel output."""
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"{path} is not a RIFF/WAVE file")
    pos, channels, rate, data = 12, None, None, None
    while pos + 8 <= len(raw):
        chunk_id = raw[pos:pos + 4]
        size = struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if chunk_id == b"fmt ":
            _, channels, rate = struct.unpack("<HHI", body[:8])
        elif chunk_id == b"data":
            data = body
        pos += 8 + size + (size & 1)
    if data is None or rate is None:
        raise ValueError(f"{path} has no data/fmt chunk")
    samples = np.frombuffer(data, dtype="<i2").astype(np.float32)
    if channels and channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples, rate


def measure_lag(reference: np.ndarray, test: np.ndarray, rate: int,
                window_s: float = 8.0, start_s: float = 20.0, max_lag: int = 5000):
    """Sample lag of `test` relative to `reference`, plus the correlation peak.

    The window starts well inside the track: an intro can be near-silent, and
    correlating silence against silence localises nothing.
    """
    window = int(window_s * rate)
    start = int(start_s * rate)
    if len(reference) < start + window + max_lag or len(test) < start + window + max_lag:
        start = 0
        window = min(len(reference), len(test)) - 2 * max_lag
        if window <= 0:
            raise ValueError("tracks too short to correlate")

    anchor = reference[start:start + window].astype(np.float64)
    anchor -= anchor.mean()
    haystack = test[start - max_lag:start + window + max_lag].astype(np.float64)
    haystack -= haystack.mean()

    correlation = np.correlate(haystack, anchor, mode="valid")
    lag = int(np.argmax(correlation)) - max_lag

    aligned = test[start + lag:start + lag + window].astype(np.float64)
    aligned -= aligned.mean()
    norm = np.linalg.norm(anchor) * np.linalg.norm(aligned)
    peak = float((anchor * aligned).sum() / norm) if norm else 0.0
    return lag, peak


def main() -> int:
    if not CATALOG.exists():
        print(f"missing {CATALOG.relative_to(REPO_ROOT)} — run tools/convert_upstream_timelines.py",
              file=sys.stderr)
        return 1
    catalog = json.loads(CATALOG.read_text())

    failures = 0
    print(f"{'performance':14} {'lag(smp)':>9} {'lag(ms)':>9} {'corr':>7} "
          f"{'timeline(s)':>12} {'audio(s)':>9}  verdict")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for entry in catalog:
            cover = entry["file"].removeprefix("performance_")
            extension = entry.get("audioExtension", "m4a")
            m4a = RESOURCES / f"{entry.get('audio', 'audio_' + cover)}.{extension}"
            # Only the Ogg sources are transcoded; an MP3 is copied verbatim,
            # so there is no original to correlate against and nothing to shift.
            ogg = WORK / f"music_{cover}.ogg"
            timeline_s = entry["durationMs"] / 1000

            if not m4a.exists():
                print(f"{cover:14} {'-':>9} {'-':>9} {'-':>7} {timeline_s:12.1f} {'-':>9}  "
                      f"SKIP (no audio; run tools/fetch_preset_live_audio.sh)")
                continue

            decode_to_wav(m4a, tmp_path / f"{cover}_test.wav")
            test, rate = read_wav(tmp_path / f"{cover}_test.wav")
            audio_s = len(test) / rate

            if not ogg.exists():
                print(f"{cover:14} {'-':>9} {'-':>9} {'-':>7} {timeline_s:12.1f} {audio_s:9.2f}  "
                      f"SKIP transcode check (no Ogg; use --keep-intermediate)")
                continue

            decode_to_wav(ogg, tmp_path / f"{cover}_ref.wav")
            reference, _ = read_wav(tmp_path / f"{cover}_ref.wav")
            lag, peak = measure_lag(reference, test, rate)
            lag_ms = lag / rate * 1000

            notes = []
            if lag != 0:
                notes.append(f"TRANSCODE SHIFTED {lag_ms:+.1f} ms")
                failures += 1
            if peak < 0.99:
                notes.append(f"LOW CORRELATION {peak:.3f}")
                failures += 1
            if timeline_s > audio_s:
                # Upstream's exact-match polling never reaches these frames
                # either, so this is inherited data, not a conversion fault.
                notes.append(f"timeline outruns audio by {timeline_s - audio_s:.1f}s (upstream data)")

            verdict = "; ".join(notes) if notes else "ok"
            print(f"{cover:14} {lag:9d} {lag_ms:9.3f} {peak:7.4f} "
                  f"{timeline_s:12.1f} {audio_s:9.2f}  {verdict}")

    print()
    if failures:
        print(f"FAILED: {failures} problem(s). One keyframe is {KEYFRAME_MS:.0f} ms at 10 fps.")
        return 1
    print(f"All transcodes are sample-aligned with the Ogg originals "
          f"(tolerance: 0 samples; one keyframe = {KEYFRAME_MS:.0f} ms).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
