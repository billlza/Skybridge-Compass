import CryptoKit
import Darwin
import Foundation
import Security

public enum FormalMacNetworkIsolation {
    public static func makeEphemeralURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

public enum FormalMacSessionBindingWaitPolicy {
    public static func isRetryable(_ error: FormalMacInteropError) -> Bool {
        switch error {
        case .selectedICEUnavailable, .peerKEMAdmissionRequired:
            return true
        default:
            return false
        }
    }
}

/// Main-actor owned one-shot state for a formal connection capability. The UUID is an ownership
/// token, not a security identifier; it prevents an async continuation from installing state for
/// an attempt that has already been retired.
struct FormalMacConnectLifecycle: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case unavailable
        case available
        case connecting(UUID)
        case active(UUID)
        case retired
    }

    private(set) var state: State

    init(capabilityInstalled: Bool) {
        state = capabilityInstalled ? .available : .unavailable
    }

    mutating func claim() throws -> UUID {
        guard state == .available else {
            throw FormalMacInteropError.capabilityAlreadyConsumed
        }
        let attemptID = UUID()
        state = .connecting(attemptID)
        return attemptID
    }

    func requireConnecting(_ attemptID: UUID) throws {
        guard state == .connecting(attemptID) else {
            throw FormalMacInteropError.staleSession
        }
    }

    mutating func activate(_ attemptID: UUID) throws {
        try requireConnecting(attemptID)
        state = .active(attemptID)
    }

    func requireActive(_ attemptID: UUID) throws {
        guard state == .active(attemptID) else {
            throw FormalMacInteropError.staleSession
        }
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var activeAttemptID: UUID? {
        guard case .active(let attemptID) = state else { return nil }
        return attemptID
    }

    mutating func retire() {
        guard state != .unavailable else { return }
        state = .retired
    }
}

public enum FormalMacHandshakeAdmission {
    @discardableResult
    public static func requireCanonicalIdentityPublicKeys(
        _ encoded: Data
    ) throws -> IdentityPublicKeys {
        do {
            let identity = try IdentityPublicKeys.decode(from: encoded)
            guard identity.protocolAlgorithm == .mlDSA65,
                  identity.encoded == encoded else {
                throw FormalMacInteropError.missingExactPeerTrust
            }
            return identity
        } catch let error as FormalMacInteropError {
            throw error
        } catch {
            throw FormalMacInteropError.missingExactPeerTrust
        }
    }

    public static func requireCanonicalMessageAWire(
        _ message: HandshakeMessageA,
        wireData: Data
    ) throws {
        _ = try requireCanonicalIdentityPublicKeys(message.identityPublicKey)
        guard message.encoded == wireData,
              try HandshakeMessageA.rawSignaturePreimage(from: wireData)
                == message.signaturePreimage else {
            throw FormalMacInteropError.invalidSession
        }
    }
}

/// One-shot authority installed before a formal Android -> macOS connection starts.
///
/// The capability deliberately carries authentication only in memory. It does not consult
/// `AuthenticationService`, mutate product identity/trust, or authorize any transfer identifier
/// other than the two identifiers bound to this run.
public struct FormalMacInteropCapability: Sendable {
    public static let suiteWireID: UInt16 = 0x0101

    public let runRef: String
    public let androidToMacTransferID: String
    public let macToAndroidTransferID: String
    public let bearerToken: String
    public let tenantID: String
    public let runDirectory: URL
    public let localIdentity: FormalMacLocalIdentityMaterial

