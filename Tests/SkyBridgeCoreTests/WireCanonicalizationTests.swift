import XCTest
@testable import SkyBridgeCore

final class WireCanonicalizationTests: XCTestCase {
    private func makeMessageA(extensionsRaw: Data = Data()) -> HandshakeMessageA {
        let nonce = Data(repeating: 0x11, count: 32)
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: false,
            platformVersion: "test",
            providerType: .classic
        )
        let policy = HandshakePolicy(
            requirePQC: false,
            allowClassicFallback: true,
            minimumTier: .classic,
            requireSecureEnclavePoP: false
        )
        let identity = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x22, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        let keyShare = HandshakeKeyShare(
            suite: .x25519Ed25519,
            shareBytes: Data(repeating: 0x33, count: 32)
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [keyShare],
            clientNonce: nonce,
            policy: policy,
            capabilities: capabilities,
            signature: Data(repeating: 0x44, count: 64),
            identityPublicKeys: identity,
            extensionsRaw: extensionsRaw
        )
    }

    private func makeTLV(type: UInt16, value: Data) -> Data {
        var raw = Data()
        raw.append(UInt8(type & 0xFF))
        raw.append(UInt8((type >> 8) & 0xFF))
        raw.append(UInt8(value.count & 0xFF))
        raw.append(UInt8((value.count >> 8) & 0xFF))
        raw.append(value)
        return raw
    }

    func testMessageAWithoutExtensionsIsByteStable() throws {
        let message = makeMessageA()
        let encoded = message.encoded
        let decoded = try HandshakeMessageA.decode(from: encoded)
        let reencoded = decoded.encoded

        XCTAssertEqual(reencoded, encoded)
        XCTAssertEqual(decoded.transcriptBytes, message.transcriptBytes)
    }

    func testMessageAUnknownTLVPassthroughIsByteStable() throws {
        let unknownA = makeTLV(type: 0x7001, value: Data([0xAA, 0xBB, 0xCC]))
        let unknownB = makeTLV(type: 0x7002, value: Data([0x10, 0x20]))
        let raw = unknownA + unknownB
        let message = makeMessageA(extensionsRaw: raw)

        let encoded = message.encoded
        let decoded = try HandshakeMessageA.decode(from: encoded)
        let reencoded = decoded.encoded

        XCTAssertEqual(decoded.extensionsRaw, raw)
        XCTAssertEqual(reencoded, encoded)
        XCTAssertEqual(decoded.transcriptBytes, message.transcriptBytes)
    }

    func testMessageAUnknownTLVAndSOAPassthroughPreservesRawOrder() throws {
        let initiatorPeerId = Data(repeating: 0x01, count: 32)
        let targetPeerId = Data(repeating: 0x02, count: 32)
        let attemptId = Data(repeating: 0x03, count: 16)
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        )

        let unknownPrefix = makeTLV(type: 0x7A01, value: Data([0x0A, 0x0B]))
        let unknownSuffix = makeTLV(type: 0x7A02, value: Data([0x0C, 0x0D, 0x0E]))
        let raw = unknownPrefix + soa.encodedTLV + unknownSuffix
        let message = makeMessageA(extensionsRaw: raw)

        let decoded = try HandshakeMessageA.decode(from: message.encoded)
        XCTAssertEqual(decoded.extensionsRaw, raw)
        XCTAssertEqual(decoded.soaExtension?.initiatorPeerId, initiatorPeerId)
        XCTAssertEqual(decoded.soaExtension?.targetPeerId, targetPeerId)
        XCTAssertEqual(decoded.soaExtension?.attemptId, attemptId)

        let reencoded = decoded.encoded
        XCTAssertEqual(reencoded, message.encoded)
    }

    func testMalformedExtensionsTLVIsRejected() {
        // type + len(4) + value(2) with claimed length=3 -> malformed TLV.
        var malformed = Data([0x34, 0x12, 0x03, 0x00, 0xAA, 0xBB])
        let message = makeMessageA(extensionsRaw: malformed)
        var encoded = message.encoded

        let extMagic = Data([0x53, 0x4F, 0x41, 0x31])
        XCTAssertTrue(encoded.contains(extMagic))

        // Keep bytes as produced by encoder; decoder should reject malformed TLV value section.
        // We intentionally patch extension payload to malformed bytes while preserving container length.
        if let magicRange = encoded.range(of: extMagic) {
            let lenOffset = magicRange.upperBound
            let extLen = Int(encoded[lenOffset]) | (Int(encoded[lenOffset + 1]) << 8)
            let payloadStart = lenOffset + 2
            let payloadEnd = payloadStart + extLen
            encoded.replaceSubrange(payloadStart..<payloadEnd, with: malformed.prefix(extLen))
        }

        XCTAssertThrowsError(try HandshakeMessageA.decode(from: encoded))
        malformed.removeAll(keepingCapacity: false)
    }
}
