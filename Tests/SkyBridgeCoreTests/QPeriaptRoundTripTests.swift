//
// QPeriaptRoundTripTests.swift
// SkyBridgeCoreTests
//
// SAME-PROCESS round-trip self-consistency test for `QPeriaptCryptoProvider`.
//
// HONESTY: this proves SELF-CONSISTENCY only — a SINGLE provider instance
// encapsulates→decapsulates and seals→opens against its OWN key pair, all in
// one process. It does NOT prove cross-peer / two-device interop (separate
// encaps and decaps processes / wire encoding / handshake). That still requires
// the user's Xcode/device two-peer run.
//
// The provider type is gated for SELECTION at runtime (Q-Periapt beta flag),
// but the type itself is directly instantiable, which is exactly what we drive
// here via the `CryptoProvider` protocol surface.
//

import XCTest
@testable import SkyBridgeCore

#if canImport(CQPeriapt)

@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptRoundTripTests: XCTestCase {
    func testQPeriaptRuntimeProbePassesOnSupportedAppleRuntime() throws {
        guard QPeriaptPlatformPolicy.isSupportedAppleOSVersion(ProcessInfo.processInfo.operatingSystemVersion) else {
            throw XCTSkip("Q-Periapt runtime admission requires macOS/iOS 26+.")
        }

        XCTAssertTrue(QPeriaptCryptoProvider.quickRuntimeProbe())
        XCTAssertTrue(QPeriaptPlatformPolicy.isLocalRuntimeSupported)
    }

    /// KEM round-trip: encapsulate against a freshly generated public key, then
    /// decapsulate with the matching private blob, and assert both sides derive
    /// the identical 32-byte shared secret (and it is non-zero). Also pins the
    /// wire/blob lengths the provider documents.
    func testQPeriaptKEMRoundTrip() async throws {
        let provider = QPeriaptCryptoProvider()
        XCTAssertEqual(provider.tier, .qperiaptPQC)

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)

        // Pin documented sizes: publicKey = pk_pq(1184) ‖ pk_trad(32) = 1216.
        XCTAssertEqual(keyPair.publicKey.bytes.count, 1216, "recipientPublicKey must be 1216 bytes (pk_pq‖pk_trad)")

        // Encapsulate (sender side).
        let enc = try await provider.kemEncapsulate(recipientPublicKey: keyPair.publicKey.bytes)

        // KEM ciphertext = ct_pq(1088) ‖ ct_trad(32) = 1120.
        XCTAssertEqual(enc.encapsulatedKey.count, 1120, "encapsulatedKey must be 1120 bytes (ct_pq‖ct_trad)")

        // Decapsulate (recipient side) using the provider's private blob, wrapped
        // into SecureBytes exactly as the protocol expects.
        let recipientPrivate = SecureBytes(data: keyPair.privateKey.bytes)
        let ss2 = try await provider.kemDecapsulate(
            encapsulatedKey: enc.encapsulatedKey,
            privateKey: recipientPrivate
        )

        // Both shared secrets must be 32 bytes.
        let ssSender = enc.sharedSecret.data
        let ssRecipient = ss2.data
        XCTAssertEqual(ssSender.count, 32, "sender shared secret must be 32 bytes")
        XCTAssertEqual(ssRecipient.count, 32, "recipient shared secret must be 32 bytes")

        // Self-consistency: the two derived secrets are byte-identical.
        XCTAssertEqual(ssSender, ssRecipient, "encaps and decaps must derive the same shared secret")

        // Sanity: not the all-zero secret.
        XCTAssertNotEqual(ssSender, Data(repeating: 0, count: 32), "shared secret must be non-zero")
    }

    /// DEM round-trip: seal a message with the KEM-DEM API, then open it with the
    /// matching private blob and the SAME `info`, and assert the recovered
    /// plaintext equals the original. Also asserts the exported shared secrets on
    /// both sides agree.
    func testQPeriaptDEMRoundTrip() async throws {
        let provider = QPeriaptCryptoProvider()

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)

        let message = Data("Q-Periapt in-process DEM self-consistency 🔒".utf8)
        let info = Data("skybridge-qperiapt-roundtrip-test/v1".utf8)

        // Seal (sender side): KEM-DEM with exported shared secret.
        let sealed = try await provider.kemDemSealWithSecret(
            plaintext: message,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )

        // Open (recipient side) with the matching private blob and the SAME info.
        let recipientPrivate = SecureBytes(data: keyPair.privateKey.bytes)
        let opened = try await provider.kemDemOpenWithSecret(
            sealedBox: sealed.sealedBox,
            privateKey: recipientPrivate,
            info: info
        )

        XCTAssertEqual(opened.plaintext, message, "recovered plaintext must equal the original message")

        // The exported shared secrets on both sides must agree (32 bytes).
        XCTAssertEqual(sealed.sharedSecret.data.count, 32)
        XCTAssertEqual(sealed.sharedSecret.data, opened.sharedSecret.data, "seal/open must export the same shared secret")
    }

    /// Negative control: tampering the sealed ciphertext must make `open` throw
    /// (AES-GCM authentication failure). Proves the DEM is actually
    /// authenticating, not just XOR-ing bytes.
    func testQPeriaptDEMTamperedCiphertextThrows() async throws {
        let provider = QPeriaptCryptoProvider()

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        let message = Data("tamper me".utf8)
        let info = Data("skybridge-qperiapt-roundtrip-test/v1".utf8)

        let sealed = try await provider.kemDemSealWithSecret(
            plaintext: message,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )

        // Flip one bit in the ciphertext.
        var tamperedCiphertext = sealed.sealedBox.ciphertext
        XCTAssertFalse(tamperedCiphertext.isEmpty, "ciphertext must be non-empty to tamper")
        let idx = tamperedCiphertext.startIndex
        tamperedCiphertext[idx] ^= 0x01

        let tamperedBox = HPKESealedBox(
            encapsulatedKey: sealed.sealedBox.encapsulatedKey,
            nonce: sealed.sealedBox.nonce,
            ciphertext: tamperedCiphertext,
            tag: sealed.sealedBox.tag
        )

        let recipientPrivate = SecureBytes(data: keyPair.privateKey.bytes)
        do {
            _ = try await provider.kemDemOpenWithSecret(
                sealedBox: tamperedBox,
                privateKey: recipientPrivate,
                info: info
            )
            XCTFail("opening a tampered ciphertext must throw")
        } catch {
            // Expected: AES-GCM auth failure (any thrown error is acceptable here).
        }
    }
}

#endif
