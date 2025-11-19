// swift-tools-version: 6.0
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "SkybridgeCompass",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .iOSApplication(
            name: "SkybridgeCompass",
            targets: ["SkybridgeCompassApp"],
            bundleIdentifier: "com.skybridge.mobile",
            teamIdentifier: "SKYBR",
            displayVersion: "0.1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .asset("AccentColor"),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
            ],
            additionalInfoPlistContentFilePath: "Info.plist"
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SkybridgeCompassApp",
            dependencies: [
                "SkyBridgeDesignSystem",
                "SkyBridgeCore",
                "DeviceDiscoveryKit",
                "RemoteDesktopKit",
                "QuantumSecurityKit",
                "SettingsKit"
            ],
            path: "Sources/SkybridgeCompassApp",
            resources: [.process("Resources")]
        ),
        .target(name: "SkyBridgeDesignSystem"),
        .target(name: "SkyBridgeCore"),
        .target(name: "DeviceDiscoveryKit"),
        .target(name: "RemoteDesktopKit"),
        .target(name: "QuantumSecurityKit"),
        .target(name: "SettingsKit"),
        .target(name: "SkyBridgeWidgets")
    ]
)
