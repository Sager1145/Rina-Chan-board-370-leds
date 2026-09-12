# WebUI boot-loader animation — port spec (legacy/webui_v1 → SwiftUI)

Sources: `legacy/webui_v1/data/index.html:32-64`, `styles.css:2647-2956`, `app.js:26-190`
(`WEBUI_CONFIG.boot`), `app.js:6024-6346` (loader state machine), `13868-13912` (waterfall).

## Constants
holdMs 260 · haloBreathMs 1620 · haloPeakRatio 0.5 · haloToleranceMs 24 · haloContractMs 520 ·
imageReleaseMs 2100 · blurDurationMs 850 · extraMs 180 · minDisplayMs 400 · revealEdge 100 px ·
IMG_SHRINK_MS = round(2100×0.18) = 378 · waterfall stagger 115 ms/item, settle 260 ms.

## Geometry / colours
- Icon 96 px, white frame 5 px → avatar circle 106 px (white, round; the images themselves are drawn at 106 px — see Corrections). Halo spread 18 px → ring outer diameter 142 px.
- Halo ring gradient (radial, from centre): transparent to r−18; white .55 at r−15; pink(249,113,212) .72 at r−11; .40 at r−6; .13 at r−1; transparent at edge. `filter: blur(2.4px) drop-shadow(0 0 10px rgba(249,113,212,.36))`.
- Backdrop: rgba(15,17,23,.55) + blur 14 px over the app content.
- Text "LOADING": rgba(249,200,240,.85), 15 px, weight 700, letter-spacing .12em, uppercase, below the avatar.
- Icons: `rina_icon1_default.png` (before), `rina_icon2_hover.png` (after) — in `ios/RinaBoard/Resources/Images`.

## Timeline
| Phase | Start | Duration | Easing | What changes |
|---|---|---|---|---|
| P0 breathe | overlay shown | loop 1620 ms | cubic-bezier(.42,0,.58,1) | halo opacity .28↔1, scale .965↔1.075 (peak at 50 %) |
| P1 align | finish requested (after content ready AND ≥400 ms shown) | wait until next halo peak (±24 ms; iOS: at most 450 ms, see deviations) | — | nothing |
| P2 contract + pop | t0 | halo 520 ms; avatar 620 ms | halo cubic-bezier(.55,.085,.68,.53); avatar cubic-bezier(.16,1.25,.3,1) | halo scale 1.075→.65, opacity→0 then hidden; avatar circle scale→1.22; icon swap: default stays 180 ms then snaps to 0 while hover icon fades in over 180 ms; both scale 1.025; text fades out + translateY 6 px over 220 ms |
| P3 hold | t0 (concurrent with the contraction — see Corrections) | 260 ms | — | nothing new starts |
| P4 release | t0+260 | 2100 ms keyframes | 0 %: scale 1.22 op 1 (bezier .34,0,.2,1) → 18 % (378 ms): scale 1.12 op 1 (bezier .12,.88,.18,1) → 100 %: scale 2.35 op 0 | avatar circle |
| P4b reveal | P4 + 378 ms | 850 ms | ease-in-cubic t<.5 ? 4t³ : 1−(−2t+2)³/2 | radial mask centred on the avatar grows from 0 to the farthest corner + 90 px with a 100 px feather **outside** it, unblurring the app underneath; overlay stops intercepting touches |
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
- **`drop-shadow(0 0 10px)` is a blur diameter.** A renderer taking a Gaussian sigma (e.g. SwiftUI `.shadow(radius:)`) needs 5.

## Deliberate iOS deviations
Choices the port makes on purpose; do not "fix" them back to the table without reading why.
- **Peak wait capped at 450 ms** (`BootTimeline.maxPeakWait`), and the halo contracts from its *current* breath values instead of the keyframes' snap to the peak values. The legacy wait of up to 1.62 s exists only to hide that snap; on iOS the waterfall (3×115+260 ms) plus the launch-to-first-frame delay lands the finish request ≈0.8–1.0 s after `start`, straddling the first peak, so launches alternated between a ≈0.8 s and a ≈2.4 s loader. Cost: the "pop on the brightest halo" beat only survives when the peak is close.
- **Halo gradient stops are measured against the 71 px box half-size.** In CSS the percentages in `radial-gradient(circle …)` resolve against the farthest-corner ray (100.4 px), which would put the whole pink band *under* the avatar and leave only a faint .13→0 tail visible. The variable names (`--rina-halo-spread: 18px`) show a visible ring outside the avatar was the intent, so the port draws that.
- **Backdrop blur is `UIBlurEffect(.regular)` + the rgba(15,17,23,.55) scrim**, masked via `UIVisualEffectView.mask` (SwiftUI's `.mask` on a `Material` renders the feather as a white fringe). The system blur is appearance-adaptive and not a literal 14 px Gaussian.
- **Rendering is Core Animation, not per-frame sampling.** Every phase is scheduled at t0 as CA animations with `beginTime` offsets and the spec's `cubic-bezier` timing functions, so the render server interpolates them and launch-time main-thread work cannot drop frames. P4b's closed-form ease-in-out cubic is its standard bezier fit cubic-bezier(.65,0,.35,1) (≈1 % max deviation); the halo ring (gradient + blur 2.4 + shadow) is rendered once to a texture.
- **Reduced motion:** peak alignment uses the actual 2.6 s period (the legacy JS keeps aligning to 1.62 s while its CSS runs 2.6 s, so its alignment is off there), and the waterfall reveals every card at once instead of stepping them 115 ms apart with 1 ms transitions.
