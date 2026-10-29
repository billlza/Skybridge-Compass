import Foundation
import OSLog
import SkyBridgeProtocolCore

public enum CurrentPathDeviceIdentityRotationError: LocalizedError, Sendable {
    case authenticationStateChanged
    case localAuthorityCommittedRecoveryRequired(String)
    case localConfigurationChanged
    case preparedIdentityMismatch
    case proofVerificationFailed
    case pendingRotationConflictsWithLocalAuthority
    case pendingRotationJournalUnsupported
    case challengeExpired

    public var errorDescription: String? {
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

struct PendingDeviceIdentityRotationRequest: Codable, Sendable {
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
            protection: oldProtection
        )
    }

    var newConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: newAlgorithm,
            protection: newProtection
        )
    }

    var authenticationScope: SignalServerClient.IdentityRotationAuthenticationScope {
        SignalServerClient.IdentityRotationAuthenticationScope(
            tenantID: expectedTenantID,
            userID: expectedUserID
        )
    }

    func bindings() throws -> (
        old: ProtocolIdentityBinding,
        new: ProtocolIdentityBinding
    ) {
        guard version == Self.currentVersion,
              let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationJournalUnsupported
        }
        return (
            try ProtocolIdentityBinding(
                deviceId: deviceID,
                protocolSigningAlgorithm: oldAlgorithm,
                protocolPublicKeyBytes: oldPublicKey,
                protocolPublicKeyFingerprint: oldFingerprint
            ),
            try ProtocolIdentityBinding(
                deviceId: deviceID,
                protocolSigningAlgorithm: newAlgorithm,
                protocolPublicKeyBytes: newPublicKey,
                protocolPublicKeyFingerprint: newFingerprint
            )
        )
    }
}

struct PendingDeviceIdentityRotation: Codable, Sendable {
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

    func challenge() throws -> SignalServerClient.IdentityRotationChallenge {
        guard version == Self.currentVersion else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationJournalUnsupported
        }
        let oldIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: oldAlgorithm,
            protocolPublicKeyBytes: oldPublicKey,
            protocolPublicKeyFingerprint: oldFingerprint
        )
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: newAlgorithm,
            protocolPublicKeyBytes: newPublicKey,
            protocolPublicKeyFingerprint: newFingerprint
        )
        let transcript = try DeviceIdentityRotationTranscript(
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
        return try SignalServerClient.IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: issuedAtMilliseconds,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion
        )
    }

    var oldConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: oldAlgorithm,
            protection: oldProtection
        )
    }

    var newConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: newAlgorithm,
            protection: newProtection
        )
    }

    var authenticationScope: SignalServerClient.IdentityRotationAuthenticationScope {
        SignalServerClient.IdentityRotationAuthenticationScope(
            tenantID: tenantID,
            userID: userID
        )
    }
}

/// Serializes crash recovery across startup and current-path authority readers.
/// Success is intentionally not cached because a rotation journal may appear
/// after any previous readiness check.
@MainActor
public final class CurrentPathAuthorityReadinessGate {
    public static let shared = CurrentPathAuthorityReadinessGate()

    private struct InFlightRecovery {
        let id: UUID
        let task: Task<Bool, Error>
    }

    private let recoverPendingRotation: () async throws -> Bool
    private var inFlightRecovery: InFlightRecovery?

    init(
        recoverPendingRotation: @escaping () async throws -> Bool = {
            try await CurrentPathDeviceIdentityRotationCoordinator.shared
                .recoverPendingRotationIfPresent()
        }
    ) {
        self.recoverPendingRotation = recoverPendingRotation
    }

