import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class RemoteControlTrustResolutionTests: XCTestCase {
    @MainActor
    func testTrustInvalidationSynchronouslyRemovesMatchingPeerAdmissionOnly() async {
        let manager = RemoteControlManager()
        let revokedId = "id:remote-control-revoked-\(UUID().uuidString.lowercased())"
        let retainedId = "id:remote-control-retained-\(UUID().uuidString.lowercased())"
        let revokedProbe = manager.testingRegisterPeerForTrustInvalidation(deviceId: revokedId)
        manager.testingRegisterPeerForTrustInvalidation(deviceId: retainedId)
        XCTAssertEqual(manager.testingPeerSecurityAdmissionApproved(deviceId: revokedId), true)
        XCTAssertEqual(manager.testingPeerSecurityAdmissionApproved(deviceId: retainedId), true)

        manager.testingHandleTrustInvalidation(
            TrustInvalidationEvent(
                revision: UUID(),
                deviceIds: [revokedId],
                protocolFingerprints: []
            )
        )

        XCTAssertFalse(revokedProbe.isSecurityAdmissionApproved)
        XCTAssertTrue(revokedProbe.didCancelConnection)
        XCTAssertFalse(manager.testingHasCurrentPeer(deviceId: revokedId))
        XCTAssertTrue(manager.testingHasCurrentPeer(deviceId: retainedId))
        XCTAssertEqual(manager.testingPeerSecurityAdmissionApproved(deviceId: retainedId), true)
        XCTAssertFalse(manager.connectedDevices.contains(revokedId))
        XCTAssertTrue(manager.connectedDevices.contains(retainedId))

        manager.testingHandleTrustInvalidation(
            TrustInvalidationEvent(
                revision: UUID(),
                deviceIds: [retainedId],
                protocolFingerprints: []
            )
        )
        await Task.yield()
    }

    func testQuarantinedAndReverificationRecordsCannotAuthorizeInboundOrHandshakeTrust() async {
        let deviceId = "id:lifecycle-gated-peer"
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: deviceId)
        let quarantined = lifecycleRecord(
            deviceId: deviceId,
            fingerprint: String(repeating: "a", count: 64),
            state: .quarantined
        )
        let reverification = lifecycleRecord(
            deviceId: deviceId,
            fingerprint: String(repeating: "b", count: 64),
            state: .reverificationRequired
        )

        for record in [quarantined, reverification] {
            XCTAssertEqual(
                RemoteControlInboundTrustResolver.resolve(
                    remoteSOAPeerId: remotePeerId,
                    records: [record]
                ),
                .missing
            )
            let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: [record])
            let fingerprints = await provider.trustedFingerprints(for: deviceId)
            let kemKeys = await provider.trustedKEMPublicKeys(for: deviceId)
            XCTAssertEqual(fingerprints, [])
            XCTAssertEqual(kemKeys, [:])
        }
    }

    func testQuarantinedAliasSuppressesMatchingActiveAuthority() async {
        let deviceId = "id:mixed-lifecycle-peer"
        let activeFingerprint = String(repeating: "c", count: 64)
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: deviceId)
        let active = lifecycleRecord(
            deviceId: deviceId,
            fingerprint: activeFingerprint,
            state: .active
        )
        let quarantined = lifecycleRecord(
            deviceId: "shadow-mixed-lifecycle-peer",
            fingerprint: String(repeating: "d", count: 64),
            state: .quarantined,
            currentDeviceId: deviceId
        )

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(
                remoteSOAPeerId: remotePeerId,
                records: [active, quarantined]
            ),
            .missing
        )
        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: [active, quarantined])
        let trustedFingerprints = await provider.trustedFingerprints(for: deviceId)
        XCTAssertTrue(trustedFingerprints.isEmpty)
        let requiresPin = await provider.requiresPinnedProtocolIdentity(for: deviceId)
        XCTAssertTrue(requiresPin)
    }

    func testEquivalentInboundTrustRecordsCollapseToSingleCanonicalDevice() {
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:peer-mac")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "f", count: 64),
                signature: Data([0x03]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["id:peer-mac", "bonjour:lza's macbook pro@local."]
            ),
            TrustRecord(
                deviceId: "shadow-peer-a",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "f", count: 64),
                signature: Data([0x13]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["id:peer-mac"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .resolved(deviceId: "id:peer-mac", fingerprint: String(repeating: "f", count: 64))
        )
    }

    func testDualAlgorithmInboundTrustRecordsResolveToSingleCanonicalDevice() {
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: deviceId)

        let records = [
            TrustRecord(
                deviceId: "\(deviceId)|ed25519",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "9", count: 64),
                signature: Data([0x03]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            ),
            TrustRecord(
                deviceId: "\(deviceId)|mldsa",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .resolved(deviceId: deviceId, fingerprint: nil)
        )
    }

    func testSameAlgorithmFingerprintConflictRemainsAmbiguous() {
        let deviceId = "id:shared-peer"
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: deviceId)

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
                signature: Data([0x03]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            ),
            TrustRecord(
                deviceId: "legacy-peer-b",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .ambiguous(
                deviceIds: [deviceId],
                fingerprints: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)]
            )
        )
    }

    func testDefaultHandshakeTrustProviderRejectsSameAlgorithmFingerprintConflict() async {
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let records = [
            TrustRecord(
                deviceId: "\(deviceId)|mldsa-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
                signature: Data([0x03]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            ),
            TrustRecord(
                deviceId: "\(deviceId)|mldsa-b",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        ]

        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: records)
        let multiProvider: any MultiFingerprintHandshakeTrustProvider = provider
        let trustedFingerprints = await multiProvider.trustedFingerprints(for: deviceId)
        let singleFingerprint = await provider.trustedFingerprint(for: deviceId)

        XCTAssertEqual(trustedFingerprints, [])
        XCTAssertNil(singleFingerprint)
    }

    func testDefaultHandshakeTrustProviderRejectsAliasDeviceConflict() async {
        let alias = "id:shared-peer"
        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
                signature: Data([0x03]),
                deviceName: "iPhone",
                currentDeviceId: "id:peer-a",
                knownDeviceIds: [alias]
            ),
            TrustRecord(
                deviceId: "legacy-peer-b",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: "id:peer-b",
                knownDeviceIds: [alias]
            )
        ]

        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: records)
        let multiProvider: any MultiFingerprintHandshakeTrustProvider = provider
        let trustedFingerprints = await multiProvider.trustedFingerprints(for: alias)
        let singleFingerprint = await provider.trustedFingerprint(for: alias)

        XCTAssertEqual(trustedFingerprints, [])
        XCTAssertNil(singleFingerprint)
    }

    func testDefaultHandshakeTrustProviderReturnsAllPinsFromSingleMultiPinRecord() async {
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let edFingerprint = String(repeating: "9", count: 64)
        let mlFingerprint = String(repeating: "c", count: 64)
        let record = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x01]),
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: mlFingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .ed25519,
                    fingerprint: edFingerprint,
                    source: .legacyMigration
                ),
                ProtocolIdentityPin(
                    algorithm: .mlDSA65,
                    fingerprint: mlFingerprint,
                    source: .pib1OperatorApproval
                )
            ],
            signature: Data([0x02]),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId]
        )

        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: [record])
        let multiProvider: any MultiFingerprintHandshakeTrustProvider = provider
        let trustedFingerprints = await multiProvider.trustedFingerprints(for: deviceId)

        XCTAssertEqual(trustedFingerprints, [edFingerprint, mlFingerprint])
        let singleFingerprint = await provider.trustedFingerprint(for: deviceId)
        XCTAssertNil(singleFingerprint)
    }

    func testDefaultHandshakeTrustProviderUsesSnapshotForKEMAndSecureEnclavePins() async {
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let kemPublicKey = Data(repeating: 0x44, count: 1_184)
        let secureEnclavePublicKey = Data([0x77, 0x88, 0x99])
        let records = [
            TrustRecord(
                deviceId: "\(deviceId)|mldsa",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                secureEnclavePublicKey: secureEnclavePublicKey,
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                kemPublicKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                        publicKey: kemPublicKey
                    )
                ],
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        ]

        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: records)
        let trustedKEMPublicKeys = await provider.trustedKEMPublicKeys(for: deviceId)
        let trustedSecureEnclavePublicKey = await provider.trustedSecureEnclavePublicKey(for: deviceId)

        XCTAssertEqual(
            trustedKEMPublicKeys,
            [.mlkem768MLDSA65: kemPublicKey]
        )
        XCTAssertEqual(
            trustedSecureEnclavePublicKey,
            secureEnclavePublicKey
        )
    }

    @MainActor
    func testDefaultHandshakeTrustProviderReturnsAllDualAlgorithmPinsForSingleDevice() async throws {
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let edRecordId = "\(deviceId)|ed25519"
        let mlRecordId = "\(deviceId)|mldsa"
        let edFingerprint = String(repeating: "9", count: 64)
        let mlFingerprint = String(repeating: "c", count: 64)
        let trust = TrustSyncService.shared

        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [edRecordId, mlRecordId])
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [edRecordId, mlRecordId])
            trust.endInMemoryPersistenceForTesting()
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: edRecordId,
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: edFingerprint,
                signature: Data([0x03]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        )
        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: mlRecordId,
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: mlFingerprint,
                signature: Data([0x13]),
                deviceName: "iPhone",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        )

        XCTAssertEqual(
            trust.activeTrustRecords.filter { $0.currentDeviceId == deviceId }.count,
            2
        )

        let activeRecords = trust.activeTrustRecords.filter { $0.currentDeviceId == deviceId }
        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: activeRecords)
        XCTAssertEqual(
            provider.resolvedTrustedFingerprints(directRecord: nil, matchingRecords: activeRecords),
            [edFingerprint, mlFingerprint]
        )
        let multiProvider: any MultiFingerprintHandshakeTrustProvider = provider
        let trustedFingerprints = await multiProvider.trustedFingerprints(for: deviceId)
        let singleFingerprint = await provider.trustedFingerprint(for: deviceId)

        XCTAssertEqual(
            trustedFingerprints,
            [edFingerprint, mlFingerprint]
        )
        XCTAssertNil(
            singleFingerprint,
            "The legacy single-pin lookup must not invent one winner when a device has multiple protocol-signing pins."
        )
    }

    func testConflictingInboundTrustRecordsRemainAmbiguous() {
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:shared-peer")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
                signature: Data([0x03]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac-a",
                knownDeviceIds: ["id:shared-peer"]
            ),
            TrustRecord(
                deviceId: "legacy-peer-b",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data([0x13]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac-b",
                knownDeviceIds: ["id:shared-peer"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .ambiguous(
                deviceIds: ["id:peer-mac-a", "id:peer-mac-b"],
                fingerprints: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)]
            )
        )
    }

    func testEquivalentBareAndPersistentCurrentDeviceIdsCollapse() {
        let rawUUID = "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:\(rawUUID.lowercased())")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                signature: Data([0x03]),
                deviceName: "iPad",
                currentDeviceId: rawUUID,
                knownDeviceIds: [rawUUID, "id:\(rawUUID.lowercased())", "bonjour:ipad@local."]
            ),
            TrustRecord(
                deviceId: "shadow-peer-a",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                signature: Data([0x13]),
                deviceName: "iPad",
                currentDeviceId: "id:\(rawUUID.lowercased())",
                knownDeviceIds: ["id:\(rawUUID.lowercased())"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .resolved(
                deviceId: "id:\(rawUUID.lowercased())",
                fingerprint: String(repeating: "c", count: 64)
            )
        )
    }

    private func lifecycleRecord(
        deviceId: String,
        fingerprint: String,
        state: TrustLifecycleState,
        currentDeviceId: String? = nil
    ) -> TrustRecord {
        let canonicalDeviceId = currentDeviceId ?? deviceId
        return TrustRecord(
            deviceId: deviceId,
            pubKeyFP: fingerprint,
            publicKey: Data([0x01]),
            protocolPublicKey: Data([0x02]),
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0x44, count: 1_184)
                )
            ],
            signature: Data([0x03]),
            currentDeviceId: canonicalDeviceId,
            knownDeviceIds: [canonicalDeviceId],
            lifecycleState: state
        )
    }
}
