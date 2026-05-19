import Foundation
import CryptoKit
import SkyBridgeRealtimeMedia

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    nonisolated static func lanRealtimeMediaSessionId(for keys: SessionKeys) -> String {
        var material = Data("skybridge-lan-remote-media-session-v1".utf8)
        material.append(keys.transcriptHash)
        let digest = SHA256.hash(data: material)
        let prefix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "lan-rc-\(prefix)"
    }

    nonisolated static func fallbackRemoteAudioUnlockAt(
        activeTransportModeIsCrossNetwork: Bool,
        nativeAudioReceiveEnabled: Bool,
        remoteAudioTrackHasReceivedFirstPacket: Bool,
        currentUnlockAt: Date?,
        now: Date
    ) -> Date? {
        RemoteAudioPlaybackPolicy.fallbackUnlockAt(
            activeTransportModeIsCrossNetwork: activeTransportModeIsCrossNetwork,
            nativeAudioReceiveEnabled: nativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: remoteAudioTrackHasReceivedFirstPacket,
            currentUnlockAt: currentUnlockAt,
            now: now
        )
    }

    nonisolated static func remoteAudioPlaybackRetryDelay(for error: NSError) -> TimeInterval {
        RemoteAudioPlaybackPolicy.retryDelay(for: error)
    }

    nonisolated static func isUsableRealtimeMediaAudioEndpoint(
        _ endpoint: SkyBridgeMediaEndpoint,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = 10
    ) -> Bool {
        guard let expiresAt = endpoint.expiresAt else { return true }
        return expiresAt - now.timeIntervalSince1970 > minimumRemainingTime
    }

    nonisolated static func isSameRealtimeMediaRelayAddress(
        _ lhs: SkyBridgeMediaEndpoint,
        _ rhs: SkyBridgeMediaEndpoint
    ) -> Bool {
        lhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && lhs.port == rhs.port
    }

    nonisolated static func shouldIgnoreFallbackFrameAfterNativeVideoRendered(
        activeTransportModeIsCrossNetwork: Bool,
        nativeVideoTrackHasRenderedFrame: Bool
    ) -> Bool {
        activeTransportModeIsCrossNetwork && nativeVideoTrackHasRenderedFrame
    }

    nonisolated static func shouldDropNativeWarmupNonJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: Bool,
        hasRemoteNativeVideoTrack: Bool,
        nativeVideoTrackHasRenderedFrame: Bool,
        format: String?
    ) -> Bool {
        guard activeTransportModeIsCrossNetwork,
              hasRemoteNativeVideoTrack,
              !nativeVideoTrackHasRenderedFrame else {
            return false
        }
        _ = format
        return true
    }

    nonisolated static func shouldUseJPEGOnlyFallbackDuringNativeWarmup(
        activeTransportModeIsCrossNetwork: Bool,
        hasRemoteNativeVideoTrack: Bool,
        nativeVideoTrackHasRenderedFrame: Bool
    ) -> Bool {
        _ = activeTransportModeIsCrossNetwork
        _ = hasRemoteNativeVideoTrack
        _ = nativeVideoTrackHasRenderedFrame
        return false
    }

    nonisolated static func shouldRequestExtremeMediaValidation(
        activeTransportModeIsCrossNetwork: Bool,
        viewerSettings: RemoteDesktopViewerSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
            || activeTransportModeIsCrossNetwork
    }

    nonisolated static func shouldProcessCrossNetworkFrameNotification(
        isStreaming: Bool,
        subscribedSessionId: String?,
        expectedSessionId: String,
        updateSessionId: String
    ) -> Bool {
        guard isStreaming else { return false }
        guard subscribedSessionId == expectedSessionId else { return false }
        return updateSessionId == expectedSessionId
    }

    static func shouldAnnounceCrossNetworkNativeVideoReady(
        activeTransportModeIsCrossNetwork: Bool,
        hasCurrentConnection: Bool,
        hasRenderedNativeFrame: Bool,
        lastSentNativeVideoTrackReady: Bool,
        force: Bool,
        lastAnnouncementAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = 0.5
    ) -> Bool {
        guard activeTransportModeIsCrossNetwork, hasCurrentConnection, hasRenderedNativeFrame else {
            return false
        }
        if !force && lastSentNativeVideoTrackReady {
            return false
        }
        if !force,
           let lastAnnouncementAt,
           now.timeIntervalSince(lastAnnouncementAt) < minimumInterval {
            return false
        }
        return true
    }

    static func advertisedCrossNetworkNativeVideoReadyFlag(
        activeTransportModeIsCrossNetwork: Bool,
        hasRenderedNativeFrame: Bool
    ) -> Bool? {
        guard activeTransportModeIsCrossNetwork else { return nil }
        return hasRenderedNativeFrame
    }
}
