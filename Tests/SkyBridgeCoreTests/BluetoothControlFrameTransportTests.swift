import Foundation
import Darwin
import SkyBridgeProtocolCore
import XCTest
import os
@testable import SkyBridgeAppleTransport

/// Native Foundation streams exercise the real run-loop pump. No Bluetooth radio is simulated as
/// accepted: CoC publication, peer/account admission, codecs and physical output remain separate.
@MainActor
final class BluetoothControlFrameTransportTests: XCTestCase {
    private enum TestFailure: Error { case revoked, nativeCleanupTimeout, missingNativeClose }

    func testReadyNativeIOProgressesWhileMainActorIsBusy() async throws {
        for writing in [false, true] {
            let body = Data([7, 9])
            let transport = memoryTransport(try P2PControlFramePolicy.frame(body: body))
            let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let finished = OSAllocatedUnfairLock(initialState: false)
            let worker = Task.detached { () -> Result<Data, Error> in
                ready.continuation.yield(()); ready.continuation.finish()
                var iterator = start.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { return .failure(TestFailure.missingNativeClose) }
                let result: Result<Data, Error>
                do {
                    if writing {
                        try await transport.writeFrame(body, timeout: .seconds(2))
                        result = .success(Data())
                    } else {
                        result = .success(try await transport.readFrame(maximumBytes: 16, timeout: .seconds(2)))
                    }
                } catch { result = .failure(error) }
                finished.withLock { $0 = true }
                return result
            }
            defer { worker.cancel(); start.continuation.finish() }
            try await awaitNativeEvent(ready.stream)
            // Intentionally occupy MainActor. Both streams are already native-ready; byte I/O
            // and its completion must not require this UI executor to become available.
            // Start I/O only after the last await. A CPU-busy UI models this boundary without
            // making the UI synchronously wait on a lower-QoS task's semaphore.
            start.continuation.yield(()); start.continuation.finish()
            occupyUI(for: .milliseconds(400))
            let completedWhileUIBusy = finished.withLock { $0 }
            XCTAssertTrue(completedWhileUIBusy, writing ? "Write waited for UI" : "Read waited for UI")
            if !completedWhileUIBusy { worker.cancel() }
            let result = await worker.value
            transport.close()
            if completedWhileUIBusy {
                XCTAssertEqual(try result.get(), writing ? Data() : body)
            }
        }
    }

    /// Bounded synchronous fault injection only. Production I/O must not run on this executor.
    private func occupyUI(for duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {} // No await or run-loop servicing in this bounded test.
    }

    func testAllNativeOperationsUseOneBackgroundThreadAndCleanupJoinsIt() async throws {
        struct Trace: Sendable {
            var threadIDs = Set<UInt64>()
            var threadIDErrors = 0
            var usedMainThread = false
            var opened = 0, closed = 0, exiting = 0, readBytes = 0, writtenBytes = 0
        }
        let trace = OSAllocatedUnfairLock(initialState: Trace())
        let body = Data([1, 4, 7])
        let transport = own(BluetoothControlFrameTransport(
            input: InputStream(data: try P2PControlFramePolicy.frame(body: body)), output: OutputStream(toMemory: ()),
            observeNativeIO: { event in
                var identifier: UInt64 = 0
                let status = pthread_threadid_np(nil, &identifier)
                let observedThreadID = identifier
                trace.withLock {
                    if status == 0 { $0.threadIDs.insert(observedThreadID) } else { $0.threadIDErrors += 1 }
                    $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
                    switch event {
                    case .openRequested: $0.opened += 1
                    case .read(let bytes): $0.readBytes += bytes
                    case .wrote(let bytes): $0.writtenBytes += bytes
                    case .closed: $0.closed += 1
                    case .willExit: $0.exiting += 1
                    }
                }
            }))
        let read = try await transport.readFrame(maximumBytes: 16, timeout: .seconds(2))
        try await transport.writeFrame(body, timeout: .seconds(2))
        XCTAssertEqual(read, body)
        try await transport.closeAndAwait()
        try await transport.closeAndAwait()
        let result = trace.withLock { $0 }
        XCTAssertEqual(result.threadIDErrors, 0); XCTAssertEqual(result.threadIDs.count, 1)
        XCTAssertFalse(result.usedMainThread)
        XCTAssertEqual(result.opened, 1); XCTAssertEqual(result.closed, 1); XCTAssertEqual(result.exiting, 1)
        XCTAssertEqual(result.readBytes, body.count + 4); XCTAssertEqual(result.writtenBytes, body.count + 4)
    }

