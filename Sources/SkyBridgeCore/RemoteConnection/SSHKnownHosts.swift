import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOSSH
import OSLog

public struct SSHKnownHostEntry: Codable, Equatable, Identifiable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let fingerprint: String

    public var id: String {
        "\(host):\(port):\(keyType):\(fingerprint)"
    }
}

public struct SSHKnownHostsImportResult: Sendable, Equatable {
    public let added: Int
    public let skipped: Int
}

public enum SSHKnownHostsStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidPersistedData
    case invalidEntry
    case conflictingHostKey
    case importFileTooLarge
    case invalidImportFile
    case persistenceUnavailable
    case persistenceVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPersistedData:
            return "The SSH known-hosts database is invalid. Host-key trust is unavailable."
        case .invalidEntry:
            return "The SSH host-key entry is invalid."
        case .conflictingHostKey:
            return "A different SSH host key of the same algorithm is already trusted. Verify the replacement key and rotate it atomically; do not delete the old key first."
        case .importFileTooLarge:
            return "The SSH known-hosts import exceeds the supported size limit."
        case .invalidImportFile:
            return "The SSH known-hosts import is not a valid UTF-8 regular file."
        case .persistenceUnavailable:
            return "The SSH known-hosts database is unavailable. Host-key trust is fail-closed."
        case .persistenceVerificationFailed:
            return "The SSH known-hosts update could not be verified. Host-key trust is fail-closed."
        }
    }
}

private enum SSHKnownHostAdditionPolicy {
    case unknownHostOnly
    case allowAdditionalAlgorithm
}

enum SSHKnownHostValidationDecision: Equatable {
    case trusted
    case trustedOnFirstUse
    case unknown
    case mismatch
}

/// Serialized, fail-closed SSH host-key authority.
///
/// The store publishes a new in-memory snapshot only after its file backend has durably committed
/// and reopened the exact encoded bytes. Equivalent DNS/IP spellings are canonicalized before every
/// lookup so TOFU cannot create parallel trust authorities for the same endpoint.
public final class SSHKnownHostsStore: @unchecked Sendable {
    public static let shared = makeSharedStore()

    private static let legacySuiteName = "com.skybridge.compass"
    private static let legacyStorageKey = "ssh.knownHosts"
    private static let maximumEntryCount = 4_096
    private static let maximumImportBytes = 1_024 * 1_024

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHKnownHosts")
    private let queue = DispatchQueue(label: "com.skybridge.ssh.knownhosts", qos: .utility)
    private let persistence: (any SSHKnownHostsPersistenceBackend)?
    private let integrityPersistence: (any SSHKnownHostsIntegrityPersistenceBackend)?
    private let legacyDefaults: UserDefaults?
    private let legacyStorageKey: String?
    private var entries: [SSHKnownHostEntry] = []
    private var integrityState: SSHKnownHostsIntegrityState?
    private var persistenceFailure: SSHKnownHostsStoreError?

    private init(
        persistence: (any SSHKnownHostsPersistenceBackend)?,
        integrityPersistence: (any SSHKnownHostsIntegrityPersistenceBackend)?,
        legacyDefaults: UserDefaults?,
        legacyStorageKey: String?,
        initialFailure: SSHKnownHostsStoreError? = nil
    ) {
        self.persistence = persistence
        self.integrityPersistence = integrityPersistence
        self.legacyDefaults = legacyDefaults
        self.legacyStorageKey = legacyStorageKey
        persistenceFailure = initialFailure
        guard initialFailure == nil else { return }
        loadPersistedEntries()
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        persistence: any SSHKnownHostsPersistenceBackend,
        integrityPersistence: any SSHKnownHostsIntegrityPersistenceBackend,
        legacyDefaults: UserDefaults? = nil,
        legacyStorageKey: String? = nil
    ) {
        self.persistence = persistence
        self.integrityPersistence = integrityPersistence
        self.legacyDefaults = legacyDefaults
        self.legacyStorageKey = legacyStorageKey
        loadPersistedEntries()
    }
#endif

