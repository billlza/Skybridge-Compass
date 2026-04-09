import XCTest
@testable import SkyBridgeCore

final class StrictPQCAdmissionGateTests: XCTestCase {
    func testStrictPQCRejectsClassicOnlyInboundPeer() {
        let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: .strictPQC,
            peerSupportedSuites: [.x25519Ed25519],
            localPQCSuitesAvailable: true
        )

        XCTAssertEqual(rejection, .peerOfferedClassicOnly)
    }

    func testStrictPQCRejectsLocalPQCUnavailabilityEvenIfPeerSupportsPQC() {
        let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: .strictPQC,
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            localPQCSuitesAvailable: false
        )

        XCTAssertEqual(rejection, .localPQCUnavailable)
    }

    func testDefaultPolicyDoesNotRejectClassicOnlyInboundPeer() {
        let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: .default,
            peerSupportedSuites: [.x25519Ed25519],
            localPQCSuitesAvailable: false
        )

        XCTAssertNil(rejection)
    }
}
