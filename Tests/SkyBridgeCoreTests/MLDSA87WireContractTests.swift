import XCTest
@testable import SkyBridgeProtocolCore

final class MLDSA87WireContractTests: XCTestCase {
    private static let mlDSA87PublicKeyLength = 2_592
    private static let mlDSA87SignatureLength = 4_627

    func testAlgorithmCodesPreserveExistingAssignmentsAndAddMLDSA87() {
        XCTAssertEqual(SignatureAlgorithm.ed25519.wireCode, 0x0001)
        XCTAssertEqual(SignatureAlgorithm.mlDSA65.wireCode, 0x0002)
        XCTAssertEqual(SignatureAlgorithm.p256ECDSA.wireCode, 0x0003)
        XCTAssertEqual(SignatureAlgorithm.mlDSA87.wireCode, 0x0004)

        XCTAssertEqual(ProtocolSigningAlgorithm.ed25519.wireCode, 0x0001)
        XCTAssertEqual(ProtocolSigningAlgorithm.mlDSA65.wireCode, 0x0002)
        XCTAssertEqual(ProtocolSigningAlgorithm.mlDSA87.wireCode, 0x0004)
        XCTAssertEqual(ProtocolSigningAlgorithm(from: .mlDSA87), .mlDSA87)
        XCTAssertEqual(ProtocolSigningAlgorithm.mlDSA87.wire, .mlDSA87)
        XCTAssertNil(ProtocolSigningAlgorithm(from: .p256ECDSA))
    }

    func testIdentityPublicKeysMLDSA87UsesCanonicalIdentityByte() throws {
        let publicKey = Data(repeating: 0xA1, count: Self.mlDSA87PublicKeyLength)
        let identity = IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: .mlDSA87
        )

