import XCTest
import Foundation
import os
import SkyBridgeProtocolCore

final class AudioBluetoothAttachmentTests: XCTestCase {
    private struct Fixture: Decodable {
        let offer, route, sendKey, receiveKey, transcriptHash, sourceNonce, sinkNonce, sourceProof, sinkProof: String
        let suite: UInt16
    }
    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            XCTUnwrap(Bundle.module.url(forResource: "audio-bluetooth-binding-v1", withExtension: "json"))))
    }
    private func bytes(_ text: String) throws -> Data {
        let chars = Array(text)
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
        })
    }
    private func messages() throws -> (AudioStreamingMessage, AudioStreamingMessage) {
        let f = try fixture()
        return try (AudioStreamingWire.decode(bytes(f.offer)), AudioStreamingWire.decode(bytes(f.route)))
    }
    private func binding(_ role: AudioBluetoothRole, offer: AudioStreamingMessage, route: AudioStreamingMessage) throws -> AudioBluetoothBinding {
        var negotiation = AudioBluetoothNegotiation(role: role, streamID: offer.streamID)
        if role == .source {
            try negotiation.prepareSend(offer); try negotiation.commitSend(offer); try negotiation.receive(route)
        } else {
            try negotiation.receive(offer); try negotiation.prepareSend(route); try negotiation.commitSend(route)
        }
        return try negotiation.takeBinding()
    }

    func testIndependentPythonHKDFHMACAndWireVectorsMatchBothDirections() throws {
        let f = try fixture(), (offer, route) = try messages()
        XCTAssertEqual(try AudioStreamingWire.encode(offer), try bytes(f.offer))
        XCTAssertEqual(try AudioStreamingWire.encode(route), try bytes(f.route))
        for role in [AudioBluetoothRole.source, .sink] {
            let secret = try AudioBluetoothAttachmentSecret(binding: binding(role, offer: offer, route: route),
                sendKey: bytes(role == .source ? f.sendKey : f.receiveKey),
                receiveKey: bytes(role == .source ? f.receiveKey : f.sendKey), transcriptHash: bytes(f.transcriptHash), suite: f.suite)
            let source = try bytes(f.sourceNonce), sink = try bytes(f.sinkNonce)
            XCTAssertEqual(try secret.confirmation(role: .source, sourceNonce: source, sinkNonce: sink), try bytes(f.sourceProof))
            XCTAssertEqual(try secret.confirmation(role: .sink, sourceNonce: source, sinkNonce: sink), try bytes(f.sinkProof))
            try secret.verify(bytes(f.sourceProof), role: .source, sourceNonce: source, sinkNonce: sink)
            XCTAssertThrowsError(try secret.verify(bytes(f.sourceProof), role: .sink, sourceNonce: source, sinkNonce: sink))
        }
    }

    func testRouteCannotBeTruncatedExtendedOrReinterpretedWithReservedBits() throws {
        let encoded = try bytes(fixture().route)
        for length in 0..<encoded.count { XCTAssertThrowsError(try AudioStreamingWire.decode(Data(encoded.prefix(length)))) }
        XCTAssertThrowsError(try AudioStreamingWire.decode(encoded + Data([0])))
        for index in [6, 7, 30, 31] {
            var bad = encoded; bad[index] = 1
            XCTAssertThrowsError(try AudioStreamingWire.decode(bad))
        }
        for psm: UInt16 in [0, 256, .max] {
            var bad = encoded; bad[28] = UInt8(psm >> 8); bad[29] = UInt8(psm & 255)
            XCTAssertThrowsError(try AudioStreamingWire.decode(bad))
        }
        for start in [32, 48] {
            var bad = encoded; bad.replaceSubrange(start..<(start + 16), with: Data(repeating: 0, count: 16))
            XCTAssertThrowsError(try AudioStreamingWire.decode(bad))
        }
    }

    func testBindingRequiresActualOutgoingCompletionAndIsIssuedOnlyOnce() throws {
        let (offer, route) = try messages()
        for role in [AudioBluetoothRole.source, .sink] {
            var n = AudioBluetoothNegotiation(role: role, streamID: offer.streamID)
            XCTAssertThrowsError(try n.takeBinding())
            if role == .source { try n.prepareSend(offer); try n.receive(route) }
            else { try n.receive(offer); try n.prepareSend(route) }
            XCTAssertThrowsError(try n.takeBinding())
            try n.commitSend(role == .source ? offer : route)
            XCTAssertEqual(try n.takeBinding().role, role)
            XCTAssertThrowsError(try n.takeBinding()) { XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .alreadyIssued) }
        }
    }

    func testIssuedMailboxBindingIsRetiredByStopBeforeNativeCleanup() throws {
        let (offer, route) = try messages()
        let capabilities: Set<String> = [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability]
        for role in [AudioBluetoothRole.source, .sink] {
            for incomingStop in [true, false] {
                let mailbox = AudioStreamingMailbox(); defer { mailbox.finish(.closed) }
                let outgoing = role == .source ? offer : route
                let completion = AudioStreamingSendCompletion()
                if role == .source {
                    try mailbox.prepareSend(offer, peerCapabilities: capabilities, completion: completion)
                    try mailbox.receive(route)
                } else {
                    try mailbox.receive(offer)
                    try mailbox.prepareSend(route, peerCapabilities: capabilities, completion: completion)
                }
                XCTAssertThrowsError(try mailbox.requireBluetoothBindingCurrent())
                try mailbox.commitSent(outgoing); mailbox.finishSend(completion)
                let binding = try mailbox.takeBluetoothBinding(); XCTAssertEqual(binding.role, role)
                try mailbox.requireBluetoothBindingCurrent()
                let stop = AudioStreamingMessage(streamID: offer.streamID, body: .stop(.userStopped))
                if incomingStop { try mailbox.receive(stop) }
                else { try mailbox.prepareSend(stop, peerCapabilities: capabilities, completion: .init()) }
                XCTAssertThrowsError(try mailbox.requireBluetoothBindingCurrent()) {
                    XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .closed)
                }
                try mailbox.requireActive() // Retirement does not discard the parent's Stop reason.
            }
        }
    }

    func testRoleConfusionMediaReplayAndStopCannotBecomeAttachmentAuthority() throws {
        let (offer, route) = try messages()
        var source = AudioBluetoothNegotiation(role: .source, streamID: offer.streamID)
        XCTAssertThrowsError(try source.receive(offer))
        XCTAssertThrowsError(try source.receive(route))
        try source.prepareSend(offer); try source.commitSend(offer)
        XCTAssertThrowsError(try source.prepareSend(offer))
        XCTAssertThrowsError(try source.prepareSend(route))
        for body: AudioStreamingMessage.Body in [.accept(receiveWindowBytes: 640), .opusConfiguration(preSkipFrames: 312),
            .opusData(sequence: 0, bytes: Data(repeating: 0, count: 480)), .opusOutputReady] {
            XCTAssertThrowsError(try source.prepareSend(.init(streamID: offer.streamID, body: body)))
        }
        try source.receive(route)
        XCTAssertThrowsError(try source.receive(route))
        let stop = AudioStreamingMessage(streamID: offer.streamID, body: .stop(.userStopped))
        try source.prepareSend(stop); try source.commitSend(stop)
        XCTAssertThrowsError(try source.takeBinding())
    }

    func testEveryNegotiatedContextAndKeyChangeRejectsTheOldConfirmation() throws {
        let f = try fixture(), (offer, route) = try messages()
        let offerBytes = try AudioStreamingWire.encode(offer), routeBytes = try AudioStreamingWire.encode(route)
        for mutation in 0..<11 {
            var o = offerBytes, r = routeBytes, tx = try bytes(f.sendKey), rx = try bytes(f.receiveKey), th = try bytes(f.transcriptHash)
            var suite = f.suite
            switch mutation {
            case 0: tx[0] ^= 1
            case 1: rx[0] ^= 1
            case 2: th[0] ^= 1
            case 3: suite ^= 1
            case 4: o[8] ^= 1; r[8] ^= 1 // Same replacement stream on both messages.
            case 5: o[29] = 2
            case 6: o[30] = 1
            case 7: o.replaceSubrange(40..<44, with: [0, 1, 244, 0]) // 128 kbps.
            case 8: r[29] = 130
            case 9: r[32] ^= 1
            default: r[48] ^= 1
            }
            let secret = try AudioBluetoothAttachmentSecret(binding: binding(.source,
                offer: AudioStreamingWire.decode(o), route: AudioStreamingWire.decode(r)),
                sendKey: tx, receiveKey: rx, transcriptHash: th, suite: suite)
            XCTAssertThrowsError(try secret.verify(bytes(f.sinkProof), role: .sink,
                sourceNonce: bytes(f.sourceNonce), sinkNonce: bytes(f.sinkNonce)), "mutation \(mutation)")
        }
    }

    func testHandleRejectsReflectionExpiredClosedAndReplacedParent() throws {
        let f = try fixture(), (offer, route) = try messages()
        let b = try binding(.source, offer: offer, route: route)
        let secret = try AudioBluetoothAttachmentSecret(binding: b, sendKey: bytes(f.sendKey), receiveKey: bytes(f.receiveKey),
                                                       transcriptHash: bytes(f.transcriptHash), suite: f.suite)
        let current = OSAllocatedUnfairLock(initialState: true), clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        func handle() -> AudioBluetoothAttachment {
            .init(binding: b, secret: secret, requireParentCurrent: {
                if !current.withLock({ $0 }) { throw AudioStreamingChannelError.staleOwner }
            }, now: { clock.withLock { $0 } })
        }
        let owned = handle(), source = try bytes(f.sourceNonce), sink = try bytes(f.sinkNonce)
        try owned.verifyPeer(bytes(f.sinkProof), sourceNonce: source, sinkNonce: sink)
        XCTAssertThrowsError(try owned.verifyPeer(owned.confirmation(sourceNonce: source, sinkNonce: sink), sourceNonce: source, sinkNonce: sink))
        current.withLock { $0 = false }
        XCTAssertThrowsError(try owned.confirmation(sourceNonce: source, sinkNonce: sink))
        current.withLock { $0 = true }
        owned.close()
        XCTAssertThrowsError(try owned.confirmation(sourceNonce: source, sinkNonce: sink))
        let expiring = handle()
        clock.withLock { $0 = $0.advanced(by: .seconds(30)) }
        XCTAssertThrowsError(try expiring.confirmation(sourceNonce: source, sinkNonce: sink)) {
            XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .expired)
        }
        XCTAssertThrowsError(try secret.confirmation(role: .source, sourceNonce: source, sinkNonce: source))
        XCTAssertThrowsError(try secret.confirmation(role: .source, sourceNonce: source.dropLast(), sinkNonce: sink))
        XCTAssertThrowsError(try secret.verify(Data(repeating: 0, count: 31), role: .sink, sourceNonce: source, sinkNonce: sink))
    }
}
