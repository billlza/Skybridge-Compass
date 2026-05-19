import CoreGraphics
import Foundation

#if canImport(WebRTC)
import WebRTC
#endif

enum CrossNetworkWebRTCNativeVideoPolicy {
#if canImport(WebRTC)
    static func remoteVideoTracksShareNativeBacking(_ lhs: RTCVideoTrack?, _ rhs: RTCVideoTrack?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // RTCRtpReceiver.track may vend a fresh wrapper on each read; WebRTC requires isEqual for backing identity.
            return lhs === rhs || lhs.isEqual(rhs)
        default:
            return false
        }
    }
#endif

    static func requestedSmokeNativeVideoVisibleFrameSize() -> CGSize? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    static func evenNativeVideoBackingDimension(_ visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    static func isActualNativeRenderEvidence(source: String) -> Bool {
        switch source {
        case "rtc-mtl-video-view":
            return true
        default:
            return false
        }
    }

    private static func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }
}
