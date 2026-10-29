import Foundation
import OSLog
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia
import Darwin

final class CrossNetworkWebRTCDiagnosticWriter: @unchecked Sendable {
    typealias WriteOperation = @Sendable (Data, URL, String) throws -> Void
    typealias FailureHandler = @Sendable (String, Error) -> Void

    private struct PendingEntry: Sendable {
        let data: Data
        let url: URL
        let label: String
    }

    private let queue: DispatchQueue
    private let maximumPendingCount: Int
    private let maximumPendingBytes: Int
    private let writeOperation: WriteOperation
    private let failureHandler: FailureHandler
    private let lock = NSLock()
    private var pendingEntries: [PendingEntry] = []
    private var pendingCount = 0
    private var pendingBytes = 0
    private var isDraining = false

    init(
        queue: DispatchQueue,
        maximumPendingCount: Int,
        maximumPendingBytes: Int,
        writeOperation: @escaping WriteOperation,
        failureHandler: @escaping FailureHandler
    ) {
        precondition(maximumPendingCount > 0)
        precondition(maximumPendingBytes > 0)
        self.queue = queue
        self.maximumPendingCount = maximumPendingCount
        self.maximumPendingBytes = maximumPendingBytes
        self.writeOperation = writeOperation
        self.failureHandler = failureHandler
    }

    @discardableResult
    func enqueue(data: Data, url: URL, label: String) -> Bool {
        var shouldScheduleDrain = false
        lock.lock()
        let canAccept = !data.isEmpty
            && data.count <= maximumPendingBytes
            && pendingCount < maximumPendingCount
            && pendingBytes <= maximumPendingBytes - data.count
        if canAccept {
            pendingEntries.append(PendingEntry(data: data, url: url, label: label))
            pendingCount += 1
            pendingBytes += data.count
            if !isDraining {
                isDraining = true
                shouldScheduleDrain = true
            }
        }
        lock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drain()
            }
        }
        return canAccept
    }

#if DEBUG || SKYBRIDGE_TESTING
    func flushForTesting() {
        queue.sync {}
    }

    func pendingSnapshotForTesting() -> (count: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pendingCount, pendingBytes)
    }
#endif

    private func drain() {
        while true {
            let entry: PendingEntry
            lock.lock()
            guard !pendingEntries.isEmpty else {
                isDraining = false
                lock.unlock()
                return
            }
            entry = pendingEntries.removeFirst()
            lock.unlock()

            do {
                try writeOperation(entry.data, entry.url, entry.label)
            } catch {
                failureHandler(entry.label, error)
            }

            lock.lock()
            pendingCount -= 1
            pendingBytes -= entry.data.count
            lock.unlock()
        }
    }
}

