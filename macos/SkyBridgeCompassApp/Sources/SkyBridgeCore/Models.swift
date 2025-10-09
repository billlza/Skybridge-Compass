import Foundation
import OrderedCollections

/// 表示当前登录用户的安全会话信息。
public struct AuthSession: Codable, Hashable {
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
public struct RemoteSessionSummary: Identifiable, Hashable {
    public let id: UUID
    public let targetName: String
    public let protocolDescription: String
    public let bandwidthMbps: Double
    public let frameLatencyMilliseconds: Double

    public init(
        id: UUID,
        targetName: String,
        protocolDescription: String,
        bandwidthMbps: Double,
        frameLatencyMilliseconds: Double
    ) {
        self.id = id
        self.targetName = targetName
        self.protocolDescription = protocolDescription
        self.bandwidthMbps = bandwidthMbps
        self.frameLatencyMilliseconds = frameLatencyMilliseconds
    }
}

/// 表示通过真实网络扫描获得的可连接设备。
public struct DiscoveredDevice: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let ipv4: String?
    public let ipv6: String?
    public let services: [String]
    public let portMap: [String: Int]

    public init(
        id: UUID,
        name: String,
        ipv4: String?,
        ipv6: String?,
        services: [String],
        portMap: [String: Int]
    ) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.services = services
        self.portMap = portMap
    }
}

/// 表示一个正在进行或最近完成的文件传输任务。
public struct FileTransferTask: Identifiable, Hashable {
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
public struct RemoteMetricsSnapshot {
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
