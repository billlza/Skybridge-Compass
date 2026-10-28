import Foundation
import Combine

/// Native completion is a receipt, not cancellation of an awaiting Swift task.
/// A backend must report stop only after its callback queue has been drained.
@MainActor
protocol IOSAudioCaptureBackend: AnyObject {
    var ingress: IOSAudioCaptureIngress { get }
    var didStop: (@MainActor (any Error) -> Void)? { get set }
    func prepare(completion: @escaping @MainActor (Result<Void, Error>) -> Void)
    func start(completion: @escaping @MainActor (Result<Void, Error>) -> Void)
    func stop(completion: @escaping @MainActor (Result<Void, Error>) -> Void)
    func close() throws
}

/// Retained by the product owner until native cleanup is confirmed. A timeout
/// releases the caller, never the pending selection/start/stop operation.
@MainActor
final class IOSAudioCaptureSource: ObservableObject {
    enum Phase: Equatable { case idle, selecting, prepared, starting, running, stopping, cleanupRequired, closed }
    struct Options {
        var selectionTimeout: Duration = .seconds(120)
        var startTimeout: Duration = .seconds(5)
        var stopTimeout: Duration = .seconds(5)
        func validate() throws {
            guard [selectionTimeout, startTimeout, stopTimeout].allSatisfy({ $0 > .zero && $0 <= .seconds(120) }) else {
                throw IOSAudioCaptureError.invalidLimits
            }
        }
    }
    private enum Operation: Hashable { case prepare, start, stop }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        var timer: Task<Void, Never>?
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var failure: (any Error)?
    @Published private(set) var cleanupPending = false
    let ingress: IOSAudioCaptureIngress
    private let backend: any IOSAudioCaptureBackend
    private let options: Options
    private var pending: (operation: Operation, id: UUID)?
    private var waiters: [Operation: Waiter] = [:]
    private var stopRequested = false
    private var startAttempted = false
    private var stopConfirmed = false
    private var nativeStopDeadline: Task<Void, Never>?
    private var senderOwner: UUID?

    init(backend: any IOSAudioCaptureBackend, options: Options = Options()) throws {
        try options.validate()
        self.backend = backend; self.options = options; ingress = backend.ingress
        try ingress.installFailureHandler { [weak self] error in
            Task { @MainActor in self?.captureFailed(error) }
        }
        backend.didStop = { [weak self] error in self?.nativeStopped(error) }
    }

    func requireUnclaimedForSending() throws {
        guard senderOwner == nil else { throw IOSAudioCaptureError.alreadyBound }
        guard phase == .idle || phase == .prepared else { throw IOSAudioCaptureError.invalidState }
    }

    func claimForSending(_ owner: UUID) throws {
        try requireUnclaimedForSending()
        senderOwner = owner
    }

    /// User selection has its own deadline. No capture Offer is sent here.
    func prepare() async throws {
        guard phase == .idle, !stopRequested else { throw IOSAudioCaptureError.alreadyStarted }
        try await wait(.prepare, timeout: options.selectionTimeout) {
            phase = .selecting; cleanupPending = true
            let id = UUID(); pending = (.prepare, id)
            backend.prepare { [weak self] result in self?.completed(.prepare, id: id, result: result) }
        }
    }

    /// Starts local format preparation after account and system authorization.
    /// The ingress's separate admission boundary gates transmitted audio after
    /// receiver approval. This source never grants account/playback authority.
    func start() async throws {
        guard phase == .prepared, !stopRequested, failure == nil else { throw IOSAudioCaptureError.invalidState }
        try await wait(.start, timeout: options.startTimeout) {
            phase = .starting; startAttempted = true
            let id = UUID(); pending = (.start, id)
            backend.start { [weak self] result in self?.completed(.start, id: id, result: result) }
        }
    }

    /// Normal end of a running source preserves the queue for exact draining.
    func stop() async throws {
        if phase == .closed { return }
        guard phase != .cleanupRequired else { throw IOSAudioCaptureError.cleanupPending }
        try await wait(.stop, timeout: options.stopTimeout) {
            if phase == .selecting || phase == .starting { record(IOSAudioCaptureError.cancelled) }
            stopRequested = true
            finish(.prepare, .failure(failure ?? IOSAudioCaptureError.cancelled))
            finish(.start, .failure(failure ?? IOSAudioCaptureError.cancelled))
            advanceStop()
        }
    }

    func cancel(_ error: any Error = IOSAudioCaptureError.cancelled) {
        guard phase != .closed else { return }
        captureFailed(error)
    }

    /// Never resubmits an operation whose native completion is still pending.
    func retryCleanup() async throws {
        guard phase == .cleanupRequired, pending == nil else { throw IOSAudioCaptureError.cleanupPending }
        try await wait(.stop, timeout: options.stopTimeout) { advanceStop() }
    }

