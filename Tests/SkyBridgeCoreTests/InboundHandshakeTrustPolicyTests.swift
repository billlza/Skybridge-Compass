import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

/// Shared inbound-admission classification: macOS and iOS both feed this
/// policy, so its semantics are protocol contract, not adapter behavior.
final class InboundHandshakeTrustPolicyTests: XCTestCase {
    private let fingerprint = "AB12cd34EF56ab78cd90ef12ab34cd56ef78ab90cd12ef34ab56cd78ef90ab12"

    // MARK: - Disposition

    func testUniquePinnedMatchResolvesPinnedPeer() {
        let disposition = InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: ["id:mac-1234"]
        )
        XCTAssertEqual(disposition, .pinnedPeer(stablePeerId: "id:mac-1234"))
    }

    func testNoMatchResolvesUnpinnedPeer() {
        let disposition = InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: []
        )
        XCTAssertEqual(disposition, .unpinnedPeer)
    }

    func testMissingFingerprintResolvesUnpinnedPeerEvenWithCandidates() {
        for absent in [nil, "", "   "] {
            let disposition = InboundHandshakeTrustPolicy.disposition(
                presentedProtocolIdentityFingerprint: absent,
                pinnedStablePeerIdsMatchingPresentedIdentity: ["id:mac-1234"]
            )
            XCTAssertEqual(disposition, .unpinnedPeer)
        }
    }

    func testDistinctMatchesResolveAmbiguous() {
        let disposition = InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: ["id:mac-1234", "id:mac-9999"]
        )
        XCTAssertEqual(
            disposition,
            .ambiguousPinnedIdentity(stablePeerIds: ["id:mac-1234", "id:mac-9999"])
        )
    }

    func testEquivalentAliasSpellingsCollapseToOnePinnedPeer() {
        let disposition = InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: [
                "id:MAC-1234",
                " id:mac-1234 ",
                "id:mac-1234"
            ]
        )
        XCTAssertEqual(disposition, .pinnedPeer(stablePeerId: "id:mac-1234"))
    }

    func testBlankCandidatesAreIgnored() {
        let disposition = InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: ["", "   ", "id:mac-1234"]
        )
        XCTAssertEqual(disposition, .pinnedPeer(stablePeerId: "id:mac-1234"))
    }

    // MARK: - Action mapping (the product semantics both platforms must apply)

    func testPinnedPeerIsAdmittedAutomaticallyWithPinEnforced() {
        XCTAssertEqual(
            InboundHandshakeTrustPolicy.action(
                for: .pinnedPeer(stablePeerId: "id:mac-1234")
            ),
            .admitPinned(stablePeerId: "id:mac-1234")
        )
    }

    func testUnpinnedPeerIsAdmittedWithDeferredPairingConfirmationNotDropped() {
        XCTAssertEqual(
            InboundHandshakeTrustPolicy.action(for: .unpinnedPeer),
            .admitDeferringPairingConfirmation
        )
    }

    func testAmbiguousPinIsAdmittedWithDeferredPairingConfirmationNotDropped() {
        XCTAssertEqual(
            InboundHandshakeTrustPolicy.action(
                for: .ambiguousPinnedIdentity(stablePeerIds: ["a", "b"])
            ),
            .admitDeferringPairingConfirmation
        )
    }
}
