import Foundation

@available(iOS 17.0, *)
enum IOSCurrentPathDeviceIdentityRotationError: LocalizedError {
    case authenticationStateChanged
    case localAuthorityCommittedRecoveryRequired(String)
    case localConfigurationChanged
    case preparedIdentityMismatch
    case proofVerificationFailed
    case pendingRotationConflictsWithLocalAuthority
    case pendingRotationJournalUnsupported
    case challengeExpired

    var errorDescription: String? {
        switch self {
        case .authenticationStateChanged:
            return "登录身份在协议身份轮换期间发生变化，请重新发起"
        case .localAuthorityCommittedRecoveryRequired(let reason):
            return "协议身份已提交，但恢复记录清理未完成；已保留恢复记录: \(reason)"
        case .localConfigurationChanged:
            return "本机协议身份在轮换期间发生变化，请重新发起"
        case .preparedIdentityMismatch:
            return "重新载入的候选协议身份与待提交轮换不一致"
        case .proofVerificationFailed:
            return "旧身份或新身份的轮换签名自检失败"
        case .pendingRotationConflictsWithLocalAuthority:
            return "待恢复的身份轮换与当前本机 authority 冲突"
        case .pendingRotationJournalUnsupported:
            return "待恢复的身份轮换记录版本不受支持"
        case .challengeExpired:
            return "身份轮换挑战已过期，旧 authority 保持不变，请重新发起"
        }
    }
}

@available(iOS 17.0, *)
struct IOSPendingDeviceIdentityRotationRequest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let requestID: String
    let expectedTenantID: String
    let expectedUserID: String
    let deviceID: String
    let oldAlgorithm: ProtocolSigningAlgorithm
    let oldProtection: ProtocolSigningKeyProtection
    let oldFingerprint: String
    let oldPublicKey: Data
    let newAlgorithm: ProtocolSigningAlgorithm
    let newProtection: ProtocolSigningKeyProtection
    let newFingerprint: String
    let newPublicKey: Data

    var oldConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: oldAlgorithm,
            keyProtection: oldProtection
        )
    }

    var newConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: newAlgorithm,
            keyProtection: newProtection
        )
    }

    var authenticationScope: SignalServerClientCompat.IdentityRotationAuthenticationScope {
        SignalServerClientCompat.IdentityRotationAuthenticationScope(
            tenantID: expectedTenantID,
            userID: expectedUserID
        )
    }

    func bindings() throws -> (
        old: ProtocolIdentityBindingCompat,
        new: ProtocolIdentityBindingCompat
    ) {
        guard version == Self.currentVersion,
              let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationJournalUnsupported
        }
        return (
            try ProtocolIdentityBindingCompat(
                deviceId: deviceID,
                protocolSigningAlgorithm: oldAlgorithm,
                protocolPublicKeyBytes: oldPublicKey,
                protocolPublicKeyFingerprint: oldFingerprint
            ),
            try ProtocolIdentityBindingCompat(
                deviceId: deviceID,
                protocolSigningAlgorithm: newAlgorithm,
                protocolPublicKeyBytes: newPublicKey,
                protocolPublicKeyFingerprint: newFingerprint
            )
        )
    }
}

