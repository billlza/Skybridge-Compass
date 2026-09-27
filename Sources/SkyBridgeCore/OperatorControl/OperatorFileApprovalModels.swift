import Foundation
import SkyBridgeProtocolCore

public struct OperatorFileApprovalRequest: Sendable {
    public enum Action: String, Sendable { case status, authorize, decide, revoke }
    public let action: Action
    public let deviceRef: String
    public let approvalID: UUID?
    public let allow: Bool?

    public init(action: Action, params: CrossnetControlParams) throws {
        guard let target = params.string("device_ref"), UUID(uuidString: target) != nil,
              action == .decide || (!params.contains("approval_id") && !params.contains("allow")) else {
            throw CrossnetControlFailure.malformedRequest("file approval requires a device_ref UUID")
        }
        let id = params.string("approval_id").flatMap(UUID.init(uuidString:))
        let allow = params.bool("allow")
        guard action != .decide || (id != nil && allow != nil) else {
            throw CrossnetControlFailure.malformedRequest("file decision requires an approval_id and boolean allow")
        }
        self.action = action; deviceRef = target; approvalID = id; self.allow = allow
    }
}

public struct OperatorFileApprovalResult: Codable, Sendable {
    public var runtime_target = "mac_app_runtime"
    public let operation: String
    public let device_ref: String
    /// nil means this failed operation did not obtain an authoritative grant read-back.
    public var authorized: Bool?
    public var pending: [RemoteFileApprovalPrompt] = []
    public var decided_id: String?
    public var allowed: Bool?
    public var transport: String?
    public var success = false
    public var error_code: String?
    public init(request: OperatorFileApprovalRequest) {
        operation = request.action.rawValue; device_ref = request.deviceRef
    }
}
