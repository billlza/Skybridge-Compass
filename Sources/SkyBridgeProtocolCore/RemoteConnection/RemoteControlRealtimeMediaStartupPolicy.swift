import Foundation

public enum RemoteControlRealtimeMediaStartupFailureAction: Sendable, Equatable {
    case failSession
    case preserveVideo
}

/// Stable, role-neutral startup failures shared by Apple remote-control media
/// adapters. Transport-specific failures remain in the realtime-media module;
/// these cases describe missing authenticated prerequisites and topology.
public enum RemoteControlRealtimeMediaStartupError: String, Error, Sendable, Equatable {
    case missingAuthenticatedMediaSessionKeys = "missing_authenticated_media_session_keys"
    case missingAuthenticatedMediaAudioEndpoint = "missing_authenticated_media_audio_endpoint"
    case relayLeaseUnavailable = "relay_lease_unavailable"
    case transportUnavailable = "transport_unavailable"

    public var stableCode: String { rawValue }
}

/// One shared fail-closed decision for Apple remote-control media adapters.
/// Transport roles may differ, but the same requested media contract must
/// produce the same failure action on macOS and iOS.
public enum RemoteControlRealtimeMediaStartupPolicy {
    public static func failureAction(
        strictMediaFallbacks: Bool,
        audioRedirectionEnabled: Bool,
        realtimeMediaAudioRequested: Bool,
        legacyAudioFallbackEnabled: Bool
    ) -> RemoteControlRealtimeMediaStartupFailureAction {
        if strictMediaFallbacks,
           audioRedirectionEnabled,
           realtimeMediaAudioRequested,
           !legacyAudioFallbackEnabled {
            return .failSession
        }
        return .preserveVideo
    }

    public static func forbidsFallback(
        performanceValidationMode: String?,
        mediaFallbackPolicy: String?
    ) -> Bool {
        switch normalized(performanceValidationMode) {
        case "extreme", "strict", "strict-extreme", "2k60", "4k60", "performance-acceptance":
            return true
        default:
            break
        }
        switch normalized(mediaFallbackPolicy) {
        case "fail-fast", "disabled", "forbidden":
            return true
        default:
            return false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
