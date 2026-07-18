import Foundation
import OSLog

public enum PairingTrustPolicyStoreError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "配对信任策略存储不可用；已拒绝自动应用历史策略"
    }
}

public enum PairingTrustApprovalAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case waiterLimitExceeded(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .waiterLimitExceeded(let maximum):
            return "Pairing trust approval waiter limit exceeded: maximum=\(maximum)"
        }
    }
}

/// Pairing / trust approval service for bootstrap KEM identity exchange.
///
/// When a peer requests pairing/trust (via `AppMessage.pairingIdentityExchange`), macOS SHOULD prompt the user
/// with device details and allow: Always Allow / Allow Once / Reject.
///
/// This service is UI-facing (ObservableObject) and provides an async decision API for the networking layer.
@available(macOS 14.0, *)
@MainActor
public final class PairingTrustApprovalService: ObservableObject {
    public static let shared = PairingTrustApprovalService()
    private static let maximumWaitersPerRequest = 8
    
    public enum Decision: String, Sendable {
        case alwaysAllow
        case allowOnce
        case reject
    }
    
    public struct Request: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let peerEndpoint: String
        public let declaredDeviceId: String
        public let policyBindingKey: String?
        public let displayName: String
        public let model: String?
        public let platform: String?
        public let osVersion: String?
        public let kemKeyCount: Int
        public let receivedAt: Date
        
        public init(
            id: UUID = UUID(),
            peerEndpoint: String,
            declaredDeviceId: String,
            policyBindingKey: String? = nil,
            displayName: String,
            model: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            kemKeyCount: Int,
            receivedAt: Date = Date()
        ) {
            self.id = id
            self.peerEndpoint = peerEndpoint
            self.declaredDeviceId = declaredDeviceId
            self.policyBindingKey = policyBindingKey
            self.displayName = displayName
            self.model = model
            self.platform = platform
            self.osVersion = osVersion
            self.kemKeyCount = kemKeyCount
            self.receivedAt = receivedAt
        }
    }
    
    /// Current pending request (drives UI sheet).
    @Published public private(set) var pendingRequest: Request?

    /// Decision selected for the current pending request (set after user action).
    @Published public private(set) var pendingDecision: Decision?

    /// 6-digit SAS verification code derived from the current session's transcript hash.
    @Published public private(set) var pendingVerificationCode: String?

    /// Negotiated suite for which `pendingVerificationCode` was derived.
    @Published public private(set) var pendingVerificationSuite: String?

    /// Last time the verification fields were updated (best-effort).
    @Published public private(set) var pendingVerificationUpdatedAt: Date?
    
    private static let policyStore = CodablePersistenceStore<[String: String]>(
        location: .protectedApplicationSupport(
            path: "PairingTrust/policy.json",
            legacyUserDefaultsKey: "com.skybridge.pairingTrust.policy.v1"
        )
    )
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PairingTrustApproval")
    private nonisolated static var protocolIdentityLogRedaction: String { "<redacted>" }
    
    /// Policy key -> decisionRawValue. Identity-bound requests use their full
    /// binding key; device-only keys are retained solely for legacy unbound
    /// requests and as a fail-closed deny for newly bound identities.
    private var policyByDeviceId: [String: String] = [:]
    private var policyStoreLoadFailed = false
#if DEBUG || SKYBRIDGE_TESTING
    private var forcePolicyStoreSaveFailureForTesting = false
