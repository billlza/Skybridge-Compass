import Foundation
import OSLog
#if os(macOS)
import AppKit
#endif

/// 管理器工厂类 - 统一管理器创建和依赖注入
/// 遵循Apple Silicon最佳实践和Swift 6.2特性
@MainActor
public final class ManagerFactory: Sendable {
    
 // MARK: - 单例
    
    public static let shared = ManagerFactory()
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ManagerFactory")
    private var managerInstances: [String: BaseManager] = [:]
    private var registry: [ObjectIdentifier: () -> Any] = [:]
    private let creationQueue = DispatchQueue(label: "com.skybridge.manager.factory", qos: .userInitiated)
    
 // MARK: - 初始化
    
    private init() {
        logger.info("🏭 管理器工厂初始化")
 // 注册已知管理器构造器（避免恒为 false 的类型强转告警）
        registry[ObjectIdentifier(ConnectionManager.self)] = { ConnectionManager() }
        registry[ObjectIdentifier(DeviceDiscoveryManager.self)] = { DeviceDiscoveryManager() }
        registry[ObjectIdentifier(AccessibilityManager.self)] = { AccessibilityManager() }
        registry[ObjectIdentifier(KeyboardNavigationManager.self)] = { KeyboardNavigationManager() }
        registry[ObjectIdentifier(ThermalManager.self)] = { ThermalManager() }
        registry[ObjectIdentifier(WiFiManager.self)] = { WiFiManager() }
        registry[ObjectIdentifier(AirPlayManager.self)] = { AirPlayManager() }
        registry[ObjectIdentifier(FileTransferManager.self)] = { FileTransferManager() }
        registry[ObjectIdentifier(LocationManager.self)] = { LocationManager() }
        registry[ObjectIdentifier(USBDeviceDiscoveryManager.self)] = { USBDeviceDiscoveryManager() }
        registry[ObjectIdentifier(P2PSecurityManager.self)] = { P2PSecurityManager() }
 // DeviceTypesSecurityManager 已弃用，使用 DeviceSecurityManager 替代（见下方注册）
        registry[ObjectIdentifier(InteractiveClearManager.self)] = { InteractiveClearManager() }
        registry[ObjectIdentifier(TLSSecurityManager.self)] = { TLSSecurityManager() }
        registry[ObjectIdentifier(DeviceSecurityManager.self)] = { DeviceSecurityManager.shared }
        registry[ObjectIdentifier(P2PPermissionManager.self)] = { P2PPermissionManager() }
        registry[ObjectIdentifier(RemoteControlManager.self)] = { RemoteControlManager() }
        registry[ObjectIdentifier(UnifiedMemoryManager.self)] = { UnifiedMemoryManager() }
        registry[ObjectIdentifier(DeviceFilterManager.self)] = { DeviceFilterManager() }
 // 特殊：需要配置的管理器
        registry[ObjectIdentifier(NATTraversalManager.self)] = { NATTraversalManager(configuration: P2PNetworkConfiguration()) }
        registry[ObjectIdentifier(HolographicManager.self)] = { HolographicManager() }
    }
    
 // MARK: - 公共方法
    
 /// 创建或获取管理器实例
 /// - Parameter managerType: 管理器类型
 /// - Returns: 管理器实例
    public func getManager<T: BaseManager>(_ managerType: T.Type) async throws -> T {
        let key = String(describing: managerType)
        
 // 检查是否已存在实例
        if let existingManager = self.managerInstances[key] as? T {
            logger.debug("📦 返回现有管理器实例: \(key)")
            return existingManager
        }
        
 // 创建新实例
        logger.info("🔨 创建新管理器实例: \(key)")
        let manager = try await createManager(managerType)
        self.managerInstances[key] = manager
        
        return manager
    }
    
 /// 创建管理器实例（不缓存）
 /// - Parameter managerType: 管理器类型
 /// - Returns: 新的管理器实例
    public func createManager<T: BaseManager>(_ managerType: T.Type) async throws -> T {
        logger.debug("🆕 创建管理器: \(String(describing: managerType))")
        let key = ObjectIdentifier(managerType)
        if let factory = registry[key] {
            let instance = factory()
            guard let typed = instance as? T else {
                presentErrorAlert("管理器创建失败", "类型不匹配: \(managerType)")
                throw ManagerFactoryError.managerCreationFailed(String(describing: managerType))
            }
            return typed
        }
        presentErrorAlert("管理器未注册", "类型: \(managerType)")
        throw ManagerFactoryError.managerNotFound(String(describing: managerType))
    }
    
 /// 启动所有管理器
    public func startAllManagers() async throws {
        logger.info("🚀 启动所有管理器 (\(self.managerInstances.count)个)")
        
        var errors: [Error] = []
        
        for (key, manager) in self.managerInstances {
            do {
                try await manager.start()
                logger.debug("✅ 管理器启动成功: \(key)")
            } catch {
                logger.error("❌ 管理器启动失败: \(key) - \(error.localizedDescription)")
                errors.append(error)
            }
        }
        
        if !errors.isEmpty {
            throw ManagerFactoryError.multipleStartupFailures(errors)
        }
    }
    
