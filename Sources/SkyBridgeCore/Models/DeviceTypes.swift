import Foundation
import SwiftUI
import OSLog

// MARK: - 设备管理相关类型
// ⚡ 重构：移除占位符实现，连接到真实服务或标记为已弃用

/// 增强设备发现服务
///
/// 注意：此类是 `DeviceDiscoveryService` 的轻量级包装，用于简化 UI 绑定。
/// 完整的设备发现功能请使用 `DeviceDiscoveryService.shared`。
///
/// **Requirements**: 10.1, 10.2
@available(*, deprecated, message: "请使用 DeviceDiscoveryService.shared 替代")
@MainActor
public class EnhancedDeviceDiscovery: ObservableObject {
    @Published public var discoveredDevices: [UUID] = []
    @Published public var isScanning = false
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "EnhancedDeviceDiscovery")
    
    public init() {
        logger.warning("⚠️ EnhancedDeviceDiscovery 已弃用，请使用 DeviceDiscoveryService.shared")
 // Track deprecation usage (Requirements 10.2, 12.1)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "EnhancedDeviceDiscovery.init()",
                replacement: "DeviceDiscoveryService.shared"
            )
        }
    }
    
    public func startScanning() {
        isScanning = true
        logger.info("🔍 开始设备扫描（委托给 DeviceDiscoveryService）")
 // Track deprecation usage (Requirements 10.2, 12.1)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "EnhancedDeviceDiscovery.startScanning()",
                replacement: "DeviceDiscoveryService.shared.startDiscovery()"
            )
        }
 // 委托给真实的设备发现服务 (Requirement 10.1)
#if os(macOS)
        // `DeviceDiscoveryService` 目前仍是 macOS 侧实现（iOS 有自己的一份，属于去重目标）。
        if #available(macOS 14.0, *) {
            Task {
                await DeviceDiscoveryService.shared.startDiscovery()
            }
        }
#endif
    }
    
    public func stopScanning() {
        isScanning = false
        logger.info("⏹️ 停止设备扫描")
 // Track deprecation usage (Requirements 10.2, 12.1)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "EnhancedDeviceDiscovery.stopScanning()",
                replacement: "DeviceDiscoveryService.shared.stopDiscovery()"
            )
        }
 // 委托给真实的设备发现服务 (Requirement 10.1)
#if os(macOS)
        if #available(macOS 14.0, *) {
            DeviceDiscoveryService.shared.stopDiscovery()
        }
#endif
    }
}

/// 硬件远程控制器（兼容层）
///
/// 注意：此类是 `HardwareRemoteController` 的兼容包装。
/// 完整功能请使用 `HardwareRemoteController`。
///
/// **Requirements**: 10.1
@available(*, deprecated, message: "请使用 HardwareRemoteController 替代")
@MainActor
public class DeviceTypesHardwareRemoteController: ObservableObject {
    @Published public var isConnected = false
    @Published public var connectionStatus = "未连接"
    @Published public var lastError: String?
    
    private let realController = HardwareRemoteController()
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeviceTypesHardwareRemoteController")
    
    public init() {
        logger.warning("⚠️ DeviceTypesHardwareRemoteController 已弃用，请使用 HardwareRemoteController")
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesHardwareRemoteController.init()",
                replacement: "HardwareRemoteController()"
            )
        }
    }
    
    public func connect(to device: DiscoveredDevice) async throws {
        connectionStatus = "连接中..."
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesHardwareRemoteController.connect(to:)",
                replacement: "HardwareRemoteController.connect(to:)"
            )
        }
 // 委托给真实的控制器 (Requirement 10.1)
        do {
            try await realController.connect(to: device)
            isConnected = realController.isConnected
            connectionStatus = realController.connectionStatus
            logger.info("✅ 连接成功: \(device.name)")
        } catch {
            lastError = error.localizedDescription
            connectionStatus = "连接失败"
            logger.error("❌ 连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    public func disconnect() {
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesHardwareRemoteController.disconnect()",
                replacement: "HardwareRemoteController.disconnect()"
            )
        }
 // 委托给真实的控制器 (Requirement 10.1)
        realController.disconnect()
        isConnected = false
        connectionStatus = "未连接"
        logger.info("🔌 已断开连接")
    }
}

/// 设备安全管理器（兼容层）
///
/// 注意：此类是 `DeviceSecurityManager` 的兼容包装。
/// 完整功能请使用 `DeviceSecurityManager`。
///
/// **Requirements**: 10.1
@available(*, deprecated, message: "请使用 DeviceSecurityManager 替代")
@MainActor
public class DeviceTypesSecurityManager: ObservableObject, @unchecked Sendable {
    
 // MARK: - 生命周期管理
    
