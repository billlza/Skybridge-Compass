import SkyBridgeProtocolCore
import XCTest

final class CrossNetworkFileTransferInboundAdmissionPolicyTests: XCTestCase {
    private let transferID = "01234567-89AB-CDEF-0123-456789ABCDEF"

    func testFrameAndRetainedBudgetBoundariesAreOverflowSafe() throws {
        let request = cancel(message: nil)
        let maximumFrame = CrossNetworkFileTransferWireDecoder
            .maximumEncodedPayloadByteCount

        XCTAssertEqual(
            try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
                for: request,
                encodedPayloadByteCount: maximumFrame
            ),
            maximumFrame
        )
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
                for: request,
                encodedPayloadByteCount: maximumFrame + 1
            )
        )

        let maximumRetained = CrossNetworkFileTransferInboundAdmissionPolicy
            .maximumRetainedOperationBytes
        XCTAssertTrue(
            CrossNetworkFileTransferInboundAdmissionPolicy.canReserve(
                currentRetainedByteCount: maximumRetained - 1,
                additionalByteCount: 1
            )
        )
        XCTAssertFalse(
            CrossNetworkFileTransferInboundAdmissionPolicy.canReserve(
                currentRetainedByteCount: maximumRetained,
                additionalByteCount: 1
            )
        )
        XCTAssertFalse(
            CrossNetworkFileTransferInboundAdmissionPolicy.canReserve(
                currentRetainedByteCount: Int.max,
                additionalByteCount: Int.max
            )
        )
    }

    func testMetadataFieldBoundariesAndCrossOperationFields() throws {
        _ = try admit(
            metadata(
                fileName: String(repeating: "a", count: 255),
                senderDeviceID: String(repeating: "d", count: 256),
                senderDeviceName: String(repeating: "n", count: 256)
            )
        )
        XCTAssertThrowsError(
            try admit(metadata(fileName: String(repeating: "a", count: 256)))
        )
        XCTAssertThrowsError(
            try admit(metadata(senderDeviceID: String(repeating: "d", count: 257)))
        )
        XCTAssertThrowsError(
            try admit(metadata(senderDeviceName: String(repeating: "n", count: 257)))
        )
        XCTAssertThrowsError(
            try admit(metadata(chunkData: Data([0x01])))
        )
        XCTAssertThrowsError(
            try admit(metadata(encryption: "aes-gcm-256-v1"))
        )
        XCTAssertThrowsError(
            try admit(metadata(relativePath: "directory/payload.bin"))
        )
    }

    func testChunkAndDigestBoundaries() throws {
        let maximumChunk = CrossNetworkFileTransferInboundAdmissionPolicy
            .maximumChunkDataByteCount
        _ = try admit(
            chunk(
                data: Data(repeating: 0x41, count: maximumChunk),
                digest: Data(repeating: 0x01, count: 32)
            )
        )
        XCTAssertThrowsError(
            try admit(
                chunk(data: Data(repeating: 0x41, count: maximumChunk + 1))
            )
        )
        for digestSize in [31, 33] {
            XCTAssertThrowsError(
                try admit(
                    chunk(
                        data: Data([0x41]),
                        digest: Data(repeating: 0x01, count: digestSize)
                    )
                )
            )
        }
        XCTAssertThrowsError(
            try admit(
                chunk(data: Data([0x41]), rawSize: 2)
            )
        )
        XCTAssertThrowsError(
            try admit(
                CrossNetworkFileTransferMessage(
                    op: .chunk,
                    transferId: transferID,
                    chunkIndex: 0,
                    chunkData: Data([0x41]),
                    nonce: Data(repeating: 0, count: 12),
                    rawSize: 1
                )
            )
        )
    }

    func testCompletionProofShapeAndCancelMessageBounds() throws {
        _ = try admit(
            CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferID,
                receivedBytes: 1,
                fileSha256: Data(repeating: 0x01, count: 32),
                merkleRoot: Data(repeating: 0x02, count: 32),
                merkleRootSignature: Data(repeating: 0x03, count: 32),
                merkleRootSignatureAlg: CrossNetworkMerkleAuth.signatureAlgV1
            )
        )
        XCTAssertThrowsError(
            try admit(
                CrossNetworkFileTransferMessage(
                    op: .complete,
                    transferId: transferID,
                    fileSha256: Data(repeating: 0, count: 31)
                )
            )
        )
        XCTAssertThrowsError(
            try admit(
                CrossNetworkFileTransferMessage(
                    op: .complete,
                    transferId: transferID,
                    merkleRoot: Data(repeating: 0, count: 32)
                )
            )
        )
        XCTAssertThrowsError(
            try admit(
                CrossNetworkFileTransferMessage(
                    op: .complete,
                    transferId: transferID,
                    missingChunks: [0]
                )
            )
        )

        _ = try admit(cancel(message: String(repeating: "c", count: 512)))
        XCTAssertThrowsError(
            try admit(cancel(message: String(repeating: "c", count: 513)))
        )
    }

    func testAllResponseOperationsAreRejectedFromRequestAdmission() {
        for operation in [
            CrossNetworkFileTransferOp.error,
            .metadataAck,
            .chunkAck,
            .completeAck
        ] {
            XCTAssertThrowsError(
                try admit(
                    CrossNetworkFileTransferMessage(
                        op: operation,
                        transferId: transferID
                    )
                )
            )
        }
    }

    func testResponseAdmissionAcceptsCanonicalV1Shapes() throws {
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .metadataAck,
                    transferId: transferID
                )
            )
        )
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .chunkAck,
                    transferId: transferID,
                    chunkIndex: 0,
                    receivedBytes: 1
                )
            )
        )
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .chunkAck,
                    transferId: transferID,
                    missingChunks: [0, 2, 4],
                    message: "missingChunks"
                )
            )
        )
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 1,
                    fileSha256: Data(repeating: 0x01, count: 32)
                )
            )
        )
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: transferID,
                    chunkIndex: 0,
                    message: "rejected"
                )
            )
        )
    }

    func testResponseAdmissionRejectsCrossOperationPayloads() {
        for response in [
            CrossNetworkFileTransferMessage(
                op: .metadataAck,
                transferId: transferID,
                chunkData: Data([0x01])
            ),
            CrossNetworkFileTransferMessage(
                op: .completeAck,
                transferId: transferID,
                receivedBytes: 1,
                fileSha256: Data(repeating: 0x01, count: 32),
                missingChunks: [0]
            ),
            CrossNetworkFileTransferMessage(
                op: .error,
                transferId: transferID,
                fileName: "payload.bin",
                message: "rejected"
            )
        ] {
            XCTAssertThrowsError(
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(response)
            )
        }
    }

    func testResponseAdmissionRejectsInvalidCompletionDimensions() {
        for digestSize in [31, 33] {
            XCTAssertThrowsError(
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(
                        CrossNetworkFileTransferMessage(
                            op: .completeAck,
                            transferId: transferID,
                            receivedBytes: 1,
                            fileSha256: Data(repeating: 0x01, count: digestSize)
                        )
                    )
            )
        }
        for receivedBytes in [-1, CrossNetworkFileTransferInboundAdmissionPolicy.maximumFileSize + 1] {
            XCTAssertThrowsError(
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(
                        CrossNetworkFileTransferMessage(
                            op: .completeAck,
                            transferId: transferID,
                            receivedBytes: receivedBytes,
                            fileSha256: Data(repeating: 0x01, count: 32)
                        )
                    )
            )
        }
    }

    func testResponseAdmissionRejectsInvalidMissingChunkVariants() {
        let invalidMissingChunkLists = [
            [],
            [0, 0],
            [1, 0],
            [CrossNetworkFileTransferInboundAdmissionPolicy.maximumChunkCount],
            Array(
                0...CrossNetworkFileTransferInboundAdmissionPolicy.maximumMissingChunkCount
            )
        ]
        for missingChunks in invalidMissingChunkLists {
            XCTAssertThrowsError(
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(
                        CrossNetworkFileTransferMessage(
                            op: .chunkAck,
                            transferId: transferID,
                            missingChunks: missingChunks,
                            message: "missingChunks"
                        )
                    )
            )
        }
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .chunkAck,
                    transferId: transferID,
                    chunkIndex: 0,
                    receivedBytes: 1,
                    missingChunks: [0],
                    message: "missingChunks"
                )
            )
        )
    }

    func testResponseAdmissionBoundsErrorStatusAndChunkIndex() throws {
        XCTAssertNoThrow(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: transferID,
                    message: String(repeating: "e", count: 512)
                )
            )
        )
        for invalidMessage in ["", "\n", String(repeating: "e", count: 513)] {
            XCTAssertThrowsError(
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(
                        CrossNetworkFileTransferMessage(
                            op: .error,
                            transferId: transferID,
                            message: invalidMessage
                        )
                    )
            )
        }
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: transferID,
                    chunkIndex: CrossNetworkFileTransferInboundAdmissionPolicy
                        .maximumChunkCount,
                    message: "rejected"
                )
            )
        )
    }

    func testEnvelopeAdmissionRejectsNilUUIDAndUnsupportedVersion() {
        let nilTransferID = "00000000-0000-0000-0000-000000000000"

        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
                for: CrossNetworkFileTransferMessage(
                    op: .cancel,
                    transferId: nilTransferID
                ),
                encodedPayloadByteCount: 1
            )
        )
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    op: .metadataAck,
                    transferId: nilTransferID
                )
            )
        )
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
                for: CrossNetworkFileTransferMessage(
                    version: 2,
                    op: .cancel,
                    transferId: transferID
                ),
                encodedPayloadByteCount: 1
            )
        )
        XCTAssertThrowsError(
            try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(
                CrossNetworkFileTransferMessage(
                    version: 2,
                    op: .metadataAck,
                    transferId: transferID
                )
            )
        )
    }

    func testStrictWireDecoderAcceptsCanonicalEncodedMessage() throws {
        let original = cancel(message: "cancelled")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try CrossNetworkFileTransferWireDecoder.decode(encoded)

        XCTAssertEqual(decoded.op, .cancel)
        XCTAssertEqual(decoded.transferId, transferID)
        XCTAssertEqual(decoded.message, "cancelled")
    }

    func testStrictWireDecoderRejectsUnknownAndDuplicateTopLevelFields() {
        let unknown = Data(
            "{\"version\":1,\"op\":\"cancel\",\"transferId\":\"\(transferID)\",\"future\":true}"
                .utf8
        )
        let duplicate = Data(
            "{\"version\":1,\"op\":\"cancel\",\"\\u006f\\u0070\":\"cancel\",\"transferId\":\"\(transferID)\"}"
                .utf8
        )

        XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(unknown))
        XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(duplicate))
    }

    func testStrictWireDecoderRejectsMalformedOrNonObjectEnvelopes() {
        for encoded in [
            Data("[]".utf8),
            Data("{}".utf8),
            Data("{\"version\":1,\"op\":\"cancel\"}".utf8),
            Data("{\"version\":1,\"op\":\"cancel\",\"transferId\":\"\(transferID)\"} trailing".utf8),
        ] {
            XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(encoded))
        }
    }

    func testStrictWireDecoderBoundsNestingBeforeModelDecode() {
        let nested = String(repeating: "[", count: 18)
            + "0"
            + String(repeating: "]", count: 18)
        let encoded = Data(
            "{\"version\":1,\"op\":\"cancel\",\"transferId\":\"\(transferID)\",\"message\":\(nested)}"
                .utf8
        )

        XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(encoded))
    }

    func testStrictWireDecoderRejectsUnknownTopLevelFieldImmediately() {
        var components = [
            "\"version\":1",
            "\"op\":\"cancel\"",
            "\"transferId\":\"\(transferID)\"",
        ]
        components.append(contentsOf: (0..<29).map { "\"unknown\($0)\":null" })
        let encoded = Data(("{" + components.joined(separator: ",") + "}").utf8)

        XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(encoded))
    }

    func testStrictWireDecoderRejectsMoreThan512ArrayElementsBeforeModelDecode() {
        let values = Array(repeating: "0", count: 513).joined(separator: ",")
        let encoded = Data(
            "{\"version\":1,\"op\":\"chunkAck\",\"transferId\":\"\(transferID)\",\"missingChunks\":[\(values)],\"message\":\"missingChunks\"}"
                .utf8
        )

        XCTAssertThrowsError(try CrossNetworkFileTransferWireDecoder.decode(encoded))
    }

    func testStrictWireDecoderRequiresCanonicalBase64ForBinaryFields() throws {
        let canonical = Data(
            "{\"version\":1,\"op\":\"chunk\",\"transferId\":\"\(transferID)\",\"chunkData\":\"AQ==\"}"
                .utf8
        )
        let decoded = try CrossNetworkFileTransferWireDecoder.decode(canonical)

        XCTAssertEqual(decoded.chunkData, Data([0x01]))

        for nonCanonical in ["AQ===", "AR=="] {
            let encoded = Data(
                "{\"version\":1,\"op\":\"chunk\",\"transferId\":\"\(transferID)\",\"chunkData\":\"\(nonCanonical)\"}"
                    .utf8
            )
            XCTAssertThrowsError(
                try CrossNetworkFileTransferWireDecoder.decode(encoded),
                "Expected non-canonical Base64 to be rejected: \(nonCanonical)"
            )
        }
    }

    func testReservationLedgerCountsActiveAndQueuedOperations() throws {
        var ledger = CrossNetworkFileTransferOperationReservationLedger()
        var reservations: [CrossNetworkFileTransferOperationReservationLedger.Reservation] = []

        for _ in 0..<CrossNetworkFileTransferInboundAdmissionPolicy.maximumQueuedOperationCount {
            reservations.append(try ledger.reserve(byteCount: 1))
        }

        XCTAssertEqual(
            ledger.reservationCount,
            CrossNetworkFileTransferInboundAdmissionPolicy.maximumQueuedOperationCount
        )
        XCTAssertEqual(ledger.retainedByteCount, reservations.count)
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertThrowsError(try ledger.reserve(byteCount: 1))

        for reservation in reservations {
            XCTAssertTrue(ledger.release(reservation))
        }
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.retainedByteCount, 0)
    }

    func testReservationLedgerRetainedByteBoundaryIsExact() throws {
        var ledger = CrossNetworkFileTransferOperationReservationLedger()
        let maximum = CrossNetworkFileTransferInboundAdmissionPolicy
            .maximumRetainedOperationBytes
        let reservation = try ledger.reserve(byteCount: maximum)

        XCTAssertEqual(ledger.retainedByteCount, maximum)
        XCTAssertThrowsError(try ledger.reserve(byteCount: 1))
        XCTAssertThrowsError(try ledger.reserve(byteCount: Int.max))
        XCTAssertTrue(ledger.release(reservation))
        XCTAssertTrue(ledger.isEmpty)
    }

    func testReservationLedgerRejectsInvalidByteCounts() {
        var ledger = CrossNetworkFileTransferOperationReservationLedger()

        XCTAssertThrowsError(try ledger.reserve(byteCount: 0))
        XCTAssertThrowsError(try ledger.reserve(byteCount: -1))
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.retainedByteCount, 0)
    }

    func testReservationLedgerDuplicateReleaseDoesNotChangeAccounting() throws {
        var ledger = CrossNetworkFileTransferOperationReservationLedger()
        let reservation = try ledger.reserve(byteCount: 42)

        XCTAssertTrue(ledger.release(reservation))
        XCTAssertFalse(ledger.release(reservation))
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.retainedByteCount, 0)
    }

    func testReservationLedgerRejectsForeignOwnerToken() throws {
        var ownerLedger = CrossNetworkFileTransferOperationReservationLedger()
        var foreignLedger = CrossNetworkFileTransferOperationReservationLedger()
        let ownerReservation = try ownerLedger.reserve(byteCount: 17)
        let foreignReservation = try foreignLedger.reserve(byteCount: 29)

        XCTAssertFalse(ownerLedger.release(foreignReservation))
        XCTAssertTrue(ownerLedger.contains(ownerReservation))
        XCTAssertEqual(ownerLedger.reservationCount, 1)
        XCTAssertEqual(ownerLedger.retainedByteCount, 17)
        XCTAssertTrue(ownerLedger.release(ownerReservation))
        XCTAssertTrue(foreignLedger.release(foreignReservation))
    }

    func testReservationLedgerReleasesOnlyTheExactOperation() throws {
        var ledger = CrossNetworkFileTransferOperationReservationLedger()
        let active = try ledger.reserve(byteCount: 1_024)
        let queued = try ledger.reserve(byteCount: 2_048)

        XCTAssertTrue(ledger.release(queued))
        XCTAssertTrue(ledger.contains(active))
        XCTAssertEqual(ledger.reservationCount, 1)
        XCTAssertEqual(ledger.retainedByteCount, 1_024)
        XCTAssertTrue(ledger.release(active))
        XCTAssertTrue(ledger.isEmpty)
    }

    private func admit(_ message: CrossNetworkFileTransferMessage) throws -> Int {
        try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
            for: message,
            encodedPayloadByteCount: 1_024
        )
    }

    private func metadata(
        fileName: String = "payload.bin",
        senderDeviceID: String = "sender",
        senderDeviceName: String? = "Sender",
        chunkData: Data? = nil,
        encryption: String? = nil,
        relativePath: String? = nil
    ) -> CrossNetworkFileTransferMessage {
        CrossNetworkFileTransferMessage(
            op: .metadata,
            transferId: transferID,
            senderDeviceId: senderDeviceID,
            senderDeviceName: senderDeviceName,
            fileName: fileName,
            fileSize: 1,
            chunkSize: 1,
            totalChunks: 1,
            chunkData: chunkData,
            encryption: encryption,
            relativePath: relativePath
        )
    }

    private func chunk(
        data: Data,
        digest: Data? = nil,
        rawSize: Int? = nil
    ) -> CrossNetworkFileTransferMessage {
        CrossNetworkFileTransferMessage(
            op: .chunk,
            transferId: transferID,
            chunkIndex: 0,
            chunkData: data,
            chunkSha256: digest,
            rawSize: rawSize ?? data.count
        )
    }

    private func cancel(message: String?) -> CrossNetworkFileTransferMessage {
        CrossNetworkFileTransferMessage(
            op: .cancel,
            transferId: transferID,
            message: message
        )
    }
}
