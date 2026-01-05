import Foundation
import SkyBridgeCore

/// 为 SwiftUI 提供 Apple ID 设备链数据的 Service 抽象
@MainActor
public protocol CloudDeviceService: Sendable {
 /// 获取当前 Apple ID 下所有已注册设备
    func fetchDevices() async throws -> [iCloudDevice]

 /// 刷新本机心跳（可选，用于在线状态更准确）
    func refreshHeartbeat() async throws
    
 /// 获取本机设备 ID
    var currentDeviceId: String? { get }
}

@MainActor
public final class DefaultCloudDeviceService: CloudDeviceService {
    public static let shared = DefaultCloudDeviceService()

    private let manager = iCloudDeviceDiscoveryManager.shared

    public init() {}

    public func fetchDevices() async throws -> [iCloudDevice] {
 // 调用 Core 中的刷新逻辑，确保列表是最新的
        await manager.refreshDevices()
        return manager.discoveredDevices
    }

    public func refreshHeartbeat() async throws {
        await manager.updateHeartbeat()
    }
    
    public var currentDeviceId: String? {
        manager.currentDevice?.id
    }
}

/// Preview 专用 Service
public final class PreviewCloudDeviceService: CloudDeviceService, @unchecked Sendable {
    public init() {}
    
    public func fetchDevices() async throws -> [iCloudDevice] {
        [
            iCloudDevice(
                id: "local-mac",
                name: "Lza 的 MacBook Pro",
                model: "MacBookPro18,4",
                osVersion: "macOS 14.1",
                appVersion: "1.0.0",
                lastSeen: Date(),
                capabilities: [.remoteDesktop, .fileTransfer],
                isOnline: true,
                networkType: .wifi,
                ipAddress: "192.168.1.5"
            ),
            iCloudDevice(
                id: "iphone",
                name: "Lza 的 iPhone",
                model: "iPhone16,2",
                osVersion: "iOS 18.0",
                appVersion: "1.0.0",
                lastSeen: Date().addingTimeInterval(-600),
                capabilities: [.clipboard, .calls],
                isOnline: false,
                networkType: .cellular,
                ipAddress: nil
            )
        ]
    }

    public func refreshHeartbeat() async throws {
 // Preview 模式下不做任何操作
    }
    
    public var currentDeviceId: String? {
        "local-mac"
    }
}
