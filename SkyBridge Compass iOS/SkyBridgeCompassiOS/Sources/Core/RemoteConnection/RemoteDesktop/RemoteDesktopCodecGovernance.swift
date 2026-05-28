//
//  RemoteDesktopCodecGovernance.swift
//  SkyBridgeCompassiOS
//

import Foundation
import VideoToolbox

enum RemoteDesktopCodecGovernanceEvent: Sendable, Equatable {
    case none
    case requestRefresh
    case failFastHEVC(reason: String)
    case reenableHEVCProbe
}

struct RemoteDesktopCodecGovernance: Sendable, Equatable {
    private(set) var hevcFailureStreak: Int = 0
    private(set) var hevcDisabledUntil: Date?
    private(set) var hevcDisableCount: Int = 0
    private(set) var stableFallbackFrameCount: Int = 0

    mutating func noteDecodeSuccess(format: String, at now: Date) -> RemoteDesktopCodecGovernanceEvent {
        let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "hevc" {
            hevcFailureStreak = 0
            stableFallbackFrameCount = 0
            return .none
        }

        return .none
    }

    mutating func noteDecodeFailure(
        format: String,
        reason: String?,
        at now: Date
    ) -> RemoteDesktopCodecGovernanceEvent {
        let normalizedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedFormat == "hevc" else { return .none }

        let normalizedReason = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        stableFallbackFrameCount = 0

        if normalizedReason.contains("waiting-for-sync-frame") {
            hevcFailureStreak += 1
            guard hevcFailureStreak >= 3 else {
                return .requestRefresh
            }

            hevcDisableCount += 1
            stableFallbackFrameCount = 0
            return .failFastHEVC(reason: normalizedReason.isEmpty ? "waiting-for-sync-frame" : normalizedReason)
        }

        hevcFailureStreak += 1
        guard hevcFailureStreak >= 3 else { return .none }

        hevcDisableCount += 1
        stableFallbackFrameCount = 0
        return .failFastHEVC(reason: normalizedReason.isEmpty ? "hevc-decode-failed" : normalizedReason)
    }

    func effectiveSupportedFormats(from formats: [String], at now: Date) -> [String] {
        guard let disabledUntil = hevcDisabledUntil,
              now < disabledUntil else {
            return formats
        }

        return formats.filter { $0.lowercased() != "hevc" }
    }

    func effectivePreferredCodec(
        userPreference: RemoteDesktopViewerCodec,
        supportedFormats: [String],
        at now: Date
    ) -> String? {
        let effectiveFormats = effectiveSupportedFormats(from: supportedFormats, at: now)
        let hevcDisabled = effectiveFormats.contains("hevc") == false && supportedFormats.contains("hevc")

        if hevcDisabled {
            switch userPreference {
            case .automatic, .hevc:
                if effectiveFormats.contains("jpeg") {
                    return "jpeg"
                }
            case .h264, .jpeg:
                break
            }
        }

        return userPreference.resolvedWireValue(supportedFormats: effectiveFormats)
    }
}

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    public static func supportedRemoteVideoFormats() -> [String] {
        var formats = ["jpeg"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            formats.insert("hevc", at: 0)
        }
        var seen: Set<String> = []
        return formats.filter { seen.insert($0).inserted }
    }
}
