import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PQCIdentityTokenTests: XCTestCase {
    func testStrictIdentityTokenPreservesExactBoundedUTF8Value() throws {
        let asciiBoundary = String(repeating: "a", count: 256)
        let multibyteBoundary = String(repeating: "é", count: 128)

        XCTAssertEqual(
            try PQCIdentityToken.validated(asciiBoundary),
            asciiBoundary
        )
        XCTAssertEqual(multibyteBoundary.utf8.count, 256)
        XCTAssertEqual(
            try PQCIdentityToken.validated(multibyteBoundary),
            multibyteBoundary
        )
    }

    func testStrictIdentityTokenRejectsAliasesControlsAndOverlongUTF8() {
        let invalidValues = [
            "",
            " peer",
            "peer ",
            "peer\nvalue",
            "peer\0value",
            String(repeating: "a", count: 257),
            String(repeating: "é", count: 129)
        ]

        for invalid in invalidValues {
            XCTAssertThrowsError(try PQCIdentityToken.validated(invalid)) {
                XCTAssertEqual($0 as? PQCIdentityTokenError, .invalid)
            }
        }
    }

    func testInvalidStoreIdentityFailsBeforeGenerationValidationOrAuthorityClaim() throws {
        let keychain = PQCKeychainTestContext()
        let authorityDomain = PQCBackendAuthorityDomain.testing(
            "invalid-token-\(UUID().uuidString)"
        )
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: " invalid-store-identity ",
            authority: .active,
            authorityDomain: authorityDomain,
            storageScope: keychain.storageScope
        )
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: authorityDomain,
                scopeSource: keychain.scopeSource
            )
        }
        var generationCount = 0
        var pairValidationCount = 0
        let candidate = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data(repeating: 0x11, count: 4),
            privateKey: Data(repeating: 0x22, count: 4)
        )
        let validatePair: (PQCKeyPairRecord) throws -> Void = { _ in
            pairValidationCount += 1
        }

        assertInvalidIdentity {
            _ = try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: 4,
                privateKeyLength: 4,
                validatePair: validatePair
            )
        }
        assertInvalidIdentity {
            _ = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: 4,
                privateKeyLength: 4,
                validatePair: validatePair,
                generate: {
                    generationCount += 1
                    return candidate
                }
            )
        }
        assertInvalidIdentity {
            _ = try PQCKeyPairStore.insertIfAbsent(
                candidate,
                descriptor: descriptor,
                publicKeyLength: 4,
                privateKeyLength: 4,
                validatePair: validatePair
            )
        }

        XCTAssertEqual(generationCount, 0)
        XCTAssertEqual(pairValidationCount, 0)
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: authorityDomain,
                scopeSource: keychain.scopeSource
            )
        )
    }

    private func assertInvalidIdentity(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case PQCKeyPairStoreError.invalidIdentity = error else {
                return XCTFail(
                    "Expected invalidIdentity, got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
