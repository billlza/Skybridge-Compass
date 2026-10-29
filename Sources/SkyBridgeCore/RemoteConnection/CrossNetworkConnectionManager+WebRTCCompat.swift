import CoreGraphics
import Foundation
import SkyBridgeProtocolCore

@MainActor
extension CrossNetworkConnectionManager {
    #if os(macOS)
    static func webRTCHardwareCompatibleCaptureSize(
        _ size: CGSize,
        preferredCodec: PreferredVideoCodec,
        preserveExactVisibleSize: Bool = false
    ) -> CGSize {
        WebRTCRemoteDesktopVideoRequestFactory.hardwareCompatibleCaptureSize(
            size,
            preferredCodec: preferredCodec,
            preserveExactVisibleSize: preserveExactVisibleSize
        )
    }
    #endif

    static func supportedRemoteVideoFormats() -> [String] {
        WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats()
    }

    nonisolated static func remoteFrameFormatName(frameType: RemoteFrameType, payload: Data) -> String {
        switch frameType {
        case .hevc:
            return "hevc"
        case .h264:
            return "h264"
        case .bgra:
            if payload.count >= 2, payload[0] == 0xFF, payload[1] == 0xD8 {
                return "jpeg"
            }
            return "bgra"
        }
    }

    func appendSmokeStatus(_ line: String) {
        CrossNetworkWebRTCDiagnostics.appendSmokeStatus(line)
    }

    func appendRemoteMediaHeartbeatSmokeStatus(
        _ media: AppMessage.WebRTCMediaHeartbeatDiagnostics?,
        sessionID: String
    ) {
        CrossNetworkWebRTCDiagnostics.appendRemoteMediaHeartbeatSmokeStatus(media, sessionID: sessionID)
    }

    func appendWebRTCSessionDiagnostic(_ line: String, sessionID: String) {
        Self.writeWebRTCSessionDiagnostic(line, sessionID: sessionID)
    }

    nonisolated static func writeWebRTCSessionDiagnostic(_ line: String, sessionID: String) {
        CrossNetworkWebRTCDiagnostics.writeSessionDiagnostic(line, sessionID: sessionID)
    }

    func sanitizeStatus(_ value: String) -> String {
        CrossNetworkWebRTCDiagnostics.sanitizeStatus(value)
    }

    static func describeWebRTCScreenPayloadMagic(_ payload: Data) -> String {
        CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(payload)
    }
}
