// swift-tools-version:5.9
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
    ]
)