    public init(
        runRef: String,
        androidToMacTransferID: String,
        macToAndroidTransferID: String,
        bearerToken: String,
        tenantID: String,
        runDirectory: URL,
        localIdentity: FormalMacLocalIdentityMaterial
    ) throws {
        guard Self.isCanonicalSHA256(runRef),
              Self.isCanonicalTransferID(androidToMacTransferID),
              Self.isCanonicalTransferID(macToAndroidTransferID),
              androidToMacTransferID != macToAndroidTransferID,
              Self.isJWT(bearerToken),
              (1...512).contains(tenantID.count),
              tenantID.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
                      && !CharacterSet.controlCharacters.contains(scalar)
              }),
              runDirectory.isFileURL else {
            throw FormalMacInteropError.invalidConfiguration
        }
        self.runRef = runRef
        self.androidToMacTransferID = androidToMacTransferID
        self.macToAndroidTransferID = macToAndroidTransferID
        self.bearerToken = bearerToken
        self.tenantID = tenantID
        self.runDirectory = runDirectory.standardizedFileURL
        self.localIdentity = localIdentity
    }

    public func sessionRef(_ sessionID: String) throws -> String {
        guard !sessionID.isEmpty,
              sessionID == sessionID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FormalMacInteropError.invalidSession
        }
        return SHA256.hash(data: Data(sessionID.utf8)).hexString
    }

    public func fileName(direction: FormalMacInteropDirection) -> String {
        "\(direction.payloadLabel)-\(runRef.prefix(16)).txt"
    }

    public func payload(
        direction: FormalMacInteropDirection,
        sessionRef: String,
        transferID: String
    ) throws -> Data {
        guard Self.isCanonicalSHA256(sessionRef),
              Self.isCanonicalTransferID(transferID),
              transferID == direction.transferID(in: self) else {
            throw FormalMacInteropError.invalidTransferBinding
        }
        return Data(
            (
                "skybridge-formal-p2p-file-v1\n"
                    + "direction=\(direction.payloadLabel)\n"
                    + "runRef=\(runRef)\n"
                    + "sessionRef=\(sessionRef)\n"
                    + "transferId=\(transferID)\n"
            ).utf8
        )
    }

    public func validateInboundMetadata(
        transferID: String,
        fileName: String,
        fileSize: Int64,
        senderDeviceID: String?,
        expectedPeerDeviceID: String,
        sessionRef: String
    ) throws {
        let expected = try payload(
            direction: .androidToMac,
            sessionRef: sessionRef,
            transferID: androidToMacTransferID
        )
        guard transferID == androidToMacTransferID,
              fileName == self.fileName(direction: .androidToMac),
              fileSize == Int64(expected.count),
              senderDeviceID == expectedPeerDeviceID else {
            throw FormalMacInteropError.invalidTransferBinding
        }
    }

    public static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    public static func isCanonicalTransferID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isJWT(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(where: { $0.isWhitespace }) else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count == 3 && segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-")
                    || byte == UInt8(ascii: "_")
            }
        }
    }
}

public enum FormalMacInteropDirection: Sendable {
    case androidToMac
    case macToAndroid

    fileprivate var payloadLabel: String {
        switch self {
        case .androidToMac: return "android-to-peer"
        case .macToAndroid: return "peer-to-android"
        }
    }

    fileprivate func transferID(in capability: FormalMacInteropCapability) -> String {
        switch self {
        case .androidToMac: return capability.androidToMacTransferID
        case .macToAndroid: return capability.macToAndroidTransferID
        }
    }
}

public struct FormalMacLocalIdentityMaterial: Sendable {
    public let deviceID: String
    public let protocolPublicKey: Data
    public let protocolSigningKeyHandle: SigningKeyHandle
    public let kemPublicKey: Data
    public let kemPrivateKey: SecureBytes

    public init(
        deviceID: String,
        protocolPublicKey: Data,
        protocolSigningKeyHandle: SigningKeyHandle,
        kemPublicKey: Data,
        kemPrivateKey: SecureBytes
    ) {
        self.deviceID = deviceID
        self.protocolPublicKey = protocolPublicKey
        self.protocolSigningKeyHandle = protocolSigningKeyHandle
        self.kemPublicKey = kemPublicKey
        self.kemPrivateKey = kemPrivateKey
    }

    public var currentPathBinding: ProtocolIdentityBinding {
        get throws {
            try ProtocolIdentityBinding(
                deviceId: deviceID,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyBytes: protocolPublicKey
            )
        }
    }

    public var handshakeIdentity: ResolvedHandshakeIdentity {
        ResolvedHandshakeIdentity(
            identityPublicKey: ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolPublicKey,
                protocolAlgorithm: .mlDSA65,
                sePoPPublicKey: nil
            ).asWire().encoded,
            identityKeyHandle: protocolSigningKeyHandle,
            secureEnclaveKeyHandle: nil,
            sigAAlgorithm: .mlDSA65
        )
    }
}

public struct FormalMacPeerTrustMaterial: Sendable, Equatable {
    public let deviceID: String
    public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    public let protocolPublicKeyFingerprint: String
    public let protocolPublicKey: Data
    public let kemPublicKey: Data

    public init(
        deviceID: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        protocolPublicKey: Data,
        kemPublicKey: Data
    ) {
        self.deviceID = deviceID
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
        self.protocolPublicKey = protocolPublicKey
        self.kemPublicKey = kemPublicKey
    }
}

