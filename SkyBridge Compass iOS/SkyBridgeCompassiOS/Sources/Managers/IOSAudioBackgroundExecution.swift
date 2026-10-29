import Foundation
import Combine

enum IOSAudioBackgroundState: Equatable {
    case foregroundOnly, requesting, active, stopping, finished, failed
}

enum IOSAudioBackgroundError: Error, Equatable {
    case alreadyStarted, invalidIdentifier, registrationRejected, unexpectedTask, launchTimedOut
    case cancelled, expired, invalidProgress, incompleteWork
}

enum IOSAudioTaskStatus: Equatable, Sendable {
    case originalFile(IOSOriginalFileSendSession.Phase)
    case bluetoothFile(IOSOpusFileSendSession.Phase)

    var isCompleted: Bool {
        switch self {
        case .originalFile(.completed), .bluetoothFile(.completed): return true
        default: return false
        }
    }
}

@MainActor
protocol IOSContinuedAudioTask: AnyObject {
    var identifier: String { get }
    var isExpired: Bool { get }
    func updateProgress(_ progress: Progress)
    func updateStatus(_ status: IOSAudioTaskStatus)
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    @discardableResult func complete(success: Bool) -> Bool
}

@MainActor
protocol IOSContinuedAudioScheduler: AnyObject {
    func submit(identifier: String, title: String,
                launch: @escaping @MainActor (Result<any IOSContinuedAudioTask, any Error>) -> Void) async throws
    func cancel(identifier: String)
}

/// Three measured work components plus final receipt/cleanup. Original files use
/// hash bytes, transfer bytes and output frames; Bluetooth files use completed
/// preparation, confirmed packet writes and receiver-retired packet contributions.
/// Neither representation is a clock or an audible-position estimate.
@MainActor
final class IOSAudioTaskProgress {
    // Native continued tasks need advancing completed units, not only a child
    // Progress fraction. Preserve the four equal measured-work components with
    // integer resolution; the final quarter still requires receipt and cleanup.
    private static let unitsPerComponent: UInt64 = 1_000_000
    let value = Progress(totalUnitCount: 4_000_000)
    private var counts: [(completed: Int64, total: Int64)?] = [nil, nil, nil]
    private enum Kind: Equatable { case originalFile, bluetoothFile }
    private var kind: Kind?
    private(set) var status = IOSAudioTaskStatus.originalFile(.idle)

    func update(_ work: IOSOriginalFileSendSession.WorkProgress) throws {
        guard let frames = Int64(exactly: work.outputFrames) else { throw IOSAudioBackgroundError.invalidProgress }
        let totalFrames: Int64?
        if let total = work.sourceFrames {
            guard let exact = Int64(exactly: total) else { throw IOSAudioBackgroundError.invalidProgress }
            totalFrames = exact
        } else { totalFrames = nil }
        try update(kind: .originalFile, status: .originalFile(work.phase),
            preparation: (work.hashedBytes, work.hashTotal),
            transfer: (work.transferredBytes, work.fileBytes), receiver: (frames, totalFrames))
    }

    func update(_ work: IOSOpusFileSendSession.WorkProgress) throws {
        guard let sent = Int64(exactly: work.sentPackets), let retired = Int64(exactly: work.retiredPackets) else {
            throw IOSAudioBackgroundError.invalidProgress
        }
        let total: Int64?
        if let packets = work.totalPackets {
            guard packets > 0, let exact = Int64(exactly: packets) else { throw IOSAudioBackgroundError.invalidProgress }
            total = exact
        } else { total = nil }
        try update(kind: .bluetoothFile, status: .bluetoothFile(work.phase),
            preparation: (work.preparationCompleted ? 1 : 0, 1),
            transfer: (sent, total), receiver: (retired, total))
    }