    func testCleanupWaitDoesNotCompleteAtThePreExitNotification() async throws {
        let tail = makePausedExit()
        defer { tail.release.signal(); tail.transport.close() }
        let completed = OSAllocatedUnfairLock(initialState: false)
        let closing = Task.detached {
            try await tail.transport.closeAndAwait()
            completed.withLock { $0 = true }
        }
        try await awaitNativeEvent(tail.entered)
        XCTAssertTrue(tail.transport.isClosed)
        // The native streams and run-loop source are already closed; only thread exit is held.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(completed.withLock { $0 })
        tail.release.signal()
        try await closing.value
        XCTAssertTrue(completed.withLock { $0 })
        XCTAssertFalse(tail.releaseTimedOut.withLock { $0 })
    }

    func testCancelledCleanupCallerStillWaitsForTheOwnedThread() async throws {
        let tail = makePausedExit()
        defer { tail.release.signal(); tail.transport.close() }
        let closing = Task.detached { try await tail.transport.closeAndAwait() }
        try await awaitNativeEvent(tail.entered)
        closing.cancel()
        tail.release.signal()
        try await closing.value
        XCTAssertTrue(closing.isCancelled, "Cleanup must not clear the caller's cancellation state")
        XCTAssertFalse(tail.releaseTimedOut.withLock { $0 })
        try await tail.transport.closeAndAwait()
    }

    func testUnconfirmedExitIsReportedAndSameOwnerCanBeCheckedAgain() async throws {
        let tail = makePausedExit()
        defer { tail.release.signal(); tail.transport.close() }
        let closing = Task.detached { try await tail.transport.closeAndAwait() }
        try await awaitNativeEvent(tail.entered)
        let error = await failure { try await closing.value }
        XCTAssertEqual(error as? BluetoothControlStreamError, .workerExitUnconfirmed)
        XCTAssertTrue(tail.transport.isClosed)
        tail.release.signal()
        try await tail.transport.closeAndAwait()
        XCTAssertFalse(tail.releaseTimedOut.withLock { $0 })
    }

    func testMemoryFramesPreserveBoundariesAndDeliverCompleteFrameBeforeEOF() async throws {
        let first = Data([1, 2, 3]), second = Data([4, 5])
        let wire = try P2PControlFramePolicy.frame(body: first) + P2PControlFramePolicy.frame(body: second)
        let transport = memoryTransport(wire)
        defer { transport.close() }
        let firstRead = try await transport.readFrame(maximumBytes: 64, timeout: .seconds(2))
        let secondRead = try await transport.readFrame(maximumBytes: 64, timeout: .seconds(2))
        XCTAssertEqual(firstRead, first); XCTAssertEqual(secondRead, second)
        XCTAssertFalse(transport.isClosed)
        let error = await failure { try await transport.readFrame(maximumBytes: 64, timeout: .seconds(2)) }
        XCTAssertEqual(error as? BluetoothControlStreamError, .unexpectedEnd)
        XCTAssertTrue(transport.isClosed)
    }

