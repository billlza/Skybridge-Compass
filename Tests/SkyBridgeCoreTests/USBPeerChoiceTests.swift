import CryptoKit
import XCTest
@testable import SkyBridgeCore

@MainActor
final class USBPeerChoiceTests: XCTestCase {
    func testPairedIdentityIsSelectableWithoutAnyDiscoveryRecord() async throws {
        let peerID = UUID().uuidString
        let record = makeRecord(id: "id:\(peerID)")
        let choices = await TrustSyncService.usbPeerChoices(from: [record])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice.peer_id, peerID)
        XCTAssertEqual(choice.expected_fingerprint, record.protocolPublicKeyFingerprint)
        XCTAssertNil(choice.unavailable_reason)
    }

    func testConflictingPinsStayVisibleButCannotBeSelected() async throws {
        let peerID = UUID().uuidString
        let first = makeRecord(id: "id:\(peerID)")
        let other = makeRecord(id: peerID)
        let choices = await TrustSyncService.usbPeerChoices(from: [first, other])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertNil(choice.expected_fingerprint)
        XCTAssertEqual(choice.unavailable_reason, "pairing_identity_needs_verification")
    }

    func testDisplayAliasCannotCreateASelectableProtocolIdentity() async {
        let claimed = UUID().uuidString
        let record = makeRecord(id: "account:display-only", alias: claimed)
        let choices = await TrustSyncService.usbPeerChoices(from: [record])
        XCTAssertTrue(choices.isEmpty)
    }

    func testRevokedAndQuarantinedRecordsAreNotConnectionChoices() async {
        let revoked = makeRecord(id: UUID().uuidString, lifecycle: .revoked)
        let quarantined = makeRecord(id: UUID().uuidString, lifecycle: .quarantined)
        let choices = await TrustSyncService.usbPeerChoices(from: [revoked, quarantined])
        XCTAssertTrue(choices.isEmpty)
    }

    private func makeRecord(id: String, alias: String? = nil,
                            lifecycle: TrustLifecycleState = .active) -> TrustRecord {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .ed25519, publicKeyBytes: key)
        return TrustRecord(
            deviceId: id, pubKeyFP: fingerprint, publicKey: key,
            protocolPublicKey: key, protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint, signature: Data(),
            deviceName: "Paired device", currentDeviceId: alias, knownDeviceIds: alias.map { [$0] },
            lifecycleState: lifecycle
        )
    }
}
