import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ImageIO
import SwiftUI
import UIKit

/// Full-screen boot-loader overlay recreating the legacy WebUI animation.
/// See docs/BOOT_ANIMATION_SPEC.md for the authoritative timeline.
///
/// SwiftUI here is only a thin host: the stage is a UIKit view whose every
/// phase is a set of Core Animation animations built from `BootTimeline`.
/// The render server interpolates them, so the loader keeps its frame rate
/// through the launch-time main-thread work (list layout, transports coming
/// up, image decodes) that used to drop frames of a main-thread-sampled
/// animation.
struct BootLoaderOverlay: View {
    @Environment(BootLoaderModel.self) private var model

    var body: some View {
        BootStage(phase: model.phase,
                  breathPeriod: model.breathPeriod,
                  interceptsTouches: model.interceptsTouches)
            // A replay while the loader is still up must get a fresh stage:
            // the old one has consumed its one-shot phases and its root layer
            // is already at opacity 0, which would leave an invisible view
            // swallowing touches for the whole run.
            .id(model.runID)
            .ignoresSafeArea()
            // The stage view swallows touches itself while `interceptsTouches`;
            // that does not stop VoiceOver, so also declare the overlay modal
            // or the tab bar and the list behind it stay focusable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(.isModal)
    }
}

private extension BootLoaderOverlay {
    /// `aria-label` flips to "loaded" when the outro starts (app.js:6259).
    var accessibilityLabel: LocalizedStringKey {
        if case .outro = model.phase { return "页面加载完成" }
        return "页面加载中"
    }
}

private struct BootStage: UIViewRepresentable {
    let phase: BootLoaderModel.Phase
    let breathPeriod: TimeInterval
    let interceptsTouches: Bool

    func makeUIView(context: Context) -> BootStageView { BootStageView() }

    func updateUIView(_ view: BootStageView, context: Context) {
        view.isUserInteractionEnabled = interceptsTouches
        switch phase {
        case .idle, .done:
            break
        case .breathing(let since):
            view.breathe(period: breathPeriod, since: since)
        case .outro(let since):
            view.runOutro(since: since)
        }
    }
}

// MARK: - Stage view

