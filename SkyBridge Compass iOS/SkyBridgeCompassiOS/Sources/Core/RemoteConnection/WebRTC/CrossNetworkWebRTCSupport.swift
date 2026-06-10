import Foundation

extension Notification.Name {
    static let crossNetworkScreenDataUpdated = Notification.Name("CrossNetworkScreenDataUpdated")
}

enum CrossNetworkNotificationUserInfoKey {
    static let sessionId = "sessionId"
    static let screenData = "screenData"
}

enum CrossNetworkWebRTCHandshakeLimits {
    /// padded 帧上限：8192 - 4 字节长度前缀 = 8188
    static let maxPaddedPayloadBytes = (8 * 1024) - 4
    /// 控制帧分片上限：一个完整 padded 帧 + 4 字节长度前缀恰好为一条 DataChannel 消息。
    /// 两端接收侧均为流式重组（不校验单条消息大小），与旧版 1024 分片互操作安全。
    static let maxControlFrameChunkBytes = maxPaddedPayloadBytes + 4
    static let maxBufferedAmountBytes: UInt64 = 256 * 1024
    static let strictPQCClassicBootstrapTimeoutSeconds: TimeInterval = 30.0
    static let strictPQCClassicBootstrapMaxGraceSeconds: TimeInterval = 120.0
}

@available(iOS 17.0, *)
struct CurrentPathWebRTCHandshakeTransportCompat: DiscoveryTransport {
    let sendFramed: @Sendable (Data) async throws -> Void

    func send(to peer: PeerIdentifier, data: Data) async throws {
        try await sendFramed(data)
    }
}

enum SignalingSessionHealth: String, Sendable, Equatable {
    case healthy
    case degradedRecoverable = "degraded_recoverable"
    case degradedFatal = "degraded_fatal"
}
