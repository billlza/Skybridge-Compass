import Foundation
import OSLog
@preconcurrency import Combine

/// 公共Manager基类，提供统一的初始化、日志记录和错误处理模式
/// 遵循Apple Silicon最佳实践和Swift 6.2特性
@MainActor
open class BaseManager: ObservableObject, Sendable {

 // MARK: - 公共属性

 /// 统一的日志记录器
    public let logger: Logger

 /// 管理器状态
    @Published public private(set) var status: ManagerStatus = .inactive

 /// 错误状态
    @Published public private(set) var lastError: ManagerError?

 /// 初始化状态
    @Published public private(set) var isInitialized: Bool = false

 /// 取消订阅集合
    public var cancellables = Set<AnyCancellable>()

 // MARK: - 私有属性

    private let subsystem: String
    private let category: String
    private let initializationQueue: DispatchQueue

 // MARK: - 初始化

 /// 基础初始化方法
 /// - Parameters:
 /// - subsystem: 日志子系统标识
 /// - category: 日志分类
    public init(subsystem: String = "com.skybridge.compass", category: String) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
        self.initializationQueue = DispatchQueue(
            label: "com.skybridge.\(category.lowercased()).init",
            qos: .userInitiated
        )

        logger.info("📱 \(category) 管理器开始初始化")

 // 异步执行初始化
        Task {
            await performInitialization()
        }
    }

    public func waitUntilInitialized(timeout: TimeInterval = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isInitialized, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return isInitialized
    }

    deinit {
        logger.info("🗑️ \(self.category) 管理器已销毁")
 // 移除cancellables清理，避免non-Sendable类型访问错误
 // Combine的AnyCancellable会在对象销毁时自动清理
    }

 // MARK: - 公共方法

 /// 启动管理器
    public func start() async throws {
        guard isInitialized else {
            throw ManagerError.notInitialized
        }

        guard status != .active else {
            logger.debug("⚠️ \(self.category) 管理器已在运行中")
            return
        }

        do {
            await updateStatus(.starting)
            try await performStart()
            await updateStatus(.active)
            logger.info("✅ \(self.category) 管理器启动成功")
        } catch {
            let managerError = ManagerError.startupFailed(error)
            await handleError(managerError)
            throw managerError
        }
    }

 /// 停止管理器
    public func stop() async {
        guard status == .active else {
            logger.debug("⚠️ \(self.category) 管理器未在运行中")
            return
        }

        await updateStatus(.stopping)
        await performStop()
        await updateStatus(.inactive)
        logger.info("🛑 \(self.category) 管理器已停止")
    }

 /// 重启管理器
    public func restart() async throws {
        logger.info("🔄 \(self.category) 管理器重启中...")
        await stop()
        try await start()
    }

 // MARK: - 子类重写方法

 /// 子类实现具体的初始化逻辑
    open func performInitialization() async {
 // 默认实现：标记为已初始化
        await MainActor.run {
            self.isInitialized = true
        }
    }

 /// 子类实现具体的启动逻辑
    open func performStart() async throws {
 // 子类重写此方法
    }

 /// 子类实现具体的停止逻辑
    open func performStop() async {
 // 子类重写此方法
    }

 /// 子类实现具体的清理逻辑
    open func cleanup() {
 // 子类重写此方法
        cancellables.removeAll()
    }

 // MARK: - 错误处理

 /// 统一的错误处理方法
    public func handleError(_ error: ManagerError) async {
        await MainActor.run {
            self.lastError = error
            self.status = .error(error.localizedDescription)
        }

        logger.error("❌ \(self.category) 管理器错误: \(error.localizedDescription)")

 // 根据错误类型决定是否尝试恢复
        if error.isRecoverable {
            logger.info("🔄 尝试从错误中恢复...")
            await attemptRecovery(from: error)
        }
    }

 /// 尝试从错误中恢复
    private func attemptRecovery(from error: ManagerError) async {
        guard error.isRecoverable else {
            logger.warning("⚠️ \(self.category) 管理器错误不可恢复")
            return
        }

        logger.info("🔧 \(self.category) 管理器尝试自动恢复...")

 // 等待一段时间后重试
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒

        do {
            try await start()
        } catch {
            logger.error("❌ \(self.category) 管理器恢复失败: \(error.localizedDescription)")
        }
    }

 // MARK: - 私有方法

 /// 更新管理器状态
    private func updateStatus(_ newStatus: ManagerStatus) async {
        await MainActor.run {
            self.status = newStatus
        }
    }
}

// MARK: - 管理器状态枚举

/// 管理器状态定义
public enum ManagerStatus: Sendable, Equatable {
    case inactive       // 未激活
    case initializing   // 初始化中
    case starting       // 启动中
    case active         // 活跃状态
    case stopping       // 停止中
    case error(String)  // 错误状态

 /// 状态描述
    public var description: String {
        switch self {
        case .inactive:
            return "未激活"
        case .initializing:
            return "初始化中..."
        case .starting:
            return "启动中..."
        case .active:
            return "运行中"
        case .stopping:
            return "停止中..."
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

// MARK: - 管理器错误枚举

/// 统一的管理器错误类型
public enum ManagerError: LocalizedError, Sendable {
    case notInitialized
    case startupFailed(Error)
    case configurationError(String)
    case networkError(String)
    case permissionDenied
    case resourceUnavailable(String)
    case operationTimeout
    case invalidState(String)

 /// 错误描述
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "管理器未初始化"
        case .startupFailed(let error):
            return "启动失败: \(error.localizedDescription)"
        case .configurationError(let message):
            return "配置错误: \(message)"
        case .networkError(let message):
            return "网络错误: \(message)"
        case .permissionDenied:
            return "权限被拒绝"
        case .resourceUnavailable(let resource):
            return "资源不可用: \(resource)"
        case .operationTimeout:
            return "操作超时"
        case .invalidState(let state):
            return "无效状态: \(state)"
        }
    }

 /// 是否可恢复
    public var isRecoverable: Bool {
        switch self {
        case .networkError, .resourceUnavailable, .operationTimeout:
            return true
        case .notInitialized, .startupFailed, .configurationError, .permissionDenied, .invalidState:
            return false
        }
    }
}

// MARK: - 服务状态协议

/// 服务状态协议，用于统一不同服务的状态管理
@MainActor
public protocol ServiceStatusProvider: Sendable {
    var status: ManagerStatus { get }
    var isActive: Bool { get }
}

@MainActor
extension BaseManager: ServiceStatusProvider {
    @objc public var isActive: Bool {
        status.isActive
    }
}
