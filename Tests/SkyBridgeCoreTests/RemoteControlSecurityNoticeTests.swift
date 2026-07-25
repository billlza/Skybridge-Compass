import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeUI
import SkyBridgeRealtimeMedia

final class RemoteControlSecurityNoticeTests: XCTestCase {
    func testDiagnosticFieldSanitizerSanitizesStructuredEvidence() {
        XCTAssertEqual(
            DiagnosticFieldSanitizer.fieldValue(" id:device-1\nspoof=value "),
            "id:device-1_spoof_value"
        )
        XCTAssertEqual(DiagnosticFieldSanitizer.fieldValue("  "), "missing")
        XCTAssertEqual(DiagnosticFieldSanitizer.fieldValue(nil), "missing")
    }

    func testSecurityNoticeLocalizationContractCoversCodeShellGateAndAllLocales() throws {
        let requiredKeys = RemoteControlSecurityNoticeLocalizationContract.requiredKeys
        XCTAssertEqual(requiredKeys.count, 20)
        XCTAssertEqual(Set(requiredKeys).count, 20)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keyPattern = try NSRegularExpression(
            pattern: #"\"(remoteControl\.securityNotice\.[A-Za-z0-9_.]+)\""#
        )
        func keys(in source: String) -> Set<String> {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return Set(keyPattern.matches(in: source, range: range).compactMap { match in
                guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[keyRange])
            })
        }

        let presentationSourcePaths = [
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift",
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift",
        ]
        var codeKeys = Set<String>()
        for relativePath in presentationSourcePaths {
            var source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            if relativePath.hasSuffix("RemoteControlSecurityNoticePanelController.swift"),
               let implementationStart = source.range(of: "@available(macOS 14.0, *)")?.lowerBound {
                source = String(source[implementationStart...])
            }
            codeKeys.formUnion(keys(in: source))
        }
        XCTAssertEqual(codeKeys, Set(requiredKeys))

