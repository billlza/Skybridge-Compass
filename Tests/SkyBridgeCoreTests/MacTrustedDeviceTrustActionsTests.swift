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
            viewModelSource.contains("CrossNetworkConnectionManager.shared.connectToCloudDevice"),
            "The shared iCloud device view model must perform a real cross-network connect, not only log the tap."
        )
        XCTAssertFalse(
            viewModelSource.contains("SkyBridgeLogger.discovery.info(\"Connecting to device:"),
            "A log-only iCloud connect button is a fake action and must not return."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("unifiedDeviceManager.startDiscovery()"),
            "The cross-network window should start local discovery so live iPad presence can refresh stale iCloud rows."
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
    }

    func testSharedICloudPresenceIsWiredForMacPackageAndIOSRuntime() throws {
        let macPackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements")
        let macNativePackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.native.packaging.entitlements")
        let iosDebug = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements")
        let iosRelease = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements")
        let iosAppSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift")
        let iosPresenceSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CloudKitSyncManager.swift")
        let macICloudSource = try repositorySource("Sources/SkyBridgeCore/iCloud/iCloudDeviceDiscoveryManager.swift")
        let signingHelperSource = try repositorySource("Scripts/signing_entitlements_helpers.sh")

        for entitlements in [macPackaging, macNativePackaging, iosDebug, iosRelease] {
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
