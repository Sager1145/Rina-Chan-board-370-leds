import SwiftUI

/// Full-screen boot-loader overlay recreating the legacy WebUI animation.
/// See docs/BOOT_ANIMATION_SPEC.md for the authoritative timeline.
struct BootLoaderOverlay: View {
    @Environment(BootLoaderModel.self) private var model

    private static let pink = Color(red: 249 / 255, green: 113 / 255, blue: 212 / 255)
    private static let backdrop = Color(red: 15 / 255, green: 17 / 255, blue: 23 / 255)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let corner = sqrt(pow(size.width / 2, 2) + pow(size.height / 2, 2))
            let maxRadius = corner + 90
            let holeRadius = model.revealProgress * maxRadius
            let featherStart = max(0, holeRadius - 100)

            ZStack {
                Self.backdrop.opacity(0.55)
                    .background(.ultraThinMaterial)
            }
            .compositingGroup()
            .mask(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: maxRadius > 0 ? featherStart / maxRadius : 0),
                        .init(color: .white, location: maxRadius > 0 ? holeRadius / maxRadius : 0),
                        .init(color: .white, location: 1),
                    ]),
                    center: UnitPoint(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1)),
                    startRadius: 0,
                    endRadius: maxRadius
                )
            )
            .ignoresSafeArea()

            stage
                .position(center)
        }
        .allowsHitTesting(model.hitTestingEnabled)
        .transition(.identity)
    }

    private var stage: some View {
        ZStack {
            haloRing
            avatar
        }
        .overlay(alignment: .bottom) {
            loadingText
                .offset(y: 78)
        }
    }

    private var haloRing: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            guard radius > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let gradient = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: max(0, (radius - 18) / radius)),
                .init(color: .white.opacity(0.55), location: max(0, (radius - 15) / radius)),
                .init(color: Self.pink.opacity(0.72), location: max(0, (radius - 11) / radius)),
                .init(color: Self.pink.opacity(0.40), location: max(0, (radius - 6) / radius)),
                .init(color: Self.pink.opacity(0.13), location: max(0, (radius - 1) / radius)),
                .init(color: .clear, location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius)
            )
        }
        .frame(width: 142, height: 142)
        .blur(radius: 2.4)
        .shadow(color: Self.pink.opacity(0.36), radius: 10)
        .opacity(model.haloVisible ? model.haloOpacity : 0)
        .scaleEffect(model.haloScale)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 106, height: 106)
            Self.bundleImage("rina_icon1_default")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(model.iconDefaultOpacity)
            Self.bundleImage("rina_icon2_hover")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(model.iconHoverOpacity)
        }
        .scaleEffect(model.avatarScale)
        .opacity(model.avatarOpacity)
    }

    private var loadingText: some View {
        Text("LOADING")
            .font(.system(size: 15, weight: .bold))
            .tracking(15 * 0.12)
            .foregroundStyle(Color(red: 249 / 255, green: 200 / 255, blue: 240 / 255).opacity(0.85))
            .opacity(model.textOpacity)
            .offset(y: model.textOffsetY)
    }

    private static func bundleImage(_ name: String) -> Image {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "photo")
    }
}

#Preview {
    ZStack {
        Color.gray
        BootLoaderOverlay()
            .environment({
                let model = BootLoaderModel()
                model.start()
                return model
            }())
    }
}
