import Foundation
import XCTest
import os
@testable import SkyBridgeProtocolCore

final class AudioBluetoothChannelProtocolTests: XCTestCase {
    private enum Failure: Error { case revoked }

    private func handshake(_ f: BluetoothAudioFixture, source: AudioBluetoothAttachment? = nil,
                           sink: AudioBluetoothAttachment? = nil, sourceNonce: Data? = nil) throws
        -> (AudioBluetoothRecordCipher, AudioBluetoothRecordCipher) {
        let source = try source ?? f.attachment(.source), sink = try sink ?? f.attachment(.sink)
        let s = try source.beginHandshake(initialHello: nil, localNonce: sourceNonce ?? f.bytes(f.sourceNonce))
        let hello = try s.initialFrame(); try s.didSend(hello)
        let r = try sink.beginHandshake(initialHello: hello, localNonce: f.bytes(f.sinkNonce))
        let challenge = try r.initialFrame(); try r.didSend(challenge)
        let finish = try XCTUnwrap(s.receive(challenge)); try s.didSend(finish)
        let ready = try XCTUnwrap(r.receive(finish)); try r.didSend(ready)
        XCTAssertNil(try s.receive(ready))
        return try (s.takeRecordCipher(), r.takeRecordCipher())
    }

    func testIndependentFourStepAndBidirectionalAEADVectorsMatch() throws {
        let f = try BluetoothAudioFixture.load()
        let source = try f.attachment(.source), sink = try f.attachment(.sink)
        defer { source.close(); sink.close() }
        let s = try source.beginHandshake(initialHello: nil, localNonce: f.bytes(f.sourceNonce))
        let hello = try s.initialFrame(); XCTAssertEqual(hello, try f.bytes(f.hello)); try s.didSend(hello)
        let r = try sink.beginHandshake(initialHello: hello, localNonce: f.bytes(f.sinkNonce))
        let challenge = try r.initialFrame(); XCTAssertEqual(challenge, try f.bytes(f.challenge)); try r.didSend(challenge)
        let finish = try XCTUnwrap(s.receive(challenge)); XCTAssertEqual(finish, try f.bytes(f.finish)); try s.didSend(finish)
        let ready = try XCTUnwrap(r.receive(finish)); XCTAssertEqual(ready, try f.bytes(f.ready))
        XCTAssertThrowsError(try s.takeRecordCipher()); XCTAssertThrowsError(try r.takeRecordCipher())
        try r.didSend(ready); XCTAssertNil(try s.receive(ready))
        let tx = try s.takeRecordCipher(), rx = try r.takeRecordCipher()
        defer { tx.close(); rx.close() }
        XCTAssertThrowsError(try s.takeRecordCipher()); XCTAssertThrowsError(try r.takeRecordCipher())
        for (records, send, receive) in [(f.sourceRecords, tx, rx), (f.sinkRecords, rx, tx)] {
            for record in records {
                let plaintext = try f.bytes(record.plaintext), sealed = try f.bytes(record.record)
                XCTAssertEqual(try send.seal(AudioStreamingWire.decode(plaintext)), sealed)
                XCTAssertEqual(try AudioStreamingWire.encode(receive.open(sealed)), plaintext)
            }
        }
    }

    func testUnauthenticatedCandidatesDoNotConsumePendingAttachment() throws {
        let f = try BluetoothAudioFixture.load(), sink = try f.attachment(.sink)
        defer { sink.close() }
        let hello = try f.bytes(f.hello)
        var malformed = (0..<hello.count).map { Data(hello.prefix($0)) }
        malformed.append(hello + Data([0]))
        malformed += hello.indices.map { index in var bad = hello; bad[index] ^= 1; return bad }
        for candidate in malformed {
            XCTAssertThrowsError(try sink.beginHandshake(initialHello: candidate, localNonce: f.bytes(f.sinkNonce)))
        }
        let valid = try sink.beginHandshake(initialHello: hello, localNonce: f.bytes(f.sinkNonce))
        XCTAssertEqual(try valid.initialFrame(), try f.bytes(f.challenge))
        XCTAssertThrowsError(try sink.beginHandshake(initialHello: hello))
        try valid.didSend(f.bytes(f.challenge))
        XCTAssertEqual(try valid.receive(f.bytes(f.finish)), try f.bytes(f.ready))
    }

    func testWritesMustCompleteBeforeReceivingAndWrongCompletionRetiresAttempt() throws {
        let f = try BluetoothAudioFixture.load()
        for wrongCompletion in [false, true] {
            let source = try f.attachment(.source); defer { source.close() }
            let s = try source.beginHandshake(initialHello: nil, localNonce: f.bytes(f.sourceNonce))
            _ = try s.initialFrame()
            if wrongCompletion {
                var bad = try f.bytes(f.hello); bad[0] = 0
                XCTAssertThrowsError(try s.didSend(bad))
            } else { XCTAssertThrowsError(try s.receive(f.bytes(f.challenge))) }
            XCTAssertThrowsError(try s.didSend(f.bytes(f.hello)))
        }
    }

    func testChallengeMacCannotBeReusedAsReady() throws {
        let f = try BluetoothAudioFixture.load(), source = try f.attachment(.source)
        defer { source.close() }
        let s = try source.beginHandshake(initialHello: nil, localNonce: f.bytes(f.sourceNonce))
        try s.didSend(s.initialFrame())
        try s.didSend(XCTUnwrap(s.receive(f.bytes(f.challenge))))
        var reused = try f.bytes(f.challenge); reused[5] = 4
        XCTAssertThrowsError(try s.receive(reused))
        XCTAssertThrowsError(try s.receive(f.bytes(f.ready)))
        XCTAssertThrowsError(try s.takeRecordCipher())
    }