struct FormalMacVerifiedPeerKEMAdmission: Sendable, Equatable {
    let owner: CrossNetworkFileTransferSessionOwner
    let peerDeviceID: String
    let suiteWireID: UInt16
    let kemPublicKey: Data
}

enum FormalMacPeerKEMAdmissionReplyDisposition: Sendable, Equatable {
    case sendReply(FormalMacVerifiedPeerKEMAdmission)
    case noReplyRequired
}

private enum FormalMacPeerKEMAdmissionState: Sendable, Equatable {
    case replyPending(FormalMacVerifiedPeerKEMAdmission)
    case admitted(FormalMacVerifiedPeerKEMAdmission)

    var admission: FormalMacVerifiedPeerKEMAdmission {
        switch self {
        case .replyPending(let admission), .admitted(let admission):
            return admission
        }
    }
}

/// Claims the first exact peer KEM presentation before its reply is sent, and only promotes it to
/// admitted after that send succeeds. Exact duplicates are idempotent while conflicting owner,
/// epoch, identity, or key presentations fail closed instead of replacing established authority.
struct FormalMacPeerKEMAdmissionRegistry: Sendable {
    private var statesBySessionID: [String: FormalMacPeerKEMAdmissionState] = [:]

    mutating func beginReply(
        owner: CrossNetworkFileTransferSessionOwner,
        peerDeviceID: String,
        presentedKeys: [KEMPublicKeyInfo],
        expectedTrust: FormalMacPeerTrustMaterial
    ) throws -> FormalMacPeerKEMAdmissionReplyDisposition {
        guard peerDeviceID == expectedTrust.deviceID,
              presentedKeys.count == 1,
              presentedKeys[0].suiteWireId == FormalMacInteropCapability.suiteWireID,
              presentedKeys[0].publicKey == expectedTrust.kemPublicKey else {
            throw FormalMacInteropError.missingExactPeerTrust
        }
        let candidate = FormalMacVerifiedPeerKEMAdmission(
            owner: owner,
            peerDeviceID: peerDeviceID,
            suiteWireID: FormalMacInteropCapability.suiteWireID,
            kemPublicKey: presentedKeys[0].publicKey
        )
        if let existing = statesBySessionID[owner.sessionID] {
            guard existing.admission == candidate else {
                throw FormalMacInteropError.staleSession
            }
            return .noReplyRequired
        }
        statesBySessionID[owner.sessionID] = .replyPending(candidate)
        return .sendReply(candidate)
    }

    mutating func installAfterReply(_ admission: FormalMacVerifiedPeerKEMAdmission) throws {
        guard statesBySessionID[admission.owner.sessionID] == .replyPending(admission) else {
            throw FormalMacInteropError.staleSession
        }
        statesBySessionID[admission.owner.sessionID] = .admitted(admission)
    }

    mutating func cancelReply(_ admission: FormalMacVerifiedPeerKEMAdmission) {
        guard statesBySessionID[admission.owner.sessionID] == .replyPending(admission) else {
            return
        }
        statesBySessionID.removeValue(forKey: admission.owner.sessionID)
    }

    func require(
        sessionID: String,
        owner: CrossNetworkFileTransferSessionOwner,
        expectedTrust: FormalMacPeerTrustMaterial
    ) throws {
        guard owner.sessionID == sessionID,
              statesBySessionID[sessionID] == .admitted(FormalMacVerifiedPeerKEMAdmission(
                owner: owner,
                peerDeviceID: expectedTrust.deviceID,
                suiteWireID: FormalMacInteropCapability.suiteWireID,
                kemPublicKey: expectedTrust.kemPublicKey
              )) else {
            throw FormalMacInteropError.peerKEMAdmissionRequired
        }
    }

    mutating func remove(sessionID: String) {
        statesBySessionID.removeValue(forKey: sessionID)
    }

    mutating func removeAll() {
        statesBySessionID.removeAll(keepingCapacity: false)
    }
}

public struct FormalMacTransferEvidence: Sendable, Equatable, Codable {
    public let transferId: String
    public let bytes: Int
    public let sha256: String
    public let durableCommit: Bool
    public let completeAck: Bool

    public init(
        transferId: String,
        bytes: Int,
        sha256: String,
        durableCommit: Bool,
        completeAck: Bool
    ) {
        self.transferId = transferId
        self.bytes = bytes
        self.sha256 = sha256
        self.durableCommit = durableCommit
        self.completeAck = completeAck
    }
}

