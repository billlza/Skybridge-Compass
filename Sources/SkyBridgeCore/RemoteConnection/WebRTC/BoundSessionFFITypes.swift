import CBoundSession
import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

/// Authoritative producer groups that must exist before this product can emit
/// a claim-eligible experiment-evidence/v2 bundle. These are intentionally
/// record-level gaps, not values that a caller may fill with defaults.
enum BoundSessionExperimentEvidenceV2Gap: String, CaseIterable, Sendable, Equatable {
    case preregistrationAndSourceClosure =
        "raw_preregistration+raw_source_freeze+raw_source_tree_manifest+raw_build_record"
    case physicalEndpointRecords = "raw_device_record"
    case carrierObservations = "raw_ice_observation"
    case sessionAndWireAcceptanceRecords = "raw_bound_session_report+raw_wire_authentication_acceptance"
    case fileTransferRecords = "raw_file_transfer_record"
    case durableCommitRecords = "raw_durable_commit"
    case receiptAndAuthorityAcceptanceRecords = "raw_receipt_verification+raw_authority_acceptance"
    case persistentEventJournals = "raw_event_journal"
    case trustSnapshots = "raw_trust_snapshot(before+after)"
    case ownerCleanupRecords = "raw_cleanup_record"
}

enum BoundSessionExperimentEvidenceExportReadinessV2: Sendable, Equatable {
    case blocked(missingAuthoritativeProducers: [BoundSessionExperimentEvidenceV2Gap])
}

enum BoundSessionFFIError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case native(status: Int32, name: String)
    case trustedStatePersistenceFailed(String)
    case trustedStateChangedConcurrently
    case trustedStateCleanupFailed(primary: String, cleanupStatus: Int32, cleanupName: String)
    case evidenceJournalFailed(String)
    case identitySlotMismatch
    case signatureRequestMismatch
    case invalidRecordKind(UInt32)
    case invalidStateCode(UInt32)
    case invalidOutcomeCode(UInt32)
    case staleSwiftHandle(String)
    case crossOwnerHandle
    case pendingResources(String)
    case bufferTooSmall(required: Int, recordKind: BoundSessionWebRTCRecordKindV1)
    case nativeOutputContract(String)
    case signatureFailed(String)
    case requiredCapabilitiesUnavailable(expected: UInt64, actual: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid BoundSession configuration: \(reason)"
        case .native(let status, let name):
            "BoundSession FFI failed: \(name) (\(status))"
        case .trustedStatePersistenceFailed(let reason):
            "BoundSession trusted policy state was not persisted: \(reason)"
        case .trustedStateChangedConcurrently:
            "BoundSession trusted policy state changed during service creation"
        case .trustedStateCleanupFailed(let primary, let status, let name):
            "BoundSession trusted-state commit failed (\(primary)); service cleanup failed: \(name) (\(status))"
        case .evidenceJournalFailed(let reason):
            "BoundSession authoritative evidence journal failed: \(reason)"
        case .identitySlotMismatch:
            "BoundSession requires the exact configured ML-DSA-65 identity slot"
        case .signatureRequestMismatch:
            "BoundSession returned a signing request for a different identity or role"
        case .invalidRecordKind(let rawValue):
            "BoundSession returned an unknown record kind: \(rawValue)"
        case .invalidStateCode(let rawValue):
            "BoundSession returned an unknown session state: \(rawValue)"
        case .invalidOutcomeCode(let rawValue):
            "BoundSession returned an unknown outcome code: \(rawValue)"
        case .staleSwiftHandle(let kind):
            "BoundSession \(kind) handle is stale or already consumed"
        case .crossOwnerHandle:
            "BoundSession handle belongs to a different owner"
        case .pendingResources(let description):
            "BoundSession resource cannot be destroyed while \(description) remain live"
        case .bufferTooSmall(let required, let recordKind):
            "BoundSession output buffer is too small for kind \(recordKind.rawValue): required=\(required)"
        case .nativeOutputContract(let reason):
            "BoundSession FFI returned an invalid public output: \(reason)"
        case .signatureFailed(let reason):
            "BoundSession identity signing failed: \(reason)"
        case .requiredCapabilitiesUnavailable(let expected, let actual):
            "BoundSession required ABI-v2 capabilities unavailable: expected=0x\(String(expected, radix: 16)), actual=0x\(String(actual, radix: 16))"
        }
    }
}

