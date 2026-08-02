import CryptoKit
import Foundation

enum SkyBridgeDiagnosticReference {
    static func stableReference(_ rawValue: String?) -> String {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "-"
        }
        if value == "-" {
            return "-"
        }
        if value == "<redacted>" {
            return "redacted"
        }
        if value == "present" || value == "missing" {
            return value
        }

        let digest = SHA256.hash(data: Data(value.utf8))
        let prefix = digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "ref:\(prefix)"
    }
}

#if DEBUG || SKYBRIDGE_TESTING
enum SkyBridgeTraceRedaction {
    private static let assignmentRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(?i)(?<![A-Za-z0-9_-])(session|sessionId|session_id|from|to|peer|peerDeviceId|targetDeviceId|p2pDeviceId|remoteId|remoteName|device|deviceId|device_id|identityKey|fingerprint|pubKeyFP|publicKeyBase64|xwingPublicKey|mlkemPublicKey|token|accessToken|refreshToken|bearerToken|authorization|tenantId|userIdentifier|userId|sub|nebulaId|displayName|accountDisplayName|relay|routeIdentifier|bonjourServiceName|endpoint|endpointHost|controlEndpoint|host|ip|address|url|path|trackId|connectionCode|status-file|statusFile)=([^\s,]+)"#
            )
        } catch {
            preconditionFailure("SkyBridge smoke redaction regex is invalid")
        }
    }()

    private static let diagnosticReferenceKeys: [String: String] = [
        "session": "session_ref",
        "sessionid": "session_ref",
        "session_id": "session_ref",
        "from": "from_ref",
        "to": "to_ref",
        "peer": "peer_ref",
        "peerdeviceid": "peer_ref",
        "targetdeviceid": "peer_ref",
        "p2pdeviceid": "peer_ref",
        "remoteid": "remote_ref",
        "remotename": "remote_ref",
        "device": "device_ref",
        "deviceid": "device_ref",
        "device_id": "device_ref",
        "identitykey": "identity_key_ref",
        "fingerprint": "fingerprint_ref",
        "pubkeyfp": "fingerprint_ref",
        "publickeybase64": "public_key_ref",
        "xwingpublickey": "public_key_ref",
        "mlkempublickey": "public_key_ref",
        "token": "token_ref",
        "accesstoken": "token_ref",
        "refreshtoken": "token_ref",
        "bearertoken": "token_ref",
        "authorization": "token_ref",
        "tenantid": "tenant_ref",
        "userid": "user_ref",
        "useridentifier": "user_ref",
        "sub": "user_ref",
        "nebulaid": "nebula_ref",
        "displayname": "display_name_ref",
        "accountdisplayname": "display_name_ref",
        "relay": "relay_ref",
        "routeidentifier": "route_ref",
        "bonjourservicename": "bonjour_service_ref",
        "endpoint": "endpoint_ref",
        "endpointhost": "endpoint_ref",
        "controlendpoint": "endpoint_ref",
        "host": "host_ref",
        "ip": "host_ref",
        "address": "host_ref",
        "url": "url_ref",
        "path": "path_ref",
        "trackid": "track_ref",
        "statusfile": "status_file_ref",
        "status-file": "status_file_ref",
        "connectioncode": "connection_code_ref"
    ]

    static func stableReference(_ rawValue: String?) -> String {
        SkyBridgeDiagnosticReference.stableReference(rawValue)
    }

    static func redactKnownAssignments(in line: String) -> String {
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = assignmentRegex.matches(in: line, range: range)
        guard !matches.isEmpty else {
            return line
        }

        let redacted = NSMutableString(string: line)
        for match in matches.reversed() {
            guard match.numberOfRanges == 3 else {
                return "trace_redaction_failed"
            }
            let key = source.substring(with: match.range(at: 1))
            let value = source.substring(with: match.range(at: 2))
            redacted.replaceCharacters(
                in: match.range(at: 0),
                with: "\(key)_ref=\(stableReference(value))"
            )
        }
        return redacted as String
    }

    static func sanitizedMediaDiagnosticFields(
        _ fields: [String: Any],
        timestamp: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "schema_version": 1,
            "timestamp": timestamp
        ]

        for (rawKey, rawValue) in fields {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            if key == "schema_version" || key == "timestamp" {
                continue
            }

            if let entry = sanitizedMediaDiagnosticEntry(key: key, value: rawValue) {
                payload[entry.key] = entry.value
            }
        }

        return payload
    }

    private static func sanitizedMediaDiagnosticEntry(key: String, value: Any) -> (key: String, value: Any)? {
        let referenceKey = diagnosticReferenceKey(for: key)
        if let referenceKey {
            return (referenceKey, stableReference(diagnosticScalarDescription(value)))
        }

        switch value {
        case let stringValue as String:
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLikelySensitiveDiagnosticString(trimmed) {
                return ("\(key)_ref", stableReference(trimmed))
            }
            return (key, trimmed)
        case let boolValue as Bool:
            return (key, boolValue)
        case let intValue as Int:
            return (key, intValue)
        case let intValue as Int64:
            return (key, intValue)
        case let doubleValue as Double:
            guard doubleValue.isFinite else { return nil }
            return (key, doubleValue)
        case let floatValue as Float:
            guard floatValue.isFinite else { return nil }
            return (key, Double(floatValue))
        case let numberValue as NSNumber:
            return (key, numberValue)
        default:
            return ("\(key)_redacted", "unsupported_non_scalar")
        }
    }

    private static func diagnosticReferenceKey(for key: String) -> String? {
        let normalized = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let replacement = diagnosticReferenceKeys[normalized] {
            return replacement
        }
        let compact = normalized
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return diagnosticReferenceKeys[compact]
    }

    private static func diagnosticScalarDescription(_ value: Any) -> String {
        switch value {
        case let stringValue as String:
            return stringValue
        case let boolValue as Bool:
            return boolValue ? "true" : "false"
        case let intValue as Int:
            return String(intValue)
        case let intValue as Int64:
            return String(intValue)
        case let doubleValue as Double:
            return String(doubleValue)
        case let floatValue as Float:
            return String(floatValue)
        case let numberValue as NSNumber:
            return numberValue.stringValue
        default:
            return String(describing: type(of: value))
        }
    }

    private static func isLikelySensitiveDiagnosticString(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lowercased = value.lowercased()
        if lowercased.contains("://") ||
            lowercased.contains("/users/") ||
            lowercased.contains("/private/var/") ||
            lowercased.contains("/var/folders/") ||
            lowercased.contains("/data/user/") ||
            lowercased.contains("token=") ||
            lowercased.contains("authorization: bearer") ||
            lowercased.contains("authorization=") ||
            lowercased.contains("bearer ") ||
            lowercased.contains("session=") ||
            lowercased.contains("peer=") ||
            lowercased.contains("device=") ||
            lowercased.hasPrefix("sk-") {
            return true
        }
        if value.count >= 32 {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
            return value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        if value.contains("@") {
            return true
        }
        if value.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?$"#, options: .regularExpression) != nil {
            return true
        }
        if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,}(?::\d{1,5})?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

