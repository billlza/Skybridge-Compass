import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class CurrentPathTrustedDeviceStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TrustedDeviceStore.shared.clearAll()
    }

    override func tearDown() {
        TrustedDeviceStore.shared.clearAll()
        super.tearDown()
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

    func testCurrentPathBindingRejectsDeviceIdMigration() {
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

        XCTAssertEqual(conflict, .deviceIdMigrationRequired)
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
}