        var expected = Data([0x04, 0x20, 0x0A])
        expected.append(publicKey)
        expected.append(0x00)
        XCTAssertEqual(identity.encoded, expected)
        XCTAssertEqual(try IdentityPublicKeys.decode(from: identity.encoded), identity)
        XCTAssertEqual(
            try IdentityPublicKeys.decodeWithLegacyFallback(from: identity.encoded),
            identity
        )
    }

    func testIdentityPublicKeysRejectsUnknownAndNonCanonicalWireValues() {
        let canonical = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0xA1, count: Self.mlDSA87PublicKeyLength),
            protocolAlgorithm: .mlDSA87
        ).encoded

        var unknownAlgorithm = canonical
        unknownAlgorithm[0] = 0x05
        assertInvalidFormat("Unknown signature algorithm: 5") {
            _ = try IdentityPublicKeys.decode(from: unknownAlgorithm)
        }

        var invalidPresenceMarker = canonical
        invalidPresenceMarker[invalidPresenceMarker.count - 1] = 0x02
        assertInvalidFormat("Invalid SE key presence marker: 2") {
            _ = try IdentityPublicKeys.decode(from: invalidPresenceMarker)
        }

        var trailingByte = canonical
        trailingByte.append(0x00)
        assertInvalidFormat("IdentityPublicKeys trailing bytes") {
            _ = try IdentityPublicKeys.decode(from: trailingByte)
        }
    }

    func testIdentityPublicKeyLengthsAreExactForEveryProtocolAlgorithm() throws {
        let cases: [(SignatureAlgorithm, Int)] = [
            (.ed25519, 32),
            (.mlDSA65, 1_952),
            (.mlDSA87, 2_592),
        ]

        for (algorithm, expectedLength) in cases {
            let exact = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xA5, count: expectedLength),
                protocolAlgorithm: algorithm
            )
            XCTAssertEqual(try IdentityPublicKeys.decode(from: exact.encoded), exact)

            for invalidLength in [expectedLength - 1, expectedLength + 1] {
                let invalid = IdentityPublicKeys(
                    protocolPublicKey: Data(repeating: 0xA5, count: invalidLength),
                    protocolAlgorithm: algorithm
                )
                assertInvalidFormat(
                    "Invalid \(algorithm.rawValue) public key length: expected \(expectedLength), got \(invalidLength)"
                ) {
                    _ = try IdentityPublicKeys.decode(from: invalid.encoded)
                }
            }
        }
    }

    func testAlgorithmByteTamperFailsAtIdentityDecodeAndConversionBoundaries() {
        let publicKey = Data(repeating: 0x87, count: Self.mlDSA87PublicKeyLength)
        let mlDSA87 = IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: .mlDSA87
        )
        var tamperedWire = mlDSA87.encoded
        tamperedWire[0] = 0x02
        let expectedError = "Invalid ML-DSA-65 public key length: expected 1952, got 2592"
        assertInvalidFormat(expectedError) {
            _ = try IdentityPublicKeys.decode(from: tamperedWire)
        }
        assertInvalidFormat(expectedError) {
            _ = try IdentityPublicKeys(
                protocolPublicKey: publicKey,
                protocolAlgorithm: .mlDSA65
            ).asProtocolIdentityKeys()
        }
    }

    func testMLDSA87MessageAFitsNewBoundButExceedsLegacyEightKiB() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)

        XCTAssertGreaterThan(message.encoded.count, 8 * 1024)
        XCTAssertLessThanOrEqual(message.encoded.count, HandshakeConstants.maxMessageALength)
        XCTAssertEqual(HandshakeConstants.maxMessageALength, 16 * 1024)

        let decoded = try HandshakeMessageA.decode(from: message.encoded)
        XCTAssertEqual(decoded.signature.count, Self.mlDSA87SignatureLength)
        XCTAssertEqual(try decoded.decodedIdentityPublicKeys().protocolAlgorithm, .mlDSA87)
    }

    func testMLDSA87MessageARejectsOffByOneSignatureLengths() {
        for invalidLength in [
            Self.mlDSA87SignatureLength - 1,
            Self.mlDSA87SignatureLength + 1,
        ] {
            let message = makeMLDSA87MessageA(signatureLength: invalidLength)
            assertInvalidFormat(
                "ML-DSA-87 signature must be exactly 4627 bytes, got \(invalidLength)"
            ) {
                _ = try HandshakeMessageA.decode(from: message.encoded)
            }
        }
    }

    func testMLDSA87MessageBRequiresExactSignatureLength() throws {
        let exact = makeMLDSA87MessageB(signatureLength: Self.mlDSA87SignatureLength)
        XCTAssertEqual(
            try HandshakeMessageB.decode(from: exact.encoded).signature.count,
            Self.mlDSA87SignatureLength
        )

        for invalidLength in [
            Self.mlDSA87SignatureLength - 1,
            Self.mlDSA87SignatureLength + 1,
        ] {
            let invalid = makeMLDSA87MessageB(signatureLength: invalidLength)
            assertInvalidFormat(
                "ML-DSA-87 signature must be exactly 4627 bytes, got \(invalidLength)"
            ) {
                _ = try HandshakeMessageB.decode(from: invalid.encoded)
            }
        }
    }

    func testMessageARejectsPayloadAboveSixteenKiB() {
        let oversized = Data(repeating: 0x00, count: HandshakeConstants.maxMessageALength + 1)
        assertInvalidFormat("MessageA exceeds maximum length") {
            _ = try HandshakeMessageA.decode(from: oversized)
        }
    }

    func testMessageACapabilitiesRejectUnboundedCountsAndStringLengths() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)
        let capabilitiesWire = try message.capabilities.deterministicEncode()
        let capabilitiesRange = try XCTUnwrap(message.encoded.range(of: capabilitiesWire))

        var excessiveCount = message.encoded
        excessiveCount.replaceSubrange(
            capabilitiesRange.lowerBound..<(capabilitiesRange.lowerBound + 4),
            with: [0xff, 0xff, 0xff, 0xff]
        )
        assertInvalidMessageA(excessiveCount)

        var excessiveString = message.encoded
        excessiveString.replaceSubrange(
            (capabilitiesRange.lowerBound + 4)..<(capabilitiesRange.lowerBound + 8),
            with: [0x01, 0x02, 0x00, 0x00] // 513 bytes
        )
        assertInvalidMessageA(excessiveString)

        let aggregateOversize = CryptoCapabilities(
            supportedKEM: Array(repeating: String(repeating: "K", count: 512), count: 9),
            supportedSignature: [],
            supportedAuthProfiles: [],
            supportedAEAD: [],
            pqcAvailable: true,
            platformVersion: "26.0",
            providerType: .cryptoKitPQC
        )
        let aggregateMessage = makeMLDSA87MessageA(
            signatureLength: Self.mlDSA87SignatureLength,
            capabilities: aggregateOversize
        )
        XCTAssertLessThanOrEqual(aggregateMessage.encoded.count, HandshakeConstants.maxMessageALength)
        assertInvalidMessageA(aggregateMessage.encoded)
    }

    func testMessageARejectsNonCanonicalCapabilityAndPolicyBooleans() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)
        let capabilitiesWire = try message.capabilities.deterministicEncode()
        let capabilitiesRange = try XCTUnwrap(message.encoded.range(of: capabilitiesWire))

        var capabilityAlias = message.encoded
        capabilityAlias[
            capabilitiesRange.lowerBound + capabilitiesBooleanOffset(message.capabilities)
        ] = 0x02
        assertInvalidMessageA(capabilityAlias)

        let policyWire = message.policy.deterministicEncode()
        let policyRange = try XCTUnwrap(message.encoded.range(of: policyWire))
        var policyAlias = message.encoded
        policyAlias[policyRange.lowerBound + 1] = 0x02
        assertInvalidMessageA(policyAlias)
    }

    func testMessageALegacyPolicyEncodingPreservesExactSignedWire() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)
        let currentPolicy = message.policy.deterministicEncode()
        let policyRange = try XCTUnwrap(message.encoded.range(of: currentPolicy))
        XCTAssertGreaterThan(currentPolicy.count, 0)

        var legacyWire = message.encoded
        legacyWire.remove(at: policyRange.upperBound - 1)
        writeUInt16LE(
            UInt16(currentPolicy.count - 1),
            to: &legacyWire,
            at: policyRange.lowerBound - 2
        )

        let decoded = try HandshakeMessageA.decode(from: legacyWire)
        XCTAssertFalse(decoded.policy.requireSecureEnclavePoP)
        XCTAssertEqual(decoded.encoded, legacyWire)

        var expectedUnsigned = message.encodedWithoutSignature()
        expectedUnsigned.remove(at: policyRange.upperBound - 1)
        writeUInt16LE(
            UInt16(currentPolicy.count - 1),
            to: &expectedUnsigned,
            at: policyRange.lowerBound - 2
        )
        XCTAssertEqual(decoded.encodedWithoutSignature(), expectedUnsigned)
        XCTAssertEqual(decoded.transcriptBytes, expectedUnsigned)
    }

    func testMessageBRejectsNonCanonicalInnerHeaderAliases() throws {
        let message = makeMLDSA87MessageB(signatureLength: Self.mlDSA87SignatureLength)
        let payload = message.encryptedPayload.combinedWithHeader(suite: message.selectedSuite)
        let payloadRange = try XCTUnwrap(message.encoded.range(of: payload))

        var wrongInnerSuite = message.encoded
        wrongInnerSuite[payloadRange.lowerBound + 5] ^= 0x01
        assertInvalidMessageB(wrongInnerSuite)

        var nonzeroReservedFlags = message.encoded
        nonzeroReservedFlags[payloadRange.lowerBound + 7] = 0x01
        assertInvalidMessageB(nonzeroReservedFlags)

        var versionAlias = message.encoded
        versionAlias[payloadRange.lowerBound + 4] = 0x02
        XCTAssertThrowsError(try HandshakeMessageB.decode(from: versionAlias))
    }

    func testMessageBCanonicalNativeHPKEV2RemainsSupported() throws {
        let message = HandshakeMessageB(
            selectedSuite: .mlkem768MLDSA65,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x51, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: Data(repeating: 0x52, count: 32),
                nonce: Data(),
                ciphertext: Data(repeating: 0x53, count: 64),
                tag: Data()
            ),
            signature: Data(repeating: 0x54, count: Self.mlDSA87SignatureLength),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x55, count: Self.mlDSA87PublicKeyLength),
                protocolAlgorithm: .mlDSA87
            )
        )

        let decoded = try HandshakeMessageB.decode(from: message.encoded)
        XCTAssertEqual(decoded.encoded, message.encoded)
        XCTAssertEqual(
            decoded.encryptedPayload.combinedWithHeader(suite: decoded.selectedSuite)[4],
            0x02
        )
    }

    private func makeMLDSA87MessageA(
        signatureLength: Int,
        capabilities: CryptoCapabilities? = nil
    ) -> HandshakeMessageA {
        HandshakeMessageA(
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            keyShares: [
                HandshakeKeyShare(
                    suite: .mlkem768MLDSA65FS,
                    shareBytes: Data(repeating: 0x31, count: 1_088)
                ),
                HandshakeKeyShare(
                    suite: .mlkem768MLDSA65,
                    shareBytes: Data(repeating: 0x32, count: 1_088)
                ),
            ],
            clientNonce: Data(repeating: 0x33, count: 32),
            policy: .default,
            capabilities: capabilities ?? CryptoCapabilities(
                supportedKEM: ["ML-KEM-768"],
                supportedSignature: ["ML-DSA-87"],
                supportedAuthProfiles: [AuthProfile.pqc.displayName],
                supportedAEAD: ["AES-GCM"],
                pqcAvailable: true,
                platformVersion: "26.0",
                providerType: .cryptoKitPQC
            ),
            signature: Data(repeating: 0x34, count: signatureLength),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x35, count: Self.mlDSA87PublicKeyLength),
                protocolAlgorithm: .mlDSA87
            ),
            initiatorContribution: Data(repeating: 0x36, count: 32)
        )
    }

    private func capabilitiesBooleanOffset(_ capabilities: CryptoCapabilities) -> Int {
        var encoder = DeterministicEncoder()
        encoder.encode(capabilities.supportedKEM)
        encoder.encode(capabilities.supportedSignature)
        encoder.encode(capabilities.supportedAuthProfiles)
        encoder.encode(capabilities.supportedAEAD)
        return encoder.finalize().count
    }

    private func writeUInt16LE(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8(value >> 8)
    }

    private func assertInvalidMessageA(
        _ wire: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try HandshakeMessageA.decode(from: wire),
            file: file,
            line: line
        ) { error in
            guard case HandshakeError.failed(.invalidMessageFormat) = error else {
                XCTFail("Expected invalidMessageFormat, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertInvalidMessageB(
        _ wire: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try HandshakeMessageB.decode(from: wire),
            file: file,
            line: line
        ) { error in
            guard case HandshakeError.failed(.invalidMessageFormat) = error else {
                XCTFail("Expected invalidMessageFormat, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func makeMLDSA87MessageB(signatureLength: Int) -> HandshakeMessageB {
        HandshakeMessageB(
            selectedSuite: .mlkem768MLDSA65,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x41, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: Data(),
                nonce: Data(repeating: 0x42, count: 12),
                ciphertext: Data(repeating: 0x43, count: 64),
                tag: Data(repeating: 0x44, count: 16)
            ),
            signature: Data(repeating: 0x45, count: signatureLength),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x46, count: Self.mlDSA87PublicKeyLength),
                protocolAlgorithm: .mlDSA87
            )
        )
    }

    private func assertInvalidFormat(
        _ expectedMessage: String,
        _ expression: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case HandshakeError.failed(.invalidMessageFormat(let message)) = error else {
                XCTFail("Expected invalidMessageFormat, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(message, expectedMessage, file: file, line: line)
        }
    }
}
