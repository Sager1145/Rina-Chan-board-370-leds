# WebUI boot-loader animation — port spec (legacy/webui_v1 → SwiftUI)

Sources: `legacy/webui_v1/data/index.html:32-64`, `styles.css:2647-2956`, `app.js:26-190`
(`WEBUI_CONFIG.boot`), `app.js:6024-6346` (loader state machine), `13868-13912` (waterfall).

## Constants
holdMs 260 · haloBreathMs 1620 · haloPeakRatio 0.5 · haloToleranceMs 24 · haloContractMs 520 ·
imageReleaseMs 2100 · blurDurationMs 850 · extraMs 180 · minDisplayMs 400 · revealEdge 100 px ·
IMG_SHRINK_MS = round(2100×0.18) = 378 · waterfall stagger 115 ms/item, settle 260 ms.

## Geometry / colours
- Icon 96 px, white frame 5 px → avatar circle 106 px (white, round; the images themselves are drawn at 106 px — see Corrections). Halo spread 18 px → ring outer diameter 142 px.
- Halo ring gradient (radial, from centre; the stops are `calc(50% − k)` where 50 % is half the *farthest-corner ray* ≈ 50.2 px, not the 71 px box radius — see Corrections): transparent to 50%−18; white .55 at 50%−15; pink(249,113,212) .72 at 50%−11; .40 at 50%−6; .13 at 50%−1; transparent at the ray's end; the box is clipped round at 71 px. `filter: blur(2.4px) drop-shadow(0 0 10px rgba(249,113,212,.36))`.
- Backdrop: rgba(15,17,23,.55) + blur 14 px over the app content.
- Text "LOADING": rgba(249,200,240,.85), 15 px, weight 700, letter-spacing .12em, uppercase, below the avatar.
- Icons: `rina_icon1_default.png` (before), `rina_icon2_hover.png` (after) — in `ios/RinaBoard/Resources/Images`, 420 px renders supplied for iOS (the WebUI ships 160 px); iOS keeps them at 420 px, mapped onto the 106 pt circle (≈3.96 px/pt), so the 2.35× release still has headroom on a 3× panel.
- Text font: the page font, GNU Unifont (`--ui-font`); the CSS `font-weight: 700` is not synthesised (`font-synthesis: none`), so it renders at the font's single weight. iOS bundles an ASCII subset of the WebUI's own `unifont.woff2` as `UnifontLoading.ttf` (PostScript name `GNUUnifont-WebUIOfflineSubset`).

## Timeline
| Phase | Start | Duration | Easing | What changes |
|---|---|---|---|---|
| P0 breathe | overlay shown | loop 1620 ms | cubic-bezier(.42,0,.58,1) | halo opacity .28↔1, scale .965↔1.075 (peak at 50 %) |
| P1 align | finish requested (after content ready AND ≥400 ms shown) | wait until next halo peak (±24 ms; iOS: at most 450 ms, see deviations) | — | nothing |
| P2 contract + pop | t0 | halo 520 ms; avatar 620 ms | halo cubic-bezier(.55,.085,.68,.53); avatar cubic-bezier(.16,1.25,.3,1) | halo scale 1.075→.65, opacity→0 then hidden; avatar circle scale→1.22; icon swap: default stays 180 ms then snaps to 0 while hover icon fades in over 180 ms; both scale 1.025; text fades out + translateY 6 px over 220 ms |
| P3 hold | t0 (concurrent with the contraction — see Corrections) | 260 ms | — | nothing new starts |
| P4 release | t0+260 | 2100 ms keyframes | 0 %: scale 1.22 op 1 (bezier .34,0,.2,1) → 18 % (378 ms): scale 1.12 op 1 (bezier .12,.88,.18,1) → 100 %: scale 2.35 op 0 | avatar circle |
| P4b reveal | P4 + 378 ms (iOS: feather from P4 + 478 ms, hole from P4 + 598 ms, see deviations) | 850 ms | ease-in-cubic t<.5 ? 4t³ : 1−(−2t+2)³/2 (iOS: r = R·t², see deviations) | radial mask centred on the avatar grows from 0 to the farthest corner + 90 px with a 100 px feather **outside** it, unblurring the app underneath; overlay stops intercepting touches |
| P5 done | P4 + max(2100, 378+850) + 180 = 2280 ms (= t0+2540) | — | — | overlay opacity 0, removed after a **further** 180 ms (total P4+2460 = t0+2720) |

## Card waterfall (first page)
Cards start `opacity 0, translateY 10 px, hidden`; revealed top-to-bottom, one every 115 ms,
each with `opacity 320 ms ease` and `translateY 360 ms cubic-bezier(.16,1,.3,1)`; 260 ms settle
after the last. Runs while the loader is still covering the screen (its reveal mask shows it).

