import Foundation
import CryptoKit

/// Shared request semantics for native hosts. Platform adapters supply existing
/// signing/trust, provider configuration, Keychain and UI services.
@MainActor
public final class HandshakeConfigurationService {
    public enum Decision: Sendable { case allowOnce, alwaysAllow, reject }
    public typealias IdentityLoader = @MainActor @Sendable () async throws -> HandshakeManagementIdentity
    public typealias TrustCheck = @MainActor @Sendable (HandshakeManagementIdentity) async throws -> Bool
    public typealias Verify = @Sendable (Data, Data, HandshakeManagementIdentity) async throws -> Bool
    public typealias Sign = @Sendable (Data) async throws -> Data
    public typealias Snapshot = @MainActor @Sendable () throws -> HandshakeConfigurationSnapshot
    public typealias Revalidate = @MainActor @Sendable () async throws -> Void
    public typealias Apply = @MainActor @Sendable (HandshakeProfile, String, Revalidate) async throws -> HandshakeConfigurationSnapshot
    public typealias GrantRead = @MainActor @Sendable (String) throws -> Bool
    public typealias GrantWrite = @MainActor @Sendable (String, Bool) throws -> Void
    public typealias Approval = @MainActor @Sendable (HandshakeManagementIdentity, HandshakeProfile) async -> Decision

    private let identity: IdentityLoader
    private let trusted: TrustCheck
    private let verify: Verify
    private let sign: Sign
    private let snapshot: Snapshot
    private let apply: Apply
    private let readGrant: GrantRead
    private let writeGrant: GrantWrite
    private let approve: Approval
    public typealias FileApproval = @MainActor @Sendable (HandshakeManagementIdentity) async -> Decision
    private let approveFiles: FileApproval
    private let fileApprovalSupported: Bool
    private let fileRegistry: RemoteFileApprovalRegistry
    private var transientFileGrants: [String: Date] = [:]
    private var mutating = false
    private struct Challenge {
        var identity: HandshakeManagementIdentity
        var targetFingerprint: String
        var revision: String
        var fileScope: Bool
        var expires: Date
    }
    private var challenges: [Data: Challenge] = [:]

    public init(identity: @escaping IdentityLoader, trusted: @escaping TrustCheck,
                verify: @escaping Verify, sign: @escaping Sign,
                snapshot: @escaping Snapshot, apply: @escaping Apply,
                readGrant: @escaping GrantRead, writeGrant: @escaping GrantWrite,
                approve: @escaping Approval,
                approveFiles: @escaping FileApproval = { _ in .reject },
                fileApprovalSupported: Bool = false,
                fileRegistry: RemoteFileApprovalRegistry = .shared) {
        self.identity = identity; self.trusted = trusted; self.verify = verify; self.sign = sign
        self.snapshot = snapshot; self.apply = apply
        self.readGrant = readGrant; self.writeGrant = writeGrant; self.approve = approve
        self.approveFiles = approveFiles; self.fileRegistry = fileRegistry
        self.fileApprovalSupported = fileApprovalSupported
    }