    private func update(kind incomingKind: Kind, status: IOSAudioTaskStatus,
                        preparation: (Int64, Int64?), transfer: (Int64, Int64?),
                        receiver: (Int64, Int64?)) throws {
        guard kind == nil || kind == incomingKind else { throw IOSAudioBackgroundError.invalidProgress }
        // Validate all fields before publishing any of this observation.
        var next = counts
        func record(_ index: Int, _ completed: Int64, _ total: Int64?) throws {
            guard let total else {
                guard completed == 0, next[index] == nil else { throw IOSAudioBackgroundError.invalidProgress }
                return
            }
            guard total >= 0, completed >= 0, completed <= total,
                  next[index].map({ $0.total == total && completed >= $0.completed }) ?? true else {
                throw IOSAudioBackgroundError.invalidProgress
            }
            next[index] = (completed, total)
        }
        try record(0, preparation.0, preparation.1)
        try record(1, transfer.0, transfer.1)
        try record(2, receiver.0, receiver.1)
        counts = next; kind = incomingKind; self.status = status
        value.completedUnitCount = next.reduce(Int64(0)) { completed, count in
            // Known empty work is complete. Unknown extent remains at zero.
            guard let count else { return completed }
            guard count.total > 0 else { return completed + Int64(Self.unitsPerComponent) }
            // Full-width arithmetic floors the measured ratio without overflow
            // or rounding unfinished Int64.max-sized work up to completion.
            // Validation above bounds the quotient to unitsPerComponent.
            let product = UInt64(count.completed).multipliedFullWidth(by: Self.unitsPerComponent)
            let units = UInt64(count.total).dividingFullWidth(product).quotient
            return completed + Int64(units)
        }
    }

    func finishSuccessfully() throws {
        guard status.isCompleted, counts.allSatisfy({ $0.map { $0.completed == $0.total } ?? false }) else {
            throw IOSAudioBackgroundError.incompleteWork
        }
        value.completedUnitCount = value.totalUnitCount
    }
}

/// Owns one user-initiated request, its actual submission callback and its system
/// task. Cancellation can end playback promptly but cannot detach a late submit.
@MainActor
final class IOSAudioBackgroundExecution: ObservableObject {
    @Published private(set) var state: IOSAudioBackgroundState = .foregroundOnly
    private(set) var failure: (any Error)?
    private(set) var submissionFailure: (any Error)?
    let identifier: String
    let progress = IOSAudioTaskProgress()
    private let scheduler: any IOSContinuedAudioScheduler
    private let title: String
    private let launchDeadline: ContinuousClock.Instant
    private var started = false
    private var closed = false
    private var submitted = false
    private var systemTask: (any IOSContinuedAudioTask)?
    private var submission: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var awaitingLaunch: CheckedContinuation<Void, Error>?
    private var onExpiration: (@MainActor () -> Void)?

