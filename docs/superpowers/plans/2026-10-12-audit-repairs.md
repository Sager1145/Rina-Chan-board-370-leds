# Audit Repairs Implementation Plan

> **For agentic workers:** Use subagent-driven-development practices proportionately, with exclusive file ownership, regression tests, and independent review. User has authorized implementation and flashing both connected ESP32-S3 boards; no commits or pushes are authorized.

**Goal:** Repair every concrete finding and misleading testing assertion from the full audit, diagnose red verification lanes, and flash/verify both boards.

**Architecture:** Preserve the current app/firmware design. Concentrate fixes at existing playback, configuration, identity, diagnostic and watch input seams. Architecture opportunities and intentional anonymous-control policy are decisions rather than mandates for unrelated rewrites.

**Tech Stack:** Swift/SwiftUI, XCTest/Swift Testing, Arduino ESP32-S3 C++/PlatformIO, Python/Bash host tooling.

**Spec:** docs/audits/2026-10-12-full-audit/README.md and linked detail reports.

## Global Constraints

- Preserve all pre-existing modifications, including untracked FaceSync code.
- App iOS17 / Swift5, watchOS10 / Swift5, RinaCore Swift6.
- Add meaningful regression checks; do not weaken failures or raise warning baseline.
- Flash esp32s3-rmt-dma application firmware, preserving LittleFS/NVS; no mass erase.
- No commits, pushes, issue publication or messages to other chats.

## Review Focus

- Playback cancellation must stop only boards owned by the aborted attempt.
- Passive confirmed watch values must never send commands.
- Firmware end states, loop settings and retry identity must agree across status and physical output.
- Invalid settings/imports must preserve prior usable configuration/data.
- Test gates must detect actual exercised behavior, fail on missing fixtures and propagate failure status.

## Tasks

- [x] Firmware FW-A1..A10/A12: regression-first fixes for battery snapshots, group end/loop, Wi-Fi validation/scans, identities, renderer fallback, BLE teardown and presentation retry/hint precedence. Run every host test and firmware build.
- [x] App LOGIC-1/2 + UI-1..5: checkpoint safety, cancelled group cleanup, live composition publication, non-drag seeking, board-scoped diagnostics, passive crown echoes, and query ownership. Add production-interface regressions.
- [x] Test software: fix inert permutation/overlap/lifetime/lock assertions, fixture skips, stale UI selector and defaults isolation. Improve real BLE bookkeeping test coverage rather than a private duplicate model.
- [x] Host tools: fix CPP dependencies, all-skipped gates, emulator state isolation, short-audio alignment and archived failure propagation; make verification lanes explicit.
- [x] Diagnose and repair video failures; fix real strict-concurrency diagnostic causes; reconcile stale catalogue entries.
- [x] Independent diff review, full package/app/host/UI/concurrency verification and repair any detected regressions.
- [x] Identify each ESP32-S3, flash both using the validated image, verify upload checksums and boot/status/identity per board.
- [x] Record each finding disposition and validation in docs/audits/2026-10-12-full-audit/repairs.md.
