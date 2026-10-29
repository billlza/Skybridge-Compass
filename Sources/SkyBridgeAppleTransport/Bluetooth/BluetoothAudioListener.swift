import CoreBluetooth
import Foundation
import SkyBridgeProtocolCore

public enum BluetoothAudioListenerError: Error, Sendable {
    case alreadyStarted, notReady, closed, timedOut, invalidTimeout, invalidAttachment, unexpectedCallback, candidateLimit
    case unavailable(state: Int), cleanupUnconfirmed
    case cleanupFailed(primary: any Error, cleanup: any Error)
    case establishmentFailed(candidates: [any Error], terminal: any Error)
}

/// One real encrypted publication and one authenticated media child. Own this before publishing
/// and retain it until closeAndAwait succeeds. A UUID/PSM locates a service; it grants no identity,
/// account membership or playback permission. Native control callbacks use MainActor, never
/// media I/O. The caller supplies the current finite authorization and the exact MAIN attachment.
@MainActor
public final class BluetoothAudioListener: BluetoothAudioPublicationEvents {
    private enum Phase { case idle, publishing, published, accepting, active, stopping, closed }
    public let streamID: UUID
    private let serviceID = UUID(), publicationID = UUID()
    private let requireCurrent: @Sendable () throws -> Void
    private let makeDriver: @MainActor () -> any BluetoothAudioPublicationDriver
    private var driver: (any BluetoothAudioPublicationDriver)?
    private var phase = Phase.idle
    private var route: AudioBluetoothRoute?
    private var publicationIssued = false, publicationPending = false
    private var servicePending = false, advertisingPending = false
    private var publishedPSMs = Set<UInt16>(), unpublishRequests = Set<UInt16>(), failedUnpublishes = Set<UInt16>()
    private var candidates: [BluetoothControlFrameTransport] = []
    private var retiredCandidates: [BluetoothControlFrameTransport] = []
    private var child: BluetoothAudioChannel?
    private var pendingAttachment: AudioBluetoothAttachment?
    private var attemptedCandidates = 0
    private var candidateErrors: [any Error] = []
    private var routeWaiter: CheckedContinuation<AudioBluetoothRoute, any Error>?
    private var candidateWaiter: CheckedContinuation<Void, any Error>?
    private var deadline: ContinuousClock.Instant?
    private var monitor: Task<Void, Never>?
    private var terminalFailure: (any Error)?
    private var cleanupFailure: (any Error)?
    private var cleanupTask: (UUID, Task<Void, any Error>)?
    private var cleanupObserved = false
    private static let maximumCandidates = 4

    public convenience init(streamID: UUID, requireCurrent: @escaping @Sendable () throws -> Void) {
        self.init(streamID: streamID, requireCurrent: requireCurrent, makeDriver: { NativeBluetoothAudioPublicationDriver() })
    }
    init(streamID: UUID, requireCurrent: @escaping @Sendable () throws -> Void,
         makeDriver: @escaping @MainActor () -> any BluetoothAudioPublicationDriver) {
        self.streamID = streamID; self.requireCurrent = requireCurrent; self.makeDriver = makeDriver
    }

