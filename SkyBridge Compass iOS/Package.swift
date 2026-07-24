// swift-tools-version: 6.3
// SkyBridge Compass iOS - Swift Package Configuration
// 与 macOS 版本共享核心模块，支持 iOS 17 - iOS 26

import PackageDescription
import Foundation

// Build-time gate for Apple CryptoKit PQC types (iOS 26+).
//
// Important: SwiftPM manifests are commonly evaluated in a restricted sandbox under Xcode,
// where executing external processes (e.g. `xcrun`) and relying on build env vars can be unreliable.
//
// Build scripts must run a CryptoKit symbol probe before setting this override.
// Direct SwiftPM workflows default to classic/liboqs compilation because Swift
// language or SDK major versions are not proof that PQC symbols are available.
//
// Manual override: set SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1 only after the probe succeeds.
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

// WebRTC binary header overlay path, resolved as an ABSOLUTE path from this
// manifest's own location (#filePath) instead of a build-CWD-relative "../" flag.
// The shared WebRTC headers live in the parent monorepo's Sources/Vendor/WebRTCHeaders;
// a relative `-I ../Sources/...` is resolved against the build working directory and
// breaks when SwiftPM/Xcode builds from a different CWD. An absolute path is stable.
let webRTCHeadersIncludePath: String = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()              // "SkyBridge Compass iOS"
    .deletingLastPathComponent()              // monorepo root
    .appendingPathComponent("Sources/Vendor/WebRTCHeaders")
    .path

let package = Package(
    name: "SkyBridgeCompassiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),        // 支持 iOS 17+；Apple PQC 路径在 iOS 26+ 运行时启用
        .macOS(.v14)       // 用于共享模块
    ],
    products: [
        // iOS 主应用
        .library(
            name: "SkyBridgeCompassiOS",
            targets: ["SkyBridgeCompassiOS"]
        )
    ],
    dependencies: [
        .package(name: "SkyBridgeRoot", path: ".."),
        .package(url: "https://github.com/stasel/WebRTC", from: "148.0.0")
    ],
    targets: [
        // MARK: - iOS 主应用目标
        .target(
            name: "SkyBridgeCompassiOS",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "SkyBridgeQPeriaptRuntime", package: "SkyBridgeRoot"),
                .product(name: "OQSRAII", package: "SkyBridgeRoot"),
                .product(name: "SkyBridgeRealtimeMedia", package: "SkyBridgeRoot")
            ],
            path: "SkyBridgeCompassiOS",
            exclude: [
                "Supporting Files/Info.plist",
                "Supporting Files/LaunchScreen.storyboard"
            ],
            sources: ["Sources"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: ([
                .enableUpcomingFeature("StrictConcurrency"),
                // WebRTC binary header overlay (SwiftPM): some distributions omit internal headers referenced by WebRTC.h.
                // Absolute path (computed above from #filePath) — CWD-independent, unlike the previous "../" flag.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", webRTCHeadersIncludePath]),
            ] + (enableApplePQCSDK ? [.define("HAS_APPLE_PQC_SDK")] : []))
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
