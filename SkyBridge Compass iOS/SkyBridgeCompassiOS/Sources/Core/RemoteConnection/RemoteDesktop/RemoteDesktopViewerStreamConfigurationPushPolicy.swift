import Foundation
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
enum RemoteDesktopViewerStreamConfigurationPushPolicy {
    struct AcknowledgementExpectation: Equatable {
        let transaction: RemoteDesktopStreamConfigurationTransaction
        let streamRefreshToken: UInt64?
        let audioEndpointPresent: Bool
        let screenFrameTransport: String?
    }

    struct PreparationPlan: Equatable {
        let canSendOverWebRTC: Bool
        let canSendOverLAN: Bool
        let shouldStartRealtimeMediaAudioReceiver: Bool
        let shouldStopRealtimeMediaAudioReceiver: Bool
        let includeAudioEndpointInStreamConfig: Bool

        var canSend: Bool {
            canSendOverWebRTC || canSendOverLAN
        }
    }

    static func prepare(
        activeTransportMode: RemoteDesktopManager.ActiveTransportMode,
        hasCurrentConnection: Bool,
        hasLANConnection: Bool,
        audioRedirectionEnabled: Bool,
        hasUsableMediaAudioBinding: Bool,
        refreshStream: Bool,
        lastSentMediaAudioEndpointPresent: Bool,
        lastAcknowledgedMediaAudioEndpointPresent: Bool
    ) -> PreparationPlan {
        let canSendOverWebRTC = activeTransportMode == .crossNetwork && hasCurrentConnection
        let canSendOverLAN = activeTransportMode == .lan && hasLANConnection
        let includeAudioEndpointInStreamConfig = audioRedirectionEnabled
            && hasUsableMediaAudioBinding
            && (activeTransportMode == .lan
                || !refreshStream
                || !lastSentMediaAudioEndpointPresent
                || !lastAcknowledgedMediaAudioEndpointPresent)

        return PreparationPlan(
            canSendOverWebRTC: canSendOverWebRTC,
            canSendOverLAN: canSendOverLAN,
            shouldStartRealtimeMediaAudioReceiver: audioRedirectionEnabled,
            shouldStopRealtimeMediaAudioReceiver: !audioRedirectionEnabled,
            includeAudioEndpointInStreamConfig: includeAudioEndpointInStreamConfig
        )
    }

    static func shouldSendPayload(
        force: Bool,
        payloadMatchesLastSent: Bool
    ) -> Bool {
        force || !payloadMatchesLastSent
    }

    static func shouldScheduleAckRetry(
        activeTransportMode: RemoteDesktopManager.ActiveTransportMode,
        isStreaming: Bool,
        hasReceivedFrameInCurrentStream: Bool,
        payloadIncludesAudioEndpoint: Bool
    ) -> Bool {
        activeTransportMode == .crossNetwork
            && isStreaming
            && !hasReceivedFrameInCurrentStream
            && !payloadIncludesAudioEndpoint
    }

    static func acknowledgementMatches(
        _ acknowledgement: RemoteDesktopStreamConfigurationAcknowledgement,
        expectation: AcknowledgementExpectation
    ) -> Bool {
        acknowledgement.transaction == expectation.transaction
            && acknowledgement.streamRefreshToken == expectation.streamRefreshToken
            && acknowledgement.audioEndpointPresent == expectation.audioEndpointPresent
            && acknowledgement.screenFrameTransport == expectation.screenFrameTransport
    }

    static func allowsMediaAdmission(
        isReadOnlyCameraSession: Bool,
        activeTransaction: RemoteDesktopStreamConfigurationTransaction?,
        acknowledgedTransaction: RemoteDesktopStreamConfigurationTransaction?
    ) -> Bool {
        if isReadOnlyCameraSession {
            return true
        }
        guard let activeTransaction, let acknowledgedTransaction else {
            return false
        }
        return activeTransaction == acknowledgedTransaction
    }
}
