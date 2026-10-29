import XCTest
import CryptoKit
@testable import SkyBridgeCore

final class QUICReliableFramePolicyTests: XCTestCase {
    func testControlDeclaredLengthRejectsMaximumPlusOneBeforeBody() throws {
        XCTAssertEqual(
            try QUICReliableFramePolicy.validatedPayloadByteCount(
                kind: .control,
                encodedLength: UInt32(QUICReliableFramePolicy.maximumControlPayloadByteCount)
            ),
            QUICReliableFramePolicy.maximumControlPayloadByteCount
        )

        let oversized = UInt32(QUICReliableFramePolicy.maximumControlPayloadByteCount + 1)
        XCTAssertThrowsError(
            try QUICReliableFramePolicy.validatedPayloadByteCount(
                kind: .control,
                encodedLength: oversized
            )
        ) { error in
            XCTAssertEqual(
                error as? QUICReliableFramePolicyError,
                .payloadTooLarge(
                    kind: QUICReliableFramePolicy.Kind.control.rawValue,
                    actual: Int(oversized),
                    maximum: QUICReliableFramePolicy.maximumControlPayloadByteCount
                )
            )
        }

        XCTAssertThrowsError(
            try QUICReliableFramePolicy.validatedPayloadByteCount(
                kind: .control,
                encodedLength: .max
            )
        )
    }

    func testFileFrameDeclaredLengthHasExactBound() throws {
        let maximum = QUICReliableFramePolicy.maximumFileChunkPayloadByteCount
        XCTAssertEqual(
            try QUICReliableFramePolicy.validatedPayloadByteCount(
                kind: .fileChunk,
                encodedLength: UInt32(maximum)
            ),
            maximum
        )
        XCTAssertThrowsError(
            try QUICReliableFramePolicy.validatedPayloadByteCount(
                kind: .fileChunk,
                encodedLength: UInt32(maximum + 1)
            )
        )
    }

    func testFileChunkDataAndChecksumBoundaries() throws {
        try QUICReliableFramePolicy.validateFileChunk(
            dataByteCount: QUICReliableFramePolicy.maximumEncodedFileChunkByteCount,
            checksumByteCount: nil
        )
        try QUICReliableFramePolicy.validateFileChunk(
            dataByteCount: QUICReliableFramePolicy.maximumEncodedFileChunkByteCount,
            checksumByteCount: QUICReliableFramePolicy.checksumByteCount
        )

        XCTAssertThrowsError(
            try QUICReliableFramePolicy.validateFileChunk(
                dataByteCount: QUICReliableFramePolicy.maximumEncodedFileChunkByteCount + 1,
                checksumByteCount: nil
            )
        )
        for invalidChecksumByteCount in [31, 33] {
            XCTAssertThrowsError(
                try QUICReliableFramePolicy.validateFileChunk(
                    dataByteCount: 1,
                    checksumByteCount: invalidChecksumByteCount
                )
            )
        }
    }

    func testParserValidatesDeclaredLengthBeforeWaitingForBody() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/QUICTransportService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func parseReliableFrames("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func decodeUUID(",
                range: start.upperBound..<source.endIndex
            )
        )
        let parser = String(source[start.lowerBound..<end.lowerBound])
        let validation = try XCTUnwrap(
            parser.range(of: "QUICReliableFramePolicy.validatedPayloadByteCount(")
        )
        let bodyWait = try XCTUnwrap(parser.range(of: "guard available >= frameTotal else"))

        XCTAssertLessThan(validation.lowerBound, bodyWait.lowerBound)
        XCTAssertTrue(parser.contains("rejectReliableProtocolViolation("))
        XCTAssertTrue(parser.contains("generation: UUID"))
        XCTAssertTrue(source.contains("guard isCurrentConnection(conn, generation: generation)"))
    }

    func testWorstCaseRawChunkEncodingFitsLegacyEnvelopeWithoutSlashExpansion() throws {
        let raw = Data(repeating: 0xff, count: P2PConstants.fileChunkSize)
        let hash = Data(SHA256.hash(data: raw))
        let chunk = P2PFileChunk(
            transferId: UUID(),
            chunkIndex: 0,
            filePath: "",
            offset: 0,
            data: raw,
            chunkHash: hash,
            isLastChunk: true
        )

        let encoded = try P2PFileChunkWireCodec.encode(chunk)

        XCTAssertLessThanOrEqual(
            encoded.count,
            QUICReliableFramePolicy.maximumEncodedFileChunkByteCount
        )
        XCTAssertFalse(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("\\/"))
        XCTAssertEqual(try P2PFileChunkWireCodec.decode(encoded), chunk)

        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = .sortedKeys
        let legacyEncoded = try legacyEncoder.encode(chunk)
        XCTAssertLessThanOrEqual(
            legacyEncoded.count,
            QUICReliableFramePolicy.maximumEncodedFileChunkByteCount
        )
        XCTAssertEqual(try P2PFileChunkWireCodec.decode(legacyEncoded), chunk)
    }

    func testRawFileChunkProtocolBoundaryRejectsMaximumPlusOne() throws {
        try P2PFileChunkWireCodec.validateRawChunkByteCount(P2PConstants.fileChunkSize)
        XCTAssertThrowsError(
            try P2PFileChunkWireCodec.validateRawChunkByteCount(P2PConstants.fileChunkSize + 1)
        )
    }
}