enum SkyBridgeDiagnosticTrace {
    private enum ConfigurationError: LocalizedError, Sendable {
        case invalidListenerStatusBasename
        case cachesDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidListenerStatusBasename:
                return "smoke listener status basename is invalid"
            case .cachesDirectoryUnavailable:
                return "smoke listener status directory is unavailable"
            }
        }
    }

    private enum ListenerStatusResolution: Sendable {
        case disabled
        case configured(URL)
        case invalid(ConfigurationError)
    }

    private struct Destination {
        let baseCaches: URL
        let fileName: String

        func url(suffix: String) -> URL {
            baseCaches.appendingPathComponent("\(fileName)\(suffix)")
        }
    }

    private struct MediaDiagnosticFields: @unchecked Sendable {
        let values: [String: Any]
    }

    private final class WriterState: @unchecked Sendable {
        private let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        func timestamp() -> String {
            timestampFormatter.string(from: Date())
        }
    }

    private static let writerQueueKey = DispatchSpecificKey<UInt8>()
    private static let writerQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.skybridge.compass.smoke-trace-writer",
            qos: .utility
        )
        queue.setSpecific(key: writerQueueKey, value: 1)
        return queue
    }()
    private static let destination: Destination? = {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return nil }
        let basename: SmokeArtifactBasename
        do {
            guard let resolved = try SmokeArtifactBasename.resolve(
                environmentValue: ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"],
                defaultValue: "skybridge-smoke-status.log"
            ) else {
                return nil
            }
            basename = resolved
        } catch {
            SkyBridgeLogger.shared.error("Smoke trace status basename rejected")
            return nil
        }
        guard let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return Destination(baseCaches: baseCaches, fileName: basename.value)
    }()
    private static let listenerStatusResolution: ListenerStatusResolution = {
        do {
            guard let url = try makeListenerStatusURL(
                environment: ProcessInfo.processInfo.environment,
                cachesDirectory: FileManager.default.urls(
                    for: .cachesDirectory,
                    in: .userDomainMask
                ).first
            ) else {
                return .disabled
            }
            return .configured(url)
        } catch let error as ConfigurationError {
            SkyBridgeLogger.shared.error("Smoke trace listener configuration rejected")
            return .invalid(error)
        } catch {
            SkyBridgeLogger.shared.error("Smoke trace listener configuration failed unexpectedly")
            return .invalid(.invalidListenerStatusBasename)
        }
    }()
    private static let writerState = WriterState()

    static func appendStatus(_ line: @autoclosure () -> String) {
        enqueueStatusLine(line())
    }

    static func append(_ line: @autoclosure () -> String) {
        enqueueLine(SkyBridgeTraceRedaction.redactKnownAssignments(in: line()), suffix: ".trace.log")
    }

    /// Waits until every diagnostic write submitted before this call is durable.
    /// Smoke completion uses this barrier before the runner copies the app cache,
    /// preventing a successful tail event from remaining only in the queue.
    static func flush() {
        guard DispatchQueue.getSpecific(key: writerQueueKey) == nil else { return }
        writerQueue.sync {}
    }

    static func resetStatusArtifacts(primaryStatusURL: URL) throws {
        if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
            try resetConfiguredStatusArtifacts(primaryStatusURL: primaryStatusURL)
            return
        }
        try writerQueue.sync {
            try resetConfiguredStatusArtifacts(primaryStatusURL: primaryStatusURL)
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func resetStatusArtifactsForTesting(
        primaryStatusURL: URL,
        listenerStatusURL: URL?
    ) throws {
        if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
            try resetStatusArtifacts(
                primaryStatusURL: primaryStatusURL,
                listenerStatusURL: listenerStatusURL
            )
            return
        }
        try writerQueue.sync {
            try resetStatusArtifacts(
                primaryStatusURL: primaryStatusURL,
                listenerStatusURL: listenerStatusURL
            )
        }
    }

    static func resolveListenerStatusURLForTesting(
        environment: [String: String],
        cachesDirectory: URL?
    ) throws -> URL? {
        try makeListenerStatusURL(
            environment: environment,
            cachesDirectory: cachesDirectory
        )
    }
