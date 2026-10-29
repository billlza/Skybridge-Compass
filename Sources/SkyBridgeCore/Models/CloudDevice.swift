// CloudKit 设备模型。定义在此处而不是 CloudKitService（当前仍是 macOS 侧实现）内部，
// 因为 CrossNetworkConnectionManager 与 CloudDeviceService 等共享层引用它。
//
// 抽取自 Services/CloudKitService.swift，属于 iOS/SkyBridgeCore 统一化的分层修复：
// 模型类型不应与平台专属实现耦合在同一文件。

import CloudKit
import Foundation

public struct CloudDevice: Identifiable, Equatable, Codable {
    public let id: String
    public let deviceName: String
    public let deviceModel: String
    public let publicKey: String
    public let lastSeenAt: Date
    public let lastKnownEndpoint: String?
    public let capabilities: [String]

    public var isOnline: Bool {
 // 假设 5 分钟内有心跳视为在线
        return Date().timeIntervalSince(lastSeenAt) < 5 * 60
    }

 // 兼容 UI 的辅助属性
    public var name: String { deviceName }
    public var lastSeen: Date { lastSeenAt }
    public var type: DeviceType {
        if deviceModel.contains("Mac") { return .mac }
        if deviceModel.contains("iPhone") { return .iPhone }
        if deviceModel.contains("iPad") { return .iPad }
        return .mac // Default
    }

    public enum DeviceType: String, Codable {
        case mac, iPhone, iPad
    }

    public enum DeviceCapability: String, Codable {
        case remoteDesktop, fileTransfer, screenMirroring
    }

    public var deviceCapabilities: [DeviceCapability] {
        return capabilities.compactMap { DeviceCapability(rawValue: $0) }
    }

    init?(record: CKRecord) {
        guard let deviceId = record["deviceId"] as? String,
              let deviceName = record["deviceName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }
        let publicKey = (record["publicKeyFingerprint"] as? String) ?? (record["publicKey"] as? String) ?? ""

        self.id = deviceId
        self.deviceName = deviceName
        self.deviceModel = record["deviceModel"] as? String ?? "Unknown"
        self.publicKey = publicKey
        self.lastSeenAt = lastSeenAt
        self.lastKnownEndpoint = record["lastKnownEndpoint"] as? String
        self.capabilities = record["capabilities"] as? [String] ?? []
    }

 // 为了兼容 CrossNetworkConnectionManager 的初始化
    public init(id: String, name: String, type: DeviceType, lastSeen: Date, capabilities: [DeviceCapability]) {
        self.id = id
        self.deviceName = name
        self.deviceModel = type == .mac ? "Mac" : (type == .iPhone ? "iPhone" : "iPad")
        self.publicKey = ""
        self.lastSeenAt = lastSeen
        self.lastKnownEndpoint = nil
        self.capabilities = capabilities.map { $0.rawValue }
    }
}