/// Run-scoped witness between durable inbound commit and the exact complete ACK.
/// A completed replay-cache entry is not sufficient on its own: the committed payload must still
/// match this run before every initial or replayed acknowledgement.
public struct FormalMacInboundCompletionRegistry: Sendable {
    private struct Entry: Sendable {
        let owner: CrossNetworkFileTransferSessionOwner
        let committedURL: URL
        let expectedRunDirectory: URL
        let expectedFileName: String
        let expectedPayload: Data
        let acknowledgement: CrossNetworkFileTransferMessage
        let evidence: FormalMacTransferEvidence
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func stage(
        owner: CrossNetworkFileTransferSessionOwner,
        committedURL: URL,
        expectedRunDirectory: URL,
        expectedFileName: String,
        expectedPayload: Data,
        acknowledgement: CrossNetworkFileTransferMessage
    ) throws {
        let transferID = acknowledgement.transferId
        guard entries[transferID] == nil else {
            throw FormalMacInteropError.invalidTransferBinding
        }
        let evidence = try Self.validate(
            owner: owner,
            committedURL: committedURL,
            expectedRunDirectory: expectedRunDirectory,
            expectedFileName: expectedFileName,
            expectedPayload: expectedPayload,
            acknowledgement: acknowledgement
        )
        entries[transferID] = Entry(
            owner: owner,
            committedURL: committedURL,
            expectedRunDirectory: expectedRunDirectory,
            expectedFileName: expectedFileName,
            expectedPayload: expectedPayload,
            acknowledgement: acknowledgement,
            evidence: evidence
        )
    }

    /// Must be called before every first or replayed ACK.
    public func validateBeforeAcknowledgement(
        owner: CrossNetworkFileTransferSessionOwner,
        acknowledgement: CrossNetworkFileTransferMessage
    ) throws -> FormalMacTransferEvidence {
        guard let entry = entries[acknowledgement.transferId],
              entry.owner == owner,
              entry.acknowledgement == acknowledgement else {
            throw FormalMacInteropError.invalidTransferBinding
        }
        let current = try Self.validate(
            owner: owner,
            committedURL: entry.committedURL,
            expectedRunDirectory: entry.expectedRunDirectory,
            expectedFileName: entry.expectedFileName,
            expectedPayload: entry.expectedPayload,
            acknowledgement: acknowledgement
        )
        guard current == entry.evidence else {
            throw FormalMacInteropError.invalidTransferBinding
        }
        return current
    }

    /// Promotion occurs only after the exact ACK send has succeeded. If the send fails, the entry
    /// deliberately remains staged so an identical replay can be revalidated and acknowledged.
    public mutating func promoteAfterAcknowledgement(
        owner: CrossNetworkFileTransferSessionOwner,
        acknowledgement: CrossNetworkFileTransferMessage
    ) throws -> FormalMacTransferEvidence {
        let evidence = try validateBeforeAcknowledgement(
            owner: owner,
            acknowledgement: acknowledgement
        )
        return evidence
    }

    public mutating func discardAllAfterQuiescence() {
        entries.removeAll(keepingCapacity: false)
    }

    private static func validate(
        owner: CrossNetworkFileTransferSessionOwner,
        committedURL: URL,
        expectedRunDirectory: URL,
        expectedFileName: String,
        expectedPayload: Data,
        acknowledgement: CrossNetworkFileTransferMessage
    ) throws -> FormalMacTransferEvidence {
        _ = owner
        let values = try committedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let bytes = try Data(contentsOf: committedURL, options: .mappedIfSafe)
        let digest = Data(SHA256.hash(data: bytes))
        guard committedURL.deletingLastPathComponent().standardizedFileURL
                == expectedRunDirectory.standardizedFileURL,
              committedURL.lastPathComponent == expectedFileName,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              bytes == expectedPayload,
              acknowledgement.op == .completeAck,
              acknowledgement.receivedBytes == Int64(bytes.count),
              acknowledgement.fileSha256 == digest else {
            throw FormalMacInteropError.invalidTransferBinding
        }
        return FormalMacTransferEvidence(
            transferId: acknowledgement.transferId,
            bytes: bytes.count,
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            durableCommit: true,
            completeAck: true
        )
    }
}

public struct FormalMacSessionBinding: Sendable, Equatable {
    public let owner: CrossNetworkFileTransferSessionOwner
    public let sessionID: String
    public let sessionRef: String
    public let suite: String
    public let suiteWireID: String
    public let selectedICE: WebRTCSession.SelectedICECandidateEvidence
    public let peerDeviceID: String