#endif

    private static func enqueueStatusLine(_ line: String) {
        guard let destination else { return }
        let statusURL = destination.url(suffix: "")
        let mirrorURL: URL?
        if isListenerLifecycleStatusLine(line) {
            do {
                mirrorURL = try resolvedListenerStatusURL()
            } catch {
                SkyBridgeLogger.shared.error("Smoke trace listener configuration rejected")
                return
            }
        } else {
            mirrorURL = nil
        }
        writerQueue.async {
            let formatted = "[\(writerState.timestamp())] \(line)\n"
            guard let data = formatted.data(using: .utf8) else { return }
            do {
                try write(data, to: statusURL)
            } catch {
                SkyBridgeLogger.shared.error("Smoke trace primary status write failed")
                return
            }
            if let mirrorURL {
                do {
                    try write(data, to: mirrorURL)
                } catch {
                    SkyBridgeLogger.shared.error("Smoke trace listener status write failed")
                    appendListenerStatusWriteFailure(to: statusURL)
                }
            }
        }
    }

    private static func enqueueLine(_ line: String, suffix: String) {
        guard let destination else { return }
        let url = destination.url(suffix: suffix)
        writerQueue.async {
            let formatted = "[\(writerState.timestamp())] \(line)\n"
            guard let data = formatted.data(using: .utf8) else { return }
            do {
                try write(data, to: url)
            } catch {
                SkyBridgeLogger.shared.error("Smoke trace diagnostic write failed")
            }
        }
    }

    static func appendMediaDiagnostic(_ fields: @autoclosure () -> [String: Any]) {
        guard let destination else { return }
        let url = destination.url(suffix: ".webrtc-media.jsonl")
        let snapshot = MediaDiagnosticFields(values: fields())
        writerQueue.async {
            let payload = SkyBridgeTraceRedaction.sanitizedMediaDiagnosticFields(
                snapshot.values,
                timestamp: writerState.timestamp()
            )
            guard JSONSerialization.isValidJSONObject(payload) else {
                SkyBridgeLogger.shared.error("Smoke media diagnostic serialization input rejected")
                return
            }
            do {
                var line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                line.append(0x0a)
                try write(line, to: url)
            } catch {
                SkyBridgeLogger.shared.error("Smoke media diagnostic write failed")
            }
        }
    }

    private static func isListenerLifecycleStatusLine(_ line: String) -> Bool {
        let lifecyclePrefixes = [
            "p2p-listener ready",
            "p2p-listener stopped",
            "p2p-listener failed",
            "p2p-listener cancelled",
            "p2p-listener unhealthy"
        ]
        return lifecyclePrefixes.contains { line.hasPrefix($0) }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try SmokeArtifactFileIO.appendProtectedData(data, to: url)
    }

    private static func resolvedListenerStatusURL() throws -> URL? {
        switch listenerStatusResolution {
        case .disabled:
            return nil
        case .configured(let url):
            return url
        case .invalid(let error):
            throw error
        }
    }

    private static func makeListenerStatusURL(
        environment: [String: String],
        cachesDirectory: URL?
    ) throws -> URL? {
        guard environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return nil }
        let basename: SmokeArtifactBasename
        do {
            guard let resolved = try SmokeArtifactBasename.resolve(
                environmentValue: environment["SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME"]
            ) else {
                return nil
            }
            basename = resolved
        } catch {
            throw ConfigurationError.invalidListenerStatusBasename
        }
        guard let cachesDirectory else {
            throw ConfigurationError.cachesDirectoryUnavailable
        }
        return basename.url(in: cachesDirectory)
    }

    private static func resetStatusArtifacts(
        primaryStatusURL: URL,
        listenerStatusURL: URL?
    ) throws {
        try SmokeArtifactFileIO.resetProtectedFile(at: primaryStatusURL)
        if let listenerStatusURL {
            try SmokeArtifactFileIO.resetProtectedFile(at: listenerStatusURL)
        }
    }

    private static func resetConfiguredStatusArtifacts(primaryStatusURL: URL) throws {
        // Primary evidence is always cleared first. A malformed listener configuration must fail
        // the new run without leaving a previous primary success marker readable by the runner.
        try SmokeArtifactFileIO.resetProtectedFile(at: primaryStatusURL)
        if let listenerStatusURL = try resolvedListenerStatusURL() {
            try SmokeArtifactFileIO.resetProtectedFile(at: listenerStatusURL)
        }
    }

    private static func appendListenerStatusWriteFailure(to statusURL: URL) {
        let line = "[\(writerState.timestamp())] p2p-listener failed stage=listener-status-sidecar-write reason=write-failed\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try write(data, to: statusURL)
        } catch {
            SkyBridgeLogger.shared.error("Smoke trace listener failure evidence write failed")
        }
    }
}
#else
/// Compile-time production sink for diagnostic call sites shared with smoke-enabled builds.
/// Autoclosures keep trace strings and diagnostic dictionaries unevaluated in product builds;
/// the optimized Release binary therefore contains no smoke writer state, environment reads,
/// file I/O, queues, or evidence payloads.
enum SkyBridgeDiagnosticTrace {
    @inline(__always)
    static func appendStatus(_ line: @autoclosure () -> String) {}

    @inline(__always)
    static func append(_ line: @autoclosure () -> String) {}

    @inline(__always)
    static func appendMediaDiagnostic(_ fields: @autoclosure () -> [String: Any]) {}

    @inline(__always)
    static func flush() {}
}
#endif