#endif

    private typealias DecisionContinuation = CheckedContinuation<Decision, any Error>
    private var continuationByRequestId: [UUID: [UUID: DecisionContinuation]] = [:]
    private var resolutionTaskByRequestId: [UUID: Task<Void, Never>] = [:]
    private struct ProtocolIdentityPinContext: Sendable {
        let deviceIds: [String]
        let algorithm: ProtocolSigningAlgorithm
        let fingerprint: String
    }

    private var protocolIdentityPinContextByRequestId: [UUID: ProtocolIdentityPinContext] = [:]
    
    private init() {
        do {
            policyByDeviceId = try Self.loadPolicy()
        } catch {
            policyByDeviceId = [:]
            policyStoreLoadFailed = true
            logger.error(
                "Pairing trust policy store unavailable; historical policies are disabled: \(error.localizedDescription, privacy: .private)"
            )
        }
        logger.info("🔐 PairingTrustApprovalService initialized")
    }

    public nonisolated static func policyBindingKey(
        declaredDeviceId: String,
        algorithmRawValue: String,
        protocolPublicKeyFingerprint: String
    ) -> String? {
        let normalizedDeviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlgorithm = algorithmRawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedDeviceId.isEmpty,
              !normalizedAlgorithm.isEmpty,
              !normalizedFingerprint.isEmpty else {
            return nil
        }
        return "\(normalizedDeviceId)|\(normalizedAlgorithm)|\(normalizedFingerprint)"
    }
    
    private static func loadPolicy() throws -> [String: String] {
        try Self.policyStore.loadOrThrow() ?? [:]
    }

    private func requirePolicyStoreReady() throws {
        guard !policyStoreLoadFailed else {
            throw PairingTrustPolicyStoreError.unavailable
        }
    }
    
    private func savePolicy() throws {
#if DEBUG || SKYBRIDGE_TESTING
        if forcePolicyStoreSaveFailureForTesting {
            throw PairingTrustPolicyStoreError.unavailable
        }
#endif
        try Self.policyStore.save(policyByDeviceId)
    }

#if DEBUG || SKYBRIDGE_TESTING
    var pendingDecisionWaiterCountForTesting: Int {
        guard let requestId = pendingRequest?.id else { return 0 }
        return continuationByRequestId[requestId]?.count ?? 0
    }

    func setPolicyStoreSaveFailureForTesting(_ enabled: Bool) {
        forcePolicyStoreSaveFailureForTesting = enabled
    }
