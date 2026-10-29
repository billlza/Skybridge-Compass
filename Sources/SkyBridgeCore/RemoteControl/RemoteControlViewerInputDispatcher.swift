#if os(macOS)
import Foundation

public enum RemoteControlViewerInputEvent: Sendable {
    case mouse(RemoteMouseEvent)
    case keyboard(RemoteKeyboardEvent)

    fileprivate var isPointerMove: Bool {
        if case .mouse(let event) = self { return event.type == .mouseMoved }
        return false
    }
}

public enum RemoteControlViewerInputFailure: Error, LocalizedError {
    case inactive
    case deactivationInProgress
    case closed
    case accessRevoked
    case capacityExceeded(limit: Int)
    case pressedControlCapacityExceeded(limit: Int)
    case sendTimedOut
    case releaseTimedOut
    case sendFailed(underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case .inactive:
            return "远程输入尚未获得焦点"
        case .deactivationInProgress:
            return "正在释放上一轮远程输入，请等待释放完成"
        case .closed:
            return "远程输入会话已关闭"
        case .accessRevoked:
            return "主机已变更输入权限，当前会话继续观看。"
        case .capacityExceeded(let limit):
            return "远程输入积压超过 \(limit) 个事件，会话已停止"
        case .pressedControlCapacityExceeded(let limit):
            return "远程同时按下的输入超过 \(limit) 个，会话已停止"
        case .sendTimedOut:
            return "远程输入发送超时，会话已停止"
        case .releaseTimedOut:
            return "远程输入释放超时，会话已停止"
        case .sendFailed(let underlying):
            return "发送远程输入失败：\(underlying.localizedDescription)"
        }
    }
}

/// One ordered input stream for one exact remote-control engine lifetime.
/// The sender must capture that engine, never look up a replacement by host ID.
/// On terminal failure, the owner must close that engine's connection so the
/// receiving input owner releases any event whose delivery was uncertain.
@MainActor
public final class RemoteControlViewerInputDispatcher {
    private enum State {
        case inactive
        case active
        case deactivating
        case terminal(RemoteControlViewerInputFailure)
    }

    private enum PressedControl {
        case key(Int)
        case mouse(RemoteMouseEvent)

        func release(at timestamp: TimeInterval) -> RemoteControlViewerInputEvent {
            switch self {
            case .key(let code):
                return .keyboard(RemoteKeyboardEvent(type: .keyUp, keyCode: code, timestamp: timestamp))
            case .mouse(let down):
                return .mouse(RemoteMouseEvent(
                    type: down.type == .leftMouseDown ? .leftMouseUp : .rightMouseUp,
                    x: down.x,
                    y: down.y,
                    timestamp: timestamp,
                    clickCount: down.clickCount
                ))
            }
        }
    }

    /// Concurrent deactivation callers share one completion. Closing resolves
    /// it immediately even when a transport send has not observed cancellation.
    @MainActor
    private final class Deactivation {
        private var result: Result<Void, RemoteControlViewerInputFailure>?
        private var continuation: CheckedContinuation<Void, any Error>?
        private var waitTask: Task<Void, any Error>?

        func wait() async throws {
            let task: Task<Void, any Error>
            if let waitTask {
                task = waitTask
            } else {
                task = Task { @MainActor in
                    try await withCheckedThrowingContinuation { continuation in
                        if let result = self.result {
                            continuation.resume(with: result.mapError { $0 as any Error })
                        } else {
                            self.continuation = continuation
                        }
                    }
                }
                waitTask = task
            }
            try await task.value
        }

