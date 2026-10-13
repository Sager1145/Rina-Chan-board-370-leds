# iOS feature, watch and resource audit

Read-only audit at `/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds`. All 82 assigned Swift production files (76 feature + 6 watch, 23,713 lines) were read completely in chunks, with comments/blank lines omitted from some tool displays for compactness. No source sampling. No production edits, external actions or nested workers. `codebase-design`, `ios-dev`, `guide-swift-concurrency`, `guide-swiftui-ui-patterns`, `guide-swiftui-performance-audit` and verification instructions applied proportionately. App target remains iOS 17/Swift 5; watch is watchOS 10/Swift 5. Warnings about a hypothetical Swift 6 migration are not reported as present race bugs.

## Actionable findings (P2)

### 1. Live lip-sync composition changes never reach a steady phoneme

**Location:** `ios/RinaBoard/Features/LipSync/LipSyncModel.swift:467` (early return); mapping mutation `:227–231`, costume mutation `:254–262`, base-call observer `:125–131`.

**Trigger:** Start lip sync, remain silent or sustain one vowel, then open 口型与造型 and change the mouth mapped to the current vowel/silence, eyes, cheeks, mirror or random costume. The editor deliberately stays enabled during a live run (`LipSyncView.swift:40–44`).

**Evidence/impact:** Mutators compose and publish the new `previewFrame` but do not clear `lastSentVowel` or push the new composition. Each subsequent `tick` returns at line 467 when the detected vowel equals the last sent vowel, before pushing a frame. The preview changes immediately while the physical board keeps its former face indefinitely during sustained silence/vowel. The next vowel transition eventually resends it.

**Fix:** Deduplicate the composed frame, or invalidate the send gate on composition changes and republish once through the existing coalesced sender. Preserve phoneme dedup when the full frame is unchanged. A regression should keep the audio classifier on one vowel and verify a mapping/costume edit produces exactly one newly composed board frame.

**Confidence:** Direct data-flow proof; microphone/hardware reproduction not run by this worker. Existing broader lifecycle/DSP coverage is reviewed by the test worker.

### 2. Media sliders lack a non-drag seek commit; VoiceOver needs runtime verification

**Location:** `ios/RinaBoard/Features/PresetLive/PresetLiveView.swift:315–323`; `ios/RinaBoard/Features/Video/VideoPlayerView.swift:359–368`.

**Trigger:** Import valid media and increment/decrement the playback-position slider through VoiceOver rather than dragging its thumb.

**Evidence/impact:** Binding setters only assign `seekPositionMs`; while `isSeeking == false`, getters continue returning `model.positionMs`. The only seek commit is `onEditingChanged(false)`, which belongs to the drag editing lifecycle. A value adjustment without an edit-end callback neither seeks nor updates the exposed value. Whether VoiceOver emits that callback in these views remains unverified; independent validation narrows the finding accordingly. The Text slider explicitly implements `accessibilityAdjustableAction` for this exact problem (`ScrollTextView.swift:775–782`); the two media sliders do not. Local Apple reference `swiftui/slider.md` documents `onEditingChanged` as drag callbacks.

**Fix:** Add an adjustable action that calls `model.seek`, or commit binding updates whenever no drag is in progress. Provide a playback-position label/value. Verify both paused and playing media by accessibility adjustment; normal drag should still send one final seek.

**Confidence:** Proven missing path for value changes without edit-end; specific VoiceOver outcome remains a runtime verification candidate. No VoiceOver test performed.

### 3. Diagnostic refresh from a previous board can repopulate the new board's page

**Location:** `ios/RinaBoard/Features/Debug/DebugViewModel.swift:611–618` (global single-flight); stale writes `:623–634`, `:643–647`, `:658–659`; board-change path `:495–506`.

**Trigger:** With boards A and B connected, press Debug → 刷新全部 for A (`DebugView.swift:161`, creates an unstructured task). While a reply is pending, switch the Control Center target to B and return to Debug.

