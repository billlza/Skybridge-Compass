import CryptoKit
import Foundation

public enum ClassicTransferApprovalError: Error, Equatable, Sendable {
    case unsupportedProtocol
    case invalidResponse
    case requestMismatch
    case authenticationFailed
    case refused(ClassicTransferApprovalRefusal)
    case invalidSessionBinding
    case capabilityEvidenceUnavailable
}

/// A value retained only after accepting a pairing-identity message on its
/// authenticated session. The constructor does not authenticate a payload:
/// production callers must run their existing trust/current-owner boundary first.
public struct ClassicTransferPeerCapabilities: Sendable, Equatable {
    private let sessionID: String
    private let transcriptHash: Data
    private let supportsApproval: Bool

    public init(
        acceptedCapabilities: [String]?, sessionID: String, transcriptHash: Data
    ) throws {
        guard P2PEvidenceReference.sessionIncarnation(
            sessionID: sessionID, transcriptHash: transcriptHash
        ) != nil else { throw ClassicTransferApprovalError.invalidSessionBinding }
        self.sessionID = sessionID
        self.transcriptHash = transcriptHash
        self.supportsApproval = ClassicTransferApprovalContract.isSupported(by: acceptedCapabilities ?? [])
    }

    /// nil means unknown/stale, not an authenticated legacy selection. An
    /// initial sender must reject it before metadata rather than default to false.
    public func approvalSupport(sessionID: String, transcriptHash: Data) -> Bool? {
        guard self.sessionID == sessionID, self.transcriptHash == transcriptHash else { return nil }
        return supportsApproval
    }
}

public enum ClassicTransferApprovalRefusal: String, Codable, Sendable {
    case denied
    case unavailable
}

/// A permission to start this file, never a receipt or permission to resume it.
public struct ClassicTransferApprovalResponse: Codable, Sendable {
    public let transferId: String
    public let metadataDigest: String
    public let accepted: Bool
    public let reason: ClassicTransferApprovalRefusal?
    public let securityVersion: Int
    public let authTag: Data
}

public struct ClassicTransferApprovalRequest: Sendable {
    public let transferID: String
    public let metadataDigest: String

    /// The caller supplies the exact transcript used to authenticate metadata,
    /// including the negotiated protocol. Do not reconstruct it from UI state.
    public init(transferID: String, authenticatedMetadataTranscript: Data) throws {
        try ClassicTransferMetadataContract.validateTransferIdentifier(transferID)
        guard !authenticatedMetadataTranscript.isEmpty else {
            throw ClassicTransferApprovalError.invalidResponse
        }
        self.transferID = transferID
        self.metadataDigest = SHA256.hash(data: authenticatedMetadataTranscript)
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum ClassicTransferApprovalContract {
    public static let capability = "classic_approval_v1"
    public static let protocolIdentifier = "metadata-bound-v1"
    public static let wireMessageType: UInt32 = 7
    public static let maximumPayloadBytes = 2_048
    // The UI allows 60 s; this separate bounded phase also covers preparation
    // and transport. It does not change the 30 s data-frame send deadline.
    public static let responseHeaderTimeoutSeconds: TimeInterval = 90
    public static let responsePayloadTimeoutSeconds: TimeInterval = 10

    public static func isSupported(by authenticatedCapabilities: [String]) -> Bool {
        authenticatedCapabilities.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == capability
        }
    }

    public static func validateRequestedProtocol(_ value: String?) throws {
        guard value == nil || value == protocolIdentifier else {
            throw ClassicTransferApprovalError.unsupportedProtocol
        }
    }

    public static func makeResponse(
        for request: ClassicTransferApprovalRequest,
        refusal: ClassicTransferApprovalRefusal?,
        using key: SymmetricKey
    ) throws -> ClassicTransferApprovalResponse {
        let version = ClassicTransferInboundPolicy.currentSecurityVersion
        let transcript = try ClassicTransferCanonicalTranscript.approvalDecision(
            transferID: request.transferID, metadataDigest: request.metadataDigest,
            accepted: refusal == nil, reason: refusal?.rawValue, securityVersion: version
        )
        return ClassicTransferApprovalResponse(
            transferId: request.transferID, metadataDigest: request.metadataDigest,
            accepted: refusal == nil, reason: refusal, securityVersion: version,
            authTag: Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
        )
    }

    /// Returns the authenticated refusal, or nil for permission. The caller must
    /// still recheck its live session/cancellation before sending any file data.
    public static func validateResponse(
        _ response: ClassicTransferApprovalResponse,
        for request: ClassicTransferApprovalRequest,
        using key: SymmetricKey
    ) throws -> ClassicTransferApprovalRefusal? {
        try ClassicTransferMetadataContract.validateSecurityVersion(response.securityVersion)
        try ClassicTransferMetadataContract.validateTransferIdentifier(response.transferId)
        try ClassicTransferMetadataContract.validateSHA256Hex(response.metadataDigest)
        guard response.accepted == (response.reason == nil) else {
            throw ClassicTransferApprovalError.invalidResponse
        }
        guard response.transferId == request.transferID,
              response.metadataDigest == request.metadataDigest else {
            throw ClassicTransferApprovalError.requestMismatch
        }
        let transcript = try ClassicTransferCanonicalTranscript.approvalDecision(
            transferID: response.transferId, metadataDigest: response.metadataDigest,
            accepted: response.accepted, reason: response.reason?.rawValue,
            securityVersion: response.securityVersion
        )
        guard ClassicTransferAuthenticationContract.isValidHMACSHA256(
            response.authTag, authenticating: transcript, using: key
        ) else {
            throw ClassicTransferApprovalError.authenticationFailed
        }
        return response.reason
    }
}
