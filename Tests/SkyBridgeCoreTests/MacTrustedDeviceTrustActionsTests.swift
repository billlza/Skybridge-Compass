import XCTest

final class MacTrustedDeviceTrustActionsTests: XCTestCase {
    func testMacTrustedDeviceDetailSplitsRepairAndFullForgetSemantics() throws {
        let detailSource = try repositorySource("Sources/SkyBridgeCompassApp/Views/TrustedDeviceDetailView.swift")
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")

        XCTAssertTrue(detailSource.contains("onRepairP2PTrust"))
        XCTAssertTrue(detailSource.contains("修复 P2P 信任"))
        XCTAssertTrue(detailSource.contains("Repair P2P Trust"))
        XCTAssertTrue(detailSource.contains("彻底忘记设备"))
        XCTAssertTrue(detailSource.contains("Forget Device"))
        XCTAssertFalse(detailSource.contains("Label(ui(chinese: \"移除信任\""))

        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: idsToRepair)"))
        XCTAssertTrue(discoverySource.contains("let idsToForget = Array(Set(idsToRevoke + [declaredDeviceId].compactMap { $0 }))"))
        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.forgetDevice(deviceIds: idsToForget)"))

        let repairRange = try XCTUnwrap(discoverySource.range(of: "onRepairP2PTrust"))
        let repairCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.repairP2PTrust"))
        let forgetRange = try XCTUnwrap(discoverySource.range(of: "onRemoveTrust"))
        let forgetCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.forgetDevice"))

