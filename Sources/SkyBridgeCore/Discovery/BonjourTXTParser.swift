import Foundation
import Network

// MARK: - Bonjour TXT 记录解析器
// Swift 6.2.1 最佳实践：统一的 TXT 记录解析，消除重复代码

/// 设备信息结构体
public struct BonjourDeviceInfo: Sendable, Equatable {
    public let deviceId: String?
    public let hostname: String?
    public let model: String?
    public let type: String?
    public let version: String?
    /// 操作系统版本（优先用于 UI 展示；例如 "macOS 26.2" / "iOS 26.0"）
    public let osVersion: String?
    public let manufacturer: String?
    public let platform: String?
    public let name: String?

    public init(
        deviceId: String? = nil,
        hostname: String? = nil,
        model: String? = nil,
        type: String? = nil,
        version: String? = nil,
        osVersion: String? = nil,
        manufacturer: String? = nil,
        platform: String? = nil,
        name: String? = nil
    ) {
        self.deviceId = deviceId
        self.hostname = hostname
        self.model = model
        self.type = type
        self.version = version
        self.osVersion = osVersion
        self.manufacturer = manufacturer
        self.platform = platform
        self.name = name
    }

 /// 获取最佳可用的唯一标识符
    public var bestIdentifier: String? {
        deviceId ?? hostname ?? name
    }

 /// 获取最佳可用的显示名称
    public var displayName: String? {
        name ?? hostname ?? model
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
        ("deviceId", ["deviceId", "id", "deviceID", "device_id"]),
        ("serial", ["serial", "serialNumber", "sn"]),
        ("mac", ["mac", "macAddress", "hwaddr"]),
        ("bssid", ["bssid"]),
        ("hostname", ["hostname", "host"]),
        ("model", ["model", "modelName", "md"]),
        ("type", ["type", "deviceType"]),
        ("name", ["name", "device", "fn"]),
        ("manufacturer", ["manufacturer", "brand", "mf"]),
        ("platform", ["platform", "os"]),
        ("version", ["version", "ver", "sw"]),
        ("osVersion", ["osVersion", "os_version", "osver", "osVer", "osv"]),
    ]

 /// 用于正则解析的模式（降级方案）
    private static let regexPatterns: [(key: String, pattern: String)] = [
        ("deviceId", "deviceId=([^,\\]]+)"),
        ("id", "id=([^,\\]]+)"),
        ("deviceID", "deviceID=([^,\\]]+)"),
        ("serial", "serial=([^,\\]]+)"),
        ("mac", "mac=([0-9A-Fa-f:]{12,17})"),
        ("bssid", "bssid=([0-9A-Fa-f:]{12,17})"),
        ("hostname", "hostname=([^,\\]]+)"),
        ("model", "model=([^,\\]]+)"),
        ("modelName", "modelName=([^,\\]]+)"),
        ("brand", "brand=([^,\\]]+)"),
        ("manufacturer", "manufacturer=([^,\\]]+)"),
        ("name", "name=([^,\\]]+)"),
        ("device", "device=([^,\\]]+)"),
        ("type", "type=([^,\\]]+)"),
        ("platform", "platform=([^,\\]]+)"),
        ("version", "version=([^,\\]]+)"),
        ("osVersion", "osVersion=([^,\\]]+)"),
        ("os_version", "os_version=([^,\\]]+)"),
    ]

 // MARK: - 主解析方法

 /// 解析 NWTXTRecord 为字典
 /// - Parameter txtRecord: Network.framework 的 TXT 记录
 /// - Returns: 键值对字典
    public static func parse(_ txtRecord: NWTXTRecord) -> [String: String] {
        var result: [String: String] = [:]

 // 方法 1: 尝试使用原生 API（macOS 14.0+）
        if #available(macOS 14.0, *) {
 // NWTXTRecord 在 macOS 14+ 提供更好的迭代支持
 // 通过 rawValue 获取底层数据
            if let rawData = txtRecord.rawValue {
                let parsed = parseRawTXTData(rawData)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }

 // 方法 2: 使用 NetService 兼容层
        if let rawData = txtRecord.rawValue {
            let dict = NetService.dictionary(fromTXTRecord: rawData)
            for (key, value) in dict {
                if let stringValue = String(data: value, encoding: .utf8) {
                    result[key] = stringValue
                }
            }
            if !result.isEmpty {
                return result
            }
        }

 // 方法 3: 降级到字符串正则解析
        let description = "\(txtRecord)"
        return parseWithRegex(description)
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
        let deviceId = dict["deviceId"] ?? dict["id"] ?? dict["deviceID"] ?? dict["serial"] ?? dict["mac"] ?? dict["bssid"]

        return BonjourDeviceInfo(
            deviceId: deviceId,
            hostname: dict["hostname"] ?? dict["host"],
            model: dict["model"] ?? dict["modelName"],
            type: dict["type"] ?? dict["deviceType"],
            version: dict["version"] ?? dict["ver"],
            osVersion: dict["osVersion"] ?? dict["os_version"] ?? dict["osver"] ?? dict["osVer"] ?? dict["osv"],
            manufacturer: dict["manufacturer"] ?? dict["brand"],
            platform: dict["platform"] ?? dict["os"],
            name: dict["name"] ?? dict["device"] ?? dict["fn"]
        )
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
        return dict["deviceId"] ?? dict["id"] ?? dict["deviceID"] ?? dict["serial"] ?? dict["mac"] ?? dict["bssid"]
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

// MARK: - NWTXTRecord 扩展

extension NWTXTRecord {
 /// 获取原始数据（兼容层）
 /// NWTXTRecord 没有直接的 rawValue 属性，通过描述解析或使用 NetService 转换
    public var rawValue: Data? {
 // 尝试从描述中提取数据
 // 这是一个兼容层，因为 NWTXTRecord 的内部实现可能变化
        let description = "\(self)"

 // 如果描述包含有效数据，尝试重建
        if description.contains("=") {
 // 构建 TXT 记录数据
            var data = Data()
            let pairs = BonjourTXTParser.parseWithRegex(description)

            for (key, value) in pairs {
                let entry = "\(key)=\(value)"
                if let entryData = entry.data(using: .utf8), entryData.count < 256 {
                    data.append(UInt8(entryData.count))
                    data.append(entryData)
                }
            }

            return data.isEmpty ? nil : data
        }

        return nil
    }
}

// MARK: - 注意事项
// TXTRecordHelper 已在 RealSignalService.swift 中定义
// 新代码应直接使用 BonjourTXTParser