/// The legacy `.loading-overlay`: `.blur-screen` (scrim + backdrop blur with
/// the reveal mask) under a `.loader-stage` of halo, avatar and label.
private final class BootStageView: UIView {
    /// The legacy scrim is the page background at 55 % (`--bg: #0f1117`).
    /// Light mode uses the app's grouped background the same way, so the
    /// backdrop reads as a frosted version of the screen behind it in both
    /// appearances. The avatar circle stays white in both.
    private static let scrim = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 15 / 255, green: 17 / 255, blue: 23 / 255, alpha: 0.55)
            : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 0.55)
    }
    /// `rgba(249,200,240,.85)` on the dark backdrop; a deeper pink for the
    /// light one, where the pale tint would vanish.
    private static let loadingPink = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 249 / 255, green: 200 / 255, blue: 240 / 255, alpha: 0.85)
            : UIColor(red: 214 / 255, green: 48 / 255, blue: 170 / 255, alpha: 0.9)
    }

    /// A thin material so the screen stays legible through the frost, dark
    /// in Dark Mode (the WebUI's near-black look) and light in Light Mode;
    /// the dynamic scrim above follows the appearance.
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let holeMask = RadialMaskView()
    private let halo = CALayer()
    private let avatar = UIView()
    private let icons = UIView()
    private let defaultIcon = UIImageView(image: BootAssets.defaultIcon)
    private let hoverIcon = UIImageView(image: BootAssets.hoverIcon)
    private let label = UILabel()

    private var breathing: (period: TimeInterval, since: Date)?
    private var outroSince: Date?
    private var activeObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Backdrop. Masking the effect view itself is what UIKit supports;
        // SwiftUI's `.mask` on a `Material` renders the feather as a white
        // fringe (a backdrop layer at partial alpha).
        blur.isUserInteractionEnabled = false
        let scrim = UIView(frame: blur.contentView.bounds)
        scrim.backgroundColor = Self.scrim
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.contentView.addSubview(scrim)
        addSubview(blur)

        // Halo: a texture, transformed only. Rendering the blur and the drop
        // shadow live every frame is exactly the work that makes a launch
        // animation stutter on older devices. The texture is produced off
        // the main thread (≈200 ms cold, mostly Core Image warm-up) and
        // attached when ready; the breath animates the layer regardless.
        let haloSide = BootTimeline.haloDiameter + BootTimeline.haloPadding * 2
        halo.bounds = CGRect(x: 0, y: 0, width: haloSide, height: haloSide)
        halo.contentsScale = BootAssets.haloScale
        halo.opacity = 0.28
        Task { @MainActor [weak halo] in
            let image = await BootAssets.haloTask.value
            halo?.contents = image.cgImage
        }
        halo.setAffineTransform(CGAffineTransform(scaleX: 0.965, y: 0.965))
        layer.addSublayer(halo)

        // Avatar: `.avatar-circle { overflow: hidden; border-radius: 50% }`
        // with both 106 pt images inside. The artwork fills its canvas to the
        // edges, so without the clip the sleeves and hair would spill onto
        // the halo.
        let side = BootTimeline.avatarDiameter
        avatar.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        avatar.backgroundColor = .white
        avatar.layer.cornerRadius = side / 2
        avatar.layer.masksToBounds = true
        icons.frame = avatar.bounds
        for icon in [defaultIcon, hoverIcon] {
            icon.frame = icons.bounds
            icon.contentMode = .scaleAspectFit
            icons.addSubview(icon)
        }
        hoverIcon.layer.opacity = 0
        avatar.addSubview(icons)
        // A clipped group (`masksToBounds` + `cornerRadius` over sublayers)
        // is composited directly while its transform is the identity, but
        // the moment the pop's scale animation starts Core Animation renders
        // it through an offscreen buffer sized to the layer's *bounds*, at
        // 1× — 106 px point-sampled from the 420 px artwork, then magnified
        // up to 2.35×: the icon snapped to a coarse dot pattern at t0 and
        // stayed that way through the release (measured 2026-09-12: the
        // Laplacian variance of the avatar region fell 494 → 27 between two
        // consecutive frames). Rasterising the group explicitly, at the
        // artwork's own density, gives the transform a 420 px bitmap
        // instead, so every scale from 1 to 2.35 samples the full image.
        avatar.layer.shouldRasterize = true
        avatar.layer.rasterizationScale = BootAssets.iconScale
        addSubview(avatar)

        // `.loading-text`: 15 px / .12em in the page font, GNU Unifont (the
        // CSS asks for 700 but `font-synthesis: none` leaves the pixel font
        // at its single weight). A subset with ASCII only ships in the
        // bundle, so a localized line outside that subset (any zh-Hans/ja
        // string) falls back to the system font at the same size/weight —
        // checked by actual glyph coverage, never a hardcoded language list.
        let bootText = NSLocalizedString("加载中...", comment: "boot loader loading label, shown before the reveal")
        label.attributedText = NSAttributedString(
            string: bootText,
            attributes: [
                .font: Self.bootLabelFont(for: bootText, size: 15),
                .kern: 15 * 0.12,
                .foregroundColor: Self.loadingPink,
            ]
        )
        label.sizeToFit()
        addSubview(label)

        // UIKit strips every CA animation when the app is backgrounded, and
        // a call or an app-switcher peek can land inside the ~3 s loader.
        // Without this, on return the halo sits frozen or — worse — the
        // overlay is invisible (root opacity at its model value 0) while
        // still swallowing touches. Both entry points derive their times
        // from `since`, so replaying them resumes mid-way.
        // (Also posts once at launch: the replay then re-adds the breath with
        // the same `since`/`timeOffset`, which is visually a no-op.)
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.replayAfterForeground()
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    private func replayAfterForeground() {
        guard let breathing else { return }
        let outroSince = outroSince
        self.breathing = nil
        self.outroSince = nil
        breathe(period: breathing.period, since: breathing.since)
        if let outroSince { runOutro(since: outroSince) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pixel font when it actually has every glyph the label needs,
    /// otherwise a system font at the same point size and weight. Coverage
    /// is checked with `CTFontGetGlyphsForCharacters` rather than a hardcoded
    /// language check, so this keeps working if the label's copy changes.
    private static func bootLabelFont(for text: String, size: CGFloat) -> UIFont {
        guard let pixelFont = UIFont(name: "GNUUnifont-WebUIOfflineSubset", size: size),
              fontCovers(pixelFont, text) else {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        return pixelFont
    }

    private static func fontCovers(_ font: UIFont, _ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(ctFont, units, &glyphs, units.count)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        blur.frame = bounds
        holeMask.frame = bounds
        holeMask.configure(for: bounds.size)

        // Bare sublayers get implicit 0.25 s actions on geometry changes;
        // a resize mid-animation must not tween them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = centre
        avatar.center = centre
        label.center = CGPoint(x: centre.x, y: centre.y + BootTimeline.textOffset)
        CATransaction.commit()
    }

    // MARK: P0 — breathe

    /// `rinaBoot-pulseRingBreath`: opacity .28↔1 and scale .965↔1.075,
    /// peaking at 50 %, eased on both legs. `since` is the model's clock so
    /// the loop's phase matches its peak alignment.
    func breathe(period: TimeInterval, since: Date) {
        guard breathing == nil else { return }
        breathing = (period, since)

        let elapsed = max(0, Date().timeIntervalSince(since))
        for (keyPath, values) in [("opacity", [0.28, 1, 0.28]), ("transform.scale", [0.965, 1.075, 0.965])] {
            let breath = CAKeyframeAnimation(keyPath: keyPath)
            breath.values = values
            breath.keyTimes = [0, NSNumber(value: BootTimeline.peakRatio), 1]
            breath.timingFunctions = [BootTimeline.Curve.breath, BootTimeline.Curve.breath]
            breath.duration = period
            breath.repeatCount = .infinity
            breath.timeOffset = elapsed.truncatingRemainder(dividingBy: period)
            breath.preferredFrameRateRange = Self.proMotion
            halo.add(breath, forKey: "breath.\(keyPath)")
        }
    }

    // MARK: P2…P5 — outro

    /// Schedules the whole outro at once, relative to t0 = `since`. Every
    /// later phase is a Core Animation `beginTime`, so the main thread is not
    /// involved again until the model removes the overlay.
    func runOutro(since: Date) {
        guard outroSince == nil else { return }
        outroSince = since

        let t0 = CACurrentMediaTime() - max(0, Date().timeIntervalSince(since))
        let presented = halo.presentation() ?? halo
        let haloOpacity = presented.opacity
        // `transform.scale` reads back as the mean of x/y/z (m33 included);
        // `.x` is the exact value.
        let haloScale = presented.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 1.075

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // P2 — halo contracts and fades from wherever the breath left it
        // (see `BootTimeline.maxPeakWait`), then is gone for good.
        halo.removeAllAnimations()
        halo.opacity = 0
        halo.setAffineTransform(CGAffineTransform(scaleX: 0.65, y: 0.65))
        halo.add(basic("opacity", from: haloOpacity, to: 0,
                       begin: t0, duration: BootTimeline.haloContract,
                       curve: .haloContract), forKey: "contract.opacity")
        halo.add(basic("transform.scale", from: haloScale, to: 0.65,
                       begin: t0, duration: BootTimeline.haloContract,
                       curve: .haloContract), forKey: "contract.scale")

        // P2 — avatar pops, overshooting past 1.22 on the way …
        avatar.layer.add(basic("transform.scale", from: 1, to: 1.22,
                               begin: t0, duration: BootTimeline.avatarPop,
                               curve: .avatarPop), forKey: "pop")
        // … and P4 takes it over mid-pop (from ≈1.223 to the keyframes'
        // 1.22): two legs, 0 %→18 %→100 %, growing to 2.35 while fading.
        // Added after "pop", so it wins from its `beginTime` on.
        let releaseTimes: [NSNumber] = [0, NSNumber(value: BootTimeline.imgShrink / BootTimeline.release), 1]
        let releaseCurves = [BootTimeline.Curve.releaseIn, BootTimeline.Curve.releaseOut]
        avatar.layer.setAffineTransform(CGAffineTransform(scaleX: 2.35, y: 2.35))
        avatar.layer.opacity = 0
        avatar.layer.add(keyframes("transform.scale", values: [1.22, 1.12, 2.35],
                                   keyTimes: releaseTimes, curves: releaseCurves,
                                   begin: t0 + BootTimeline.releaseStart,
                                   duration: BootTimeline.release,
                                   fill: .forwards), forKey: "release.scale")
        // Opacity as one track from t0 — held at 1 through the pop and the
        // shrink, then fading — so no gap between abutting animations can
        // ever show the model value.
        let releaseEnd = BootTimeline.releaseStart + BootTimeline.release
        avatar.layer.add(keyframes("opacity", values: [1, 1, 1, 0],
                                   keyTimes: [0,
                                              NSNumber(value: BootTimeline.releaseStart / releaseEnd),
                                              NSNumber(value: (BootTimeline.releaseStart + BootTimeline.imgShrink) / releaseEnd),
                                              1],
                                   curves: [.linear, BootTimeline.Curve.releaseIn, BootTimeline.Curve.releaseOut],
                                   begin: t0, duration: releaseEnd), forKey: "release.opacity")

        // P2 — the icons grow to 1.025 inside the circle on the pop curve
        // (`.avatar-circle img`) and cross-fade *overlapping*: the hover icon
        // fades in over [0, 180] while the default one holds, then snaps off
        // (`opacity 0s linear 180ms`). Back to back would show a bare circle.
        icons.layer.setAffineTransform(CGAffineTransform(scaleX: 1.025, y: 1.025))
        icons.layer.add(basic("transform.scale", from: 1, to: 1.025,
                              begin: t0, duration: BootTimeline.avatarPop,
                              curve: .avatarPop), forKey: "pop")
        hoverIcon.layer.opacity = 1
        hoverIcon.layer.add(basic("opacity", from: 0, to: 1,
                                  begin: t0, duration: BootTimeline.iconSwap,
                                  curve: .ease), forKey: "fadeIn")
        defaultIcon.layer.opacity = 0
        defaultIcon.layer.add(hold("opacity", at: 1, from: t0, for: BootTimeline.iconSwap), forKey: "hold")

        // P2 — "LOADING" fades out and drops 6 pt.
        label.layer.opacity = 0
        label.layer.setAffineTransform(CGAffineTransform(translationX: 0, y: 6))
        label.layer.add(basic("opacity", from: 1, to: 0,
                              begin: t0, duration: BootTimeline.textFade,
                              curve: .ease), forKey: "fade")
        label.layer.add(basic("transform.translation.y", from: 0, to: 6,
                              begin: t0, duration: BootTimeline.textFade,
                              curve: .ease), forKey: "drop")

        // P4b — the radial mask opens over the blur. Installed only now, as
        // `.blur-screen.is-revealing` is: its 100 pt feather lies outside the
        // hole, so a mask at radius 0 already dents the scrim.
        //
        // One track from t0, in three legs — a gap between two abutting
        // animations here would flash the whole UI through the model value
        // (fully open):
        //   shut …                                    until revealFeatherIn
        //   feather widens 0 → 100 pt, hole still 0 … until revealStart
        //   hole opens on the reveal curve …          until revealEnd
        // The legacy goes straight from "shut" to "hole 0 with the full
        // feather", which lands a 100 pt soft dent around the avatar in one
        // frame (see `BootTimeline.revealFeatherIn`). Interpolating the stop
        // array from `nil` to `progress: 0` moves only the outer stop, which
        // is exactly the feather widening in place, and `featherIn` brings it
        // to rest just as the hole starts moving.
        blur.mask = holeMask
        holeMask.gradient.locations = holeMask.locations(progress: 1)
        let revealEnd = BootTimeline.revealStart + BootTimeline.reveal
        let revealAt = BootTimeline.revealStart / revealEnd
        let featherAt = (BootTimeline.revealStart - BootTimeline.revealFeatherIn) / revealEnd
        holeMask.gradient.add(keyframes("locations",
                                        values: [holeMask.locations(progress: nil),
                                                 holeMask.locations(progress: nil),
                                                 holeMask.locations(progress: 0),
                                                 holeMask.locations(progress: 1)],
                                        keyTimes: [0, NSNumber(value: featherAt),
                                                   NSNumber(value: revealAt), 1],
                                        curves: [.linear, BootTimeline.Curve.featherIn,
                                                 BootTimeline.Curve.reveal],
                                        begin: t0, duration: revealEnd), forKey: "reveal")

        // P5 — the (by now fully punched-through) overlay snaps to opacity 0
        // (`.loading-overlay.is-hidden` has no transition); the model removes
        // it `extra` later.
        layer.opacity = 0
        layer.add(hold("opacity", at: 1, from: t0, for: BootTimeline.overlayFadeStart), forKey: "hold")

        CATransaction.commit()
    }

    // MARK: Animation builders

    /// ProMotion: iPhone caps Core Animation at 60 Hz unless the app opts in
    /// (`CADisableMinimumFrameDurationOnPhone` in Info.plist) *and* the
    /// animation asks for it; without the hint the system may still settle on
    /// 60 Hz for a "slow" tween like the halo breath.
    private static let proMotion = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    private func basic(_ keyPath: String, from: Any, to: Any,
                       begin: CFTimeInterval, duration: TimeInterval,
                       curve: CAMediaTimingFunction) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.timingFunction = curve
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = Self.proMotion
        return animation
    }

    /// `fill` defaults to `.both` for tracks that start at t0; a track that
    /// begins later and takes over from an earlier one (the release from the
    /// pop) must not fill backwards or it would pre-empt its predecessor.
    private func keyframes(_ keyPath: String, values: [Any], keyTimes: [NSNumber],
                           curves: [CAMediaTimingFunction],
                           begin: CFTimeInterval, duration: TimeInterval,
                           fill: CAMediaTimingFillMode = .both) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.timingFunctions = curves
        animation.beginTime = begin
        animation.duration = duration
        animation.fillMode = fill
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = Self.proMotion
        return animation
    }

    /// Pins `keyPath` at `value` for `duration`, after which the layer's
    /// model value shows — a CSS `0s linear <delay>` transition.
    private func hold(_ keyPath: String, at value: Any,
                      from begin: CFTimeInterval, for duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.toValue = value
        animation.beginTime = begin
        animation.duration = duration
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = Self.proMotion
        return animation
    }
}

