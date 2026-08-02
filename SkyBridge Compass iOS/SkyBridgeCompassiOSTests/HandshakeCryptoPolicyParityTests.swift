import XCTest
import Darwin
import CryptoKit
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class HandshakeCryptoPolicyParityTests: XCTestCase {
    private static let mlDSA87PublicKeyLength = 2_592
    private static let mlDSA87SignatureLength = 4_627

    @MainActor
    func testCorePolicySwitchPublishesAtomicallyAndRetriesAfterIdentityFailure() async throws {
        let probe = InitializationIdentityResolverProbe()
        let core = SkyBridgeiOSCore { algorithm, _ in
            try await probe.resolve(algorithm: algorithm)
        }

        try await core.initialize(policy: .classicOnly)
        XCTAssertTrue(core.isInitialized)
        XCTAssertEqual(core.cryptoProvider?.tier, .classic)
        XCTAssertEqual(core.signatureProvider?.signatureAlgorithm, .ed25519)
        XCTAssertFalse(core.handshakePolicy.requirePQC)

        do {
            try await core.initialize(
                policy: .requirePQC,
                providerOverride: MockNativeHybridProvider()
            )
            XCTFail("The injected first PQC identity resolution must fail")
        } catch is InjectedInitializationIdentityError {
            // Expected. The prior complete classic configuration must remain.
        }
        XCTAssertTrue(core.isInitialized)
        XCTAssertEqual(core.cryptoProvider?.tier, .classic)
        XCTAssertEqual(core.signatureProvider?.signatureAlgorithm, .ed25519)
        XCTAssertFalse(core.handshakePolicy.requirePQC)

        try await core.initialize(
            policy: .requirePQC,
            providerOverride: MockNativeHybridProvider()
        )
        let pqcAttemptCount = await probe.pqcAttemptCount()
        XCTAssertEqual(pqcAttemptCount, 2)
        XCTAssertEqual(core.cryptoProvider?.tier, .nativePQC)
        XCTAssertEqual(core.signatureProvider?.signatureAlgorithm, .mlDSA65)
        XCTAssertTrue(core.handshakePolicy.requirePQC)
    }

    @MainActor
    func testLatestInitializationRequestSupersedesSuspendedPolicyChange() async throws {
        let gate = SupersedingInitializationIdentityResolver()
        let core = SkyBridgeiOSCore { algorithm, _ in
            try await gate.resolve(algorithm: algorithm)
        }
        try await core.initialize(
            policy: .classicOnly,
            providerOverride: ClassicCryptoProvider()
        )

        let suspendedPQCRequest = Task { @MainActor in
            try await core.initialize(
                policy: .requirePQC,
                providerOverride: MockNativeHybridProvider()
            )
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await gate.waitUntilPQCResolutionStarted()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw InitializationResolutionTimeout()
            }
            _ = try await group.next()
            group.cancelAll()
        }

        // This request matches the currently published classic state, but it
        // is still the newest configuration request and must invalidate the
        // suspended PQC attempt before returning a coherent classic snapshot.
        try await core.initialize(policy: .classicOnly)
        await gate.resumePQCResolution()

        do {
            try await suspendedPQCRequest.value
            XCTFail("A superseded initialization attempt must not publish")
        } catch {
            guard case SkyBridgeError.handshakeFailed(let reason) = error else {
                throw error
            }
            XCTAssertEqual(
                reason,
                "Core initialization was superseded by a newer configuration request"
            )
        }
        XCTAssertTrue(core.isInitialized)
        XCTAssertEqual(core.cryptoProvider?.tier, .classic)
        XCTAssertEqual(core.signatureProvider?.signatureAlgorithm, .ed25519)
        XCTAssertFalse(core.handshakePolicy.requirePQC)
    }

    func testMLDSA87WireContractAndCanonicalIdentityEncoding() throws {
        XCTAssertEqual(SignatureAlgorithm.ed25519.wireCode, 0x0001)
        XCTAssertEqual(SignatureAlgorithm.mlDSA65.wireCode, 0x0002)
        XCTAssertEqual(SignatureAlgorithm.p256ECDSA.wireCode, 0x0003)
        XCTAssertEqual(SignatureAlgorithm.mlDSA87.wireCode, 0x0004)
        XCTAssertEqual(ProtocolSigningAlgorithm.mlDSA87.wireCode, 0x0004)
        XCTAssertEqual(ProtocolSigningAlgorithm(from: .mlDSA87), .mlDSA87)

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
    }

    func testMLDSA87IdentityWireRejectsUnknownAndTamperedFraming() {
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

    func testMLDSA87AlgorithmByteTamperFailsAtIdentityBoundaries() {
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

    func testMLDSA87MessageAFitsSixteenKiBBoundAndOversizeFailsClosed() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)

        XCTAssertEqual(HandshakeConstants.maxMessageALength, 16 * 1024)
        XCTAssertGreaterThan(message.encoded.count, 8 * 1024)
        XCTAssertLessThanOrEqual(message.encoded.count, HandshakeConstants.maxMessageALength)
        XCTAssertEqual(
            try HandshakeMessageA.decode(from: message.encoded).decodedIdentityPublicKeys().protocolAlgorithm,
            .mlDSA87
        )

        for invalidLength in [
            Self.mlDSA87SignatureLength - 1,
            Self.mlDSA87SignatureLength + 1,
        ] {
            let invalid = makeMLDSA87MessageA(signatureLength: invalidLength)
            assertInvalidFormat(
                "ML-DSA-87 signature must be exactly 4627 bytes, got \(invalidLength)"
            ) {
                _ = try HandshakeMessageA.decode(from: invalid.encoded)
            }
        }

        let oversized = Data(repeating: 0x00, count: HandshakeConstants.maxMessageALength + 1)
        assertInvalidFormat("MessageA exceeds maximum length") {
            _ = try HandshakeMessageA.decode(from: oversized)
        }
    }

    func testMLDSA87MessageAReassemblesAcrossEightKiBWebRTCControlChunks() throws {
        let message = makeMLDSA87MessageA(signatureLength: Self.mlDSA87SignatureLength)
        let payload = try HandshakePadding.wrapIfEnabled(
            message.encoded,
            label: "test/webrtc",
            maximumPaddingTargetByteCount: CrossNetworkWebRTCHandshakeLimits.maxPaddedPayloadBytes
        )
        var framed = Data()
        var payloadLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &payloadLength) { framed.append(contentsOf: $0) }
        framed.append(payload)

        XCTAssertGreaterThan(framed.count, CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes)
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(
            maxInboundFrameBytes: HandshakeConstants.maxMessageALength + 8
        )
        var recovered: Data?
        var offset = 0
        var chunkCount = 0
        while offset < framed.count {
            let end = min(
                offset + CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes,
                framed.count
            )
            let chunk = Data(framed[offset..<end])
            XCTAssertLessThanOrEqual(
                chunk.count,
                CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes
            )
            parser.append(chunk)
            if let parsed = parser.nextPayload(
                sessionId: "ml-dsa-87-fragment-contract",
                logLabel: "WebRTC"
            ) {
                XCTAssertNil(recovered)
                recovered = parsed
            }
            chunkCount += 1
            offset = end
        }

        XCTAssertGreaterThanOrEqual(chunkCount, 2)
        XCTAssertEqual(recovered, payload)
        let decoded = try HandshakeMessageA.decode(
            from: HandshakePadding.unwrapIfNeeded(recovered ?? Data())
        )
        XCTAssertEqual(
            try decoded.decodedIdentityPublicKeys().protocolAlgorithm,
            .mlDSA87
        )
    }

    func testMLDSA87MessageADecoderConsumesOptionalSecureEnclaveSignatureExactly() throws {
        let withoutSecureEnclaveSignature = makeMLDSA87MessageA(
            signatureLength: Self.mlDSA87SignatureLength
        )
        XCTAssertNil(
            try HandshakeMessageA.decode(from: withoutSecureEnclaveSignature.encoded)
                .secureEnclaveSignature
        )

        let secureEnclaveSignature = Data(repeating: 0x5e, count: 64)
        let withSecureEnclaveSignature = makeMLDSA87MessageA(
            signatureLength: Self.mlDSA87SignatureLength,
            secureEnclaveSignature: secureEnclaveSignature
        )
        XCTAssertEqual(
            try HandshakeMessageA.decode(from: withSecureEnclaveSignature.encoded)
                .secureEnclaveSignature,
            secureEnclaveSignature
        )

        var trailingByte = withoutSecureEnclaveSignature.encoded
        trailingByte.append(0)
        assertInvalidFormat("MessageA trailing bytes") {
            _ = try HandshakeMessageA.decode(from: trailingByte)
        }

        var truncatedSecureEnclaveSignature = withSecureEnclaveSignature.encoded
        truncatedSecureEnclaveSignature.removeLast()
        assertInvalidFormat("Secure Enclave signature truncated") {
            _ = try HandshakeMessageA.decode(from: truncatedSecureEnclaveSignature)
        }
    }

    func testMLDSA87MessageADecoderRejectsMalformedExtensionTLVContainer() throws {
        let truncatedHeader = makeMLDSA87MessageA(
            signatureLength: Self.mlDSA87SignatureLength,
            extensionsRaw: Data([0x01, 0x00, 0x01])
        )
        assertInvalidFormat("Extensions TLV header truncated") {
            _ = try HandshakeMessageA.decode(from: truncatedHeader.encoded)
        }

        let truncatedValue = makeMLDSA87MessageA(
            signatureLength: Self.mlDSA87SignatureLength,
            extensionsRaw: Data([0x01, 0x00, 0x02, 0x00, 0xaa])
        )
        assertInvalidFormat("Extensions TLV value truncated") {
            _ = try HandshakeMessageA.decode(from: truncatedValue.encoded)
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

    func testMLDSA87MessageBDecoderAcceptsExactMaximumAndRejectsOneByteOver() throws {
        let baseline = makeMLDSA87MessageB(
            signatureLength: Self.mlDSA87SignatureLength,
            ciphertextLength: 64
        )
        let additionalCiphertextBytes = HandshakeConstants.maxMessageBLength
            - baseline.encoded.count
        XCTAssertGreaterThan(additionalCiphertextBytes, 0)

        let exactMaximum = makeMLDSA87MessageB(
            signatureLength: Self.mlDSA87SignatureLength,
            ciphertextLength: 64 + additionalCiphertextBytes
        ).encoded
        XCTAssertEqual(exactMaximum.count, HandshakeConstants.maxMessageBLength)
        XCTAssertEqual(
            try HandshakeMessageB.decode(from: exactMaximum).signature.count,
            Self.mlDSA87SignatureLength
        )

        var oneByteOver = exactMaximum
        oneByteOver.append(0)
        assertInvalidFormat("MessageB exceeds maximum length") {
            _ = try HandshakeMessageB.decode(from: oneByteOver)
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
            selectedSuite: .mlkem768,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x51, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: Data(repeating: 0x52, count: 32),
                ciphertext: Data(repeating: 0x53, count: 64),
                tag: Data(),
                nonce: Data()
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
        capabilities: CryptoCapabilities? = nil,
        extensionsRaw: Data = Data(),
        secureEnclaveSignature: Data? = nil
    ) -> HandshakeMessageA {
        HandshakeMessageA(
            supportedSuites: [.mlkem768fs, .mlkem768],
            keyShares: [
                HandshakeKeyShare(
                    suite: .mlkem768fs,
                    shareBytes: Data(repeating: 0x31, count: 1_088)
                ),
                HandshakeKeyShare(
                    suite: .mlkem768,
                    shareBytes: Data(repeating: 0x32, count: 1_088)
                ),
            ],
            clientNonce: Data(repeating: 0x33, count: HandshakeConstants.nonceSize),
            policy: .strictPQC,
            capabilities: capabilities ?? CryptoCapabilities(),
            signature: Data(repeating: 0x34, count: signatureLength),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x35, count: Self.mlDSA87PublicKeyLength),
                protocolAlgorithm: .mlDSA87
            ),
            extensionsRaw: extensionsRaw,
            initiatorContribution: Data(repeating: 0x36, count: 32),
            secureEnclaveSignature: secureEnclaveSignature
        )
    }

    private func capabilitiesBooleanOffset(_ capabilities: CryptoCapabilities) -> Int {
        var encoder = DeterministicEncoder()
        encoder.encodeStringArray(capabilities.supportedKEM)
        encoder.encodeStringArray(capabilities.supportedSignature)
        encoder.encodeStringArray(capabilities.supportedAuthProfiles)
        encoder.encodeStringArray(capabilities.supportedAEAD)
        return encoder.data.count
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

    private func makeMLDSA87MessageB(
        signatureLength: Int,
        ciphertextLength: Int = 64
    ) -> HandshakeMessageB {
        HandshakeMessageB(
            selectedSuite: .mlkem768,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x41, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: Data(),
                ciphertext: Data(repeating: 0x43, count: ciphertextLength),
                tag: Data(repeating: 0x44, count: 16),
                nonce: Data(repeating: 0x42, count: 12)
            ),
            signature: Data(repeating: 0x45, count: signatureLength),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x46, count: Self.mlDSA87PublicKeyLength),
                protocolAlgorithm: .mlDSA87
            )
        )
    }

    func testPrepareAttemptForXWingCarriesHybridCryptoPolicy() throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: AppleXWingCryptoProvider()
        )

        XCTAssertEqual(preparation.offeredSuites, [.xwing])
        XCTAssertEqual(preparation.cryptoPolicy.minimumSecurityTier, .hybridPreferred)
        XCTAssertTrue(preparation.cryptoPolicy.allowExperimentalHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.advertiseHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.requireHybridIfAvailable)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testPrepareAttemptCompatibilityRetryDropsToPurePQCWhenXWingWasPreferred() throws {
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: MockNativeHybridProvider(),
            pqcOfferMode: .compatRetry
        )

        XCTAssertEqual(preparation.offeredSuites, [.mlkem768])
        XCTAssertEqual(preparation.cryptoPolicy, .default)
    }

    func testPeerScopedMLDSA87SelectionRequiresAuthenticatedRawKeyBinding() {
        XCTAssertEqual(
            SkyBridgeiOSCore.peerPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA87,
                hasAuthenticatedMLDSA87Binding: false
            ),
            .mlDSA65
        )
        XCTAssertEqual(
            SkyBridgeiOSCore.peerPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA87,
                hasAuthenticatedMLDSA87Binding: true
            ),
            .mlDSA87
        )
        XCTAssertEqual(
            SkyBridgeiOSCore.peerPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA65,
                hasAuthenticatedMLDSA87Binding: true
            ),
            .mlDSA65
        )
    }

    func testResponderMLDSA87AcceptsExactSessionAuthorityForFirstQRHandshake() throws {
        let messageKey = Data(repeating: 0x87, count: Self.mlDSA87PublicKeyLength)
        XCTAssertEqual(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: messageKey
            ),
            .mlDSA87
        )
    }

    func testResponderMLDSA87RejectsMissingMismatchedAndConflictingAuthorities() throws {
        let messageKey = Data(repeating: 0x87, count: Self.mlDSA87PublicKeyLength)
        let differentKey = Data(repeating: 0x88, count: Self.mlDSA87PublicKeyLength)

        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: nil
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: differentKey
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: messageKey,
                sessionAuthenticatedMLDSA87PublicKey: differentKey
            )
        )
        XCTAssertEqual(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: messageKey,
                sessionAuthenticatedMLDSA87PublicKey: messageKey
            ),
            .mlDSA87
        )
    }

    func testResponderMLDSA87StillRequiresLocal87Policy() throws {
        let messageKey = Data(repeating: 0x87, count: Self.mlDSA87PublicKeyLength)
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: messageKey,
                requestedPQCAlgorithm: .mlDSA65,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: messageKey
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .mlDSA65,
                messagePublicKey: Data(repeating: 0x65, count: 1_952),
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: nil
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.validatedIncomingProtocolSigningAlgorithm(
                messageAlgorithm: .ed25519,
                messagePublicKey: Data(repeating: 0x25, count: 32),
                requestedPQCAlgorithm: .mlDSA87,
                durableAuthenticatedMLDSA87PublicKey: nil,
                sessionAuthenticatedMLDSA87PublicKey: nil
            )
        )
    }

    func testAuthorityBoundCurrentPathMLDSA87NeverDowngradesToMLDSA65() throws {
        XCTAssertThrowsError(
            try SkyBridgeiOSCore.authorityBoundCurrentPathPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA87,
                hasAuthenticatedMLDSA87Binding: false
            )
        )
        XCTAssertEqual(
            try SkyBridgeiOSCore.authorityBoundCurrentPathPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA87,
                hasAuthenticatedMLDSA87Binding: true
            ),
            .mlDSA87
        )
        XCTAssertEqual(
            try SkyBridgeiOSCore.authorityBoundCurrentPathPQCSignatureAlgorithm(
                requestedPQCAlgorithm: .mlDSA65,
                hasAuthenticatedMLDSA87Binding: false
            ),
            .mlDSA65
        )
    }

    func testHandshakeDriverRequiresExactRawAuthorityForMLDSA87() throws {
        let publicKey = Data(repeating: 0x87, count: Self.mlDSA87PublicKeyLength)
        XCTAssertNoThrow(
            try HandshakeDriver.validateExactMLDSA87Authority(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: publicKey,
                trustedPublicKey: publicKey
            )
        )
        XCTAssertThrowsError(
            try HandshakeDriver.validateExactMLDSA87Authority(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: publicKey,
                trustedPublicKey: nil
            )
        )
        XCTAssertThrowsError(
            try HandshakeDriver.validateExactMLDSA87Authority(
                messageAlgorithm: .mlDSA87,
                messagePublicKey: publicKey,
                trustedPublicKey: Data(
                    repeating: 0x88,
                    count: Self.mlDSA87PublicKeyLength
                )
            )
        )
        XCTAssertNoThrow(
            try HandshakeDriver.validateExactMLDSA87Authority(
                messageAlgorithm: .mlDSA65,
                messagePublicKey: Data(repeating: 0x65, count: 1_952),
                trustedPublicKey: nil
            )
        )
    }

    func testPeerScopedProtectionNeverUsesSecureEnclaveForFallbackIdentity() {
        XCTAssertEqual(
            SkyBridgeiOSCore.protocolSigningKeyProtection(
                for: .mlDSA87,
                requestedPQCAlgorithm: .mlDSA87,
                requestedPQCProtection: .secureEnclaveRequired
            ),
            .secureEnclaveRequired
        )
        XCTAssertEqual(
            SkyBridgeiOSCore.protocolSigningKeyProtection(
                for: .mlDSA65,
                requestedPQCAlgorithm: .mlDSA87,
                requestedPQCProtection: .secureEnclaveRequired
            ),
            .softwareKeychain
        )
        XCTAssertEqual(
            SkyBridgeiOSCore.protocolSigningKeyProtection(
                for: .ed25519,
                requestedPQCAlgorithm: .mlDSA87,
                requestedPQCProtection: .secureEnclaveRequired
            ),
            .softwareKeychain
        )
    }

    func testMLDSA87HandshakeCapabilityAdvertisementMatchesActiveIdentity() {
        let capabilities = CryptoCapabilities.fromProvider(
            MockNativeHybridProvider(),
            protocolSigningAlgorithm: .mlDSA87
        )

        XCTAssertEqual(
            capabilities.supportedSignature,
            [
                ProtocolSigningAlgorithm.mlDSA87.rawValue,
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ]
        )
    }

    func testSoftwareAndSecureEnclaveIdentitiesUseDistinctImmutableSlots() throws {
        let software = try ProtocolSigningIdentitySlot(
            algorithm: .mlDSA87,
            keyProtection: .softwareKeychain
        )
        let secureEnclave = try ProtocolSigningIdentitySlot(
            algorithm: .mlDSA87,
            keyProtection: .secureEnclaveRequired
        )

        XCTAssertEqual(software.persistenceAccount, ProtocolSigningAlgorithm.mlDSA87.rawValue)
        XCTAssertNotEqual(software.persistenceAccount, secureEnclave.persistenceAccount)
        XCTAssertTrue(secureEnclave.persistenceAccount.hasPrefix("v2|"))
        XCTAssertThrowsError(
            try ProtocolSigningIdentitySlot(
                algorithm: .ed25519,
                keyProtection: .secureEnclaveRequired
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtocolDeviceIdentityError,
                .unsupportedKeyProtection(.ed25519, .secureEnclaveRequired)
            )
        }
    }

    func testIdentityAuthorityResolvesSoftwareAndSecureEnclaveSlotsIndependently() async throws {
        let persistence = InMemoryProtocolIdentityPersistence()
        let authority = ProtocolDeviceIdentityAuthority {
            persistence
        }
        let softwareMaterial = ProtocolSigningIdentityMaterial(
            algorithm: .mlDSA87,
            privateKey: Data(repeating: 0x11, count: 128),
            publicKey: Data(repeating: 0x12, count: Self.mlDSA87PublicKeyLength),
            keyProtection: .softwareKeychain
        )
        let secureEnclaveMaterial = ProtocolSigningIdentityMaterial(
            algorithm: .mlDSA87,
            privateKey: Data(repeating: 0x21, count: 128),
            publicKey: Data(repeating: 0x22, count: Self.mlDSA87PublicKeyLength),
            keyProtection: .secureEnclaveRequired
        )

        let software = try await authority.resolveSigningIdentity(
            for: .mlDSA87,
            keyProtection: .softwareKeychain,
            generate: { softwareMaterial },
            validate: { material in
                guard material.keyProtection == .softwareKeychain else {
                    throw IdentitySlotValidationError()
                }
            },
            decodeLegacy: { _ in throw IdentitySlotValidationError() }
        )
        let secureEnclave = try await authority.resolveSigningIdentity(
            for: .mlDSA87,
            keyProtection: .secureEnclaveRequired,
            generate: { secureEnclaveMaterial },
            validate: { material in
                guard material.keyProtection == .secureEnclaveRequired else {
                    throw IdentitySlotValidationError()
                }
            },
            decodeLegacy: { _ in throw IdentitySlotValidationError() }
        )

        XCTAssertEqual(software.material, softwareMaterial)
        XCTAssertEqual(secureEnclave.material, secureEnclaveMaterial)
        XCTAssertEqual(Set(persistence.signingKeyAccounts()), Set([
            ProtocolSigningAlgorithm.mlDSA87.rawValue,
            "v2|ML-DSA-87|secure-enclave-required"
        ]))
    }

    func testMLDSA87AttemptNeverFallsBackToClassic() async throws {
        let tracker = SignatureAttemptTracker()
        let provider = MockNativeHybridProvider()

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "ml-dsa-87-no-classic-fallback",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider,
                pqcSignatureAlgorithm: .mlDSA87
            ) { preparation in
                await tracker.record(
                    strategy: preparation.strategy,
                    algorithm: preparation.sigAAlgorithm
                )
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTFail("ML-DSA-87 must fail closed without a classic signature attempt")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }

        let attempts = await tracker.snapshot()
        XCTAssertFalse(attempts.isEmpty)
        XCTAssertTrue(attempts.allSatisfy { $0.strategy == .pqcOnly })
        XCTAssertTrue(attempts.allSatisfy { $0.algorithm == .mlDSA87 })
    }

    func testMLDSA87RejectsDirectClassicRequestBeforeExecutingAttempt() async throws {
        let tracker = AttemptTracker()
        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "ml-dsa-87-direct-classic-rejected",
                preferPQC: false,
                policy: .default,
                cryptoProvider: MockNativeHybridProvider(),
                pqcSignatureAlgorithm: .mlDSA87
            ) { _ in
                _ = await tracker.record([])
                return Self.makeSessionKeys(suite: .p256)
            }
            XCTFail("ML-DSA-87 must never enter a direct classic attempt")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .pqcProviderUnavailable)
        }
        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [])
    }

    @MainActor
    func testRejectedIdentityConfigurationDoesNotPersistRequestedSettings() async throws {
        let defaults = UserDefaults.standard
        let algorithmKey = ProtocolSigningIdentityPolicy.algorithmDefaultsKey
        let protectionKey = ProtocolSigningIdentityPolicy.protectionDefaultsKey
        let previousAlgorithm = defaults.object(forKey: algorithmKey)
        let previousProtection = defaults.object(forKey: protectionKey)
        defer {
            if let previousAlgorithm {
                defaults.set(previousAlgorithm, forKey: algorithmKey)
            } else {
                defaults.removeObject(forKey: algorithmKey)
            }
            if let previousProtection {
                defaults.set(previousProtection, forKey: protectionKey)
            } else {
                defaults.removeObject(forKey: protectionKey)
            }
        }

        defaults.set(ProtocolSigningAlgorithm.mlDSA65.rawValue, forKey: algorithmKey)
        defaults.set(ProtocolSigningKeyProtection.softwareKeychain.rawValue, forKey: protectionKey)
        let core = SkyBridgeiOSCore { _, _ in
            throw InjectedInitializationIdentityError()
        }

        do {
            try await core.configureProtocolSigningIdentity(
                algorithm: .ed25519,
                protection: .secureEnclaveRequired
            )
            XCTFail("Ed25519 must not be admitted as a PQC identity configuration")
        } catch let SkyBridgeError.invalidKeyData(reason) {
            XCTAssertEqual(reason, "Ed25519 is not a PQC identity configuration")
        }

        XCTAssertEqual(defaults.string(forKey: algorithmKey), ProtocolSigningAlgorithm.mlDSA65.rawValue)
        XCTAssertEqual(
            defaults.string(forKey: protectionKey),
            ProtocolSigningKeyProtection.softwareKeychain.rawValue
        )
        XCTAssertFalse(core.isInitialized)
    }

    func testProtocolIdentityConfigurationRejectsPartialLegacyWrite() throws {
        let defaults = try makeEphemeralDefaults()
        defaults.set(
            ProtocolSigningAlgorithm.mlDSA87.rawValue,
            forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
        )

        let resolution = ProtocolSigningIdentityPolicy.configurationResolution(
            defaults: defaults,
            legacySlotExists: { _ in true }
        )

        XCTAssertEqual(resolution, .requiresExplicitConfirmation)
        XCTAssertThrowsError(
            try ProtocolSigningIdentityPolicy.requiredConfiguration(defaults: defaults)
        ) { error in
            XCTAssertEqual(
                error as? ProtocolDeviceIdentityError,
                .corruptIdentityConfiguration
            )
        }
        XCTAssertNil(defaults.data(forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey))
    }

    func testProtocolIdentityConfigurationRejectsCorruptRecordWithoutLegacyFallback() throws {
        let defaults = try makeEphemeralDefaults()
        defaults.set(
            Data([0xff, 0x00, 0x01]),
            forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey
        )
        defaults.set(
            ProtocolSigningAlgorithm.mlDSA87.rawValue,
            forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
        )
        defaults.set(
            ProtocolSigningKeyProtection.secureEnclaveRequired.rawValue,
            forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey
        )

        let resolution = ProtocolSigningIdentityPolicy.configurationResolution(
            defaults: defaults,
            legacySlotExists: { _ in true }
        )

        XCTAssertEqual(resolution, .requiresExplicitConfirmation)
        XCTAssertThrowsError(
            try ProtocolSigningIdentityPolicy.requiredConfiguration(defaults: defaults)
        ) { error in
            XCTAssertEqual(
                error as? ProtocolDeviceIdentityError,
                .corruptIdentityConfiguration
            )
        }
        XCTAssertNotNil(defaults.object(forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey))
        XCTAssertNotNil(defaults.object(forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey))
    }

    func testProtocolIdentityConfigurationRejectsUnknownVersion() throws {
        let defaults = try makeEphemeralDefaults()
        let unknownVersion = Data(
            "{\"algorithm\":\"ML-DSA-87\",\"keyProtection\":\"secure-enclave-required\",\"version\":2}"
                .utf8
        )
        defaults.set(
            unknownVersion,
            forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey
        )

        let resolution = ProtocolSigningIdentityPolicy.configurationResolution(
            defaults: defaults,
            legacySlotExists: { _ in true }
        )

        XCTAssertEqual(resolution, .requiresExplicitConfirmation)
        XCTAssertThrowsError(
            try ProtocolSigningIdentityPolicy.requiredConfiguration(defaults: defaults)
        ) { error in
            XCTAssertEqual(
                error as? ProtocolDeviceIdentityError,
                .corruptIdentityConfiguration
            )
        }
        XCTAssertEqual(
            defaults.data(forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey),
            unknownVersion
        )
    }

    func testProtocolIdentityConfigurationMigratesOnlyCompleteExactSlotIntent() throws {
        let defaults = try makeEphemeralDefaults()
        defaults.set(
            ProtocolSigningAlgorithm.mlDSA87.rawValue,
            forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
        )
        defaults.set(
            ProtocolSigningKeyProtection.secureEnclaveRequired.rawValue,
            forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey
        )

        let resolution = ProtocolSigningIdentityPolicy.configurationResolution(
            defaults: defaults,
            legacySlotExists: { slot in
                slot.algorithm == .mlDSA87
                    && slot.keyProtection == .secureEnclaveRequired
            }
        )

        let configuration = resolution.effectiveConfiguration
        XCTAssertFalse(resolution.needsExplicitConfirmation)
        XCTAssertEqual(configuration.algorithm, .mlDSA87)
        XCTAssertEqual(configuration.keyProtection, .secureEnclaveRequired)
        XCTAssertNotNil(defaults.data(forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey))
        XCTAssertNil(defaults.object(forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey))
        XCTAssertNil(defaults.object(forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey))
    }

    func testLegacyP256SecureEnclaveBooleanIsNeverIdentityConfigurationAuthority() throws {
        let defaults = try makeEphemeralDefaults()
        defaults.set(true, forKey: "Settings.UseSecureEnclaveMLDSA")

        let resolution = ProtocolSigningIdentityPolicy.configurationResolution(
            defaults: defaults,
            legacySlotExists: { _ in true }
        )

        let configuration = resolution.effectiveConfiguration
        XCTAssertEqual(resolution, .freshInstallDefault(configuration))
        XCTAssertEqual(configuration.algorithm, .mlDSA65)
        XCTAssertEqual(configuration.keyProtection, .softwareKeychain)
        XCTAssertNil(defaults.data(forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey))
    }

    @MainActor
    func testSupersededProtocolIdentityConfigurationCannotOverwriteNewerInitialization() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Apple CryptoKit ML-DSA requires iOS 26 or newer")
        }
        let gate = SupersedingExplicitConfigurationResolver()
        let core = SkyBridgeiOSCore(
            protocolIdentityResolver: { algorithm, _ in
                guard algorithm == .ed25519 else {
                    throw IdentitySlotValidationError()
                }
                let key = Curve25519.Signing.PrivateKey()
                let publicKey = key.publicKey.rawRepresentation
                return ResolvedProtocolSigningIdentity(
                    snapshot: ProtocolIdentitySnapshot(
                        deviceId: "superseding-explicit-configuration-device",
                        signingAlgorithm: algorithm,
                        signingPublicKey: publicKey,
                        signingPublicKeyFingerprint: String(repeating: "c", count: 64)
                    ),
                    material: ProtocolSigningIdentityMaterial(
                        algorithm: algorithm,
                        privateKey: key.rawRepresentation,
                        publicKey: publicKey
                    )
                )
            },
            explicitProtocolIdentityResolver: { algorithm, _, protection in
                try await gate.resolve(
                    algorithm: algorithm,
                    protection: protection
                )
            }
        )
        let defaults = UserDefaults.standard
        let configurationKey = ProtocolSigningIdentityPolicy.configurationDefaultsKey
        let previousConfiguration = defaults.object(forKey: configurationKey)
        let previousAlgorithm = defaults.object(
            forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
        )
        let previousProtection = defaults.object(
            forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey
        )
        defer {
            if let previousConfiguration {
                defaults.set(previousConfiguration, forKey: configurationKey)
            } else {
                defaults.removeObject(forKey: configurationKey)
            }
            if let previousAlgorithm {
                defaults.set(
                    previousAlgorithm,
                    forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
                )
            } else {
                defaults.removeObject(
                    forKey: ProtocolSigningIdentityPolicy.algorithmDefaultsKey
                )
            }
            if let previousProtection {
                defaults.set(
                    previousProtection,
                    forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey
                )
            } else {
                defaults.removeObject(
                    forKey: ProtocolSigningIdentityPolicy.protectionDefaultsKey
                )
            }
        }
        try ProtocolSigningIdentityPolicy.persist(
            ProtocolIdentityConfigurationRecord(
                algorithm: .mlDSA65,
                keyProtection: .softwareKeychain
            )
        )
        try await core.initialize(policy: .classicOnly)

        let staleConfiguration = Task { @MainActor in
            try await core.configureProtocolSigningIdentity(
                algorithm: .mlDSA87,
                protection: .softwareKeychain
            )
        }
        try await gate.waitUntilResolutionStarted()
        try await core.initialize(policy: .classicOnly)
        await gate.resumeResolution()

        do {
            try await staleConfiguration.value
            XCTFail("Superseded explicit configuration must not publish")
        } catch let SkyBridgeError.handshakeFailed(reason) {
            XCTAssertEqual(
                reason,
                "Protocol identity configuration was superseded by a newer request"
            )
        }
        XCTAssertEqual(core.signatureProvider?.signatureAlgorithm, .ed25519)
        XCTAssertEqual(core.cryptoProvider?.tier, .classic)
        XCTAssertEqual(
            ProtocolSigningIdentityPolicy.requestedPQCAlgorithm(),
            .mlDSA65
        )
        XCTAssertEqual(
            ProtocolSigningIdentityPolicy.requestedProtection(),
            .softwareKeychain
        )
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testSecureEnclaveMLDSA65And87PersistRestoreSignVerifyOnPhysicalDevice() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Secure Enclave ML-DSA requires iOS 26 or newer")
        }
        #if targetEnvironment(simulator)
        XCTAssertFalse(IOSSecureEnclaveMLDSAIdentityFactory.isAvailable)
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .mlDSA87] {
            do {
                _ = try await IOSSecureEnclaveMLDSAIdentityFactory.create(
                    algorithm: algorithm
                )
                XCTFail("Simulator must not synthesize a software fallback for \(algorithm.rawValue)")
            } catch let error as ProtocolDeviceIdentityError {
                XCTAssertEqual(error, .secureEnclaveUnavailable)
            }
        }
        throw XCTSkip("Secure Enclave ML-DSA round trip is a selectable physical-device test")
        #else
        guard IOSSecureEnclaveMLDSAIdentityFactory.isAvailable else {
            throw XCTSkip("Secure Enclave ML-DSA is unavailable on this physical device")
        }
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .mlDSA87] {
            let created = try await IOSSecureEnclaveMLDSAIdentityFactory.create(
                algorithm: algorithm
            )
            let persistedRepresentation = try JSONEncoder().encode(created)
            let restored = try JSONDecoder()
                .decode(ProtocolSigningIdentityMaterial.self, from: persistedRepresentation)
                .validated(for: algorithm)
            XCTAssertEqual(restored.keyProtection, .secureEnclaveRequired)
            XCTAssertEqual(restored.publicKey, created.publicKey)

            let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
                for: restored
            )
            let provider = ProtocolSignatureProviderSelector.select(for: algorithm)
            let message = Data("SkyBridge/iOS/SE-MLDSA/device-proof/v1".utf8)
            let signature = try await provider.sign(message, key: keyHandle)
            let signatureIsValid = try await provider.verify(
                message,
                signature: signature,
                publicKey: restored.publicKey
            )
            XCTAssertTrue(signatureIsValid)
        }
        #endif
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testExplicitXWingPreferenceDoesNotSilentlyOfferMLKEMOnLiboqsProvider() throws {
        setenv("SB_PQC_PREFERRED_SUITE", "xwing", 1)
        defer { unsetenv("SB_PQC_PREFERRED_SUITE") }

        XCTAssertThrowsError(
            try TwoAttemptHandshakeManager.prepareAttempt(
                strategy: .pqcOnly,
                cryptoProvider: MockLiboqsPQCProvider()
            )
        ) { error in
            guard case AttemptPreparationError.pqcProviderUnavailable = error else {
                XCTFail("Expected pqcProviderUnavailable, got \(error)")
                return
            }
        }
    }

    func testStrictPQCDoesNotRetryPurePQCCompatibilityAfterXWingFailure() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "xwing-strict-device",
                preferPQC: true,
                policy: .strictPQC,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTFail("strictPQC must fail fast instead of retrying a compatibility suite")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testDefaultPolicyRetriesPurePQCBeforeClassicFallback() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        let keys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: "xwing-compat-device",
            preferPQC: true,
            policy: .default,
            cryptoProvider: provider
        ) { preparation in
            let attempt = await tracker.record(preparation.offeredSuites)
            if attempt == 1 {
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }

            XCTAssertEqual(preparation.offeredSuites, [.mlkem768])
            return Self.makeSessionKeys(suite: .mlkem768)
        }

        XCTAssertEqual(keys.negotiatedSuite, .mlkem768)
        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], initialPreparation.offeredSuites)
        XCTAssertEqual(attempts[1], [.mlkem768])
    }

    func testMissingPeerKEMForPreferredXWingDoesNotRetryPureMLKEM() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "xwing-missing-kem-device",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))
            }
            XCTFail("missing peer KEM must surface as provisioning failure, not retry another PQC suite")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testSuiteNotSupportedDoesNotFallbackOrRetry() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        XCTAssertFalse(
            TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported),
            "Unsupported or unknown wire suites must fail closed instead of becoming fallback-eligible."
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "unsupported-suite-device",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNotSupported)
            }
            XCTFail("suiteNotSupported must fail without compatibility retry or classic fallback")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNotSupported)
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testResponderSelectionRejectsXWingWhenAttemptDidNotEnableHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple PQC provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: ApplePQCCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x11, count: 32),
            policy: .strictPQC,
            cryptoPolicy: .default
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])

        do {
            _ = try await context.selectResponderSuite(for: messageA)
            XCTFail("Expected X-Wing to be rejected when hybrid policy is disabled")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionAcceptsXWingWhenResolverEnabledHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x22, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing])
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionRejectsSuiteOutsideFrozenLocalOffer() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple PQC provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: ApplePQCCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x23, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing]),
            offeredSuites: [.mlkem768]
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])

        do {
            _ = try await context.selectResponderSuite(for: messageA)
            XCTFail("Responder must not select a suite outside its frozen local offer")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionPrefersHybridWhenPolicyRequiresIt() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x33, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing, .mlkem768])
        )

        let messageA = makeMessageA(
            supportedSuites: [.xwing, .mlkem768],
            keyShareSuites: [.xwing, .mlkem768]
        )
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testMessageAOfferShapeRejectsLegacyAndDuplicateSuitesBeforeRekeyAdmission() {
        let classic = makeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShareSuites: [.x25519Ed25519]
        )
        XCTAssertTrue(classic.hasNegotiableOfferShape)

        let legacy = makeMessageA(
            supportedSuites: [.qperiaptContextBound],
            keyShareSuites: [.qperiaptContextBound]
        )
        XCTAssertFalse(legacy.hasNegotiableOfferShape)

        let duplicate = makeMessageA(
            supportedSuites: [.x25519Ed25519, .x25519Ed25519],
            keyShareSuites: [.x25519Ed25519]
        )
        XCTAssertFalse(duplicate.hasNegotiableOfferShape)
        XCTAssertThrowsError(try HandshakeMessageA.decode(from: duplicate.encoded))
    }

    private func makeMessageA(
        supportedSuites: [CryptoSuite],
        keyShareSuites: [CryptoSuite]
    ) -> HandshakeMessageA {
        let keyShares = keyShareSuites.map { suite in
            HandshakeKeyShare(
                suite: suite,
                shareBytes: Data(repeating: UInt8(truncatingIfNeeded: suite.wireId & 0x00FF), count: 32)
            )
        }

        return HandshakeMessageA(
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(repeating: 0x44, count: HandshakeConstants.nonceSize),
            policy: .strictPQC,
            capabilities: CryptoCapabilities(),
            signature: Data(),
            identityPublicKey: Data(repeating: 0x55, count: 32)
        )
    }

    private static func makeSessionKeys(suite: CryptoSuite) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: suite,
            transcriptHash: Data(repeating: 0x33, count: 32)
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

    private func makeEphemeralDefaults() throws -> UserDefaults {
        let suiteName = "HandshakeCryptoPolicyParityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw IdentitySlotValidationError()
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct InjectedInitializationIdentityError: Error {}
private struct InitializationResolutionTimeout: Error {}
private struct IdentitySlotValidationError: Error {}

@available(iOS 17.0, *)
private final class InMemoryProtocolIdentityPersistence: ProtocolIdentityPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var deviceAuthority: Data?
    private var signingKeys: [String: Data] = [:]
    private var signingAuthorities: [String: Data] = [:]

    func loadDeviceAuthority() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return deviceAuthority
    }

    func insertDeviceAuthorityIfAbsent(_ data: Data) throws -> IOSKeychainInsertResult {
        lock.lock()
        defer { lock.unlock() }
        guard deviceAuthority == nil else { return .alreadyExists }
        deviceAuthority = data
        return .inserted
    }

    func loadSigningKey(for slot: ProtocolSigningIdentitySlot) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return signingKeys[slot.persistenceAccount]
    }

    func insertSigningKeyIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult {
        lock.lock()
        defer { lock.unlock() }
        guard signingKeys[slot.persistenceAccount] == nil else { return .alreadyExists }
        signingKeys[slot.persistenceAccount] = data
        return .inserted
    }

    func loadSigningAuthority(for slot: ProtocolSigningIdentitySlot) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return signingAuthorities[slot.persistenceAccount]
    }

    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult {
        lock.lock()
        defer { lock.unlock() }
        guard signingAuthorities[slot.persistenceAccount] == nil else { return .alreadyExists }
        signingAuthorities[slot.persistenceAccount] = data
        return .inserted
    }

    func legacyDeviceIdCandidates() throws -> [ProtocolIdentityLegacyItem] {
        []
    }

    func legacySigningKeyCandidates(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> [ProtocolIdentityLegacyItem] {
        _ = algorithm
        return []
    }

    func deleteLegacyItemIfUnchanged(_ item: ProtocolIdentityLegacyItem) throws {
        _ = item
    }

    func legacyDefaultsDeviceIds() -> [String] {
        ["identity-slot-test-device"]
    }

    func publishDeviceIdMirrors(_ deviceId: String) {
        _ = deviceId
    }

    func signingKeyAccounts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(signingKeys.keys)
    }
}

