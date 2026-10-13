# Independent video repair review

Read-only review of the working-tree VideoPlayerModel.swift and VideoProgressPublishingTests.swift changes against HEAD, surrounding player/still-frame/seek/end/processor lifecycles, and the current SDK AVAssetImageGenerator contract. Reused `/tmp/rina-video-green.log` (16 passing tests), without duplicating the suite. No code or user changes.

## One actionable finding

### [P2] Portrait still frames use the unrotated bounding box and lose sampling resolution

**Location:** `ios/RinaBoard/Features/Video/VideoPlayerModel.swift:422` (`generator.maximumSize = size`), where size is now derived from naturalSize at402 while preferred transform remains enabled at421.

**Trigger:** A conventional portrait phone clip encoded as a landscape natural track with a90/270degree preferredTransform, then initial/import preview, paused seek, or stopped-frame regeneration.

**Evidence:** The native decoded-buffer request correctly remains in natural orientation. For1920x1080 it requests160x90; orientedLuma then yields90x160. But AVAssetImageGenerator has appliesPreferredTrackTransform=true, so it produces an upright1080x1920 picture and now fits that into the unrotated160x90 maximum box. SDK AVAssetImageGenerator.h:101–103 explicitly requires images to fit that bounding box without changing aspect ratio. The generated still is therefore about51x90, instead of90x160. Before this repair, composition.renderSize was already oriented, so the generator received the correct portrait90x160 box.

**Impact:** Portrait paused/import/seek images are unnecessarily downsampled again, losing thin detail and potentially changing threshold/dither LED decisions when switching between the same still image and playback. The pure3x2 orientation regression does not instantiate the generator; all generated playback fixtures are square64x64, so the16green tests do not cover this path.

**Minimal correction:** Keep naturalSize for the native video output, but size the already-transformed image generator independently:

```swift
let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
generator.maximumSize = Self.samplingSize(for: orientedBounds.size)
```

Add a nonsquare90degree asset fixture and assert its generated still uses the portrait sampling box, ideally retaining the same quantized picture across still/playback for a static asymmetric source. Root owns the patch and validation.

**Confidence:** Direct dimension calculation and SDK bounding-box semantics, not an unobserved timing theory. No separate live media probe was run.

## No additional concrete findings

- For standard90/180/270degree orientation and axis mirrors, orientedLuma normalizes transformed bounds, inverse-samples pixel centers, and discards original-resolution translation correctly. Transform is captured with the frame job and applied before quantization; user mirror remains a separate quantizer setting. Existing pure regression's clockwise rotation and horizontal mirror expectations agree with the row-major source convention.
- Waiting-to-play is not treated as an interruption merely because rate iszero; playbackClockStarted resets for each start and only actual observed playing enables the paused/ratezero interruption path.
- Failed items take pause(), which cancels pending output/processor work and checkpoints exact progress before publishing the item's error. This is a direct failure-state stop path rather than an endlessly waiting decoder.
- Natural completion still uses didPlayToEndTimeNotification and exact duration checkpoint; retained test now fails on premature pause/decoder failure instead of restarting playback to hide it.
- Teardown invalidates pending processing, removes the item observer/output, and stops the player; processed jobs retain their own transform, avoiding a current-track transform read from background work.

## Test/evidence boundary

The16passing video tests establish the previouslyred recovery/end-clock behavior with the generated native-playback fixture and pure orientation mappings. They do not demonstrate a real rotated/mirrored asset through both AVPlayerItemVideoOutput and the still-image generator. No speculative singular-affine hardening, decoder retries, new timeout policy, or unrelated lifecycle refactor is requested.
