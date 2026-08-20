import Foundation
import Network
import CryptoKit
import os
import SkyBridgeProtocolCore
#if canImport(Security)
import Security
#endif

@available(macOS 14.0, iOS 17.0, *)
enum P2PHandshakeOperationKind: Sendable, Equatable {
    case authentication
    case outboundRekey
    case inboundRekey
}

@available(macOS 14.0, iOS 17.0, *)
struct P2PHandshakeOperationToken: Sendable, Equatable {
    let connectionGeneration: UInt64
    let operationSequence: UInt64
    let kind: P2PHandshakeOperationKind
}

@available(macOS 14.0, iOS 17.0, *)
enum P2PHandshakeOperationBeginOutcome: Sendable, Equatable {
    case started(P2PHandshakeOperationToken)
    case operationInProgress
    case disconnected
    case sequenceExhausted
}

/// Linearizes ownership of every handshake driver used by one `P2PConnection`.
///
/// `P2PConnection` is deliberately `@unchecked Sendable`, and its async handshake
/// paths can resume after `disconnect()` or after a replacement rekey has started.
/// Keeping the connection generation, operation token and driver identity in one
/// lock-protected value gives each post-await publication a single exact witness.
@available(macOS 14.0, iOS 17.0, *)
struct P2PHandshakeOperationRegistry<Driver: AnyObject & Sendable>: Sendable {
    private struct ActiveOperation: Sendable {
        let token: P2PHandshakeOperationToken
        var driver: Driver?
    }

    private(set) var connectionGeneration: UInt64 = 1
    private var nextOperationSequence: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private(set) var isDisconnected = false
    private(set) var isOperationSequenceExhausted = false

    init() {}

    #if DEBUG || SKYBRIDGE_TESTING
    init(
        testingConnectionGeneration: UInt64,
        testingNextOperationSequence: UInt64
    ) {
        connectionGeneration = testingConnectionGeneration
        nextOperationSequence = testingNextOperationSequence
    }
    #endif

    mutating func begin(
        kind: P2PHandshakeOperationKind
    ) -> P2PHandshakeOperationBeginOutcome {
        guard !isDisconnected else { return .disconnected }
        guard !isOperationSequenceExhausted else { return .sequenceExhausted }
        guard activeOperation == nil else { return .operationInProgress }
        let increment = nextOperationSequence.addingReportingOverflow(1)
        guard !increment.overflow else {
            activeOperation = nil
            isOperationSequenceExhausted = true
            return .sequenceExhausted
        }
        nextOperationSequence = increment.partialValue
        let token = P2PHandshakeOperationToken(
            connectionGeneration: connectionGeneration,
            operationSequence: nextOperationSequence,
            kind: kind
        )
        activeOperation = ActiveOperation(token: token, driver: nil)
        return .started(token)
    }

    mutating func install(
        _ driver: Driver,
        for token: P2PHandshakeOperationToken
    ) -> (installed: Bool, displacedDriver: Driver?) {
        guard owns(token) else { return (false, nil) }
        let displacedDriver = activeOperation?.driver
        activeOperation?.driver = driver
        return (true, displacedDriver)
    }

    func owns(
        _ token: P2PHandshakeOperationToken,
        exactDriver: Driver? = nil
    ) -> Bool {
        guard !isDisconnected,
              token.connectionGeneration == connectionGeneration,
              let activeOperation,
              activeOperation.token == token else {
            return false
        }
        guard let exactDriver else { return true }
        return activeOperation.driver === exactDriver
    }

    func currentOwnedDriver() -> (token: P2PHandshakeOperationToken, driver: Driver)? {
        guard !isDisconnected,
              let activeOperation,
              let driver = activeOperation.driver else {
            return nil
        }
        return (activeOperation.token, driver)
    }

    mutating func detachDriverIfOwned(
        _ token: P2PHandshakeOperationToken,
        exactDriver: Driver? = nil
    ) -> Driver? {
        guard owns(token, exactDriver: exactDriver) else { return nil }
        let driver = activeOperation?.driver
        activeOperation?.driver = nil
        return driver
    }

    @discardableResult
    mutating func finish(
        _ token: P2PHandshakeOperationToken,
        exactDriver: Driver? = nil
    ) -> Bool {
        guard owns(token, exactDriver: exactDriver) else { return false }
        activeOperation = nil
        return true
    }

    func ownsConnectionGeneration(_ generation: UInt64) -> Bool {
        !isDisconnected && connectionGeneration == generation
    }

