import CoreGraphics
import Foundation
import VideoToolbox

struct RemoteControlStreamRequest: Sendable, Equatable {
    let preferredSize: CGSize
    let preferredCodec: PreferredVideoCodec
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let lowLatencyMode: Bool
    let enableHardwareAcceleration: Bool
    let enableAppleSiliconOptimization: Bool
    let preserveExactVisibleSize: Bool
}

struct RemoteControlStreamPolicy: Sendable, Equatable {
    let codec: RemoteFrameType
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let preferredSize: CGSize
    let preserveExactVisibleSize: Bool
    let reason: String

    func protectingRealtimeAudio() -> RemoteControlStreamPolicy {
        let protectedFrameRate = min(targetFrameRate, Self.realtimeAudioProtectedFrameRate)
        let protectedSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            Self.sizeByCappingLongEdge(preferredSize, maxLongEdge: Self.realtimeAudioProtectedLongEdge),
            for: codec,
            preserveExactVisibleSize: preserveExactVisibleSize
        )
        guard protectedFrameRate != targetFrameRate || protectedSize != preferredSize else {
            return self
        }
        return RemoteControlStreamPolicy(
            codec: codec,
            targetFrameRate: protectedFrameRate,
            keyFrameInterval: min(keyFrameInterval, max(10, protectedFrameRate * 2)),
            preferredSize: protectedSize,
            preserveExactVisibleSize: preserveExactVisibleSize,
            reason: "\(reason)+audio-protect"
        )
    }

    private static let realtimeAudioProtectedFrameRate = 24
    private static let realtimeAudioProtectedLongEdge: CGFloat = 1_920

    private static func sizeByCappingLongEdge(_ size: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge.isFinite, longEdge > maxLongEdge, maxLongEdge > 0 else {
            return size
        }
        let scale = maxLongEdge / longEdge
        return CGSize(
            width: max(1, (size.width * scale).rounded(.down)),
            height: max(1, (size.height * scale).rounded(.down))
        )
    }
}

enum RemoteControlCaptureCompatibility {
    static func normalizedCaptureSize(
        _ requestedSize: CGSize,
        for codec: RemoteFrameType,
        preserveExactVisibleSize: Bool = false
    ) -> CGSize {
        if preserveExactVisibleSize {
            return CGSize(
                width: normalizedDimension(requestedSize.width, requiresEvenAlignment: false),
                height: normalizedDimension(requestedSize.height, requiresEvenAlignment: false)
            )
        }
        let requiresEvenAlignment = codec != .bgra
        return CGSize(
            width: normalizedDimension(requestedSize.width, requiresEvenAlignment: requiresEvenAlignment),
            height: normalizedDimension(requestedSize.height, requiresEvenAlignment: requiresEvenAlignment)
        )
    }

    static func fallbackCodec(afterEncodeFailure status: OSStatus, activeCodec: RemoteFrameType) -> RemoteFrameType? {
        switch (status, activeCodec) {
        case (kVTInvalidSessionErr, .hevc),
             (kVTVideoEncoderMalfunctionErr, .hevc),
             (kVTVideoEncoderNotAvailableNowErr, .hevc):
            return .h264
        case (kVTInvalidSessionErr, .h264),
             (kVTVideoEncoderMalfunctionErr, .h264),
             (kVTVideoEncoderNotAvailableNowErr, .h264):
            return .bgra
        default:
            return nil
        }
    }

    private static func normalizedDimension(_ rawValue: CGFloat, requiresEvenAlignment: Bool) -> CGFloat {
        let minimum = requiresEvenAlignment ? 2 : 1
        let sanitized = rawValue.isFinite ? rawValue : CGFloat(minimum)
        var dimension = max(minimum, Int(sanitized.rounded(.down)))
        if requiresEvenAlignment, !dimension.isMultiple(of: 2) {
            dimension -= 1
            if dimension < minimum {
                dimension = minimum
            }
        }
        return CGFloat(dimension)
    }
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
        let exactOddVisibleDimension = request.preserveExactVisibleSize
            && (Int(request.preferredSize.width.rounded(.down)).isMultiple(of: 2) == false
                || Int(request.preferredSize.height.rounded(.down)).isMultiple(of: 2) == false)

        if request.lowLatencyMode {
            if supportsH264 && !exactOddVisibleDimension {
                codec = .h264
                reason = "low-latency-h264"
            } else if supportsHEVC {
                codec = .hevc
                reason = exactOddVisibleDimension
                    ? "low-latency-hevc-exact-visible"
                    : "low-latency-hevc-fallback"
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
        } else if request.preferredCodec == .h264,
                  supportsHEVC,
                  supportsH264,
                  requestedFPS >= 55,
                  longEdge >= 2_000,
                  isAppleSilicon,
                  request.enableHardwareAcceleration,
                  request.enableAppleSiliconOptimization {
            codec = .hevc
            reason = "high-fps-lan-hevc-probe"
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

        let normalizedSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            request.preferredSize,
            for: codec,
            preserveExactVisibleSize: request.preserveExactVisibleSize
        )

        return RemoteControlStreamPolicy(
            codec: codec,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            preferredSize: normalizedSize,
            preserveExactVisibleSize: request.preserveExactVisibleSize,
            reason: reason
        )
    }
}
