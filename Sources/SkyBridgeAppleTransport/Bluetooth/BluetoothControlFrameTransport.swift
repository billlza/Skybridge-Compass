import CoreBluetooth
import CoreFoundation
import Foundation
import SkyBridgeProtocolCore
import os

public enum BluetoothControlStreamError: Error, Equatable, Sendable {
    case closed, readInProgress, writeInProgress, timedOut, unexpectedEnd
    case invalidTimeout, invalidReadLimit, frameTooLarge(actual: Int, maximum: Int)
    case nativeReadFailed, nativeWriteFailed, unavailableNativeStreams
    case runLoopUnavailable, runLoopStopped, workerExitUnconfirmed
}

/// An owned CoC stream pair, independent of UI scheduling. This transports framed bytes only;
/// identity, account membership and playback permission remain with the authenticated owner.
/// Native streams never leave their private worker storage after handoff. All open/read/write/
/// schedule/remove/close operations run on the same dedicated run-loop thread.
public final class BluetoothControlFrameTransport: NSObject, StreamDelegate, Sendable {
    enum NativeEvent: Sendable {
        case openRequested, read(Int), wrote(Int), closed(inputStatus: UInt, outputStatus: UInt), willExit
    }
    private let worker: BluetoothStreamWorker
    private let lifetime = BluetoothStreamThreadLifetime()
    public var terminalFailure: Error? { worker.mailbox.failure }
    /// Logical retirement. Use closeAndAwait() to confirm native cleanup and actual thread exit.
    public var isClosed: Bool { terminalFailure != nil }

    public convenience init(channel: sending CBL2CAPChannel) throws {
        let input = channel.inputStream, output = channel.outputStream
        guard let input, let output else {
            input?.close(); output?.close()
            throw BluetoothControlStreamError.unavailableNativeStreams
        }
        self.init(input: input, output: output, channel: channel)
    }

    /// Core Bluetooth keeps aliases to its callback argument, so Swift cannot transfer that
    /// argument as a disconnected `sending` region. Only the module's main-queue delegate uses
    /// this bridge. After handoff it never accesses the channel or streams again; the existing
    /// private worker storage confines all stream I/O to its one native thread.
    @MainActor
    convenience init(acceptedChannel channel: CBL2CAPChannel) throws {
        let input = channel.inputStream, output = channel.outputStream
        guard let input, let output else {
            input?.close(); output?.close()
            throw BluetoothControlStreamError.unavailableNativeStreams
        }
        self.init(input: input, output: output, channel: channel)
    }

    /// Internal framework bridge and Foundation test seam. Ownership transfers here; references may be
    /// inspected only after closeAndAwait confirms exit, never while this worker is live.
    init(input: InputStream, output: OutputStream, channel: CBL2CAPChannel? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         observeNativeIO: (@Sendable (NativeEvent) -> Void)? = nil) {
        worker = BluetoothStreamWorker(input: input, output: output, channel: channel,
                                       now: now, observe: observeNativeIO)
        super.init()
        worker.installDelegate(self)
        let ownedWorker = worker
        lifetime.start { ownedWorker.run() }
    }

    deinit { worker.close(BluetoothControlStreamError.closed) }