**Evidence/impact:** `pageAppeared(B)` changes `lastSessionKey`, clears the former snapshots, then calls `refreshOverview(B)`. Its shared `isRefreshingOverview` gate returns while A's manual refresh is running. A's refresh continues awaiting A's status/power/info and assigns each response to the shared model without checking connection identity or session generation. Since A remains connected, its request can succeed normally. B's page now shows A's firmware, battery and network data, and B's initial refresh was skipped. The decisive trigger is an uncancelled/unstructured manual refresh. Normal .task(id:) cancellation is checked in BoardConnection and is less likely to publish stale responses; it can still leave the new refresh skipped while the busy flag unwinds.

**Fix:** Scope refresh ownership and snapshots to the board/session; invalidate the former run when the page moves and reject every post-await result belonging to the old session. A new session should be able to launch its own read. Regression: hold A's response, call pageAppeared(B), release A and verify only B's fields survive.

**Confidence:** Direct main-actor reentrancy trace; no runtime dual-board reproduction run by this worker. This is state provenance, not an unsynchronized memory race.

### 4. Passive phone echoes in a crown page write a rounded value back to the board

**Location:** `ios/RinaBoardWatch/WatchCrownValueView.swift:96–105`; snapping `:154–158`; brightness configuration `WatchRootView.swift:187–198`.

**Trigger:** Keep the watch brightness page open at raw 50. After the touch-suppression window has expired, set raw brightness 67 from the phone or another client. The phone snapshot sets the watch's value to 67.

**Evidence/impact:** The `onChange(value)` callback copies the echoed 67 into `crownValue` because the difference exceeds the step (5). The `onChange(crownValue)` callback then snaps it to the 10+N×5 lattice (65), sees that 65 differs from the echoed 67, writes 65 and invokes `brightnessChanged()`, which sends `setBrightness(65)`. A passive snapshot therefore changes the physical board without a crown turn or button press. Auto-interval has the same issue: the phone supports 0.1-second increments while this crown page snaps to 0.5 seconds.

**Fix:** Distinguish a programmatic crown-origin synchronization from user input, and suppress its command callback. Keep arbitrary confirmed values until the user actually adjusts them. Regression should update an open control with an off-step value and assert zero outbound commands.

**Confidence:** Exact callback sequence and arithmetic from source; watch UI/runtime not exercised. Example snap: 10 + round((67−10)/5)×5 = 65.

### 5. Read-only CMD queries in the debug terminal stop live output

**Location:** `ios/RinaBoard/Features/Debug/DebugViewModel.swift:911–915`.

**Trigger:** While lip sync, a performance or video is running, open Debug → 终端 and send its default input `get_info` (or query JSON `{"cmd":"get_info"}`).

**Evidence/impact:** The terminal takes a `.debug` lease for every `.cmd` frame, even though `get_info` is classified as a query in `DebugCommandCatalog.swift:54`. `BoardPlaybackCoordinator.begin` synchronously invokes the previous output stop handler. `RootTabView.swift:283–294` registers those handlers to stop microphone capture or pause media. Thus querying firmware information stops the ongoing activity before the read is sent; PING/GET_STATUS/GET_POWER avoid the issue only because they use different frame types. Raw `send` itself does not perform control fan-out, so read queries need not lease merely to keep the terminal board-local.

**Fix:** Only take output ownership for commands that actually change the displayed activity; known read-only queries and subscription/settings operations should send without a takeover. Preserve intentional terminal takeover for display commands. Add an ownership-preservation test for `get_info` alongside a mutating-command takeover test.

**Coverage:** Fully read `DebugSerialMonitorTests.swift`: existing send tests check reply text/redaction/rejection, but do not install producer stop handlers or assert read-only query ownership preservation.

**Confidence:** Direct call-chain proof; no live audio run by this worker.

## Architecture candidates (separate from defect priority)

