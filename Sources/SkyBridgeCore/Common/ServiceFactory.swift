import Foundation
import OSLog
#if os(macOS)
import AppKit
#endif

/// Service工厂类 - 统一Service创建和依赖注入
/// 遵循Apple Silicon最佳实践和Swift 6.2特性
@MainActor
public final class ServiceFactory: Sendable {
    
 // MARK: - 单例
    
    public static let shared = ServiceFactory()
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ServiceFactory")
    private var serviceInstances: [String: BaseService] = [:]
    private let creationQueue = DispatchQueue(label: "com.skybridge.service.factory", qos: .userInitiated)
    
 // MARK: - 初始化
    
    private init() {
        logger.info("🏭 Service工厂初始化")
    }
    
 // MARK: - 公共方法
    
 /// 获取Service实例（单例模式）
 /// - Parameter serviceType: Service类型
 /// - Returns: Service实例
    @available(macOS 14.0, *)
    public func getService<T: BaseService>(_ serviceType: T.Type) async throws -> T {
        let key = String(describing: serviceType)
        
 // 检查是否已存在实例
        if let existingService = self.serviceInstances[key] as? T {
            logger.debug("📦 返回现有Service实例: \(key)")
            return existingService
        }
        
 // 创建新实例
        logger.info("🔨 创建新Service实例: \(key)")
        let service = try await createService(serviceType)
        self.serviceInstances[key] = service
        
        return service
    }
    
 /// 创建Service实例（不缓存）
 /// - Parameter serviceType: Service类型
 /// - Returns: 新的Service实例
 /// 创建Service实例
    @available(macOS 14.0, *)
    public func createService<T: BaseService>(_ serviceType: T.Type) async throws -> T {
        logger.debug("🆕 创建Service: \(String(describing: serviceType))")
        
        presentErrorAlert("未支持的Service类型", "当前没有继承BaseService的服务实现: \(serviceType)")
        throw ServiceFactoryError.serviceCreationFailed(String(describing: serviceType))
    }
    
 /// 启动所有Service
    public func startAllServices() async throws {
        logger.info("🚀 启动所有Service (\(self.serviceInstances.count)个)")
        
        var errors: [Error] = []
        
        for (key, service) in self.serviceInstances {
            do {
                try await service.startService()
                logger.debug("✅ Service启动成功: \(key)")
            } catch {
                logger.error("❌ Service启动失败: \(key) - \(error.localizedDescription)")
                errors.append(error)
            }
        }
        
        if !errors.isEmpty {
            throw ServiceFactoryError.multipleStartupFailures(errors)
        }
    }
    
 /// 停止所有Service
    public func stopAllServices() async {
        logger.info("🛑 停止所有Service (\(self.serviceInstances.count)个)")
        
        for (key, service) in self.serviceInstances {
            await service.stopService()
            logger.debug("🛑 Service已停止: \(key)")
        }
    }
    
 /// 重启所有Service
    public func restartAllServices() async throws {
        logger.info("🔄 重启所有Service")
        await stopAllServices()
        try await startAllServices()
    }
    
 /// 获取Service状态摘要
    public func getServiceStatusSummary() -> ServiceStatusSummary {
        let statuses = self.serviceInstances.mapValues { $0.serviceStatus }
        
        let activeCount = statuses.values.filter { $0.isActive }.count
        let errorCount = statuses.values.compactMap { status in
            if case .error = status { return 1 } else { return nil }
        }.count
        
        return ServiceStatusSummary(
            totalServices: self.serviceInstances.count,
            activeServices: activeCount,
            errorServices: errorCount,
            serviceStatuses: statuses
        )
    }
    
 /// 清理所有Service实例
    public func cleanup() {
        logger.info("🧹 清理所有Service实例")
        
        for (key, service) in self.serviceInstances {
            service.cleanup()
            logger.debug("🧹 Service已清理: \(key)")
        }
        
        self.serviceInstances.removeAll()
    }
    
 /// 移除特定Service实例
    public func removeService<T: BaseService>(_ serviceType: T.Type) async {
        let key = String(describing: serviceType)
        
        if let service = self.serviceInstances[key] {
            await service.stopService()
            service.cleanup()
            self.serviceInstances.removeValue(forKey: key)
            logger.info("🗑️ 移除Service实例: \(key)")
        }
    }
    
 /// 检查Service是否存在
    public func hasService<T: BaseService>(_ serviceType: T.Type) -> Bool {
        let key = String(describing: serviceType)
        return self.serviceInstances[key] != nil
    }
    
 /// 获取所有Service类型
    public func getAllServiceTypes() -> [String] {
        return Array(self.serviceInstances.keys)
    }
    
 /// 暂停所有Service
    public func pauseAllServices() async {
        logger.info("⏸️ 暂停所有Service")
        
        for (key, service) in self.serviceInstances {
            await service.pauseService()
            logger.debug("⏸️ Service已暂停: \(key)")
        }
    }
    
