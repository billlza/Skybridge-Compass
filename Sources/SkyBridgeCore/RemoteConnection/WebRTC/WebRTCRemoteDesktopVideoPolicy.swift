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
    let preserveExactVisibleSize: Bool

    init(
        preferredSize: CGSize,
        preferredCodec: PreferredVideoCodec,
        requestedFrameRate: Int,
        keyFrameInterval: Int,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool,
        preserveExactVisibleSize: Bool = false
    ) {
        self.preferredSize = preferredSize
        self.preferredCodec = preferredCodec
        self.requestedFrameRate = requestedFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.lowLatencyMode = lowLatencyMode
        self.enableHardwareAcceleration = enableHardwareAcceleration
        self.enableAppleSiliconOptimization = enableAppleSiliconOptimization
        self.preserveExactVisibleSize = preserveExactVisibleSize
    }
}

struct WebRTCRemoteDesktopVideoPolicy: Sendable, Equatable {
    let codec: RemoteFrameType
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let preferredSize: CGSize
    let usesHardwareEncoder: Bool
    let reason: String

    func protectingRealtimeAudio() -> WebRTCRemoteDesktopVideoPolicy {
        let protectedPolicy = RemoteControlStreamPolicy(
            codec: codec,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            preferredSize: preferredSize,
            preserveExactVisibleSize: false,
            reason: reason
        ).protectingRealtimeAudio()
        guard protectedPolicy.codec != codec
            || protectedPolicy.targetFrameRate != targetFrameRate
            || protectedPolicy.keyFrameInterval != keyFrameInterval
            || protectedPolicy.preferredSize != preferredSize
            || protectedPolicy.reason != reason else {
            return self
        }
        return WebRTCRemoteDesktopVideoPolicy(
            codec: protectedPolicy.codec,
            targetFrameRate: protectedPolicy.targetFrameRate,
            keyFrameInterval: protectedPolicy.keyFrameInterval,
            preferredSize: protectedPolicy.preferredSize,
            usesHardwareEncoder: usesHardwareEncoder,
            reason: protectedPolicy.reason
        )
    }
}

struct WebRTCDegradedFallbackJPEGProfile: Sendable, Equatable {
    static let maxLongEdge = 1280
    static let secondaryLongEdge = 960
    static let targetFrameRate = 12
    static let maxEncodedFrameBytes = 160 * 1024
    static let maxTransportFrameBytes = 256 * 1024
    static let qualityLadder: [CGFloat] = [0.65, 0.50, 0.40]

    let maxLongEdge: Int
    let targetFrameRate: Int
    let maxEncodedFrameBytes: Int
    let maxTransportFrameBytes: Int
    let qualityLadder: [CGFloat]

    static let emergency = WebRTCDegradedFallbackJPEGProfile(
        maxLongEdge: maxLongEdge,
        targetFrameRate: targetFrameRate,
        maxEncodedFrameBytes: maxEncodedFrameBytes,
        maxTransportFrameBytes: maxTransportFrameBytes,
        qualityLadder: qualityLadder
    )

    func constrainedSize(for size: CGSize) -> CGSize {
        Self.constrainedSize(for: size, maxLongEdge: maxLongEdge)
    }

    static func constrainedSize(for size: CGSize, maxLongEdge: Int) -> CGSize {
        guard size.width > 0, size.height > 0, maxLongEdge > 0 else {
            return size
        }
        let sourceLongEdge = max(size.width, size.height)
        guard sourceLongEdge > CGFloat(maxLongEdge) else { return size }
        let scale = CGFloat(maxLongEdge) / sourceLongEdge
        return CGSize(
            width: max(2, floor(size.width * scale)),
            height: max(2, floor(size.height * scale))
        )
    }
}

enum WebRTCRemoteDesktopVideoPolicySelector {
    static func degradedFallbackPolicy(
        from policy: WebRTCRemoteDesktopVideoPolicy,
        profile: WebRTCDegradedFallbackJPEGProfile = .emergency,
        reasonSuffix: String = "degraded-emergency-jpeg"
    ) -> WebRTCRemoteDesktopVideoPolicy {
        WebRTCRemoteDesktopVideoPolicy(
            codec: .bgra,
            targetFrameRate: min(policy.targetFrameRate, profile.targetFrameRate),
            keyFrameInterval: max(10, min(policy.keyFrameInterval, profile.targetFrameRate * 2)),
            preferredSize: profile.constrainedSize(for: policy.preferredSize),
            usesHardwareEncoder: false,
            reason: "\(policy.reason)+\(reasonSuffix)"
        )
    }

    static func select(
        request: WebRTCRemoteDesktopVideoRequest,
        transportPath: WebRTCSession.ICETransportPath,
        peerFormats: Set<String>,
        thermalState: ProcessInfo.ThermalState,
        isAppleSilicon: Bool,
        nativeVideoTrackEnabled: Bool = false
    ) -> WebRTCRemoteDesktopVideoPolicy {
        let basePolicy = RemoteControlStreamPolicySelector.select(
            request: .init(
                preferredSize: request.preferredSize,
                preferredCodec: request.preferredCodec,
                targetFrameRate: request.requestedFrameRate,
                keyFrameInterval: request.keyFrameInterval,
                lowLatencyMode: request.lowLatencyMode,
                enableHardwareAcceleration: request.enableHardwareAcceleration,
                enableAppleSiliconOptimization: request.enableAppleSiliconOptimization,
                preserveExactVisibleSize: request.preserveExactVisibleSize,
                preferredDisplayID: nil // 显示器选择不影响 WebRTC 视频编解码/尺寸策略
            ),
            peerFormats: peerFormats,
            thermalState: thermalState,
            isAppleSilicon: isAppleSilicon
        )

        guard transportPath == .direct else {
            if nativeVideoTrackEnabled, basePolicy.codec != .bgra {
                let highFrameRateNativeStream = request.lowLatencyMode || request.requestedFrameRate >= 59
                return WebRTCRemoteDesktopVideoPolicy(
                    codec: basePolicy.codec,
                    targetFrameRate: basePolicy.targetFrameRate,
                    keyFrameInterval: basePolicy.keyFrameInterval,
                    preferredSize: nativeRTPPreferredSize(
                        for: request.preferredSize,
                        transportPath: transportPath,
                        highFrameRate: highFrameRateNativeStream
                    ),
                    usesHardwareEncoder: true,
                    reason: "\(transportPath == .relay ? "relay" : "unknown-path")-native-rtp-\(basePolicy.reason)"
                )
            }
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

    private static func nativeRTPPreferredSize(
        for preferredSize: CGSize,
        transportPath: WebRTCSession.ICETransportPath,
        highFrameRate: Bool
    ) -> CGSize {
        guard preferredSize.width > 0, preferredSize.height > 0 else {
            return preferredSize
        }
        guard transportPath == .relay else {
            return conservativePreferredSize(for: preferredSize, transportPath: transportPath)
        }
        let longEdgeLimit: CGFloat = highFrameRate ? 2560 : 1920
        let longEdge = max(preferredSize.width, preferredSize.height)
        guard longEdge > longEdgeLimit else { return preferredSize }
        let scale = longEdgeLimit / longEdge
        return CGSize(
            width: max(960, floor(preferredSize.width * scale)),
            height: max(540, floor(preferredSize.height * scale))
        )
    }
}
