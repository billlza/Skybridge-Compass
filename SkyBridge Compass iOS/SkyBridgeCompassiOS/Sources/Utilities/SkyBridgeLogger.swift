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
        publish(level: .info, message: message)
    }
    
    public func debug(_ message: String) {
        publish(level: .debug, message: message)
    }
    
    public func warning(_ message: String) {
        publish(level: .warning, message: message)
    }
    
    public func error(_ message: String) {
        publish(level: .error, message: message)
    }

    private func publish(level: LogLevel, message: String) {
        let persistedMessage = Self.runtimeMessage(
            message,
            environment: ProcessInfo.processInfo.environment
        )
        switch level {
        case .debug: logger.debug("\(persistedMessage, privacy: .public)")
        case .info: logger.info("\(persistedMessage, privacy: .public)")
        case .warning: logger.warning("\(persistedMessage, privacy: .public)")
        case .error: logger.error("\(persistedMessage, privacy: .public)")
        }
        LogStore.shared.append(level: level, category: category, message: persistedMessage)
        echo(level: level, message: persistedMessage)
    }

    static func runtimeMessage(
        _ message: String,
        environment: [String: String]
    ) -> String {
        guard environment["SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY"] == "1" else {
            return message
        }
        let rawEvent = message.prefix { !$0.isWhitespace }
        let event = rawEvent.unicodeScalars.prefix(64).map { scalar -> Character in
            let value = scalar.value
            let allowed = (48...57).contains(value) ||
                (65...90).contains(value) ||
                (97...122).contains(value) ||
                scalar == "-" || scalar == "_" || scalar == "."
            return allowed ? Character(String(scalar)) : "_"
        }
        let category = event.isEmpty ? "unknown" : String(event)
        return "event=\(category) details=<redacted>"
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
