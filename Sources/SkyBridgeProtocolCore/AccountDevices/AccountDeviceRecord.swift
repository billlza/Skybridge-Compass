import Foundation

/// 账号设备能力词汇（与 iCloud KVS 心跳、Bonjour TXT 使用同一套 token）。
/// 记录里保留原始 `[String]` 以便前向兼容；UI 判断只认这里列出的 token。
public enum AccountDeviceCapability: String, CaseIterable, Sendable {
    /// 可作为远程桌面被控端（当前仅 macOS 上报）。
    case remoteDesktop = "remote_desktop"
    case fileTransfer = "file_transfer"
    case clipboard = "clipboard"
}

/// 账号设备的平台标识，与 Bonjour 广播的平台 token 同源（macos/ios/ipados/android/windows/linux）。
public typealias AccountDevicePlatform = BonjourInteropProtocolContract.AdvertisementPlatform

/// 信令服务器 `GET /api/devices/list` 返回的单台设备：注册表行 + 实时在线记录合并后的结果。
///
/// 时间戳一律是 epoch 毫秒整数（服务端已把 PostgREST 的 ISO 字符串转换掉），不使用 `Date` 解码策略。
public struct AccountDeviceRecord: Codable, Sendable, Equatable, Identifiable {
    public let deviceId: String
    public let deviceName: String?
    /// 注册表状态：active / pending / frozen（revoked 永远不会出现在列表里）。
    public let status: String
    public let protocolSigningAlgorithm: String
    public let protocolPublicKeyFingerprint: String
    /// 服务端原始平台字符串；未知值保留原文而不是解码失败。
    public let platformRawValue: String?
    public let deviceModel: String?
    public let osVersion: String?
    public let appVersion: String?
    public let lanAddresses: [String]
    public let publicAddress: String?
    public let capabilities: [String]
    public let registeredAtEpochMilliseconds: Int64?
    public let lastSeenAtEpochMilliseconds: Int64?
    public let presenceUpdatedAtEpochMilliseconds: Int64?
    /// 服务端合并时的在线判定；快照过期后由引擎统一置为 false（见 `markingOffline()`）。
    public private(set) var online: Bool
    /// 该行是否就是发起请求的设备（服务端按完整身份绑定判定）。
    public let isCaller: Bool

    /// A hardware/device ID can survive a signing-key change. Separate registry
    /// bindings must remain separate rows; neither their metadata nor trust merges.
    public var id: String {
        "\(deviceId)/\(protocolSigningAlgorithm)/\(protocolPublicKeyFingerprint.lowercased())"
    }

    public var platform: AccountDevicePlatform? {
        platformRawValue.flatMap(AccountDevicePlatform.init(rawValue:))
    }

    public var lastSeenAt: Date? { Self.date(fromEpochMilliseconds: lastSeenAtEpochMilliseconds) }

    public var knownCapabilities: Set<AccountDeviceCapability> {
        Set(capabilities.compactMap(AccountDeviceCapability.init(rawValue:)))
    }

    /// 同一记录的离线副本：快照超过 TTL 未刷新时，名称/地址等静态信息仍然有用，但在线状态必须失效。
    public func markingOffline() -> AccountDeviceRecord {
        guard online else { return self }
        var copy = self
        copy.online = false
        return copy
    }

    public init(
        deviceId: String,
        deviceName: String?,
        status: String,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        platformRawValue: String?,
        deviceModel: String?,
        osVersion: String?,
        appVersion: String?,
        lanAddresses: [String],
        publicAddress: String?,
        capabilities: [String],
        registeredAtEpochMilliseconds: Int64?,
        lastSeenAtEpochMilliseconds: Int64?,
        presenceUpdatedAtEpochMilliseconds: Int64?,
        online: Bool,
        isCaller: Bool
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.status = status
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
        self.platformRawValue = platformRawValue
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.lanAddresses = lanAddresses
        self.publicAddress = publicAddress
        self.capabilities = capabilities
        self.registeredAtEpochMilliseconds = registeredAtEpochMilliseconds
        self.lastSeenAtEpochMilliseconds = lastSeenAtEpochMilliseconds
        self.presenceUpdatedAtEpochMilliseconds = presenceUpdatedAtEpochMilliseconds
        self.online = online
        self.isCaller = isCaller
    }

