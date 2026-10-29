import Foundation
import XCTest
@testable import SkyBridgeCameraKit

final class RTSPParserTests: XCTestCase {
    func testParsesSplitResponseAndBody() throws {
        var parser = RTSPMessageParser()
        let message = Data(
            "RTSP/1.0 200 OK\r\nCSeq: 7\r\nContent-Length: 4\r\n\r\ntest".utf8
        )
        XCTAssertTrue(try parser.append(message.prefix(19)).isEmpty)
        let events = try parser.append(message.dropFirst(19))
        XCTAssertEqual(events.count, 1)
        guard case let .response(response) = try XCTUnwrap(events.first) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.cSeq, 7)
        XCTAssertEqual(response.body, Data("test".utf8))
    }

    func testParsesCoalescedInterleavedAndResponseEvents() throws {
        var parser = RTSPMessageParser()
        var bytes = Data([0x24, 0, 0, 4, 1, 2, 3, 4])
        bytes.append(Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8))
        let events = try parser.append(bytes)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], .interleaved(.init(channel: 0, payload: Data([1, 2, 3, 4]))))
        guard case let .response(response) = events[1] else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.statusCode, 200)
    }

    func testRejectsConflictingLengthFoldedHeadersAndShortInterleavedFrames() throws {
        var conflicting = RTSPMessageParser()
        XCTAssertThrowsError(try conflicting.append(Data(
            "RTSP/1.0 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx".utf8
        )))

        var folded = RTSPMessageParser()
        XCTAssertThrowsError(try folded.append(Data(
            "RTSP/1.0 200 OK\r\nX-Test: first\r\n second\r\n\r\n".utf8
        )))

        var shortFrame = RTSPMessageParser()
        XCTAssertThrowsError(try shortFrame.append(Data([0x24, 0, 0, 3, 1, 2, 3])))
    }

    func testBoundsSingleChunkAccumulatedBufferAndEventAmplification() throws {
        let limits = RTSPParserLimits(
            maximumHeaderBytes: 64,
            maximumBodyBytes: 64,
            maximumBufferedBytes: 128,
            maximumEventsPerAppend: 1
        )
        var oversizedChunk = RTSPMessageParser(limits: limits)
        XCTAssertThrowsError(try oversizedChunk.append(Data(repeating: 65, count: 129)))

        var accumulated = RTSPMessageParser(limits: limits)
        XCTAssertNoThrow(try accumulated.append(Data(repeating: 65, count: 60)))
        XCTAssertThrowsError(try accumulated.append(Data(repeating: 65, count: 69)))

        var amplified = RTSPMessageParser(limits: limits)
        let frames = Data([
            0x24, 0, 0, 4, 1, 2, 3, 4,
            0x24, 1, 0, 4, 5, 6, 7, 8,
        ])
        XCTAssertThrowsError(try amplified.append(frames))
    }

    func testRejectsOversizedHeaderAndBodyBeforeAllocationProgresses() throws {
        let limits = RTSPParserLimits(
            maximumHeaderBytes: 64,
            maximumBodyBytes: 8,
            maximumBufferedBytes: 128
        )
        var headerParser = RTSPMessageParser(limits: limits)
        XCTAssertThrowsError(try headerParser.append(Data(repeating: 65, count: 65))) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .responseHeaderTooLarge(limit: 64))
        }

        var bodyParser = RTSPMessageParser(limits: limits)
        XCTAssertThrowsError(try bodyParser.append(Data(
            "RTSP/1.0 200 OK\r\nContent-Length: 9\r\n\r\n".utf8
        ))) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .responseBodyTooLarge(limit: 8))
        }
    }
}
