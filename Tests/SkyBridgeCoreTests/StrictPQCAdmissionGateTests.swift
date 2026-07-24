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

    func testStrictPQCHasNoClassicAuthorityBootstrapException() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/StrictPQCAdmissionGate.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("allowClassicAuthorityBootstrap"),
            "strictPQC must not expose a classic-only authority bootstrap bypass."
        )
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
