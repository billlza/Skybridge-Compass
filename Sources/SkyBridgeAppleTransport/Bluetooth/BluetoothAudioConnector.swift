import CoreBluetooth
import Foundation
import SkyBridgeProtocolCore
import os

/// Preserve which native callback failed without exposing NSError userInfo in
/// diagnostics. A radio failure is not an encoding or source-file failure.
public struct BluetoothAudioNativeFailure: Error, Sendable, CustomStringConvertible {
    public enum Operation: String, CaseIterable, Sendable {
        case connect, disconnect, openL2CAP = "open_l2cap"
        case discoverServices = "discover_services", discoverCharacteristics = "discover_characteristics", readPSM = "read_psm"
    }
    public let operation: Operation
    public let underlying: any Error
    init(operation: Operation, underlying: any Error) {
        self.operation = operation; self.underlying = underlying
    }
    public var diagnosticLabel: String {
        "native." + operation.rawValue + "." + AudioPlaybackFailureDiagnostic.label(for: underlying)
    }
    public var description: String { diagnosticLabel }
}

public enum BluetoothAudioConnectorError: Error, Sendable {
    case alreadyStarted, notReady, closed, timedOut, invalidTimeout, invalidAttachment
    case unavailable(state: Int), unexpectedCallback, connectionFailed, disconnected, openFailed
    case missingPSMService, missingPSMCharacteristic, invalidPSMValue, psmMismatch
    case cleanupUnconfirmed
    case cleanupFailed(primary: any Error, cleanup: any Error)
}

/// A single outbound CoC owner, subordinate to one completed MAIN binding and
/// the caller's current finite authorization. A native connection is not ready
/// until the existing four-message child authentication also finishes.
/// Retain this owner until closeAndAwait succeeds, including after a timeout.
@MainActor
public final class BluetoothAudioConnector: BluetoothAudioDialEvents {
    private enum Phase { case idle, starting, scanning, connecting, opening, authenticating, active, stopping, closed }
    private let attachment: AudioBluetoothAttachment
    private let route: AudioBluetoothRoute
    private let requireCurrent: @Sendable () throws -> Void
    private let makeDriver: @MainActor () -> any BluetoothAudioDialDriver
    private let now: @MainActor () -> ContinuousClock.Instant
    private var phase = Phase.idle
    private var driver: (any BluetoothAudioDialDriver)?
    private var candidate: UUID?
    private var transport: BluetoothControlFrameTransport?
    // The native driver allocates at most one worker. Retain any rejected handoff
    // too, so a lifetime change between its two checks cannot abandon cleanup.
    private var retiredTransports: [BluetoothControlFrameTransport] = []
    private var child: BluetoothAudioChannel?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var execution: Task<Void, any Error>?
    private var executionCompleted = OSAllocatedUnfairLock(initialState: false)
    private var monitor: Task<Void, Never>?
    private var cleanup: (UUID, Task<Void, any Error>)?
    private var deadline: ContinuousClock.Instant?
    private var terminalFailure: (any Error)?
    public var isClosed: Bool { phase == .closed }
    public var cleanupPending: Bool { phase == .stopping }

    public convenience init(attachment: AudioBluetoothAttachment, requireCurrent: @escaping @Sendable () throws -> Void) throws {
        try self.init(attachment: attachment, requireCurrent: requireCurrent, makeDriver: { NativeBluetoothAudioDialDriver() })
    }
    init(attachment: AudioBluetoothAttachment, requireCurrent: @escaping @Sendable () throws -> Void,
         makeDriver: @escaping @MainActor () -> any BluetoothAudioDialDriver,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) throws {
        guard attachment.binding.role == .source,
              case .bluetoothRoute(let route) = attachment.binding.route.body else {
            throw BluetoothAudioConnectorError.invalidAttachment
        }
        self.attachment = attachment; self.route = route; self.requireCurrent = requireCurrent
        self.makeDriver = makeDriver; self.now = now
    }

