import Foundation
import os.log

/// SkyBridge 日志系统
public final class SkyBridgeLogger: @unchecked Sendable {
    public static let shared = SkyBridgeLogger(subsystem: "com.skybridge.compass", category: "General")
    
    private let logger: Logger
    private let category: String
    private let lock = NSLock()
    private var echoToXcodeConsole: Bool
    private var consoleMinLevel: LogLevel
    
    public init(subsystem: String = "com.skybridge.compass", category: String = "General") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category

        // Xcode debug console doesn't reliably show OSLog output; we optionally echo to stdout.
        // Defaults:
        // - Debug: enabled + minLevel=debug
        // - Release: enabled + minLevel=warning (to avoid spam)
        let envOn = ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG"]
        let envLevel = (ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG_LEVEL"] ?? "").lowercased()

        #if DEBUG
        let defaultOn = true
        let defaultMin = LogLevel.debug
        #else
        let defaultOn = true
        let defaultMin = LogLevel.warning
        #endif

        if let envOn {
            let v = envOn.lowercased()
            self.echoToXcodeConsole = (v == "1" || v == "true" || v == "yes")
        } else {
            self.echoToXcodeConsole = defaultOn
        }

        self.consoleMinLevel = {
            switch envLevel {
            case "debug": return .debug
            case "info": return .info
            case "warning", "warn": return .warning
            case "error": return .error
            default: return defaultMin
            }
        }()
    }
    
    public func configure(level: LogLevel) {
        lock.lock()
        consoleMinLevel = level
        lock.unlock()
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
        lock.lock()
        let echoEnabled = echoToXcodeConsole
        let minLevel = consoleMinLevel
        lock.unlock()

        guard echoEnabled else { return }
        guard level.rank >= minLevel.rank else { return }
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