| Candidate / files | Problem | Direction | Test seam and benefits |
|---|---|---|---|
| Diagnostic snapshot module — `DebugViewModel.swift` | Session identity, global refresh gate and independent mutable fields are separate invariants callers must coordinate. | Give board-scoped refresh and publication one ownership location; keep formatting/console state separate from board snapshots. | Existing fake transport can suspend replies and switch boards. Deepening gives locality for cancellation/provenance instead of adding guards at every view. |
| Media scrub module — `PresetLiveView.swift`, `VideoPlayerView.swift`, `ScrollTextView.swift` | Three implementations duplicate draft/drag/commit semantics, and only Text handles non-drag input. | Consolidate user-position editing behavior across the existing media players without inventing a player protocol. | Exercise the same interface for drag and accessibility input; preserve each player's seek operation. Reduces hidden ordering obligations. |
| Watch value-control module — `WatchCrownValueView.swift`, `WatchSessionModel.swift` | One state-change callback conflates confirmed echoes with user adjustments, and outgoing draft handling is separate. | Keep input provenance and echo reconciliation together so a confirmed-value update cannot issue a command. | A real seam already exists at outgoing watch commands. Fake sender/snapshots can prove echoes are read-only and crown edits coalesce. |
| Lip-sync publication module — `LipSyncModel.swift`, `LipSyncProcessor.swift` | Phoneme dedup hides a second changing input: composition. Every mapping caller implicitly needs to reset publication. | Make frame composition/publication own dedup across both phoneme and costume. DSP should keep classifying independently. | Injected `LipSyncCapturing` plus fake board transport already vary at real seams. Tests can sustain a single classifier result while changing mapping. |
| Library ownership module — `FaceLibraryModel.swift` | Local disk transactions and board generation/reload state share a large observable surface; invariants are concentrated but mixed. | Separate confirmed local and board document ownership internally while retaining one concise feature-facing library interface. | The existing `LocalFaceStoring` fake and board transport are real adapters; preserve transaction and conflict tests through the same external seam. Avoid a new pass-through layer. |

## Other inspected concerns, not filed as defects

- Video frame quantization is bounded/off-main through `LatestFrameProcessor`; lip DSP runs on its actor with one analysis outstanding. Text render tick state is narrowed through `TextPreviewPlayhead`. Bloom contours cache immutable paths behind a lock. No trace-backed perf regression was established.
- Parent strict-concurrency diagnostic output includes immutable Core Animation/CoreText references, main-queue NotificationCenter callbacks, diagnostic counters and compiler region-checker limitations. Source review did not establish a current Swift 5 race from those warnings. Parent owns the separate warning-budget gate failure (50 sites vs baseline 44).
- `WatchCoalescedSender.reset()` leaves pending drafts alive; a very fast target switch could redirect a pending value. Not filed because the actual navigation timing and message ordering were not demonstrated; the passive-echo bug above has a deterministic trigger.
- Personal-hotspot name field binds directly to `hotspotName` rather than `setHotspotName`, leaving old per-SSID password state possible. Not filed as an independent defect without resolving the intended field-edit semantics.

## Video test failure investigation

Fully read `VideoPlaybackRecoveryTests.swift` and `VideoProgressPublishingTests.swift`. Parent reports both failures reproduced alongside Fig decoder errors; their root cause remains unresolved. Do not call the suite green or label these simply flaky.

- `testMatchingSavedVideoResumesBoardPositionWithOriginalStreamID` waits for `.setFrame`. Restore seeking invalidates `lastLuma`; `startPlayback` cancels the still task and `refreshCurrentFrame` has nothing to publish. The test consequently requires the actual video output decoder to yield a fresh frame, not only correct identity restoration. Failure after ~2.2 seconds is the fake transport's wait deadline.
- `testCheckpointAtEndOfPlaybackIsExactDuration` already retries early automatic pauses three times. Parent's failure (`isPlaying == true`, `positionMs == 0` after 10 seconds) indicates an unadvanced playback/decoder, not the coarse-publishing arithmetic. No conclusive new code regression was proven. Further diagnosis needs current-item status/error, timeControlStatus/reasonForWaiting and rate/currentTime on the failing simulator.
- Production handles a zero playback rate by pausing, but does not report AVPlayerItem failures separately. This is a follow-up hypothesis, not a confirmed P2 from these logs.

## Resources and metadata verification

