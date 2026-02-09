// swift-tools-version: 6.2
// SkyBridge Compass iOS - Swift Package Configuration
// 与 macOS 版本共享核心模块，支持 iOS 17 - iOS 26

import PackageDescription
import Foundation

// Build-time gate for Apple CryptoKit PQC types (iOS 26+).
//
// Important: SwiftPM manifests are commonly evaluated in a restricted sandbox under Xcode,
// where executing external processes (e.g. `xcrun`) and relying on build env vars can be unreliable.
//
// Instead, we gate PQC compilation on the toolchain Swift version:
// - Xcode 26.x ships Swift 6.2+ and the iOS 26 SDK with CryptoKit PQC types (MLKEM/MLDSA).
// - Older Xcode versions won't satisfy this and will compile without PQC support.
//
// Manual override (rare): set SKYBRIDGE_FORCE_DISABLE_APPLE_PQC_SDK=1 to force classic-only compilation.
let enableApplePQCSDK: Bool = {
    if ProcessInfo.processInfo.environment["SKYBRIDGE_FORCE_DISABLE_APPLE_PQC_SDK"] == "1" { return false }
    #if swift(>=6.2)
    return true
    #else
    return false
    #endif
}()

let package = Package(
    name: "SkyBridgeCompassiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),        // 支持 iOS 17, 18
        .macOS(.v14)       // 用于共享模块
    ],
    products: [
        // iOS 主应用
        .library(
            name: "SkyBridgeCompassiOS",
            targets: ["SkyBridgeCompassiOS"]
        )
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            path: "Vendor/WebRTC/WebRTC.xcframework"
        ),
        // MARK: - iOS 主应用目标
        .target(
            name: "SkyBridgeCompassiOS",
            dependencies: [
                "WebRTC"
            ],
            path: "SkyBridgeCompassiOS",
            sources: ["Sources"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: ([
                .enableUpcomingFeature("StrictConcurrency"),
                // WebRTC binary header overlay (SwiftPM): some distributions omit internal headers referenced by WebRTC.h.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", "../Sources/Vendor/WebRTCHeaders"]),
            ] + (enableApplePQCSDK ? [.define("HAS_APPLE_PQC_SDK")] : []))
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