    enum CodingKeys: String, CodingKey {
        case deviceId
        case deviceName
        case status
        case protocolSigningAlgorithm
        case protocolPublicKeyFingerprint
        case platformRawValue = "platform"
        case deviceModel
        case osVersion
        case appVersion
        case lanAddresses
        case publicAddress
        case capabilities
        case registeredAtEpochMilliseconds = "registeredAt"
        case lastSeenAtEpochMilliseconds = "lastSeenAt"
        case presenceUpdatedAtEpochMilliseconds = "presenceUpdatedAt"
        case online
        case isCaller
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        status = try container.decode(String.self, forKey: .status)
        protocolSigningAlgorithm = try container.decode(String.self, forKey: .protocolSigningAlgorithm)
        protocolPublicKeyFingerprint = try container.decode(String.self, forKey: .protocolPublicKeyFingerprint)
        platformRawValue = try container.decodeIfPresent(String.self, forKey: .platformRawValue)
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        lanAddresses = try container.decodeIfPresent([String].self, forKey: .lanAddresses) ?? []
        publicAddress = try container.decodeIfPresent(String.self, forKey: .publicAddress)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        registeredAtEpochMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .registeredAtEpochMilliseconds)
        lastSeenAtEpochMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .lastSeenAtEpochMilliseconds)
        presenceUpdatedAtEpochMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .presenceUpdatedAtEpochMilliseconds)
        online = try container.decode(Bool.self, forKey: .online)
        isCaller = try container.decodeIfPresent(Bool.self, forKey: .isCaller) ?? false
    }

    static func date(fromEpochMilliseconds value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
    }
}

/// `GET /api/devices/list` 的完整响应。
public struct AccountDeviceListSnapshot: Codable, Sendable, Equatable {
    public let generatedAtEpochMilliseconds: Int64
    public let callerDeviceId: String
    /// 服务端按 200 台截断时为 true；UI 必须提示而不是假装列表完整。
    public let truncated: Bool
    public let devices: [AccountDeviceRecord]

    public var generatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(generatedAtEpochMilliseconds) / 1_000)
    }

    public var onlineDeviceIds: Set<String> {
        Set(devices.filter(\.online).map(\.deviceId))
    }

    public var hasOnlineDevices: Bool {
        devices.contains(where: \.online)
    }

    /// 全部设备置为离线的副本（快照过期时使用）。
    public func markingAllOffline() -> AccountDeviceListSnapshot {
        guard hasOnlineDevices else { return self }
        return AccountDeviceListSnapshot(
            generatedAtEpochMilliseconds: generatedAtEpochMilliseconds,
            callerDeviceId: callerDeviceId,
            truncated: truncated,
            devices: devices.map { $0.markingOffline() }
        )
    }

    public init(
        generatedAtEpochMilliseconds: Int64,
        callerDeviceId: String,
        truncated: Bool,
        devices: [AccountDeviceRecord]
    ) {
        self.generatedAtEpochMilliseconds = generatedAtEpochMilliseconds
        self.callerDeviceId = callerDeviceId
        self.truncated = truncated
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case generatedAtEpochMilliseconds = "generatedAt"
        case callerDeviceId
        case truncated
        case devices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAtEpochMilliseconds = try container.decode(Int64.self, forKey: .generatedAtEpochMilliseconds)
        callerDeviceId = try container.decode(String.self, forKey: .callerDeviceId)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        devices = try container.decode([AccountDeviceRecord].self, forKey: .devices)
    }
}