    func testNativeBoundStreamsCarryConcurrentBidirectionalFragmentedFrames() async throws {
        let pair = try makePair(bufferBytes: 257)
        defer { pair.close() }
        let leftBytes = Data((0..<100_003).map { UInt8(truncatingIfNeeded: $0) })
        let rightBytes = Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0 * 7) })
        async let leftReceive = pair.left.readFrame(maximumBytes: 120_000, timeout: .seconds(10))
        async let rightReceive = pair.right.readFrame(maximumBytes: 120_000, timeout: .seconds(10))
        async let leftSend: Void = pair.left.writeFrame(leftBytes, timeout: .seconds(10))
        async let rightSend: Void = pair.right.writeFrame(rightBytes, timeout: .seconds(10))
        let received = try await (leftReceive, rightReceive, leftSend, rightSend)
        XCTAssertEqual(received.0, rightBytes); XCTAssertEqual(received.1, leftBytes)
        XCTAssertFalse(pair.left.isClosed); XCTAssertFalse(pair.right.isClosed)
    }

    func testNativeOneByteBufferSplitsLengthPrefixAndPayload() async throws {
        let pair = try makePair(bufferBytes: 1)
        defer { pair.close() }
        let body = Data([9, 8, 7, 6, 5])
        async let received = pair.right.readFrame(maximumBytes: 32, timeout: .seconds(5))
        try await pair.left.writeFrame(body, timeout: .seconds(5))
        let value = try await received
        XCTAssertEqual(value, body)
    }

    func testMemoryIOYieldsAcrossPumpBudgetWithoutTruncatingData() async throws {
        let body = Data((0..<300_003).map { UInt8(truncatingIfNeeded: $0) })
        let output = OutputStream(toMemory: ())
        let transport = own(BluetoothControlFrameTransport(input: InputStream(data: try P2PControlFramePolicy.frame(body: body)),
                                                           output: output))
        defer { transport.close() }
        async let received = transport.readFrame(maximumBytes: body.count, timeout: .seconds(5))
        try await transport.writeFrame(body, timeout: .seconds(5))
        let value = try await received
        XCTAssertEqual(value, body)
        try await transport.closeAndAwait()
        XCTAssertEqual(output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data,
                       try P2PControlFramePolicy.frame(body: body))
    }

    func testWriteDeadlineAbortsNativeBackpressure() async throws {
        let pair = try makePair(bufferBytes: 8)
        defer { pair.close() }
        let error = await failure { try await pair.left.writeFrame(Data(repeating: 1, count: 128), timeout: .milliseconds(40)) }
        XCTAssertEqual(error as? BluetoothControlStreamError, .timedOut)
        XCTAssertTrue(pair.left.isClosed)
    }

    func testReadDeadlineRetiresWaitingNativeStream() async throws {
        let pair = try makePair(bufferBytes: 8)
        defer { pair.close() }
        let error = await failure { try await pair.left.readFrame(maximumBytes: 128, timeout: .milliseconds(40)) }
        XCTAssertEqual(error as? BluetoothControlStreamError, .timedOut)
        XCTAssertTrue(pair.left.isClosed)
    }

    func testCancellationRetiresBothOwnedDirectionsAndClosesNativeStreams() async throws {
        let pair = try makePair(bufferBytes: 8)
        defer { pair.close() }
        let readStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let writeStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let reading = Task { @MainActor in
            readStarted.continuation.yield(()); readStarted.continuation.finish()
            return try await pair.left.readFrame(maximumBytes: 128, timeout: .seconds(5))
        }
        let writing = Task { @MainActor in
            writeStarted.continuation.yield(()); writeStarted.continuation.finish()
            try await pair.left.writeFrame(Data(repeating: 7, count: 128), timeout: .seconds(5))
        }
        for await _ in readStarted.stream { }
        for await _ in writeStarted.stream { }
        writing.cancel()
        let writeError = await failure { try await writing.value }
        let readError = await failure { try await reading.value }
        XCTAssertTrue(writeError is CancellationError); XCTAssertTrue(readError is CancellationError)
        XCTAssertTrue(pair.left.isClosed)
        try await pair.left.closeAndAwait()
        XCTAssertEqual(pair.leftInput.streamStatus, .closed)
        XCTAssertEqual(pair.leftOutput.streamStatus, .closed)
    }

    func testConcurrentDuplicateOperationsDoNotCloseTheirOriginalOwners() async throws {
        let pair = try makePair(bufferBytes: 8)
        defer { pair.close() }
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let body = Data(repeating: 6, count: 128), reply = Data([3, 2, 1])
        let reading = Task { @MainActor in
            started.continuation.yield(())
            return try await pair.left.readFrame(maximumBytes: 128, timeout: .seconds(5))
        }
        let writing = Task { @MainActor in
            started.continuation.yield(())
            try await pair.left.writeFrame(body, timeout: .seconds(5))
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(); _ = await iterator.next(); started.continuation.finish()
        let readError = await failure { try await pair.left.readFrame(maximumBytes: 128, timeout: .seconds(5)) }
        let writeError = await failure { try await pair.left.writeFrame(reply, timeout: .seconds(5)) }
        XCTAssertEqual(readError as? BluetoothControlStreamError, .readInProgress)
        XCTAssertEqual(writeError as? BluetoothControlStreamError, .writeInProgress)
        XCTAssertFalse(pair.left.isClosed)
        async let peerReceive = pair.right.readFrame(maximumBytes: 128, timeout: .seconds(5))
        try await pair.right.writeFrame(reply, timeout: .seconds(5))
        let receivedReply = try await reading.value
        try await writing.value
        let receivedBody = try await peerReceive
        XCTAssertEqual(receivedReply, reply); XCTAssertEqual(receivedBody, body)
    }

    func testCancellationBeforeAdmissionDoesNotCloseOrWriteToTransport() async throws {
        let output = OutputStream(toMemory: ())
        let transport = own(BluetoothControlFrameTransport(input: InputStream(data: Data()), output: output))
        defer { transport.close() }
        let task = Task { @MainActor in try await transport.writeFrame(Data([1]), timeout: .seconds(2)) }
        task.cancel()
        let error = await failure { try await task.value }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(transport.isClosed)
        try await transport.closeAndAwait()
        XCTAssertEqual(output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data, Data())
    }

    func testRevocationIsRecheckedAfterNativeBackpressure() async throws {
        let pair = try makePair(bufferBytes: 8)
        defer { pair.close() }
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let writing = Task { @MainActor in
            started.continuation.yield(()); started.continuation.finish()
            try await pair.left.writeFrame(Data(repeating: 5, count: 128), timeout: .seconds(5),
                requireEffectAuthorization: {
                    guard allowed.withLock({ $0 }) else { throw TestFailure.revoked }
                })
        }
        for await _ in started.stream { }
        allowed.withLock { $0 = false }
        let receiving = Task { @MainActor in try await pair.right.readFrame(maximumBytes: 128, timeout: .seconds(5)) }
        let writeError = await failure { try await writing.value }
        let peerError = await failure { try await receiving.value }
        XCTAssertTrue(writeError is TestFailure)
        XCTAssertNotNil(peerError)
        XCTAssertTrue(pair.left.isClosed)
    }

    func testNativeSuccessPastDeadlineCannotBeatDelayedTimer() async throws {
        for isWrite in [false, true] {
            let base = ContinuousClock.now
            let clock = OSAllocatedUnfairLock(initialState: base)
            let progress = OSAllocatedUnfairLock(initialState: 0)
            let body = Data([1, 2, 3])
            let output = OutputStream(toMemory: ())
            let transport = own(BluetoothControlFrameTransport(
                input: InputStream(data: try P2PControlFramePolicy.frame(body: body)), output: output,
                now: { clock.withLock { $0 } },
                observeNativeIO: { event in
                    switch event {
                    case .read(let bytes), .wrote(let bytes):
                        progress.withLock { $0 += bytes }
                        clock.withLock { $0 = base.advanced(by: .seconds(3)) }
                    default: break
                    }
                }))
            defer { transport.close() }
            let error: Error?
            if isWrite { error = await failure { try await transport.writeFrame(body, timeout: .seconds(2)) } }
            else { error = await failure { try await transport.readFrame(maximumBytes: 64, timeout: .seconds(2)) } }
            XCTAssertEqual(error as? BluetoothControlStreamError, .timedOut)
            XCTAssertGreaterThan(progress.withLock { $0 }, 0, "Clock must expire after real native I/O, not a check-count guess")
            try await transport.closeAndAwait()
            if isWrite {
                XCTAssertEqual(output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data,
                               try P2PControlFramePolicy.frame(body: body))
            }
            XCTAssertTrue(transport.isClosed)
        }
    }

    func testInvalidLengthPrefixesFailBeforeWaitingForBody() async throws {
        for length in [0, 16_641, P2PControlFramePolicy.maximumBodyByteCount + 1] {
            var prefix = UInt32(length).bigEndian
            let transport = memoryTransport(Data(bytes: &prefix, count: 4))
            defer { transport.close() }
            let error = await failure { try await transport.readFrame(maximumBytes: 16_640, timeout: .seconds(2)) }
            if length == 16_641 {
                XCTAssertEqual(error as? BluetoothControlStreamError, .frameTooLarge(actual: length, maximum: 16_640))
            } else { XCTAssertTrue(error is P2PControlFramePolicyError) }
            XCTAssertTrue(transport.isClosed)
        }
    }

    func testInvalidLocalArgumentsDoNotRetireAnUnusedConnection() async throws {
        let transport = memoryTransport(try P2PControlFramePolicy.frame(body: Data([9])))
        defer { transport.close() }
        let limitError = await failure { try await transport.readFrame(maximumBytes: 0, timeout: .seconds(1)) }
        let timeoutError = await failure { try await transport.writeFrame(Data([1]), timeout: .zero) }
        let emptyError = await failure { try await transport.writeFrame(Data(), timeout: .seconds(1)) }
        XCTAssertEqual(limitError as? BluetoothControlStreamError, .invalidReadLimit)
        XCTAssertEqual(timeoutError as? BluetoothControlStreamError, .invalidTimeout)
        XCTAssertTrue(emptyError is P2PControlFramePolicyError)
        XCTAssertFalse(transport.isClosed)
        let value = try await transport.readFrame(maximumBytes: 1, timeout: .seconds(1))
        XCTAssertEqual(value, Data([9]))
    }

    func testLateEventsAndCancelledTimersCannotRetireAnotherOwner() async throws {
        let firstInput = InputStream(data: try P2PControlFramePolicy.frame(body: Data([1])))
        let first = own(BluetoothControlFrameTransport(input: firstInput, output: OutputStream(toMemory: ())))
        _ = try await first.readFrame(maximumBytes: 1, timeout: .milliseconds(80))
        first.close()
        let next = memoryTransport(try P2PControlFramePolicy.frame(body: Data([2])))
        defer { next.close() }
        first.stream(firstInput, handle: [.errorOccurred, .endEncountered, .hasBytesAvailable])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(next.isClosed)
        let value = try await next.readFrame(maximumBytes: 1, timeout: .seconds(1))
        XCTAssertEqual(value, Data([2]))
    }

    func testUnusedTransportDeinitializationClosesItsNativeStreamPair() async throws {
        let input = InputStream(data: Data()), output = OutputStream(toMemory: ())
        let closed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let statuses = OSAllocatedUnfairLock<(UInt, UInt)?>(initialState: nil)
        var transport: BluetoothControlFrameTransport? = BluetoothControlFrameTransport(input: input, output: output,
            observeNativeIO: { event in
                if case let .closed(inputStatus, outputStatus) = event {
                    statuses.withLock { $0 = (inputStatus, outputStatus) }
                    closed.continuation.yield(()); closed.continuation.finish()
                }
            })
        weak let owner = transport
        XCTAssertNotNil(owner)
        transport = nil
        try await awaitNativeEvent(closed.stream)
        // open() and a concurrent StreamDelegate callback may temporarily hold a
        // strong borrow. Require release at the actual bounded cleanup barrier,
        // rather than assuming no native call is active at the local assignment.
        XCTAssertNil(owner)
        let result = try XCTUnwrap(statuses.withLock { $0 })
        XCTAssertEqual(result.0, Stream.Status.closed.rawValue)
        XCTAssertEqual(result.1, Stream.Status.closed.rawValue)
    }

    private func memoryTransport(_ input: Data) -> BluetoothControlFrameTransport {
        own(BluetoothControlFrameTransport(input: InputStream(data: input), output: OutputStream(toMemory: ())))
    }

    private func own(_ transport: BluetoothControlFrameTransport) -> BluetoothControlFrameTransport {
        addTeardownBlock { try await transport.closeAndAwait() }
        return transport
    }

    private struct PausedExit: Sendable {
        let transport: BluetoothControlFrameTransport
        let release: DispatchSemaphore
        let entered: AsyncStream<Void>
        let releaseTimedOut: OSAllocatedUnfairLock<Bool>
    }

    private func makePausedExit() -> PausedExit {
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let release = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let transport = own(BluetoothControlFrameTransport(input: InputStream(data: Data()), output: OutputStream(toMemory: ()),
            observeNativeIO: { event in
                if case .willExit = event {
                    signal.continuation.yield(()); signal.continuation.finish()
                    let result = release.wait(timeout: .now() + 4)
                    timedOut.withLock { $0 = result != .success }
                }
            }))
        return PausedExit(transport: transport, release: release, entered: signal.stream, releaseTimedOut: timedOut)
    }

    private func awaitNativeEvent(_ stream: AsyncStream<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw TestFailure.missingNativeClose }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw TestFailure.nativeCleanupTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @MainActor private struct Pair {
        let left: BluetoothControlFrameTransport
        let right: BluetoothControlFrameTransport
        let leftInput: InputStream
        let leftOutput: OutputStream
        func close() { left.close(); right.close() }
    }

    private func makePair(bufferBytes: Int) throws -> Pair {
        var forwardInput: InputStream?, forwardOutput: OutputStream?
        var reverseInput: InputStream?, reverseOutput: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferBytes, inputStream: &forwardInput, outputStream: &forwardOutput)
        Stream.getBoundStreams(withBufferSize: bufferBytes, inputStream: &reverseInput, outputStream: &reverseOutput)
        let leftInput = try XCTUnwrap(reverseInput), leftOutput = try XCTUnwrap(forwardOutput)
        let rightInput = try XCTUnwrap(forwardInput), rightOutput = try XCTUnwrap(reverseOutput)
        return Pair(left: own(BluetoothControlFrameTransport(input: leftInput, output: leftOutput)),
                    right: own(BluetoothControlFrameTransport(input: rightInput, output: rightOutput)),
                    leftInput: leftInput, leftOutput: leftOutput)
    }

    private func failure<T>(_ operation: () async throws -> T,
                            file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        do { _ = try await operation(); XCTFail("Expected an operation failure", file: file, line: line); return nil }
        catch { return error }
    }
}
