# Shared iPad and Mac app implementation plan

**Goal:** Ship a Mac version of the existing iPad app from the same sources and test real boards from the Mac, disconnecting and clearing any test pairings afterward.

**Architecture:** Enable Mac Catalyst's iPad interface idiom on the existing app target. Keep all screens, feature models, transports, resources and protocol code shared. Isolate only APIs unavailable on macOS, with appropriate Mac adapters rather than copies of features.

**Constraints:** Preserve existing audit/user changes; no commits or pushes. Match the iPad layout rather than redesigning it. Device tests are opt-in, target only the two known boards, restore transient changes and wait for actual BLE cancellation. Inspect and remove only board pairings after testing.

- [x] Establish the unsupported Mac build, enable Catalyst and iPad idiom with platform-specific entitlements and Watch embedding.
- [x] Compile shared sources; implement/test only required platform adapters and verify iPad behavior remains intact.
- [x] Build/run the Mac app and verify its shared iPad screens and representative unit/UI tests.
- [x] Add an opt-in production-transport board test with guaranteed disconnect cleanup; test both physical boards and verify identity/output/status.
- [x] Verify Mac disconnects, inspect/remove board pairings, and document reusable test commands and shared-source synchronization.
- [x] Independently review changes and run final Mac/iOS checks; record actual results and any platform limitations.
