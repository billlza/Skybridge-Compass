import Foundation
import os.log

/// SkyBridge 日志系统
public class SkyBridgeLogger {
    public static let shared = SkyBridgeLogger(subsystem: "com.skybridge.compass", category: "General")
    
    private let logger: Logger
    private let category: String
    
    public init(subsystem: String = "com.skybridge.compass", category: String = "General") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }
    
    public func configure(level: LogLevel) {
        // 配置日志级别
    }
    
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogStore.shared.append(level: .info, category: category, message: message)
    }
    
    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        LogStore.shared.append(level: .debug, category: category, message: message)
    }
    
    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        LogStore.shared.append(level: .warning, category: category, message: message)
    }
    
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogStore.shared.append(level: .error, category: category, message: message)
    }
}

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}
