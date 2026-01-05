import Foundation
#if canImport(OrderedCollections)
import OrderedCollections
#endif

/// 表示当前登录用户的安全会话信息。
public struct AuthSession: Codable, Hashable, Sendable {
 /// 后端颁发的访问令牌。
    public let accessToken: String
 /// 用于续期访问令牌的刷新令牌。
    public let refreshToken: String?
 /// 唯一的用户标识。
    public let userIdentifier: String
 /// 当前登录用户的展示名称。
    public let displayName: String
 /// 会话创建时间，便于判断过期策略。
    public let issuedAt: Date

    public init(accessToken: String,
                refreshToken: String?,
                userIdentifier: String,
                displayName: String,
                issuedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userIdentifier = userIdentifier
        self.displayName = displayName
        self.issuedAt = issuedAt
    }
}

/// 概括远程桌面会话的状态与性能指标。
public struct RemoteSessionSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let targetName: String
    public let protocolDescription: String
    public let bandwidthMbps: Double
    public let frameLatencyMilliseconds: Double
 /// 会话连接状态（统一来源于管理器）
    public let status: SessionStatus

    public init(
        id: UUID,
        targetName: String,
        protocolDescription: String,
        bandwidthMbps: Double,
        frameLatencyMilliseconds: Double,
        status: SessionStatus
    ) {
        self.id = id
        self.targetName = targetName
        self.protocolDescription = protocolDescription
        self.bandwidthMbps = bandwidthMbps
        self.frameLatencyMilliseconds = frameLatencyMilliseconds
        self.status = status
    }
}

/// 远程会话状态（跨模块统一）
public enum SessionStatus: String, Codable, Hashable, Sendable {
    case connected
    case connecting
    case disconnected
    case failed
}

/// 设备连接方式
public enum DeviceConnectionType: String, Codable, Hashable, Sendable, CaseIterable {
    case wifi = "Wi-Fi"
    case ethernet = "有线"
    case usb = "USB"
    case thunderbolt = "雷雳"
    case bluetooth = "蓝牙"
    case unknown = "未知"
    
