import CryptoKit
import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class AudioCaptureReceiveFlowTests: XCTestCase {
    private func format() throws -> AudioStreamingPCMFormat {
        try .init(sampleRate: 44_100, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3)
    }
    func testLowBitsStayInContentHashAndRetirementDoesNotChangeByteSequence() throws {
        let id = UUID(), format = try format()
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format, windowBytes: 12)
        let first = Data([1, 2, 0x80, 3, 4, 0x7f]), second = Data([0xff, 0, 0, 1, 0, 0])
        try flow.didEnqueue(streamID: id, offset: 0, bytes: first)
        try flow.didEnqueue(streamID: id, offset: 6, bytes: second)
        XCTAssertEqual(try flow.retire(sourceFrames: 1), 6)
        XCTAssertNil(try flow.retire(sourceFrames: 1))
        XCTAssertEqual(try flow.verifyEnd(streamID: id, totalBytes: 12, sha256: Data(SHA256.hash(data: first + second))), 2)
        XCTAssertThrowsError(try flow.didComplete(sourceFrames: 2))
        XCTAssertEqual(try flow.retire(sourceFrames: 2), 12)
        try flow.didComplete(sourceFrames: 2)
        XCTAssertEqual(flow.state, .completed)
    }
    func testWindowRequiresNativeRetirementNotJustEnqueue() throws {
        let id = UUID()
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format(), windowBytes: 6)
        let bytes = Data(repeating: 7, count: 6)
        try flow.didEnqueue(streamID: id, offset: 0, bytes: bytes)
        XCTAssertThrowsError(try flow.validateData(streamID: id, offset: 6, bytes: bytes)) {
            XCTAssertEqual($0 as? AudioCaptureReceiveError, .windowExceeded)
        }
        try flow.retire(sourceFrames: 1)
        try flow.didEnqueue(streamID: id, offset: 6, bytes: bytes)
    }
    func testDiscontinuityPartialFramesWrongOwnerAndOversizedChunksCannotMutateState() throws {
        let id = UUID()
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format(), windowBytes: 60)
        for (stream, offset, bytes) in [(UUID(), UInt64(0), Data(count: 6)), (id, 1, Data(count: 6)),
            (id, 0, Data(count: 5)), (id, 0, Data()), (id, 0, Data(count: 12_258))] {
            XCTAssertThrowsError(try flow.didEnqueue(streamID: stream, offset: offset, bytes: bytes))
            XCTAssertEqual(flow.receivedBytes, 0)
        }
    }
    func testEndIsExactAndNoDataOrSecondEndMayFollowVerification() throws {
        let id = UUID(), bytes = Data(repeating: 1, count: 6)
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format(), windowBytes: 6)
        try flow.didEnqueue(streamID: id, offset: 0, bytes: bytes)
        XCTAssertThrowsError(try flow.verifyEnd(streamID: id, totalBytes: 5, sha256: Data(SHA256.hash(data: bytes))))
        XCTAssertThrowsError(try flow.verifyEnd(streamID: id, totalBytes: 6, sha256: Data(repeating: 0, count: 32)))
        _ = try flow.verifyEnd(streamID: id, totalBytes: 6, sha256: Data(SHA256.hash(data: bytes)))
        XCTAssertThrowsError(try flow.didEnqueue(streamID: id, offset: 6, bytes: bytes))
        XCTAssertThrowsError(try flow.verifyEnd(streamID: id, totalBytes: 6, sha256: Data(SHA256.hash(data: bytes))))
    }
    func testNativeProgressCannotGoBackwardsOrIncludePadding() throws {
        let id = UUID()
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format(), windowBytes: 12)
        try flow.didEnqueue(streamID: id, offset: 0, bytes: Data(count: 12))
        try flow.retire(sourceFrames: 1)
        XCTAssertThrowsError(try flow.retire(sourceFrames: 0))
        XCTAssertThrowsError(try flow.retire(sourceFrames: 3))
        XCTAssertThrowsError(try flow.retire(sourceFrames: .max))
        XCTAssertEqual(flow.retiredBytes, 6)
    }
    func testEmptyCaptureStillRequiresItsExactDigestAndNativeNoAudioReceipt() throws {
        let id = UUID()
        var flow = try AudioCaptureReceiveFlow(streamID: id, format: format(), windowBytes: 6)
        XCTAssertThrowsError(try flow.didComplete(sourceFrames: 0))
        XCTAssertEqual(try flow.verifyEnd(streamID: id, totalBytes: 0, sha256: Data(SHA256.hash(data: Data()))), 0)
        try flow.didComplete(sourceFrames: 0)
    }
    func testWindowMustBePositiveBoundedAndFrameAligned() throws {
        for window: UInt32 in [0, 1, 7, 1_048_577] {
            XCTAssertThrowsError(try AudioCaptureReceiveFlow(streamID: UUID(), format: format(), windowBytes: window))
        }
    }
}
