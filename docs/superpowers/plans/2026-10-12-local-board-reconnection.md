# Local board reconnection implementation plan

Goal: Keep each physical board reachable through its available Bluetooth or local Wi-Fi carriers, with immediate retry and a reliable stop for automatic attempts.

Architecture: BoardConnection owns one bounded retry loop and its cancellation epoch. BoardSession supplies same-board alternate transports from its BLE aliases and board-reported local STA address. Each alternate handshake must verify the expected physical board identity. ConnectionView exposes retry controls. Shared sources serve iPad and Mac.

User scope: Bluetooth, board-scanned Wi-Fi and board AP modes. Wi-Fi is local and has no Internet prerequisite. Stop the Mac board-hotspot association experiments; do not create a Mac hotspot or automatically change Mac Wi-Fi networks.

- [x] Add same-board reconnect candidates, immediate retry and stop APIs to BoardConnection; test failed carrier fallback, stopped/superseded work, identity mismatch and bounded exhaustion.
- [x] Supply candidates in BoardSession without global active-board changes, metadata replacement or saved-preference changes; test two independent sessions and missing endpoints.
- [x] Add immediate retry and stop automatic retry controls to ConnectionView, reflecting real retry state.
- [x] Batch software verification and one shipping Mac build including paused reorder preview retention. Verify iPad build.
- [x] Reflash clean firmware without temporary ps/bw/phy diagnostic setters. Use the Mac app to scan networks on both boards, provision the existing test network, and confirm BLE remains usable in Wi-Fi/AP modes.
- [ ] Test local TCP, same-board automatic fallback, manual retry, stopping during a pending attempt, and multiboard sends/switching. Do not treat alternate Bluetooth success as proof that a failing TCP path is fixed.
- [ ] Retest true held drag and preserved preview during paused reorder. Restore boards, forget their test Wi-Fi, restore Mac network and remove test-only permissions/groups/links.

Validation evidence remains in docs/mac/2026-10-12-board-ip-testing.md. No commits, publishing or system authentication exemptions.

2026-10-13 continuation: 729 software tests, one opt-in skip, zero failures; shared Mac/iPad builds passed and the signed Mac release was installed. New bounded manual fallback retains station alternatives learned before teardown. Both physical USB ports are absent, so final per-board manual retry and scrolling stress are pending reconnection. Prior held-drag verification passed; B's Mac test-AP profile removal still needs confirmation.
