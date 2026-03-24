import CoreGraphics
import Foundation

struct WebRTCRemoteDesktopVideoRequest: Sendable, Equatable {
    let preferredSize: CGSize
    let preferredCodec: PreferredVideoCodec
    let requestedFrameRate: Int
    let keyFrameInterval: Int
    let lowLatencyMode: Bool
    let enableHardwareAcceleration: Bool
    let enableAppleSiliconOptimization: Bool
}

struct WebRTCRemoteDesktopVideoPolicy: Sendable, Equatable {
    let codec: RemoteFrameType
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let preferredSize: CGSize
    let usesHardwareEncoder: Bool
    let reason: String
}

enum WebRTCRemoteDesktopVideoPolicySelector {
    static func select(
        request: WebRTCRemoteDesktopVideoRequest,
        transportPath: WebRTCSession.ICETransportPath,
        peerFormats: Set<String>,
        thermalState: ProcessInfo.ThermalState,
        isAppleSilicon: Bool
    ) -> WebRTCRemoteDesktopVideoPolicy {
        let basePolicy = RemoteControlStreamPolicySelector.select(
            request: .init(
                preferredSize: request.preferredSize,
                preferredCodec: request.preferredCodec,
                targetFrameRate: request.requestedFrameRate,
                keyFrameInterval: request.keyFrameInterval,
                lowLatencyMode: request.lowLatencyMode,
                enableHardwareAcceleration: request.enableHardwareAcceleration,
                enableAppleSiliconOptimization: request.enableAppleSiliconOptimization
            ),
            peerFormats: peerFormats,
            thermalState: thermalState,
            isAppleSilicon: isAppleSilicon
        )

        guard transportPath == .direct else {
            return WebRTCRemoteDesktopVideoPolicy(
                codec: .bgra,
                targetFrameRate: max(4, min(request.requestedFrameRate, transportPath == .relay ? 15 : 24)),
                keyFrameInterval: max(10, min(request.keyFrameInterval, max(30, request.requestedFrameRate * 2))),
                preferredSize: conservativePreferredSize(
                    for: request.preferredSize,
                    transportPath: transportPath
                ),
                usesHardwareEncoder: false,
                reason: transportPath == .relay ? "relay-jpeg-conservative" : "unknown-path-jpeg-safe"
            )
        }

        guard basePolicy.codec != .bgra else {
            return jpegFallback(
                request: request,
                reason: "direct-\(basePolicy.reason)"
            )
        }

        return WebRTCRemoteDesktopVideoPolicy(
            codec: basePolicy.codec,
            targetFrameRate: basePolicy.targetFrameRate,
            keyFrameInterval: basePolicy.keyFrameInterval,
            preferredSize: basePolicy.preferredSize,
            usesHardwareEncoder: true,
            reason: "direct-\(basePolicy.reason)"
        )
    }

    private static func conservativePreferredSize(
        for preferredSize: CGSize,
        transportPath: WebRTCSession.ICETransportPath
    ) -> CGSize {
        guard preferredSize.width > 0, preferredSize.height > 0 else {
            return preferredSize
        }

        let longEdgeLimit: CGFloat
        switch transportPath {
        case .relay:
            longEdgeLimit = 1920
        case .unknown:
            longEdgeLimit = 2560
        case .direct:
            return preferredSize
        }

        let longEdge = max(preferredSize.width, preferredSize.height)
        guard longEdge > longEdgeLimit else { return preferredSize }

        let scale = longEdgeLimit / longEdge
        return CGSize(
            width: max(960, floor(preferredSize.width * scale)),
            height: max(540, floor(preferredSize.height * scale))
        )
    }

    private static func jpegFallback(
        request: WebRTCRemoteDesktopVideoRequest,
        reason: String
    ) -> WebRTCRemoteDesktopVideoPolicy {
        let requestedFrameRate = max(4, min(request.requestedFrameRate, 120))
        let keyFrameInterval = max(10, min(request.keyFrameInterval, max(30, requestedFrameRate * 2)))
        return WebRTCRemoteDesktopVideoPolicy(
            codec: .bgra,
            targetFrameRate: requestedFrameRate,
            keyFrameInterval: keyFrameInterval,
            preferredSize: request.preferredSize,
            usesHardwareEncoder: false,
            reason: reason
        )
    }
}