    func testMalformedChallengeAndNonceChangesRetireAttempt() throws {
        let f = try BluetoothAudioFixture.load()
        for index in [0, 4, 5, 6, 7, 8, 24, 56, 88, 119] {
            let source = try f.attachment(.source); defer { source.close() }
            let s = try source.beginHandshake(initialHello: nil, localNonce: f.bytes(f.sourceNonce))
            try s.didSend(s.initialFrame())
            var bad = try f.bytes(f.challenge); bad[index] ^= 1
            XCTAssertThrowsError(try s.receive(bad))
            XCTAssertThrowsError(try s.receive(f.bytes(f.challenge)))
        }
    }

    func testTamperingReplayGapsAndReflectionNeverReleasePlaintext() throws {
        let f = try BluetoothAudioFixture.load()
        for mutation in 0...7 {
            let (source, sink) = try handshake(f); defer { source.close(); sink.close() }
            let record = try source.seal(f.packet())
            var bad = record
            switch mutation {
            case 0: bad[0] = 1
            case 1: bad[7] = 2
            case 2: bad[8] ^= 1
            case 3: bad[bad.count - 1] ^= 1
            case 4: bad = Data(record.prefix(51))
            case 5: bad = Data(repeating: 0, count: 701)
            case 6: _ = try sink.open(record)
            default: bad = try source.seal(f.packet())
            }
            XCTAssertThrowsError(try sink.open(bad))
            XCTAssertThrowsError(try sink.open(record))
        }
        let (source, sink) = try handshake(f); defer { source.close(); sink.close() }
        XCTAssertThrowsError(try source.open(source.seal(f.packet())))
    }

    func testRoleStreamAndNegotiatedProfileAreEnforced() throws {
        let f = try BluetoothAudioFixture.load(), packet = try f.packet()
        let wrong: [AudioStreamingMessage] = [
            .init(streamID: packet.streamID, body: .accept(receiveWindowBytes: 7680)),
            .init(streamID: UUID(), body: packet.body),
            .init(streamID: packet.streamID, body: .opusData(sequence: 0, bytes: Data(repeating: 0, count: 640))),
            try AudioStreamingWire.decode(f.bytes(f.offer))]
        for message in wrong {
            let (source, sink) = try handshake(f); defer { source.close(); sink.close() }
            XCTAssertThrowsError(try source.seal(message)); XCTAssertThrowsError(try source.seal(packet))
        }
        for window: UInt32 in [0, 1, 480 * 17] {
            let (source, sink) = try handshake(f); defer { source.close(); sink.close() }
            XCTAssertThrowsError(try sink.seal(.init(streamID: packet.streamID, body: .accept(receiveWindowBytes: window))))
        }
    }

    func testEstablishedLifetimeTracksParentRatherThanPreparationExpiry() throws {
        let f = try BluetoothAudioFixture.load(), current = OSAllocatedUnfairLock(initialState: true)
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let check: @Sendable () throws -> Void = { if !current.withLock({ $0 }) { throw Failure.revoked } }
        let sourceOwner = try f.attachment(.source, current: check, now: { clock.withLock { $0 } })
        let sinkOwner = try f.attachment(.sink, current: check, now: { clock.withLock { $0 } })
        let (source, sink) = try handshake(f, source: sourceOwner, sink: sinkOwner)
        defer { source.close(); sink.close() }
        clock.withLock { $0 = $0.advanced(by: .seconds(31)) }
        XCTAssertEqual(try sink.open(source.seal(f.packet())), try f.packet())
        XCTAssertThrowsError(try sourceOwner.beginHandshake())
        XCTAssertThrowsError(try sinkOwner.beginHandshake(initialHello: f.bytes(f.hello)))
        _ = try sink.open(source.seal(f.packet()))
        current.withLock { $0 = false }
        XCTAssertThrowsError(try source.seal(f.packet()))
        current.withLock { $0 = true }
        XCTAssertThrowsError(try source.seal(f.packet()))
        let pending = try f.attachment(.source, now: { clock.withLock { $0 } })
        defer { pending.close() }
        let attempt = try pending.beginHandshake()
        clock.withLock { $0 = $0.advanced(by: .seconds(30)) }
        XCTAssertThrowsError(try attempt.initialFrame())
    }

    func testFreshNonceChangesKeysAndBudgetNeverWraps() throws {
        let f = try BluetoothAudioFixture.load()
        var nonce = try f.bytes(f.sourceNonce); nonce[0] = 9
        let first = try handshake(f), second = try handshake(f, sourceNonce: nonce)
        defer { first.0.close(); first.1.close(); second.0.close(); second.1.close() }
        let original = try first.0.seal(f.packet())
        XCTAssertNotEqual(original, try second.0.seal(f.packet()))
        XCTAssertThrowsError(try second.1.open(original))
        let retired = OSAllocatedUnfairLock(initialState: false)
        let material = try f.secret(.source).traffic(role: .source, source: f.bytes(f.sourceNonce), sink: f.bytes(f.sinkNonce))
        let cipher = try AudioBluetoothRecordCipher(binding: f.binding(.source), material: material,
            requireCurrent: { if retired.withLock({ $0 }) { throw Failure.revoked } },
            closeOwner: { retired.withLock { $0 = true } }, recordBudget: 1)
        defer { cipher.close() }
        _ = try cipher.seal(f.packet())
        XCTAssertThrowsError(try cipher.seal(f.packet())) { XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .recordLimit) }
        XCTAssertTrue(retired.withLock { $0 })
    }
}