    @discardableResult
    public func ensureReady() async throws -> Bool {
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

/// Coordinates the production authority change without allowing Settings to
/// publish a candidate before the authenticated server-side CAS commits.
@MainActor
public final class CurrentPathDeviceIdentityRotationCoordinator {
    public static let shared = CurrentPathDeviceIdentityRotationCoordinator()

    private let logger = Logger(
        subsystem: "com.skybridge.compass",
        category: "IdentityRotation"
    )
    private let signalServer: SignalServerClient
    private let requestJournalStore: CodablePersistenceStore<PendingDeviceIdentityRotationRequest>
    private let journalStore: CodablePersistenceStore<PendingDeviceIdentityRotation>
    private var inFlight = false

    init(
        signalServer: SignalServerClient = CrossNetworkConnectionManager
            .makeAuthenticatedSignalServerClient(),
        requestJournalStore: CodablePersistenceStore<PendingDeviceIdentityRotationRequest> =
            CodablePersistenceStore(
                location: .protectedApplicationSupport(
                    path: "Security/device-identity-rotation-request-v1.json"
                ),
                maximumPayloadBytes: 64 * 1_024
            ),
        journalStore: CodablePersistenceStore<PendingDeviceIdentityRotation> =
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

    public func rotate(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection,
        expectedScope: SignalServerClient.IdentityRotationAuthenticationScope
    ) async throws {
        guard !inFlight else {
            throw SettingsError.validationFailed(
                "A protocol identity rotation is already in progress"
            )
        }
        inFlight = true
        defer { inFlight = false }

        guard try await signalServer.authenticatedIdentityRotationScope()
                == expectedScope else {
            throw CurrentPathDeviceIdentityRotationError.authenticationStateChanged
        }
        _ = try await recoverPendingRotationIfPresentAssumingExclusiveAccess()
        let target = ProtocolIdentityConfigurationRecord(
            algorithm: algorithm,
            protection: protection
        )
        let settings = SettingsManager.shared
        if try await settings.committedProtocolIdentityConfiguration() == target {
            return
        }

        let oldSnapshot = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let deviceID = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: true)
            .deviceId
        let oldIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: oldSnapshot.algorithm,
            protocolPublicKeyBytes: oldSnapshot.publicKey
        )
        let prepared = try await settings.prepareProtocolIdentityConfiguration(
            algorithm: algorithm,
            protection: protection
        )

        do {
            let newIdentity = try ProtocolIdentityBinding(
                deviceId: deviceID,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyBytes: prepared.publicKey
            )
            let request = PendingDeviceIdentityRotationRequest(
                version: PendingDeviceIdentityRotationRequest.currentVersion,
                requestID: UUID().uuidString.lowercased(),
                expectedTenantID: expectedScope.tenantID,
                expectedUserID: expectedScope.userID,
                deviceID: deviceID,
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
            logger.info("Protocol identity rotation committed and activated")
        } catch CurrentPathDeviceIdentityRotationError.challengeExpired {
            settings.abandonPreparedProtocolIdentityConfiguration(prepared)
            throw CurrentPathDeviceIdentityRotationError.challengeExpired
        } catch CurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw CurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            settings.markProtocolIdentityConfigurationFailed(error, for: prepared)
            throw error
        }
    }

    @discardableResult
    public func recoverPendingRotationIfPresent() async throws -> Bool {
        guard !inFlight else {
            throw SettingsError.validationFailed(
                "A protocol identity rotation is already in progress"
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
        let authScope = try await CrossNetworkConnectionManager
            .currentAuthenticatedIdentityRotationScope()
        guard authScope.tenantID == request.expectedTenantID,
              authScope.userID == request.expectedUserID else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let settings = SettingsManager.shared
        guard try await settings.committedProtocolIdentityConfiguration()
                == request.oldConfiguration else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let oldSnapshot = try await CommittedLocalProtocolIdentitySnapshot.load(
            algorithm: request.oldAlgorithm,
            protection: request.oldProtection,
            keyManager: .shared
        )
        let prepared = try await settings.prepareProtocolIdentityConfiguration(
            algorithm: request.newAlgorithm,
            protection: request.newProtection
        )
        do {
            guard oldSnapshot.publicKey == request.oldPublicKey,
                  prepared.publicKey == request.newPublicKey else {
                throw CurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
            }
            try await completePendingRequest(
                request,
                oldSnapshot: oldSnapshot,
                prepared: prepared
            )
            logger.info("Recovered a challenge-stage protocol identity rotation")
            return true
        } catch CurrentPathDeviceIdentityRotationError.challengeExpired {
            settings.abandonPreparedProtocolIdentityConfiguration(prepared)
            return false
        } catch CurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw CurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            settings.markProtocolIdentityConfigurationFailed(error, for: prepared)
            throw error
        }
    }

    private func recoverCommitReadyRotation(
        _ pending: PendingDeviceIdentityRotation
    ) async throws -> Bool {
        let challenge = try pending.challenge()
        let authScope = try await CrossNetworkConnectionManager
            .currentAuthenticatedIdentityRotationScope()
        guard authScope.tenantID == pending.tenantID,
              authScope.userID == pending.userID else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }
        let settings = SettingsManager.shared
        let current = try await settings.committedProtocolIdentityConfiguration()

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
                throw CurrentPathDeviceIdentityRotationError
                    .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
            }
            return true
        }
        guard current == pending.oldConfiguration else {
            throw CurrentPathDeviceIdentityRotationError
                .pendingRotationConflictsWithLocalAuthority
        }

