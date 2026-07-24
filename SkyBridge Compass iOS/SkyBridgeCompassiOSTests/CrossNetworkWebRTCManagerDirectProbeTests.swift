import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCManagerDirectProbeTests: XCTestCase {
    private var inboundProbeCounter: UInt64 = 0

    func testStrictWebRTCJoinBootstrapValidatesAndBindsMLDSA87Authority() throws {
        let remoteDeviceId = "device-\(UUID().uuidString.lowercased())"
        let publicKey = Data(repeating: 0x87, count: 2_592)
        let fingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: publicKey
        )
        let kemPublicKey = Data(repeating: 0x42, count: 1_216)
        let payload = WebRTCSignalingEnvelope.Payload(
            protocolSigningAlgorithm: .mlDSA87,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: publicKey,
            kemPublicKeys: [
                .init(suiteWireId: CryptoSuite.xwing.wireId, publicKey: kemPublicKey)
            ],
            platform: "iOS",
            osVersion: "iOS 26.0"
        )

        let validated = try XCTUnwrap(
            CrossNetworkWebRTCManager.validatedWebRTCJoinBootstrap(
                payload,
                from: remoteDeviceId,
                expectedAuthority: nil,
                requiresStrictPQC: true
            )
        )

        XCTAssertEqual(validated.authority.deviceId, remoteDeviceId)
        XCTAssertEqual(validated.authority.protocolSigningAlgorithm, .mlDSA87)
        XCTAssertEqual(validated.authority.protocolPublicKeyFingerprint, fingerprint)
        XCTAssertEqual(validated.authority.protocolPublicKeyBytes, publicKey)
        XCTAssertEqual(validated.kemPublicKeys, [
            KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: kemPublicKey)
        ])
    }

    func testStrictWebRTCJoinBootstrapRejectsTamperMismatchAndMissingKEM() throws {
        let remoteDeviceId = "device-\(UUID().uuidString.lowercased())"
        let publicKey = Data(repeating: 0x65, count: 1_952)
        let fingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )
        let validKEM = WebRTCSignalingEnvelope.Payload.BootstrapKEMPublicKey(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x24, count: 1_184)
        )
        let validPayload = WebRTCSignalingEnvelope.Payload(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: publicKey,
            kemPublicKeys: [validKEM],
            platform: "iOS",
            osVersion: "iOS 26.0"
        )
        let expected = CurrentPathRemoteAuthorityCompat(
            deviceId: remoteDeviceId,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: publicKey,
            deviceName: "Peer"
        )

        var tamperedKey = publicKey
        tamperedKey[0] ^= 0x01
        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.validatedWebRTCJoinBootstrap(
                WebRTCSignalingEnvelope.Payload(
                    protocolSigningAlgorithm: .mlDSA65,
                    protocolPublicKeyFingerprint: fingerprint,
                    protocolPublicKeyBytes: tamperedKey,
                    kemPublicKeys: [validKEM],
                    platform: "iOS",
                    osVersion: "iOS 26.0"
                ),
                from: remoteDeviceId,
                expectedAuthority: expected,
                requiresStrictPQC: true
            )
        ) { error in
            XCTAssertEqual(error as? CurrentPathJoinBootstrapError, .invalidIdentity)
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.validatedWebRTCJoinBootstrap(
                validPayload,
                from: "different-\(UUID().uuidString.lowercased())",
                expectedAuthority: expected,
                requiresStrictPQC: true
            )
        ) { error in
            XCTAssertEqual(error as? CurrentPathJoinBootstrapError, .authorityMismatch)
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.validatedWebRTCJoinBootstrap(
                WebRTCSignalingEnvelope.Payload(
                    protocolSigningAlgorithm: .mlDSA65,
                    protocolPublicKeyFingerprint: fingerprint,
                    protocolPublicKeyBytes: publicKey,
                    kemPublicKeys: [],
                    platform: "iOS",
                    osVersion: "iOS 26.0"
                ),
                from: remoteDeviceId,
                expectedAuthority: expected,
                requiresStrictPQC: true
            )
        ) { error in
            XCTAssertEqual(error as? CurrentPathJoinBootstrapError, .missingKEM)
        }
    }

    func testControlChannelCodecLabelsBootstrapAppMessageKinds() {
        XCTAssertEqual(
            CrossNetworkWebRTCControlChannelCodec.bootstrapAppMessageKind(.heartbeat(.init())),
            "heartbeat"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCControlChannelCodec.bootstrapAppMessageKind(.peerDisconnecting(.init(deviceId: "peer"))),
            "peerDisconnecting"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCControlChannelCodec.bootstrapAppMessageKind(.ping(.init(id: 7))),
            "ping"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCControlChannelCodec.bootstrapAppMessageKind(.pong(.init(id: 7))),
            "pong"
        )
    }

    func testControlChannelCodecRecognizesFinishedHandshakePacket() {
        let finished = HandshakeFinished(
            direction: .responderToInitiator,
            mac: Data(repeating: 0x11, count: 32)
        )

        XCTAssertTrue(CrossNetworkWebRTCControlChannelCodec.isLikelyCompleteHandshakeControlPacket(finished.encoded))
        XCTAssertTrue(CrossNetworkWebRTCControlChannelCodec.isActiveHandshakeDriverFrame(finished.encoded))
        XCTAssertFalse(CrossNetworkWebRTCControlChannelCodec.isLikelyCompleteHandshakeControlPacket(Data()))
        XCTAssertFalse(CrossNetworkWebRTCControlChannelCodec.isLikelyCompleteHandshakeControlPacket(Data([0xff, 0, 0, 0, 0])))
    }

    func testNativeVideoPolicyNormalizesEvenBackedOddVisibleFrameSize() {
        let normalization = CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
            forCodedSize: CGSize(width: 1920, height: 1080),
            expectedVisibleSize: CGSize(width: 1919, height: 1079)
        )

        XCTAssertEqual(normalization.visibleSize, CGSize(width: 1919, height: 1079))
        XCTAssertTrue(normalization.usedEvenPadding)
    }

    func testNativeVideoPolicyKeepsExactExpectedFrameWithoutPaddingFlag() {
        let normalization = CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
            forCodedSize: CGSize(width: 1920, height: 1080),
            expectedVisibleSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(normalization.visibleSize, CGSize(width: 1920, height: 1080))
        XCTAssertFalse(normalization.usedEvenPadding)
    }

    func testNativeVideoPolicyReturnsCodedSizeWhenExpectedFrameIsMissingInvalidOrMismatched() {
        let codedSize = CGSize(width: 1280, height: 720)

        XCTAssertEqual(
            CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
                forCodedSize: codedSize,
                expectedVisibleSize: nil
            ),
            CrossNetworkWebRTCNativeVideoPolicy.VisibleFrameNormalization(
                visibleSize: codedSize,
                usedEvenPadding: false
            )
        )
        XCTAssertEqual(
            CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
                forCodedSize: codedSize,
                expectedVisibleSize: CGSize(width: 0, height: 720)
            ),
            CrossNetworkWebRTCNativeVideoPolicy.VisibleFrameNormalization(
                visibleSize: codedSize,
                usedEvenPadding: false
            )
        )
        XCTAssertEqual(
            CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
                forCodedSize: codedSize,
                expectedVisibleSize: CGSize(width: 1024, height: 768)
            ),
            CrossNetworkWebRTCNativeVideoPolicy.VisibleFrameNormalization(
                visibleSize: codedSize,
                usedEvenPadding: false
            )
        )
    }

    func testWebRTCSecureEnvelopeRejectsReplayAndWrongPacketType() throws {
        let receiverKeys = makeSessionKeys()
        let senderRole: HandshakeRole = receiverKeys.role == .initiator ? .responder : .initiator
        let senderKeys = SessionKeys(
            sendKey: receiverKeys.receiveKey,
            receiveKey: receiverKeys.sendKey,
            negotiatedSuite: receiverKeys.negotiatedSuite,
            role: senderRole,
            transcriptHash: receiverKeys.transcriptHash,
            sessionId: receiverKeys.sessionId
        )
        let packet = try CrossNetworkWebRTCControlChannelCodec.encryptAppPayload(
            Data("metadata".utf8),
            with: senderKeys,
            packetType: .fileTransfer,
            counter: 1
        )

        let opened = try CrossNetworkWebRTCControlChannelCodec.decryptAppPayload(
            packet,
            with: receiverKeys,
            allowedPacketTypes: [.fileTransfer]
        )
        XCTAssertEqual(opened.packetType, .fileTransfer)
        XCTAssertEqual(opened.payload, Data("metadata".utf8))

        var replayWindow = WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(opened)
        XCTAssertThrowsError(try replayWindow.validateAndRecord(opened)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .fileTransfer,
                    counter: 1,
                    highestCounter: 1,
                    reason: .duplicateCounter
                )
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCControlChannelCodec.decryptAppPayload(
                packet,
                with: receiverKeys,
                allowedPacketTypes: [.appControl]
            )
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .packetTypeMismatch(expected: [.appControl], actual: .fileTransfer)
            )
        }
    }

    func testWebRTCSecureEnvelopeSeparatesRemoteDesktopAudioReplayLane() throws {
        let receiverKeys = makeSessionKeys()
        let screenPacket = try encryptForInboundProbe(
            Data("screen-frame".utf8),
            keys: receiverKeys,
            packetType: .remoteDesktop
        )
        let audioPacket = try encryptForInboundProbe(
            Data("fallback-audio".utf8),
            keys: receiverKeys,
            packetType: .remoteDesktopAudio
        )

        let audioOpened = try XCTUnwrap(
            CrossNetworkWebRTCManager.openDirectControlProbePayload(audioPacket, keys: receiverKeys)
        )
        XCTAssertEqual(audioOpened.packetType, .remoteDesktopAudio)
        XCTAssertEqual(audioOpened.counter, 2)

        let screenOpened = try WebRTCAppSecureEnvelope.open(
            screenPacket,
            keys: receiverKeys,
            allowedPacketTypes: [.remoteDesktop]
        )
        XCTAssertEqual(screenOpened.counter, 1)

        var replayWindow = WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(audioOpened)
        XCTAssertNoThrow(
            try replayWindow.validateAndRecord(screenOpened),
            "Control-channel fallback audio must not advance the independently ordered screen channel replay lane."
        )
    }

    func testWebRTCSecureEnvelopeReportsOutsideWindowReplayReason() throws {
        let receiverKeys = makeSessionKeys()
        let highPacket = try encryptForInboundProbe(
            Data("screen-high".utf8),
            keys: receiverKeys,
            packetType: .remoteDesktop,
            counter: 2_000
        )
        let stalePacket = try encryptForInboundProbe(
            Data("screen-stale".utf8),
            keys: receiverKeys,
            packetType: .remoteDesktop,
            counter: 976
        )
        let highOpened = try WebRTCAppSecureEnvelope.open(
            highPacket,
            keys: receiverKeys,
            allowedPacketTypes: [.remoteDesktop]
        )
        let staleOpened = try WebRTCAppSecureEnvelope.open(
            stalePacket,
            keys: receiverKeys,
            allowedPacketTypes: [.remoteDesktop]
        )
        var replayWindow = WebRTCAppSecureReplayWindow()

        try replayWindow.validateAndRecord(highOpened)
        XCTAssertThrowsError(try replayWindow.validateAndRecord(staleOpened)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .remoteDesktop,
                    counter: 976,
                    highestCounter: 2_000,
                    reason: .counterOutsideWindow
                )
            )
        }
    }

    func testFileTransferIntegrityMerkleRootUsesOrderedSha256Tree() throws {
        let leafA = CrossNetworkCryptoCompat.sha256(Data("a".utf8))
        let leafB = CrossNetworkCryptoCompat.sha256(Data("b".utf8))
        let leafC = CrossNetworkCryptoCompat.sha256(Data("c".utf8))

        XCTAssertNil(CrossNetworkMerkleCompat.root(leaves: []))
        XCTAssertNil(CrossNetworkMerkleCompat.root(leaves: [Data([0x01])]))
        XCTAssertEqual(CrossNetworkMerkleCompat.root(leaves: [leafA]), leafA)

        let expectedPairRoot = CrossNetworkCryptoCompat.sha256(leafA + leafB)
        XCTAssertEqual(CrossNetworkMerkleCompat.root(leaves: [leafA, leafB]), expectedPairRoot)

        let leftParent = CrossNetworkCryptoCompat.sha256(leafA + leafB)
        let duplicatedRightParent = CrossNetworkCryptoCompat.sha256(leafC + leafC)
        let expectedOddRoot = CrossNetworkCryptoCompat.sha256(leftParent + duplicatedRightParent)
        XCTAssertEqual(
            CrossNetworkMerkleCompat.root(leaves: [leafA, leafB, leafC]),
            expectedOddRoot
        )
    }

    func testFileTransferMerkleAuthPreimageAndHMACAreStable() throws {
        let transferId = "transfer-1"
        let merkleRoot = Data(repeating: 0x11, count: 32)
        let fileSha256 = Data(repeating: 0x22, count: 32)
        let preimage = CrossNetworkMerkleAuthCompat.preimage(
            transferId: transferId,
            merkleRoot: merkleRoot,
            fileSha256: fileSha256
        )

        var expected = Data("SkyBridge-MerkleRoot|v1|".utf8)
        let transferIdBytes = Data(transferId.utf8)
        expected.append(littleEndianUInt16(transferIdBytes.count))
        expected.append(transferIdBytes)
        expected.append(littleEndianUInt16(merkleRoot.count))
        expected.append(merkleRoot)
        expected.append(littleEndianUInt16(fileSha256.count))
        expected.append(fileSha256)

        XCTAssertEqual(CrossNetworkMerkleAuthCompat.signatureAlgV1, "hmac-sha256-session-v1")
        XCTAssertEqual(preimage, expected)

        let key = Data(repeating: 0x33, count: 32)
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(
            for: expected,
            using: SymmetricKey(data: key)
        ))
        XCTAssertEqual(CrossNetworkMerkleAuthCompat.hmacSha256(key: key, data: preimage), expectedMac)
    }

    func testFileTransferIntegrityValidatorRejectsMissingProofAndChunkHashMismatch() throws {
        let payload = Data("file-chunk".utf8)
        let payloadHash = CrossNetworkCryptoCompat.sha256(payload)

        XCTAssertEqual(
            try CrossNetworkFileTransferIntegrityValidator.verifiedChunkHash(
                data: payload,
                expectedChunkSha256: payloadHash
            ).get(),
            payloadHash
        )

        if case .failure(.chunkHashMismatch) = CrossNetworkFileTransferIntegrityValidator.verifiedChunkHash(
            data: payload,
            expectedChunkSha256: Data(repeating: 0x44, count: 32)
        ) {
            // Expected.
        } else {
            XCTFail("Chunk hash mismatches must be rejected before writing inbound file data.")
        }

        XCTAssertEqual(
            CrossNetworkFileTransferIntegrityValidator.requiredProofFailure(
                fileSha256: nil,
                merkleRoot: nil,
                merkleRootSignature: nil,
                merkleRootSignatureAlg: nil
            ),
            .missingIntegrityProof
        )
        XCTAssertNil(
            CrossNetworkFileTransferIntegrityValidator.requiredProofFailure(
                fileSha256: payloadHash,
                merkleRoot: nil,
                merkleRootSignature: nil,
                merkleRootSignatureAlg: nil
            )
        )
    }

    func testFileTransferIntegrityValidatorRejectsMerkleRootAndSignatureFailures() throws {
        let transferId = "transfer-2"
        let leaves = [
            CrossNetworkCryptoCompat.sha256(Data("chunk-0".utf8)),
            CrossNetworkCryptoCompat.sha256(Data("chunk-1".utf8))
        ]
        let merkleRoot = try XCTUnwrap(CrossNetworkMerkleCompat.root(leaves: leaves))
        let fileSha256 = Data(repeating: 0x22, count: 32)
        let receiveKey = Data(repeating: 0x33, count: 32)
        let validSignature = CrossNetworkMerkleAuthCompat.hmacSha256(
            key: receiveKey,
            data: CrossNetworkMerkleAuthCompat.preimage(
                transferId: transferId,
                merkleRoot: merkleRoot,
                fileSha256: fileSha256
            )
        )
        let chunkHashes = [0: leaves[0], 1: leaves[1]]

        XCTAssertNil(
            CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                transferId: transferId,
                totalChunks: 2,
                chunkHashes: chunkHashes,
                expectedMerkleRoot: merkleRoot,
                merkleRootSignature: validSignature,
                merkleRootSignatureAlg: CrossNetworkMerkleAuthCompat.signatureAlgV1,
                expectedFileSha256: fileSha256,
                receiveKey: receiveKey
            )
        )
        XCTAssertEqual(
            CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                transferId: transferId,
                totalChunks: 2,
                chunkHashes: chunkHashes,
                expectedMerkleRoot: Data(repeating: 0x55, count: 32),
                merkleRootSignature: validSignature,
                merkleRootSignatureAlg: CrossNetworkMerkleAuthCompat.signatureAlgV1,
                expectedFileSha256: fileSha256,
                receiveKey: receiveKey
            ),
            .merkleRootMismatch
        )
        XCTAssertEqual(
            CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                transferId: transferId,
                totalChunks: 2,
                chunkHashes: chunkHashes,
                expectedMerkleRoot: merkleRoot,
                merkleRootSignature: validSignature,
                merkleRootSignatureAlg: "hmac-sha1-legacy",
                expectedFileSha256: fileSha256,
                receiveKey: receiveKey
            ),
            .unknownMerkleSignatureAlgorithm
        )
        XCTAssertEqual(
            CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                transferId: transferId,
                totalChunks: 2,
                chunkHashes: chunkHashes,
                expectedMerkleRoot: merkleRoot,
                merkleRootSignature: Data(repeating: 0x66, count: 32),
                merkleRootSignatureAlg: CrossNetworkMerkleAuthCompat.signatureAlgV1,
                expectedFileSha256: fileSha256,
                receiveKey: receiveKey
            ),
            .merkleSignatureMismatch
        )
    }

    @MainActor
    func testDirectProbeOpensSecureEnvelopeAndRejectsRawCiphertextPayload() throws {
        let keys = makeSessionKeys(sessionId: "direct-probe-\(UUID().uuidString)")
        let plaintext = Data("hello-direct-probe".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)

        let opened = CrossNetworkWebRTCManager.testOnlyOpenDirectControlProbePayload(
            ciphertext,
            keys: keys
        )

        XCTAssertEqual(opened?.packetType, .remoteDesktop)
        XCTAssertEqual(opened?.payload, plaintext)

        let rawCiphertext = try rawLegacyEncryptForInboundProbe(plaintext, keys: keys)
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyOpenDirectControlProbePayload(rawCiphertext, keys: keys)
        )
    }

    @MainActor
    func testDirectProbeReturnsNilForLengthPrefixedFrame() throws {
        let keys = makeSessionKeys(sessionId: "direct-framed-\(UUID().uuidString)")
        let plaintext = Data("hello-framed-payload".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)
        var framed = Data()
        var length = UInt32(ciphertext.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(ciphertext)

        let opened = CrossNetworkWebRTCManager.testOnlyOpenDirectControlProbePayload(
            framed,
            keys: keys
        )

        XCTAssertNil(opened)
    }

    @MainActor
    func testDirectProbeRejectsUndeclaredPacketTypes() throws {
        let keys = makeSessionKeys(sessionId: "direct-type-\(UUID().uuidString)")
        let fileTransferPacket = try encryptForInboundProbe(
            Data("file-transfer-direct".utf8),
            keys: keys,
            packetType: .fileTransfer
        )

        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyOpenDirectControlProbePayload(fileTransferPacket, keys: keys)
        )
    }

    @MainActor
    func testScreenChannelSecureEnvelopeUsesManagerReplayWindow() throws {
        let manager = CrossNetworkWebRTCManager.instance
        let keys = makeSessionKeys(byte: 0x45, sessionId: "screen-replay-\(UUID().uuidString)")
        manager.clearWebRTCSecureEnvelopeState(for: keys.sessionId)
        defer { manager.clearWebRTCSecureEnvelopeState(for: keys.sessionId) }

        let packet = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let opened = try CrossNetworkWebRTCManager.openScreenChannelPayload(packet, keys: keys)
        let validated = try manager.testOnlyValidateWebRTCSecureOpenedPayload(
            opened,
            with: keys,
            sessionId: keys.sessionId
        )
        XCTAssertEqual(CrossNetworkWebRTCManager.decodeScreenChannelPayload(validated) != nil, true)

        let replay = try CrossNetworkWebRTCManager.openScreenChannelPayload(packet, keys: keys)
        XCTAssertThrowsError(
            try manager.testOnlyValidateWebRTCSecureOpenedPayload(replay, with: keys, sessionId: keys.sessionId)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .remoteDesktop,
                    counter: opened.counter,
                    highestCounter: opened.counter,
                    reason: .duplicateCounter
                )
            )
        }
    }

    @MainActor
    func testScreenChannelLengthFramedReplayDropsWithoutResettingParser() throws {
        let replayError = WebRTCAppSecureEnvelopeError.replayDetected(
            packetType: .remoteDesktop,
            counter: 44,
            highestCounter: 44,
            reason: .duplicateCounter
        )
        let wrongKeyError = WebRTCAppSecureEnvelopeError.authenticationFailed(
            packetType: .remoteDesktop,
            counter: 44
        )

        XCTAssertEqual(
            CrossNetworkWebRTCManager.screenLengthFramedDecodeFailureAction(for: replayError),
            .dropAuthenticatedReplay(
                packetType: .remoteDesktop,
                counter: 44,
                highestCounter: 44,
                reason: .duplicateCounter
            )
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.screenLengthFramedDecodeFailureAction(for: wrongKeyError),
            .resetParser
        )

        var decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)
        decoder.markLengthFramedMode()
        if case .dropAuthenticatedReplay = CrossNetworkWebRTCManager.screenLengthFramedDecodeFailureAction(for: replayError) {
            XCTAssertEqual(decoder.mode, .lengthFramed)
        } else {
            XCTFail("expected authenticated replay to be dropped without parser reset")
        }
        if case .resetParser = CrossNetworkWebRTCManager.screenLengthFramedDecodeFailureAction(for: wrongKeyError) {
            decoder.resetLengthFramedAfterDecodeFailure()
        } else {
            XCTFail("expected unauthenticated decode failure to reset parser")
        }
        XCTAssertEqual(decoder.mode, .unknown)
    }

    func testHighThroughputRemoteDesktopScreenPayloadDecodesOffMainActor() async throws {
        let screen = ScreenData(
            width: 2,
            height: 2,
            imageData: Data([0x01, 0x02, 0x03]),
            timestamp: 1_700_000_000,
            format: "jpeg",
            isSyncFrame: true
        )
        let inner = try JSONEncoder().encode(screen)
        let message = RemoteMessage(type: .screenData, payload: inner)
        let plaintext = try JSONEncoder().encode(message)

        let kind = await Task.detached {
            CrossNetworkWebRTCManager.testOnlyDecodeHighThroughputRemoteDesktopPayloadKind(plaintext)
        }.value

        XCTAssertEqual(kind, "screen")
    }

    @MainActor
    func testViewerStreamConfigurationDisablesCrossNetworkFallbackScreenChannel() async throws {
        try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
        let payload = try RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

        XCTAssertEqual(payload.screenDataChannelEnabled, true)

        let source = try readRepositorySource(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationFactory.swift"
        )
        XCTAssertTrue(source.contains("screenDataChannelEnabled: activeTransportMode != .crossNetwork"))
        XCTAssertTrue(source.contains("mediaFallbackPolicy: activeTransportMode == .crossNetwork ? \"forbidden\" : \"fail-fast\""))
        XCTAssertTrue(source.contains("screenChannelWireFormat: activeTransportMode == .crossNetwork || activeTransportMode == .lan"))
        XCTAssertTrue(source.contains("\"sbc2-chunked-v1\""))
    }

    @MainActor
    func testScreenChannelDirectSBP2PayloadDecodesWithoutLengthParser() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let padded = sbp2Wrap(ciphertext)
        var decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)

        XCTAssertTrue(decoder.shouldKeepOutOfLengthParser(padded))
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyDecodeDirectScreenChannelPayloadKind(padded, keys: keys),
            "screen"
        )

        decoder.markDirectPayloadMode()
        XCTAssertEqual(decoder.mode, .directPayload)
    }

    @MainActor
    func testScreenChannelDirectEnvelopeProbeAcceptsNonZeroStartIndexSliceAndRejectsTruncation() {
        let directEnvelope = Data([0x53, 0x42, 0x52, 0x46, 0x01, 0x02])
        var storage = Data([0xA0, 0xA1, 0xA2])
        storage.append(directEnvelope)
        storage.append(0xA3)
        let directSlice = storage[3..<(3 + directEnvelope.count)]
        let truncatedSlice = directSlice.prefix(3)
        let decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(
            maxInboundFrameBytes: 8_000_000
        )

        XCTAssertEqual(directSlice.startIndex, 3)
        XCTAssertEqual(
            CrossNetworkWebRTCManager.InboundFrameParser.knownDirectEnvelopeName(directSlice),
            "SBRF"
        )
        XCTAssertTrue(decoder.shouldKeepOutOfLengthParser(directSlice))
        XCTAssertNil(
            CrossNetworkWebRTCManager.InboundFrameParser.knownDirectEnvelopeName(truncatedSlice)
        )
    }

    @MainActor
    func testScreenChannelLengthFramedSBP2PayloadDecodes() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let framed = framedPayload(sbp2Wrap(ciphertext))
        var decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)

        decoder.appendLengthChunk(Data(framed.prefix(5)))
        XCTAssertNil(decoder.nextLengthPayload(sessionId: "S-length", logLabel: "test-screen"))
        decoder.appendLengthChunk(Data(framed.dropFirst(5)))
        let payload = try XCTUnwrap(decoder.nextLengthPayload(sessionId: "S-length", logLabel: "test-screen"))

        XCTAssertEqual(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(payload, keys: keys),
            "screen"
        )
        decoder.markLengthFramedMode()
        XCTAssertEqual(decoder.mode, .lengthFramed)
    }

    @MainActor
    func testScreenChannelDirectSecureCiphertextPayloadDecodes() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)

        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyDecodeDirectScreenChannelPayloadKind(ciphertext, keys: keys),
            "screen"
        )
    }

    @MainActor
    func testScreenChannelInvalidDirectCandidateDoesNotPoisonNextFramedPayload() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let framed = framedPayload(sbp2Wrap(ciphertext))
        var decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)

        let invalidDirectCandidate = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x02, 0x03])
        XCTAssertTrue(decoder.shouldKeepOutOfLengthParser(invalidDirectCandidate))
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyDecodeDirectScreenChannelPayloadKind(
                invalidDirectCandidate,
                keys: keys
            )
        )

        decoder.appendLengthChunk(framed)
        let payload = try XCTUnwrap(decoder.nextLengthPayload(sessionId: "S-recover", logLabel: "test-screen"))
        XCTAssertEqual(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(payload, keys: keys),
            "screen"
        )
    }

    @MainActor
    func testScreenChannelWrongKeyDoesNotLockWireMode() throws {
        let keys = makeSessionKeys()
        let wrongKeys = makeSessionKeys(byte: 0x43)
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let padded = sbp2Wrap(ciphertext)
        let decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)

        XCTAssertTrue(decoder.shouldKeepOutOfLengthParser(padded))
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyDecodeDirectScreenChannelPayloadKind(padded, keys: wrongKeys)
        )
        XCTAssertEqual(decoder.mode, .unknown)
    }

    @MainActor
    func testScreenChannelLengthFramedDecryptFailureResetsForNextFrame() throws {
        let keys = makeSessionKeys()
        let wrongKeys = makeSessionKeys(byte: 0x43)
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let framed = framedPayload(sbp2Wrap(ciphertext))
        var decoder = CrossNetworkWebRTCManager.ScreenChannelWireDecoder(maxInboundFrameBytes: 8_000_000)

        decoder.appendLengthChunk(framed)
        let failedPayload = try XCTUnwrap(decoder.nextLengthPayload(sessionId: "S-reset", logLabel: "test-screen"))
        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(failedPayload, keys: wrongKeys)
        )
        decoder.markLengthFramedMode()
        decoder.resetLengthFramedAfterDecodeFailure()
        XCTAssertEqual(decoder.mode, .unknown)

        decoder.appendLengthChunk(framed)
        let recoveredPayload = try XCTUnwrap(decoder.nextLengthPayload(sessionId: "S-reset", logLabel: "test-screen"))
        XCTAssertEqual(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(recoveredPayload, keys: keys),
            "screen"
        )
    }

    @MainActor
    func testScreenChannelSBC2ChunksReassembleAndDecode() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let padded = sbp2Wrap(ciphertext)
        let maxChunkBytes = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.headerLength + 5
        let chunks = try makeSBC2Chunks(payload: padded, frameId: 42, maxChunkBytes: maxChunkBytes)
        var reassembler = CrossNetworkWebRTCManager.ScreenChunkedPayloadReassembler(maxFrameBytes: 8_000_000)
        var completed: Data?

        for chunk in chunks {
            let envelope = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(chunk))
            switch reassembler.append(envelope, now: Date()) {
            case .complete(let frameId, let payload):
                XCTAssertEqual(frameId, 42)
                completed = payload
            case .waiting:
                break
            case .dropped(let reason, _):
                XCTFail("Unexpected drop: \(reason)")
            case .suppressed(let frameId, let reason):
                XCTFail("Unexpected suppression: frameId=\(frameId) reason=\(reason)")
            }
        }

        let payload = try XCTUnwrap(completed)
        XCTAssertEqual(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(payload, keys: keys),
            "screen"
        )
    }

    @MainActor
    func testScreenChannelSBC2DecodersAcceptNonZeroStartIndexSliceAndRejectTruncation() throws {
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let chunk = try XCTUnwrap(
            makeSBC2Chunks(payload: payload, frameId: 88, maxChunkBytes: 64 * 1_024).first
        )
        var storage = Data([0xB0, 0xB1])
        storage.append(chunk)
        storage.append(0xB2)
        let chunkSlice = storage[2..<(2 + chunk.count)]
        let truncatedSlice = chunkSlice.dropLast()

        XCTAssertEqual(chunkSlice.startIndex, 2)
        XCTAssertTrue(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.startsWithMagic(chunkSlice))
        let screenChannelEnvelope = try XCTUnwrap(
            CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(chunkSlice)
        )
        XCTAssertEqual(screenChannelEnvelope.frameId, 88)
        XCTAssertEqual(screenChannelEnvelope.payload, payload)
        XCTAssertNil(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(truncatedSlice))

        XCTAssertTrue(RemoteDesktopScreenFrameWire.startsWithChunkMagic(chunkSlice))
        let remoteDesktopEnvelope = try XCTUnwrap(
            RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(chunkSlice)
        )
        XCTAssertEqual(remoteDesktopEnvelope.frameId, 88)
        XCTAssertEqual(remoteDesktopEnvelope.payload, payload)
        XCTAssertNil(RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(truncatedSlice))
    }

    @MainActor
    func testScreenChannelSBC2MissingFirstChunkDoesNotPoisonNextFrame() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let padded = sbp2Wrap(ciphertext)
        let chunks = try makeSBC2Chunks(
            payload: padded,
            frameId: 7,
            maxChunkBytes: CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.headerLength + 4
        )
        var reassembler = CrossNetworkWebRTCManager.ScreenChunkedPayloadReassembler(maxFrameBytes: 8_000_000)

        let missingFirst = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(chunks[1]))
        if case .dropped(let reason, _) = reassembler.append(missingFirst, now: Date()) {
            XCTAssertEqual(reason, "missing-first-chunk")
        } else {
            XCTFail("Expected missing-first-chunk drop")
        }

        let orphan = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(chunks[2]))
        if case .suppressed(let frameId, let reason) = reassembler.append(orphan, now: Date()) {
            XCTAssertEqual(frameId, 7)
            XCTAssertEqual(reason, "missing-first-chunk")
        } else {
            XCTFail("Expected same-frame orphan chunk to be suppressed")
        }

        let nextFrame = try makeSBC2Chunks(payload: padded, frameId: 8, maxChunkBytes: 64 * 1024)
        let envelope = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(nextFrame[0]))
        if case .complete(let frameId, let payload) = reassembler.append(envelope, now: Date()) {
            XCTAssertEqual(frameId, 8)
            XCTAssertEqual(
                try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(payload, keys: keys),
                "screen"
            )
        } else {
            XCTFail("Expected next frame to complete")
        }
    }

    @MainActor
    func testScreenChannelSBC2NewFrameFirstChunkSupersedesStaleFrame() throws {
        let keys = makeSessionKeys()
        let ciphertext = try encryptForInboundProbe(makeScreenFrameWirePlaintext(), keys: keys)
        let padded = sbp2Wrap(ciphertext)
        let maxChunkBytes = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.headerLength + 4
        let staleFrame = try makeSBC2Chunks(payload: padded, frameId: 31, maxChunkBytes: maxChunkBytes)
        let replacementFrame = try makeSBC2Chunks(payload: padded, frameId: 32, maxChunkBytes: maxChunkBytes)
        var reassembler = CrossNetworkWebRTCManager.ScreenChunkedPayloadReassembler(maxFrameBytes: 8_000_000)

        let staleFirst = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(staleFrame[0]))
        if case .dropped(let reason, _) = reassembler.append(staleFirst, now: Date()) {
            XCTFail("Unexpected stale first-chunk drop: \(reason)")
        }

        let replacementFirst = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(replacementFrame[0]))
        if case .dropped(let reason, _) = reassembler.append(replacementFirst, now: Date()) {
            XCTFail("New frame chunk0 should replace stale in-flight frame, not drop: \(reason)")
        }

        var completed: Data?
        for chunk in replacementFrame.dropFirst() {
            let envelope = try XCTUnwrap(CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.decode(chunk))
            switch reassembler.append(envelope, now: Date()) {
            case .complete(let frameId, let payload):
                XCTAssertEqual(frameId, 32)
                completed = payload
            case .waiting:
                break
            case .dropped(let reason, _):
                XCTFail("Unexpected replacement frame drop: \(reason)")
            case .suppressed(let frameId, let reason):
                XCTFail("Unexpected replacement suppression: frameId=\(frameId) reason=\(reason)")
            }
        }

        let payload = try XCTUnwrap(completed)
        XCTAssertEqual(
            try CrossNetworkWebRTCManager.testOnlyDecodeEncryptedScreenChannelPayloadKind(payload, keys: keys),
            "screen"
        )
    }

    func testMediaLeaseFailureReasonsMapSessionInactiveToAuthorityLostBeforeScopeMismatch() {
        let body = #"{"error":"session_inactive"}"#

        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlySessionRefreshFailureReason(status: 403, body: body),
            "sessionAuthorityLost"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaAdmissionRefreshFailureReason(status: 403, body: body),
            "sessionAuthorityLost"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReason(status: 403, body: body),
            "sessionAuthorityLost"
        )
    }

    func testMediaLeaseRevokedMissingSessionMapsToAuthorityLost() {
        let body = #"{"error":"media_admission_token_superseded","mediaTokenRequestGeneration":"aaaa","mediaTokenExpectedPresent":false,"mediaTokenSessionPresent":false,"mediaTokenState":"revoked","rejectReason":"remote_kill"}"#

        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReason(status: 401, body: body),
            "sessionAuthorityLost"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReasonAfterRefresh(status: 401, body: body),
            "sessionAuthorityLost"
        )
    }

    func testMediaLeaseRevokedButExpectedPresentRemainsSuperseded() {
        let body = #"{"error":"media_admission_token_superseded","mediaTokenRequestGeneration":"aaaa","mediaTokenExpectedGeneration":"bbbb","mediaTokenExpectedPresent":true,"mediaTokenSessionPresent":true,"mediaTokenState":"revoked","rejectReason":"media_admission_refreshed"}"#

        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReason(status: 401, body: body),
            "superseded"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReasonAfterRefresh(status: 401, body: body),
            "serverStateMismatch"
        )
    }

    func testMediaLeaseLimitRefreshabilityUsesStructuredErrorCode() {
        let structuredBody = #"{"code":"media_admission_token_lease_limit","message":"retry with a refreshed lease"}"#
        let messageOnlyBody = #"{"message":"media_admission_token_lease_limit"}"#

        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsMediaAdmissionTokenRefreshable(
                status: 429,
                body: structuredBody
            )
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReason(
                status: 429,
                body: structuredBody
            ),
            "leaseLimit"
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsMediaAdmissionTokenRefreshable(
                status: 429,
                body: messageOnlyBody
            )
        )
    }

    func testMediaLeaseRetryAfterRefreshMapsSupersededToServerStateMismatch() {
        let body = #"{"error":"media_admission_token_superseded","mediaTokenRequestGeneration":"aaaa","mediaTokenExpectedGeneration":"bbbb","mediaTokenExpectedPresent":true}"#

        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReason(status: 401, body: body),
            "superseded"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyMediaRelayLeaseFailureReasonAfterRefresh(status: 401, body: body),
            "serverStateMismatch"
        )
    }

    private func makeSessionKeys(byte: UInt8 = 0x42, sessionId: String? = nil) -> SessionKeys {
        let keyBytes = Data(repeating: byte, count: 32)
        return SessionKeys(
            sendKey: keyBytes,
            receiveKey: keyBytes,
            negotiatedSuite: .mlkem768,
            transcriptHash: Data(repeating: 0x24, count: 32),
            sessionId: sessionId
        )
    }

    private func encryptForInboundProbe(
        _ plaintext: Data,
        keys: SessionKeys,
        packetType: WebRTCAppSecurePacketType = .remoteDesktop,
        counter: UInt64? = nil
    ) throws -> Data {
        let packetCounter: UInt64
        if let counter {
            packetCounter = counter
            inboundProbeCounter = max(inboundProbeCounter, counter)
        } else {
            inboundProbeCounter += 1
            packetCounter = inboundProbeCounter
        }
        let senderRole: HandshakeRole = keys.role == .initiator ? .responder : .initiator
        let senderKeys = SessionKeys(
            sendKey: keys.receiveKey,
            receiveKey: keys.sendKey,
            negotiatedSuite: keys.negotiatedSuite,
            role: senderRole,
            transcriptHash: keys.transcriptHash,
            sessionId: keys.sessionId
        )
        return try CrossNetworkWebRTCControlChannelCodec.encryptAppPayload(
            plaintext,
            with: senderKeys,
            packetType: packetType,
            counter: packetCounter
        )
    }

    private func rawLegacyEncryptForInboundProbe(_ plaintext: Data, keys: SessionKeys) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keys.receiveKey))
        guard let combined = sealed.combined else {
            throw NSError(
                domain: "CrossNetworkWebRTCManagerDirectProbeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AES.GCM.seal produced no combined box"]
            )
        }
        return combined
    }

    private func framedPayload(_ payload: Data) -> Data {
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    private func sbp2Wrap(_ payload: Data) -> Data {
        var wrapped = Data([0x53, 0x42, 0x50, 0x32])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { wrapped.append(contentsOf: $0) }
        wrapped.append(payload)
        wrapped.append(Data(repeating: 0xA5, count: 16))
        return wrapped
    }

    private func makeSBC2Chunks(payload: Data, frameId: UInt64, maxChunkBytes: Int) throws -> [Data] {
        let headerLength = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope.headerLength
        let maxPayloadBytes = maxChunkBytes - headerLength
        XCTAssertGreaterThan(maxPayloadBytes, 0)
        let chunkCount = max(1, (payload.count + maxPayloadBytes - 1) / maxPayloadBytes)
        var chunks: [Data] = []
        var offset = 0
        for chunkIndex in 0..<chunkCount {
            let end = min(offset + maxPayloadBytes, payload.count)
            let fragment = Data(payload[offset..<end])
            chunks.append(
                try WebRTCSession.encodeScreenChunkEnvelope(
                    frameId: frameId,
                    chunkIndex: chunkIndex,
                    chunkCount: chunkCount,
                    totalBytes: payload.count,
                    chunkOffset: offset,
                    payload: fragment
                )
            )
            offset = end
        }
        return chunks
    }

    func testWebRTCAuthorityCommitPrecedesAllInitialAndRekeyStatePublication() throws {
        let source = try readRepositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        let outboundInitialStart = try XCTUnwrap(source.range(of: "func startHandshakeOverWebRTC("))
        let outboundInitialEnd = try XCTUnwrap(
            source.range(of: "nonisolated private static func webRTCPQCRekeyProvider", range: outboundInitialStart.lowerBound..<source.endIndex)
        )
        let outboundInitial = String(source[outboundInitialStart.lowerBound..<outboundInitialEnd.lowerBound])
        assertAuthorityCommitPrecedesPublishedSession(
            in: outboundInitial,
            sessionKeyNeedle: "self.sessionKeys = keys",
            connectedNeedle: "self.state = .connected",
            routeNeedle: "await self.sendLocalAuthenticatedRouteBindings("
        )
        XCTAssertTrue(outboundInitial.contains("driver.getAuthenticatedRemoteAuthority()"))

        let inboundRekeyStart = try XCTUnwrap(source.range(of: "private func syncInboundPQCRekeyState("))
        let inboundRekeyEnd = try XCTUnwrap(
            source.range(of: "private func syncInboundInitialHandshakeState(", range: inboundRekeyStart.lowerBound..<source.endIndex)
        )
        let inboundRekey = String(source[inboundRekeyStart.lowerBound..<inboundRekeyEnd.lowerBound])
        assertAuthorityCommitPrecedesPublishedSession(
            in: inboundRekey,
            sessionKeyNeedle: "sessionKeys = keys",
            connectedNeedle: "state = .connected",
            routeNeedle: "await sendLocalAuthenticatedRouteBindings("
        )
        XCTAssertTrue(inboundRekey.contains("stage: \"inbound-rekey\""))

        let inboundInitialStart = try XCTUnwrap(source.range(of: "private func syncInboundInitialHandshakeState("))
        let inboundInitialEnd = try XCTUnwrap(
            source.range(of: "func sendAppMessageOverWebRTC(", range: inboundInitialStart.lowerBound..<source.endIndex)
        )
        let inboundInitial = String(source[inboundInitialStart.lowerBound..<inboundInitialEnd.lowerBound])
        assertAuthorityCommitPrecedesPublishedSession(
            in: inboundInitial,
            sessionKeyNeedle: "sessionKeys = keys",
            connectedNeedle: "state = .connected",
            routeNeedle: "await sendLocalAuthenticatedRouteBindings("
        )
        XCTAssertTrue(inboundInitial.contains("stage: \"inbound-initial\""))

        let outboundRekeyStart = try XCTUnwrap(source.range(of: "func maybeStartPQCRekeyOverWebRTC("))
        let outboundRekeyEnd = try XCTUnwrap(
            source.range(of: "private extension CrossNetworkWebRTCManager", range: outboundRekeyStart.lowerBound..<source.endIndex)
        )
        let outboundRekey = String(source[outboundRekeyStart.lowerBound..<outboundRekeyEnd.lowerBound])
        assertAuthorityCommitPrecedesPublishedSession(
            in: outboundRekey,
            sessionKeyNeedle: "sessionKeys = rekeyed",
            connectedNeedle: "state = .connected",
            routeNeedle: "await sendLocalAuthenticatedRouteBindings("
        )
        XCTAssertTrue(outboundRekey.contains("driver.getAuthenticatedRemoteAuthority()"))
        XCTAssertTrue(outboundRekey.contains("error is CurrentPathAuthorityCommitError"))
        XCTAssertTrue(outboundRekey.contains("stage: \"outbound-rekey\""))
    }

    func testWebRTCAuthorityCommitFailureTerminatesInsteadOfRetainingPostRekeySession() throws {
        let source = try readRepositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func failCurrentPathAuthorityCommit("))
        let end = try XCTUnwrap(
            source.range(of: "func authenticatedInboundFileTransferSenderAuthority", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("await terminateRemoteDesktopSession("))
        XCTAssertTrue(body.contains("state = .failed(message)"))
        XCTAssertTrue(body.contains("readiness = .idle"))
    }

    private func assertAuthorityCommitPrecedesPublishedSession(
        in source: String,
        sessionKeyNeedle: String,
        connectedNeedle: String,
        routeNeedle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let commit = source.range(of: "persistCurrentPathTrust("),
              let sessionKeys = source.range(of: sessionKeyNeedle),
              let connected = source.range(of: connectedNeedle),
              let route = source.range(of: routeNeedle) else {
            XCTFail("Expected authority commit and publication markers", file: file, line: line)
            return
        }
        XCTAssertLessThan(commit.lowerBound, sessionKeys.lowerBound, file: file, line: line)
        XCTAssertLessThan(commit.lowerBound, connected.lowerBound, file: file, line: line)
        XCTAssertLessThan(commit.lowerBound, route.lowerBound, file: file, line: line)
        if let heartbeat = source.range(of: "startRemotePeer") {
            XCTAssertLessThan(commit.lowerBound, heartbeat.lowerBound, file: file, line: line)
        }
        if let desktopHeartbeat = source.range(of: "startRemoteDesktopHeartbeat()") {
            XCTAssertLessThan(commit.lowerBound, desktopHeartbeat.lowerBound, file: file, line: line)
        }
    }

    private func makeScreenFrameWirePlaintext() -> Data {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var data = Data()
        appendUInt32(0x53425246, to: &data) // SBRF
        data.append(1) // version
        data.append(1) // jpeg
        appendUInt16(1, to: &data) // sync frame
        appendUInt32(2, to: &data)
        appendUInt32(2, to: &data)
        appendUInt64(1_700_000_000_000_000, to: &data)
        appendUInt32(UInt32(imageData.count), to: &data)
        data.append(imageData)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func littleEndianUInt16(_ value: Int) -> Data {
        var littleEndian = UInt16(value).littleEndian
        return Data(bytes: &littleEndian, count: 2)
    }

    private func readRepositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip(
            "Repository source files are not mounted inside the physical-device test sandbox; run source-shape regression tests on macOS or iOS Simulator."
        )
        #else
        return try String(contentsOf: sourceURL, encoding: .utf8)
        #endif
    }
}
