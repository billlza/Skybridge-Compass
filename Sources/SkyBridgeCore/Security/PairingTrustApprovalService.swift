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
    
    /// deviceId -> decisionRawValue (persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var policyByDeviceId: [String: String] = [:]
    
    private var continuationByRequestId: [UUID: [CheckedContinuation<Decision, Never>]] = [:]
    private struct ProtocolIdentityPinContext: Sendable {
        let deviceIds: [String]
        let fingerprint: String
        let verificationCode: String
    }

    private var protocolIdentityPinContextByRequestId: [UUID: ProtocolIdentityPinContext] = [:]
    
    private init() {
        policyByDeviceId = Self.loadPolicy()
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
    
    private static func loadPolicy() -> [String: String] {
        Self.policyStore.load() ?? [:]
    }
    
    private func savePolicy() {
        try? Self.policyStore.save(policyByDeviceId)
    }
    
    /// Clear persisted policy for a device (used when user removes trust).
    public func clearPolicy(for declaredDeviceId: String) {
        let trimmedDeviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeviceId.isEmpty else { return }
        let keysToRemove = policyByDeviceId.keys.filter {
            $0 == trimmedDeviceId || $0.hasPrefix("\(trimmedDeviceId)|")
        }
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            policyByDeviceId.removeValue(forKey: key)
        }
        savePolicy()
        logger.info("🔓 Cleared pairing trust policy for deviceId=\(trimmedDeviceId, privacy: .public)")
    }
    
    /// Ask the user to approve a pairing/trust request, or return immediately if a policy exists.
    public func decide(for request: Request) async -> Decision {
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            logger.info("🧪 Smoke auto-approving pairing request for deviceId=\(request.declaredDeviceId, privacy: .public)")
            return .alwaysAllow
        }

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

        // Only one prompt at a time (keep first to avoid UI spam).
        if let pendingRequest {
            if isSameTrustRequest(pendingRequest, request) {
                if let pendingDecision {
                    logger.info("Pairing request reused existing decision for deviceId=\(deviceId, privacy: .public) decision=\(pendingDecision.rawValue, privacy: .public)")
                    return pendingDecision
                }
                logger.info("Pairing request coalesced with pending prompt for deviceId=\(deviceId, privacy: .public)")
                return await withCheckedContinuation { cont in
                    continuationByRequestId[pendingRequest.id, default: []].append(cont)
                }
            }
            logger.warning("Pairing request ignored because another prompt is pending. deviceId=\(deviceId, privacy: .public)")
            return .reject
        }

        pendingDecision = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
        pendingRequest = request
        logger.info("🔔 Pairing/trust approval required: name=\(request.displayName, privacy: .public) deviceId=\(deviceId, privacy: .public)")
        
        return await withCheckedContinuation { cont in
            continuationByRequestId[request.id, default: []].append(cont)
        }
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
            "🔐 PIB-1 verification code displayed: deviceId=\(declaredDeviceId, privacy: .public) fp=\(protocolIdentityFingerprint, privacy: .public)"
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
        requesterProtocolIdentityFingerprint: String
    ) async -> Decision {
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
        let policyBindingKey = "PIB-1-requester|\(declaredDeviceId)|\(normalizedFingerprint)"
        if let raw = policyByDeviceId[policyBindingKey],
           let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                await pinProtocolIdentityRequester(
                    deviceIds: normalizedIds,
                    fingerprint: normalizedFingerprint,
                    verificationCode: verificationCode,
                    operatorLabel: "stored-policy"
                )
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
            case .alwaysAllow:
                await pinProtocolIdentityRequester(
                    deviceIds: normalizedIds,
                    fingerprint: normalizedFingerprint,
                    verificationCode: verificationCode,
                    operatorLabel: "stored-policy"
                )
                return policy
            case .reject:
                return policy
            case .allowOnce:
                break
            }
        }

        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            await pinProtocolIdentityRequester(
                deviceIds: normalizedIds,
                fingerprint: normalizedFingerprint,
                verificationCode: verificationCode,
                operatorLabel: "smoke-auto-approve"
            )
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
            if isSameTrustRequest(pendingRequest, request) {
                if let pendingDecision {
                    return pendingDecision
                }
                logger.info("PIB-1 requester approval coalesced with pending prompt for deviceId=\(declaredDeviceId, privacy: .public)")
                return await withCheckedContinuation { cont in
                    continuationByRequestId[pendingRequest.id, default: []].append(cont)
                }
            }
            logger.warning("PIB-1 requester approval rejected because another prompt is pending. deviceId=\(declaredDeviceId, privacy: .public)")
            return .reject
        }
        protocolIdentityPinContextByRequestId[request.id] = ProtocolIdentityPinContext(
            deviceIds: normalizedIds,
            fingerprint: normalizedFingerprint,
            verificationCode: verificationCode
        )
        pendingDecision = nil
        pendingVerificationCode = verificationCode
        pendingVerificationSuite = "PIB-1"
        pendingVerificationUpdatedAt = Date()
        pendingRequest = request
        logger.info(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(declaredDeviceId, privacy: .public) fp=\(normalizedFingerprint, privacy: .public) code=\(verificationCode, privacy: .public)"
        )
        RemoteControlSmokeStatusWriter.append(
            "🔐 PIB-1 requester protocol identity approval required: requester=\(declaredDeviceId) fingerprint=\(normalizedFingerprint) code=\(verificationCode) lifecycle=identity-oob>awaiting-requester-approval"
        )
        return await withCheckedContinuation { cont in
            continuationByRequestId[request.id, default: []].append(cont)
        }
    }

    private func pinProtocolIdentityRequester(
        deviceIds: [String],
        fingerprint: String,
        verificationCode: String,
        operatorLabel: String
    ) async {
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: deviceIds,
            fingerprints: [fingerprint]
        )
        let line = "🔐 PIB-1 requester protocol identity pinned: requester=\(deviceIds.first ?? "-") fingerprint=\(fingerprint) code=\(verificationCode) operator=\(operatorLabel) lifecycle=identity-oob>requester-pinned"
        logger.info("\(line, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(line)
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
        if continuationByRequestId[req.id]?.isEmpty == false {
            resolve(req, decision: .reject)
            return
        }

        protocolIdentityPinContextByRequestId.removeValue(forKey: req.id)
        pendingRequest = nil
        pendingDecision = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
    }

    private func finishResolution(
        request: Request,
        decision: Decision,
        continuations: [CheckedContinuation<Decision, Never>]
    ) {
        for cont in continuations {
            cont.resume(returning: decision)
        }

        pendingDecision = decision

        // For allow decisions, keep the sheet open so we can surface the transcript-bound SAS code
        // after the follow-up (rekey) handshake completes. The user dismisses the sheet manually.
        if decision == .reject {
            pendingRequest = nil
            pendingDecision = nil
            pendingVerificationCode = nil
            pendingVerificationSuite = nil
            pendingVerificationUpdatedAt = nil
        }

        logger.info("Pairing/trust decision: \(decision.rawValue, privacy: .public) deviceId=\(request.declaredDeviceId, privacy: .public)")
    }

    /// Resolve a pending request from UI.
    public func resolve(_ request: Request, decision: Decision) {
        let protocolIdentityContext = protocolIdentityPinContextByRequestId.removeValue(forKey: request.id)
        switch decision {
        case .alwaysAllow, .reject:
            let deviceId = request.declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deviceId.isEmpty {
                policyByDeviceId[deviceId] = decision.rawValue
            }
            if let bindingKey = request.policyBindingKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bindingKey.isEmpty {
                policyByDeviceId[bindingKey] = decision.rawValue
            }
            savePolicy()
        case .allowOnce:
            break
        }

        let continuations = continuationByRequestId.removeValue(forKey: request.id) ?? []
        if let protocolIdentityContext, decision != .reject {
            Task { @MainActor in
                await self.pinProtocolIdentityRequester(
                    deviceIds: protocolIdentityContext.deviceIds,
                    fingerprint: protocolIdentityContext.fingerprint,
                    verificationCode: protocolIdentityContext.verificationCode,
                    operatorLabel: "local-user"
                )
                self.finishResolution(
                    request: request,
                    decision: decision,
                    continuations: continuations
                )
            }
            return
        }

        finishResolution(
            request: request,
            decision: decision,
            continuations: continuations
        )
    }
}