        let prepared = try await settings.prepareProtocolIdentityConfiguration(
            algorithm: pending.newAlgorithm,
            protection: pending.newProtection
        )
        do {
            guard prepared.publicKey == pending.newPublicKey else {
                throw CurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
            }
            _ = try await commitIdentityRotationPreservingOnlyRecoverableState(
                challenge: challenge,
                oldSignature: pending.oldSignature,
                newSignature: pending.newSignature,
                expectedScope: pending.authenticationScope
            )
            guard try await settings.committedProtocolIdentityConfiguration()
                    == pending.oldConfiguration else {
                throw CurrentPathDeviceIdentityRotationError.localConfigurationChanged
            }
            try settings.commitPreparedProtocolIdentityConfiguration(prepared)
            do {
                try journalStore.remove()
                try requestJournalStore.remove()
            } catch {
                throw CurrentPathDeviceIdentityRotationError
                    .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
            }
            logger.info("Recovered and activated a pending protocol identity rotation")
            return true
        } catch CurrentPathDeviceIdentityRotationError.challengeExpired {
            settings.abandonPreparedProtocolIdentityConfiguration(prepared)
            return false
        } catch CurrentPathDeviceIdentityRotationError
            .localAuthorityCommittedRecoveryRequired(let reason) {
            throw CurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(reason)
        } catch {
            settings.markProtocolIdentityConfigurationFailed(error, for: prepared)
            throw error
        }
    }

    private func completePendingRequest(
        _ request: PendingDeviceIdentityRotationRequest,
        oldSnapshot: CommittedLocalProtocolIdentitySnapshot,
        prepared: PreparedProtocolIdentityConfiguration
    ) async throws {
        let bindings = try request.bindings()
        guard oldSnapshot.algorithm == request.oldAlgorithm,
              oldSnapshot.protection == request.oldProtection,
              oldSnapshot.publicKey == request.oldPublicKey,
              prepared.configuration == request.newConfiguration,
              prepared.publicKey == request.newPublicKey else {
            throw CurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
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
            throw CurrentPathDeviceIdentityRotationError.preparedIdentityMismatch
        }
        let oldSignature = try await Self.signAndVerify(
            challenge.transcript.encoded,
            algorithm: oldSnapshot.algorithm,
            keyHandle: oldSnapshot.keyHandle,
            publicKey: oldSnapshot.publicKey
        )
        let newSignature = try await Self.signAndVerify(
            challenge.transcript.encoded,
            algorithm: request.newAlgorithm,
            keyHandle: prepared.keyHandle,
            publicKey: prepared.publicKey
        )
        let pending = PendingDeviceIdentityRotation(
            version: PendingDeviceIdentityRotation.currentVersion,
            requestID: request.requestID,
            rotationID: challenge.transcript.rotationID,
            nonce: challenge.transcript.nonce,
            issuedAtMilliseconds: challenge.issuedAtMilliseconds,
            expiresAtMilliseconds: challenge.expiresAtMilliseconds,
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
        let settings = SettingsManager.shared
        guard try await settings.committedProtocolIdentityConfiguration()
                == pending.oldConfiguration else {
            throw CurrentPathDeviceIdentityRotationError.localConfigurationChanged
        }
        try settings.commitPreparedProtocolIdentityConfiguration(prepared)
        do {
            try journalStore.remove()
            try requestJournalStore.remove()
        } catch {
            throw CurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(error.localizedDescription)
        }
    }

    private func commitIdentityRotationPreservingOnlyRecoverableState(
        challenge: SignalServerClient.IdentityRotationChallenge,
        oldSignature: Data,
        newSignature: Data,
        expectedScope: SignalServerClient.IdentityRotationAuthenticationScope
    ) async throws -> SignalServerClient.IdentityRotationCommitReceipt {
        do {
            return try await signalServer.commitIdentityRotation(
                challenge: challenge,
                oldSignature: oldSignature,
                newSignature: newSignature,
                expectedScope: expectedScope
            )
        } catch {
            guard SignalServerClient.isUncommittedIdentityRotationExpired(error) else {
                throw error
            }
            try journalStore.remove()
            try requestJournalStore.remove()
            throw CurrentPathDeviceIdentityRotationError.challengeExpired
        }
    }

    private func requestIdentityRotationChallengePreservingOnlyRecoverableState(
        oldIdentity: ProtocolIdentityBinding,
        newIdentity: ProtocolIdentityBinding,
        idempotencyKey: String,
        expectedScope: SignalServerClient.IdentityRotationAuthenticationScope
    ) async throws -> SignalServerClient.IdentityRotationChallenge {
        do {
            return try await signalServer.requestIdentityRotationChallenge(
                oldIdentity: oldIdentity,
                newIdentity: newIdentity,
                idempotencyKey: idempotencyKey,
                expectedScope: expectedScope
            )
        } catch {
            guard SignalServerClient.isUncommittedIdentityRotationExpired(error) else {
                throw error
            }
            try requestJournalStore.remove()
            throw CurrentPathDeviceIdentityRotationError.challengeExpired
        }
    }

    private func validateCommittedAuthorityMatchesPendingNewIdentity(
        _ pending: PendingDeviceIdentityRotation
    ) async throws {
        let snapshot = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let deviceID = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: false)
            .deviceId
        let binding = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: snapshot.algorithm,
            protocolPublicKeyBytes: snapshot.publicKey
        )
        guard deviceID == pending.deviceID,
              snapshot.algorithm == pending.newAlgorithm,
              snapshot.protection == pending.newProtection,
              snapshot.publicKey == pending.newPublicKey,
              binding.protocolPublicKeyFingerprint == pending.newFingerprint else {
            throw CurrentPathDeviceIdentityRotationError
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
            throw CurrentPathDeviceIdentityRotationError.proofVerificationFailed
        }
        return signature
    }
}
