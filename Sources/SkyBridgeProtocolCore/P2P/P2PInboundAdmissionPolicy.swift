import Foundation

/// Shared protocol-level budgets for unauthenticated inbound P2P work.
/// Platform adapters own their sockets and tasks, but must apply the same
/// capacity and stage semantics on macOS and iOS.
public enum P2PInboundAdmissionStage: String, Sendable, CaseIterable {
    case awaitingFirstFrame
    case bootstrapCrypto
    case protocolIdentityConfirmation
    case initialHandshake
}

public enum P2PInboundAdmissionReleaseMilestone: String, Sendable, Equatable {
    /// The same capacity slot transitions to the recognized protocol stage.
    case transitionWithoutRelease
    /// A bounded bootstrap response has been submitted to the transport.
    case responseSubmitted
    /// The initial handshake reached authenticated `.established` state.
    case authenticatedSessionEstablished
}

public enum P2PInboundAdmissionPolicy {
    public static let maximumConcurrentConnections = 32
    public static let maximumConcurrentConnectionsPerRemoteEndpoint = 4
    public static let defaultProtocolIdentityConfirmationResponseBudgetSeconds: TimeInterval = 195

    public static func deadlineSeconds(
        for stage: P2PInboundAdmissionStage,
        protocolIdentityConfirmationResponseBudgetSeconds: TimeInterval = defaultProtocolIdentityConfirmationResponseBudgetSeconds
    ) -> TimeInterval {
        switch stage {
        case .awaitingFirstFrame:
            return 12
        case .bootstrapCrypto, .initialHandshake:
            return 45
        case .protocolIdentityConfirmation:
            guard protocolIdentityConfirmationResponseBudgetSeconds.isFinite else {
                return defaultProtocolIdentityConfirmationResponseBudgetSeconds
            }
            return min(max(protocolIdentityConfirmationResponseBudgetSeconds, 45), 315)
        }
    }

    public static func releaseMilestone(
        for stage: P2PInboundAdmissionStage
    ) -> P2PInboundAdmissionReleaseMilestone {
        switch stage {
        case .awaitingFirstFrame:
            return .transitionWithoutRelease
        case .bootstrapCrypto, .protocolIdentityConfirmation:
            return .responseSubmitted
        case .initialHandshake:
            return .authenticatedSessionEstablished
        }
    }

    public static func remainingSeconds(
        until deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> TimeInterval? {
        let components = now.duration(to: deadline).components
        let remaining = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds)
                / 1_000_000_000_000_000_000
        return remaining > 0 ? remaining : nil
    }
}

/// Shared responder-side PIB-1 admission and freshness limits. These values
/// are protocol semantics, not adapter tuning: the same signed request must be
/// admitted or rejected consistently by macOS and iOS.
public enum P2PProtocolIdentityBindingAdmissionPolicy {
    public static let maximumTransactions = 32
    public static let maximumTransactionsPerRequester = 4
    public static let admissionWindowSeconds: TimeInterval = 10
    public static let maximumAdmissionsPerRequesterPerWindow = 8
    public static let maximumGlobalAdmissionsPerWindow = 64
    public static let maximumTransactionTTLSeconds: TimeInterval = 300
    public static let maximumRequestAgeSeconds: TimeInterval = 120
    public static let maximumRequestFutureSkewSeconds: TimeInterval = 30
    public static let candidateResponseTimeoutSeconds: TimeInterval = 30
    public static let defaultFinalAckResponseTimeoutSeconds: TimeInterval = 195

    public static func boundedChildExpiry(
        parentExpiry: Date,
        issuedAt: Date
    ) -> Date {
        min(
            parentExpiry,
            issuedAt.addingTimeInterval(maximumTransactionTTLSeconds)
        )
    }
}