    public func readFrame(maximumBytes: Int, timeout: Duration) async throws -> Data {
        defer { withExtendedLifetime(self) {} } // The weak native delegate must outlive this operation.
        guard maximumBytes > 0, maximumBytes <= P2PControlFramePolicy.maximumBodyByteCount else {
            throw BluetoothControlStreamError.invalidReadLimit
        }
        try validateTimeout(timeout)
        try Task.checkCancellation()
        let operation = BluetoothStreamOperation<Data>(deadline: worker.now().advanced(by: timeout))
        let request = BluetoothStreamRead(operation: operation, maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                do { try worker.mailbox.enqueue(request); worker.wake.signal() }
                catch { operation.finish(.failure(error)) }
            }
        } onCancel: { [worker] in
            operation.cancel()
            worker.cancel(operation.id)
        }
    }

    /// The captured authorization check must be bounded, thread-safe and non-reentrant. It runs
    /// on the native worker immediately before every partial write, including after backpressure.
    public func writeFrame(_ body: Data, timeout: Duration,
                           requireEffectAuthorization: (@Sendable () throws -> Void)? = nil) async throws {
        defer { withExtendedLifetime(self) {} }
        try validateTimeout(timeout)
        try Task.checkCancellation()
        let frame = try P2PControlFramePolicy.frame(body: body)
        let operation = BluetoothStreamOperation<Void>(deadline: worker.now().advanced(by: timeout))
        let request = BluetoothStreamWrite(operation: operation, bytes: frame, effect: requireEffectAuthorization)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.install(continuation)
                do { try worker.mailbox.enqueue(request); worker.wake.signal() }
                catch { operation.finish(.failure(error)) }
            }
        } onCancel: { [worker] in
            operation.cancel()
            worker.cancel(operation.id)
        }
    }

    public func close() { worker.close(BluetoothControlStreamError.closed) }

    /// Cleanup is not abandoned when the calling task is cancelled. A bounded, independent
    /// observer checks the actual Thread.isFinished flag, not a flag set just before return.
    /// A timeout retains this owner for an explicit later cleanup check; it never reopens I/O.
    public func closeAndAwait() async throws {
        close()
        if lifetime.isFinished, worker.mailbox.didCleanUp { return }
        let observer = Task.detached { [worker, lifetime] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                guard ContinuousClock.now < deadline else { throw BluetoothControlStreamError.workerExitUnconfirmed }
                if lifetime.isFinished {
                    guard worker.mailbox.didCleanUp else { throw BluetoothControlStreamError.workerExitUnconfirmed }
                    return
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await observer.value
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        // Framework callbacks transfer immutable identifiers/flags only, never a Stream object.
        worker.recordEvent(identifier: ObjectIdentifier(aStream), event: eventCode.rawValue)
    }

    private func validateTimeout(_ timeout: Duration) throws {
        guard timeout > .zero, timeout <= .seconds(300) else { throw BluetoothControlStreamError.invalidTimeout }
    }
}

/// Thread is non-Sendable in Foundation. Its private handle is created/started once, and only
/// its documented finished-state getter is exposed under this lock; the Thread never escapes.
private final class BluetoothStreamThreadLifetime: Sendable {
    private let native = OSAllocatedUnfairLock<Thread?>(uncheckedState: nil)
    func start(_ body: @escaping @Sendable () -> Void) {
        native.withLock { thread in
            precondition(thread == nil, "A stream worker can only be started once")
            let created = Thread(block: body)
            created.name = "SkyBridge Bluetooth Stream"
            created.qualityOfService = .userInitiated
            thread = created
            created.start()
        }
    }
    var isFinished: Bool { native.withLock { $0?.isFinished == true } }
}

private final class BluetoothStreamOperation<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var result: Result<Value, Error>?
        var continuation: CheckedContinuation<Value, Error>?
    }
    let id = UUID()
    let deadline: ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    func cancel() { state.withLock { $0.cancelled = true } }
    func check(at now: ContinuousClock.Instant) throws {
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        guard now < deadline else { throw BluetoothControlStreamError.timedOut }
    }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = state.withLock { value -> Result<Value, Error>? in
            if let result = value.result { return result }
            precondition(value.continuation == nil, "An I/O operation has one continuation")
            value.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func finish(_ result: Result<Value, Error>) {
        let continuation = state.withLock { value -> CheckedContinuation<Value, Error>? in
            guard value.result == nil else { return nil }
            value.result = result
            let continuation = value.continuation
            value.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class BluetoothStreamRead: Sendable {
    let operation: BluetoothStreamOperation<Data>
    let maximumBytes: Int
    init(operation: BluetoothStreamOperation<Data>, maximumBytes: Int) {
        self.operation = operation; self.maximumBytes = maximumBytes
    }
}
private final class BluetoothStreamWrite: Sendable {
    let operation: BluetoothStreamOperation<Void>
    let bytes: Data
    let effect: (@Sendable () throws -> Void)?
    init(operation: BluetoothStreamOperation<Void>, bytes: Data, effect: (@Sendable () throws -> Void)?) {
        self.operation = operation; self.bytes = bytes; self.effect = effect
    }
}

private struct BluetoothStreamWork: Sendable {
    let read: BluetoothStreamRead?
    let write: BluetoothStreamWrite?
    let inputEvents: UInt
    let outputEvents: UInt
}

/// One admitted operation per direction, at most one queued request per direction, and coalesced
/// native event bits. No unbounded packet or executor-work queue is created while a peer stalls.
private final class BluetoothStreamMailbox: Sendable {
    private struct State: Sendable {
        var reader: BluetoothStreamRead?
        var writer: BluetoothStreamWrite?
        var nextRead: BluetoothStreamRead?
        var nextWrite: BluetoothStreamWrite?
        var inputEvents: UInt = 0
        var outputEvents: UInt = 0
        var failure: Error?
        var cleaned = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> ContinuousClock.Instant
    init(now: @escaping @Sendable () -> ContinuousClock.Instant) { self.now = now }
    var failure: Error? { state.withLock { $0.failure } }
    var didCleanUp: Bool { state.withLock { $0.cleaned } }

    func enqueue(_ read: BluetoothStreamRead) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            try read.operation.check(at: now())
            guard $0.reader == nil else { throw BluetoothControlStreamError.readInProgress }
            $0.reader = read; $0.nextRead = read
        }
    }
    func enqueue(_ write: BluetoothStreamWrite) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            try write.operation.check(at: now())
            guard $0.writer == nil else { throw BluetoothControlStreamError.writeInProgress }
            $0.writer = write; $0.nextWrite = write
        }
    }
    func takeWork() -> BluetoothStreamWork {
        state.withLock {
            let work = BluetoothStreamWork(read: $0.nextRead, write: $0.nextWrite,
                                          inputEvents: $0.inputEvents, outputEvents: $0.outputEvents)
            $0.nextRead = nil; $0.nextWrite = nil; $0.inputEvents = 0; $0.outputEvents = 0
            return work
        }
    }
    func record(input: UInt, output: UInt) -> Bool {
        state.withLock {
            guard $0.failure == nil else { return false }
            $0.inputEvents |= input; $0.outputEvents |= output
            return true
        }
    }
    func requireCurrent(_ id: UUID) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard $0.reader?.operation.id == id || $0.writer?.operation.id == id else {
                throw BluetoothControlStreamError.closed
            }
        }
    }
    func close(_ failure: Error) { state.withLock { if $0.failure == nil { $0.failure = failure } } }
    func cancel(_ id: UUID) {
        state.withLock {
            guard $0.failure == nil, $0.reader?.operation.id == id || $0.writer?.operation.id == id else { return }
            $0.failure = CancellationError()
        }
    }
    func complete(_ read: BluetoothStreamRead, value: Data) {
        let accepted = state.withLock { state in
            guard state.failure == nil, state.reader === read else { return false }
            do { try read.operation.check(at: now()) }
            catch { state.failure = error; return false }
            state.reader = nil
            return true
        }
        if accepted { read.operation.finish(.success(value)) }
    }
    func complete(_ write: BluetoothStreamWrite) {
        let accepted = state.withLock { state in
            guard state.failure == nil, state.writer === write else { return false }
            do { try write.operation.check(at: now()) }
            catch { state.failure = error; return false }
            state.writer = nil
            return true
        }
        if accepted { write.operation.finish(.success(())) }
    }
    func finishCleanup() {
        let pending = state.withLock { state in
            let failure = state.failure ?? BluetoothControlStreamError.closed
            state.failure = failure; state.cleaned = true
            let pending = (state.reader, state.writer, failure)
            state.reader = nil; state.writer = nil; state.nextRead = nil; state.nextWrite = nil
            state.inputEvents = 0; state.outputEvents = 0
            return pending
        }
        // Failure waiters are released only after the owning thread has closed both native streams.
        pending.0?.operation.finish(.failure(pending.2))
        pending.1?.operation.finish(.failure(pending.2))
    }
}

