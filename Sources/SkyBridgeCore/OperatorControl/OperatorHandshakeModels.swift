import Foundation
import SkyBridgeProtocolCore

public struct OperatorHandshakeRequest: Sendable {
    public enum Action: String, Sendable { case list, status, set, revoke }
    public let action: Action
    public let deviceRef: String?
    public let usb: OperatorUSBConnectRequest?
    public let scope: String
    public let profile: HandshakeProfile?
    public let reconnect: Bool
    public init(action: Action, params: CrossnetControlParams) throws {
        self.action = action
        deviceRef = params.string("device_ref")
        usb = params.contains("udid") ? try OperatorUSBConnectRequest(params: params) : nil
        scope = params.string("scope") ?? "local"
        profile = params.string("profile").flatMap(HandshakeProfile.init(rawValue:))
        reconnect = params.bool("reconnect") ?? false
        guard (!params.contains("scope") || params.string("scope") != nil),
              (!params.contains("reconnect") || params.bool("reconnect") != nil),
              (!params.contains("device_ref") || deviceRef != nil),
              (!params.contains("peer_id") || usb != nil),
              (!params.contains("expected_fingerprint") || usb != nil),
              (action == .set || !params.contains("profile")),
              ["local", "both"].contains(scope),
              deviceRef == nil || deviceRef.flatMap(UUID.init(uuidString:)) != nil,
              (action == .set) == (profile != nil),
              action == .set || !reconnect,
              deviceRef == nil || usb == nil,
              !(scope == "both" || reconnect || action == .revoke) || deviceRef != nil || usb != nil else {
            throw CrossnetControlFailure.malformedRequest("handshake requires a valid profile, scope and target device_ref")
        }
    }
}

public struct OperatorHandshakeResult: Codable, Sendable {
    public var runtime_target = "mac_app_runtime"
    public var operation: String
    public var scope: String
    public var device_ref: String?
    public var usb_udid: String?
    public var local: HandshakeConfigurationSnapshot
    public var remote: HandshakeConfigurationSnapshot?
    public var local_applied = false
    public var remote_applied = false
    public var local_error: String?
    public var remote_error: String?
    public var management_authorized: Bool?
    public var management_transport: String?
    public var negotiated_suite: String?
    public var session_transport: String?
    public var session_matches_configuration: Bool?
    public var reconnected = false
    public var reconnect_error: String?
    public var success = true
    public var partial = false

    public init(request: OperatorHandshakeRequest, local: HandshakeConfigurationSnapshot) {
        operation = request.action.rawValue; scope = request.scope; device_ref = request.deviceRef
        self.local = local
        usb_udid = request.usb?.udid
    }
}
