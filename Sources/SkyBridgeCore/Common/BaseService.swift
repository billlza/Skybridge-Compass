import Foundation
import OSLog
import Combine

/// 公共Service基类，提供统一的服务生命周期管理
/// 遵循Apple Silicon最佳实践和Swift 6.2特性
@MainActor
open class BaseService: ObservableObject, Sendable {
    
 // MARK: - 公共属性
    
 /// 统一的日志记录器
    public let logger: Logger
    
 /// 服务状态
    @Published public private(set) var serviceStatus: ServiceStatus = .inactive
    
 /// 错误状态
    @Published public private(set) var lastError: ServiceError?
    
 /// 服务配置
    public let configuration: BaseServiceConfiguration
    
 /// 取消订阅集合
    public var cancellables = Set<AnyCancellable>()
    
 // MARK: - 私有属性
    
    private let serviceName: String
    private let serviceQueue: DispatchQueue
    private var healthCheckTimer: Timer?
    
 // MARK: - 初始化
    
 /// 基础初始化方法
 /// - Parameters:
 /// - serviceName: 服务名称
 /// - configuration: 服务配置
    public init(serviceName: String, configuration: BaseServiceConfiguration = .default) {
        self.serviceName = serviceName
        self.configuration = configuration
        self.logger = Logger(subsystem: "com.skybridge.compass", category: serviceName)
        self.serviceQueue = DispatchQueue(
            label: "com.skybridge.service.\(serviceName.lowercased())",
            qos: DispatchQoS(qosClass: configuration.qosClass, relativePriority: 0)
        )
        
        logger.info("🔧 \(serviceName) 服务初始化")
        
 // 设置健康检查
        if configuration.enableHealthCheck {
            setupHealthCheck()
        }
    }
    
    deinit {
        logger.info("🗑️ \(self.serviceName) 服务已销毁")
 // 移除Timer操作，避免non-Sendable类型访问错误
 // Timer会在对象销毁时自动清理
    }
    
 // MARK: - 公共方法
    
 /// 启动服务
    public func startService() async throws {
        guard serviceStatus == .inactive else {
            logger.debug("⚠️ \(self.serviceName) 服务已在运行或正在启动")
            return
        }
        
        do {
            await updateServiceStatus(.initializing)
            logger.info("🚀 启动 \(self.serviceName) 服务")
            
            try await performServiceStart()
            
            await updateServiceStatus(.active)
            logger.info("✅ \(self.serviceName) 服务启动成功")
            
 // 启动健康检查
            if configuration.enableHealthCheck {
                startHealthCheck()
            }
            
        } catch {
            let serviceError = ServiceError.startupFailed(error)
            await updateServiceStatus(.error(serviceError.localizedDescription))
            logger.error("❌ \(self.serviceName) 服务启动失败: \(error.localizedDescription)")
            throw serviceError
        }
    }
    
 /// 停止服务
    public func stopService() async {
        guard serviceStatus.isActive else {
            logger.debug("⚠️ \(self.serviceName) 服务未在运行")
            return
        }
        
        await updateServiceStatus(.inactive)
        logger.info("🛑 停止 \(self.serviceName) 服务")
        
 // 停止健康检查
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        
        await performServiceStop()
        logger.info("✅ \(self.serviceName) 服务已停止")
    }
    
 /// 重启服务
    public func restartService() async throws {
        logger.info("🔄 重启 \(self.serviceName) 服务")
        await stopService()
        try await startService()
    }
    
 /// 暂停服务
    public func pauseService() async {
        guard serviceStatus.isActive else { return }
        
        await performServicePause()
        logger.info("⏸️ \(self.serviceName) 服务已暂停")
    }
    
 /// 恢复服务
    public func resumeService() async throws {
        try await performServiceResume()
        logger.info("▶️ \(self.serviceName) 服务已恢复")
    }
    
 // MARK: - 兼容性方法别名
    
 /// 启动服务（别名方法）
    public func start() async throws {
        try await startService()
    }
    
 /// 停止服务（别名方法）
    public func stop() async {
        await stopService()
    }
    
 /// 获取服务状态（别名方法）
    public var status: ServiceStatus {
        return serviceStatus
    }
    
 /// 暂停服务（别名方法）
    public func pause() async {
        await pauseService()
    }
    
 /// 恢复服务（别名方法）
    public func resume() async throws {
        try await resumeService()
    }
    
 // MARK: - 子类重写方法
    
 /// 子类实现具体的启动逻辑
    open func performServiceStart() async throws {
 // 子类重写此方法
    }
    
 /// 子类实现具体的停止逻辑
    open func performServiceStop() async {
 // 子类重写此方法
    }
    
 /// 子类实现具体的暂停逻辑
    open func performServicePause() async {
 // 子类重写此方法
    }
    
 /// 子类实现具体的恢复逻辑
    open func performServiceResume() async throws {
 // 子类重写此方法
    }
    
 /// 子类实现健康检查逻辑
    open func performHealthCheck() async -> Bool {
 // 默认实现：检查服务状态
        return serviceStatus == .active
    }
    
 /// 子类实现清理逻辑
    open func cleanup() {
        cancellables.removeAll()
    }
    
 // MARK: - 错误处理
    
 /// 统一的错误处理方法
    public func handleServiceError(_ error: ServiceError) async {
        await MainActor.run {
            self.lastError = error
            self.serviceStatus = .error(error.localizedDescription)
        }
        
        logger.error("❌ \(self.serviceName) 服务错误: \(error.localizedDescription)")
        
 // 根据配置决定是否自动恢复
        if configuration.autoRecovery && error.isRecoverable {
            await attemptRecovery(from: error)
        }
    }
    
