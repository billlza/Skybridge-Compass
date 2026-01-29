import Foundation
import os.log

/// SkyBridge 日志系统
public class SkyBridgeLogger {
    public static let shared = SkyBridgeLogger(subsystem: "com.skybridge.compass", category: "General")
    
    private let logger: Logger
    private let category: String
    private let echoToXcodeConsole: Bool
    
    public init(subsystem: String = "com.skybridge.compass", category: String = "General") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
        #if DEBUG
        // Xcode debug console doesn't reliably show OSLog output; echo a concise line for developer builds.
        // Can also be forced in Release via env var (useful for TestFlight repros).
        let env = ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG"] ?? "1"
        self.echoToXcodeConsole = (env == "1" || env.lowercased() == "true" || env.lowercased() == "yes")
        #else
        let env = ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG"] ?? "0"
        self.echoToXcodeConsole = (env == "1" || env.lowercased() == "true" || env.lowercased() == "yes")
        #endif
    }
    
    public func configure(level: LogLevel) {
        // 配置日志级别
    }
    
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogStore.shared.append(level: .info, category: category, message: message)
        echo(level: .info, message: message)
    }
    
    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        LogStore.shared.append(level: .debug, category: category, message: message)
        echo(level: .debug, message: message)
    }
    
    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        LogStore.shared.append(level: .warning, category: category, message: message)
        echo(level: .warning, message: message)
    }
    
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogStore.shared.append(level: .error, category: category, message: message)
        echo(level: .error, message: message)
    }

    private func echo(level: LogLevel, message: String) {
        guard echoToXcodeConsole else { return }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let ts = df.string(from: Date())
        Swift.print("[\(ts)] [\(level.rawValue.uppercased())] [\(category)] \(message)")
    }
}

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}
