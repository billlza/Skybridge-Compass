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
        guard transportPath == .direct else {
            return jpegFallback(
                request: request,
                reason: transportPath == .relay ? "relay-jpeg-conservative" : "unknown-path-jpeg-safe"
            )
        }

        let directPolicy = RemoteControlStreamPolicySelector.select(
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

        guard directPolicy.codec != .bgra else {
            return jpegFallback(
                request: request,
                reason: "direct-\(directPolicy.reason)"
            )
        }

        return WebRTCRemoteDesktopVideoPolicy(
            codec: directPolicy.codec,
            targetFrameRate: directPolicy.targetFrameRate,
            keyFrameInterval: directPolicy.keyFrameInterval,
            preferredSize: directPolicy.preferredSize,
            usesHardwareEncoder: true,
            reason: "direct-\(directPolicy.reason)"
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