    public init(
        owner: CrossNetworkFileTransferSessionOwner,
        sessionID: String,
        sessionRef: String,
        suite: String,
        suiteWireID: String,
        selectedICE: WebRTCSession.SelectedICECandidateEvidence,
        peerDeviceID: String
    ) {
        self.owner = owner
        self.sessionID = sessionID
        self.sessionRef = sessionRef
        self.suite = suite
        self.suiteWireID = suiteWireID
        self.selectedICE = selectedICE
        self.peerDeviceID = peerDeviceID
    }
}

public enum FormalMacInteropError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case invalidSession
    case invalidTransferBinding
    case capabilityNotInstalled
    case capabilityAlreadyConsumed
    case missingExistingIdentity
    case inconsistentExistingIdentity
    case missingExactPeerTrust
    case duplicatePeerTrust
    case corruptPeerTrust
    case revokedPeerTrust
    case peerKEMAdmissionRequired
    case staleSession
    case selectedICEUnavailable
    case cleanupFailed
    case exclusiveWriteFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Invalid formal interoperability configuration"
        case .invalidSession: return "Invalid formal interoperability session"
        case .invalidTransferBinding: return "Formal transfer is not bound to this run"
        case .capabilityNotInstalled: return "Formal capability was not installed before connect"
        case .capabilityAlreadyConsumed: return "Formal capability has already been consumed"
        case .missingExistingIdentity: return "Required existing formal identity is missing"
        case .inconsistentExistingIdentity: return "Existing formal identity is inconsistent"
        case .missingExactPeerTrust: return "Exact existing peer trust is missing"
        case .duplicatePeerTrust: return "Duplicate exact peer trust records were found"
        case .corruptPeerTrust: return "Existing peer trust is corrupt"
        case .revokedPeerTrust: return "Existing peer trust is revoked or inactive"
        case .peerKEMAdmissionRequired: return "Exact peer KEM admission is required for this key epoch"
        case .staleSession: return "Formal session owner is stale"
        case .selectedICEUnavailable: return "Selected ICE candidate evidence is unavailable"
        case .cleanupFailed: return "Run-owned cleanup failed"
        case .exclusiveWriteFailed(let code): return "Exclusive result write failed: \(code)"
        }
    }
}

public enum FormalMacInteropFileSystem {
    public static func validateExpectedPayload(
        at url: URL,
        in runDirectory: URL,
        payload: Data,
        actualSHA256: Data
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.deletingLastPathComponent().standardizedFileURL
                == runDirectory.standardizedFileURL,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              actualSHA256 == Data(SHA256.hash(data: payload)) else {
            throw FormalMacInteropError.invalidTransferBinding
        }
    }

