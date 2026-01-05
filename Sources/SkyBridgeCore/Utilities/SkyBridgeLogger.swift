import Foundation
import OSLog

// MARK: - SkyBridge 统一日志系统
// Swift 6.2.1 最佳实践：统一日志管理，规范化表情符号处理

/// 日志级别
public enum LogLevel: Int, Sendable, Comparable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case critical = 5
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

/// 日志表情符号配置
public enum LogEmoji: Sendable {
 /// 表情符号策略
    public enum Strategy: Sendable {
        case always          // 总是显示表情符号
        case debugOnly       // 仅 DEBUG 构建显示
        case never           // 从不显示表情符号
        
        var shouldShow: Bool {
            switch self {
            case .always: return true
            case .never: return false
            case .debugOnly:
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
        }
    }
    
 // 功能类别表情
    public static let ui = "🎨"
    public static let network = "🌐"
    public static let p2p = "🔗"
    public static let security = "🔐"
    public static let discovery = "🔍"
    public static let connection = "🔌"
    public static let metal = "⚡"
    public static let performance = "📊"
    public static let weather = "🌤️"
    public static let file = "📁"
    public static let auth = "🔑"
    public static let quantum = "🔮"
    public static let system = "🖥️"
    
 // 状态表情
    public static let success = "✅"
    public static let warning = "⚠️"
    public static let error = "❌"
    public static let info = "ℹ️"
    public static let progress = "🔄"
    public static let start = "🚀"
    public static let stop = "🛑"
    public static let complete = "✓"
}

/// 统一日志工具
///
/// 中文说明：集中管理子系统与分类，避免使用分散的 `print`/`NSLog`
/// 符合 Apple Silicon 与 Swift 6.2.1 最佳实践，支持结构化日志
public enum SkyBridgeLogger {
    
 // MARK: - 配置
    
 /// 统一子系统标识
    public static let subsystem = "com.skybridge.compass"
    
 /// 当前表情符号策略
 /// Swift 6.2.1: 使用 nonisolated(unsafe) 标记跨并发域共享的可变状态
 /// 注意：此属性的修改应在应用启动时进行，运行时不应频繁修改
    nonisolated(unsafe) public static var emojiStrategy: LogEmoji.Strategy = .debugOnly
    
 /// 最小日志级别（低于此级别的日志不输出）
 /// Swift 6.2.1: 使用 nonisolated(unsafe) 允许跨并发域访问
    nonisolated(unsafe) public static var minimumLogLevel: LogLevel = .debug
    
 // MARK: - 分类 Logger 实例
    
 /// UI 相关日志
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    
 /// 网络相关日志
    public static let network = Logger(subsystem: subsystem, category: "Network")
    
 /// P2P 相关日志
    public static let p2p = Logger(subsystem: subsystem, category: "P2P")
    
 /// 安全相关日志
    public static let security = Logger(subsystem: subsystem, category: "Security")
    
 /// 设备发现日志
    public static let discovery = Logger(subsystem: subsystem, category: "Discovery")
    
 /// 连接管理日志
    public static let connection = Logger(subsystem: subsystem, category: "Connection")
    
 /// Metal/图形日志
    public static let metal = Logger(subsystem: subsystem, category: "Metal")
    
 /// 性能监控日志
    public static let performance = Logger(subsystem: subsystem, category: "Performance")
    
 /// 天气系统日志
    public static let weather = Logger(subsystem: subsystem, category: "Weather")
    
 /// 文件传输日志
    public static let fileTransfer = Logger(subsystem: subsystem, category: "FileTransfer")
    
 /// 认证日志
    public static let auth = Logger(subsystem: subsystem, category: "Auth")
    
 /// 量子安全日志
    public static let quantum = Logger(subsystem: subsystem, category: "Quantum")
    
 /// 系统监控日志
    public static let system = Logger(subsystem: subsystem, category: "System")
    
 /// 测试日志
    public static let test = Logger(subsystem: subsystem, category: "Test")
    
 // MARK: - 统一日志方法
    
 /// 格式化消息（处理表情符号）
 /// - Parameters:
 /// - message: 原始消息
 /// - emoji: 可选表情符号
 /// - forceEmoji: 强制显示表情符号（覆盖策略）
 /// - Returns: 格式化后的消息
    public static func formatMessage(_ message: String, emoji: String? = nil, forceEmoji: Bool = false) -> String {
        let shouldShowEmoji = forceEmoji || emojiStrategy.shouldShow
        
        if shouldShowEmoji, let emoji = emoji {
            return "\(emoji) \(message)"
        }
        
 // 如果不显示表情符号，移除消息开头的表情符号
        if !shouldShowEmoji {
            return stripLeadingEmoji(message)
        }
        
        return message
    }
    
