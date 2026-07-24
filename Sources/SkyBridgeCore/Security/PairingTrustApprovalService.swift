import Foundation
import OSLog

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
        public let protocolIdentityAlgorithm: String?
        public let protocolIdentityFingerprint: String?
        public let protocolIdentityTransactionId: UUID?
        public let protocolIdentityRequestHashHex: String?
        public let protocolIdentityCandidateHashHex: String?
        public let protocolIdentitySASTranscriptHashHex: String?
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
            protocolIdentityAlgorithm: String? = nil,
            protocolIdentityFingerprint: String? = nil,
            protocolIdentityTransactionId: UUID? = nil,
            protocolIdentityRequestHashHex: String? = nil,
            protocolIdentityCandidateHashHex: String? = nil,
            protocolIdentitySASTranscriptHashHex: String? = nil,
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
            self.protocolIdentityAlgorithm = protocolIdentityAlgorithm
            self.protocolIdentityFingerprint = protocolIdentityFingerprint
            self.protocolIdentityTransactionId = protocolIdentityTransactionId
            self.protocolIdentityRequestHashHex = protocolIdentityRequestHashHex
            self.protocolIdentityCandidateHashHex = protocolIdentityCandidateHashHex
            self.protocolIdentitySASTranscriptHashHex = protocolIdentitySASTranscriptHashHex
            self.kemKeyCount = kemKeyCount
            self.receivedAt = receivedAt
        }
    }
    
    /// Current pending request (drives UI sheet).
    @Published public private(set) var pendingRequest: Request?

    /// Decision selected for the current pending request (set after user action).
    @Published public private(set) var pendingDecision: Decision?

    /// True after an explicit decision has committed and while its pin/policy writes finish.
    /// Dismissal cannot rewrite an accepted decision during this interval.
    @Published public private(set) var isPendingResolutionInFlight = false

    /// User-visible detail for a safe degradation such as an Always Allow policy
    /// that could not be persisted and was therefore applied to this session only.
    @Published public private(set) var pendingResolutionNotice: String?

    /// 6-digit SAS verification code derived from the current session's transcript hash.
    @Published public private(set) var pendingVerificationCode: String?

    /// Negotiated suite for which `pendingVerificationCode` was derived.
    @Published public private(set) var pendingVerificationSuite: String?

    /// Last time the verification fields were updated (best-effort).
    @Published public private(set) var pendingVerificationUpdatedAt: Date?
    
    nonisolated private static let policyStore = CodablePersistenceStore<[String: String]>(
        location: .protectedApplicationSupport(
            path: "PairingTrust/policy.json",
            legacyUserDefaultsKey: "com.skybridge.pairingTrust.policy.v1"
        )
    )
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PairingTrustApproval")
    private nonisolated static var protocolIdentityLogRedaction: String { "<redacted>" }
    
    /// deviceId -> decisionRawValue (persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var policyByDeviceId: [String: String] = [:]
    private let policyLoadTask: Task<[String: String]?, Error>
    private var policyLoaded = false
    private var policyLoadFailed = false
    
    private struct DecisionWaiter {
        let continuation: CheckedContinuation<Decision, Never>
        let timeoutTask: Task<Void, Never>?
    }
    private static let maximumCoalescedWaiters = 8
    private static let maximumPolicyEntries = 1_024
    private static let maximumRequesterDeviceIds = 16
    private static let maximumDeviceIdLength = 256
    private let decisionTimeout: Duration = .seconds(180)
    private var waitersByRequestId: [UUID: [UUID: DecisionWaiter]] = [:]
    private var earlyDecisionByRequestId: [UUID: Decision] = [:]
    private var resolutionTasksByRequestId: [UUID: Task<Void, Never>] = [:]
    private var requestIDsWithoutActiveWaiters: Set<UUID> = []
    private struct ProtocolIdentityPinContext: Sendable {
        let deviceIds: [String]
        let algorithm: ProtocolSigningAlgorithm
        let fingerprint: String
        let publicKey: Data?
    }

    private var protocolIdentityPinContextByRequestId: [UUID: ProtocolIdentityPinContext] = [:]
    private struct ApprovedProtocolIdentityContext: Sendable {
        let request: Request
        let deviceIds: [String]
        let algorithm: ProtocolSigningAlgorithm
        let fingerprint: String
        let publicKey: Data?
        let decision: Decision
        let expiresAt: Date
    }

    private static let maximumApprovedProtocolIdentityContexts = 32
    private static let approvedProtocolIdentityContextTTL: TimeInterval = 300
    private var approvedProtocolIdentityContexts: [UUID: ApprovedProtocolIdentityContext] = [:]
