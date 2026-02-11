import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class BootstrapAssuranceTests: XCTestCase {
    func testBootstrapControlMessageClassification() {
        let controlMessage = AppMessage.pairingIdentityExchange(
            .init(deviceId: "peer-device", kemPublicKeys: [])
        )
        let businessMessage = AppMessage.heartbeat(.init())

        XCTAssertTrue(P2PConnection.isBootstrapControlMessage(controlMessage))
        XCTAssertFalse(P2PConnection.isBootstrapControlMessage(businessMessage))
    }

    func testAssuranceClassificationStrictPQCWithoutBootstrap() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .strictPQC,
            negotiatedSuite: .mlkem768MLDSA65,
            bootstrapAssisted: false
        )

        XCTAssertEqual(assurance, .pqcStrict)
    }

    func testAssuranceClassificationBootstrapAssistedWins() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .strictPQC,
            negotiatedSuite: .mlkem768MLDSA65,
            bootstrapAssisted: true
        )

        XCTAssertEqual(assurance, .bootstrapAssisted)
    }

    func testAssuranceClassificationLegacyClassic() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .default,
            negotiatedSuite: .x25519Ed25519,
            bootstrapAssisted: false
        )

        XCTAssertEqual(assurance, .legacyClassic)
    }
}
