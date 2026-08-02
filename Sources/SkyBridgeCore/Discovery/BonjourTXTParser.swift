import Foundation
import Network

// MARK: - Bonjour TXT 记录解析器
// Swift 6.2.1 最佳实践：统一的 TXT 记录解析，消除重复代码

/// 设备信息结构体
public struct BonjourDeviceInfo: Sendable, Equatable {
    public let deviceId: String?
    public let hostname: String?
    public let model: String?
    public let chip: String?
    public let type: String?
    public let version: String?
    /// 操作系统版本（优先用于 UI 展示；例如 "macOS 26.2" / "iOS 26.0"）
    public let osVersion: String?
    public let manufacturer: String?
    public let platform: String?
    public let name: String?
    public let remoteVideoFormats: [String]

    public init(
        deviceId: String? = nil,
        hostname: String? = nil,
        model: String? = nil,
        chip: String? = nil,
        type: String? = nil,
        version: String? = nil,
        osVersion: String? = nil,
        manufacturer: String? = nil,
        platform: String? = nil,
        name: String? = nil,
        remoteVideoFormats: [String] = []
    ) {
        self.deviceId = deviceId
        self.hostname = hostname
        self.model = model
        self.chip = chip
        self.type = type
        self.version = version
        self.osVersion = osVersion
        self.manufacturer = manufacturer
        self.platform = platform
        self.name = name
        self.remoteVideoFormats = remoteVideoFormats
    }

 /// 获取最佳可用的唯一标识符
    public var bestIdentifier: String? {
        deviceId ?? hostname ?? name
    }

 /// 获取最佳可用的显示名称
    public var displayName: String? {
        name ?? model ?? hostname
    }
}

/// 统一的 Bonjour TXT 记录解析器
///
/// Swift 6.2.1 特性：
/// - `Sendable` 协议确保跨并发域安全
/// - 静态方法避免状态共享问题
/// - 支持 macOS 14.0+ 原生 API 和降级方案
public enum BonjourTXTParser: Sendable {

 // MARK: - 解析模式定义

 /// TXT 记录键名映射（支持多种命名约定）
    private static let keyPatterns: [(key: String, patterns: [String])] = [
        ("deviceId", ["deviceId", "id", "deviceID", "device_id", "uuid", "uniqueId", "unique_id"]),
        ("serial", ["serial", "serialNumber", "sn"]),
        ("mac", ["mac", "macAddress", "hwaddr"]),
        ("bssid", ["bssid"]),
        ("hostname", ["hostname", "host"]),
        ("model", ["model", "modelName", "md"]),
        ("chip", ["chip", "soc", "cpu"]),
        ("type", ["type", "deviceType"]),
        ("name", ["name", "device", "fn"]),
        ("manufacturer", ["manufacturer", "brand", "mf"]),
        ("platform", ["platform", "os"]),
        ("version", ["version", "ver", "sw"]),
        ("osVersion", ["osVersion", "os_version", "osver", "osVer", "osv"]),
        ("remoteVideoFormats", ["remoteVideoFormats", "remotevideoformats", "remote_video_formats", "remoteformats", "remotevideformats"]),
    ]

 /// 用于正则解析的模式（降级方案）
    private static let regexPatterns: [(key: String, pattern: String)] = [
        ("deviceId", "deviceId=([^,\\]]+)"),
        ("id", "id=([^,\\]]+)"),
        ("deviceID", "deviceID=([^,\\]]+)"),
        ("uuid", "uuid=([^,\\]]+)"),
        ("uniqueId", "uniqueId=([^,\\]]+)"),
        ("unique_id", "unique_id=([^,\\]]+)"),
        ("serial", "serial=([^,\\]]+)"),
        ("mac", "mac=([0-9A-Fa-f:]{12,17})"),
        ("bssid", "bssid=([0-9A-Fa-f:]{12,17})"),
        ("hostname", "hostname=([^,\\]]+)"),
        ("model", "model=([^,\\]]+)"),
        ("modelName", "modelName=([^,\\]]+)"),
        ("chip", "chip=([^,\\]]+)"),
        ("brand", "brand=([^,\\]]+)"),
        ("manufacturer", "manufacturer=([^,\\]]+)"),
        ("name", "name=([^,\\]]+)"),
        ("device", "device=([^,\\]]+)"),
        ("type", "type=([^,\\]]+)"),
        ("platform", "platform=([^,\\]]+)"),
        ("version", "version=([^,\\]]+)"),
        ("osVersion", "osVersion=([^,\\]]+)"),
        ("os_version", "os_version=([^,\\]]+)"),
        (
            "remoteVideoFormats",
            "remoteVideoFormats=([^\\]]+?)(?=,(?:[A-Za-z0-9_]+=)|\\]|$)"
        ),
        (
            "remote_video_formats",
            "remote_video_formats=([^\\]]+?)(?=,(?:[A-Za-z0-9_]+=)|\\]|$)"
        ),
        (
            "remoteformats",
            "remoteformats=([^\\]]+?)(?=,(?:[A-Za-z0-9_]+=)|\\]|$)"
        ),
        (
            "remotevideoformats",
            "remotevideoformats=([^\\]]+?)(?=,(?:[A-Za-z0-9_]+=)|\\]|$)"
        ),
        (
            "remotevideformats",
            "remotevideformats=([^\\]]+?)(?=,(?:[A-Za-z0-9_]+=)|\\]|$)"
        ),
    ]