    func isTrusted(host: String, port: Int, keyType: String, fingerprint: String) throws -> Bool {
        let candidate = try Self.normalizedEntry(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint
        )
        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            return entries.contains(candidate)
        }
    }

    func hasTrustedKey(forHost host: String, port: Int) throws -> Bool {
        let normalizedHost = try Self.normalizedHost(host)
        guard (1...65_535).contains(port) else {
            throw SSHKnownHostsStoreError.invalidEntry
        }
        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            return entries.contains { $0.host == normalizedHost && $0.port == port }
        }
    }

    @discardableResult
    func record(
        host: String,
        port: Int,
        keyType: String,
        fingerprint: String
    ) throws -> Bool {
        try record(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint,
            policy: .unknownHostOnly
        )
    }

    func fingerprint(for hostKey: NIOSSHPublicKey) -> (keyType: String, fingerprint: String)? {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            logger.error("OpenSSH public-key framing is invalid")
            return nil
        }
        let keyType = String(parts[0])
        guard let keyData = Data(base64Encoded: String(parts[1])) else {
            logger.error("OpenSSH public-key payload is invalid")
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return (keyType: keyType, fingerprint: fingerprint)
    }

    func fingerprintForOpenSSHKey(
        keyType: String,
        keyData: String
    ) -> (keyType: String, fingerprint: String)? {
        let publicKey: NIOSSHPublicKey
        do {
            publicKey = try NIOSSHPublicKey(openSSHPublicKey: "\(keyType) \(keyData)")
        } catch {
            logger.error("OpenSSH public-key parsing failed")
            return nil
        }
        return fingerprint(for: publicKey)
    }

    private func openSSHKeyInfo(
        _ openSSHPublicKey: String
    ) throws -> (keyType: String, fingerprint: String) {
        let parts = openSSHPublicKey.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard parts.count >= 2,
              let info = fingerprintForOpenSSHKey(
                  keyType: String(parts[0]),
                  keyData: String(parts[1])
              ) else {
            throw SSHHostKeyValidationError.invalidHostKey
        }
        return info
    }

    public func allEntries() throws -> [SSHKnownHostEntry] {
        try queue.sync {
            try ensurePersistenceAvailableLocked()
            return Self.sorted(entries)
        }
    }

    public func removeAll() throws {
        try queue.sync {
            try ensurePersistenceAvailableLocked()
            try saveLocked([])
            entries = []
        }
    }

    /// Explicit recovery for a corrupt or unavailable authority. Callers must obtain user
    /// confirmation because this operation intentionally discards all existing host-key trust.
    public func resetAuthorityAfterUserConfirmation() throws {
        try queue.sync {
            try saveLocked([])
            entries = []
            persistenceFailure = nil
        }
    }

    public func remove(entry: SSHKnownHostEntry) throws {
        let normalized = try Self.normalizedEntry(entry)
        try queue.sync {
            try ensurePersistenceAvailableLocked()
            let snapshot = entries.filter { $0 != normalized }
            guard snapshot.count != entries.count else { return }
            try saveLocked(snapshot)
            entries = snapshot
        }
    }

    @discardableResult
    public func addOpenSSHPublicKey(
        host: String,
        port: Int,
        openSSHPublicKey: String
    ) throws -> Bool {
        let info = try openSSHKeyInfo(openSSHPublicKey)
        return try record(
            host: host,
            port: port,
            keyType: info.keyType,
            fingerprint: info.fingerprint,
            policy: .allowAdditionalAlgorithm
        )
    }

    /// Atomically replaces a same-algorithm host key only when the caller's expected key still
    /// matches the durable authority. This avoids the delete-then-add gap in which TOFU could trust
    /// an attacker-controlled key.
    @discardableResult
    public func compareAndReplaceOpenSSHPublicKey(
        host: String,
        port: Int,
        expectedOpenSSHPublicKey: String,
        replacementOpenSSHPublicKey: String
    ) throws -> Bool {
        let expectedInfo = try openSSHKeyInfo(expectedOpenSSHPublicKey)
        let replacementInfo = try openSSHKeyInfo(replacementOpenSSHPublicKey)
        guard expectedInfo.keyType == replacementInfo.keyType else {
            throw SSHKnownHostsStoreError.invalidEntry
        }

        let expected = try Self.normalizedEntry(
            host: host,
            port: port,
            keyType: expectedInfo.keyType,
            fingerprint: expectedInfo.fingerprint
        )
        let replacement = try Self.normalizedEntry(
            host: host,
            port: port,
            keyType: replacementInfo.keyType,
            fingerprint: replacementInfo.fingerprint
        )
        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            guard let expectedIndex = entries.firstIndex(of: expected) else {
                throw SSHKnownHostsStoreError.conflictingHostKey
            }
            guard expected != replacement else { return false }
            guard !entries.contains(where: {
                $0.host == replacement.host
                    && $0.port == replacement.port
                    && $0.keyType == replacement.keyType
                    && $0 != expected
            }) else {
                throw SSHKnownHostsStoreError.conflictingHostKey
            }

            var snapshot = entries
            snapshot[expectedIndex] = replacement
            snapshot = Self.sorted(snapshot)
            try saveLocked(snapshot)
            entries = snapshot
            return true
        }
    }

    /// Parses and validates the complete import before performing one durable snapshot commit.
    public func importKnownHostsFile(from url: URL) throws -> SSHKnownHostsImportResult {
        let data: Data
        do {
            guard let loaded = try SSHKnownHostsFilePersistence.readRegularFile(
                at: url,
                maximumBytes: Self.maximumImportBytes
            ) else {
                throw SSHKnownHostsStoreError.invalidImportFile
            }
            data = loaded
        } catch SSHKnownHostsStoreError.invalidPersistedData {
            throw SSHKnownHostsStoreError.importFileTooLarge
        } catch let error as SSHKnownHostsStoreError {
            throw error
        } catch {
            throw SSHKnownHostsStoreError.invalidImportFile
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw SSHKnownHostsStoreError.invalidImportFile
        }
        let parsed = try parseImport(content)

        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            var snapshot = entries
            var added = 0
            var skipped = parsed.skipped

            for candidate in parsed.entries {
                if snapshot.contains(candidate) {
                    skipped += 1
                    continue
                }
                if snapshot.contains(where: {
                    $0.host == candidate.host
                        && $0.port == candidate.port
                        && $0.keyType == candidate.keyType
                        && $0.fingerprint != candidate.fingerprint
                }) {
                    throw SSHKnownHostsStoreError.conflictingHostKey
                }
                guard snapshot.count < Self.maximumEntryCount else {
                    throw SSHKnownHostsStoreError.importFileTooLarge
                }
                snapshot.append(candidate)
                added += 1
            }

            if added > 0 {
                try saveLocked(snapshot)
                entries = Self.sorted(snapshot)
            }
            return SSHKnownHostsImportResult(added: added, skipped: skipped)
        }
    }

    private static func makeSharedStore() -> SSHKnownHostsStore {
        guard let legacyDefaults = UserDefaults(suiteName: legacySuiteName) else {
            return SSHKnownHostsStore(
                persistence: nil,
                integrityPersistence: nil,
                legacyDefaults: nil,
                legacyStorageKey: nil,
                initialFailure: .persistenceUnavailable
            )
        }

        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fileURL = applicationSupport
                .appendingPathComponent("com.skybridge.compass", isDirectory: true)
                .appendingPathComponent("SkyBridgeState", isDirectory: true)
                .appendingPathComponent("Security", isDirectory: true)
                .appendingPathComponent("ssh-known-hosts.json", isDirectory: false)
            return SSHKnownHostsStore(
                persistence: SSHKnownHostsFilePersistence(fileURL: fileURL),
                integrityPersistence: SSHKnownHostsKeychainIntegrityPersistence(),
                legacyDefaults: legacyDefaults,
                legacyStorageKey: legacyStorageKey
            )
        } catch {
            return SSHKnownHostsStore(
                persistence: nil,
                integrityPersistence: nil,
                legacyDefaults: nil,
                legacyStorageKey: nil,
                initialFailure: .persistenceUnavailable
            )
        }
    }

    private func loadPersistedEntries() {
        queue.sync {
            guard let persistence, let integrityPersistence else {
                persistenceFailure = .persistenceUnavailable
                return
            }

            do {
                let protectedState = try integrityPersistence.loadState()
                integrityState = protectedState
                if let protectedState {
                    guard let data = try persistence.loadData(),
                          Self.databaseDigest(data) == protectedState.databaseSHA256 else {
                        throw SSHKnownHostsStoreError.invalidPersistedData
                    }
                    entries = try Self.decodePersistedEntries(data)
                    return
                }

                // One-time upgrade for a valid authority written before protected rollback markers
                // existed. Recommit the canonical snapshot before installing the marker so the
                // upgrade has the same file-then-Keychain ordering as every later transaction.
                if let existingData = try persistence.loadData() {
                    let existingEntries = try Self.decodePersistedEntries(existingData)
                    try saveLocked(existingEntries)
                    entries = existingEntries
                    return
                }

                let initialEntries: [SSHKnownHostEntry]
                guard let legacyDefaults, let legacyStorageKey,
                      let legacyObject = legacyDefaults.object(forKey: legacyStorageKey) else {
                    initialEntries = []
                    try saveLocked(initialEntries)
                    entries = initialEntries
                    return
                }
                guard let legacyData = legacyObject as? Data else {
                    throw SSHKnownHostsStoreError.invalidPersistedData
                }

                let migratedEntries = try Self.decodePersistedEntries(legacyData)
                try saveLocked(migratedEntries)
                entries = migratedEntries
                legacyDefaults.removeObject(forKey: legacyStorageKey)
            } catch {
                entries = []
                persistenceFailure = Self.persistenceFailure(for: error, loading: true)
                logger.fault("SSH known-hosts storage failed validation; trust is fail-closed")
            }
        }
    }

    private func record(
        host: String,
        port: Int,
        keyType: String,
        fingerprint: String,
        policy: SSHKnownHostAdditionPolicy
    ) throws -> Bool {
        let candidate = try Self.normalizedEntry(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint
        )
        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            return try recordLocked(candidate, policy: policy)
        }
    }

    private func recordLocked(
        _ candidate: SSHKnownHostEntry,
        policy: SSHKnownHostAdditionPolicy
    ) throws -> Bool {
        if entries.contains(candidate) {
            return false
        }

        let endpointEntries = entries.filter {
            $0.host == candidate.host && $0.port == candidate.port
        }
        switch policy {
        case .unknownHostOnly:
            guard endpointEntries.isEmpty else {
                throw SSHKnownHostsStoreError.conflictingHostKey
            }
        case .allowAdditionalAlgorithm:
            guard !endpointEntries.contains(where: { $0.keyType == candidate.keyType }) else {
                throw SSHKnownHostsStoreError.conflictingHostKey
            }
        }

        guard entries.count < Self.maximumEntryCount else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        var snapshot = entries
        snapshot.append(candidate)
        snapshot = Self.sorted(snapshot)
        try saveLocked(snapshot)
        entries = snapshot
        return true
    }

    func validationDecision(
        host: String,
        port: Int,
        keyType: String,
        fingerprint: String,
        trustOnFirstUse: Bool
    ) throws -> SSHKnownHostValidationDecision {
        let candidate = try Self.normalizedEntry(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint
        )
        return try queue.sync {
            try ensurePersistenceAvailableLocked()
            if entries.contains(candidate) {
                return .trusted
            }
            if entries.contains(where: { $0.host == candidate.host && $0.port == candidate.port }) {
                return .mismatch
            }
            guard trustOnFirstUse else {
                return .unknown
            }
            _ = try recordLocked(candidate, policy: .unknownHostOnly)
            return .trustedOnFirstUse
        }
    }

    private func parseImport(_ content: String) throws -> (entries: [SSHKnownHostEntry], skipped: Int) {
        var parsedEntries: [SSHKnownHostEntry] = []
        var skipped = 0

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, !fields[0].hasPrefix("@") else {
                skipped += 1
                continue
            }
            let hostField = String(fields[0])
            guard !hostField.hasPrefix("|") else {
                skipped += 1
                continue
            }
            guard let info = fingerprintForOpenSSHKey(
                keyType: String(fields[1]),
                keyData: String(fields[2])
            ) else {
                skipped += 1
                continue
            }

            for rawHost in hostField.split(separator: ",", omittingEmptySubsequences: false) {
                guard let endpoint = Self.parseImportedHostField(String(rawHost)) else {
                    skipped += 1
                    continue
                }
                do {
                    parsedEntries.append(
                        try Self.normalizedEntry(
                            host: endpoint.host,
                            port: endpoint.port,
                            keyType: info.keyType,
                            fingerprint: info.fingerprint
                        )
                    )
                } catch SSHKnownHostsStoreError.invalidEntry {
                    skipped += 1
                } catch {
                    throw error
                }
                guard parsedEntries.count <= Self.maximumEntryCount else {
                    throw SSHKnownHostsStoreError.importFileTooLarge
                }
            }
        }
        return (parsedEntries, skipped)
    }

    private static func parseImportedHostField(_ raw: String) -> (host: String, port: Int)? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("[") {
            guard let closing = raw.firstIndex(of: "]") else { return nil }
            let host = String(raw[raw.index(after: raw.startIndex)..<closing])
            let delimiter = raw.index(after: closing)
            guard delimiter < raw.endIndex, raw[delimiter] == ":" else { return nil }
            let portStart = raw.index(after: delimiter)
            guard portStart < raw.endIndex,
                  let port = Int(raw[portStart...]),
                  (1...65_535).contains(port) else {
                return nil
            }
            return (host, port)
        }
        return (raw, 22)
    }

    private func saveLocked(_ snapshot: [SSHKnownHostEntry]) throws {
        guard let persistence, let integrityPersistence else {
            persistenceFailure = .persistenceUnavailable
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }

        do {
            let normalized = try snapshot.map(Self.normalizedEntry)
            guard normalized.count <= Self.maximumEntryCount else {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            let sortedEntries = Self.sorted(normalized)
            let data = try Self.encodeEntries(sortedEntries)
            let committed = try persistence.commitAndReload(data)
            guard committed == data,
                  try Self.decodePersistedEntries(committed) == sortedEntries else {
                throw SSHKnownHostsStoreError.persistenceVerificationFailed
            }
            let currentGeneration = integrityState?.generation ?? 0
            guard currentGeneration < UInt64.max else {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            let nextState = SSHKnownHostsIntegrityState(
                generation: currentGeneration + 1,
                databaseSHA256: Self.databaseDigest(committed)
            )
            guard try integrityPersistence.commitAndReload(nextState) == nextState else {
                throw SSHKnownHostsStoreError.persistenceVerificationFailed
            }
            integrityState = nextState
        } catch {
            let failure = Self.persistenceFailure(for: error, loading: false)
            persistenceFailure = failure
            logger.fault("SSH known-hosts persistence failed; trust is fail-closed")
            throw failure
        }
    }

    private func ensurePersistenceAvailableLocked() throws {
        if let persistenceFailure {
            throw persistenceFailure
        }
    }

    private static func persistenceFailure(for error: Error, loading: Bool) -> SSHKnownHostsStoreError {
        if let storeError = error as? SSHKnownHostsStoreError {
            switch storeError {
            case .invalidPersistedData, .invalidEntry, .conflictingHostKey:
                return loading ? .invalidPersistedData : .persistenceVerificationFailed
            case .persistenceVerificationFailed:
                return .persistenceVerificationFailed
            case .importFileTooLarge, .invalidImportFile, .persistenceUnavailable:
                return .persistenceUnavailable
            }
        }
        return .persistenceUnavailable
    }

    private static func encodeEntries(_ entries: [SSHKnownHostEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(sorted(entries))
    }

    private static func databaseDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodePersistedEntries(_ data: Data) throws -> [SSHKnownHostEntry] {
        guard !data.isEmpty, data.count <= SSHKnownHostsFilePersistence.maximumDatabaseBytes else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
        let decoded: [SSHKnownHostEntry]
        do {
            decoded = try JSONDecoder().decode([SSHKnownHostEntry].self, from: data)
        } catch {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
        guard decoded.count <= maximumEntryCount else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }

        let normalized = try decoded.map(normalizedEntry)
        var identities = Set<String>()
        var fingerprintByAlgorithmAuthority: [String: String] = [:]
        identities.reserveCapacity(normalized.count)
        fingerprintByAlgorithmAuthority.reserveCapacity(normalized.count)
        for entry in normalized {
            guard identities.insert(entry.id).inserted else {
                throw SSHKnownHostsStoreError.invalidPersistedData
            }
            let authority = "\(entry.host)\u{0}\(entry.port)\u{0}\(entry.keyType)"
            if let existing = fingerprintByAlgorithmAuthority[authority],
               existing != entry.fingerprint {
                throw SSHKnownHostsStoreError.invalidPersistedData
            }
            fingerprintByAlgorithmAuthority[authority] = entry.fingerprint
        }
        return sorted(normalized)
    }

    private static func normalizedEntry(_ entry: SSHKnownHostEntry) throws -> SSHKnownHostEntry {
        try normalizedEntry(
            host: entry.host,
            port: entry.port,
            keyType: entry.keyType,
            fingerprint: entry.fingerprint
        )
    }

    private static func normalizedEntry(
        host: String,
        port: Int,
        keyType: String,
        fingerprint: String
    ) throws -> SSHKnownHostEntry {
        guard (1...65_535).contains(port),
              !keyType.isEmpty,
              keyType.utf8.count <= 128,
              keyType.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !keyType.utf8.contains(92),
              !keyType.utf8.contains(34) else {
            throw SSHKnownHostsStoreError.invalidEntry
        }

        let normalizedFingerprint = fingerprint.lowercased()
        guard normalizedFingerprint.utf8.count == 64,
              normalizedFingerprint.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw SSHKnownHostsStoreError.invalidEntry
        }
        return SSHKnownHostEntry(
            host: try normalizedHost(host),
            port: port,
            keyType: keyType,
            fingerprint: normalizedFingerprint
        )
    }

    static func normalizedHost(_ rawHost: String) throws -> String {
        guard rawHost == rawHost.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            throw SSHKnownHostsStoreError.invalidEntry
        }

        var host = rawHost
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else {
                throw SSHKnownHostsStoreError.invalidEntry
            }
            host.removeFirst()
            host.removeLast()
        }

        let scopedParts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if scopedParts.count == 2 {
            let address = String(scopedParts[0])
            let scope = String(scopedParts[1])
            guard let canonicalAddress = canonicalIPv6(address),
                  !scope.isEmpty,
                  scope.utf8.count <= 64,
                  scope.utf8.allSatisfy({
                    ($0 >= 48 && $0 <= 57)
                        || ($0 >= 65 && $0 <= 90)
                        || ($0 >= 97 && $0 <= 122)
                        || $0 == 45 || $0 == 46 || $0 == 95
                  }) else {
                throw SSHKnownHostsStoreError.invalidEntry
            }
            return "\(canonicalAddress)%\(scope)"
        }

        if let address = canonicalIPv4(host) ?? canonicalIPv6(host) ?? canonicalNumericHost(host) {
            return address
        }

        if host.hasSuffix(".") {
            host.removeLast()
        }
        let normalized = host.lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 253,
              normalized.unicodeScalars.allSatisfy({ $0.value <= 127 }) else {
            throw SSHKnownHostsStoreError.invalidEntry
        }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45 || $0 == 95
            }
        }) else {
            throw SSHKnownHostsStoreError.invalidEntry
        }
        return normalized
    }

    private static func canonicalIPv4(_ host: String) -> String? {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let bufferCount = buffer.count
        let result = withUnsafePointer(to: &address) { addressPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(AF_INET, addressPointer, bufferPointer.baseAddress, socklen_t(bufferCount))
            }
        }
        guard result != nil else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func canonicalIPv6(_ host: String) -> String? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let bufferCount = buffer.count
        let result = withUnsafePointer(to: &address) { addressPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(AF_INET6, addressPointer, bufferPointer.baseAddress, socklen_t(bufferCount))
            }
        }
        guard result != nil else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).lowercased()
    }

    /// Canonicalizes legacy numeric forms using the same Darwin resolver semantics as
    /// `ClientBootstrap.connect`, without performing DNS. Examples include `127.1`, integer IPv4,
    /// and hexadecimal IPv4. Otherwise those spellings would create parallel host authorities.
    private static func canonicalNumericHost(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            getnameinfo(
                result.pointee.ai_addr,
                result.pointee.ai_addrlen,
                bufferPointer.baseAddress,
                socklen_t(bufferPointer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard status == 0 else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).lowercased()
    }

    private static func sorted(_ entries: [SSHKnownHostEntry]) -> [SSHKnownHostEntry] {
        entries.sorted {
            ($0.host, $0.port, $0.keyType, $0.fingerprint)
                < ($1.host, $1.port, $1.keyType, $1.fingerprint)
        }
    }
}

