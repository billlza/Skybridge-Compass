import Foundation
import SkyBridgeProtocolCore

struct RemoteDesktopInputContext: Equatable, Sendable {
    let connectionID: String
    let streamEpoch: UInt64
    let transaction: RemoteDesktopStreamConfigurationTransaction
    let access: RemoteControlAccess?
}

/// One bounded ordered input lane for one authenticated viewer incarnation.
/// The caller captures authority before enqueueing; a delayed event never reads a new lease.
@MainActor
final class RemoteDesktopInputDispatcher {
    struct ConfigurationAdmissionToken: Hashable {
        fileprivate let id: UUID
    }

    enum Event {
        case mouse(MouseEvent)
        case keyboard(KeyboardEvent)

        var isPointerMotion: Bool {
            if case .mouse(let event) = self { return event.type == .mouseMoved }
            return false
        }

        func message(context: RemoteDesktopInputContext) throws -> RemoteMessage {
            switch self {
            case .mouse(let event):
                return RemoteMessage(type: .mouseEvent, payload: try JSONEncoder().encode(event),
                                     inputControlLease: context.access?.lease)
            case .keyboard(let event):
                return RemoteMessage(type: .keyboardEvent, payload: try JSONEncoder().encode(event),
                                     inputControlLease: context.access?.lease)
            }
        }
    }

    enum Failure: Error, Equatable { case queueCapacityExceeded }
    private struct Pending { let event: Event; let context: RemoteDesktopInputContext }
    private let capacity: Int
    private let send: @MainActor (RemoteMessage, RemoteDesktopInputContext) async throws -> Void
    private let failed: @MainActor (any Error, RemoteDesktopInputContext) async -> Void
    private let cancelPendingSend: @MainActor (RemoteDesktopInputContext) -> Void
    private let releaseTimeout: Duration
    private var pending: [Pending] = []
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var heldKeys: Set<Int> = []
    private var heldButtons: Set<MouseEventType> = []
    private var lastPointer: MouseEvent?
    private var heldContext: RemoteDesktopInputContext?
    private var releasing = false
    private var releaseTask: Task<Void, any Error>?
    private var inFlightContext: RemoteDesktopInputContext?
    private var configurationAdmissions: Set<ConfigurationAdmissionToken> = []

