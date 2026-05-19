import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCManagerDirectProbeTests: XCTestCase {
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
    func testDirectProbeDecryptsRawCiphertextPayload() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-direct-probe".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)

        let decrypted = CrossNetworkWebRTCManager.testOnlyDecryptDirectControlProbePayload(
            ciphertext,
            keys: keys
        )

        XCTAssertEqual(decrypted, plaintext)
    }

    @MainActor
    func testDirectProbeReturnsNilForLengthPrefixedFrame() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-framed-payload".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)
        var framed = Data()
        var length = UInt32(ciphertext.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(ciphertext)

        let decrypted = CrossNetworkWebRTCManager.testOnlyDecryptDirectControlProbePayload(
            framed,
            keys: keys
        )

        XCTAssertNil(decrypted)
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
    func testViewerStreamConfigurationDisablesCrossNetworkFallbackScreenChannel() throws {
        let payload = RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

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
    func testScreenChannelDirectRawCiphertextPayloadDecodes() throws {
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

    private func makeSessionKeys(byte: UInt8 = 0x42) -> SessionKeys {
        let keyBytes = Data(repeating: byte, count: 32)
        return SessionKeys(
            sendKey: keyBytes,
            receiveKey: keyBytes,
            negotiatedSuite: .mlkem768,
            transcriptHash: Data(repeating: 0x24, count: 32)
        )
    }

    private func encryptForInboundProbe(_ plaintext: Data, keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            XCTFail("Missing combined ciphertext")
            return Data()
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
