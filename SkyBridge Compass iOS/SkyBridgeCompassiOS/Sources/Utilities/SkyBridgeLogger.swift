import Foundation
import os.log

private enum SkyBridgeLogPrivacySanitizer {
    private static let assignmentRegex = expression(
        #"(?i)(?<![A-Za-z0-9_-])(session|sessionId|session_id|from|to|peer|peerDeviceId|targetDeviceId|p2pDeviceId|remoteId|remoteName|device|deviceId|device_id|deviceName|declaredSenderId|senderDeviceId|matchDeviceId|resolvedPeerDeviceId|identityKey|fingerprint|pubKeyFP|publicKeyBase64|xwingPublicKey|mlkemPublicKey|token|accessToken|refreshToken|bearerToken|authorization|apiKey|secret|password|passphrase|credential|cookie|tenantId|userIdentifier|userId|sub|nebulaId|displayName|accountDisplayName|relay|routeIdentifier|bonjourServiceName|endpoint|endpointHost|endpointHostOrIP|controlEndpoint|host|ip|address|url|path|trackId|connectionCode|status-file|statusFile|transferId|fileName|fileHash|target|original|resolved|requested|service|services|portMap|port|aliasCandidates|error|detail)=([^,;\r\n]*?)(?=\s+[A-Za-z][A-Za-z0-9_-]*=|[,;]|$)"#
    )
    private static let bearerRegex = expression(
        #"(?i)\bbearer\s+[A-Za-z0-9._~+\-/]+=*"#
    )
    private static let urlRegex = expression(
        #"(?i)\b(?:https?|wss?|rtsp|rtsps)://[^\s,;]+"#
    )
    private static let absolutePathRegex = expression(
        #"(?:/Users|/private|/var|/tmp|/Volumes|/data/user)/[^\s,;\r\n]+"#
    )
    private static let digestRegex = expression(
        #"(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])"#
    )
    private static let emailRegex = expression(
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
    )
    private static let ipv4EndpointRegex = expression(
        #"(?<![A-Za-z0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?(?![A-Za-z0-9])"#
    )
    private static let ipv6EndpointRegex = expression(
        #"(?i)(?:\[[0-9A-F:%.]+\](?::[0-9]{1,5})?|\b(?:fc|fd)[0-9A-F:%.]*:[0-9A-F:%.]+\b)"#
    )
    private static let uuidRegex = expression(
        #"(?i)\b[0-9A-F]{8}-[0-9A-F]{4}-[1-8][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b"#
    )

    static func sanitize(_ message: String) -> String {
        var sanitized = replacingMatches(
            in: message,
            using: assignmentRegex,
            template: "$1=<redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: bearerRegex,
            template: "Bearer <redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: urlRegex,
            template: "<redacted-url>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: absolutePathRegex,
            template: "<redacted-path>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: digestRegex,
            template: "<redacted-digest>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: emailRegex,
            template: "<redacted-email>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: ipv4EndpointRegex,
            template: "<redacted-endpoint>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            using: ipv6EndpointRegex,
            template: "<redacted-endpoint>"
        )
        return replacingMatches(
            in: sanitized,
            using: uuidRegex,
            template: "<redacted-identifier>"
        )
    }

    private static func replacingMatches(
        in value: String,
        using expression: NSRegularExpression,
        template: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("SkyBridge log privacy regex is invalid")
        }
    }
}

/// SkyBridge 日志系统
public final class SkyBridgeLogger: @unchecked Sendable {
    public static let shared = SkyBridgeLogger(subsystem: "com.skybridge.compass", category: "General")

    private let logger: Logger
    private let category: String
    private let lock = NSLock()
    private let timestampFormatter: DateFormatter
    private var echoToXcodeConsole: Bool
    private var consoleMinLevel: LogLevel
    
    public init(subsystem: String = "com.skybridge.compass", category: String = "General") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category

        // Xcode debug console doesn't reliably show OSLog output; we optionally echo to stdout.
        // Defaults:
        // - Debug: enabled + minLevel=info
        // - Release: disabled unless explicitly enabled through the environment
        let envOn = ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG"]
        let envLevel = (ProcessInfo.processInfo.environment["SKYBRIDGE_CONSOLE_LOG_LEVEL"] ?? "").lowercased()

        #if DEBUG
        let defaultOn = true
        let defaultMin = LogLevel.info
        #else
        let defaultOn = false
        let defaultMin = LogLevel.warning
        #endif

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.timestampFormatter = formatter

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
        write(level: .info, message: message)
    }

    public func debug(_ message: String) {
        write(level: .debug, message: message)
    }

    public func warning(_ message: String) {
        write(level: .warning, message: message)
    }

    public func error(_ message: String) {
        write(level: .error, message: message)
    }

    static func sanitizedMessage(_ message: String) -> String {
        SkyBridgeLogPrivacySanitizer.sanitize(message)
    }

    private func write(level: LogLevel, message: String) {
        let sanitizedMessage = Self.sanitizedMessage(message)
        switch level {
        case .debug:
            logger.debug("\(sanitizedMessage, privacy: .public)")
        case .info:
            logger.info("\(sanitizedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(sanitizedMessage, privacy: .public)")
        case .error:
            logger.error("\(sanitizedMessage, privacy: .public)")
        }
        LogStore.shared.append(level: level, category: category, message: sanitizedMessage)
        echo(level: level, message: sanitizedMessage)
    }

    private func echo(level: LogLevel, message: String) {
        lock.lock()
        let echoEnabled = echoToXcodeConsole
        let minLevel = consoleMinLevel
        guard echoEnabled, level.rank >= minLevel.rank else {
            lock.unlock()
            return
        }
        let ts = timestampFormatter.string(from: Date())
        lock.unlock()
        Swift.print("[\(ts)] [\(level.rawValue.uppercased())] [\(category)] \(message)")
    }
}

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}
