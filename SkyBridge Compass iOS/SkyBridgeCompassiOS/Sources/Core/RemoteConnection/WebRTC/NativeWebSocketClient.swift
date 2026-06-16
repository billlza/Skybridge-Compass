import Foundation
import Network
import OSLog

@available(iOS 17.0, *)
public struct NativeWebSocketCallbacks: Sendable {
    public var onOpen: (@Sendable () -> Void)?
    public var onText: (@Sendable (String) -> Void)?
    public var onBinary: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (NWConnection.State) -> Void)?
    public var onClose: (@Sendable (NWProtocolWebSocket.CloseCode?, Data?) -> Void)?
    public var onError: (@Sendable (NWError) -> Void)?

    public init(
        onOpen: (@Sendable () -> Void)? = nil,
        onText: (@Sendable (String) -> Void)? = nil,
        onBinary: (@Sendable (Data) -> Void)? = nil,
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
    private var isReceiving = false

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
                break
            }
        }

        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateUpdate(state) }
        }
        conn.betterPathUpdateHandler = { [weak self] _ in
            Task { await self?.handleBetterPathUpdate() }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    public func close(code: NWProtocolWebSocket.CloseCode? = nil, reason: Data? = nil) {
        guard let conn = connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        conn.send(content: reason, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        conn.cancel()
        connection = nil
        isReceiving = false
    }

    public func send(text: String) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let data = text.data(using: .utf8) ?? Data()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
    }

    public func send(binary data: Data) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
    }

    public func ping() async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        try await sendInternal(conn: conn, data: nil, context: context)
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) async {
        callbacks.onStateChange?(state)
        switch state {
        case .ready:
            callbacks.onOpen?()
            if let conn = connection {
                requestEstablishmentReport(for: conn)
            }
            await startReceiveLoopIfNeeded()
        case .failed(let error):
            callbacks.onError?(error)
        case .waiting(let error):
            callbacks.onError?(error)
        case .cancelled:
            callbacks.onClose?(nil, nil)
        default:
            break
        }
    }

    private func handleBetterPathUpdate() async {
        callbacks.onStateChange?(.preparing)
    }

    private func startReceiveLoopIfNeeded() async {
        guard !isReceiving, let conn = connection else { return }
        isReceiving = true
        receiveNext(on: conn)
    }

    private func receiveNext(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            Task { await self?.processReceive(data: data, context: context, error: error) }
        }
    }

    private func processReceive(
        data: Data?,
        context: NWConnection.ContentContext?,
        error: NWError?
    ) async {
        if let error {
            callbacks.onError?(error)
            return
        }

        if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
            switch metadata.opcode {
            case .text:
                if let data, let text = String(data: data, encoding: .utf8) {
                    callbacks.onText?(text)
                }
            case .binary:
                if let data {
                    callbacks.onBinary?(data)
                }
            case .close:
                callbacks.onClose?(metadata.closeCode, nil)
                close(code: metadata.closeCode, reason: nil)
                return
            case .cont, .ping, .pong:
                break
            @unknown default:
                break
            }
        }

        await continueReceiveIfNeeded()
    }

    private func continueReceiveIfNeeded() async {
        guard isReceiving, let conn = connection else { return }
        receiveNext(on: conn)
    }

    private func requestEstablishmentReport(for conn: NWConnection) {
        conn.requestEstablishmentReport(queue: .global(qos: .utility)) { [weak self] report in
            guard let report else { return }
            Task { await self?.logEstablishmentReport(report) }
        }
    }

    private func logEstablishmentReport(_ report: NWConnection.EstablishmentReport) {
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
    }
}

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