        func finish(_ result: Result<Void, RemoteControlViewerInputFailure>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result.mapError { $0 as any Error })
            continuation = nil
        }
    }

    private static let maximumPressedControls = 256
    private let capacity: Int
    private let sendTimeout: Duration
    private let send: @MainActor (RemoteControlViewerInputEvent) async throws -> Void
    private let onFailure: @MainActor (RemoteControlViewerInputFailure) -> Void
    private var state: State = .inactive
    private var pending: [RemoteControlViewerInputEvent] = []
    private var pressedControls: [PressedControl] = []
    private var sending = false
    private var sendGeneration: UInt64 = 0
    private var sendDeadlineTask: Task<Void, Never>?
    private var deactivationDeadline: ContinuousClock.Instant?
    private var drainTask: Task<Void, Never>?
    private var deactivation: Deactivation?

    public init(
        capacity: Int = 256,
        sendTimeout: Duration = .seconds(5),
        send: @escaping @MainActor (RemoteControlViewerInputEvent) async throws -> Void,
        onFailure: @escaping @MainActor (RemoteControlViewerInputFailure) -> Void
    ) {
        precondition(capacity > 0, "Input queue capacity must be positive")
        precondition(sendTimeout > .zero, "Input send timeout must be positive")
        self.capacity = capacity
        self.sendTimeout = sendTimeout
        self.send = send
        self.onFailure = onFailure
    }

    public func activate() throws {
        switch state {
        case .inactive, .active:
            state = .active
        case .deactivating:
            throw RemoteControlViewerInputFailure.deactivationInProgress
        case .terminal(let failure):
            throw failure
        }
    }

    public func submitMouse(_ event: RemoteMouseEvent) throws {
        try submit(.mouse(event))
    }

    public func submitKeyboard(_ event: RemoteKeyboardEvent) throws {
        try submit(.keyboard(event))
    }

    /// Stops accepting input immediately, sends accepted events in order, then
    /// releases held controls in reverse press order. Activation is fenced until
    /// all releases finish. The entire drain shares the send timeout budget;
    /// cancelling a waiter does not cancel these releases.
    public func deactivate() async throws {
        let completion: Deactivation
        switch state {
        case .inactive:
            return
        case .terminal(let failure):
            throw failure
        case .active:
            completion = Deactivation()
            deactivation = completion
            deactivationDeadline = .now.advanced(by: sendTimeout)
            state = .deactivating
            scheduleDrainIfNeeded()
        case .deactivating:
            guard let deactivation else {
                preconditionFailure("Deactivating input requires a completion")
            }
            completion = deactivation
        }
        try await completion.wait()
    }

    /// Terminal retirement, paired with closing the exact engine's transport.
    /// Use deactivate() for focus loss while keeping the connection alive.
    public func close() {
        if case .terminal(.accessRevoked) = state {
            terminate(with: .closed)
            return
        }
        if case .terminal = state { return }
        terminate(with: .closed)
    }

    /// The host has already retired the old input grant. Do not send queued
    /// events or synthetic releases under a replacement grant.
    public func revokeAccess() {
        if case .terminal = state { return }
        // A revoked queue may still own one send accepted by the transport.
        // Keep its original deadline until that exact send completes so repeated
        // grants cannot leave stalled sends alive indefinitely.
        terminate(with: .accessRevoked, preservingInFlightDeadline: true)
    }

    private func submit(_ event: RemoteControlViewerInputEvent) throws {
        switch state {
        case .inactive:
            throw RemoteControlViewerInputFailure.inactive
        case .deactivating:
            throw RemoteControlViewerInputFailure.deactivationInProgress
        case .terminal(let failure):
            throw failure
        case .active:
            break
        }

        if event.isPointerMove, pending.last?.isPointerMove == true {
            pending[pending.count - 1] = event
            return
        }
        guard pending.count + (sending ? 1 : 0) < capacity else {
            let failure = RemoteControlViewerInputFailure.capacityExceeded(limit: capacity)
            fail(failure)
            throw failure
        }
        pending.append(event)
        scheduleDrainIfNeeded()
    }

    private func scheduleDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { drainTask = nil }
        while true {
            if case .terminal = state { return }
            if let deactivationDeadline, .now >= deactivationDeadline {
                fail(.releaseTimedOut)
                return
            }
            let event: RemoteControlViewerInputEvent
            if !pending.isEmpty {
                event = pending.removeFirst()
            } else if case .deactivating = state {
                guard let pressed = pressedControls.last else {
                    state = .inactive
                    deactivationDeadline = nil
                    let completed = deactivation
                    deactivation = nil
                    completed?.finish(.success(()))
                    return
                }
                event = pressed.release(at: Date().timeIntervalSince1970)
            } else {
                return
            }

            if isNewPress(event), pressedControls.count >= Self.maximumPressedControls {
                fail(.pressedControlCapacityExceeded(limit: Self.maximumPressedControls))
                return
            }
            let generation = beginSendDeadline()
            do {
                try await send(event)
            } catch {
                if case .terminal(.accessRevoked) = state, !(error is CancellationError) {
                    failSend(.sendFailed(underlying: error), generation: generation)
                    return
                }
                finishSendDeadline(generation: generation)
                if case .terminal = state { return }
                fail(.sendFailed(underlying: error))
                return
            }
            finishSendDeadline(generation: generation)
            if case .terminal = state { return }
            recordSent(event)
        }
    }

    private func beginSendDeadline() -> UInt64 {
        sendGeneration &+= 1
        let generation = sendGeneration
        sending = true
        let sendDeadline = ContinuousClock.now.advanced(by: sendTimeout)
        let deadline: ContinuousClock.Instant
        let failure: RemoteControlViewerInputFailure
        if let deactivationDeadline, deactivationDeadline <= sendDeadline {
            deadline = deactivationDeadline
            failure = .releaseTimedOut
        } else {
            deadline = sendDeadline
            failure = .sendTimedOut
        }
        sendDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch is CancellationError {
                return
            } catch {
                self?.failSend(.sendFailed(underlying: error), generation: generation)
                return
            }
            self?.failSend(failure, generation: generation)
        }
        return generation
    }

    private func finishSendDeadline(generation: UInt64) {
        guard sendGeneration == generation else { return }
        sendGeneration &+= 1
        sendDeadlineTask?.cancel()
        sendDeadlineTask = nil
        sending = false
    }

    private func failSend(_ failure: RemoteControlViewerInputFailure, generation: UInt64) {
        guard sending, sendGeneration == generation else { return }
        if case .terminal(.accessRevoked) = state {
            terminate(with: failure)
            onFailure(failure)
        } else {
            fail(failure)
        }
    }

    private func isNewPress(_ event: RemoteControlViewerInputEvent) -> Bool {
        switch event {
        case .keyboard(let key):
            return key.type == .keyDown && !pressedControls.contains { control in
                if case .key(let code) = control { return code == key.keyCode }
                return false
            }
        case .mouse(let mouse):
            guard mouse.type == .leftMouseDown || mouse.type == .rightMouseDown else { return false }
            return !pressedControls.contains { control in
                if case .mouse(let down) = control { return down.type == mouse.type }
                return false
            }
        }
    }

    private func recordSent(_ event: RemoteControlViewerInputEvent) {
        switch event {
        case .keyboard(let key):
            if isNewPress(event) {
                pressedControls.append(.key(key.keyCode))
            } else if key.type == .keyUp {
                pressedControls.removeAll { control in
                    if case .key(let code) = control { return code == key.keyCode }
                    return false
                }
            }
        case .mouse(let mouse):
            guard mouse.type != .scrollUp && mouse.type != .scrollDown else { return }
            for index in pressedControls.indices {
                if case .mouse(let down) = pressedControls[index] {
                    pressedControls[index] = .mouse(RemoteMouseEvent(
                        type: down.type, x: mouse.x, y: mouse.y,
                        timestamp: down.timestamp, clickCount: down.clickCount
                    ))
                }
            }
            if isNewPress(event) {
                pressedControls.append(.mouse(mouse))
            } else if mouse.type == .leftMouseUp || mouse.type == .rightMouseUp {
                let downType: MouseEventType = mouse.type == .leftMouseUp ? .leftMouseDown : .rightMouseDown
                pressedControls.removeAll { control in
                    if case .mouse(let down) = control { return down.type == downType }
                    return false
                }
            }
        }
    }

    private func fail(_ failure: RemoteControlViewerInputFailure) {
        if case .terminal = state { return }
        terminate(with: failure)
        onFailure(failure)
    }

    private func terminate(
        with failure: RemoteControlViewerInputFailure,
        preservingInFlightDeadline: Bool = false
    ) {
        state = .terminal(failure)
        if !preservingInFlightDeadline || !sending {
            finishSendDeadline(generation: sendGeneration)
        }
        deactivationDeadline = nil
        pending.removeAll(keepingCapacity: false)
        pressedControls.removeAll(keepingCapacity: false)
        drainTask?.cancel()
        let completed = deactivation
        deactivation = nil
        completed?.finish(.failure(failure))
    }
}
#endif
