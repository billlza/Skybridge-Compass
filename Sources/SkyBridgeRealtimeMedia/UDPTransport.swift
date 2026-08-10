import Foundation
import Network
import SkyBridgeAppleTransport

public struct SkyBridgeMediaEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let relayToken: String?
    public let expiresAt: TimeInterval?

    public init(host: String, port: UInt16, relayToken: String? = nil, expiresAt: TimeInterval? = nil) {
        self.host = host
        self.port = port
        self.relayToken = relayToken
        self.expiresAt = expiresAt
    }
}

public protocol SkyBridgeRealtimeMediaTransport: Sendable {
    func start() async throws
    func send(_ packet: Data) async throws
    func stop() async
}

public enum SkyBridgeRealtimeMediaTransportError: Error, LocalizedError, Sendable {
    case udpConnectionReadyTimedOut
    case udpLocalNetworkPermissionDenied
    case udpListenerMissingBoundPort
    case udpListenerReadyTimedOut
    case udpReceiverAlreadyStarted
    case udpReadyPathMismatch
    case relayBindRejected(String)
    case relayBindMalformed
    case relayBindTimedOut

    public var errorDescription: String? {
        switch self {
        case .udpConnectionReadyTimedOut:
            return "udp connection did not become ready before timeout"
        case .udpLocalNetworkPermissionDenied:
            return "udp local network permission denied"
        case .udpListenerMissingBoundPort:
            return "udp listener became ready without a bound port"
        case .udpListenerReadyTimedOut:
            return "udp listener did not become ready before timeout"
        case .udpReceiverAlreadyStarted:
            return "udp receiver is already starting or active"
        case .udpReadyPathMismatch:
            return "udp ready path did not preserve the authenticated interface binding"
        case .relayBindRejected(let reason):
            return "media relay bind rejected: \(reason)"
        case .relayBindMalformed:
            return "media relay bind response malformed"
        case .relayBindTimedOut:
            return "media relay bind timed out"
        }
    }

    public var stableCode: String {
        switch self {
        case .udpConnectionReadyTimedOut:
            return "udp_connection_ready_timed_out"
        case .udpLocalNetworkPermissionDenied:
            return "udp_local_network_permission_denied"
        case .udpListenerMissingBoundPort:
            return "udp_listener_missing_bound_port"
        case .udpListenerReadyTimedOut:
            return "udp_listener_ready_timed_out"
        case .udpReceiverAlreadyStarted:
            return "udp_receiver_already_started"
        case .udpReadyPathMismatch:
            return "udp_ready_path_mismatch"
        case .relayBindRejected:
            return "relay_bind_rejected"
        case .relayBindMalformed:
            return "relay_bind_malformed"
        case .relayBindTimedOut:
            return "relay_bind_timed_out"
        }
    }
}

public enum SkyBridgeRealtimeMediaRelayBindPolicy: Sendable, Equatable {
    case requireAcknowledgement
    case optimisticAfterSend
}

public enum SkyBridgeRealtimeMediaTransportEvent: Sendable, Equatable {
    case udpConnectionReady
    case relayBindSent
    case relayBindAccepted
    case relayBindAckTimedOut
    case relayBindRejected(String)
    case relayBindMalformed
}

public struct SkyBridgeMediaReceivedDatagram: Sendable {
    public let packet: Data
    public let remoteEndpoint: SkyBridgeMediaEndpoint?

    public init(packet: Data, remoteEndpoint: SkyBridgeMediaEndpoint?) {
        self.packet = packet
        self.remoteEndpoint = remoteEndpoint
    }
}

public final class SkyBridgeUDPRealtimeMediaReceiver: @unchecked Sendable {
    public typealias PacketHandler = @Sendable (SkyBridgeMediaReceivedDatagram) -> Void
    public typealias TerminalFailureHandler = @Sendable (Error) -> Void

    fileprivate final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: Result<SkyBridgeMediaEndpoint, Error>?
        private var continuation: CheckedContinuation<SkyBridgeMediaEndpoint, Error>?

