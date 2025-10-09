// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkyBridgeCompassApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SkyBridgeCompassApp", targets: ["SkyBridgeCompassApp"]),
        .library(name: "SkyBridgeCore", targets: ["SkyBridgeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream", from: "4.0.6"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.0.5")
    ],
    targets: [
        .target(
            name: "FreeRDPBridge",
            dependencies: [],
            path: "Sources/FreeRDPBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SkyBridgeCore",
            dependencies: [
                "Starscream",
                "FreeRDPBridge",
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCore",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "SkyBridgeCompassApp",
            dependencies: [
                "SkyBridgeCore",
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCompassApp",
            linkerSettings: [
                .linkedFramework("AppIntents"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices")
            ]
        ),
        .executableTarget(
            name: "SkyBridgeCompassWidgets",
            dependencies: [
                "SkyBridgeCore"
            ],
            path: "Sources/SkyBridgeCompassWidgets",
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ],
    swiftLanguageVersions: [
        .version("6.0")
    ]
)
