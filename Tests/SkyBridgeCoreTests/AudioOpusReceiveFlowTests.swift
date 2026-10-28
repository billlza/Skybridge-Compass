import CryptoKit
import Foundation
import XCTest
import SkyBridgeOpus
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class AudioOpusReceiveFlowTests: XCTestCase {
    private struct Fixtures: Decodable { let streams: [Fixture] }
    private struct Fixture: Decodable {
        let name: String; let shouldComplete: Bool; let expectedPCMFrames: UInt64
        let channels: UInt8; let bitrate: UInt32; let preSkipFrames: UInt16
        let expectedDecodedSHA256: String?; let packetBase64: [String]
        func packets() throws -> [Data] { try packetBase64.map { try XCTUnwrap(Data(base64Encoded: $0)) } }
    }
    private enum EnqueueFailure: Error { case rejected }
    private func fixtures() throws -> [Fixture] {
        try ["opus-decoder-v1", "opus-product-encoder-v1"].flatMap { name in
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
            return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url)).streams
        }
    }
    private func medium() throws -> Fixture {
        try XCTUnwrap(fixtures().first { $0.name == "padded-48913-192000-constant-separate" })
    }
    private func flow(_ value: Fixture, skip: UInt16? = nil, buffering: AudioStreamingOpusBuffering = .legacy) throws -> AudioOpusReceiveFlow {
        let format = try AudioStreamingOpusFormat(channels: value.channels, bitrate: value.bitrate)
        let flow = try AudioOpusReceiveFlow(offer: roundTrip(.init(streamID: UUID(), body: buffering == .bufferedFile
            ? .bufferedOpusFileOffer(format) : .opusOffer(source: .originalFile, format: format))))
        try flow.configure(roundTrip(.init(streamID: flow.streamID, body: .opusConfiguration(preSkipFrames: skip ?? value.preSkipFrames))))
        return flow
    }
    private func roundTrip(_ message: AudioStreamingMessage) throws -> AudioStreamingMessage {
        try AudioStreamingWire.decode(AudioStreamingWire.encode(message))
    }
    private func packet(_ bytes: Data, _ index: Int, _ flow: AudioOpusReceiveFlow) throws -> AudioStreamingMessage {
        try roundTrip(.init(streamID: flow.streamID, body: .opusData(sequence: UInt64(index), bytes: bytes)))
    }
    private func end(_ value: Fixture, _ flow: AudioOpusReceiveFlow) throws -> AudioStreamingMessage {
        let packets = try value.packets(), bytes = packets.reduce(into: Data()) { $0.append($1) }
        return try roundTrip(.init(streamID: flow.streamID, body: .opusEnd(sourceFrames: value.expectedPCMFrames,
            packetCount: UInt64(packets.count), totalEncodedBytes: UInt64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))))
    }

    func testRecordedPacketsPassThroughBoundedAccountingAndExactProductDecoder() throws {
        let values = try fixtures().filter(\.shouldComplete)
        XCTAssertEqual(values.count, 36)
        for value in values {
            let flow = try flow(value), packets = try value.packets()
            var pcm = Data()
            let enqueue: (SkyBridgeOpusDecodedChunk) throws -> Void = { chunk in
                XCTAssertEqual(chunk.firstPCMFrame, UInt64(pcm.count / (Int(value.channels) * 2)))
                pcm.append(chunk.pcm16LE)
            }
            for (index, bytes) in packets.enumerated() {
                try flow.receive(packet(bytes, index, flow), enqueue: enqueue)
                XCTAssertLessThanOrEqual(flow.receivedEncodedBytes - flow.retiredEncodedBytes, UInt64(flow.windowBytes))
                XCTAssertLessThanOrEqual(flow.bufferedCodecFrames, 960)
                // Explicit output substitute: this is bookkeeping, not physical playback proof.
                _ = try flow.retire(sourceFrames: flow.enqueuedSourceFrames)
            }
            XCTAssertNil(flow.expectedSourceFrames)
            XCTAssertNil(flow.verifiedDigest)
            XCTAssertEqual(try flow.verifyEnd(end(value, flow), enqueue: enqueue), value.expectedPCMFrames)
            XCTAssertEqual(flow.state, .contentVerified)
            XCTAssertLessThan(flow.retiredEncodedBytes, flow.receivedEncodedBytes)
            _ = try flow.retire(sourceFrames: flow.enqueuedSourceFrames)
            XCTAssertEqual(try flow.didComplete(sourceFrames: value.expectedPCMFrames), flow.receivedEncodedBytes)
            XCTAssertEqual(flow.state, .completed)
            XCTAssertEqual(pcm.count, Int(value.expectedPCMFrames) * Int(value.channels) * 2)
            XCTAssertEqual(SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined(), value.expectedDecodedSHA256)
            XCTAssertEqual(flow.bufferedCodecFrames, 0)
            XCTAssertEqual(flow.trailingCodecPaddingFrames, UInt32(packets.count * 960 - Int(value.preSkipFrames) - Int(value.expectedPCMFrames)))
        }
    }

    func testCreditRequiresRetiredFramesAndWindowOverflowTerminates() throws {
        let value = try medium(), packets = try value.packets(), flow = try flow(value)
        try flow.receive(packet(packets[0], 0, flow), enqueue: { _ in XCTFail("First packet must remain held") })
        XCTAssertNil(try flow.retire(sourceFrames: 0))
        try flow.receive(packet(packets[1], 1, flow), enqueue: { _ in })
        XCTAssertEqual(flow.enqueuedSourceFrames, 648)
        XCTAssertNil(try flow.retire(sourceFrames: 647))
        XCTAssertEqual(try flow.retire(sourceFrames: 648), 480)
        XCTAssertNil(try flow.retire(sourceFrames: 648))
        flow.cancel()

        let bounded = try self.flow(value)
        for index in 0..<16 { try bounded.receive(packet(packets[index], index, bounded), enqueue: { _ in }) }
        XCTAssertEqual(bounded.receivedEncodedBytes, UInt64(bounded.windowBytes))
        XCTAssertThrowsError(try bounded.receive(packet(packets[16], 16, bounded), enqueue: { _ in XCTFail("Over-window PCM was delivered") })) {
            XCTAssertEqual($0 as? AudioOpusReceiveError, .windowExceeded)
        }
        XCTAssertEqual(bounded.receivedPackets, 16)
        XCTAssertEqual(bounded.state, .failed)
        XCTAssertEqual(bounded.bufferedCodecFrames, 0)
    }

    func testEntirelySkippedPacketsRetireWithoutInventingSourceProgress() throws {
        let value = try medium(), packets = try value.packets(), flow = try flow(value, skip: 3840)
        for index in 0..<4 {
            try flow.receive(packet(packets[index], index, flow), enqueue: { _ in XCTFail("Encoder delay was rendered") })
            XCTAssertEqual(try flow.retire(sourceFrames: 0), UInt64(index + 1) * 480)
            XCTAssertEqual(flow.enqueuedSourceFrames, 0)
            XCTAssertEqual(flow.retiredSourceFrames, 0)
        }
        try flow.receive(packet(packets[4], 4, flow), enqueue: { _ in XCTFail("Final packet holdback missing") })
        XCTAssertNil(try flow.retire(sourceFrames: 0))
        flow.cancel()
    }

    func testBufferedWindowRejectsSixtyFifthUnretiredPacket() throws {
        let value = try medium(), flow = try flow(value, buffering: .bufferedFile)
        let bytes = try value.packets()[0]
        // Repeated real codec payload isolates queue accounting; this is not a finite-file
        // fidelity test and deliberately has no content/end receipt.
        for index in 0..<64 { try flow.receive(packet(bytes, index, flow), enqueue: { _ in }) }
        XCTAssertEqual(flow.retiredEncodedBytes, 0)
        XCTAssertEqual(flow.windowBytes, 64 * 480)
        XCTAssertEqual(flow.receivedEncodedBytes, UInt64(flow.windowBytes))
        XCTAssertThrowsError(try flow.receive(packet(bytes, 64, flow), enqueue: { _ in XCTFail("Queue overflow reached output") })) {
            XCTAssertEqual($0 as? AudioOpusReceiveError, .windowExceeded)
        }
        XCTAssertEqual(flow.receivedPackets, 64)
        XCTAssertEqual(flow.state, .failed)
        XCTAssertEqual(flow.bufferedCodecFrames, 0)
    }

    func testBufferedRecordedFileKeepsFinalCreditUntilExactNativeCompletion() throws {
        let value = try medium(), flow = try flow(value, buffering: .bufferedFile)
        let packets = try value.packets()
        for (index, bytes) in packets.enumerated() { try flow.receive(packet(bytes, index, flow), enqueue: { _ in }) }
        XCTAssertEqual(flow.retiredEncodedBytes, 0)
        XCTAssertEqual(try flow.verifyEnd(end(value, flow), enqueue: { _ in }), value.expectedPCMFrames)
        XCTAssertThrowsError(try flow.didComplete(sourceFrames: value.expectedPCMFrames - 1))
        XCTAssertEqual(flow.state, .failed)

        let complete = try self.flow(value, buffering: .bufferedFile)
        for (index, bytes) in packets.enumerated() { try complete.receive(packet(bytes, index, complete), enqueue: { _ in }) }
        _ = try complete.verifyEnd(end(value, complete), enqueue: { _ in })
        _ = try complete.retire(sourceFrames: value.expectedPCMFrames)
        XCTAssertEqual(complete.retiredEncodedBytes, UInt64(packets.count - 1) * 480)
        XCTAssertEqual(try complete.didComplete(sourceFrames: value.expectedPCMFrames), UInt64(packets.count) * 480)
        XCTAssertEqual(complete.state, .completed)
    }

    func testExactPacketBoundaryKeepsFinalCreditUntilNativeCompletion() throws {
        let value = try medium(), first = try value.packets()[0], flow = try flow(value)
        // Synthetic finite substream from one real packet: 960 decoded frames minus 312 delay.
        // This tests completion accounting, not the original recording's finite source extent.
        try flow.receive(packet(first, 0, flow), enqueue: { _ in XCTFail("Final packet was not held") })
        let end = AudioStreamingMessage(streamID: flow.streamID, body: .opusEnd(sourceFrames: 648,
            packetCount: 1, totalEncodedBytes: 480, sha256: Data(SHA256.hash(data: first))))
        XCTAssertEqual(try flow.verifyEnd(roundTrip(end), enqueue: { _ in }), 648)
        XCTAssertEqual(flow.trailingCodecPaddingFrames, 0)
        XCTAssertNil(try flow.retire(sourceFrames: 648))
        XCTAssertEqual(flow.retiredEncodedBytes, 0)
        XCTAssertEqual(flow.state, .contentVerified)
        XCTAssertEqual(try flow.didComplete(sourceFrames: 648), 480)
        XCTAssertEqual(flow.state, .completed)
    }

    func testEnqueueErrorsDoNotCommitCreditHashOrCompletion() throws {
        let value = try medium(), packets = try value.packets(), flow = try flow(value)
        try flow.receive(packet(packets[0], 0, flow), enqueue: { _ in })
        XCTAssertThrowsError(try flow.receive(packet(packets[1], 1, flow), enqueue: { _ in throw EnqueueFailure.rejected })) {
            XCTAssertEqual($0 as? EnqueueFailure, .rejected)
        }
        XCTAssertEqual(flow.receivedPackets, 1); XCTAssertEqual(flow.retiredEncodedBytes, 0)
        XCTAssertEqual(flow.enqueuedSourceFrames, 0); XCTAssertNil(flow.verifiedDigest)
        XCTAssertEqual(flow.state, .failed); XCTAssertEqual(flow.bufferedCodecFrames, 0)

        let final = try self.flow(value)
        for (index, bytes) in packets.enumerated() {
            try final.receive(packet(bytes, index, final), enqueue: { _ in })
            _ = try final.retire(sourceFrames: final.enqueuedSourceFrames)
        }
        XCTAssertThrowsError(try final.verifyEnd(end(value, final), enqueue: { _ in throw EnqueueFailure.rejected })) {
            XCTAssertEqual($0 as? EnqueueFailure, .rejected)
        }
        XCTAssertEqual(final.state, .failed); XCTAssertNil(final.expectedSourceFrames); XCTAssertNil(final.verifiedDigest)
        XCTAssertEqual(final.bufferedCodecFrames, 0)
    }

    func testMissingTailWrongDigestOrCountersCannotVerifyContent() throws {
        let incomplete = try XCTUnwrap(fixtures().first { !$0.shouldComplete }), flow = try flow(incomplete)
        for (index, bytes) in try incomplete.packets().enumerated() {
            try flow.receive(packet(bytes, index, flow), enqueue: { _ in })
            _ = try flow.retire(sourceFrames: flow.enqueuedSourceFrames)
        }
        XCTAssertThrowsError(try flow.verifyEnd(end(incomplete, flow), enqueue: { _ in XCTFail("Missing tail was fabricated") })) {
            XCTAssertEqual($0 as? SkyBridgeOpusStreamError, .invalidEnd)
        }
        XCTAssertEqual(flow.state, .failed); XCTAssertNil(flow.verifiedDigest)

        let value = try medium(), first = try value.packets()[0]
        for body in [AudioStreamingMessage.Body.opusEnd(sourceFrames: 648, packetCount: 1, totalEncodedBytes: 480, sha256: Data(repeating: 0, count: 32)),
            .opusEnd(sourceFrames: 648, packetCount: 2, totalEncodedBytes: 960, sha256: Data(SHA256.hash(data: first)))] {
            let rejected = try self.flow(value)
            try rejected.receive(packet(first, 0, rejected), enqueue: { _ in })
            XCTAssertThrowsError(try rejected.verifyEnd(.init(streamID: rejected.streamID, body: body), enqueue: { _ in XCTFail("Invalid end delivered PCM") }))
            XCTAssertEqual(rejected.state, .failed); XCTAssertEqual(rejected.bufferedCodecFrames, 0)
        }
    }

    func testWrongOwnerReplayReconfigurationAndInvalidProgressAreTerminal() throws {
        let value = try medium(), first = try value.packets()[0]
        let wrong = try flow(value)
        XCTAssertThrowsError(try wrong.receive(.init(streamID: UUID(), body: .opusData(sequence: 0, bytes: first)), enqueue: { _ in }))
        XCTAssertEqual(wrong.state, .failed)
        let replay = try flow(value)
        try replay.receive(packet(first, 0, replay), enqueue: { _ in })
        XCTAssertThrowsError(try replay.receive(packet(first, 0, replay), enqueue: { _ in }))
        XCTAssertEqual(replay.state, .failed)
        let reconfigured = try flow(value)
        XCTAssertThrowsError(try reconfigured.configure(.init(streamID: reconfigured.streamID, body: .opusConfiguration(preSkipFrames: 312))))
        XCTAssertEqual(reconfigured.state, .failed)
        let progress = try flow(value)
        XCTAssertThrowsError(try progress.retire(sourceFrames: 1))
        XCTAssertEqual(progress.state, .failed)
        let premature = try flow(value)
        XCTAssertThrowsError(try premature.didComplete(sourceFrames: 0))
        XCTAssertEqual(premature.state, .failed)
        let cancelled = try flow(value)
        try cancelled.receive(packet(first, 0, cancelled), enqueue: { _ in })
        cancelled.cancel(); cancelled.cancel()
        XCTAssertEqual(cancelled.state, .cancelled); XCTAssertEqual(cancelled.bufferedCodecFrames, 0)
        XCTAssertThrowsError(try cancelled.receive(packet(first, 1, cancelled), enqueue: { _ in }))
        XCTAssertEqual(cancelled.state, .cancelled)
    }
}