- Entire Xcode project/config, both schemes, workspace, Info.plist and entitlements manually read. Filesystem-synchronized groups cover feature/watch sources and shared `RinaWatchLink` in both targets; main iOS target is 17.0, Swift 5.0; watch 10.0, Swift 5.0; watch is embedded as dependent companion. No unintended Swift 6 or iOS 26 minimum is asserted.
- 10 `.rinalive` files, all directives and all **2,374** keyframes structurally interpreted against the fully read `LivePerformanceScriptParser` grammar. Every frame is nonnegative/bounded/strictly increasing; every four-part call resolves; FPS directives all resolve to 10. All nine catalog keyframe counts/durations match exactly. Full directive evidence: `/tmp/rina-audit-ios-resource-validation.json`.
- All **92** expression parts checked for frame size/tail bits/lit counts and physical-to-logical strip parity. All **11** default faces have valid packed frame ranges, unique IDs and a valid startup reference. All 370 matrix entries and wiring permutation agree. All **33,476** font glyph tuples/rows/scalar keys agree with metadata (empty skin-tone modifier glyphs handled as zero-height).
- All nine JSON resources decoded; config/scroll defaults/catalog/ark12 metadata manually inspected. Four string catalogs structurally decoded and localization coverage enumerated. Missing source-language entries correctly fall back to source keys; many absent translations are numeric/technical/obsolete entries, so no blanket translation defect is claimed.
- Every asset catalog `Contents.json` manually read; every named image reference exists. Declared font, board/loading images and all nine catalog audio files exist. Binary contents/artwork/audio and linguistic quality are outside this read-only source audit.
- Fresh resource checks succeeded: `/tmp/rina-audit-ios-resource-checks.txt`. Resource literal rows were structurally validated, not manually read as prose. This is the explicit exception for generated bitmap/font/timeline data.

## Coverage manifest and limitations

- Production Swift manually read: **82 files, 23,713 lines**.
- Manual project/metadata/docs: **10 files**.
- Resource structural checks: **37 files** (9 JSON, 4 string catalogs, 10 timelines, 14 asset Contents.json).
- Additional full test reads: **3 files**; complete test coverage delegated to `/root/test_audit` by parent.
- No gaps in the 82-file assigned feature/watch production-source set. Services/App/Core are references only and primarily reviewed by the other workers. No whole-test-suite coverage claimed here.
- No device/watch/VoiceOver runtime repro or profiling trace. Parent owns builds/tests; static findings are distinguished from observed failures.

### All production source files fully read