private extension CAMediaTimingFunction {
    static let linear = CAMediaTimingFunction(name: .linear)
    static let haloContract = BootTimeline.Curve.haloContract
    static let avatarPop = BootTimeline.Curve.avatarPop
    static let ease = BootTimeline.Curve.ease
    static let reveal = BootTimeline.Curve.reveal
}

// MARK: - Reveal mask

/// The `.blur-screen.is-revealing` mask: clear out to the hole's edge,
/// ramping to opaque over the next 100 pt (styles.css:2706-2716). A view
/// backed by the gradient layer so resizes never tween it.
private final class RadialMaskView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }

    private var maxRadius: CGFloat = 1
    private var extent: CGFloat { maxRadius + BootTimeline.revealEdge }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.colors = [UIColor.clear, .clear, .black, .black].map(\.cgColor)
        gradient.locations = locations(progress: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        maxRadius = hypot(size.width / 2, size.height / 2) + BootTimeline.revealOvershoot
        // A radial gradient's end point sets its radii as fractions of the
        // layer's size; equal radii in points make it a circle. The gradient
        // runs to `maxRadius + feather` so the outer stop stays in range.
        gradient.endPoint = CGPoint(x: 0.5 + extent / size.width, y: 0.5 + extent / size.height)
    }

    /// Stops for a hole of `progress × maxRadius`; `nil` is no hole at all.
    func locations(progress: Double?) -> [NSNumber] {
        guard let progress else { return [0, 0, 0, 1] }
        let hole = CGFloat(progress) * maxRadius
        return [0, hole / extent, (hole + BootTimeline.revealEdge) / extent, 1]
            .map { NSNumber(value: Double($0)) }
    }
}

