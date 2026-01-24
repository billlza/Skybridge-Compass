// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Build-time gate for Apple CryptoKit PQC types (iOS 26+/macOS 26+).
//
// Why: Swift does not provide a compile-time "SDK has PQC types" check for structs like MLKEM/MLDSA.
// If we define HAS_APPLE_PQC_SDK while compiling against an older SDK, the build will fail.
//
// Therefore we enable it only when the build environment explicitly opts in (release pipeline / Xcode 26).
func shouldEnableApplePQCSDK() -> Bool {
    if ProcessInfo.processInfo.environment["SKYBRIDGE_ENABLE_APPLE_PQC_SDK"] == "1" { return true }
    // Auto-enable when building with a 26.x SDK (Xcode 26 / iOS 26 / macOS 26).
    //
    // Notes:
    // - In Xcode builds, SDKROOT is sometimes an unversioned path like ".../MacOSX.sdk".
    // - But the build environment often exposes a target triple / SDK name that includes "26.0".
    //
    // We therefore look at multiple hints, and enable when ANY suggests a 26.x SDK.
    let hints: [String] = [
        ProcessInfo.processInfo.environment["SDKROOT"] ?? "",
        ProcessInfo.processInfo.environment["SDK_NAME"] ?? "",
        ProcessInfo.processInfo.environment["PLATFORM_NAME"] ?? "",
        ProcessInfo.processInfo.environment["TARGET_TRIPLE"] ?? "",
        ProcessInfo.processInfo.environment["SWIFT_TARGET_TRIPLE"] ?? "",
        ProcessInfo.processInfo.environment["LLVM_TARGET_TRIPLE"] ?? ""
    ]
    let joined = hints.joined(separator: " ").lowercased()
    if joined.contains("macosx26") { return true }
    if joined.contains("iphoneos26") { return true }
    if joined.contains("iphonesimulator26") { return true }

    // Final fallback: ask Xcode which SDKs are installed.
    // This works even when SDKROOT/SDK_NAME are not exported (common in some SwiftPM/Xcode invocation paths).
    //
    // Safety: defining HAS_APPLE_PQC_SDK is safe as long as the SDK *has* the PQC types; runtime gating is
    // still done via `#available(iOS 26, macOS 26, *)`.
    func sdkMajorVersion(_ sdk: String) -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--sdk", sdk, "--show-sdk-version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let first = raw.split(separator: ".").first,
              let major = Int(first) else { return nil }
        return major
    }

    if let major = sdkMajorVersion("macosx"), major >= 26 { return true }
    if let major = sdkMajorVersion("iphoneos"), major >= 26 { return true }
    if let major = sdkMajorVersion("iphonesimulator"), major >= 26 { return true }

    return false
}

let enableApplePQCSDK: Bool = shouldEnableApplePQCSDK()