enum CrossNetworkWebRTCDiagnostics {
    private static let writerQueue = DispatchQueue(
        label: "com.skybridge.webrtc.diagnostics-writer",
        qos: .utility
    )
    private static let logger = Logger(
        subsystem: "com.skybridge.compass",
        category: "WebRTCDiagnostics"
    )
    private static let maximumLogByteCount: off_t = 8 * 1_024 * 1_024
    private static let maximumEntryByteCount = 64 * 1_024
    private static let maximumInputByteCount = 48 * 1_024
    private static let maximumPendingEntryCount = 128
    private static let maximumPendingByteCount = 1 * 1_024 * 1_024
    private static let rolloverMarker = Data("[diagnostic-log-rolled-over]\n".utf8)
    private static let writer = CrossNetworkWebRTCDiagnosticWriter(
        queue: writerQueue,
        maximumPendingCount: maximumPendingEntryCount,
        maximumPendingBytes: maximumPendingByteCount,
        writeOperation: { data, url, label in
            try append(data, to: url, label: label)
        },
        failureHandler: { label, error in
            logger.error(
                "WebRTC diagnostic write failed label=\(label, privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    )

    static func appendSmokeStatus(_ line: String) {
        guard let statusURL = smokeStatusURL() else { return }
        let sanitizedLine = sanitizeStatus(line)
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(sanitizedLine)\n"
        let data = Data(rendered.utf8)
        guard writer.enqueue(data: data, url: statusURL, label: "smoke-status") else {
            logger.error("WebRTC diagnostic queue capacity reached label=smoke-status")
            return
        }
    }

    static func appendRemoteMediaHeartbeatSmokeStatus(
        _ media: AppMessage.WebRTCMediaHeartbeatDiagnostics?,
        sessionID: String
    ) {
        guard let media else { return }
        if media.nativeVideoRendered,
           let width = media.nativeVideoWidth,
           let height = media.nativeVideoHeight,
           width > 0,
           height > 0 {
            let size = "\(width)x\(height)"
            appendSmokeStatus(
                "native-receiver-frame session=\(sessionID) size=\(size) visibleSize=\(size) codedSize=\(size) source=remote-heartbeat"
            )
            appendSmokeStatus(
                "native-render-frame session=\(sessionID) size=\(size) visibleSize=\(size) codedSize=\(size) source=rtc-mtl-video-view nativeRenderEvidenceSource=rtc-mtl-video-view nativePromotionState=remote-heartbeat"
            )
        }

        let audioDiagnosticValues = [
            media.audioRxDatagrams,
            media.audioRxRecv,
            media.audioRxDecoded,
            media.audioRxPlayed,
            media.audioRxRejected,
            media.audioRxAuthRejected,
            media.audioRxSessionHashRejected,
            media.audioRxReplayRejected,
            media.audioRxJitterEvicted,
            media.audioRxPlaybackDropped,
            media.audioRenderedFrames
        ]
        let hasAudioDiagnostics = audioDiagnosticValues.contains { $0 != nil }
            || media.audioUnderflow != nil
            || media.audioRebuffer != nil
            || media.audioStartupSilenceFrames != nil
            || media.audioEngineRunning != nil
        guard hasAudioDiagnostics else { return }
        let hasPositiveAudioEvidence = audioDiagnosticValues.contains { ($0 ?? 0) > 0 }
        let probableSuffix = hasPositiveAudioEvidence ? "" : " probable=audio-rx-no-positive-evidence"
        appendSmokeStatus(
            "audio-rx session=\(sessionID) source=remote-heartbeat "
                + "audioRxDatagrams=\(smokeUInt(media.audioRxDatagrams)) "
                + "audioRxRecv=\(smokeUInt(media.audioRxRecv)) "
                + "audioRxDecoded=\(smokeUInt(media.audioRxDecoded)) "
                + "audioRxPlayed=\(smokeUInt(media.audioRxPlayed)) "
                + "recvTotal=\(smokeUInt(media.audioRxRecv)) "
                + "decodeTotal=\(smokeUInt(media.audioRxDecoded)) "
                + "playTotal=\(smokeUInt(media.audioRxPlayed)) "
                + "rejected=\(smokeUInt(media.audioRxRejected)) "
                + "authRejected=\(smokeUInt(media.audioRxAuthRejected)) "
                + "sessionHashRejected=\(smokeUInt(media.audioRxSessionHashRejected)) "
                + "replayRejected=\(smokeUInt(media.audioRxReplayRejected)) "
                + "jitterEvicted=\(smokeUInt(media.audioRxJitterEvicted)) "
                + "playbackDrop=\(smokeUInt(media.audioRxPlaybackDropped)) "
                + "renderedFrames=\(smokeUInt(media.audioRenderedFrames)) "
                + "underflow=\(smokeUInt(media.audioUnderflow)) "
                + "rebuffer=\(smokeUInt(media.audioRebuffer)) "
                + "startupSilenceFrames=\(smokeUInt(media.audioStartupSilenceFrames)) "
                + "engineRunning=\(smokeBool(media.audioEngineRunning))"
                + probableSuffix
        )
    }

    static func writeSessionDiagnostic(_ line: String, sessionID: String) {
#if os(macOS)
        let safeSessionID = String(
            sessionID.prefix(256)
                .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                .prefix(128)
        )
        guard !safeSessionID.isEmpty else { return }
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("webrtc-session-\(safeSessionID).log")
        let boundedLine = boundedDiagnosticInput(line)
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(boundedLine)\n"
        let data = Data(rendered.utf8)
        guard writer.enqueue(data: data, url: logURL, label: "session-diagnostic") else {
            logger.error("WebRTC diagnostic queue capacity reached label=session-diagnostic")
            return
        }
#else
        _ = line
        _ = sessionID
#endif
    }

    private static func append(_ data: Data, to url: URL, label: String) throws {
        guard !data.isEmpty, data.count <= maximumEntryByteCount else {
            throw POSIXError(.EFBIG)
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var parentMetadata = stat()
        guard lstat(parent.path, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
              parentMetadata.st_uid == geteuid(),
              (parentMetadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let descriptor = open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1,
                  (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw CocoaError(.fileWriteNoPermission)
            }

            if metadata.st_size < 0 || metadata.st_size > maximumLogByteCount {
                throw POSIXError(.EFBIG)
            }
            if metadata.st_size + off_t(data.count) > maximumLogByteCount {
                guard ftruncate(descriptor, 0) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try writeAll(rolloverMarker, to: descriptor)
            }
            try writeAll(data, to: descriptor)
        } catch {
            let operationError = error
            if close(descriptor) != 0 {
                logger.error(
                    "WebRTC diagnostic close failed after write error label=\(label, privacy: .public) errno=\(errno, privacy: .public)"
                )
            }
            throw operationError
        }

        guard close(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    static func sanitizeStatus(_ value: String) -> String {
        let lineSafe = boundedDiagnosticInput(value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return smokeStatusRedactionPatterns.reduce(lineSafe) { current, rule in
            rule.regex.stringByReplacingMatches(
                in: current,
                range: NSRange(current.startIndex..<current.endIndex, in: current),
                withTemplate: rule.replacement
            )
        }
    }

    static func boundedDiagnosticInput(_ value: String) -> String {
        let truncationMarker = " [truncated]"
        let maximumContentBytes = maximumInputByteCount - truncationMarker.utf8.count
        let boundedPrefix = value.utf8.prefix(maximumInputByteCount + 1)
        guard boundedPrefix.count > maximumInputByteCount else { return value }

        var prefix = Data(boundedPrefix.prefix(maximumContentBytes))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return (String(data: prefix, encoding: .utf8) ?? "") + truncationMarker
    }

    private static let smokeStatusRedactionPatterns: [(regex: NSRegularExpression, replacement: String)] = [
        (
            try! NSRegularExpression(pattern: #"(session|sessionId|code|deviceId|peerId|fingerprint|from|to)=("[^"\s]+"|[^"\s]+)"#),
            "$1=<redacted>"
        ),
        (
            try! NSRegularExpression(pattern: #"(sessionId|code): "[^"]+""#),
            "$1: \"<redacted>\""
        ),
        (
            try! NSRegularExpression(pattern: #"\bcode [A-Za-z0-9_-]{6,}\b"#),
            "code <redacted>"
        )
    ]

    static func describeScreenPayloadMagic(_ payload: Data) -> String {
        guard payload.count >= 4 else { return "raw" }
        let prefix = payload.prefix(4)
        if prefix.elementsEqual([0x53, 0x42, 0x50, 0x32]) { return "SBP2" }
        if prefix.elementsEqual([0x53, 0x42, 0x52, 0x46]) { return "SBRF" }
        return "cipher"
    }

    static func writeAudioTxTransportEvent(
        _ event: SkyBridgeRealtimeMediaTransportEvent,
        sessionID: String,
        endpoint: SkyBridgeMediaEndpoint,
        leaseSource: String,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy
    ) {
        let kind: String
        let probable: String
        let detail: String
        switch event {
        case .udpConnectionReady:
            kind = "audioTxRelayUDPReady"
            probable = "udp-ready"
            detail = "audioTxRelayUDPReady"
        case .relayBindSent:
            kind = "audioTxRelayBindSent"
            probable = "relay-bind-sent"
            detail = "audioTxRelayBindSent"
        case .relayBindAccepted:
            kind = "audioTxRelayBindAccepted"
            probable = "relay-bind-accepted"
            detail = "audioTxRelayBindAccepted"
        case .relayBindAckTimedOut:
            if relayBindPolicy == .optimisticAfterSend {
                kind = "audioTxRelayBindAckPending"
                probable = "relay-bind-ack-pending-media-optimistic"
                detail = "audioTxRelayBindAckPending reason=relayBindAckTimedOut"
            } else {
                kind = "audioTxRelayBindTimedOut"
                probable = "relay-bind-timed-out"
                detail = "audioTxUnavailable reason=relayBindTimedOut"
            }
        case .relayBindRejected(let reason):
            kind = "audioTxRelayBindRejected"
            probable = "relay-bind-rejected"
            detail = "audioTxUnavailable reason=relayBindRejected error=\(reason)"
        case .relayBindMalformed:
            kind = "audioTxRelayBindMalformed"
            probable = "relay-bind-malformed"
            detail = "audioTxUnavailable reason=relayBindMalformed"
        }

        writeSessionDiagnostic(
            "\(detail) session=\(sessionID) leaseSource=\(leaseSource) endpoint=\(endpoint.host):\(endpoint.port) token=\(endpoint.relayToken == nil ? "missing" : "present")",
            sessionID: sessionID
        )
        WebRTCMediaDiagnosticWriter.append(
            WebRTCMediaDiagnosticEvent(
                sessionId: sessionID,
                kind: kind,
                probable: probable
            )
        )
    }

    private static func smokeStatusURL() -> URL? {
#if DEBUG || SKYBRIDGE_TESTING
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
#else
        nil
#endif
    }

    private static func smokeUInt(_ value: UInt64?) -> String {
        value.map(String.init) ?? "-"
    }

    private static func smokeBool(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "true" : "false"
    }
}
