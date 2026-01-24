// swift-tools-version: 5.9
// SkyBridge Compass iOS - Swift Package Configuration
// 与 macOS 版本共享核心模块，支持 iOS 17 - iOS 26

import PackageDescription
import Foundation

// Build-time gate for Apple CryptoKit PQC types (iOS 26+).
// See root Package.swift for rationale.
func shouldEnableApplePQCSDK() -> Bool {
    if ProcessInfo.processInfo.environment["SKYBRIDGE_ENABLE_APPLE_PQC_SDK"] == "1" { return true }
    let hints: [String] = [
        ProcessInfo.processInfo.environment["SDKROOT"] ?? "",
        ProcessInfo.processInfo.environment["SDK_NAME"] ?? "",
        ProcessInfo.processInfo.environment["PLATFORM_NAME"] ?? "",
        ProcessInfo.processInfo.environment["TARGET_TRIPLE"] ?? "",
        ProcessInfo.processInfo.environment["SWIFT_TARGET_TRIPLE"] ?? "",
        ProcessInfo.processInfo.environment["LLVM_TARGET_TRIPLE"] ?? ""
    ]
    let joined = hints.joined(separator: " ").lowercased()
    if joined.contains("iphoneos26") { return true }
    if joined.contains("iphonesimulator26") { return true }
    if joined.contains("macosx26") { return true } // for shared builds
    
    // Fallback: query installed SDK versions via xcrun.
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
    
    if let major = sdkMajorVersion("iphoneos"), major >= 26 { return true }
    if let major = sdkMajorVersion("iphonesimulator"), major >= 26 { return true }
    if let major = sdkMajorVersion("macosx"), major >= 26 { return true } // shared builds
    
    return false
}

let enableApplePQCSDK: Bool = shouldEnableApplePQCSDK()

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
    dependencies: [
        // 可以添加第三方依赖
        // .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.0"),
        // WebRTC (ICE / DataChannel) - 跨网连接基础设施（走 STUN/TURN）
        .package(url: "https://github.com/stasel/WebRTC", from: "114.0.0"),
    ],
    targets: [
        // MARK: - iOS 主应用目标
        .target(
            name: "SkyBridgeCompassiOS",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "SkyBridgeCompassiOS",
            sources: ["Sources"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: ([
                .enableExperimentalFeature("StrictConcurrency")
            ] + (enableApplePQCSDK ? [.define("HAS_APPLE_PQC_SDK")] : []))
        )
    ]
)