@available(iOS 17.0, *)
struct IOSPendingDeviceIdentityRotation: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let requestID: String
    let rotationID: String
    let nonce: Data
    let issuedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let tenantID: String
    let userID: String
    let deviceID: String
    let oldGeneration: UInt64
    let oldAlgorithm: ProtocolSigningAlgorithm
    let oldProtection: ProtocolSigningKeyProtection
    let oldFingerprint: String
    let oldPublicKey: Data
    let newAlgorithm: ProtocolSigningAlgorithm
    let newProtection: ProtocolSigningKeyProtection
    let newFingerprint: String
    let newPublicKey: Data
    let transcriptHash: String
    let transcriptBase64: String
    let oldSignature: Data
    let newSignature: Data
    let clientVersion: String
    let protocolVersion: String

    var oldConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: oldAlgorithm,
            keyProtection: oldProtection
        )
    }

    var newConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: newAlgorithm,
            keyProtection: newProtection
        )
    }

    var authenticationScope: SignalServerClientCompat.IdentityRotationAuthenticationScope {
        SignalServerClientCompat.IdentityRotationAuthenticationScope(
            tenantID: tenantID,
            userID: userID
        )
    }

    func challenge() throws -> SignalServerClientCompat.IdentityRotationChallenge {
        guard version == Self.currentVersion else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationJournalUnsupported
        }
        let oldIdentity = try ProtocolIdentityBindingCompat(
            deviceId: deviceID,
            protocolSigningAlgorithm: oldAlgorithm,
            protocolPublicKeyBytes: oldPublicKey,
            protocolPublicKeyFingerprint: oldFingerprint
        )
        let newIdentity = try ProtocolIdentityBindingCompat(
            deviceId: deviceID,
            protocolSigningAlgorithm: newAlgorithm,
            protocolPublicKeyBytes: newPublicKey,
            protocolPublicKeyFingerprint: newFingerprint
        )
        let transcript = try DeviceIdentityRotationTranscriptCompat(
            rotationID: rotationID,
            nonce: nonce,
            expiresAtMilliseconds: expiresAtMilliseconds,
            tenantID: tenantID,
            userID: userID,
            deviceID: deviceID,
            oldGeneration: oldGeneration,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        try transcript.validateServerCommitment(
            transcriptBase64: transcriptBase64,
            transcriptHash: transcriptHash
        )
        return try SignalServerClientCompat.IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: issuedAtMilliseconds,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion
        )
    }
}

/// Serializes crash recovery across startup, LAN identity advertisement, and
/// current-path WebRTC. It deliberately does not cache success: a rotation
/// journal can be created after any previous readiness check.
@available(iOS 17.0, *)
@MainActor
final class IOSCurrentPathAuthorityReadinessGate {
    static let shared = IOSCurrentPathAuthorityReadinessGate()

    private struct InFlightRecovery {
        let id: UUID
        let task: Task<Bool, Error>
    }

    private let recoverPendingRotation: () async throws -> Bool
    private var inFlightRecovery: InFlightRecovery?

    init(
        recoverPendingRotation: @escaping () async throws -> Bool = {
            try await IOSCurrentPathDeviceIdentityRotationCoordinator.shared
                .recoverPendingRotationIfPresent()
        }
    ) {
        self.recoverPendingRotation = recoverPendingRotation
    }

    @discardableResult
    func ensureReady() async throws -> Bool {
        if let inFlightRecovery {
            return try await inFlightRecovery.task.value
        }
        let recoveryID = UUID()
        let task = Task { @MainActor [recoverPendingRotation] in
            try await recoverPendingRotation()
        }
        inFlightRecovery = InFlightRecovery(id: recoveryID, task: task)
        defer {
            if inFlightRecovery?.id == recoveryID {
                inFlightRecovery = nil
            }
        }
        return try await task.value
    }
}

/// Keeps the settings switch honest: the candidate remains staged until the
/// authenticated old/new dual proof commits remotely and its receipt matches.
@available(iOS 17.0, *)
@MainActor
final class IOSCurrentPathDeviceIdentityRotationCoordinator {
    static let shared = IOSCurrentPathDeviceIdentityRotationCoordinator()

    private let signalServer: SignalServerClientCompat
    private let requestJournalStore:
        CodablePersistenceStore<IOSPendingDeviceIdentityRotationRequest>
    private let journalStore: CodablePersistenceStore<IOSPendingDeviceIdentityRotation>
    private var inFlight = false

    init(
        signalServer: SignalServerClientCompat = SignalServerClientCompat(),
        requestJournalStore:
            CodablePersistenceStore<IOSPendingDeviceIdentityRotationRequest> =
                CodablePersistenceStore(
                    location: .protectedApplicationSupport(
                        path: "Security/device-identity-rotation-request-v1.json"
                    ),
                    maximumPayloadBytes: 64 * 1_024
                ),
        journalStore: CodablePersistenceStore<IOSPendingDeviceIdentityRotation> =
            CodablePersistenceStore(
                location: .protectedApplicationSupport(
                    path: "Security/device-identity-rotation-v1.json"
                ),
                maximumPayloadBytes: 64 * 1_024
            )
    ) {
        self.signalServer = signalServer
        self.requestJournalStore = requestJournalStore
        self.journalStore = journalStore
    }

