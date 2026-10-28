import Foundation
import XCTest
import SkyBridgeProtocolCore

final class AudioStreamingWireTests: XCTestCase {
    private struct Fixtures: Decodable { let streamId: UUID; let vectors: [Vector] }
    private struct Vector: Decodable {
        let name: String; let opcode: UInt8; let hex: String; let expected: Expected
    }
    private struct Expected: Decodable {
        let transferId: UUID?; let length: String?; let sha256Hex: String?
        let sampleRate: UInt32?; let channels: UInt16?; let encoding: UInt8?; let validBits: UInt8?
        let waveChannelMask: UInt32?; let receiveWindowBytes: UInt32?
        let byteOffset: String?; let dataHex: String?; let retiredBytes: String?
        let totalBytes: String?; let sourceFrames: String?; let trailingPaddingFrames: UInt32?; let reason: UInt16?
    }
    private func fixtures() throws -> Fixtures {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "audio-streaming-v1-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    private func hex(_ string: String) throws -> Data {
        let characters = Array(string)
        XCTAssertEqual(characters.count % 2, 0)
        return try Data(stride(from: 0, to: characters.count, by: 2).map {
            try XCTUnwrap(UInt8(String(characters[$0...($0 + 1)]), radix: 16))
        })
    }
    private func number(_ text: String?) throws -> UInt64 { try XCTUnwrap(UInt64(try XCTUnwrap(text))) }
    private func sampleFormat() throws -> AudioStreamingPCMFormat {
        try .init(sampleRate: 44100, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3)
    }

    func testOptionalFilePlaybackProgressRoundTripsIndependentBytes() throws {
        let prefix = "534241550113000000112233445566778899aabbccddeeff00000008"
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let rows: [(UInt64, String)] = [(0, "0000000000000000"), (1, "0000000000000001"),
            (48_000, "000000000000bb80"), (9_007_199_254_740_993, "0020000000000001"),
            (UInt64(Int64.max), "7fffffffffffffff")]
        for (frames, payload) in rows {
            let bytes = try hex(prefix + payload)
            let expected = AudioStreamingMessage(streamID: id, body: .fileOutputProgress(sourceFrames: frames))
            XCTAssertEqual(try AudioStreamingWire.decode(bytes), expected)
            XCTAssertEqual(try AudioStreamingWire.encode(expected), bytes)
        }
    }