    mutating func disconnect() -> Driver? {
        guard !isDisconnected else { return nil }
        let driver = activeOperation?.driver
        activeOperation = nil
        isDisconnected = true
        let increment = connectionGeneration.addingReportingOverflow(1)
        connectionGeneration = increment.overflow ? .max : increment.partialValue
        return driver
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct P2PInboundFrameRoutingPolicy {
    enum DriverPhase: Sendable, Equatable {
        case absent
        case handshaking
        case established(sessionId: String)
    }

    enum Route: Sendable, Equatable {
        case handshakeDriver
        case authenticated(expectedSessionId: String?)
        case awaitSessionHandoff(sessionId: String)
        case restartInboundRekey
        case rejectNoOwner
        case rejectUnexpectedAuthenticatedHandshake
    }

    static func route(
        driverPhase: DriverPhase,
        publishedSessionId: String?,
        isHandshakeControl: Bool
    ) -> Route {
        switch driverPhase {
        case .established(let driverSessionId):
            if isHandshakeControl {
                return .rejectUnexpectedAuthenticatedHandshake
            }
            if publishedSessionId == driverSessionId {
                return .authenticated(expectedSessionId: driverSessionId)
            }
            return .awaitSessionHandoff(sessionId: driverSessionId)

        case .handshaking:
            if isHandshakeControl {
                return .handshakeDriver
            }
            if publishedSessionId != nil {
                return .authenticated(expectedSessionId: publishedSessionId)
            }
            return .rejectNoOwner

        case .absent:
            if isHandshakeControl {
                return publishedSessionId == nil
                    ? .rejectNoOwner
                    : .restartInboundRekey
            }
            return publishedSessionId.map {
                .authenticated(expectedSessionId: $0)
            } ?? .rejectNoOwner
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct P2PSessionHandoffKey: Sendable, Equatable {
    let operation: P2PHandshakeOperationToken
    let sessionId: String
}

@available(macOS 14.0, iOS 17.0, *)
enum P2PSessionHandoffError: Error, Sendable, Equatable {
    case invalidated
    case concurrentWaiter
    case duplicateContinuationInstallation
}

@available(macOS 14.0, iOS 17.0, *)
final class P2PSessionHandoffOperation: @unchecked Sendable {
    private enum State {
        case awaitingInstallation
        case installed(CheckedContinuation<Void, Error>)
        case completedPending(Result<Void, Error>)
        case consumed
    }

    private let lock = NSLock()
    private var state: State = .awaitingInstallation

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let result = lock.withLock { () -> Result<Void, Error>? in
            switch state {
            case .awaitingInstallation:
                state = .installed(continuation)
                return nil
            case .completedPending(let pendingResult):
                state = .consumed
                return pendingResult
            case .installed, .consumed:
                return .failure(
                    P2PSessionHandoffError.duplicateContinuationInstallation
                )
            }
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func succeed() {
        finish(with: .success(()))
    }

    func fail(_ error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            switch state {
            case .awaitingInstallation:
                state = .completedPending(result)
                return nil
            case .installed(let continuation):
                state = .consumed
                return continuation
            case .completedPending, .consumed:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

@available(macOS 14.0, iOS 17.0, *)
private final class P2PSessionHandoffGate: @unchecked Sendable {
    private struct PendingWaiter {
        let key: P2PSessionHandoffKey
        let operation: P2PSessionHandoffOperation
    }

    private struct State {
        var publishedKey: P2PSessionHandoffKey?
        var pendingWaiter: PendingWaiter?
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: State(publishedKey: nil, pendingWaiter: nil)
    )

    func wait(for key: P2PSessionHandoffKey) async throws {
        let operation = P2PSessionHandoffOperation()
        let admission = lock.withLock { state -> Result<Bool, P2PSessionHandoffError> in
            if state.publishedKey == key {
                return .success(false)
            }
            guard state.pendingWaiter == nil else {
                return .failure(.concurrentWaiter)
            }
            state.pendingWaiter = PendingWaiter(key: key, operation: operation)
            return .success(true)
        }
        let shouldWait = try admission.get()
        guard shouldWait else { return }

        defer { removeWaiterIfOwned(operation) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
            }
        } onCancel: {
            operation.fail(CancellationError())
        }
    }

    func publish(_ key: P2PSessionHandoffKey) {
        let waiter = lock.withLock { state -> P2PSessionHandoffOperation? in
            state.publishedKey = key
            guard let pendingWaiter = state.pendingWaiter,
                  pendingWaiter.key == key else {
                return nil
            }
            state.pendingWaiter = nil
            return pendingWaiter.operation
        }
        waiter?.succeed()
    }

    func invalidate(operation token: P2PHandshakeOperationToken) {
        let waiter = lock.withLock { state -> P2PSessionHandoffOperation? in
            if state.publishedKey?.operation == token {
                state.publishedKey = nil
            }
            guard let pendingWaiter = state.pendingWaiter,
                  pendingWaiter.key.operation == token else {
                return nil
            }
            state.pendingWaiter = nil
            return pendingWaiter.operation
        }
        waiter?.fail(P2PSessionHandoffError.invalidated)
    }

    func invalidateAll() {
        let waiter = lock.withLock { state -> P2PSessionHandoffOperation? in
            state.publishedKey = nil
            let operation = state.pendingWaiter?.operation
            state.pendingWaiter = nil
            return operation
        }
        waiter?.fail(P2PSessionHandoffError.invalidated)
    }

    private func removeWaiterIfOwned(_ operation: P2PSessionHandoffOperation) {
        lock.withLock { state in
            guard state.pendingWaiter?.operation === operation else { return }
            state.pendingWaiter = nil
        }
    }
}

// MARK: - P2P连接
public final class P2PConnection: ObservableObject, Identifiable, @unchecked Sendable {
    private static let protocolIdentityLogRedaction = "<redacted>"

    public let id = UUID()
    public let device: P2PDevice
    public let connection: NWConnection

    @Published public private(set) var status: P2PConnectionStatus = .connecting
    @Published public private(set) var lastActivity: Date = Date()
    @Published public private(set) var bytesReceived: UInt64 = 0
    @Published public private(set) var bytesSent: UInt64 = 0
    @available(macOS 14.0, iOS 17.0, *)
    @Published public private(set) var assuranceLevel: P2PSessionAssuranceLevel = .unknown

    // Real, continuously updated quality signals (no simulated constants).
    @Published public private(set) var measuredLatency: TimeInterval = 0
    @Published public private(set) var measuredPacketLoss: Double = 0
    @Published public private(set) var measuredBandwidthBytesPerSecond: Double = 0

    // Handshake / session state (paper-aligned).
    @available(macOS 14.0, iOS 17.0, *)
    private let handshakeOperationLock = OSAllocatedUnfairLock(
        initialState: P2PHandshakeOperationRegistry<HandshakeDriver>()
    )
    @available(macOS 14.0, iOS 17.0, *)
    private let sessionKeysLock = OSAllocatedUnfairLock<SessionKeys?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let remoteDesktopFrameHandlerLock = OSAllocatedUnfairLock<(@Sendable (Data, UInt64) -> Void)?>(initialState: nil)
    private let handshakePeerLock: OSAllocatedUnfairLock<PeerIdentifier>
    private var handshakePeer: PeerIdentifier {
        get { handshakePeerLock.withLock { $0 } }
        set { handshakePeerLock.withLock { $0 = newValue } }
    }
    private var handshakePeerDiagnosticLabel: String {
        SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakePeer.deviceId)
    }
    private var deviceDiagnosticLabel: String {
        SkyBridgeDiagnosticRedaction.stableIdentifierLabel(device.deviceId)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct MetricsState: Sendable {
        var lastTotalBytes: UInt64 = 0
        var lastBandwidthSampleAt: ContinuousClock.Instant?

        var lastPingSentAt: ContinuousClock.Instant?
        var outstandingPing: (id: UInt64, sentAt: ContinuousClock.Instant)?
        var pingResults: [Bool] = []  // true=success, false=timeout
    }

    @available(macOS 14.0, iOS 17.0, *)
    private let metricsLock = OSAllocatedUnfairLock(initialState: MetricsState())
    private struct MetricsTaskOwner: Sendable {
        let token: UUID
        var task: Task<Void, Never>?
    }
    private let metricsTaskOwnerLock = OSAllocatedUnfairLock<MetricsTaskOwner?>(
        initialState: nil
    )
    @available(macOS 14.0, iOS 17.0, *)
    private let rekeyInProgressLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    @available(macOS 14.0, iOS 17.0, *)
    private let bootstrapAssistedHandshakeLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    @available(macOS 14.0, iOS 17.0, *)
    private let lastPairingIdentityExchangeSentAtLock = OSAllocatedUnfairLock<Date?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let latestRemotePairingIdentityPayloadLock = OSAllocatedUnfairLock<AppMessage.PairingIdentityExchangePayload?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let soaPairKeyLock = OSAllocatedUnfairLock<Data?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let establishedArbiterLeaseLock = OSAllocatedUnfairLock<PeerSessionArbiter.EstablishedLease?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let presenceLeaseLock = OSAllocatedUnfairLock<ConnectionPresenceService.PresenceLease?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let classicTransferSessionLeasesLock = OSAllocatedUnfairLock<[String: ClassicTransferSessionRegistry.SessionLease]>(initialState: [:])
    @available(macOS 14.0, iOS 17.0, *)
    private let classicTransferConnectionLeaseLock = OSAllocatedUnfairLock<ClassicTransferSessionRegistry.ConnectionLease?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let authenticatedRemoteAuthorityLock = OSAllocatedUnfairLock<AuthenticatedRemoteAuthority?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let authenticatedHandshakePeerBindingLock = OSAllocatedUnfairLock<AuthenticatedHandshakePeerBinding?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private struct OwnedHandshakeDriver: Sendable {
        let token: P2PHandshakeOperationToken
        let driver: HandshakeDriver
    }
    private struct InboundReceiveLease: Sendable {
        let id: UUID
        let connectionGeneration: UInt64
        let peer: PeerIdentifier
        let task: Task<Void, Never>
    }
    @available(macOS 14.0, iOS 17.0, *)
    private struct EstablishedHandshakeReceipt: Sendable {
        let owner: OwnedHandshakeDriver
        let keys: SessionKeys
        let peerBinding: AuthenticatedHandshakePeerBinding
        let soaPairKey: Data?
        let arbiterLease: PeerSessionArbiter.EstablishedLease?
        var connectivityAttemptOwner: ProductConnectivityAttemptOwner? = nil
    }
    @available(macOS 14.0, iOS 17.0, *)
    private struct EstablishedSessionSnapshot: Sendable {
        let keys: SessionKeys
        let peerBinding: AuthenticatedHandshakePeerBinding
        let soaPairKey: Data?
        let arbiterLease: PeerSessionArbiter.EstablishedLease?
        let assuranceLevel: P2PSessionAssuranceLevel
    }
    @available(macOS 14.0, iOS 17.0, *)
    private struct AuthenticatedMessageSendWitness: Sendable {
        let connectionGeneration: UInt64
        let keys: SessionKeys
        let peerBinding: AuthenticatedHandshakePeerBinding
    }
    @available(macOS 14.0, iOS 17.0, *)
    private struct InboundRekeyRollbackReceipt: Sendable {
        let owner: OwnedHandshakeDriver
        let previousSession: EstablishedSessionSnapshot
    }
    @available(macOS 14.0, iOS 17.0, *)
    private let inboundRekeyRollbackLock = OSAllocatedUnfairLock<InboundRekeyRollbackReceipt?>(initialState: nil)
    private let receiveLeaseLock = OSAllocatedUnfairLock<InboundReceiveLease?>(initialState: nil)
    private let sessionHandoffGate = P2PSessionHandoffGate()

    @available(macOS 14.0, iOS 17.0, *)
    private struct DirectHandshakeTransport: DiscoveryTransport {
        let sendFramed: @Sendable (Data) async throws -> Void

        func send(to peer: PeerIdentifier, data: Data) async throws {
            try await sendFramed(data)
        }
    }

    public init(device: P2PDevice, connection: NWConnection) {
        self.device = device
        self.connection = connection
        self.handshakePeerLock = OSAllocatedUnfairLock(
            initialState: PeerIdentifier(
                deviceId: device.deviceId,
                displayName: device.name,
                address: "\(device.address):\(device.port)"
            )
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func beginHandshakeOperation(
        kind: P2PHandshakeOperationKind
    ) async throws -> P2PHandshakeOperationToken {
        let outcome = handshakeOperationLock.withLock {
            $0.begin(kind: kind)
        }
        switch outcome {
        case .started(let token):
            return token
        case .operationInProgress:
            throw P2PConnectionError.handshakeOperationInProgress
        case .disconnected:
            throw P2PConnectionError.disconnected
        case .sequenceExhausted:
            throw P2PConnectionError.handshakeOperationSequenceExhausted
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func installHandshakeDriver(
        _ driver: HandshakeDriver,
        for token: P2PHandshakeOperationToken
    ) async throws -> OwnedHandshakeDriver {
        let result = handshakeOperationLock.withLock { $0.install(driver, for: token) }
        guard result.installed else {
            await driver.cancel()
            throw P2PConnectionError.staleHandshakeOperation
        }
        if let displacedDriver = result.displacedDriver,
           displacedDriver !== driver {
            await displacedDriver.cancel()
            try requireCurrentHandshakeOperation(token, exactDriver: driver)
        }
        return OwnedHandshakeDriver(token: token, driver: driver)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func requireCurrentHandshakeOperation(
        _ token: P2PHandshakeOperationToken,
        exactDriver: HandshakeDriver? = nil
    ) throws {
        guard handshakeOperationLock.withLock({
            $0.owns(token, exactDriver: exactDriver)
        }) else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func currentOwnedHandshakeDriver() -> OwnedHandshakeDriver? {
        handshakeOperationLock.withLock { registry in
            registry.currentOwnedDriver().map {
                OwnedHandshakeDriver(token: $0.token, driver: $0.driver)
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func detachAndCancelDriverIfOwned(
        _ owner: OwnedHandshakeDriver
    ) async {
        let driver = handshakeOperationLock.withLock {
            $0.detachDriverIfOwned(owner.token, exactDriver: owner.driver)
        }
        await driver?.cancel()
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func finishHandshakeOperation(
        _ owner: OwnedHandshakeDriver
    ) -> Bool {
        handshakeOperationLock.withLock { registry in
            guard registry.owns(owner.token, exactDriver: owner.driver) else {
                return false
            }
            rekeyInProgressLock.withLock { $0 = false }
            return registry.finish(owner.token, exactDriver: owner.driver)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishStatus(
        _ newStatus: P2PConnectionStatus,
        for token: P2PHandshakeOperationToken,
        exactDriver: HandshakeDriver? = nil
    ) async throws {
        let statusRawValue = newStatus.rawValue
        let published = await MainActor.run {
            self.handshakeOperationLock.withLock { registry in
                guard registry.owns(token, exactDriver: exactDriver) else {
                    return false
                }
                guard let status = P2PConnectionStatus(rawValue: statusRawValue) else {
                    return false
                }
                self.status = status
                return true
            }
        }
        guard published else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishAssuranceLevel(
        _ newAssuranceLevel: P2PSessionAssuranceLevel,
        for token: P2PHandshakeOperationToken,
        exactDriver: HandshakeDriver? = nil
    ) async throws {
        let rawValue = newAssuranceLevel.rawValue
        let published = await MainActor.run {
            self.handshakeOperationLock.withLock { registry in
                guard registry.owns(token, exactDriver: exactDriver),
                      let assuranceLevel = P2PSessionAssuranceLevel(rawValue: rawValue) else {
                    return false
                }
                self.assuranceLevel = assuranceLevel
                return true
            }
        }
        guard published else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func currentEstablishedSessionSnapshot(
        for token: P2PHandshakeOperationToken
    ) async throws -> EstablishedSessionSnapshot? {
        let currentAssuranceLevel = await MainActor.run { self.assuranceLevel }
        return try handshakeOperationLock.withLock {
            registry -> EstablishedSessionSnapshot? in
            guard registry.owns(token) else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            guard let keys = sessionKeysLock.withLock({ $0 }) else { return nil }
            guard let peerBinding = authenticatedHandshakePeerBindingLock.withLock({ $0 }) else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            return EstablishedSessionSnapshot(
                keys: keys,
                peerBinding: peerBinding,
                soaPairKey: soaPairKeyLock.withLock { $0 },
                arbiterLease: establishedArbiterLeaseLock.withLock { $0 },
                assuranceLevel: currentAssuranceLevel
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishEstablishedSession(
        _ receipt: EstablishedHandshakeReceipt
    ) throws {
        let published = handshakeOperationLock.withLock { registry -> Bool in
            guard registry.owns(
                receipt.owner.token,
                exactDriver: receipt.owner.driver
            ) else {
                return false
            }
            sessionKeysLock.withLock { $0 = receipt.keys }
            authenticatedHandshakePeerBindingLock.withLock { $0 = receipt.peerBinding }
            authenticatedRemoteAuthorityLock.withLock { $0 = receipt.peerBinding.authority }
            soaPairKeyLock.withLock { $0 = receipt.soaPairKey }
            establishedArbiterLeaseLock.withLock { $0 = receipt.arbiterLease }
            sessionHandoffGate.publish(P2PSessionHandoffKey(
                operation: receipt.owner.token,
                sessionId: receipt.keys.sessionId
            ))
            return true
        }
        guard published else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func restoreReleasedArbiterLease(
        _ lease: PeerSessionArbiter.EstablishedLease,
        for token: P2PHandshakeOperationToken
    ) async throws {
        try requireCurrentHandshakeOperation(token)
        if establishedArbiterLeaseLock.withLock({ $0 }) == lease {
            return
        }
        guard await PeerSessionArbiter.shared.restoreEstablishedIfVacant(lease) else {
            try requireCurrentHandshakeOperation(token)
            throw P2PConnectionError.arbiterLeaseUnavailable
        }
        let adopted = handshakeOperationLock.withLock { registry -> Bool in
            guard registry.owns(token) else { return false }
            establishedArbiterLeaseLock.withLock { $0 = lease }
            return true
        }
        guard adopted else {
            _ = await PeerSessionArbiter.shared.clearEstablished(lease)
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    /// Reconciles the actor-owned established slot before local session state is
    /// rolled back. A newly committed lease must be removed by its exact lease
    /// capability before an older lease can be restored into the same pair.
    /// Pair-key-only teardown is intentionally forbidden because it can delete
    /// a replacement connection's reservation or session after an actor hop.
    @available(macOS 14.0, iOS 17.0, *)
    private func rollbackPublishedArbiterLease(
        to previousLease: PeerSessionArbiter.EstablishedLease?,
        for token: P2PHandshakeOperationToken
    ) async throws {
        let publishedLease = try handshakeOperationLock.withLock {
            registry -> PeerSessionArbiter.EstablishedLease? in
            guard registry.owns(token) else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            return establishedArbiterLeaseLock.withLock { $0 }
        }
        guard publishedLease != previousLease else { return }

        if let publishedLease {
            _ = await PeerSessionArbiter.shared.clearEstablished(publishedLease)
            try requireCurrentHandshakeOperation(token)
            let detached = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(token) else { return false }
                return establishedArbiterLeaseLock.withLock { state in
                    guard state == publishedLease else { return false }
                    state = nil
                    return true
                }
            }
            guard detached else {
                throw P2PConnectionError.staleHandshakeOperation
            }
        }

        if let previousLease {
            try await restoreReleasedArbiterLease(previousLease, for: token)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func failHandshakeOperation(
        _ token: P2PHandshakeOperationToken,
        restoring previousSession: EstablishedSessionSnapshot?,
        terminalStatus: P2PConnectionStatus
    ) async throws {
        let ownsOperation = handshakeOperationLock.withLock { registry -> Bool in
            guard registry.owns(token) else { return false }
            sessionHandoffGate.invalidate(operation: token)
            return true
        }
        guard ownsOperation else { return }
        let publishedClassicSessionId = try handshakeOperationLock.withLock {
            registry -> String? in
            guard registry.owns(token) else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            guard let publishedKeys = sessionKeysLock.withLock({ $0 }),
                  publishedKeys.sessionId != previousSession?.keys.sessionId else {
                return nil
            }
            return classicTransferSessionIdentifier(for: publishedKeys)
        }
        if let owner = currentOwnedHandshakeDriver(), owner.token == token {
            await detachAndCancelDriverIfOwned(owner)
        }
        try requireCurrentHandshakeOperation(token)

        if let publishedClassicSessionId {
            await removeClassicTransferSessionLease(sessionId: publishedClassicSessionId)
            try requireCurrentHandshakeOperation(token)
        }

        do {
            try await rollbackPublishedArbiterLease(
                to: previousSession?.arbiterLease,
                for: token
            )
        } catch {
            let restorationError = error
            await clearPublishedSession(for: token)
            if handshakeOperationLock.withLock({ $0.owns(token) }) {
                inboundRekeyRollbackLock.withLock { $0 = nil }
                rekeyInProgressLock.withLock { $0 = false }
                try await publishStatus(.failed, for: token)
                _ = handshakeOperationLock.withLock { $0.finish(token) }
            }
            throw restorationError
        }

        let restored = handshakeOperationLock.withLock { registry -> Bool in
            guard registry.owns(token) else { return false }
            if let previousSession {
                sessionKeysLock.withLock { $0 = previousSession.keys }
                authenticatedHandshakePeerBindingLock.withLock {
                    $0 = previousSession.peerBinding
                }
                authenticatedRemoteAuthorityLock.withLock {
                    $0 = previousSession.peerBinding.authority
                }
                soaPairKeyLock.withLock { $0 = previousSession.soaPairKey }
                establishedArbiterLeaseLock.withLock {
                    $0 = previousSession.arbiterLease
                }
            } else {
                sessionKeysLock.withLock { $0 = nil }
                authenticatedHandshakePeerBindingLock.withLock { $0 = nil }
                authenticatedRemoteAuthorityLock.withLock { $0 = nil }
                soaPairKeyLock.withLock { $0 = nil }
                establishedArbiterLeaseLock.withLock { $0 = nil }
                latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
            }
            inboundRekeyRollbackLock.withLock { $0 = nil }
            rekeyInProgressLock.withLock { $0 = false }
            return true
        }
        guard restored else { return }
        try await publishAssuranceLevel(
            previousSession?.assuranceLevel ?? .unknown,
            for: token
        )
        try await publishStatus(terminalStatus, for: token)
        _ = handshakeOperationLock.withLock { $0.finish(token) }

        if previousSession == nil {
            let connectionLease = classicTransferConnectionLeaseLock.withLock { state in
                let current = state
                state = nil
                return current
            }
            if let connectionLease {
                _ = await ClassicTransferSessionRegistry.shared.remove(
                    ifOwned: connectionLease
                )
            }
            await removeAllClassicTransferSessionLeases()
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func clearPublishedSession(
        for token: P2PHandshakeOperationToken
    ) async {
        let lease = handshakeOperationLock.withLock {
            registry -> PeerSessionArbiter.EstablishedLease? in
            guard registry.owns(token) else { return nil }
            sessionHandoffGate.invalidate(operation: token)
            sessionKeysLock.withLock { $0 = nil }
            authenticatedRemoteAuthorityLock.withLock { $0 = nil }
            authenticatedHandshakePeerBindingLock.withLock { $0 = nil }
            soaPairKeyLock.withLock { $0 = nil }
            return establishedArbiterLeaseLock.withLock { state in
                let current = state
                state = nil
                return current
            }
        }
        if let lease {
            _ = await PeerSessionArbiter.shared.clearEstablished(lease)
        }
    }

    deinit {
        disconnect()
    }

    private func resolveCurrentRemoteIP() -> String? {
        // Try active path first (most reliable)
        if let endpoint = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let ipv4): return "\(ipv4)"
            case .ipv6(let ipv6): return "\(ipv6)"
            case .name(let name, _): return name
            default: break
            }
        }
        
        // Fallback to initial endpoint
        if case .hostPort(let host, _) = connection.endpoint {
             switch host {
             case .ipv4(let ipv4): return "\(ipv4)"
             case .ipv6(let ipv6): return "\(ipv6)"
             case .name(let name, _): return name
             default: break
             }
        }
        return nil
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferEndpointHostOrIP() -> String? {
        resolveCurrentRemoteIP() ?? normalizedNonEmptyString(device.address)
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferMatchDeviceId(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> String {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        return normalizedNonEmptyString(payload?.deviceId)
            ?? normalizedNonEmptyString(handshakePeer.deviceId)
            ?? normalizedNonEmptyString(device.persistentDeviceId)
            ?? normalizedNonEmptyString(device.deviceId)
            ?? device.deviceId
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferResolvedPeerDeviceId(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> String {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let preferred = [
            normalizedNonEmptyString(payload?.deviceId),
            normalizedNonEmptyString(device.persistentDeviceId),
            normalizedNonEmptyString(handshakePeer.deviceId),
            normalizedNonEmptyString(device.deviceId)
        ]

        for candidate in preferred {
            if let persistent = PeerTrustLookup.persistentDeviceId(from: candidate) {
                return persistent
            }
        }

        return preferred.compactMap { $0 }.first ?? device.deviceId
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferPeerLookupAliases(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> [String] {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let endpoint = classicTransferEndpointHostOrIP()
        let rawAliases: [String?] = [
            payload?.deviceId,
            payload?.deviceName,
            device.persistentDeviceId,
            handshakePeer.deviceId,
            device.deviceId,
            device.name,
            device.address,
            endpoint
        ] + device.endpoints.map(Optional.some)

        var aliases: [String] = []
        var seen = Set<String>()
        for raw in rawAliases {
            guard let raw = normalizedNonEmptyString(raw) else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                aliases.append(trimmed)
            }
        }
        return aliases
    }

    @available(macOS 14.0, iOS 17.0, *)
    func matchesTrustInvalidation(_ event: TrustInvalidationEvent) -> Bool {
        guard let authority = authenticatedRemoteAuthorityLock.withLock({ $0 }) else {
            return false
        }
        return event.matches(authority: authority)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func recordRemoteControlSecurityIdentity(
        from payload: AppMessage.PairingIdentityExchangePayload,
        validatedAuthority: ValidatedPairingIdentityAuthority
    ) {
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: payload.accountDisplayName,
            nebulaId: payload.nebulaId,
            deviceId: validatedAuthority.declaredDeviceId,
            deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
        )
        guard !identity.isEmpty else { return }

        let aliases = validatedAuthority.authorizedDeviceIds + [
            LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
            LocalDevicePresentation.sanitizedDisplayNameCandidate(handshakePeer.displayName),
            handshakePeer.address,
            device.name,
            device.address,
            classicTransferEndpointHostOrIP()
        ].compactMap { $0 }
        RemoteControlSecurityPeerIdentityStore.record(identity: identity, aliases: aliases)
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferCapabilities(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> [String] {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        var values = device.capabilities
        values.append(contentsOf: payload?.capabilities ?? [])
        if let port = payload?.fileTransferPort, (1...65535).contains(Int(port)) {
            values.append("fileTransferPort=\(port)")
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            deduped.append(trimmed)
        }
        return deduped
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishClassicTransferSessionSnapshot(
        keys: SessionKeys,
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil,
        operationOwner: OwnedHandshakeDriver? = nil
    ) async throws {
        if let operationOwner {
            try requireCurrentHandshakeOperation(
                operationOwner.token,
                exactDriver: operationOwner.driver
            )
        }
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let aliases = classicTransferPeerLookupAliases(remoteIdentityPayload: payload)
        let endpoint = classicTransferEndpointHostOrIP()
        let snapshot = ClassicTransferSessionSnapshot(
            sessionId: classicTransferSessionIdentifier(for: keys),
            matchDeviceId: classicTransferMatchDeviceId(remoteIdentityPayload: payload),
            resolvedPeerDeviceId: classicTransferResolvedPeerDeviceId(remoteIdentityPayload: payload),
            aliases: aliases,
            endpointHostOrIP: endpoint,
            capabilities: classicTransferCapabilities(remoteIdentityPayload: payload),
            sessionKeys: keys
        )

        let activeSessionLease: ClassicTransferSessionRegistry.SessionLease
        if let existingLease = classicTransferSessionLeasesLock.withLock({
            $0[snapshot.sessionId]
        }) {
            guard await ClassicTransferSessionRegistry.shared
                .updateAuthenticatedSessionIfOwned(existingLease, snapshot: snapshot) else {
                classicTransferSessionLeasesLock.withLock { leases in
                    guard leases[snapshot.sessionId] == existingLease else { return }
                    leases.removeValue(forKey: snapshot.sessionId)
                }
                throw P2PConnectionError.classicTransferSessionLeaseUnavailable
            }
            activeSessionLease = existingLease
        } else {
            let newLease = await ClassicTransferSessionRegistry.shared.upsertOwned(
                session: snapshot
            )
            if let operationOwner {
                do {
                    try requireCurrentHandshakeOperation(
                        operationOwner.token,
                        exactDriver: operationOwner.driver
                    )
                } catch {
                    _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: newLease)
                    throw error
                }
            }
            classicTransferSessionLeasesLock.withLock {
                $0[snapshot.sessionId] = newLease
            }
            guard await ClassicTransferSessionRegistry.shared
                .updateAuthenticatedSessionIfOwned(newLease, snapshot: snapshot) else {
                classicTransferSessionLeasesLock.withLock { leases in
                    guard leases[snapshot.sessionId] == newLease else { return }
                    leases.removeValue(forKey: snapshot.sessionId)
                }
                throw P2PConnectionError.classicTransferSessionLeaseUnavailable
            }
            activeSessionLease = newLease
        }
        if let operationOwner {
            try requireCurrentHandshakeOperation(
                operationOwner.token,
                exactDriver: operationOwner.driver
            )
        }
        guard classicTransferSessionLeasesLock.withLock({
            $0[snapshot.sessionId] == activeSessionLease
        }) else {
            throw P2PConnectionError.classicTransferSessionLeaseUnavailable
        }
        try await publishClassicTransferConnection(
            peerKeys: [snapshot.matchDeviceId, snapshot.resolvedPeerDeviceId]
                + aliases + [endpoint].compactMap { $0 },
            operationOwner: operationOwner
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishClassicTransferConnection(
        peerKeys: [String],
        operationOwner: OwnedHandshakeDriver?
    ) async throws {
        if let operationOwner {
            try requireCurrentHandshakeOperation(
                operationOwner.token,
                exactDriver: operationOwner.driver
            )
        }
        let newLease = await ClassicTransferSessionRegistry.shared.upsertOwned(
            connection: self,
            peerKeys: peerKeys
        )
        if let operationOwner {
            do {
                try requireCurrentHandshakeOperation(
                    operationOwner.token,
                    exactDriver: operationOwner.driver
                )
            } catch {
                _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: newLease)
                throw error
            }
        }
        let previousLease = classicTransferConnectionLeaseLock.withLock { state in
            let previous = state
            state = newLease
            return previous
        }
        if let previousLease {
            _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: previousLease)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func classicTransferSessionIdentifier(for keys: SessionKeys) -> String {
        "p2p-\(id.uuidString)-\(keys.sessionId)"
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func refreshClassicTransferSessionFromHeartbeat(
        _ payload: AppMessage.HeartbeatPayload,
        keys: SessionKeys
    ) async throws {
        let sessionId = classicTransferSessionIdentifier(for: keys)
        guard let lease = classicTransferSessionLeasesLock.withLock({ $0[sessionId] }) else {
            throw P2PConnectionError.classicTransferSessionLeaseUnavailable
        }
        guard await ClassicTransferSessionRegistry.shared.refreshIfOwned(
                lease,
                capabilities: payload.capabilities,
                fileTransferPort: payload.fileTransferPort,
                remoteControlPort: payload.remoteControlPort
              ) else {
            classicTransferSessionLeasesLock.withLock { leases in
                guard leases[sessionId] == lease else { return }
                leases.removeValue(forKey: sessionId)
            }
            throw P2PConnectionError.classicTransferSessionLeaseUnavailable
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func removeClassicTransferSessionLease(sessionId: String) async {
        let lease = classicTransferSessionLeasesLock.withLock {
            $0.removeValue(forKey: sessionId)
        }
        if let lease {
            _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: lease)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func removeAllClassicTransferSessionLeases() async {
        let leases = classicTransferSessionLeasesLock.withLock { state -> [ClassicTransferSessionRegistry.SessionLease] in
            let current = Array(state.values)
            state.removeAll()
            return current
        }
        for lease in leases {
            _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: lease)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func retireClassicTransferSessionLeases(except sessionId: String) async {
        let retired = classicTransferSessionLeasesLock.withLock { state -> [ClassicTransferSessionRegistry.SessionLease] in
            let leases = state.compactMap { key, lease in key == sessionId ? nil : lease }
            state = state.filter { $0.key == sessionId }
            return leases
        }
        for lease in retired {
            _ = await ClassicTransferSessionRegistry.shared.remove(ifOwned: lease)
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    @available(macOS 14.0, iOS 17.0, *)
    func testingRollbackPublishedArbiterLease(
        currentLease: PeerSessionArbiter.EstablishedLease?,
        to previousLease: PeerSessionArbiter.EstablishedLease?
    ) async throws -> PeerSessionArbiter.EstablishedLease? {
        let operation = try await beginHandshakeOperation(kind: .outboundRekey)
        let staged = handshakeOperationLock.withLock { registry -> Bool in
            guard registry.owns(operation) else { return false }
            establishedArbiterLeaseLock.withLock { $0 = currentLease }
            return true
        }
        guard staged else {
            throw P2PConnectionError.staleHandshakeOperation
        }

        do {
            try await rollbackPublishedArbiterLease(
                to: previousLease,
                for: operation
            )
            let localLease = establishedArbiterLeaseLock.withLock { state in
                let current = state
                state = nil
                return current
            }
            _ = handshakeOperationLock.withLock { $0.finish(operation) }
            return localLease
        } catch {
            establishedArbiterLeaseLock.withLock { $0 = nil }
            _ = handshakeOperationLock.withLock { $0.finish(operation) }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testingSetClassicTransferRemoteIdentity(
        deviceId: String,
        fileTransferPort: UInt16? = nil,
        capabilities: [String]? = nil
    ) {
        latestRemotePairingIdentityPayloadLock.withLock {
            $0 = AppMessage.PairingIdentityExchangePayload(
                deviceId: deviceId,
                kemPublicKeys: [],
                capabilities: capabilities,
                fileTransferPort: fileTransferPort
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testingSetHandshakePeerDeviceId(_ deviceId: String) {
        handshakePeer = PeerIdentifier(
            deviceId: deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )
    }
    #endif

    // MARK: - Lifecycle

    func markTransportReady() {
        lastActivity = Date()
    }

    public func markConnectedAndStartReceiving() {
        guard receiveLeaseLock.withLock({ $0 != nil }) else {
            SkyBridgeLogger.p2p.error(
                "Refusing to publish a connected P2P state without an owner-bound receive loop"
            )
            status = .failed
            return
        }
        status = .connected
        lastActivity = Date()
    }

    /// Compatibility hook retained for callers that prepare a connection before
    /// `authenticate()`. Receiving is deliberately activated only after that
    /// method installs an exact operation-owned handshake driver.
    @available(*, deprecated, message: "authenticate() now owns safe receive-loop activation")
    public func startReceivingForHandshake() {
        lastActivity = Date()
    }

    public func markFailed() {
        status = .failed
    }

    public func disconnect() {
        let receiveTask = receiveLeaseLock.withLock { state -> Task<Void, Never>? in
            let current = state?.task
            state = nil
            return current
        }
        receiveTask?.cancel()
        let metricsTask = metricsTaskOwnerLock.withLock { owner -> Task<Void, Never>? in
            let task = owner?.task
            owner = nil
            return task
        }
        metricsTask?.cancel()

        if #available(macOS 14.0, iOS 17.0, *) {
            let peerIds = Array(
                Set(([handshakePeer.deviceId] + classicTransferPeerLookupAliases())
                    .compactMap { normalizedNonEmptyString($0) })
            )
            let displayName = device.name
            let teardown = handshakeOperationLock.withLock { registry -> (
                driver: HandshakeDriver?,
                arbiterLease: PeerSessionArbiter.EstablishedLease?,
                presenceLease: ConnectionPresenceService.PresenceLease?,
                classicTransferSessionLeases: [ClassicTransferSessionRegistry.SessionLease],
                classicTransferConnectionLease: ClassicTransferSessionRegistry.ConnectionLease?
            ) in
                let driver = registry.disconnect()
                sessionHandoffGate.invalidateAll()
                sessionKeysLock.withLock { $0 = nil }
                authenticatedRemoteAuthorityLock.withLock { $0 = nil }
                authenticatedHandshakePeerBindingLock.withLock { $0 = nil }
                inboundRekeyRollbackLock.withLock { $0 = nil }
                soaPairKeyLock.withLock { $0 = nil }
                let arbiterLease = establishedArbiterLeaseLock.withLock {
                    state -> PeerSessionArbiter.EstablishedLease? in
                    let current = state
                    state = nil
                    return current
                }
                let presenceLease = presenceLeaseLock.withLock {
                    state -> ConnectionPresenceService.PresenceLease? in
                    let current = state
                    state = nil
                    return current
                }
                let classicTransferSessionLeases = classicTransferSessionLeasesLock.withLock {
                    state -> [ClassicTransferSessionRegistry.SessionLease] in
                    let current = Array(state.values)
                    state.removeAll()
                    return current
                }
                let classicTransferConnectionLease = classicTransferConnectionLeaseLock.withLock {
                    state -> ClassicTransferSessionRegistry.ConnectionLease? in
                    let current = state
                    state = nil
                    return current
                }
                return (
                    driver,
                    arbiterLease,
                    presenceLease,
                    classicTransferSessionLeases,
                    classicTransferConnectionLease
                )
            }
            lastPairingIdentityExchangeSentAtLock.withLock { $0 = nil }
            latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
            metricsLock.withLock { state in
                state.lastBandwidthSampleAt = nil
                state.lastPingSentAt = nil
                state.outstandingPing = nil
                state.pingResults.removeAll()
            }
            rekeyInProgressLock.withLock { $0 = false }
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            if teardown.driver != nil || teardown.arbiterLease != nil {
                Task {
                    await teardown.driver?.cancel()
                    if let arbiterLease = teardown.arbiterLease {
                        _ = await PeerSessionArbiter.shared.clearEstablished(arbiterLease)
                    }
                }
            }
            Task {
                for sessionLease in teardown.classicTransferSessionLeases {
                    _ = await ClassicTransferSessionRegistry.shared.remove(
                        ifOwned: sessionLease
                    )
                }
                if let connectionLease = teardown.classicTransferConnectionLease {
                    _ = await ClassicTransferSessionRegistry.shared.remove(
                        ifOwned: connectionLease
                    )
                }
                if let presenceLease = teardown.presenceLease {
                    let didDisconnectPresence = await MainActor.run {
                        ConnectionPresenceService.shared.disconnectIfOwned(presenceLease)
                    }
                    if didDisconnectPresence {
                        await MainActor.run {
                            #if os(macOS)
                            // UI presence may be lowered only by the exact session owner.
                            for peerId in peerIds {
                                UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected(
                                    peerId: peerId,
                                    displayName: displayName
                                )
                            }
                            #endif
                        }
                    }
                }
            }
        }
        connection.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = .disconnected
            self.measuredLatency = 0
            self.measuredPacketLoss = 0
            self.measuredBandwidthBytesPerSecond = 0
            if #available(macOS 14.0, iOS 17.0, *) {
                self.assuranceLevel = .unknown
            }
        }
    }

    // MARK: - Authentication (HandshakeDriver)

    public func authenticate() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw P2PConnectionError.handshakeUnavailable
        }

        let operationKind: P2PHandshakeOperationKind = sessionKeysLock.withLock { $0 == nil }
            ? .authentication
            : .outboundRekey
        let operation = try await beginHandshakeOperation(kind: operationKind)
        var previousSession: EstablishedSessionSnapshot?
        var pendingConnectivityAttemptOwner: ProductConnectivityAttemptOwner?
        do {
            let gateStaged = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(operation) else { return false }
                if operation.kind == .outboundRekey {
                    rekeyInProgressLock.withLock { $0 = true }
                }
                return true
            }
            guard gateStaged else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            let capturedPreviousSession = try await currentEstablishedSessionSnapshot(
                for: operation
            )
            previousSession = capturedPreviousSession
            if operation.kind == .outboundRekey,
               capturedPreviousSession == nil {
                throw P2PConnectionError.noSessionKeys
            }
            try await publishStatus(.authenticating, for: operation)
            try requireCurrentHandshakeOperation(operation)

            if previousSession == nil {
                handshakeOperationLock.withLock { registry in
                    guard registry.owns(operation) else { return }
                    authenticatedRemoteAuthorityLock.withLock { $0 = nil }
                    authenticatedHandshakePeerBindingLock.withLock { $0 = nil }
                    latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
                }
            }

            let resolvedHandshakePeer = await resolveHandshakePeerIdentifier()
            try requireCurrentHandshakeOperation(operation)
            handshakeOperationLock.withLock { registry in
                guard registry.owns(operation) else { return }
                handshakePeer = resolvedHandshakePeer
            }
            try requireCurrentHandshakeOperation(operation)
            if resolvedHandshakePeer.deviceId != device.deviceId {
                SkyBridgeLogger.p2p.info(
                    "🧭 Handshake peer id normalized: raw=\(self.deviceDiagnosticLabel, privacy: .public) resolved=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
            }

            let receipt = try await performHandshake(operation: operation)
            pendingConnectivityAttemptOwner = receipt.connectivityAttemptOwner
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: receipt.owner.driver
            )
            try publishEstablishedSession(receipt)
            try await publishStatus(
                .authenticated,
                for: operation,
                exactDriver: receipt.owner.driver
            )
            try await publishAuthenticatedPresence(
                keys: receipt.keys,
                operationOwner: receipt.owner
            )
            if let evidenceOwner = receipt.connectivityAttemptOwner,
               let sessionReference = P2PEvidenceReference.sessionIncarnation(
                sessionID: receipt.keys.sessionId,
                transcriptHash: receipt.keys.transcriptHash
               ) {
                let recorded = await MainActor.run {
                    ProductReleaseEvidenceRecorder.shared.authenticateConnectivityAttempt(
                        owner: evidenceOwner,
                        sessionReference: sessionReference,
                        negotiatedSuite: receipt.keys.negotiatedSuite
                    )
                }
                if recorded {
                    pendingConnectivityAttemptOwner = nil
                } else {
                    SkyBridgeLogger.p2p.error(
                        "Authenticated connectivity evidence rejected its exact local attempt owner"
                    )
                }
            }
            try requireCurrentHandshakeOperation(operation, exactDriver: receipt.owner.driver)
            guard finishHandshakeOperation(receipt.owner) else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            await retireClassicTransferSessionLeases(
                except: classicTransferSessionIdentifier(for: receipt.keys)
            )
            schedulePostAuthPairingIdentityExchange()
            startMetricsIfNeeded()
        } catch {
            let originalError = error
            if let evidenceOwner = pendingConnectivityAttemptOwner {
                _ = await MainActor.run {
                    ProductReleaseEvidenceRecorder.shared.failConnectivityAttempt(
                        owner: evidenceOwner,
                        reason: .publicationFailed
                    )
                }
            }
            try await failHandshakeOperation(
                operation,
                restoring: previousSession,
                terminalStatus: previousSession == nil ? .failed : .authenticated
            )
            throw originalError
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performHandshake(
        operation: P2PHandshakeOperationToken
    ) async throws -> EstablishedHandshakeReceipt {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let selection: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let requestedProvider = CryptoProviderFactory.make(policy: selection)

        do {
            let receipt = try await performHandshakeAttempt(
                policy: policy,
                selectionPolicy: selection,
                preferPQC: true,
                operation: operation
            )
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: receipt.owner.driver
            )
            return try await finalizeAuthenticatedSession(
                receipt,
                policy: policy,
                operation: operation
            )
        } catch {
            if let receipt = try await performPQCBootstrapRecoveryIfNeeded(
                for: error,
                requestedPolicy: policy,
                requestedSelection: selection,
                requestedProvider: requestedProvider,
                operation: operation
            ) {
                try requireCurrentHandshakeOperation(
                    operation,
                    exactDriver: receipt.owner.driver
                )
                return try await finalizeAuthenticatedSession(
                    receipt,
                    policy: policy,
                    operation: operation
                )
            }

            if let receipt = try await performPQCKeyRefreshBootstrapRecoveryIfNeeded(
                for: error,
                requestedPolicy: policy,
                requestedSelection: selection,
                requestedProvider: requestedProvider,
                operation: operation
            ) {
                try requireCurrentHandshakeOperation(
                    operation,
                    exactDriver: receipt.owner.driver
                )
                return try await finalizeAuthenticatedSession(
                    receipt,
                    policy: policy,
                    operation: operation
                )
            }

            try requireCurrentHandshakeOperation(operation)
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            await logSuiteNegotiationDiagnosticsIfNeeded(error, policy: policy, cryptoProvider: requestedProvider)
            try requireCurrentHandshakeOperation(operation)
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func finalizeAuthenticatedSession(
        _ receipt: EstablishedHandshakeReceipt,
        policy: HandshakePolicy,
        operation: P2PHandshakeOperationToken
    ) async throws -> EstablishedHandshakeReceipt {
        try requireCurrentHandshakeOperation(
            operation,
            exactDriver: receipt.owner.driver
        )
        let usedBootstrapAssistedPath = bootstrapAssistedHandshakeLock.withLock { state in
            let current = state
            state = false
            return current
        }
        let assurance = Self.classifySessionAssurance(
            policy: policy,
            negotiatedSuite: receipt.keys.negotiatedSuite,
            bootstrapAssisted: usedBootstrapAssistedPath
        )
        try await publishAssuranceLevel(
            assurance,
            for: operation,
            exactDriver: receipt.owner.driver
        )
        SkyBridgeLogger.p2p.info(
            "🔐 Session assurance: \(assurance.rawValue, privacy: .public) suite=\(receipt.keys.negotiatedSuite.rawValue, privacy: .public) requirePQC=\(policy.requirePQC, privacy: .public) bootstrapAssisted=\(usedBootstrapAssistedPath, privacy: .public)"
        )
        return receipt
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performHandshakeAttempt(
        policy: HandshakePolicy,
        selectionPolicy: CryptoProviderFactory.SelectionPolicy,
        preferPQC: Bool,
        allowSOA: Bool = true,
        operation: P2PHandshakeOperationToken
    ) async throws -> EstablishedHandshakeReceipt {
        try requireCurrentHandshakeOperation(operation)
        let baseProvider = CryptoProviderFactory.make(policy: selectionPolicy)
        let successfulConnectivityAttemptOwner = OSAllocatedUnfairLock<
            ProductConnectivityAttemptOwner?
        >(initialState: nil)

        let shouldAdvertiseSOA = allowSOA && shouldUseSOA()
        let previousSession = try await currentEstablishedSessionSnapshot(for: operation)
        let localSOAPeerId: Data? = shouldAdvertiseSOA
            ? try await localSOAPeerIdBytes()
            : nil
        try requireCurrentHandshakeOperation(operation)
        let expectedRemoteSOAPeerId: Data?
        if shouldAdvertiseSOA {
            expectedRemoteSOAPeerId = remoteSOAPeerIdBytes(for: handshakePeer.deviceId)
        } else {
            expectedRemoteSOAPeerId = nil
        }

        let configuration = try await SettingsManager.shared
            .committedProtocolIdentityConfiguration()
        try requireCurrentHandshakeOperation(operation)
        let outboundProtocolIdentity = await MainActor.run {
            let requestedAlgorithm = configuration.algorithm
            let protection = configuration.protection
            let peerAlgorithm = TrustSyncService.shared.outboundPQCSignatureAlgorithm(
                deviceId: handshakePeer.deviceId,
                requestedAlgorithm: requestedAlgorithm
            )
            return (
                requestedAlgorithm: requestedAlgorithm,
                requestedProtection: protection,
                selectedAlgorithm: peerAlgorithm
            )
        }
        try requireCurrentHandshakeOperation(operation)

        let releasedArbiterLease: PeerSessionArbiter.EstablishedLease?
        if shouldAdvertiseSOA, previousSession != nil {
            guard let activeLease = previousSession?.arbiterLease,
                  previousSession?.soaPairKey == activeLease.pairKey else {
                throw P2PConnectionError.arbiterLeaseUnavailable
            }
            guard await PeerSessionArbiter.shared.clearEstablished(activeLease) else {
                try requireCurrentHandshakeOperation(operation)
                throw P2PConnectionError.arbiterLeaseUnavailable
            }
            try requireCurrentHandshakeOperation(operation)
            let detached = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(operation),
                      establishedArbiterLeaseLock.withLock({ $0 }) == activeLease else {
                    return false
                }
                establishedArbiterLeaseLock.withLock { $0 = nil }
                return true
            }
            guard detached else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            releasedArbiterLease = activeLease
            SkyBridgeLogger.p2p.info(
                "🧩 outbound rekey: releasing exact SOA established lease. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
            )
        } else {
            releasedArbiterLease = nil
        }

        do {
            let sessionKeys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: handshakePeer.deviceId,
                preferPQC: preferPQC,
                policy: policy,
                cryptoProvider: baseProvider,
                executor: { [weak self] preparation in
                    guard let self else { throw P2PConnectionError.disconnected }

                    let cryptoProvider: any CryptoProvider = {
                        switch preparation.strategy {
                        case .pqcOnly:
                            return CryptoProviderFactory.make(policy: selectionPolicy)
                        case .classicOnly:
                            return CryptoProviderFactory.make(policy: .classicOnly)
                        }
                    }()

                    let identityProvider = DeviceIdentityHandshakeProvider(
                        sigAAlgorithm: preparation.sigAAlgorithm,
                        protocolSigningKeyProtection: preparation.sigAAlgorithm
                            == outboundProtocolIdentity.requestedAlgorithm
                            ? outboundProtocolIdentity.requestedProtection
                            : .softwareKeychain,
                        includeSecureEnclavePoP: policy.requireSecureEnclavePoP
                    )

                    let outboundSOA: HandshakeSOAMetadata? = try {
                        guard shouldAdvertiseSOA,
                              let localSOAPeerId,
                              let expectedRemoteSOAPeerId else {
                            return nil
                        }
                        return try HandshakeSOAMetadata(
                            initiatorPeerId: localSOAPeerId,
                            targetPeerId: expectedRemoteSOAPeerId,
                            attemptId: Self.randomAttemptIdBytes()
                        )
                    }()

                    let connectivityAttemptOwner: ProductConnectivityAttemptOwner?
                    if let outboundSOA,
                       let attemptReference = ProductConnectivityAttemptReference.make(
                        from: outboundSOA.attemptId
                       ),
                       let localProfile = ProductConnectivityProfileClassifier
                        .configuredProfile(
                            requirePQC: policy.requirePQC,
                            selectedSuiteWireID: cryptoProvider.activeSuite.wireId
                        ) {
                        connectivityAttemptOwner = await MainActor.run {
                            ProductReleaseEvidenceRecorder.shared.beginConnectivityAttempt(
                                attemptReference: attemptReference,
                                role: .initiator,
                                localProfile: localProfile,
                                offeredSuites: preparation.offeredSuites,
                                requirePQC: policy.requirePQC,
                                allowClassicFallback: policy.allowClassicFallback
                            )
                        }
                    } else {
                        connectivityAttemptOwner = nil
                    }

                    let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: preparation.offeredSuites)
                    let exactDriverLock = OSAllocatedUnfairLock<HandshakeDriver?>(
                        initialState: nil
                    )
                    let transport = DirectHandshakeTransport(sendFramed: { [weak self] data in
                        guard let self,
                              let exactDriver = exactDriverLock.withLock({ $0 }) else {
                            throw P2PConnectionError.disconnected
                        }
                        try self.requireCurrentHandshakeOperation(
                            operation,
                            exactDriver: exactDriver
                        )
                        try await self.sendFramed(data)
                        try self.requireCurrentHandshakeOperation(
                            operation,
                            exactDriver: exactDriver
                        )
                    })
                    do {
                        let driver = try HandshakeDriver(
                            transport: transport,
                            cryptoProvider: cryptoProvider,
                            protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: preparation.sigAAlgorithm),
                            identityProvider: identityProvider,
                            sigAAlgorithm: preparation.sigAAlgorithm,
                            offeredSuites: preparation.offeredSuites,
                            policy: policy,
                            cryptoPolicy: cryptoPolicy,
                            soaMetadata: outboundSOA,
                            localSOAPeerId: localSOAPeerId,
                            expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
                        )
                        exactDriverLock.withLock { $0 = driver }
                        let owner = try await self.installHandshakeDriver(
                            driver,
                            for: operation
                        )
                        let operationPeer = self.handshakePeer
                        try self.startReceivingIfNeeded(
                            for: owner,
                            peer: operationPeer
                        )
                        try self.requireCurrentHandshakeOperation(
                            owner.token,
                            exactDriver: owner.driver
                        )
                        let sessionKeys = try await driver.initiateHandshake(with: operationPeer)
                        try self.requireCurrentHandshakeOperation(
                            owner.token,
                            exactDriver: owner.driver
                        )
                        successfulConnectivityAttemptOwner.withLock {
                            $0 = connectivityAttemptOwner
                        }
                        return sessionKeys
                    } catch {
                        if let connectivityAttemptOwner {
                            let reason: ProductConnectivityAttemptFailureReason =
                                Task.isCancelled ? .cancelled : .handshakeFailed
                            _ = await MainActor.run {
                                ProductReleaseEvidenceRecorder.shared.failConnectivityAttempt(
                                    owner: connectivityAttemptOwner,
                                    reason: reason
                                )
                            }
                        }
                        throw error
                    }
                },
                pqcSignatureAlgorithm: outboundProtocolIdentity.selectedAlgorithm
            )
            try requireCurrentHandshakeOperation(operation)
            guard let owner = currentOwnedHandshakeDriver(), owner.token == operation else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            let peerBinding = await owner.driver.getAuthenticatedHandshakePeerBinding()
            try requireCurrentHandshakeOperation(operation, exactDriver: owner.driver)
            guard let peerBinding else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            let newArbiterLease = await owner.driver.getEstablishedArbiterLease()
            try requireCurrentHandshakeOperation(operation, exactDriver: owner.driver)

            let pairKey: Data?
            if shouldAdvertiseSOA {
                guard let localSOAPeerId,
                      let authenticatedRemoteSOAPeerId = peerBinding.authenticatedRemoteSOAPeerId,
                      expectedRemoteSOAPeerId == authenticatedRemoteSOAPeerId,
                      let newArbiterLease,
                      newArbiterLease.sessionId == sessionKeys.sessionId else {
                    throw P2PConnectionError.arbiterLeaseUnavailable
                }
                let expectedPairKey = PeerSessionArbiter.pairKey(
                    localPeerId: localSOAPeerId,
                    remotePeerId: authenticatedRemoteSOAPeerId
                )
                guard newArbiterLease.pairKey == expectedPairKey else {
                    throw P2PConnectionError.arbiterLeaseUnavailable
                }
                pairKey = expectedPairKey
            } else {
                guard newArbiterLease == nil else {
                    throw P2PConnectionError.arbiterLeaseUnavailable
                }
                pairKey = nil
            }
            return EstablishedHandshakeReceipt(
                owner: owner,
                keys: sessionKeys,
                peerBinding: peerBinding,
                soaPairKey: pairKey,
                arbiterLease: newArbiterLease,
                connectivityAttemptOwner: successfulConnectivityAttemptOwner.withLock {
                    let current = $0
                    $0 = nil
                    return current
                }
            )
        } catch {
            if let connectivityAttemptOwner = successfulConnectivityAttemptOwner.withLock({
                let current = $0
                $0 = nil
                return current
            }) {
                _ = await MainActor.run {
                    ProductReleaseEvidenceRecorder.shared.failConnectivityAttempt(
                        owner: connectivityAttemptOwner,
                        reason: .publicationFailed
                    )
                }
            }
            if let owner = currentOwnedHandshakeDriver(), owner.token == operation {
                await detachAndCancelDriverIfOwned(owner)
            }
            if let releasedArbiterLease {
                SkyBridgeLogger.p2p.info(
                    "🧩 outbound rekey: restoring exact SOA established lease after failed rekey. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                try await restoreReleasedArbiterLease(
                    releasedArbiterLease,
                    for: operation
                )
            }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performPQCBootstrapRecoveryIfNeeded(
        for error: Error,
        requestedPolicy: HandshakePolicy,
        requestedSelection: CryptoProviderFactory.SelectionPolicy,
        requestedProvider: any CryptoProvider,
        operation: P2PHandshakeOperationToken
    ) async throws -> EstablishedHandshakeReceipt? {
        guard operation.kind == .authentication else { return nil }
        try requireCurrentHandshakeOperation(operation)
        let requiredPQCSuites = requestedProvider.supportedSuites.filter { $0.isPQCGroup }
        let requiredWireIds = Set(requiredPQCSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return nil }

        let hasRequiredPeerKEM = await hasRequiredPeerKEMPublicKeys(requiredWireIds: requiredWireIds)
        try requireCurrentHandshakeOperation(operation)

        guard Self.shouldAttemptPQCBootstrapRecovery(
            policy: requestedPolicy,
            error: error,
            hasRequiredPeerKEM: hasRequiredPeerKEM,
            requestedSelection: requestedSelection
        ) else {
            return nil
        }

        let targetSuites = requiredPQCSuites.map(\.rawValue).joined(separator: ",")
        let recoveryMode = requestedPolicy.requirePQC ? "strictPQC" : "preferredPQC"
        SkyBridgeLogger.p2p.info(
            "🧩 \(recoveryMode, privacy: .public) bootstrap start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) target=\(targetSuites, privacy: .public)"
        )

        do {
            let classicReceipt = try await performHandshakeAttempt(
                policy: .default,
                selectionPolicy: .classicOnly,
                preferPQC: false,
                operation: operation
            )
            let staged = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(
                    operation,
                    exactDriver: classicReceipt.owner.driver
                ) else { return false }
                rekeyInProgressLock.withLock { $0 = true }
                return true
            }
            guard staged else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            try publishEstablishedSession(classicReceipt)
            bootstrapAssistedHandshakeLock.withLock { $0 = true }

            try await sendPairingIdentityExchange(force: true)
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: classicReceipt.owner.driver
            )
            let readyForPQC = await waitForPeerKEMPublicKeys(
                requiredSuites: requiredPQCSuites,
                timeoutSeconds: 8
            )
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: classicReceipt.owner.driver
            )
            guard readyForPQC else {
                SkyBridgeLogger.p2p.warning(
                    "⏳ \(recoveryMode, privacy: .public) bootstrap 未在时限内收到对端 KEM 公钥: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                await detachAndCancelDriverIfOwned(classicReceipt.owner)
                await clearPublishedSession(for: operation)
                bootstrapAssistedHandshakeLock.withLock { $0 = false }
                return nil
            }

            return try await performHandshakeAttempt(
                policy: requestedPolicy,
                selectionPolicy: requestedSelection,
                preferPQC: true,
                operation: operation
            )
        } catch {
            if let owner = currentOwnedHandshakeDriver(), owner.token == operation {
                await detachAndCancelDriverIfOwned(owner)
            }
            await clearPublishedSession(for: operation)
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performPQCKeyRefreshBootstrapRecoveryIfNeeded(
        for error: Error,
        requestedPolicy: HandshakePolicy,
        requestedSelection: CryptoProviderFactory.SelectionPolicy,
        requestedProvider: any CryptoProvider,
        operation: P2PHandshakeOperationToken
    ) async throws -> EstablishedHandshakeReceipt? {
        guard operation.kind == .authentication else { return nil }
        try requireCurrentHandshakeOperation(operation)
        let requiredPQCSuites = requestedProvider.supportedSuites.filter { $0.isPQCGroup }
        let requiredWireIds = Set(requiredPQCSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return nil }

        let hasRequiredPeerKEM = await hasRequiredPeerKEMPublicKeys(requiredWireIds: requiredWireIds)
        try requireCurrentHandshakeOperation(operation)
        guard Self.shouldAttemptPQCKeyRefreshBootstrapRecovery(
            policy: requestedPolicy,
            error: error,
            hasRequiredPeerKEM: hasRequiredPeerKEM,
            requestedSelection: requestedSelection
        ) else {
            return nil
        }

        let baselinePeerKEM = await currentKnownPeerKEMPublicKeysByCanonicalWireId()
        try requireCurrentHandshakeOperation(operation)
        let targetSuites = requiredPQCSuites.map(\.rawValue).joined(separator: ",")
        let recoveryMode = requestedPolicy.requirePQC ? "strictPQC" : "preferredPQC"
        SkyBridgeLogger.p2p.info(
            "🧩 \(recoveryMode, privacy: .public) key-refresh bootstrap start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) target=\(targetSuites, privacy: .public)"
        )

        do {
            let classicReceipt = try await performHandshakeAttempt(
                policy: .default,
                selectionPolicy: .classicOnly,
                preferPQC: false,
                operation: operation
            )
            let staged = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(
                    operation,
                    exactDriver: classicReceipt.owner.driver
                ) else { return false }
                rekeyInProgressLock.withLock { $0 = true }
                return true
            }
            guard staged else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            try publishEstablishedSession(classicReceipt)
            bootstrapAssistedHandshakeLock.withLock { $0 = true }

            try await sendPairingIdentityExchange(force: true)
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: classicReceipt.owner.driver
            )
            let refreshedPeerKEM = await waitForPeerKEMPublicKeys(
                requiredSuites: requiredPQCSuites,
                timeoutSeconds: 8,
                requiringFreshKeyMaterialComparedTo: baselinePeerKEM
            )
            try requireCurrentHandshakeOperation(
                operation,
                exactDriver: classicReceipt.owner.driver
            )
            guard refreshedPeerKEM else {
                SkyBridgeLogger.p2p.warning(
                    "⏳ \(recoveryMode, privacy: .public) key-refresh bootstrap 未在时限内刷新对端 KEM 公钥: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                await detachAndCancelDriverIfOwned(classicReceipt.owner)
                await clearPublishedSession(for: operation)
                bootstrapAssistedHandshakeLock.withLock { $0 = false }
                return nil
            }

            return try await performHandshakeAttempt(
                policy: requestedPolicy,
                selectionPolicy: requestedSelection,
                preferPQC: true,
                operation: operation
            )
        } catch {
            if let owner = currentOwnedHandshakeDriver(), owner.token == operation {
                await detachAndCancelDriverIfOwned(owner)
            }
            await clearPublishedSession(for: operation)
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptStrictPQCBootstrap(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool
    ) -> Bool {
        false
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptPQCBootstrapRecovery(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool,
        requestedSelection: CryptoProviderFactory.SelectionPolicy
    ) -> Bool {
        guard requestedSelection != .classicOnly else { return false }
        if policy.requirePQC {
            return shouldAttemptStrictPQCBootstrap(
                policy: policy,
                error: error,
                hasRequiredPeerKEM: hasRequiredPeerKEM
            )
        }

        guard !hasRequiredPeerKEM else { return false }
        guard let handshakeError = error as? HandshakeError,
              case .failed(.suiteNegotiationFailed) = handshakeError else {
            return false
        }
        return true
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptStrictPQCKeyRefreshBootstrap(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool
    ) -> Bool {
        false
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptPQCKeyRefreshBootstrapRecovery(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool,
        requestedSelection: CryptoProviderFactory.SelectionPolicy
    ) -> Bool {
        guard requestedSelection != .classicOnly else { return false }
        if policy.requirePQC {
            return shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: policy,
                error: error,
                hasRequiredPeerKEM: hasRequiredPeerKEM
            )
        }

        guard hasRequiredPeerKEM else { return false }
        guard let handshakeError = error as? HandshakeError,
              case .failed(let reason) = handshakeError else {
            return false
        }

        switch reason {
        case .cryptoError(let detail):
            return looksLikeStalePeerKEMCryptoFailure(detail)
        case .timeout:
            return true
        case .transportError(let detail):
            return looksLikeStalePeerKEMTransportFailure(detail)
        default:
            return false
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func looksLikeStalePeerKEMCryptoFailure(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let markers = [
            "cryptokiterror",
            "aead",
            "authentication failure",
            "decrypt",
            "decryption",
            "failed to open"
        ]
        return markers.contains(where: normalized.contains)
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func looksLikeStalePeerKEMTransportFailure(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let markers = [
            "connection reset by peer",
            "connection refused",
            "error 54",
            "error 61"
        ]
        return markers.contains(where: normalized.contains)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func resolveHandshakePeerIdentifier() async -> PeerIdentifier {
        let fallback = PeerIdentifier(
            deviceId: device.deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )

        let candidates = trustLookupCandidates(
            primary: fallback.deviceId,
            persistent: device.persistentDeviceId
        )
        let fingerprint = normalizedFingerprint(device.pubKeyFingerprint)

        let resolvedId: String = await MainActor.run {
            let trust = TrustSyncService.shared

            for candidate in candidates {
                if trust.getTrustRecord(deviceId: candidate) != nil {
                    return candidate
                }
            }

            if let fingerprint {
                let matches = trust.activeTrustRecords.filter { record in
                    !record.pubKeyFP.isEmpty && record.pubKeyFP.caseInsensitiveCompare(fingerprint) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    return resolvedRecord.deviceId
                }
            }

            return candidates.first ?? fallback.deviceId
        }

        return PeerIdentifier(
            deviceId: resolvedId,
            displayName: fallback.displayName,
            address: fallback.address
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    static func shouldAdvertiseSOAForCurrentPath(
        capabilities: [String],
        handshakePeerDeviceId: String,
        connectionDeviceId: String,
        persistentDeviceId: String?
    ) -> Bool {
        let normalizedCapabilities = Set(capabilities.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if normalizedCapabilities.contains("hs_soa") {
            return true
        }

        return [handshakePeerDeviceId, connectionDeviceId, persistentDeviceId].compactMap { $0 }.contains { candidate in
            Self.strongSOARemoteIdentity(candidate) != nil
        }
    }

    private func shouldUseSOA() -> Bool {
        Self.shouldAdvertiseSOAForCurrentPath(
            capabilities: device.capabilities,
            handshakePeerDeviceId: handshakePeer.deviceId,
            connectionDeviceId: device.deviceId,
            persistentDeviceId: device.persistentDeviceId
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func localSOAPeerIdBytes() async throws -> Data {
        let deviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        return Self.soaPeerIdBytes(from: deviceId)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func remoteSOAPeerIdBytes(for peerId: String) -> Data? {
        guard let strongIdentity = Self.strongSOARemoteIdentity(peerId) else {
            return nil
        }
        return Self.soaPeerIdBytes(from: strongIdentity)
    }

    private nonisolated static func soaPeerIdBytes(from raw: String) -> Data {
        let canonical = canonicalSOAIdentityString(raw)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    private nonisolated static func canonicalSOAIdentityString(_ raw: String) -> String {
        PeerSessionArbiter.canonicalSOAIdentifier(raw)
    }

    private nonisolated static func strongSOARemoteIdentity(_ raw: String) -> String? {
        let canonical = canonicalSOAIdentityString(raw)
        guard !canonical.isEmpty else { return nil }
        guard UUID(uuidString: canonical.uppercased()) != nil else {
            return nil
        }
        return canonical
    }

    private nonisolated static func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        #else
        for idx in bytes.indices {
            bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        #endif
        return Data(bytes)
    }

    private func trustLookupCandidates(primary: String, persistent: String?) -> [String] {
        PeerTrustLookup.lookupCandidates(primary: primary, persistent: persistent)
    }

    private func normalizeHostAlias(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return normalizeHostAliasFromIPAddress(String(identifier.dropFirst("host:".count)))
        }
        if identifier.hasPrefix("peer:") {
            return normalizeHostAliasFromIPAddress(String(identifier.dropFirst("peer:".count)))
        }
        return nil
    }

    private func normalizeHostAliasFromIPAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "host:\(normalized)"
    }

    private func normalizeBonjourIdentifier(_ identifier: String) -> String? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let pieces = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let rawName = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else { return nil }
        let rawDomain = pieces.count > 1 ? pieces[1] : "local"
        let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "local"
            : rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "bonjour:\(rawName)@\(domain)"
    }

    private func normalizedFingerprint(_ fingerprint: String?) -> String? {
        guard let raw = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private func extractDisplayNameAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("recent:name:") {
            let payload = String(normalized.dropFirst("recent:name:".count))
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasPrefix("name:") {
            let payload = String(normalized.dropFirst("name:".count))
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func normalizedDisplayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func capabilityValue(prefix: String, in capabilities: [String]) -> String? {
        for capability in capabilities {
            guard capability.hasPrefix(prefix) else { continue }
            let value = String(capability.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    @MainActor
    private func trustRecordsMatchingCandidates(_ candidates: [String]) -> [TrustRecord] {
        let normalizedCandidates = Set(candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedCandidates.isEmpty else { return [] }
        let normalizedCandidatesLower = Set(normalizedCandidates.map { $0.lowercased() })

        var matchedByDeviceId: [String: TrustRecord] = [:]
        for record in TrustSyncService.shared.activeTrustRecords where !record.isTombstone {
            if PeerTrustLookup.recordMatches(
                record,
                candidates: normalizedCandidates,
                candidateLowercased: normalizedCandidatesLower
            ) {
                matchedByDeviceId[record.deviceId] = record
            }
        }

        return Array(matchedByDeviceId.values)
    }

    @available(macOS 14.0, iOS 17.0, *)
    @MainActor
    private func resolvedUniqueTrustRecord(from matches: [TrustRecord]) -> TrustRecord? {
        let activeMatches = matches.filter { !$0.isTombstone && !$0.isExpired }
        guard !activeMatches.isEmpty else { return nil }
        if activeMatches.count == 1 {
            return activeMatches[0]
        }

        let groups = TrustSyncService.buildDisplayGroups(from: activeMatches)
        guard groups.count == 1 else { return nil }
        return groups[0].displayRecord
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct SuiteNegotiationTrustDiagnostic: Sendable {
        let resolvedId: String?
        let hasTrust: Bool
        let kemSuiteWireIds: [UInt16]
        let matchedBy: String
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func resolveSuiteNegotiationTrustDiagnostic() async -> SuiteNegotiationTrustDiagnostic {
        let fallback = PeerIdentifier(
            deviceId: device.deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )
        let candidates = trustLookupCandidates(primary: fallback.deviceId, persistent: device.persistentDeviceId)
        let fingerprint = normalizedFingerprint(device.pubKeyFingerprint)
        let alias = extractDisplayNameAlias(from: fallback.deviceId) ?? normalizedDisplayName(fallback.displayName)

        var diagnostic = await MainActor.run {
            let trust = TrustSyncService.shared
            for candidate in candidates {
                if let record = trust.getTrustRecord(deviceId: candidate) {
                    let kemIds = record.kemPublicKeys?.map(\.suiteWireId) ?? []
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: candidate,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "candidate"
                    )
                }
            }

            let related = trustRecordsMatchingCandidates(candidates)
            if !related.isEmpty {
                let kemUnion = Set(related
                    .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                    .sorted()
                return SuiteNegotiationTrustDiagnostic(
                    resolvedId: related.first?.deviceId,
                    hasTrust: true,
                    kemSuiteWireIds: kemUnion,
                    matchedBy: "candidateAlias"
                )
            }

            if let fingerprint {
                let matches = trust.activeTrustRecords.filter { record in
                    !record.pubKeyFP.isEmpty && record.pubKeyFP.caseInsensitiveCompare(fingerprint) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    let kemIds = Set(matches
                        .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                        .sorted()
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: resolvedRecord.deviceId,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "fingerprint"
                    )
                }
            }

            if let alias {
                let matches = trust.activeTrustRecords.filter { record in
                    guard let recordName = record.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !recordName.isEmpty else { return false }
                    return recordName.caseInsensitiveCompare(alias) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    let kemIds = Set(matches
                        .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                        .sorted()
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: resolvedRecord.deviceId,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "name"
                    )
                }
            }

            return SuiteNegotiationTrustDiagnostic(
                resolvedId: nil,
                hasTrust: false,
                kemSuiteWireIds: [],
                matchedBy: "none"
            )
        }

        let cachedSuites = await PeerKEMBootstrapStore.shared.availableSuiteWireIds(forCandidates: candidates)
        guard !cachedSuites.isEmpty else { return diagnostic }

        let mergedSuites = Set(diagnostic.kemSuiteWireIds).union(cachedSuites).sorted()
        let matchedBy: String = {
            if diagnostic.matchedBy == "none" {
                return "bootstrapCache"
            }
            return "\(diagnostic.matchedBy)+bootstrapCache"
        }()
        let resolvedId = diagnostic.resolvedId ?? candidates.first
        diagnostic = SuiteNegotiationTrustDiagnostic(
            resolvedId: resolvedId,
            hasTrust: diagnostic.hasTrust,
            kemSuiteWireIds: mergedSuites,
            matchedBy: matchedBy
        )
        return diagnostic
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func logSuiteNegotiationDiagnosticsIfNeeded(
        _ error: Error,
        policy: HandshakePolicy,
        cryptoProvider: any CryptoProvider
    ) async {
        guard let handshakeError = error as? HandshakeError,
              case .failed(.suiteNegotiationFailed) = handshakeError else {
            return
        }
        let diag = await resolveSuiteNegotiationTrustDiagnostic()

        let requiredPQC = cryptoProvider.supportedSuites
            .filter { $0.isPQCGroup }
            .map(\.wireId)

        let missingPQC = requiredPQC.filter { !diag.kemSuiteWireIds.contains($0) }
	        let requiredPQCSummary = requiredPQC.map(String.init).joined(separator: ",")
	        let knownKEMSummary = diag.kemSuiteWireIds.map(String.init).joined(separator: ",")
	        let missingKEMSummary = missingPQC.map(String.init).joined(separator: ",")
	        let resolvedTrustId = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(diag.resolvedId)
	        let policyRequirePQC = policy.requirePQC ? "1" : "0"
	        let policyAllowClassicFallback = policy.allowClassicFallback ? "1" : "0"
	        let diagnostic = "🧩 握手协商失败诊断: peer=\(handshakePeerDiagnosticLabel) " +
	            "policy(requirePQC=\(policyRequirePQC),allowClassicFallback=\(policyAllowClassicFallback)) " +
	            "trustResolved=\(resolvedTrustId) by=\(diag.matchedBy) " +
            "requiredPQC=\(requiredPQCSummary) knownKEM=\(knownKEMSummary) missingKEM=\(missingKEMSummary)"
        SkyBridgeLogger.p2p.warning("\(diagnostic, privacy: .public)")

        if policy.requirePQC && (!diag.hasTrust || !missingPQC.isEmpty) {
            SkyBridgeLogger.p2p.warning(
                "🔐 strictPQC 当前缺少对端 KEM 公钥。请先完成配对/信任引导（交换 KEM identity keys）后重试。"
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func schedulePostAuthPairingIdentityExchange() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendPostAuthPairingIdentityExchangeWithTimeout()
            } catch {
                SkyBridgeLogger.p2p.info(
                    "ℹ️ optional post-auth pairingIdentityExchange deferred: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendPostAuthPairingIdentityExchangeWithTimeout(timeoutSeconds: TimeInterval = 2) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw P2PConnectionError.disconnected }
                try await self.sendPairingIdentityExchange(force: true)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw P2PConnectionError.postAuthPairingIdentityExchangeTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendPairingIdentityExchange(force: Bool = false) async throws {
        let now = Date()
        if !force {
            let canSend = lastPairingIdentityExchangeSentAtLock.withLock { last in
                guard let last else { return true }
                return now.timeIntervalSince(last) >= 10
            }
            guard canSend else { return }
        }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let keyManager = DeviceIdentityKeyManager.shared
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await keyManager.pairingIdentityKEMPublicKeys(using: provider)
        )
        guard !kemKeys.isEmpty else {
            SkyBridgeLogger.p2p.warning("⚠️ 跳过 pairingIdentityExchange：本机 KEM 公钥为空")
            return
        }

        let localDeviceIdRaw = try await keyManager.getDeviceId()
        let localDeviceId = localDeviceIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localDeviceId.isEmpty else {
            SkyBridgeLogger.p2p.warning("⚠️ 跳过 pairingIdentityExchange：本机 deviceId 为空")
            return
        }
        let protocolIdentityPublicKeys = try await localProtocolIdentityPublicKeysForPairing()
        let localPresentation = LocalDevicePresentation.current()
        let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys,
            deviceName: localPresentation.deviceName,
            modelName: localPresentation.modelName,
            platform: localPresentation.platformName,
            osVersion: localPresentation.osVersion,
            chip: nil,
            accountDisplayName: localIdentity?.accountDisplayName,
            nebulaId: localIdentity?.nebulaId,
            capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control", ClassicTransferCapability.classicResume],
            fileTransferPort: ServiceEndpointRegistry.shared.snapshot().fileTransferPort,
            remoteControlPort: ServiceEndpointRegistry.shared.snapshot().remoteControlPort
        ))
        try await sendEncryptedAppMessage(message)
        lastPairingIdentityExchangeSentAtLock.withLock { $0 = now }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func localProtocolIdentityPublicKeysForPairing() async throws -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        return try await LocalProtocolIdentityAdvertisement.load()
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func waitForPeerKEMPublicKeys(
        requiredSuites: [CryptoSuite],
        timeoutSeconds: TimeInterval,
        requiringFreshKeyMaterialComparedTo baselineKeys: [UInt16: Data] = [:]
    ) async -> Bool {
        let requiredWireIds = Set(requiredSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return true }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let ready = await hasRequiredPeerKEMPublicKeys(
                requiredWireIds: requiredWireIds,
                requiringFreshKeyMaterialComparedTo: baselineKeys
            )
            if ready { return true }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return await hasRequiredPeerKEMPublicKeys(
            requiredWireIds: requiredWireIds,
            requiringFreshKeyMaterialComparedTo: baselineKeys
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func hasRequiredPeerKEMPublicKeys(
        requiredWireIds: Set<UInt16>,
        requiringFreshKeyMaterialComparedTo baselineKeys: [UInt16: Data] = [:]
    ) async -> Bool {
        let currentKeys = await currentKnownPeerKEMPublicKeysByCanonicalWireId()
        let currentWireIds = Set(currentKeys.keys)
        guard requiredWireIds.isSubset(of: currentWireIds) else {
            return false
        }
        guard !baselineKeys.isEmpty else {
            return true
        }

        for wireId in requiredWireIds {
            guard let current = currentKeys[wireId] else { return false }
            if baselineKeys[wireId] != current {
                return true
            }
        }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func currentKnownPeerKEMPublicKeysByCanonicalWireId() async -> [UInt16: Data] {
        let candidates = trustLookupCandidates(primary: handshakePeer.deviceId, persistent: device.persistentDeviceId)
        let trustKeys: [UInt16: Data] = await MainActor.run {
            let trust = TrustSyncService.shared
            var availableUnion: [UInt16: Data] = [:]

            for candidate in candidates {
                guard let record = trust.getTrustRecord(deviceId: candidate),
                      let kemKeys = record.kemPublicKeys else {
                    continue
                }
                for key in kemKeys {
                    availableUnion[CryptoSuite(wireId: key.suiteWireId).canonicalKEMSuite.wireId] = key.publicKey
                }
            }

            let related = trustRecordsMatchingCandidates(candidates)
            for record in related {
                if let kemKeys = record.kemPublicKeys {
                    for key in kemKeys {
                        availableUnion[CryptoSuite(wireId: key.suiteWireId).canonicalKEMSuite.wireId] = key.publicKey
                    }
                }
            }

            return availableUnion
        }

        let cachedKeysRaw = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(forCandidates: candidates)
        var combined = trustKeys
        for (wireId, publicKey) in cachedKeysRaw {
            combined[CryptoSuite(wireId: wireId).canonicalKEMSuite.wireId] = publicKey
        }
        return combined
    }

    // MARK: - Framing IO (4-byte big-endian length)

    /// Send a single length-framed payload on the control channel.
    /// Note: For post-handshake business traffic, prefer `AppMessage` over the encrypted SessionKeys channel.
    public func send(_ payload: Data) async throws {
        try await sendFramed(payload)
    }

    /// Legacy JSON message API kept for source compatibility.
    /// New code should use `AppMessage` (encrypted) instead of `P2PMessage`.
    @available(*, deprecated, message: "Use AppMessage over the encrypted SessionKeys channel (HandshakeDriver).")
    public func sendMessage(_ message: P2PMessage) async throws {
        let data = try JSONEncoder().encode(message)
        try await sendFramed(data)
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func setRemoteDesktopFrameHandler(_ handler: (@Sendable (Data, UInt64) -> Void)?) {
        remoteDesktopFrameHandlerLock.withLock { $0 = handler }
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func sendRemoteDesktopFrame(_ data: Data, timestampNs: UInt64) async throws {
        let envelope = BusinessEnvelope.remoteDesktopFrame(timestampNs: timestampNs, payload: data)
        try await sendEncryptedBusinessPlaintext(envelope.encode(), label: "remote_desktop")
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func sendAppMessage(_ message: AppMessage) async throws {
        try await sendEncryptedAppMessage(message)
    }

    /// Sends business data only when the exact established session is bound to
    /// the conversation authority selected by the caller.
    @available(macOS 14.0, iOS 17.0, *)
    public func sendAppMessage(
        _ message: AppMessage,
        requiringRemoteProtocolFingerprint rawFingerprint: String
    ) async throws {
        try Task.checkCancellation()
        let expectedFingerprint = try DeviceTextMessagePolicy
            .normalizedConversationFingerprint(rawFingerprint)
        let witness = try authenticatedMessageSendWitness(
            requiringRemoteProtocolFingerprint: expectedFingerprint
        )
        let encoded = try encodedAppMessage(message)
        try requireCurrentAuthenticatedMessageSendWitness(witness)
        try await sendEncryptedBusinessPlaintext(
            encoded.plaintext,
            label: "tx",
            allowDuringBootstrap: encoded.allowDuringBootstrap,
            using: witness.keys
        )
        try requireCurrentAuthenticatedMessageSendWitness(witness)
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func deriveClassicFileTransferKey(transferId: String) throws -> SymmetricKey {
        guard let keys = sessionKeysLock.withLock({ $0 }) else {
            throw P2PConnectionError.noSessionKeys
        }

        let orderedKeys = [keys.sendKey, keys.receiveKey].sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        let combinedMaterial = orderedKeys.reduce(into: Data()) { partial, key in
            partial.append(key)
        }

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combinedMaterial),
            salt: Data("skybridge-classic-file-transfer-v1".utf8),
            info: Data(transferId.utf8),
            outputByteCount: 32
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendEncryptedAppMessage(_ message: AppMessage) async throws {
        let encoded = try encodedAppMessage(message)
        try await sendEncryptedBusinessPlaintext(
            encoded.plaintext,
            label: "tx",
            allowDuringBootstrap: encoded.allowDuringBootstrap
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func encodedAppMessage(
        _ message: AppMessage
    ) throws -> (plaintext: Data, allowDuringBootstrap: Bool) {
        let allowDuringBootstrap = Self.isBootstrapControlMessage(message)
        if case .clipboard(let clipboard) = message {
            guard let data = clipboard.decodedData else {
                throw P2PConnectionError.invalidAuthenticatedPayload
            }
            try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
            guard P2PClipboardMIMEPolicy.canonicalWireValue(for: clipboard.mimeType) != nil else {
                throw P2PConnectionError.invalidAuthenticatedPayload
            }
        }
        let plaintext = try P2PControlJSONEncoder.encode(message)
        return (plaintext, allowDuringBootstrap)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func authenticatedMessageSendWitness(
        requiringRemoteProtocolFingerprint expectedFingerprint: String
    ) throws -> AuthenticatedMessageSendWitness {
        try handshakeOperationLock.withLock { registry in
            guard !registry.isDisconnected,
                  let keys = sessionKeysLock.withLock({ $0 }),
                  let peerBinding = authenticatedHandshakePeerBindingLock.withLock({ $0 }) else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            let authenticatedFingerprint: String
            do {
                authenticatedFingerprint = try DeviceTextMessagePolicy
                    .normalizedConversationFingerprint(
                        peerBinding.authority.protocolPublicKeyFingerprint
                    )
            } catch {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            guard authenticatedFingerprint == expectedFingerprint else {
                throw P2PConnectionError.authenticatedIdentityMismatch
            }
            return AuthenticatedMessageSendWitness(
                connectionGeneration: registry.connectionGeneration,
                keys: keys,
                peerBinding: peerBinding
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func requireCurrentAuthenticatedMessageSendWitness(
        _ witness: AuthenticatedMessageSendWitness
    ) throws {
        try handshakeOperationLock.withLock { registry in
            guard registry.ownsConnectionGeneration(witness.connectionGeneration),
                  let keys = sessionKeysLock.withLock({ $0 }),
                  keys.sessionId == witness.keys.sessionId,
                  keys.sendKey == witness.keys.sendKey,
                  authenticatedHandshakePeerBindingLock.withLock({ $0 }) == witness.peerBinding else {
                throw P2PConnectionError.staleAuthenticatedFrame
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendEncryptedBusinessPlaintext(
        _ plaintext: Data,
        label: String,
        allowDuringBootstrap: Bool = false
    ) async throws {
        if rekeyInProgressLock.withLock({ $0 }), !allowDuringBootstrap {
            throw P2PConnectionError.bootstrapControlOnly
        }
        guard let keys = sessionKeysLock.withLock({ $0 }) else {
            throw P2PConnectionError.noSessionKeys
        }
        let ciphertext = try encryptAppPayload(plaintext, with: keys)
        let padded = try TrafficPadding.wrapForP2PControlFrame(
            ciphertext,
            label: label
        )
        try await sendFramed(padded)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendEncryptedBusinessPlaintext(
        _ plaintext: Data,
        label: String,
        allowDuringBootstrap: Bool,
        using keys: SessionKeys
    ) async throws {
        if rekeyInProgressLock.withLock({ $0 }), !allowDuringBootstrap {
            throw P2PConnectionError.bootstrapControlOnly
        }
        let ciphertext = try encryptAppPayload(plaintext, with: keys)
        let padded = try TrafficPadding.wrapForP2PControlFrame(
            ciphertext,
            label: label
        )
        try await sendFramed(padded)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private enum BusinessEnvelopeKind: UInt8, Sendable {
        case remoteDesktopFrame = 1
    }

    /// Encrypted business payload envelope (v1).
    ///
    /// - Why: `AppMessage` is JSON (and `Data` in JSON becomes base64), which is too expensive for high-rate streams.
    /// - This envelope allows binary payloads (e.g. remote desktop frames) to reuse the post-handshake SessionKeys
    ///   channel, while keeping backwards compatibility with legacy JSON `AppMessage` frames.
    @available(macOS 14.0, iOS 17.0, *)
    private struct BusinessEnvelope: Sendable {
        // "SBE1"
        private static let magic: [UInt8] = [0x53, 0x42, 0x45, 0x31]
        private static let headerLen = 4 + 1 + 8 // magic + kind + timestampNs

        let kind: BusinessEnvelopeKind
        let timestampNs: UInt64
        let payload: Data

        static func remoteDesktopFrame(timestampNs: UInt64, payload: Data) -> BusinessEnvelope {
            BusinessEnvelope(kind: .remoteDesktopFrame, timestampNs: timestampNs, payload: payload)
        }

        func encode() -> Data {
            var out = Data(capacity: Self.headerLen + payload.count)
            out.append(contentsOf: Self.magic)
            out.append(kind.rawValue)
            var tsBE = timestampNs.bigEndian
            out.append(Data(bytes: &tsBE, count: MemoryLayout.size(ofValue: tsBE)))
            out.append(payload)
            return out
        }

        static func decode(_ data: Data) -> BusinessEnvelope? {
            guard data.count >= headerLen else { return nil }
            guard data.prefix(4).elementsEqual(magic) else { return nil }

            let kindRaw = data[data.startIndex.advanced(by: 4)]
            guard let kind = BusinessEnvelopeKind(rawValue: kindRaw) else { return nil }

            let tsStart = data.startIndex.advanced(by: 5)
            let tsEnd = tsStart.advanced(by: 8)
            guard tsEnd <= data.endIndex else { return nil }
            var timestampNs: UInt64 = 0
            for b in data[tsStart..<tsEnd] {
                timestampNs = (timestampNs << 8) | UInt64(b)
            }

            let payload = data.suffix(from: tsEnd)
            return BusinessEnvelope(kind: kind, timestampNs: timestampNs, payload: payload)
        }
    }

    private func sendFramed(_ payload: Data) async throws {
        let frame = try P2PControlFramePolicy.frame(body: payload)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }

        // Update counters on main thread for SwiftUI.
        DispatchQueue.main.async {
            self.bytesSent &+= UInt64(payload.count)
            self.lastActivity = Date()
        }
    }

    // MARK: - Metrics (RTT / bandwidth)

    @available(macOS 14.0, iOS 17.0, *)
    private func startMetricsIfNeeded() {
        let ownerToken = UUID()
        let reserved = metricsTaskOwnerLock.withLock { owner -> Bool in
            guard owner == nil else { return false }
            owner = MetricsTaskOwner(token: ownerToken, task: nil)
            return true
        }
        guard reserved else { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard self.isCurrentMetricsTask(ownerToken) else { return }

            let clock = ContinuousClock()
            let now = clock.now
            let initialBytes = await MainActor.run { self.bytesReceived &+ self.bytesSent }
            guard self.isCurrentMetricsTask(ownerToken) else { return }
            self.metricsLock.withLock { state in
                state.lastTotalBytes = initialBytes
                state.lastBandwidthSampleAt = now
            }

            while !Task.isCancelled, self.isCurrentMetricsTask(ownerToken) {
                await self.sampleBandwidth(clock: clock, ownerToken: ownerToken)
                await self.tickPing(clock: clock, ownerToken: ownerToken)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        let installed = metricsTaskOwnerLock.withLock { owner -> Bool in
            guard owner?.token == ownerToken else { return false }
            owner?.task = task
            return true
        }
        if !installed {
            task.cancel()
        }
    }

    private func isCurrentMetricsTask(_ token: UUID) -> Bool {
        metricsTaskOwnerLock.withLock { $0?.token == token }
    }

    private func currentMetricsTaskToken() -> UUID? {
        metricsTaskOwnerLock.withLock { $0?.token }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sampleBandwidth(
        clock: ContinuousClock,
        ownerToken: UUID
    ) async {
        let now = clock.now
        let totalBytes = await MainActor.run { self.bytesReceived &+ self.bytesSent }
        guard isCurrentMetricsTask(ownerToken) else { return }

        let bps: Double? = metricsLock.withLock { state in
            guard let lastAt = state.lastBandwidthSampleAt else {
                state.lastBandwidthSampleAt = now
                state.lastTotalBytes = totalBytes
                return nil
            }
            let dt = Self.durationSeconds(lastAt.duration(to: now))
            guard dt > 0 else {
                state.lastBandwidthSampleAt = now
                state.lastTotalBytes = totalBytes
                return nil
            }
            let deltaBytes = totalBytes >= state.lastTotalBytes ? (totalBytes - state.lastTotalBytes) : 0
            state.lastTotalBytes = totalBytes
            state.lastBandwidthSampleAt = now
            return Double(deltaBytes) / dt
        }

        guard let bps else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentMetricsTask(ownerToken) else { return }
            let current = self.measuredBandwidthBytesPerSecond
            if current <= 0 {
                self.measuredBandwidthBytesPerSecond = bps
            } else {
                self.measuredBandwidthBytesPerSecond = (current * 0.8) + (bps * 0.2)
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func tickPing(
        clock: ContinuousClock,
        ownerToken: UUID
    ) async {
        guard isCurrentMetricsTask(ownerToken) else { return }
        // Only ping once the encrypted session is established.
        guard await MainActor.run(body: { self.status == .authenticated }) else { return }
        guard isCurrentMetricsTask(ownerToken) else { return }
        guard !rekeyInProgressLock.withLock({ $0 }) else { return }
        guard sessionKeysLock.withLock({ $0 }) != nil else { return }

        let now = clock.now

        // 1) Timeout outstanding ping if needed.
        let didUpdateLoss = metricsLock.withLock { state -> Bool in
            if let outstanding = state.outstandingPing {
                let ageSeconds = Self.durationSeconds(outstanding.sentAt.duration(to: now))
                if ageSeconds > 6.0 {
                    state.outstandingPing = nil
                    state.pingResults.append(false)
                    if state.pingResults.count > 20 {
                        state.pingResults.removeFirst(state.pingResults.count - 20)
                    }
                    return true
                }
            }
            return false
        }

        if didUpdateLoss {
            updatePacketLossFromHistory(ownerToken: ownerToken)
        }

        // 2) Send a new ping (at most one in-flight).
        let pingId: UInt64? = metricsLock.withLock { state in
            if state.outstandingPing != nil { return nil }
            if let last = state.lastPingSentAt {
                let since = Self.durationSeconds(last.duration(to: now))
                if since < 2.0 { return nil }
            }
            let id = UInt64.random(in: UInt64.min...UInt64.max)
            state.lastPingSentAt = now
            state.outstandingPing = (id: id, sentAt: now)
            return id
        }

        guard let pingId else { return }

        do {
            try await sendEncryptedAppMessage(.ping(.init(id: pingId)))
        } catch {
            guard isCurrentMetricsTask(ownerToken) else { return }
            // Treat send failure as a ping failure (but keep it best-effort).
            metricsLock.withLock { state in
                if let outstanding = state.outstandingPing, outstanding.id == pingId {
                    state.outstandingPing = nil
                    state.pingResults.append(false)
                    if state.pingResults.count > 20 {
                        state.pingResults.removeFirst(state.pingResults.count - 20)
                    }
                }
            }
            updatePacketLossFromHistory(ownerToken: ownerToken)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handlePong(id: UInt64) {
        guard let ownerToken = currentMetricsTaskToken() else { return }
        let now = ContinuousClock().now

        let rttSeconds: Double? = metricsLock.withLock { state in
            guard let outstanding = state.outstandingPing, outstanding.id == id else {
                return nil
            }
            state.outstandingPing = nil
            state.pingResults.append(true)
            if state.pingResults.count > 20 {
                state.pingResults.removeFirst(state.pingResults.count - 20)
            }
            let rtt = Self.durationSeconds(outstanding.sentAt.duration(to: now))
            return rtt
        }

        guard let rttSeconds else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isCurrentMetricsTask(ownerToken) else { return }
            let current = self.measuredLatency
            if current <= 0 {
                self.measuredLatency = rttSeconds
            } else {
                self.measuredLatency = (current * 0.8) + (rttSeconds * 0.2)
            }
        }
        updatePacketLossFromHistory(ownerToken: ownerToken)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func updatePacketLossFromHistory(ownerToken: UUID) {
        guard isCurrentMetricsTask(ownerToken) else { return }
        let loss: Double = metricsLock.withLock { state in
            guard !state.pingResults.isEmpty else { return 0 }
            let lost = state.pingResults.filter { !$0 }.count
            return Double(lost) / Double(state.pingResults.count)
        }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentMetricsTask(ownerToken) else { return }
            self.measuredPacketLoss = loss
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private static func durationSeconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + (Double(c.attoseconds) / 1_000_000_000_000_000_000.0)
    }

    private func startReceivingIfNeeded(
        for owner: OwnedHandshakeDriver,
        peer: PeerIdentifier
    ) throws {
        let leaseId = UUID()
        let connectionGeneration = owner.token.connectionGeneration
        let activated = receiveLeaseLock.withLock { state -> Bool in
            guard handshakeOperationLock.withLock({
                $0.owns(owner.token, exactDriver: owner.driver)
            }) else {
                return false
            }
            if let state {
                return state.connectionGeneration == connectionGeneration
            }

            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let reader = FramedReader.nwConnection(self.connection)
                do {
                    while !Task.isCancelled {
                        let payload = try await reader.receiveFrame()
                        try self.requireCurrentConnectionGeneration(connectionGeneration)
                        try await self.handleInboundFrame(
                            payload,
                            from: peer,
                            connectionGeneration: connectionGeneration
                        )
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.disconnectIfOwnedReceiveLease(
                        id: leaseId,
                        connectionGeneration: connectionGeneration,
                        peer: peer,
                        error: error
                    )
                }
            }
            state = InboundReceiveLease(
                id: leaseId,
                connectionGeneration: connectionGeneration,
                peer: peer,
                task: task
            )
            return true
        }
        guard activated else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    private func requireCurrentConnectionGeneration(_ generation: UInt64) throws {
        guard handshakeOperationLock.withLock({
            $0.ownsConnectionGeneration(generation)
        }) else {
            throw P2PConnectionError.staleHandshakeOperation
        }
    }

    private func disconnectIfOwnedReceiveLease(
        id: UUID,
        connectionGeneration: UInt64,
        peer: PeerIdentifier,
        error: Error
    ) {
        guard receiveLeaseLock.withLock({ state in
            state?.id == id && state?.connectionGeneration == connectionGeneration
        }), handshakeOperationLock.withLock({
            $0.ownsConnectionGeneration(connectionGeneration)
        }) else {
            return
        }
        let peerLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peer.deviceId)
        SkyBridgeLogger.p2p.warning(
            "⚠️ P2P receive loop ended; tearing down exact connection owner: peer=\(peerLabel, privacy: .public) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
        )
        disconnect()
    }

    private func handleInboundFrame(
        _ payload: Data,
        from receivePeer: PeerIdentifier,
        connectionGeneration: UInt64
    ) async throws {
        try requireCurrentConnectionGeneration(connectionGeneration)
        // Phase C2: optional post-handshake traffic padding (SBP2).
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
        // Phase C1: optional handshake padding (SBP1).
        let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx")

        DispatchQueue.main.async {
            self.bytesReceived &+= UInt64(payload.count)
            self.lastActivity = Date()
        }

        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw P2PConnectionError.handshakeUnavailable
        }
        let isHandshakeControl = isLikelyHandshakeControlPacket(frame)

        let owner = currentOwnedHandshakeDriver()
        let driverPhase: P2PInboundFrameRoutingPolicy.DriverPhase
        if let owner {
            let driverState = await owner.driver.getCurrentState()
            try requireCurrentHandshakeOperation(
                owner.token,
                exactDriver: owner.driver
            )
            try requireCurrentConnectionGeneration(connectionGeneration)
            if case .established(let driverSessionKeys) = driverState {
                driverPhase = .established(sessionId: driverSessionKeys.sessionId)
            } else {
                driverPhase = .handshaking
            }
        } else {
            driverPhase = .absent
        }

        let publishedSessionId = sessionKeysLock.withLock({ $0?.sessionId })
        let route = P2PInboundFrameRoutingPolicy.route(
            driverPhase: driverPhase,
            publishedSessionId: publishedSessionId,
            isHandshakeControl: isHandshakeControl
        )

        switch route {
        case .handshakeDriver:
            guard let owner else {
                throw P2PConnectionError.inboundFrameWithoutOwner
            }
            await owner.driver.handleMessage(frame, from: receivePeer)
            try requireCurrentHandshakeOperation(
                owner.token,
                exactDriver: owner.driver
            )
            try requireCurrentConnectionGeneration(connectionGeneration)
            await syncHandshakeState(after: owner)

        case .authenticated(let expectedSessionId):
            guard let keys = sessionKeysLock.withLock({ $0 }),
                  expectedSessionId.map({ keys.sessionId == $0 }) ?? true else {
                throw P2PConnectionError.staleAuthenticatedFrame
            }
            try await handleAuthenticatedFrame(
                frame,
                keys: keys,
                connectionGeneration: connectionGeneration
            )

        case .awaitSessionHandoff(let sessionId):
            guard let owner else {
                throw P2PConnectionError.sessionHandoffUnavailable
            }
            let handoffKey = P2PSessionHandoffKey(
                operation: owner.token,
                sessionId: sessionId
            )
            do {
                try await sessionHandoffGate.wait(for: handoffKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw P2PConnectionError.sessionHandoffUnavailable
            }
            try requireCurrentConnectionGeneration(connectionGeneration)
            guard let publishedKeys = sessionKeysLock.withLock({ $0 }),
                  publishedKeys.sessionId == sessionId else {
                throw P2PConnectionError.sessionHandoffUnavailable
            }
            try await handleAuthenticatedFrame(
                frame,
                keys: publishedKeys,
                connectionGeneration: connectionGeneration
            )

        case .restartInboundRekey:
            guard let inboundOwner = await restartInboundRekeyDriver(for: frame) else {
                throw P2PConnectionError.unexpectedAuthenticatedHandshakeFrame
            }
            await inboundOwner.driver.handleMessage(frame, from: receivePeer)
            try requireCurrentHandshakeOperation(
                inboundOwner.token,
                exactDriver: inboundOwner.driver
            )
            try requireCurrentConnectionGeneration(connectionGeneration)
            await syncHandshakeState(after: inboundOwner)

        case .rejectNoOwner:
            throw P2PConnectionError.inboundFrameWithoutOwner

        case .rejectUnexpectedAuthenticatedHandshake:
            throw P2PConnectionError.unexpectedAuthenticatedHandshakeFrame
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handleAuthenticatedFrame(
        _ frame: Data,
        keys: SessionKeys,
        connectionGeneration: UInt64
    ) async throws {
        let plaintext = try decryptAppPayload(frame, with: keys)
        try requireCurrentConnectionGeneration(connectionGeneration)
        guard sessionKeysLock.withLock({ current in
            current?.sessionId == keys.sessionId
                && current?.receiveKey == keys.receiveKey
        }) else {
            throw P2PConnectionError.staleAuthenticatedFrame
        }
        if let envelope = BusinessEnvelope.decode(plaintext) {
            switch envelope.kind {
            case .remoteDesktopFrame:
                if let handler = remoteDesktopFrameHandlerLock.withLock({ $0 }) {
                    handler(envelope.payload, envelope.timestampNs)
                }
                return
            }
        }

        let message: AppMessage
        do {
            message = try AppMessage.decodeWireMessage(from: plaintext)
        } catch {
            throw P2PConnectionError.invalidAuthenticatedPayload
        }
        try requireCurrentConnectionGeneration(connectionGeneration)
        guard sessionKeysLock.withLock({ current in
            current?.sessionId == keys.sessionId
                && current?.receiveKey == keys.receiveKey
        }) else {
            throw P2PConnectionError.staleAuthenticatedFrame
        }
        let authenticatedConversationFingerprint: String?
        switch message {
        case .textMessage, .textMessageReceipt:
            authenticatedConversationFingerprint = try conversationFingerprintForAuthenticatedFrame(
                keys: keys,
                connectionGeneration: connectionGeneration
            )
        default:
            authenticatedConversationFingerprint = nil
        }
        try await handleAppMessage(
            message,
            authenticatedConversationFingerprint: authenticatedConversationFingerprint
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func conversationFingerprintForAuthenticatedFrame(
        keys: SessionKeys,
        connectionGeneration: UInt64
    ) throws -> String {
        try handshakeOperationLock.withLock { registry in
            guard registry.ownsConnectionGeneration(connectionGeneration),
                  let currentKeys = sessionKeysLock.withLock({ $0 }),
                  currentKeys.sessionId == keys.sessionId,
                  currentKeys.receiveKey == keys.receiveKey,
                  let binding = authenticatedHandshakePeerBindingLock.withLock({ $0 }) else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            do {
                return try DeviceTextMessagePolicy.normalizedConversationFingerprint(
                    binding.authority.protocolPublicKeyFingerprint
                )
            } catch {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw AuthenticatedAppPayloadCryptoError.combinedCiphertextUnavailable
        }
        return combined
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
        if data.count == 38, (try? HandshakeFinished.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    static func shouldRestartInboundHandshakeForRekey(
        state: HandshakeState,
        frame: Data
    ) -> Bool {
        switch state {
        case .waitingFinished, .established:
            return (try? HandshakeMessageA.decode(from: frame)) != nil
        default:
            return false
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func restartInboundRekeyDriver(for frame: Data) async -> OwnedHandshakeDriver? {
        guard sessionKeysLock.withLock({ $0 }) != nil else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }

        let operation: P2PHandshakeOperationToken
        do {
            operation = try await beginHandshakeOperation(kind: .inboundRekey)
        } catch {
            return nil
        }
        var installedOwner: OwnedHandshakeDriver?
        var releasedArbiterLease: PeerSessionArbiter.EstablishedLease?
        var previousSessionForRollback: EstablishedSessionSnapshot?

        do {
            guard let previousSession = try await currentEstablishedSessionSnapshot(
                for: operation
            ) else {
                throw P2PConnectionError.noSessionKeys
            }
            previousSessionForRollback = previousSession
            let compatibilityModeEnabled = UserDefaults.standard.bool(
                forKey: "Settings.EnableCompatibilityMode"
            )
            let requestedPolicy = HandshakePolicy.recommendedDefault(
                compatibilityModeEnabled: compatibilityModeEnabled
            )
            let capability = CryptoProviderFactory.detectCapability()
            let localPQCAvailable = capability.hasApplePQC || capability.hasLiboqs
            let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
            #if !os(macOS)
            let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
            #endif
            #if os(macOS)
            let inboundProtocolIdentity = try await InboundProtocolIdentitySelectionPolicy.resolve(
                messageA: messageA,
                candidateDeviceIds: [handshakePeer.deviceId]
            )
            try requireCurrentHandshakeOperation(operation)
            #else
            let inboundProtocolIdentity = InboundProtocolIdentitySelection(
                algorithm: peerHasPQCGroup ? .mlDSA65 : .ed25519,
                protection: .softwareKeychain
            )
            #endif
            if StrictPQCAdmissionGate.inboundRejection(
                policy: requestedPolicy,
                peerSupportedSuites: messageA.supportedSuites,
                localPQCSuitesAvailable: localPQCAvailable
            ) == .peerOfferedClassicOnly {
                throw P2PConnectionError.inboundRekeyRejected
            }

            let effectivePolicy = requestedPolicy
            var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(
                policy: .classicOnly
            )
            var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
            var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter {
                !$0.isPQCGroup
            }

            if inboundProtocolIdentity.algorithm != .ed25519 {
                let selection: CryptoProviderFactory.SelectionPolicy =
                    effectivePolicy.requirePQC ? .requirePQC : .preferPQC
                cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                    policy: selection,
                    peerSupportedSuites: messageA.supportedSuites
                )
                let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(
                    using: cryptoProvider
                )
                if StrictPQCAdmissionGate.inboundRejection(
                    policy: effectivePolicy,
                    peerSupportedSuites: messageA.supportedSuites,
                    localPQCSuitesAvailable: !localPQCSuites.isEmpty
                ) != nil {
                    throw P2PConnectionError.inboundRekeyRejected
                }
                if localPQCSuites.isEmpty {
                    #if os(macOS)
                    throw P2PConnectionError.inboundRekeyRejected
                    #else
                    guard peerHasClassicGroup else {
                        throw P2PConnectionError.inboundRekeyRejected
                    }
                    cryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                    sigAAlgorithm = .ed25519
                    offeredSuites = cryptoProvider.supportedSuites.filter {
                        !$0.isPQCGroup
                    }
                    #endif
                } else {
                    let compatibleSuites = InboundProtocolIdentitySelectionPolicy
                        .compatibleResponderPQCSuites(
                            localPQCSuites,
                            algorithm: inboundProtocolIdentity.algorithm
                        )
                    guard !compatibleSuites.isEmpty else {
                        throw P2PConnectionError.inboundRekeyRejected
                    }
                    sigAAlgorithm = inboundProtocolIdentity.algorithm
                    offeredSuites = compatibleSuites
                }
            }

            let localSOAPeerId = try await localSOAPeerIdBytes()
            try requireCurrentHandshakeOperation(operation)
            let soaBinding = InboundHandshakeAdapter.bindSOAState(
                from: messageA,
                localPeerId: localSOAPeerId
            )
            let identityProvider = DeviceIdentityHandshakeProvider(
                sigAAlgorithm: sigAAlgorithm,
                protocolSigningKeyProtection: inboundProtocolIdentity.protection,
                includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
            )
            let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: offeredSuites)
            let exactDriverLock = OSAllocatedUnfairLock<HandshakeDriver?>(initialState: nil)
            let transport = DirectHandshakeTransport(sendFramed: { [weak self] data in
                guard let self,
                      let exactDriver = exactDriverLock.withLock({ $0 }) else {
                    throw P2PConnectionError.disconnected
                }
                try self.requireCurrentHandshakeOperation(
                    operation,
                    exactDriver: exactDriver
                )
                try await self.sendFramed(data)
                try self.requireCurrentHandshakeOperation(
                    operation,
                    exactDriver: exactDriver
                )
            })
            let driver = try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ProtocolSignatureProviderSelector.select(
                    for: sigAAlgorithm
                ),
                identityProvider: identityProvider,
                sigAAlgorithm: sigAAlgorithm,
                offeredSuites: offeredSuites,
                policy: effectivePolicy,
                cryptoPolicy: cryptoPolicy,
                localSOAPeerId: localSOAPeerId,
                expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId
            )
            exactDriverLock.withLock { $0 = driver }
            let owner = try await installHandshakeDriver(driver, for: operation)
            installedOwner = owner

            if previousSession.soaPairKey != nil,
               previousSession.arbiterLease == nil {
                throw P2PConnectionError.arbiterLeaseUnavailable
            }
            if let activeArbiterLease = previousSession.arbiterLease {
                guard previousSession.soaPairKey == activeArbiterLease.pairKey,
                      await PeerSessionArbiter.shared.clearEstablished(activeArbiterLease) else {
                    try requireCurrentHandshakeOperation(
                        operation,
                        exactDriver: owner.driver
                    )
                    throw P2PConnectionError.arbiterLeaseUnavailable
                }
                try requireCurrentHandshakeOperation(
                    operation,
                    exactDriver: owner.driver
                )
                releasedArbiterLease = activeArbiterLease
            }

            let staged = handshakeOperationLock.withLock { registry -> Bool in
                guard registry.owns(operation, exactDriver: owner.driver) else {
                    return false
                }
                if let activeArbiterLease = previousSession.arbiterLease {
                    guard establishedArbiterLeaseLock.withLock({ $0 })
                        == activeArbiterLease else {
                        return false
                    }
                }
                sessionKeysLock.withLock { $0 = nil }
                establishedArbiterLeaseLock.withLock { $0 = nil }
                soaPairKeyLock.withLock { $0 = nil }
                rekeyInProgressLock.withLock { $0 = true }
                inboundRekeyRollbackLock.withLock {
                    $0 = InboundRekeyRollbackReceipt(
                        owner: owner,
                        previousSession: previousSession
                    )
                }
                return true
            }
            guard staged else {
                throw P2PConnectionError.staleHandshakeOperation
            }
            let targetSuites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
            SkyBridgeLogger.p2p.info(
                "🔁 inbound rekey start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) current=\(previousSession.keys.negotiatedSuite.rawValue, privacy: .public) target=\(targetSuites, privacy: .public)"
            )
            return owner
        } catch {
            let originalError = error
            if let installedOwner {
                await detachAndCancelDriverIfOwned(installedOwner)
            }
            if let releasedArbiterLease {
                do {
                    try await restoreReleasedArbiterLease(
                        releasedArbiterLease,
                        for: operation
                    )
                } catch {
                    SkyBridgeLogger.p2p.error(
                        "❌ inbound rekey rollback failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                    )
                    disconnect()
                    return nil
                }
            }
            if let previousSessionForRollback {
                do {
                    try await failHandshakeOperation(
                        operation,
                        restoring: previousSessionForRollback,
                        terminalStatus: .authenticated
                    )
                } catch {
                    SkyBridgeLogger.p2p.error(
                        "❌ inbound rekey setup rollback could not restore the previous session: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                    )
                    disconnect()
                    return nil
                }
            } else {
                _ = handshakeOperationLock.withLock { registry -> Bool in
                    guard registry.owns(operation) else { return false }
                    inboundRekeyRollbackLock.withLock { $0 = nil }
                    rekeyInProgressLock.withLock { $0 = false }
                    return registry.finish(operation)
                }
            }
            SkyBridgeLogger.p2p.error(
                "❌ inbound rekey setup failed: \(SkyBridgeDiagnosticRedaction.errorSummary(originalError), privacy: .public)"
            )
            return nil
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func syncHandshakeState(after owner: OwnedHandshakeDriver) async {
        let state = await owner.driver.getCurrentState()
        guard (try? requireCurrentHandshakeOperation(
            owner.token,
            exactDriver: owner.driver
        )) != nil else {
            return
        }
        // Outbound authentication owns its terminal publication in
        // `authenticate()`. The receive loop may observe `.established` first,
        // but it must never race that owner or publish a second copy.
        guard owner.token.kind == .inboundRekey else { return }
        guard let rollbackReceipt = inboundRekeyRollbackLock.withLock({
            receipt -> InboundRekeyRollbackReceipt? in
            guard let receipt,
                  receipt.owner.token == owner.token,
                  receipt.owner.driver === owner.driver else {
                return nil
            }
            return receipt
        }) else {
            return
        }

        switch state {
        case .established(let keys):
            do {
                let peerBinding = await owner.driver.getAuthenticatedHandshakePeerBinding()
                try requireCurrentHandshakeOperation(
                    owner.token,
                    exactDriver: owner.driver
                )
                guard let peerBinding else {
                    throw P2PConnectionError.authenticatedBindingUnavailable
                }
                let newArbiterLease = await owner.driver.getEstablishedArbiterLease()
                try requireCurrentHandshakeOperation(
                    owner.token,
                    exactDriver: owner.driver
                )

                let pairKey: Data?
                if let previousPairKey = rollbackReceipt.previousSession.soaPairKey {
                    guard peerBinding.authenticatedRemoteSOAPeerId
                            == rollbackReceipt.previousSession.peerBinding
                                .authenticatedRemoteSOAPeerId,
                          let newArbiterLease,
                          newArbiterLease.pairKey == previousPairKey,
                          newArbiterLease.sessionId == keys.sessionId else {
                        throw P2PConnectionError.arbiterLeaseUnavailable
                    }
                    pairKey = previousPairKey
                } else {
                    guard newArbiterLease == nil else {
                        throw P2PConnectionError.arbiterLeaseUnavailable
                    }
                    pairKey = nil
                }
                let receipt = EstablishedHandshakeReceipt(
                    owner: owner,
                    keys: keys,
                    peerBinding: peerBinding,
                    soaPairKey: pairKey,
                    arbiterLease: newArbiterLease
                )
                try publishEstablishedSession(receipt)
                inboundRekeyRollbackLock.withLock { $0 = nil }
                try await publishAuthenticatedPresence(
                    keys: keys,
                    operationOwner: owner
                )
                try await publishStatus(
                    .authenticated,
                    for: owner.token,
                    exactDriver: owner.driver
                )
                guard finishHandshakeOperation(owner) else {
                    throw P2PConnectionError.staleHandshakeOperation
                }
                await retireClassicTransferSessionLeases(
                    except: classicTransferSessionIdentifier(for: keys)
                )
                startMetricsIfNeeded()
            } catch {
                let failure = error
                do {
                    try await failHandshakeOperation(
                        owner.token,
                        restoring: rollbackReceipt.previousSession,
                        terminalStatus: .authenticated
                    )
                } catch {
                    SkyBridgeLogger.p2p.error(
                        "❌ inbound rekey commit rollback failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                    )
                    disconnect()
                    return
                }
                SkyBridgeLogger.p2p.error(
                    "❌ inbound rekey commit rejected: \(SkyBridgeDiagnosticRedaction.errorSummary(failure), privacy: .public)"
                )
            }

        case .failed(let reason):
            do {
                try await failHandshakeOperation(
                    owner.token,
                    restoring: rollbackReceipt.previousSession,
                    terminalStatus: .authenticated
                )
                SkyBridgeLogger.p2p.warning(
                    "⚠️ inbound rekey failed; restored previous exact session. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public) suite=\(rollbackReceipt.previousSession.keys.negotiatedSuite.rawValue, privacy: .public)"
                )
                return
            } catch {
                SkyBridgeLogger.p2p.error(
                    "❌ inbound rekey failure rollback failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                disconnect()
            }

        default:
            break
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishAuthenticatedPresence(
        keys: SessionKeys,
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil,
        operationOwner: OwnedHandshakeDriver? = nil
    ) async throws {
        try await publishClassicTransferSessionSnapshot(
            keys: keys,
            remoteIdentityPayload: remoteIdentityPayload,
            operationOwner: operationOwner
        )

        let suite = keys.negotiatedSuite
        let cryptoKind = ConnectionCryptoPresentation.modeLabel(
            kind: nil,
            suite: suite.rawValue
        ) ?? suite.rawValue
        let declaredPeerId = normalizedNonEmptyString(remoteIdentityPayload?.deviceId)
        let remoteDisplayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(remoteIdentityPayload?.deviceName)
        let advertisedTransferPort = remoteIdentityPayload?.fileTransferPort.flatMap { port -> Int? in
            let value = Int(port)
            return (1...65535).contains(value) ? value : nil
        }

        let didPublishPresence = await MainActor.run { () -> Bool in
            guard !self.handshakeOperationLock.withLock({ $0.isDisconnected }) else {
                return false
            }
            if let operationOwner {
                guard self.handshakeOperationLock.withLock({
                    $0.owns(
                        operationOwner.token,
                        exactDriver: operationOwner.driver
                    )
                }) else { return false }
            }
            let peerId = declaredPeerId ?? self.handshakePeer.deviceId
            let displayName = remoteDisplayName ?? self.device.name
            let address = self.resolveCurrentRemoteIP() ?? self.device.address
            let endpointLabel = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? self.handshakePeer.deviceId
                : "host:\(address)"
            let resolvedRoute = P2PDiscoveryService.resolveInboundPresenceRoute(
                peerId: peerId,
                endpointLabel: endpointLabel,
                discoveredDevices: P2PDiscoveryService.shared.discoveredDevices,
                unifiedDevices: UnifiedOnlineDeviceSnapshotAccess.snapshot()
            )
            let displayAddress = resolvedRoute.displayAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let transferAddress = displayAddress?.isEmpty == false ? displayAddress! : address
            let transferPort = advertisedTransferPort ?? resolvedRoute.transferPort

            let routeDescriptor: ConnectionPresenceService.PresenceRouteDescriptor?
            if !transferAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (1...65535).contains(transferPort) {
                let resolvedRouteDescriptor = ConnectionPresenceService.PresenceRouteDescriptor(
                    peerId: peerId,
                    deviceName: remoteDisplayName ?? resolvedRoute.name,
                    displayAddress: transferAddress,
                    transferAddress: transferAddress,
                    transferPort: transferPort,
                    routeSource: .outbound,
                    connectedAt: Date()
                )
                routeDescriptor = resolvedRouteDescriptor
            } else {
                routeDescriptor = nil
            }

            let publishedDisplayName = routeDescriptor == nil
                ? displayName
                : (remoteDisplayName ?? resolvedRoute.name)
            let publishedAddress = routeDescriptor == nil ? address : transferAddress
            if let activeLease = self.presenceLeaseLock.withLock({ $0 }) {
                guard ConnectionPresenceService.shared.refreshConnectedIfOwned(
                    activeLease,
                    displayName: publishedDisplayName,
                    address: publishedAddress,
                    cryptoKind: cryptoKind,
                    suite: suite.rawValue,
                    routeDescriptor: routeDescriptor
                ) else {
                    return false
                }
            } else {
                let newLease = ConnectionPresenceService.shared.markConnectedOwned(
                    peerId: peerId,
                    displayName: publishedDisplayName,
                    address: publishedAddress,
                    cryptoKind: cryptoKind,
                    suite: suite.rawValue,
                    routeDescriptor: routeDescriptor
                )
                guard let newLease else { return false }
                self.presenceLeaseLock.withLock { $0 = newLease }
            }
            #if os(macOS)
            // `UnifiedOnlineDeviceManager` 是 macOS 侧在线设备聚合器（UI 展示用），不参与 P2P 协议决策。
            UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                peerId: peerId,
                displayName: displayName,
                cryptoKind: cryptoKind,
                suite: suite.rawValue,
                guardStatus: "守护中"
            )
            #endif
            return true
        }
        guard didPublishPresence else {
            throw P2PConnectionError.presenceLeaseUnavailable
        }
        if let operationOwner {
            try requireCurrentHandshakeOperation(
                operationOwner.token,
                exactDriver: operationOwner.driver
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handleAppMessage(
        _ message: AppMessage,
        authenticatedConversationFingerprint: String?
    ) async throws {
        if rekeyInProgressLock.withLock({ $0 }), !Self.isBootstrapControlMessage(message) {
            SkyBridgeLogger.p2p.debug(
                "ℹ️ bootstrap-assisted 模式下丢弃非引导控制消息: type=\(Self.appMessageKindForDiagnostics(message), privacy: .public)"
            )
            return
        }
        switch message {
        case .clipboard(let payload):
            // 随航剪贴板：把远端剪贴板内容交给 ClipboardSyncService 应用到本地（仅 macOS 主机端）。
            #if os(macOS)
            guard let decodedData = payload.decodedData else {
                throw P2PConnectionError.invalidAuthenticatedPayload
            }
            try await ClipboardSyncService.shared.ingestRemoteContent(
                mimeType: payload.mimeType,
                data: decodedData,
                fromDeviceID: handshakePeer.deviceId
            )
            #else
            _ = payload
            #endif
        case .textMessage(let payload):
            guard let fingerprint = authenticatedConversationFingerprint else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            try await DeviceMessagingService.shared.handleIncoming(
                payload,
                fingerprint: fingerprint
            )
            if let deliveryAttemptID = payload.deliveryAttemptID {
                try await sendEncryptedAppMessage(.textMessageReceipt(.init(
                    messageID: payload.id,
                    deliveryAttemptID: deliveryAttemptID
                )))
            }
        case .textMessageReceipt(let payload):
            guard let fingerprint = authenticatedConversationFingerprint else {
                throw P2PConnectionError.authenticatedBindingUnavailable
            }
            try await DeviceMessagingService.shared.handleAuthenticatedReceipt(
                payload,
                fingerprint: fingerprint
            )
        case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding,
             .protocolIdentityBindingConfirm, .signedProtocolIdentityBindingFinalAck:
            break
        case .pairingIdentityExchange(let payload):
            await handlePairingIdentityExchange(payload)
        case .heartbeat(let payload):
            guard let keys = sessionKeysLock.withLock({ $0 }) else {
                throw P2PConnectionError.noSessionKeys
            }
            try await refreshClassicTransferSessionFromHeartbeat(payload, keys: keys)
        case .authenticatedRouteBinding:
            break
        case .peerDisconnecting:
            disconnect()
        case .ping(let payload):
            guard !rekeyInProgressLock.withLock({ $0 }) else { return }
            // RTT probe: reply as fast as possible.
            do {
                try await sendEncryptedAppMessage(.pong(.init(id: payload.id)))
            } catch {
                SkyBridgeLogger.p2p.error(
                    "⛔️ authenticated pong reply failed; closing session: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                throw P2PConnectionError.authenticatedPongReplyFailed
            }
        case .pong(let payload):
            handlePong(id: payload.id)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func isCurrentPairingOperation(
        keys expectedKeys: SessionKeys,
        authority expectedAuthority: AuthenticatedRemoteAuthority
    ) -> Bool {
        guard !Task.isCancelled,
              !rekeyInProgressLock.withLock({ $0 }),
              let currentKeys = sessionKeysLock.withLock({ $0 }),
              currentKeys.sessionId == expectedKeys.sessionId,
              currentKeys.transcriptHash == expectedKeys.transcriptHash,
              authenticatedRemoteAuthorityLock.withLock({ $0 }) == expectedAuthority else {
            return false
        }
        if case .ready = connection.state { return true }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func rollbackPairingCommit(
        _ reservation: PairingIdentityExchangeCommitCoordinator.Reservation
    ) async {
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(reservation)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handlePairingIdentityExchange(_ payload: AppMessage.PairingIdentityExchangePayload) async {
        guard let payload = payload.normalizedBootstrapPayload else {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairingIdentityExchange rejected: invalid declaredDeviceId or KEM identity payload"
            )
            disconnect()
            return
        }

        guard let expectedKeys = sessionKeysLock.withLock({ $0 }),
              let expectedAuthority = authenticatedRemoteAuthorityLock.withLock({ $0 }) else {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairingIdentityExchange has no authenticated session owner"
            )
            disconnect()
            return
        }

        guard let validatedAuthority = await validatedPairingIdentityAuthority(for: payload) else {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairingIdentityExchange rejected before persistence: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public) reason=identity_authority_unbound"
            )
            disconnect()
            return
        }

        let reservation: PairingIdentityExchangeCommitCoordinator.Reservation
        do {
            reservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
                deviceIds: validatedAuthority.authorizedDeviceIds
            )
        } catch {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairing commit admission unavailable: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            disconnect()
            return
        }

        guard isCurrentPairingOperation(
            keys: expectedKeys,
            authority: expectedAuthority
        ) else {
            await rollbackPairingCommit(reservation)
            return
        }

        let transportIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.isCurrentPairingOperation(
                keys: expectedKeys,
                authority: expectedAuthority
            ) == true
        }
        let displayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(device.name)
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(handshakePeer.displayName)
        let commitReceipt: PairingIdentityExchangeCommitCoordinator.CommitReceipt
        do {
            let result = try await PairingIdentityExchangeCommitCoordinator
                .commitAuthorityAndKEM(
                    reservation: reservation,
                    payload: payload,
                    authority: expectedAuthority,
                    displayName: displayName,
                    isCurrent: transportIsCurrent
                )
            guard case .committed(let receipt) = result else { return }
            commitReceipt = receipt
        } catch is CancellationError {
            return
        } catch {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairing authority/KEM commit failed closed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            disconnect()
            return
        }

        do {
            try await PairingIdentityExchangeCommitCoordinator.withCommittedReceipt(
                commitReceipt
            ) {
        guard await PairingIdentityExchangeCommitCoordinator.isCurrent(
            commitReceipt,
            transportIsCurrent: transportIsCurrent
        ) else {
            return
        }

        recordRemoteControlSecurityIdentity(
            from: payload,
            validatedAuthority: validatedAuthority
        )
        let shouldForceIdentityReply = latestRemotePairingIdentityPayloadLock.withLock { current -> Bool in
            let previousDeviceId = normalizedNonEmptyString(current?.deviceId)
            guard let previousDeviceId else { return true }
            return previousDeviceId.caseInsensitiveCompare(payload.deviceId) != .orderedSame
        }
        latestRemotePairingIdentityPayloadLock.withLock { $0 = payload }

        if let keys = sessionKeysLock.withLock({ $0 }) {
            do {
                try await publishAuthenticatedPresence(
                    keys: keys,
                    remoteIdentityPayload: payload
                )
            } catch {
                SkyBridgeLogger.p2p.error(
                    "⛔️ pairingIdentityExchange presence publication failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                disconnect()
                return
            }
        }

        guard await PairingIdentityExchangeCommitCoordinator.isCurrent(
            commitReceipt,
            transportIsCurrent: transportIsCurrent
        ) else {
            return
        }

        do {
            try await sendPairingIdentityExchange(force: shouldForceIdentityReply)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange reply failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
        }

        SkyBridgeLogger.p2p.info(
            "🔑 committed generation-bound pairing authority/KEM: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
        )
            }
        } catch is CancellationError {
            return
        } catch {
            SkyBridgeLogger.p2p.error(
                "⛔️ pairing post-commit side effects failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            disconnect()
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    internal static func isBootstrapControlMessage(_ message: AppMessage) -> Bool {
        if case .pairingIdentityExchange = message {
            return true
        }
        if case .kemRefreshRequest = message {
            return true
        }
        if case .signedKEMRefresh = message {
            return true
        }
        if case .kemRefreshFailure = message {
            return true
        }
        if case .protocolIdentityBindingRequest = message {
            return true
        }
        if case .signedProtocolIdentityBinding = message {
            return true
        }
        if case .protocolIdentityBindingConfirm = message {
            return true
        }
        if case .signedProtocolIdentityBindingFinalAck = message {
            return true
        }
        return false
    }

    /// Payload-free diagnostic classification. `String(describing:)` on an
    /// associated-value enum can expose clipboard contents, text messages, and
    /// route authority metadata when the log field is public.
    @available(macOS 14.0, iOS 17.0, *)
    private static func appMessageKindForDiagnostics(_ message: AppMessage) -> String {
        switch message {
        case .clipboard: "clipboard"
        case .textMessage: "textMessage"
        case .textMessageReceipt: "textMessageReceipt"
        case .pairingIdentityExchange: "pairingIdentityExchange"
        case .kemRefreshRequest: "kemRefreshRequest"
        case .signedKEMRefresh: "signedKEMRefresh"
        case .kemRefreshFailure: "kemRefreshFailure"
        case .protocolIdentityBindingRequest: "protocolIdentityBindingRequest"
        case .signedProtocolIdentityBinding: "signedProtocolIdentityBinding"
        case .protocolIdentityBindingConfirm: "protocolIdentityBindingConfirm"
        case .signedProtocolIdentityBindingFinalAck: "signedProtocolIdentityBindingFinalAck"
        case .heartbeat: "heartbeat"
        case .authenticatedRouteBinding: "authenticatedRouteBinding"
        case .peerDisconnecting: "peerDisconnecting"
        case .ping: "ping"
        case .pong: "pong"
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    internal static func classifySessionAssurance(
        policy: HandshakePolicy,
        negotiatedSuite: CryptoSuite,
        bootstrapAssisted: Bool
    ) -> P2PSessionAssuranceLevel {
        if bootstrapAssisted {
            return .bootstrapAssisted
        }
        if negotiatedSuite.isPQCGroup {
            return .pqcStrict
        }
        if !policy.requirePQC {
            return .legacyClassic
        }
        return .unknown
    }

    private func normalizedNonEmptyString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func validatedPairingIdentityAuthority(
        for payload: AppMessage.PairingIdentityExchangePayload
    ) async -> ValidatedPairingIdentityAuthority? {
        guard let binding = authenticatedHandshakePeerBindingLock.withLock({ $0 }) else {
            return nil
        }
        return await AuthenticatedProtocolIdentityBinding
            .validatedPairingIdentityAuthorityForPersistence(
            payload: payload,
            authority: binding.authority,
            authenticatedRemoteSOAPeerId: binding.authenticatedRemoteSOAPeerId,
            sessionDeviceIds: [
                handshakePeer.deviceId,
                device.deviceId,
                device.persistentDeviceId
            ].compactMap { $0 }
        )
    }

}

#if DEBUG || SKYBRIDGE_TESTING
extension P2PConnection {
    @MainActor
    func testingSetStatus(_ status: P2PConnectionStatus) {
        self.status = status
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testingSetAuthenticatedRemoteAuthority(_ authority: AuthenticatedRemoteAuthority?) {
        authenticatedRemoteAuthorityLock.withLock { $0 = authority }
    }
}
#endif

public enum P2PConnectionError: Error, LocalizedError, Sendable {
    case handshakeUnavailable
    case noSessionKeys
    case disconnected
    case invalidFrameLength(Int)
    case invalidAuthenticatedPayload
    case inboundFrameWithoutOwner
    case unexpectedAuthenticatedHandshakeFrame
    case sessionHandoffUnavailable
    case staleAuthenticatedFrame
    case authenticatedPongReplyFailed
    case bootstrapKEMKeyTimeout
    case bootstrapControlOnly
    case postAuthPairingIdentityExchangeTimeout
    case arbiterLeaseUnavailable
    case presenceLeaseUnavailable
    case classicTransferSessionLeaseUnavailable
    case staleHandshakeOperation
    case authenticatedBindingUnavailable
    case authenticatedIdentityMismatch
    case inboundRekeyRejected
    case handshakeOperationInProgress
    case handshakeOperationSequenceExhausted
    case capacityExceeded(resource: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .handshakeUnavailable:
            return "握手不可用：系统版本不满足要求"
        case .noSessionKeys:
            return "尚未建立会话密钥"
        case .disconnected:
            return "连接已断开"
        case .invalidFrameLength(let length):
            return "无效的帧长度：\(length)"
        case .invalidAuthenticatedPayload:
            return "已认证业务载荷既不是有效 BusinessEnvelope，也不是有效 AppMessage"
        case .inboundFrameWithoutOwner:
            return "入站 P2P 帧没有绑定到握手或已认证会话所有者"
        case .unexpectedAuthenticatedHandshakeFrame:
            return "已认证业务通道收到未被握手驱动消费的握手控制帧"
        case .sessionHandoffUnavailable:
            return "握手已完成但对应的已认证会话尚未原子发布"
        case .staleAuthenticatedFrame:
            return "入站业务帧所属的已认证会话已被替换"
        case .authenticatedPongReplyFailed:
            return "已认证业务通道的 pong 回复发送失败"
        case .bootstrapKEMKeyTimeout:
            return "等待对端 KEM 公钥超时（请确认对端已批准配对/信任并重试）"
        case .bootstrapControlOnly:
            return "引导恢复期间仅允许 pairingIdentityExchange 控制消息"
        case .postAuthPairingIdentityExchangeTimeout:
            return "post-auth pairingIdentityExchange 超时"
        case .arbiterLeaseUnavailable:
            return "SOA 会话所有权已失效，必须重新连接"
        case .presenceLeaseUnavailable:
            return "在线状态所有权已被替换，必须关闭陈旧连接"
        case .classicTransferSessionLeaseUnavailable:
            return "文件传输会话所有权已失效，必须关闭陈旧连接"
        case .staleHandshakeOperation:
            return "握手操作已被断开或替换，禁止发布陈旧结果"
        case .authenticatedBindingUnavailable:
            return "握手已完成但缺少已认证的对端身份绑定"
        case .authenticatedIdentityMismatch:
            return "当前已认证对端身份与消息会话不匹配"
        case .inboundRekeyRejected:
            return "入站 rekey 不符合当前加密或身份策略"
        case .handshakeOperationInProgress:
            return "当前连接已有握手或 rekey 操作在进行"
        case .handshakeOperationSequenceExhausted:
            return "当前连接的握手操作序列已耗尽，必须新建连接"
        case .capacityExceeded(let resource, let limit):
            return "P2P \(resource) 已达安全上限（\(limit)）"
        }
    }
}

// MARK: - 扩展和辅助方法

extension P2PDevice {
 /// 信号强度 (0.0 - 1.0)
    public var signalStrength: Double {
 // 基于距离和网络质量计算信号强度
        let baseStrength = 1.0 - min(1.0, Double(port) / 65535.0 * 0.3)
        return max(0.1, baseStrength)
    }
    
 /// 信任日期
 /// Swift 6.2.1：通过 DeviceSecurityManager 单例获取设备信任日期
    @MainActor
    public var trustedDate: Date? {
        return DeviceSecurityManager.shared.getTrustedDate(for: id)
    }
    
 /// 创建模拟设备用于预览
    public static var mockDevice: P2PDevice {
        P2PDevice(
            id: "mock-device-id",
            name: "测试设备",
            type: .macOS,
            address: "192.168.1.100",
            port: 8080,
            osVersion: "macOS 14.0",
            capabilities: ["remote_desktop", "file_transfer"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["192.168.1.100:8080"]
        )
    }
}

extension P2PConnection {
 /// 连接延迟（秒）
    public var latency: Double {
        measuredLatency
    }
    
 /// 带宽（字节/秒）
    public var bandwidth: Double {
        measuredBandwidthBytesPerSecond
    }
    
 /// 连接质量
    public var quality: P2PConnectionQuality {
        let score: Int = {
            // Keep the same thresholds as P2PNetworkManager for consistent UI.
            let latency = measuredLatency
            let loss = measuredPacketLoss
            if latency <= 0 { return 0 }
            if latency < 0.05 && loss < 0.01 { return 90 }
            if latency < 0.1 && loss < 0.03 { return 70 }
            if latency < 0.2 && loss < 0.05 { return 50 }
            return 20
        }()
        return P2PConnectionQuality(
            latency: measuredLatency,
            packetLoss: measuredPacketLoss,
            bandwidth: UInt64(max(0, measuredBandwidthBytesPerSecond)),
            stabilityScore: score
        )
    }
}
