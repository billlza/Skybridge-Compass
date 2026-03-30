import XCTest
import CryptoKit
import Network
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RegressionHardeningTests: XCTestCase {
    @MainActor
    func testOfflineQueueCleanupRemovesExpiredPendingAndFailedMessages() {
        let queue = OfflineMessageQueue.shared
        queue.clear()
        defer { queue.clear() }

        let expiredPending = OfflineMessage(
            id: "expired-pending-\(UUID().uuidString)",
            targetDeviceId: "peer-a",
            messageType: .text,
            payload: Data("p".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let expiredFailed = OfflineMessage(
            id: "expired-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-b",
            messageType: .text,
            payload: Data("f".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let liveFailed = OfflineMessage(
            id: "live-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-c",
            messageType: .text,
            payload: Data("live".utf8),
            expiresAt: Date().addingTimeInterval(3600)
        )

        queue.enqueue(expiredPending)
        queue.enqueue(expiredFailed)
        queue.enqueue(liveFailed)

        for _ in 0..<3 {
            queue.markAsFailed(expiredFailed.id)
            queue.markAsFailed(liveFailed.id)
        }

        XCTAssertEqual(queue.totalCount, 3)

        queue.cleanupExpiredMessages()

        XCTAssertEqual(queue.totalCount, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)
        XCTAssertEqual(queue.failedMessages.first?.id, liveFailed.id)
    }

    @MainActor
    func testTrustedDeviceStoreTreatsDiscoveryIdAsTrustedAlias() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted Mac",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: rawDeviceId))
        XCTAssertTrue(store.isTrusted(deviceId: "id:\(rawDeviceId)"))
    }

    @MainActor
    func testTrustedDeviceStoreResolvesHostAliasBackToCanonicalTrustedID() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: "host:fe80::81d:bb45:8c18:6d6a%en0"),
            "id:\(rawDeviceId)"
        )
    }

    func testConnectableAddressCanonicalizerPreservesLinkLocalScopeForConnectionTargets() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("[fe80::468:f5a1:462b:29d3%bridge100].5901"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
    }

    func testConnectableAddressCanonicalizerStripsInterfaceScopeForLookupKeys() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.lookupKey("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3"
        )
    }

    func testViewerCapabilityDoesNotImplyRemoteControlHostSupport() {
        let viewerOnly = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Viewer iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "18.0",
            ipAddress: nil,
            services: [],
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: false,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop_viewer"],
            capabilities: ["remote_desktop_viewer"]
        )
        XCTAssertFalse(viewerOnly.supportsRemoteControl)

        let controlHost = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Remote Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20",
            services: [],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop", "remote_control"],
            capabilities: ["remote_desktop", "remote_control"]
        )
        XCTAssertTrue(controlHost.supportsRemoteControl)
    }

    @MainActor
    func testDeviceDiscoveryCleanupPreservesSilentDeviceWhenBrowserStillHasLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::18ac:9228:7844:60fe%en0"
        )
        let endpointKey = "Lza的MacBook\\032Pro._skybridge._tcp.local."

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [endpointKey: device.id],
            liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType.skybridge: [endpointKey]]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertTrue(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertEqual(manager.discoveredDevices.first?.id, device.id)
    }

    @MainActor
    func testDeviceDiscoveryCleanupRemovesTrulyStaleDeviceWithoutLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Old Mac",
            modelName: "Mac mini",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.8"
        )

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [:],
            liveBrowseEndpointKeysByServiceType: [:]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertFalse(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    @MainActor
    func testRemoteDesktopBootstrapGuardRejectsFailedLANSession() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .error("连接已断开")
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: false,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementAllowsForcedFirstFrameConfirmation() {
        let now = Date()

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: true,
                lastAnnouncementAt: now,
                now: now
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementSkipsRedundantResendAfterAck() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: true,
                force: false,
                lastAnnouncementAt: nil,
                now: Date()
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementThrottlesUntilRetryWindowExpires() {
        let now = Date()

        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.2),
                now: now
            )
        )

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.8),
                now: now
            )
        )
    }

    @MainActor
    func testTrustResolvedPeerPersistsDeclaredDeviceIdForFutureBootstrap() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let declaredDeviceId = "id:\(UUID().uuidString.lowercased())"
        let runtimeAliasDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trustResolvedPeer(runtimeAliasDevice, declaredDeviceId: declaredDeviceId)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: runtimeAliasDevice),
            declaredDeviceId
        )
    }

    @MainActor
    func testCodablePersistenceStoreMigratesLegacyDefaultsIntoProtectedStateFile() throws {
        let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
        let legacyKey = "legacy.persistence.payload"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: "Tests/\(UUID().uuidString).json",
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: "SkyBridgeStateTests",
            defaults: defaults
        )
        let expected = ["alpha", "beta", "gamma"]
        defaults.set(try JSONEncoder().encode(expected), forKey: legacyKey)

        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(store.load(), expected)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testP2PConnectionManagerPromotesPresentationIdentityWithoutBreakingRuntimeLookup() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.42"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.42"
        )

        let resolvedRuntimePeerId = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(resolvedRuntimePeerId, runtimePeerId)
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .connected)
        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(
            manager.activeConnections.first(where: { $0.device.id == stablePeerId })?.device.name,
            "Stable Mac"
        )
        XCTAssertNil(manager.connectionErrorByDeviceId[stablePeerId])
    }

    @MainActor
    func testP2PConnectionManagerTerminalCleanupRemovesPresentationArtifactsAndSuite() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.52"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.52"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.mlkem768, for: runtimePeerId)

        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(manager.negotiatedSuiteByDeviceId[stablePeerId], .mlkem768)

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)

        XCTAssertFalse(manager.activeConnections.contains { connection in
            let deviceId = connection.device.id
            return deviceId == runtimePeerId || deviceId == stablePeerId
        })
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[runtimePeerId])
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .disconnected)
    }

    @MainActor
    func testDashboardViewModelRefreshesStatusWhenNegotiatedSuitePublishes() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.57"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Classic Peer",
            ipAddress: "192.168.1.57"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, connectedText)

        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic\(connectedText)")

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
    }

    @MainActor
    func testP2PConnectionManagerResolvesPresentationPeerIdBackToRuntimePeerId() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.62"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.62"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(manager.testResolveRuntimePeerId(forAnyPeerId: stablePeerId), runtimePeerId)
    }

    @MainActor
    func testResolvedConnectionStatusPrefersLiveConnectionOverStaleAliasFailure() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.72"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testSimulateTerminalCleanup(
            runtimePeerId: runtimePeerId,
            terminalStatus: .failed,
            error: "stale failure"
        )
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )

        let device = DiscoveredDevice(
            id: stablePeerId,
            name: "Stable Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.72"
        )

        XCTAssertEqual(manager.resolvedConnectionStatus(for: device), .connected)
        XCTAssertNil(manager.resolvedConnectionError(for: device))
    }

    func testProcessMessageBWithoutTranscriptHashAFailsWithExplicitReason() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        do {
            _ = try await context.processMessageB(messageB)
            XCTFail("Expected processMessageB to fail when transcript hash A is missing")
        } catch {
            assertMissingTranscriptHashA(error)
        }
    }

    func testConcurrentProcessMessageBWithoutTranscriptHashAFailsDeterministically() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        let errors = await withTaskGroup(of: Error?.self, returning: [Error].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await context.processMessageB(messageB)
                        return nil
                    } catch {
                        return error
                    }
                }
            }

            var collected: [Error] = []
            for await error in group {
                if let error {
                    collected.append(error)
                }
            }
            return collected
        }

        XCTAssertEqual(errors.count, 12)
        for error in errors {
            assertMissingTranscriptHashA(error)
        }
    }

    func testTrafficPaddingRoundTripAndMalformedFrameBehavior() {
        let defaults = UserDefaults.standard
        let enabledKey = "sb_traffic_padding_enabled"
        let modeKey = "sb_traffic_padding_mode"
        let fixedKey = "sb_traffic_padding_fixed_size"

        let oldEnabled = defaults.object(forKey: enabledKey)
        let oldMode = defaults.object(forKey: modeKey)
        let oldFixed = defaults.object(forKey: fixedKey)

        defer {
            restore(defaults, key: enabledKey, value: oldEnabled)
            restore(defaults, key: modeKey, value: oldMode)
            restore(defaults, key: fixedKey, value: oldFixed)
        }

        defaults.set(true, forKey: enabledKey)
        defaults.set(TrafficPaddingMode.fixed.rawValue, forKey: modeKey)
        defaults.set(128, forKey: fixedKey)

        let payload = Data("traffic-padding-regression".utf8)
        let wrapped = TrafficPadding.wrapIfEnabled(payload, label: "unit")

        XCTAssertEqual(wrapped.count, 128)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped, label: "unit"), payload)

        var malformed = Data([0x53, 0x42, 0x50, 0x32])
        var declaredLen = UInt32(512).bigEndian
        malformed.append(Data(bytes: &declaredLen, count: 4))
        malformed.append(Data(repeating: 0xAA, count: 12))

        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(malformed, label: "unit"), malformed)
    }

    @MainActor
    func testFileTransferPrefersLocalP2POverStaleWebRTCForSamePeer() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: ["id:peer-1"]
        )

        XCTAssertFalse(shouldPreferCrossNetwork)
    }

    @MainActor
    func testFileTransferUsesCrossNetworkWhenNoLocalP2PExists() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: []
        )

        XCTAssertTrue(shouldPreferCrossNetwork)
    }

    func testRemoteDesktopStreamConfigurationPayloadEqualityIgnoresSentAtButTracksRefreshToken() {
        let base = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 1
        )

        let sameSettingsDifferentTimestamp = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 999
        )

        let refreshed = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: 7,
            sentAt: 1000
        )

        XCTAssertEqual(base, sameSettingsDifferentTimestamp)
        XCTAssertNotEqual(base, refreshed)
    }

    func testRemoteDesktopAutomaticViewerPolicyPrefersStableH264At60FPS() {
        XCTAssertEqual(RemoteDesktopViewerFrameRate.adaptive.targetFPS, 60)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.width, 5120)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.height, 2880)
        XCTAssertEqual(RemoteDesktopViewerSettings().activePreset, .automatic)
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["hevc", "jpeg", "h264"]
            ),
            "h264"
        )
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["jpeg", "h264"]
            ),
            "h264"
        )
    }

    func testRemoteDesktopViewerPresetApplicationSupportsProModes() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro5k120)

        XCTAssertEqual(settings.activePreset, .pro5k120)
        XCTAssertEqual(settings.resolution, .uhd5k)
        XCTAssertEqual(settings.frameRate, .fps120)
        XCTAssertEqual(settings.preferredCodec, .hevc)
        XCTAssertTrue(settings.lowLatencyMode)

        settings.resolution = .qhd1440

        XCTAssertEqual(settings.activePreset, .custom)
    }

    func testRemoteDesktopViewerFluidPresetTargetsLowLatencyH264() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.fluid)

        XCTAssertEqual(settings.activePreset, .fluid)
        XCTAssertEqual(settings.resolution, .hd720)
        XCTAssertEqual(settings.frameRate, .fps60)
        XCTAssertEqual(settings.preferredCodec, .h264)
        XCTAssertTrue(settings.lowLatencyMode)
    }

    func testRemoteDesktopViewerPresetCarriesTransportGovernanceHints() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro4k120)

        XCTAssertEqual(settings.transportTuning.qualityPresetWireValue, "geek4k120")
        XCTAssertEqual(settings.transportTuning.jitterBufferFrames, 1)
        XCTAssertEqual(settings.transportTuning.refreshStrategy, "instant")
        XCTAssertEqual(settings.transportTuning.lossRecoveryMode, "fast-retransmit")
        XCTAssertTrue(settings.transportTuning.damageTrackingEnabled)
        XCTAssertTrue(settings.transportTuning.separateCursorChannelEnabled)
        XCTAssertTrue(settings.transportTuning.interactionOverlayChannelEnabled)
    }

    func testRemoteDesktopCodecGovernanceDisablesHEVCAfterRepeatedDecoderFailures() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start),
            .none
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "VTDecompressionSessionDecodeFrame status=-12909",
                at: start.addingTimeInterval(0.2)
            ),
            .none
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected HEVC circuit breaker to disable the codec temporarily")
        }

        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
        XCTAssertEqual(
            governance.effectivePreferredCodec(
                userPreference: .automatic,
                supportedFormats: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            "h264"
        )
        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
    }

    func testRemoteDesktopCodecGovernanceReenablesHEVCAfterStableFallbackFrames() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_100)

        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start)
        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start.addingTimeInterval(0.1))
        let disableEvent = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.2)
        )
        guard case .disableHEVC(let until) = disableEvent else {
            return XCTFail("Expected HEVC to enter cooldown first")
        }

        var probeEvent: RemoteDesktopCodecGovernanceEvent = .none
        for frameIndex in 0..<24 {
            probeEvent = governance.noteDecodeSuccess(
                format: "h264",
                at: until.addingTimeInterval(Double(frameIndex) * 0.05)
            )
        }

        XCTAssertEqual(probeEvent, .reenableHEVCProbe)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: until.addingTimeInterval(2)
            ),
            ["hevc", "h264", "jpeg"]
        )
    }

    func testRemoteDesktopCodecGovernanceEscalatesRepeatedSyncFrameWaitsToH264Fallback() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_200)

        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start
            ),
            .requestRefresh
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start.addingTimeInterval(0.2)
            ),
            .requestRefresh
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "waiting-for-sync-frame",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected repeated sync-frame waits to disable HEVC temporarily")
        }

        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
    }

    func testPeerIdentityAliasResolverMapsHostEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.31.20"),
            port: NWEndpoint.Port(integerLiteral: 9527)
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["host:192.168.31.20": "id:peer-1"]
        )

        XCTAssertEqual(resolved, "id:peer-1")
    }

    func testPeerIdentityAliasResolverMapsBonjourEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.service(
            name: "Lza's MacBook Pro",
            type: "_skybridge._tcp",
            domain: "local.",
            interface: nil
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["bonjour:lza's macbook pro@local.": "id:peer-bonjour"]
        )

        XCTAssertEqual(resolved, "id:peer-bonjour")
    }

    @MainActor
    func testResolveBestTransferDevicePrefersTransferServiceCandidateOverBareSnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestTransferDeviceMatchesScopedHostSnapshotToReachableTransferCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
    }

    @MainActor
    func testResolveBestRemoteDesktopDevicePrefersReachableRemoteCandidateOverCapabilityOnlySnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestRemoteDesktopDeviceMatchesScopedHostSnapshotToReachableRemoteCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
    }

    @MainActor
    func testLiveLANMacConnectionIsEligibleForRemoteDesktopWithoutExplicitRemoteServiceAdvertisement() {
        let connectionManager = P2PConnectionManager.instance
        connectionManager.installUITestActiveConnections([])
        defer {
            connectionManager.installUITestActiveConnections([])
        }

        let runtimePeerId = "host:fe80::b4:98c9:b9a:3bb3%en2"
        connectionManager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Lza的MacBook Pro",
            ipAddress: "fe80::b4:98c9:b9a:3bb3%en2"
        )

        let device = DiscoveredDevice(
            id: runtimePeerId,
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        XCTAssertTrue(RemoteDesktopManager.instance.canPresentRemoteDesktopOption(for: device))
    }

    @MainActor
    func testCapabilityOnlyTransferDeviceDoesNotExposeExplicitLANTransferService() {
        let device = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        XCTAssertFalse(FileTransferManager.hasExplicitLANTransferService(device))
    }

    @MainActor
    func testCapabilityOnlyRemoteDesktopDeviceDoesNotExposeExplicitLANEndpoint() {
        let device = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        XCTAssertFalse(RemoteDesktopManager.hasExplicitLANRemoteDesktopEndpoint(device))
    }

    @MainActor
    func testProtectedDiscoveryIdentifiersDoNotKeepDisconnectedRuntimePeerAlive() {
        let manager = P2PConnectionManager.instance
        manager.installUITestActiveConnections([])

        let runtimePeerId = "host:fe80::468:f5a1:462b:29d3%bridge100"
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "MacBook Pro",
            ipAddress: "fe80::468:f5a1:462b:29d3%bridge100"
        )

        XCTAssertFalse(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertTrue(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId, terminalStatus: .disconnected)

        XCTAssertTrue(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains(runtimePeerId.lowercased()))
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.installUITestActiveConnections([])
    }

    private func makeInitiatorContext() -> HandshakeContext {
        let signingKey = Curve25519.Signing.PrivateKey()
        return HandshakeContext(
            role: .initiator,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: signingKey.publicKey.rawRepresentation,
            policy: .default,
            peerKEMPublicKeys: [:]
        )
    }

    private func makeMinimalMessageB() -> HandshakeMessageB {
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolAlgorithm: .ed25519
        )

        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x22, count: 32),
            ciphertext: Data([0x01, 0x02, 0x03]),
            tag: Data(repeating: 0x33, count: 16),
            nonce: Data(repeating: 0x44, count: 12)
        )

        return HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x55, count: 32),
            serverNonce: Data(repeating: 0x66, count: HandshakeConstants.nonceSize),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0x77, count: 64),
            identityPublicKeys: identityKeys
        )
    }

    private func assertMissingTranscriptHashA(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let HandshakeError.failed(reason) = error else {
            XCTFail("Expected HandshakeError.failed, got \(error)", file: file, line: line)
            return
        }
        guard case let .cryptoError(message) = reason else {
            XCTFail("Expected HandshakeFailureReason.cryptoError, got \(reason)", file: file, line: line)
            return
        }
        XCTAssertEqual(message, "Missing transcript hash A", file: file, line: line)
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testConnectionPresentationContractTreatsTransportReadyAsConnected() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sessionId: "session-1",
                    source: .code,
                    phase: .transportReady,
                    deviceId: "peer-1",
                    deviceName: "Mac mini",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.phase, .connected)
        XCTAssertEqual(presentation.statusText, "Apple PQC已连接")
    }

    func testConnectionPresentationContractPrioritizesPeerOverCrossNetworkSnapshot() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: nil,
                    suite: "X25519",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sessionId: "session-2",
                    source: .qr,
                    phase: .handshakeComplete,
                    deviceId: "peer-2",
                    deviceName: "Remote Device",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.statusText, "Classic已连接")
    }

    func testLateCleanupTokenDoesNotClearNewSnapshot() {
        let originalToken = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let replacementToken = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let newerSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: "session-1",
            source: .reused,
            phase: .handshakeComplete,
            deviceId: "peer-1",
            deviceName: "Peer A",
            negotiatedSuite: "X-Wing",
            snapshotToken: replacementToken
        )

        let afterLateCleanup = ActiveSessionSnapshotContract.disconnect(
            current: newerSnapshot,
            sessionId: "session-1",
            snapshotToken: originalToken,
            kind: .explicit
        )

        XCTAssertEqual(afterLateCleanup, newerSnapshot)
    }

    func testRemoteDesktopDecodeQueuePolicyPreservesPredictiveVideoOrder() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let first = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x01]),
            timestamp: 1,
            format: "h264"
        )
        let second = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x02]),
            timestamp: 2,
            format: "h264"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                first,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                second,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )

        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, first.imageData)
        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, second.imageData)
    }

    func testRemoteDesktopDecodeQueuePolicyStillImagesReplaceLatestFrame() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let stale = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x11]),
            timestamp: 1,
            format: "jpeg"
        )
        let latest = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x22]),
            timestamp: 2,
            format: "jpeg"
        )

        _ = RemoteDesktopDecodeQueuePolicy.enqueue(
            stale,
            into: &pending,
            waitingForSyncFrame: &waitingForSyncFrame
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                latest,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .replacedStillFrame
        )

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, latest.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyEntersWaitingForSyncWhenQueueIsFull() {
        var pending = (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
            ScreenData(
                width: 1280,
                height: 720,
                imageData: Data([UInt8(index)]),
                timestamp: TimeInterval(index),
                format: "hevc"
            )
        }
        var waitingForSyncFrame = false
        let overflow = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0xFE]),
            timestamp: 99,
            format: "hevc"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                overflow,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enteredWaitingForSync
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyRecoversWhenSyncFrameArrives() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = true
        let syncFrame = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
            timestamp: 3,
            format: "h264",
            isSyncFrame: false
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                syncFrame,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .recoveredWithIndependentFrame
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, syncFrame.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotDetectsDecodedVideoFrameEvidence() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresAudioOnlySamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "audio"),
                    "packetsReceived": NSNumber(value: 128),
                    "bytesReceived": NSNumber(value: 4_096)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotMergesInboundAndTrackSamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "track",
                values: [
                    "kind": NSString(string: "video"),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertEqual(snapshot?.framesDecoded, 7)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresTransportSideReports() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "candidate-pair",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 40_312),
                    "bytesReceived": NSNumber(value: 48_836_959)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "data-channel",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 20_993),
                    "bytesReceived": NSNumber(value: 25_438_840)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }
}