        func wait() async throws -> SkyBridgeMediaEndpoint {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(with: completion)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        @discardableResult
        func complete(_ result: Result<SkyBridgeMediaEndpoint, Error>) -> Bool {
            lock.lock()
            guard completion == nil else {
                lock.unlock()
                return false
            }
            completion = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    fileprivate final class ConnectionAdmissionState: @unchecked Sendable {
        private let lock = NSLock()
        private var admitted = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !admitted else { return false }
            admitted = true
            return true
        }
    }

    fileprivate final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func run(_ body: () -> Void) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            body()
        }
    }

    private let requestedPort: UInt16?
    private let allowLocalEndpointReuse: Bool
    private let interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding?
    private let listenerReadyTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.skybridge.realtime-media.udp.rx", qos: .userInteractive)
    private let stateLock = NSLock()
    private static let maximumActiveConnections = 4
    private var pendingListener: NWListener?
    private var pendingStartState: StartState?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handler: PacketHandler?
    private let terminalFailureHandler: TerminalFailureHandler?

    public init(
        port: UInt16? = nil,
        allowLocalEndpointReuse: Bool = false,
        interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding? = nil,
        listenerReadyTimeout: TimeInterval = 8,
        terminalFailureHandler: TerminalFailureHandler? = nil
    ) {
        self.requestedPort = port
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
        self.interfaceBinding = interfaceBinding
        self.listenerReadyTimeout = max(listenerReadyTimeout, 0.1)
        self.terminalFailureHandler = terminalFailureHandler
    }

    public func start(handler: @escaping PacketHandler) async throws -> SkyBridgeMediaEndpoint {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = allowLocalEndpointReuse
        if let interfaceBinding {
            parameters.requiredInterface = interfaceBinding.interface
            parameters.includePeerToPeer = false
        }
        let listener: NWListener
        if let requestedPort,
           let port = NWEndpoint.Port(rawValue: requestedPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters)
        }

        let startState = StartState()
        let didClaimListener = stateLock.withLock { () -> Bool in
            guard self.listener == nil, pendingListener == nil else { return false }
            pendingListener = listener
            pendingStartState = startState
            self.handler = handler
            return true
        }
        guard didClaimListener else {
            listener.cancel()
            throw SkyBridgeRealtimeMediaTransportError.udpReceiverAlreadyStarted
        }

        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let listener else {
                connection.cancel()
                return
            }
            guard let self else {
                connection.cancel()
                return
            }
            let admissionState = ConnectionAdmissionState()
            guard self.insert(connection, ifOwnedBy: listener) else {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { [weak self, weak connection, weak listener] state in
                guard let listener else {
                    connection?.cancel()
                    return
                }
                guard let connection else { return }
                guard let self else {
                    connection.cancel()
                    return
                }
                switch state {
                case .ready:
                    guard admissionState.claim() else { return }
                    guard self.isCurrent(connection, ownedBy: listener) else {
                        connection.cancel()
                        self.remove(connection)
                        return
                    }
                    if let interfaceBinding = self.interfaceBinding,
                       !interfaceBinding.validatesReadyPath(connection.currentPath) {
                        connection.cancel()
                        self.remove(connection)
                        return
                    }
                    self.receiveNext(on: connection, ownedBy: listener)
                case .failed, .cancelled:
                    self.remove(connection)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            switch state {
            case .ready:
                guard let self else {
                    if startState.complete(.failure(CancellationError())) {
                        listener.cancel()
                    }
                    return
                }
                guard let port = listener.port?.rawValue, port > 0 else {
                    if startState.complete(
                        .failure(
                            SkyBridgeRealtimeMediaTransportError
                                .udpListenerMissingBoundPort
                        )
                    ) {
                        listener.cancel()
                    }
                    return
                }
                let didInstall = self.stateLock.withLock { () -> Bool in
                    guard self.pendingListener === listener,
                          self.pendingStartState === startState else {
                        return false
                    }
                    let didComplete = startState.complete(
                        .success(SkyBridgeMediaEndpoint(host: "0.0.0.0", port: port))
                    )
                    self.pendingListener = nil
                    self.pendingStartState = nil
                    if didComplete {
                        self.listener = listener
                    }
                    return didComplete
                }
                guard didInstall else {
                    listener.cancel()
                    return
                }
            case .waiting(let error):
                let permissionDenied = NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                    error: error,
                    path: nil
                )
                if permissionDenied {
                    let failure = SkyBridgeRealtimeMediaTransportError
                        .udpLocalNetworkPermissionDenied
                    if startState.complete(.failure(failure)) {
                        listener.cancel()
                    } else if self?.isCurrent(listener: listener) == true {
                        self?.terminalFailureHandler?(failure)
                    }
                }
            case .failed(let error):
                let failure: Error = NetworkFrameworkLocalNetworkPermissionClassifier
                    .isDenied(error: error, path: nil)
                    ? SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied
                    : error
                if startState.complete(.failure(failure)) {
                    listener.cancel()
                } else if self?.isCurrent(listener: listener) == true {
                    self?.terminalFailureHandler?(failure)
                }
            case .cancelled:
                let didComplete = startState.complete(.failure(CancellationError()))
                if !didComplete, self?.isCurrent(listener: listener) == true {
                    self?.terminalFailureHandler?(CancellationError())
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + listenerReadyTimeout) {
            if startState.complete(
                .failure(SkyBridgeRealtimeMediaTransportError.udpListenerReadyTimedOut)
            ) {
                listener.cancel()
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let endpoint = try await startState.wait()
                try Task.checkCancellation()
                return endpoint
            } onCancel: {
                if startState.complete(.failure(CancellationError())) {
                    listener.cancel()
                }
            }
        } catch {
            listener.cancel()
            stateLock.withLock {
                if pendingListener === listener {
                    pendingListener = nil
                    pendingStartState = nil
                }
                if self.listener === listener {
                    self.listener = nil
                }
                if pendingListener == nil, self.listener == nil {
                    self.handler = nil
                }
            }
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        let pendingListener = self.pendingListener
        let pendingStartState = self.pendingStartState
        let listener = self.listener
        let existingConnections = Array(connections.values)
        self.pendingListener = nil
        self.pendingStartState = nil
        self.listener = nil
        connections.removeAll(keepingCapacity: false)
        handler = nil
        stateLock.unlock()

        _ = pendingStartState?.complete(.failure(CancellationError()))
        pendingListener?.cancel()
        listener?.cancel()
        existingConnections.forEach { $0.cancel() }
    }

    private func insert(
        _ connection: NWConnection,
        ifOwnedBy listener: NWListener
    ) -> Bool {
        stateLock.withLock {
            guard self.listener === listener,
                  connections.count < Self.maximumActiveConnections else {
                return false
            }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
    }

    private func isCurrent(listener: NWListener) -> Bool {
        stateLock.withLock { self.listener === listener }
    }

    private func remove(_ connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
    }

    private func isCurrent(
        _ connection: NWConnection,
        ownedBy listener: NWListener
    ) -> Bool {
        stateLock.withLock {
            self.listener === listener
                && connections[ObjectIdentifier(connection)] === connection
        }
    }

    private func currentHandler(
        for connection: NWConnection,
        ownedBy listener: NWListener
    ) -> PacketHandler? {
        stateLock.withLock {
            guard self.listener === listener,
                  connections[ObjectIdentifier(connection)] === connection else {
                return nil
            }
            return handler
        }
    }

    private func receiveNext(on connection: NWConnection, ownedBy listener: NWListener) {
        connection.receiveMessage { [weak self, weak connection, weak listener] content, _, _, error in
            guard let self, let connection, let listener else {
                connection?.cancel()
                return
            }
            if let error {
                _ = error
                self.remove(connection)
                connection.cancel()
                return
            }
            guard let handler = self.currentHandler(
                for: connection,
                ownedBy: listener
            ) else {
                self.remove(connection)
                connection.cancel()
                return
            }
            if let content, !content.isEmpty {
                handler(
                    SkyBridgeMediaReceivedDatagram(
                        packet: content,
                        remoteEndpoint: Self.endpoint(from: connection.endpoint)
                    )
                )
            }
            guard self.isCurrent(connection, ownedBy: listener) else {
                self.remove(connection)
                connection.cancel()
                return
            }
            self.receiveNext(on: connection, ownedBy: listener)
        }
    }

    private static func endpoint(from endpoint: NWEndpoint) -> SkyBridgeMediaEndpoint? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        return SkyBridgeMediaEndpoint(host: "\(host)", port: port.rawValue)
    }
}

public final class SkyBridgeUDPRealtimeMediaTransport: SkyBridgeRealtimeMediaTransport, @unchecked Sendable {
    public typealias PacketHandler = @Sendable (SkyBridgeMediaReceivedDatagram) -> Void

    private final class RelayBindState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var generation: UInt64 = 0
        private var completion: Result<Void, Error>?
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func reset() -> UInt64 {
            lock.lock()
            let staleWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            completed = false
            completion = nil
            generation &+= 1
            let currentGeneration = generation
            lock.unlock()
            staleWaiters.forEach {
                $0.resume(throwing: SkyBridgeRealtimeMediaTransportError.relayBindTimedOut)
            }
            return currentGeneration
        }

        func markCompleted() -> Bool {
            complete(.success(()), expectedGeneration: nil)
        }

        func markFailed(_ error: Error) -> Bool {
            complete(.failure(error), expectedGeneration: nil)
        }

        func markTimedOut(for expectedGeneration: UInt64) -> Bool {
            complete(
                .failure(SkyBridgeRealtimeMediaTransportError.relayBindTimedOut),
                expectedGeneration: expectedGeneration
            )
        }

        func waitForCompletion(generation expectedGeneration: UInt64) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if generation != expectedGeneration {
                    lock.unlock()
                    continuation.resume(throwing: SkyBridgeRealtimeMediaTransportError.relayBindTimedOut)
                    return
                }
                if let completion {
                    lock.unlock()
                    continuation.resume(with: completion)
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        private func complete(
            _ result: Result<Void, Error>,
            expectedGeneration: UInt64?
        ) -> Bool {
            lock.lock()
            if let expectedGeneration, generation != expectedGeneration {
                lock.unlock()
                return false
            }
            guard !completed else {
                lock.unlock()
                return false
            }
            completed = true
            completion = result
            let activeWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            activeWaiters.forEach { $0.resume(with: result) }
            return true
        }

        func markStopped() {
            lock.lock()
            completed = true
            completion = .failure(URLError(.cancelled))
            generation &+= 1
            let activeWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            activeWaiters.forEach { $0.resume(throwing: URLError(.cancelled)) }
        }

        func shouldReportTimeout(for expectedGeneration: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return generation == expectedGeneration && !completed
        }
    }

    private let endpoint: SkyBridgeMediaEndpoint
    private let receiveHandler: PacketHandler?
    private let allowLocalEndpointReuse: Bool
    private let interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding?
    private let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy
    private let connectionReadyTimeout: TimeInterval
    private let relayBindAckTimeout: TimeInterval
    private let startEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)?
    private let terminalFailureHandler: (@Sendable (Error) -> Void)?
    private let queue = DispatchQueue(label: "com.skybridge.realtime-media.udp", qos: .userInteractive)
    private let relayBindState = RelayBindState()
    private let receiveLoopLock = NSLock()
    private var connection: NWConnection?
    private var receiveLoopStarted = false

    private final class ConnectionReadyState: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(with: completion)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        @discardableResult
        func complete(_ result: Result<Void, Error>) -> Bool {
            lock.lock()
            guard completion == nil else {
                lock.unlock()
                return false
            }
            completion = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    public init(
        endpoint: SkyBridgeMediaEndpoint,
        receiveHandler: PacketHandler? = nil,
        allowLocalEndpointReuse: Bool = false,
        interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding? = nil,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy = .requireAcknowledgement,
        connectionReadyTimeout: TimeInterval = 2,
        relayBindAckTimeout: TimeInterval = 2,
        startEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)? = nil,
        terminalFailureHandler: (@Sendable (Error) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.receiveHandler = receiveHandler
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
        self.interfaceBinding = interfaceBinding
        self.relayBindPolicy = relayBindPolicy
        self.connectionReadyTimeout = max(0.1, connectionReadyTimeout)
        self.relayBindAckTimeout = max(0.1, relayBindAckTimeout)
        self.startEventHandler = startEventHandler
        self.terminalFailureHandler = terminalFailureHandler
    }

    public func start() async throws {
        if connection != nil { return }
        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw URLError(.badURL)
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = allowLocalEndpointReuse
        if let interfaceBinding {
            parameters.requiredInterface = interfaceBinding.interface
            parameters.includePeerToPeer = false
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        do {
            try await waitForConnectionReady(on: connection)
        } catch {
            if self.connection === connection {
                self.connection = nil
            }
            connection.cancel()
            throw error
        }
        startEventHandler?(.udpConnectionReady)
        if let relayToken = endpoint.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relayToken.isEmpty {
            do {
                switch relayBindPolicy {
                case .requireAcknowledgement:
                    do {
                        try await sendRelayBindAndWaitForResult(token: relayToken, on: connection)
                    } catch SkyBridgeRealtimeMediaTransportError.relayBindTimedOut {
                        startEventHandler?(.relayBindAckTimedOut)
                        throw SkyBridgeRealtimeMediaTransportError.relayBindTimedOut
                    } catch SkyBridgeRealtimeMediaTransportError.relayBindMalformed {
                        startEventHandler?(.relayBindMalformed)
                        throw SkyBridgeRealtimeMediaTransportError.relayBindMalformed
                    } catch SkyBridgeRealtimeMediaTransportError.relayBindRejected(let reason) {
                        startEventHandler?(.relayBindRejected(reason))
                        throw SkyBridgeRealtimeMediaTransportError.relayBindRejected(reason)
                    } catch {
                        throw error
                    }
                    _ = relayBindState.markCompleted()
                    startEventHandler?(.relayBindAccepted)
                case .optimisticAfterSend:
                    let generation = relayBindState.reset()
                    ensureReceiveLoopStarted(on: connection)
                    try await sendRelayBind(token: relayToken)
                    startEventHandler?(.relayBindSent)
                    scheduleRelayBindAckWatchdog(generation: generation)
                }
            } catch {
                connection.cancel()
                self.connection = nil
                relayBindState.markStopped()
                throw error
            }
        }
        if receiveHandler != nil || relayBindPolicy == .optimisticAfterSend {
            ensureReceiveLoopStarted(on: connection)
        }
    }

    public func send(_ packet: Data) async throws {
        guard let connection else {
            throw URLError(.cannotConnectToHost)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    if self.connection === connection {
                        self.terminalFailureHandler?(error)
                    }
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func rebindRelayToken(
        _ relayToken: String,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy = .optimisticAfterSend
    ) async throws {
        guard let connection else {
            throw URLError(.cannotConnectToHost)
        }
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw SkyBridgeRealtimeMediaTransportError.relayBindRejected("missing_lease_token")
        }
        let generation = relayBindState.reset()
        ensureReceiveLoopStarted(on: connection)
        try await sendRelayBind(token: token)
        startEventHandler?(.relayBindSent)
        switch relayBindPolicy {
        case .requireAcknowledgement:
            do {
                try await waitForRelayBindResult(generation: generation)
            } catch SkyBridgeRealtimeMediaTransportError.relayBindTimedOut {
                startEventHandler?(.relayBindAckTimedOut)
                throw SkyBridgeRealtimeMediaTransportError.relayBindTimedOut
            } catch {
                throw error
            }
        case .optimisticAfterSend:
            scheduleRelayBindAckWatchdog(generation: generation)
        }
    }

    public func refreshRelayBinding(_ relayToken: String) async throws {
        guard connection != nil else {
            throw URLError(.cannotConnectToHost)
        }
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw SkyBridgeRealtimeMediaTransportError.relayBindRejected("missing_lease_token")
        }
        try await sendRelayBind(token: token)
        startEventHandler?(.relayBindSent)
    }

    public func stop() async {
        let connection = self.connection
        self.connection = nil
        connection?.cancel()
        markReceiveLoopStopped()
        relayBindState.markStopped()
    }

    private func waitForConnectionReady(on connection: NWConnection) async throws {
        let readyState = ConnectionReadyState()
        connection.stateUpdateHandler = { [weak self, weak connection, interfaceBinding] state in
            guard let connection else {
                _ = readyState.complete(.failure(CancellationError()))
                return
            }
            switch state {
            case .ready:
                if let interfaceBinding,
                   !interfaceBinding.validatesReadyPath(connection.currentPath) {
                    let failure = SkyBridgeRealtimeMediaTransportError.udpReadyPathMismatch
                    if readyState.complete(.failure(failure)) {
                        connection.cancel()
                    } else if self?.connection === connection {
                        self?.terminalFailureHandler?(failure)
                    }
                } else {
                    _ = readyState.complete(.success(()))
                }
            case .waiting(let error):
                let permissionDenied = NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                    error: error,
                    path: connection.currentPath
                )
                if permissionDenied {
                    let failure = SkyBridgeRealtimeMediaTransportError
                        .udpLocalNetworkPermissionDenied
                    if readyState.complete(.failure(failure)) {
                        connection.cancel()
                    } else if self?.connection === connection {
                        self?.terminalFailureHandler?(failure)
                    }
                }
            case .failed(let error):
                let failure: Error = NetworkFrameworkLocalNetworkPermissionClassifier
                    .isDenied(error: error, path: connection.currentPath)
                    ? SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied
                    : error
                if readyState.complete(.failure(failure)) {
                    connection.cancel()
                } else if self?.connection === connection {
                    self?.terminalFailureHandler?(failure)
                }
            case .cancelled:
                let didComplete = readyState.complete(.failure(CancellationError()))
                if !didComplete, self?.connection === connection {
                    self?.terminalFailureHandler?(CancellationError())
                }
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + connectionReadyTimeout) {
            let failure: Error = NetworkFrameworkLocalNetworkPermissionClassifier
                .isDenied(path: connection.currentPath)
                ? SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied
                : SkyBridgeRealtimeMediaTransportError.udpConnectionReadyTimedOut
            if readyState.complete(
                .failure(failure)
            ) {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await readyState.wait()
            try Task.checkCancellation()
        } onCancel: {
            if readyState.complete(.failure(CancellationError())) {
                connection.cancel()
            }
        }
    }

    private func sendRelayBind(token: String) async throws {
        try await send(Self.relayBindPayload(token: token))
    }

    private func sendRelayBindAndWaitForResult(token: String, on connection: NWConnection) async throws {
        let data = try Self.relayBindPayload(token: token)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let completionGate = SkyBridgeUDPRealtimeMediaReceiver.OnceGate()
            connection.receiveMessage { content, _, _, error in
                completionGate.run {
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let content, !content.isEmpty else {
                        continuation.resume(throwing: SkyBridgeRealtimeMediaTransportError.relayBindMalformed)
                        return
                    }
                    continuation.resume(returning: content)
                }
            }
            connection.send(content: data, completion: .contentProcessed { [startEventHandler] error in
                if let error {
                    completionGate.run {
                        continuation.resume(throwing: error)
                    }
                } else {
                    startEventHandler?(.relayBindSent)
                }
            })
            queue.asyncAfter(deadline: .now() + relayBindAckTimeout) {
                completionGate.run {
                    continuation.resume(throwing: SkyBridgeRealtimeMediaTransportError.relayBindTimedOut)
                }
            }
        }
        try Self.validateRelayBindResult(response)
    }

    private static func relayBindPayload(token: String) throws -> Data {
        let payload: [String: String] = [
            "type": "bind",
            "leaseToken": token
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func waitForRelayBindResult(generation: UInt64) async throws {
        scheduleRelayBindAckFailure(generation: generation)
        try await relayBindState.waitForCompletion(generation: generation)
    }

    private static func validateRelayBindResult(_ data: Data) throws {
        guard data.first == 0x7b,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "bind-result" else {
            throw SkyBridgeRealtimeMediaTransportError.relayBindMalformed
        }
        if object["ok"] as? Bool == true {
            return
        }
        let reason = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SkyBridgeRealtimeMediaTransportError.relayBindRejected(reason?.isEmpty == false ? reason! : "unknown")
    }

    private func scheduleRelayBindAckWatchdog(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + relayBindAckTimeout) { [weak self] in
            guard let self,
                  self.relayBindState.shouldReportTimeout(for: generation) else {
                return
            }
            self.startEventHandler?(.relayBindAckTimedOut)
        }
    }

    private func scheduleRelayBindAckFailure(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + relayBindAckTimeout) { [weak self] in
            guard let self,
                  self.relayBindState.markTimedOut(for: generation) else {
                return
            }
        }
    }

    private func ensureReceiveLoopStarted(on connection: NWConnection) {
        receiveLoopLock.lock()
        guard !receiveLoopStarted else {
            receiveLoopLock.unlock()
            return
        }
        receiveLoopStarted = true
        receiveLoopLock.unlock()
        receiveNext(on: connection)
    }

    private func markReceiveLoopStopped() {
        receiveLoopLock.lock()
        receiveLoopStarted = false
        receiveLoopLock.unlock()
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if error != nil {
                self.markReceiveLoopStopped()
                return
            }
            if let content, !content.isEmpty, !self.handleRelayControlMessage(content) {
                self.receiveHandler?(
                    SkyBridgeMediaReceivedDatagram(
                        packet: content,
                        remoteEndpoint: self.endpoint
                    )
                )
            }
            self.receiveNext(on: connection)
        }
    }

    private func handleRelayControlMessage(_ data: Data) -> Bool {
        guard data.first == 0x7b,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        guard type == "bind-result" else { return false }
        do {
            try Self.validateRelayBindResult(data)
            if relayBindState.markCompleted() {
                startEventHandler?(.relayBindAccepted)
            }
        } catch SkyBridgeRealtimeMediaTransportError.relayBindRejected(let reason) {
            if relayBindState.markFailed(SkyBridgeRealtimeMediaTransportError.relayBindRejected(reason)) {
                startEventHandler?(.relayBindRejected(reason))
            }
        } catch {
            if relayBindState.markFailed(SkyBridgeRealtimeMediaTransportError.relayBindMalformed) {
                startEventHandler?(.relayBindMalformed)
            }
        }
        return true
    }
}
