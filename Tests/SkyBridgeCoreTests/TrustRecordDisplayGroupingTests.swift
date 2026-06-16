import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TrustRecordDisplayGroupingTests: XCTestCase {
    func testDisplayGroupsCollapseDuplicateAuthoritiesForSamePhysicalDevice() {
        let fingerprint = String(repeating: "a", count: 64)
        let canonical = makeRecord(
            deviceId: "id:ipad-stable",
            protocolFingerprint: fingerprint,
            deviceName: "Ziang的iPad",
            currentDeviceId: "id:ipad-stable",
            knownDeviceIds: ["bonjour:ziangdeipad@local."],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon"
            ]
        )
        let duplicate = makeRecord(
            deviceId: "id:ipad-stable-duplicate",
            protocolFingerprint: fingerprint,
            deviceName: "Ziang的iPad",
            currentDeviceId: "id:ipad-stable",
            knownDeviceIds: ["peer:fe80::1"],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad Pro 11-inch (M4)",
                "chip=M4"
            ],
            updatedAt: canonical.updatedAt.addingTimeInterval(30)
        )

        let groups = TrustSyncService.buildDisplayGroups(from: [canonical, duplicate])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].relatedRecords.count, 2)
        XCTAssertEqual(groups[0].displayRecord.deviceName, "Ziang的iPad")
        let keyedCapabilities: [(String, String)] = groups[0].displayRecord.capabilities.compactMap { capability in
            let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        let caps = Dictionary(uniqueKeysWithValues: keyedCapabilities)
        XCTAssertEqual(caps["modelName"], "iPad Pro 11-inch (M4)")
        XCTAssertEqual(caps["chip"], "M4")
    }

    func testApplePeerDeviceMetadataNormalizerResolvesKnownIdentifiers() {
        let normalized = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: "iPad16,3",
            chip: "Apple Silicon",
            platform: "ipados",
            osVersion: "26.4"
        )

        XCTAssertEqual(normalized.modelName, "iPad Pro 11-inch (M4)")
        XCTAssertEqual(normalized.chip, "M4")
        XCTAssertEqual(normalized.platform, "iPadOS")
        XCTAssertEqual(normalized.osVersion, "26.4")
    }

    func testApplePeerDeviceMetadataNormalizerMergedPresentationPrefersLiveOSVersion() {
        let fallback = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: "iPad16,3",
            chip: "Apple Silicon",
            platform: "iPadOS",
            osVersion: "26.4"
        )
        let live = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: "iPad Pro 11-inch (M4)",
            chip: nil,
            platform: "ipados",
            osVersion: "26.4.1"
        )

        let merged = ApplePeerDeviceMetadataNormalizer.mergedPresentation(
            preferred: live,
            fallback: fallback
        )

        XCTAssertEqual(merged.modelName, "iPad Pro 11-inch (M4)")
        XCTAssertEqual(merged.chip, "M4")
        XCTAssertEqual(merged.platform, "iPadOS")
        XCTAssertEqual(merged.osVersion, "26.4.1")
    }

    func testDisplayGroupsCollapseLegacyFingerprintDuplicatesAndPreferNewerOSVersion() {
        let legacyFingerprint = String(repeating: "c", count: 64)
        let older = makeRecord(
            deviceId: "legacy-ipad-a",
            protocolFingerprint: nil,
            pubKeyFingerprint: legacyFingerprint,
            deviceName: "Office iPad",
            currentDeviceId: "legacy-ipad-a",
            knownDeviceIds: ["peer:fe80::1"],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon"
            ]
        )
        let newer = makeRecord(
            deviceId: "legacy-ipad-b",
            protocolFingerprint: nil,
            pubKeyFingerprint: legacyFingerprint,
            deviceName: "Office iPad",
            currentDeviceId: "legacy-ipad-b",
            knownDeviceIds: ["peer:fe80::2"],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.5",
                "modelName=iPad Pro 11-inch (M4)",
                "chip=M4"
            ],
            updatedAt: older.updatedAt.addingTimeInterval(10)
        )

        let groups = TrustSyncService.buildDisplayGroups(from: [older, newer])

        XCTAssertEqual(groups.count, 1)
        let keyedCaps: [(String, String)] = groups[0].displayRecord.capabilities.compactMap { capability in
            let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        let caps = Dictionary(uniqueKeysWithValues: keyedCaps)
        XCTAssertEqual(caps["osVersion"], "26.5")
        XCTAssertEqual(caps["modelName"], "iPad Pro 11-inch (M4)")
        XCTAssertEqual(caps["chip"], "M4")
    }

    func testHandshakeErrorLocalizerMapsRawCryptoKitErrorThree() {
        let error = NSError(
            domain: "CryptoKit.CryptoKitError",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "密码学处理失联：未能完成操作。错误3"]
        )

        XCTAssertEqual(
            HandshakeErrorLocalizer.localizedMessage(for: error),
            "安全验证失败：解密认证失败（可能是两端 PQC 实现或协商套件不一致，或构建未启用 Apple PQC）"
        )
        XCTAssertEqual(
            HandshakeErrorLocalizer.suggestedFix(for: error),
            "请确认两台设备应用版本一致，并检查 Apple PQC 编译标记、runtime self-test 与协商套件证据；不要仅凭系统或 Xcode 版本判断已启用。"
        )
    }

    func testPresentationDisplayGroupsSuppressWeakLegacyPlaceholderWhenStrongerAliasExists() {
        let authoritativeFingerprint = String(repeating: "d", count: 64)
        let strongAlias = makeRecord(
            deviceId: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            protocolFingerprint: authoritativeFingerprint,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            knownDeviceIds: [
                "07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "bonjour:iPad@local.",
                "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
            ],
            capabilities: [
                "trusted",
                "alias=true",
                "declaredDeviceId=07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon"
            ]
        )
        let canonical = makeRecord(
            deviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            protocolFingerprint: nil,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            knownDeviceIds: [
                "07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "bonjour:iPad@local.",
                "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
            ],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon"
            ]
        )
        let stalePlaceholder = makeRecord(
            deviceId: "29094B83-3D32-4027-9B70-B1C924CB7CEF",
            protocolFingerprint: nil,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "",
            knownDeviceIds: [],
            capabilities: [
                "trusted",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon"
            ]
        )

        let groups = TrustSyncService.buildPresentationDisplayGroups(
            from: [strongAlias, canonical, stalePlaceholder]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayRecord.deviceName, "iPad")
    }

    func testPresentationDisplayGroupsSuppressRealWorldIpadPlaceholderRecord() {
        let authoritativeFingerprint = "cbae6ed24e9444945477d422e09c65b0f5534a2b3ac6704b49af63b8d1c5b351"
        let strongAlias = makeRecord(
            deviceId: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            protocolFingerprint: authoritativeFingerprint,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            knownDeviceIds: [
                "07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "07cb9a6e-7492-4680-9dd7-f37dc8568891",
                "bonjour:iPad@local.",
                "bonjour:ipad@local.",
                "host:07cb9a6e-7492-4680-9dd7-f37dc8568891",
                "host:bonjour:ipad@local",
                "host:fe80::81a:9048:8e1f:1b46",
                "host:fe80::81a:9048:8e1f:1b46%en0",
                "host:fe80::fc:b560:8413:23",
                "host:fe80::fc:b560:8413:23%en0",
                "host:id:07cb9a6e-7492-4680-9dd7-f37dc8568891",
                "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "id:07cb9a6e-7492-4680-9dd7-f37dc8568891"
            ],
            capabilities: [
                "clipboard_sync",
                "file_transfer",
                "pqc_bootstrap",
                "remote_desktop",
                "trusted",
                "alias=true",
                "chip=Apple Silicon",
                "declaredDeviceId=07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "modelName=iPad16,3",
                "osVersion=26.4",
                "peerEndpoint=id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "platform=iPadOS"
            ]
        )
        let canonical = makeRecord(
            deviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            protocolFingerprint: nil,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            knownDeviceIds: [
                "07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "bonjour:iPad@local.",
                "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
            ],
            capabilities: [
                "clipboard_sync",
                "file_transfer",
                "pqc_bootstrap",
                "remote_desktop",
                "trusted",
                "chip=Apple Silicon",
                "modelName=iPad16,3",
                "osVersion=26.4",
                "peerEndpoint=bonjour:iPad@local.",
                "platform=iPadOS"
            ],
            updatedAt: Date().addingTimeInterval(-10)
        )
        let bonjourAlias = makeRecord(
            deviceId: "bonjour:iPad@local.",
            protocolFingerprint: nil,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            knownDeviceIds: [
                "07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "bonjour:iPad@local.",
                "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
            ],
            capabilities: [
                "clipboard_sync",
                "file_transfer",
                "pqc_bootstrap",
                "remote_desktop",
                "trusted",
                "alias=true",
                "chip=Apple Silicon",
                "declaredDeviceId=07CB9A6E-7492-4680-9DD7-F37DC8568891",
                "modelName=iPad16,3",
                "osVersion=26.4",
                "peerEndpoint=bonjour:iPad@local.",
                "platform=iPadOS"
            ],
            updatedAt: Date().addingTimeInterval(-20)
        )
        let stalePlaceholder = makeRecord(
            deviceId: "29094B83-3D32-4027-9B70-B1C924CB7CEF",
            protocolFingerprint: nil,
            pubKeyFingerprint: "",
            deviceName: "iPad",
            currentDeviceId: nil,
            knownDeviceIds: nil,
            capabilities: [
                "trusted",
                "file_transfer",
                "platform=iPadOS",
                "osVersion=26.4",
                "modelName=iPad16,3",
                "chip=Apple Silicon",
                "peerEndpoint=29094B83-3D32-4027-9B70-B1C924CB7CEF"
            ],
            updatedAt: Date().addingTimeInterval(-30)
        )

        let groups = TrustSyncService.buildPresentationDisplayGroups(
            from: [strongAlias, canonical, bonjourAlias, stalePlaceholder]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayRecord.deviceName, "iPad")
    }

    func testStrictPQCBootstrapDecisionNeverUsesClassicBootstrap() {
        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: false
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: true
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCBootstrap(
                policy: .default,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: false
            )
        )
    }

    func testStrictPQCKeyRefreshBootstrapDecisionNeverUsesClassicBootstrap() {
        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0")),
                hasRequiredPeerKEM: true
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.timeout),
                hasRequiredPeerKEM: true
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.transportError("Connection reset by peer")),
                hasRequiredPeerKEM: true
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: true
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .strictPQC,
                error: HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0")),
                hasRequiredPeerKEM: false
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: .default,
                error: HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0")),
                hasRequiredPeerKEM: true
            )
        )
    }

    func testPreferredPQCBootstrapRecoveryAllowsCompatibilityModeBootstrapWhenKEMMissing() {
        XCTAssertTrue(
            P2PConnection.shouldAttemptPQCBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: false,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptPQCBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: true,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptPQCBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.suiteNegotiationFailed),
                hasRequiredPeerKEM: false,
                requestedSelection: .classicOnly
            )
        )
    }

    func testPreferredPQCKeyRefreshBootstrapRecoveryAllowsCompatibilityModeTimeoutAndReset() {
        XCTAssertTrue(
            P2PConnection.shouldAttemptPQCKeyRefreshBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.timeout),
                hasRequiredPeerKEM: true,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertTrue(
            P2PConnection.shouldAttemptPQCKeyRefreshBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.transportError("Connection reset by peer")),
                hasRequiredPeerKEM: true,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertTrue(
            P2PConnection.shouldAttemptPQCKeyRefreshBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0")),
                hasRequiredPeerKEM: true,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptPQCKeyRefreshBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.timeout),
                hasRequiredPeerKEM: false,
                requestedSelection: .preferPQC
            )
        )

        XCTAssertFalse(
            P2PConnection.shouldAttemptPQCKeyRefreshBootstrapRecovery(
                policy: .default,
                error: HandshakeError.failed(.timeout),
                hasRequiredPeerKEM: true,
                requestedSelection: .classicOnly
            )
        )
    }

    private func makeRecord(
        deviceId: String,
        protocolFingerprint: String?,
        pubKeyFingerprint: String = String(repeating: "b", count: 64),
        deviceName: String,
        currentDeviceId: String?,
        knownDeviceIds: [String]?,
        capabilities: [String],
        updatedAt: Date = Date()
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: pubKeyFingerprint,
            publicKey: Data([0x01]),
            protocolPublicKey: Data([0x02]),
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: protocolFingerprint,
            capabilities: capabilities,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            signature: Data(),
            deviceName: deviceName,
            currentDeviceId: currentDeviceId,
            knownDeviceIds: knownDeviceIds,
            lifecycleState: .active
        )
    }
}