 /// 尝试从错误中恢复
    private func attemptRecovery(from error: ServiceError) async {
        logger.info("🔄 尝试从错误中恢复 \(self.serviceName) 服务")
        
        do {
 // 等待一段时间后重试
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            try await startService()
            logger.info("✅ \(self.serviceName) 服务恢复成功")
        } catch {
            logger.error("❌ \(self.serviceName) 服务恢复失败: \(error.localizedDescription)")
        }
    }
    
 // MARK: - 健康检查
    
 /// 设置健康检查
    private func setupHealthCheck() {
 // 健康检查将在服务启动后开始
    }
    
 /// 启动健康检查
    private func startHealthCheck() {
        guard configuration.enableHealthCheck else { return }
        
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: configuration.healthCheckInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.performHealthCheck()
            }
        }
        
        logger.debug("🏥 \(self.serviceName) 健康检查已启动")
    }
    
 /// 执行健康检查
    private func runHealthCheck() async {
        let isHealthy = await performHealthCheck()
        
        if !isHealthy {
            logger.warning("⚠️ \(self.serviceName) 服务健康检查失败")
            
 // 如果启用了自动恢复，尝试恢复
            if configuration.autoRecovery {
                let error = ServiceError.healthCheckFailed
                await attemptRecovery(from: error)
            }
        }
    }
    
 // MARK: - 私有方法
    
 /// 更新服务状态
    private func updateServiceStatus(_ newStatus: ServiceStatus) async {
        await MainActor.run {
            self.serviceStatus = newStatus
        }
    }
}

// MARK: - 服务状态枚举

/// 服务状态定义
public enum ServiceStatus: Sendable, Equatable {
    case inactive       // 未激活
    case initializing   // 初始化中
    case active         // 活跃状态
    case error(String)  // 错误状态
    
 /// 状态描述
    public var description: String {
        switch self {
        case .inactive:
            return "未激活"
        case .initializing:
            return "初始化中..."
        case .active:
            return "运行中"
        case .error(let message):
            return "错误: \(message)"
        }
    }
    
 /// 是否为活跃状态
    public var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }
}

// MARK: - 服务错误枚举

/// 统一的服务错误类型
public enum ServiceError: LocalizedError, Sendable {
    case startupFailed(Error)
    case configurationInvalid(String)
    case dependencyUnavailable(String)
    case resourceExhausted
    case networkUnavailable
    case permissionDenied
    case healthCheckFailed
    case operationTimeout
    
 /// 错误描述
    public var errorDescription: String? {
        switch self {
        case .startupFailed(let error):
            return "服务启动失败: \(error.localizedDescription)"
        case .configurationInvalid(let message):
            return "配置无效: \(message)"
        case .dependencyUnavailable(let dependency):
            return "依赖不可用: \(dependency)"
        case .resourceExhausted:
            return "资源耗尽"
        case .networkUnavailable:
            return "网络不可用"
        case .permissionDenied:
            return "权限被拒绝"
        case .healthCheckFailed:
            return "健康检查失败"
        case .operationTimeout:
            return "操作超时"
        }
    }
    
 /// 是否可恢复
    public var isRecoverable: Bool {
        switch self {
        case .networkUnavailable, .resourceExhausted, .healthCheckFailed, .operationTimeout:
            return true
        case .startupFailed, .configurationInvalid, .dependencyUnavailable, .permissionDenied:
            return false
        }
    }
}

// MARK: - 服务配置

/// 服务配置结构
public struct BaseServiceConfiguration: Sendable {
 /// QoS类别
    public let qosClass: DispatchQoS.QoSClass
    
 /// 是否启用健康检查
    public let enableHealthCheck: Bool
    
 /// 健康检查间隔（秒）
    public let healthCheckInterval: TimeInterval
    
 /// 是否自动恢复
    public let autoRecovery: Bool
    
 /// 恢复延迟（秒）
    public let recoveryDelay: TimeInterval
    
 /// 默认配置
    public static let `default` = BaseServiceConfiguration(
        qosClass: .userInitiated,
        enableHealthCheck: true,
        healthCheckInterval: 30.0,
        autoRecovery: true,
        recoveryDelay: 2.0
    )
    
 /// 高性能配置
    public static let highPerformance = BaseServiceConfiguration(
        qosClass: .userInteractive,
        enableHealthCheck: true,
        healthCheckInterval: 10.0,
        autoRecovery: true,
        recoveryDelay: 1.0
    )
    
 /// 后台服务配置
    public static let background = BaseServiceConfiguration(
        qosClass: .background,
        enableHealthCheck: true,
        healthCheckInterval: 60.0,
        autoRecovery: true,
        recoveryDelay: 5.0
    )
    
    public init(
        qosClass: DispatchQoS.QoSClass = .userInitiated,
        enableHealthCheck: Bool = true,
        healthCheckInterval: TimeInterval = 30.0,
        autoRecovery: Bool = true,
        recoveryDelay: TimeInterval = 2.0
    ) {
        self.qosClass = qosClass
        self.enableHealthCheck = enableHealthCheck
        self.healthCheckInterval = healthCheckInterval
        self.autoRecovery = autoRecovery
        self.recoveryDelay = recoveryDelay
    }
}