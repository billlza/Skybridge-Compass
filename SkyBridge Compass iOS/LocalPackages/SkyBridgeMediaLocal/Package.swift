// swift-tools-version: 6.0
import PackageDescription

let latestCStandardFlags = ["-std=gnu23"]

let package = Package(
    name: "SkyBridgeMediaLocal",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SkyBridgeOpus", targets: ["SkyBridgeOpus"]),
        .library(name: "SkyBridgeRealtimeMedia", targets: ["SkyBridgeRealtimeMedia"])
    ],
    targets: [
        .binaryTarget(
            name: "libopus",
            path: "Vendor/libopus.xcframework"
        ),
        .target(
            name: "CSkyBridgeOpusShim",
            dependencies: ["libopus"],
            path: "Sources/CSkyBridgeOpusShim",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(latestCStandardFlags)
            ]
        ),
        .target(
            name: "SkyBridgeOpus",
            dependencies: ["CSkyBridgeOpusShim"],
            path: "Sources/SkyBridgeOpus"
        ),
        .target(
            name: "SkyBridgeRealtimeMedia",
            dependencies: ["SkyBridgeOpus"],
            path: "Sources/SkyBridgeRealtimeMedia"
        )
    ]
)