    /// No mutation may replay after process restart: an apply needs a fresh,
    /// single-use, identity/revision-bound challenge issued by this instance.
    public func handle(_ request: HandshakeConfigurationRequest, now: Date = Date()) async throws
        -> HandshakeConfigurationResponse {
        try request.validate(now: now)
        let local = try await identity()
        try local.validate()
        guard local.deviceID == request.targetDeviceID, local.fingerprint == request.targetFingerprint else {
            throw HandshakeConfigurationError.identityMismatch
        }
        guard try await trusted(request.requester) else { throw HandshakeConfigurationError.peerUntrusted }
        guard try await verify(request.signingData(), request.signature, request.requester) else {
            throw HandshakeConfigurationError.signatureInvalid
        }
        try Task.checkCancellation()

        if request.action.isFileApproval { return try await handleFileApproval(request, local: local, now: now) }

        var observed: HandshakeConfigurationSnapshot?
        var authorized = false
        var applied = false
        var failure: HandshakeConfigurationError?
        var issuedChallenge: Data?
        do {
            guard !mutating else { throw HandshakeConfigurationError.busy }
            let current = try snapshot(); try current.validate(); observed = current
            authorized = try readGrant(request.requester.grantKey)
            challenges = challenges.filter { $0.value.expires > now }
            if request.action == .status {
                // A read does not consume a new mutation slot for the same
                // identity and revision. Consumption, expiry and CAS checks
                // below still make the shared challenge single-use.
                if let existing = challenges.first(where: {
                    !$0.value.fileScope && $0.value.identity == request.requester
                        && $0.value.targetFingerprint == local.fingerprint
                        && $0.value.revision == current.revision
                }) {
                    issuedChallenge = existing.key
                } else {
                    guard challenges.count < 128,
                          challenges.values.filter({ $0.identity.grantKey == request.requester.grantKey }).count < 8 else {
                        throw HandshakeConfigurationError.busy
                    }
                    let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    challenges[nonce] = Challenge(identity: request.requester, targetFingerprint: local.fingerprint,
                                                   revision: current.revision, fileScope: false, expires: now.addingTimeInterval(120))
                    issuedChallenge = nonce
                }
            } else {
                guard let nonce = request.challenge,
                      let challenge = challenges.removeValue(forKey: nonce),
                      challenge.identity == request.requester, !challenge.fileScope,
                      challenge.targetFingerprint == local.fingerprint,
                      challenge.expires > now else { throw HandshakeConfigurationError.replayed }
                guard current.revision == challenge.revision else { throw HandshakeConfigurationError.revisionChanged }
                mutating = true
                defer { mutating = false }
                if request.action == .revoke {
                    try writeGrant(request.requester.grantKey, false)
                    guard try !readGrant(request.requester.grantKey) else { throw HandshakeConfigurationError.storageUnavailable }
                    authorized = false
                } else {
                    guard let profile = request.profile, let expected = request.expectedRevision else {
                        throw HandshakeConfigurationError.invalidRequest
                    }
                    guard profile != .classic else { throw HandshakeConfigurationError.classicDisabled }
                    guard expected == current.revision else { throw HandshakeConfigurationError.revisionChanged }
                    guard !current.busy else { throw HandshakeConfigurationError.transferActive }
                    guard current.options.first(where: { $0.profile == profile })?.selectable == true else {
                        throw HandshakeConfigurationError.profileUnavailable
                    }
                    var usesPersistentGrant = authorized
                    if !authorized {
                        let decision = await approve(request.requester, profile)
                        try Task.checkCancellation()
                        try request.validate()
                        guard decision != .reject else { throw HandshakeConfigurationError.authorizationDenied }
                        // Revalidate after UI awaits, before granting or changing policy.
                        guard try await identity() == local,
                              try await trusted(request.requester) else { throw HandshakeConfigurationError.identityMismatch }
                        if decision == .alwaysAllow {
                            usesPersistentGrant = true
                            try writeGrant(request.requester.grantKey, true)
                            guard try readGrant(request.requester.grantKey) else { throw HandshakeConfigurationError.storageUnavailable }
                        }
                        authorized = true
                    }
                    let beforeApply = try snapshot()
                    guard beforeApply.revision == expected else { throw HandshakeConfigurationError.revisionChanged }
                    guard !beforeApply.busy else { throw HandshakeConfigurationError.transferActive }
                    guard try await identity() == local,
                          try await trusted(request.requester) else { throw HandshakeConfigurationError.identityMismatch }
                    let requirePersistentGrant = usesPersistentGrant
                    let result = try await apply(profile, expected) { [self] in
                        try Task.checkCancellation()
                        try request.validate()
                        guard try await identity() == local,
                              try await trusted(request.requester) else { throw HandshakeConfigurationError.identityMismatch }
                        if requirePersistentGrant, try !readGrant(request.requester.grantKey) {
                            throw HandshakeConfigurationError.authorizationDenied
                        }
                    }
                    try result.validate()
                    observed = result
                    guard result.configuredProfile == profile, profile.matches(suite: result.providerSuite) else {
                        throw HandshakeConfigurationError.applyFailed
                    }
                    applied = true
                }
            }
        } catch let error as HandshakeConfigurationError {
            failure = error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Arbitrary backend/Keychain errors never enter the network response.
            failure = .applyFailed
        }
        if failure != nil {
            do {
                let current = try snapshot(); try current.validate(); observed = current
                authorized = try readGrant(request.requester.grantKey)
            }
            catch { observed = nil; failure = .outcomeUnknown }
        }
        guard try await identity() == local else { throw HandshakeConfigurationError.identityMismatch }
        var response = try HandshakeConfigurationResponse(request: request, responder: local,
            snapshot: observed, managementAuthorized: authorized, applied: applied,
            error: failure, challenge: issuedChallenge)
        response.signature = try await sign(response.signingData())
        return response
    }
    /// Settings and remote revocation clear both bounded and durable delegation.
    public func revokeFileManagement(grantKey: String) throws {
        transientFileGrants.removeValue(forKey: grantKey)
        let key = "file-approval:v1:" + grantKey
        try writeGrant(key, false)
        guard try !readGrant(key) else { throw HandshakeConfigurationError.storageUnavailable }
    }

