#if os(macOS)
import CSkyBridgeUSBHost
import Foundation
import os

public struct USBHostFailure: Error, Equatable, Sendable {
    public let status: UInt32
    public let phase: UInt32
    public let domain: UInt32
    public let nativeCode: Int32
    public let bytesTransferred: UInt32
    public let byteCountKnown: Bool
    init(_ result: SBUSBResult) {
        status = result.status.rawValue; phase = result.phase.rawValue; domain = result.domain.rawValue
        nativeCode = result.nativeCode; bytesTransferred = result.bytesTransferred; byteCountKnown = result.byteCountKnown
    }
}

public struct USBHostDevice: Equatable, Sendable {
    public let deviceRegistryID: UInt64
    public let interfaceRegistryID: UInt64
    public let inputPacketSize: UInt16
    public let outputPacketSize: UInt16
    public let inputEndpoint: UInt8
    public let outputEndpoint: UInt8
}

public enum USBHostByteError: Error, Equatable, Sendable {
    case closed, alreadyStarted, notReady, readInProgress, writeInProgress
    case invalidRegistryEntry, invalidTimeout, invalidByteCount, timedOut, cleanupUnconfirmed
}

/// Cleanup facts are independent. A native close error can coexist with confirmed release;
/// an application owner must retain unresolved cleanup instead of treating all errors alike.
public struct USBHostShutdownState: Sendable {
    public let retired: Bool
    public let workersExited: Bool
    public let referencesReleased: Bool
    public let cleanupFailure: (any Error)?
}

struct USBHostCleanup: Sendable {
    let referencesReleased: Bool
    let failure: (any Error)?
}

/// Internal native boundary. The owner supplies one reader (also used for acquisition), one
/// writer, and an interrupt/cleanup supervisor. Cleanup runs only after both workers EXIT.
protocol USBHostDriver: Sendable {
    func open(registryID: UInt64) throws -> USBHostDevice
    func read(timeoutMilliseconds: UInt32) throws -> Data
    func write(_ bytes: Data, timeoutMilliseconds: UInt32) throws
    /// Bounded in-memory admission change only; must never call native I/O or callbacks.
    func retire()
    func interrupt() -> (any Error)?
    func closeAndRelease() -> USBHostCleanup
}

/// A raw AOA byte carrier, not a product session or an audio eligibility decision. Registry
/// IDs select the current physical attachment; the caller must still authenticate the peer.
/// Ordinary IOUSBLib opening never seizes an interface or disables another driver's ownership.
public final class USBHostByteTransport: Sendable {
    public static let transferBytes = 16_384
    private let worker: USBHostWorker
    private let reader = USBHostThread()
    private let writer = USBHostThread()
    private let supervisor = USBHostThread()

    /// Capture a bounded, thread-safe attachment-generation check, not a mutable selection.
    public convenience init(deviceRegistryID: UInt64,
                            requireAttachmentCurrent: @escaping @Sendable () throws -> Void) throws {
        guard deviceRegistryID != 0 else { throw USBHostByteError.invalidRegistryEntry }
        self.init(deviceRegistryID: deviceRegistryID, driver: try USBHostNativeDriver(),
                  requireAttachmentCurrent: requireAttachmentCurrent)
    }

    init(deviceRegistryID: UInt64, driver: any USBHostDriver,
         requireAttachmentCurrent: @escaping @Sendable () throws -> Void) {
        worker = USBHostWorker(registryID: deviceRegistryID, driver: driver, attachment: requireAttachmentCurrent)
        let worker = worker, reader = reader, writer = writer
        reader.start(name: "SkyBridge USB reader") { worker.runReader() }
        writer.start(name: "SkyBridge USB writer") { worker.runWriter() }
        supervisor.start(name: "SkyBridge USB cleanup") {
            worker.runSupervisor(readFinished: { reader.isFinished }, writeFinished: { writer.isFinished })
        }
    }

    deinit { worker.retire(USBHostByteError.closed) }
    public var terminalFailure: (any Error)? { worker.failure }
    public var shutdownState: USBHostShutdownState {
        let receipt = worker.cleanup
        return USBHostShutdownState(retired: worker.failure != nil,
            workersExited: reader.isFinished && writer.isFinished && supervisor.isFinished,
            referencesReleased: receipt?.referencesReleased == true, cleanupFailure: receipt?.failure)
    }

