import Foundation

extension CrossNetworkConnectionManager {
    internal struct WebRTCInboundResponderSelection: Sendable {
        let selectionPolicy: CryptoProviderFactory.SelectionPolicy
        let cryptoProvider: any CryptoProvider
        let sigAAlgorithm: ProtocolSigningAlgorithm
        let offeredSuites: [CryptoSuite]
        let fellBackToClassic: Bool
    }

    internal static func shouldDeferSignalingSendRecovery(
        isHandshakeComplete: Bool,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        isHandshakeComplete && messageType != .leave
    }

    internal static func shouldUseOnDemandSignalingAfterTransportFailure(
        isHandshakeComplete: Bool
    ) -> Bool {
        isHandshakeComplete
    }

    internal static func classifySignalingFailure(
        from frame: WebSocketSignalingClient.SignalingServerFrame
    ) -> WebSocketSignalingClient.SignalingFailureClass {
        let reason = frame.error ?? frame.what ?? "unknown_signaling_error"
        if reason.localizedCaseInsensitiveContains("token") && reason.localizedCaseInsensitiveContains("expired") {
            return .tokenExpired
        }
        if reason.localizedCaseInsensitiveContains("auth") ||
            reason.localizedCaseInsensitiveContains("unauthorized") ||
            reason.localizedCaseInsensitiveContains("forbidden") ||
            reason.localizedCaseInsensitiveContains("bind_rejected") {
            return .authBindRejected
        }
        if reason.localizedCaseInsensitiveContains("invalid shard") ||
            reason.localizedCaseInsensitiveContains("invalid session") ||
            reason.localizedCaseInsensitiveContains("session mismatch") ||
            reason.localizedCaseInsensitiveContains("unknown shard") {
            return .invalidShardOrSessionMismatch
        }
        if reason.localizedCaseInsensitiveContains("protocol") ||
            reason.localizedCaseInsensitiveContains("malformed") {
            return .protocolViolation
        }
        return .transientServer
    }

    internal static func isFatalPreTransportFailure(
        _ failureClass: WebSocketSignalingClient.SignalingFailureClass
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    internal static func isFatalPostTransportFailure(
        _ failureClass: WebSocketSignalingClient.SignalingFailureClass
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    nonisolated static func shouldWakeOffererFromRemoteJoin(
        hasLocalSession: Bool,
        pendingOfferStart: Bool,
        authorityBoundBootstrap: Bool,
        hasSignalingToken: Bool
    ) -> Bool {
        !hasLocalSession
            && !pendingOfferStart
            && authorityBoundBootstrap
            && hasSignalingToken
    }

    nonisolated static func shouldRecoverMissingOfferCacheFromRemoteJoin(
        hasLocalSession: Bool,
        isOfferer: Bool,
        hasCachedOffer: Bool,
        authorityBoundBootstrap: Bool,
        hasSignalingToken: Bool
    ) -> Bool {
        hasLocalSession
            && isOfferer
            && !hasCachedOffer
            && authorityBoundBootstrap
            && hasSignalingToken
    }

    nonisolated static func selectWebRTCInboundResponder(
        peerSupportedSuites: [CryptoSuite],
        policy: HandshakePolicy,
        environment: any CryptoEnvironment = SystemCryptoEnvironment.system
    ) -> WebRTCInboundResponderSelection? {
        let peerHasPQCGroup = peerSupportedSuites.contains { $0.isPQCGroup }
        let peerHasClassicGroup = peerSupportedSuites.contains { !$0.isPQCGroup }
        let classicProvider = CryptoProviderFactory.make(policy: .classicOnly, environment: environment)
        let classicSuites = classicProvider.supportedSuites.filter { !$0.isPQCGroup }

        guard peerHasPQCGroup else {
            guard !policy.requirePQC else {
                return nil
            }
            return WebRTCInboundResponderSelection(
                selectionPolicy: .classicOnly,
                cryptoProvider: classicProvider,
                sigAAlgorithm: .ed25519,
                offeredSuites: classicSuites,
                fellBackToClassic: false
            )
        }

        let requestedSelection: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let pqcProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
            policy: requestedSelection,
            peerSupportedSuites: peerSupportedSuites,
            environment: environment
        )
        let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: pqcProvider)
        if !localPQCSuites.isEmpty {
            return WebRTCInboundResponderSelection(
                selectionPolicy: requestedSelection,
                cryptoProvider: pqcProvider,
                sigAAlgorithm: .mlDSA65,
                offeredSuites: localPQCSuites,
                fellBackToClassic: false
            )
        }

        guard !policy.requirePQC, peerHasClassicGroup else {
            return nil
        }

        return WebRTCInboundResponderSelection(
            selectionPolicy: .classicOnly,
            cryptoProvider: classicProvider,
            sigAAlgorithm: .ed25519,
            offeredSuites: classicSuites,
            fellBackToClassic: true
        )
    }
}
