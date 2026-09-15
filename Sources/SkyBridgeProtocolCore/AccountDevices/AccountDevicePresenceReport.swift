import Foundation

public enum AccountDevicePresenceReportError: Error, Equatable, Sendable {
    case invalidDeviceName
    case invalidMetadata(field: String)
    case tooManyLANAddresses(count: Int)
    case invalidLANAddress(String)
    case tooManyCapabilities(count: Int)
    case invalidCapability(String)
}

/// 心跳上报给信令服务器的本机元数据（只含元数据；身份绑定与 client/protocol 版本由各平台客户端自己附加）。
///
/// 校验规则与服务端 `lib/presence_report.js` 一一对应：这里先拒绝，服务端再拒绝一次，两端不允许"宽松放行再靠服务端截断"。
public struct AccountDevicePresenceReport: Encodable, Sendable, Equatable {
    public static let maximumDeviceNameCodePoints = 128
    public static let maximumMetadataBytes = 64
    public static let maximumLANAddresses = 8
    public static let maximumCapabilities = 16

    public let deviceName: String
    public let platform: AccountDevicePlatform
    public let deviceModel: String?
    public let osVersion: String?
    /// 已规范化：去重、保持上报顺序（首选接口在前）、最多 8 条。
    public let lanAddresses: [String]
    /// 已规范化：去重、字典序、最多 16 条。
    public let capabilities: [String]

    public init(
        deviceName: String,
        platform: AccountDevicePlatform,
        deviceModel: String?,
        osVersion: String?,
        lanAddresses: [String],
        capabilities: [AccountDeviceCapability]
    ) throws {
        self.deviceName = try Self.normalizedDeviceName(deviceName)
        self.platform = platform
        self.deviceModel = try Self.normalizedMetadata(deviceModel, field: "deviceModel")
        self.osVersion = try Self.normalizedMetadata(osVersion, field: "osVersion")
        self.lanAddresses = try Self.normalizedLANAddresses(lanAddresses)
        self.capabilities = try Self.normalizedCapabilities(capabilities.map(\.rawValue))
    }

    enum CodingKeys: String, CodingKey {
        case deviceName
        case platform
        case deviceModel
        case osVersion
        case lanAddresses
        case capabilities
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(platform.rawValue, forKey: .platform)
        try container.encodeIfPresent(deviceModel, forKey: .deviceModel)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encode(lanAddresses, forKey: .lanAddresses)
        try container.encode(capabilities, forKey: .capabilities)
    }

    // MARK: - Normalization (mirrors Server/skybridge-signaling/lib/presence_report.js)

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                || (0x7f...0x9f).contains(scalar.value)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    static func normalizedDeviceName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !containsControlCharacters(trimmed) else {
            throw AccountDevicePresenceReportError.invalidDeviceName
        }
        // 与服务端一致：按 Unicode 标量截断，绝不产生孤立代理项。
        let scalars = Array(trimmed.unicodeScalars.prefix(maximumDeviceNameCodePoints))
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func normalizedMetadata(_ raw: String?, field: String) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsControlCharacters(trimmed), trimmed.utf8.count <= maximumMetadataBytes else {
            throw AccountDevicePresenceReportError.invalidMetadata(field: field)
        }
        return trimmed
    }

    static func normalizedLANAddresses(_ raw: [String]) throws -> [String] {
        guard raw.count <= maximumLANAddresses else {
            throw AccountDevicePresenceReportError.tooManyLANAddresses(count: raw.count)
        }
        // 顺序即接口偏好（首选地址在前），与服务端 normalizePresenceReport 一样只去重、不重排。
        var canonicals: [String] = []
        var seen = Set<String>()
        for candidate in raw {
            guard let literal = LANAddressRoutabilityPolicy.parse(candidate) else {
                throw AccountDevicePresenceReportError.invalidLANAddress(candidate)
            }
            guard seen.insert(literal.canonical).inserted else { continue }
            canonicals.append(literal.canonical)
        }
        return canonicals
    }

    static func normalizedCapabilities(_ raw: [String]) throws -> [String] {
        guard raw.count <= maximumCapabilities else {
            throw AccountDevicePresenceReportError.tooManyCapabilities(count: raw.count)
        }
        var seen = Set<String>()
        for token in raw {
            guard Self.isValidCapabilityToken(token) else {
                throw AccountDevicePresenceReportError.invalidCapability(token)
            }
            seen.insert(token)
        }
        return seen.sorted()
    }

    static func isValidCapabilityToken(_ token: String) -> Bool {
        guard (1...32).contains(token.utf8.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (0x61...0x7a).contains(scalar.value)   // a-z
                || (0x30...0x39).contains(scalar.value)   // 0-9
                || scalar.value == 0x5f   // _
        }
    }
}
