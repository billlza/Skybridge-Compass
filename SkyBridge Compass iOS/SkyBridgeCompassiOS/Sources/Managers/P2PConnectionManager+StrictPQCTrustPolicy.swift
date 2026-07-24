import Foundation

@available(iOS 17.0, *)
struct ProtocolIdentityBindingV3ResponderContext: Sendable {
    let request: AppMessage.ProtocolIdentityBindingRequestPayload
    let candidate: AppMessage.SignedProtocolIdentityBindingPayload
    let requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm
    let requesterProtocolIdentityPublicKey: Data
    let requesterProtocolIdentityFingerprint: String
    let responderProtocolSigningKeyHandle: SigningKeyHandle
    let peerId: String
    let expiresAt: Date
}

@available(iOS 17.0, *)
enum ProtocolIdentityBindingV3CandidateRegistration: Sendable {
    case stored(ProtocolIdentityBindingV3ResponderContext)
    case replay(ProtocolIdentityBindingV3ResponderContext)
    case transactionConflict
    case capacityExceeded
}

@available(iOS 17.0, *)
enum ProtocolIdentityBindingV3ConfirmAdmission: Sendable {
    case allowed(ProtocolIdentityBindingV3ResponderContext)
    case replay(AppMessage.SignedProtocolIdentityBindingFinalAckPayload)
    case inFlight
    case rejected
}