## Rules
- Loader is time/asset based only; it does not wait for the board. Board status fetch begins after the loader is gone.
- Reduced motion: halo breath slows to 2.6 s; waterfall becomes instant (1 ms, no slide). The contract/release/mask sequence still plays.

## Corrections to this document (verified against the sources above)
Points where the table above was wrong or lossy; the iOS port follows the sources, not the table.
- **Peak alignment is a tolerance, not a hold-off.** Within ±24 ms of the peak, start *immediately* (`app.js:6233-6236`). Waiting for the "next" peak adds a full 1.62 s.
- **The hold does not wait for the halo.** `app.js:6262-6268` schedules `is-halo-hidden` fire-and-forget at 520 ms and awaits only `HOLD_MS`, so `is-final-release` lands at **t0+260**, the reveal at t0+638 and removal at t0+2720 — 520 ms earlier than the table's original P3/P4/P5 starts. The release keyframes take the circle over mid-pop (from ≈1.223 down to the 0 % value 1.22, a 0.003 step); the icons finish their own 620 ms pop.
- **The reveal feather is outside the hole**, not inside: clear to r, ramping to opaque over r→r+100 (`styles.css:2706-2716`). Inverting it leaves scrim in the corners at progress 1.
- **The backdrop is unmasked until P4b.** The radial mask belongs to `.blur-screen.is-revealing` only (`styles.css:2706`). Because its 100 px feather lies outside the hole, applying it at radius 0 from the start punches a soft 100 px hole in the scrim behind the halo for the whole breathing phase.
- **The avatar images are 106 px, not 96.** `.avatar-circle img { width/height: var(--rina-avatar-size); object-fit: contain }` inside `overflow: hidden; border-radius: 50%` (`styles.css:2760-2790`): the artwork fills the circle edge to edge and is clipped to it. "Icon 96 px + 5 px frame" only describes the CSS variables, not what is drawn.
- **The icon cross-fade overlaps.** The hover icon fades in over [0, 180] with no delay; the default icon only *then* snaps to 0 (`styles.css:2793, 2811-2820`). Running the two back to back exposes a bare white circle.
- **The halo contracts on one curve.** `.flash-halo` declares per-property transitions (`styles.css:2845-2847`), but adding `.is-ring-contracting` changes only the `animation` property — the declared `opacity`/`transform` values do not change, so no transition ever fires — and the `rinaBoot-haloContractOut` keyframes (`styles.css:2851-2853`) drive scale and opacity with the one cubic-bezier(.55,.085,.68,.53).
- **"LOADING" sits ≈100 px below the avatar centre**: `.loading-box` is a grid of the 142 px stage and the label with a 20 px gap (`styles.css:2732-2743`), not a fixed offset from the halo's shadow bounds.
- **P4b's easing is ease-in-*out*-cubic**, despite the "ease-in-cubic" label; the formula given is correct.
- **P5 is a snap, then a wait.** `.loading-overlay.is-hidden { opacity: 0 }` has no transition (`styles.css:2718-2721`); the overlay vanishes at once and is removed from the DOM 180 ms later.
- **The waterfall sleeps after the last card too** (`app.js:13906-13910`): n items take n×115 ms + 260 ms settle.
- **The halo gradient's percentages resolve against the farthest-corner ray, not the box radius.** `radial-gradient(circle at 50% 50%, …)` with no explicit size is `farthest-corner`, so on the 142 px box `50%` is 71·√2 ≈ 100.4 px and `calc(50% − 18px)` ≈ 32 px. The bright band (white .55 → pink .72 → .40 → .13 over 35–49 px) therefore lies *under* the 53 px avatar, and what the browser shows beyond the avatar is only the .13→0 tail out to the 71 px `border-radius` clip plus the drop shadow — a faint pink haze, not a ring (verified side by side in the browser, 2026-09-11). iOS draws it the same way (`BootTimeline.haloGradientRay`).
- **`drop-shadow(0 0 10px)` is a blur diameter.** A renderer taking a Gaussian sigma (e.g. SwiftUI `.shadow(radius:)`) needs 5.