- `ios/RinaBoard/Features/Boot/BootAnimationTimeline.swift`
- `ios/RinaBoard/Features/Boot/BootLoaderModel.swift`
- `ios/RinaBoard/Features/Boot/BootLoaderOverlay.swift`
- `ios/RinaBoard/Features/Boot/BootRevealModifier.swift`
- `ios/RinaBoard/Features/Connection/AddBoardView.swift`
- `ios/RinaBoard/Features/Connection/BoardNetworkSettingsView.swift`
- `ios/RinaBoard/Features/Connection/ConnectionView.swift`
- `ios/RinaBoard/Features/Connection/ConnectionViewModel.swift`
- `ios/RinaBoard/Features/Control/ControlView.swift`
- `ios/RinaBoard/Features/Control/ControlViewModel.swift`
- `ios/RinaBoard/Features/Control/FacePartSelectorView.swift`
- `ios/RinaBoard/Features/ControlCenter/BoardBattery.swift`
- `ios/RinaBoard/Features/ControlCenter/BoardControlCenterAccessory.swift`
- `ios/RinaBoard/Features/ControlCenter/BoardControlCenterModel.swift`
- `ios/RinaBoard/Features/ControlCenter/BoardControlCenterView.swift`
- `ios/RinaBoard/Features/Debug/BoardConnection+Debug.swift`
- `ios/RinaBoard/Features/Debug/DebugCommandCatalog.swift`
- `ios/RinaBoard/Features/Debug/DebugSerialMonitor.swift`
- `ios/RinaBoard/Features/Debug/DebugView.swift`
- `ios/RinaBoard/Features/Debug/DebugViewModel.swift`
- `ios/RinaBoard/Features/Debug/RingBuffer.swift`
- `ios/RinaBoard/Features/Faces/BoardConnection+Faces.swift`
- `ios/RinaBoard/Features/Faces/FaceLibraryModel.swift`
- `ios/RinaBoard/Features/Faces/FaceLibraryView.swift`
- `ios/RinaBoard/Features/Faces/FaceNameEditorSheet.swift`
- `ios/RinaBoard/Features/Faces/FaceNumberLedger.swift`
- `ios/RinaBoard/Features/Faces/FaceNumberRegistry.swift`
- `ios/RinaBoard/Features/Groups/BoardGroupEditorView.swift`
- `ios/RinaBoard/Features/Groups/BoardGroupListView.swift`
- `ios/RinaBoard/Features/Groups/BoardGroupStatusFormatting.swift`
- `ios/RinaBoard/Features/Groups/GroupMemberStatusList.swift`
- `ios/RinaBoard/Features/Groups/GroupPreviewPolicy.swift`
- `ios/RinaBoard/Features/Groups/GroupScrollPreview.swift`
- `ios/RinaBoard/Features/LipSync/LipSyncAudioCapture.swift`
- `ios/RinaBoard/Features/LipSync/LipSyncModel.swift`
- `ios/RinaBoard/Features/LipSync/LipSyncProcessor.swift`
- `ios/RinaBoard/Features/LipSync/LipSyncView.swift`
- `ios/RinaBoard/Features/PresetLive/PerformanceTabView.swift`
- `ios/RinaBoard/Features/PresetLive/PresetLiveModel.swift`
- `ios/RinaBoard/Features/PresetLive/PresetLiveView.swift`
- `ios/RinaBoard/Features/Settings/AboutView.swift`
- `ios/RinaBoard/Features/Settings/AppSettings.swift`
- `ios/RinaBoard/Features/Settings/ApplicationSettingsView.swift`
- `ios/RinaBoard/Features/Settings/BoardSettingsView.swift`
- `ios/RinaBoard/Features/Settings/SettingsCategory.swift`
- `ios/RinaBoard/Features/Settings/SettingsView.swift`
- `ios/RinaBoard/Features/Settings/SettingsWorkspace.swift`
- `ios/RinaBoard/Features/Shared/Background/RinaAppBackdrop.swift`
- `ios/RinaBoard/Features/Shared/Background/RinaPalette.swift`
- `ios/RinaBoard/Features/Shared/Background/RinaStarfield.swift`
- `ios/RinaBoard/Features/Shared/Background/RinaStarfieldSourceSpec.swift`
- `ios/RinaBoard/Features/Shared/CardContainer.swift`
- `ios/RinaBoard/Features/Shared/Components/AppLayout.swift`
- `ios/RinaBoard/Features/Shared/Components/BoardSplitPage.swift`
- `ios/RinaBoard/Features/Shared/Components/ColorHex.swift`
- `ios/RinaBoard/Features/Shared/Components/ErrorAlert.swift`
- `ios/RinaBoard/Features/Shared/Components/KeyboardDismissal.swift`
- `ios/RinaBoard/Features/Shared/Components/PillButtonStyle.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/BoardPreviewRow.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/BoardPreviewZoom.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/LEDBloomRenderer.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/LEDBoardGeometry.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/LEDBoardPreview.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/PencilHoverTracker.swift`
- `ios/RinaBoard/Features/Shared/LEDBoardPreview/SavedFaceThumbnail.swift`
- `ios/RinaBoard/Features/Shared/LatestFrameProcessor.swift`
- `ios/RinaBoard/Features/Shared/LatestValueSender.swift`
- `ios/RinaBoard/Features/Shared/PlaybackAudioSession.swift`
- `ios/RinaBoard/Features/Shared/RinaPerf.swift`
- `ios/RinaBoard/Features/Text/ArkPixelInputFont.swift`
- `ios/RinaBoard/Features/Text/ScrollTextView.swift`
- `ios/RinaBoard/Features/Text/TextPlaybackControls.swift`
- `ios/RinaBoard/Features/Text/TextPreviewPlayhead.swift`
- `ios/RinaBoard/Features/Text/TextViewModel.swift`
- `ios/RinaBoard/Features/Video/VideoPlayerModel.swift`
- `ios/RinaBoard/Features/Video/VideoPlayerView.swift`
- `ios/RinaBoardWatch/RinaBoardWatchApp.swift`
- `ios/RinaBoardWatch/WatchColorPickerView.swift`
- `ios/RinaBoardWatch/WatchCrownValueView.swift`
- `ios/RinaBoardWatch/WatchRootView.swift`
- `ios/RinaBoardWatch/WatchSessionModel.swift`
- `ios/RinaBoardWatch/WatchTargetPickerView.swift`