let package = Package(
    name: "SkyBridgeCompassApp",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14) // 支持 macOS 14.x (Sonoma)、15.x (Sequoia) 和 26.x (Tahoe) - 后量子加密PQC
        // 版本兼容策略：
        // - macOS 14.0–15.x：经典密码 + liboqs/OQSRAII PQC（HPKE 降级为 KEM+AES-GCM）
        // - macOS 26+（2025-09-15 正式发布）：首选 Apple CryptoKit 原生 PQC（HPKE X-Wing、ML-KEM、ML-DSA），liboqs 仅作 legacy 兼容
    ],
    products: [
        .executable(name: "SkyBridgeCompassApp", targets: ["SkyBridgeCompassApp"]),
        .executable(name: "BaselineBenchRunner", targets: ["BaselineBenchRunner"]),
        .executable(name: "HandshakeBenchRunner", targets: ["HandshakeBenchRunner"]),
        .executable(name: "MessageSizeBenchRunner", targets: ["MessageSizeBenchRunner"]),
        .library(name: "SkyBridgeCore", targets: ["SkyBridgeCore"]),
        .library(name: "SkyBridgeUI", targets: ["SkyBridgeUI"]),
        // 中文注释：导出 OQSRAII 作为示例静态库，便于独立链接与集成
        .library(name: "OQSRAII", targets: ["OQSRAII"]),
        // 小组件共享数据模型 - 主 App 和 Widget Extension 共用
        .library(name: "SkyBridgeWidgetShared", targets: ["SkyBridgeWidgetShared"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.12.0"),
        // ASN.1/DER 解析库：用于 PEM/PKCS#8 私钥解析（Ed25519）
        .package(url: "https://github.com/apple/swift-asn1", from: "1.5.1"),
        // WebRTC (ICE / DataChannel) - 跨网连接基础设施（走 STUN/TURN）
        .package(url: "https://github.com/stasel/WebRTC", from: "114.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "liboqs",
            path: "Sources/Vendor/liboqs.xcframework"
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
                // 中文注释：启用 C++17 支持，确保 RAII 与标准库特性可用
                .unsafeFlags(["-std=c++20"])
            ]
        ),
        .target(
            name: "FreeRDPBridge",
            dependencies: ["WinPR", "FreeRDP", "FreeRDPClient"],
            path: "Sources/FreeRDPBridge",
            publicHeadersPath: "include",
            cSettings: [
                // ARM64优化编译选项
                .define("TARGET_CPU_ARM64", to: "1"),
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
            name: "NoiseKit",
            dependencies: [],
            path: "Sources/NoiseKit"
        ),
        .target(
            name: "SkyBridgeCore",
            dependencies: [
                "FreeRDPBridge",
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "WebRTC", package: "WebRTC"),
                "liboqs",
                "OQSRAII",
                "SkyBridgeWidgetShared"
            ],
            path: "Sources/SkyBridgeCore",
            // 排除文档文件，避免未处理文件警告 - 符合Swift 6.2.3最佳实践
            exclude: ["RemoteDesktop/UltraStream/README.md", "Weather/PerformanceOptimization.md"],
            resources: [
                .process("Resources"),
                .process("RemoteDesktop/RemoteDesktopShaders.metal"),
                .process("Rendering/Metal4Shaders.metal"),
                .process("Rendering/AuroraShaders.metal"),
                .process("Shaders/WeatherParticleShaders.metal"),
                .process("Rendering/WeatherShaders.metal"),
                .process("Rendering/WeatherShaders.air"),
                .process("Weather/RainShaders.metal"),
                .process("Weather/HazeShaders.metal"),
                .process("Weather/HazeParticleShaders.metal")
                // 注意：PerformanceOptimization.md 已在 exclude 中，不需要在 resources 中处理
            ],
            swiftSettings: ([
                // Apple Silicon特定优化
                .define("APPLE_SILICON_OPTIMIZED"),
                .define("ARM64_NATIVE"),
                // Swift 6.2 严格并发控制
                .enableUpcomingFeature("StrictConcurrency"),
                // Suppress deprecated declarations coming from imported Objective‑C headers inside WebRTC.xcframework
                // (e.g., RTCNSGLVideoView uses NSOpenGLView/NSOpenGLPixelFormat which are deprecated on macOS).
                .unsafeFlags(["-Xcc", "-Wno-deprecated-declarations"], .when(platforms: [.macOS])),
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
            name: "SkyBridgeUI",
            dependencies: [
                "SkyBridgeCore"
            ],
            path: "Sources/SkyBridgeUI",
            swiftSettings: [
                // Apple Silicon特定优化
                .define("APPLE_SILICON_OPTIMIZED"),
                .define("ARM64_NATIVE"),
                // Swift 6.2 严格并发控制
                .enableUpcomingFeature("StrictConcurrency"),
                // Suppress deprecated declarations coming from imported Objective‑C headers inside WebRTC.xcframework
                // (e.g., RTCNSGLVideoView uses NSOpenGLView/NSOpenGLPixelFormat which are deprecated on macOS).
                .unsafeFlags(["-Xcc", "-Wno-deprecated-declarations"], .when(platforms: [.macOS])),
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
                "OQSRAII"
            ],
            path: "Tests/SkyBridgeCoreTests",
            exclude: [
            ],
            swiftSettings: (enableApplePQCSDK ? [
                // 与 SkyBridgeCore 保持一致：否则测试中的 `#if HAS_APPLE_PQC_SDK` 分支会与被测模块不一致
                .define("HAS_APPLE_PQC_SDK")
            ] : [])
        ),
        .testTarget(
            name: "SkyBridgeBenchTests",
            dependencies: [
                "SkyBridgeCore",
                "OQSRAII",
                "NoiseKit"
            ],
            path: "Tests/SkyBridgeBenchTests",
            swiftSettings: (enableApplePQCSDK ? [
                .define("HAS_APPLE_PQC_SDK")
            ] : [])
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
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            path: "Sources/SkyBridgeCompassApp",
            // 排除配置文件和文档 - 符合Swift 6.2.1最佳实践
            exclude: ["Info.plist", "SkyBridgeCompassApp.entitlements"],
            resources: [
                // 处理并打包目标内的 Resources 目录（例如 AppIcon.icns / AppIcon.png）
                .process("Resources"),
                // 全页面雾霾效果着色器
                .process("GlobalHazeShaders.metal"),
            ],
            swiftSettings: [
                // Apple Silicon特定优化
                .enableUpcomingFeature("StrictConcurrency"),
                .define("APPLE_SILICON_OPTIMIZED"),
                // Suppress deprecated declarations coming from imported Objective‑C headers inside WebRTC.xcframework
                // (e.g., RTCNSGLVideoView uses NSOpenGLView/NSOpenGLPixelFormat which are deprecated on macOS).
                .unsafeFlags(["-Xcc", "-Wno-deprecated-declarations"], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("AppIntents"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices"),
                // 中文注释：移除静默链接器告警，依赖库目标版本已统一为 14.0
            ]
        ),
        .executableTarget(
            name: "BaselineBenchRunner",
            dependencies: [
                "SkyBridgeCore",
                "NoiseKit"
            ],
            path: "Sources/BaselineBenchRunner",
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
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "MessageSizeBenchRunner",
            dependencies: [
                "SkyBridgeCore"
            ],
            path: "Sources/MessageSizeBenchRunner"
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
        .executableTarget(
            name: "PowerMetricsHelper",
            dependencies: [],
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
        .v6 // 启用Swift 6.2完整语言模式，包括严格并发检查和新特性
    ]
)