public enum SSHHostKeyValidationError: Error, Sendable, Equatable {
    case unknownHostKey
    case hostKeyMismatch
    case invalidHostKey
    case knownHostsUnavailable
}

/// Strict host-key validation delegate backed by `SSHKnownHostsStore`.
final class SSHKnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private static let validationQueue = DispatchQueue(
        label: "com.skybridge.ssh.host-key-validation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let host: String
    private let port: Int
    private let trustOnFirstUse: Bool
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHKnownHostsDelegate")

    init(host: String, port: Int, trustOnFirstUse: Bool) {
        self.host = host
        self.port = port
        self.trustOnFirstUse = trustOnFirstUse
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let host = self.host
        let port = self.port
        let trustOnFirstUse = self.trustOnFirstUse
        let logger = self.logger
        Self.validationQueue.async {
            // `shared` performs file/Keychain initialization. Keep both initialization and
            // fingerprint framing away from the NIO event loop.
            guard let info = SSHKnownHostsStore.shared.fingerprint(for: hostKey) else {
                validationCompletePromise.fail(SSHHostKeyValidationError.invalidHostKey)
                return
            }
            do {
                let decision = try SSHKnownHostsStore.shared.validationDecision(
                    host: host,
                    port: port,
                    keyType: info.keyType,
                    fingerprint: info.fingerprint,
                    trustOnFirstUse: trustOnFirstUse
                )
                switch decision {
                case .trusted:
                    validationCompletePromise.succeed(())
                case .trustedOnFirstUse:
                    logger.notice("An SSH host key was durably trusted on first use")
                    validationCompletePromise.succeed(())
                case .unknown:
                    logger.error("An unknown SSH host key was rejected")
                    validationCompletePromise.fail(SSHHostKeyValidationError.unknownHostKey)
                case .mismatch:
                    logger.error("An SSH host-key mismatch was rejected")
                    validationCompletePromise.fail(SSHHostKeyValidationError.hostKeyMismatch)
                }
            } catch SSHKnownHostsStoreError.conflictingHostKey {
                logger.error("SSH TOFU could not replace an existing host authority")
                validationCompletePromise.fail(SSHHostKeyValidationError.hostKeyMismatch)
            } catch {
                logger.fault("SSH known-hosts authority was unavailable; validation was rejected")
                validationCompletePromise.fail(SSHHostKeyValidationError.knownHostsUnavailable)
            }
        }
    }
}
