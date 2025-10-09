import Foundation

struct RemoteShellConnection: Sendable {
    let session: RemoteShellSession
    let messages: AsyncStream<RemoteShellMessage>
}

enum RemoteShellError: Error {
    case disconnected
    case invalidResponse
}

actor RemoteShellService {
    static let shared = RemoteShellService()

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var messageContinuation: AsyncStream<RemoteShellMessage>.Continuation?
    private var latency: TimeInterval?
    private var endpoint: URL?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func connect(to endpoint: URL, token: String? = nil) async throws -> RemoteShellConnection {
        await disconnect()
        var request = URLRequest(url: endpoint)
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        self.endpoint = endpoint
        let stream = AsyncStream<RemoteShellMessage> { continuation in
            self.messageContinuation = continuation
        }
        task.resume()
        try await performHandshake(on: task)
        listen(on: task)
        let session = RemoteShellSession(endpoint: endpoint, isConnected: true, latency: latency, messages: [])
        return RemoteShellConnection(session: session, messages: stream)
    }

    func disconnect() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        messageContinuation?.finish()
        messageContinuation = nil
        endpoint = nil
        latency = nil
    }

    func send(_ command: String) async throws {
        guard let task else { throw RemoteShellError.disconnected }
        try await task.send(.string(command))
    }

    private func performHandshake(on task: URLSessionWebSocketTask) async throws {
        let start = Date()
        try await task.sendPing()
        latency = Date().timeIntervalSince(start)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        Task {
            while true {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let string):
                        messageContinuation?.yield(RemoteShellMessage(id: UUID(), role: .system, text: string, timestamp: .now))
                    case .data(let data):
                        let text = String(decoding: data, as: UTF8.self)
                        messageContinuation?.yield(RemoteShellMessage(id: UUID(), role: .system, text: text, timestamp: .now))
                    @unknown default:
                        break
                    }
                } catch {
                    messageContinuation?.yield(RemoteShellMessage(id: UUID(), role: .system, text: "连接关闭: \(error.localizedDescription)", timestamp: .now))
                    messageContinuation?.finish()
                    await disconnect()
                    break
                }
            }
        }
    }
}