    public static func prepareRunDirectory(parent: URL, runRef: String) throws -> URL {
        guard parent.isFileURL, FormalMacInteropCapability.isCanonicalSHA256(runRef) else {
            throw FormalMacInteropError.invalidConfiguration
        }
        let canonicalParent = parent.standardizedFileURL
        try requirePrivateDirectory(canonicalParent)
        let directory = canonicalParent.appendingPathComponent(runRef, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try requirePrivateDirectory(directory)
            try synchronizeDirectory(canonicalParent)
        } catch {
            // Creation succeeded but ownership/mode/type verification did not. Do not permit any
            // formal I/O beneath an authority boundary we cannot prove.
            throw FormalMacInteropError.invalidConfiguration
        }
        return directory
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FormalMacInteropError.invalidConfiguration }
        let syncStatus = Darwin.fsync(descriptor)
        let closeStatus = Darwin.close(descriptor)
        guard syncStatus == 0, closeStatus == 0 else {
            throw FormalMacInteropError.invalidConfiguration
        }
    }

    public static func requirePrivateDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw FormalMacInteropError.invalidConfiguration }
        var metadata = stat()
        let status = directory.path.withCString { path in
            Darwin.lstat(path, &metadata)
        }
        guard status == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw FormalMacInteropError.invalidConfiguration
        }
    }

    public static func writeExclusiveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try writeExclusive(data, to: url)
    }

    public static func writeExclusive(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw FormalMacInteropError.invalidConfiguration }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw FormalMacInteropError.exclusiveWriteFailed(errno) }
        var writeError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    writeError = FormalMacInteropError.exclusiveWriteFailed(errno)
                    return
                }
                offset += written
            }
        }
        if writeError == nil, Darwin.fsync(descriptor) != 0 {
            writeError = FormalMacInteropError.exclusiveWriteFailed(errno)
        }
        let closeStatus = Darwin.close(descriptor)
        if let writeError { throw writeError }
        guard closeStatus == 0 else { throw FormalMacInteropError.exclusiveWriteFailed(errno) }
    }

    public static func cleanupRunDirectory(_ directory: URL, parent: URL, runRef: String) throws {
        let canonicalParent = parent.standardizedFileURL
        let expected = canonicalParent.appendingPathComponent(runRef, isDirectory: true).standardizedFileURL
        guard directory.standardizedFileURL == expected,
              directory.deletingLastPathComponent().standardizedFileURL == canonicalParent,
              FormalMacInteropCapability.isCanonicalSHA256(runRef) else {
            throw FormalMacInteropError.cleanupFailed
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FormalMacInteropError.cleanupFailed
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let entryValues = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard entry.deletingLastPathComponent().standardizedFileURL == expected,
                  entryValues.isRegularFile == true,
                  entryValues.isSymbolicLink != true else {
                throw FormalMacInteropError.cleanupFailed
            }
            try FileManager.default.removeItem(at: entry)
        }
        try FileManager.default.removeItem(at: directory)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FormalMacInteropError.cleanupFailed
        }
        let parentDescriptor = canonicalParent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else { throw FormalMacInteropError.cleanupFailed }
        defer { _ = Darwin.close(parentDescriptor) }
        guard Darwin.fsync(parentDescriptor) == 0 else { throw FormalMacInteropError.cleanupFailed }
    }
}

/// Hash-only before/after snapshot of the product identity and signed trust Keychain services.
/// The digest detects mutation; it is not presented as an anti-tamper mechanism.
public enum FormalMacPersistentStateDigest {
    private static let genericServices = [
        "com.skybridge.p2p.identity",
        "com.skybridge.p2p.identity.mldsa65",
        "com.skybridge.p2p.identity.kem",
        "com.skybridge.p2p.trust"
    ]

    public static func capture() throws -> String {
        var components: [Data] = []
        for service in genericServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecReturnAttributes as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess,
                  let items = result as? [[String: Any]] else {
                throw FormalMacInteropError.inconsistentExistingIdentity
            }
            var seenAccounts = Set<String>()
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      seenAccounts.insert(account).inserted,
                      let value = item[kSecValueData as String] as? Data else {
                    throw FormalMacInteropError.inconsistentExistingIdentity
                }
                components.append(canonicalComponent(service: service, account: account, value: value))
            }
        }

        let keyTag = Data("com.skybridge.p2p.identity.signing".utf8)
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var keyResult: AnyObject?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)
        if keyStatus == errSecSuccess {
            let keyReferences: [SecKey]
            if let values = keyResult as? [AnyObject] {
                keyReferences = values.compactMap { value in
                    guard CFGetTypeID(value) == SecKeyGetTypeID() else { return nil }
                    return unsafeDowncast(value, to: SecKey.self)
                }
            } else if let value = keyResult, CFGetTypeID(value) == SecKeyGetTypeID() {
                keyReferences = [unsafeDowncast(value, to: SecKey.self)]
            } else {
                throw FormalMacInteropError.inconsistentExistingIdentity
            }
            guard keyReferences.count == 1,
                  let publicKey = SecKeyCopyPublicKey(keyReferences[0]),
                  let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                throw FormalMacInteropError.inconsistentExistingIdentity
            }
            components.append(
                canonicalComponent(
                    service: "key",
                    account: "com.skybridge.p2p.identity.signing",
                    value: publicData
                )
            )
        } else if keyStatus != errSecItemNotFound {
            throw FormalMacInteropError.inconsistentExistingIdentity
        }

        guard !components.isEmpty else { throw FormalMacInteropError.missingExistingIdentity }
        var canonical = Data("SkyBridge-Formal-Mac-Persistent-State-v1\n".utf8)
        for component in components.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            canonical.append(component)
        }
        return SHA256.hash(data: canonical).hexString
    }

    private static func canonicalComponent(service: String, account: String, value: Data) -> Data {
        var result = Data("\(service.utf8.count):\(service)\n\(account.utf8.count):\(account)\n\(value.count):".utf8)
        result.append(value)
        result.append(0x0A)
        return result
    }
}

extension Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
