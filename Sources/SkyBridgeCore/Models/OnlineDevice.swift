// 在线设备模型。抽取自 DeviceDiscovery/UnifiedOnlineDeviceManager.swift（macOS 侧发现编排），
// 因为共享的 P2P 入站路由解析（P2P/InboundPresenceRouteResolver）引用它。
//
// 属于 iOS/SkyBridgeCore 统一化的分层修复：模型类型不应与平台专属实现耦合在同一文件。

import Foundation

/// 在线设备
public struct OnlineDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var deviceType: DeviceClassifier.DeviceType
    public var ipv4: String?
    public var ipv6: String?
    public var platformName: String? = nil
    public var osVersion: String? = nil
    public var modelName: String? = nil
    public var chip: String? = nil
    public var macAddress: String?
    public var serialNumber: String?
    public var connectionTypes: Set<DeviceConnectionType>
    public var services: [String]
    public var portMap: [String: Int]
    /// Dialable route aliases such as `bonjour:<instance>@local.` that must survive
    /// stable identity promotion.
    public var routeIdentifiers: [String] = []
    /// Runtime-only protocol fingerprint observed from live discovery TXT. This is
    /// intentionally not encoded so persisted recent/cloud rows cannot outrank
    /// current live protocol identity.
    public var protocolFingerprint: String? = nil
    public let uniqueIdentifier: String
    public var sources: [DeviceSource]
    public let discoveredAt: Date
    public var lastSeen: Date
    public var connectionStatus: OnlineDeviceStatus
    public var lastConnectedAt: Date?
    /// Best-effort crypto info for last successful handshake (UI-only).
    public var lastCryptoKind: String?
    public var lastCryptoSuite: String?
    /// UI hint: whether we are actively guarding this connection (keepalive enabled).
    public var guardStatus: String?
    public var isLocalDevice: Bool
    public var isAuthorized: Bool
    public var signalStrength: Double? = nil
    public var isConnectable: Bool = true

    public static func == (lhs: OnlineDevice, rhs: OnlineDevice) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 在线设备状态（用于UnifiedOnlineDeviceManager）
public enum OnlineDeviceStatus: String, Sendable, Codable {
    case connected = "已连接"
    case online = "在线"
    case offline = "离线"

    var priority: Int {
        switch self {
        case .connected: return 3
        case .online: return 2
        case .offline: return 1
        }
    }
}