#endif
    
    /// Transactionally clears every persisted policy schema for all aliases of
    /// a forgotten device. In-memory state is rolled back if durable storage
    /// cannot be updated, so the UI never reports a false successful forget.
    public func clearPolicies(for declaredDeviceIds: [String]) throws {
        try requirePolicyStoreReady()
        let normalizedDeviceIds = normalizedPolicyAliases(for: declaredDeviceIds)
        guard !normalizedDeviceIds.isEmpty else { return }
        rejectPendingRequest(matchingPolicyAliases: normalizedDeviceIds)
        let keysToRemove = policyByDeviceId.keys.filter { key in
            guard let storedDeviceId = Self.deviceIdEncodedByPolicyKey(key) else { return false }
            return !normalizedPolicyAliases(for: [storedDeviceId]).isDisjoint(with: normalizedDeviceIds)
        }
        guard !keysToRemove.isEmpty else { return }
        let previousPolicy = policyByDeviceId
        for key in keysToRemove {
            policyByDeviceId.removeValue(forKey: key)
        }
        do {
            try savePolicy()
        } catch {
            policyByDeviceId = previousPolicy
            logger.error(
                "Failed to clear pairing trust policies: aliases=\(normalizedDeviceIds.count, privacy: .public) err=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
        logger.info(
            "🔓 Cleared pairing trust policies: aliases=\(normalizedDeviceIds.count, privacy: .public) keys=\(keysToRemove.count, privacy: .public)"
        )
    }

    private static func deviceIdEncodedByPolicyKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "PIB-1" || parts.first == "PIB-1-requester" {
            guard parts.count >= 2, !parts[1].isEmpty else { return nil }
            return parts[1]
        }
        return parts.first
    }

    private func normalizedPolicyAliases(for rawIds: [String]) -> Set<String> {
        rawIds.reduce(into: Set<String>()) { aliases, rawId in
            for candidate in PeerTrustLookup.lookupCandidates(for: rawId) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    aliases.insert(normalized)
                }
            }
        }
    }

    private func rejectPendingRequest(matchingPolicyAliases aliases: Set<String>) {
        guard let request = pendingRequest,
              !normalizedPolicyAliases(for: [request.declaredDeviceId]).isDisjoint(with: aliases) else {
            return
        }
        resolutionTaskByRequestId.removeValue(forKey: request.id)?.cancel()
        protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
        let continuations = continuationByRequestId
            .removeValue(forKey: request.id)
            .map { Array($0.values) } ?? []
        continuations.forEach { $0.resume(returning: .reject) }
        clearPendingPresentation(requestId: request.id)
        logger.info("Rejected pending pairing request while clearing device trust policy")
    }

    private func awaitDecision(requestId: UUID) async throws -> Decision {
        try Task.checkCancellation()
        let waiterCount = continuationByRequestId[requestId]?.count ?? 0
        guard waiterCount < Self.maximumWaitersPerRequest else {
            logger.error(
                "Pairing trust approval admission rejected: requestId=\(requestId.uuidString, privacy: .private) maximum=\(Self.maximumWaitersPerRequest, privacy: .public)"
            )
            throw PairingTrustApprovalAdmissionError.waiterLimitExceeded(
                maximum: Self.maximumWaitersPerRequest
            )
        }
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationByRequestId[requestId, default: [:]][waiterId] = continuation
                if Task.isCancelled {
                    cancelDecisionWaiter(requestId: requestId, waiterId: waiterId)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelDecisionWaiter(requestId: requestId, waiterId: waiterId)
            }
        }
    }

    private func cancelDecisionWaiter(requestId: UUID, waiterId: UUID) {
        guard let continuation = continuationByRequestId[requestId]?.removeValue(forKey: waiterId) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if continuationByRequestId[requestId]?.isEmpty == true {
            continuationByRequestId.removeValue(forKey: requestId)
            if resolutionTaskByRequestId[requestId] != nil {
                logger.info("Last waiter cancelled after pairing decision commit; durable resolution continues")
                return
            }
            protocolIdentityPinContextByRequestId.removeValue(forKey: requestId)
            clearPendingPresentation(requestId: requestId)
        }
    }

    private func clearPendingPresentation(requestId: UUID) {
        guard pendingRequest?.id == requestId else { return }
        pendingRequest = nil
        pendingDecision = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
    }

    public func clearPolicy(for declaredDeviceId: String) throws {
        try clearPolicies(for: [declaredDeviceId])
    }
    
    /// Ask the user to approve a pairing/trust request, or return immediately if a policy exists.
    public func decide(for request: Request) async throws -> Decision {
        try requirePolicyStoreReady()
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            logger.info("🧪 Smoke auto-approving pairing request for deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
            let bindingKey = request.policyBindingKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return bindingKey?.isEmpty == false ? .alwaysAllow : .allowOnce
        }

        if let policy = try persistedPolicyDecision(for: request) {
            return policy
        }

        // Only one prompt at a time (keep first to avoid UI spam).
        if let pendingRequest {
            if pendingDecision != nil {
                logger.warning("Pairing request rejected while a resolved verification sheet remains open. deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
                return .reject
            }
            if isSameTrustRequest(pendingRequest, request) {
                logger.info("Pairing request coalesced with pending prompt for deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
                return try await awaitDecision(requestId: pendingRequest.id)
            }
            logger.warning("Pairing request ignored because another prompt is pending. deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
            return .reject
        }

        pendingDecision = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
        pendingRequest = request
        logger.info("🔔 Pairing/trust approval required: name=\(Self.protocolIdentityLogRedaction, privacy: .public) deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
        
        return try await awaitDecision(requestId: request.id)
    }

    /// Returns a persisted allow/reject decision without creating a new approval prompt.
    public func persistedPolicyDecision(for request: Request) throws -> Decision? {
        try requirePolicyStoreReady()
        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindingKey = request.policyBindingKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bindingKey, !bindingKey.isEmpty {
            if let raw = policyByDeviceId[bindingKey],
               let policy = Decision(rawValue: raw) {
                switch policy {
                case .alwaysAllow, .reject:
                    return policy
                case .allowOnce:
                    break
                }
            }

            // A legacy device-level allow is not proof for a new protocol
            // identity. Preserve only an explicit deny as a safe migration.
            if let raw = policyByDeviceId[deviceId],
               Decision(rawValue: raw) == .reject {
                return .reject
            }
            return nil
        }

        if let raw = policyByDeviceId[deviceId],
           Decision(rawValue: raw) == .reject {
            return .reject
        }

        return nil
    }

    private func isSameTrustRequest(_ lhs: Request, _ rhs: Request) -> Bool {
        let lhsBinding = lhs.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsBinding = rhs.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lhsHasBinding = lhsBinding?.isEmpty == false
        let rhsHasBinding = rhsBinding?.isEmpty == false
        if lhsHasBinding || rhsHasBinding {
            return lhsHasBinding && rhsHasBinding && lhsBinding == rhsBinding
        }
        let lhsDeviceId = lhs.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsDeviceId = rhs.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhsDeviceId.isEmpty && lhsDeviceId == rhsDeviceId
    }
    
    /// Update the transcript-bound pairing verification code for the current prompt (if it matches the declared deviceId).
    public func updateVerificationCode(declaredDeviceId: String, sessionKeys: SessionKeys) {
        let deviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let req = pendingRequest,
              req.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines) == deviceId else { return }
        pendingVerificationCode = sessionKeys.pairingVerificationCode()
        pendingVerificationSuite = sessionKeys.negotiatedSuite.rawValue
        pendingVerificationUpdatedAt = Date()
    }

    /// Display a pre-handshake PIB-1 short authentication string. This is
    /// informational only; the peer that imports the protocol identity must
    /// still require its local operator approval before pinning it.
    public func showProtocolIdentityBindingCode(
        peerEndpoint: String,
        declaredDeviceId: String,
        displayName: String,
        model: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil,
        verificationCode: String,
        protocolIdentityFingerprint: String
    ) {
        guard pendingRequest == nil else {
            logger.warning(
                "PIB-1 informational verification code not displayed because another pairing prompt is active"
            )
            return
        }
        let request = Request(
            peerEndpoint: peerEndpoint,
            declaredDeviceId: declaredDeviceId,
            policyBindingKey: "PIB-1|\(declaredDeviceId)|\(protocolIdentityFingerprint.lowercased())",
            displayName: displayName,
            model: model,
            platform: platform,
            osVersion: osVersion,
            kemKeyCount: 0
        )
        pendingRequest = request
        pendingDecision = .allowOnce
        pendingVerificationCode = verificationCode
        pendingVerificationSuite = "PIB-1"
        pendingVerificationUpdatedAt = Date()
        logger.info(
            "🔐 PIB-1 verification code displayed: deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public)"
        )
    }

    public func stageProtocolIdentityBindingRequesterApproval(
        peerEndpoint: String,
        requesterDeviceIds: [String],
        displayName: String,
        model: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil,
        verificationCode: String,
        requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        requesterProtocolIdentityFingerprint: String
    ) async throws -> Decision {
        try requirePolicyStoreReady()
        let normalizedIds = normalizedUniqueDeviceIds(requesterDeviceIds)
        let normalizedFingerprint = requesterProtocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedIds.isEmpty,
              normalizedFingerprint.count == 64,
              normalizedFingerprint.allSatisfy(\.isHexDigit) else {
            return .reject
        }

        let declaredDeviceId = normalizedIds.first ?? "unknown"
        let policyBindingKey = "PIB-1-requester|\(declaredDeviceId)|\(requesterProtocolSigningAlgorithm.rawValue)|\(normalizedFingerprint)"
        if let raw = policyByDeviceId[policyBindingKey],
           let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                try Task.checkCancellation()
                guard try await pinProtocolIdentityRequester(
                    deviceIds: normalizedIds,
                    algorithm: requesterProtocolSigningAlgorithm,
                    fingerprint: normalizedFingerprint,
                    operatorLabel: "stored-policy"
                ) else { return .reject }
                try Task.checkCancellation()
                return policy
            case .reject:
                return policy
            case .allowOnce:
                break
            }
        }
        if let raw = policyByDeviceId[declaredDeviceId],
           Decision(rawValue: raw) == .reject {
            return .reject
        }

        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            try Task.checkCancellation()
            guard try await pinProtocolIdentityRequester(
                deviceIds: normalizedIds,
                algorithm: requesterProtocolSigningAlgorithm,
                fingerprint: normalizedFingerprint,
                operatorLabel: "smoke-auto-approve"
            ) else { return .reject }
            try Task.checkCancellation()
            return .alwaysAllow
        }

        let request = Request(
            peerEndpoint: peerEndpoint,
            declaredDeviceId: declaredDeviceId,
            policyBindingKey: policyBindingKey,
            displayName: displayName,
            model: model,
            platform: platform,
            osVersion: osVersion,
            kemKeyCount: 0
        )
        if let pendingRequest {
            if pendingDecision != nil {
                logger.warning("PIB-1 requester approval rejected while a resolved verification sheet remains open")
                return .reject
            }
            if isSameTrustRequest(pendingRequest, request) {
                logger.info("PIB-1 requester approval coalesced with pending prompt for deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
                return try await awaitDecision(requestId: pendingRequest.id)
            }
            logger.warning("PIB-1 requester approval rejected because another prompt is pending. deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
            return .reject
        }
        protocolIdentityPinContextByRequestId[request.id] = ProtocolIdentityPinContext(
            deviceIds: normalizedIds,
            algorithm: requesterProtocolSigningAlgorithm,
            fingerprint: normalizedFingerprint
        )
        pendingDecision = nil
        pendingVerificationCode = verificationCode
        pendingVerificationSuite = "PIB-1"
        pendingVerificationUpdatedAt = Date()
        pendingRequest = request
        logger.info(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(Self.protocolIdentityLogRedaction, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public) code=\(Self.protocolIdentityLogRedaction, privacy: .public)"
        )
        RemoteControlSmokeStatusWriter.append(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>awaiting-requester-approval"
        )
        return try await awaitDecision(requestId: request.id)
    }

    private func pinProtocolIdentityRequester(
        deviceIds: [String],
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        operatorLabel: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let stableDeviceId = stableProtocolIdentityDeviceId(from: deviceIds) else {
            let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=missing_stable_device_id lifecycle=identity-oob>requester-pin-failed"
            logger.warning("\(line, privacy: .public)")
            RemoteControlSmokeStatusWriter.append(line)
            return false
        }
        do {
            let promoted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
                deviceId: stableDeviceId,
                preferredCurrentDeviceId: stableDeviceId,
                knownDeviceIds: deviceIds,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyFingerprint: fingerprint,
                pinSource: .pib1OperatorApproval
            )
            guard promoted else {
                let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_record_not_promoted lifecycle=identity-oob>requester-pin-failed"
                logger.warning("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
                return false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TrustSyncError {
            if case .fallbackCleanupFailedAfterAuthoritativeCommit = error {
                let line = "⚠️ PIB-1 requester authority committed but stale fallback cleanup failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>requester-pin-fallback-cleanup-failed"
                logger.warning("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
            } else {
                let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=\(error.localizedDescription) lifecycle=identity-oob>requester-pin-failed"
                logger.error("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
                return false
            }
        } catch {
            let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=\(error.localizedDescription) lifecycle=identity-oob>requester-pin-failed"
            logger.error("\(line, privacy: .public)")
            RemoteControlSmokeStatusWriter.append(line)
            return false
        }
        try Task.checkCancellation()
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: deviceIds,
            fingerprints: [fingerprint]
        )
        try Task.checkCancellation()
        let line = "🔐 PIB-1 requester protocol identity pinned: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=\(operatorLabel) lifecycle=identity-oob>requester-pinned"
        logger.info("\(line, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(line)
        return true
    }

    private func stableProtocolIdentityDeviceId(from deviceIds: [String]) -> String? {
        for deviceId in deviceIds {
            if let persistent = PeerTrustLookup.persistentDeviceId(from: deviceId) {
                return persistent
            }
        }
        return nil
    }

    private func normalizedUniqueDeviceIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    /// Called when the user dismisses the sheet (ESC/click outside/close button).
    /// If the request hasn't been resolved yet, treat dismissal as `reject`.
    public func userDismissedCurrentPrompt() {
        guard let req = pendingRequest else { return }
        if resolutionTaskByRequestId[req.id] != nil {
            logger.info("Ignored dismissal after pairing decision reached its commit point")
            return
        }
        if continuationByRequestId[req.id]?.isEmpty == false {
            resolve(req, decision: .reject)
            return
        }

        resolutionTaskByRequestId.removeValue(forKey: req.id)?.cancel()
        protocolIdentityPinContextByRequestId.removeValue(forKey: req.id)
        clearPendingPresentation(requestId: req.id)
    }

    private func finishResolution(
        request: Request,
        decision: Decision,
        continuations: [DecisionContinuation]
    ) {
        for cont in continuations {
            cont.resume(returning: decision)
        }

        pendingDecision = decision

        // For allow decisions, keep the sheet open so we can surface the transcript-bound SAS code
        // after the follow-up (rekey) handshake completes. The user dismisses the sheet manually.
        if decision == .reject {
            clearPendingPresentation(requestId: request.id)
        }

        logger.info("Pairing/trust decision: \(decision.rawValue, privacy: .public) deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
    }

    private func persistPolicyDecision(_ decision: Decision, for request: Request) -> Decision {
        guard decision == .alwaysAllow || decision == .reject else { return decision }
        let bindingKey = request.policyBindingKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceId = request.declaredDeviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A durable allow must be bound to authenticated protocol identity.
        // Device IDs alone are peer-controlled aliases in several call paths,
        // so an unbound "always" choice is deliberately one-shot. A deny may
        // remain device-wide because that migration direction is fail-closed.
        if decision == .alwaysAllow, bindingKey?.isEmpty != false {
            logger.warning(
                "Unbound pairing trust allow downgraded to one-shot because no authenticated identity binding is available"
            )
            return .allowOnce
        }
        let policyKey = bindingKey?.isEmpty == false ? bindingKey : deviceId
        guard let policyKey, !policyKey.isEmpty else {
            logger.error("Pairing trust decision has no durable policy key")
            return decision == .reject ? .reject : .allowOnce
        }

        let previousPolicy = policyByDeviceId
        policyByDeviceId[policyKey] = decision.rawValue
        do {
            try savePolicy()
            return decision
        } catch {
            policyByDeviceId = previousPolicy
            logger.error(
                "Pairing trust decision could not be persisted; current request remains one-shot: err=\(error.localizedDescription, privacy: .private)"
            )
            return decision == .reject ? .reject : .allowOnce
        }
    }

    /// Resolve a pending request from UI.
    public func resolve(_ request: Request, decision: Decision) {
        guard pendingRequest?.id == request.id else {
            logger.warning("Ignored stale pairing trust resolution after request invalidation")
            return
        }
        guard pendingDecision == nil,
              resolutionTaskByRequestId[request.id] == nil else {
            logger.info("Ignored later pairing decision after the request reached its commit point")
            return
        }
        guard !policyStoreLoadFailed else {
            resolutionTaskByRequestId.removeValue(forKey: request.id)?.cancel()
            protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
            let continuations = continuationByRequestId
                .removeValue(forKey: request.id)
                .map { Array($0.values) } ?? []
            finishResolution(request: request, decision: .reject, continuations: continuations)
            return
        }
        if decision == .reject {
            // Rejection owns the request immediately. Cancel and detach any
            // in-flight identity pin before touching policy state so the old
            // allow task cannot resume later and commit stale authority.
            resolutionTaskByRequestId.removeValue(forKey: request.id)?.cancel()
            protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
            let continuations = continuationByRequestId
                .removeValue(forKey: request.id)
                .map { Array($0.values) } ?? []
            let effectiveDecision = persistPolicyDecision(.reject, for: request)
            finishResolution(
                request: request,
                decision: effectiveDecision,
                continuations: continuations
            )
            return
        }
        if let protocolIdentityContext = protocolIdentityPinContextByRequestId[request.id],
           decision != .reject {
            resolutionTaskByRequestId[request.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                var pinned = false
                do {
                    pinned = try await self.pinProtocolIdentityRequester(
                        deviceIds: protocolIdentityContext.deviceIds,
                        algorithm: protocolIdentityContext.algorithm,
                        fingerprint: protocolIdentityContext.fingerprint,
                        operatorLabel: "local-user"
                    )
                    try Task.checkCancellation()
                } catch {
                    pinned = false
                }
                self.resolutionTaskByRequestId.removeValue(forKey: request.id)
                guard !Task.isCancelled,
                      self.pendingRequest?.id == request.id else {
                    return
                }
                self.protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
                let continuations = self.continuationByRequestId
                    .removeValue(forKey: request.id)
                    .map { Array($0.values) } ?? []
                let finalDecision: Decision = pinned
                    ? self.persistPolicyDecision(decision, for: request)
                    : .reject
                self.finishResolution(
                    request: request,
                    decision: finalDecision,
                    continuations: continuations
                )
            }
            return
        }

        protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
        let continuations = continuationByRequestId
            .removeValue(forKey: request.id)
            .map { Array($0.values) } ?? []
        let effectiveDecision = persistPolicyDecision(decision, for: request)
        finishResolution(
            request: request,
            decision: effectiveDecision,
            continuations: continuations
        )
    }
}
