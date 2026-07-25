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

// SkyBridgeSmokeSupport is a testing-only module (smoke-status file appender used
// by the real-device smoke lanes). It must never be linked into the shipping
// production app: all production call sites are guarded by #if DEBUG ||
// SKYBRIDGE_TESTING, but SwiftPM would still link the module's public symbols if
// the production targets declared it as an unconditional dependency.
//
// The production release producer (Scripts/build_dmg.sh) sets
// SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT=1 so SkyBridgeCore and SkyBridgeCompassApp
// drop the dependency entirely; every other build (DEBUG, swift test, iOS lanes,
// smoke hosts) keeps it so the guarded code and the smoke-host executables build
// unchanged. If a release build ever forgets the flag, the readiness gate's
// test/smoke-surface scan fails closed.
func shouldExcludeSmokeSupportFromRelease() -> Bool {
    guard let rawOverride = ProcessInfo.processInfo.environment["SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT"]?
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
        fatalError("Invalid SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT value: \(rawOverride)")
    }
}

// Production library/app targets depend on the smoke-support module only when the
// release exclusion is not requested. Smoke-host executables always keep it.
let smokeSupportProductionDependencies: [Target.Dependency] =
    shouldExcludeSmokeSupportFromRelease() ? [] : ["SkyBridgeSmokeSupport"]

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
        .library(name: "SkyBridgeQPeriaptRuntime", targets: ["SkyBridgeQPeriaptRuntime"]),
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
        .package(url: "https://github.com/stasel/WebRTC", from: "148.0.0"),
        .package(path: "Packages/SkyBridgeCameraKit")
    ],
    targets: [
        .binaryTarget(
            name: "liboqs",
            path: "Sources/Vendor/liboqs.xcframework"
        ),
        // Q-Periapt ABI2 PolicyBound hybrid KEM (ML-KEM-768 + X25519) FFI.
        // Admission requires an authenticated signed-policy session and remains
        // beta/default-off; the binary artifact is pinned by release provenance.
        .binaryTarget(
            name: "QPeriaptFFI",
            path: "Sources/Vendor/qperiapt.xcframework"
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
        // Q-Periapt FFI 的 C 包装目标（mirror OQSRAII）。
        //
        // 动机：qperiapt.xcframework 与 liboqs.xcframework 都会把 module.modulemap 放进共享的
        // Release/include/ 目录，导致 Xcode 报 "Multiple commands produce
        // '.../Release/include/module.modulemap'"。OQSRAII 的成熟做法是：liboqs 仅作 .binaryTarget
        // 提供静态库，由一个常规 C/C++ 目标 OQSRAII 消费（Swift `import OQSRAII`），SwiftPM 在该目标
        // 自有模块目录里自动生成模块，不与共享 include 冲突。这里对 QPeriaptFFI 完全照搬：
        //   - QPeriaptFFI（binaryTarget）只贡献 libq_periapt_ffi.a，不再携带任何 module.modulemap；
        //   - CQPeriapt 自带一份 q_periapt.h（vendored，与 OQSRAII 自带 OQSRAII.h 同构），通过伞头
        //     CQPeriapt.h 重新导出 C ABI；SwiftPM 为 CQPeriapt 自动生成模块映射；
        //   - Swift 端改为 `import CQPeriapt`（替代 `import QPeriaptFFI`）。
        // q_periapt_* 符号不变，仅模块名变化。
        .target(
            name: "CQPeriapt",
            dependencies: ["QPeriaptFFI"],
            path: "Sources/CQPeriapt",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SkyBridgeQPeriaptRuntime",
            dependencies: ["CQPeriapt"],
            path: "Sources/SkyBridgeQPeriaptRuntime",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
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
                .define("APPLE_SILICON_OPTIMIZED", to: "1"),
                // 真实 FreeRDP/WinPR 3.26.0 头（与 Sources/Vendor/FreeRDPDylibs 的 dylib 版本一一对应）。
                // 让结构体偏移与设置枚举值由编译器解析，取代此前的占位 opaque 类型 + 硬编码 slot/伪造常量。
                .headerSearchPath("../Vendor/FreeRDPHeaders/include"),
                // FreeRDP/WinPR 头自带若干 deprecated 标注（如 pVerifyCertificate）以及与
                // CoreFoundation 同值不同写法的 HRESULT 宏（S_OK/E_FAIL 等）重定义。均为第三方头、
                // 不可改，仅对本桥接目标抑制这两类告警以满足「零告警」要求；不影响我方代码的告警检查。
                .unsafeFlags(["-Wno-deprecated-declarations", "-Wno-macro-redefined"])
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
        .target(
            name: "SkyBridgeBenchmarkSupport",
            dependencies: ["SkyBridgeCore"],
            path: "Sources/SkyBridgeBenchmarkSupport",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "LocalLanInteropHost",
            dependencies: [
                "SkyBridgeCore",
                "SkyBridgeSmokeSupport",
                "SkyBridgeUI"
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
                .target(name: "FreeRDPBridge", condition: .when(platforms: [.macOS])),
                "WebRTCAudioDeviceBridge",
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "SkyBridgeCameraKit", package: "SkyBridgeCameraKit"),
                "liboqs",
                "OQSRAII",
                "SkyBridgeQPeriaptRuntime",
                "SkyBridgeWidgetShared"
            ] + smokeSupportProductionDependencies,
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
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
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
                "SkyBridgeProtocolCore",
                "SkyBridgeQPeriaptRuntime",
                "SkyBridgeUI",
                "SkyBridgeOpus",
                "SkyBridgeRealtimeMedia",
                "CQPeriapt",
                "OQSRAII",
                "SkyBridgeBenchmarkSupport",
                "PrivateSensorBridge"
            ],
            path: "Tests/SkyBridgeCoreTests",
            exclude: [
            ],
            resources: [
                .copy("Fixtures/QPeriaptABI2/signed-policy-vectors.json")
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
            name: "SkyBridgeQPeriaptRuntimeTests",
            dependencies: ["SkyBridgeQPeriaptRuntime"],
            path: "Tests/SkyBridgeQPeriaptRuntimeTests"
        ),
        .testTarget(
            name: "SkyBridgeBenchTests",
            dependencies: [
                "SkyBridgeCore",
                "OQSRAII",
                "NoiseKit",
                "SkyBridgeBenchmarkSupport"
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
                .product(name: "OrderedCollections", package: "swift-collections")
            ] + smokeSupportProductionDependencies,
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
                "NoiseKit",
                "SkyBridgeBenchmarkSupport"
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
                "OQSRAII",
                "SkyBridgeBenchmarkSupport"
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
