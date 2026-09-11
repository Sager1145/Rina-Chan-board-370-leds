# WebUI boot-loader animation — port spec (legacy/webui_v1 → SwiftUI)

Sources: `legacy/webui_v1/data/index.html:32-64`, `styles.css:2647-2956`, `app.js:26-190`
(`WEBUI_CONFIG.boot`), `app.js:6024-6346` (loader state machine), `13868-13912` (waterfall).

## Constants
holdMs 260 · haloBreathMs 1620 · haloPeakRatio 0.5 · haloToleranceMs 24 · haloContractMs 520 ·
imageReleaseMs 2100 · blurDurationMs 850 · extraMs 180 · minDisplayMs 400 ·
IMG_SHRINK_MS = round(2100×0.18) = 378 · waterfall stagger 115 ms/item, settle 260 ms.

## Geometry / colours
- Icon 96 px, white frame 5 px → avatar circle 106 px (white, round). Halo spread 18 px → ring outer diameter 142 px.
- Halo ring gradient (radial, from centre): transparent to r−18; white .55 at r−15; pink(249,113,212) .72 at r−11; .40 at r−6; .13 at r−1; transparent at edge. `filter: blur(2.4px) drop-shadow(0 0 10px rgba(249,113,212,.36))`.
- Backdrop: rgba(15,17,23,.55) + blur 14 px over the app content.
- Text "LOADING": rgba(249,200,240,.85), 15 px, weight 700, letter-spacing .12em, uppercase, below the avatar.
- Icons: `rina_icon1_default.png` (before), `rina_icon2_hover.png` (after) — in `ios/RinaBoard/Resources/Images`.

## Timeline
| Phase | Start | Duration | Easing | What changes |
|---|---|---|---|---|
| P0 breathe | overlay shown | loop 1620 ms | cubic-bezier(.42,0,.58,1) | halo opacity .28↔1, scale .965↔1.075 (peak at 50 %) |
| P1 align | finish requested (after content ready AND ≥400 ms shown) | wait until next halo peak (±24 ms) | — | nothing |
| P2 contract + pop | t0 | halo 520 ms; avatar 620 ms | halo cubic-bezier(.55,.085,.68,.53); avatar cubic-bezier(.16,1.25,.3,1) | halo scale 1.075→.65, opacity→0 then hidden; avatar circle scale→1.22; icon swap: default stays 180 ms then snaps to 0 while hover icon fades in over 180 ms; both scale 1.025; text fades out + translateY 6 px over 220 ms |
| P3 hold | t0+520 (after halo hidden) | 260 ms | — | nothing |
| P4 release | t0+780 | 2100 ms keyframes | 0 %: scale 1.22 op 1 (bezier .34,0,.2,1) → 18 % (378 ms): scale 1.12 op 1 (bezier .12,.88,.18,1) → 100 %: scale 2.35 op 0 | avatar circle |
| P4b reveal | P4 + 378 ms | 850 ms | ease-in-cubic t<.5 ? 4t³ : 1−(−2t+2)³/2 | radial mask centred on the avatar grows from 0 to the farthest corner + 90 px with a 100 px feather, unblurring the app underneath; overlay stops intercepting touches |
| P5 done | P4 + max(2100, 378+850) + 180 = 2280 ms | — | — | overlay opacity 0, removed after 180 ms |

## Card waterfall (first page)
Cards start `opacity 0, translateY 10 px, hidden`; revealed top-to-bottom, one every 115 ms,
each with `opacity 320 ms ease` and `translateY 360 ms cubic-bezier(.16,1,.3,1)`; 260 ms settle
after the last. Runs while the loader is still covering the screen (its reveal mask shows it).

## Rules
- Loader is time/asset based only; it does not wait for the board. Board status fetch begins after the loader is gone.
- Reduced motion: halo breath slows to 2.6 s; waterfall becomes instant (1 ms, no slide). The contract/release/mask sequence still plays.
