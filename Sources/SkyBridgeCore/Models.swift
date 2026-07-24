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
/// 规范化的 Nebula ID（若会话来源提供）。
    public let nebulaId: String?
/// 当前登录用户的展示名称。
    public let displayName: String
/// 已经由服务端确认并可回读的头像 URL。
    public let avatarURL: String?
/// 会话创建时间，便于判断过期策略。
    public let issuedAt: Date

    public init(accessToken: String,
                refreshToken: String?,
                userIdentifier: String,
                nebulaId: String? = nil,
                displayName: String,
                avatarURL: String? = nil,
                issuedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userIdentifier = userIdentifier
        self.nebulaId = nebulaId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.issuedAt = issuedAt
    }

    public var isAuthenticatedForProtectedServices: Bool {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty
            && token != "guest_token"
            && token != "pending_verification"
    }
}

/// 远程可视会话的交互边界。
public enum RemoteSessionKind: String, Codable, Hashable, Sendable {
    case interactiveDesktop
    case readOnlyCamera

    public var supportsRemoteInput: Bool {
        self == .interactiveDesktop
    }
}

/// 概括远程桌面会话的状态与性能指标。
public struct RemoteSessionSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let targetName: String
    public let protocolDescription: String
    public let kind: RemoteSessionKind
    public let bandwidthMbps: Double
    public let frameLatencyMilliseconds: Double
 /// 会话连接状态（统一来源于管理器）
    public let status: SessionStatus

    public init(
        id: UUID,
        targetName: String,
        protocolDescription: String,
        kind: RemoteSessionKind = .interactiveDesktop,
        bandwidthMbps: Double,
        frameLatencyMilliseconds: Double,
        status: SessionStatus
    ) {
        self.id = id
        self.targetName = targetName
        self.protocolDescription = protocolDescription
        self.kind = kind
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
    case cellular = "蜂窝"
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
        case .cellular:
            return "antenna.radiowaves.left.and.right"
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
        case .cellular:
            return "green"
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

/// 当前设备对外广播的网络链路状态。
///
/// `signalStrength` 使用 0...1 的归一化真实测量值；若来源提供 RSSI，则保留在 `rssi`
/// 并由展示层按 Wi-Fi RSSI 范围换算成信号格。没有真实测量值时保持 nil。
public struct DeviceNetworkLinkStatus: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case wifi
        case cellular
        case ethernet
        case unknown

        public var connectionType: DeviceConnectionType {
            switch self {
            case .wifi:
                return .wifi
            case .cellular:
                return .cellular
            case .ethernet:
                return .ethernet
            case .unknown:
                return .unknown
            }
        }
    }

    public let kind: Kind
    public let radioAccessTechnology: String?
    public let signalStrength: Double?
    public let rssi: Int?

    public init(
        kind: Kind,
        radioAccessTechnology: String? = nil,
        signalStrength: Double? = nil,
        rssi: Int? = nil
    ) {
        self.kind = kind
        self.radioAccessTechnology = Self.sanitizedRadioAccessTechnology(radioAccessTechnology)
        self.signalStrength = Self.normalizedSignalStrength(signalStrength)
        self.rssi = rssi
    }

    public var connectionType: DeviceConnectionType {
        kind.connectionType
    }

    public var displayLabel: String {
        switch kind {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return radioAccessTechnology ?? "蜂窝"
        case .ethernet:
            return "以太网"
        case .unknown:
            return radioAccessTechnology ?? "未知"
        }
    }

    public var iconName: String {
        switch kind {
        case .wifi:
            return "wifi"
        case .cellular:
            return "antenna.radiowaves.left.and.right"
        case .ethernet:
            return "cable.connector.horizontal"
        case .unknown:
            return "questionmark.circle"
        }
    }

    public var normalizedSignalStrength: Double? {
        if let signalStrength {
            return signalStrength
        }
        guard let rssi else { return nil }
        return Self.normalizedRSSI(rssi)
    }

    public var advertisementFields: [String: String] {
        var fields: [String: String] = [
            "linkKind": kind.rawValue,
            "networkType": kind.rawValue
        ]
        if let radioAccessTechnology {
            fields["radioAccessTechnology"] = radioAccessTechnology
            fields["cellularTechnology"] = radioAccessTechnology
        }
        if let signalStrength {
            fields["signalStrength"] = Self.formatSignalFraction(signalStrength)
            fields["signalUnit"] = "fraction"
        }
        if let rssi {
            fields["rssi"] = String(rssi)
            fields["signalUnit"] = "dbm"
        }
        return fields
    }

    public static func kind(fromAdvertisement raw: String?) -> Kind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "wifi", "wi-fi", "wlan", "awdl":
            return .wifi
        case "cellular", "cell", "mobile", "wwan", "4g", "5g", "lte", "5guw", "5g uw":
            return .cellular
        case "ethernet", "wired", "wire", "lan":
            return .ethernet
        default:
            return .unknown
        }
    }

    public static func normalizedSignalStrength(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        let fraction = raw > 1.0 ? raw / 100.0 : raw
        return min(1.0, max(0.0, fraction))
    }

    public static func normalizedRSSI(_ rssi: Int) -> Double {
        let minRSSI = -100.0
        let maxRSSI = -30.0
        let clamped = min(maxRSSI, max(minRSSI, Double(rssi)))
        return (clamped - minRSSI) / (maxRSSI - minRSSI)
    }

    private static func sanitizedRadioAccessTechnology(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let allowed = value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || scalar == UnicodeScalar("-")
                || scalar == UnicodeScalar("_")
        }
        guard allowed else { return nil }
        let collapsed = value.replacingOccurrences(of: "_", with: " ")
        return collapsed.uppercased()
    }

    private static func formatSignalFraction(_ value: Double) -> String {
        String(format: "%.3f", min(1.0, max(0.0, value)))
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
    public var platformName: String?
    public var osVersion: String?
    public var modelName: String?
    public var chip: String?
    public var services: [String]
    public var portMap: [String: Int]
    public var remoteVideoFormats: Set<String>
 /// 设备连接方式集合（一台设备可能有多种连接方式）
    public var connectionTypes: Set<DeviceConnectionType>
 /// 设备唯一标识符（用于去重，如序列号、MAC地址等）
    public var uniqueIdentifier: String?
 /// 真实可拨路由标识符（例如 Bonjour service instance），与稳定身份分开保存。
    public var routeIdentifiers: [String]
 /// 链路强度（0-100），来源于真实测量（RSSI或RTT映射）
    public var signalStrength: Double?
 /// 对端声明的真实网络链路状态；没有公开/协议来源时保持 nil，不做猜测。
    public var networkLinkStatus: DeviceNetworkLinkStatus?
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
        platformName: String? = nil,
        osVersion: String? = nil,
        modelName: String? = nil,
        chip: String? = nil,
        services: [String],
        portMap: [String: Int],
        remoteVideoFormats: Set<String> = [],
        connectionTypes: Set<DeviceConnectionType> = [DeviceConnectionType.unknown],
        uniqueIdentifier: String? = nil,
        routeIdentifiers: [String] = [],
        signalStrength: Double? = nil,
        networkLinkStatus: DeviceNetworkLinkStatus? = nil,
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
        self.platformName = platformName
        self.osVersion = osVersion
        self.modelName = modelName
        self.chip = chip
        self.services = services
        self.portMap = portMap
        self.remoteVideoFormats = remoteVideoFormats
        self.connectionTypes = connectionTypes
        self.uniqueIdentifier = uniqueIdentifier
        self.routeIdentifiers = Self.normalizedRouteIdentifiers(routeIdentifiers)
        self.signalStrength = signalStrength
        self.networkLinkStatus = networkLinkStatus
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

    public mutating func mergeRouteIdentifiers(_ identifiers: [String]) {
        routeIdentifiers = Self.mergedRouteIdentifiers(routeIdentifiers, identifiers)
    }

    /// Strong identity and real dial-route aliases used to resolve an authenticated peer.
    /// The local discovery record UUID is intentionally excluded because it is not a peer identity.
    public var connectionRouteCandidates: [String] {
        Self.mergedRouteIdentifiers(
            [deviceId, uniqueIdentifier].compactMap { $0 },
            routeIdentifiers + [ipv4, ipv6].compactMap { $0 }
        )
    }

    public static func mergedRouteIdentifiers(_ lhs: [String], _ rhs: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for routeIdentifier in lhs + rhs {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            merged.append(trimmed)
        }
        return merged
    }

    private static func normalizedRouteIdentifiers(_ identifiers: [String]) -> [String] {
        mergedRouteIdentifiers([], identifiers)
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
        if connectionTypes.contains(.cellular) { return .cellular }
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
