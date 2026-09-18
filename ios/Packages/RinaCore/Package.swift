// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RinaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RinaCore", targets: ["RinaCore"]),
    ],
    targets: [
        .target(
            name: "RinaCore"
        ),
        .testTarget(
            name: "RinaCoreTests",
            dependencies: ["RinaCore"]
        ),
    ],
    // Swift 6 language mode makes data-race safety a compile error, so the
    // package cannot regress to the warnings it had under Swift 5 (audit A57).
    swiftLanguageModes: [.v6]
)
