import Foundation

/// Identifies one logical remote-desktop stream configuration inside an
/// authenticated, ordered transport session. Retries reuse the same value; a
/// semantic replacement receives a fresh value.
public struct RemoteDesktopStreamConfigurationTransaction: Codable, Equatable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum RemoteDesktopStreamConfigurationIngressDecision: Equatable, Sendable {
    case apply
    case acknowledgeDuplicate
    case rejectMissingTransaction
    case rejectConflictingDuplicate

    public var isProtocolViolation: Bool {
        switch self {
        case .rejectMissingTransaction, .rejectConflictingDuplicate:
            return true
        case .apply, .acknowledgeDuplicate:
            return false
        }
    }
}

public enum RemoteDesktopStreamConfigurationTransactionPolicy {
    public static func ingressDecision(
        incoming: RemoteDesktopStreamConfigurationTransaction?,
        lastAccepted: RemoteDesktopStreamConfigurationTransaction?,
        payloadMatchesLastAccepted: Bool
    ) -> RemoteDesktopStreamConfigurationIngressDecision {
        guard let incoming else { return .rejectMissingTransaction }
        guard let lastAccepted else { return .apply }
        if incoming == lastAccepted {
            return payloadMatchesLastAccepted
                ? .acknowledgeDuplicate
                : .rejectConflictingDuplicate
        }
        // Both supported carriers are ordered (TCP and ordered WebRTC data
        // channels). A different ID is therefore the next logical operation;
        // session ownership remains bound by the authenticated transport.
        return .apply
    }
}

public struct RemoteDesktopStreamConfigurationAcknowledgement: Codable, Equatable, Sendable {
    public let acceptedAt: TimeInterval
    public let transaction: RemoteDesktopStreamConfigurationTransaction
    public let streamRefreshToken: UInt64?
    public let audioEndpointPresent: Bool
    public let screenFrameTransport: String?

    public init(
        acceptedAt: TimeInterval,
        transaction: RemoteDesktopStreamConfigurationTransaction,
        streamRefreshToken: UInt64?,
        audioEndpointPresent: Bool,
        screenFrameTransport: String?
    ) {
        self.acceptedAt = acceptedAt
        self.transaction = transaction
        self.streamRefreshToken = streamRefreshToken
        self.audioEndpointPresent = audioEndpointPresent
        self.screenFrameTransport = screenFrameTransport
    }
}
