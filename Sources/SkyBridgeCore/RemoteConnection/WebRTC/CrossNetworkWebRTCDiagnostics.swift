import Foundation
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

enum CrossNetworkWebRTCDiagnostics {
    static func appendSmokeStatus(_ line: String) {
        guard let statusURL = smokeStatusURL() else { return }
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = rendered.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: statusURL.path
            )
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
        let safeSessionID = sessionID
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeSessionID.isEmpty else { return }
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("webrtc-session-\(safeSessionID).log")
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = rendered.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        }
#else
        _ = line
        _ = sessionID
#endif
    }

    static func sanitizeStatus(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

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
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func smokeUInt(_ value: UInt64?) -> String {
        value.map(String.init) ?? "-"
    }

    private static func smokeBool(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "true" : "false"
    }
}
