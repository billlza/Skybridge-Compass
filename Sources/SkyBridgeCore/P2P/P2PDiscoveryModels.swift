import Foundation
import Network

/// 网络发现的设备（内部使用）
internal struct P2PNetworkDiscoveredDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public var metadata: NWTXTRecord?
    public let discoveredAt: Date
    public var lastSeen: Date = Date()

    public init(id: String, name: String, endpoint: NWEndpoint, metadata: NWTXTRecord?, discoveredAt: Date) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.metadata = metadata
        self.discoveredAt = discoveredAt
    }
}

/// 设备发现连接状态
public enum P2PDiscoveryConnectionStatus: String, CaseIterable {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case reconnecting = "重连中"
    case failed = "连接失败"
    case timeout = "连接超时"

    public var displayName: String {
        return rawValue
    }
}

/// 设备发现错误
public enum P2PDiscoveryError: Error, LocalizedError {
    case deviceNotConnected
    case connectionCancelled
    case timeout
    case scanningFailed
    case noConnectableEndpoint
    case localNetworkPermissionDenied
    case strictPQCTrustPreflightFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "设备未连接"
        case .connectionCancelled:
            return "连接已取消"
        case .timeout:
            return "连接超时"
        case .scanningFailed:
            return "扫描失败"
        case .noConnectableEndpoint:
            return "设备未暴露可连接的 SkyBridge 控制端点"
        case .localNetworkPermissionDenied:
            return "本地网络权限被系统拒绝，请在 macOS 系统设置的本地网络权限中允许 SkyBridge Compass Pro 后重试"
        case .strictPQCTrustPreflightFailed(let reason):
            return "strict PQC 信任预检失败：\(reason)"
        }
    }
}

enum AuthenticatedAppPayloadCryptoError: Error, LocalizedError, Sendable {
    case combinedCiphertextUnavailable

    var errorDescription: String? {
        switch self {
        case .combinedCiphertextUnavailable:
            return "已认证业务载荷加密失败：AES-GCM combined 密文不可用"
        }
    }
}