/// Bounded, expiring responder transcript state for the two short connections
/// that make up PIB-1 v3. No trust material is installed by this actor.
@available(iOS 17.0, *)
actor ProtocolIdentityBindingV3StateStore {
    static let shared = ProtocolIdentityBindingV3StateStore()

    private struct Entry: Sendable {
        let context: ProtocolIdentityBindingV3ResponderContext
        let requestHashHex: String
        let candidateHashHex: String
        let sasTranscriptHashHex: String
        var inFlightConfirmHashHex: String?
        var completedConfirmHashHex: String?
        var finalAck: AppMessage.SignedProtocolIdentityBindingFinalAckPayload?
    }

    private let ttl: TimeInterval
    private let maximumEntries: Int
    private var entries: [UUID: Entry] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(ttl: TimeInterval = 300, maximumEntries: Int = 32) {
        self.ttl = min(max(ttl, 1), 300)
        self.maximumEntries = min(max(maximumEntries, 1), 32)
    }

    deinit {
        cleanupTask?.cancel()
    }

    func registerCandidate(
        _ context: ProtocolIdentityBindingV3ResponderContext,
        now: Date = Date()
    ) -> ProtocolIdentityBindingV3CandidateRegistration {
        prune(now: now)
        let transactionId = context.request.transactionId
        let requestHashHex = context.request.canonicalRequestHashHex
        guard context.candidate.transactionId == transactionId,
              context.candidate.requestNonce == context.request.nonce,
              context.candidate.requestHashHex?.lowercased() == requestHashHex,
              context.requesterProtocolSigningAlgorithm.rawValue
                == context.request.requesterProtocolSigningAlgorithm,
              context.requesterProtocolIdentityPublicKey
                == context.request.requesterProtocolIdentityPublicKey,
              context.requesterProtocolIdentityFingerprint
                == context.request.requesterProtocolIdentityFingerprint?.lowercased() else {
            return .transactionConflict
        }
        if let existing = entries[transactionId] {
            guard existing.requestHashHex == requestHashHex else {
                return .transactionConflict
            }
            return .replay(existing.context)
        }
        guard entries.count < maximumEntries else {
            return .capacityExceeded
        }
        let effectiveExpiry = min(
            min(context.expiresAt, context.candidate.expiresAt),
            now.addingTimeInterval(ttl)
        )
        guard effectiveExpiry > now else {
            return .transactionConflict
        }
        let boundedContext = ProtocolIdentityBindingV3ResponderContext(
            request: context.request,
            candidate: context.candidate,
            requesterProtocolSigningAlgorithm: context.requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityPublicKey: context.requesterProtocolIdentityPublicKey,
            requesterProtocolIdentityFingerprint: context.requesterProtocolIdentityFingerprint,
            responderProtocolSigningKeyHandle: context.responderProtocolSigningKeyHandle,
            peerId: context.peerId,
            expiresAt: effectiveExpiry
        )
        entries[transactionId] = Entry(
            context: boundedContext,
            requestHashHex: requestHashHex,
            candidateHashHex: context.candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: context.candidate.sasTranscriptHashHex(request: context.request),
            inFlightConfirmHashHex: nil,
            completedConfirmHashHex: nil,
            finalAck: nil
        )
        scheduleCleanup()
        return .stored(boundedContext)
    }

    func beginConfirm(
        _ confirm: AppMessage.ProtocolIdentityBindingConfirmPayload,
        now: Date = Date()
    ) -> ProtocolIdentityBindingV3ConfirmAdmission {
        prune(now: now)
        guard var entry = entries[confirm.transactionId],
              entry.context.expiresAt > now,
              entry.requestHashHex == confirm.requestHashHex.lowercased(),
              entry.candidateHashHex == confirm.candidateHashHex.lowercased(),
              entry.sasTranscriptHashHex == confirm.sasTranscriptHashHex.lowercased() else {
            return .rejected
        }
        let confirmHashHex = confirm.canonicalConfirmHashHex
        if let finalAck = entry.finalAck {
            guard entry.completedConfirmHashHex == confirmHashHex else {
                return .rejected
            }
            guard finalAck.expiresAt > now else {
                entries.removeValue(forKey: confirm.transactionId)
                return .rejected
            }
            return .replay(finalAck)
        }
        if let inFlight = entry.inFlightConfirmHashHex {
            return inFlight == confirmHashHex ? .inFlight : .rejected
        }
        entry.inFlightConfirmHashHex = confirmHashHex
        entries[confirm.transactionId] = entry
        return .allowed(entry.context)
    }

    func completeConfirm(
        transactionId: UUID,
        confirmHashHex: String,
        finalAck: AppMessage.SignedProtocolIdentityBindingFinalAckPayload
    ) -> Bool {
        guard var entry = entries[transactionId],
              entry.inFlightConfirmHashHex == confirmHashHex else {
            return false
        }
        entry.inFlightConfirmHashHex = nil
        entry.completedConfirmHashHex = confirmHashHex
        entry.finalAck = finalAck
        entries[transactionId] = entry
        return true
    }

    func abortConfirm(transactionId: UUID, confirmHashHex: String) {
        guard var entry = entries[transactionId],
              entry.inFlightConfirmHashHex == confirmHashHex else {
            return
        }
        entry.inFlightConfirmHashHex = nil
        entries[transactionId] = entry
    }

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        cleanupTask?.cancel()
        cleanupTask = nil
        entries.removeAll(keepingCapacity: false)
    }

    func entryCountForTesting(now: Date = Date()) -> Int {
        prune(now: now)
        return entries.count
    }
#endif

    private func prune(now: Date) {
        entries = entries.filter { $0.value.context.expiresAt > now }
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        guard let nextExpiry = entries.values.map(\.context.expiresAt).min() else {
            cleanupTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        cleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.expireEntriesAndReschedule()
        }
    }

    private func expireEntriesAndReschedule() {
        prune(now: Date())
        scheduleCleanup()
    }
}

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
        let normalizedPinnedProtocolFingerprints = Set(
            pinnedProtocolFingerprints.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
        guard !normalizedPinnedProtocolFingerprints.isEmpty else {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
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
        if shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure: signedRefreshFailureReason) {
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

    static func protocolIdentityBindingCandidateResponseTimeoutSeconds() -> Double {
        30
    }

    static func protocolIdentityBindingStoredPolicyAction(
        pairingPolicyByPeerId: [String: String],
        policyCandidates: [String],
        trustedProtocolFingerprints: Set<String>,
        payloadFingerprint: String,
        hasActiveDurableTrust: Bool
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
        if hasActiveDurableTrust,
           normalizedTrustedFingerprints.contains(normalizedFingerprint) {
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
