#if os(macOS)
import Foundation
import Combine
import os
import SkyBridgeProtocolCore
import SkyBridgeAppleTransport
import CSkyBridgeUSBHost

public enum AndroidUSBConnectionPhase: String, Sendable {
    case idle, preparing, opening, authenticating, connected, stopping, cleanupRequired, failed
}

/// A selected existing protocol identity, never a USB serial, name or port.
public struct AndroidUSBSelectedPeer: Sendable {
    public let deviceID: String
    public let fingerprint: String
    public let algorithm: ProtocolSigningAlgorithm
    public let name: String
    public init(deviceID: String, fingerprint: String, algorithm: ProtocolSigningAlgorithm, name: String) throws {
        let raw = deviceID.lowercased().hasPrefix("id:") ? String(deviceID.dropFirst(3)) : deviceID
        guard algorithm == .mlDSA65 || algorithm == .mlDSA87,
              let id = UUID(uuidString: raw), fingerprint.count == 64,
              fingerprint.allSatisfy(\.isHexDigit) else { throw AndroidUSBConnectionError.invalidPeer }
        self.deviceID = id.uuidString.lowercased(); self.fingerprint = fingerprint.lowercased(); self.algorithm = algorithm; self.name = name
    }
}

public enum AndroidUSBConnectionError: Error, Sendable {
    case invalidPeer, alreadyConnecting, unavailable, attachmentChanged, ambiguousAttachment
    case reenumerationTimedOut, unownedAccessory, interfaceBusy, cleanupUnconfirmed, connectionLost
}

final class AndroidUSBAttemptAuthority: Sendable {
    let id = UUID()
    private let current = OSAllocatedUnfairLock(initialState: true)
    func retire() { current.withLock { $0 = false } }
    func requireCurrent() throws {
        try Task.checkCancellation()
        guard current.withLock({ $0 }) else { throw CancellationError() }
    }
}

@MainActor
protocol AndroidUSBSessionRuntime: AnyObject {
    var connection: P2PConnection? { get }
    var connectionEndFailure: (any Error)? { get }
    var attemptKey: String? { get }
    var cleanupConfirmed: Bool { get }
    func run(progress: @escaping @MainActor (AndroidUSBConnectionPhase) -> Void) async throws
    func releaseAttempt()
    func retire()
    func closeAndAwait() async throws
}

/// App-lived owner, retained by P2PDiscoveryService across view navigation.
/// An observer timeout leaves the same runtime/task retained for cleanup; it
/// never permits another native owner or replays a connect request.
@MainActor
public final class AndroidUSBConnectionCoordinator: ObservableObject {
    typealias Factory = (USBDeviceInfo, AndroidUSBSelectedPeer, AndroidUSBAttemptAuthority) throws -> any AndroidUSBSessionRuntime
    private final class Entry {
        let source: USBDeviceInfo
        let peer: AndroidUSBSelectedPeer
        let authority: AndroidUSBAttemptAuthority
        let runtime: any AndroidUSBSessionRuntime
        var run: Task<Void, Never>?
        var cleanup: Task<Result<Void, any Error>, Never>?
        var cleanupResult: Result<Void, any Error>?
        var observer: Task<Void, Never>?
        var subscription: AnyCancellable?
        var primaryFailure: (any Error)?
        init(source: USBDeviceInfo, peer: AndroidUSBSelectedPeer, authority: AndroidUSBAttemptAuthority,
             runtime: any AndroidUSBSessionRuntime) {
            self.source = source; self.peer = peer; self.authority = authority; self.runtime = runtime
        }
    }
    @Published public private(set) var phase: AndroidUSBConnectionPhase = .idle
    @Published public private(set) var failure: (any Error)?
    @Published public private(set) var selectedSource: USBDeviceInfo?
    @Published public private(set) var selectedPeer: AndroidUSBSelectedPeer?
    private var entry: Entry?
    private let factory: Factory
    private let cleanupObservation: Duration

    init(factory: @escaping Factory, cleanupObservation: Duration = .seconds(10)) {
        self.factory = factory; self.cleanupObservation = cleanupObservation
    }
    public var isOccupied: Bool { entry != nil }
    public var authenticatedConnection: P2PConnection? {
        guard phase == .connected, let value = entry?.runtime.connection, value.status == .authenticated else { return nil }
        return value
    }

