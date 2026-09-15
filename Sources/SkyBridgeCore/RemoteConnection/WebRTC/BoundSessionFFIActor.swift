import CBoundSession
import CryptoKit
import Foundation
import SkyBridgeProtocolCore

enum BoundSessionRemoteRustAcceptanceOutcomeV2: UInt32, Sendable, Equatable {
    case first = 1
    case exactReplay = 2
}

/// Opaque product witness that the remote endpoint's Rust authority returned
/// First or Exact for these exact canonical bytes. Only this actor boundary can
/// construct one. It is not a transport ACK, peer attestation, malicious-host
/// proof, or crash-recovery record.
struct BoundSessionRemoteRustAcceptanceWitnessV2: Sendable, Equatable {
    let recordKind: BoundSessionWebRTCRecordKindV1
    let recordID: Data
    let recordSHA256: Data
    let remoteOutcome: BoundSessionRemoteRustAcceptanceOutcomeV2
    fileprivate let exactBytes: Data

    fileprivate init(
        record: BoundSessionGrantOutboundRecordV2,
        remoteOutcome: BoundSessionRemoteRustAcceptanceOutcomeV2
    ) {
        recordKind = record.metadata.kind
        recordID = record.metadata.recordID
        recordSHA256 = record.metadata.recordSHA256
        self.remoteOutcome = remoteOutcome
        exactBytes = record.exactBytes
    }
}

enum BoundSessionObservedWireActionV2: Sendable, Equatable {
    case produced
    case authenticated
    case receiptFirstAccepted
}

struct BoundSessionObservedWireV2: Sendable, Equatable {
    let direction: BoundSessionEvidenceDirectionV2
    let localRole: BoundSessionLocalRole
    let kind: BoundSessionWebRTCRecordKindV1
    let action: BoundSessionObservedWireActionV2
    let exactBytes: Data
    let sha256: Data
    let observedAt: Date

    fileprivate init(
        direction: BoundSessionEvidenceDirectionV2,
        localRole: BoundSessionLocalRole,
        kind: BoundSessionWebRTCRecordKindV1,
        action: BoundSessionObservedWireActionV2,
        exactBytes: Data,
        sha256: Data,
        observedAt: Date
    ) {
        self.direction = direction
        self.localRole = localRole
        self.kind = kind
        self.action = action
        self.exactBytes = exactBytes
        self.sha256 = sha256
        self.observedAt = observedAt
    }
}

struct BoundSessionObservedSignatureRequestV2: Sendable, Equatable {
    let direction: BoundSessionEvidenceDirectionV2
    let localRole: BoundSessionLocalRole
    let identityFingerprint: Data
    let exactPreimage: Data
    let signatureSHA256: Data
    let completedAt: Date

    fileprivate init(
        direction: BoundSessionEvidenceDirectionV2,
        localRole: BoundSessionLocalRole,
        identityFingerprint: Data,
        exactPreimage: Data,
        signatureSHA256: Data,
        completedAt: Date
    ) {
        self.direction = direction
        self.localRole = localRole
        self.identityFingerprint = identityFingerprint
        self.exactPreimage = exactPreimage
        self.signatureSHA256 = signatureSHA256
        self.completedAt = completedAt
    }
}

struct BoundSessionObservedDurableFileEffectV2: Sendable, Equatable {
    let direction: BoundSessionEvidenceDirectionV2
    let operation: BoundSessionFileOperationDescriptor
    let effectDigest: Data
    let durableCommit: InboundFileTransferDurableCommitObservation

    fileprivate init(
        direction: BoundSessionEvidenceDirectionV2,
        operation: BoundSessionFileOperationDescriptor,
        effectDigest: Data,
        durableCommit: InboundFileTransferDurableCommitObservation
    ) {
        self.direction = direction
        self.operation = operation
        self.effectDigest = effectDigest
        self.durableCommit = durableCommit
    }
}

struct BoundSessionAuthoritativeObservationSnapshotV2: Sendable, Equatable {
    let wires: [BoundSessionObservedWireV2]
    let signatureRequests: [BoundSessionObservedSignatureRequestV2]
    let grants: [BoundSessionFileGrantEvidenceProjectionV2]
    let durableFileEffects: [BoundSessionObservedDurableFileEffectV2]

    fileprivate init(
        wires: [BoundSessionObservedWireV2],
        signatureRequests: [BoundSessionObservedSignatureRequestV2],
        grants: [BoundSessionFileGrantEvidenceProjectionV2],
        durableFileEffects: [BoundSessionObservedDurableFileEffectV2]
    ) {
        self.wires = wires
        self.signatureRequests = signatureRequests
        self.grants = grants
        self.durableFileEffects = durableFileEffects
    }
}