    init(identifier: String, title: String, scheduler: any IOSContinuedAudioScheduler,
         launchTimeout: Duration = .seconds(10)) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 200,
              !identifier.contains("*"), !identifier.utf8.contains(0) else {
            throw IOSAudioBackgroundError.invalidIdentifier
        }
        guard launchTimeout > .zero, launchTimeout <= .seconds(30) else { throw IOSAudioBackgroundError.launchTimedOut }
        self.identifier = identifier; self.title = title; self.scheduler = scheduler
        launchDeadline = ContinuousClock.now + launchTimeout
        // Planning is synchronous with the user's file selection. App switching
        // before the owned async worker starts must not masquerade as dismissal.
        state = .requesting
    }

    var preservesBackgroundWork: Bool { !closed && failure == nil && (state == .requesting || state == .active) }

    func start(onExpiration: @escaping @MainActor () -> Void) async throws {
        guard !started, !closed else { throw IOSAudioBackgroundError.alreadyStarted }
        started = true; self.onExpiration = onExpiration
        if let failure { throw failure }
        if Task.isCancelled { cancel(); throw IOSAudioBackgroundError.cancelled }
        guard ContinuousClock.now < launchDeadline else {
            end(IOSAudioBackgroundError.launchTimedOut); throw IOSAudioBackgroundError.launchTimedOut
        }
        state = .requesting
        SkyBridgeLogger.shared.info("audio_background state=requesting backend=\(String(reflecting: type(of: scheduler))) operation=\(identifier)")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                awaitingLaunch = continuation
                watchdog = Task { [self] in
                    do { try await Task.sleep(until: launchDeadline, clock: .continuous) }
                    catch is CancellationError { return }
                    catch { end(error); return }
                    guard !Task.isCancelled else { return }
                    end(IOSAudioBackgroundError.launchTimedOut)
                }
                submission = Task { [self] in
                    do {
                        try await scheduler.submit(identifier: identifier, title: title) { [weak self] result in
                            guard let self else {
                                if case .success(let task) = result { task.complete(success: false) }
                                return
                            }
                            self.receive(result)
                        }
                        submitted = true
                        if closed || failure != nil { scheduler.cancel(identifier: identifier) }
                        activateIfReady()
                    } catch { submissionFailure = error; end(error) }
                }
            }
        } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
    }

    func update(_ work: IOSOriginalFileSendSession.WorkProgress) {
        updateProgress { try progress.update(work) }
    }

    func update(_ work: IOSOpusFileSendSession.WorkProgress) {
        updateProgress { try progress.update(work) }
    }

    private func updateProgress(_ update: () throws -> Void) {
        guard !closed, failure == nil else { return }
        do {
            let previousStatus = progress.status
            try update()
            systemTask?.updateProgress(progress.value)
            if previousStatus != progress.status { systemTask?.updateStatus(progress.status) }
        }
        catch { end(error) }
    }

    func cancel() { if !closed { end(IOSAudioBackgroundError.cancelled) } }

    /// Called only after the file session has joined its workers and attempted
    /// resource cleanup. A cleanup failure must pass success=false and retain its
    /// product owner; ending the system task is never a cleanup-success receipt.
    func finish(success: Bool) async {
        guard !closed else { return }
        closed = true; state = .stopping
        watchdog?.cancel()
        scheduler.cancel(identifier: identifier)
        if let waiting = awaitingLaunch {
            awaitingLaunch = nil
            waiting.resume(throwing: failure ?? IOSAudioBackgroundError.cancelled)
        }
        // The scheduler callback may ignore Swift cancellation. Its eventual
        // error/launch still belongs to this job, including after a timeout.
        await submission?.value; await watchdog?.value
        submission = nil; watchdog = nil
        if systemTask?.isExpired == true, failure == nil { failure = IOSAudioBackgroundError.expired }
        if success, failure == nil, !submitted || systemTask == nil { failure = IOSAudioBackgroundError.incompleteWork }
        var completed = success && failure == nil
        if completed {
            do {
                try progress.finishSuccessfully()
                systemTask?.updateProgress(progress.value)
            }
            catch { failure = error; completed = false }
        }
        let acceptedSuccess = systemTask?.complete(success: completed)
        if completed, acceptedSuccess != true {
            failure = systemTask?.isExpired == true ? IOSAudioBackgroundError.expired : IOSAudioBackgroundError.incompleteWork
            completed = false
        }
        systemTask = nil; onExpiration = nil
        state = completed ? .finished : .failed
        SkyBridgeLogger.shared.info("audio_background state=ended backend=\(String(reflecting: type(of: scheduler))) operation=\(identifier) completed=\(completed)")
    }

    private func receive(_ result: Result<any IOSContinuedAudioTask, any Error>) {
        switch result {
        case .failure(let error): end(error)
        case .success(let task):
            guard task.identifier == identifier, systemTask == nil else {
                task.complete(success: false); end(IOSAudioBackgroundError.unexpectedTask); return
            }
            guard !closed, failure == nil else { task.complete(success: false); return }
            systemTask = task
            task.updateProgress(progress.value)
            task.updateStatus(progress.status)
            task.setExpirationHandler { [weak self] in self?.end(IOSAudioBackgroundError.expired) }
            activateIfReady()
        }
    }

    private func activateIfReady() {
        guard submitted, systemTask != nil, !closed, failure == nil, let waiting = awaitingLaunch else { return }
        guard systemTask?.isExpired != true else { end(IOSAudioBackgroundError.expired); return }
        guard ContinuousClock.now < launchDeadline else { end(IOSAudioBackgroundError.launchTimedOut); return }
        awaitingLaunch = nil; watchdog?.cancel(); state = .active; waiting.resume()
        SkyBridgeLogger.shared.info("audio_background state=active backend=\(String(reflecting: type(of: scheduler))) operation=\(identifier)")
    }

    private func end(_ error: any Error) {
        // Keep the primary cause stable. submissionFailure separately retains an
        // eventual submit error even when cancellation/expiration was first.
        let firstFailure = failure == nil
        if firstFailure { failure = error }
        if firstFailure {
            let diagnostic = error as NSError
            SkyBridgeLogger.shared.info("audio_background state=stopping backend=\(String(reflecting: type(of: scheduler))) operation=\(identifier) domain=\(diagnostic.domain) code=\(diagnostic.code)")
        }
        scheduler.cancel(identifier: identifier)
        watchdog?.cancel()
        if !closed { state = .stopping; if firstFailure { onExpiration?() } }
        if let waiting = awaitingLaunch {
            awaitingLaunch = nil; waiting.resume(throwing: failure ?? error)
        }
    }
}
