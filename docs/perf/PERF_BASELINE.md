# PR-0 performance baseline

Machine: MacBook Pro, Apple M4, 32 GB RAM, macOS 27.0 (Darwin), Xcode-beta toolchain.
Date: 2026-09-13. Commit: `e7a0a5c` (branch `perf/ios-hotpaths`, worktree at
`Rina-Chan-board-perf`).

These numbers come from the Mac (Swift Package unit tests) and the iOS
Simulator (device `53787319-2C1D-474F-9C2C-CD398583E554`). They are **relative
baselines for regression tracking on this machine**, not device numbers — the
real ESP32-side and physical-iPhone timings will differ. PR-0 adds no
optimizations; these are the numbers the later hotpath work is measured
against.

## RinaCore: LipSync DSP (`LipSyncPerformanceTests`)

`analyze`/`measure` run on a synthesized voiced 48 kHz window of 3584 samples
(`fftSize * 3 + 512`); `analyze` also runs on an all-zero (silent) window that
exits at the volume gate. `synthesized` builds one full `LipSyncProfile` per
preset. p50/p95 in milliseconds, ContinuousClock, 5 warm-up runs discarded.

| case | debug p50 | debug p95 | release p50 | release p95 |
|---|---|---|---|---|
| analyze-voiced | 18.9013 | 36.7725 | 0.0961 | 0.1138 |
| analyze-silent | 0.1956 | 0.4382 | 0.0021 | 0.0026 |
| measure-voiced | 16.8210 | 42.0481 | 0.0931 | 0.1138 |
| synthesized-standard | 23.2485 | 44.5880 | 0.2507 | 0.4526 |
| synthesized-male | 26.8209 | 32.2710 | 0.2386 | 0.2829 |
| synthesized-female | 22.5960 | 24.1026 | 0.2424 | 0.3791 |
| synthesized-anime | 22.7133 | 23.9311 | 0.2395 | 0.4688 |

Debug builds are ~100-200x slower than release for the DSP-heavy cases (no
inlining/bounds-check elimination); this gap is expected and not itself a
regression signal — compare release-to-release across PRs.

## RinaCore: RinaLinkDecoder throughput (`RinaLinkDecoderBaselineTests`)

Built with `RinaLinkEncoder.encode`, decoded with the current
`RinaLinkDecoder.feed`, ContinuousClock wall time.

| case | debug frames/s | debug MB/s | release frames/s | release MB/s |
|---|---|---|---|---|
| A: 100k frames, 16B payload, one Data per frame | 1,625,621 | 35.76 | 3,912,529 | 86.08 |
| B: 2k frames, 32B payload, 1 byte at a time | 73,392 | 2.79 | 255,422 | 9.71 |
| C: 20k frames, 64B payload, 1024B chunks | 2,270,524 | 158.94 | 5,072,549 | 355.08 |
| D: 2k frames + 64B garbage prefix, 512B chunks | 127,067 | 11.94 | 667,176 | 62.71 |
| E: 500 frames, 4096B payload, 4096B chunks | 1,154,401 | 4735.35 | 1,921,843 | 7883.40 |

Case B (byte-at-a-time) is the slowest per-frame path, as expected for a
decoder that rescans its buffer from the front on every `feed` call — this is
the case most likely to show a clear win once PR-1+ lands.

## App (iOS Simulator): live Control send under load (`ControlLivePreviewStressTests`)

`ControlViewModel.pushLiveIfNeeded` driven by `toggle(led:)` at a fixed rate
for 2.0 s against a `FakeRinaTransport` with a simulated 30 ms BLE round-trip
reply delay, then drained to quiescence. `quarantineEvents` is the cumulative
count of seqs `BoardConnection` quarantined (a superseded live send whose old
request was cancelled after its seq was already allocated); `quarantinedNow`
is only what is still quarantined at the moment the test reads it, which is
almost always 0 because the delayed fake reply retires the entry a few tens of
ms later — `quarantinedNow` alone hid real quarantine churn in the first pass
of this baseline. `errorsSeen` counts how many of the sampled post-edit
`model.errorMessage` reads were non-nil.

| rate (Hz) | edits | wire | quarantineEvents | quarantinedNow | finalMatches | errorsSeen |
|---|---|---|---|---|---|---|
| 10 | 20 | 20 | 1 | 0 | true | 0 |
| 25 | 50 | 50 | 2 | 0 | true | 0 |
| 50 | 100 | 89 | 88 | 0 | true | 0 |
| 75 | 150 | 83 | 82 | 0 | true | 0 |
| 100 | 200 | 76 | 76 | 0 | true | 0 |

`wire` caps out well below `edits` once the edit rate exceeds what a 30 ms
round trip can drain (consistent with the existing `framePump`/rate-pump
serialization). `quarantineEvents` tracks that gap almost 1:1 above 25 Hz —
most superseded sends are quarantined, not merely dropped — while
`finalMatches=true` confirms the last frame actually on the wire always
converges to the final draft, and `errorsSeen=0` shows none of that churn
surfaces as a user-visible error.

`uptime` immediately before and after this run:

```
before: 21:54  up 4 days,  1:22, load averages: 59.59 98.83 82.67
after:  21:57  up 4 days,  1:25, load averages: 186.97 147.72 105.22
```

Load averages around 100-190 on this (nominally 10-core) machine, caused by
poster-extension work from another concurrent session on this shared box,
contaminate every wall-clock timing in this baseline — the LipSync DSP and
decoder throughput numbers above were captured under similarly uncontrolled
load. Treat every absolute number here as noisy; only re-measure ratios
(fresh vs. stored, rate vs. rate, debug vs. release) under a quiet machine
before trusting them for regression gating.

## App (iOS Simulator): `LipSyncModel` init (`LipSyncModelInitBenchmarkTests`)

10 timed inits each, ContinuousClock, fresh empty `UserDefaults` suite
(synthesizes a profile) vs. a suite pre-populated with one stored profile.

```
[LipSyncInitBench] fresh p50=20.300 max=20.463 stored p50=1.490 max=2.444
```

Synthesizing a profile from scratch (5 vowels × the full analysis chain) costs
roughly 10-15x a plain JSON-decode-and-reuse init.

## Verification

- RinaCore debug: `swift test --package-path ios/Packages/RinaCore --scratch-path $S/rinacore-build-main` — 189 tests, 0 failures (180 pre-existing + 9 new).
- RinaCore release: `-c release -Xswiftc -enable-testing --filter "LipSyncPerformanceTests|RinaLinkDecoderBaselineTests"` — 9 tests, 0 failures.
- RinaBoardTests (simulator `53787319-2C1D-474F-9C2C-CD398583E554`): 236 tests, 0 failures (234 pre-existing + 2 new).
