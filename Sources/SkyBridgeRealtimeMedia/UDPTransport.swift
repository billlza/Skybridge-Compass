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
    case relayBindRejected(String)
    case relayBindMalformed
    case relayBindTimedOut

    public var errorDescription: String? {
        switch self {
        case .relayBindRejected(let reason):
            return "media relay bind rejected: \(reason)"
        case .relayBindMalformed:
            return "media relay bind response malformed"
        case .relayBindTimedOut:
            return "media relay bind timed out"
        }
    }
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

    private let endpoint: SkyBridgeMediaEndpoint
    private let receiveHandler: PacketHandler?
    private let allowLocalEndpointReuse: Bool
    private let queue = DispatchQueue(label: "com.skybridge.realtime-media.udp", qos: .userInteractive)
    private var connection: NWConnection?

    public init(
        endpoint: SkyBridgeMediaEndpoint,
        receiveHandler: PacketHandler? = nil,
        allowLocalEndpointReuse: Bool = false
    ) {
        self.endpoint = endpoint
        self.receiveHandler = receiveHandler
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
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
            connection.start(queue: queue)
        }
        if let relayToken = endpoint.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relayToken.isEmpty {
            do {
                try await sendRelayBind(token: relayToken)
                try await waitForRelayBindResult(on: connection)
            } catch {
                connection.cancel()
                self.connection = nil
                throw error
            }
        }
        if receiveHandler != nil {
            receiveNext(on: connection)
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

    public func stop() async {
        connection?.cancel()
        connection = nil
    }

    private func sendRelayBind(token: String) async throws {
        let payload: [String: String] = [
            "type": "bind",
            "leaseToken": token
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await send(data)
    }

    private func waitForRelayBindResult(on connection: NWConnection) async throws {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw SkyBridgeRealtimeMediaTransportError.relayBindTimedOut
            }
            group.addTask {
                try await Self.receiveMessageOnce(on: connection)
            }
            guard let data = try await group.next() else {
                throw SkyBridgeRealtimeMediaTransportError.relayBindTimedOut
            }
            group.cancelAll()
            return data
        }
        try Self.validateRelayBindResult(data)
    }

    private static func receiveMessageOnce(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
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

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if error != nil {
                return
            }
            if let content, !content.isEmpty, !Self.isRelayControlMessage(content) {
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

    private static func isRelayControlMessage(_ data: Data) -> Bool {
        guard data.first == 0x7b,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        return type == "bind-result"
    }
}