    public func open(timeout: Duration) async throws -> USBHostDevice {
        defer { withExtendedLifetime(self) {} }
        let operation = try USBHostOperation<USBHostDevice>(timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                do { try Task.checkCancellation(); try worker.enqueueOpen(operation) }
                catch { operation.finish(.failure(error)) }
            }
        } onCancel: { [worker] in worker.retire(CancellationError()) }
    }

    /// Returns 1...maximumBytes; native packet tails are retained for the next request. USB
    /// zero-length packets do not mean EOF and do not renew this request's whole deadline.
    public func readBytes(maximumBytes: Int, timeout: Duration) async throws -> Data {
        defer { withExtendedLifetime(self) {} }
        guard (1...Self.transferBytes).contains(maximumBytes) else { throw USBHostByteError.invalidByteCount }
        let operation = try USBHostOperation<Data>(timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                do { try Task.checkCancellation(); try worker.enqueueRead(operation, count: maximumBytes) }
                catch { operation.finish(.failure(error)) }
            }
        } onCancel: { [worker] in worker.retire(CancellationError()) }
    }

    /// One bounded write. Authorization is checked before the actual native call and after
    /// completion. Cancellation/failure never retries a possibly partially emitted write.
    public func writeBytes(_ bytes: Data, timeout: Duration,
                           requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        try await write(bytes, timeout: timeout, effect: requireEffectAuthorization, completion: nil)
    }

    /// Internal pump ownership: an error may retire admission immediately, but
    /// this call does not return until the request's native execution actually
    /// ends (or is known never to have started). Cancellation still retires the
    /// carrier. Parent cleanup has a bounded observer and retains unresolved I/O;
    /// this owned continuation is not polling or claiming a universal native bound.
    func writeBytesAndAwaitNativeCompletion(_ bytes: Data, timeout: Duration,
                                           requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        let completion = USBHostWriteCompletion()
        let result: Result<Void, any Error>
        do { try await write(bytes, timeout: timeout, effect: requireEffectAuthorization, completion: completion); result = .success(()) }
        catch { result = .failure(error) }
        await completion.wait()
        try result.get()
    }

    private func write(_ bytes: Data, timeout: Duration, effect: @escaping @Sendable () throws -> Void,
                       completion: USBHostWriteCompletion?) async throws {
        defer { withExtendedLifetime(self) {} }
        let operation: USBHostOperation<Void>
        do {
            guard (1...Self.transferBytes).contains(bytes.count) else { throw USBHostByteError.invalidByteCount }
            operation = try USBHostOperation<Void>(timeout: timeout)
        } catch { completion?.finish(); throw error }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                do {
                    try Task.checkCancellation()
                    try worker.enqueueWrite(operation, bytes: Data(bytes), effect: effect, completion: completion)
                } catch { completion?.finish(); operation.finish(.failure(error)) }
            }
        } onCancel: { [worker] in worker.retire(CancellationError()) }
    }

    /// Non-blocking logical retirement. Native abort/close runs on the owned supervisor.
    public func close() { worker.retire(USBHostByteError.closed) }

    /// A bounded observer, independent of caller cancellation. It never abandons the native
    /// owner or equates a flag set before a worker returns with actual Thread.isFinished.
    public func closeAndAwait(timeout: Duration = .seconds(2)) async throws {
        defer { withExtendedLifetime(self) {} }
        try USBHostOperation<Void>.validate(timeout)
        close()
        let worker = worker, reader = reader, writer = writer, supervisor = supervisor
        let observer = Task.detached {
            let end = ContinuousClock.now.advanced(by: timeout)
            while true {
                if reader.isFinished && writer.isFinished && supervisor.isFinished {
                    guard let cleanup = worker.cleanup, cleanup.referencesReleased else { throw USBHostByteError.cleanupUnconfirmed }
                    if let failure = cleanup.failure { throw failure }
                    return
                }
                guard ContinuousClock.now < end else { throw USBHostByteError.cleanupUnconfirmed }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await observer.value
    }
}

/// Exactly one owned waiter, independent from the operation's early error result.
/// finish is idempotent because a failed request is also observed at worker exit.
private final class USBHostWriteCompletion: Sendable {
    private struct State: Sendable {
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func finish() {
        let continuation = state.withLock { value -> CheckedContinuation<Void, Never>? in
            guard !value.finished else { return nil }
            value.finished = true; let result = value.continuation; value.continuation = nil; return result
        }
        continuation?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { value in
                if value.finished { return true }
                precondition(value.continuation == nil, "One pump owns native write completion")
                value.continuation = continuation; return false
            }
            if immediate { continuation.resume() }
        }
    }
}

/// Non-Sendable Foundation handles remain private. Only start and the documented finished
/// getter are used under this lock. Worker bodies do not retain their own lifetime handle.
final class USBHostThread: Sendable {
    private let storage = OSAllocatedUnfairLock<Thread?>(uncheckedState: nil)
    func start(name: String, body: @escaping @Sendable () -> Void) {
        storage.withLock { value in
            precondition(value == nil, "A native USB worker starts once")
            let thread = Thread(block: body); thread.name = name; thread.qualityOfService = .userInitiated
            value = thread; thread.start()
        }
    }
    var isFinished: Bool { storage.withLock { $0?.isFinished == true } }
}

private final class USBHostOperation<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
    }
    let deadline: ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(timeout: Duration) throws {
        try Self.validate(timeout); deadline = ContinuousClock.now.advanced(by: timeout)
    }
    static func validate(_ timeout: Duration) throws {
        guard timeout > .zero && timeout <= .seconds(60) else { throw USBHostByteError.invalidTimeout }
    }
    func remainingMilliseconds() throws -> UInt32 {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw USBHostByteError.timedOut }
        let parts = duration.components
        let milliseconds = parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return UInt32(min(60_000, max(1, milliseconds)))
    }
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = state.withLock { value -> Result<Value, any Error>? in
            if let result = value.result { return result }
            precondition(value.continuation == nil); value.continuation = continuation; return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { value -> CheckedContinuation<Value, any Error>? in
            guard value.result == nil else { return nil }
            value.result = result; let continuation = value.continuation; value.continuation = nil; return continuation
        }
        continuation?.resume(with: result)
    }
}