 // MARK: - 主解析方法

 /// 解析 NWTXTRecord 为字典
    /// - Parameter txtRecord: Network.framework 的 TXT 记录
    /// - Returns: 键值对字典
    public static func parse(_ txtRecord: NWTXTRecord) -> [String: String] {
        parseRawTXTData(txtRecord.data)
    }

 /// 从原始 TXT 记录数据解析
 /// - Parameter data: TXT 记录的原始字节数据
 /// - Returns: 键值对字典
    public static func parseRawTXTData(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex

        while index < data.endIndex {
 // TXT 记录格式：[length][key=value]
            let length = Int(data[index])
            index = data.index(after: index)

            guard index.advanced(by: length) <= data.endIndex else { break }

            let entryData = data[index..<index.advanced(by: length)]
            if let entry = String(data: entryData, encoding: .utf8) {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    result[String(parts[0])] = String(parts[1])
                } else if parts.count == 1 {
 // 布尔标志（无值）
                    result[String(parts[0])] = ""
                }
            }

            index = index.advanced(by: length)
        }

        return result
    }

 /// 使用正则表达式解析字符串描述（降级方案）
 /// - Parameter description: TXT 记录的字符串描述
 /// - Returns: 键值对字典
    public static func parseWithRegex(_ description: String) -> [String: String] {
        var dict: [String: String] = [:]

        for (key, pattern) in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: description, options: [], range: NSRange(description.startIndex..., in: description)),
               let range = Range(match.range(at: 1), in: description) {
                dict[key] = String(description[range])
            }
        }

        return dict
    }

 // MARK: - 高级解析方法

 /// 提取设备信息
 /// - Parameter txtRecord: NWTXTRecord
 /// - Returns: 结构化的设备信息
    public static func extractDeviceInfo(_ txtRecord: NWTXTRecord) -> BonjourDeviceInfo {
        let dict = parse(txtRecord)
        return extractDeviceInfo(from: dict)
    }

 /// 从字典提取设备信息
 /// - Parameter dict: 解析后的字典
 /// - Returns: 结构化的设备信息
    public static func extractDeviceInfo(from dict: [String: String]) -> BonjourDeviceInfo {
 // 查找设备 ID（按优先级）
        let deviceId = dict["deviceId"]
            ?? dict["id"]
            ?? dict["deviceID"]
            ?? dict["device_id"]
            ?? dict["uuid"]
            ?? dict["uniqueId"]
            ?? dict["unique_id"]
            ?? dict["serial"]
            ?? dict["mac"]
            ?? dict["bssid"]
        let remoteVideoFormats = parseRemoteVideoFormats(
            dict["remoteVideoFormats"]
                ?? dict["remotevideoformats"]
                ?? dict["remote_video_formats"]
                ?? dict["remoteformats"]
                ?? dict["remotevideformats"]
        )

        let platform = dict["platform"] ?? dict["os"]
        let model = sanitizedDisplayName(dict["model"] ?? dict["modelName"])
        let hostname = sanitizedDisplayName(dict["hostname"] ?? dict["host"])
        let name = sanitizedDisplayName(dict["name"] ?? dict["device"] ?? dict["fn"])

        return BonjourDeviceInfo(
            deviceId: deviceId,
            hostname: hostname,
            model: model,
            chip: dict["chip"] ?? dict["soc"] ?? dict["cpu"],
            type: dict["type"] ?? dict["deviceType"],
            version: dict["version"] ?? dict["ver"],
            osVersion: dict["osVersion"] ?? dict["os_version"] ?? dict["osver"] ?? dict["osVer"] ?? dict["osv"],
            manufacturer: dict["manufacturer"] ?? dict["brand"],
            platform: platform,
            name: name,
            remoteVideoFormats: remoteVideoFormats
        )
    }

    private static func sanitizedDisplayName(_ raw: String?) -> String? {
        LocalDevicePresentation.sanitizedDisplayNameCandidate(raw)
    }

    private static func parseRemoteVideoFormats(_ raw: String?) -> [String] {
        BonjourInteropContract.normalizedRemoteVideoFormats(from: raw)
    }

 /// 从字符串描述提取设备信息
 /// - Parameter description: TXT 记录字符串
 /// - Returns: 结构化的设备信息
    public static func extractDeviceInfo(from description: String) -> BonjourDeviceInfo {
        let dict = parseWithRegex(description)
        return extractDeviceInfo(from: dict)
    }

 // MARK: - 便捷方法

 /// 获取设备唯一标识符
 /// - Parameter txtRecord: NWTXTRecord
 /// - Returns: 设备唯一标识符（如有）
    public static func getDeviceIdentifier(_ txtRecord: NWTXTRecord) -> String? {
        let dict = parse(txtRecord)
        return dict["deviceId"]
            ?? dict["id"]
            ?? dict["deviceID"]
            ?? dict["device_id"]
            ?? dict["uuid"]
            ?? dict["uniqueId"]
            ?? dict["unique_id"]
            ?? dict["serial"]
            ?? dict["mac"]
            ?? dict["bssid"]
    }

 /// 获取设备显示名称
 /// - Parameter txtRecord: NWTXTRecord
 /// - Returns: 设备显示名称（如有）
    public static func getDisplayName(_ txtRecord: NWTXTRecord) -> String? {
        let dict = parse(txtRecord)
 // 优先使用友好名称，然后是主机名，最后是型号
        if let name = dict["name"] ?? dict["device"] ?? dict["fn"] {
            return name
        }
        if let hostname = dict["hostname"] ?? dict["host"] {
            return hostname
        }
        if let model = dict["model"] ?? dict["modelName"] {
            return model
        }
        return nil
    }

 /// 获取设备类型信息
 /// - Parameter txtRecord: NWTXTRecord
 /// - Returns: 设备类型字符串（如有）
    public static func getDeviceType(_ txtRecord: NWTXTRecord) -> String? {
        let dict = parse(txtRecord)
        return dict["type"] ?? dict["model"] ?? dict["deviceType"]
    }
}