    private func wait(_ operation: Operation, timeout: Duration, begin: () -> Void) async throws {
        try await withTaskCancellationHandler {
            if Task.isCancelled { cancel(); throw IOSAudioCaptureError.cancelled }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard waiters[operation] == nil else { continuation.resume(throwing: IOSAudioCaptureError.busy); return }
                let id = UUID()
                waiters[operation] = Waiter(id: id, continuation: continuation)
                begin()
                if waiters[operation]?.id == id {
                    waiters[operation]?.timer = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) }
                        catch is CancellationError { return }
                        catch { self?.captureFailed(error); return }
                        self?.expired(operation, id: id)
                    }
                }
            }
            if Task.isCancelled { cancel(); throw IOSAudioCaptureError.cancelled }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func finish(_ operation: Operation, _ result: Result<Void, Error>) {
        guard let waiter = waiters.removeValue(forKey: operation) else { return }
        waiter.timer?.cancel(); waiter.continuation.resume(with: result)
    }

    private func expired(_ operation: Operation, id: UUID) {
        guard waiters[operation]?.id == id else { return }
        finish(operation, .failure(IOSAudioCaptureError.timedOut))
        record(IOSAudioCaptureError.timedOut); stopRequested = true
        finish(.prepare, .failure(IOSAudioCaptureError.timedOut))
        finish(.start, .failure(IOSAudioCaptureError.timedOut))
        phase = .cleanupRequired; cleanupPending = true
        // A still-pending native callback retains the owner. If no native call is
        // pending, cleanup may proceed, but it cannot replay a failed native stop.
        if pending == nil, !startAttempted { advanceStop() }
    }

    private func record(_ error: any Error) {
        if failure == nil { failure = error }
        ingress.abort(error)
    }

    private func captureFailed(_ error: any Error) {
        guard phase != .closed else { return }
        record(error); stopRequested = true
        finish(.prepare, .failure(failure ?? error)); finish(.start, .failure(failure ?? error))
        // A cleanup failure is retained for an explicit retry, never retried by
        // a delayed notification from the ingress failure handler.
        if phase != .cleanupRequired { advanceStop() }
    }

    private func completed(_ operation: Operation, id: UUID, result: Result<Void, Error>) {
        guard pending?.operation == operation, pending?.id == id else { return }
        pending = nil
        switch operation {
        case .prepare, .start:
            if case .failure(let error) = result { record(error); stopRequested = true }
            if stopRequested {
                finish(operation, .failure(failure ?? IOSAudioCaptureError.cancelled))
                advanceStop()
            } else {
                phase = operation == .prepare ? .prepared : .running
                finish(operation, .success(()))
            }
        case .stop:
            nativeStopDeadline?.cancel(); nativeStopDeadline = nil
            switch result {
            case .success:
                stopConfirmed = true; ingress.seal(); advanceStop()
            case .failure(let error):
                record(error); phase = .cleanupRequired; cleanupPending = true
                finish(.stop, .failure(error))
            }
        }
    }

    private func nativeStopped(_ error: any Error) {
        guard phase != .closed else { return }
        record(error); stopRequested = true
        finish(.prepare, .failure(error)); finish(.start, .failure(error))
        // A delegate receipt while start/stop is in flight cannot retire that
        // operation. Once its completion arrives it is handled on this owner.
        if pending == nil { stopConfirmed = true; advanceStop() }
    }

    private func advanceStop() {
        guard stopRequested, phase != .closed else { return }
        phase = .stopping; cleanupPending = true
        guard pending == nil else { return }
        if startAttempted, !stopConfirmed {
            let id = UUID(); pending = (.stop, id)
            backend.stop { [weak self] result in self?.completed(.stop, id: id, result: result) }
            if pending?.id == id {
                nativeStopDeadline = Task { [weak self, options] in
                    do { try await Task.sleep(for: options.stopTimeout) }
                    catch is CancellationError { return }
                    catch { self?.captureFailed(error); return }
                    guard let self, self.pending?.id == id else { return }
                    self.record(IOSAudioCaptureError.timedOut)
                    self.phase = .cleanupRequired
                    self.finish(.stop, .failure(IOSAudioCaptureError.timedOut))
                }
            }
            return
        }
        do {
            try backend.close()
            ingress.retireOwner(); ingress.seal(); phase = .closed; cleanupPending = false
            finish(.stop, .success(()))
        } catch {
            record(error); phase = .cleanupRequired
            finish(.stop, .failure(error))
        }
    }
}

/// Device support/restrictions and platform availability are distinct from the
/// user's selection and consent for a particular capture.
enum IOSSystemAudioCaptureAvailability: String, Equatable, Sendable {
    case requiresNewerSystem, systemUnavailable, available
}

/// App-owned retention also covers a caller which times out and drops its task.
@MainActor
final class IOSAudioCaptureSourceOwner {
    private(set) var current: IOSAudioCaptureSource?
    private let readScreenCaptureAvailability: @MainActor () -> IOSSystemAudioCaptureAvailability

    init(screenCaptureAvailability: @escaping @MainActor () -> IOSSystemAudioCaptureAvailability = {
        IOSAudioCaptureSourceOwner.systemScreenCaptureAvailability
    }) {
        readScreenCaptureAvailability = screenCaptureAvailability
    }

    /// A fresh presentation/preflight snapshot, never capture permission.
    var screenCaptureAvailability: IOSSystemAudioCaptureAvailability { readScreenCaptureAvailability() }

    func make(backend: any IOSAudioCaptureBackend,
              options: IOSAudioCaptureSource.Options = .init()) throws -> IOSAudioCaptureSource {
        guard current == nil || current?.phase == .closed else { throw IOSAudioCaptureError.busy }
        let source = try IOSAudioCaptureSource(backend: backend, options: options)
        current = source
        return source
    }
}
