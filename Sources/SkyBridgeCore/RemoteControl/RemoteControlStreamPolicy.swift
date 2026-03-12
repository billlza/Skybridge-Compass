import CoreGraphics
import Foundation

struct RemoteControlStreamRequest: Sendable, Equatable {
    let preferredSize: CGSize
    let preferredCodec: PreferredVideoCodec
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let lowLatencyMode: Bool
    let enableHardwareAcceleration: Bool
    let enableAppleSiliconOptimization: Bool
}

struct RemoteControlStreamPolicy: Sendable, Equatable {
    let codec: RemoteFrameType
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let preferredSize: CGSize
    let reason: String
}

enum RemoteControlStreamPolicySelector {
    static func select(
        request: RemoteControlStreamRequest,
        peerFormats: Set<String>,
        thermalState: ProcessInfo.ThermalState,
        isAppleSilicon: Bool
    ) -> RemoteControlStreamPolicy {
        let normalizedFormats = Set(peerFormats.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let requestedFPS = max(12, min(request.targetFrameRate, 120))
        let longEdge = Int(max(request.preferredSize.width, request.preferredSize.height))

        let codec: RemoteFrameType
        let reason: String

        let peerFormatsUnknown = normalizedFormats.isEmpty
        let supportsJPEG = peerFormatsUnknown || normalizedFormats.contains("jpeg")
        let supportsH264 = peerFormatsUnknown || normalizedFormats.contains("h264")
        let supportsHEVC = normalizedFormats.contains("hevc")

        if request.lowLatencyMode {
            if supportsH264 {
                codec = .h264
                reason = "low-latency-h264"
            } else if supportsHEVC {
                codec = .hevc
                reason = "low-latency-hevc-fallback"
            } else if supportsJPEG {
                codec = .bgra
                reason = "low-latency-jpeg-compat"
            } else {
                codec = .bgra
                reason = "low-latency-unknown-peer"
            }
        } else if request.preferredCodec == .hevc && supportsHEVC {
            codec = .hevc
            reason = "peer-hevc-supported"
        } else if request.preferredCodec == .h264 && supportsH264 {
            codec = .h264
            reason = "peer-h264-supported"
        } else if longEdge >= 3840 && supportsHEVC {
            codec = .hevc
            reason = "high-resolution-hevc"
        } else if supportsH264 {
            codec = .h264
            reason = "fallback-h264"
        } else if supportsHEVC {
            codec = .hevc
            reason = "fallback-hevc"
        } else if supportsJPEG {
            codec = .bgra
            reason = "legacy-jpeg-compat"
        } else {
            codec = .bgra
            reason = "unknown-peer-compat"
        }

        var fpsCap = requestedFPS
        switch codec {
        case .bgra:
            if longEdge >= 5120 {
                fpsCap = min(fpsCap, 15)
            } else if longEdge >= 3840 {
                fpsCap = min(fpsCap, 20)
            } else {
                fpsCap = min(fpsCap, 30)
            }
        case .h264:
            fpsCap = min(fpsCap, 60)
        case .hevc:
            if longEdge >= 5120 {
                fpsCap = min(
                    fpsCap,
                    isAppleSilicon && request.enableHardwareAcceleration && request.enableAppleSiliconOptimization ? 120 : 60
                )
            } else if longEdge >= 3840 {
                fpsCap = min(fpsCap, isAppleSilicon ? 90 : 60)
            }
        }

        if !request.enableHardwareAcceleration {
            fpsCap = min(fpsCap, codec == .bgra ? 20 : 30)
        }
        if !request.enableAppleSiliconOptimization {
            fpsCap = min(fpsCap, 60)
        }

        switch thermalState {
        case .nominal:
            break
        case .fair:
            fpsCap = min(fpsCap, longEdge >= 5120 ? 90 : 60)
        case .serious:
            fpsCap = min(fpsCap, longEdge >= 3840 ? 45 : 60)
        case .critical:
            fpsCap = min(fpsCap, 24)
        @unknown default:
            fpsCap = min(fpsCap, 30)
        }

        let targetFrameRate = max(12, min(requestedFPS, fpsCap))
        let keyFrameCeiling = request.lowLatencyMode
            ? max(15, targetFrameRate / 2)
            : max(30, targetFrameRate * 2)
        let keyFrameInterval = max(10, min(request.keyFrameInterval, keyFrameCeiling))

        return RemoteControlStreamPolicy(
            codec: codec,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            preferredSize: request.preferredSize,
            reason: reason
        )
    }
}