        XCTAssertLessThan(repairRange.lowerBound, repairCleanupRange.lowerBound)
        XCTAssertLessThan(forgetRange.lowerBound, forgetCleanupRange.lowerBound)
    }

    func testMacCloudDeviceConnectButtonsUseRealConnectionPaths() throws {
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let viewModelSource = try repositorySource("Sources/SkyBridgeCompassApp/ViewModels/CloudDeviceListViewModel.swift")
        let crossNetworkSource = try repositorySource("Sources/SkyBridgeCompassApp/Views/CrossNetworkConnectionView.swift")
        let unifiedSource = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")
        let xcodeProjectSource = try repositorySource("SkyBridgeWidgets.xcodeproj/project.pbxproj")

        XCTAssertTrue(
            discoverySource.contains("connectToCloudDevice(device)"),
            "Cloud/iCloud rows in the main discovery UI must call the real connect path."
        )
        XCTAssertTrue(
            discoverySource.contains("connectToOnlineDevice(liveDevice)"),
            "When local Bonjour/P2P already sees the iPad, iCloud rows should prefer the direct local connect path."
        )
        XCTAssertTrue(
            discoverySource.contains("unifiedDeviceManager.resolvedOnlineDevice(for: device)"),
            "Mac UI should merge live local discovery into iCloud row reachability before showing an offline state."
        )
        XCTAssertTrue(
            viewModelSource.contains("OnlineDeviceConnectionCoordinator.connect(to: liveDevice)"),
            "The shared iCloud device view model must perform a real local P2P connect, not call the incomplete KVS offer path."
        )
        XCTAssertFalse(
            viewModelSource.contains("SkyBridgeLogger.discovery.info(\"Connecting to device:"),
            "A log-only iCloud connect button is a fake action and must not return."
        )
        XCTAssertFalse(
            viewModelSource.contains("CrossNetworkConnectionManager.shared.connectToCloudDevice"),
            "Cloud-device list actions must not wait on the iCloud offer/answer path until iOS has a responder."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("unifiedDeviceManager.startDiscovery()"),
            "The cross-network window should start local discovery so live iPad presence can refresh stale iCloud rows."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("OnlineDeviceConnectionCoordinator.connect(to: liveDevice)"),
            "CrossNetwork iCloud rows must prefer the same real Bonjour/P2P connection path as the main discovery UI."
        )
        XCTAssertFalse(
            crossNetworkSource.contains("deviceChainViewModel.connectToDeviceAsync(device)"),
            "CrossNetwork iCloud rows must not delegate back to the incomplete KVS offer/answer action."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("connectingCloudDeviceId"),
            "The cross-network iCloud button must show an in-flight state instead of looking like a no-op."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("deviceChainViewModel.errorMessage"),
            "The cross-network iCloud button must surface connection failures in the current UI."
        )
        XCTAssertTrue(
            unifiedSource.contains("iCloudDiscovery.$discoveredDevices"),
            "UnifiedOnlineDeviceManager must subscribe to iCloud discovery updates instead of creating a half-wired manager."
        )
        XCTAssertTrue(
            unifiedSource.contains("self?.handleiCloudDevicesUpdate(devices)"),
            "iCloud heartbeat rows must flow into the unified online device list."
        )
        XCTAssertTrue(
            unifiedSource.contains("startDiscoveryPresenceRefreshTimer()"),
            "Bonjour discovery must refresh active results periodically so visible iPads do not expire to offline after 60 seconds."
        )
        XCTAssertTrue(
            unifiedSource.contains("device.sources.contains(.skybridgeCloud), timeSinceLastSeen < 120"),
            "KVS-backed iCloud presence must use a TTL compatible with its 30s heartbeat and 120s discovery timeout."
        )
        XCTAssertTrue(
            unifiedSource.contains("iCloudDeviceDiscoveryManager.shared"),
            "All Mac UI discovery paths must share one iCloud manager instead of splitting state across half-wired instances."
        )
        XCTAssertTrue(
            xcodeProjectSource.contains("OnlineDeviceConnectionCoordinator.swift in Sources"),
            "The packaged Mac app target must compile the shared connection coordinator, not only the SwiftPM test target."
        )
    }

    func testSharedICloudPresenceIsWiredForMacPackageAndIOSRuntime() throws {
        let macDev = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.entitlements")
        let macPackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements")
        let macNativePackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.native.packaging.entitlements")
        let iosDebug = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements")
        let iosRelease = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements")
        let iosAppSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift")
        let iosPresenceSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CloudKitSyncManager.swift")
        let macICloudSource = try repositorySource("Sources/SkyBridgeCore/iCloud/iCloudDeviceDiscoveryManager.swift")
        let signingHelperSource = try repositorySource("Scripts/signing_entitlements_helpers.sh")

        for entitlements in [macDev, macPackaging, macNativePackaging, iosDebug, iosRelease] {
            XCTAssertTrue(entitlements.contains("iCloud.com.skybridge.compass"))
            XCTAssertTrue(entitlements.contains("com.apple.developer.ubiquity-kvstore-identifier"))
            XCTAssertTrue(entitlements.contains("$(TeamIdentifierPrefix)com.skybridge.compass"))
        }

        XCTAssertTrue(signingHelperSource.contains("skybridge_expand_build_setting_entitlements"))
        XCTAssertTrue(signingHelperSource.contains("ApplicationIdentifierPrefix"))
        XCTAssertTrue(signingHelperSource.contains("$(TeamIdentifierPrefix)"))

        XCTAssertTrue(iosAppSource.contains("ICloudDevicePresenceService.shared.start()"))
        XCTAssertTrue(iosAppSource.contains("ICloudDevicePresenceService.shared.refreshNow()"))
        XCTAssertTrue(iosPresenceSource.contains("private let deviceKeyPrefix = \"skybridge.device.\""))
        XCTAssertTrue(iosPresenceSource.contains("NSUbiquitousKeyValueStore.default"))
        XCTAssertTrue(iosPresenceSource.contains("\"remote_desktop\", \"file_transfer\", \"clipboard\""))
        XCTAssertTrue(macICloudSource.contains("继续使用 iCloud KV Store 做设备在线心跳"))
        XCTAssertFalse(
            macICloudSource.contains("iCloud 容器不可用：请检查 iCloud Drive"),
            "iCloud KVS device presence must not be blocked by the optional iCloud Documents container."
        )
    }

    func testLegacyP2PConnectionViewDoesNotExposePlanningOnlyConnectionCodeButton() throws {
        let p2pSource = try repositorySource("Sources/SkyBridgeCore/UI/P2PConnectionView.swift")

        XCTAssertFalse(p2pSource.contains("showConnectionCode"))
        XCTAssertFalse(p2pSource.contains("功能规划"))
        XCTAssertFalse(p2pSource.contains("连接码功能将支持"))
    }

    func testMacAppAvoidsVolatileAutosaveDefaultsAndPerFrameDateStateWrites() throws {
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let animatedBackgrounds = try [
            "Sources/SkyBridgeCompassApp/ClassicBackgroundV2.swift",
            "Sources/SkyBridgeCompassApp/StarryBackground.swift",
            "Sources/SkyBridgeCompassApp/DeepSpaceBackground.swift",
            "Sources/SkyBridgeCompassApp/AuroraBackground.swift",
            "Sources/SkyBridgeCompassApp/AuroraBackgroundV2.swift"
        ].map(repositorySource)

        XCTAssertTrue(
            appSource.contains("WindowGroup(localizationManager.localizedString(\"app.name\"), id: \"main\")"),
            "The main Mac window needs a stable id so AppKit does not persist frame keys based on volatile SwiftUI type names."
        )
        XCTAssertTrue(appSource.contains("pruneVolatileSwiftUIAutosaveDefaults()"))
        XCTAssertTrue(appSource.contains("\"NSWindow Frame SwiftUI\""))
        XCTAssertTrue(appSource.contains("\"NSSplitView Subview Frames SwiftUI\""))
        XCTAssertTrue(appSource.contains("(unknown context at $"))

        for source in animatedBackgrounds {
            XCTAssertFalse(
                source.contains(".onChange(of: timeline.date"),
                "TimelineView-backed backgrounds should derive animation time from timeline.date without mutating SwiftUI state every frame."
            )
            XCTAssertFalse(
                source.contains("time += delta"),
                "Per-frame @State accumulation in animated backgrounds can trigger SwiftUI multiple-updates-per-frame warnings."
            )
            XCTAssertTrue(
                source.contains("timeIntervalSince(Self.animationEpoch)") || source.contains("let phase = timeline.date.timeIntervalSince(Self.animationEpoch)"),
                "Animated backgrounds should render from a stable timeline epoch."
            )
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
