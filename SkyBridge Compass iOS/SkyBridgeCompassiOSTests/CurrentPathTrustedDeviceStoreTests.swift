import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class CurrentPathTrustedDeviceStoreTests: XCTestCase {
    private func canonical(_ raw: String) -> String {
        PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    override func setUp() async throws {
        try await super.setUp()
        TrustedDeviceStore.shared.clearAll()
    }

    override func tearDown() async throws {
        TrustedDeviceStore.shared.clearAll()
        try await super.tearDown()
    }

    func testCurrentPathBindingRejectsIdentityConflict() {
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64)
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: "device-alpha-1234",
            protocolPublicKeyFingerprint: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(conflict, .identityConflict)
    }

    func testCurrentPathBindingAllowsSameAuthorityDeviceIdMigration() {
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64)
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: "device-beta-5678",
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64)
        )

        XCTAssertNil(conflict)
    }

    func testUniqueCanonicalTrustedDeviceIdRejectsAmbiguousEndpointAlias() {
        let endpointAlias = "host:fe80::812:27b6:c448:dad0"
        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-a",
                name: "Peer A",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-a",
                knownDeviceIds: [endpointAlias]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-b",
                name: "Peer B",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-b",
                knownDeviceIds: [endpointAlias]
            )
        ])

        XCTAssertNil(TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: endpointAlias))

        TrustedDeviceStore.shared.clearAll()
        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-a",
                name: "Peer A",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-a",
                knownDeviceIds: [endpointAlias]
            )
        ])

        XCTAssertEqual(
            TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: "host:fe80::812:27b6:c448:dad0%en0.56600"),
            "id:peer-a"
        )
    }

    func testAuthenticatedQRCodeRebindBlocksIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .identityConflict)
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .deviceIdMigrationRequired)
        )
    }

    func testAuthenticatedQRCodeRebindStillBlocksQuarantinedAndRevokedIdentities() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .revokedIdentity)
        )
    }

    func testVerifiedQRCodeCanReactivateQuarantinedAuthorityForSameDeviceOnly() {
        let deviceId = "device-alpha-1234"
        let otherDeviceId = "device-beta-1234"
        let fingerprint = String(repeating: "a", count: 64)
        let otherFingerprint = String(repeating: "b", count: 64)
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertTrue(TrustedDeviceStore.shared.markReverificationRequired(deviceId: deviceId))

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: fingerprint
        )

        XCTAssertEqual(conflict, .quarantinedIdentity)
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: otherFingerprint
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: otherDeviceId,
                protocolPublicKeyFingerprint: otherFingerprint
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .revokedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        )
    }

    func testAuthenticatedAuthorityRebindPolicyBlocksGenericIdentityConflictHealing() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .revokedIdentity)
        )
    }

    func testAuthenticatedConnectionCodeRebindOnlyAllowsSameDeviceIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .revokedIdentity)
        )
    }

    func testCurrentPathTrustLookupUsesFingerprintAuthority() {
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "c", count: 64)
        )

        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: String(repeating: "c", count: 64)
        )

        XCTAssertEqual(trusted?.currentDeviceId, canonical("device-alpha-1234"))
        XCTAssertEqual(trusted?.protocolPublicKeyFingerprint, String(repeating: "c", count: 64))
    }

    func testCurrentPathBindingMatchesKnownAliasesForConflictEvaluation() {
        let stableId = canonical("11111111-2222-4333-8444-555555555555")
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        XCTAssertTrue(
            TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: device,
                preferredCurrentDeviceId: stableId,
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: String(repeating: "d", count: 64)
            )
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: stableId,
            protocolPublicKeyFingerprint: String(repeating: "e", count: 64)
        )

        XCTAssertEqual(conflict, .identityConflict)
    }

    func testCurrentPathTrustLookupMatchesAliasBackToStableDeviceId() {
        let stableId = canonical("11111111-2222-4333-8444-555555555555")
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        XCTAssertTrue(
            TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: device,
                preferredCurrentDeviceId: stableId,
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: String(repeating: "f", count: 64)
            )
        )

        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: String(repeating: "f", count: 64),
            matchingDeviceId: stableId
        )

        XCTAssertEqual(trusted?.currentDeviceId, stableId)
    }

    func testPersistentDeviceIdRejectsDisplayNamePayloads() {
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "Fixture MacBook Pro"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "id:fixture macbook pro"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "192.168.10.22"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "id:192.168.10.22"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            PeerIdentityAliasResolver.persistentDeviceId(from: "11111111-2222-4333-8444-555555555555"),
            "id:11111111-2222-4333-8444-555555555555"
        )
    }

    func testCanonicalTrustedDeviceIdFallsBackToUniqueTrustedNameForDiscoveryDevice() {
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-mac-stable",
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "d", count: 64)
        )

        let discoveryDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: discoveryDevice),
            canonical("device-mac-stable")
        )
    }

    func testRecordAuthenticatedRemoteAuthorityUpdatesAliasMatchedTrustedRecord() {
        let stableId = "id:peer-mac-stable"
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)

        let updated = TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: aliasDevice,
            preferredCurrentDeviceId: stableId,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: String(repeating: "f", count: 64)
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice),
            stableId
        )
        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: String(repeating: "f", count: 64)
        )
        XCTAssertEqual(trusted?.currentDeviceId, stableId)
        XCTAssertEqual(trusted?.protocolSigningAlgorithm, "ML-DSA-65")
    }

    func testRecordAuthenticatedRemoteAuthorityRejectsEphemeralOnlyNewRecord() {
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: nil
        )

        let updated = TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: aliasDevice,
            preferredCurrentDeviceId: nil,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: String(repeating: "e", count: 64)
        )

        XCTAssertFalse(updated)
        XCTAssertNil(
            TrustedDeviceStore.shared.currentPathTrustRecord(
                fingerprint: String(repeating: "e", count: 64)
            )
        )
    }

    func testUpsertCurrentPathAuthorityCoalescesRepeatedDeviceIdAuthority() {
        let deviceId = "11111111-2222-4333-8444-555555555555"
        let canonicalDeviceId = canonical(deviceId)

        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: String(repeating: "1", count: 64)
        )
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: String(repeating: "2", count: 64)
        )

        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices.count, 1)
        XCTAssertNil(
            TrustedDeviceStore.shared.currentPathTrustRecord(
                fingerprint: String(repeating: "1", count: 64)
            )
        )
        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: String(repeating: "2", count: 64)
        )
        XCTAssertEqual(trusted?.currentDeviceId, canonicalDeviceId)
        XCTAssertEqual(trusted?.protocolSigningAlgorithm, "ML-DSA-65")
    }

    func testApprovedProtocolIdentityBindingAddsDifferentAlgorithmAuthorityPin() {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let edFingerprint = String(repeating: "3", count: 64)
        let mlFingerprint = String(repeating: "4", count: 64)

        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: edFingerprint
        )

        XCTAssertTrue(
            TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
                peerId: "host:fe80::812:27b6:c448:dad0%en0",
                deviceId: canonicalStableId,
                aliases: ["bonjour:Fixture MacBook Pro@local."],
                displayName: "Fixture MacBook Pro",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: mlFingerprint
            )
        )

        let fingerprints = TrustedDeviceStore.shared.currentPathFingerprints(forAny: [canonicalStableId])
        XCTAssertEqual(fingerprints, [edFingerprint, mlFingerprint])
        XCTAssertNotNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: edFingerprint))
        XCTAssertNotNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: mlFingerprint))
    }

    func testRecordAuthenticatedRemoteAuthorityCoalescesLegacyDuplicateAuthorities() {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let deviceName = "Fixture MacBook Pro"
        let oldFingerprint = String(repeating: "a", count: 64)
        let staleFingerprint = String(repeating: "b", count: 64)
        let healedFingerprint = String(repeating: "c", count: 64)

        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: stableId,
                name: deviceName,
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: oldFingerprint,
                currentDeviceId: stableId,
                knownDeviceIds: [stableId, aliasId],
                currentPathLifecycleState: .active
            ),
            TrustedDeviceStore.TrustedDevice(
                id: aliasId,
                name: deviceName,
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: staleFingerprint,
                currentDeviceId: stableId,
                knownDeviceIds: [stableId, aliasId],
                currentPathLifecycleState: .active
            )
        ])

        let aliasDevice = DiscoveredDevice(
            id: aliasId,
            name: deviceName,
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let updated = TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: aliasDevice,
            preferredCurrentDeviceId: stableId,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: healedFingerprint
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices.count, 1)
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: oldFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: staleFingerprint))
        let healedRecord = TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: healedFingerprint)
        XCTAssertEqual(healedRecord?.currentDeviceId, canonicalStableId)
        XCTAssertEqual(healedRecord?.protocolSigningAlgorithm, "ML-DSA-65")
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
    }

    func testCanonicalTrustedDeviceIdIgnoresPollutedDisplayNameCurrentDeviceId() {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)

        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:fixture macbook pro",
                name: "Fixture MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                currentDeviceId: "id:fixture macbook pro",
                knownDeviceIds: ["bonjour:Fixture MacBook Pro@local.", stableId]
            )
        ])

        let discoveryDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: discoveryDevice),
            canonicalStableId
        )
    }

    func testReverificationRequiredRecordIsNotPresentedAsTrustedOrConnectable() {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)

        XCTAssertTrue(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
        XCTAssertNotNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))

        XCTAssertTrue(TrustedDeviceStore.shared.markReverificationRequired(deviceId: stableId))

        XCTAssertFalse(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertNil(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice))
        XCTAssertNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentPathLifecycleState,
            .reverificationRequired
        )

        TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)

        XCTAssertTrue(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
        XCTAssertNotNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentPathLifecycleState,
            .active
        )
    }

    func testRepairLegacyTrustedDeviceIdentityPromotesUniqueLiveStableId() async {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let pollutedId = "id:fixture macbook pro"

        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: pollutedId,
                name: "Fixture MacBook Pro",
                platform: .macOS,
                ipAddress: nil,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: pollutedId,
                knownDeviceIds: ["bonjour:Fixture MacBook Pro@local.", "host:id:fixture macbook pro"]
            )
        ])

        let requestedDevice = DiscoveredDevice(
            id: pollutedId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1"
        )
        let liveDevice = DiscoveredDevice(
            id: canonicalStableId,
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        let migratedAliases = TrustedDeviceStore.shared.repairLegacyTrustedDeviceIdentity(
            requestedDevice: requestedDevice,
            liveDiscoveredDevice: liveDevice
        )

        XCTAssertTrue(migratedAliases.contains(pollutedId))
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: requestedDevice),
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: liveDevice),
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentDeviceId,
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.connectableContext?.bonjourServiceName,
            "Fixture MacBook Pro"
        )
    }

    func testKEMTrustStoreRebindCanonicalDeviceIdClearsLegacyAliases() async {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let pollutedId = "id:fixture macbook pro"
        let legacyHostAlias = "host:id:fixture macbook pro"
        let mlkemKey = Data(repeating: 0xAA, count: 1_184)

        await KEMTrustStore.shared.clearForTesting()
        defer {
            Task {
                await KEMTrustStore.shared.clearForTesting()
            }
        }

        await KEMTrustStore.shared.upsert(
            deviceId: pollutedId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: mlkemKey)]
        )
        await KEMTrustStore.shared.upsert(
            deviceId: legacyHostAlias,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: mlkemKey)]
        )

        await KEMTrustStore.shared.rebindCanonicalDeviceId(
            stableId,
            legacyIdentifiers: [pollutedId, legacyHostAlias]
        )

        let stableKeys = await KEMTrustStore.shared.kemPublicKeys(for: stableId)
        let legacyKeys = await KEMTrustStore.shared.kemPublicKeys(for: legacyHostAlias)

        XCTAssertEqual(stableKeys[CryptoSuite(wireId: 257)], mlkemKey)
        XCTAssertNil(legacyKeys[CryptoSuite(wireId: 257)])
    }
}