    public func connect(timeout: Duration = .seconds(20)) async throws {
        guard phase == .idle else { throw BluetoothAudioConnectorError.alreadyStarted }
        guard timeout > .zero, timeout <= .seconds(30) else { throw BluetoothAudioConnectorError.invalidTimeout }
        phase = .starting; deadline = now().advanced(by: timeout)
        let completed = executionCompleted
        let task = Task {
            defer { completed.withLock { $0 = true } }
            try await self.performConnection()
        }; execution = task
        defer { execution = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                Task { @MainActor [self] in requestStop(CancellationError()) }
            }
            try Task.checkCancellation(); try requireCurrent()
            guard phase == .active else { throw terminalFailure ?? BluetoothAudioConnectorError.closed }
        } catch {
            requestStop(error)
            do { try await closeAndAwait() }
            catch let cleanup { throw BluetoothAudioConnectorError.cleanupFailed(primary: terminalFailure ?? error, cleanup: cleanup) }
            throw terminalFailure ?? error
        }
    }

    public var channel: BluetoothAudioChannel {
        get throws {
            try requireCurrent(); try attachment.requireEstablishedCurrent()
            guard phase == .active, let child else { throw terminalFailure ?? BluetoothAudioConnectorError.notReady }
            return child
        }
    }

    public func closeAndAwait() async throws {
        if phase == .closed { return }
        requestStop(nil)
        let owned: (UUID, Task<Void, any Error>)
        if let cleanup { owned = cleanup }
        else {
            let operation = execution, id = UUID()
            // A cancelled caller cannot cancel resource observation or drop the
            // native owner. The same pending cleanup is joined by all callers.
            let task = Task.detached { try await self.finishCleanup(operation: operation) }
            owned = (id, task); cleanup = owned
        }
        defer { if cleanup?.0 == owned.0 { cleanup = nil } }
        try await owned.1.value
    }

    private func performConnection() async throws {
        try Task.checkCancellation(); try checkCurrent()
        _ = try attachment.handshakeRemainingTime()
        guard phase == .starting else { throw terminalFailure ?? BluetoothAudioConnectorError.closed }
        let driver = makeDriver(); self.driver = driver; driver.events = self
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try self.checkCurrent() }
                catch { self.requestStop(error); return }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch is CancellationError { return }
                catch { self.requestStop(error); return }
            }
        }
        try await withCheckedThrowingContinuation { waiter = $0; driver.start() }
        try Task.checkCancellation(); try checkCurrent()
        guard phase == .opening, let transport else { throw terminalFailure ?? BluetoothAudioConnectorError.notReady }
        let child = BluetoothAudioChannel(transport: transport, attachment: attachment)
        self.child = child; phase = .authenticating
        try await child.authenticate(requireEffectAuthorization: requireCurrent)
        try Task.checkCancellation(); try checkCurrent(); try attachment.requireEstablishedCurrent()
        guard phase == .authenticating else { throw terminalFailure ?? BluetoothAudioConnectorError.closed }
        phase = .active; deadline = nil
    }

    private func checkCurrent() throws {
        guard phase != .stopping, phase != .closed else { throw terminalFailure ?? BluetoothAudioConnectorError.closed }
        try requireCurrent()
        try attachment.requireLifetimeCurrent()
        if phase != .active {
            if let deadline, now() >= deadline { throw BluetoothAudioConnectorError.timedOut }
        }
    }
    private func requestStop(_ error: (any Error)?) {
        guard phase != .closed else { return }
        if terminalFailure == nil { terminalFailure = error }
        phase = .stopping; monitor?.cancel(); monitor = nil
        attachment.close(); transport?.close(); execution?.cancel()
        for transport in retiredTransports { transport.close() }
        let waiting = waiter; waiter = nil
        waiting?.resume(throwing: terminalFailure ?? BluetoothAudioConnectorError.closed)
        driver?.stop()
    }
    private func finishCleanup(operation: Task<Void, any Error>?) async throws {
        // performConnection never calls cleanup, so this cannot join itself.
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while operation != nil, !executionCompleted.withLock({ $0 }) {
            guard ContinuousClock.now < end else { throw BluetoothAudioConnectorError.cleanupUnconfirmed }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let operation { _ = await operation.result }
        if let child { try await child.closeAndAwait() }
        else if let transport { try await transport.closeAndAwait() }
        for transport in retiredTransports { try await transport.closeAndAwait() }
        while driver?.isQuiescent == false {
            guard ContinuousClock.now < end else { throw BluetoothAudioConnectorError.cleanupUnconfirmed }
            try await Task.sleep(for: .milliseconds(10))
        }
        try driver?.detach()
        driver = nil; child = nil; transport = nil; candidate = nil; retiredTransports.removeAll()
        phase = .closed
    }

    func stateChanged(_ state: CBManagerState) {
        if phase == .stopping || phase == .closed { driver?.stop(); return }
        do {
            try checkCurrent()
            switch state {
            case .poweredOn:
                if phase == .starting { phase = .scanning; driver?.scan(serviceID: route.serviceID) }
            case .unknown, .resetting:
                if phase != .starting { throw BluetoothAudioConnectorError.unavailable(state: state.rawValue) }
            default: throw BluetoothAudioConnectorError.unavailable(state: state.rawValue)
            }
        } catch { requestStop(error) }
    }
    func discovered(_ identifier: UUID) {
        guard phase == .scanning, candidate == nil else { return }
        do {
            try checkCurrent()
            candidate = identifier; phase = .connecting
            driver?.stopScan(); driver?.connect(identifier: identifier)
        } catch { requestStop(error) }
    }
    func connected(_ identifier: UUID) {
        if phase == .stopping || phase == .closed { driver?.stop(); return }
        do {
            try checkCurrent()
            guard phase == .connecting, identifier == candidate else { throw BluetoothAudioConnectorError.unexpectedCallback }
            phase = .opening; driver?.open(psm: route.psm)
        } catch { requestStop(error) }
    }
    func disconnected(_ identifier: UUID, error: (any Error)?) {
        guard phase != .closed else { return }
        guard identifier == candidate else { requestStop(BluetoothAudioConnectorError.unexpectedCallback); return }
        if phase != .stopping { requestStop(error ?? BluetoothAudioConnectorError.disconnected) }
    }
    func failed(_ error: any Error) { requestStop(error) }
    func mayAccept(identifier: UUID, psm: UInt16) -> Bool {
        do {
            try checkCurrent()
            guard phase == .opening, transport == nil, identifier == candidate, psm == route.psm else {
                throw BluetoothAudioConnectorError.unexpectedCallback
            }
            return true
        } catch { requestStop(error); return false }
    }
    func opened(_ transport: BluetoothControlFrameTransport, identifier: UUID, psm: UInt16) {
        // The native delegate checks before allocating the worker, and rechecks
        // at handoff. A refused worker still has a real cleanup owner.
        guard mayAccept(identifier: identifier, psm: psm) else {
            transport.close(); retiredTransports.append(transport); return
        }
        self.transport = transport
        let waiting = waiter; waiter = nil; waiting?.resume()
    }
}
