import Foundation
import Network
import OSLog

private final class NativeWebSocketSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@available(iOS 17.0, *)
public struct NativeWebSocketCallbacks: Sendable {
    public var onOpen: (@Sendable () -> Void)?
    public var onText: (@Sendable (String) async -> Void)?
    public var onBinary: (@Sendable (Data) async -> Void)?
    public var onStateChange: (@Sendable (NWConnection.State) -> Void)?
    public var onClose: (@Sendable (NWProtocolWebSocket.CloseCode?, Data?) -> Void)?
    public var onError: (@Sendable (NWError) -> Void)?

    public init(
        onOpen: (@Sendable () -> Void)? = nil,
        onText: (@Sendable (String) async -> Void)? = nil,
        onBinary: (@Sendable (Data) async -> Void)? = nil,
        onStateChange: (@Sendable (NWConnection.State) -> Void)? = nil,
        onClose: (@Sendable (NWProtocolWebSocket.CloseCode?, Data?) -> Void)? = nil,
        onError: (@Sendable (NWError) -> Void)? = nil
    ) {
        self.onOpen = onOpen
        self.onText = onText
        self.onBinary = onBinary
        self.onStateChange = onStateChange
        self.onClose = onClose
        self.onError = onError
    }
}

@available(iOS 17.0, *)
public actor NativeWebSocketClient {
    private let logger = Logger(subsystem: "com.skybridge.signal", category: "NativeWebSocketClient")
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let callbacks: NativeWebSocketCallbacks
    private let preferNoProxies: Bool
    private var connection: NWConnection?
    private var connectionGeneration: UInt64 = 0
    private var receivingGeneration: UInt64?

    public init(
        url: URL,
        tls: Bool = true,
        pingInterval: TimeInterval? = 30,
        preferNoProxies: Bool = false,
        additionalHeaders: [String: String] = [:],
        callbacks: NativeWebSocketCallbacks = .init()
    ) {
        self.endpoint = NWEndpoint.url(url)
        self.preferNoProxies = preferNoProxies
        self.parameters = Self.buildParameters(
            tls: tls,
            pingInterval: pingInterval,
            preferNoProxies: preferNoProxies,
            additionalHeaders: additionalHeaders
        )
        self.callbacks = callbacks
    }

    public func connect() {
        if let conn = connection {
            switch conn.state {
            case .ready, .preparing, .setup, .waiting(_):
                return
            default:
                _ = retireCurrentConnection(
                    conn,
                    generation: connectionGeneration,
                    cancel: true
                )
            }
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        receivingGeneration = nil
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            Task { await self?.handleStateUpdate(state, from: conn, generation: generation) }
        }
        conn.betterPathUpdateHandler = { [weak self, weak conn] _ in
            guard let conn else { return }
            Task { await self?.handleBetterPathUpdate(from: conn, generation: generation) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    public func close(code: NWProtocolWebSocket.CloseCode? = nil, reason: Data? = nil) {
        guard let conn = connection else {
            connectionGeneration &+= 1
            receivingGeneration = nil
            return
        }
        let generation = connectionGeneration
        guard retireCurrentConnection(conn, generation: generation, cancel: false) != nil else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        conn.send(content: reason, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        conn.cancel()
    }

    public func send(text: String) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let generation = connectionGeneration
        let data = text.data(using: .utf8) ?? Data()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
        guard isCurrentConnection(conn, generation: generation) else {
            throw NativeWebSocketError.connectionSuperseded
        }
    }

    public func send(binary data: Data) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let generation = connectionGeneration
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
        guard isCurrentConnection(conn, generation: generation) else {
            throw NativeWebSocketError.connectionSuperseded
        }
    }

    public func ping() async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let generation = connectionGeneration
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        try await sendInternal(conn: conn, data: nil, context: context)
        guard isCurrentConnection(conn, generation: generation) else {
            throw NativeWebSocketError.connectionSuperseded
        }
    }

    private static func buildParameters(
        tls: Bool,
        pingInterval: TimeInterval?,
        preferNoProxies: Bool,
        additionalHeaders: [String: String] = [:]
    ) -> NWParameters {
        let params: NWParameters = tls ? .tls : NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.preferNoProxies = preferNoProxies

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 64 * 1024
        if !additionalHeaders.isEmpty {
            options.setAdditionalHeaders(
                additionalHeaders
                    .sorted { $0.key < $1.key }
                    .map { (name: $0.key, value: $0.value) }
            )
        }
        _ = pingInterval
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return params
    }

    private func sendInternal(
        conn: NWConnection,
        data: Data?,
        context: NWConnection.ContentContext
    ) async throws {
        let gate = NativeWebSocketSendGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success(()))
                    }
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
            conn.cancel()
        }
    }

    private func handleStateUpdate(
        _ state: NWConnection.State,
        from conn: NWConnection,
        generation: UInt64
    ) async {
        guard isCurrentConnection(conn, generation: generation) else { return }
        callbacks.onStateChange?(state)
        switch state {
        case .ready:
            callbacks.onOpen?()
            requestEstablishmentReport(for: conn, generation: generation)
            startReceiveLoopIfNeeded(on: conn, generation: generation)
        case .failed(let error):
            _ = retireCurrentConnection(conn, generation: generation, cancel: true)
            callbacks.onError?(error)
        case .waiting(let error):
            callbacks.onError?(error)
        case .cancelled:
            _ = retireCurrentConnection(conn, generation: generation, cancel: false)
            callbacks.onClose?(nil, nil)
        default:
            break
        }
    }

    private func handleBetterPathUpdate(from conn: NWConnection, generation: UInt64) {
        guard isCurrentConnection(conn, generation: generation) else { return }
        callbacks.onStateChange?(.preparing)
    }

    private func startReceiveLoopIfNeeded(on conn: NWConnection, generation: UInt64) {
        guard isCurrentConnection(conn, generation: generation),
              receivingGeneration != generation else { return }
        receivingGeneration = generation
        receiveNext(on: conn, generation: generation)
    }

    private func receiveNext(on conn: NWConnection, generation: UInt64) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let conn else { return }
            Task {
                await self?.processReceive(
                    data: data,
                    context: context,
                    error: error,
                    from: conn,
                    generation: generation
                )
            }
        }
    }

    private func processReceive(
        data: Data?,
        context: NWConnection.ContentContext?,
        error: NWError?,
        from conn: NWConnection,
        generation: UInt64
    ) async {
        guard isCurrentConnection(conn, generation: generation),
              receivingGeneration == generation else { return }
        if let error {
            _ = retireCurrentConnection(conn, generation: generation, cancel: true)
            callbacks.onError?(error)
            return
        }

        if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
            switch metadata.opcode {
            case .text:
                if let data, let text = String(data: data, encoding: .utf8) {
                    await callbacks.onText?(text)
                }
            case .binary:
                if let data {
                    await callbacks.onBinary?(data)
                }
            case .close:
                _ = retireCurrentConnection(conn, generation: generation, cancel: true)
                callbacks.onClose?(metadata.closeCode, nil)
                return
            case .cont, .ping, .pong:
                break
            @unknown default:
                break
            }
        }

        continueReceiveIfNeeded(on: conn, generation: generation)
    }

    private func continueReceiveIfNeeded(on conn: NWConnection, generation: UInt64) {
        guard isCurrentConnection(conn, generation: generation),
              receivingGeneration == generation else { return }
        receiveNext(on: conn, generation: generation)
    }

    private func isCurrentConnection(_ conn: NWConnection, generation: UInt64) -> Bool {
        connectionGeneration == generation && connection === conn
    }

    @discardableResult
    private func retireCurrentConnection(
        _ conn: NWConnection,
        generation: UInt64,
        cancel: Bool
    ) -> UInt64? {
        guard isCurrentConnection(conn, generation: generation) else { return nil }
        connection = nil
        receivingGeneration = nil
        connectionGeneration &+= 1
        conn.stateUpdateHandler = nil
        conn.betterPathUpdateHandler = nil
        if cancel {
            conn.cancel()
        }
        return connectionGeneration
    }

    private func requestEstablishmentReport(for conn: NWConnection, generation: UInt64) {
        conn.requestEstablishmentReport(queue: .global(qos: .utility)) { [weak self, weak conn] report in
            guard let conn, let report else { return }
            Task { await self?.logEstablishmentReport(report, from: conn, generation: generation) }
        }
    }

    private func logEstablishmentReport(
        _ report: NWConnection.EstablishmentReport,
        from conn: NWConnection,
        generation: UInt64
    ) {
        guard isCurrentConnection(conn, generation: generation) else { return }
        let proxyEndpoint = report.proxyEndpoint.map { String(describing: $0) } ?? "direct"
        if preferNoProxies && report.usedProxy {
            logger.error(
                "⚠️ native websocket bypass attempt still used proxy: used_proxy=\(report.usedProxy ? 1 : 0, privacy: .public) proxy_configured=\(report.proxyConfigured ? 1 : 0, privacy: .public) proxy_endpoint=\(proxyEndpoint, privacy: .public)"
            )
        } else {
            logger.info(
                "🌐 native websocket establishment report: prefer_no_proxies=\(self.preferNoProxies ? 1 : 0, privacy: .public) used_proxy=\(report.usedProxy ? 1 : 0, privacy: .public) proxy_configured=\(report.proxyConfigured ? 1 : 0, privacy: .public) proxy_endpoint=\(proxyEndpoint, privacy: .public)"
            )
        }
    }

    public enum NativeWebSocketError: Error {
        case notConnected
        case connectionSuperseded
    }
}

#if DEBUG || SKYBRIDGE_TESTING
@available(iOS 17.0, *)
extension NativeWebSocketClient {
    internal static func testOnlyBuildParameters(
        tls: Bool,
        pingInterval: TimeInterval?,
        preferNoProxies: Bool,
        additionalHeaders: [String: String] = [:]
    ) -> NWParameters {
        buildParameters(
            tls: tls,
            pingInterval: pingInterval,
            preferNoProxies: preferNoProxies,
            additionalHeaders: additionalHeaders
        )
    }
}
#endif