 /// 恢复所有Service
    public func resumeAllServices() async throws {
        logger.info("▶️ 恢复所有Service (\(self.serviceInstances.count)个)")
        
        var errors: [Error] = []
        
        for (key, service) in self.serviceInstances {
            do {
                try await service.resumeService()
                logger.debug("▶️ Service已恢复: \(key)")
            } catch {
                logger.error("❌ Service恢复失败: \(key) - \(error.localizedDescription)")
                errors.append(error)
            }
        }
        
        if !errors.isEmpty {
            throw ServiceFactoryError.multipleResumeFailures(errors)
        }
    }
    
 /// 执行所有Service健康检查
    public func performHealthCheck() async -> ServiceHealthReport {
        logger.info("🏥 执行Service健康检查")
        
        var healthyServices: [String] = []
        var unhealthyServices: [String: String] = [:]
        
        for (key, service) in self.serviceInstances {
            let isHealthy = await service.performHealthCheck()
            if isHealthy {
                healthyServices.append(key)
            } else {
                let errorMessage = service.lastError?.localizedDescription ?? "未知错误"
                unhealthyServices[key] = errorMessage
            }
        }
        
        return ServiceHealthReport(
            totalServices: self.serviceInstances.count,
            healthyServices: healthyServices,
            unhealthyServices: unhealthyServices
        )
    }
}

// MARK: - 错误提示
extension ServiceFactory {
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

// MARK: - Service状态摘要

/// Service状态摘要
public struct ServiceStatusSummary: Sendable {
 /// 总Service数量
    public let totalServices: Int
    
 /// 活跃Service数量
    public let activeServices: Int
    
 /// 错误Service数量
    public let errorServices: Int
    
 /// 各Service状态
    public let serviceStatuses: [String: ServiceStatus]
    
 /// 整体健康状态
    public var overallHealth: HealthStatus {
        if errorServices > 0 {
            return .unhealthy
        } else if activeServices == totalServices {
            return .healthy
        } else {
            return .degraded
        }
    }
    
 /// 健康状态描述
    public var healthDescription: String {
        switch overallHealth {
        case .healthy:
            return "所有Service运行正常"
        case .degraded:
            return "部分Service未激活"
        case .unhealthy:
            return "存在错误的Service"
        }
    }
}

// MARK: - Service健康报告

/// Service健康报告
public struct ServiceHealthReport: Sendable {
 /// 总Service数量
    public let totalServices: Int
    
 /// 健康的Service列表
    public let healthyServices: [String]
    
 /// 不健康的Service及其错误信息
    public let unhealthyServices: [String: String]
    
 /// 健康率
    public var healthRate: Double {
        guard totalServices > 0 else { return 1.0 }
        return Double(healthyServices.count) / Double(totalServices)
    }
    
 /// 是否整体健康
    public var isOverallHealthy: Bool {
        return unhealthyServices.isEmpty
    }
}

// MARK: - 工厂错误枚举

/// Service工厂错误
public enum ServiceFactoryError: LocalizedError, Sendable {
    case serviceCreationFailed(String)
    case multipleStartupFailures([Error])
    case multipleResumeFailures([Error])
    case serviceNotFound(String)
    case dependencyNotMet(String, [String])
    
    public var errorDescription: String? {
        switch self {
        case .serviceCreationFailed(let serviceType):
            return "Service创建失败: \(serviceType)"
        case .multipleStartupFailures(let errors):
            return "多个Service启动失败: \(errors.count)个错误"
        case .multipleResumeFailures(let errors):
            return "多个Service恢复失败: \(errors.count)个错误"
        case .serviceNotFound(let serviceType):
            return "Service未找到: \(serviceType)"
        case .dependencyNotMet(let serviceType, let dependencies):
            return "Service依赖未满足: \(serviceType) 需要 \(dependencies.joined(separator: ", "))"
        }
    }
}

// MARK: - Service配置协议

/// Service配置协议
public protocol ServiceConfiguration: Sendable {
 /// Service优先级
    var priority: Int { get }
    
 /// 是否自动启动
    var autoStart: Bool { get }
    
 /// 依赖的Service类型
    var dependencies: [String] { get }
    
 /// 健康检查间隔
    var healthCheckInterval: TimeInterval { get }
    
 /// 是否支持暂停/恢复
    var supportsPauseResume: Bool { get }
}

// MARK: - 默认Service配置

/// 默认Service配置
public struct DefaultServiceConfiguration: ServiceConfiguration {
    public let priority: Int
    public let autoStart: Bool
    public let dependencies: [String]
    public let healthCheckInterval: TimeInterval
    public let supportsPauseResume: Bool
    
    public init(
        priority: Int = 0,
        autoStart: Bool = true,
        dependencies: [String] = [],
        healthCheckInterval: TimeInterval = 60.0,
        supportsPauseResume: Bool = true
    ) {
        self.priority = priority
        self.autoStart = autoStart
        self.dependencies = dependencies
        self.healthCheckInterval = healthCheckInterval
        self.supportsPauseResume = supportsPauseResume
    }
    
 /// 高优先级配置
    public static let highPriority = DefaultServiceConfiguration(
        priority: 10,
        autoStart: true,
        healthCheckInterval: 30.0
    )
    
 /// 低优先级配置
    public static let lowPriority = DefaultServiceConfiguration(
        priority: -10,
        autoStart: false,
        healthCheckInterval: 120.0
    )
    
 /// 默认配置
    public static let `default` = DefaultServiceConfiguration()
}
