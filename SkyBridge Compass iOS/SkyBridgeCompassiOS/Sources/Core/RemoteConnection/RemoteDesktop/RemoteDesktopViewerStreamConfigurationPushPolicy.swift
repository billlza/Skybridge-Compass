import Foundation
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
enum RemoteDesktopViewerStreamConfigurationPushPolicy {
    /// A configuration depends only on the audio resource it actually publishes.
    /// Video-only and stop transactions must survive asynchronous receiver installation.
    enum AudioBindingRequirement<Owner: Equatable>: Equatable {
        enum Failure: Error, LocalizedError {
            case missingAudioBinding
            var errorDescription: String? { "远控音频配置缺少当前会话的接收器。" }
        }
        case unused
        case exact(Owner)

        init(audioEndpointPresent: Bool, installedOwner: Owner?) throws {
            guard audioEndpointPresent else {
                self = .unused
                return
            }
            guard let installedOwner else { throw Failure.missingAudioBinding }
            self = .exact(installedOwner)
        }

        var requiresAudioBinding: Bool {
            if case .exact = self { return true }
            return false
        }

        var requiredOwner: Owner? {
            if case .exact(let owner) = self { return owner }
            return nil
        }

        func isSatisfied(by currentOwner: Owner?) -> Bool {
            switch self {
            case .unused: return true
            case .exact(let expected): return currentOwner == expected
            }
        }
    }

    /// Call only after the exact configuration ACK. Repeated ACKs cannot extend
    /// first-media deadlines; a replacement audio receiver gets its own deadline.
    struct StartupWatchdogAdmission<AudioOwner: Equatable> {
        struct Plan: Equatable {
            let startVideo: Bool
            let startAudio: Bool
        }
        private var videoStarted = false
        private var monitoredAudioOwner: AudioOwner?

        mutating func acknowledge(audioOwner: AudioOwner?) -> Plan {
            let startVideo = !videoStarted
            let startAudio = audioOwner != nil && audioOwner != monitoredAudioOwner
            videoStarted = true
            if startAudio { monitoredAudioOwner = audioOwner }
            return Plan(startVideo: startVideo, startAudio: startAudio)
        }

        mutating func retireAudio() { monitoredAudioOwner = nil }
    }

    struct AcknowledgementExpectation: Equatable {
        let transaction: RemoteDesktopStreamConfigurationTransaction
        let streamRefreshToken: UInt64?
        let audioEndpointPresent: Bool
        let screenFrameTransport: String?
        let framePresentationAckVersion: Int?

        init(
            transaction: RemoteDesktopStreamConfigurationTransaction,
            streamRefreshToken: UInt64?,
            audioEndpointPresent: Bool,
            screenFrameTransport: String?,
            framePresentationAckVersion: Int? = nil
        ) {
            self.transaction = transaction
            self.streamRefreshToken = streamRefreshToken
            self.audioEndpointPresent = audioEndpointPresent
            self.screenFrameTransport = screenFrameTransport
            self.framePresentationAckVersion = framePresentationAckVersion
        }
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
            && (acknowledgement.framePresentationAckVersion == nil
                || acknowledgement.framePresentationAckVersion
                    == expectation.framePresentationAckVersion)
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
