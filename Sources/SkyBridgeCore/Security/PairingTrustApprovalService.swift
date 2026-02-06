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
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PairingTrustApproval")
    private let policyKey = "com.skybridge.pairingTrust.policy.v1"
    
    /// deviceId -> decisionRawValue (persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var policyByDeviceId: [String: String] = [:]
    
    private var continuationByRequestId: [UUID: CheckedContinuation<Decision, Never>] = [:]
    
    private init() {
        policyByDeviceId = Self.loadPolicy(key: policyKey)
        logger.info("🔐 PairingTrustApprovalService initialized")
    }
    
    private static func loadPolicy(key: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    
    private func savePolicy() {
        let data = (try? JSONEncoder().encode(policyByDeviceId)) ?? Data()
        UserDefaults.standard.set(data, forKey: policyKey)
    }
    
    /// Clear persisted policy for a device (used when user removes trust).
    public func clearPolicy(for declaredDeviceId: String) {
        if policyByDeviceId.removeValue(forKey: declaredDeviceId) != nil {
            savePolicy()
            logger.info("🔓 Cleared pairing trust policy for deviceId=\(declaredDeviceId, privacy: .public)")
        }
    }
    
    /// Ask the user to approve a pairing/trust request, or return immediately if a policy exists.
    public func decide(for request: Request) async -> Decision {
        let deviceId = request.declaredDeviceId
        if let raw = policyByDeviceId[deviceId], let policy = Decision(rawValue: raw) {
            switch policy {
            case .alwaysAllow, .reject:
                return policy
            case .allowOnce:
                break
            }
        }
        
        // Only one prompt at a time (keep first to avoid UI spam).
        if pendingRequest != nil {
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
            continuationByRequestId[request.id] = cont
        }
    }
    
    /// Update the transcript-bound pairing verification code for the current prompt (if it matches the declared deviceId).
    public func updateVerificationCode(declaredDeviceId: String, sessionKeys: SessionKeys) {
        guard let req = pendingRequest, req.declaredDeviceId == declaredDeviceId else { return }
        pendingVerificationCode = sessionKeys.pairingVerificationCode()
        pendingVerificationSuite = sessionKeys.negotiatedSuite.rawValue
        pendingVerificationUpdatedAt = Date()
    }

    /// Called when the user dismisses the sheet (ESC/click outside/close button).
    /// If the request hasn't been resolved yet, treat dismissal as `reject`.
    public func userDismissedCurrentPrompt() {
        guard let req = pendingRequest else { return }
        if continuationByRequestId[req.id] != nil {
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
        if decision == .alwaysAllow || decision == .reject {
            policyByDeviceId[request.declaredDeviceId] = decision.rawValue
            savePolicy()
        }
        
        if let cont = continuationByRequestId.removeValue(forKey: request.id) {
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
}