    private func fileGrant(_ identity: HandshakeManagementIdentity, now: Date = Date()) throws -> Bool {
        try readGrant("file-approval:v1:" + identity.grantKey)
            || (transientFileGrants[identity.grantKey].map { $0 > now } ?? false)
    }

    private func handleFileApproval(_ request: HandshakeConfigurationRequest,
                                    local: HandshakeManagementIdentity, now: Date) async throws -> HandshakeConfigurationResponse {
        var authorized = false
        var state: RemoteFileApprovalState?
        var failure: HandshakeConfigurationError?
        var fileFailure: RemoteFileApprovalError?
        var nonce: Data?
        do {
            guard fileApprovalSupported else { throw RemoteFileApprovalError.unavailable }
            authorized = try fileGrant(request.requester, now: now)
            challenges = challenges.filter { $0.value.expires > now }
            transientFileGrants = transientFileGrants.filter { $0.value > now }
            switch request.action {
            case .fileStatus:
                // Polling a pending receive must not exhaust the mutation nonce quota.
                if let existing = challenges.first(where: {
                    $0.value.fileScope && $0.value.identity == request.requester && $0.value.targetFingerprint == local.fingerprint
                }) { nonce = existing.key }
                else {
                    guard challenges.count < 128 else { throw RemoteFileApprovalError.busy }
                    let issued = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    challenges[issued] = Challenge(identity: request.requester, targetFingerprint: local.fingerprint,
                        revision: "file-approval-v1", fileScope: true, expires: now.addingTimeInterval(120))
                    nonce = issued
                }
            case .fileAuthorize, .fileRevoke:
                guard let challenge = request.challenge.flatMap({ challenges.removeValue(forKey: $0) }),
                      challenge.fileScope, challenge.identity == request.requester,
                      challenge.targetFingerprint == local.fingerprint, challenge.expires > now else {
                    throw HandshakeConfigurationError.replayed
                }
                guard !mutating else { throw RemoteFileApprovalError.busy }
                mutating = true
                defer { mutating = false }
                let key = "file-approval:v1:" + request.requester.grantKey
                if request.action == .fileRevoke {
                    try revokeFileManagement(grantKey: request.requester.grantKey)
                } else if !authorized {
                    let decision = await approveFiles(request.requester)
                    try Task.checkCancellation(); try request.validate()
                    guard try await identity() == local, try await trusted(request.requester) else {
                        throw HandshakeConfigurationError.identityMismatch
                    }
                    guard decision != .reject else { throw RemoteFileApprovalError.unauthorized }
                    if decision == .alwaysAllow {
                        try writeGrant(key, true)
                        guard try readGrant(key) else { throw HandshakeConfigurationError.storageUnavailable }
                    } else {
                        // Explicit bounded approval; no durable grant is created by “this session”.
                        transientFileGrants[request.requester.grantKey] = Date().addingTimeInterval(600)
                    }
                }
            case .fileDecide:
                guard authorized, let decision = request.fileDecision else { throw RemoteFileApprovalError.unauthorized }
                try await fileRegistry.decide(decision, requester: request.requester) { [self] in
                    try request.validate()
                    guard try await identity() == local, try await trusted(request.requester),
                          try fileGrant(request.requester) else { throw RemoteFileApprovalError.unauthorized }
                }
            default: throw HandshakeConfigurationError.invalidRequest
            }
            authorized = try fileGrant(request.requester)
            state = RemoteFileApprovalState(authorized: authorized,
                pending: authorized ? try fileRegistry.pending(for: request.requester) : [])
        } catch let error as RemoteFileApprovalError { fileFailure = error }
        catch let error as HandshakeConfigurationError { failure = error }
        catch is CancellationError { throw CancellationError() }
        catch { failure = .outcomeUnknown }
        guard try await identity() == local else { throw HandshakeConfigurationError.identityMismatch }
        var response = try HandshakeConfigurationResponse(request: request, responder: local, snapshot: nil,
            managementAuthorized: false, applied: false, error: failure, challenge: nonce,
            fileApproval: state, fileApprovalError: fileFailure)
        response.signature = try await sign(response.signingData())
        return response
    }

}