enum BoundSessionLocalRole: UInt32, Sendable, Equatable {
    case initiator = 1
    case responder = 2
}

enum BoundSessionSessionState: UInt32, Sendable, Equatable {
    case awaitingMessageASignature = 1
    case awaitingMessageB = 2
    case awaitingResponderFinished = 3
    case awaitingMessageBSignature = 4
    case awaitingInitiatorFinished = 5
    case established = 6
    case failed = 7
}

struct BoundSessionOwnerHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionSessionHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionGrantHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionOperationHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionCommitPermitHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionFinalizationRetryHandle: Hashable, Sendable {
    let identifier: UUID
}

struct BoundSessionOwnerBinding: Sendable, Equatable {
    let callerPrincipalDigest: Data
    let connectionGeneration: UInt64
    let operationToken: Data
    let driverIdentityDigest: Data
    let arbiterLease: Data
    let decisionEpoch: UInt64
}

struct BoundSessionServiceMetadata: Sendable, Equatable {
    let trustedPolicyState: Data
    let policyRootFingerprint: Data
    let localRecipientKeyDigest: Data
    let peerRecipientKeyDigest: Data
    let localIdentityFingerprint: Data
    let peerIdentityFingerprint: Data
}

struct BoundSessionFFIServiceConfiguration: Sendable {
    let policyMaterial: QPeriaptSignedPolicyMaterial
    let enrollmentMode: QPeriaptEnrollmentMode
    let trustedStateStore: any QPeriaptTrustedStateStore
    let localRecipientPublicKey: Data
    let localRecipientPrivateKey: SecureBytes
    let peerRecipientPublicKey: Data
    let localIdentity: CommittedLocalProtocolIdentitySnapshot
    let peerIdentityVerificationKey: Data
    let finishedOutboxRoot: URL
    let evidenceJournalRoot: URL
    let maximumInFlightSessions: UInt32
    let maximumOwnerCapabilities: UInt32
    let maximumHandshakeLifetimeMilliseconds: UInt64
}

struct BoundSessionOutboundRecord: Sendable, Equatable {
    let kind: BoundSessionWebRTCRecordKindV1
    let exactBytes: Data
}

struct BoundSessionEstablishedInfo: Sendable, Equatable {
    let peerSessionID: Data
    let contextDigest: Data
    let transcriptDigest: Data
}

struct BoundSessionFileGrantAuthorization: Sendable, Equatable {
    /// Public digest of evidence produced by the trusted Apple authorization
    /// adapter. This is a correlation digest, not a signature or attestation.
    let platformAuthorizationEvidenceDigest: Data

    /// Bounded relative lifetime in the Rust service's monotonic millisecond
    /// clock domain. Rust derives the absolute expiry.
    let authorizationLifetimeMilliseconds: UInt64

    /// Present only on the endpoint that receives and durably commits the file.
    let receiverTargetScopeDigest: Data?
}

struct BoundSessionFileGrantInstallResult: Sendable, Equatable {
    let grant: BoundSessionGrantHandle
    let peerSessionID: Data
    let localRole: BoundSessionLocalRole
    let localReceivesFile: Bool
}

enum BoundSessionGrantEnableOutcome: UInt32, Sendable, Equatable {
    case first = 1
    case exactReplay = 2
}

struct BoundSessionGrantEnableResult: Sendable, Equatable {
    let outcome: BoundSessionGrantEnableOutcome
    let bilateralReadyDigest: Data
    let remoteAcceptance: BoundSessionRemoteRustAcceptanceWitnessV2
}

enum BoundSessionFileDirectionV2: UInt32, Sendable, Equatable {
    case initiatorToResponder = 1
    case responderToInitiator = 2
}

