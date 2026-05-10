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

    /// Called when the user dismisses the sheet (ESC/click outside/close button).
    /// If the request hasn't been resolved yet, treat dismissal as `reject`.
    public func userDismissedCurrentPrompt() {
        guard let req = pendingRequest else { return }
        if continuationByRequestId[req.id]?.isEmpty == false {
            resolve(req, decision: .reject)
            return
        }

        pendingRequest = nil
        pendingDecision = nil
        pendingVerificationCode = nil
        pendingVerificationSuite = nil
        pendingVerificationUpdatedAt = nil
    }

    /// Resolve a pending request from UI.
    public func resolve(_ request: Request, decision: Decision) {
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
        
        if let continuations = continuationByRequestId.removeValue(forKey: request.id) {
            for cont in continuations {
                cont.resume(returning: decision)
            }
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
}
