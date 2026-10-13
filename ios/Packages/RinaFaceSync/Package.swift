// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RinaFaceSync",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FaceSyncCore", targets: ["FaceSyncCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "FaceSyncCore", dependencies: ["CSQLite"]),
        .testTarget(name: "FaceSyncCoreTests", dependencies: ["FaceSyncCore"])
    ]
)
