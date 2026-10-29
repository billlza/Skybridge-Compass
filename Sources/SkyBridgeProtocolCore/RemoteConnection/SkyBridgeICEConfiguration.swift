import Foundation

/// Cross-platform ICE configuration used by the signaling / control plane.
///
/// Notes:
/// - This is intentionally transport-agnostic and does not depend on WebRTC SDK types.
/// - Apple runtime code can map it directly into `RTCIceServer` or equivalent platform objects.
public struct SkyBridgeICEConfiguration: Sendable, Equatable {
    public var stunURL: String
    public var turnURLs: [String]
    public var turnUsername: String
    public var turnPassword: String

    public var turnURL: String {
        get { turnURLs.first ?? "" }
        set { turnURLs = newValue.isEmpty ? [] : [newValue] }
    }

    public var hasUsableTURNCredentials: Bool {
        !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURLs.isEmpty
    }

    public init(stunURL: String, turnURLs: [String], turnUsername: String, turnPassword: String) {
        self.stunURL = stunURL
        self.turnURLs = turnURLs
        self.turnUsername = turnUsername
        self.turnPassword = turnPassword
    }

    public init(stunURL: String, turnURL: String, turnUsername: String, turnPassword: String) {
        self.init(
            stunURL: stunURL,
            turnURLs: turnURL.isEmpty ? [] : [turnURL],
            turnUsername: turnUsername,
            turnPassword: turnPassword
        )
    }
}
