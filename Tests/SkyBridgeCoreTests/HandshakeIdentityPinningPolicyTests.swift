import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeIdentityPinningPolicyTests: XCTestCase {
    func testMLDSA87RejectsMatchingFingerprintWithoutExactRawAuthority() throws {
        let identity = makeIdentity(algorithm: .mlDSA87, byte: 0x87)
        let matchingFingerprint = try identity.authoritativeProtocolFingerprint()

        XCTAssertThrowsError(
            try HandshakeIdentityPinningPolicy.validate(
                identityKeys: identity,
                exactAuthorities: [],
                trustedFingerprints: [matchingFingerprint, String(repeating: "a", count: 64)],
                requiresPinnedIdentity: true
            )
        ) { error in
            guard case HandshakeError.failed(.identityMismatch(let expected, let actual)) = error else {
                XCTFail("Expected typed exact-key rejection, got \(error)")
                return
            }
            XCTAssertEqual(expected, "exact_ml-dsa-87_raw_key")
            XCTAssertEqual(actual, "fingerprint_only_or_missing")
        }
    }

    func testMLDSA87AcceptsOnlyTheExactAlgorithmTaggedRawAuthority() throws {
        let identity = makeIdentity(algorithm: .mlDSA87, byte: 0x87)
        XCTAssertNoThrow(
            try HandshakeIdentityPinningPolicy.validate(
                identityKeys: identity,
                exactAuthorities: [
                    TrustedProtocolIdentityRawKey(
                        algorithm: .mlDSA87,
                        publicKey: identity.protocolPublicKey
                    )
                ],
                trustedFingerprints: [],
                requiresPinnedIdentity: true
            )
        )
    }

    func testConflictingRawAuthoritySourcesFailEvenWhenOneMatches() throws {
        let identity = makeIdentity(algorithm: .mlDSA87, byte: 0x87)
        XCTAssertThrowsError(
            try HandshakeIdentityPinningPolicy.validate(
                identityKeys: identity,
                exactAuthorities: [
                    TrustedProtocolIdentityRawKey(
                        algorithm: .mlDSA87,
                        publicKey: identity.protocolPublicKey
                    ),
                    TrustedProtocolIdentityRawKey(
                        algorithm: .mlDSA87,
                        publicKey: Data(repeating: 0x88, count: 2_592)
                    )
                ],
                trustedFingerprints: [try identity.authoritativeProtocolFingerprint()],
                requiresPinnedIdentity: true
            )
        ) { error in
            guard case HandshakeError.failed(.identityMismatch(_, let actual)) = error else {
                XCTFail("Expected typed conflict rejection, got \(error)")
                return
            }
            XCTAssertEqual(actual, "conflicting_raw_key_authorities")
        }
    }

    func testMLDSA65RetainsFingerprintCompatibilityWhenRawAuthorityIsAbsent() throws {
        let identity = makeIdentity(algorithm: .mlDSA65, byte: 0x65)
        XCTAssertNoThrow(
            try HandshakeIdentityPinningPolicy.validate(
                identityKeys: identity,
                exactAuthorities: [],
                trustedFingerprints: [try identity.authoritativeProtocolFingerprint()],
                requiresPinnedIdentity: true
            )
        )
    }

    private func makeIdentity(
        algorithm: ProtocolSigningAlgorithm,
        byte: UInt8
    ) -> IdentityPublicKeys {
        let length: Int
        switch algorithm {
        case .ed25519:
            length = 32
        case .mlDSA65:
            length = 1_952
        case .mlDSA87:
            length = 2_592
        }
        return IdentityPublicKeys(
            protocolPublicKey: Data(repeating: byte, count: length),
            protocolAlgorithm: algorithm.wire
        )
    }
}
