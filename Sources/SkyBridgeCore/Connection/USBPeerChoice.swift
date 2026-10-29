import Foundation

/// A current pairing identity the user may select for a cable. Presence in this
/// list does not claim that the identity is at that cable; the handshake proves it.
public struct USBPeerChoice: Codable, Equatable, Sendable {
    public let peer_id: String
    public let name: String
    public let expected_fingerprint: String?
    public let unavailable_reason: String?

    public init(peerID: String, name: String, expectedFingerprint: String?, unavailableReason: String?) {
        self.peer_id = peerID
        self.name = name
        self.expected_fingerprint = expectedFingerprint
        self.unavailable_reason = unavailableReason
    }
}

public struct USBPeerInspection: Codable, Sendable {
    public let runtime_target: String
    public let udid: String
    public let peer: USBPeerChoice
    public let signature_verified: Bool
    public let paired: Bool

    public init(udid: String, peer: USBPeerChoice, paired: Bool) {
        runtime_target = "mac_app_runtime"; self.udid = udid; self.peer = peer
        signature_verified = true; self.paired = paired
    }
}
