// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkyBridgeCompassApp",
    platforms: [
        .macOS(.v13) // 支持macOS 13+，确保Apple Silicon优化特性可用，同时保持兼容性
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
            publicHeadersPath: "include",
            cSettings: [
                // ARM64优化编译选项
                .define("TARGET_CPU_ARM64", to: "1"),
                .define("APPLE_SILICON_OPTIMIZED", to: "1")
            ]
        ),
        .target(
            name: "SkyBridgeCore",
            dependencies: [
                "Starscream",
                "FreeRDPBridge",
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCore",
            resources: [
                .process("RemoteDesktop/RemoteDesktopShaders.metal"),
                .process("Rendering/Metal4Shaders.metal")
            ],
            swiftSettings: [
                // Apple Silicon特定优化
                .define("APPLE_SILICON_OPTIMIZED"),
                .define("ARM64_NATIVE")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalFX"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                // Apple Silicon性能框架
                .linkedFramework("Accelerate"), // 向量化计算优化
                .linkedFramework("MetalPerformanceShaders") // GPU加速计算
            ]
        ),
        .executableTarget(
            name: "SkyBridgeCompassApp",
            dependencies: [
                "SkyBridgeCore",
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCompassApp",
            resources: [
                // 处理并打包目标内的 Resources 目录（例如 AppIcon.icns / AppIcon.png）
                .process("Resources")
            ],
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
        ),
        .testTarget(
            name: "SkyBridgeCoreTests",
            dependencies: ["SkyBridgeCore"],
            path: "Tests/SkyBridgeCoreTests"
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
