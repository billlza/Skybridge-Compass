import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TrustMirrorRecoveryPlanTests: XCTestCase {
    private let peer = "A1B2C3D4-2222-3333-4444-555555555555"
    private let other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let fingerprint = String(repeating: "b", count: 64)

    private func row(_ id: String, storage: String = "protected_mirror", peerID: String? = nil,
                     pin: String? = nil, updated: TimeInterval = 1, aliases: [String] = [],
                     revoke: Bool = false) -> TrustRecoverySourceRecord {
        let record = TrustRecord(deviceId: id, pubKeyFP: "", publicKey: Data(),
            protocolSigningAlgorithm: pin == nil ? nil : .mlDSA65,
            protocolPublicKeyFingerprint: pin, createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: revoke ? Date() : Date(timeIntervalSince1970: 1_780_000_000 + updated), signature: Data(),
            recordType: revoke ? .revoke : .add, revokedAt: revoke ? Date() : nil,
            currentDeviceId: peerID ?? peer, knownDeviceIds: aliases)
        return TrustRecoverySourceRecord(storage: storage, backingReferenceSHA256: id,
                                         recordSHA256: String(repeating: "f", count: 64), record: record)
    }

    private var authority: TrustRecoverySourceRecord {
        row("id:\(peer.lowercased())", storage: "data_protection_keychain", pin: fingerprint, updated: 20)
    }

    func testRetiresOnlyMirrorAliasesAndKeepsAnAlreadyPinnedKeychainAuthority() throws {
        let legacy = row("id:\(peer.uppercased())", pin: String(repeating: "a", count: 64))
        let alias = row("bonjour:iPhone@local.")
        let unrelated = row("id:\(other.lowercased())", peerID: other, pin: String(repeating: "a", count: 64))
        let plan = try TrustMirrorRecoveryPlan.resolve(sources: [authority, legacy, alias, unrelated],
                                                      peerID: peer, fingerprint: fingerprint)
        XCTAssertEqual(plan.authority.record, authority.record)
        XCTAssertEqual(Set(plan.retiring.map { $0.record.deviceId }), [legacy.record.deviceId, alias.record.deviceId])
        XCTAssertFalse(plan.retiring.contains { $0.record.deviceId == unrelated.record.deviceId })
    }

    func testRefusesKeyReplacementRevocationNewerMirrorAndCrossDeviceClaims() {
        for sources in [
            [row("id:\(peer)", pin: fingerprint)],
            [authority, row("bonjour:revoked", revoke: true)],
            [authority, row("bonjour:newer", updated: 21)],
            [authority, row("bonjour:cross", aliases: [other]), row("id:\(other)", peerID: other)],
            [authority, row("id:\(peer)", storage: "file_keychain", pin: fingerprint)],
        ] {
            XCTAssertThrowsError(try TrustMirrorRecoveryPlan.resolve(sources: sources, peerID: peer, fingerprint: fingerprint))
        }
        XCTAssertThrowsError(try TrustMirrorRecoveryPlan.resolve(sources: [authority, row("bonjour:phone")],
                                                                peerID: peer, fingerprint: String(repeating: "c", count: 64)))
    }

    func testSharedAliasRequiresExactPreservedPeerAndCannotDeleteItsAuthorityOrHideRevocation() throws {
        let alias = row("bonjour:iPhone@local.", aliases: [peer, other])
        let foreign = row("id:\(other)", peerID: other, pin: String(repeating: "a", count: 64))
        let sources = [authority, alias, foreign]
        XCTAssertThrowsError(try TrustMirrorRecoveryPlan.resolve(sources: sources, peerID: peer, fingerprint: fingerprint))
        let plan = try TrustMirrorRecoveryPlan.resolve(sources: sources, peerID: peer, fingerprint: fingerprint,
                                                      preservingSharedPeerID: other)
        XCTAssertEqual(plan.retiring.map(\.record), [alias.record])
        XCTAssertEqual(plan.preserving.map(\.record), [foreign.record])
        XCTAssertEqual(plan.authority.record, authority.record)
        for bad in [
            [authority, alias, row("id:\(other)", peerID: other, revoke: true)],
            [authority, row("id:\(other)", peerID: peer, aliases: [other]), foreign],
            [authority, alias, row("bonjour:foreign", peerID: other)],
            [authority, row("bonjour:unshared")]
        ] {
            XCTAssertThrowsError(try TrustMirrorRecoveryPlan.resolve(sources: bad, peerID: peer, fingerprint: fingerprint,
                                                                    preservingSharedPeerID: other))
        }
    }
}