 /// 停止所有管理器
    public func stopAllManagers() async {
        logger.info("🛑 停止所有管理器 (\(self.managerInstances.count)个)")
        
        for (key, manager) in self.managerInstances {
            await manager.stop()
            logger.debug("🛑 管理器已停止: \(key)")
        }
    }
    
 /// 重启所有管理器
    public func restartAllManagers() async throws {
        logger.info("🔄 重启所有管理器")
        await stopAllManagers()
        try await startAllManagers()
    }
    
 /// 获取管理器状态摘要
    public func getManagerStatusSummary() -> ManagerStatusSummary {
        let statuses = self.managerInstances.mapValues { $0.status }
        
        let activeCount = statuses.values.filter { $0.isActive }.count
        let errorCount = statuses.values.compactMap { status in
            if case .error = status { return 1 } else { return nil }
        }.count
        
        return ManagerStatusSummary(
            totalManagers: self.managerInstances.count,
            activeManagers: activeCount,
            errorManagers: errorCount,
            managerStatuses: statuses
        )
    }
    
 /// 清理所有管理器实例
    public func cleanup() {
        logger.info("🧹 清理所有管理器实例")
        
        for (key, manager) in self.managerInstances {
            manager.cleanup()
            logger.debug("🧹 管理器已清理: \(key)")
        }
        
        self.managerInstances.removeAll()
    }
    
 /// 移除特定管理器实例
    public func removeManager<T: BaseManager>(_ managerType: T.Type) async {
        let key = String(describing: managerType)
        
        if let manager = self.managerInstances[key] {
            await manager.stop()
            manager.cleanup()
            self.managerInstances.removeValue(forKey: key)
            logger.info("🗑️ 移除管理器实例: \(key)")
        }
    }
    
 /// 检查管理器是否存在
    public func hasManager<T: BaseManager>(_ managerType: T.Type) -> Bool {
        let key = String(describing: managerType)
        return self.managerInstances[key] != nil
    }
    
 /// 获取所有管理器类型
    public func getAllManagerTypes() -> [String] {
        return Array(self.managerInstances.keys)
    }
}

// MARK: - 错误提示
extension ManagerFactory {
    private func presentErrorAlert(_ title: String, _ message: String) {
        #if os(macOS)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
        #endif
        logger.error("\(title): \(message)")
    }
}

// MARK: - 管理器状态摘要

/// 管理器状态摘要
public struct ManagerStatusSummary: Sendable {
 /// 总管理器数量
    public let totalManagers: Int
    
 /// 活跃管理器数量
    public let activeManagers: Int
    
 /// 错误管理器数量
    public let errorManagers: Int
    
 /// 各管理器状态
    public let managerStatuses: [String: ManagerStatus]
    
 /// 整体健康状态
    public var overallHealth: HealthStatus {
        if errorManagers > 0 {
            return .unhealthy
        } else if activeManagers == totalManagers {
            return .healthy
        } else {
            return .degraded
        }
    }
    
 /// 健康状态描述
    public var healthDescription: String {
        switch overallHealth {
        case .healthy:
            return "所有管理器运行正常"
        case .degraded:
            return "部分管理器未激活"
        case .unhealthy:
            return "存在错误的管理器"
        }
    }
}

// MARK: - 健康状态枚举

/// 健康状态
public enum HealthStatus: Sendable {
    case healthy    // 健康
    case degraded   // 降级
    case unhealthy  // 不健康
}

// MARK: - 工厂错误枚举

/// 管理器工厂错误
public enum ManagerFactoryError: LocalizedError, Sendable {
    case managerCreationFailed(String)
    case multipleStartupFailures([Error])
    case managerNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .managerCreationFailed(let managerType):
            return "管理器创建失败: \(managerType)"
        case .multipleStartupFailures(let errors):
            return "多个管理器启动失败: \(errors.count)个错误"
        case .managerNotFound(let managerType):
            return "管理器未找到: \(managerType)"
        }
    }
}

// MARK: - 管理器配置协议

/// 管理器配置协议
public protocol ManagerConfiguration: Sendable {
 /// 管理器优先级
    var priority: Int { get }
    
 /// 是否自动启动
    var autoStart: Bool { get }
    
 /// 依赖的管理器类型
    var dependencies: [String] { get }
}

// MARK: - 默认管理器配置

/// 默认管理器配置
public struct DefaultManagerConfiguration: ManagerConfiguration {
    public let priority: Int
    public let autoStart: Bool
    public let dependencies: [String]
    
    public init(priority: Int = 0, autoStart: Bool = true, dependencies: [String] = []) {
        self.priority = priority
        self.autoStart = autoStart
        self.dependencies = dependencies
    }
    
 /// 高优先级配置
    public static let highPriority = DefaultManagerConfiguration(priority: 10, autoStart: true)
    
 /// 低优先级配置
    public static let lowPriority = DefaultManagerConfiguration(priority: -10, autoStart: false)
    
 /// 默认配置
    public static let `default` = DefaultManagerConfiguration()
}