        let smokeScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/run_real_device_p2p_remote_smoke.sh"),
            encoding: .utf8
        )
        let arrayStart = try XCTUnwrap(
            smokeScript.range(of: "REMOTE_CONTROL_SECURITY_NOTICE_LOCALIZATION_KEYS=(")?.upperBound
        )
        let arrayEnd = try XCTUnwrap(smokeScript[arrayStart...].range(of: "\n)"))
        let shellKeys = keys(in: String(smokeScript[arrayStart..<arrayEnd.lowerBound]))
        XCTAssertEqual(shellKeys, Set(requiredKeys))

        for localeDirectory in ["en", "ja", "zh-Hans"] {
            let stringsURL = repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/Resources", isDirectory: true)
                .appendingPathComponent("\(localeDirectory).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let stringsData = try Data(contentsOf: stringsURL)
            let propertyList = try PropertyListSerialization.propertyList(
                from: stringsData,
                options: [],
                format: nil
            )
            let translations = try XCTUnwrap(propertyList as? [String: String])
            for key in requiredKeys {
                let value = try XCTUnwrap(translations[key], "Missing \(key) in \(localeDirectory)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertNotEqual(value, key)
            }
        }
    }

    #if os(macOS)
    @MainActor
    func testReusablePanelStopRejectsPendingNoticeAndCannotBeResurrectedByQueuedRender() async {
        let center = RemoteControlSecurityNoticeCenter.shared
        let controller = RemoteControlSecurityNoticePanelController.shared
        controller.stop()
        center.closeCurrentNoticeFailClosed()
        defer {
            controller.stop()
            center.closeCurrentNoticeFailClosed()
        }

        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "panel-stop-\(UUID().uuidString)",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.90",
            remoteDeviceId: "panel-stop-ipad",
            remoteDeviceName: "Test iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-panel-stop",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )

        controller.start()
        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }

        controller.stop()
        await Task.yield()
        await Task.yield()

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(center.currentNotice)
        XCTAssertFalse(controller.isStartedForTesting)
        XCTAssertFalse(controller.hasPanelForTesting)

        controller.stop()
        XCTAssertFalse(controller.isStartedForTesting)
        XCTAssertFalse(controller.hasPanelForTesting)

        let unownedDescriptor = RemoteControlSecurityDescriptor(
            sessionId: "panel-unowned-stop-\(UUID().uuidString)",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.91",
            remoteDeviceId: "panel-unowned-stop-ipad",
            remoteDeviceName: "Test iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-panel-unowned-stop",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let unownedApprovalTask = Task { @MainActor in
            await center.requestApproval(unownedDescriptor)
        }
        while center.currentNotice?.id != unownedDescriptor.id {
            await Task.yield()
        }

        controller.stop()
        XCTAssertEqual(center.currentNotice?.id, unownedDescriptor.id)
        center.rejectCurrentNotice()
        let unownedDecision = await unownedApprovalTask.value
        XCTAssertEqual(unownedDecision, .rejected)
    }
    #endif

    @MainActor
    func testPresenterMasksSensitiveIdentityValues() {
        XCTAssertEqual(RemoteControlSecurityNoticePresenter.maskedIdentity("ab"), "a***")
        XCTAssertEqual(RemoteControlSecurityNoticePresenter.maskedIdentity("nebula-123456"), "neb***456")
    }

    func testP2PAdmissionBlocksInputAndClipboardBeforeApproval() {
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
                .mouseEvent,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
                .keyboardEvent,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
                .clipboard,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
                .streamConfiguration,
                isApproved: false
            )
        )
        XCTAssertTrue(
            RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
                .mouseEvent,
                isApproved: true
            )
        )
    }

    func testWebRTCAdmissionBlocksInputAndClipboardBeforeApproval() {
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                .mouseEvent,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                .keyboardEvent,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                .clipboard,
                isApproved: false
            )
        )
        XCTAssertFalse(
            RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                .streamConfiguration,
                isApproved: false
            )
        )
        XCTAssertTrue(
            RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                .clipboard,
                isApproved: true
            )
        )
    }

    func testDescriptorDoesNotInventMissingIdentityFields() {
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "session-1",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "device-1",
            remoteDeviceName: nil,
            remoteAccountDisplayName: nil,
            remoteNebulaId: nil,
            localAccountDisplayName: "operator@example.com",
            localNebulaId: "nebula-123456",
            cryptoSuite: "X-Wing PQC"
        )

        XCTAssertNil(descriptor.remoteAccountDisplayName)
        XCTAssertNil(descriptor.remoteNebulaId)
        XCTAssertEqual(descriptor.localNebulaId, "nebula-123456")
        XCTAssertEqual(descriptor.cryptoSuite, "X-Wing PQC")
        XCTAssertEqual(
            descriptor.missingRequiredNoticeMetadata,
            ["remote_account", "remote_nebula"]
        )
    }

    func testDescriptorDoesNotInventMissingOrGenericCryptoSuite() {
        let missingSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-missing-suite",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.10",
            remoteDeviceId: "device-1",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "   "
        )
        let genericSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-generic-suite",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.10",
            remoteDeviceId: "device-1",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "PQC secure channel"
        )
        let concreteSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-concrete-suite",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.10",
            remoteDeviceId: "device-1",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let legacyQPeriaptSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-qperiapt-legacy-suite",
            transportKind: .webrtc,
            remoteIPAddress: "192.0.2.11",
            remoteDeviceId: "android-1",
            remoteDeviceName: "Android",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "Q-Periapt-ContextBound PQC"
        )
        let concreteQPeriaptSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-qperiapt-abi2-suite",
            transportKind: .webrtc,
            remoteIPAddress: "192.0.2.12",
            remoteDeviceId: "android-2",
            remoteDeviceName: "Android",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "Q-Periapt-ABI2-PolicyBound PQC"
        )
        let concreteQPeriaptWireSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-qperiapt-abi2-wire-suite",
            transportKind: .webrtc,
            remoteIPAddress: "192.0.2.14",
            remoteDeviceId: "android-4",
            remoteDeviceName: "Android",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "0x0012 PQC"
        )
        let misleadingSubstringSuite = RemoteControlSecurityDescriptor(
            sessionId: "session-misleading-suite",
            transportKind: .webrtc,
            remoteIPAddress: "192.0.2.13",
            remoteDeviceId: "android-3",
            remoteDeviceName: "Android",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing failed"
        )

        XCTAssertEqual(missingSuite.cryptoSuite, "missing")
        XCTAssertTrue(missingSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertTrue(genericSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertFalse(concreteSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertTrue(legacyQPeriaptSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertFalse(concreteQPeriaptSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertFalse(concreteQPeriaptWireSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
        XCTAssertTrue(misleadingSubstringSuite.missingRequiredNoticeMetadata.contains("crypto_suite"))
    }

    func testPeerIdentityStoreResolvesRemoteIdentityByEndpointAlias() {
        let token = UUID().uuidString
        let alias = "notice-test-\(token)"
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: "remote@example.com",
            nebulaId: "nebula-remote-\(token)",
            deviceId: "device-\(token)",
            deviceName: "Remote iPad"
        )

        RemoteControlSecurityPeerIdentityStore.record(
            identity: identity,
            aliases: ["host:\(alias)"]
        )

        let resolved = RemoteControlSecurityPeerIdentityStore.identity(forAliases: [alias])
        XCTAssertEqual(resolved?.accountDisplayName, "remote@example.com")
        XCTAssertEqual(resolved?.nebulaId, "nebula-remote-\(token)")
        XCTAssertEqual(resolved?.deviceName, "Remote iPad")
    }

    func testPeerIdentityStoreRejectsAmbiguousWeakAliasWithoutCorruptingPrimaryRecords() {
        let store = RemoteControlSecurityPeerIdentityStorage()
        let first = RemoteControlSecurityIdentity(
            accountDisplayName: "first@example.com",
            nebulaId: "nebula-first",
            deviceId: "device-first-1234",
            deviceName: "First iPad"
        )
        let second = RemoteControlSecurityIdentity(
            accountDisplayName: "second@example.com",
            nebulaId: "nebula-second",
            deviceId: "device-second-5678",
            deviceName: "Second iPad"
        )

        XCTAssertTrue(store.record(identity: first, aliases: ["shared-endpoint", "192.0.2.50"]))
        XCTAssertTrue(store.record(identity: second, aliases: ["shared-endpoint", "192.0.2.51"]))

        XCTAssertNil(store.identity(forAliases: ["shared-endpoint"]))
        XCTAssertEqual(store.identity(forAliases: ["device-first-1234"]), first)
        XCTAssertEqual(store.identity(forAliases: ["device-second-5678"]), second)
    }

    func testPeerIdentityStoreExpiresClearsAndEvictsLeastRecentlyUsedRecords() {
        let time = RemoteControlIdentityTestTime(Date(timeIntervalSince1970: 10_000))
        let store = RemoteControlSecurityPeerIdentityStorage(
            timeToLive: 10,
            maximumRecordCount: 2,
            now: { time.current }
        )
        let first = RemoteControlSecurityIdentity(
            accountDisplayName: "first@example.com",
            nebulaId: "nebula-first",
            deviceId: "device-first-1234",
            deviceName: "First iPad"
        )
        let second = RemoteControlSecurityIdentity(
            accountDisplayName: "second@example.com",
            nebulaId: "nebula-second",
            deviceId: "device-second-5678",
            deviceName: "Second iPad"
        )
        let third = RemoteControlSecurityIdentity(
            accountDisplayName: "third@example.com",
            nebulaId: "nebula-third",
            deviceId: "device-third-9012",
            deviceName: "Third iPad"
        )

        XCTAssertTrue(store.record(identity: first, aliases: ["session-first"]))
        time.advance(by: 1)
        XCTAssertTrue(store.record(identity: second, aliases: ["session-second"]))
        time.advance(by: 1)
        XCTAssertEqual(store.identity(forAliases: ["device-first-1234"]), first)
        time.advance(by: 1)
        XCTAssertTrue(store.record(identity: third, aliases: ["session-third"]))

        XCTAssertNil(store.identity(forAliases: ["device-second-5678"]))
        XCTAssertEqual(store.identity(forAliases: ["device-first-1234"]), first)
        XCTAssertEqual(store.identity(forAliases: ["device-third-9012"]), third)

        store.clear(forAliases: ["device-first-1234"])
        XCTAssertNil(store.identity(forAliases: ["device-first-1234"]))
        XCTAssertEqual(store.recordCount, 1)

        time.advance(by: 11)
        XCTAssertNil(store.identity(forAliases: ["device-third-9012"]))
        XCTAssertEqual(store.recordCount, 0)
    }

    func testStreamConfigurationCarriesRemoteControlSecurityIdentity() throws {
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: "viewer@example.com",
            nebulaId: "nebula-viewer",
            deviceId: "viewer-device",
            deviceName: "Viewer iPad"
        )
        let config = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["hevc"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaSessionId: "media-session",
            performanceValidationMode: "extreme",
            mediaFallbackPolicy: "fail-fast",
            remoteControlSecurityIdentity: identity
        )

        let decoded = try JSONDecoder().decode(
            RemoteDesktopStreamConfiguration.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded.remoteControlSecurityIdentity, identity)
        XCTAssertEqual(decoded.remoteControlSecurityIdentity?.nebulaId, "nebula-viewer")
    }

    func testP2PStreamConfigurationRejectsOversizedDecodedSecurityIdentity() throws {
        let data = try streamConfigurationData(
            replacingSecurityIdentityWith: [
                "accountDisplayName": String(repeating: "a", count: 321),
                "nebulaId": "nebula-viewer",
                "deviceId": "viewer-device",
                "deviceName": "Viewer iPad"
            ]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(RemoteDesktopStreamConfiguration.self, from: data)
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "accountDisplayName")
        }
    }

    func testWebRTCStreamConfigurationRejectsControlCharactersInDecodedSecurityIdentity() throws {
        let data = try streamConfigurationData(
            replacingSecurityIdentityWith: [
                "accountDisplayName": "viewer@example.com",
                "nebulaId": "nebula\u{0000}spoofed",
                "deviceId": "viewer-device",
                "deviceName": "Viewer iPad"
            ]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(RemoteDesktopStreamConfiguration.self, from: data)
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "nebulaId")
        }
    }

    func testDecodedSecurityIdentityKeepsLegalNilFieldsBackwardCompatible() throws {
        let data = try streamConfigurationData(
            replacingSecurityIdentityWith: [
                "deviceId": "viewer-device"
            ]
        )

        let decoded = try JSONDecoder().decode(
            RemoteDesktopStreamConfiguration.self,
            from: data
        )
        XCTAssertNil(decoded.remoteControlSecurityIdentity?.accountDisplayName)
        XCTAssertNil(decoded.remoteControlSecurityIdentity?.nebulaId)
        XCTAssertEqual(decoded.remoteControlSecurityIdentity?.deviceId, "viewer-device")
        XCTAssertNil(decoded.remoteControlSecurityIdentity?.deviceName)
    }

    func testVideoRefreshPreservesRemoteControlSecurityIdentity() {
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: "viewer@example.com",
            nebulaId: "nebula-viewer",
            deviceId: "viewer-device",
            deviceName: "Viewer iPad"
        )
        let previous = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["hevc"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaSessionId: "media-session",
            mediaAudioEndpoint: SkyBridgeMediaEndpoint(
                host: "192.0.2.10",
                port: 9,
                relayToken: nil,
                expiresAt: nil
            ),
            remoteControlSecurityIdentity: identity
        )
        let refresh = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["hevc"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            streamRefreshToken: 42
        )

        let preserved = RemoteControlStreamRequestPolicy
            .streamConfigurationByPreservingAudioEndpointForVideoRefresh(refresh, previous: previous)

        XCTAssertEqual(preserved.remoteControlSecurityIdentity, identity)
        XCTAssertEqual(preserved.mediaAudioEndpoint, previous.mediaAudioEndpoint)
    }

    @MainActor
    func testDisconnectCurrentNoticeInvokesActiveDisconnectHandler() async {
        let center = RemoteControlSecurityNoticeCenter()
        let sessionId = "disconnect-handler-\(UUID().uuidString)"
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: sessionId,
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.44",
            remoteDeviceId: "device-disconnect-handler",
            remoteDeviceName: "iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote-123",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac-456",
            cryptoSuite: "X-Wing PQC"
        )
        var disconnectCount = 0

        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }

        center.approveCurrentNotice()
        XCTAssertEqual(center.currentNotice?.id, descriptor.id)

        center.setDisconnectHandler(for: descriptor.id) {
            disconnectCount += 1
        }
        center.disconnectCurrentNotice()

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .approved)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertNil(center.currentNotice)
    }

    @MainActor
    func testStalePanelActionsCannotResolveReplacementNotice() async {
        let center = RemoteControlSecurityNoticeCenter()
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "stale-panel-action-\(UUID().uuidString)",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.92",
            remoteDeviceId: "replacement-ipad",
            remoteDeviceName: "Replacement iPad",
            remoteAccountDisplayName: "replacement@example.com",
            remoteNebulaId: "nebula-replacement",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let staleNoticeID = UUID()
        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }

        center.approveNotice(id: staleNoticeID)
        center.rejectNotice(id: staleNoticeID)
        center.closeNoticeFailClosed(id: staleNoticeID)
        center.disconnectNotice(id: staleNoticeID)

        XCTAssertEqual(center.currentNotice?.id, descriptor.id)
        XCTAssertEqual(center.currentNotice?.phase, .awaitingApproval)

        center.closeNoticeFailClosed(id: descriptor.id)
        let decision = await approvalTask.value
        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(center.currentNotice)
    }

    @MainActor
    func testActiveNoticeRejectsConcurrentInboundRequestWithoutReplacingBanner() async {
        let center = RemoteControlSecurityNoticeCenter()
        let activeDescriptor = RemoteControlSecurityDescriptor(
            sessionId: "active-\(UUID().uuidString)",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.10",
            remoteDeviceId: "active-device",
            remoteDeviceName: "Active iPad",
            remoteAccountDisplayName: "active@example.com",
            remoteNebulaId: "nebula-active",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let competingDescriptor = RemoteControlSecurityDescriptor(
            sessionId: "competing-\(UUID().uuidString)",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "competing-device",
            remoteDeviceName: "Competing iPad",
            remoteAccountDisplayName: "competing@example.com",
            remoteNebulaId: "nebula-competing",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "ML-KEM PQC"
        )

        let approvalTask = Task { @MainActor in
            await center.requestApproval(activeDescriptor)
        }
        while center.currentNotice?.id != activeDescriptor.id {
            await Task.yield()
        }
        center.approveCurrentNotice()
        let firstDecision = await approvalTask.value
        XCTAssertEqual(firstDecision, .approved)

        let competingDecision = await center.requestApproval(competingDescriptor)

        XCTAssertEqual(competingDecision, .rejected)
        XCTAssertEqual(center.currentNotice?.id, activeDescriptor.id)
        XCTAssertEqual(center.currentNotice?.descriptor.sessionId, activeDescriptor.sessionId)
        XCTAssertEqual(center.currentNotice?.phase, .active)
    }

    @MainActor
    func testActiveNoticeEarlyReturnsReleaseOnlyIncomingDisconnectHandlers() async {
        let center = RemoteControlSecurityNoticeCenter()
        let activeDescriptor = RemoteControlSecurityDescriptor(
            sessionId: "handler-retention-\(UUID().uuidString)",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.20",
            remoteDeviceId: "handler-retention-device",
            remoteDeviceName: "Active iPad",
            remoteAccountDisplayName: "active@example.com",
            remoteNebulaId: "nebula-active",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let approvalTask = Task { @MainActor in
            await center.requestApproval(activeDescriptor)
        }
        while center.currentNotice?.id != activeDescriptor.id {
            await Task.yield()
        }
        center.approveCurrentNotice()
        let activeDecision = await approvalTask.value
        XCTAssertEqual(activeDecision, .approved)

        var activeDisconnectCount = 0
        var incomingDisconnectCount = 0
        center.setDisconnectHandler(for: activeDescriptor.id) {
            activeDisconnectCount += 1
        }
        XCTAssertEqual(center.disconnectHandlerCountForTesting, 1)

        let sameSessionDescriptor = RemoteControlSecurityDescriptor(
            sessionId: activeDescriptor.sessionId,
            transportKind: activeDescriptor.transportKind,
            remoteIPAddress: activeDescriptor.remoteIPAddress,
            remoteDeviceId: activeDescriptor.remoteDeviceId,
            remoteDeviceName: activeDescriptor.remoteDeviceName,
            remoteAccountDisplayName: activeDescriptor.remoteAccountDisplayName,
            remoteNebulaId: activeDescriptor.remoteNebulaId,
            localAccountDisplayName: activeDescriptor.localAccountDisplayName,
            localNebulaId: activeDescriptor.localNebulaId,
            cryptoSuite: activeDescriptor.cryptoSuite
        )
        center.setDisconnectHandler(for: sameSessionDescriptor.id) {
            incomingDisconnectCount += 1
        }

        let sameSessionDecision = await center.requestApproval(sameSessionDescriptor)
        XCTAssertEqual(sameSessionDecision, .approved)
        XCTAssertEqual(center.disconnectHandlerCountForTesting, 1)
        XCTAssertEqual(center.currentNotice?.id, activeDescriptor.id)

        let competingDescriptor = RemoteControlSecurityDescriptor(
            sessionId: "competing-handler-\(UUID().uuidString)",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.20",
            remoteDeviceId: "competing-handler-device",
            remoteDeviceName: "Competing iPad",
            remoteAccountDisplayName: "competing@example.com",
            remoteNebulaId: "nebula-competing",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        center.setDisconnectHandler(for: competingDescriptor.id) {
            incomingDisconnectCount += 1
        }

        let competingDecision = await center.requestApproval(competingDescriptor)
        XCTAssertEqual(competingDecision, .rejected)
        XCTAssertEqual(center.disconnectHandlerCountForTesting, 1)
        XCTAssertEqual(center.currentNotice?.id, activeDescriptor.id)

        center.disconnectCurrentNotice()
        XCTAssertEqual(activeDisconnectCount, 1)
        XCTAssertEqual(incomingDisconnectCount, 0)
        XCTAssertEqual(center.disconnectHandlerCountForTesting, 0)
    }

    @MainActor
    func testActiveNoticeDisconnectsWhenSameSessionSecurityIdentityChanges() async {
        let center = RemoteControlSecurityNoticeCenter()
        let sessionID = "identity-mutation-\(UUID().uuidString)"
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: sessionID,
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "identity-device-1234",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-original",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }
        center.approveCurrentNotice()
        let approvalDecision = await approvalTask.value
        XCTAssertEqual(approvalDecision, .approved)

        var disconnectCount = 0
        center.setDisconnectHandler(for: descriptor.id) {
            disconnectCount += 1
        }
        let changedIdentity = RemoteControlSecurityDescriptor(
            sessionId: sessionID,
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "identity-device-1234",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-mutated",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )

        let decision = await center.requestApproval(changedIdentity)

        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(disconnectCount, 1)
    }

    @MainActor
    func testActiveNoticeRejectsInvalidSameSessionCryptoUpdateInsteadOfReportingApproval() async {
        let center = RemoteControlSecurityNoticeCenter()
        let sessionID = "invalid-suite-update-\(UUID().uuidString)"
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: sessionID,
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.11",
            remoteDeviceId: "suite-device-1234",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }
        center.approveCurrentNotice()
        let approvalDecision = await approvalTask.value
        XCTAssertEqual(approvalDecision, .approved)

        var disconnectCount = 0
        center.setDisconnectHandler(for: descriptor.id) {
            disconnectCount += 1
        }
        let invalidUpdate = RemoteControlSecurityDescriptor(
            sessionId: sessionID,
            transportKind: .webrtc,
            remoteIPAddress: descriptor.remoteIPAddress,
            remoteDeviceId: descriptor.remoteDeviceId,
            remoteDeviceName: descriptor.remoteDeviceName,
            remoteAccountDisplayName: descriptor.remoteAccountDisplayName,
            remoteNebulaId: descriptor.remoteNebulaId,
            localAccountDisplayName: descriptor.localAccountDisplayName,
            localNebulaId: descriptor.localNebulaId,
            cryptoSuite: "X-Wing failed"
        )

        let decision = await center.requestApproval(invalidUpdate)

        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(disconnectCount, 1)
    }

    @MainActor
    func testMissingRequiredNoticeMetadataFailsClosedWithoutShowingApproval() async {
        let center = RemoteControlSecurityNoticeCenter()
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "missing-metadata-\(UUID().uuidString)",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "device-missing-metadata",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: nil,
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )

        let decision = await center.requestApproval(descriptor)

        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(center.currentNotice)
    }

    func testDescriptorRejectsMissingSessionAndBoundsApprovalTimeout() {
        let missingSession = RemoteControlSecurityDescriptor(
            sessionId: "   ",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.10",
            remoteDeviceId: "device-timeout-bounds",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC",
            approvalTimeoutSeconds: .infinity
        )
        let oversizedTimeout = RemoteControlSecurityDescriptor(
            sessionId: "session-timeout-bounds",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.1",
            remoteDeviceId: "device-timeout-bounds",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC",
            approvalTimeoutSeconds: 10_000
        )

        XCTAssertTrue(missingSession.missingRequiredNoticeMetadata.contains("session_id"))
        XCTAssertEqual(missingSession.approvalTimeoutSeconds, 45)
        XCTAssertEqual(oversizedTimeout.approvalTimeoutSeconds, 120)
    }

    func testDescriptorDecodingRejectsOversizedAndControlCharacterFields() throws {
        let descriptor = validRemoteControlSecurityDescriptor()
        let encoded = try JSONEncoder().encode(descriptor)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return XCTFail("Expected descriptor JSON object")
        }

        object["remoteIPAddress"] = String(repeating: "1", count: 257)
        let oversizedData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(RemoteControlSecurityDescriptor.self, from: oversizedData)
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "remoteIPAddress")
        }

        object["remoteIPAddress"] = "192.0.2.1"
        object["remoteAccountDisplayName"] = "remote\u{000A}spoofed@example.com"
        let controlCharacterData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteControlSecurityDescriptor.self,
                from: controlCharacterData
            )
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "remoteAccountDisplayName")
        }
    }

    func testDescriptorDecodingRejectsNonFiniteAndOutOfRangeApprovalTimeout() throws {
        let descriptor = validRemoteControlSecurityDescriptor()
        let jsonData = try JSONEncoder().encode(descriptor)
        guard var jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return XCTFail("Expected descriptor JSON object")
        }
        jsonObject["approvalTimeoutSeconds"] = 121
        let oversizedTimeoutData = try JSONSerialization.data(withJSONObject: jsonObject)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteControlSecurityDescriptor.self,
                from: oversizedTimeoutData
            )
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "approvalTimeoutSeconds")
        }

        let propertyListData = try PropertyListEncoder().encode(descriptor)
        guard var propertyList = try PropertyListSerialization.propertyList(
            from: propertyListData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return XCTFail("Expected descriptor property-list object")
        }
        propertyList["approvalTimeoutSeconds"] = Double.nan
        let nonFiniteTimeoutData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(
            try PropertyListDecoder().decode(
                RemoteControlSecurityDescriptor.self,
                from: nonFiniteTimeoutData
            )
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, received \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "approvalTimeoutSeconds")
        }
    }

    @MainActor
    func testCancellingApprovalFailsClosedAndClearsNotice() async {
        let center = RemoteControlSecurityNoticeCenter()
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "cancel-approval-\(UUID().uuidString)",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.44",
            remoteDeviceId: "device-cancel-approval",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        let approvalTask = Task { @MainActor in
            await center.requestApproval(descriptor)
        }
        while center.currentNotice?.id != descriptor.id {
            await Task.yield()
        }

        approvalTask.cancel()
        let decision = await approvalTask.value

        XCTAssertEqual(decision, .disconnected)
        XCTAssertNil(center.currentNotice)
    }

    @MainActor
    func testAlreadyCancelledApprovalReleasesPreRegisteredDisconnectHandler() async {
        let center = RemoteControlSecurityNoticeCenter()
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "pre-cancel-approval-\(UUID().uuidString)",
            transportKind: .webrtc,
            remoteIPAddress: "203.0.113.45",
            remoteDeviceId: "device-pre-cancel-approval",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
        var disconnectCount = 0
        center.setDisconnectHandler(for: descriptor.id) {
            disconnectCount += 1
        }
        let approvalTask = Task { @MainActor in
            await Task.yield()
            return await center.requestApproval(descriptor)
        }
        approvalTask.cancel()

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .disconnected)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(center.disconnectHandlerCountForTesting, 0)
        XCTAssertEqual(disconnectCount, 0)
    }

    func testApprovedNoticeKeepsDisconnectHandlerUntilDisconnect() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift")

        XCTAssertTrue(
            source.contains("if decision != .approved") &&
                source.contains("cleanupNoticeState(id: id)"),
            "Approving a notice must not remove its disconnect handler; the active banner needs it for the Disconnect button."
        )
        XCTAssertTrue(
            source.contains("let handler = notice.phase == .active ? disconnectHandlers[notice.id] : nil") &&
                source.contains("handler?()"),
            "Active disconnect should capture the handler before notice cleanup and invoke it after state teardown."
        )
        XCTAssertTrue(
            source.contains("notice.phase == .active") &&
                source.contains("appendConcurrentRequestRejectedEvidence") &&
                source.contains("return .rejected"),
            "A second inbound remote-control request must not replace an already-active safety banner."
        )
        XCTAssertTrue(
            source.contains("missingRequiredNoticeMetadata") &&
                source.contains("missing_required_notice_metadata") &&
                source.contains("return .rejected"),
            "Inbound remote-control notice approval must fail closed before UI presentation when required identity metadata is missing."
        )
        XCTAssertTrue(
            source.contains("maskedStatusValue(descriptor.remoteAccountDisplayName)") &&
                source.contains("maskedStatusValue(descriptor.remoteNebulaId)"),
            "Notice evidence should preserve field presence without writing raw account or Nebula identifiers."
        )
        XCTAssertTrue(
            source.contains("remoteDeviceId=\\(Self.statusValue(descriptor.remoteDeviceId))"),
            "Active P2P notice evidence must retain the authenticated remote device id so route liveness proof can stay target-bound."
        )
        let manager = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        XCTAssertTrue(
            manager.contains("mac remote established peer=\\(peer.id) remoteDeviceId=\\(remoteDeviceId) suite=\\(keys.negotiatedSuite.rawValue)"),
            "X-Wing establishment evidence must bind the transport peer to the authenticated remote device id."
        )
        XCTAssertTrue(
            manager.contains("DiagnosticFieldSanitizer.fieldValue(") &&
                manager.contains("peer.handshakePeer?.deviceId"),
            "The target-bound establishment marker must pass its device id through the diagnostic field sanitizer."
        )
    }

    func testDeviceDiscoveryInboundPairingIdentityFeedsP2PNoticeMetadata() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")

        XCTAssertTrue(
            source.contains("func recordRemoteControlSecurityIdentity(\n            from payload: AppMessage.PairingIdentityExchangePayload") &&
                source.contains("RemoteControlSecurityPeerIdentityStore.record("),
            "DeviceDiscoveryManager inbound control sessions must record authenticated pairing identity metadata for P2P notice approval."
        )
        XCTAssertTrue(
            source.contains("recordRemoteControlSecurityIdentity(from: payload)") &&
                source.contains("guard decision != PairingTrustApprovalService.Decision.reject else"),
            "Remote identity must be recorded only after the pairing/trust decision has not rejected the payload."
        )
        XCTAssertTrue(
            source.contains("payload.accountDisplayName") &&
                source.contains("payload.nebulaId") &&
                source.contains("endpointHostOrIP") &&
                source.contains("endpointDescription"),
            "P2P notice identity lookup must include the peer account, NebulaID, and endpoint aliases used by the remote-control socket."
        )
        XCTAssertTrue(
            source.contains("let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()") &&
                source.contains("accountDisplayName: localIdentity?.accountDisplayName") &&
                source.contains("nebulaId: localIdentity?.nebulaId"),
            "Pairing identity replies must carry local account and Nebula metadata instead of leaving the peer to fail notice validation."
        )
    }

    func testP2PClipboardSyncCannotBeEnabledBeforeApproval() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")

        XCTAssertTrue(
            source.contains("disableClipboardSyncIfActive(for: peer.id)") &&
            source.contains("remoteControlClipboardSyncBlocked session=\\(peer.id) transport=p2p reason=awaiting_security_notice"),
            "configureClipboardSync must fail closed before the P2P security notice is approved."
        )
        XCTAssertTrue(
            source.contains("remoteControlClipboardSendBlocked session=\\(peer.id) transport=p2p reason=awaiting_security_notice"),
            "local pasteboard forwarding must also be blocked if a pre-approval stream configuration enabled clipboard sync earlier."
        )
        XCTAssertTrue(
            source.contains("var pendingRequestedStreamConfiguration: RemoteDesktopStreamConfiguration?") &&
                source.contains("peer.pendingRequestedStreamConfiguration = config") &&
                source.contains("await applyViewerStreamConfiguration(pendingConfiguration, for: peer)") &&
                source.contains("remoteControlStreamConfigDeferred session=\\(peer.id) transport=p2p reason=awaiting_security_notice"),
            "P2P streamConfiguration may be staged before approval, but must not be applied until the security notice is approved."
        )
    }

    func testWebRTCClipboardSyncCannotBeSentBeforeApproval() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        XCTAssertTrue(
            source.contains("guard webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else") &&
            source.contains("stopWebRTCClipboardSyncIfNeeded(for: sessionID)") &&
            source.contains("remoteControlClipboardSendBlocked session=\\(sessionID) transport=webrtc reason=awaiting_security_notice"),
            "WebRTC local pasteboard forwarding must fail closed even if a stale clipboard callback fires before notice approval."
        )
        XCTAssertTrue(
            source.contains("webrtcPendingRemoteStreamConfigurationBySessionId") &&
                source.contains("self.webrtcPendingRemoteStreamConfigurationBySessionId[sessionID] = config") &&
                source.contains("await applyApprovedWebRTCStreamConfiguration(") &&
                source.contains("remoteControlStreamConfigDeferred session=\\(sessionID) transport=webrtc reason=awaiting_security_notice"),
            "WebRTC streamConfiguration may be staged before approval, but must not be applied or acknowledged until the security notice is approved."
        )
    }

    func testSecurityNoticePanelDoesNotFallbackToLocalIdentity() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift"
        )

        XCTAssertTrue(source.contains("masked(descriptor.remoteAccountDisplayName)"))
        XCTAssertTrue(source.contains("masked(descriptor.remoteNebulaId)"))
        XCTAssertFalse(
            source.contains("descriptor.remoteAccountDisplayName ?? descriptor.localAccountDisplayName"),
            "The user-visible account row must not disguise missing remote identity with the local account."
        )
        XCTAssertFalse(
            source.contains("descriptor.remoteNebulaId ?? descriptor.localNebulaId"),
            "The user-visible NebulaID row must not disguise missing remote identity with the local NebulaID."
        )
    }

    func testSecurityNoticePanelEmitsVerifiableTopCenterEvidence() throws {
        let panelSource = try repositorySource(
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift"
        )
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let probeScript = try repositorySource("Scripts/run_remote_control_notice_panel_probe.sh")
        let noticeSource = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift")
        let checkerSource = try repositorySource("rust/crates/skybridge-cli/src/remote_control_notice_check.rs")

        XCTAssertTrue(panelSource.contains("recordPanelPresentedEvidence("))
        XCTAssertTrue(panelSource.contains("topCentered"))
        XCTAssertTrue(panelSource.contains("buttons: buttons(for: notice.phase, isCollapsed: isCollapsed)"))
        XCTAssertTrue(panelSource.contains("remoteControlSecurityNoticeCollapseButton"))
        XCTAssertTrue(panelSource.contains("remoteControlSecurityNoticeApproveButton"))
        XCTAssertTrue(panelSource.contains("remoteControlSecurityNoticeDisconnectButton"))
        XCTAssertTrue(appSource.contains("RemoteControlNoticePanelProbeHarness"))
        XCTAssertTrue(appSource.contains("SKYBRIDGE_SMOKE_PANEL_PROBE"))
        XCTAssertTrue(appSource.contains("RemoteControlSecurityNoticePanelController.shared.start()"))
        XCTAssertTrue(probeScript.contains("SKYBRIDGE_SMOKE_ROLE=mac-panel-probe"))
        XCTAssertTrue(noticeSource.contains("remoteControlNoticePanelPresented"))
        XCTAssertTrue(noticeSource.contains("remoteControlNoticePanelHidden"))
        XCTAssertTrue(checkerSource.contains("panel_pending_top_center"))
        XCTAssertTrue(checkerSource.contains("panel_active_buttons"))
        XCTAssertTrue(checkerSource.contains("panel_visible_until_disconnect"))
    }

    func testSecurityNoticePanelIsCompiledIntoPackagedMacAppTarget() throws {
        let xcodeProjectSource = try repositorySource("SkyBridgeWidgets.xcodeproj/project.pbxproj")
        let packageSource = try repositorySource("Package.swift")
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let panelSource = try repositorySource(
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift"
        )

        XCTAssertTrue(
            xcodeProjectSource.contains("SkyBridgeUI in Frameworks") &&
                packageSource.contains("path: \"Sources/SkyBridgeUI\"") &&
                appSource.contains("import SkyBridgeUI") &&
                panelSource.contains("public final class RemoteControlSecurityNoticePanelController"),
            "The packaged Mac app must consume the single reusable SkyBridgeUI panel implementation."
        )
        XCTAssertFalse(
            xcodeProjectSource.contains("RemoteControlSecurityNoticePanelController.swift in Sources"),
            "The packaged app must not compile a second target-local copy of the reusable panel."
        )
    }

    func testSecurityNoticeUsesDedicatedLocalizedAppName() throws {
        let noticeSource = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift")
        let englishStrings = try repositorySource("Sources/SkyBridgeCore/Resources/en.lproj/Localizable.strings")
        let chineseStrings = try repositorySource("Sources/SkyBridgeCore/Resources/zh-Hans.lproj/Localizable.strings")
        let japaneseStrings = try repositorySource("Sources/SkyBridgeCore/Resources/ja.lproj/Localizable.strings")

        XCTAssertTrue(noticeSource.contains("remoteControl.securityNotice.appName"))
        XCTAssertFalse(
            noticeSource.contains("localizedString(\"app.name\")"),
            "The remote-control notice must not inherit broader app branding such as Pro suffixes."
        )
        XCTAssertTrue(englishStrings.contains("\"remoteControl.securityNotice.appName\" = \"SkyBridge Compass\";"))
        XCTAssertTrue(chineseStrings.contains("\"remoteControl.securityNotice.appName\" = \"云桥司南\";"))
        XCTAssertTrue(japaneseStrings.contains("\"remoteControl.securityNotice.appName\" = \"SkyBridge Compass\";"))
    }

    func testIOSPairingIdentityExchangeCarriesAccountAndNebulaMetadata() throws {
        let payloadSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage+PairingIdentityPayloads.swift"
        )
        let heartbeatSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage+HeartbeatPayload.swift"
        )
        let webrtcSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let p2pSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(payloadSource.contains("public let accountDisplayName: String?"))
        XCTAssertTrue(payloadSource.contains("public let nebulaId: String?"))
        XCTAssertTrue(heartbeatSource.contains("public let accountDisplayName: String?"))
        XCTAssertTrue(heartbeatSource.contains("public let nebulaId: String?"))
        XCTAssertTrue(webrtcSource.contains("AuthenticationManager.instance.remoteControlSecurityIdentityMetadata"))
        XCTAssertTrue(webrtcSource.contains("accountDisplayName: identity.accountDisplayName"))
        XCTAssertTrue(webrtcSource.contains("nebulaId: identity.nebulaId"))
        XCTAssertTrue(p2pSource.contains("AuthenticationManager.instance.remoteControlSecurityIdentityMetadata"))
        XCTAssertTrue(p2pSource.contains("accountDisplayName: identity.accountDisplayName"))
        XCTAssertTrue(p2pSource.contains("nebulaId: identity.nebulaId"))
    }

    func testIOSNebulaBrowserAuthHydratesNoticeNebulaIdentitySynchronously() throws {
        let authSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
        )
        let macAuthSource = try repositorySource("Sources/SkyBridgeCompassApp/AuthenticationViewModel.swift")
        let oauthSource = try repositorySource("Sources/SkyBridgeCore/Services/NebulaPublicClientOAuth.swift")
        let iOSOAuthSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Auth/NebulaPublicClientOAuth.swift"
        )

        XCTAssertTrue(oauthSource.contains("public let nebulaId: String?"))
        XCTAssertTrue(oauthSource.contains("case nebulaId = \"nebula_id\""))
        XCTAssertTrue(oauthSource.contains("case nebulaIdCamel = \"nebulaId\""))
        XCTAssertTrue(iOSOAuthSource.contains("public let nebulaId: String?"))
        XCTAssertTrue(iOSOAuthSource.contains("case nebulaId = \"nebula_id\""))
        XCTAssertTrue(iOSOAuthSource.contains("case nebulaIdCamel = \"nebulaId\""))
        XCTAssertTrue(authSource.contains("internal static func resolvedNebulaId(from userInfo: NebulaPublicClientOAuth.UserInfo) -> String?"))
        XCTAssertTrue(authSource.contains("let nebulaId = Self.resolvedNebulaId(from: userInfo)"))
        XCTAssertTrue(authSource.contains("Self.isCanonicalNebulaId(userInfo.subject)"))
        XCTAssertTrue(authSource.contains("nebulaId: nebulaId"))
        XCTAssertTrue(macAuthSource.contains("internal static func resolvedNebulaId(from userInfo: NebulaPublicClientOAuth.UserInfo) -> String?"))
        XCTAssertTrue(macAuthSource.contains("let nebulaId = Self.resolvedNebulaId(from: userInfo)"))
        XCTAssertTrue(macAuthSource.contains("NebulaIdentityContract.isCanonicalNebulaId(userInfo.subject)"))
        XCTAssertTrue(macAuthSource.contains("nebulaId: nebulaId"))
    }

    func testP2PRemoteControlNoticeWaitsForFreshIdentityMetadataBeforePrompt() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")

        XCTAssertTrue(source.contains("waitForRemoteControlSecurityIdentityMetadata("))
        XCTAssertTrue(source.contains("RemoteControlSecurityPeerIdentityStore.identity(forAliases: aliases)"))
        XCTAssertTrue(source.contains("Self.noticeMetadataPresent(identity?.accountDisplayName)"))
        XCTAssertTrue(source.contains("Self.noticeMetadataPresent(identity?.nebulaId)"))
        XCTAssertTrue(source.contains("try await Task.sleep(for: .milliseconds(100))"))
        XCTAssertTrue(source.contains("} catch {\n                return nil"))
        XCTAssertFalse(source.contains("try? await Task.sleep(for: .milliseconds(100))"))
        XCTAssertTrue(source.contains("let remoteIdentity = await waitForRemoteControlSecurityIdentityMetadata("))
        XCTAssertTrue(source.contains("recordRemoteControlSecurityIdentity("))
        XCTAssertTrue(source.contains("from: \"streamConfiguration\""))
        XCTAssertTrue(source.contains("remoteControlSecurityIdentity: RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()"))
    }

    func testIOSViewerStreamConfigurationProvidesSecurityIdentityMetadata() throws {
        let managerSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let factorySource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationFactory.swift"
        )
        let payloadSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopWirePayloads.swift"
        )

        XCTAssertTrue(managerSource.contains("AuthenticationManager.instance.remoteControlSecurityIdentityMetadata"))
        XCTAssertTrue(managerSource.contains("RemoteDesktopSecurityIdentityPayload("))
        XCTAssertTrue(managerSource.contains("securityIdentity: securityIdentity"))
        XCTAssertTrue(managerSource.contains("validateViewerStreamConfigurationNoticeIdentity("))
        XCTAssertTrue(managerSource.contains("missing_viewer_notice_identity"))
        XCTAssertTrue(factorySource.contains("let securityIdentity: RemoteDesktopSecurityIdentityPayload?"))
        XCTAssertTrue(factorySource.contains("remoteControlSecurityIdentity: input.securityIdentity?.isEmpty == true ? nil : input.securityIdentity"))
        XCTAssertTrue(payloadSource.contains("struct RemoteDesktopSecurityIdentityPayload"))
        XCTAssertTrue(payloadSource.contains("let remoteControlSecurityIdentity: RemoteDesktopSecurityIdentityPayload?"))
    }

    func testLocalLanSmokeHostUsesExplicitNoticeIdentityEnvOnly() throws {
        let source = try repositorySource("Sources/LocalLanInteropHost/main.swift")

        XCTAssertTrue(source.contains("configureRemoteControlNoticeIdentity(protocolDeviceId: protocolDeviceId)"))
        XCTAssertTrue(source.contains("SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME"))
        XCTAssertTrue(source.contains("SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID"))
        XCTAssertTrue(source.contains("RemoteControlSecurityNoticeCenter.shared.setLocalIdentityProvider"))
        XCTAssertTrue(
            source.contains("reason=missing-smoke-identity-env"),
            "Notice smoke should fail closed when identity metadata was requested but not explicitly supplied."
        )
    }

    func testRealDeviceP2PNoticeSmokeProvidesBothMacAndIPadIdentityMetadata() throws {
        let script = try repositorySource("Scripts/run_real_device_p2p_remote_smoke.sh")
        let rustPlan = try repositorySource("rust/crates/skybridge-cli/src/smoke_suite/plan/real_device.rs")

        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME is required"))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID is required"))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME=\"${SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME:-Mac Smoke Operator}\""))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID=\"${SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID:-mac-smoke-nebula}\""))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME=\"${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-iPad Smoke Operator}\""))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID=\"${SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID:-ipad-smoke-nebula}\""))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=\"${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-1}\""))
        XCTAssertFalse(script.contains("SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=\"${SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE:-1}\""))
        XCTAssertFalse(script.contains("--env \"SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE="))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME=\"${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-}\""))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID=\"${SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID:-}\""))
        XCTAssertTrue(script.contains("validate_ios_launch_notice_identity_env"))
        XCTAssertTrue(script.contains("remoteControlNoticeRejected .*missing_required_notice_metadata"))
        XCTAssertTrue(
            script.contains(
                "remoteControlNoticePanelPresented .*transport=p2p .*phase=awaitingApproval"
            )
        )
        XCTAssertTrue(rustPlan.contains("\"SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME\""))
        XCTAssertTrue(rustPlan.contains("\"iPad Smoke Operator\""))
        XCTAssertTrue(rustPlan.contains("\"SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID\""))
        XCTAssertTrue(rustPlan.contains("\"ipad-smoke-nebula\""))
    }

    func testRealDeviceP2POnlineMacClientLaunchesThroughAppBundleForTCC() throws {
        let script = try repositorySource("Scripts/run_real_device_p2p_remote_smoke.sh")

        XCTAssertTrue(script.contains("MAC_ONLINE_APP_BUNDLE="))
        XCTAssertTrue(script.contains("MAC_ONLINE_PACKAGED_APP_BUNDLE="))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_MAC_ONLINE_APP_BUNDLE"))
        XCTAssertTrue(script.contains("SKYBRIDGE_SMOKE_MAC_ONLINE_ALLOW_DEBUG_BUILD"))
        XCTAssertTrue(script.contains("xcrun stapler validate \"$MAC_ONLINE_APP_BUNDLE\""))
        XCTAssertTrue(script.contains("spctl --assess --type execute \"$MAC_ONLINE_APP_BUNDLE\""))
        XCTAssertTrue(script.contains("register_macos_online_ipad_app_bundle"))
        XCTAssertTrue(script.contains("find_macos_online_ipad_client_pid"))
        XCTAssertTrue(script.contains("open_macos_online_ipad_app_bundle"))
        XCTAssertTrue(script.contains("start_macos_online_ipad_client"))
        XCTAssertTrue(script.contains("/usr/bin/open \\"))
        XCTAssertTrue(script.contains("    -n \\"))
        XCTAssertTrue(script.contains("--stdout \"$MAC_ONLINE_LAUNCH_STDOUT\""))
        XCTAssertTrue(script.contains("--stderr \"$MAC_ONLINE_LAUNCH_STDERR\""))
        XCTAssertTrue(script.contains("2>>\"$MAC_ONLINE_LAUNCH_OPEN_STDERR\""))
        XCTAssertTrue(script.contains("sync_mac_online_launch_stdio"))
        XCTAssertTrue(script.contains("--env \"SKYBRIDGE_SMOKE_ROLE=mac-online-ipad-client\""))
        XCTAssertTrue(script.contains("\"$MAC_ONLINE_APP_BUNDLE\""))
        XCTAssertTrue(script.contains("MAC_ONLINE_PID=\"$(find_macos_online_ipad_client_pid)\""))
        XCTAssertTrue(script.contains("launch method=open-app-bundle pid=%s role=mac-online-ipad-client"))
        XCTAssertTrue(script.contains("launch requested role=mac-online-ipad-client"))
        XCTAssertTrue(script.contains("wait_for_mac_online_pattern 'boot .*role=mac-online-ipad-client .*source=app'"))
        XCTAssertTrue(script.contains("phase=wait-pattern reason=process-exited"))
        XCTAssertTrue(script.contains("phase=wait-pattern reason=timeout"))
        XCTAssertFalse(script.contains("boot role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility"))
        XCTAssertFalse(
            script.contains("\"$MAC_ONLINE_APP_BIN\" >\"$MAC_ONLINE_STDOUT\" 2>&1 &"),
            "The packaged Mac UI client smoke must launch the .app bundle so macOS TCC reads the bundle Info.plist usage descriptions."
        )
    }

    func testLocalLanSmokeHostRetainsCoordinatorForInboundRemoteControlHandoff() throws {
        let source = try repositorySource("Sources/LocalLanInteropHost/main.swift")

        XCTAssertTrue(source.contains("private enum LocalLanInteropHostLifetime"))
        XCTAssertTrue(source.contains("static var coordinator: LocalLanInteropHostCoordinator?"))
        XCTAssertTrue(
            source.contains("LocalLanInteropHostLifetime.coordinator = coordinator"),
            "The CLI host must keep the coordinator alive after startup so weak listener callbacks can hand off real P2P remote-control connections."
        )
        XCTAssertTrue(source.contains("let application = NSApplication.shared"))
        XCTAssertTrue(source.contains("if application.activationPolicy() != .regular"))
        XCTAssertTrue(source.contains("guard application.activationPolicy() == .regular else"))
        XCTAssertFalse(source.contains("guard application.setActivationPolicy(.regular) else"))
        XCTAssertTrue(source.contains("Task { @MainActor in"))
        XCTAssertTrue(source.contains("application.run()"))
        XCTAssertTrue(source.contains("static var remoteControlSecurityNoticePanelController: RemoteControlSecurityNoticePanelController?"))
        XCTAssertTrue(source.contains("let remoteControlSecurityNoticePanelController = RemoteControlSecurityNoticePanelController.shared"))
        XCTAssertTrue(source.contains("remoteControlSecurityNoticePanelController.start()"))
        XCTAssertTrue(
            source.contains(
                "LocalLanInteropHostLifetime.remoteControlSecurityNoticePanelController =\n                remoteControlSecurityNoticePanelController"
            ),
            "The CLI host must retain the reusable remote-control notice presenter for its listener lifetime."
        )
        XCTAssertFalse(
            source.contains("await MainActor.run {\n            NSApplication.shared.run()"),
            "The AppKit run loop must not be started inside a MainActor job because that starves inbound remote-control handoff tasks."
        )
    }

    func testLocalWebRTCSmokeHoldsMacHostLongEnoughForNoticeLifecycle() throws {
        let source = try repositorySource("Scripts/run_local_webrtc_smoke.sh")

        XCTAssertTrue(source.contains("SMOKE_HOLD_AFTER_SUCCESS_SECONDS"))
        XCTAssertTrue(source.contains("SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE"))
        XCTAssertTrue(
            source.contains("SMOKE_HOLD_AFTER_SUCCESS_SECONDS=5"),
            "The WebRTC notice smoke should not let the macOS host close the data channel before iOS records success."
        )
        XCTAssertTrue(source.contains("SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME"))
        XCTAssertTrue(source.contains("SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID"))
        XCTAssertTrue(source.contains("remoteControlNoticeDisconnected .*transport=webrtc"))
    }

    func testReleaseReadinessConsumesRemoteControlNoticeArtifacts() throws {
        let readiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        let workflow = try repositorySource(".github/workflows/macos-release-readiness.yml")
        let fastfile = try repositorySource("fastlane/Fastfile")

        XCTAssertTrue(readiness.contains("P2P_NOTICE_ARTIFACT_DIR"))
        XCTAssertTrue(readiness.contains("WEBRTC_NOTICE_ARTIFACT_DIR"))
        XCTAssertTrue(readiness.contains("NOTICE_PANEL_ARTIFACT_DIR"))
        XCTAssertTrue(readiness.contains("run_cli_remote_control_notice_gates"))
        XCTAssertTrue(readiness.contains("check remote-control-notice"))
        XCTAssertTrue(readiness.contains("--transport p2p"))
        XCTAssertTrue(readiness.contains("--transport webrtc"))
        XCTAssertTrue(
            readiness.contains("--transport p2p \\\n    --require-panel"),
            "Physical P2P release artifacts must include LocalLanInteropHost's explicit AppKit panel evidence."
        )
        XCTAssertTrue(readiness.contains("--transport webrtc \\\n    --require-panel"))
        XCTAssertTrue(readiness.contains("P2P and WebRTC remote-control security notice artifacts pass lifecycle and metadata gates"))
        XCTAssertTrue(workflow.contains("P2P_NOTICE_ARTIFACT_NAME"))
        XCTAssertTrue(workflow.contains("WEBRTC_NOTICE_ARTIFACT_NAME"))
        XCTAssertTrue(workflow.contains("NOTICE_PANEL_ARTIFACT_NAME"))
        XCTAssertTrue(workflow.contains("--p2p-notice-artifact-dir \"Artifacts/release-gate/p2p-notice\""))
        XCTAssertTrue(workflow.contains("--webrtc-notice-artifact-dir \"Artifacts/release-gate/webrtc-notice\""))
        XCTAssertTrue(workflow.contains("--notice-panel-artifact-dir \"Artifacts/release-gate/notice-panel\""))
        XCTAssertTrue(fastfile.contains("SKYBRIDGE_RELEASE_GATE_P2P_NOTICE_ARTIFACT_DIR"))
        XCTAssertTrue(fastfile.contains("SKYBRIDGE_RELEASE_GATE_WEBRTC_NOTICE_ARTIFACT_DIR"))
        XCTAssertTrue(fastfile.contains("SKYBRIDGE_RELEASE_GATE_NOTICE_PANEL_ARTIFACT_DIR"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func streamConfigurationData(
        replacingSecurityIdentityWith identity: [String: Any]
    ) throws -> Data {
        let configuration = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["hevc"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaSessionId: "security-identity-decode-test",
            performanceValidationMode: "extreme",
            mediaFallbackPolicy: "fail-fast",
            remoteControlSecurityIdentity: RemoteControlSecurityIdentity(
                accountDisplayName: "viewer@example.com",
                nebulaId: "nebula-viewer",
                deviceId: "viewer-device",
                deviceName: "Viewer iPad"
            )
        )
        let encoded = try JSONEncoder().encode(configuration)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        object["remoteControlSecurityIdentity"] = identity
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validRemoteControlSecurityDescriptor() -> RemoteControlSecurityDescriptor {
        RemoteControlSecurityDescriptor(
            sessionId: "descriptor-decode-test",
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.1",
            remoteDeviceId: "descriptor-device",
            remoteDeviceName: "Remote iPad",
            remoteAccountDisplayName: "remote@example.com",
            remoteNebulaId: "nebula-remote",
            localAccountDisplayName: "mac@example.com",
            localNebulaId: "nebula-mac",
            cryptoSuite: "X-Wing PQC"
        )
    }
}

private final class RemoteControlIdentityTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var current: Date {
        lock.withLock { value }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(seconds)
        }
    }
}
