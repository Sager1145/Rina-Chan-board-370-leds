import CoreImage
import CoreImage.CIFilterBuiltins
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
            .ignoresSafeArea()
            // The stage view swallows touches itself while `interceptsTouches`;
            // that does not stop VoiceOver, so also declare the overlay modal
            // or the tab bar and the list behind it stay focusable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("页面加载中"))
            .accessibilityAddTraits(.isModal)
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
    private static let scrim = UIColor(red: 15 / 255, green: 17 / 255, blue: 23 / 255, alpha: 0.55)
    private static let loadingPink = UIColor(red: 249 / 255, green: 200 / 255, blue: 240 / 255, alpha: 0.85)

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let holeMask = RadialMaskView()
    private let halo = CALayer()
    private let avatar = UIView()
    private let icons = UIView()
    private let defaultIcon = UIImageView(image: BootAssets.defaultIcon)
    private let hoverIcon = UIImageView(image: BootAssets.hoverIcon)
    private let label = UILabel()

    private var isBreathing = false
    private var outroStarted = false

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
        // animation stutter on older devices.
        let haloImage = BootAssets.halo
        halo.contents = haloImage.cgImage
        halo.contentsScale = haloImage.scale
        halo.bounds = CGRect(origin: .zero, size: haloImage.size)
        halo.opacity = 0.28
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
        addSubview(avatar)

        // `.loading-text`: 15 px / 700 / .12em, below the stage.
        label.attributedText = NSAttributedString(
            string: "LOADING",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .kern: 15 * 0.12,
                .foregroundColor: Self.loadingPink,
            ]
        )
        label.sizeToFit()
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        guard !isBreathing else { return }
        isBreathing = true

        let elapsed = max(0, Date().timeIntervalSince(since))
        for (keyPath, values) in [("opacity", [0.28, 1, 0.28]), ("transform.scale", [0.965, 1.075, 0.965])] {
            let breath = CAKeyframeAnimation(keyPath: keyPath)
            breath.values = values
            breath.keyTimes = [0, NSNumber(value: BootTimeline.peakRatio), 1]
            breath.timingFunctions = [BootTimeline.Curve.breath, BootTimeline.Curve.breath]
            breath.duration = period
            breath.repeatCount = .infinity
            breath.timeOffset = elapsed.truncatingRemainder(dividingBy: period)
            halo.add(breath, forKey: "breath.\(keyPath)")
        }
    }

    // MARK: P2…P5 — outro

    /// Schedules the whole outro at once, relative to t0 = `since`. Every
    /// later phase is a Core Animation `beginTime`, so the main thread is not
    /// involved again until the model removes the overlay.
    func runOutro(since: Date) {
        guard !outroStarted else { return }
        outroStarted = true

        let t0 = CACurrentMediaTime() - max(0, Date().timeIntervalSince(since))
        let presented = halo.presentation() ?? halo
        let haloOpacity = presented.opacity
        let haloScale = presented.value(forKeyPath: "transform.scale") as? CGFloat ?? 1.075

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
        // Nothing else drives opacity until the release begins, so pin it
        // (the pop animation covers scale over the same window).
        avatar.layer.add(hold("opacity", at: 1, from: t0, for: BootTimeline.releaseStart), forKey: "hold")
        avatar.layer.add(keyframes("transform.scale", values: [1.22, 1.12, 2.35],
                                   keyTimes: releaseTimes, curves: releaseCurves,
                                   begin: t0 + BootTimeline.releaseStart,
                                   duration: BootTimeline.release), forKey: "release.scale")
        avatar.layer.add(keyframes("opacity", values: [1, 1, 0],
                                   keyTimes: releaseTimes, curves: releaseCurves,
                                   begin: t0 + BootTimeline.releaseStart,
                                   duration: BootTimeline.release), forKey: "release.opacity")

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
        // hole, so a mask at radius 0 already dents the scrim. `closed` holds
        // it shut until `revealStart`, then the reveal takes over.
        blur.mask = holeMask
        holeMask.gradient.locations = holeMask.locations(progress: 1)
        holeMask.gradient.add(hold("locations", at: holeMask.locations(progress: nil),
                                   from: t0, for: BootTimeline.revealStart), forKey: "closed")
        holeMask.gradient.add(basic("locations",
                                    from: holeMask.locations(progress: 0),
                                    to: holeMask.locations(progress: 1),
                                    begin: t0 + BootTimeline.revealStart,
                                    duration: BootTimeline.reveal,
                                    curve: .reveal), forKey: "reveal")

        // P5 — the (by now fully punched-through) overlay snaps to opacity 0
        // (`.loading-overlay.is-hidden` has no transition); the model removes
        // it `extra` later.
        layer.opacity = 0
        layer.add(hold("opacity", at: 1, from: t0, for: BootTimeline.overlayFadeStart), forKey: "hold")

        CATransaction.commit()
    }

    // MARK: Animation builders

    private func basic(_ keyPath: String, from: Any, to: Any,
                       begin: CFTimeInterval, duration: TimeInterval,
                       curve: CAMediaTimingFunction) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.timingFunction = curve
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func keyframes(_ keyPath: String, values: [Any], keyTimes: [NSNumber],
                           curves: [CAMediaTimingFunction],
                           begin: CFTimeInterval, duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.timingFunctions = curves
        animation.beginTime = begin
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
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
        return animation
    }
}

private extension CAMediaTimingFunction {
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

    private static func icon(_ name: String) -> UIImage? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let image = UIImage(contentsOfFile: path) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private static let pink = CIColor(red: 249 / 255, green: 113 / 255, blue: 212 / 255)

    /// The `.flash-halo` ring rendered once: the spec's radial gradient,
    /// `blur(2.4px)`, and `drop-shadow(0 0 10px rgba(249,113,212,.36))` —
    /// a 10 pt blur *diameter*, so sigma 5.
    static let halo: UIImage = {
        let radius = BootTimeline.haloDiameter / 2
        let side = BootTimeline.haloDiameter + BootTimeline.haloPadding * 2
        let scale = UIScreen.main.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let ring = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let stops: [(CGFloat, UIColor)] = [
                (0, .clear),
                ((radius - 18) / radius, .clear),
                ((radius - 15) / radius, UIColor.white.withAlphaComponent(0.55)),
                ((radius - 11) / radius, UIColor(ciColor: pink).withAlphaComponent(0.72)),
                ((radius - 6) / radius, UIColor(ciColor: pink).withAlphaComponent(0.40)),
                ((radius - 1) / radius, UIColor(ciColor: pink).withAlphaComponent(0.13)),
                (1, .clear),
            ]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: stops.map(\.1.cgColor) as CFArray,
                                            locations: stops.map(\.0)) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                                 endCenter: centre, endRadius: radius, options: [])
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
    }()
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
