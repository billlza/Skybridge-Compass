import Foundation
import CryptoKit

/// User choices are separate from the signature identity and negotiated session.
public enum HandshakeProfile: String, Codable, CaseIterable, Sendable {
    case qperiapt, xwing, mlkem, classic

    public var title: String {
        switch self {
        case .qperiapt: return "Q-Periapt"
        case .xwing: return "X-Wing"
        case .mlkem: return "ML-KEM-768（纯 PQC）"
        case .classic: return "Classic"
        }
    }

    public func matches(suite: String?) -> Bool {
        guard let suite, let parsed = CryptoSuite(rawValue: suite) else { return false }
        switch self {
        case .qperiapt: return parsed == .qperiaptABI2PolicyBound
        case .xwing: return parsed == .xwingMLDSA
        case .mlkem: return parsed.canonicalKEMSuite == .mlkem768MLDSA65
        case .classic: return !parsed.isPQC && parsed.isNegotiable
        }
    }
}

public struct HandshakeProfileOption: Codable, Sendable, Equatable {
    public var profile: HandshakeProfile
    public var selectable: Bool
    public var reason: String?

    public init(_ profile: HandshakeProfile, selectable: Bool, reason: String? = nil) {
        self.profile = profile; self.selectable = selectable; self.reason = reason
    }
}

public struct HandshakeConfigurationSnapshot: Codable, Sendable, Equatable {
    public var revision: String
    public var configuredProfile: HandshakeProfile
    /// A provider read-back, never evidence of a completed peer handshake.
    public var providerSuite: String?
    public var options: [HandshakeProfileOption]
    public var busy: Bool

    public init(revision: String, configuredProfile: HandshakeProfile,
                providerSuite: String?, options: [HandshakeProfileOption], busy: Bool) {
        self.revision = revision; self.configuredProfile = configuredProfile
        self.providerSuite = providerSuite; self.options = options; self.busy = busy
    }

    public func validate() throws {
        guard UUID(uuidString: revision) != nil,
              options.count == HandshakeProfile.allCases.count,
              Set(options.map(\.profile)) == Set(HandshakeProfile.allCases),
              options.allSatisfy({ ($0.reason?.utf8.count ?? 0) <= 512 }),
              options.first(where: { $0.profile == .classic })?.selectable == false,
              providerSuite.map({ CryptoSuite(rawValue: $0)?.isNegotiable == true }) ?? true else {
            throw HandshakeConfigurationError.invalidResponse
        }
    }
}

public enum HandshakeConfigurationError: String, Error, Codable, Sendable, LocalizedError {
    case invalidRequest = "invalid_request"
    case invalidResponse = "invalid_response"
    case identityMismatch = "identity_mismatch"
    case signatureInvalid = "signature_invalid"
    case peerUntrusted = "peer_untrusted"
    case expired = "expired"
    case replayed = "replayed_operation"
    case busy = "configuration_busy"
    case transferActive = "transfer_active"
    case revisionChanged = "configuration_changed"
    case authorizationDenied = "authorization_denied"
    case classicDisabled = "classic_disabled_by_policy"
    case profileUnavailable = "profile_unavailable"
    case storageUnavailable = "configuration_storage_unavailable"
    case applyFailed = "configuration_apply_failed"
    case rollbackFailed = "configuration_rollback_failed"
    case outcomeUnknown = "configuration_outcome_unknown"
    case peerUnsupported = "peer_configuration_unavailable"

    public var errorDescription: String? { rawValue }
}

public struct HandshakeManagementIdentity: Codable, Sendable, Equatable {
    public var deviceID: String
    public var algorithm: String
    public var publicKey: Data
    public var fingerprint: String

    public init(deviceID: String, algorithm: String, publicKey: Data, fingerprint: String) {
        self.deviceID = HandshakeConfigurationWire.canonicalDeviceID(deviceID); self.algorithm = algorithm
        self.publicKey = publicKey; self.fingerprint = fingerprint.lowercased()
    }