private enum USBHostReadRequest: Sendable {
    case open(USBHostOperation<USBHostDevice>)
    case bytes(USBHostOperation<Data>, Int)
    var deadline: ContinuousClock.Instant {
        switch self { case .open(let op): op.deadline; case .bytes(let op, _): op.deadline }
    }
    func fail(_ error: any Error) {
        switch self { case .open(let op): op.finish(.failure(error)); case .bytes(let op, _): op.finish(.failure(error)) }
    }
}
private struct USBHostWriteRequest: Sendable {
    let operation: USBHostOperation<Void>
    let bytes: Data
    let effect: @Sendable () throws -> Void
    let completion: USBHostWriteCompletion?
}

private final class USBHostWorker: Sendable {
    private struct State: Sendable {
        var openStarted = false, ready = false
        var read: USBHostReadRequest?
        var write: USBHostWriteRequest?
        var failure: (any Error)?
        var cleanup: USBHostCleanup?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readWake = DispatchSemaphore(value: 0), writeWake = DispatchSemaphore(value: 0), supervisorWake = DispatchSemaphore(value: 0)
    private let registryID: UInt64
    private let driver: any USBHostDriver
    private let attachment: @Sendable () throws -> Void
    init(registryID: UInt64, driver: any USBHostDriver, attachment: @escaping @Sendable () throws -> Void) {
        self.registryID = registryID; self.driver = driver; self.attachment = attachment
    }
    var failure: (any Error)? { state.withLock { $0.failure } }
    var cleanup: USBHostCleanup? { state.withLock { $0.cleanup } }
    func enqueueOpen(_ operation: USBHostOperation<USBHostDevice>) throws {
        try state.withLock { value in
            if let error = value.failure { throw error }
            guard !value.openStarted else { throw USBHostByteError.alreadyStarted }
            value.openStarted = true; value.read = .open(operation)
        }
        readWake.signal(); supervisorWake.signal()
    }
    func enqueueRead(_ operation: USBHostOperation<Data>, count: Int) throws {
        try state.withLock { value in
            if let error = value.failure { throw error }
            guard value.ready else { throw USBHostByteError.notReady }
            guard value.read == nil else { throw USBHostByteError.readInProgress }
            value.read = .bytes(operation, count)
        }
        readWake.signal(); supervisorWake.signal()
    }
    func enqueueWrite(_ operation: USBHostOperation<Void>, bytes: Data, effect: @escaping @Sendable () throws -> Void,
                      completion: USBHostWriteCompletion?) throws {
        try state.withLock { value in
            if let error = value.failure { throw error }
            guard value.ready else { throw USBHostByteError.notReady }
            guard value.write == nil else { throw USBHostByteError.writeInProgress }
            value.write = USBHostWriteRequest(operation: operation, bytes: bytes, effect: effect, completion: completion)
        }
        writeWake.signal(); supervisorWake.signal()
    }
    func retire(_ error: any Error) {
        retire(error, onlyIfExpired: false)
    }
    private func retire(_ error: any Error, onlyIfExpired: Bool) {
        let pending = state.withLock { value -> (USBHostReadRequest?, USBHostWriteRequest?)? in
            guard value.failure == nil else { return nil }
            if onlyIfExpired {
                let now = ContinuousClock.now
                guard value.read.map({ now >= $0.deadline }) == true ||
                    value.write.map({ now >= $0.operation.deadline }) == true else { return nil }
            }
            // Publish failure only after native admission is closed. Otherwise the supervisor
            // could enter a blocking close while the first retirement still needs that handle.
            driver.retire()
            value.failure = error; value.ready = false; return (value.read, value.write)
        }
        guard let pending else { return }
        pending.0?.fail(error); pending.1?.operation.finish(.failure(error))
        readWake.signal(); writeWake.signal(); supervisorWake.signal()
    }
    private func checkCurrent() throws {
        if let failure { throw failure }
        try attachment()
        if let failure { throw failure }
    }
    func runReader() {
        var buffered = Data(), offset = 0
        while failure == nil {
            readWake.wait()
            if failure != nil { break }
            guard let request = state.withLock({ $0.read }) else { continue }
            do {
                try checkCurrent()
                switch request {
                case .open(let op):
                    _ = try op.remainingMilliseconds()
                    let device = try driver.open(registryID: registryID)
                    try checkCurrent(); _ = try op.remainingMilliseconds()
                    try state.withLock { value in
                        if let error = value.failure { throw error }; value.ready = true; value.read = nil
                    }
                    supervisorWake.signal()
                    op.finish(.success(device))
                case .bytes(let op, let maximum):
                    while offset == buffered.count {
                        try checkCurrent()
                        let data = try driver.read(timeoutMilliseconds: op.remainingMilliseconds())
                        try checkCurrent(); _ = try op.remainingMilliseconds()
                        guard data.count <= USBHostByteTransport.transferBytes else { throw USBHostByteError.invalidByteCount }
                        buffered = Data(data); offset = 0
                        if data.isEmpty { Thread.sleep(forTimeInterval: 0.001) }
                    }
                    try checkCurrent(); _ = try op.remainingMilliseconds()
                    let end = min(buffered.count, offset + maximum)
                    let result = buffered.subdata(in: offset..<end)
                    offset = end
                    try state.withLock { value in
                        if let error = value.failure { throw error }; value.read = nil
                    }
                    supervisorWake.signal()
                    op.finish(.success(result))
                }
            } catch { retire(error); request.fail(failure ?? error); break }
        }
    }
    func runWriter() {
        // A request canceled while still queued is never entered by the worker.
        // At exit no native writer can subsequently start it.
        defer { state.withLock { $0.write?.completion }?.finish() }
        while failure == nil {
            writeWake.wait()
            if failure != nil { break }
            guard let request = state.withLock({ $0.write }) else { continue }
            do {
                try checkCurrent(); try request.effect(); try checkCurrent()
                try driver.write(request.bytes, timeoutMilliseconds: request.operation.remainingMilliseconds())
                try checkCurrent(); try request.effect(); _ = try request.operation.remainingMilliseconds()
                try state.withLock { value in
                    if let error = value.failure { throw error }; value.write = nil
                }
                supervisorWake.signal()
                request.completion?.finish()
                request.operation.finish(.success(()))
            } catch {
                retire(error)
                request.completion?.finish()
                request.operation.finish(.failure(failure ?? error)); break
            }
        }
    }
    func runSupervisor(readFinished: @Sendable () -> Bool, writeFinished: @Sendable () -> Bool) {
        while failure == nil {
            let deadline = state.withLock { value -> ContinuousClock.Instant? in
                [value.read?.deadline, value.write?.operation.deadline].compactMap { $0 }.min()
            }
            guard let deadline else { supervisorWake.wait(); continue }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero {
                // Recheck and retire in the SAME critical section as completion/admission:
                // a stale deadline snapshot must not kill a later request.
                retire(USBHostByteError.timedOut, onlyIfExpired: true)
            } else {
                let parts = remaining.components
                let nanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
                _ = supervisorWake.wait(timeout: .now() + .nanoseconds(Int(max(1, nanoseconds))))
            }
        }
        let interruptFailure = driver.interrupt()
        while !readFinished() || !writeFinished() {
            _ = supervisorWake.wait(timeout: .now() + .milliseconds(2))
        }
        let receipt = driver.closeAndRelease()
        state.withLock { value in
            value.read = nil; value.write = nil
            value.cleanup = USBHostCleanup(referencesReleased: receipt.referencesReleased, failure: receipt.failure ?? interruptFailure)
        }
    }
}

/// The C pointer is private and never escapes this boundary. Read/write borrow it only on the
/// owned workers. Destruction occurs after their actual exit, under the same lock as snapshots.
private final class USBHostNativeDriver: USBHostDriver {
    private let pointer: OSAllocatedUnfairLock<OpaquePointer?>
    init() throws {
        var result = SBUSBResult()
        let handle = SBUSBCreate(&result)
        guard let handle, result.status == SB_USB_OK else { throw USBHostFailure(result) }
        pointer = OSAllocatedUnfairLock(uncheckedState: handle)
    }
    private func borrowed() throws -> OpaquePointer {
        // This private borrow is confined to the three owned workers. C admits concurrent
        // read/write/abort, and the supervisor joins readers/writers before destruction.
        // Keeping the lock across native I/O would prevent abort and the opposite direction.
        guard let handle = pointer.withLockUnchecked({ $0 }) else { throw USBHostByteError.closed }; return handle
    }
    func open(registryID: UInt64) throws -> USBHostDevice {
        let handle = try borrowed(), result = SBUSBOpen(handle, registryID)
        guard result.status == SB_USB_OK else { throw USBHostFailure(result) }
        let d = SBUSBGetSnapshot(handle).device
        return USBHostDevice(deviceRegistryID: d.deviceRegistryID, interfaceRegistryID: d.interfaceRegistryID,
                             inputPacketSize: d.inputPacketSize, outputPacketSize: d.outputPacketSize,
                             inputEndpoint: d.inputEndpoint, outputEndpoint: d.outputEndpoint)
    }
    func read(timeoutMilliseconds: UInt32) throws -> Data {
        let handle = try borrowed()
        var bytes = [UInt8](repeating: 0, count: USBHostByteTransport.transferBytes)
        let result = SBUSBRead(handle, &bytes, UInt32(bytes.count), timeoutMilliseconds)
        guard result.status == SB_USB_OK else { throw USBHostFailure(result) }
        return Data(bytes.prefix(Int(result.bytesTransferred)))
    }
    func write(_ bytes: Data, timeoutMilliseconds: UInt32) throws {
        let handle = try borrowed()
        let result = bytes.withUnsafeBytes { SBUSBWrite(handle, $0.baseAddress, UInt32($0.count), timeoutMilliseconds) }
        guard result.status == SB_USB_OK else { throw USBHostFailure(result) }
    }
    func interrupt() -> (any Error)? {
        do {
            let result = SBUSBInterrupt(try borrowed())
            return result.status == SB_USB_OK ? nil : USBHostFailure(result)
        } catch { return error }
    }
    func retire() {
        // This entry can run on any caller; keeping the pointer lock until the bounded C
        // retirement returns prevents a race with a supervisor destroying the handle.
        pointer.withLock { handle in if let handle { _ = SBUSBRetire(handle) } }
    }
    func closeAndRelease() -> USBHostCleanup {
        pointer.withLock { handle in
            guard let current = handle else { return USBHostCleanup(referencesReleased: true, failure: USBHostByteError.closed) }
            let close = SBUSBTryClose(current)
            guard SBUSBGetSnapshot(current).ownedReferencesReleased else {
                return USBHostCleanup(referencesReleased: false, failure: USBHostFailure(close))
            }
            let destruction = SBUSBDestroy(&handle)
            return USBHostCleanup(referencesReleased: handle == nil, failure: destruction.status == SB_USB_OK ? nil : USBHostFailure(destruction))
        }
    }
}
#endif
