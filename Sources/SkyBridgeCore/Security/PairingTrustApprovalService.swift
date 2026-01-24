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
        
        pendingRequest = request
        logger.info("🔔 Pairing/trust approval required: name=\(request.displayName, privacy: .public) deviceId=\(deviceId, privacy: .public)")
        
        return await withCheckedContinuation { cont in
            continuationByRequestId[request.id] = cont
        }
    }
    
    /// Resolve a pending request from UI.
    public func resolve(_ request: Request, decision: Decision) {
        defer {
            pendingRequest = nil
        }
        
        if decision == .alwaysAllow || decision == .reject {
            policyByDeviceId[request.declaredDeviceId] = decision.rawValue
            savePolicy()
        }
        
        if let cont = continuationByRequestId.removeValue(forKey: request.id) {
            cont.resume(returning: decision)
        }
        
        logger.info("Pairing/trust decision: \(decision.rawValue, privacy: .public) deviceId=\(request.declaredDeviceId, privacy: .public)")
    }
}