/// Only signal/wakeup is called across threads. Creation, installation and invalidation occur on
/// the owning run-loop thread; all opaque CF references stay inside this private locked storage.
private final class BluetoothStreamWake: Sendable {
    private struct Native { var loop: CFRunLoop?; var source: CFRunLoopSource? }
    private let native = OSAllocatedUnfairLock(uncheckedState: Native())
    func installOnCurrentThread() throws {
        try native.withLock { state in
            var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in })
            guard let loop = CFRunLoopGetCurrent(), let source = CFRunLoopSourceCreate(nil, 0, &context) else {
                throw BluetoothControlStreamError.runLoopUnavailable
            }
            CFRunLoopAddSource(loop, source, .defaultMode)
            state.loop = loop; state.source = source
        }
    }
    func signal() {
        native.withLock {
            guard let loop = $0.loop, let source = $0.source else { return }
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(loop)
        }
    }
    func removeOnCurrentThread() {
        native.withLock {
            if let loop = $0.loop, let source = $0.source {
                CFRunLoopRemoveSource(loop, source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
            $0.loop = nil; $0.source = nil
        }
    }
}

private final class BluetoothStreamWorker: Sendable {
    let mailbox: BluetoothStreamMailbox
    let wake = BluetoothStreamWake()
    let now: @Sendable () -> ContinuousClock.Instant
    private let inputID: ObjectIdentifier
    private let outputID: ObjectIdentifier
    private let observe: (@Sendable (BluetoothControlFrameTransport.NativeEvent) -> Void)?
    // Foundation explicitly makes Stream non-Sendable. No conformance is added to it. The
    // uncheckedState initializer is the narrow native ownership boundary: this private lock
    // never returns a Stream or pump, and only run() performs native operations after handoff.
    private let native: OSAllocatedUnfairLock<BluetoothNativeStreamPump>

    init(input: InputStream, output: OutputStream, channel: CBL2CAPChannel?,
         now: @escaping @Sendable () -> ContinuousClock.Instant,
         observe: (@Sendable (BluetoothControlFrameTransport.NativeEvent) -> Void)?) {
        self.now = now
        self.observe = observe
        inputID = ObjectIdentifier(input); outputID = ObjectIdentifier(output)
        mailbox = BluetoothStreamMailbox(now: now)
        native = OSAllocatedUnfairLock(uncheckedState: BluetoothNativeStreamPump(input: input, output: output,
            channel: channel, now: now, observe: observe))
    }
    func installDelegate(_ delegate: BluetoothControlFrameTransport) {
        // Only sets a weak reference before the worker starts; no Stream API is called here.
        native.withLock { $0.delegate = delegate }
    }
    func recordEvent(identifier: ObjectIdentifier, event: UInt) {
        guard identifier == inputID || identifier == outputID else { return }
        if mailbox.record(input: identifier == inputID ? event : 0, output: identifier == outputID ? event : 0) {
            wake.signal()
        }
    }
    func cancel(_ id: UUID) { mailbox.cancel(id); wake.signal() }
    func close(_ error: Error) { mailbox.close(error); wake.signal() }

    func run() {
        defer {
            native.withLock { $0.close() }
            wake.removeOnCurrentThread()
            mailbox.finishCleanup()
            // Deliberately distinct from Thread.isFinished; observers must not treat this as exit.
            observe?(.willExit)
        }
        do {
            try wake.installOnCurrentThread()
            if mailbox.failure != nil { return }
            try native.withLock { try $0.open() }
            while mailbox.failure == nil {
                try autoreleasepool {
                    let work = mailbox.takeWork()
                    let result = native.withLock { $0.tick(work, mailbox: mailbox) }
                    if let read = result.read { mailbox.complete(read.0, value: read.1) }
                    if let write = result.write { mailbox.complete(write) }
                    if let error = result.failure { mailbox.close(error) }
                    if mailbox.failure != nil { return }
                    let outcome = CFRunLoopRunInMode(.defaultMode, result.waitSeconds, true)
                    if outcome == .finished || outcome == .stopped {
                        throw BluetoothControlStreamError.runLoopStopped
                    }
                }
            }
        } catch { mailbox.close(error) }
    }
}

/// Mutable native/parser state is confined to the dedicated run loop and its private worker lock.
/// The delegate itself only posts event bits, so even a synchronous callback cannot reenter this pump.
private final class BluetoothNativeStreamPump {
    private final class Read {
        let request: BluetoothStreamRead
        var prefix = Data(), body = Data()
        var bodyCount: Int?
        var remaining: Int { bodyCount.map { $0 - body.count } ?? (4 - prefix.count) }
        init(_ request: BluetoothStreamRead) { self.request = request }
    }
    private final class Write {
        let request: BluetoothStreamWrite
        var offset = 0
        init(_ request: BluetoothStreamWrite) { self.request = request }
    }
    struct Result: Sendable {
        var read: (BluetoothStreamRead, Data)?
        var write: BluetoothStreamWrite?
        var failure: Error?
        var waitSeconds: Double = 300
    }
    weak var delegate: BluetoothControlFrameTransport?
    private let input: InputStream
    private let output: OutputStream
    private var channel: CBL2CAPChannel?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let observe: (@Sendable (BluetoothControlFrameTransport.NativeEvent) -> Void)?
    private var reader: Read?
    private var writer: Write?
    private var scheduled = false
    private var closed = false
    private var inputEnded = false
    private var inputFailure: Error?
    private static let chunkBytes = 2_048
    private static let pumpByteBudget = 32 * 1_024
    private static let pumpOperationBudget = 32

    init(input: InputStream, output: OutputStream, channel: CBL2CAPChannel?,
         now: @escaping @Sendable () -> ContinuousClock.Instant,
         observe: (@Sendable (BluetoothControlFrameTransport.NativeEvent) -> Void)?) {
        self.input = input; self.output = output; self.channel = channel; self.now = now; self.observe = observe
    }
    func open() throws {
        guard let delegate else { throw BluetoothControlStreamError.closed }
        for stream in [input as Stream, output as Stream] {
            stream.delegate = delegate
            stream.schedule(in: .current, forMode: .default)
            stream.open()
        }
        scheduled = true
        observe?(.openRequested)
    }
    func close() {
        guard !closed else { return }
        closed = true
        reader = nil; writer = nil
        for stream in [input as Stream, output as Stream] {
            stream.close()
            if scheduled { stream.remove(from: .current, forMode: .default) }
            stream.delegate = nil
        }
        delegate = nil; channel = nil
        observe?(.closed(inputStatus: input.streamStatus.rawValue, outputStatus: output.streamStatus.rawValue))
    }
    func tick(_ work: BluetoothStreamWork, mailbox: BluetoothStreamMailbox) -> Result {
        var result = Result()
        do {
            if let read = work.read {
                guard reader == nil else { throw BluetoothControlStreamError.readInProgress }
                reader = Read(read)
            }
            if let write = work.write {
                guard writer == nil else { throw BluetoothControlStreamError.writeInProgress }
                writer = Write(write)
            }
            let inputEvents = Stream.Event(rawValue: work.inputEvents)
            let outputEvents = Stream.Event(rawValue: work.outputEvents)
            if inputEvents.contains(.endEncountered) { inputEnded = true }
            if inputEvents.contains(.errorOccurred) { inputFailure = input.streamError ?? BluetoothControlStreamError.nativeReadFailed }
            let read = try pumpRead(mailbox: mailbox)
            result.read = read.value
            if outputEvents.contains(.errorOccurred) { throw output.streamError ?? BluetoothControlStreamError.nativeWriteFailed }
            if outputEvents.contains(.endEncountered) { throw BluetoothControlStreamError.unexpectedEnd }
            let write = try pumpWrite(mailbox: mailbox)
            result.write = write.value
            if read.more || write.more { result.waitSeconds = 0 }
            else {
                let deadlines = [reader?.request.operation.deadline, writer?.request.operation.deadline].compactMap { $0 }
                if let deadline = deadlines.min() {
                    let parts = now().duration(to: deadline).components
                    result.waitSeconds = max(0, min(300, Double(parts.seconds) + Double(parts.attoseconds) / 1e18))
                }
            }
        } catch { result.failure = error }
        return result
    }
    private func check<T: Sendable>(_ operation: BluetoothStreamOperation<T>, mailbox: BluetoothStreamMailbox) throws {
        try mailbox.requireCurrent(operation.id)
        try operation.check(at: now())
    }
    private func pumpRead(mailbox: BluetoothStreamMailbox) throws -> (value: (BluetoothStreamRead, Data)?, more: Bool) {
        var bytes = 0, operations = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
        while let pending = reader {
            try check(pending.request.operation, mailbox: mailbox)
            if pending.bodyCount == pending.body.count {
                reader = nil
                return ((pending.request, pending.body), false)
            }
            guard input.hasBytesAvailable else {
                if let error = inputFailure ?? input.streamError { throw error }
                if input.streamStatus == .error { throw BluetoothControlStreamError.nativeReadFailed }
                if inputEnded || input.streamStatus == .atEnd || input.streamStatus == .closed { throw BluetoothControlStreamError.unexpectedEnd }
                return (nil, false)
            }
            guard bytes < Self.pumpByteBudget, operations < Self.pumpOperationBudget else { return (nil, true) }
            let count = input.read(&buffer, maxLength: min(buffer.count, pending.remaining))
            if count > 0 { observe?(.read(count)) }
            try check(pending.request.operation, mailbox: mailbox)
            guard count >= 0 else { throw input.streamError ?? BluetoothControlStreamError.nativeReadFailed }
            guard count > 0 else { throw BluetoothControlStreamError.unexpectedEnd }
            bytes += count; operations += 1
            if pending.bodyCount == nil {
                pending.prefix.append(contentsOf: buffer.prefix(count))
                if pending.prefix.count == 4 {
                    let length = pending.prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let checked = try P2PControlFramePolicy.inboundBodyByteCount(from: length)
                    guard checked <= pending.request.maximumBytes else {
                        throw BluetoothControlStreamError.frameTooLarge(actual: checked, maximum: pending.request.maximumBytes)
                    }
                    pending.bodyCount = checked
                    pending.body.reserveCapacity(min(checked, Self.chunkBytes))
                }
            } else { pending.body.append(contentsOf: buffer.prefix(count)) }
        }
        return (nil, false)
    }
    private func pumpWrite(mailbox: BluetoothStreamMailbox) throws -> (value: BluetoothStreamWrite?, more: Bool) {
        var bytes = 0, operations = 0
        while let pending = writer {
            try check(pending.request.operation, mailbox: mailbox)
            if pending.offset == pending.request.bytes.count {
                writer = nil
                return (pending.request, false)
            }
            guard output.hasSpaceAvailable else {
                if let error = output.streamError { throw error }
                if output.streamStatus == .error { throw BluetoothControlStreamError.nativeWriteFailed }
                if output.streamStatus == .atEnd || output.streamStatus == .closed { throw BluetoothControlStreamError.unexpectedEnd }
                return (nil, false)
            }
            guard bytes < Self.pumpByteBudget, operations < Self.pumpOperationBudget else { return (nil, true) }
            try pending.request.effect?()
            try check(pending.request.operation, mailbox: mailbox)
            let remaining = min(Self.chunkBytes, pending.request.bytes.count - pending.offset)
            let count = pending.request.bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base.advanced(by: pending.offset), maxLength: remaining)
            }
            if count > 0 { observe?(.wrote(count)) }
            try check(pending.request.operation, mailbox: mailbox)
            guard count >= 0 else { throw output.streamError ?? BluetoothControlStreamError.nativeWriteFailed }
            guard count > 0 else { return (nil, false) }
            pending.offset += count; bytes += count; operations += 1
        }
        return (nil, false)
    }
}
