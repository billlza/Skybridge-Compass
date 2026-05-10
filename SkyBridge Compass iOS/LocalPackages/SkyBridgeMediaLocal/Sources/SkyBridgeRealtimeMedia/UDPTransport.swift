import Foundation
import Network

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
    case relayBindRejected(String)
    case relayBindMalformed
    case relayBindTimedOut

    public var errorDescription: String? {
        switch self {
        case .udpConnectionReadyTimedOut:
            return "udp connection did not become ready before timeout"
        case .relayBindRejected(let reason):
            return "media relay bind rejected: \(reason)"
        case .relayBindMalformed:
            return "media relay bind response malformed"
        case .relayBindTimedOut:
            return "media relay bind timed out"
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

    fileprivate final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ body: () -> Void) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            body()
        }
    }

    private let requestedPort: UInt16?
    private let allowLocalEndpointReuse: Bool
    private let queue = DispatchQueue(label: "com.skybridge.realtime-media.udp.rx", qos: .userInteractive)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handler: PacketHandler?

    public init(port: UInt16? = nil, allowLocalEndpointReuse: Bool = false) {
        self.requestedPort = port
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
    }

    public func start(handler: @escaping PacketHandler) async throws -> SkyBridgeMediaEndpoint {
        self.handler = handler
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = allowLocalEndpointReuse
        let listener: NWListener
        if let requestedPort,
           let port = NWEndpoint.Port(rawValue: requestedPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.insert(connection)
            connection.start(queue: self.queue)
            self.receiveNext(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let startState = StartState()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startState.resumeOnce {
                        self.listener = listener
                        let port = listener.port?.rawValue ?? self.requestedPort ?? 0
                        continuation.resume(returning: SkyBridgeMediaEndpoint(host: "0.0.0.0", port: port))
                    }
                case .failed(let error):
                    startState.resumeOnce {
                        listener.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        stateLock.lock()
        let listener = self.listener
        let existingConnections = Array(connections.values)
        self.listener = nil
        connections.removeAll(keepingCapacity: false)
        handler = nil
        stateLock.unlock()

        listener?.cancel()
        existingConnections.forEach { $0.cancel() }
    }

    private func insert(_ connection: NWConnection) {
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()
    }

    private func remove(_ connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
    }

    private func currentHandler() -> PacketHandler? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handler
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if let error {
                _ = error
                self.remove(connection)
                connection.cancel()
                return
            }
            if let content, !content.isEmpty {
                self.currentHandler()?(
                    SkyBridgeMediaReceivedDatagram(
                        packet: content,
                        remoteEndpoint: Self.endpoint(from: connection.endpoint)
                    )
                )
            }
            self.receiveNext(on: connection)
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
    private let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy
    private let connectionReadyTimeout: TimeInterval
    private let relayBindAckTimeout: TimeInterval
    private let startEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)?
    private let queue = DispatchQueue(label: "com.skybridge.realtime-media.udp", qos: .userInteractive)
    private let relayBindState = RelayBindState()
    private let receiveLoopLock = NSLock()
    private var connection: NWConnection?
    private var receiveLoopStarted = false

    public init(
        endpoint: SkyBridgeMediaEndpoint,
        receiveHandler: PacketHandler? = nil,
        allowLocalEndpointReuse: Bool = false,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy = .requireAcknowledgement,
        connectionReadyTimeout: TimeInterval = 2,
        relayBindAckTimeout: TimeInterval = 2,
        startEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.receiveHandler = receiveHandler
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
        self.relayBindPolicy = relayBindPolicy
        self.connectionReadyTimeout = max(0.1, connectionReadyTimeout)
        self.relayBindAckTimeout = max(0.1, relayBindAckTimeout)
        self.startEventHandler = startEventHandler
    }

    public func start() async throws {
        if connection != nil { return }
        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw URLError(.badURL)
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = allowLocalEndpointReuse
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        try await waitForConnectionReady(on: connection)
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
        connection?.cancel()
        connection = nil
        markReceiveLoopStopped()
        relayBindState.markStopped()
    }

    private func waitForConnectionReady(on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = SkyBridgeUDPRealtimeMediaReceiver.StartState()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startState.resumeOnce {
                        continuation.resume()
                    }
                case .failed(let error):
                    startState.resumeOnce {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + connectionReadyTimeout) {
                startState.resumeOnce {
                    connection.cancel()
                    continuation.resume(throwing: SkyBridgeRealtimeMediaTransportError.udpConnectionReadyTimedOut)
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendRelayBind(token: String) async throws {
        try await send(Self.relayBindPayload(token: token))
    }

    private func sendRelayBindAndWaitForResult(token: String, on connection: NWConnection) async throws {
        let data = try Self.relayBindPayload(token: token)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let startState = SkyBridgeUDPRealtimeMediaReceiver.StartState()
            connection.receiveMessage { content, _, _, error in
                startState.resumeOnce {
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
                    startState.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                } else {
                    startEventHandler?(.relayBindSent)
                }
            })
            queue.asyncAfter(deadline: .now() + relayBindAckTimeout) {
                startState.resumeOnce {
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