    func rotate(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection,
        expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope
    ) async throws {
        guard !inFlight else {
            throw SkyBridgeError.handshakeFailed(
                reason: "A protocol identity rotation is already in progress"
            )
        }
        inFlight = true
        defer { inFlight = false }

        guard try await signalServer.authenticatedIdentityRotationScope()
                == expectedScope else {
            throw IOSCurrentPathDeviceIdentityRotationError.authenticationStateChanged
        }
        _ = try await recoverPendingRotationIfPresentAssumingExclusiveAccess()
        let target = ProtocolIdentityConfigurationRecord(
            algorithm: algorithm,
            keyProtection: protection
        )
        if try ProtocolSigningIdentityPolicy.requiredConfiguration() == target {
            return
        }

        let core = SkyBridgeiOSCore.shared
        let oldSnapshot = try await core.committedActiveProtocolIdentitySnapshot()
        let oldIdentity = try ProtocolIdentityBindingCompat(
            deviceId: oldSnapshot.deviceId,
            protocolSigningAlgorithm: oldSnapshot.algorithm,
            protocolPublicKeyBytes: oldSnapshot.publicKey
        )
        let prepared = try await core.prepareProtocolSigningIdentity(
            algorithm: algorithm,
            protection: protection
        )
        do {
            let newIdentity = try ProtocolIdentityBindingCompat(
                deviceId: oldSnapshot.deviceId,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyBytes: prepared.publicKey
            )
            let request = IOSPendingDeviceIdentityRotationRequest(
                version: IOSPendingDeviceIdentityRotationRequest.currentVersion,
                requestID: UUID().uuidString.lowercased(),
                expectedTenantID: expectedScope.tenantID,
                expectedUserID: expectedScope.userID,
                deviceID: oldSnapshot.deviceId,
                oldAlgorithm: oldSnapshot.algorithm,
                oldProtection: oldSnapshot.protection,
                oldFingerprint: oldIdentity.protocolPublicKeyFingerprint,
                oldPublicKey: oldSnapshot.publicKey,
                newAlgorithm: algorithm,
                newProtection: protection,
                newFingerprint: newIdentity.protocolPublicKeyFingerprint,
                newPublicKey: prepared.publicKey
            )
            try requestJournalStore.save(request)
            try await completePendingRequest(
                request,
                oldSnapshot: oldSnapshot,
                prepared: prepared
            )
        } catch IOSCurrentPathDeviceIdentityRotationError.challengeExpired {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            throw IOSCurrentPathDeviceIdentityRotationError.challengeExpired
        } catch IOSCurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw IOSCurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            throw error
        }
    }

    @discardableResult
    func recoverPendingRotationIfPresent() async throws -> Bool {
        guard !inFlight else {
            throw SkyBridgeError.handshakeFailed(
                reason: "A protocol identity rotation is already in progress"
            )
        }
        inFlight = true
        defer { inFlight = false }
        return try await recoverPendingRotationIfPresentAssumingExclusiveAccess()
    }

    private func recoverPendingRotationIfPresentAssumingExclusiveAccess() async throws -> Bool {
        if let pending = try journalStore.loadOrThrow() {
            return try await recoverCommitReadyRotation(pending)
        }
        guard let request = try requestJournalStore.loadOrThrow() else { return false }
        let authScope = try await signalServer.authenticatedIdentityRotationScope()
        guard authScope == request.authenticationScope else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        guard try ProtocolSigningIdentityPolicy.requiredConfiguration()
                == request.oldConfiguration else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let core = SkyBridgeiOSCore.shared
        let oldSnapshot = try await core.committedProtocolIdentitySnapshot(
            for: request.oldAlgorithm,
            protection: request.oldProtection
        )
        let prepared = try await core.prepareProtocolSigningIdentity(
            algorithm: request.newAlgorithm,
            protection: request.newProtection
        )
        do {
            guard oldSnapshot.publicKey == request.oldPublicKey,
                  prepared.publicKey == request.newPublicKey else {
                throw IOSCurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
            }
            try await completePendingRequest(
                request,
                oldSnapshot: oldSnapshot,
                prepared: prepared
            )
            return true
        } catch IOSCurrentPathDeviceIdentityRotationError.challengeExpired {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            return false
        } catch IOSCurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw IOSCurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            throw error
        }
    }

    private func recoverCommitReadyRotation(
        _ pending: IOSPendingDeviceIdentityRotation
    ) async throws -> Bool {
        let challenge = try pending.challenge()
        let authScope = try await signalServer.authenticatedIdentityRotationScope()
        guard authScope == pending.authenticationScope else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let current = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        if current == pending.newConfiguration {
            try await validateCommittedAuthorityMatchesPendingNewIdentity(pending)
            _ = try await signalServer.commitIdentityRotation(
                challenge: challenge,
                oldSignature: pending.oldSignature,
                newSignature: pending.newSignature,
                expectedScope: pending.authenticationScope
            )
            do {
                try journalStore.remove()
                try requestJournalStore.remove()
            } catch {
                throw IOSCurrentPathDeviceIdentityRotationError
                    .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
            }
            return true
        }
        guard current == pending.oldConfiguration else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let core = SkyBridgeiOSCore.shared
        let prepared = try await core.prepareProtocolSigningIdentity(
            algorithm: pending.newAlgorithm,
            protection: pending.newProtection
        )
        do {
            guard prepared.publicKey == pending.newPublicKey else {
                throw IOSCurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
            }
            _ = try await commitIdentityRotationPreservingOnlyRecoverableState(
                challenge: challenge,
                oldSignature: pending.oldSignature,
                newSignature: pending.newSignature,
                expectedScope: pending.authenticationScope
            )
            guard try ProtocolSigningIdentityPolicy.requiredConfiguration()
                    == pending.oldConfiguration else {
                throw IOSCurrentPathDeviceIdentityRotationError.localConfigurationChanged
            }
            try core.commitPreparedProtocolSigningIdentity(prepared)
            do {
                try journalStore.remove()
                try requestJournalStore.remove()
            } catch {
                throw IOSCurrentPathDeviceIdentityRotationError
                    .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
            }
            return true
        } catch IOSCurrentPathDeviceIdentityRotationError.challengeExpired {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            return false
        } catch IOSCurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw IOSCurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            core.abandonPreparedProtocolSigningIdentity(prepared)
            throw error
        }
    }

    private func completePendingRequest(
        _ request: IOSPendingDeviceIdentityRotationRequest,
        oldSnapshot: CommittedIOSProtocolIdentitySnapshot,
        prepared: SkyBridgeiOSCore.PreparedProtocolSigningIdentity
    ) async throws {
        let bindings = try request.bindings()
        guard oldSnapshot.algorithm == request.oldAlgorithm,
              oldSnapshot.protection == request.oldProtection,
              oldSnapshot.publicKey == request.oldPublicKey,
              prepared.configuration == request.newConfiguration,
              prepared.publicKey == request.newPublicKey else {
            throw IOSCurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
        }
        let challenge = try await requestIdentityRotationChallengePreservingOnlyRecoverableState(
            oldIdentity: bindings.old,
            newIdentity: bindings.new,
            idempotencyKey: request.requestID,
            expectedScope: request.authenticationScope
        )
        guard challenge.transcript.oldIdentity == bindings.old,
              challenge.transcript.newIdentity == bindings.new,
              challenge.transcript.tenantID == request.expectedTenantID,
              challenge.transcript.userID == request.expectedUserID else {
            throw IOSCurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
        }
        let oldSignature = try await Self.signAndVerify(
            challenge.transcript.encoded,
            algorithm: request.oldAlgorithm,
            keyHandle: oldSnapshot.keyHandle,
            publicKey: oldSnapshot.publicKey
        )
        let newSignature = try await Self.signAndVerify(
            challenge.transcript.encoded,
            algorithm: request.newAlgorithm,
            keyHandle: prepared.keyHandle,
            publicKey: prepared.publicKey
        )
        let pending = IOSPendingDeviceIdentityRotation(
            version: IOSPendingDeviceIdentityRotation.currentVersion,
            requestID: request.requestID,
            rotationID: challenge.transcript.rotationID,
            nonce: challenge.transcript.nonce,
            issuedAtMilliseconds: challenge.issuedAtMilliseconds,
            expiresAtMilliseconds: challenge.transcript.expiresAtMilliseconds,
            tenantID: challenge.transcript.tenantID,
            userID: challenge.transcript.userID,
            deviceID: challenge.transcript.deviceID,
            oldGeneration: challenge.transcript.oldGeneration,
            oldAlgorithm: request.oldAlgorithm,
            oldProtection: request.oldProtection,
            oldFingerprint: bindings.old.protocolPublicKeyFingerprint,
            oldPublicKey: request.oldPublicKey,
            newAlgorithm: request.newAlgorithm,
            newProtection: request.newProtection,
            newFingerprint: bindings.new.protocolPublicKeyFingerprint,
            newPublicKey: request.newPublicKey,
            transcriptHash: challenge.transcript.sha256Hex,
            transcriptBase64: challenge.transcript.encoded.base64EncodedString(),
            oldSignature: oldSignature,
            newSignature: newSignature,
            clientVersion: challenge.clientVersion,
            protocolVersion: challenge.protocolVersion
        )
        try journalStore.save(pending)
        try requestJournalStore.remove()
        _ = try await commitIdentityRotationPreservingOnlyRecoverableState(
            challenge: challenge,
            oldSignature: oldSignature,
            newSignature: newSignature,
            expectedScope: pending.authenticationScope
        )
        guard try ProtocolSigningIdentityPolicy.requiredConfiguration()
                == pending.oldConfiguration else {
            throw IOSCurrentPathDeviceIdentityRotationError.localConfigurationChanged
        }
        try SkyBridgeiOSCore.shared.commitPreparedProtocolSigningIdentity(prepared)
        do {
            try journalStore.remove()
            try requestJournalStore.remove()
        } catch {
            throw IOSCurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
        }
    }

    private func commitIdentityRotationPreservingOnlyRecoverableState(
        challenge: SignalServerClientCompat.IdentityRotationChallenge,
        oldSignature: Data,
        newSignature: Data,
        expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope
    ) async throws -> SignalServerClientCompat.IdentityRotationCommitReceipt {
        do {
            return try await signalServer.commitIdentityRotation(
                challenge: challenge,
                oldSignature: oldSignature,
                newSignature: newSignature,
                expectedScope: expectedScope
            )
        } catch {
            guard SignalServerClientCompat
                .isUncommittedIdentityRotationExpired(error) else {
                throw error
            }
            try journalStore.remove()
            try requestJournalStore.remove()
            throw IOSCurrentPathDeviceIdentityRotationError.challengeExpired
        }
    }

    private func requestIdentityRotationChallengePreservingOnlyRecoverableState(
        oldIdentity: ProtocolIdentityBindingCompat,
        newIdentity: ProtocolIdentityBindingCompat,
        idempotencyKey: String,
        expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope
    ) async throws -> SignalServerClientCompat.IdentityRotationChallenge {
        do {
            return try await signalServer.requestIdentityRotationChallenge(
                oldIdentity: oldIdentity,
                newIdentity: newIdentity,
                idempotencyKey: idempotencyKey,
                expectedScope: expectedScope
            )
        } catch {
            guard SignalServerClientCompat
                .isUncommittedIdentityRotationExpired(error) else {
                throw error
            }
            try requestJournalStore.remove()
            throw IOSCurrentPathDeviceIdentityRotationError.challengeExpired
        }
    }

    private func validateCommittedAuthorityMatchesPendingNewIdentity(
        _ pending: IOSPendingDeviceIdentityRotation
    ) async throws {
        let snapshot = try await SkyBridgeiOSCore.shared
            .committedActiveProtocolIdentitySnapshot()
        let binding = try ProtocolIdentityBindingCompat(
            deviceId: snapshot.deviceId,
            protocolSigningAlgorithm: snapshot.algorithm,
            protocolPublicKeyBytes: snapshot.publicKey
        )
        guard snapshot.deviceId == pending.deviceID,
              snapshot.algorithm == pending.newAlgorithm,
              snapshot.protection == pending.newProtection,
              snapshot.publicKey == pending.newPublicKey,
              binding.protocolPublicKeyFingerprint == pending.newFingerprint else {
            throw IOSCurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
    }

    private static func signAndVerify(
        _ payload: Data,
        algorithm: ProtocolSigningAlgorithm,
        keyHandle: SigningKeyHandle,
        publicKey: Data
    ) async throws -> Data {
        let provider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let signature = try await provider.sign(payload, key: keyHandle)
        guard signature.count == algorithm.signatureByteCount,
              try await provider.verify(
                payload,
                signature: signature,
                publicKey: publicKey
              ) else {
            throw IOSCurrentPathDeviceIdentityRotationError.proofVerificationFailed
        }
        return signature
    }
}
