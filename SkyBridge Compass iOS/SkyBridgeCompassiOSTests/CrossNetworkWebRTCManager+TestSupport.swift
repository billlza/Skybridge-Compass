import Foundation
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    nonisolated internal static func testOnlyDecryptDirectControlProbePayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> Data? {
        decryptDirectControlProbePayload(payload, keys: keys)
    }

    nonisolated internal static func testOnlyDecodeHighThroughputRemoteDesktopPayloadKind(
        _ plaintext: Data
    ) -> String? {
        switch decodeRemoteDesktopHighThroughputPayload(plaintext) {
        case .screen:
            return "screen"
        case .audio:
            return "audio"
        case nil:
            return nil
        }
    }

    nonisolated internal static func testOnlyDecodeDirectScreenChannelPayloadKind(
        _ payload: Data,
        keys: SessionKeys
    ) -> String? {
        decodeDirectScreenChannelPayload(payload, keys: keys).map { _ in "screen" }
    }

    nonisolated internal static func testOnlyDecodeEncryptedScreenChannelPayloadKind(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> String? {
        try decodeEncryptedScreenChannelPayload(payload, keys: keys).map { _ in "screen" }
    }

    nonisolated internal static func testOnlyMediaRelayLeaseFailureReason(status: Int, body: String) -> String {
        mediaRelayLeaseFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyMediaRelayLeaseFailureReasonAfterRefresh(status: Int, body: String) -> String {
        mediaRelayLeaseFailureReasonAfterRefresh(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyMediaAdmissionRefreshFailureReason(status: Int, body: String) -> String {
        mediaAdmissionRefreshFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlySessionRefreshFailureReason(status: Int, body: String) -> String {
        sessionRefreshFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyDecodeMediaRelayLeaseResponse(_ data: Data) throws -> (
        localToken: String?,
        localRole: String,
        localExpiresAt: TimeInterval?
    ) {
        let lease = try SignalServerClientCompat.testOnlyDecodeMediaRelayLeaseResponse(data)
        return (
            localToken: lease.endpoint.relayToken,
            localRole: lease.role,
            localExpiresAt: lease.endpoint.expiresAt
        )
    }

    nonisolated internal static func testOnlyShouldReuseRedeemedQRSessionArtifacts(
        canonicalQRSignalingOrigin: String,
        qrDeviceId: String,
        qrProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qrProtocolPublicKeyFingerprint: String,
        qrProtocolPublicKeyBytes: Data,
        signalingToken: String?,
        turnAdmissionToken: String?,
        cachedSignalingOrigin: String?,
        cachedAuthorityDeviceId: String?,
        cachedAuthorityProtocolSigningAlgorithm: ProtocolSigningAlgorithm?,
        cachedAuthorityProtocolPublicKeyFingerprint: String?,
        cachedAuthorityProtocolPublicKeyBytes: Data = Data()
    ) -> Bool {
        let cachedAuthority: CurrentPathRemoteAuthorityCompat?
        if let cachedAuthorityDeviceId,
           let cachedAuthorityProtocolSigningAlgorithm,
           let cachedAuthorityProtocolPublicKeyFingerprint {
            cachedAuthority = CurrentPathRemoteAuthorityCompat(
                deviceId: cachedAuthorityDeviceId,
                protocolSigningAlgorithm: cachedAuthorityProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: cachedAuthorityProtocolPublicKeyFingerprint,
                protocolPublicKeyBytes: cachedAuthorityProtocolPublicKeyBytes,
                deviceName: nil
            )
        } else {
            cachedAuthority = nil
        }

        return Self.shouldReuseRedeemedQRSessionArtifacts(
            canonicalQRSignalingOrigin: canonicalQRSignalingOrigin,
            qrDeviceId: qrDeviceId,
            qrProtocolSigningAlgorithm: qrProtocolSigningAlgorithm,
            qrProtocolPublicKeyFingerprint: qrProtocolPublicKeyFingerprint,
            qrProtocolPublicKeyBytes: qrProtocolPublicKeyBytes,
            signalingToken: testOnlyNormalizedNonEmptyToken(signalingToken),
            turnAdmissionToken: testOnlyNormalizedNonEmptyToken(turnAdmissionToken),
            cachedSignalingOrigin: cachedSignalingOrigin,
            cachedAuthority: cachedAuthority
        )
    }

    nonisolated internal static func testOnlyIsActualNativeRenderEvidence(_ source: String) -> Bool {
        CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source)
    }

    nonisolated internal static func testOnlyInboundPQCRekeySelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool
    ) -> CryptoProviderFactory.SelectionPolicy? {
        CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeySelectionPolicy(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable
        )
    }

    nonisolated internal static func testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool
    ) -> Bool {
        CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeyNegotiatedSuiteAllowed(
            suite,
            strictPQCRequested: strictPQCRequested
        )
    }

    nonisolated internal static func testOnlyResolveTrustedPeerKEMCoverage(
        requiredSuites: [CryptoSuite],
        trustedPeerKEM: [CryptoSuite: Data]
    ) -> (availableSuites: [CryptoSuite], missingSuites: [CryptoSuite]) {
        CrossNetworkWebRTCPQCHandshakePolicy.resolveTrustedPeerKEMCoverage(
            requiredSuites: requiredSuites,
            trustedPeerKEM: trustedPeerKEM
        )
    }

    nonisolated internal static func testOnlyStrictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProviderSuites: [CryptoSuite],
        selectedProviderTier: CryptoTier,
        appleXWingAvailable: Bool
    ) -> [CryptoSuite] {
        CrossNetworkWebRTCPQCHandshakePolicy.strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: selectedProviderSuites,
            selectedProviderTier: selectedProviderTier,
            appleXWingAvailable: appleXWingAvailable
        )
    }

    nonisolated internal static func testOnlyWebRTCPQCRekeyProviderPlans(
        capability: CryptoProviderFactory.Capability,
        prefersLiboqsForPeer: Bool,
        peerHasXWing: Bool,
        appleXWingAvailable: Bool
    ) -> [WebRTCPQCRekeyProviderPlan] {
        CrossNetworkWebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: prefersLiboqsForPeer,
            peerHasXWing: peerHasXWing,
            appleXWingAvailable: appleXWingAvailable
        )
    }

    nonisolated internal static func testOnlyInboundInitialHandshakeSelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> CryptoProviderFactory.SelectionPolicy? {
        CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm
        )
    }

    nonisolated internal static func testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool,
        allowsClassicAuthorityBootstrap: Bool
    ) -> Bool {
        CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeNegotiatedSuiteAllowed(
            suite,
            strictPQCRequested: strictPQCRequested,
            allowsClassicAuthorityBootstrap: allowsClassicAuthorityBootstrap
        )
    }

    nonisolated internal static func testOnlyShouldInitiateInitialWebRTCHandshake(
        role: WebRTCSession.Role
    ) -> Bool {
        CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: role)
    }

    nonisolated internal static func testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
        sessionId: String,
        authorityBoundBootstrapSessionIds: Set<String>,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?,
        localConnectionSessionId: String?
    ) -> Bool {
        CrossNetworkWebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
            sessionId: sessionId,
            authorityBoundBootstrapSessionIds: authorityBoundBootstrapSessionIds,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm,
            localConnectionSessionId: localConnectionSessionId
        )
    }

    nonisolated internal static func testOnlyCurrentPathRequestTimeoutSeconds() -> TimeInterval {
        SignalServerClientCompat.testOnlyRequestTimeoutSeconds()
    }

    nonisolated internal static func testOnlyWebRTCStartupJoinHeartbeatAttempts() -> Int {
        webRTCStartupJoinHeartbeatAttempts
    }

    nonisolated private static func testOnlyNormalizedNonEmptyToken(_ raw: String?) -> String? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