    public func validate() throws {
        guard UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID,
              let signingAlgorithm = ProtocolSigningAlgorithm(rawValue: algorithm),
              signingAlgorithm == .mlDSA65 || signingAlgorithm == .mlDSA87,
              fingerprint == ProtocolIdentityBinding.computeFingerprint(algorithm: signingAlgorithm, publicKeyBytes: publicKey) else {
            throw HandshakeConfigurationError.identityMismatch
        }
        do { try ProtocolIdentityBinding.validateKeyEncoding(bytes: publicKey, algorithm: signingAlgorithm) }
        catch { throw HandshakeConfigurationError.identityMismatch }
    }

    public var grantKey: String { deviceID + ":" + fingerprint }
}

public struct HandshakeConfigurationRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case status, apply, revoke
        case fileStatus = "file_status", fileAuthorize = "file_authorize", fileDecide = "file_decide", fileRevoke = "file_revoke"
        public var isFileApproval: Bool { [.fileStatus, .fileAuthorize, .fileDecide, .fileRevoke].contains(self) }
        public var isReadOnly: Bool { self == .status || self == .fileStatus }
    }
    public var version = 1
    public var requestID: UUID
    public var action: Action
    public var requester: HandshakeManagementIdentity
    public var targetDeviceID: String
    public var targetFingerprint: String
    public var profile: HandshakeProfile?
    public var fileDecision: RemoteFileApprovalDecision?
    public var expectedRevision: String?
    public var challenge: Data?
    public var issuedAtMilliseconds: Int64
    public var expiresAtMilliseconds: Int64
    public var signature: Data

    public init(action: Action, requester: HandshakeManagementIdentity,
                targetDeviceID: String, targetFingerprint: String,
                profile: HandshakeProfile? = nil, expectedRevision: String? = nil, challenge: Data? = nil,
                fileDecision: RemoteFileApprovalDecision? = nil, now: Date = Date()) {
        self.fileDecision = fileDecision
        requestID = UUID(); self.action = action; self.requester = requester
        self.targetDeviceID = HandshakeConfigurationWire.canonicalDeviceID(targetDeviceID)
        self.targetFingerprint = targetFingerprint.lowercased()
        self.profile = profile; self.expectedRevision = expectedRevision
        self.challenge = challenge
        issuedAtMilliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        expiresAtMilliseconds = issuedAtMilliseconds + 120_000
        signature = Data()
    }

    public func validate(now: Date = Date()) throws {
        try requester.validate()
        try fileDecision?.prompt.validate()
        let current = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        guard version == 1,
              UUID(uuidString: targetDeviceID)?.uuidString.lowercased() == targetDeviceID,
              targetDeviceID != requester.deviceID,
              HandshakeConfigurationWire.isFingerprint(targetFingerprint),
              signature.count <= 8192,
              (action == .apply) == (profile != nil && expectedRevision != nil),
              action == .apply || (profile == nil && expectedRevision == nil),
              ((action.isReadOnly || action == .fileDecide) ? challenge == nil : challenge?.count == 32),
              (action == .fileDecide) == (fileDecision != nil),
              expectedRevision.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw HandshakeConfigurationError.invalidRequest
        }
        guard issuedAtMilliseconds > 0, issuedAtMilliseconds <= current + 15_000,
              expiresAtMilliseconds > current,
              expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds <= issuedAtMilliseconds + 120_000 else {
            throw HandshakeConfigurationError.expired
        }
    }

    public func signingData() throws -> Data {
        var copy = self; copy.signature = Data()
        return try HandshakeConfigurationWire.canonical(copy, domain: "request")
    }
    public func digest() throws -> String { try HandshakeConfigurationWire.hash(signingData()) }
}