    public func publish(timeout: Duration = .seconds(20)) async throws -> AudioBluetoothRoute {
        guard phase == .idle else { throw BluetoothAudioListenerError.alreadyStarted }
        guard timeout > .zero, timeout <= .seconds(30) else { throw BluetoothAudioListenerError.invalidTimeout }
        guard streamID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw BluetoothAudioListenerError.invalidAttachment
        }
        try Task.checkCancellation(); try requireCurrent()
        phase = .publishing; deadline = .now.advanced(by: timeout)
        let driver = makeDriver(); self.driver = driver; driver.events = self
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.checkCurrent() { return }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch is CancellationError { return }
                catch { self.requestStop(error); return }
            }
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    routeWaiter = continuation
                    driver.start()
                }
            } onCancel: { Task { @MainActor [self] in requestStop(CancellationError()) } }
            try Task.checkCancellation(); try requireCurrent()
            guard phase == .published else { throw terminalFailure ?? BluetoothAudioListenerError.closed }
            return value
        } catch { throw await retireAfter(error) }
    }

    /// The listener retains the candidate before awaiting authentication. Invalid Hello frames
    /// cannot consume the pending attachment. At most four candidates use the original deadline.
    public func accept(_ attachment: AudioBluetoothAttachment) async throws {
        guard phase == .published, let route else { throw BluetoothAudioListenerError.notReady }
        guard attachment.binding.role == .sink, attachment.binding.offer.streamID == streamID,
              case .bluetoothRoute(let supplied) = attachment.binding.route.body, supplied == route else {
            throw BluetoothAudioListenerError.invalidAttachment
        }
        pendingAttachment = attachment; phase = .accepting
        do {
            try Task.checkCancellation(); try requireCurrent()
            try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation(); try requireCurrent()
                    guard checkCurrent(), phase == .accepting else { throw terminalFailure ?? BluetoothAudioListenerError.closed }
                    _ = try attachment.handshakeRemainingTime()
                    guard attemptedCandidates < Self.maximumCandidates else { throw BluetoothAudioListenerError.candidateLimit }
                    if candidates.isEmpty {
                        try await withCheckedThrowingContinuation { candidateWaiter = $0 }
                        continue
                    }
                    let transport = candidates.removeFirst()
                    let attempt = BluetoothAudioChannel(transport: transport, attachment: attachment)
                    child = attempt; attemptedCandidates += 1
                    do {
                        try await attempt.authenticate(initialHelloTimeout: .seconds(3), requireEffectAuthorization: requireCurrent)
                    } catch {
                        // A failed cleanup retains this exact child and terminates the listener.
                        do { try await attempt.closeAndAwait() }
                        catch let cleanup { throw BluetoothAudioListenerError.cleanupFailed(primary: error, cleanup: cleanup) }
                        child = nil
                        try Task.checkCancellation()
                        guard phase == .accepting else { throw terminalFailure ?? error }
                        candidateErrors.append(error)
                        _ = try attachment.handshakeRemainingTime()
                        continue
                    }
                    try Task.checkCancellation(); try requireCurrent()
                    guard checkCurrent(), phase == .accepting else { throw terminalFailure ?? BluetoothAudioListenerError.closed }
                    phase = .active; deadline = nil
                    driver?.stopAdvertisingAndRemoveServices()
                    // Retain the PSM until the owned media child closes. Removing the listener is
                    // not assumed to be independent of already-open platform channels.
                    retiredCandidates += candidates; candidates.removeAll()
                    for transport in retiredCandidates { transport.close() }
                    for transport in retiredCandidates { try await transport.closeAndAwait() }
                    retiredCandidates.removeAll()
                    return
                }
            } onCancel: { Task { @MainActor [self] in requestStop(CancellationError()) } }
        } catch { throw await retireAfter(error) }
    }

    /// Borrowed from this listener. Closing the listener always retires this same child.
    public var channel: BluetoothAudioChannel {
        get throws {
            guard phase == .active, let child else { throw BluetoothAudioListenerError.notReady }
            try requireCurrent()
            return child
        }
    }

    /// Concurrent callers share one cleanup observation. A timed-out/failed observer may be
    /// retried using this owner; late publish/add/advertise callbacks still retire their resources.
    public func closeAndAwait() async throws {
        if phase == .closed { return }
        let owned: (UUID, Task<Void, any Error>)
        if let cleanupTask { owned = cleanupTask }
        else {
            if cleanupObserved {
                cleanupFailure = nil
                unpublishRequests.subtract(failedUnpublishes); failedUnpublishes.removeAll()
            }
            cleanupObserved = true
            requestStop(nil)
            advanceStop()
            let id = UUID()
            let task = Task { try await finishCleanup() }
            owned = (id, task); cleanupTask = owned
        }
        defer { if cleanupTask?.0 == owned.0 { cleanupTask = nil } }
        try await owned.1.value
    }

    private func retireAfter(_ primary: any Error) async -> any Error {
        requestStop(primary)
        let reported: any Error = candidateErrors.isEmpty ? primary :
            BluetoothAudioListenerError.establishmentFailed(candidates: candidateErrors, terminal: primary)
        do { try await closeAndAwait(); return reported }
        catch { return BluetoothAudioListenerError.cleanupFailed(primary: reported, cleanup: error) }
    }
    private func checkCurrent() -> Bool {
        guard phase != .stopping, phase != .closed else { return false }
        do {
            try requireCurrent()
            if let deadline, ContinuousClock.now >= deadline { throw BluetoothAudioListenerError.timedOut }
            return true
        } catch { requestStop(error); return false }
    }
    private func requestStop(_ error: (any Error)?) {
        guard phase != .closed else { return }
        if terminalFailure == nil { terminalFailure = error }
        let firstStop = phase != .stopping
        phase = .stopping; monitor?.cancel(); monitor = nil
        let reason = terminalFailure ?? BluetoothAudioListenerError.closed
        routeWaiter?.resume(throwing: reason); routeWaiter = nil
        candidateWaiter?.resume(throwing: reason); candidateWaiter = nil
        driver?.stopAdvertisingAndRemoveServices()
        pendingAttachment?.close()
        for transport in candidates + retiredCandidates { transport.close() }
        if firstStop, let child { Task { await child.close() } }
        advanceStop()
    }
    private func advanceStop() {
        guard phase == .stopping else { return }
        for psm in publishedPSMs.subtracting(unpublishRequests) {
            unpublishRequests.insert(psm)
            driver?.unpublish(psm: psm)
        }
    }
    private func finishCleanup() async throws {
        let observedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var nativeFailure: (any Error)?
        if let child {
            do { try await child.closeAndAwait() } catch { nativeFailure = error }
        }
        for transport in candidates + retiredCandidates {
            do { try await transport.closeAndAwait() }
            catch {
                nativeFailure = nativeFailure.map { BluetoothAudioListenerError.cleanupFailed(primary: $0, cleanup: error) } ?? error
            }
        }
        while publicationPending || servicePending || advertisingPending || !publishedPSMs.isEmpty || driver?.isAdvertising == true {
            if let cleanupFailure { throw combine(nativeFailure, cleanupFailure) }
            guard ContinuousClock.now < observedDeadline else { throw combine(nativeFailure, BluetoothAudioListenerError.cleanupUnconfirmed) }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let cleanupFailure { throw combine(nativeFailure, cleanupFailure) }
        if let nativeFailure { throw nativeFailure }
        candidates.removeAll(); retiredCandidates.removeAll(); child = nil; pendingAttachment = nil
        driver?.events = nil; driver = nil; phase = .closed
    }
    private func combine(_ primary: (any Error)?, _ cleanup: any Error) -> any Error {
        primary.map { BluetoothAudioListenerError.cleanupFailed(primary: $0, cleanup: cleanup) } ?? cleanup
    }

    func stateChanged(_ state: CBManagerState) {
        guard checkCurrent() else { return }
        switch state {
        case .poweredOn:
            if !publicationIssued {
                publicationIssued = true; publicationPending = true
                driver?.publish()
            }
        case .unknown, .resetting:
            if publicationIssued { requestStop(BluetoothAudioListenerError.unavailable(state: state.rawValue)) }
        default: requestStop(BluetoothAudioListenerError.unavailable(state: state.rawValue))
        }
    }
    func published(psm: UInt16, error: (any Error)?) {
        let expected = publicationPending
        publicationPending = false
        if psm > 0 { publishedPSMs.insert(psm) }
        guard expected else { requestStop(BluetoothAudioListenerError.unexpectedCallback); return }
        guard phase != .stopping, checkCurrent() else { advanceStop(); return }
        if let error { requestStop(error); return }
        do {
            route = try AudioBluetoothRoute(serviceID: serviceID, publicationID: publicationID, psm: psm)
            servicePending = true; driver?.addService(id: serviceID, psm: psm)
        } catch { requestStop(error) }
    }
    func serviceAdded(error: (any Error)?) {
        let expected = servicePending; servicePending = false
        guard phase != .stopping else { driver?.stopAdvertisingAndRemoveServices(); return }
        guard expected, checkCurrent() else { requestStop(BluetoothAudioListenerError.unexpectedCallback); return }
        if let error { requestStop(error); return }
        advertisingPending = true; driver?.advertise(id: serviceID)
    }
    func advertisingStarted(error: (any Error)?) {
        let expected = advertisingPending; advertisingPending = false
        guard phase != .stopping else { driver?.stopAdvertisingAndRemoveServices(); return }
        guard expected, checkCurrent(), let route else { requestStop(BluetoothAudioListenerError.unexpectedCallback); return }
        if let error { requestStop(error); return }
        guard driver?.isAdvertising == true else { requestStop(BluetoothAudioListenerError.unexpectedCallback); return }
        phase = .published; deadline = .now.advanced(by: .seconds(30))
        routeWaiter?.resume(returning: route); routeWaiter = nil
    }
    func unpublished(psm: UInt16, error: (any Error)?) {
        guard unpublishRequests.contains(psm), publishedPSMs.contains(psm) else {
            cleanupFailure = BluetoothAudioListenerError.unexpectedCallback; return
        }
        if let error { failedUnpublishes.insert(psm); cleanupFailure = error }
        else { publishedPSMs.remove(psm); unpublishRequests.remove(psm) }
    }
    func mayAccept(psm: UInt16) -> Bool {
        guard phase == .published || phase == .accepting, checkCurrent(), route?.psm == psm,
              candidates.count + (child == nil ? 0 : 1) < Self.maximumCandidates,
              attemptedCandidates + candidates.count < Self.maximumCandidates else { return false }
        return true
    }
    func opened(_ transport: BluetoothControlFrameTransport, psm: UInt16) {
        guard mayAccept(psm: psm) else { transport.close(); retiredCandidates.append(transport); return }
        candidates.append(transport)
        candidateWaiter?.resume(); candidateWaiter = nil
    }
    func candidateFailed(_ error: any Error) {
        guard phase == .published || phase == .accepting else { return }
        if candidateErrors.count < Self.maximumCandidates { candidateErrors.append(error) }
        attemptedCandidates = min(Self.maximumCandidates, attemptedCandidates + 1)
        candidateWaiter?.resume(); candidateWaiter = nil
    }
}
