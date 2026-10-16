# Board-owned Faces Implementation Plan

> For agentic workers: implement task by task with regression tests and independent review; do not commit, push or flash without task authorization.

**Goal:** Implement the approved board-only saved library, compact parts storage, reliable saves, and display-safe bulk transfer.

**Architecture:** Canonical board files hold either versioned parts references or packed pixels. A staged runtime table publishes only after a successful atomic file write. GET_FACES serves a bounded immutable expanded RAM snapshot per generation, so old clients retain full frames without repeated flash I/O. App saves use stable persistent IDs and conditional writes; reconnect reads authoritative state without replaying stale drafts.

**Tech Stack:** Arduino ESP32-S3, ArduinoJson/PSRAM/LittleFS, SwiftUI, RinaCore.

**Spec:** docs/superpowers/specs/2026-10-15-board-owned-faces-design.zh-CN.md

## Global Constraints

- Preserve existing user changes and all existing saved data; no automatic local-library migration/deletion.
- Formal saved lists require a live current board. Unsaved drafts remain independently recoverable.
- Pure parts use catalog rina_expression_parts_370_runtime_v4, version 4. Custom pixels retain 47-byte packed payload.
- Bulk reads and writes must not send display frames or partially publish runtime tables.
- Keep existing wire format readable by older clients, capability-gate new writes.

## Review Focus

- A stale editor must not adopt a newly loaded foreign name/gen as its baseline.
- An ACK followed by failed readback and App restart must not produce a second create ID.
- A disconnected/canceled load cannot update another board's list or live preview.
- Invalid references, no memory, disk failure and mid-transfer mutation preserve existing file/display.
- Large list reads must preserve ongoing scroll/auto output without repeated flash operations per page.

### Task 1: Firmware compact storage and transactional runtime publication

Files: storage.cpp/.h, generated parts table/generator and host tests.
- [x] Add failing tests for catalog composition, ID-only roundtrip, invalid references and preserved runtime on failure.
- [x] Generate parts from the App asset; materialize/canonicalize/expand using stable IDs and exact equality.
- [x] Prepare runtime table before atomic write; publish only after success, without sending a frame.
- [x] Run host tests and four firmware environment builds.

### Task 2: Protocol transfer and conditional writes

Files: protocol.cpp, storage interface consumers, BoardConnection.swift, protocol tests/docs.
- [x] Test stale boot/gen, createOnly existing ID, immutable paged reads and interrupted transfers.
- [x] Advertise bootId, facesGeneration and parts/conditional-write capabilities.
- [x] Attach/check expectedBootId/expectedGen for each mutation and blob commit.
- [x] Cache expanded serialized GET_FACES snapshot in bounded PSRAM keyed by generation; no per-page file open/read. Preserve legacy gen prefix and 409 handling.
- [x] Bound/cancel/coalesce App reads and record the read cursor for writes.

### Task 3: App board-owned library and save recovery

Files: FaceLibraryModel/View, ControlView/Model, DraftStorage, BoardSyncCoordinator, RinaCore face/command models, relevant tests.
- [x] Reproduce two known save defects plus offline-list and reconnect preview regressions.
- [x] Remove formal local save paths; hide/dismiss offline list; retain recoverable unsaved draft and legacy archive/migration.
- [x] Persist stable operation ID/target/snapshot before sending; verify readback and preserve pending result on failure.
- [x] Preserve edit baseline; capability-gate compact parts and conditional writes.
- [x] Run targeted and full App/Core tests.

### Task 4: Integration and board acceptance

- [x] Review diff across protocol/App/storage boundaries, run host, emulator and full tests.
- [x] Build four firmware environments; flash both boards only within user's firmware acceptance authorization.
- [x] Back up each board, test large mixed list transfers during steady/auto display and disconnect/reconnect; verify exact frame hashes and serial refresh errors plus user visual check.
- [x] Restore original user content and display settings; document actual evidence and remaining limitations.

**Acceptance limit:** The new Mac client/test host remains blocked by CoreBluetooth staying unknown/notDetermined. Real BLE bulk, reconnect, button and automatic-cycle acceptance used the existing installed client against the newly flashed firmware. Both original 11-item libraries and display settings were restored. See the implementation report for exact evidence.

### Task 5: Explicit multi-board save destinations (user steering)

Files: ControlView/ControlViewModel, new MultiBoardFaceSaveCoordinator, BoardConnection carrierGeneration accessor, dedicated tests.
- [x] Present individual board toggles and All connected boards when more than one board is connected; no This device tab.
- [x] Freeze/deduplicate physical destinations on opening. Default to current board; All never silently includes a later connection.
- [x] Persist per-destination stable IDs, submitted snapshots and results before any write. Overwrite an existing ID only on its owning source board; other destinations receive independent copies.
- [x] Submit with isolated per-board models/cursors. Show per-board results, retry only unconfirmed targets after identity/readback reconciliation, and skip confirmed targets across restart.
- [x] Tests: two different libraries, all/individual selection, partial failure/retry, reconnect identity, remote-only editor ownership, interrupted operation recovery. Run final targeted and App suite.