public struct HandshakeConfigurationResponse: Codable, Sendable, Equatable {
    public var version = 1
    public var requestID: UUID
    public var requestHash: String
    public var responder: HandshakeManagementIdentity
    public var snapshot: HandshakeConfigurationSnapshot?
    public var managementAuthorized: Bool
    public var applied: Bool
    public var error: HandshakeConfigurationError?
    public var challenge: Data?
    public var signature = Data()
    public var fileApproval: RemoteFileApprovalState?
    public var fileApprovalError: RemoteFileApprovalError?

    public init(request: HandshakeConfigurationRequest, responder: HandshakeManagementIdentity,
                snapshot: HandshakeConfigurationSnapshot?, managementAuthorized: Bool,
                applied: Bool, error: HandshakeConfigurationError?, challenge: Data? = nil,
                fileApproval: RemoteFileApprovalState? = nil, fileApprovalError: RemoteFileApprovalError? = nil) throws {
        requestID = request.requestID; requestHash = try request.digest()
        self.responder = responder; self.snapshot = snapshot
        self.managementAuthorized = managementAuthorized; self.applied = applied; self.error = error
        self.challenge = challenge
        self.fileApproval = fileApproval; self.fileApprovalError = fileApprovalError
    }

    public func signingData() throws -> Data {
        var copy = self; copy.signature = Data()
        return try HandshakeConfigurationWire.canonical(copy, domain: "response")
    }

    public func validate(for request: HandshakeConfigurationRequest) throws {
        try responder.validate()
        guard version == 1, requestID == request.requestID,
              requestHash == (try request.digest()),
              responder.deviceID == request.targetDeviceID,
              responder.fingerprint == request.targetFingerprint,
              signature.count <= 8192,
              challenge == nil || (request.action.isReadOnly && challenge?.count == 32),
              error != nil || fileApprovalError != nil || !request.action.isReadOnly || challenge?.count == 32,
              error != nil || request.action != .apply || applied,
              !applied || (request.action == .apply && error == nil && managementAuthorized),
              fileApproval == nil || request.action.isFileApproval,
              fileApprovalError == nil || request.action.isFileApproval,
              error != nil || fileApprovalError != nil || !request.action.isFileApproval || fileApproval != nil,
              error != nil || request.action.isFileApproval || snapshot != nil else { throw HandshakeConfigurationError.invalidResponse }
        if let state = fileApproval {
            guard state.pending.count <= 8, state.authorized || state.pending.isEmpty else { throw HandshakeConfigurationError.invalidResponse }
            for prompt in state.pending {
                try prompt.validate()
                guard prompt.binding.belongs(to: request.requester) else { throw HandshakeConfigurationError.invalidResponse }
            }
        }
        if let snapshot { try snapshot.validate() }
        if applied {
            guard snapshot?.configuredProfile == request.profile,
                  request.profile?.matches(suite: snapshot?.providerSuite) == true else {
                throw HandshakeConfigurationError.invalidResponse
            }
        }
    }
}

public enum HandshakeConfigurationWire {
    /// Existing native stores use id:UUID; the management wire uses lowercase
    /// UUID. Only this identity wrapper is removed; endpoints remain invalid.
    public static func canonicalDeviceID(_ value: String) -> String {
        let lower = value.lowercased()
        return lower.hasPrefix("id:") ? String(lower.dropFirst(3)) : lower
    }
    /// Regenerate on any observed settings/identity change, including ordinary UI edits.
    @MainActor public static func revision(for state: String, defaults: UserDefaults) -> String {
        let stateKey = revisionKey + ".state"
        if defaults.string(forKey: stateKey) == state,
           let existing = defaults.string(forKey: revisionKey), UUID(uuidString: existing) != nil { return existing }
        let revision = UUID().uuidString
        defaults.set(revision, forKey: revisionKey)
        defaults.set(state, forKey: stateKey)
        return revision
    }
    public static let revisionKey = "Settings.HandshakeConfigurationRevision.v1"
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func canonical<T: Encodable>(_ value: T, domain: String) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data("SkyBridge/handshake-configuration/1/\(domain)\0".utf8) + (try encoder.encode(value))
    }
}
