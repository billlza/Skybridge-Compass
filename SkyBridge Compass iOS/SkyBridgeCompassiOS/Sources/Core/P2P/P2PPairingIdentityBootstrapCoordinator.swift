import Foundation

struct P2PPairingIdentityBootstrapReadinessReceipt: Sendable, Equatable {
    let peerId: String
    let connectionGeneration: UUID
    let sessionId: String
    let declaredDeviceId: String
    let protocolPublicKeyFingerprint: String
    let acceptedMaterialDigest: Data

    func matches(
        peerId: String,
        connectionGeneration: UUID,
        sessionId: String,
        declaredDeviceId: String,
        protocolPublicKeyFingerprint: String,
        acceptedMaterialDigest: Data
    ) -> Bool {
        self.peerId == peerId
            && self.connectionGeneration == connectionGeneration
            && self.sessionId == sessionId
            && self.declaredDeviceId == declaredDeviceId
            && self.protocolPublicKeyFingerprint == protocolPublicKeyFingerprint
            && self.acceptedMaterialDigest == acceptedMaterialDigest
    }

    func evidenceState(
        for candidates: [P2PPairingIdentityBootstrapEvidence]
    ) -> P2PPairingIdentityBootstrapEvidenceState {
        let exactSessionCandidates = candidates.filter {
            $0.connectionGeneration == connectionGeneration
                && $0.sessionId == sessionId
        }
        guard !exactSessionCandidates.isEmpty else { return .missing }
        guard exactSessionCandidates.allSatisfy({ candidate in
            matches(
                peerId: peerId,
                connectionGeneration: candidate.connectionGeneration,
                sessionId: candidate.sessionId,
                declaredDeviceId: candidate.declaredDeviceId,
                protocolPublicKeyFingerprint: candidate.protocolPublicKeyFingerprint,
                acceptedMaterialDigest: candidate.acceptedMaterialDigest
            )
        }) else {
            return .authorityConflict
        }
        return .current
    }
}

enum P2PPairingIdentityBootstrapReceiptState: Sendable, Equatable {
    case current
    case journalBusy
}

enum P2PPairingIdentityBootstrapEvidenceState: Sendable, Equatable {
    case current
    case missing
    case authorityConflict
}

struct P2PPairingIdentityBootstrapEvidence: Sendable, Equatable {
    let connectionGeneration: UUID
    let sessionId: String
    let declaredDeviceId: String
    let protocolPublicKeyFingerprint: String
    let acceptedMaterialDigest: Data
}

struct P2PPairingIdentityBootstrapReadinessResult: Sendable, Equatable {
    let receipt: P2PPairingIdentityBootstrapReadinessReceipt?
    let observedReply: Bool

    var isReady: Bool { receipt != nil }
}

struct P2PPairingIdentityBootstrapObservation: Sendable {
    let connectionGeneration: UUID
    let sessionId: String
    let observedAt: Date
    let declaredDeviceId: String
    let protocolPublicKeyFingerprint: String
    let acceptedMaterialDigest: Data
}

/// Coordinates one exact authenticated session. Network refresh uses the existing
/// signed KEM exchange; it never grants trust or substitutes unsigned metadata.
@MainActor
enum P2PPairingIdentityBootstrapCoordinator {
    struct Operations {
        let requireCurrent: @MainActor () throws -> Void
        let isRecoveryReady: @MainActor () -> Bool
        let observe: @MainActor () -> P2PPairingIdentityBootstrapObservation?
        let hasStrictMaterial: @MainActor (P2PPairingIdentityBootstrapObservation) async -> Bool
        let refreshSignedMaterial: @MainActor (P2PPairingIdentityBootstrapObservation) async throws -> Void
        let makeCurrentReceipt: @MainActor (P2PPairingIdentityBootstrapObservation) throws -> P2PPairingIdentityBootstrapReadinessReceipt?
        let sendIdentityExchange: @MainActor () async throws -> Void
    }

    enum Failure: Error, Equatable, LocalizedError {
        case signedMaterialUnavailableAfterRefresh

        var errorDescription: String? {
            "签名密钥刷新完成，但当前远程连接仍缺少可用的后量子密钥。"
        }
    }

    nonisolated static func isPairingIdentityBootstrapReady(
        hasCurrentSessionObservation: Bool,
        hasStrictPQCTrustMaterial: Bool
    ) -> Bool {
        hasCurrentSessionObservation && hasStrictPQCTrustMaterial
    }

    static func run(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100),
        operations: Operations
    ) async throws -> P2PPairingIdentityBootstrapReadinessResult {
        let clock = ContinuousClock()
        var deadline = clock.now + timeout
        var observedReply = false
        var requestedIdentity = false
        var refreshedSignedMaterial = false

        while clock.now < deadline {
            try Task.checkCancellation()
            try operations.requireCurrent()
            guard operations.isRecoveryReady() else {
                try await Task.sleep(for: pollInterval)
                continue
            }
            let observation = operations.observe()
            observedReply = observedReply || observation != nil
            let strictMaterial = if let observation {
                await operations.hasStrictMaterial(observation)
            } else { false }
            try Task.checkCancellation()
            try operations.requireCurrent()
            guard operations.isRecoveryReady() else {
                try await Task.sleep(for: pollInterval)
                continue
            }
            if isPairingIdentityBootstrapReady(
                hasCurrentSessionObservation: observation != nil,
                hasStrictPQCTrustMaterial: strictMaterial
            ), let observation {
                if let receipt = try operations.makeCurrentReceipt(observation) {
                    return .init(receipt: receipt, observedReply: observedReply)
                }
                try await Task.sleep(for: pollInterval)
                continue
            }
            if let observation {
                guard !refreshedSignedMaterial else {
                    throw Failure.signedMaterialUnavailableAfterRefresh
                }
                refreshedSignedMaterial = true
                let refreshStarted = clock.now
                try await operations.refreshSignedMaterial(observation)
                try Task.checkCancellation()
                try operations.requireCurrent()
                // The one signed exchange has its own bounded network deadline.
                // Preserve the remaining metadata budget; never restart it on replies.
                deadline += refreshStarted.duration(to: clock.now)
                continue
            }
            if !requestedIdentity {
                requestedIdentity = true
                try await operations.sendIdentityExchange()
                try Task.checkCancellation()
                try operations.requireCurrent()
            }
            try await Task.sleep(for: pollInterval)
        }
        try Task.checkCancellation()
        try operations.requireCurrent()
        return .init(receipt: nil, observedReply: observedReply)
    }
}
