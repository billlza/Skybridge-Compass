import Foundation
import XCTest
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport

/// Native Foundation stream pairs exercise the product pump and authenticated audio channel.
/// They do not establish Bluetooth radio, account enrollment, codec or native output acceptance.
@MainActor
final class BluetoothAudioChannelTests: XCTestCase {
    private enum Failure: Error { case revoked, eventTimeout, missingEvent }

    func testFragmentedNativeDuplexCarriesMediaAndReverseCredits() async throws {
        let f = try BluetoothAudioFixture.load(), pair = try nativePair(buffer: 17)
        let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source))
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
        try await authenticate(source, sink)
        for sequence: UInt64 in 0...3 {
            let packet = try f.packet()
            let message = AudioStreamingMessage(streamID: packet.streamID,
                body: .opusData(sequence: sequence, bytes: Data(repeating: UInt8(sequence), count: 480)))
            async let incoming = sink.receive(requireEffectAuthorization: {})
            try await source.send(message, requireEffectAuthorization: {})
            let delivered = try await incoming
            XCTAssertEqual(delivered, message)
            let credit = AudioStreamingMessage(streamID: packet.streamID, body: .credit(retiredBytes: (sequence + 1) * 480))
            async let returning = source.receive(requireEffectAuthorization: {})
            try await sink.send(credit, requireEffectAuthorization: {})
            let returned = try await returning
            XCTAssertEqual(returned, credit)
        }
        let duplicate = await failure { try await source.authenticate(requireEffectAuthorization: {}) }
        guard case .alreadyStarted = duplicate as? BluetoothAudioChannelError else { return XCTFail("Duplicate authentication was not rejected") }
        XCTAssertFalse(pair.0.isClosed); XCTAssertFalse(pair.1.isClosed)
        try await source.closeAndAwait(); try await sink.closeAndAwait()
    }

    func testHandshakeAuthorizationIsRecheckedAfterNativePartialWrite() async throws {
        let f = try BluetoothAudioFixture.load()
        let allowed = OSAllocatedUnfairLock(initialState: true), written = OSAllocatedUnfairLock(initialState: 0)
        let pair = try nativePair(buffer: 17, observeLeft: { event in
            if case .wrote(let count) = event {
                written.withLock { $0 += count }; allowed.withLock { $0 = false }
            }
        })
        let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source))
        let reading = Task { try await pair.1.readFrame(maximumBytes: 4096, timeout: .seconds(2)) }
        defer { reading.cancel() }
        let error = await failure {
            try await source.authenticate(requireEffectAuthorization: {
                guard allowed.withLock({ $0 }) else { throw Failure.revoked }
            })
        }
        guard case .revoked = error as? Failure else { return XCTFail("Handshake outlived its grant: \(String(describing: error))") }
        XCTAssertEqual(written.withLock { $0 }, 17, "Only the admitted partial write may finish")
        _ = await failure { try await reading.value }
        try await source.closeAndAwait()
        XCTAssertTrue(pair.0.isClosed)
    }

    func testBadNativeCandidateLeavesPendingAttachmentAvailable() async throws {
        let f = try BluetoothAudioFixture.load(), pending = try f.attachment(.sink)
        let badPair = try nativePair(buffer: 256)
        let bad = BluetoothAudioChannel(transport: badPair.1, attachment: pending)
        let attempt = Task { await failure { try await bad.authenticate(requireEffectAuthorization: {}) } }
        var hello = try f.bytes(f.hello); hello[hello.count - 1] ^= 1
        try await badPair.0.writeFrame(hello, timeout: .seconds(2))
        let rejected = await attempt.value
        XCTAssertEqual(rejected as? AudioBluetoothAttachmentError, .authenticationFailed)
        try await bad.closeAndAwait()
        let validPair = try nativePair(buffer: 31)
        let source = BluetoothAudioChannel(transport: validPair.0, attachment: try f.attachment(.source))
        let sink = BluetoothAudioChannel(transport: validPair.1, attachment: pending)
        try await authenticate(source, sink)
        try await source.closeAndAwait(); try await sink.closeAndAwait()
    }

    func testDuplicateCandidateCannotRevokeEstablishedAttachment() async throws {
        let f = try BluetoothAudioFixture.load(), owner = try f.attachment(.sink)
        let pair = try nativePair(buffer: 256)
        let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source))
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: owner)
        try await authenticate(source, sink)
        let other = try nativePair(buffer: 256)
        let competing = BluetoothAudioChannel(transport: other.1, attachment: owner)
        let rejected = await failure { try await competing.authenticate(requireEffectAuthorization: {}) }
        XCTAssertEqual(rejected as? AudioBluetoothAttachmentError, .closed)
        async let incoming = sink.receive(requireEffectAuthorization: {})
        try await source.send(f.packet(), requireEffectAuthorization: {})
        let message = try await incoming
        XCTAssertEqual(message, try f.packet())
        try await source.closeAndAwait(); try await sink.closeAndAwait(); try await competing.closeAndAwait()
    }

    func testCancellingAdmittedReadClosesNativeWorker() async throws {
        let f = try BluetoothAudioFixture.load(), pair = try nativePair(buffer: 256)
        let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source))
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
        try await authenticate(source, sink)
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let reader = Task { try await source.receive { entered.continuation.yield(()); entered.continuation.finish() } }
        try await event(entered.stream)
        reader.cancel()
        let rejected = await failure { try await reader.value }
        XCTAssertTrue(rejected is CancellationError)
        try await source.closeAndAwait()
        XCTAssertTrue(pair.0.isClosed)
        try await sink.closeAndAwait()
    }

    func testConcurrentReaderIsRejectedWithoutDisturbingActiveReader() async throws {
        let f = try BluetoothAudioFixture.load(), pair = try nativePair(buffer: 256)
        let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source))
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
        try await authenticate(source, sink)
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let reader = Task { try await source.receive { entered.continuation.yield(()); entered.continuation.finish() } }
        try await event(entered.stream)
        let duplicate = await failure { try await source.receive(requireEffectAuthorization: {}) }
        guard case .readInProgress = duplicate as? BluetoothAudioChannelError else { reader.cancel(); return XCTFail("Concurrent read was not rejected") }
        XCTAssertFalse(pair.0.isClosed)
        let credit = AudioStreamingMessage(streamID: try f.packet().streamID, body: .credit(retiredBytes: 480))
        try await sink.send(credit, requireEffectAuthorization: {})
        let delivered = try await reader.value
        XCTAssertEqual(delivered, credit)
        try await source.closeAndAwait(); try await sink.closeAndAwait()
    }

    func testParentAndPlaybackRevocationPreventNativeMediaWrite() async throws {
        let f = try BluetoothAudioFixture.load()
        for revokeParent in [false, true] {
            let current = OSAllocatedUnfairLock(initialState: true), written = OSAllocatedUnfairLock(initialState: 0)
            let pair = try nativePair(buffer: 256, observeLeft: { event in
                if case .wrote(let count) = event { written.withLock { $0 += count } }
            })
            let source = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.source, current: {
                if !current.withLock({ $0 }) { throw Failure.revoked }
            }))
            let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
            try await authenticate(source, sink)
            let before = written.withLock { $0 }
            if revokeParent { current.withLock { $0 = false } }
            let denied = await failure {
                try await source.send(f.packet()) { if !revokeParent { throw Failure.revoked } }
            }
            XCTAssertTrue(denied is Failure)
            XCTAssertEqual(written.withLock { $0 }, before)
            XCTAssertTrue(pair.0.isClosed)
            try await source.closeAndAwait(); try await sink.closeAndAwait()
        }
    }

    func testUnansweredHandshakeUsesRemainingPreparationDeadline() async throws {
        let f = try BluetoothAudioFixture.load(), pair = try nativePair(buffer: 16)
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let owner = try f.attachment(.source, now: { clock.withLock { $0 } })
        clock.withLock { $0 = $0.advanced(by: .milliseconds(29_960)) }
        let source = BluetoothAudioChannel(transport: pair.0, attachment: owner)
        let error = await failure { try await source.authenticate(requireEffectAuthorization: {}) }
        XCTAssertEqual(error as? BluetoothControlStreamError, .timedOut)
        XCTAssertTrue(pair.0.isClosed)
        try await source.closeAndAwait()
    }

    func testAuthenticationFailureRetainsUnconfirmedNativeCleanup() async throws {
        let f = try BluetoothAudioFixture.load(), release = DispatchSemaphore(value: 0)
        let overran = OSAllocatedUnfairLock(initialState: false)
        let pair = try nativePair(buffer: 256, observeLeft: { event in
            if case .willExit = event { overran.withLock { $0 = release.wait(timeout: .now() + 5) != .success } }
        })
        let candidate = BluetoothAudioChannel(transport: pair.0, attachment: try f.attachment(.sink))
        let attempt = Task { await failure { try await candidate.authenticate(requireEffectAuthorization: {}) } }
        defer { release.signal() }
        try await pair.1.writeFrame(Data([0]), timeout: .seconds(2))
        let error = await attempt.value
        if case .cleanupFailed(let primary, let cleanup) = error as? BluetoothAudioChannelError {
            XCTAssertEqual(primary as? AudioBluetoothAttachmentError, .unexpectedMessage)
            XCTAssertEqual(cleanup as? BluetoothControlStreamError, .workerExitUnconfirmed)
        } else { XCTFail("Primary and native cleanup failures were not both retained: \(String(describing: error))") }
        release.signal()
        try await candidate.closeAndAwait()
        XCTAssertFalse(overran.withLock { $0 })
    }

    private func authenticate(_ source: BluetoothAudioChannel, _ sink: BluetoothAudioChannel) async throws {
        async let s: Void = source.authenticate(requireEffectAuthorization: {})
        async let r: Void = sink.authenticate(requireEffectAuthorization: {})
        _ = try await (s, r)
    }

    private func nativePair(buffer: Int, observeLeft: @escaping @Sendable (BluetoothControlFrameTransport.NativeEvent) -> Void = { _ in }) throws
        -> (BluetoothControlFrameTransport, BluetoothControlFrameTransport) {
        var forwardIn: InputStream?, forwardOut: OutputStream?, reverseIn: InputStream?, reverseOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: buffer, inputStream: &forwardIn, outputStream: &forwardOut)
        Stream.getBoundStreams(withBufferSize: buffer, inputStream: &reverseIn, outputStream: &reverseOut)
        let left = try BluetoothControlFrameTransport(input: XCTUnwrap(reverseIn), output: XCTUnwrap(forwardOut), observeNativeIO: observeLeft)
        let right = try BluetoothControlFrameTransport(input: XCTUnwrap(forwardIn), output: XCTUnwrap(reverseOut))
        addTeardownBlock {
            left.close(); right.close()
            try await left.closeAndAwait(); try await right.closeAndAwait()
        }
        return (left, right)
    }

    private func event(_ stream: AsyncStream<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw Failure.missingEvent }
            }
            group.addTask { try await Task.sleep(for: .seconds(2)); throw Failure.eventTimeout }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func failure<T>(_ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> (any Error)? {
        do { _ = try await action(); XCTFail("Expected failure", file: file, line: line); return nil }
        catch { return error }
    }
}