// MARK: - Assets

/// Decoded once. The legacy awaits `img.decode()` on the hover icon before
/// starting P2; pre-decoding keeps its first draw at t0 from hitching.
private enum BootAssets {
    static let defaultIcon = icon("rina_icon1_default")
    static let hoverIcon = icon("rina_icon2_hover")

    /// Pixels per point of the icons in the 106 pt circle (420 / 106 ≈ 3.96);
    /// the avatar group is rasterised at this density. Falls back to the
    /// release's largest on-screen size on a 3× panel.
    static var iconScale: CGFloat { defaultIcon?.scale ?? 3 * 2.35 }

    /// The PNGs are 420 px, decoded once and mapped to the 106 pt circle at
    /// their full resolution (≈4×), so the 2.35× release still has headroom
    /// on a 3× panel.
    ///
    /// Decoded through ImageIO rather than `UIImage.preparingForDisplay()`:
    /// the build's `copypng` adds an `iDOT` chunk to these palette PNGs and
    /// UIKit's decompressor logs "Error -17102 decompressing image" on them
    /// before falling back, once per icon at every launch.
    private static func icon(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        let scale = CGFloat(cgImage.width) / BootTimeline.avatarDiameter
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    private static let pink = CIColor(red: 249 / 255, green: 113 / 255, blue: 212 / 255)

    /// Rendered at 3× regardless of the panel: it is a soft glow.
    static let haloScale: CGFloat = 3

    /// Starts rendering the halo texture in the background; called at app
    /// init so it is ready by the loader's first frame.
    static let haloTask = Task.detached(priority: .userInitiated) { renderHalo() }

    /// The `.flash-halo` rendered once, as the browser draws it: the radial
    /// gradient with its stops on the farthest-corner ray (see
    /// `BootTimeline.haloGradientRay`), clipped to the round box, then
    /// `blur(2.4px)` and `drop-shadow(0 0 10px rgba(249,113,212,.36))` — a
    /// 10 pt blur *diameter*, so sigma 5 — which spill past the clip.
    private static func renderHalo() -> UIImage {
        let radius = BootTimeline.haloDiameter / 2
        let ray = BootTimeline.haloGradientRay
        let side = BootTimeline.haloDiameter + BootTimeline.haloPadding * 2
        let scale = haloScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let ring = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            // `calc(50% − 18px)` etc., with 50 % = half the ray. `CGGradient`
            // interpolates un-premultiplied, so a transparent stop must carry
            // the neighbouring colour (`UIColor.clear` is transparent *black*
            // and would drag the visible tail ~45 % towards black); the CSS
            // pins its inner stop at `rgba(255,255,255,0)` for the same reason.
            let pinkColor = UIColor(ciColor: pink)
            let stops: [(CGFloat, UIColor)] = [
                (0, UIColor.white.withAlphaComponent(0)),
                ((ray / 2 - 18) / ray, UIColor.white.withAlphaComponent(0)),
                ((ray / 2 - 15) / ray, UIColor.white.withAlphaComponent(0.55)),
                ((ray / 2 - 11) / ray, pinkColor.withAlphaComponent(0.72)),
                ((ray / 2 - 6) / ray, pinkColor.withAlphaComponent(0.40)),
                ((ray / 2 - 1) / ray, pinkColor.withAlphaComponent(0.13)),
                (1, pinkColor.withAlphaComponent(0)),
            ]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: stops.map(\.1.cgColor) as CFArray,
                                            locations: stops.map(\.0)) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            // `border-radius: 50%` clips the background to the 71 pt circle;
            // the filters below are applied to the clipped result.
            context.cgContext.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                    width: radius * 2, height: radius * 2))
            context.cgContext.clip()
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                                 endCenter: centre, endRadius: ray, options: [])
        }

        guard let source = CIImage(image: ring) else { return ring }
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 2.4 * scale)
            .cropped(to: source.extent)

        // The shadow is the ring's alpha, blurred by sigma 5 and tinted pink
        // at .36 (premultiplied, hence the alpha factor in every channel).
        let tint = CIFilter.colorMatrix()
        tint.inputImage = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 5 * scale)
            .cropped(to: source.extent)
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: pink.red * 0.36)
        tint.gVector = CIVector(x: 0, y: 0, z: 0, w: pink.green * 0.36)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: pink.blue * 0.36)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.36)
        guard let shadow = tint.outputImage else { return ring }

        let composed = blurred.composited(over: shadow)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(composed, from: source.extent) else { return ring }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

extension BootLoaderOverlay {
    /// Kick off the halo texture render (and image decodes) in the
    /// background. Call once at app init; everything is idempotent.
    static func prewarm() {
        _ = BootAssets.haloTask
        // Same priority as the first frame that will otherwise block on
        // these `static let`s: `swift_once` does not donate priority.
        Task.detached(priority: .userInitiated) {
            _ = BootAssets.defaultIcon
            _ = BootAssets.hoverIcon
        }
    }
}

// MARK: - Preview

#Preview("Boot loader") {
    BootLoaderPreviewHost()
}

private struct BootLoaderPreviewHost: View {
    @State private var model = BootLoaderModel()

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom)
            if model.isVisible {
                BootLoaderOverlay().environment(model)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            model.start(reduceMotion: false)
            model.beginWaterfall(count: 3)
        }
    }
}
