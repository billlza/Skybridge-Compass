import Foundation
import SkyBridgeCore

/// Inline delivery preserves the real handshake state machine and crypto while
/// excluding sockets. Drivers own transports; handlers use weak driver captures.
actor BenchmarkTransport: DiscoveryTransport {
    private var receiver: (@Sendable (PeerIdentifier, Data) async throws -> Void)?
    private var pending: [(PeerIdentifier, Data)] = []
    private var isDelivering = false
    private var closed = false
    private(set) var sentMessages: [Data] = []

    func setReceiver(_ receiver: @escaping @Sendable (PeerIdentifier, Data) async throws -> Void) {
        self.receiver = receiver
    }

    func send(to peer: PeerIdentifier, data: Data) async throws {
        guard !closed else { throw BenchmarkError.closedTransport }
        guard receiver != nil else { throw BenchmarkError.missingReceiver }
        pending.append((peer, data))
        sentMessages.append(data)
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pending.isEmpty {
            guard !closed else { throw BenchmarkError.closedTransport }
            guard let receiver else { throw BenchmarkError.missingReceiver }
            let (target, message) = pending.removeFirst()
            try await receiver(target, message)
        }
    }

    func close() {
        closed = true
        receiver = nil
        pending.removeAll()
        sentMessages.removeAll()
    }
}