 /// 移除消息开头的表情符号
    private static func stripLeadingEmoji(_ message: String) -> String {
        var result = message
        
 // 检查并移除开头的表情符号和空格
        while let first = result.unicodeScalars.first {
            if first.properties.isEmoji && !first.properties.isASCIIHexDigit {
                result = String(result.dropFirst())
 // 移除表情后面的空格
                if result.hasPrefix(" ") {
                    result = String(result.dropFirst())
                }
            } else {
                break
            }
        }
        
        return result
    }
    
 // MARK: - 便捷日志方法
    
 /// 记录 UI 日志
    public static func logUI(_ message: String, level: LogLevel = .debug) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.ui)
        ui.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录网络日志
    public static func logNetwork(_ message: String, level: LogLevel = .debug) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.network)
        network.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录 P2P 日志
    public static func logP2P(_ message: String, level: LogLevel = .debug) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.p2p)
        p2p.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录安全日志
    public static func logSecurity(_ message: String, level: LogLevel = .info) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.security)
        security.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录发现日志
    public static func logDiscovery(_ message: String, level: LogLevel = .debug) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.discovery)
        discovery.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录性能日志
    public static func logPerformance(_ message: String, level: LogLevel = .debug) {
        guard level >= minimumLogLevel else { return }
        let formatted = formatMessage(message, emoji: LogEmoji.performance)
        performance.log(level: level.osLogType, "\(formatted)")
    }
    
 /// 记录错误
    public static func logError(_ message: String, category: Logger = performance, error: Error? = nil) {
        var fullMessage = formatMessage(message, emoji: LogEmoji.error)
        if let error = error {
            fullMessage += " - \(error.localizedDescription)"
        }
        category.error("\(fullMessage)")
    }
    
 /// 记录成功
    public static func logSuccess(_ message: String, category: Logger = performance) {
        let formatted = formatMessage(message, emoji: LogEmoji.success)
        category.info("\(formatted)")
    }
    
 /// 记录警告
    public static func logWarning(_ message: String, category: Logger = performance) {
        let formatted = formatMessage(message, emoji: LogEmoji.warning)
        category.warning("\(formatted)")
    }
}

// MARK: - Logger 扩展

extension Logger {
 /// 仅在 DEBUG 构建中输出调试日志
    public func debugOnly(_ message: String) {
        #if DEBUG
        self.debug("\(SkyBridgeLogger.formatMessage(message))")
        #endif
    }

 /// 仅在 DEBUG 构建中输出跟踪日志
    public func traceOnly(_ message: String) {
        #if DEBUG
        self.debug("\(SkyBridgeLogger.formatMessage(message))")
        #endif
    }
    
 /// 带表情符号的日志（遵循全局策略）
    public func withEmoji(_ emoji: String, _ message: String, level: OSLogType = .debug) {
        let formatted = SkyBridgeLogger.formatMessage(message, emoji: emoji)
        self.log(level: level, "\(formatted)")
    }
    
 /// 记录操作开始
    public func start(_ operation: String) {
        let formatted = SkyBridgeLogger.formatMessage("\(operation) 开始", emoji: LogEmoji.start)
        self.info("\(formatted)")
    }
    
 /// 记录操作完成
    public func complete(_ operation: String, duration: TimeInterval? = nil) {
        var message = "\(operation) 完成"
        if let duration = duration {
            message += " (耗时: \(String(format: "%.2f", duration))s)"
        }
        let formatted = SkyBridgeLogger.formatMessage(message, emoji: LogEmoji.complete)
        self.info("\(formatted)")
    }
    
 /// 记录进度
    public func progress(_ message: String, percent: Double? = nil) {
        var fullMessage = message
        if let percent = percent {
            fullMessage += " (\(String(format: "%.1f", percent * 100))%)"
        }
        let formatted = SkyBridgeLogger.formatMessage(fullMessage, emoji: LogEmoji.progress)
        self.debug("\(formatted)")
    }
}

// MARK: - 性能计时器

/// 性能计时器
public final class PerformanceTimer: @unchecked Sendable {
    private let name: String
    private let logger: Logger
    private let startTime: CFAbsoluteTime
    
    public init(_ name: String, logger: Logger = SkyBridgeLogger.performance) {
        self.name = name
        self.logger = logger
        self.startTime = CFAbsoluteTimeGetCurrent()
        logger.start(name)
    }
    
    public func stop() {
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.complete(name, duration: duration)
    }
    
    @discardableResult
    public func measure<T>(_ operation: () throws -> T) rethrows -> T {
        defer { stop() }
        return try operation()
    }
    
    @discardableResult
    public func measureAsync<T>(_ operation: () async throws -> T) async rethrows -> T {
        defer { stop() }
        return try await operation()
    }
}
