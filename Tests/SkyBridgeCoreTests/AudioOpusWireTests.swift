import Foundation
import XCTest
import SkyBridgeProtocolCore

final class AudioOpusWireTests: XCTestCase {
    private struct Fixture: Decodable { let streamId: UUID; let vectors: [Vector] }
    private struct Vector: Decodable { let name: String; let opcode: UInt8; let hex: String; let expected: Expected }
    private struct Expected: Decodable {
        let source: UInt8?; let channels: UInt8?; let bitrate: UInt32?; let preSkipFrames: UInt16?
        let sequence: String?; let dataHex: String?; let sourceFrames: String?; let packetCount: String?
        let totalEncodedBytes: String?; let sha256Hex: String?
    }
    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            XCTUnwrap(bundle.url(forResource: "audio-opus-v1-vectors", withExtension: "json"))))
    }
    private func hex(_ text: String) throws -> Data {
        let value = Array(text)
        return try Data(stride(from: 0, to: value.count, by: 2).map {
            try XCTUnwrap(UInt8(String(value[$0...($0 + 1)]), radix: 16))
        })
    }
    private func number(_ text: String?) throws -> UInt64 { try XCTUnwrap(UInt64(XCTUnwrap(text))) }
    private func vector(_ name: String) throws -> Data { try hex(XCTUnwrap(fixture().vectors.first { $0.name == name }).hex) }
    private func expected(_ row: Vector) throws -> AudioStreamingMessage.Body {
        let e = row.expected
        switch row.opcode {
        case 11: return .opusOffer(source: try XCTUnwrap(AudioStreamingOpusSource(rawValue: XCTUnwrap(e.source))),
            format: try .init(channels: XCTUnwrap(e.channels), bitrate: XCTUnwrap(e.bitrate)))
        case 12: return .opusConfiguration(preSkipFrames: try XCTUnwrap(e.preSkipFrames))
        case 13: return .opusData(sequence: try number(e.sequence), bytes: try hex(XCTUnwrap(e.dataHex)))
        case 14: return .opusEnd(sourceFrames: try number(e.sourceFrames), packetCount: try number(e.packetCount),
            totalEncodedBytes: try number(e.totalEncodedBytes), sha256: try hex(XCTUnwrap(e.sha256Hex)))
        case 15: return .opusOutputReady
        default: throw AudioStreamingWireError.unknownOpcode(row.opcode)
        }
    }

    func testIndependentVectorsMatchTypedFieldsAndExactBytes() throws {
        let sample = try fixture()
        XCTAssertEqual(sample.vectors.count, 21)
        for row in sample.vectors {
            let message = try AudioStreamingMessage(streamID: sample.streamId, body: expected(row))
            let bytes = try hex(row.hex)
            XCTAssertEqual(try AudioStreamingWire.decode(bytes), message, row.name)
            XCTAssertEqual(try AudioStreamingWire.encode(message), bytes, row.name)
        }
    }

    func testAllTruncationsTrailingBytesAndInvalidLengthsFail() throws {
        for row in try fixture().vectors {
            let bytes = try hex(row.hex)
            for end in 0..<bytes.count { XCTAssertThrowsError(try AudioStreamingWire.decode(bytes.prefix(end))) }
            XCTAssertThrowsError(try AudioStreamingWire.decode(bytes + Data([0])))
            var longer = bytes + Data([0]); put(UInt64(longer.count - 28), width: 4, at: 24, into: &longer)
            XCTAssertThrowsError(try AudioStreamingWire.decode(longer))
            var invalidLength = bytes; invalidLength[24] = 0xff
            XCTAssertThrowsError(try AudioStreamingWire.decode(invalidLength))
        }
    }

    func testProfileAndConfigurationCannotChangeCodecRateDurationOrReservedBits() throws {
        let offer = try vector("opus-offer-1-2-192000")
        for (offset, value) in [(28, UInt8(0)), (28, 2), (29, 0), (29, 3), (30, 0), (30, 3),
            (31, 1), (32, 1), (37, 1), (38, 1), (39, 1), (40, 1)] {
            var wire = offer; wire[offset] = value
            XCTAssertThrowsError(try AudioStreamingWire.decode(wire))
        }
        let id = try fixture().streamId
        for channels: UInt8 in [0, 3] { XCTAssertThrowsError(try AudioStreamingOpusFormat(channels: channels, bitrate: 192000)) }
        for bitrate: UInt32 in [0, 64000, 192001] { XCTAssertThrowsError(try AudioStreamingOpusFormat(channels: 2, bitrate: bitrate)) }
        for skip: UInt16 in [3841, .max] {
            XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: .opusConfiguration(preSkipFrames: skip))))
            var wire = try vector("opus-configuration-312"); put(UInt64(skip), width: 2, at: 28, into: &wire)
            XCTAssertThrowsError(try AudioStreamingWire.decode(wire))
        }
        for offset in [30, 31] {
            var wire = try vector("opus-configuration-312"); wire[offset] = 1
            XCTAssertThrowsError(try AudioStreamingWire.decode(wire))
        }
    }

    func testPacketAndEndExtentsFailBeforeOverflowOrInvalidAllocation() throws {
        let id = try fixture().streamId, limit = AudioStreamingWire.maximumOpusPacketCount
        for sequence in [limit, UInt64(Int64.max), UInt64.max] {
            XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: .opusData(sequence: sequence, bytes: Data(repeating: 0, count: 320)))))
            var wire = try vector("opus-data-320"); put(sequence, width: 8, at: 28, into: &wire)
            XCTAssertThrowsError(try AudioStreamingWire.decode(wire))
        }
        for count in [0, 319, 321, 479, 481, 639, 641, 4096] {
            XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: .opusData(sequence: 0, bytes: Data(repeating: 0, count: count)))))
        }
        let invalid: [(UInt64, UInt64, UInt64)] = [(0, 1, 320), (.max, 1, 320), (UInt64(Int64.max), 1, 320),
            (1, 0, 320), (1, .max, 320), (1, limit + 1, 320), (1, 2, 641), (1, 2, 0), (1, 2, 1282)]
        for (frames, count, total) in invalid {
            XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id,
                body: .opusEnd(sourceFrames: frames, packetCount: count, totalEncodedBytes: total, sha256: Data(repeating: 0, count: 32)))))
            var wire = try vector("opus-end-short")
            put(frames, width: 8, at: 28, into: &wire); put(count, width: 8, at: 36, into: &wire); put(total, width: 8, at: 44, into: &wire)
            XCTAssertThrowsError(try AudioStreamingWire.decode(wire))
        }
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id,
            body: .opusEnd(sourceFrames: 1, packetCount: 1, totalEncodedBytes: 320, sha256: Data(repeating: 0, count: 31)))))
    }

    func testCompressedSourceRemainsExplicitAndNeedsBothCapabilities() throws {
        let offer = try AudioStreamingWire.decode(vector("opus-offer-1-2-192000"))
        XCTAssertEqual(try AudioPlaybackSource(offer: offer),
            .opus(source: .originalFile, format: try .init(channels: 2, bitrate: 192_000)))
        let bytes = try vector("opus-data-640")
        let backing = Data([0xff]) + bytes
        XCTAssertEqual(try AudioStreamingWire.decode(backing.dropFirst()), try AudioStreamingWire.decode(bytes))
        let id = try fixture().streamId
        let mailbox = AudioStreamingMailbox()
        // Codec support alone cannot admit a Bluetooth stream; attachment support is required too.
        XCTAssertThrowsError(try mailbox.prepareSend(offer,
            peerCapabilities: [AudioStreamingWire.opusReceiveCapability], completion: AudioStreamingSendCompletion()))
        XCTAssertNil(mailbox.streamID)
        XCTAssertThrowsError(try mailbox.prepareSend(.init(streamID: id, body: .opusOutputReady),
            peerCapabilities: [AudioStreamingWire.opusReceiveCapability], completion: AudioStreamingSendCompletion()))
    }

    private func put(_ value: UInt64, width: Int, at offset: Int, into data: inout Data) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((width - 1 - index) * 8)) }
    }
}