    func testOptionalFileOutputProgressRejectsMalformedExtentsAndCounters() throws {
        let bytes = try hex("534241550113000000112233445566778899aabbccddeeff00000008000000000000bb80")
        for size in 0..<bytes.count { XCTAssertThrowsError(try AudioStreamingWire.decode(bytes.prefix(size))) }
        XCTAssertThrowsError(try AudioStreamingWire.decode(bytes + Data([0])))
        var longBody = bytes + Data([0]); longBody[27] = 9
        XCTAssertThrowsError(try AudioStreamingWire.decode(longBody))
        var shortBody = Data(bytes.dropLast()); shortBody[27] = 7
        XCTAssertThrowsError(try AudioStreamingWire.decode(shortBody))
        for (index, value) in [(28, UInt8(0x80)), (6, 1), (5, 20)] {
            var changed = bytes; changed[index] = value
            XCTAssertThrowsError(try AudioStreamingWire.decode(changed))
        }
        var zero = bytes; zero.replaceSubrange(8..<24, with: repeatElement(UInt8(0), count: 16))
        XCTAssertThrowsError(try AudioStreamingWire.decode(zero))
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id,
            body: .fileOutputProgress(sourceFrames: UInt64(Int64.max) + 1))))
    }

    func testAllFixedVectorsHaveExpectedSemanticsAndCanonicalBytes() throws {
        let fixture = try fixtures()
        XCTAssertEqual(fixture.vectors.count, 31)
        for vector in fixture.vectors {
            let bytes = try hex(vector.hex)
            let message = try AudioStreamingWire.decode(bytes)
            XCTAssertEqual(message.streamID, fixture.streamId, vector.name)
            XCTAssertEqual(try AudioStreamingWire.encode(message), bytes, vector.name)
            let expected = vector.expected
            switch message.body {
            case let .fileOffer(id, length, digest):
                XCTAssertEqual(vector.opcode, 1); XCTAssertEqual(id, expected.transferId)
                XCTAssertEqual(length, try number(expected.length)); XCTAssertEqual(digest, try hex(XCTUnwrap(expected.sha256Hex)))
            case let .captureOffer(format), let .outputReady(format):
                XCTAssertTrue(vector.opcode == 2 || vector.opcode == 8)
                XCTAssertEqual(format.sampleRate, expected.sampleRate); XCTAssertEqual(format.channels, expected.channels)
                XCTAssertEqual(format.encoding.rawValue, expected.encoding); XCTAssertEqual(format.declaredValidBits, expected.validBits)
                XCTAssertEqual(format.waveChannelMask, expected.waveChannelMask)
            case let .accept(window): XCTAssertEqual(vector.opcode, 3); XCTAssertEqual(window, expected.receiveWindowBytes)
            case let .pcmData(offset, payload):
                XCTAssertEqual(vector.opcode, 4); XCTAssertEqual(offset, try number(expected.byteOffset))
                XCTAssertEqual(payload, try hex(XCTUnwrap(expected.dataHex)))
            case let .credit(retired): XCTAssertEqual(vector.opcode, 5); XCTAssertEqual(retired, try number(expected.retiredBytes))
            case let .end(total, digest), let .contentVerified(total, digest):
                XCTAssertTrue(vector.opcode == 6 || vector.opcode == 7)
                XCTAssertEqual(total, try number(expected.totalBytes)); XCTAssertEqual(digest, try hex(XCTUnwrap(expected.sha256Hex)))
            case let .playbackComplete(frames, padding):
                XCTAssertEqual(vector.opcode, 9); XCTAssertEqual(frames, try number(expected.sourceFrames))
                XCTAssertEqual(padding, expected.trailingPaddingFrames)
            case let .stop(reason): XCTAssertEqual(vector.opcode, 10); XCTAssertEqual(reason.rawValue, expected.reason)
            case .opusOffer, .bufferedOpusFileOffer, .opusConfiguration, .opusData, .opusEnd, .opusOutputReady, .bluetoothRoute, .usbFileRoute, .fileOutputProgress:
                XCTFail("Base PCM/file vector was decoded as an optional transport message")
            }
        }
    }

    func testEveryTruncationAndTrailingByteFails() throws {
        for vector in try fixtures().vectors {
            let bytes = try hex(vector.hex)
            for count in 0..<bytes.count {
                XCTAssertThrowsError(try AudioStreamingWire.decode(bytes.prefix(count)), "\(vector.name) prefix \(count)")
            }
            XCTAssertThrowsError(try AudioStreamingWire.decode(bytes + Data([0])))
            var malformedLength = bytes; malformedLength[24] = 0xFF
            XCTAssertThrowsError(try AudioStreamingWire.decode(malformedLength))
        }
    }

    func testHeaderAndIdentifierCorruptionFails() throws {
        let fixture = try fixtures()
        let encoded = try AudioStreamingWire.encode(.init(streamID: fixture.streamId, body: .captureOffer(sampleFormat())))
        for (offset, byte) in [(0, UInt8(0)), (4, 2), (5, 0), (5, 16), (6, 1), (7, 1)] {
            var data = encoded; data[offset] = byte
            XCTAssertThrowsError(try AudioStreamingWire.decode(data))
        }
        var zeroID = encoded; zeroID.replaceSubrange(8..<24, with: repeatElement(UInt8(0), count: 16))
        XCTAssertThrowsError(try AudioStreamingWire.decode(zeroID))
        let zero = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: zero, body: .stop(.userStopped))))
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: fixture.streamId,
            body: .fileOffer(transferID: zero, length: 44, sha256: Data(repeating: 0, count: 32)))))
    }

    func testFormatCorruptionAndPrecisionBoundsFail() throws {
        let id = try fixtures().streamId
        let encoded = try AudioStreamingWire.encode(.init(streamID: id, body: .captureOffer(sampleFormat())))
        for (offset, value) in [(34, UInt8(0)), (34, 8), (35, 0), (35, 25), (36, 2), (37, 1), (38, 1), (39, 1)] {
            var data = encoded; data[offset] = value
            XCTAssertThrowsError(try AudioStreamingWire.decode(data))
        }
        var hiddenMask = encoded; hiddenMask[36] = 0
        XCTAssertThrowsError(try AudioStreamingWire.decode(hiddenMask))
        XCTAssertThrowsError(try AudioStreamingPCMFormat(sampleRate: 0, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3))
        XCTAssertThrowsError(try AudioStreamingPCMFormat(sampleRate: UInt32.max, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3))
        XCTAssertThrowsError(try AudioStreamingPCMFormat(sampleRate: 1, channels: UInt16.max, encoding: .signed64, declaredValidBits: 64, waveChannelMask: nil))
        XCTAssertThrowsError(try AudioStreamingPCMFormat(sampleRate: 48000, channels: 2, encoding: .float32, declaredValidBits: 24, waveChannelMask: 3))
    }

    func testSignedCounterLimitsAndCompleteMessageBudget() throws {
        let id = try fixtures().streamId
        let limit = AudioStreamingWire.maximumCounter
        let valid = AudioStreamingMessage(streamID: id, body: .pcmData(byteOffset: limit - 1, bytes: Data([0xFF])))
        XCTAssertEqual(try AudioStreamingWire.decode(AudioStreamingWire.encode(valid)), valid)
        let invalid: [AudioStreamingMessage.Body] = [
            .credit(retiredBytes: limit + 1), .pcmData(byteOffset: limit, bytes: Data([0])),
            .pcmData(byteOffset: 0, bytes: Data()), .accept(receiveWindowBytes: 1_048_577),
            .end(totalBytes: limit + 1, sha256: Data(repeating: 0, count: 32)),
            .playbackComplete(sourceFrames: limit, trailingPaddingFrames: 1),
            .fileOffer(transferID: id, length: 0, sha256: Data(repeating: 0, count: 32)),
            .fileOffer(transferID: id, length: AudioStreamingWire.maximumFileBytes + 1, sha256: Data(repeating: 0, count: 32)),
            .end(totalBytes: 0, sha256: Data(repeating: 0, count: 31))
        ]
        for body in invalid { XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: body))) }
        let bytes = Data(repeating: 0xA5, count: AudioStreamingWire.maximumPCMDataBytes)
        let maximum = try AudioStreamingWire.encode(.init(streamID: id, body: .pcmData(byteOffset: 0, bytes: bytes)))
        XCTAssertEqual(maximum.count, AudioStreamingWire.maximumMessageBytes)
        XCTAssertEqual(try AudioStreamingWire.decode(maximum).body, .pcmData(byteOffset: 0, bytes: bytes))
        XCTAssertThrowsError(try AudioStreamingWire.decode(maximum + Data([0])))
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: .pcmData(byteOffset: 0, bytes: bytes + Data([0])))))
    }

    func testUnknownStopAndNonzeroReservedFail() throws {
        let id = try fixtures().streamId
        let data = try AudioStreamingWire.encode(.init(streamID: id, body: .stop(.userStopped)))
        for (offset, byte) in [(28, UInt8(1)), (29, 0), (29, 14), (30, 1), (31, 1)] {
            var changed = data; changed[offset] = byte
            XCTAssertThrowsError(try AudioStreamingWire.decode(changed))
        }
    }

    func testDataSlicesDoNotAssumeZeroBasedIndices() throws {
        let id = try fixtures().streamId
        let original = try AudioStreamingWire.encode(.init(streamID: id, body: .credit(retiredBytes: 6)))
        let backing = Data([0xFF]) + original
        XCTAssertEqual(try AudioStreamingWire.decode(backing.dropFirst()), try AudioStreamingWire.decode(original))
    }

    func testUSBFileRouteHasCanonicalBoundedWireEncoding() throws {
        let bytes = try hex("5342415501110000000102030405060708090a0b0c0d0e0f00000004c0010000")
        let id = try XCTUnwrap(UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f"))
        let message = AudioStreamingMessage(streamID: id, body: .usbFileRoute(port: 49_153))
        XCTAssertEqual(try AudioStreamingWire.decode(bytes), message)
        XCTAssertEqual(try AudioStreamingWire.encode(message), bytes)
        for count in 0..<bytes.count { XCTAssertThrowsError(try AudioStreamingWire.decode(bytes.prefix(count))) }
        XCTAssertThrowsError(try AudioStreamingWire.decode(bytes + Data([0])))
        for offset in [30, 31] {
            var invalid = bytes; invalid[offset] = 1
            XCTAssertThrowsError(try AudioStreamingWire.decode(invalid))
        }
        var zero = bytes; zero[28] = 0; zero[29] = 0
        XCTAssertThrowsError(try AudioStreamingWire.decode(zero))
        XCTAssertThrowsError(try AudioStreamingWire.encode(.init(streamID: id, body: .usbFileRoute(port: 0))))
    }

    func testUSBFileRouteSendRequiresReceiverAndApprovalCapabilities() throws {
        let mailbox = AudioStreamingMailbox(), id = UUID(), first = AudioStreamingSendCompletion()
        try mailbox.prepareSend(.init(streamID: id, body: .fileOffer(transferID: UUID(), length: 1,
            sha256: Data(repeating: 1, count: 32))), peerCapabilities: [AudioStreamingWire.fileReceiveCapability], completion: first)
        mailbox.finishSend(first)
        let route = AudioStreamingMessage(streamID: id, body: .usbFileRoute(port: 49_153))
        let incomplete: [Set<String>] = [[], [AudioStreamingWire.usbFileReceiveCapability], ["classic_approval_v1"]]
        for capabilities in incomplete {
            XCTAssertThrowsError(try mailbox.prepareSend(route, peerCapabilities: capabilities,
                completion: AudioStreamingSendCompletion())) { XCTAssertEqual($0 as? AudioStreamingChannelError, .unsupportedPeer) }
        }
        let completion = AudioStreamingSendCompletion()
        try mailbox.prepareSend(route, peerCapabilities: [AudioStreamingWire.usbFileReceiveCapability, "classic_approval_v1"], completion: completion)
        mailbox.finishSend(completion); mailbox.finish(.closed)
    }

    func testFileOutputProgressRequiresThePeersReceivingRole() throws {
        let mailbox = AudioStreamingMailbox(), id = UUID(), first = AudioStreamingSendCompletion()
        try mailbox.prepareSend(.init(streamID: id, body: .fileOffer(transferID: UUID(), length: 1,
            sha256: Data(repeating: 1, count: 32))), peerCapabilities: [AudioStreamingWire.fileReceiveCapability], completion: first)
        mailbox.finishSend(first)
        let progress = AudioStreamingMessage(streamID: id, body: .fileOutputProgress(sourceFrames: 1))
        let unsupported: [Set<String>] = [[], [AudioStreamingWire.fileReceiveCapability],
            [AudioStreamingWire.fileOutputProgressReportCapability]]
        for capabilities in unsupported {
            let attempt = AudioStreamingSendCompletion()
            XCTAssertThrowsError(try mailbox.prepareSend(progress, peerCapabilities: capabilities,
                completion: attempt)) { XCTAssertEqual($0 as? AudioStreamingChannelError, .unsupportedPeer) }
            mailbox.finishSend(attempt)
        }
        let completion = AudioStreamingSendCompletion()
        try mailbox.prepareSend(progress, peerCapabilities: [AudioStreamingWire.fileOutputProgressReceiveCapability],
            completion: completion)
        mailbox.finishSend(completion); mailbox.finish(.closed)
    }

    func testFileOutputProgressCannotOpenAnUnadmittedStream() throws {
        let mailbox = AudioStreamingMailbox()
        XCTAssertThrowsError(try mailbox.prepareSend(.init(streamID: UUID(), body: .fileOutputProgress(sourceFrames: 1)),
            peerCapabilities: [AudioStreamingWire.fileOutputProgressReceiveCapability],
            completion: AudioStreamingSendCompletion())) { XCTAssertEqual($0 as? AudioStreamingChannelError, .offerRequired) }
        XCTAssertNil(mailbox.streamID)
    }
}
