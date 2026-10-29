import Foundation
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
enum RemoteDesktopViewerStreamConfigurationPushPolicy {
    /// One LAN configuration may await a response while receiver readiness or
    /// settings changes coalesce into one latest intent. This owns scheduling
    /// only; the existing transaction/transport gates still own authority.
    struct LANSendLane<Owner: Equatable> {
        struct Intent: Equatable {
            let force: Bool
            let refreshStream: Bool

            func merging(_ newer: Self) -> Self {
                .init(force: force || newer.force, refreshStream: refreshStream || newer.refreshStream)
            }
        }
        struct Work: Equatable {
            let id: UUID
            let owner: Owner
            let intent: Intent
        }
        private struct Pending {
            let work: Work
            var transaction: RemoteDesktopStreamConfigurationTransaction?
            var sendCompleted = false
            var responseReceived = false
        }
        private var pending: Pending?
        private(set) var queuedIntent: Intent?

        mutating func request(owner: Owner, intent: Intent) -> Work? {
            if let pending, pending.work.owner == owner {
                queuedIntent = queuedIntent.map { $0.merging(intent) } ?? intent
                return nil
            }
            reset()
            let work = Work(id: UUID(), owner: owner, intent: intent)
            pending = Pending(work: work)
            return work
        }

        func isCurrent(_ work: Work) -> Bool { pending?.work == work }

        func isAwaitingResponse(_ work: Work) -> Bool {
            isCurrent(work) && pending?.responseReceived == false
        }

        mutating func bind(_ transaction: RemoteDesktopStreamConfigurationTransaction, work: Work) -> Bool {
            guard isCurrent(work), pending?.transaction == nil else { return false }
            pending?.transaction = transaction
            return true
        }

        mutating func finishSending(_ work: Work) -> Work? {
            guard isCurrent(work) else { return nil }
            pending?.sendCompleted = true
            // Nothing went on the wire when an unchanged configuration is skipped.
            if pending?.transaction == nil { pending?.responseReceived = true }
            return takeNextIfComplete()
        }

        func awaits(_ transaction: RemoteDesktopStreamConfigurationTransaction, owner: Owner) -> Bool {
            pending?.work.owner == owner && pending?.transaction == transaction && pending?.responseReceived == false
        }

        mutating func acknowledge(_ transaction: RemoteDesktopStreamConfigurationTransaction, owner: Owner) -> Work? {
            guard pending?.work.owner == owner, pending?.transaction == transaction else { return nil }
            pending?.responseReceived = true
            return takeNextIfComplete()
        }

        @discardableResult
        mutating func cancel(_ work: Work) -> Bool {
            guard isCurrent(work) else { return false }
            reset()
            return true
        }

        mutating func reset() {
            pending = nil
            queuedIntent = nil
        }

        private mutating func takeNextIfComplete() -> Work? {
            guard let pending, pending.sendCompleted, pending.responseReceived else { return nil }
            let owner = pending.work.owner
            let intent = queuedIntent
            reset()
            guard let intent else { return nil }
            return request(owner: owner, intent: intent)
        }
    }

    static func configurationResponseTimeout(hasApprovedSession: Bool) -> Duration {
        RemoteControlStartupTiming.acknowledgementTimeout(
            hasApprovedSession: hasApprovedSession,
            configurationTimeout: .seconds(10)
        )
    }

    static func rejectionLocalizationKey(code: String) -> String {
        switch code {
        case "audio-unsupported": return "remote.error.audioUnsupported"
        case "clipboard-unsupported": return "remote.error.clipboardUnsupported"
        case "audio-and-clipboard-unsupported": return "remote.error.audioAndClipboardUnsupported"
        case "configuration-unsupported": return "remote.error.configurationUnsupported"
        default: return "remote.error.configurationRejected"
        }
    }

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
        let sessionTerminationVersion: Int?

        init(
            transaction: RemoteDesktopStreamConfigurationTransaction,
            streamRefreshToken: UInt64?,
            audioEndpointPresent: Bool,
            screenFrameTransport: String?,
            framePresentationAckVersion: Int? = nil,
            sessionTerminationVersion: Int? = nil
        ) {
            self.transaction = transaction
            self.streamRefreshToken = streamRefreshToken
            self.audioEndpointPresent = audioEndpointPresent
            self.screenFrameTransport = screenFrameTransport
            self.framePresentationAckVersion = framePresentationAckVersion
            self.sessionTerminationVersion = sessionTerminationVersion
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
            && RemoteDesktopSessionTerminationContract.acknowledgementMatches(
                requested: expectation.sessionTerminationVersion, acknowledged: acknowledgement.sessionTerminationVersion)
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