/// Actor-isolated ownership boundary for the frozen BoundSession C ABI.
///
/// Rust remains the sole protocol and authority state machine. This actor only
/// records which opaque native capability is still live, which owner issued
/// it, and whether a linear capability was consumed by a successful ABI call.
actor BoundSessionFFIActor {
    private struct OwnedHandle {
        let nativeBytes: Data
        let ownerIdentifier: UUID
    }

    private struct GrantLinearHandle {
        let nativeBytes: Data
        let ownerIdentifier: UUID
        let grantIdentifier: UUID
        let operationDescriptor: BoundSessionFileOperationDescriptor
    }

    private struct NativeServiceCreation {
        let serviceBytes: Data
        let metadata: BoundSessionServiceMetadata
    }

    nonisolated let metadata: BoundSessionServiceMetadata

    private var serviceBytes: Data?
    private let localIdentity: CommittedLocalProtocolIdentitySnapshot
    private let evidenceJournal: BoundSessionEvidenceJournalV2
    private var evidenceJournalFailure: String?
    private var owners: [UUID: Data] = [:]
    private var sessions: [UUID: OwnedHandle] = [:]
    private var grants: [UUID: OwnedHandle] = [:]
    private var sessionDirections: [UUID: BoundSessionEvidenceDirectionV2] = [:]
    private var grantDirections: [UUID: BoundSessionEvidenceDirectionV2] = [:]
    private var operations: [UUID: GrantLinearHandle] = [:]
    private var permits: [UUID: GrantLinearHandle] = [:]
    private var retries: [UUID: GrantLinearHandle] = [:]
    private var durableEventCommittedPermits: Set<UUID> = []
    private var pendingDurableEventDigests: [UUID: Data] = [:]
    private var sessionRoles: [UUID: BoundSessionLocalRole] = [:]
    private var grantRoles: [UUID: BoundSessionLocalRole] = [:]
    private var observedWires: [BoundSessionObservedWireV2] = []
    private var observedSignatureRequests: [BoundSessionObservedSignatureRequestV2] = []
    private var observedGrantProjections: [BoundSessionFileGrantEvidenceProjectionV2] = []
    private var observedDurableFileEffects: [BoundSessionObservedDurableFileEffectV2] = []

    private init(
        serviceBytes: Data,
        metadata: BoundSessionServiceMetadata,
        localIdentity: CommittedLocalProtocolIdentitySnapshot,
        evidenceJournal: BoundSessionEvidenceJournalV2
    ) {
        self.serviceBytes = serviceBytes
        self.metadata = metadata
        self.localIdentity = localIdentity
        self.evidenceJournal = evidenceJournal
        evidenceJournalFailure = nil
    }

    static func create(
        configuration: BoundSessionFFIServiceConfiguration
    ) async throws -> BoundSessionFFIActor {
        defer { configuration.localRecipientPrivateKey.zeroize() }
        try requireRequiredCapabilitiesV2()
        try validate(configuration: configuration)
        let evidenceJournal: BoundSessionEvidenceJournalV2
        do {
            evidenceJournal = try BoundSessionEvidenceJournalV2(
                rootURL: configuration.evidenceJournalRoot,
                identityFingerprint: identityFingerprint(
                    for: configuration.localIdentity
                )
            )
        } catch {
            throw BoundSessionFFIError.evidenceJournalFailed(
                "factory validation failed: \(error.localizedDescription)"
            )
        }

        let loadedState: Data?
        do {
            loadedState = try await configuration.trustedStateStore.loadTrustedState(
                trustRootIdentifier: configuration.policyMaterial.trustRootIdentifier
            )
        } catch {
            throw BoundSessionFFIError.trustedStatePersistenceFailed(
                "load failed: \(error.localizedDescription)"
            )
        }

        let previousState: Data
        switch (configuration.enrollmentMode, loadedState) {
        case (.existingEnrollment, nil):
            throw BoundSessionFFIError.invalidConfiguration(
                "existing enrollment requires a persisted trusted policy state"
            )
        case (.explicitlyAuthorizedFirstEnrollment, nil):
            previousState = Data()
        case (_, .some(let state)):
            guard state.count == Int(BS_FFI_TRUSTED_POLICY_STATE_BYTES_V1) else {
                throw BoundSessionFFIError.invalidConfiguration(
                    "trusted policy state must be exactly \(BS_FFI_TRUSTED_POLICY_STATE_BYTES_V1) bytes"
                )
            }
            previousState = state
        }

        try Task.checkCancellation()
        let creation = try createNativeService(
            configuration: configuration,
            previousState: previousState
        )

        let committed: Bool
        do {
            committed = try await configuration.trustedStateStore.compareAndSwapTrustedState(
                expectedPreviousState: loadedState,
                newState: creation.metadata.trustedPolicyState,
                trustRootIdentifier: configuration.policyMaterial.trustRootIdentifier
            )
        } catch {
            try throwAfterDestroyingCreatedService(
                creation.serviceBytes,
                primary: "commit failed: \(error.localizedDescription)"
            )
        }
        guard committed else {
            try throwAfterDestroyingCreatedService(
                creation.serviceBytes,
                primary: "trusted state changed concurrently",
                concurrentChange: true
            )
        }

        // A definitive CAS success is the commit point. Do not reinterpret it
        // as cancellation and hide the monotonic state change from the caller.
        return BoundSessionFFIActor(
            serviceBytes: creation.serviceBytes,
            metadata: creation.metadata,
            localIdentity: configuration.localIdentity,
            evidenceJournal: evidenceJournal
        )
    }

    func issueOwner(_ binding: BoundSessionOwnerBinding) throws -> BoundSessionOwnerHandle {
        try requireEvidenceJournalHealthy()
        try Self.requireExact(binding.callerPrincipalDigest, count: 32, name: "caller principal digest")
        try Self.requireExact(binding.operationToken, count: 32, name: "operation token")
        try Self.requireExact(binding.driverIdentityDigest, count: 32, name: "driver identity digest")
        try Self.requireExact(binding.arbiterLease, count: 32, name: "arbiter lease")
        guard binding.connectionGeneration != 0, binding.decisionEpoch != 0 else {
            throw BoundSessionFFIError.invalidConfiguration(
                "connection generation and decision epoch must be non-zero"
            )
        }

        var input = BsFfiOwnerInputV1()
        input.abi_version = UInt32(BS_FFI_ABI_VERSION_V1)
        input.struct_size = UInt32(MemoryLayout<BsFfiOwnerInputV1>.size)
        input.connection_generation = binding.connectionGeneration
        input.decision_epoch = binding.decisionEpoch
        try Self.copyFixed(binding.callerPrincipalDigest, to: &input.caller_principal_digest)
        try Self.copyFixed(binding.operationToken, to: &input.operation_token)
        try Self.copyFixed(binding.driverIdentityDigest, to: &input.driver_identity_digest)
        try Self.copyFixed(binding.arbiterLease, to: &input.arbiter_lease)

        var nativeOwner = BsFfiOwnerHandleV1()
        let status = bs_ffi_owner_issue_v1(
            try nativeService(),
            &input,
            &nativeOwner
        )
        try Self.requireSuccess(status)
        let nativeBytes = Self.nativeBytes(of: &nativeOwner)
        try Self.requireNonzeroNativeHandle(nativeBytes, name: "owner")
        let identifier = UUID()
        owners[identifier] = nativeBytes
        return BoundSessionOwnerHandle(identifier: identifier)
    }

    func destroyOwner(_ owner: BoundSessionOwnerHandle) throws {
        _ = try ownerBytes(owner)
        let hasSession = sessions.values.contains { $0.ownerIdentifier == owner.identifier }
        let hasGrant = grants.values.contains { $0.ownerIdentifier == owner.identifier }
        let hasOperation = operations.values.contains { $0.ownerIdentifier == owner.identifier }
        let hasPermit = permits.values.contains { $0.ownerIdentifier == owner.identifier }
        let hasRetry = retries.values.contains { $0.ownerIdentifier == owner.identifier }
        guard !hasSession, !hasGrant, !hasOperation, !hasPermit, !hasRetry else {
            throw BoundSessionFFIError.pendingResources("owner-bound capabilities")
        }
        let status = bs_ffi_owner_destroy_v1(
            try nativeService(),
            try nativeOwner(owner)
        )
        try Self.requireSuccess(status)
        owners.removeValue(forKey: owner.identifier)
    }

    func beginInitiator(
        owner: BoundSessionOwnerHandle,
        canonicalContext: Data
    ) async throws -> BoundSessionSessionHandle {
        try requireEvidenceJournalHealthy()
        try Self.requireContext(canonicalContext)
        var request = BsFfiSignatureRequestV1()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let status = canonicalContext.withUnsafeBytes { context in
            bs_ffi_session_begin_initiator_v1(
                service,
                nativeOwner,
                context.bindMemory(to: UInt8.self).baseAddress,
                UInt(context.count),
                &request
            )
        }
        try Self.requireSuccess(status)
        return try await retainSignAndComplete(
            request: &request,
            owner: owner,
            expectedRole: .initiator
        )
    }

    func acceptMessageA(
        owner: BoundSessionOwnerHandle,
        canonicalContext: Data,
        messageA: Data,
        responderNonce: Data
    ) async throws -> BoundSessionSessionHandle {
        try requireEvidenceJournalHealthy()
        try Self.requireContext(canonicalContext)
        try Self.requireExact(responderNonce, count: 32, name: "responder nonce")
        try Self.requireRecord(messageA, kind: .messageA)
        var request = BsFfiSignatureRequestV1()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let status = Self.withBorrowedDataBuffers(
            [canonicalContext, messageA, responderNonce]
        ) { buffers in
            bs_ffi_session_accept_message_a_v1(
                service,
                nativeOwner,
                buffers[0].bindMemory(to: UInt8.self).baseAddress,
                UInt(buffers[0].count),
                buffers[1].bindMemory(to: UInt8.self).baseAddress,
                UInt(buffers[1].count),
                buffers[2].bindMemory(to: UInt8.self).baseAddress,
                UInt(buffers[2].count),
                &request
            )
        }
        try Self.requireSuccess(status)
        let session = try await retainSignAndComplete(
            request: &request,
            owner: owner,
            expectedRole: .responder
        )
        do {
            try appendAuthenticatedWireEvent(
                kind: .messageA,
                exactWire: messageA,
                direction: try sessionDirection(session, owner: owner),
                localRole: try sessionRole(session, owner: owner)
            )
            return session
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    func acceptMessageB(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        messageB: Data
    ) throws {
        try requireEvidenceJournalHealthy()
        try Self.requireRecord(messageB, kind: .messageB)
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeSession = try nativeSession(session, owner: owner)
        let status = messageB.withUnsafeBytes { bytes in
            bs_ffi_session_accept_message_b_v1(
                service,
                nativeOwner,
                nativeSession,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count)
            )
        }
        try Self.requireSuccess(status)
        do {
            try appendAuthenticatedWireEvent(
                kind: .messageB,
                exactWire: messageB,
                direction: try sessionDirection(session, owner: owner),
                localRole: try sessionRole(session, owner: owner)
            )
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    func acceptInitiatorFinished(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        finished: Data
    ) throws {
        try requireEvidenceJournalHealthy()
        try Self.requireRecord(finished, kind: .finished)
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeSession = try nativeSession(session, owner: owner)
        let status = finished.withUnsafeBytes { bytes in
            bs_ffi_session_accept_initiator_finished_v1(
                service,
                nativeOwner,
                nativeSession,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count)
            )
        }
        try Self.requireSuccess(status)
        do {
            try appendAuthenticatedWireEvent(
                kind: .finished,
                exactWire: finished,
                direction: try sessionDirection(session, owner: owner),
                localRole: try sessionRole(session, owner: owner)
            )
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    func acceptResponderFinished(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        finished: Data
    ) throws {
        try requireEvidenceJournalHealthy()
        try Self.requireRecord(finished, kind: .finished)
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeSession = try nativeSession(session, owner: owner)
        let status = finished.withUnsafeBytes { bytes in
            bs_ffi_session_accept_responder_finished_v1(
                service,
                nativeOwner,
                nativeSession,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count)
            )
        }
        try Self.requireSuccess(status)
        do {
            try appendAuthenticatedWireEvent(
                kind: .finished,
                exactWire: finished,
                direction: try sessionDirection(session, owner: owner),
                localRole: try sessionRole(session, owner: owner)
            )
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    func validateInboundLength(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        kind: BoundSessionWebRTCRecordKindV1,
        declaredLength: Int
    ) throws {
        guard declaredLength > 0,
            declaredLength <= kind.maximumRecordByteCount
        else {
            throw BoundSessionFFIError.invalidConfiguration("invalid declared inbound length")
        }
        let status = bs_ffi_session_validate_inbound_length_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner),
            kind.ffiRawValue,
            UInt(declaredLength)
        )
        try Self.requireSuccess(status)
    }

    nonisolated static func wireMaximumLength(
        for kind: BoundSessionWebRTCRecordKindV1
    ) throws -> Int {
        var maximum = UInt(0)
        let status = bs_ffi_wire_max_length_v1(kind.ffiRawValue, &maximum)
        try requireSuccess(status)
        guard let value = Int(exactly: maximum),
            value == kind.maximumRecordByteCount
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "wire maximum disagrees with the frozen carrier contract"
            )
        }
        return value
    }

    func takeSessionOutbound(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        capacity: Int? = nil
    ) throws -> BoundSessionOutboundRecord {
        try requireEvidenceJournalHealthy()
        var queriedKind = UInt32(0)
        var queriedLength = UInt(0)
        let sizeStatus = bs_ffi_session_outbound_size_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner),
            &queriedKind,
            &queriedLength
        )
        try Self.requireSuccess(sizeStatus)
        let kind = try BoundSessionWebRTCRecordKindV1(ffiRawValue: queriedKind)
        let required = try Self.validatedOutboundLength(queriedLength, kind: kind)
        let record = try takeSessionOutbound(
            owner: owner,
            session: session,
            queriedKind: kind,
            required: required,
            capacity: capacity ?? required
        )
        do {
            try recordObservedWire(
                record,
                action: .produced,
                direction: try sessionDirection(session, owner: owner),
                localRole: try sessionRole(session, owner: owner)
            )
            return record
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    func sessionState(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle
    ) throws -> BoundSessionSessionState {
        var rawState = UInt32(0)
        let status = bs_ffi_session_state_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner),
            &rawState
        )
        try Self.requireSuccess(status)
        guard let state = BoundSessionSessionState(rawValue: rawState) else {
            throw BoundSessionFFIError.invalidStateCode(rawState)
        }
        return state
    }

    func establishedInfo(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle
    ) throws -> BoundSessionEstablishedInfo {
        var result = BsFfiEstablishedInfoV1()
        let status = bs_ffi_session_established_info_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner),
            &result
        )
        try Self.requireSuccess(status)
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiEstablishedInfoV1>.size,
            name: "established info"
        )
        return BoundSessionEstablishedInfo(
            peerSessionID: Self.fixedData(&result.peer_session_id),
            contextDigest: Self.fixedData(&result.context_digest),
            transcriptDigest: Self.fixedData(&result.transcript_digest)
        )
    }

    func abortSession(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle
    ) throws {
        let status = bs_ffi_session_abort_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner)
        )
        try Self.requireSuccess(status)
        sessions.removeValue(forKey: session.identifier)
        sessionRoles.removeValue(forKey: session.identifier)
        sessionDirections.removeValue(forKey: session.identifier)
    }

    func shutdown() throws {
        guard owners.isEmpty, sessions.isEmpty, grants.isEmpty,
            operations.isEmpty, permits.isEmpty, retries.isEmpty
        else {
            throw BoundSessionFFIError.pendingResources("opaque capabilities")
        }
        let service = try nativeService()
        let status = bs_ffi_service_destroy_v1(service)
        try Self.requireSuccess(status)
        serviceBytes = nil
    }

    /// Returns the closed set of authoritative product producers still needed
    /// before any experiment-evidence/v2 export can be signed. This actor does
    /// not accept caller-authored records or success flags. Until every group
    /// is backed by an ordinary shipping-product observation, there is no
    /// export or signing entry point.
    func experimentEvidenceExportReadinessV2()
        -> BoundSessionExperimentEvidenceExportReadinessV2
    {
        .blocked(
            missingAuthoritativeProducers: BoundSessionExperimentEvidenceV2Gap.allCases
        )
    }

    /// Read-only snapshot of events durably emitted by ordinary FFI transitions.
    /// It exposes neither protocol secrets nor a way to insert caller-authored
    /// success. Complete V2 export remains blocked by the producer-gap set above.
    func evidenceJournalSnapshotV2() throws -> BoundSessionEvidenceJournalSnapshotV2 {
        try requireEvidenceJournalHealthy()
        return evidenceJournal.snapshot()
    }

    func authoritativeObservationSnapshotV2()
        throws -> BoundSessionAuthoritativeObservationSnapshotV2
    {
        try requireEvidenceJournalHealthy()
        return BoundSessionAuthoritativeObservationSnapshotV2(
            wires: observedWires,
            signatureRequests: observedSignatureRequests,
            grants: observedGrantProjections,
            durableFileEffects: observedDurableFileEffects
        )
    }

    // MARK: - File-purpose authority

    func installFileGrant(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        authorization: BoundSessionFileGrantAuthorization
    ) throws -> BoundSessionFileGrantInstallResult {
        try requireEvidenceJournalHealthy()
        let direction = try sessionDirection(session, owner: owner)
        let sessionRole = try sessionRole(session, owner: owner)
        try Self.requireExact(
            authorization.platformAuthorizationEvidenceDigest,
            count: 32,
            name: "platform authorization evidence digest"
        )
        try Self.requireNonzeroDigest(
            authorization.platformAuthorizationEvidenceDigest,
            name: "platform authorization evidence digest"
        )
        guard authorization.authorizationLifetimeMilliseconds > 0,
            authorization.authorizationLifetimeMilliseconds
                <= UInt64(BS_FFI_MAX_GRANT_AUTHORIZATION_LIFETIME_TICKS_V2)
        else {
            throw BoundSessionFFIError.invalidConfiguration(
                "grant authorization lifetime must be within the ABI-v2 bound"
            )
        }
        if let receiverTargetScopeDigest = authorization.receiverTargetScopeDigest {
            try Self.requireExact(
                receiverTargetScopeDigest,
                count: 32,
                name: "receiver target scope"
            )
            try Self.requireNonzeroDigest(
                receiverTargetScopeDigest,
                name: "receiver target scope"
            )
        }

        var nativeAuthorization = BsFfiDerivedFileGrantAuthorizationV2()
        nativeAuthorization.abi_version = UInt32(BS_FFI_ABI_VERSION_V2)
        nativeAuthorization.struct_size = UInt32(
            MemoryLayout<BsFfiDerivedFileGrantAuthorizationV2>.size
        )
        nativeAuthorization.receiver_target_scope_presence =
            authorization.receiverTargetScopeDigest == nil
            ? UInt32(BS_FFI_TARGET_SCOPE_ABSENT_V2)
            : UInt32(BS_FFI_TARGET_SCOPE_PRESENT_V2)
        nativeAuthorization.authorization_lifetime_ticks =
            authorization.authorizationLifetimeMilliseconds
        try Self.copyFixed(
            authorization.platformAuthorizationEvidenceDigest,
            to: &nativeAuthorization.platform_authorization_evidence_digest
        )
        if let receiverTargetScopeDigest = authorization.receiverTargetScopeDigest {
            try Self.copyFixed(
                receiverTargetScopeDigest,
                to: &nativeAuthorization.receiver_target_scope_digest
            )
        }

        var result = BsFfiFileGrantInstallResultV2()
        let status = bs_ffi_session_install_file_grant_v2(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner),
            &nativeAuthorization,
            &result
        )
        try Self.requireSuccess(status)
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiFileGrantInstallResultV2>.size,
            name: "grant install result",
            expectedABIVersion: UInt32(BS_FFI_ABI_VERSION_V2)
        )
        guard let localRole = BoundSessionLocalRole(rawValue: result.local_role),
            localRole == sessionRole,
            result.local_receives_file == 0 || result.local_receives_file == 1
        else {
            throw BoundSessionFFIError.nativeOutputContract("invalid grant role projection")
        }
        guard (result.local_receives_file == 1)
            == (authorization.receiverTargetScopeDigest != nil)
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "receiver-only target scope disagrees with the Rust-derived file direction"
            )
        }
        let nativeGrantBytes = Self.nativeBytes(of: &result.grant)
        try Self.requireNonzeroNativeHandle(nativeGrantBytes, name: "grant")
        let grantIdentifier = UUID()
        grants[grantIdentifier] = OwnedHandle(
            nativeBytes: nativeGrantBytes,
            ownerIdentifier: owner.identifier
        )
        grantDirections[grantIdentifier] = direction
        grantRoles[grantIdentifier] = sessionRole
        sessions.removeValue(forKey: session.identifier)
        sessionRoles.removeValue(forKey: session.identifier)
        sessionDirections.removeValue(forKey: session.identifier)
        return BoundSessionFileGrantInstallResult(
            grant: BoundSessionGrantHandle(identifier: grantIdentifier),
            peerSessionID: Self.fixedData(&result.peer_session_id),
            localRole: localRole,
            localReceivesFile: result.local_receives_file == 1
        )
    }

    func commitGrantAuthorization(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws {
        try requireEvidenceJournalHealthy()
        let status = bs_ffi_grant_commit_authorization_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner)
        )
        try Self.requireSuccess(status)
    }

    func prepareLocalReady(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws {
        try requireEvidenceJournalHealthy()
        let status = bs_ffi_grant_prepare_local_ready_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner)
        )
        try Self.requireSuccess(status)
    }

    func acceptPeerReadyAndEnable(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        ready: BoundSessionGrantOutboundRecordV2
    ) throws -> BoundSessionGrantEnableResult {
        try requireEvidenceJournalHealthy()
        guard ready.metadata.kind == .grantReady else {
            throw BoundSessionFFIError.nativeOutputContract(
                "peer Ready acceptance requires a GrantReady peek"
            )
        }
        try Self.validatePeekedGrantOutboundRecord(ready)
        var result = BsFfiGrantEnableResultV1()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeGrant = try nativeGrant(grant, owner: owner)
        let status = ready.exactBytes.withUnsafeBytes { bytes in
            bs_ffi_grant_accept_peer_ready_enable_v1(
                service,
                nativeOwner,
                nativeGrant,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &result
            )
        }
        try Self.requireSuccess(status)
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiGrantEnableResultV1>.size,
            name: "grant enable result"
        )
        guard let outcome = BoundSessionGrantEnableOutcome(rawValue: result.outcome) else {
            throw BoundSessionFFIError.invalidOutcomeCode(result.outcome)
        }
        let projection = BoundSessionGrantEnableResult(
            outcome: outcome,
            bilateralReadyDigest: Self.fixedData(&result.bilateral_ready_digest),
            remoteAcceptance: BoundSessionRemoteRustAcceptanceWitnessV2(
                record: ready,
                remoteOutcome: try Self.remoteAcceptanceOutcome(outcome)
            )
        )
        if outcome == .first {
            do {
                try requireObservationCapacity(
                    currentCount: observedGrantProjections.count,
                    name: "enabled grant projections"
                )
                try appendAuthenticatedWireEvent(
                    kind: .grantReady,
                    exactWire: ready.exactBytes,
                    direction: try grantDirection(grant, owner: owner),
                    localRole: try grantRole(grant, owner: owner)
                )
                let enabledProjection = try fileGrantEvidenceProjectionV2(
                    owner: owner,
                    grant: grant
                )
                observedGrantProjections.append(enabledProjection)
            } catch {
                try revokeGrantAfterEvidenceFailure(
                    owner: owner,
                    grant: grant,
                    primary: error
                )
            }
        }
        return projection
    }

    /// Returns a stable non-destructive view. The pending Rust outbox record is
    /// unchanged until `confirmGrantOutboundDelivery` receives a witness from
    /// the remote Rust authority for these exact bytes.
    func peekGrantOutbound(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        capacity: Int? = nil
    ) throws -> BoundSessionGrantOutboundRecordV2 {
        try requireEvidenceJournalHealthy()
        let probe = try peekGrantOutboundNative(
            owner: owner,
            grant: grant,
            capacity: 0
        )
        let required = probe.metadata.recordLength
        let requestedCapacity = capacity ?? required
        guard requestedCapacity >= 0,
            requestedCapacity <= Int(BS_FFI_GRANT_OUTBOUND_MAX_BYTES_V2)
        else {
            throw BoundSessionFFIError.invalidConfiguration(
                "invalid ABI-v2 grant outbound capacity"
            )
        }
        guard requestedCapacity >= required else {
            throw BoundSessionFFIError.bufferTooSmall(
                required: required,
                recordKind: probe.metadata.kind
            )
        }
        let copied = try peekGrantOutboundNative(
            owner: owner,
            grant: grant,
            capacity: requestedCapacity
        )
        guard copied.metadata == probe.metadata else {
            throw BoundSessionFFIError.nativeOutputContract(
                "grant outbound metadata changed between stable peeks"
            )
        }
        try Self.validatePeekedGrantOutboundRecord(copied)
        return copied
    }

    /// Enabled-only projection from Rust authority state.
    func fileGrantEvidenceProjectionV2(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws -> BoundSessionFileGrantEvidenceProjectionV2 {
        try requireEvidenceJournalHealthy()
        var nativeEvidence = BsFfiFileGrantEvidenceV2()
        let status = bs_ffi_grant_evidence_projection_v2(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            &nativeEvidence
        )
        try Self.requireSuccess(status)
        return try Self.validatedFileGrantEvidenceProjectionV2(
            &nativeEvidence,
            expectedRole: try grantRole(grant, owner: owner)
        )
    }

    /// Confirms only after a separately recorded remote Rust First/Exact
    /// acceptance for the exact peeked record. Transport sends and ACKs cannot
    /// produce the required witness.
    func confirmGrantOutboundDelivery(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        remoteAcceptance: BoundSessionRemoteRustAcceptanceWitnessV2
    ) throws -> BoundSessionTrustedDeliveryConfirmationOutcomeV2 {
        try requireEvidenceJournalHealthy()
        try Self.validateRemoteAcceptanceWitness(remoteAcceptance)

        var confirmation = BsFfiTrustedDeliveryConfirmationInputV2()
        confirmation.abi_version = UInt32(BS_FFI_ABI_VERSION_V2)
        confirmation.struct_size = UInt32(
            MemoryLayout<BsFfiTrustedDeliveryConfirmationInputV2>.size
        )
        try Self.copyFixed(remoteAcceptance.recordID, to: &confirmation.record_id)
        try Self.copyFixed(remoteAcceptance.recordSHA256, to: &confirmation.record_sha256)

        var result = BsFfiTrustedDeliveryConfirmationResultV2()
        let status = bs_ffi_grant_confirm_outbound_delivery_v2(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            &confirmation,
            &result
        )
        try Self.requireSuccess(status)
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiTrustedDeliveryConfirmationResultV2>.size,
            name: "trusted delivery confirmation result",
            expectedABIVersion: UInt32(BS_FFI_ABI_VERSION_V2)
        )
        guard result.reserved == 0,
            let outcome = BoundSessionTrustedDeliveryConfirmationOutcomeV2(
                rawValue: result.outcome
            )
        else {
            throw BoundSessionFFIError.invalidOutcomeCode(result.outcome)
        }
        if outcome == .firstConfirmed {
            let record = BoundSessionOutboundRecord(
                kind: remoteAcceptance.recordKind,
                exactBytes: remoteAcceptance.exactBytes
            )
            do {
                try recordObservedWire(
                    record,
                    action: .produced,
                    direction: try grantDirection(grant, owner: owner),
                    localRole: try grantRole(grant, owner: owner)
                )
                if record.kind == .effectReceipt {
                    _ = try appendEvidenceJournalEvent(
                        eventType: .receiptIssued,
                        direction: try grantDirection(grant, owner: owner),
                        subjectSHA256: remoteAcceptance.recordSHA256,
                        wireSHA256: remoteAcceptance.recordSHA256,
                        describedAt: Date()
                    )
                }
            } catch {
                try revokeGrantAfterEvidenceFailure(
                    owner: owner,
                    grant: grant,
                    primary: error
                )
            }
        }
        return outcome
    }

    func createOutboundFileDescriptor(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        requestDigest: Data
    ) throws -> BoundSessionFileOperationDescriptor {
        try requireEvidenceJournalHealthy()
        try Self.requireExact(requestDigest, count: 32, name: "request digest")
        var result = BsFfiFileOperationDescriptorV1()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeGrant = try nativeGrant(grant, owner: owner)
        let status = requestDigest.withUnsafeBytes { bytes in
            bs_ffi_grant_create_outbound_file_descriptor_v1(
                service,
                nativeOwner,
                nativeGrant,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &result
            )
        }
        try Self.requireSuccess(status)
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiFileOperationDescriptorV1>.size,
            name: "file operation descriptor"
        )
        let descriptor = BoundSessionFileOperationDescriptor(
            operationID: Self.fixedData(&result.operation_id),
            sequence: result.sequence,
            requestDigest: Self.fixedData(&result.request_digest)
        )
        guard descriptor.sequence != 0,
            descriptor.operationID.contains(where: { $0 != 0 }),
            descriptor.requestDigest == requestDigest
        else {
            throw BoundSessionFFIError.nativeOutputContract("invalid file operation descriptor")
        }
        return descriptor
    }

    func reserveInboundFileOperation(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        descriptor: BoundSessionFileOperationDescriptor
    ) throws -> BoundSessionOperationHandle {
        try requireEvidenceJournalHealthy()
        try Self.requireExact(descriptor.operationID, count: 32, name: "operation id")
        try Self.requireExact(descriptor.requestDigest, count: 32, name: "request digest")
        guard descriptor.sequence != 0 else {
            throw BoundSessionFFIError.invalidConfiguration("operation sequence must be non-zero")
        }
        var nativeDescriptor = BsFfiFileOperationDescriptorV1()
        nativeDescriptor.abi_version = UInt32(BS_FFI_ABI_VERSION_V1)
        nativeDescriptor.struct_size = UInt32(MemoryLayout<BsFfiFileOperationDescriptorV1>.size)
        nativeDescriptor.sequence = descriptor.sequence
        try Self.copyFixed(descriptor.operationID, to: &nativeDescriptor.operation_id)
        try Self.copyFixed(descriptor.requestDigest, to: &nativeDescriptor.request_digest)
        var nativeOperation = BsFfiOperationHandleV1()
        let status = bs_ffi_grant_reserve_inbound_file_operation_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            &nativeDescriptor,
            &nativeOperation
        )
        try Self.requireSuccess(status)
        let nativeBytes = Self.nativeBytes(of: &nativeOperation)
        try Self.requireNonzeroNativeHandle(nativeBytes, name: "operation")
        let identifier = UUID()
        operations[identifier] = GrantLinearHandle(
            nativeBytes: nativeBytes,
            ownerIdentifier: owner.identifier,
            grantIdentifier: grant.identifier,
            operationDescriptor: descriptor
        )
        return BoundSessionOperationHandle(identifier: identifier)
    }

    func markFileMayHaveStarted(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        operation: BoundSessionOperationHandle
    ) throws -> BoundSessionCommitPermitHandle {
        try requireEvidenceJournalHealthy()
        let operationEntry = try linearEntry(
            operation.identifier,
            in: operations,
            kind: "operation",
            owner: owner,
            grant: grant
        )
        let nativeOperation = try Self.nativeHandle(
            operationEntry.nativeBytes,
            initial: BsFfiOperationHandleV1()
        )
        var nativePermit = BsFfiCommitPermitHandleV1()
        let status = bs_ffi_grant_mark_file_may_have_started_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            nativeOperation,
            &nativePermit
        )
        try Self.requireSuccess(status)
        let nativeBytes = Self.nativeBytes(of: &nativePermit)
        try Self.requireNonzeroNativeHandle(nativeBytes, name: "permit")
        operations.removeValue(forKey: operation.identifier)
        let identifier = UUID()
        permits[identifier] = GrantLinearHandle(
            nativeBytes: nativeBytes,
            ownerIdentifier: owner.identifier,
            grantIdentifier: grant.identifier,
            operationDescriptor: operationEntry.operationDescriptor
        )
        return BoundSessionCommitPermitHandle(identifier: identifier)
    }

    /// Finalizes only an actually committed durable-file effect. The caller
    /// cannot provide an outcome flag or opaque effect digest: both are derived
    /// from the sealed I/O actor observation and the exact Rust operation.
    func finalizeCommittedFileOperation(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        permit: BoundSessionCommitPermitHandle,
        durableCommit: InboundFileTransferDurableCommitObservation
    ) throws -> BoundSessionFileFinalizationResult {
        let permitEntry = try linearEntry(
            permit.identifier,
            in: permits,
            kind: "permit",
            owner: owner,
            grant: grant
        )
        let effectDigest = try Self.durableFileEffectDigest(
            durableCommit,
            operation: permitEntry.operationDescriptor
        )
        let recordsNewDurableEffect = !durableEventCommittedPermits.contains(
            permit.identifier
        )
        if recordsNewDurableEffect {
            try requireObservationCapacity(
                currentCount: observedDurableFileEffects.count,
                name: "durable file effects"
            )
        }
        try ensureDurableCommitEvent(
            permit: permit,
            grant: grant,
            owner: owner,
            effectDigest: effectDigest,
            committedAt: durableCommit.committedAt
        )
        if recordsNewDurableEffect {
            observedDurableFileEffects.append(
                BoundSessionObservedDurableFileEffectV2(
                    direction: try grantDirection(grant, owner: owner),
                    operation: permitEntry.operationDescriptor,
                    effectDigest: effectDigest,
                    durableCommit: durableCommit
                )
            )
        }
        let nativePermit = try Self.nativeHandle(
            permitEntry.nativeBytes,
            initial: BsFfiCommitPermitHandleV1()
        )
        var result = BsFfiFileFinalizationResultV1()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeGrant = try nativeGrant(grant, owner: owner)
        let status = effectDigest.withUnsafeBytes { bytes in
            bs_ffi_grant_finalize_file_operation_v1(
                service,
                nativeOwner,
                nativeGrant,
                nativePermit,
                UInt32(BS_FFI_FINALIZE_COMMITTED_V1),
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &result
            )
        }
        try Self.requireSuccess(status)
        let projection = try retainFinalizationResult(
            &result,
            owner: owner,
            grant: grant,
            operationDescriptor: permitEntry.operationDescriptor
        )
        permits.removeValue(forKey: permit.identifier)
        durableEventCommittedPermits.remove(permit.identifier)
        pendingDurableEventDigests.removeValue(forKey: permit.identifier)
        return projection
    }

    func retryFileFinalization(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        retry: BoundSessionFinalizationRetryHandle
    ) throws -> BoundSessionFileFinalizationResult {
        try requireEvidenceJournalHealthy()
        let retryEntry = try linearEntry(
            retry.identifier,
            in: retries,
            kind: "retry",
            owner: owner,
            grant: grant
        )
        let nativeRetry = try Self.nativeHandle(
            retryEntry.nativeBytes,
            initial: BsFfiFinalizationRetryHandleV1()
        )
        var result = BsFfiFileFinalizationResultV1()
        let status = bs_ffi_grant_retry_file_finalization_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            nativeRetry,
            &result
        )
        try Self.requireSuccess(status)
        let projection = try retainFinalizationResult(
            &result,
            owner: owner,
            grant: grant,
            operationDescriptor: retryEntry.operationDescriptor
        )
        retries.removeValue(forKey: retry.identifier)
        return projection
    }

    func cancelReservedFileOperation(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        operation: BoundSessionOperationHandle
    ) throws {
        try requireEvidenceJournalHealthy()
        let status = bs_ffi_grant_cancel_reserved_file_operation_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner),
            try nativeOperation(operation, owner: owner, grant: grant)
        )
        try Self.requireSuccess(status)
        operations.removeValue(forKey: operation.identifier)
    }

    func acceptPeerReceipt(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        receipt: BoundSessionGrantOutboundRecordV2
    ) throws -> BoundSessionReceiptAcceptanceResultV2 {
        try requireEvidenceJournalHealthy()
        guard receipt.metadata.kind == .effectReceipt else {
            throw BoundSessionFFIError.nativeOutputContract(
                "peer receipt acceptance requires an EffectReceipt peek"
            )
        }
        try Self.validatePeekedGrantOutboundRecord(receipt)
        var rawAcceptance = UInt32(0)
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeGrant = try nativeGrant(grant, owner: owner)
        let status = receipt.exactBytes.withUnsafeBytes { bytes in
            bs_ffi_grant_accept_peer_receipt_v1(
                service,
                nativeOwner,
                nativeGrant,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &rawAcceptance
            )
        }
        try Self.requireSuccess(status)
        guard let acceptance = BoundSessionReceiptAcceptance(rawValue: rawAcceptance) else {
            throw BoundSessionFFIError.invalidOutcomeCode(rawAcceptance)
        }
        if acceptance == .first {
            let wireDigest = receipt.metadata.recordSHA256
            do {
                _ = try appendEvidenceJournalEvent(
                    eventType: .receiptVerified,
                    direction: try grantDirection(grant, owner: owner),
                    subjectSHA256: wireDigest,
                    wireSHA256: wireDigest,
                    describedAt: Date()
                )
                try recordObservedWire(
                    BoundSessionOutboundRecord(
                        kind: .effectReceipt,
                        exactBytes: receipt.exactBytes
                    ),
                    action: .receiptFirstAccepted,
                    direction: try grantDirection(grant, owner: owner),
                    localRole: try grantRole(grant, owner: owner)
                )
            } catch {
                try revokeGrantAfterEvidenceFailure(
                    owner: owner,
                    grant: grant,
                    primary: error
                )
            }
        }
        return BoundSessionReceiptAcceptanceResultV2(
            outcome: acceptance,
            remoteAcceptance: BoundSessionRemoteRustAcceptanceWitnessV2(
                record: receipt,
                remoteOutcome: try Self.remoteAcceptanceOutcome(acceptance)
            )
        )
    }

    func revokeGrant(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws {
        _ = try nativeGrant(grant, owner: owner)
        let hasOperation = operations.values.contains { $0.grantIdentifier == grant.identifier }
        let hasPermit = permits.values.contains { $0.grantIdentifier == grant.identifier }
        let hasRetry = retries.values.contains { $0.grantIdentifier == grant.identifier }
        guard !hasOperation, !hasPermit, !hasRetry else {
            throw BoundSessionFFIError.pendingResources("grant linear capabilities")
        }
        let status = bs_ffi_grant_revoke_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner)
        )
        try Self.requireSuccess(status)
        grants.removeValue(forKey: grant.identifier)
        grantDirections.removeValue(forKey: grant.identifier)
        grantRoles.removeValue(forKey: grant.identifier)
    }

    // MARK: - Native helpers

    private func retainSignAndComplete(
        request: inout BsFfiSignatureRequestV1,
        owner: BoundSessionOwnerHandle,
        expectedRole: BoundSessionLocalRole
    ) async throws -> BoundSessionSessionHandle {
        try Self.requireOutputHeader(
            abiVersion: request.abi_version,
            structSize: request.struct_size,
            expectedSize: MemoryLayout<BsFfiSignatureRequestV1>.size,
            name: "signature request"
        )
        let nativeSessionBytes = Self.nativeBytes(of: &request.session)
        try Self.requireNonzeroNativeHandle(nativeSessionBytes, name: "session")
        let sessionIdentifier = UUID()
        let session = BoundSessionSessionHandle(identifier: sessionIdentifier)
        sessions[sessionIdentifier] = OwnedHandle(
            nativeBytes: nativeSessionBytes,
            ownerIdentifier: owner.identifier
        )

        do {
            guard request.role == expectedRole.rawValue,
                Self.fixedData(&request.identity_fingerprint) == metadata.localIdentityFingerprint,
                Self.fixedData(&request.identity_fingerprint)
                    == Self.identityFingerprint(for: localIdentity)
            else {
                throw BoundSessionFFIError.signatureRequestMismatch
            }
            let preimage = Self.fixedData(&request.preimage)
            guard preimage.count == 32 else {
                throw BoundSessionFFIError.nativeOutputContract("signature preimage length")
            }
            try Task.checkCancellation()
            let signature: Data
            do {
                signature = try await PQCSignatureProvider(
                    algorithm: .mlDSA65,
                    backend: .auto
                ).sign(preimage, key: localIdentity.keyHandle)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BoundSessionFFIError.signatureFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            try Self.requireExact(
                signature,
                count: Int(BS_FFI_ML_DSA_65_SIGNATURE_BYTES_V1),
                name: "ML-DSA-65 signature"
            )
            let service = try nativeService()
            let nativeOwner = try nativeOwner(owner)
            let nativeSession = try nativeSession(session, owner: owner)
            let status = signature.withUnsafeBytes { bytes in
                bs_ffi_session_complete_signature_v1(
                    service,
                    nativeOwner,
                    nativeSession,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    UInt(bytes.count)
                )
            }
            try Self.requireSuccess(status)
            try requireObservationCapacity(
                currentCount: observedSignatureRequests.count,
                name: "identity signature requests"
            )
            let direction = evidenceDirection(localRole: expectedRole)
            observedSignatureRequests.append(
                BoundSessionObservedSignatureRequestV2(
                    direction: direction,
                    localRole: expectedRole,
                    identityFingerprint: Self.fixedData(&request.identity_fingerprint),
                    exactPreimage: preimage,
                    signatureSHA256: Data(SHA256.hash(data: signature)),
                    completedAt: Date()
                )
            )
            sessionRoles[sessionIdentifier] = expectedRole
            sessionDirections[sessionIdentifier] = evidenceDirection(
                localRole: expectedRole
            )
            return session
        } catch {
            try abortSessionAfterFailure(owner: owner, session: session, primary: error)
        }
    }

    private func abortSessionAfterFailure(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        primary: any Error
    ) throws -> Never {
        let status = bs_ffi_session_abort_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeSession(session, owner: owner)
        )
        if status == Int32(BS_FFI_OK_V1) {
            sessions.removeValue(forKey: session.identifier)
            sessionRoles.removeValue(forKey: session.identifier)
            sessionDirections.removeValue(forKey: session.identifier)
            throw primary
        }
        throw BoundSessionFFIError.nativeOutputContract(
            "session abort failed after \(primary.localizedDescription): \(Self.statusName(status)) (\(status))"
        )
    }

    private func requireEvidenceJournalHealthy() throws {
        if let evidenceJournalFailure {
            throw BoundSessionFFIError.evidenceJournalFailed(evidenceJournalFailure)
        }
    }

    private func appendAuthenticatedWireEvent(
        kind: BoundSessionWebRTCRecordKindV1,
        exactWire: Data,
        direction: BoundSessionEvidenceDirectionV2,
        localRole: BoundSessionLocalRole
    ) throws {
        try requireObservationCapacity(
            currentCount: observedWires.count,
            name: "exact wire observations"
        )
        let eventType: BoundSessionEvidenceJournalEventTypeV2
        switch kind {
        case .messageA:
            eventType = .wireMessageAVerified
        case .messageB:
            eventType = .wireMessageBVerified
        case .finished:
            eventType = .wireFinishedVerified
        case .grantReady:
            eventType = .wireGrantReadyVerified
        case .effectReceipt:
            throw BoundSessionFFIError.nativeOutputContract(
                "EffectReceipt uses the receipt authority event path"
            )
        }
        let wireDigest = Data(SHA256.hash(data: exactWire))
        _ = try appendEvidenceJournalEvent(
            eventType: eventType,
            direction: direction,
            subjectSHA256: wireDigest,
            wireSHA256: wireDigest,
            describedAt: Date()
        )
        try recordObservedWire(
            BoundSessionOutboundRecord(kind: kind, exactBytes: exactWire),
            action: .authenticated,
            direction: direction,
            localRole: localRole,
            capacityAlreadyChecked: true
        )
    }

    private func recordObservedWire(
        _ record: BoundSessionOutboundRecord,
        action: BoundSessionObservedWireActionV2,
        direction: BoundSessionEvidenceDirectionV2,
        localRole: BoundSessionLocalRole,
        capacityAlreadyChecked: Bool = false
    ) throws {
        if !capacityAlreadyChecked {
            try requireObservationCapacity(
                currentCount: observedWires.count,
                name: "exact wire observations"
            )
        }
        try Self.requireRecord(record.exactBytes, kind: record.kind)
        observedWires.append(
            BoundSessionObservedWireV2(
                direction: direction,
                localRole: localRole,
                kind: record.kind,
                action: action,
                exactBytes: record.exactBytes,
                sha256: Data(SHA256.hash(data: record.exactBytes)),
                observedAt: Date()
            )
        )
    }

    private func requireObservationCapacity(
        currentCount: Int,
        name: String
    ) throws {
        guard currentCount < 128 else {
            let reason = "bounded \(name) reached capacity 128"
            evidenceJournalFailure = reason
            throw BoundSessionFFIError.evidenceJournalFailed(reason)
        }
    }

    private func appendEvidenceJournalEvent(
        eventType: BoundSessionEvidenceJournalEventTypeV2,
        direction: BoundSessionEvidenceDirectionV2,
        subjectSHA256: Data,
        wireSHA256: Data?,
        describedAt: Date
    ) throws -> BoundSessionEvidenceJournalEventV2 {
        do {
            return try evidenceJournal.append(
                eventType: eventType,
                direction: direction,
                subjectSHA256: subjectSHA256,
                wireSHA256: wireSHA256,
                describedAt: describedAt
            )
        } catch {
            let reason = error.localizedDescription
            evidenceJournalFailure = reason
            throw BoundSessionFFIError.evidenceJournalFailed(reason)
        }
    }

    private func ensureDurableCommitEvent(
        permit: BoundSessionCommitPermitHandle,
        grant: BoundSessionGrantHandle,
        owner: BoundSessionOwnerHandle,
        effectDigest: Data,
        committedAt: Date
    ) throws {
        let direction = try grantDirection(grant, owner: owner)
        if let pendingDigest = pendingDurableEventDigests[permit.identifier] {
            guard pendingDigest == effectDigest else {
                throw BoundSessionFFIError.nativeOutputContract(
                    "durable commit retry changed its exact effect digest"
                )
            }
            do {
                let event = try evidenceJournal.retryPendingCommit()
                guard event.eventType == .durableCommit,
                    event.direction == direction,
                    event.subjectSHA256 == effectDigest,
                    event.wireSHA256 == nil
                else {
                    throw BoundSessionFFIError.nativeOutputContract(
                        "durable commit retry resolved a different journal event"
                    )
                }
                pendingDurableEventDigests.removeValue(forKey: permit.identifier)
                durableEventCommittedPermits.insert(permit.identifier)
                evidenceJournalFailure = nil
                return
            } catch {
                let reason = error.localizedDescription
                evidenceJournalFailure = reason
                throw BoundSessionFFIError.evidenceJournalFailed(reason)
            }
        }
        if durableEventCommittedPermits.contains(permit.identifier) {
            try requireEvidenceJournalHealthy()
            return
        }

        try requireEvidenceJournalHealthy()
        do {
            _ = try appendEvidenceJournalEvent(
                eventType: .durableCommit,
                direction: direction,
                subjectSHA256: effectDigest,
                wireSHA256: nil,
                describedAt: committedAt
            )
            durableEventCommittedPermits.insert(permit.identifier)
        } catch {
            pendingDurableEventDigests[permit.identifier] = effectDigest
            throw error
        }
    }

    private func evidenceDirection(
        localRole: BoundSessionLocalRole
    ) -> BoundSessionEvidenceDirectionV2 {
        let localIsGlobalInitiator = metadata.localIdentityFingerprint
            .lexicographicallyPrecedes(metadata.peerIdentityFingerprint)
        switch (localIsGlobalInitiator, localRole) {
        case (true, .initiator), (false, .responder):
            return .initiatorToResponder
        case (true, .responder), (false, .initiator):
            return .responderToInitiator
        }
    }

    private func sessionDirection(
        _ session: BoundSessionSessionHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BoundSessionEvidenceDirectionV2 {
        _ = try sessionEntry(session, owner: owner)
        guard let direction = sessionDirections[session.identifier] else {
            throw BoundSessionFFIError.nativeOutputContract(
                "session evidence direction is unavailable"
            )
        }
        return direction
    }

    private func sessionRole(
        _ session: BoundSessionSessionHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BoundSessionLocalRole {
        _ = try sessionEntry(session, owner: owner)
        guard let role = sessionRoles[session.identifier] else {
            throw BoundSessionFFIError.nativeOutputContract(
                "session evidence role is unavailable"
            )
        }
        return role
    }

    private func grantDirection(
        _ grant: BoundSessionGrantHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BoundSessionEvidenceDirectionV2 {
        _ = try grantEntry(grant, owner: owner)
        guard let direction = grantDirections[grant.identifier] else {
            throw BoundSessionFFIError.nativeOutputContract(
                "grant evidence direction is unavailable"
            )
        }
        return direction
    }

    private func grantRole(
        _ grant: BoundSessionGrantHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BoundSessionLocalRole {
        _ = try grantEntry(grant, owner: owner)
        guard let role = grantRoles[grant.identifier] else {
            throw BoundSessionFFIError.nativeOutputContract(
                "grant evidence role is unavailable"
            )
        }
        return role
    }

    private func revokeGrantAfterEvidenceFailure(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        primary: any Error
    ) throws -> Never {
        let status = bs_ffi_grant_revoke_v1(
            try nativeService(),
            try nativeOwner(owner),
            try nativeGrant(grant, owner: owner)
        )
        if status == Int32(BS_FFI_OK_V1) {
            grants.removeValue(forKey: grant.identifier)
            grantDirections.removeValue(forKey: grant.identifier)
            grantRoles.removeValue(forKey: grant.identifier)
            throw primary
        }
        throw BoundSessionFFIError.evidenceJournalFailed(
            "\(primary.localizedDescription); grant revoke failed: \(Self.statusName(status))"
        )
    }

    private nonisolated static func durableFileEffectDigest(
        _ observation: InboundFileTransferDurableCommitObservation,
        operation: BoundSessionFileOperationDescriptor
    ) throws -> Data {
        try requireExact(operation.operationID, count: 32, name: "operation id")
        try requireExact(operation.requestDigest, count: 32, name: "request digest")
        try requireExact(observation.sha256, count: 32, name: "committed file digest")
        let pathBytes = Data(observation.destinationRelativePath.utf8)
        guard operation.sequence > 0,
            observation.byteCount > 0,
            observation.sha256.contains(where: { $0 != 0 }),
            !pathBytes.isEmpty,
            pathBytes.count <= Int(UInt16.max),
            !pathBytes.contains(0),
            !observation.destinationRelativePath.contains("/"),
            observation.durabilityPrimitive == .fileAndParentDirectorySync
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "invalid sealed durable-file observation projection"
            )
        }
        var input = Data("skybridge/bound-session/durable-file-effect/v1\0".utf8)
        input.append(operation.operationID)
        appendUInt64(operation.sequence, to: &input)
        input.append(operation.requestDigest)
        appendUInt64(observation.byteCount, to: &input)
        input.append(observation.sha256)
        appendUInt16(UInt16(pathBytes.count), to: &input)
        input.append(pathBytes)
        let digest = Data(SHA256.hash(data: input))
        guard digest.contains(where: { $0 != 0 }) else {
            throw BoundSessionFFIError.nativeOutputContract(
                "durable-file effect digest is zero"
            )
        }
        return digest
    }

    private nonisolated static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private nonisolated static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private func takeSessionOutbound(
        owner: BoundSessionOwnerHandle,
        session: BoundSessionSessionHandle,
        queriedKind: BoundSessionWebRTCRecordKindV1,
        required: Int,
        capacity: Int
    ) throws -> BoundSessionOutboundRecord {
        guard capacity >= 0, capacity <= Int(BS_FFI_MAX_OUTBOUND_BYTES_V1) else {
            throw BoundSessionFFIError.invalidConfiguration("invalid outbound capacity")
        }
        var output = Data(repeating: 0, count: capacity)
        var takenKind = UInt32(0)
        var takenLength = UInt(0)
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeSession = try nativeSession(session, owner: owner)
        let status = output.withUnsafeMutableBytes { bytes in
            bs_ffi_session_take_outbound_v1(
                service,
                nativeOwner,
                nativeSession,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &takenKind,
                &takenLength
            )
        }
        if status == Int32(BS_FFI_ERR_BUFFER_TOO_SMALL_V1) {
            let reportedKind = try BoundSessionWebRTCRecordKindV1(ffiRawValue: takenKind)
            guard reportedKind == queriedKind,
                Int(exactly: takenLength) == required
            else {
                throw BoundSessionFFIError.nativeOutputContract("short-buffer metadata changed")
            }
            throw BoundSessionFFIError.bufferTooSmall(required: required, recordKind: queriedKind)
        }
        try Self.requireSuccess(status)
        return try Self.validatedTakenRecord(
            output: output,
            takenKind: takenKind,
            takenLength: takenLength,
            expectedKind: queriedKind,
            expectedLength: required
        )
    }

    private func peekGrantOutboundNative(
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        capacity: Int
    ) throws -> BoundSessionGrantOutboundRecordV2 {
        guard capacity >= 0,
            capacity <= Int(BS_FFI_GRANT_OUTBOUND_MAX_BYTES_V2)
        else {
            throw BoundSessionFFIError.invalidConfiguration(
                "invalid ABI-v2 grant outbound capacity"
            )
        }
        var output = Data(repeating: 0, count: capacity)
        var nativeMetadata = BsFfiGrantOutboundMetadataV2()
        let service = try nativeService()
        let nativeOwner = try nativeOwner(owner)
        let nativeGrant = try nativeGrant(grant, owner: owner)
        let status = output.withUnsafeMutableBytes { bytes in
            bs_ffi_grant_outbound_peek_v2(
                service,
                nativeOwner,
                nativeGrant,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count),
                &nativeMetadata
            )
        }
        guard status == Int32(BS_FFI_OK_V1)
            || status == Int32(BS_FFI_ERR_BUFFER_TOO_SMALL_V1)
        else {
            try Self.requireSuccess(status)
            throw BoundSessionFFIError.nativeOutputContract("unreachable grant peek status")
        }
        let metadata = try Self.validatedGrantOutboundMetadataV2(&nativeMetadata)
        guard status == Int32(BS_FFI_ERR_BUFFER_TOO_SMALL_V1)
            ? capacity < metadata.recordLength
            : capacity >= metadata.recordLength
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "grant peek status disagrees with its exact metadata"
            )
        }
        return BoundSessionGrantOutboundRecordV2(
            metadata: metadata,
            exactBytes: status == Int32(BS_FFI_OK_V1)
                ? Data(output.prefix(metadata.recordLength))
                : Data()
        )
    }

    private func retainFinalizationResult(
        _ result: inout BsFfiFileFinalizationResultV1,
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle,
        operationDescriptor: BoundSessionFileOperationDescriptor
    ) throws -> BoundSessionFileFinalizationResult {
        try Self.requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiFileFinalizationResultV1>.size,
            name: "file finalization result"
        )
        switch result.outcome {
        case UInt32(BS_FFI_FINALIZATION_RECEIPT_QUEUED_V1):
            let retryBytes = Self.nativeBytes(of: &result.retry)
            guard retryBytes.allSatisfy({ $0 == 0 }) else {
                throw BoundSessionFFIError.nativeOutputContract("queued receipt returned a retry handle")
            }
            return .receiptQueued
        case UInt32(BS_FFI_FINALIZATION_RETRY_REQUIRED_V1):
            let nativeBytes = Self.nativeBytes(of: &result.retry)
            try Self.requireNonzeroNativeHandle(nativeBytes, name: "retry")
            let identifier = UUID()
            retries[identifier] = GrantLinearHandle(
                nativeBytes: nativeBytes,
                ownerIdentifier: owner.identifier,
                grantIdentifier: grant.identifier,
                operationDescriptor: operationDescriptor
            )
            return .retryRequired(
                BoundSessionFinalizationRetryHandle(identifier: identifier)
            )
        default:
            throw BoundSessionFFIError.invalidOutcomeCode(result.outcome)
        }
    }

    private func ownerBytes(_ owner: BoundSessionOwnerHandle) throws -> Data {
        guard let bytes = owners[owner.identifier] else {
            throw BoundSessionFFIError.staleSwiftHandle("owner")
        }
        return bytes
    }

    private func sessionEntry(
        _ session: BoundSessionSessionHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> OwnedHandle {
        guard let entry = sessions[session.identifier] else {
            throw BoundSessionFFIError.staleSwiftHandle("session")
        }
        guard entry.ownerIdentifier == owner.identifier else {
            throw BoundSessionFFIError.crossOwnerHandle
        }
        return entry
    }

    private func grantEntry(
        _ grant: BoundSessionGrantHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> OwnedHandle {
        guard let entry = grants[grant.identifier] else {
            throw BoundSessionFFIError.staleSwiftHandle("grant")
        }
        guard entry.ownerIdentifier == owner.identifier else {
            throw BoundSessionFFIError.crossOwnerHandle
        }
        return entry
    }

    private func linearEntry(
        _ identifier: UUID,
        in entries: [UUID: GrantLinearHandle],
        kind: String,
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws -> GrantLinearHandle {
        guard let entry = entries[identifier] else {
            throw BoundSessionFFIError.staleSwiftHandle(kind)
        }
        guard entry.ownerIdentifier == owner.identifier,
            entry.grantIdentifier == grant.identifier
        else {
            throw BoundSessionFFIError.crossOwnerHandle
        }
        return entry
    }

    private func nativeService() throws -> BsFfiServiceHandleV1 {
        guard let serviceBytes else {
            throw BoundSessionFFIError.staleSwiftHandle("service")
        }
        return try Self.nativeHandle(serviceBytes, initial: BsFfiServiceHandleV1())
    }

    private func nativeOwner(_ owner: BoundSessionOwnerHandle) throws -> BsFfiOwnerHandleV1 {
        try Self.nativeHandle(try ownerBytes(owner), initial: BsFfiOwnerHandleV1())
    }

    private func nativeSession(
        _ session: BoundSessionSessionHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BsFfiSessionHandleV1 {
        try Self.nativeHandle(
            try sessionEntry(session, owner: owner).nativeBytes,
            initial: BsFfiSessionHandleV1()
        )
    }

    private func nativeGrant(
        _ grant: BoundSessionGrantHandle,
        owner: BoundSessionOwnerHandle
    ) throws -> BsFfiGrantHandleV1 {
        try Self.nativeHandle(
            try grantEntry(grant, owner: owner).nativeBytes,
            initial: BsFfiGrantHandleV1()
        )
    }

    private func nativeOperation(
        _ operation: BoundSessionOperationHandle,
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws -> BsFfiOperationHandleV1 {
        let entry = try linearEntry(
            operation.identifier,
            in: operations,
            kind: "operation",
            owner: owner,
            grant: grant
        )
        return try Self.nativeHandle(entry.nativeBytes, initial: BsFfiOperationHandleV1())
    }

    private func nativePermit(
        _ permit: BoundSessionCommitPermitHandle,
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws -> BsFfiCommitPermitHandleV1 {
        let entry = try linearEntry(
            permit.identifier,
            in: permits,
            kind: "permit",
            owner: owner,
            grant: grant
        )
        return try Self.nativeHandle(entry.nativeBytes, initial: BsFfiCommitPermitHandleV1())
    }

    private func nativeRetry(
        _ retry: BoundSessionFinalizationRetryHandle,
        owner: BoundSessionOwnerHandle,
        grant: BoundSessionGrantHandle
    ) throws -> BsFfiFinalizationRetryHandleV1 {
        let entry = try linearEntry(
            retry.identifier,
            in: retries,
            kind: "retry",
            owner: owner,
            grant: grant
        )
        return try Self.nativeHandle(
            entry.nativeBytes,
            initial: BsFfiFinalizationRetryHandleV1()
        )
    }

    private nonisolated static func validate(
        configuration: BoundSessionFFIServiceConfiguration
    ) throws {
        guard configuration.maximumInFlightSessions > 0,
            configuration.maximumOwnerCapabilities > 0,
            configuration.maximumHandshakeLifetimeMilliseconds > 0
        else {
            throw BoundSessionFFIError.invalidConfiguration("capacity and lifetime must be non-zero")
        }
        guard !configuration.policyMaterial.policyTOML.isEmpty,
            configuration.policyMaterial.policyTOML.count <= Int(BS_FFI_MAX_SIGNED_POLICY_BYTES_V1)
        else {
            throw BoundSessionFFIError.invalidConfiguration("signed policy length")
        }
        try requireExact(
            configuration.policyMaterial.detachedSignature,
            count: Int(BS_FFI_ML_DSA_65_SIGNATURE_BYTES_V1),
            name: "policy signature"
        )
        try requireExact(
            configuration.policyMaterial.verificationKey,
            count: Int(BS_FFI_ML_DSA_65_PUBLIC_KEY_BYTES_V1),
            name: "policy verification key"
        )
        try requireExact(
            configuration.policyMaterial.verificationKeySHA256Pin,
            count: 32,
            name: "policy verification-key pin"
        )
        guard
            Data(SHA256.hash(data: configuration.policyMaterial.verificationKey))
                == configuration.policyMaterial.verificationKeySHA256Pin
        else {
            throw BoundSessionFFIError.invalidConfiguration("policy verification-key pin mismatch")
        }
        guard !configuration.policyMaterial.trustRootIdentifier.isEmpty else {
            throw BoundSessionFFIError.invalidConfiguration("empty trust-root identifier")
        }

        let publicKeyLength =
            Int(BS_FFI_ML_KEM_768_PUBLIC_KEY_BYTES_V1)
            + Int(BS_FFI_X25519_KEY_BYTES_V1)
        let privateKeyLength =
            Int(BS_FFI_ML_KEM_768_SECRET_KEY_BYTES_V1)
            + Int(BS_FFI_X25519_KEY_BYTES_V1)
            + publicKeyLength
        try requireExact(
            configuration.localRecipientPublicKey,
            count: publicKeyLength,
            name: "local recipient public key"
        )
        try requireExact(
            configuration.peerRecipientPublicKey,
            count: publicKeyLength,
            name: "peer recipient public key"
        )
        guard configuration.localRecipientPublicKey != configuration.peerRecipientPublicKey else {
            throw BoundSessionFFIError.invalidConfiguration("local and peer recipient keys are reflected")
        }
        guard configuration.localRecipientPrivateKey.byteCount == privateKeyLength else {
            throw BoundSessionFFIError.invalidConfiguration("local recipient private-key blob length")
        }
        let embeddedPublicMatches = configuration.localRecipientPrivateKey.withUnsafeBytes { bytes in
            let publicOffset =
                Int(BS_FFI_ML_KEM_768_SECRET_KEY_BYTES_V1)
                + Int(BS_FFI_X25519_KEY_BYTES_V1)
            guard let base = bytes.baseAddress else { return false }
            return Data(bytes: base.advanced(by: publicOffset), count: publicKeyLength)
                == configuration.localRecipientPublicKey
        }
        guard embeddedPublicMatches else {
            throw BoundSessionFFIError.invalidConfiguration(
                "local recipient private blob disagrees with its public key"
            )
        }

        guard configuration.localIdentity.algorithm == .mlDSA65,
            configuration.localIdentity.publicKey.count == Int(BS_FFI_ML_DSA_65_PUBLIC_KEY_BYTES_V1),
            configuration.peerIdentityVerificationKey.count == Int(BS_FFI_ML_DSA_65_PUBLIC_KEY_BYTES_V1),
            configuration.localIdentity.publicKey != configuration.peerIdentityVerificationKey
        else {
            throw BoundSessionFFIError.identitySlotMismatch
        }
        let outboxPath = configuration.finishedOutboxRoot.standardizedFileURL.path
        let journalPath = configuration.evidenceJournalRoot.standardizedFileURL.path
        guard outboxPath.hasPrefix("/"), !outboxPath.utf8.contains(0) else {
            throw BoundSessionFFIError.invalidConfiguration(
                "Finished outbox path must be absolute"
            )
        }
        guard journalPath.hasPrefix("/"), !journalPath.utf8.contains(0),
            journalPath != outboxPath
        else {
            throw BoundSessionFFIError.invalidConfiguration(
                "evidence journal path must be absolute and distinct from Finished outbox"
            )
        }
    }

    private nonisolated static func requireRequiredCapabilitiesV2() throws {
        let required: UInt64 = 0x0F
        let compiled =
            UInt64(BS_FFI_CAPABILITY_GRANT_EVIDENCE_V2)
            | UInt64(BS_FFI_CAPABILITY_GRANT_OUTBOUND_PEEK_V2)
            | UInt64(BS_FFI_CAPABILITY_TRUSTED_DELIVERY_CONFIRMATION_V2)
            | UInt64(BS_FFI_CAPABILITY_DERIVED_FILE_GRANT_INSTALL_V2)
        let linked = bs_ffi_capabilities_v2()
        guard compiled == required, linked == required else {
            throw BoundSessionFFIError.requiredCapabilitiesUnavailable(
                expected: required,
                actual: linked
            )
        }
    }

    private nonisolated static func createNativeService(
        configuration: BoundSessionFFIServiceConfiguration,
        previousState: Data
    ) throws -> NativeServiceCreation {
        let pathBytes = Data(configuration.finishedOutboxRoot.standardizedFileURL.path.utf8)
        let buffers = [
            configuration.policyMaterial.policyTOML,
            configuration.policyMaterial.detachedSignature,
            configuration.policyMaterial.verificationKey,
            previousState,
            configuration.localRecipientPublicKey,
            configuration.peerRecipientPublicKey,
            configuration.localIdentity.publicKey,
            configuration.peerIdentityVerificationKey,
            pathBytes,
        ]

        var result = BsFfiServiceCreateResultV1()
        let status = try configuration.localRecipientPrivateKey.withUnsafeBytes { privateKey in
            try withBorrowedDataBuffers(buffers) { borrowed in
                var nativeConfig = BsFfiServiceConfigV1()
                nativeConfig.abi_version = UInt32(BS_FFI_ABI_VERSION_V1)
                nativeConfig.struct_size = UInt32(MemoryLayout<BsFfiServiceConfigV1>.size)
                nativeConfig.max_in_flight_sessions = configuration.maximumInFlightSessions
                nativeConfig.max_owner_capabilities = configuration.maximumOwnerCapabilities
                nativeConfig.max_handshake_lifetime_ticks =
                    configuration.maximumHandshakeLifetimeMilliseconds
                nativeConfig.signed_policy = try ffiBytes(borrowed[0])
                nativeConfig.policy_signature = try ffiBytes(borrowed[1])
                nativeConfig.policy_verification_key = try ffiBytes(borrowed[2])
                nativeConfig.last_trusted_policy_state = try ffiBytes(borrowed[3])
                nativeConfig.local_recipient_pq_secret_key = try ffiBytes(
                    privateKey,
                    offset: 0,
                    count: Int(BS_FFI_ML_KEM_768_SECRET_KEY_BYTES_V1)
                )
                nativeConfig.local_recipient_x25519_secret_key = try ffiBytes(
                    privateKey,
                    offset: Int(BS_FFI_ML_KEM_768_SECRET_KEY_BYTES_V1),
                    count: Int(BS_FFI_X25519_KEY_BYTES_V1)
                )
                nativeConfig.local_recipient_pq_public_key = try ffiBytes(
                    borrowed[4],
                    offset: 0,
                    count: Int(BS_FFI_ML_KEM_768_PUBLIC_KEY_BYTES_V1)
                )
                nativeConfig.local_recipient_x25519_public_key = try ffiBytes(
                    borrowed[4],
                    offset: Int(BS_FFI_ML_KEM_768_PUBLIC_KEY_BYTES_V1),
                    count: Int(BS_FFI_X25519_KEY_BYTES_V1)
                )
                nativeConfig.peer_recipient_pq_public_key = try ffiBytes(
                    borrowed[5],
                    offset: 0,
                    count: Int(BS_FFI_ML_KEM_768_PUBLIC_KEY_BYTES_V1)
                )
                nativeConfig.peer_recipient_x25519_public_key = try ffiBytes(
                    borrowed[5],
                    offset: Int(BS_FFI_ML_KEM_768_PUBLIC_KEY_BYTES_V1),
                    count: Int(BS_FFI_X25519_KEY_BYTES_V1)
                )
                nativeConfig.local_identity_verification_key = try ffiBytes(borrowed[6])
                nativeConfig.peer_identity_verification_key = try ffiBytes(borrowed[7])
                nativeConfig.finished_outbox_root = try ffiBytes(borrowed[8])
                return bs_ffi_service_create_v1(&nativeConfig, &result)
            }
        }
        try requireSuccess(status)
        try requireOutputHeader(
            abiVersion: result.abi_version,
            structSize: result.struct_size,
            expectedSize: MemoryLayout<BsFfiServiceCreateResultV1>.size,
            name: "service create result"
        )
        let serviceBytes = nativeBytes(of: &result.service)
        try requireNonzeroNativeHandle(serviceBytes, name: "service")
        let metadata = BoundSessionServiceMetadata(
            trustedPolicyState: fixedData(&result.trusted_policy_state),
            policyRootFingerprint: fixedData(&result.policy_root_fingerprint),
            localRecipientKeyDigest: fixedData(&result.local_recipient_key_digest),
            peerRecipientKeyDigest: fixedData(&result.peer_recipient_key_digest),
            localIdentityFingerprint: fixedData(&result.local_identity_fingerprint),
            peerIdentityFingerprint: fixedData(&result.peer_identity_fingerprint)
        )
        guard metadata.trustedPolicyState.count == Int(BS_FFI_TRUSTED_POLICY_STATE_BYTES_V1),
            metadata.policyRootFingerprint.count == 32,
            metadata.localRecipientKeyDigest.count == 32,
            metadata.peerRecipientKeyDigest.count == 32,
            metadata.localIdentityFingerprint
                == identityFingerprint(for: configuration.localIdentity),
            metadata.peerIdentityFingerprint
                == identityFingerprint(
                    publicKey: configuration.peerIdentityVerificationKey
                )
        else {
            let cleanupStatus = destroyNativeService(serviceBytes)
            if cleanupStatus != Int32(BS_FFI_OK_V1) {
                throw BoundSessionFFIError.nativeOutputContract(
                    "service metadata invalid and cleanup failed: \(statusName(cleanupStatus))"
                )
            }
            throw BoundSessionFFIError.nativeOutputContract("service metadata mismatch")
        }
        return NativeServiceCreation(serviceBytes: serviceBytes, metadata: metadata)
    }

    private nonisolated static func throwAfterDestroyingCreatedService(
        _ serviceBytes: Data,
        primary: String,
        concurrentChange: Bool = false
    ) throws -> Never {
        let cleanupStatus = destroyNativeService(serviceBytes)
        guard cleanupStatus == Int32(BS_FFI_OK_V1) else {
            throw BoundSessionFFIError.trustedStateCleanupFailed(
                primary: primary,
                cleanupStatus: cleanupStatus,
                cleanupName: statusName(cleanupStatus)
            )
        }
        if concurrentChange {
            throw BoundSessionFFIError.trustedStateChangedConcurrently
        }
        throw BoundSessionFFIError.trustedStatePersistenceFailed(primary)
    }

    private nonisolated static func destroyNativeService(_ bytes: Data) -> Int32 {
        guard let service = try? nativeHandle(bytes, initial: BsFfiServiceHandleV1()) else {
            return Int32(BS_FFI_ERR_INVALID_SERVICE_V1)
        }
        return bs_ffi_service_destroy_v1(service)
    }

    private nonisolated static func validatedTakenRecord(
        output: Data,
        takenKind: UInt32,
        takenLength: UInt,
        expectedKind: BoundSessionWebRTCRecordKindV1,
        expectedLength: Int
    ) throws -> BoundSessionOutboundRecord {
        let kind = try BoundSessionWebRTCRecordKindV1(ffiRawValue: takenKind)
        guard kind == expectedKind,
            Int(exactly: takenLength) == expectedLength,
            output.count >= expectedLength
        else {
            throw BoundSessionFFIError.nativeOutputContract("outbound metadata changed during take")
        }
        let exactBytes = Data(output.prefix(expectedLength))
        try requireRecord(exactBytes, kind: kind)
        return BoundSessionOutboundRecord(kind: kind, exactBytes: exactBytes)
    }

    private nonisolated static func validatedGrantOutboundMetadataV2(
        _ native: inout BsFfiGrantOutboundMetadataV2
    ) throws -> BoundSessionGrantOutboundMetadataV2 {
        try requireOutputHeader(
            abiVersion: native.abi_version,
            structSize: native.struct_size,
            expectedSize: MemoryLayout<BsFfiGrantOutboundMetadataV2>.size,
            name: "grant outbound metadata",
            expectedABIVersion: UInt32(BS_FFI_ABI_VERSION_V2)
        )
        let kind = try BoundSessionWebRTCRecordKindV1(ffiRawValue: native.record_kind)
        guard kind == .grantReady || kind == .effectReceipt,
            let direction = BoundSessionFileDirectionV2(rawValue: native.record_direction),
            let recordLength = Int(exactly: native.record_length),
            recordLength > 0,
            recordLength <= kind.maximumRecordByteCount,
            recordLength <= Int(BS_FFI_GRANT_OUTBOUND_MAX_BYTES_V2),
            native.logical_sequence > 0
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "invalid ABI-v2 grant outbound metadata"
            )
        }
        let metadata = BoundSessionGrantOutboundMetadataV2(
            kind: kind,
            direction: direction,
            recordLength: recordLength,
            logicalSequence: native.logical_sequence,
            recordID: fixedData(&native.record_id),
            recordSHA256: fixedData(&native.record_sha256),
            peerSessionID: fixedData(&native.peer_session_id),
            sharedGrantID: fixedData(&native.shared_grant_id)
        )
        for (name, digest) in [
            ("record id", metadata.recordID),
            ("record SHA-256", metadata.recordSHA256),
            ("peer session id", metadata.peerSessionID),
            ("shared grant id", metadata.sharedGrantID),
        ] {
            try requireNonzeroNativeDigest(digest, name: name)
        }
        return metadata
    }

    private nonisolated static func validatePeekedGrantOutboundRecord(
        _ record: BoundSessionGrantOutboundRecordV2
    ) throws {
        guard record.exactBytes.count == record.metadata.recordLength,
            Data(SHA256.hash(data: record.exactBytes)) == record.metadata.recordSHA256
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "peeked grant bytes disagree with authoritative metadata"
            )
        }
        try requireRecord(record.exactBytes, kind: record.metadata.kind)
    }

    private nonisolated static func validateRemoteAcceptanceWitness(
        _ witness: BoundSessionRemoteRustAcceptanceWitnessV2
    ) throws {
        try requireExact(witness.recordID, count: 32, name: "accepted record id")
        try requireNonzeroNativeDigest(witness.recordID, name: "accepted record id")
        try requireExact(witness.recordSHA256, count: 32, name: "accepted record SHA-256")
        try requireNonzeroNativeDigest(witness.recordSHA256, name: "accepted record SHA-256")
        guard witness.recordKind == .grantReady || witness.recordKind == .effectReceipt,
            Data(SHA256.hash(data: witness.exactBytes)) == witness.recordSHA256
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "remote Rust acceptance witness changed its exact record"
            )
        }
        try requireRecord(witness.exactBytes, kind: witness.recordKind)
    }

    private nonisolated static func remoteAcceptanceOutcome(
        _ outcome: BoundSessionGrantEnableOutcome
    ) throws -> BoundSessionRemoteRustAcceptanceOutcomeV2 {
        guard let result = BoundSessionRemoteRustAcceptanceOutcomeV2(
            rawValue: outcome.rawValue
        ) else {
            throw BoundSessionFFIError.invalidOutcomeCode(outcome.rawValue)
        }
        return result
    }

    private nonisolated static func remoteAcceptanceOutcome(
        _ outcome: BoundSessionReceiptAcceptance
    ) throws -> BoundSessionRemoteRustAcceptanceOutcomeV2 {
        guard let result = BoundSessionRemoteRustAcceptanceOutcomeV2(
            rawValue: outcome.rawValue
        ) else {
            throw BoundSessionFFIError.invalidOutcomeCode(outcome.rawValue)
        }
        return result
    }

    private nonisolated static func validatedFileGrantEvidenceProjectionV2(
        _ native: inout BsFfiFileGrantEvidenceV2,
        expectedRole: BoundSessionLocalRole
    ) throws -> BoundSessionFileGrantEvidenceProjectionV2 {
        try requireOutputHeader(
            abiVersion: native.abi_version,
            structSize: native.struct_size,
            expectedSize: MemoryLayout<BsFfiFileGrantEvidenceV2>.size,
            name: "file grant evidence projection",
            expectedABIVersion: UInt32(BS_FFI_ABI_VERSION_V2)
        )
        guard let state = BoundSessionEnabledGrantStateV2(rawValue: native.grant_state),
            let fileDirection = BoundSessionFileDirectionV2(rawValue: native.file_direction),
            let localRole = BoundSessionLocalRole(rawValue: native.local_role),
            localRole == expectedRole,
            native.local_receives_file == 0 || native.local_receives_file == 1,
            native.reserved_u32 == 0,
            native.connection_generation > 0,
            native.decision_epoch > 0,
            native.authorization_expires_at_tick > 0,
            native.policy_version > 0,
            native.declared_bytes > 0,
            native.wire_crypto_profile_id > 0,
            native.suite_id > 0,
            native.hybrid_profile_id > 0,
            native.key_format_id > 0
        else {
            throw BoundSessionFFIError.nativeOutputContract(
                "invalid enabled file grant evidence projection"
            )
        }
        let targetBytes = fixedData(&native.local_durable_file_target_scope)
        let target: Data?
        switch native.local_durable_file_target_scope_presence {
        case UInt32(BS_FFI_TARGET_SCOPE_ABSENT_V2) where targetBytes.allSatisfy({ $0 == 0 }):
            target = nil
        case UInt32(BS_FFI_TARGET_SCOPE_PRESENT_V2) where targetBytes.contains(where: { $0 != 0 }):
            target = targetBytes
        default:
            throw BoundSessionFFIError.nativeOutputContract(
                "invalid receiver-only target scope projection"
            )
        }
        let localReceivesFile = native.local_receives_file == 1
        guard localReceivesFile == (target != nil) else {
            throw BoundSessionFFIError.nativeOutputContract(
                "target scope presence disagrees with the Rust-derived receiver role"
            )
        }
        let projection = BoundSessionFileGrantEvidenceProjectionV2(
            state: state,
            fileDirection: fileDirection,
            localRole: localRole,
            localReceivesFile: localReceivesFile,
            connectionGeneration: native.connection_generation,
            decisionEpoch: native.decision_epoch,
            authorizationExpiresAtTick: native.authorization_expires_at_tick,
            policyVersion: native.policy_version,
            declaredBytes: native.declared_bytes,
            wireCryptoProfileID: native.wire_crypto_profile_id,
            suiteID: native.suite_id,
            hybridProfileID: native.hybrid_profile_id,
            keyFormatID: native.key_format_id,
            peerSessionID: fixedData(&native.peer_session_id),
            contextDigest: fixedData(&native.context_digest),
            transcriptDigest: fixedData(&native.transcript_digest),
            sharedGrantID: fixedData(&native.shared_grant_id),
            bilateralReadyDigest: fixedData(&native.bilateral_ready_digest),
            policyDigest: fixedData(&native.policy_digest),
            policyRootKeyFingerprint: fixedData(&native.policy_root_key_fingerprint),
            wireDecisionDigest: fixedData(&native.wire_decision_digest),
            purposeDigest: fixedData(&native.purpose_digest),
            recipientKEMPublicKeyDigest: fixedData(&native.recipient_kem_public_key_digest),
            initiatorIdentityFingerprint: fixedData(&native.initiator_identity_fingerprint),
            responderIdentityFingerprint: fixedData(&native.responder_identity_fingerprint),
            clientNonce: fixedData(&native.client_nonce),
            transferID: fixedData(&native.transfer_id),
            contentSHA256: fixedData(&native.content_sha256),
            localAuthorizationCommitment: fixedData(&native.local_authorization_commitment),
            localDurableFileTargetScope: target,
            authorizationTransactionIDDigest: fixedData(
                &native.authorization_transaction_id_digest
            ),
            platformAuthorizationEvidenceDigest: fixedData(
                &native.platform_authorization_evidence_digest
            ),
            authorizationRecordDigest: fixedData(&native.authorization_record_digest),
            ownerBindingDigest: fixedData(&native.owner_binding_digest),
            serviceIncarnationDigest: fixedData(&native.service_incarnation_digest),
            durableFileCommitterIdentityDigest: fixedData(
                &native.durable_file_committer_identity_digest
            )
        )
        for (name, digest) in [
            ("peer session id", projection.peerSessionID),
            ("context digest", projection.contextDigest),
            ("transcript digest", projection.transcriptDigest),
            ("shared grant id", projection.sharedGrantID),
            ("bilateral Ready digest", projection.bilateralReadyDigest),
            ("policy digest", projection.policyDigest),
            ("policy root fingerprint", projection.policyRootKeyFingerprint),
            ("wire decision digest", projection.wireDecisionDigest),
            ("purpose digest", projection.purposeDigest),
            ("recipient KEM public-key digest", projection.recipientKEMPublicKeyDigest),
            ("initiator identity fingerprint", projection.initiatorIdentityFingerprint),
            ("responder identity fingerprint", projection.responderIdentityFingerprint),
            ("client nonce", projection.clientNonce),
            ("transfer id", projection.transferID),
            ("content SHA-256", projection.contentSHA256),
            ("local authorization commitment", projection.localAuthorizationCommitment),
            ("authorization transaction digest", projection.authorizationTransactionIDDigest),
            ("platform authorization evidence digest", projection.platformAuthorizationEvidenceDigest),
            ("authorization record digest", projection.authorizationRecordDigest),
            ("owner binding digest", projection.ownerBindingDigest),
            ("service incarnation digest", projection.serviceIncarnationDigest),
            ("durable file committer identity digest", projection.durableFileCommitterIdentityDigest),
        ] {
            try requireNonzeroNativeDigest(digest, name: name)
        }
        return projection
    }

    private nonisolated static func validatedOutboundLength(
        _ rawLength: UInt,
        kind: BoundSessionWebRTCRecordKindV1
    ) throws -> Int {
        guard let length = Int(exactly: rawLength),
            length > 0,
            length <= kind.maximumRecordByteCount,
            length <= Int(BS_FFI_MAX_OUTBOUND_BYTES_V1)
        else {
            throw BoundSessionFFIError.nativeOutputContract("outbound length exceeds its exact cap")
        }
        return length
    }

    private nonisolated static func requireRecord(
        _ record: Data,
        kind: BoundSessionWebRTCRecordKindV1
    ) throws {
        try BoundSessionWebRTCCarrierPolicyV1.validateRecordEnvelope(
            record,
            expectedRecordKind: kind
        )
    }

    private nonisolated static func requireContext(_ context: Data) throws {
        guard !context.isEmpty,
            context.count <= Int(BS_FFI_MAX_CONTEXT_BYTES_V1)
        else {
            throw BoundSessionFFIError.invalidConfiguration("canonical context length")
        }
    }

    private nonisolated static func requireExact(
        _ data: Data,
        count: Int,
        name: String
    ) throws {
        guard data.count == count else {
            throw BoundSessionFFIError.invalidConfiguration(
                "\(name) must be exactly \(count) bytes, got \(data.count)"
            )
        }
    }

    private nonisolated static func requireNonzeroDigest(
        _ data: Data,
        name: String
    ) throws {
        try requireExact(data, count: 32, name: name)
        guard data.contains(where: { $0 != 0 }) else {
            throw BoundSessionFFIError.invalidConfiguration(
                "\(name) must be non-zero"
            )
        }
    }

    private nonisolated static func requireNonzeroNativeDigest(
        _ data: Data,
        name: String
    ) throws {
        guard data.count == 32, data.contains(where: { $0 != 0 }) else {
            throw BoundSessionFFIError.nativeOutputContract(
                "\(name) must be an exact non-zero 32-byte value"
            )
        }
    }

    private nonisolated static func requireOutputHeader(
        abiVersion: UInt32,
        structSize: UInt32,
        expectedSize: Int,
        name: String,
        expectedABIVersion: UInt32 = UInt32(BS_FFI_ABI_VERSION_V1)
    ) throws {
        guard abiVersion == expectedABIVersion,
            structSize == UInt32(expectedSize)
        else {
            throw BoundSessionFFIError.nativeOutputContract("\(name) ABI header")
        }
    }

    private nonisolated static func requireNonzeroNativeHandle(
        _ bytes: Data,
        name: String
    ) throws {
        guard bytes.count == Int(BS_FFI_HANDLE_BYTES_V1),
            bytes.contains(where: { $0 != 0 })
        else {
            throw BoundSessionFFIError.nativeOutputContract("invalid \(name) handle")
        }
    }

    private nonisolated static func requireSuccess(_ status: Int32) throws {
        guard status == Int32(BS_FFI_OK_V1) else {
            throw BoundSessionFFIError.native(status: status, name: statusName(status))
        }
    }

    private nonisolated static func statusName(_ status: Int32) -> String {
        guard let pointer = bs_ffi_status_name_v1(status) else {
            return "UNKNOWN_STATUS"
        }
        return String(cString: pointer)
    }

    private nonisolated static func identityFingerprint(
        for identity: CommittedLocalProtocolIdentitySnapshot
    ) -> Data {
        identityFingerprint(publicKey: identity.publicKey)
    }

    private nonisolated static func identityFingerprint(publicKey: Data) -> Data {
        let value = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )
        return Data(hexString: value) ?? Data()
    }

    private nonisolated static func copyFixed<T>(_ data: Data, to value: inout T) throws {
        guard data.count == MemoryLayout<T>.size else {
            throw BoundSessionFFIError.nativeOutputContract("fixed C field size mismatch")
        }
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination)
        }
    }

    private nonisolated static func fixedData<T>(_ value: inout T) -> Data {
        withUnsafeBytes(of: &value) { Data($0) }
    }

    private nonisolated static func nativeBytes<T>(of value: inout T) -> Data {
        withUnsafeBytes(of: &value) { Data($0) }
    }

    private nonisolated static func nativeHandle<T>(
        _ bytes: Data,
        initial: T
    ) throws -> T {
        guard bytes.count == MemoryLayout<T>.size else {
            throw BoundSessionFFIError.nativeOutputContract("native handle layout mismatch")
        }
        var value = initial
        _ = withUnsafeMutableBytes(of: &value) { destination in
            bytes.copyBytes(to: destination)
        }
        return value
    }

    private nonisolated static func ffiBytes(
        _ buffer: UnsafeRawBufferPointer,
        offset: Int = 0,
        count: Int? = nil
    ) throws -> BsFfiBytesV1 {
        let length = count ?? buffer.count
        guard offset >= 0, length >= 0, offset <= buffer.count,
            length <= buffer.count - offset
        else {
            throw BoundSessionFFIError.nativeOutputContract("borrowed C buffer range")
        }
        let pointer = buffer.baseAddress?
            .advanced(by: offset)
            .assumingMemoryBound(to: UInt8.self)
        return BsFfiBytesV1(pointer: pointer, length: UInt(length))
    }

    private nonisolated static func withBorrowedDataBuffers<Result>(
        _ data: [Data],
        _ body: ([UnsafeRawBufferPointer]) throws -> Result
    ) rethrows -> Result {
        var buffers: [UnsafeRawBufferPointer] = []
        buffers.reserveCapacity(data.count)

        func borrow(_ index: Int) throws -> Result {
            if index == data.count {
                return try body(buffers)
            }
            return try data[index].withUnsafeBytes { bytes in
                buffers.append(bytes)
                defer { buffers.removeLast() }
                return try borrow(index + 1)
            }
        }

        return try borrow(0)
    }
}