    init(capacity: Int = 128,
         releaseTimeout: Duration = .seconds(5),
         cancelPendingSend: @escaping @MainActor (RemoteDesktopInputContext) -> Void,
         send: @escaping @MainActor (RemoteMessage, RemoteDesktopInputContext) async throws -> Void,
         failed: @escaping @MainActor (any Error, RemoteDesktopInputContext) async -> Void) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.releaseTimeout = releaseTimeout
        self.cancelPendingSend = cancelPendingSend
        self.send = send
        self.failed = failed
    }

    var acceptsNewInput: Bool { !releasing && configurationAdmissions.isEmpty }

    func enqueue(_ event: Event, context: RemoteDesktopInputContext) {
        guard acceptsNewInput else { return }
        if event.isPointerMotion, let last = pending.last,
           last.event.isPointerMotion, last.context == context {
            pending[pending.count - 1] = Pending(event: event, context: context)
        } else if pending.count < capacity {
            pending.append(Pending(event: event, context: context))
        } else {
            retire()
            Task { await failed(Failure.queueCapacityExceeded, context) }
            return
        }
        startWorkerIfNeeded()
    }

    func drain() async { await worker?.value }

    /// The configuration owner keeps admission closed across release-task completion and its own commit.
    func beginConfigurationUpdate() -> ConfigurationAdmissionToken {
        let token = ConfigurationAdmissionToken(id: UUID())
        configurationAdmissions.insert(token)
        return token
    }

    func finishConfigurationUpdate(_ token: ConfigurationAdmissionToken) {
        configurationAdmissions.remove(token)
    }

    /// Concurrent callers join one bounded barrier, keeping admission closed until every release commits.
    func releasePressedInput() async throws {
        if let releaseTask { return try await releaseTask.value }
        releasing = true
        let task = Task { @MainActor [self] in
            defer { releasing = false; releaseTask = nil }
            let operationGeneration = generation
            var work: Task<Void, Never>?
            let deadline = RemoteDesktopOperationDeadline(cancelResource: { [self] in
                if let context = inFlightContext ?? heldContext ?? pending.first?.context {
                    cancelPendingSend(context)
                }
                work?.cancel()
                worker?.cancel()
                retire()
            })
            try await deadline.run(timeout: releaseTimeout, phase: .inputRelease) { finish in
                work = Task { @MainActor [self] in
                    do {
                        await drain()
                        try Task.checkCancellation()
                        guard generation == operationGeneration else { throw CancellationError() }
                        try await sendPressedInputReleases(generation: operationGeneration)
                        finish(.success(()))
                    } catch { finish(.failure(error)) }
                }
            }
        }
        releaseTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func sendPressedInputReleases(generation expectedGeneration: UInt64) async throws {
        guard let context = heldContext else { return }
        if let pointer = lastPointer {
            for button in [MouseEventType.leftMouseDown, .rightMouseDown] where heldButtons.contains(button) {
                let up: MouseEventType = button == .leftMouseDown ? .leftMouseUp : .rightMouseUp
                let event = Event.mouse(MouseEvent(type: up, x: pointer.x, y: pointer.y))
                inFlightContext = context
                try await send(event.message(context: context), context)
                guard generation == expectedGeneration else { throw CancellationError() }
                inFlightContext = nil
                heldButtons.remove(button)
            }
        }
        for code in heldKeys.sorted() {
            let event = Event.keyboard(KeyboardEvent(type: .keyUp, keyCode: code))
            inFlightContext = context
            try await send(event.message(context: context), context)
            guard generation == expectedGeneration else { throw CancellationError() }
            inFlightContext = nil
            heldKeys.remove(code)
        }
        heldContext = nil
    }

    /// Host revocation/transport retirement already owns native release. Do not compensate on a new lease.
    func retire() {
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        heldKeys.removeAll(keepingCapacity: true)
        heldButtons.removeAll(keepingCapacity: true)
        heldContext = nil
        lastPointer = nil
        inFlightContext = nil
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { worker = nil }
            while !pending.isEmpty && !Task.isCancelled {
                let operation = pending.removeFirst()
                let operationGeneration = generation
                do {
                    inFlightContext = operation.context
                    try await send(operation.event.message(context: operation.context), operation.context)
                    guard generation == operationGeneration else { continue }
                    inFlightContext = nil
                    recordCommitted(operation)
                } catch is CancellationError {
                    if generation == operationGeneration { inFlightContext = nil }
                    // A retired incarnation has no authority to inject or release into its replacement.
                    continue
                } catch {
                    guard generation == operationGeneration else { continue }
                    retire()
                    await failed(error, operation.context)
                    return
                }
            }
        }
    }

    private func recordCommitted(_ operation: Pending) {
        if heldContext != operation.context {
            heldKeys.removeAll(keepingCapacity: true)
            heldButtons.removeAll(keepingCapacity: true)
        }
        heldContext = operation.context
        switch operation.event {
        case .mouse(let event):
            lastPointer = event
            switch event.type {
            case .leftMouseDown, .rightMouseDown: heldButtons.insert(event.type)
            case .leftMouseUp: heldButtons.remove(.leftMouseDown)
            case .rightMouseUp: heldButtons.remove(.rightMouseDown)
            case .mouseMoved, .scrollUp, .scrollDown: break
            }
        case .keyboard(let event):
            if event.type == .keyDown { heldKeys.insert(event.keyCode) }
            else { heldKeys.remove(event.keyCode) }
        }
    }
}
