import Foundation

extension P2PConnectionManager {
    enum StrictPQCPreflightAction: Equatable {
        case proceed
        case attemptSignedLANRefresh
        case attemptOOBProtocolIdentityBindingThenRefresh
    }

    static func canSatisfyStrictPQCWithTrustedKEM(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        if let preferredTargetSuite {
            return trustedPeerKEMSuites.contains {
                suiteSupportsTargetKEM($0, target: preferredTargetSuite)
            }
        }
        return trustedPeerKEMSuites.contains(where: { $0.isPQCGroup })
    }

    static func suiteSupportsTargetKEM(_ availableSuite: CryptoSuite, target: CryptoSuite) -> Bool {
        if availableSuite == target {
            return true
        }

        let availableCanonical = availableSuite.canonicalKEMSuite
        let targetCanonical = target.canonicalKEMSuite
        if availableCanonical == targetCanonical {
            return true
        }

        if target.isHybrid {
            return availableSuite.isHybrid
        }

        if availableSuite.isHybrid {
            return target.isHybrid
        }

        return false
    }

    static func signedRefreshEvidenceSuites(_ evidence: KEMTrustStore.SignedRefreshEvidence?) -> Set<CryptoSuite> {
        guard let evidence else { return [] }
        return Set(evidence.suiteWireIds.map { CryptoSuite(wireId: $0) })
    }

    static func signedRefreshEvidenceSatisfiesStrictPQC(
        _ evidence: KEMTrustStore.SignedRefreshEvidence?,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: signedRefreshEvidenceSuites(evidence),
            preferredTargetSuite: preferredTargetSuite
        )
    }

    static func strictPQCPreflightAction(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        signedRefreshEvidence: KEMTrustStore.SignedRefreshEvidence?,
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?,
        signedRefreshFailureReason: String? = nil,
        requiresSignedRefreshEvidence: Bool = true
    ) -> StrictPQCPreflightAction {
        let trustedSuites = requiresSignedRefreshEvidence
            ? signedRefreshEvidenceSuites(signedRefreshEvidence)
            : trustedPeerKEMSuites
        if canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: trustedSuites,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return .proceed
        }
        if requiresSignedRefreshEvidence, signedRefreshEvidence == nil {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        if pinnedProtocolFingerprints.isEmpty
            || shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure: signedRefreshFailureReason) {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        return .attemptSignedLANRefresh
    }

    static func protocolIdentityBindingPolicyCandidates(
        for device: DiscoveredDevice,
        candidates: [String],
        payload: AppMessage.SignedProtocolIdentityBindingPayload
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }

        for raw in candidates + [device.id, payload.deviceId] + payload.aliases {
            append(raw)
            for alias in PeerIdentityAliasResolver.lookupCandidates(for: raw) {
                append(alias)
            }
        }

        return ordered
    }

    static func protocolIdentityBindingApprovalTimeoutSeconds() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS"],
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 180
        }
        return min(max(value, 30), 300)
    }

    static func protocolIdentityBindingResponseTimeoutSeconds() -> Double {
        Double(protocolIdentityBindingApprovalTimeoutSeconds() + 15)
    }

    static func protocolIdentityBindingStoredPolicyAction(
        pairingPolicyByPeerId: [String: String],
        policyCandidates: [String],
        trustedProtocolFingerprints: Set<String>,
        payloadFingerprint: String
    ) -> ProtocolIdentityBindingStoredPolicyAction? {
        let normalizedFingerprint = payloadFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedFingerprint.count == 64,
              normalizedFingerprint.allSatisfy(\.isHexDigit) else {
            return nil
        }

        for candidate in policyCandidates {
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let raw = pairingPolicyByPeerId[key],
                  let policy = PairingTrustDecision(rawValue: raw) else {
                continue
            }
            switch policy {
            case .reject:
                return .reject
            case .alwaysAllow, .allowOnce, .timedOut:
                continue
            }
        }

        let normalizedTrustedFingerprints = Set(
            trustedProtocolFingerprints.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        if normalizedTrustedFingerprints.contains(normalizedFingerprint) {
            return .approve(operatorLabel: "stored-protocol-identity")
        }

        return nil
    }

    static func expandedTrustMaterialCandidates(for rawIds: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }

        for rawId in rawIds {
            append(rawId)
            for alias in PeerIdentityAliasResolver.lookupCandidates(for: rawId) {
                append(alias)
            }
        }

        return ordered
    }

    static func trustedPeerKEMPublicKeysFromAllStores(forAny candidates: [String]) async -> [CryptoSuite: Data] {
        let expandedCandidates = expandedTrustMaterialCandidates(for: candidates)
        guard !expandedCandidates.isEmpty else { return [:] }
        return await KEMTrustStore.shared.kemPublicKeys(forAny: expandedCandidates)
    }

    static func preferredBootstrapRekeyTargetSuite(using cryptoProvider: any CryptoProvider) -> CryptoSuite? {
        if let preparation = try? TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: cryptoProvider,
            pqcOfferMode: .preferredSingle
        ) {
            if let preferredPQC = preparation.offeredSuites.first(where: { $0.isPQCGroup }) {
                return preferredPQC
            }
            return preparation.offeredSuites.first
        }

        if let fallbackPQC = cryptoProvider.supportedSuites.first(where: { $0.isPQCGroup }) {
            return fallbackPQC
        }
        return cryptoProvider.supportedSuites.first
    }

    private static func shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return reason.contains("pinned_protocol_identity_mismatch_requires_oob")
            || reason.contains("missing_pinned_identity_requires_oob")
            || reason.contains("requester_protocol_identity_not_pinned")
    }
}