### Manual metadata/docs

- `ios/RinaBoard.xcodeproj/project.pbxproj`
- `ios/RinaBoard/Info.plist`
- `ios/RinaBoard/RinaBoard.entitlements`
- `ios/RinaBoard.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `ios/RinaBoard.xcodeproj/xcshareddata/xcschemes/RinaBoard.xcscheme`
- `ios/RinaBoard.xcodeproj/xcshareddata/xcschemes/RinaBoardWatch.xcscheme`
- `ios/RinaBoard/Resources/README.md`
- `ios/README.md`
- `ios/RinaBoard/Resources/Fonts/UnifontLoading-NOTICE.txt`
- `ios/RinaBoard/Resources/Assets.xcassets/TabRinaSettings.imageset/TabRinaSettings.svg`

### Structurally checked resource files

- `ios/RinaBoard/Resources/ark12.json`
- `ios/RinaBoard/Resources/ark12_meta.json`
- `ios/RinaBoard/Resources/color_presets.json`
- `ios/RinaBoard/Resources/default_faces.json`
- `ios/RinaBoard/Resources/expression_parts.json`
- `ios/RinaBoard/Resources/matrix_geometry.json`
- `ios/RinaBoard/Resources/preset_live_catalog.json`
- `ios/RinaBoard/Resources/scroll_text_defaults.json`
- `ios/RinaBoard/Resources/webui_config.json`
- `ios/RinaBoard/Resources/InfoPlist.xcstrings`
- `ios/RinaBoard/Resources/Localizable.xcstrings`
- `ios/RinaBoard/Resources/PresetNames.xcstrings`
- `ios/RinaBoardWatch/Resources/Localizable.xcstrings`
- `ios/RinaBoard/Resources/performance_lumf.rinalive`
- `ios/RinaBoard/Resources/performance_poppin_up.rinalive`
- `ios/RinaBoard/Resources/performance_solo0.rinalive`
- `ios/RinaBoard/Resources/performance_solo1.rinalive`
- `ios/RinaBoard/Resources/performance_solo2.rinalive`
- `ios/RinaBoard/Resources/performance_solo3.rinalive`
- `ios/RinaBoard/Resources/performance_solo4.rinalive`
- `ios/RinaBoard/Resources/performance_solo5.rinalive`
- `ios/RinaBoard/Resources/performance_tkmk.rinalive`
- `ios/RinaBoard/Resources/preset_live_demo.rinalive`
- `ios/RinaBoard/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/RinaBackgroundStar1.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/RinaBackgroundStar2.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/RinaBackgroundStar3.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/RinaBackgroundStar4.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/RinaBackgroundStar5.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/TabRinaFace.imageset/Contents.json`
- `ios/RinaBoard/Resources/Assets.xcassets/TabRinaSettings.imageset/Contents.json`
- `ios/RinaBoardWatch/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- `ios/RinaBoardWatch/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `ios/RinaBoardWatch/Resources/Assets.xcassets/Contents.json`

### Additional full test file reads

- `ios/RinaBoardTests/VideoProgressPublishingTests.swift`
- `ios/RinaBoardTests/VideoPlaybackRecoveryTests.swift`
- `ios/RinaBoardTests/DebugSerialMonitorTests.swift`

## UI smoke failure checked at parent request

Parent smoke ran three UI cases and failed only `RinaBoardUITests.testLegacyControlCenterAndFaceLibraryAreReachable` at line 39; its navigation-bar assertion succeeded. The failing line queries `app.buttons` for a label containing 预设. Current `FaceLibraryView.row` (lines 305–347) is an HStack containing thumbnail/name/caption Text plus separate pencil/send Buttons. The preset caption at line 330 is not inside a row Button. The test comment claiming a Button-wrapped row is stale; failure is a definite selector-role drift, not a translation change and not evidence that the library is empty. Test worker owns the full UI test review; this worker read the relevant first 65 lines only, so the UI test file is not in the full-read manifest.
