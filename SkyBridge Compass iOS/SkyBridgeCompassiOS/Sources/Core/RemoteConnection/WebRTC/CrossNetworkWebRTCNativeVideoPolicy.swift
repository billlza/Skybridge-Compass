import CoreGraphics
import Foundation

#if canImport(WebRTC)
import WebRTC
#endif

enum CrossNetworkWebRTCNativeVideoPolicy {
    struct VisibleFrameNormalization: Equatable {
        let visibleSize: CGSize
        let usedEvenPadding: Bool
    }

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

#if DEBUG || SKYBRIDGE_TESTING
    static func requestedSmokeNativeVideoVisibleFrameSize() -> CGSize? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
#endif

    static func normalizedVisibleFrameSize(
        forCodedSize codedSize: CGSize,
        expectedVisibleSize: CGSize?
    ) -> VisibleFrameNormalization {
        guard let expectedVisibleSize else {
            return VisibleFrameNormalization(visibleSize: codedSize, usedEvenPadding: false)
        }
        let expectedWidth = Int(expectedVisibleSize.width)
        let expectedHeight = Int(expectedVisibleSize.height)
        guard expectedWidth > 0, expectedHeight > 0 else {
            return VisibleFrameNormalization(visibleSize: codedSize, usedEvenPadding: false)
        }
        let codedWidth = Int(codedSize.width)
        let codedHeight = Int(codedSize.height)
        let expectedCodedWidth = evenNativeVideoBackingDimension(expectedWidth)
        let expectedCodedHeight = evenNativeVideoBackingDimension(expectedHeight)
        if codedWidth == expectedCodedWidth, codedHeight == expectedCodedHeight {
            return VisibleFrameNormalization(
                visibleSize: expectedVisibleSize,
                usedEvenPadding: expectedCodedWidth != expectedWidth || expectedCodedHeight != expectedHeight
            )
        }
        if codedWidth == expectedWidth, codedHeight == expectedHeight {
            return VisibleFrameNormalization(visibleSize: expectedVisibleSize, usedEvenPadding: false)
        }
        return VisibleFrameNormalization(visibleSize: codedSize, usedEvenPadding: false)
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

    static func allowsTrackRender(
        isAdmitted: Bool,
        currentTrackID: String?,
        renderedTrackID: String,
        currentRenderEpoch: UInt64,
        renderedEpoch: UInt64
    ) -> Bool {
        guard isAdmitted,
              currentRenderEpoch == renderedEpoch,
              let currentTrackID,
              !currentTrackID.isEmpty,
              currentTrackID == renderedTrackID else {
            return false
        }
        return true
    }

#if DEBUG || SKYBRIDGE_TESTING
    private static func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }
#endif
}
