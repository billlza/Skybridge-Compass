import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

enum WebRTCNativeScreenVideoValuePolicy {
    static func recommendedBitrateBps(
        width: Int,
        height: Int,
        fps: Int
    ) -> Int {
        let clampedWidth = max(1, width)
        let clampedHeight = max(1, height)
        let clampedFPS = max(1, fps)
        let pixelsPerSecond = Double(clampedWidth) * Double(clampedHeight) * Double(clampedFPS)
        let target = Int((pixelsPerSecond * 0.18).rounded())
        return max(8_000_000, min(85_000_000, target))
    }

    static func minimumExtremeBitrateBps(
        width: Int,
        height: Int,
        fps: Int
    ) -> UInt64 {
        let recommended = recommendedBitrateBps(
            width: width,
            height: height,
            fps: fps
        )
        return UInt64(max(8_000_000, (recommended * 3) / 5))
    }

    static let extremeH264SDPWidth = 2_056
    static let extremeH264SDPHeight = 1_329
    static let extremeH264SDPFPS = 60
    static let extremeH264LevelHex = "33"

    static var extremeH264MaxFS: Int {
        h264MacroblockFrameSize(
            width: extremeH264SDPWidth,
            height: extremeH264SDPHeight
        )
    }

    static var extremeH264MaxMBPS: Int {
        extremeH264MaxFS * extremeH264SDPFPS
    }

    static func h264MacroblockFrameSize(width: Int, height: Int) -> Int {
        let clampedWidth = max(1, width)
        let clampedHeight = max(1, height)
        let macroblockWidth = (clampedWidth + 15) / 16
        let macroblockHeight = (clampedHeight + 15) / 16
        return macroblockWidth * macroblockHeight
    }

    static func h264SDPConstraintsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    static func evenBackingDimension(_ visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    static func codecPreferenceRank(_ codecName: String) -> Int {
        let normalized = codecName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("h265") || normalized.contains("hevc") {
            return 0
        }
        if normalized.contains("h264") || normalized.contains("avc") {
            return 1
        }
        if normalized == "vp8"
            || normalized == "vp9"
            || normalized == "av1"
            || normalized.contains("vp8")
            || normalized.contains("vp9")
            || normalized.contains("av1")
            || normalized.contains("vpx") {
            return 10
        }
        return 5
    }

    static func codecIsHardwarePreferred(_ codecName: String) -> Bool {
        let normalized = codecName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("h264")
            || normalized.contains("avc")
            || normalized.contains("h265")
            || normalized.contains("hevc")
    }

    static func codecIsRTX(_ codecName: String) -> Bool {
        codecName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtx"
    }

    /// Secondary ordering key for two H264 codec entries that tie on `codecPreferenceRank`.
    ///
    /// The macOS-host WebRTC VideoToolbox encoder will not bring up a Constrained-High
    /// (`profile-idc=0x64`, e.g. `640c1f`) H264 stream — it stays at framesEncoded=0.
    /// Constrained Baseline (`profile-idc=0x42`, e.g. `42e01f`) starts cleanly. The
    /// `profile-level-id` is six hex chars: the first two are the `profile-idc`. Lower
    /// rank sorts first, so Baseline (`42`) precedes Main (`4d`) precedes High (`64`).
    /// Entries without a parseable `profile-level-id` sort after the recognized ones but
    /// keep their relative order via the stable sort's offset tiebreak.
    static func h264ProfilePreferenceRank(profileLevelID: String?) -> Int {
        guard let profileLevelID else { return 3 }
        let cleaned = profileLevelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count >= 2 else { return 3 }
        let profileIDC = String(cleaned.prefix(2))
        switch profileIDC {
        case "42": // Baseline / Constrained Baseline — encoder starts cleanly.
            return 0
        case "4d": // Main — acceptable middle ground.
            return 1
        case "64": // High / Constrained High — encoder won't bring it up; demote.
            return 2
        default:
            return 3
        }
    }

#if canImport(WebRTC)
    static func preferredHardwareVideoEncoderCodec(
        from supportedCodecs: [RTCVideoCodecInfo] = RTCDefaultVideoEncoderFactory.supportedCodecs()
    ) -> RTCVideoCodecInfo? {
        supportedCodecs
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = encoderCodecPreferenceRank(lhs.element.name)
                let rhsRank = encoderCodecPreferenceRank(rhs.element.name)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .first { encoderCodecPreferenceRank($0.name) < 10 }
    }

    static func encoderCodecPreferenceRank(_ codecName: String) -> Int {
        let normalized = codecName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("h265") || normalized.contains("hevc") {
            return 0
        }
        if normalized.contains("h264") || normalized.contains("avc") {
            return 1
        }
        return 10
    }

    static func codecPreferences(from codecs: [RTCRtpCodecCapability]) -> [RTCRtpCodecCapability] {
        let sorted = codecs.enumerated().sorted { lhs, rhs in
            let lhsRank = codecPreferenceRank(lhs.element.name)
            let rhsRank = codecPreferenceRank(rhs.element.name)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            // Secondary key: among tied H264 entries, prefer Constrained Baseline
            // (`profile-level-id` starting `42`) over High (`640c`). The family-level
            // ordering above is untouched; this only reorders within H264.
            if lhsRank == codecPreferenceRank("h264"),
               codecIsHardwarePreferred(lhs.element.name),
               codecIsHardwarePreferred(rhs.element.name) {
                let lhsProfileRank = h264ProfilePreferenceRank(
                    profileLevelID: lhs.element.parameters["profile-level-id"]
                )
                let rhsProfileRank = h264ProfilePreferenceRank(
                    profileLevelID: rhs.element.parameters["profile-level-id"]
                )
                if lhsProfileRank != rhsProfileRank {
                    return lhsProfileRank < rhsProfileRank
                }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let hardwarePreferredPrimary = sorted.filter {
            codecIsHardwarePreferred($0.name)
        }
        guard !hardwarePreferredPrimary.isEmpty else { return sorted }

        let hardwarePayloadTypes = Set(
            hardwarePreferredPrimary.compactMap { $0.preferredPayloadType?.stringValue }
        )
        return sorted.filter { codec in
            if codecIsHardwarePreferred(codec.name) {
                return true
            }
            guard codecIsRTX(codec.name) else {
                return false
            }
            guard let apt = codec.parameters["apt"], !hardwarePayloadTypes.isEmpty else {
                return true
            }
            return hardwarePayloadTypes.contains(apt)
        }
    }
#endif
}
