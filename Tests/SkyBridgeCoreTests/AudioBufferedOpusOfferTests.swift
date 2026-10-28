import Foundation
import XCTest
import SkyBridgeProtocolCore

final class AudioBufferedOpusOfferTests: XCTestCase {
    private func offer(buffered: Bool = true) throws -> AudioStreamingMessage {
        let format = try AudioStreamingOpusFormat(channels: 2, bitrate: 128_000)
        return .init(streamID: try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
                     body: buffered ? .bufferedOpusFileOffer(format) : .opusOffer(source: .originalFile, format: format))
    }
    private func bytes(_ hex: String) throws -> Data {
        let chars = Array(hex)
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
        })
    }
    private func binding(_ role: AudioBluetoothRole, buffered: Bool) throws -> AudioBluetoothBinding {
        let offer = try offer(buffered: buffered)
        let route = AudioStreamingMessage(streamID: offer.streamID, body: .bluetoothRoute(try .init(
            serviceID: XCTUnwrap(UUID(uuidString: "11112233-4455-6677-8899-aabbccddeeff")),
            publicationID: XCTUnwrap(UUID(uuidString: "22112233-4455-6677-8899-aabbccddeeff")), psm: 0x81)))
        var negotiation = AudioBluetoothNegotiation(role: role, streamID: offer.streamID)
        if role == .source {
            try negotiation.prepareSend(offer); try negotiation.commitSend(offer); try negotiation.receive(route)
        } else {
            try negotiation.receive(offer); try negotiation.prepareSend(route); try negotiation.commitSend(route)
        }
        return try negotiation.takeBinding()
    }
    private func secret(_ role: AudioBluetoothRole, buffered: Bool) throws -> AudioBluetoothAttachmentSecret {
        try .init(binding: binding(role, buffered: buffered),
            sendKey: Data(repeating: role == .source ? 0x21 : 0x43, count: 32),
            receiveKey: Data(repeating: role == .source ? 0x43 : 0x21, count: 32),
            transcriptHash: Data(repeating: 0x65, count: 32), suite: 0x1001)
    }
    private func attachment(_ role: AudioBluetoothRole, buffered: Bool) throws -> AudioBluetoothAttachment {
        try .init(binding: binding(role, buffered: buffered), secret: secret(role, buffered: buffered), requireParentCurrent: {})
    }
    private func ciphers(buffered: Bool) throws -> (AudioBluetoothRecordCipher, AudioBluetoothRecordCipher) {
        let source = try attachment(.source, buffered: buffered), sink = try attachment(.sink, buffered: buffered)
        let s = try source.beginHandshake(initialHello: nil)
        let hello = try s.initialFrame(); try s.didSend(hello)
        let r = try sink.beginHandshake(initialHello: hello)
        let challenge = try r.initialFrame(); try r.didSend(challenge)
        let finish = try XCTUnwrap(s.receive(challenge)); try s.didSend(finish)
        let ready = try XCTUnwrap(r.receive(finish)); try r.didSend(ready)
        XCTAssertNil(try s.receive(ready))
        return try (s.takeRecordCipher(), r.takeRecordCipher())
    }

    func testFixedBytesDistinguishBufferedFileFromLegacyWithoutChangingCodec() throws {
        // Independently specified v1 header/opcode 18 and fixed 16-byte profile payload.
        let expected = try bytes("534241550112000000112233445566778899aabbccddeeff00000010010102000000bb8003c000000001f400")
        let message = try offer()
        XCTAssertEqual(try AudioStreamingWire.encode(message), expected)
        XCTAssertEqual(try AudioStreamingWire.decode(expected), message)
        let legacy = try offer(buffered: false)
        var originalBytes = expected; originalBytes[5] = 11
        XCTAssertEqual(try AudioStreamingWire.encode(legacy), originalBytes)
        XCTAssertEqual(try AudioStreamingWire.decode(originalBytes), legacy)
        XCTAssertEqual(message.body.opusOfferParameters?.format, legacy.body.opusOfferParameters?.format)
        XCTAssertEqual(message.body.opusOfferParameters?.buffering, .bufferedFile)
        XCTAssertEqual(legacy.body.opusOfferParameters?.buffering, .legacy)
        XCTAssertEqual(try AudioPlaybackSource(offer: message), try AudioPlaybackSource(offer: legacy))
    }

    func testBufferedOfferCannotClaimSystemCaptureOrChangeFixedProfile() throws {
        let encoded = try AudioStreamingWire.encode(offer())
        for count in 0..<encoded.count { XCTAssertThrowsError(try AudioStreamingWire.decode(encoded.prefix(count))) }
        XCTAssertThrowsError(try AudioStreamingWire.decode(encoded + Data([0])))
        for (index, value) in [(28, UInt8(2)), (29, 2), (30, 0), (31, 1), (32, 1), (37, 1), (38, 1), (40, 1)] {
            var invalid = encoded; invalid[index] = value
            XCTAssertThrowsError(try AudioStreamingWire.decode(invalid), "offset \(index)")
        }
    }

    func testExtendedOfferRequiresEveryAuthenticatedCapabilityBeforeBinding() throws {
        let capabilities: Set<String> = [AudioStreamingWire.opusReceiveCapability,
            AudioStreamingWire.bluetoothAttachmentCapability, AudioStreamingWire.bufferedOpusFileReceiveCapability]
        for missing in capabilities {
            let mailbox = AudioStreamingMailbox(); defer { mailbox.finish(.closed) }
            XCTAssertThrowsError(try mailbox.prepareSend(offer(), peerCapabilities: capabilities.subtracting([missing]), completion: .init())) {
                XCTAssertEqual($0 as? AudioStreamingChannelError, .unsupportedPeer)
            }
            XCTAssertThrowsError(try mailbox.takeBluetoothBinding())
        }
        let mailbox = AudioStreamingMailbox(); defer { mailbox.finish(.closed) }
        let message = try offer(), completion = AudioStreamingSendCompletion()
        try mailbox.prepareSend(message, peerCapabilities: capabilities, completion: completion)
        let expected = try binding(.source, buffered: true)
        try mailbox.receive(expected.route)
        XCTAssertThrowsError(try mailbox.takeBluetoothBinding(), "Outgoing offer completion is still mandatory")
        try mailbox.commitSent(message); mailbox.finishSend(completion)
        XCTAssertEqual(try mailbox.takeBluetoothBinding().offer, message)
        XCTAssertThrowsError(try mailbox.prepareSend(.init(streamID: message.streamID, body: .opusData(sequence: 0,
            bytes: Data(count: 320))), peerCapabilities: capabilities, completion: .init()), "Media must stay off MAIN")
    }

    func testBufferPolicyIsBoundToChildConfirmation() throws {
        let sourceNonce = Data(repeating: 0x11, count: 32), sinkNonce = Data(repeating: 0x22, count: 32)
        let extended = try secret(.source, buffered: true), receiver = try secret(.sink, buffered: true)
        let legacy = try secret(.source, buffered: false)
        let proof = try extended.confirmation(role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce)
        try receiver.verify(proof, role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce)
        XCTAssertThrowsError(try legacy.verify(proof, role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce))
        let oldProof = try legacy.confirmation(role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce)
        XCTAssertThrowsError(try extended.verify(oldProof, role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce))
    }

    func testEncryptedAcceptKeepsSeparateBoundedWindows() throws {
        for buffered in [false, true] {
            let upper: UInt32 = buffered ? 64 : 16
            for window in [UInt32(320), upper * 320, 0, (upper + 1) * 320, upper * 320 - 1] {
                let (source, sink) = try ciphers(buffered: buffered)
                defer { source.close(); sink.close() }
                let message = AudioStreamingMessage(streamID: try offer().streamID, body: .accept(receiveWindowBytes: window))
                if window == 320 || window == upper * 320 {
                    XCTAssertEqual(try source.open(sink.seal(message)), message)
                } else { XCTAssertThrowsError(try sink.seal(message)) }
            }
        }
    }
}
