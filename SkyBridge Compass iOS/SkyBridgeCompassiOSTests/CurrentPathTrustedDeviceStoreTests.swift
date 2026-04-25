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
        let stableId = canonical("E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        let aliasId = "bonjour:Lza的MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Lza的MacBook Pro",
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
        let stableId = canonical("E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        let aliasId = "bonjour:Lza的MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Lza的MacBook Pro",
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
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "Lza的MacBook Pro"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "id:lza的macbook pro"))
        XCTAssertEqual(
            PeerIdentityAliasResolver.persistentDeviceId(from: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"),
            "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"
        )
    }

    func testCanonicalTrustedDeviceIdFallsBackToUniqueTrustedNameForDiscoveryDevice() {
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-mac-stable",
            name: "Lza的MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "d", count: 64)
        )

        let discoveryDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Lza的MacBook Pro",
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
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
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
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
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
        let deviceId = "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        let canonicalDeviceId = canonical(deviceId)

        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Lza的MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: String(repeating: "1", count: 64)
        )
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Lza的MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "ML-DSA-87",
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
        XCTAssertEqual(trusted?.protocolSigningAlgorithm, "ML-DSA-87")
    }

    func testRecordAuthenticatedRemoteAuthorityCoalescesLegacyDuplicateAuthorities() {
        let stableId = "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        let canonicalStableId = canonical(stableId)
        let aliasId = "bonjour:Lza的MacBook Pro@local."
        let deviceName = "Lza的MacBook Pro"
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
            protocolSigningAlgorithm: "ML-DSA-87",
            protocolPublicKeyFingerprint: healedFingerprint
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices.count, 1)
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: oldFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: staleFingerprint))
        let healedRecord = TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: healedFingerprint)
        XCTAssertEqual(healedRecord?.currentDeviceId, canonicalStableId)
        XCTAssertEqual(healedRecord?.protocolSigningAlgorithm, "ML-DSA-87")
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
    }

    func testCanonicalTrustedDeviceIdIgnoresPollutedDisplayNameCurrentDeviceId() {
        let stableId = "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        let canonicalStableId = canonical(stableId)

        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:lza的macbook pro",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                currentDeviceId: "id:lza的macbook pro",
                knownDeviceIds: ["bonjour:Lza的MacBook Pro@local.", stableId]
            )
        ])

        let discoveryDevice = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            bonjourServiceName: "Lza的MacBook Pro",
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

    func testRepairLegacyTrustedDeviceIdentityPromotesUniqueLiveStableId() async {
        let stableId = "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        let canonicalStableId = canonical(stableId)
        let pollutedId = "id:lza的macbook pro"

        TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: pollutedId,
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: nil,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: pollutedId,
                knownDeviceIds: ["bonjour:Lza的MacBook Pro@local.", "host:id:lza的macbook pro"]
            )
        ])

        let requestedDevice = DiscoveredDevice(
            id: pollutedId,
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1"
        )
        let liveDevice = DiscoveredDevice(
            id: canonicalStableId,
            name: "Lza的MacBook Pro",
            bonjourServiceName: "Lza的MacBook Pro",
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
            "Lza的MacBook Pro"
        )
    }

    func testKEMTrustStoreRebindCanonicalDeviceIdClearsLegacyAliases() async {
        let stableId = "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"
        let pollutedId = "id:lza的macbook pro"
        let legacyHostAlias = "host:id:lza的macbook pro"
        let mlkemKey = Data([0xAA, 0xBB, 0xCC])

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
