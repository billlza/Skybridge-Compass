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
        .package(name: "SkyBridgeCameraKit", path: "../Packages/SkyBridgeCameraKit"),
        .package(url: "https://github.com/stasel/WebRTC", exact: "150.0.0")
    ],
    targets: [
        // MARK: - iOS 主应用目标
        .target(
            name: "SkyBridgeCompassiOS",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "SkyBridgeQPeriaptRuntime", package: "SkyBridgeRoot"),
                .product(name: "OQSRAII", package: "SkyBridgeRoot"),
                .product(name: "SkyBridgeRealtimeMedia", package: "SkyBridgeRoot"),
                .product(name: "SkyBridgeWebRTCRuntime", package: "SkyBridgeRoot"),
                .product(name: "SkyBridgeMessagePersistence", package: "SkyBridgeRoot"),
                .product(name: "SkyBridgeCameraKit", package: "SkyBridgeCameraKit")
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
            ] + (enableApplePQCSDK ? [.define("HAS_APPLE_PQC_SDK")] : []))
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
