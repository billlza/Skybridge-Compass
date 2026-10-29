import XCTest
@testable import SkyBridgeCore

final class ProtocolIdentityConfigurationRecordTests: XCTestCase {
    func testTestProcessReportsEphemeralIdentityStorageLifetime() {
        XCTAssertTrue(DeviceIdentityKeyManager.usesEphemeralIdentityStoreForCurrentProcess)
    }

    func testEphemeralIdentityStoreProvisionsStoredSelectionWithoutMutatingDurablePolicy() {
        XCTAssertEqual(
            ProtocolIdentityAuthorityRestorationPolicy.action(
                shouldProvisionDefault: false,
                usesEphemeralIdentityStore: true
            ),
            .provision
        )
        XCTAssertEqual(
            ProtocolIdentityAuthorityRestorationPolicy.action(
                shouldProvisionDefault: false,
                usesEphemeralIdentityStore: false
            ),
            .requireExisting
        )
        XCTAssertEqual(
            ProtocolIdentityAuthorityRestorationPolicy.action(
                shouldProvisionDefault: true,
                usesEphemeralIdentityStore: false
            ),
            .provision
        )
    }

    func testAtomicRecordRoundTripsAlgorithmAndProtectionTogether() throws {
        let record = ProtocolIdentityConfigurationRecord(
            algorithm: .mlDSA87,
            protection: .secureEnclaveRequired
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(
            ProtocolIdentityConfigurationRecord.self,
            from: encoded
        )

        XCTAssertEqual(decoded, record)
        XCTAssertTrue(decoded.isValidAuthoritySelection)
    }

    func testUnknownVersionAndClassicIdentityAreNotAuthoritySelections() {
        XCTAssertFalse(
            ProtocolIdentityConfigurationRecord(
                version: ProtocolIdentityConfigurationRecord.currentVersion + 1,
                algorithm: .mlDSA87,
                protection: .softwareKeychain
            ).isValidAuthoritySelection
        )
        XCTAssertFalse(
            ProtocolIdentityConfigurationRecord(
                algorithm: .ed25519,
                protection: .softwareKeychain
            ).isValidAuthoritySelection
        )
    }

    func testOnlyNewestAsynchronousConfigurationRequestMayCommit() {
        var gate = ProtocolIdentityConfigurationRequestGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }
}
