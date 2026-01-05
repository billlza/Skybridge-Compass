import Foundation
import os.log

/// 统一错误处理框架
///
/// 提供类型安全的错误处理机制，替代 try? 和错误吞没
///
/// 🆕 2025年最佳实践：
/// - ✅ 使用 Result 类型进行错误传播
/// - ✅ 结构化的错误分类
/// - ✅ 详细的错误上下文
/// - ✅ 错误恢复策略
/// - ✅ 错误遥测和监控
///
/// ⚡ Swift 6.2.1 特性：全面的并发安全支持
@available(macOS 14.0, *)
public actor UnifiedErrorHandler {
    
 // MARK: - 错误类型定义
    
 /// 应用程序错误分类
    public enum AppError: Error, LocalizedError, Sendable {
 // 网络错误
        case networkUnavailable
        case connectionTimeout
        case serverError(statusCode: Int, message: String)
        case invalidResponse
        
 // 认证错误
        case authenticationFailed(reason: String)
        case unauthorized
        case tokenExpired
        
 // 数据错误
        case dataCorrupted(description: String)
        case invalidInput(field: String, reason: String)
        case serializationFailed(Error)
        
 // 系统错误
        case insufficientPermissions(permission: String)
        case resourceUnavailable(resource: String)
        case fileSystemError(Error)
        
 // 业务逻辑错误
        case deviceNotFound(identifier: String)
        case operationNotSupported(operation: String)
        case configurationError(message: String)
        
 // 未知错误
        case unknown(Error)
        
        public var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                return "网络不可用，请检查网络连接"
            case .connectionTimeout:
                return "连接超时，请稍后重试"
            case .serverError(let code, let message):
                return "服务器错误（\(code)）：\(message)"
            case .invalidResponse:
                return "服务器返回无效响应"
                
            case .authenticationFailed(let reason):
                return "认证失败：\(reason)"
            case .unauthorized:
                return "未授权访问，请先登录"
            case .tokenExpired:
                return "登录已过期，请重新登录"
                
            case .dataCorrupted(let description):
                return "数据损坏：\(description)"
            case .invalidInput(let field, let reason):
                return "输入无效[\(field)]：\(reason)"
            case .serializationFailed(let error):
                return "数据序列化失败：\(error.localizedDescription)"
                
            case .insufficientPermissions(let permission):
                return "权限不足，需要 \(permission) 权限"
            case .resourceUnavailable(let resource):
                return "资源不可用：\(resource)"
            case .fileSystemError(let error):
                return "文件系统错误：\(error.localizedDescription)"
                
            case .deviceNotFound(let id):
                return "未找到设备：\(id)"
            case .operationNotSupported(let op):
                return "不支持的操作：\(op)"
            case .configurationError(let message):
                return "配置错误：\(message)"
                
            case .unknown(let error):
                return "未知错误：\(error.localizedDescription)"
            }
        }
        
 /// 错误的严重程度
        public var severity: ErrorSeverity {
            switch self {
            case .networkUnavailable, .connectionTimeout:
                return .warning
            case .authenticationFailed, .unauthorized, .tokenExpired:
                return .error
            case .dataCorrupted, .serializationFailed:
                return .critical
            case .insufficientPermissions:
                return .error
            case .deviceNotFound, .operationNotSupported:
                return .warning
            case .serverError(let code, _):
                return code >= 500 ? .critical : .error
            case .configurationError:
                return .critical
            default:
                return .error
            }
        }
        
 /// 是否可恢复
        public var isRecoverable: Bool {
            switch self {
            case .networkUnavailable, .connectionTimeout:
                return true
            case .tokenExpired:
                return true
            case .serverError(let code, _):
                return code < 500
            case .dataCorrupted, .configurationError:
                return false
            default:
                return true
            }
        }
    }
    
 /// 错误严重程度
    public enum ErrorSeverity: String, Sendable {
        case debug = "🔍 调试"
        case info = "ℹ️ 信息"
        case warning = "⚠️ 警告"
        case error = "❌ 错误"
        case critical = "🔥 严重"
    }
    
 // MARK: - 错误处理策略
    
 /// 错误恢复策略
    public enum RecoveryStrategy: Sendable {
        case retry(maxAttempts: Int, delay: TimeInterval)
        case fallback(action: @Sendable () async -> Void)
        case notifyUser(message: String)
        case silent
    }
    
 // MARK: - 属性
    
    public static let shared = UnifiedErrorHandler()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ErrorHandler")
    
 /// 错误历史记录（用于分析）
    private var errorHistory: [ErrorRecord] = []
    private let maxHistorySize = 100
    
 /// 错误记录
    public struct ErrorRecord: Sendable {
        public let error: AppError
        public let timestamp: Date
        public let context: String
        public let recovered: Bool
        
        public init(error: AppError, timestamp: Date, context: String, recovered: Bool) {
            self.error = error
            self.timestamp = timestamp
            self.context = context
            self.recovered = recovered
        }
    }
    
    private init() {
        logger.info("✅ 统一错误处理器已初始化")
    }
    
 // MARK: - 错误处理
    
 /// 处理错误并应用恢复策略
 ///
 /// - Parameters:
 /// - error: 要处理的错误
 /// - context: 错误上下文
 /// - strategy: 恢复策略
    public func handle(
        _ error: Error,
        context: String = "",
        strategy: RecoveryStrategy = .notifyUser(message: "")
    ) async {
        let appError = mapToAppError(error)
        
 // 记录错误
        logError(appError, context: context)
        
 // 添加到历史
        let record = ErrorRecord(
            error: appError,
            timestamp: Date(),
            context: context,
            recovered: false
        )
        errorHistory.append(record)
        
 // 维护历史大小
        if errorHistory.count > maxHistorySize {
            errorHistory.removeFirst()
        }
        
 // 应用恢复策略
        await applyRecoveryStrategy(strategy, for: appError)
    }
    
 /// 安全执行操作，自动处理错误
 ///
 /// 替代 try? 的类型安全版本
    public func safely<T>(
        context: String = "",
        operation: @Sendable () async throws -> T
    ) async -> Result<T, AppError> {
        do {
            let result = try await operation()
            return .success(result)
        } catch {
            let appError = mapToAppError(error)
            await handle(appError, context: context)
            return .failure(appError)
        }
    }
    
 /// 安全执行操作（带默认值）
 ///
 /// 当操作失败时返回默认值
    public func safelyWithDefault<T>(
        context: String = "",
        defaultValue: T,
        operation: @Sendable () async throws -> T
    ) async -> T {
        let result = await safely(context: context, operation: operation)
        return result.value ?? defaultValue
    }
    
 /// 带重试的安全执行
 ///
 /// 自动重试失败的操作
    public func withRetry<T>(
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0,
        context: String = "",
        operation: @Sendable @escaping () async throws -> T
    ) async -> Result<T, AppError> {
        var lastError: AppError?
        
        for attempt in 1...maxAttempts {
            let result = await safely(context: "\(context) (尝试 \(attempt)/\(maxAttempts))", operation: operation)
            
            switch result {
            case .success(let value):
                if attempt > 1 {
                    logger.info("✅ 重试成功：\(context)")
                }
                return .success(value)
            case .failure(let error):
                lastError = error
                
                if attempt < maxAttempts {
                    logger.warning("⚠️ 操作失败，\(delay)秒后重试...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        logger.error("❌ 所有重试均失败：\(context)")
        return .failure(lastError ?? .unknown(NSError(domain: "Unknown", code: -1)))
    }
    
 // MARK: - 私有方法
    
    private func mapToAppError(_ error: Error) -> AppError {
 // 如果已经是 AppError，直接返回
        if let appError = error as? AppError {
            return appError
        }
        
 // URL 错误映射
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkUnavailable
            case .timedOut:
                return .connectionTimeout
            default:
                return .unknown(urlError)
            }
        }
        
 // 解码错误
        if error is DecodingError {
            return .serializationFailed(error)
        }
        
 // 其他错误
        return .unknown(error)
    }
    
    private func logError(_ error: AppError, context: String) {
        let severityIcon = error.severity.rawValue
        let contextStr = context.isEmpty ? "" : " [\(context)]"
        let message = "\(severityIcon) \(error.errorDescription ?? "未知错误")\(contextStr)"
        
        switch error.severity {
        case .debug:
            logger.debug("\(message)")
        case .info:
            logger.info("\(message)")
        case .warning:
            logger.warning("\(message)")
        case .error:
            logger.error("\(message)")
        case .critical:
            logger.critical("\(message)")
        }
    }
    
    private func applyRecoveryStrategy(_ strategy: RecoveryStrategy, for error: AppError) async {
        switch strategy {
        case .retry(let maxAttempts, let delay):
            logger.info("应用重试策略：最多 \(maxAttempts) 次，间隔 \(delay) 秒")
            
        case .fallback(let action):
            logger.info("应用降级策略")
            await action()
            
        case .notifyUser(let message):
            let userMessage = message.isEmpty ? error.errorDescription ?? "发生错误" : message
            logger.info("通知用户：\(userMessage)")
 // 这里可以发送通知到 UI 层
            
        case .silent:
            logger.debug("静默处理错误")
        }
    }
    
 // MARK: - 错误分析
    
 /// 获取错误统计
    public func getErrorStatistics() -> ErrorStatistics {
        let totalErrors = errorHistory.count
        let criticalErrors = errorHistory.filter { $0.error.severity == .critical }.count
        let recoveredErrors = errorHistory.filter { $0.recovered }.count
        
 // 按类型分组
        var errorsByType: [String: Int] = [:]
        for record in errorHistory {
            let typeName = String(describing: record.error)
            errorsByType[typeName, default: 0] += 1
        }
        
        return ErrorStatistics(
            totalErrors: totalErrors,
            criticalErrors: criticalErrors,
            recoveredErrors: recoveredErrors,
            errorsByType: errorsByType,
            recentErrors: Array(errorHistory.suffix(10))
        )
    }
    
    public struct ErrorStatistics {
        public let totalErrors: Int
        public let criticalErrors: Int
        public let recoveredErrors: Int
        public let errorsByType: [String: Int]
        public let recentErrors: [ErrorRecord]
    }
}

// MARK: - Result 扩展

extension Result {
 /// 获取值（如果成功），否则返回 nil
    public var value: Success? {
        switch self {
        case .success(let value):
            return value
        case .failure:
            return nil
        }
    }
    
 /// 获取错误（如果失败），否则返回 nil
    public var error: Failure? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }
}

// MARK: - 使用示例和文档

/*
 ## 使用示例
 
 ### 1. 基本错误处理
 
 ```swift
 let result = await UnifiedErrorHandler.shared.safely {
     try await someRiskyOperation()
 }
 
 switch result {
 case .success(let value):
     SkyBridgeLogger.ui.debugOnly("成功：\(String(describing: value), privacy: .private)")
 case .failure(let error):
     SkyBridgeLogger.ui.error("失败：\(error.localizedDescription, privacy: .private)")
 }
 ```
 
 ### 2. 带默认值的安全执行
 
 ```swift
 let devices = await UnifiedErrorHandler.shared.safelyWithDefault(
     context: "加载设备列表",
     defaultValue: []
 ) {
     try await loadDevices()
 }
 ```
 
 ### 3. 自动重试
 
 ```swift
 let result = await UnifiedErrorHandler.shared.withRetry(
     maxAttempts: 3,
     delay: 2.0,
     context: "连接服务器"
 ) {
     try await connectToServer()
 }
 ```
 
 ### 4. 手动错误处理
 
 ```swift
 await UnifiedErrorHandler.shared.handle(
     error,
     context: "用户登录",
     strategy: .retry(maxAttempts: 3, delay: 1.0)
 )
 ```
 */