extension BonjourTXTParser {
    public static func extractNetworkLinkStatus(_ txtRecord: NWTXTRecord) -> DeviceNetworkLinkStatus? {
        extractNetworkLinkStatus(from: parse(txtRecord))
    }

    public static func extractNetworkLinkStatus(from dict: [String: String]) -> DeviceNetworkLinkStatus? {
        let rawKind = firstValue(
            in: dict,
            keys: [
                "linkKind", "networkType", "network_kind", "network_type",
                "interfaceType", "interface_type", "connectionType", "connection_type"
            ]
        )
        let radioTechnology = firstValue(
            in: dict,
            keys: [
                "radioAccessTechnology", "radio_access_technology",
                "radioTech", "radio_tech",
                "cellularTechnology", "cellular_technology",
                "mobileDataLabel", "mobile_data_label", "rat"
            ]
        )
        let rssi = firstValue(in: dict, keys: ["rssi", "wifiRSSI", "wifi_rssi"])
            .flatMap(parseRSSI)
        let explicitSignal = firstValue(
            in: dict,
            keys: [
                "signalStrength", "signal_strength", "signal",
                "signalPercent", "signal_percent",
                "signalFraction", "signal_fraction"
            ]
        ).flatMap { parseSignalStrength($0, unit: firstValue(in: dict, keys: ["signalUnit", "signal_unit"])) }

        let inferredKind = DeviceNetworkLinkStatus.kind(fromAdvertisement: rawKind)
            ?? (radioTechnology == nil ? nil : .cellular)

        guard let kind = inferredKind ?? (rssi != nil || explicitSignal != nil ? .unknown : nil) else {
            return nil
        }

        return DeviceNetworkLinkStatus(
            kind: kind,
            radioAccessTechnology: radioTechnology,
            signalStrength: explicitSignal,
            rssi: rssi
        )
    }

    private static func firstValue(in dict: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmpty(dict[key]) ?? nonEmpty(dict[key.lowercased()]) {
                return value
            }
        }
        return nil
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func parseRSSI(_ raw: String) -> Int? {
        let cleaned = raw
            .replacingOccurrences(of: "dbm", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(cleaned) {
            return value
        }
        if let value = Double(cleaned) {
            return Int(value.rounded())
        }
        let numeric = cleaned.filter { "-0123456789.".contains($0) }
        return Double(numeric).map { Int($0.rounded()) }
    }

    private static func parseSignalStrength(_ raw: String, unit: String?) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value.isFinite else {
            return nil
        }

        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedUnit == "percent" || normalizedUnit == "%" {
            return DeviceNetworkLinkStatus.normalizedSignalStrength(value)
        }
        if normalizedUnit == "fraction" || normalizedUnit == "ratio" {
            return DeviceNetworkLinkStatus.normalizedSignalStrength(value)
        }
        if normalizedUnit == "dbm" {
            return nil
        }
        return DeviceNetworkLinkStatus.normalizedSignalStrength(value)
    }
}

// MARK: - 注意事项
// 旧的 RealSignalService / TXTRecordHelper 已下线
// 新代码应直接使用 BonjourTXTParser