 /// 图标名称
    public var iconName: String {
        switch self {
        case .wifi:
            return "wifi"
        case .ethernet:
            return "cable.connector.horizontal"
        case .usb:
            return "cable.connector"
        case .thunderbolt:
            return "bolt.fill"
        case .bluetooth:
            return "bluetooth"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
 /// 显示颜色
    public var color: String {
        switch self {
        case .wifi:
            return "blue"
        case .ethernet:
            return "orange"
        case .usb:
            return "green"
        case .thunderbolt:
            return "purple"
        case .bluetooth:
            return "cyan"
        case .unknown:
            return "gray"
        }
    }
}

/// 设备发现来源（用于区分"永久防第三方设备变本机"）
public enum DeviceSource: String, Codable, Hashable, Sendable {
    case skybridgeBonjour = "SkyBridge Bonjour"
    case skybridgeP2P = "SkyBridge P2P"
    case skybridgeUSB = "SkyBridge USB"
    case skybridgeCloud = "SkyBridge iCloud"
    case thirdPartyBonjour = "第三方 Bonjour"
    case unknown = "未知来源"
}

/// 表示通过真实网络扫描获得的可连接设备。
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public private(set) var name: String
    public private(set) var ipv4: String?
    public private(set) var ipv6: String?
    public var services: [String]
    public var portMap: [String: Int]
 /// 设备连接方式集合（一台设备可能有多种连接方式）
    public var connectionTypes: Set<DeviceConnectionType>
 /// 设备唯一标识符（用于去重，如序列号、MAC地址等）
    public var uniqueIdentifier: String?
 /// 链路强度（0-100），来源于真实测量（RSSI或RTT映射）
    public var signalStrength: Double?
 /// 设备来源（默认 unknown，不断断逻辑化）
    public var source: DeviceSource = DeviceSource.unknown
 /// 是否为本机设备（只读对外，内部唯一写入点 _setIsLocalInternal）
    public private(set) var isLocalDevice: Bool = false
    
 // MARK: - 强身份字段（用于精确判定本机）
 /// 设备 ID（UUID，持久化标识）
    public var deviceId: String?
 /// P-256 公钥指纹（SHA256 hex 小写）
    public var pubKeyFP: String?
 /// MAC 地址集合（物理网卡）
    public var macSet: Set<String>

    public init(
        id: UUID,
        name: String,
        ipv4: String?,
        ipv6: String?,
        services: [String],
        portMap: [String: Int],
        connectionTypes: Set<DeviceConnectionType> = [DeviceConnectionType.unknown],
        uniqueIdentifier: String? = nil,
        signalStrength: Double? = nil,
        source: DeviceSource = DeviceSource.unknown,
        isLocalDevice: Bool = false,
        deviceId: String? = nil,
        pubKeyFP: String? = nil,
        macSet: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.services = services
        self.portMap = portMap
        self.connectionTypes = connectionTypes
        self.uniqueIdentifier = uniqueIdentifier
        self.signalStrength = signalStrength
        self.source = source
        self.isLocalDevice = isLocalDevice
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.macSet = macSet
    }
    
 /// 内部唯一写口（DiscoveryManager 调用）
    public mutating func _setIsLocalInternal(_ v: Bool) {
        self.isLocalDevice = v
    }
    
 /// 公开唯一写口（供 DiscoveryManager 调用）
    public mutating func setIsLocalDeviceByDiscovery(_ v: Bool) {
        self.isLocalDevice = v
    }
    
 /// 更新 transient 字段（IP 地址）
    public mutating func _updateTransient(ipv4: String?, ipv6: String?) {
        self.ipv4 = ipv4 ?? self.ipv4
        self.ipv6 = ipv6 ?? self.ipv6
    }
    
 /// 更新显示名称（仅在允许时）
 /// 中文说明：merge 中调用，需要外部判断是否允许更新
    public mutating func _updateDisplayNameIfAllowed(_ newName: String) {
        self.name = newName
    }
    
 /// 主要连接方式（优先级最高的）
    public var primaryConnectionType: DeviceConnectionType {
 // 优先级：雷雳 > 有线 > USB > Wi-Fi > 蓝牙
        if connectionTypes.contains(.thunderbolt) { return .thunderbolt }
        if connectionTypes.contains(.ethernet) { return .ethernet }
        if connectionTypes.contains(.usb) { return .usb }
        if connectionTypes.contains(.wifi) { return .wifi }
        if connectionTypes.contains(.bluetooth) { return .bluetooth }
        return DeviceConnectionType.unknown
    }
    
 /// 是否为 SkyBridge 对端设备
 /// 根据 DeviceSource 判断是否为 SkyBridge 发现的设备
    public var isSkyBridgePeer: Bool {
        switch source {
        case .skybridgeBonjour, .skybridgeP2P, .skybridgeUSB, .skybridgeCloud:
            return true
        case .thirdPartyBonjour, .unknown:
            return false
        }
    }
}

/// 表示一个正在进行或最近完成的文件传输任务。
public struct FileTransferTask: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let progress: Double
    public let throughputMbps: Double
    public let remainingTime: TimeInterval

    public init(
        id: UUID,
        fileName: String,
        progress: Double,
        throughputMbps: Double,
        remainingTime: TimeInterval
    ) {
        self.id = id
        self.fileName = fileName
        self.progress = progress
        self.throughputMbps = throughputMbps
        self.remainingTime = remainingTime
    }

 /// 生成一个本地化的剩余时间描述，所有数据来自真实传输状态。
    public var remainingTimeDescription: String {
        guard remainingTime.isFinite, remainingTime > 0 else { return "即将完成" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: remainingTime) ?? "--"
    }
}

/// 仪表盘实时指标快照，直接来源于后台遥测。
public struct RemoteMetricsSnapshot: Sendable {
    public let onlineDevices: Int
    public let activeSessions: Int
    public let transferCount: Int
    public let alertCount: Int
    public let cpuTimeline: OrderedDictionary<Date, Double>

    public init(
        onlineDevices: Int,
        activeSessions: Int,
        transferCount: Int,
        alertCount: Int,
        cpuTimeline: OrderedDictionary<Date, Double>
    ) {
        self.onlineDevices = onlineDevices
        self.activeSessions = activeSessions
        self.transferCount = transferCount
        self.alertCount = alertCount
        self.cpuTimeline = cpuTimeline
    }
}

/// 网络速率数据结构（用于仪表盘显示）
/// 以字节每秒（Bytes per second, Bps）为单位，分别表示入站/出站速率。
/// 注意：展示层如需显示 Mbps，应在视图层做单位换算，避免混淆。
public struct NetworkRateData: Codable, Hashable, Sendable {
 /// 入站速率（字节/秒）
    public let inBps: Double
 /// 出站速率（字节/秒）
    public let outBps: Double

    public init(inBps: Double = 0.0, outBps: Double = 0.0) {
        self.inBps = inBps
        self.outBps = outBps
    }
}
