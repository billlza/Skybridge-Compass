// swift-tools-version: 6.3
import Foundation
import PackageDescription

let packageRootPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let webRTCHeadersIncludePath = "\(packageRootPath)/Sources/Vendor/WebRTCHeaders"
let macOSAppInfoPlistPath = "\(packageRootPath)/Sources/SkyBridgeCompassApp/Info.plist"
let latestCStandardFlags = ["-std=gnu23"]
let latestCXXStandardFlags = ["-std=gnu++23"]

// Build-time gate for Apple CryptoKit PQC types (iOS 26+/macOS 26+).
//
// Why: Swift does not provide a compile-time "SDK has PQC types" check for structs like MLKEM/MLDSA.
// If we define HAS_APPLE_PQC_SDK while compiling against an older SDK, the build will fail.
//
// Build scripts must run a CryptoKit symbol probe before setting this override.
// Direct SwiftPM workflows default to classic/liboqs compilation because Swift
// language or SDK major versions are not proof that PQC symbols are available.
func shouldEnableApplePQCSDK() -> Bool {
    guard let rawOverride = ProcessInfo.processInfo.environment["SKYBRIDGE_ENABLE_APPLE_PQC_SDK"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
        !rawOverride.isEmpty
    else {
        return false
    }

    switch rawOverride {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        fatalError("Invalid SKYBRIDGE_ENABLE_APPLE_PQC_SDK value: \(rawOverride)")
    }
}

let enableApplePQCSDK: Bool = shouldEnableApplePQCSDK()
let swiftPMProductRootRPath = "@loader_path/../../.."

func metalResource(_ path: String) -> Resource {
    // Xcode 27 SwiftPM emits missing-creator warnings when processing .metal resources.
    // The app runtime validates copied shader sources through SkyBridgeMetalShaderLibrary.
    .copy(path)
}

func webRTCTestLinkerSettings() -> [LinkerSetting] {
    [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", swiftPMProductRootRPath], .when(platforms: [.macOS]))
    ]
}

let package = Package(
    name: "SkyBridgeCompassApp",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // 支持 macOS 14.x (Sonoma)、15.x (Sequoia)、26.x (Tahoe) 和 27.x beta - 后量子加密PQC
        // 版本兼容策略：
        // - macOS 14.0–15.x：经典密码 + liboqs/OQSRAII PQC（HPKE 降级为 KEM+AES-GCM）
        // - macOS 26+：首选 Apple CryptoKit 原生 PQC（HPKE X-Wing、ML-KEM、ML-DSA），liboqs 仅作 legacy 兼容
    ],
    products: [
        .executable(name: "SkyBridgeCompassApp", targets: ["SkyBridgeCompassApp"]),
        .executable(name: "MacUIBaselineCapture", targets: ["MacUIBaselineCapture"]),
        .executable(name: "LocalLanInteropHost", targets: ["LocalLanInteropHost"]),
        .executable(name: "LocalLanSmokeSourceHost", targets: ["LocalLanSmokeSourceHost"]),
        .executable(name: "LocalWebRTCSmokeHost", targets: ["LocalWebRTCSmokeHost"]),
        .executable(name: "CurrentPathProbe", targets: ["CurrentPathProbe"]),
        .executable(name: "BaselineBenchRunner", targets: ["BaselineBenchRunner"]),
        .executable(name: "HandshakeBenchRunner", targets: ["HandshakeBenchRunner"]),
        .executable(name: "MessageSizeBenchRunner", targets: ["MessageSizeBenchRunner"]),
        .library(name: "SkyBridgeProtocolCore", targets: ["SkyBridgeProtocolCore"]),
        .library(name: "SkyBridgeAppleTransport", targets: ["SkyBridgeAppleTransport"]),
        .library(name: "SkyBridgeOpus", targets: ["SkyBridgeOpus"]),
        .library(name: "SkyBridgeRealtimeMedia", targets: ["SkyBridgeRealtimeMedia"]),
        .library(name: "SkyBridgeCore", targets: ["SkyBridgeCore"]),
        .library(name: "SkyBridgeUI", targets: ["SkyBridgeUI"]),
        .library(name: "SkyBridgeVisualParity", targets: ["SkyBridgeVisualParity"]),
        // 中文注释：导出 OQSRAII 作为示例静态库，便于独立链接与集成
        .library(name: "OQSRAII", targets: ["OQSRAII"]),
        // 小组件共享数据模型 - 主 App 和 Widget Extension 共用
        .library(name: "SkyBridgeWidgetShared", targets: ["SkyBridgeWidgetShared"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.4.1"),
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.13.0"),
        // ASN.1/DER 解析库：用于 PEM/PKCS#8 私钥解析（Ed25519）
        .package(url: "https://github.com/apple/swift-asn1", from: "1.7.0"),
        // WebRTC (ICE / DataChannel) - 跨网连接基础设施（走 STUN/TURN）
        // 注意：上游 149.0.0 发布损坏（资产 SHA256 与其 manifest 声明不符，SwiftPM 必然拉取失败），
        // 故停留在 148.x；上游修复后再升级。
        .package(url: "https://github.com/stasel/WebRTC", from: "148.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "liboqs",
            path: "Sources/Vendor/liboqs.xcframework"
        ),
        .binaryTarget(
            name: "libopus",
            path: "Sources/Vendor/libopus.xcframework"
        ),
        .binaryTarget(
            name: "FreeRDP",
            path: "Sources/Vendor/FreeRDP.xcframework"
        ),
        .binaryTarget(
            name: "WinPR",
            path: "Sources/Vendor/WinPR.xcframework"
        ),
        .binaryTarget(
            name: "FreeRDPClient",
            path: "Sources/Vendor/FreeRDPClient.xcframework"
        ),
        .target(
            name: "OQSRAII",
            dependencies: ["liboqs"],
            path: "Sources/OQSRAII",
            publicHeadersPath: "include",
            cxxSettings: [
                // 中文注释：启用 C++23 支持，统一 Apple 端原生桥接目标的语言标准。
                .unsafeFlags(latestCXXStandardFlags)
            ]
        ),
        .target(
            name: "FreeRDPBridge",
            dependencies: ["WinPR", "FreeRDP", "FreeRDPClient"],
            path: "Sources/FreeRDPBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(latestCStandardFlags),
                // Apple Silicon 优化编译选项（不要手动定义 TARGET_CPU_*，由 SDK/编译器根据架构提供）
                .define("APPLE_SILICON_OPTIMIZED", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "SkyBridgeSmokeSupport",
            dependencies: [],
            path: "Sources/SkyBridgeSmokeSupport",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "LocalLanInteropHost",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeSmokeSupport"
            ],
            path: "Sources/LocalLanInteropHost",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "LocalLanSmokeSourceHost",
            dependencies: [
                "SkyBridgeSmokeSupport"
            ],
            path: "Sources/LocalLanSmokeSourceHost",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "CurrentPathProbe",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeProtocolCore",
                "SkyBridgeAppleTransport"
            ],
            path: "Sources/CurrentPathProbe",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "NoiseKit",
            dependencies: [],
            path: "Sources/NoiseKit"
        ),
        .target(
            name: "SkyBridgeProtocolCore",
            dependencies: [],
            path: "Sources/SkyBridgeProtocolCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .target(
            name: "SkyBridgeAppleTransport",
            dependencies: [
                "SkyBridgeProtocolCore"
            ],
            path: "Sources/SkyBridgeAppleTransport",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "WebRTCAudioDeviceBridge",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/WebRTCAudioDeviceBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(latestCStandardFlags),
                .unsafeFlags(["-I", webRTCHeadersIncludePath])
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox")
            ]
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
            dependencies: [
                "CSkyBridgeOpusShim"
            ],
            path: "Sources/SkyBridgeOpus",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SkyBridgeRealtimeMedia",
            dependencies: [
                "SkyBridgeOpus"
            ],
            path: "Sources/SkyBridgeRealtimeMedia",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "SkyBridgeCore",
            dependencies: [
                "SkyBridgeProtocolCore",
                "SkyBridgeAppleTransport",
                "SkyBridgeOpus",
                "SkyBridgeRealtimeMedia",
                "SkyBridgeSmokeSupport",
                "FreeRDPBridge",
                "WebRTCAudioDeviceBridge",
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "WebRTC", package: "WebRTC"),
                "liboqs",
                "OQSRAII",
                "SkyBridgeWidgetShared"
            ],
            path: "Sources/SkyBridgeCore",
            // 排除文档文件，避免未处理文件警告 - 符合 Swift 6.3 最佳实践
            exclude: [
                "RemoteDesktop/UltraStream/README.md",
                "Weather/PerformanceOptimization.md"
            ],
            resources: [
                .process("Resources"),
                metalResource("RemoteDesktop/RemoteDesktopShaders.metal"),
                metalResource("RemoteDesktop/Shaders/RemoteDesktopPassthrough.metal"),
                metalResource("RemoteDesktop/Shaders/RemoteDesktopHDR.metal"),
                metalResource("Rendering/Metal4Shaders.metal"),
                metalResource("Rendering/AuroraShaders.metal"),
                metalResource("Shaders/WeatherParticleShaders.metal"),
                metalResource("Rendering/WeatherShaders.metal"),
                metalResource("Weather/RainShaders.metal"),
                metalResource("Weather/HazeShaders.metal"),
                metalResource("Weather/HazeParticleShaders.metal")
                // 注意：PerformanceOptimization.md 已在 exclude 中，不需要在 resources 中处理
            ],
            swiftSettings: ([
                // Apple Silicon特定优化
                .define("APPLE_SILICON_OPTIMIZED"),
                .define("ARM64_NATIVE"),
                // Swift 6.3 严格并发控制
                .enableUpcomingFeature("StrictConcurrency"),
                // WebRTC binary header overlay (SwiftPM): provide missing public/internal include paths on macOS.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
                .define("OQS_ENABLED"),
            ] + (enableApplePQCSDK ? [.define("HAS_APPLE_PQC_SDK")] : [])),
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalFX"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"), // macOS 26+ 后量子加密支持（HPKE X-Wing, ML-KEM）
                .linkedFramework("Network"), // 原生 WebSocket 与网络路径迁移支持
                // Apple Silicon性能框架
                .linkedFramework("Accelerate"), // 向量化计算优化
                .linkedFramework("MetalPerformanceShaders"), // GPU加速计算
                // macOS 系统框架
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CloudKit"),
                // 中文注释：移除静默链接器告警，严格清0依赖对象版本配置由 XCFramework 重建保障
            ]
        ),
        .target(
            name: "SkyBridgeVisualParity",
            dependencies: [],
            path: "Sources/SkyBridgeVisualParity"
        ),
        .target(
            name: "SkyBridgeUI",
            dependencies: [
                "SkyBridgeCore"
            ],
            path: "Sources/SkyBridgeUI",
            swiftSettings: [
                // Apple Silicon特定优化
                .define("APPLE_SILICON_OPTIMIZED"),
                .define("ARM64_NATIVE"),
                // Swift 6.3 严格并发控制
                .enableUpcomingFeature("StrictConcurrency"),
                // SkyBridgeUI depends on SkyBridgeCore -> WebRTC; keep Clang scanner include paths aligned.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "SkyBridgeCoreTests",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeUI",
                "SkyBridgeOpus",
                "SkyBridgeRealtimeMedia",
                "OQSRAII",
                "PrivateSensorBridge"
            ],
            path: "Tests/SkyBridgeCoreTests",
            exclude: [
            ],
            swiftSettings: ([
                // 测试目标同样会导入 WebRTC，保持与主模块一致的头文件覆盖路径，避免 clang 依赖扫描误报。
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
            ] + (enableApplePQCSDK ? [
                // 与 SkyBridgeCore 保持一致：否则测试中的 `#if HAS_APPLE_PQC_SDK` 分支会与被测模块不一致
                .define("HAS_APPLE_PQC_SDK")
            ] : [])),
            linkerSettings: webRTCTestLinkerSettings()
        ),
        .testTarget(
            name: "SkyBridgeBenchTests",
            dependencies: [
                "SkyBridgeCore",
                "OQSRAII",
                "NoiseKit"
            ],
            path: "Tests/SkyBridgeBenchTests",
            swiftSettings: ([
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
            ] + (enableApplePQCSDK ? [
                .define("HAS_APPLE_PQC_SDK")
            ] : []))
        ),
        // 小组件共享模型测试
        .testTarget(
            name: "SkyBridgeWidgetSharedTests",
            dependencies: [
                "SkyBridgeWidgetShared"
            ],
            path: "Tests/SkyBridgeWidgetSharedTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SkyBridgeCompassApp",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeUI",
                "SkyBridgeVisualParity",
                "SkyBridgeSmokeSupport",
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCompassApp",
            // 排除配置文件和文档 - 符合 Swift 6.3 最佳实践
            exclude: [
                "Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIconDock.icns",
                "Resources/AppIconDock.png",
                "Resources/AppIconMaster.png",
                "Resources/AppIconMaster.svg",
                "Resources/Assets.xcassets",
                "Resources/BrandIcon.png",
                "Resources/Icons",
                "Resources/SkyBridgeCompassApp.entitlements",
                "Resources/app-icon.svg",
                "Resources/app_icon.png",
                "SkyBridgeCompassApp.entitlements",
                "SkyBridgeCompassApp.packaging.entitlements",
                "SkyBridgeCompassApp.native.packaging.entitlements"
            ],
            resources: [
                // Process the development-only Resources directory; release packaging installs precomposed icon assets separately.
                .process("Resources"),
                // 全页面雾霾效果着色器
                metalResource("GlobalHazeShaders.metal"),
            ],
            swiftSettings: [
                // Apple Silicon特定优化
                .enableUpcomingFeature("StrictConcurrency"),
                .define("APPLE_SILICON_OPTIMIZED"),
                // App target depends transitively on SkyBridgeCore -> WebRTC.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("AppIntents"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("WebKit"),
                .unsafeFlags([
                    "-Xlinker",
                    "-sectcreate",
                    "-Xlinker",
                    "__TEXT",
                    "-Xlinker",
                    "__info_plist",
                    "-Xlinker",
                    macOSAppInfoPlistPath
                ], .when(platforms: [.macOS])),
                // 中文注释：移除静默链接器告警，依赖库目标版本已统一为 14.0
            ]
        ),
        .executableTarget(
            name: "MacUIBaselineCapture",
            dependencies: ["SkyBridgeVisualParity"],
            path: "Sources/MacUIBaselineCapture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "LocalWebRTCSmokeHost",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeSmokeSupport"
            ],
            path: "Sources/LocalWebRTCSmokeHost",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .define("APPLE_SILICON_OPTIMIZED"),
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "BaselineBenchRunner",
            dependencies: [
                "SkyBridgeCore",
                "NoiseKit"
            ],
            path: "Sources/BaselineBenchRunner",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "HandshakeBenchRunner",
            dependencies: [
                "SkyBridgeCore",
                "OQSRAII"
            ],
            path: "Sources/HandshakeBenchRunner",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "MessageSizeBenchRunner",
            dependencies: [
                "SkyBridgeCore"
            ],
            path: "Sources/MessageSizeBenchRunner",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath], .when(platforms: [.macOS]))
            ]
        ),
        // 小组件共享数据模型 - 轻量级，无外部依赖
        .target(
            name: "SkyBridgeWidgetShared",
            dependencies: [],
            path: "Sources/SkyBridgeWidgetShared",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SkyBridgeCompassWidgets",
            dependencies: [
                "SkyBridgeWidgetShared"
            ],
            path: "Sources/SkyBridgeCompassWidgets",
            exclude: ["Info.plist", "SkyBridgeCompassWidgetsExtension.entitlements"],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "PrivateSensorBridgeC",
            dependencies: [],
            path: "Sources/PrivateSensorBridgeC",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(latestCStandardFlags)
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "PrivateSensorBridge",
            dependencies: ["PrivateSensorBridgeC"],
            path: "Sources/PrivateSensorBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "PowerMetricsHelper",
            dependencies: ["PrivateSensorBridge"],
            path: "Sources/PowerMetricsHelper",
            exclude: ["Info.plist", "com.skybridge.PowerMetricsHelper.plist"], // 排除 plist 文件，它们由系统管理
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        // XPC Helper for isolated regex matching (ReDoS protection)
        // Minimal privileges: no file system, no network, stateless
        .executableTarget(
            name: "RegexMatchingHelper",
            dependencies: [],
            path: "Sources/RegexMatchingHelper",
            exclude: ["RegexMatchingHelper.entitlements"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        )
    ],
    swiftLanguageModes: [
        .v6 // 启用 Swift 6.3 完整语言模式，包括严格并发检查和新特性
    ]
)
