// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SkyBridgeCameraKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SkyBridgeCameraKit", targets: ["SkyBridgeCameraKit"]),
    ],
    targets: [
        .target(name: "SkyBridgeCameraKit"),
        .testTarget(
            name: "SkyBridgeCameraKitTests",
            dependencies: ["SkyBridgeCameraKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
