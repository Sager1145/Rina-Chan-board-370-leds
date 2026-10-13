# iOS, watch, macOS UI audit — incomplete checkpoint

**Status: INCOMPLETE.** Work paused on 2026-10-13 at the user's request to commit and push the current tree. This is a read-only audit checkpoint, not a completed full-scope result. No source files were edited, and no build, test, device, network, or external action was run by this worker.

The inventory in `ios-ui-coverage.csv` contains 165 assigned files after excluding generated caches and user-specific Xcode data. The 2026-10-12 full audit supplies prior coverage for unchanged files. Thirty-six files in this working tree are changed or newly added and need a complete current rereview. Some of those changes and their supporting paths were inspected before the interruption, but the manifest deliberately retains `pending-current-review` for them rather than claiming full coverage. In particular, new macOS Catalyst transport and layout work, network transport selection, group drag behavior, Xcode project settings, and localization catalog changes still need complete review.

## Confirmed findings

### P2 — pending watch crown edit can land on a newly selected board

**Location:** `ios/RinaBoardWatch/WatchSessionModel.swift:148-156`, `:235-253`; phone command routing at `ios/RinaBoard/Services/WatchLinkService.swift:332-350`.

**Trigger:** Spin a watch value crown so the coalescing sender has a pending value, then quickly choose a different target in the watch target picker. `selectTarget` calls `reset()` on each sender and sends `.selectTarget`, but `reset()` only clears `lastSent`. The `pending` value and sleeping `drain` task remain. Once the drain wakes, it sends the old board's draft as a target-free command. The phone routes that command using its current `selectedTargetID`, which can now be the newly selected board. This can unexpectedly alter its brightness, auto interval, scroll speed, or lip-sync sensitivity. The exact arrival order depends on WatchConnectivity scheduling, but the cross-target pending path exists directly in source.

**Fix direction:** On target change, discard pending values and cancel/invalidate each sender's drain. A generation token for outgoing value commands would also make target ownership explicit. Test with a controlled sender clock: submit twice inside one interval, change target, advance the clock, and assert the old pending value is never emitted. Also verify the next intentional edit of the same value sends on the new target.

### P2 — failed refresh can leave an unreadable local face archive writable

**Location:** `ios/RinaBoard/Features/Faces/FaceLibraryModel.swift:270-320`, `:1109-1112`, `:1189-1202`; store read errors at `ios/RinaBoard/Services/LocalFaceStore.swift:29-58`.

**Trigger:** Load the local face archive successfully, then make the backing `local_faces.json` malformed or temporarily unreadable and invoke `reloadLocal` (the library's explicit refresh). The generic `catch` sets only `errorMessage`; it retains `isLocalLoaded == true`, the old in-memory document, and any local deletion undo record. `loadLocalForMutation()` then skips reloading because that flag remains true, and a later local edit can call `commitLocal` to atomically overwrite the unreadable archive with stale in-memory contents. The special `partiallyUnreadable` catch already blocks saves, but malformed JSON and I/O failures take the generic path.

**Fix direction:** A failed explicit reload should revoke mutation authority (`isLocalLoaded = false`) and invalidate stale undo state while retaining the last good document only for display. A successful fresh load can restore authority. Regression: initial load succeeds; make the store throw a generic malformed/read error on refresh; attempt rename/delete/undo; assert no save occurs and the original file remains untouched.

## Current review notes

- The prior audit's lip-sync composition, media slider accessibility, debug snapshot provenance, read-only debug command ownership, and passive watch echo findings have corresponding source changes in the current tree. These were inspected at the diff/call-path level and are not repeated as open findings here. Their complete validation belongs to the continuing audit and parent test work.
- `WatchCrownValueView` now separates confirmed phone synchronization from user crown input through `WatchCrownInput`; that addresses the prior passive echo callback path. The pending-sender target transition above remains separate.
- No runtime reproduction was performed. Both findings are source-traced and need regression tests before a fix is called verified.

## Architecture opportunity (separate from defect priority)

Watch value publication and target selection currently have separate ownership: value senders know only values while phone routing uses whichever target is current at send time. A small target-scoped publication module could own pending drafts, target generation, and coalescing behind one interface, making cross-target correctness testable at a single seam.
