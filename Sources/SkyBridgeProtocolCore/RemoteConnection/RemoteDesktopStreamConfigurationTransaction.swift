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
    /// Version 1 confirms that the host accepts an authenticated acknowledgement
    /// after the viewer's product renderer presents an exact sequenced frame.
    /// Absence preserves legacy streaming while leaving presentation evidence
    /// unavailable.
    public let framePresentationAckVersion: Int?

    public init(
        acceptedAt: TimeInterval,
        transaction: RemoteDesktopStreamConfigurationTransaction,
        streamRefreshToken: UInt64?,
        audioEndpointPresent: Bool,
        screenFrameTransport: String?,
        framePresentationAckVersion: Int? = nil
    ) {
        self.acceptedAt = acceptedAt
        self.transaction = transaction
        self.streamRefreshToken = streamRefreshToken
        self.audioEndpointPresent = audioEndpointPresent
        self.screenFrameTransport = screenFrameTransport
        self.framePresentationAckVersion = framePresentationAckVersion
    }
}

/// Authenticated receipt emitted only after the viewer's ordinary product
/// renderer presents the identified source frame. The stream transaction keeps
/// a delayed renderer callback from acknowledging a replacement configuration.
public struct RemoteDesktopFramePresentationAcknowledgement: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sequenceNumber: UInt64
    public let streamTransaction: RemoteDesktopStreamConfigurationTransaction

    public init(
        version: Int = Self.currentVersion,
        sequenceNumber: UInt64,
        streamTransaction: RemoteDesktopStreamConfigurationTransaction
    ) {
        self.version = version
        self.sequenceNumber = sequenceNumber
        self.streamTransaction = streamTransaction
    }
}
