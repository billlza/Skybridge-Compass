import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class CurrentPathTrustedDeviceStoreTests: XCTestCase {
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

        XCTAssertEqual(trusted?.currentDeviceId, "device-alpha-1234")
        XCTAssertEqual(trusted?.protocolPublicKeyFingerprint, String(repeating: "c", count: 64))
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
            "device-mac-stable"
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
        XCTAssertEqual(trusted?.currentDeviceId, deviceId)
        XCTAssertEqual(trusted?.protocolSigningAlgorithm, "ML-DSA-87")
    }

    func testRecordAuthenticatedRemoteAuthorityCoalescesLegacyDuplicateAuthorities() {
        let stableId = "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
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
        XCTAssertEqual(healedRecord?.currentDeviceId, stableId)
        XCTAssertEqual(healedRecord?.protocolSigningAlgorithm, "ML-DSA-87")
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), stableId)
    }
}
