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
}
