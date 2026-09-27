import Foundation
import SkyBridgeProtocolCore

public struct OperatorLocalApprovalRequest: Sendable {
    public enum Action: String, Sendable { case pending, decide }
    public enum Decision: String, Sendable { case allow_once, always_allow, reject }
    public let action: Action
    public let id: UUID?
    public let decision: Decision?
    public let verificationCode: String?

    public init(action: Action, params: CrossnetControlParams) throws {
        self.action = action
        id = params.string("approval_id").flatMap(UUID.init(uuidString:))
        decision = params.string("decision").flatMap(Decision.init(rawValue:))
        verificationCode = params.string("verification_code")
        guard action == .pending || (id != nil && decision != nil),
              !params.contains("verification_code") || verificationCode != nil else {
            throw CrossnetControlFailure.malformedRequest("approval decision requires the current request UUID and decision")
        }
    }
}

public struct OperatorLocalApproval: Codable, Sendable {
    public let id: String
    public let kind: String
    public let peer_id: String
    public let name: String
    public let fingerprint: String?
    public let verification_code: String?
    public let can_decide: Bool
}

public struct OperatorLocalApprovalResult: Codable, Sendable {
    public let runtime_target: String
    public let pending: [OperatorLocalApproval]
    public let decision_submitted: Bool
    public let approval_id: String?
    public init(pending: [OperatorLocalApproval], submitted: UUID? = nil) {
        runtime_target = "mac_app_runtime"; self.pending = pending
        decision_submitted = submitted != nil; approval_id = submitted?.uuidString
    }
}

/// Resolves the native owner's current prompt. It cannot create grants, choose
/// another peer, or approve a remote device's initial delegation to this Mac.
@MainActor
public enum OperatorLocalApprovals {
    public static let methods = ["crossnet.approval.pending", "crossnet.approval.decide"]

    public static func execute(_ request: OperatorLocalApprovalRequest) throws -> OperatorLocalApprovalResult {
        let pairing = PairingTrustApprovalService.shared
        let management = HandshakeConfigurationApproval.shared
        if request.action == .decide {
            guard let id = request.id, let decision = request.decision else {
                throw CrossnetControlFailure.malformedRequest("approval decision missing")
            }
            if let prompt = pairing.pendingRequest, prompt.id == id,
               pairing.pendingDecision == nil, !pairing.isPendingResolutionInFlight {
                if decision != .reject {
                    guard let expected = pairing.pendingVerificationCode,
                          let supplied = request.verificationCode,
                          code(supplied) != nil, code(supplied) == code(expected) else {
                        throw CrossnetControlFailure.sessionMutationRejected("approval_verification_code_mismatch")
                    }
                }
                pairing.resolve(prompt, decision: decision == .allow_once ? .allowOnce : (decision == .always_allow ? .alwaysAllow : .reject))
            } else if let prompt = management.pending, prompt.id == id {
                management.resolve(id, decision: decision == .allow_once ? .allowOnce : (decision == .always_allow ? .alwaysAllow : .reject))
            } else {
                throw CrossnetControlFailure.sessionMutationRejected("approval_expired_or_replaced")
            }
            return OperatorLocalApprovalResult(pending: pending(), submitted: id)
        }
        return OperatorLocalApprovalResult(pending: pending())
    }

    private static func pending() -> [OperatorLocalApproval] {
        var values: [OperatorLocalApproval] = []
        let pairing = PairingTrustApprovalService.shared
        if let request = pairing.pendingRequest {
            values.append(OperatorLocalApproval(id: request.id.uuidString, kind: "pairing",
                peer_id: request.declaredDeviceId, name: request.displayName,
                fingerprint: request.protocolIdentityFingerprint, verification_code: pairing.pendingVerificationCode,
                can_decide: pairing.pendingDecision == nil && !pairing.isPendingResolutionInFlight))
        }
        if let request = HandshakeConfigurationApproval.shared.pending {
            values.append(OperatorLocalApproval(id: request.id.uuidString,
                kind: request.profile == nil ? "file_delegation" : "handshake_configuration",
                peer_id: request.identity.deviceID, name: request.identity.deviceID,
                fingerprint: request.identity.fingerprint, verification_code: nil, can_decide: true))
        }
        return values
    }

    static func code(_ value: String) -> String? {
        guard value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 32 || $0 == 45 }) else { return nil }
        let digits = value.filter { $0 >= "0" && $0 <= "9" }
        return digits.count == 6 ? digits : nil
    }
}