## Deliberate iOS deviations
Choices the port makes on purpose; do not "fix" them back to the table without reading why.
- **Peak wait capped at 450 ms** (`BootTimeline.maxPeakWait`), and the halo contracts from its *current* breath values instead of the keyframes' snap to the peak values. The legacy wait of up to 1.62 s exists only to hide that snap; on iOS the waterfall (3×115+260 ms) plus the launch-to-first-frame delay lands the finish request ≈0.8–1.0 s after `start`, straddling the first peak, so launches alternated between a ≈0.8 s and a ≈2.4 s loader. Cost: the "pop on the brightest halo" beat only survives when the peak is close.
- **The feather widens in; it does not arrive whole.** The mask's 100 px feather lies *outside* the hole, so installing the mask at hole radius 0 — which is exactly what `.blur-screen.is-revealing` does — drops a 100 px soft dent around the avatar in a single frame, and the hole's own slow `r = R·t²` start is nowhere near fast enough to cover it. Measured on a 60 Hz capture of the replay, that one frame delivered as much un-blurring in the 40–110 pt annulus as the following ~150 ms combined (+1.39 against neighbouring frames of +0.03/−0.11), and it reads as a pop. The port grows the feather from 0 to its full 100 pt over the 120 ms *ending* at P4b (`BootTimeline.revealFeatherIn`), on `Curve.featherIn` — y = 2x − x², the mirror of the reveal curve — so the feather comes to rest exactly as the hole starts moving and the mask's outer edge has no kink. The hole itself still travels for the spec's 850 ms from P4 + 378 ms; only the onset moves ~120 ms earlier, and for its first ~50 ms the feather is still narrower than the avatar and therefore invisible. Re-measured after the change, the onset reads +0.04, +0.10, +0.53, +0.42, +0.08 per frame — a ramp, not a step (2026-09-12).
- **The blur spreads 100 ms after the avatar starts growing.** The mask's first movement (the feather widening) begins at P4 + 378 + 100 ms (`BootTimeline.revealDelay`), so the feather rests and the hole starts opening at P4 + 598 ms (t0+858) instead of the legacy P4 + 378 ms; the hole still travels 850 ms and ends at t0+1708, well inside the 2100 ms release, so P5 is unchanged. The overlay stops intercepting touches with the hole's start. Product decision (2026-09-12).
- **The reveal accelerates uniformly.** The hole radius follows r = R·t² (bezier control points (⅓, 0, ⅔, ⅓), which is exactly y = x²), a slow start that keeps speeding up, instead of the WebUI's ease-in-out cubic. Product decision (2026-09-12).
- **The loader is the first frame.** `RootTabView` mounts only the overlay on its first frame and inserts the tab content one frame later; the halo texture and images are pre-rendered in the background from app init. Board work still waits for `waitUntilDone()`.
- **Light and dark variants.** The backdrop is `UIBlurEffect(.systemThinMaterial)` (adaptive) under a scrim that is the screen's own background at 55 %: rgba(15,17,23,.55) in Dark Mode (the WebUI's `--bg`), rgba(242,242,247,.55) in Light Mode. "LOADING" is rgba(249,200,240,.85) on dark and rgba(214,48,170,.9) on light. The avatar circle is white in both. Masked via `UIVisualEffectView.mask` (SwiftUI's `.mask` on a `Material` renders the feather as a white fringe); the system blur is not a literal 14 px Gaussian.
- **Replay hooks.** Settings › 调试 › "重新播放启动动画" runs `BootLoaderModel.replay()` over the current screen; `-replayBootAfter <seconds>` does the same from a launch argument for automated recordings.
- **Rendering is Core Animation, not per-frame sampling.** Every phase is scheduled at t0 as CA animations with `beginTime` offsets and the spec's `cubic-bezier` timing functions, so the render server interpolates them and launch-time main-thread work cannot drop frames. (P4b's curve: see the bullet below); the halo ring (gradient + blur 2.4 + shadow) is rendered once to a texture. ProMotion: the app opts in with `CADisableMinimumFrameDurationOnPhone` (Info.plist) and every loader animation carries a 120 Hz `preferredFrameRateRange`; the simulator still records at 60, so verify the rate on a device with Instruments.
- **The avatar group is rasterised at the artwork's density.** The circle is a `masksToBounds` + `cornerRadius` clip over the two icon views. Core Animation composites that directly while the transform is the identity, but as soon as the pop's scale animation starts it renders the clipped group through an offscreen buffer sized to the layer's bounds at 1× — 106 px point-sampled from the 420 px artwork, then magnified up to 2.35×. The icon snapped to a coarse dot pattern at t0 and stayed that way through the whole release (Laplacian variance of the avatar region 494 → 27 between two consecutive frames of a simulator capture, 2026-09-12). `shouldRasterize` with `rasterizationScale` = 420 / 106 gives the transform a 420 px bitmap instead; re-verified on the same capture: smooth through the release.
- **Reduced motion:** peak alignment uses the actual 2.6 s period (the legacy JS keeps aligning to 1.62 s while its CSS runs 2.6 s, so its alignment is off there), and the waterfall reveals every card at once instead of stepping them 115 ms apart with 1 ms transitions.