    public func connect(source: USBDeviceInfo, peer: AndroidUSBSelectedPeer) throws {
        guard entry == nil else { throw AndroidUSBConnectionError.alreadyConnecting }
        guard cleanupObservation > .zero && cleanupObservation <= .seconds(60) else { throw AndroidUSBConnectionError.unavailable }
        let authority = AndroidUSBAttemptAuthority()
        let runtime = try factory(source, peer, authority)
        let owned = Entry(source: source, peer: peer, authority: authority, runtime: runtime)
        entry = owned; selectedSource = source; selectedPeer = peer; failure = nil; phase = .preparing
        owned.run = Task { [weak self, owned] in
            guard let self else { return }
            do {
                try await owned.runtime.run { [weak self, weak owned] value in
                    guard let self, let owned, self.entry === owned,
                          self.phase != .stopping && self.phase != .cleanupRequired else { return }
                    self.phase = value
                }
                try owned.authority.requireCurrent()
                guard self.entry === owned else { throw CancellationError() }
                guard let connection = owned.runtime.connection, connection.status == .authenticated else {
                    throw AndroidUSBConnectionError.unavailable
                }
                self.phase = .connected
                owned.runtime.releaseAttempt()
                do {
                    owned.subscription = connection.$status.sink { [weak self, weak owned] status in
                        guard status == .disconnected || status == .failed else { return }
                        Task { @MainActor in
                            guard let self, let owned, self.entry === owned else { return }
                            if let error = owned.runtime.connectionEndFailure {
                                owned.primaryFailure = error
                                self.failure = error
                            } else if status == .failed {
                                owned.primaryFailure = AndroidUSBConnectionError.connectionLost
                                self.failure = owned.primaryFailure
                            }
                            self.stop()
                        }
                    }
                }
            } catch {
                if self.entry === owned {
                    // Native startup keeps its receipt when cancellation wins.
                    // Only a cancelled operation with proven release is normal
                    // cancellation; a concurrent I/O/cleanup error remains visible.
                    let cancelledStartup: Bool
                    if let startup = error as? USBHostAccessoryPreparationFailure {
                        cancelledStartup = (self.phase == .stopping || self.phase == .cleanupRequired) &&
                            startup.cause is CancellationError && startup.receipt.referencesReleased &&
                            startup.receipt.cleanupFailure == nil &&
                            (startup.receipt.operationFailure == nil ||
                             startup.receipt.operationFailure?.status == SB_USB_CANCELLED.rawValue)
                    } else { cancelledStartup = false }
                    if !(error is CancellationError) && !cancelledStartup {
                        owned.primaryFailure = error; self.failure = error
                    }
                    self.stop()
                }
            }
        }
    }

    public func stop() {
        guard let owned = entry else { return }
        phase = .stopping
        owned.authority.retire()
        owned.subscription = nil
        owned.runtime.retire()
        owned.run?.cancel()
        if owned.cleanup == nil {
            owned.cleanup = Task { [owned] in
                await owned.run?.value
                let result: Result<Void, any Error>
                do { try await owned.runtime.closeAndAwait(); result = .success(()) }
                catch { result = .failure(error) }
                owned.cleanupResult = result
                return result
            }
        }
        observeCleanup(owned)
    }

    public func finishCleanup() {
        guard let owned = entry else { return }
        if let result = owned.cleanupResult, case .failure = result, !owned.runtime.cleanupConfirmed {
            // The old cleanup job actually returned. Retry only cleanup of the
            // same retained owner; never start another native generation here.
            owned.cleanup = nil; owned.cleanupResult = nil
        }
        stop()
    }

    func invalidateSupersededAttempt(_ attempts: [String: UUID]) {
        guard let owned = entry, [.preparing, .opening, .authenticating].contains(phase) else { return }
        guard let key = owned.runtime.attemptKey else { return }
        if attempts[key] != owned.authority.id { stop() }
    }

    func invalidateTrust(_ event: TrustInvalidationEvent) {
        guard let owned = entry,
              event.matches(protocolSigningAlgorithm: owned.peer.algorithm, protocolPublicKeyFingerprint: owned.peer.fingerprint) else { return }
        owned.primaryFailure = HandshakeConfigurationError.peerUntrusted
        failure = owned.primaryFailure
        stop()
    }

    func stopAndObserve() async {
        stop()
        await entry?.observer?.value
    }

    private func observeCleanup(_ owned: Entry) {
        guard owned.observer == nil else { return }
        owned.observer = Task { [weak self, owned, cleanupObservation] in
            defer { owned.observer = nil }
            let deadline = ContinuousClock.now.advanced(by: cleanupObservation)
            while owned.cleanupResult == nil {
                if ContinuousClock.now >= deadline {
                    if self?.entry === owned { self?.phase = .cleanupRequired }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch {
                    if self?.entry === owned { self?.phase = .cleanupRequired }
                    return
                }
            }
            // The receipt is set just before return. Join the actual task before
            // releasing admission, rather than treating its flag as task exit.
            guard let task = owned.cleanup else { return }
            let result = await task.value
            guard let self, self.entry === owned else { return }
            if case .failure(let cleanup) = result {
                self.failure = AndroidUSBPreparationCleanupFailure(primary: owned.primaryFailure ?? cleanup, cleanup: cleanup)
            }
            guard owned.runtime.cleanupConfirmed else {
                self.phase = .cleanupRequired
                return
            }
            self.entry = nil
            self.phase = self.failure == nil ? .idle : .failed
        }
    }
}
#endif