enum BoundSessionEnabledGrantStateV2: UInt32, Sendable, Equatable {
    case enabled = 1
}

/// Enabled-only projection copied from Rust authority state. No caller field
/// can override this value, and the correlation digests are not signatures,
/// executable identity, remote attestation, or malicious-host evidence.
struct BoundSessionFileGrantEvidenceProjectionV2: Sendable, Equatable {
    let state: BoundSessionEnabledGrantStateV2
    let fileDirection: BoundSessionFileDirectionV2
    let localRole: BoundSessionLocalRole
    let localReceivesFile: Bool
    let connectionGeneration: UInt64
    let decisionEpoch: UInt64
    let authorizationExpiresAtTick: UInt64
    let policyVersion: UInt64
    let declaredBytes: UInt64
    let wireCryptoProfileID: UInt32
    let suiteID: UInt32
    let hybridProfileID: UInt32
    let keyFormatID: UInt32
    let peerSessionID: Data
    let contextDigest: Data
    let transcriptDigest: Data
    let sharedGrantID: Data
    let bilateralReadyDigest: Data
    let policyDigest: Data
    let policyRootKeyFingerprint: Data
    let wireDecisionDigest: Data
    let purposeDigest: Data
    let recipientKEMPublicKeyDigest: Data
    let initiatorIdentityFingerprint: Data
    let responderIdentityFingerprint: Data
    let clientNonce: Data
    let transferID: Data
    let contentSHA256: Data
    let localAuthorizationCommitment: Data
    let localDurableFileTargetScope: Data?
    let authorizationTransactionIDDigest: Data
    let platformAuthorizationEvidenceDigest: Data
    let authorizationRecordDigest: Data
    let ownerBindingDigest: Data
    let serviceIncarnationDigest: Data
    let durableFileCommitterIdentityDigest: Data
}

struct BoundSessionGrantOutboundMetadataV2: Sendable, Equatable {
    let kind: BoundSessionWebRTCRecordKindV1
    let direction: BoundSessionFileDirectionV2
    let recordLength: Int
    let logicalSequence: UInt64
    let recordID: Data
    let recordSHA256: Data
    let peerSessionID: Data
    let sharedGrantID: Data
}

/// Stable non-destructive view of one exact Ready or EffectReceipt.
struct BoundSessionGrantOutboundRecordV2: Sendable, Equatable {
    let metadata: BoundSessionGrantOutboundMetadataV2
    let exactBytes: Data

    var kind: BoundSessionWebRTCRecordKindV1 { metadata.kind }
}

struct BoundSessionReceiptAcceptanceResultV2: Sendable, Equatable {
    let outcome: BoundSessionReceiptAcceptance
    let remoteAcceptance: BoundSessionRemoteRustAcceptanceWitnessV2
}

enum BoundSessionTrustedDeliveryConfirmationOutcomeV2: UInt32, Sendable, Equatable {
    case firstConfirmed = 1
    case exactReplay = 2
}

struct BoundSessionFileOperationDescriptor: Sendable, Equatable {
    let operationID: Data
    let sequence: UInt64
    let requestDigest: Data
}

enum BoundSessionFileFinalizationOutcome: UInt32, Sendable, Equatable {
    case committed = 1
    case ambiguous = 2
}

enum BoundSessionFileFinalizationResult: Sendable, Equatable {
    case receiptQueued
    case retryRequired(BoundSessionFinalizationRetryHandle)
}

enum BoundSessionReceiptAcceptance: UInt32, Sendable, Equatable {
    case first = 1
    case exactReplay = 2
}

extension BoundSessionWebRTCRecordKindV1 {
    init(ffiRawValue: UInt32) throws {
        guard let raw = UInt16(exactly: ffiRawValue),
            let kind = Self(rawValue: raw)
        else {
            throw BoundSessionFFIError.invalidRecordKind(ffiRawValue)
        }
        self = kind
    }

    var ffiRawValue: UInt32 {
        UInt32(rawValue)
    }
}