@available(iOS 17.0, *)
private actor InitializationIdentityResolverProbe {
    private var pqcAttempts = 0

    func resolve(
        algorithm: ProtocolSigningAlgorithm
    ) throws -> ResolvedProtocolSigningIdentity {
        if algorithm == .mlDSA65 {
            pqcAttempts += 1
            if pqcAttempts == 1 {
                throw InjectedInitializationIdentityError()
            }
        }
        let publicKey = Data(
            repeating: algorithm == .ed25519 ? 0x11 : 0x22,
            count: algorithm == .ed25519 ? 32 : 1_952
        )
        let material = ProtocolSigningIdentityMaterial(
            algorithm: algorithm,
            privateKey: Data(repeating: 0x33, count: 64),
            publicKey: publicKey
        )
        return ResolvedProtocolSigningIdentity(
            snapshot: ProtocolIdentitySnapshot(
                deviceId: "transactional-initialization-device",
                signingAlgorithm: algorithm,
                signingPublicKey: publicKey,
                signingPublicKeyFingerprint: String(repeating: "a", count: 64)
            ),
            material: material
        )
    }

    func pqcAttemptCount() -> Int {
        pqcAttempts
    }
}

@available(iOS 17.0, *)
private actor SupersedingInitializationIdentityResolver {
    private var pqcResolutionStarted = false
    private var pqcContinuation: CheckedContinuation<Void, Never>?

    func resolve(
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> ResolvedProtocolSigningIdentity {
        if algorithm == .mlDSA65 {
            pqcResolutionStarted = true
            await withCheckedContinuation { continuation in
                pqcContinuation = continuation
            }
        }
        try Task.checkCancellation()
        let publicKey = Data(
            repeating: algorithm == .ed25519 ? 0x44 : 0x55,
            count: algorithm == .ed25519 ? 32 : 1_952
        )
        return ResolvedProtocolSigningIdentity(
            snapshot: ProtocolIdentitySnapshot(
                deviceId: "superseding-initialization-device",
                signingAlgorithm: algorithm,
                signingPublicKey: publicKey,
                signingPublicKeyFingerprint: String(repeating: "b", count: 64)
            ),
            material: ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: Data(repeating: 0x66, count: 64),
                publicKey: publicKey
            )
        )
    }

    func waitUntilPQCResolutionStarted() async throws {
        while !pqcResolutionStarted {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func resumePQCResolution() {
        pqcContinuation?.resume()
        pqcContinuation = nil
    }
}

@available(iOS 26.0, *)
private actor SupersedingExplicitConfigurationResolver {
    private var resolutionStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func resolve(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> ResolvedProtocolSigningIdentity {
        guard algorithm == .mlDSA87,
              protection == .softwareKeychain else {
            throw IdentitySlotValidationError()
        }
        resolutionStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        let key = try MLDSA87.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        return ResolvedProtocolSigningIdentity(
            snapshot: ProtocolIdentitySnapshot(
                deviceId: "superseding-explicit-configuration-device",
                signingAlgorithm: algorithm,
                signingPublicKey: publicKey,
                signingPublicKeyFingerprint: String(repeating: "d", count: 64)
            ),
            material: ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: key.integrityCheckedRepresentation,
                publicKey: publicKey,
                keyProtection: protection
            )
        )
    }

    func waitUntilResolutionStarted() async throws {
        while !resolutionStarted {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func resumeResolution() {
        continuation?.resume()
        continuation = nil
    }
}

@available(iOS 17.0, *)
private struct MockNativeHybridProvider: CryptoProvider, Sendable {
    let providerName = "MockNativeHybridProvider"
    let tier: CryptoTier = .nativePQC
    let activeSuite: CryptoSuite = .xwing
    let supportedSuites: [CryptoSuite] = [.xwing]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(where: { $0.wireId == suite.wireId })
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeSeal")
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDemSealWithSecret")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeOpen(data)")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeOpen(secure)")
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDemOpenWithSecret")
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemEncapsulate")
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDecapsulate")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.generateKeyPair")
    }
}

@available(iOS 17.0, *)
private struct MockLiboqsPQCProvider: CryptoProvider, Sendable {
    let providerName = "MockLiboqsPQCProvider"
    let tier: CryptoTier = .liboqsPQC
    let activeSuite: CryptoSuite = .mlkem768
    let supportedSuites: [CryptoSuite] = [.mlkem768]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(where: { $0.wireId == suite.wireId })
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeSeal")
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDemSealWithSecret")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeOpen(data)")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeOpen(secure)")
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDemOpenWithSecret")
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemEncapsulate")
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDecapsulate")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.generateKeyPair")
    }
}

@available(iOS 17.0, *)
private actor AttemptTracker {
    private var offeredSuitesByAttempt: [[CryptoSuite]] = []

    func record(_ offeredSuites: [CryptoSuite]) -> Int {
        offeredSuitesByAttempt.append(offeredSuites)
        return offeredSuitesByAttempt.count
    }

    func snapshot() -> [[CryptoSuite]] {
        offeredSuitesByAttempt
    }
}

@available(iOS 17.0, *)
private actor SignatureAttemptTracker {
    struct Attempt: Sendable {
        let strategy: HandshakeAttemptStrategy
        let algorithm: ProtocolSigningAlgorithm
    }

    private var attempts: [Attempt] = []

    func record(
        strategy: HandshakeAttemptStrategy,
        algorithm: ProtocolSigningAlgorithm
    ) {
        attempts.append(Attempt(strategy: strategy, algorithm: algorithm))
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}
