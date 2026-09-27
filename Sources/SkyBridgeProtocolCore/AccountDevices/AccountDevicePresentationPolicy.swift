import Foundation

/// 账号设备列表的展示与可连接性规则（纯函数；macOS 与 iOS 共用，禁止各写一份）。
public enum AccountDevicePresentationPolicy {
    public enum Connectivity: Sendable, Equatable {
        /// 就是本机。
        case thisDevice
        /// 在局域网内被发现且身份（deviceId + 协议指纹）与注册表一致，可直接连接。
        case lanReachable
        /// 信令服务器报告在线，但不在同一局域网：需要跨网连接码/二维码。
        case online
        case offline
    }

    public struct Summary: Sendable, Equatable {
        public let total: Int
        public let online: Int
        public let remoteControllable: Int
    }

    /// 排序：本机 → 在线 → 最近活跃时间倒序（未知排最后）→ 名称（不区分大小写）→ deviceId。
    public static func orderedDevices(_ devices: [AccountDeviceRecord]) -> [AccountDeviceRecord] {
        devices.sorted { lhs, rhs in
            if lhs.isCaller != rhs.isCaller { return lhs.isCaller }
            if lhs.online != rhs.online { return lhs.online }
            switch (lhs.lastSeenAtEpochMilliseconds, rhs.lastSeenAtEpochMilliseconds) {
            case let (l?, r?) where l != r:
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            let leftName = displayName(for: lhs).lowercased()
            let rightName = displayName(for: rhs).lowercased()
            if leftName != rightName { return leftName < rightName }
            return lhs.id < rhs.id
        }
    }

    /// 本机永远是 `.thisDevice`；局域网可达优先于服务器在线（本地发现是直接证据）。
    public static func connectivity(
        for record: AccountDeviceRecord,
        isLANReachable: Bool
    ) -> Connectivity {
        if record.isCaller { return .thisDevice }
        if isLANReachable { return .lanReachable }
        if record.online { return .online }
        return .offline
    }

    /// 只认能力 token，不看平台：将来 Windows 被控端上报同一 token 时无需改 UI。
    public static func supportsRemoteControlHosting(_ record: AccountDeviceRecord) -> Bool {
        record.knownCapabilities.contains(.remoteDesktop)
    }

    /// 局域网地址优先（IPv4 在前），否则公网地址。
    public static func primaryAddress(for record: AccountDeviceRecord) -> String? {
        if let lan = record.lanAddresses.first(where: { LANAddressRoutabilityPolicy.parse($0)?.family == .ipv4 }) {
            return lan
        }
        if let lan = record.lanAddresses.first { return lan }
        return record.publicAddress
    }

    public static func displayName(for record: AccountDeviceRecord) -> String {
        if let name = record.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let model = modelDisplayName(for: record),
               genericDeviceNames.contains(name.lowercased()) {
                return model
            }
            return name
        }
        if let model = modelDisplayName(for: record) {
            return model
        }
        return shortDeviceId(record.deviceId)
    }

    private static let genericDeviceNames: Set<String> = [
        "mac", "iphone", "ipad", "ipod touch", "apple device", "ios device", "unknown device"
    ]

    public static func modelDisplayName(for record: AccountDeviceRecord) -> String? {
        AppleHardwareModelCatalog.displayName(for: record.deviceModel)
    }

    /// Metadata can supply a missing icon, but never a registration or trust binding.
    public static func displayPlatform(for record: AccountDeviceRecord) -> AccountDevicePlatform? {
        record.platform ?? AppleHardwareModelCatalog.model(for: record.deviceModel)?.platform
    }

    public enum RegistrationIssue: Sendable, Equatable {
        case identityMismatch
        case notRegistered
        case pending
        case frozen
        case unrecognizedStatus
    }

    /// An accepted heartbeat is ephemeral presence, not proof that this identity
    /// was enrolled. Only the server's exact-binding `isCaller` establishes that.
    public static func registrationIssue(for snapshot: AccountDeviceListSnapshot) -> RegistrationIssue? {
        if let caller = snapshot.devices.first(where: \.isCaller) {
            switch caller.status {
            case "pending": return .pending
            case "frozen": return .frozen
            case "active": return nil
            default: return .unrecognizedStatus
            }
        }
        guard !snapshot.truncated else { return nil }
        if snapshot.devices.contains(where: { $0.deviceId == snapshot.callerDeviceId }) {
            return .identityMismatch
        }
        // A truncated response cannot establish that this device is absent.
        return .notRegistered
    }

    /// 设备 ID 的短展示形式：前 8 个字符，大写。
    public static func shortDeviceId(_ deviceId: String) -> String {
        String(deviceId.prefix(8)).uppercased()
    }

    /// 「最近活跃」的时间分档。文案本地化由各平台负责，分档规则必须两端一致。
    public enum RelativeTimeBucket: Sendable, Equatable {
        case never
        case justNow
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    public static func relativeTimeBucket(from date: Date?, now: Date) -> RelativeTimeBucket {
        guard let date else { return .never }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return .justNow }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return .minutes(minutes) }
        let hours = minutes / 60
        if hours < 24 { return .hours(hours) }
        return .days(hours / 24)
    }

    /// 平台展示名（与本地化无关的固定商标名，两端共用一份）。
    public static func platformDisplayName(_ platform: AccountDevicePlatform) -> String {
        switch platform {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .iPadOS: return "iPadOS"
        case .android: return "Android"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }

    public static func summary(for devices: [AccountDeviceRecord]) -> Summary {
        Summary(
            total: devices.count,
            online: devices.filter(\.online).count,
            remoteControllable: devices.filter(supportsRemoteControlHosting).count
        )
    }
}