 /// 管理器是否已启动
    @Published public private(set) var isStarted: Bool = false
    
    @Published public var securityLevel: DeviceSecurityLevel = .medium
    @Published public var trustedDevices: [TrustedDevice] = []
    
    private var realManager: DeviceSecurityManager { DeviceSecurityManager.shared }
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeviceTypesSecurityManager")
    
    public init() {
        logger.warning("⚠️ DeviceTypesSecurityManager 已弃用，请使用 DeviceSecurityManager")
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.init()",
                replacement: "DeviceSecurityManager.shared"
            )
        }
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动设备类型安全管理器
    public func start() async throws {
        guard !isStarted else { return }
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.start()",
                replacement: "DeviceSecurityManager.shared (auto-initializes)"
            )
        }
 // 委托给真实的管理器 (Requirement 10.1)
 // DeviceSecurityManager 继承自 BaseManager，会自动在 init 时调用 performInitialization
 // 等待初始化完成
        while !realManager.isInitialized {
            try await Task.sleep(nanoseconds: 10_000_000) // 0.01秒
        }
        isStarted = true
        logger.info("✅ 安全管理器已启动")
    }
    
 /// 停止设备类型安全管理器
    public func stop() async {
        guard isStarted else { return }
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.stop()",
                replacement: "DeviceSecurityManager.shared (managed lifecycle)"
            )
        }
        isStarted = false
        logger.info("⏹️ 安全管理器已停止")
    }
    
 /// 清理资源
    public func cleanup() async {
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.cleanup()",
                replacement: "DeviceSecurityManager.shared (managed lifecycle)"
            )
        }
        trustedDevices.removeAll()
        securityLevel = .medium
        isStarted = false
        logger.info("🧹 资源已清理")
    }
    
    public func addTrustedDevice(_ device: DiscoveredDevice) {
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.addTrustedDevice(_:)",
                replacement: "DeviceSecurityManager.shared.addTrustedDevice(_:)"
            )
        }
 // 委托给真实的管理器 (Requirement 10.1)
        realManager.addTrustedDevice(device)
        let trustedDevice = TrustedDevice(
            id: device.id,
            name: device.name,
            addedAt: Date()
        )
        trustedDevices.append(trustedDevice)
        logger.info("✅ 添加受信任设备: \(device.name)")
    }
    
    public func removeTrustedDevice(_ deviceId: UUID) {
 // Track deprecation usage (Requirements 10.1, 10.2)
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "DeviceTypesSecurityManager.removeTrustedDevice(_:)",
                replacement: "DeviceSecurityManager.shared.removeTrustedDevice(_:)"
            )
        }
 // 委托给真实的管理器 (Requirement 10.1)
        realManager.removeTrustedDevice(deviceId.uuidString)
        trustedDevices.removeAll { $0.id == deviceId }
        logger.info("🗑️ 移除受信任设备: \(deviceId)")
    }
}

// MARK: - 设备类型定义

/// 受信任的设备
public struct TrustedDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let addedAt: Date
    
    public init(id: UUID, name: String, addedAt: Date) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
    }
}

/// 远程设备
public struct RemoteDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let ipAddress: String
    public let deviceType: String
    public let isOnline: Bool
    
    public init(id: UUID, name: String, ipAddress: String, deviceType: String, isOnline: Bool) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.deviceType = deviceType
        self.isOnline = isOnline
    }
}

/// 设备安全级别（避免与QuantumSecureP2PNetwork中的SecurityLevel冲突）
public enum DeviceSecurityLevel: String, CaseIterable, Sendable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case critical = "严重"
    
    public var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
    
 /// 转换为 SecurityLevel（用于与 DeviceSecurityManager 交互）
    public var asSecurityLevel: SecurityLevel {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .critical: return .critical
        }
    }
}

// MARK: - 量子束（已弃用）

/// 量子束 - 用于量子通信可视化
///
/// 注意：此结构体仅用于 UI 可视化效果，不涉及实际的量子通信。
/// 实际的量子安全通信请使用 `QuantumSecureP2PNetwork`。
@available(*, deprecated, message: "此结构体仅用于 UI 可视化，实际量子通信请使用 QuantumSecureP2PNetwork")
public struct QuantumBeam: Sendable {
    public let intensity: Double
    public let frequency: Double
    
    public init(intensity: Double, frequency: Double) {
        self.intensity = intensity
        self.frequency = frequency
    }
    
 /// 用于 UI 可视化的颜色
    public var visualColor: Color {
 // 基于频率计算颜色（模拟量子态可视化）
        let hue = frequency.truncatingRemainder(dividingBy: 1.0)
        return Color(hue: hue, saturation: 0.8, brightness: intensity)
    }
}