#if DEBUG || SKYBRIDGE_TESTING
    typealias ProtocolIdentityPinOperationForTesting = @MainActor @Sendable (
        _ deviceIds: [String],
        _ algorithm: ProtocolSigningAlgorithm,
        _ fingerprint: String
    ) async -> Bool

    private var protocolIdentityPinResultOverrideForTesting: Bool?
    private var protocolIdentityPinOperationForTesting: ProtocolIdentityPinOperationForTesting?
    private var policySaveResultOverrideForTesting: Bool?

    func setProtocolIdentityPinResultOverrideForTesting(_ result: Bool?) {
        protocolIdentityPinResultOverrideForTesting = result
    }

    func setProtocolIdentityPinOperationForTesting(
        _ operation: ProtocolIdentityPinOperationForTesting?
    ) {
        protocolIdentityPinOperationForTesting = operation
    }

    func setPolicySaveResultOverrideForTesting(_ result: Bool?) {
        policySaveResultOverrideForTesting = result
    }

    func pendingWaiterCountForTesting(requestID: UUID) -> Int {
        waitersByRequestId[requestID]?.count ?? 0
    }
#endif
    
    private init() {
        policyLoadTask = Task.detached(priority: .utility) {
            try Self.policyStore.loadOrThrow()
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
    
    private func ensurePolicyLoaded() async -> Bool {
        if policyLoaded { return true }
        if policyLoadFailed { return false }
        do {
            let loadedPolicy = try await policyLoadTask.value ?? [:]
            guard loadedPolicy.count <= Self.maximumPolicyEntries,
                  loadedPolicy.keys.allSatisfy({ !$0.isEmpty && $0.count <= 768 }),
                  loadedPolicy.values.allSatisfy({
                      $0 == Decision.alwaysAllow.rawValue || $0 == Decision.reject.rawValue
                  }) else {
                policyLoadFailed = true
                logger.fault("Pairing trust policy failed structural validation; approvals are fail closed")
                return false
            }
            policyByDeviceId = loadedPolicy
            policyLoaded = true
            return true
        } catch {
            policyLoadFailed = true
            logger.fault("Pairing trust policy load failed; approvals are fail closed. errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)")
            return false
        }
    }

    private func savePolicySnapshot(_ snapshot: [String: String]) async -> Bool {
        guard policyLoaded, !policyLoadFailed else { return false }
#if DEBUG || SKYBRIDGE_TESTING
        if let policySaveResultOverrideForTesting {
            return policySaveResultOverrideForTesting
        }
#endif
        do {
            try await Task.detached(priority: .utility) {
                try Self.policyStore.save(snapshot)
            }.value
            return true
        } catch {
            logger.error("Failed to persist pairing trust policy errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)")
            return false
        }
    }
    
    /// Clear persisted policy for a device (used when user removes trust).
    @discardableResult
    public func clearPolicy(for declaredDeviceId: String) async -> Bool {
        guard await ensurePolicyLoaded() else { return false }
        let trimmedDeviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeviceId.isEmpty else { return false }
        let keysToRemove = policyByDeviceId.keys.filter {
            $0 == trimmedDeviceId || $0.hasPrefix("\(trimmedDeviceId)|")
        }
        guard !keysToRemove.isEmpty else { return true }
        var updatedPolicy = policyByDeviceId
        for key in keysToRemove {
            updatedPolicy.removeValue(forKey: key)
        }
        guard await savePolicySnapshot(updatedPolicy) else { return false }
        policyByDeviceId = updatedPolicy
        logger.info("🔓 Cleared pairing trust policy for deviceId=\(trimmedDeviceId, privacy: .private)")
        return true
    }
    
    /// Ask the user to approve a pairing/trust request, or return immediately if a policy exists.
    public func decide(for request: Request) async -> Decision {
        guard await ensurePolicyLoaded() else { return .reject }
        guard isValidRequest(request) else {
            logger.warning("Rejected malformed pairing/trust request")
            return .reject
        }
        if let policy = await persistedPolicyDecision(for: request) {
            return policy
        }

        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only one prompt at a time (keep first to avoid UI spam).
        clearCompletedPromptBeforeNewAuthorization()
        if let pendingRequest {
            if isSameTrustRequest(pendingRequest, request) {
                guard (waitersByRequestId[pendingRequest.id]?.count ?? 0)
                        < Self.maximumCoalescedWaiters else {
                    logger.warning("Pairing approval waiter limit reached")
                    return .reject
                }
                logger.info("Pairing request coalesced with pending prompt for deviceId=\(deviceId, privacy: .private)")
                return await waitForDecision(requestId: pendingRequest.id)
            }
            logger.warning("Pairing request ignored because another prompt is pending. deviceId=\(deviceId, privacy: .private)")
            return .reject
        }

        pendingDecision = nil
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
        pendingRequest = request
        logger.info("🔔 Pairing/trust approval required: name=\(request.displayName, privacy: .private) deviceId=\(deviceId, privacy: .private)")
        
        return await waitForDecision(requestId: request.id)
    }

    /// Requester-side PIB-1 v3 approval after the signed candidate has arrived,
    /// so the local operator can compare the exact transcript-bound SAS before a
    /// signed confirmation is sent. This method never pins protocol identity.
    public func decideProtocolIdentityBindingCandidate(
        for request: Request,
        verificationCode: String
    ) async -> Decision {
        guard await ensurePolicyLoaded(), isValidRequest(request) else { return .reject }
        let normalizedCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidShortAuthenticationString(normalizedCode),
              request.policyBindingKey?.hasPrefix("PIB-1-peer|") == true else {
            return .reject
        }
        if let bindingKey = request.policyBindingKey,
           let raw = policyByDeviceId[bindingKey],
           let policy = Decision(rawValue: raw),
           policy != .allowOnce {
            return policy
        }
        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if policyByDeviceId[deviceId] == Decision.reject.rawValue {
            return .reject
        }

        clearCompletedPromptBeforeNewAuthorization()
        if let pendingRequest {
            guard isSameProtocolIdentityRequesterApproval(
                pendingRequest,
                request,
                verificationCode: normalizedCode
            ),
            (waitersByRequestId[pendingRequest.id]?.count ?? 0) < Self.maximumCoalescedWaiters else {
                return .reject
            }
            return await waitForDecision(requestId: pendingRequest.id)
        }

        pendingDecision = nil
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = normalizedCode
        pendingVerificationSuite = "PIB-1-v3"
        pendingVerificationUpdatedAt = Date()
        pendingRequest = request
        return await waitForDecision(requestId: request.id)
    }

    /// Returns a persisted allow/reject decision without creating a new approval prompt.
    public func persistedPolicyDecision(for request: Request) async -> Decision? {
        guard await ensurePolicyLoaded() else { return .reject }
        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bindingKey = request.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindingKey.isEmpty,
           let raw = policyByDeviceId[bindingKey],
           let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow, .reject:
                return policy
            case .allowOnce:
                break
            }
        }

        if let raw = policyByDeviceId[deviceId], let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow, .reject:
                return policy
            case .allowOnce:
                break
            }
        }

        return nil
    }

    private func isSameTrustRequest(_ lhs: Request, _ rhs: Request) -> Bool {
        let lhsBinding = lhs.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsBinding = rhs.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsBinding, let rhsBinding, !lhsBinding.isEmpty, !rhsBinding.isEmpty {
            return lhsBinding == rhsBinding
        }
        let lhsDeviceId = lhs.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsDeviceId = rhs.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhsDeviceId.isEmpty && lhsDeviceId == rhsDeviceId
    }

    private func clearCompletedPromptBeforeNewAuthorization() {
        guard pendingDecision != nil else { return }
        pendingRequest = nil
        pendingDecision = nil
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
    }

    private func isValidRequest(_ request: Request) -> Bool {
        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = request.peerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty,
              deviceId.count <= Self.maximumDeviceIdLength,
              !endpoint.isEmpty,
              endpoint.count <= 512,
              !displayName.isEmpty,
              displayName.count <= 256,
              request.kemKeyCount >= 0,
              request.kemKeyCount <= 16 else {
            return false
        }
        guard [request.model, request.platform, request.osVersion]
            .compactMap({ $0 })
            .allSatisfy({ $0.count <= 128 }) else {
            return false
        }
        if let algorithm = request.protocolIdentityAlgorithm {
            let normalizedAlgorithm = algorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAlgorithm.isEmpty, normalizedAlgorithm.count <= 64 else { return false }
        }
        if let fingerprint = request.protocolIdentityFingerprint {
            guard Self.isValidProtocolIdentityFingerprint(fingerprint) else { return false }
        }
        for hash in [
            request.protocolIdentityRequestHashHex,
            request.protocolIdentityCandidateHashHex,
            request.protocolIdentitySASTranscriptHashHex
        ].compactMap({ $0 }) {
            guard Self.isValidProtocolIdentityFingerprint(hash.lowercased()) else { return false }
        }
        return true
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
        let normalizedCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = protocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard pendingRequest == nil,
              Self.isValidShortAuthenticationString(normalizedCode),
              Self.isValidProtocolIdentityFingerprint(normalizedFingerprint) else {
            logger.warning("Refused informational PIB-1 code because another prompt is pending or the payload is malformed")
            return
        }
        let request = Request(
            peerEndpoint: peerEndpoint,
            declaredDeviceId: declaredDeviceId,
            policyBindingKey: "PIB-1|\(declaredDeviceId)|\(normalizedFingerprint)",
            displayName: displayName,
            model: model,
            platform: platform,
            osVersion: osVersion,
            kemKeyCount: 0
        )
        pendingRequest = request
        pendingDecision = .allowOnce
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = normalizedCode
        pendingVerificationSuite = "PIB-1-v3-candidate"
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
        requesterProtocolIdentityFingerprint: String,
        requesterProtocolIdentityPublicKey: Data? = nil,
        transactionId: UUID? = nil,
        requestHashHex: String? = nil,
        candidateHashHex: String? = nil,
        sasTranscriptHashHex: String? = nil
    ) async -> Decision {
        guard await ensurePolicyLoaded() else { return .reject }
        let normalizedIds = normalizedUniqueDeviceIds(requesterDeviceIds)
        let normalizedFingerprint = requesterProtocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedVerificationCode = verificationCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validatedPublicKey: Data?
        if let requesterProtocolIdentityPublicKey {
            do {
                try ProtocolIdentityBinding.validateKeyEncoding(
                    bytes: requesterProtocolIdentityPublicKey,
                    algorithm: requesterProtocolSigningAlgorithm
                )
            } catch {
                return .reject
            }
            guard ProtocolIdentityBinding.computeFingerprint(
                algorithm: requesterProtocolSigningAlgorithm,
                publicKeyBytes: requesterProtocolIdentityPublicKey
            ).lowercased() == normalizedFingerprint else {
                return .reject
            }
            validatedPublicKey = requesterProtocolIdentityPublicKey
        } else {
            guard requesterProtocolSigningAlgorithm != .mlDSA87 else { return .reject }
            validatedPublicKey = nil
        }
        guard !normalizedIds.isEmpty,
              normalizedIds.count <= Self.maximumRequesterDeviceIds,
              normalizedIds.allSatisfy({ $0.count <= Self.maximumDeviceIdLength }),
              Self.isValidProtocolIdentityFingerprint(normalizedFingerprint),
              Self.isValidShortAuthenticationString(normalizedVerificationCode),
              let transactionId,
              let requestHashHex = requestHashHex?.lowercased(),
              let candidateHashHex = candidateHashHex?.lowercased(),
              let sasTranscriptHashHex = sasTranscriptHashHex?.lowercased(),
              Self.isValidProtocolIdentityFingerprint(requestHashHex),
              Self.isValidProtocolIdentityFingerprint(candidateHashHex),
              Self.isValidProtocolIdentityFingerprint(sasTranscriptHashHex) else {
            return .reject
        }

        let declaredDeviceId = normalizedIds.first ?? "unknown"
        let policyBindingKey = "PIB-1-requester|\(declaredDeviceId)|\(requesterProtocolSigningAlgorithm.rawValue)|\(normalizedFingerprint)"
        let request = Request(
            peerEndpoint: peerEndpoint,
            declaredDeviceId: declaredDeviceId,
            policyBindingKey: policyBindingKey,
            displayName: displayName,
            model: model,
            platform: platform,
            osVersion: osVersion,
            protocolIdentityAlgorithm: requesterProtocolSigningAlgorithm.rawValue,
            protocolIdentityFingerprint: normalizedFingerprint,
            protocolIdentityTransactionId: transactionId,
            protocolIdentityRequestHashHex: requestHashHex,
            protocolIdentityCandidateHashHex: candidateHashHex,
            protocolIdentitySASTranscriptHashHex: sasTranscriptHashHex,
            kemKeyCount: 0
        )
        guard isValidRequest(request) else { return .reject }
        if let raw = policyByDeviceId[policyBindingKey],
           let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                guard recordApprovedProtocolIdentityContext(
                    request: request,
                    deviceIds: normalizedIds,
                    algorithm: requesterProtocolSigningAlgorithm,
                    fingerprint: normalizedFingerprint,
                    publicKey: validatedPublicKey,
                    decision: policy
                ) else { return .reject }
                return policy
            case .reject:
                return policy
            case .allowOnce:
                break
            }
        }
        if let raw = policyByDeviceId[declaredDeviceId],
           let policy = Decision(rawValue: raw) {
            switch policy {
            case .reject:
                return policy
            case .alwaysAllow, .allowOnce:
                logger.info("Ignored bare-device allow policy for fingerprint-bound PIB-1 requester approval")
                break
            }
        }

        clearCompletedPromptBeforeNewAuthorization()
        if let pendingRequest {
            if isSameProtocolIdentityRequesterApproval(
                pendingRequest,
                request,
                verificationCode: normalizedVerificationCode
            ) {
                guard (waitersByRequestId[pendingRequest.id]?.count ?? 0)
                        < Self.maximumCoalescedWaiters else {
                    return .reject
                }
                logger.info("PIB-1 requester approval coalesced with pending prompt for deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
                return await waitForDecision(requestId: pendingRequest.id)
            }
            logger.warning("PIB-1 requester approval rejected because another prompt is pending. deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public)")
            return .reject
        }
        protocolIdentityPinContextByRequestId[request.id] = ProtocolIdentityPinContext(
            deviceIds: normalizedIds,
            algorithm: requesterProtocolSigningAlgorithm,
            fingerprint: normalizedFingerprint,
            publicKey: validatedPublicKey
        )
        pendingDecision = nil
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = normalizedVerificationCode
        pendingVerificationSuite = "PIB-1"
        pendingVerificationUpdatedAt = Date()
        pendingRequest = request
        logger.info(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(Self.protocolIdentityLogRedaction, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public) code=\(Self.protocolIdentityLogRedaction, privacy: .public)"
        )
        RemoteControlSmokeStatusWriter.append(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>awaiting-requester-approval"
        )
        return await waitForDecision(requestId: request.id)
    }

    private func isSameProtocolIdentityRequesterApproval(
        _ lhs: Request,
        _ rhs: Request,
        verificationCode: String
    ) -> Bool {
        guard isSameTrustRequest(lhs, rhs),
              lhs.peerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.peerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
              lhs.protocolIdentityAlgorithm == rhs.protocolIdentityAlgorithm,
              lhs.protocolIdentityFingerprint == rhs.protocolIdentityFingerprint,
              lhs.protocolIdentityTransactionId == rhs.protocolIdentityTransactionId,
              lhs.protocolIdentityRequestHashHex == rhs.protocolIdentityRequestHashHex,
              lhs.protocolIdentityCandidateHashHex == rhs.protocolIdentityCandidateHashHex,
              lhs.protocolIdentitySASTranscriptHashHex == rhs.protocolIdentitySASTranscriptHashHex,
              pendingVerificationSuite?.hasPrefix("PIB-1") == true,
              pendingVerificationCode == verificationCode else {
            return false
        }
        return true
    }

    private func recordApprovedProtocolIdentityContext(
        request: Request,
        deviceIds: [String],
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        publicKey: Data?,
        decision: Decision,
        now: Date = Date()
    ) -> Bool {
        guard decision != .reject,
              let transactionId = request.protocolIdentityTransactionId else {
            return false
        }
        purgeExpiredApprovedProtocolIdentityContexts(now: now)
        if let existing = approvedProtocolIdentityContexts[transactionId] {
            return existing.request == request
                && existing.deviceIds == deviceIds
                && existing.algorithm == algorithm
                && existing.fingerprint == fingerprint
                && existing.publicKey == publicKey
                && existing.decision == decision
        }
        guard approvedProtocolIdentityContexts.count
                < Self.maximumApprovedProtocolIdentityContexts else {
            logger.error("PIB-1 approved transaction capacity reached; rejecting authorization")
            return false
        }
        approvedProtocolIdentityContexts[transactionId] = ApprovedProtocolIdentityContext(
            request: request,
            deviceIds: deviceIds,
            algorithm: algorithm,
            fingerprint: fingerprint,
            publicKey: publicKey,
            decision: decision,
            expiresAt: now.addingTimeInterval(Self.approvedProtocolIdentityContextTTL)
        )
        return true
    }

    private func purgeExpiredApprovedProtocolIdentityContexts(now: Date = Date()) {
        approvedProtocolIdentityContexts = approvedProtocolIdentityContexts.filter {
            $0.value.expiresAt > now
        }
    }

    /// Commits the responder-side requester pin only after PIB-1 v3 has
    /// revalidated the live transcript and signed the final ACK. The approval
    /// context is one-shot and transcript-bound; stale or mismatched commits
    /// fail closed.
    public func commitProtocolIdentityBindingRequesterApproval(
        decision: Decision,
        transactionId: UUID,
        requesterDeviceIds: [String],
        requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        requesterProtocolIdentityFingerprint: String,
        requesterProtocolIdentityPublicKey: Data? = nil,
        requestHashHex: String,
        candidateHashHex: String,
        sasTranscriptHashHex: String,
        now: Date = Date()
    ) async -> Decision {
        purgeExpiredApprovedProtocolIdentityContexts(now: now)
        guard decision != .reject,
              let context = approvedProtocolIdentityContexts.removeValue(forKey: transactionId),
              context.expiresAt > now else {
            return .reject
        }
        let normalizedIds = normalizedUniqueDeviceIds(requesterDeviceIds)
        let normalizedFingerprint = requesterProtocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard context.decision == decision,
              context.deviceIds == normalizedIds,
              context.algorithm == requesterProtocolSigningAlgorithm,
              context.fingerprint == normalizedFingerprint,
              context.publicKey == requesterProtocolIdentityPublicKey,
              context.request.protocolIdentityTransactionId == transactionId,
              context.request.protocolIdentityRequestHashHex == requestHashHex.lowercased(),
              context.request.protocolIdentityCandidateHashHex == candidateHashHex.lowercased(),
              context.request.protocolIdentitySASTranscriptHashHex == sasTranscriptHashHex.lowercased() else {
            logger.error("PIB-1 requester pin commit rejected because approval transcript did not match")
            return .reject
        }

        isPendingResolutionInFlight = true
        defer { isPendingResolutionInFlight = false }
        guard await pinProtocolIdentityRequester(
            deviceIds: normalizedIds,
            algorithm: requesterProtocolSigningAlgorithm,
            fingerprint: normalizedFingerprint,
            publicKey: context.publicKey,
            operatorLabel: decision == .alwaysAllow ? "always-allow" : "allow-once"
        ) else {
            pendingDecision = .reject
            pendingResolutionNotice = "协议身份授权未提交；权威信任写入失败，连接已拒绝。"
            return .reject
        }

        var effectiveDecision = decision
        if decision == .alwaysAllow,
           policyByDeviceId[context.request.policyBindingKey ?? ""]
                != Decision.alwaysAllow.rawValue {
            let persistedDecision = await persistPolicyDecision(decision, for: context.request)
            if persistedDecision != .alwaysAllow {
                pendingResolutionNotice = "协议身份已允许本次连接，但“始终允许”策略未能持久化。下次连接仍会再次询问。"
                let line = "⚠️ PIB-1 permanent requester policy persistence failed; continuing with explicit allow-once lifecycle=identity-oob>policy-downgraded"
                logger.error("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
                effectiveDecision = .allowOnce
            }
        }
        pendingDecision = effectiveDecision
        return effectiveDecision
    }

    private func pinProtocolIdentityRequester(
        deviceIds: [String],
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        publicKey: Data?,
        operatorLabel: String
    ) async -> Bool {
#if DEBUG || SKYBRIDGE_TESTING
        if let protocolIdentityPinOperationForTesting {
            return await protocolIdentityPinOperationForTesting(deviceIds, algorithm, fingerprint)
        }
        if let protocolIdentityPinResultOverrideForTesting {
            return protocolIdentityPinResultOverrideForTesting
        }
#endif
        guard !Task.isCancelled else { return false }
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
                authenticatedProtocolPublicKey: publicKey,
                pinSource: .pib1OperatorApproval
            )
            guard promoted else {
                let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_record_not_promoted lifecycle=identity-oob>requester-pin-failed"
                logger.warning("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
                return false
            }
        } catch {
            let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_store_error lifecycle=identity-oob>requester-pin-failed"
            logger.error("\(line, privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            RemoteControlSmokeStatusWriter.append(line)
            return false
        }
        let bootstrapCachePersisted = await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: deviceIds,
            fingerprints: [fingerprint]
        )
        if !bootstrapCachePersisted {
            pendingResolutionNotice = "协议身份权威信任已保存，但派生引导缓存未能持久化；本次授权有效，后续进程会失败关闭并要求重建。"
            let cacheLine = "⚠️ PIB-1 derived bootstrap cache persistence failed after authoritative TrustSync commit; authorization remains committed lifecycle=identity-oob>cache-persist-failed"
            logger.error("\(cacheLine, privacy: .public)")
            RemoteControlSmokeStatusWriter.append(cacheLine)
        }
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
        guard rawIds.count <= Self.maximumRequesterDeviceIds else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= Self.maximumDeviceIdLength else { return [] }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    nonisolated private static func isValidProtocolIdentityFingerprint(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    nonisolated private static func isValidShortAuthenticationString(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 6 && bytes.allSatisfy {
            $0 >= 48 && $0 <= 57
        }
    }

    /// Called when the user dismisses the sheet (ESC/click outside/close button).
    /// If the request hasn't been resolved yet, treat dismissal as `reject`.
    public func userDismissedCurrentPrompt() {
        guard let req = pendingRequest else { return }
        if resolutionTasksByRequestId[req.id] != nil || isPendingResolutionInFlight {
            logger.info("Ignored pairing prompt dismissal after an explicit decision committed")
            return
        }
        if waitersByRequestId[req.id]?.isEmpty == false {
            resolve(req, decision: .reject)
            return
        }

        protocolIdentityPinContextByRequestId.removeValue(forKey: req.id)
        pendingRequest = nil
        pendingDecision = nil
        isPendingResolutionInFlight = false
        pendingResolutionNotice = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
    }

    private func finishResolution(
        request: Request,
        decision: Decision
    ) {
        resolutionTasksByRequestId.removeValue(forKey: request.id)
        let waiters = waitersByRequestId
            .removeValue(forKey: request.id)
            .map { Array($0.values) }
            ?? []
        if waiters.isEmpty, requestIDsWithoutActiveWaiters.remove(request.id) == nil {
            earlyDecisionByRequestId = [request.id: decision]
        }
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: decision)
        }

        pendingDecision = decision
        isPendingResolutionInFlight = false

        // For allow decisions, keep the sheet open so we can surface the transcript-bound SAS code
        // after the follow-up (rekey) handshake completes. The user dismisses the sheet manually.
        if decision == .reject {
            pendingRequest = nil
            pendingDecision = nil
            pendingResolutionNotice = nil
            pendingVerificationCode = nil
            pendingVerificationSuite = nil
            pendingVerificationUpdatedAt = nil
        }

        logger.info("Pairing/trust decision: \(decision.rawValue, privacy: .public) deviceId=\(request.declaredDeviceId, privacy: .private)")
    }

    private func persistPolicyDecision(_ decision: Decision, for request: Request) async -> Decision {
        guard decision == .alwaysAllow || decision == .reject else {
            return decision
        }

        var updatedPolicy = policyByDeviceId
        let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bindingKey = request.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindingKey.isEmpty {
            updatedPolicy[bindingKey] = decision.rawValue
        } else if !deviceId.isEmpty {
            updatedPolicy[deviceId] = decision.rawValue
        }
        guard updatedPolicy.count <= Self.maximumPolicyEntries else {
            logger.error("Pairing trust policy capacity reached; refusing new policy")
            return .reject
        }
        guard await savePolicySnapshot(updatedPolicy) else { return .reject }
        policyByDeviceId = updatedPolicy
        return decision
    }

    /// Resolve a pending request from UI.
    public func resolve(_ request: Request, decision: Decision) {
        guard pendingRequest?.id == request.id else {
            logger.warning("Ignored stale pairing/trust resolution")
            return
        }
        guard resolutionTasksByRequestId[request.id] == nil else {
            logger.warning("Ignored duplicate pairing/trust resolution")
            return
        }

        isPendingResolutionInFlight = true
        pendingResolutionNotice = nil
        if let waiters = waitersByRequestId[request.id] {
            for waiter in waiters.values {
                waiter.timeoutTask?.cancel()
            }
        }

        if let protocolIdentityContext = protocolIdentityPinContextByRequestId
            .removeValue(forKey: request.id) {
            let resolutionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // PIB-1 v3 is a two-phase commit: an operator decision is not
                // authority to pin until the caller has revalidated the live
                // candidate/confirm transcript and produced the signed ACK.
                // Persisting Always Allow is likewise deferred so a stale
                // transaction cannot leave a durable allow policy behind.
                let effectiveDecision: Decision
                if decision == .reject {
                    effectiveDecision = .reject
                } else if recordApprovedProtocolIdentityContext(
                    request: request,
                    deviceIds: protocolIdentityContext.deviceIds,
                    algorithm: protocolIdentityContext.algorithm,
                    fingerprint: protocolIdentityContext.fingerprint,
                    publicKey: protocolIdentityContext.publicKey,
                    decision: decision
                ) {
                    effectiveDecision = decision
                } else {
                    effectiveDecision = .reject
                }
                finishResolution(request: request, decision: effectiveDecision)
            }
            resolutionTasksByRequestId[request.id] = resolutionTask
            return
        }

        let resolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let effectiveDecision = await persistPolicyDecision(decision, for: request)
            finishResolution(request: request, decision: effectiveDecision)
        }
        resolutionTasksByRequestId[request.id] = resolutionTask
    }

    private func waitForDecision(requestId: UUID) async -> Decision {
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .reject)
                    return
                }
                if let earlyDecision = earlyDecisionByRequestId.removeValue(forKey: requestId) {
                    continuation.resume(returning: earlyDecision)
                    return
                }
                let resolutionAlreadyCommitted = self.resolutionTasksByRequestId[requestId] != nil
                    || (self.isPendingResolutionInFlight && self.pendingRequest?.id == requestId)
                let timeoutTask: Task<Void, Never>? = resolutionAlreadyCommitted ? nil : Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: self.decisionTimeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        self.logger.error(
                            "Pairing approval timeout task failed; rejecting waiter. errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                        )
                        self.finishWaiter(
                            requestId: requestId,
                            waiterId: waiterId,
                            decision: .reject
                        )
                        return
                    }
                    self.finishWaiter(
                        requestId: requestId,
                        waiterId: waiterId,
                        decision: .reject
                    )
                }
                waitersByRequestId[requestId, default: [:]][waiterId] = DecisionWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(
                    requestId: requestId,
                    waiterId: waiterId,
                    decision: .reject
                )
            }
        }
    }

    private func finishWaiter(
        requestId: UUID,
        waiterId: UUID,
        decision: Decision
    ) {
        guard var waiters = waitersByRequestId[requestId],
              let waiter = waiters.removeValue(forKey: waiterId) else { return }
        waiter.timeoutTask?.cancel()
        if waiters.isEmpty {
            waitersByRequestId.removeValue(forKey: requestId)
            let resolutionCommitted = resolutionTasksByRequestId[requestId] != nil
                || (isPendingResolutionInFlight && pendingRequest?.id == requestId)
            if resolutionCommitted {
                requestIDsWithoutActiveWaiters.insert(requestId)
            } else {
                protocolIdentityPinContextByRequestId.removeValue(forKey: requestId)
                if pendingRequest?.id == requestId {
                    pendingRequest = nil
                    pendingDecision = nil
                    isPendingResolutionInFlight = false
                    pendingResolutionNotice = nil
                    pendingVerificationCode = nil
                    pendingVerificationSuite = nil
                    pendingVerificationUpdatedAt = nil
                }
            }
        } else {
            waitersByRequestId[requestId] = waiters
        }
        waiter.continuation.resume(returning: decision)
    }
}
