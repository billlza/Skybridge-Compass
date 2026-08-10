import Combine
import Foundation

public enum RemoteControlTransportKind: String, Codable, Sendable, Equatable {
    case p2p
    case webrtc

    public var localizationKey: String {
        switch self {
        case .p2p:
            return "remoteControl.securityNotice.transport.p2p"
        case .webrtc:
            return "remoteControl.securityNotice.transport.webrtc"
        }
    }

    public var evidenceValue: String {
        rawValue
    }
}

public enum RemoteControlSecurityDecision: String, Codable, Sendable, Equatable {
    case approved
    case rejected
    case timedOut
    case disconnected
}

public enum RemoteControlSecurityNoticePhase: String, Codable, Sendable, Equatable {
    case awaitingApproval
    case active
}

public struct RemoteControlSecurityIdentity: Codable, Sendable, Equatable {
    private static let maximumAccountDisplayNameBytes = 320
    private static let maximumNebulaIdBytes = 256
    private static let maximumDeviceIdBytes = 256
    private static let maximumDeviceNameBytes = 128

    private enum CodingKeys: String, CodingKey {
        case accountDisplayName
        case nebulaId
        case deviceId
        case deviceName
    }

    private struct DecodedFields {
        let accountDisplayName: String?
        let nebulaId: String?
        let deviceId: String?
        let deviceName: String?
    }

    private struct ValidationFailure: Error {
        let field: CodingKeys
        let maximumLength: Int
    }

    public let accountDisplayName: String?
    public let nebulaId: String?
    public let deviceId: String?
    public let deviceName: String?

    public init(
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.accountDisplayName = Self.normalized(
            accountDisplayName,
            maximumLength: Self.maximumAccountDisplayNameBytes
        )
        self.nebulaId = Self.normalized(
            nebulaId,
            maximumLength: Self.maximumNebulaIdBytes
        )
        self.deviceId = Self.normalized(
            deviceId,
            maximumLength: Self.maximumDeviceIdBytes
        )
        self.deviceName = Self.normalized(
            deviceName,
            maximumLength: Self.maximumDeviceNameBytes
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = DecodedFields(
            accountDisplayName: try container.decodeIfPresent(
                String.self,
                forKey: .accountDisplayName
            ),
            nebulaId: try container.decodeIfPresent(String.self, forKey: .nebulaId),
            deviceId: try container.decodeIfPresent(String.self, forKey: .deviceId),
            deviceName: try container.decodeIfPresent(String.self, forKey: .deviceName)
        )
        do {
            try self.init(validating: fields)
        } catch let failure as ValidationFailure {
            throw DecodingError.dataCorruptedError(
                forKey: failure.field,
                in: container,
                debugDescription: "Remote-control security identity field \(failure.field.rawValue) must be non-empty, contain no control characters, and fit within \(failure.maximumLength) UTF-8 bytes."
            )
        }
    }

    public var isEmpty: Bool {
        accountDisplayName == nil
            && nebulaId == nil
            && deviceId == nil
            && deviceName == nil
    }

    public func merging(_ newer: RemoteControlSecurityIdentity) -> RemoteControlSecurityIdentity {
        RemoteControlSecurityIdentity(
            accountDisplayName: newer.accountDisplayName ?? accountDisplayName,
            nebulaId: newer.nebulaId ?? nebulaId,
            deviceId: newer.deviceId ?? deviceId,
            deviceName: newer.deviceName ?? deviceName
        )
    }

    private init(validating fields: DecodedFields) throws {
        accountDisplayName = try Self.validated(
            fields.accountDisplayName,
            field: .accountDisplayName,
            maximumLength: Self.maximumAccountDisplayNameBytes
        )
        nebulaId = try Self.validated(
            fields.nebulaId,
            field: .nebulaId,
            maximumLength: Self.maximumNebulaIdBytes
        )
        deviceId = try Self.validated(
            fields.deviceId,
            field: .deviceId,
            maximumLength: Self.maximumDeviceIdBytes
        )
        deviceName = try Self.validated(
            fields.deviceName,
            field: .deviceName,
            maximumLength: Self.maximumDeviceNameBytes
        )
    }

    private static func validated(
        _ value: String?,
        field: CodingKeys,
        maximumLength: Int
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationFailure(field: field, maximumLength: maximumLength)
        }
        return trimmed
    }

    private static func normalized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}

public struct RemoteControlSecurityDescriptor: Identifiable, Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case sessionEvidenceReference
        case transportKind
        case remoteIPAddress
        case remoteDeviceId
        case remoteDeviceName
        case remoteAccountDisplayName
        case remoteNebulaId
        case localAccountDisplayName
        case localNebulaId
        case cryptoSuite
        case createdAt
        case approvalTimeoutSeconds
    }

    private struct DecodedFields {
        let id: UUID
        let sessionId: String
        let sessionEvidenceReference: String?
        let transportKind: RemoteControlTransportKind
        let remoteIPAddress: String?
        let remoteDeviceId: String?
        let remoteDeviceName: String?
        let remoteAccountDisplayName: String?
        let remoteNebulaId: String?
        let localAccountDisplayName: String?
        let localNebulaId: String?
        let cryptoSuite: String
        let createdAt: Date
        let approvalTimeoutSeconds: TimeInterval
    }

    private struct ValidationFailure: Error {
        let field: CodingKeys
        let maximumLength: Int
    }

    public let id: UUID
    public let sessionId: String
    public let sessionEvidenceReference: String?
    public let transportKind: RemoteControlTransportKind
    public let remoteIPAddress: String?
    public let remoteDeviceId: String?
    public let remoteDeviceName: String?
    public let remoteAccountDisplayName: String?
    public let remoteNebulaId: String?
    public let localAccountDisplayName: String?
    public let localNebulaId: String?
    public let cryptoSuite: String
    public let createdAt: Date
    public let approvalTimeoutSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        sessionId: String,
        sessionEvidenceReference: String? = nil,
        transportKind: RemoteControlTransportKind,
        remoteIPAddress: String?,
        remoteDeviceId: String?,
        remoteDeviceName: String?,
        remoteAccountDisplayName: String?,
        remoteNebulaId: String?,
        localAccountDisplayName: String?,
        localNebulaId: String?,
        cryptoSuite: String,
        createdAt: Date = Date(),
        approvalTimeoutSeconds: TimeInterval = 45
    ) {
        self.id = id
        self.sessionId = Self.normalized(sessionId, maximumLength: 256) ?? ""
        self.sessionEvidenceReference = sessionEvidenceReference.flatMap {
            P2PEvidenceReference.isValid($0) ? $0 : nil
        }
        self.transportKind = transportKind
        self.remoteIPAddress = Self.normalized(remoteIPAddress, maximumLength: 256)
        self.remoteDeviceId = Self.normalized(remoteDeviceId, maximumLength: 256)
        self.remoteDeviceName = Self.normalized(remoteDeviceName, maximumLength: 128)
        self.remoteAccountDisplayName = Self.normalized(remoteAccountDisplayName, maximumLength: 320)
        self.remoteNebulaId = Self.normalized(remoteNebulaId, maximumLength: 256)
        self.localAccountDisplayName = Self.normalized(localAccountDisplayName, maximumLength: 320)
        self.localNebulaId = Self.normalized(localNebulaId, maximumLength: 256)
        self.cryptoSuite = Self.normalized(cryptoSuite, maximumLength: 64) ?? "missing"
        self.createdAt = createdAt
        let finiteTimeout = approvalTimeoutSeconds.isFinite ? approvalTimeoutSeconds : 45
        self.approvalTimeoutSeconds = min(max(1, finiteTimeout), 120)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedApprovalTimeout = try container.decode(
            TimeInterval.self,
            forKey: .approvalTimeoutSeconds
        )
        guard decodedApprovalTimeout.isFinite,
              (1...120).contains(decodedApprovalTimeout) else {
            throw DecodingError.dataCorruptedError(
                forKey: .approvalTimeoutSeconds,
                in: container,
                debugDescription: "Remote-control approval timeout must be finite and within 1...120 seconds."
            )
        }
        let fields = DecodedFields(
            id: try container.decode(UUID.self, forKey: .id),
            sessionId: try container.decode(String.self, forKey: .sessionId),
            sessionEvidenceReference: try container.decodeIfPresent(
                String.self,
                forKey: .sessionEvidenceReference
            ),
            transportKind: try container.decode(
                RemoteControlTransportKind.self,
                forKey: .transportKind
            ),
            remoteIPAddress: try container.decodeIfPresent(String.self, forKey: .remoteIPAddress),
            remoteDeviceId: try container.decodeIfPresent(String.self, forKey: .remoteDeviceId),
            remoteDeviceName: try container.decodeIfPresent(String.self, forKey: .remoteDeviceName),
            remoteAccountDisplayName: try container.decodeIfPresent(
                String.self,
                forKey: .remoteAccountDisplayName
            ),
            remoteNebulaId: try container.decodeIfPresent(String.self, forKey: .remoteNebulaId),
            localAccountDisplayName: try container.decodeIfPresent(
                String.self,
                forKey: .localAccountDisplayName
            ),
            localNebulaId: try container.decodeIfPresent(String.self, forKey: .localNebulaId),
            cryptoSuite: try container.decode(String.self, forKey: .cryptoSuite),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            approvalTimeoutSeconds: decodedApprovalTimeout
        )
        do {
            try self.init(validating: fields)
        } catch let failure as ValidationFailure {
            throw DecodingError.dataCorruptedError(
                forKey: failure.field,
                in: container,
                debugDescription: "Remote-control security descriptor field \(failure.field.rawValue) must be non-empty, contain no control characters, and fit within \(failure.maximumLength) UTF-8 bytes."
            )
        }
    }

    public func updatingCryptoSuite(_ cryptoSuite: String) -> Self {
        .init(
            id: id,
            sessionId: sessionId,
            sessionEvidenceReference: sessionEvidenceReference,
            transportKind: transportKind,
            remoteIPAddress: remoteIPAddress,
            remoteDeviceId: remoteDeviceId,
            remoteDeviceName: remoteDeviceName,
            remoteAccountDisplayName: remoteAccountDisplayName,
            remoteNebulaId: remoteNebulaId,
            localAccountDisplayName: localAccountDisplayName,
            localNebulaId: localNebulaId,
            cryptoSuite: cryptoSuite,
            createdAt: createdAt,
            approvalTimeoutSeconds: approvalTimeoutSeconds
        )
    }

    public var missingRequiredNoticeMetadata: [String] {
        var missing: [String] = []
        if !Self.isPresentForNotice(sessionId) {
            missing.append("session_id")
        }
        if !Self.isPresentForNotice(remoteIPAddress) {
            missing.append("remote_ip")
        }
        if !Self.isPresentForNotice(remoteAccountDisplayName) {
            missing.append("remote_account")
        }
        if !Self.isPresentForNotice(remoteNebulaId) {
            missing.append("remote_nebula")
        }
        if !Self.isPresentForNotice(remoteDeviceId),
           !Self.isPresentForNotice(remoteDeviceName) {
            missing.append("remote_device")
        }
        if !Self.isConcreteQuantumSafeSuiteForNotice(cryptoSuite) {
            missing.append("crypto_suite")
        }
        return missing
    }

    private init(validating fields: DecodedFields) throws {
        id = fields.id
        guard let validatedSessionId = try Self.validated(
            fields.sessionId,
            field: .sessionId,
            maximumLength: 256
        ),
        let validatedCryptoSuite = try Self.validated(
            fields.cryptoSuite,
            field: .cryptoSuite,
            maximumLength: 64
        ) else {
            throw ValidationFailure(field: .sessionId, maximumLength: 256)
        }
        sessionId = validatedSessionId
        sessionEvidenceReference = fields.sessionEvidenceReference.flatMap {
            P2PEvidenceReference.isValid($0) ? $0 : nil
        }
        transportKind = fields.transportKind
        remoteIPAddress = try Self.validated(
            fields.remoteIPAddress,
            field: .remoteIPAddress,
            maximumLength: 256
        )
        remoteDeviceId = try Self.validated(
            fields.remoteDeviceId,
            field: .remoteDeviceId,
            maximumLength: 256
        )
        remoteDeviceName = try Self.validated(
            fields.remoteDeviceName,
            field: .remoteDeviceName,
            maximumLength: 128
        )
        remoteAccountDisplayName = try Self.validated(
            fields.remoteAccountDisplayName,
            field: .remoteAccountDisplayName,
            maximumLength: 320
        )
        remoteNebulaId = try Self.validated(
            fields.remoteNebulaId,
            field: .remoteNebulaId,
            maximumLength: 256
        )
        localAccountDisplayName = try Self.validated(
            fields.localAccountDisplayName,
            field: .localAccountDisplayName,
            maximumLength: 320
        )
        localNebulaId = try Self.validated(
            fields.localNebulaId,
            field: .localNebulaId,
            maximumLength: 256
        )
        cryptoSuite = validatedCryptoSuite
        createdAt = fields.createdAt
        approvalTimeoutSeconds = fields.approvalTimeoutSeconds
    }

    private static func validated(
        _ value: String?,
        field: CodingKeys,
        maximumLength: Int
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationFailure(field: field, maximumLength: maximumLength)
        }
        return trimmed
    }

    private static func normalized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func isPresentForNotice(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        return trimmed != "-" && trimmed.lowercased() != "missing"
    }

    private static func isConcreteQuantumSafeSuiteForNotice(_ value: String?) -> Bool {
        guard isPresentForNotice(value) else { return false }
        let rendered = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pqcSuffix = " PQC"
        let suiteToken = rendered.hasSuffix(pqcSuffix)
            ? String(rendered.dropLast(pqcSuffix.count))
            : rendered

        let suite: CryptoSuite?
        if suiteToken.hasPrefix("0x"), suiteToken.count == 6,
           let wireID = UInt16(suiteToken.dropFirst(2), radix: 16) {
            suite = CryptoSuite(wireId: wireID)
        } else {
            suite = CryptoSuite(rawValue: suiteToken)
        }
        return suite?.isKnown == true
            && suite?.isPQCGroup == true
            && suite?.isNegotiable == true
    }
}

public struct RemoteControlSecurityNotice: Identifiable, Codable, Sendable, Equatable {
    public let descriptor: RemoteControlSecurityDescriptor
    public let phase: RemoteControlSecurityNoticePhase
    public let approvedAt: Date?

    public var id: UUID { descriptor.id }

    public init(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase,
        approvedAt: Date? = nil
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.approvedAt = approvedAt
    }

    public func updatingPhase(
        _ phase: RemoteControlSecurityNoticePhase,
        approvedAt: Date? = nil
    ) -> Self {
        .init(
            descriptor: descriptor,
            phase: phase,
            approvedAt: approvedAt ?? self.approvedAt
        )
    }

    public func updatingDescriptor(_ descriptor: RemoteControlSecurityDescriptor) -> Self {
        .init(descriptor: descriptor, phase: phase, approvedAt: approvedAt)
    }
}

private final class RemoteControlSecurityIdentityStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteControlSecurityIdentity?

    func store(_ identity: RemoteControlSecurityIdentity?) {
        lock.lock()
        value = identity
        lock.unlock()
    }

    func snapshot() -> RemoteControlSecurityIdentity? {
        lock.lock()
        let identity = value
        lock.unlock()
        return identity
    }
}

private let remoteControlSecurityIdentityStorage = RemoteControlSecurityIdentityStorage()

final class RemoteControlSecurityPeerIdentityStorage: @unchecked Sendable {
    private enum BindingStrength: Int, Hashable {
        case weak
        case authenticatedPrimary
    }

    private struct Binding: Hashable {
        let primaryKey: String
        let epoch: UUID
        let strength: BindingStrength
    }

    private struct Record {
        let identity: RemoteControlSecurityIdentity
        let epoch: UUID
        let expiresAt: Date
        var lastAccessedAt: Date
        let aliases: Set<String>
    }

    private let lock = NSLock()
    private let timeToLive: TimeInterval
    private let maximumRecordCount: Int
    private let maximumAliasesPerRecord: Int
    private let now: @Sendable () -> Date
    private var recordsByPrimaryKey: [String: Record] = [:]
    private var bindingsByAlias: [String: Set<Binding>] = [:]

    init(
        timeToLive: TimeInterval = 10 * 60,
        maximumRecordCount: Int = 256,
        maximumAliasesPerRecord: Int = 32,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(timeToLive.isFinite && timeToLive > 0)
        precondition(maximumRecordCount > 0)
        precondition(maximumAliasesPerRecord > 0)
        self.timeToLive = timeToLive
        self.maximumRecordCount = maximumRecordCount
        self.maximumAliasesPerRecord = maximumAliasesPerRecord
        self.now = now
    }

    @discardableResult
    func record(
        identity: RemoteControlSecurityIdentity,
        aliases rawAliases: [String]
    ) -> Bool {
        guard !identity.isEmpty,
              let primary = Self.authenticatedPrimary(identity: identity, aliases: rawAliases) else {
            return false
        }
        let allAliases = Self.normalizedAliases(
            [identity.deviceId].compactMap { $0 }
                + rawAliases
                + [identity.deviceName].compactMap { $0 },
            maximumCount: maximumAliasesPerRecord
        )
        guard !allAliases.isEmpty else { return false }
        let primaryAliases = Set(
            Self.normalizedAliases(primary.sourceAliases, maximumCount: maximumAliasesPerRecord)
        )
        let currentTime = now()
        let epoch = UUID()

        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(at: currentTime)
        removeRecordLocked(primaryKey: primary.key)
        if recordsByPrimaryKey.count >= maximumRecordCount {
            evictLeastRecentlyUsedLocked()
        }

        let aliasSet = Set(allAliases)
        recordsByPrimaryKey[primary.key] = Record(
            identity: identity,
            epoch: epoch,
            expiresAt: currentTime.addingTimeInterval(timeToLive),
            lastAccessedAt: currentTime,
            aliases: aliasSet
        )
        for alias in aliasSet {
            let strength: BindingStrength = primaryAliases.contains(alias)
                ? .authenticatedPrimary
                : .weak
            bindingsByAlias[alias, default: []].insert(
                Binding(primaryKey: primary.key, epoch: epoch, strength: strength)
            )
        }
        return true
    }

    func identity(forAliases rawAliases: [String]) -> RemoteControlSecurityIdentity? {
        let aliases = Self.normalizedAliases(
            rawAliases,
            maximumCount: maximumAliasesPerRecord
        )
        guard !aliases.isEmpty else { return nil }
        let currentTime = now()

        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(at: currentTime)

        let liveBindings = aliases.flatMap { alias in
            bindingsByAlias[alias, default: []].filter(isLiveBindingLocked)
        }
        let strongPrimaryKeys = Set(
            liveBindings
                .filter { $0.strength == .authenticatedPrimary }
                .map(\.primaryKey)
        )
        let candidatePrimaryKeys = strongPrimaryKeys.isEmpty
            ? Set(liveBindings.map(\.primaryKey))
            : strongPrimaryKeys
        guard candidatePrimaryKeys.count == 1,
              let primaryKey = candidatePrimaryKeys.first,
              var record = recordsByPrimaryKey[primaryKey] else {
            return nil
        }
        record.lastAccessedAt = currentTime
        recordsByPrimaryKey[primaryKey] = record
        return record.identity
    }

    func clear(forAliases rawAliases: [String]) {
        let aliases = Self.normalizedAliases(
            rawAliases,
            maximumCount: maximumAliasesPerRecord
        )
        guard !aliases.isEmpty else { return }
        let currentTime = now()

        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(at: currentTime)
        let liveBindings = aliases.flatMap { alias in
            bindingsByAlias[alias, default: []].filter(isLiveBindingLocked)
        }
        let strongPrimaryKeys = Set(
            liveBindings
                .filter { $0.strength == .authenticatedPrimary }
                .map(\.primaryKey)
        )
        let candidatePrimaryKeys = strongPrimaryKeys.isEmpty
            ? Set(liveBindings.map(\.primaryKey))
            : strongPrimaryKeys
        guard candidatePrimaryKeys.count == 1,
              let primaryKey = candidatePrimaryKeys.first else {
            return
        }
        removeRecordLocked(primaryKey: primaryKey)
    }

    var recordCount: Int {
        let currentTime = now()
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(at: currentTime)
        return recordsByPrimaryKey.count
    }

    private func isLiveBindingLocked(_ binding: Binding) -> Bool {
        guard let record = recordsByPrimaryKey[binding.primaryKey] else { return false }
        return record.epoch == binding.epoch
    }

    private func pruneExpiredLocked(at currentTime: Date) {
        let expired = recordsByPrimaryKey.compactMap { primaryKey, record in
            record.expiresAt <= currentTime ? primaryKey : nil
        }
        for primaryKey in expired {
            removeRecordLocked(primaryKey: primaryKey)
        }
    }

    private func evictLeastRecentlyUsedLocked() {
        guard let primaryKey = recordsByPrimaryKey.min(by: { left, right in
            if left.value.lastAccessedAt == right.value.lastAccessedAt {
                return left.key < right.key
            }
            return left.value.lastAccessedAt < right.value.lastAccessedAt
        })?.key else {
            return
        }
        removeRecordLocked(primaryKey: primaryKey)
    }

    private func removeRecordLocked(primaryKey: String) {
        guard let record = recordsByPrimaryKey.removeValue(forKey: primaryKey) else { return }
        for alias in record.aliases {
            guard var bindings = bindingsByAlias[alias] else { continue }
            bindings = Set(bindings.filter { $0.primaryKey != primaryKey })
            if bindings.isEmpty {
                bindingsByAlias.removeValue(forKey: alias)
            } else {
                bindingsByAlias[alias] = bindings
            }
        }
    }

    private static func authenticatedPrimary(
        identity: RemoteControlSecurityIdentity,
        aliases: [String]
    ) -> (key: String, sourceAliases: [String])? {
        if let deviceID = normalizedStableDeviceID(identity.deviceId) {
            return (
                key: "device:\(deviceID)",
                sourceAliases: [deviceID, "id:\(deviceID)"]
            )
        }
        for alias in aliases {
            if let fingerprint = normalizedFingerprint(alias) {
                return (
                    key: "fingerprint:\(fingerprint)",
                    sourceAliases: [fingerprint, "fp:\(fingerprint)"]
                )
            }
        }
        return nil
    }

    private static func normalizedStableDeviceID(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("id:") {
            value = String(value.dropFirst(3))
        }
        guard (8...256).contains(value.count),
              !value.contains(where: \.isWhitespace),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-" || scalar == "_" || scalar == "."
                  )
              }),
              !isLiteralIPv4(value) else {
            return nil
        }
        return value
    }

    private static func normalizedFingerprint(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("fp:") {
            value = String(value.dropFirst(3))
        } else if value.hasPrefix("fingerprint:") {
            value = String(value.dropFirst("fingerprint:".count))
        } else {
            return nil
        }
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func isLiteralIPv4(_ raw: String) -> Bool {
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard let value = UInt8(component) else { return false }
            return String(value) == component || component == "0"
        }
    }

    private static func normalizedAliases(
        _ rawAliases: [String],
        maximumCount: Int
    ) -> [String] {
        var aliases: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw.count <= 512,
                  aliases.count < maximumCount,
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return
            }
            let normalized = raw.lowercased()
            guard seen.insert(normalized).inserted else { return }
            aliases.append(normalized)
        }

        func appendExpanded(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lowercased = trimmed.lowercased()
            append(lowercased)

            for prefix in ["host:", "peer:", "id:", "recent:"] {
                guard lowercased.hasPrefix(prefix) else { continue }
                append(String(lowercased.dropFirst(prefix.count)))
                return
            }

            append("host:\(lowercased)")
            append("peer:\(lowercased)")
            append("id:\(lowercased)")
        }

        for alias in rawAliases {
            appendExpanded(alias)
        }
        return aliases
    }
}

private let remoteControlSecurityPeerIdentityStorage = RemoteControlSecurityPeerIdentityStorage()

public enum RemoteControlSecurityPeerIdentityStore {
    public static func record(
        identity: RemoteControlSecurityIdentity,
        aliases: [String]
    ) {
        _ = remoteControlSecurityPeerIdentityStorage.record(identity: identity, aliases: aliases)
    }

    public static func identity(forAliases aliases: [String]) -> RemoteControlSecurityIdentity? {
        remoteControlSecurityPeerIdentityStorage.identity(forAliases: aliases)
    }

    public static func clear(forAliases aliases: [String]) {
        remoteControlSecurityPeerIdentityStorage.clear(forAliases: aliases)
    }
}

@MainActor
public enum RemoteControlSecurityNoticePresenter {
    public static func appName() -> String {
        LocalizationManager.shared.localizedString("remoteControl.securityNotice.appName")
    }

    public static func transportName(_ kind: RemoteControlTransportKind) -> String {
        LocalizationManager.shared.localizedString(kind.localizationKey)
    }

    public static func unavailableValue() -> String {
        LocalizationManager.shared.localizedString("remoteControl.securityNotice.valueUnavailable")
    }

    public static func maskedIdentity(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return unavailableValue()
        }
        let characterCount = trimmed.count
        if characterCount <= 4 {
            return String(trimmed.prefix(1)) + "***"
        }
        if characterCount <= 8 {
            return String(trimmed.prefix(2)) + "***" + String(trimmed.suffix(1))
        }
        return String(trimmed.prefix(3)) + "***" + String(trimmed.suffix(3))
    }

    public static func deviceIdentity(_ descriptor: RemoteControlSecurityDescriptor) -> String {
        if let name = descriptor.remoteDeviceName, let id = descriptor.remoteDeviceId {
            return "\(name) (\(maskedIdentity(id)))"
        }
        if let name = descriptor.remoteDeviceName {
            return name
        }
        return maskedIdentity(descriptor.remoteDeviceId)
    }
}

enum RemoteControlSecurityAdmissionPolicy {
    static func allowsInboundPayload(
        _ type: RemoteMessage.MessageType,
        isApproved: Bool
    ) -> Bool {
        guard !isApproved else { return true }
        switch type {
        case .streamConfiguration, .streamConfigurationAck, .screenData, .damageReport, .cursorUpdate, .overlayUpdate,
             .mouseEvent, .keyboardEvent, .clipboard:
            return false
        }
    }

    static func allowsInboundWebRTCPayload(
        _ type: RemoteMessageTypeWire,
        isApproved: Bool
    ) -> Bool {
        guard !isApproved else { return true }
        switch type {
        case .streamConfiguration, .streamConfigurationAck, .screenData, .damageReport, .cursorUpdate, .overlayUpdate,
             .mouseEvent, .keyboardEvent, .clipboard:
            return false
        }
    }
}

@MainActor
public final class RemoteControlSecurityNoticeCenter: ObservableObject {
    public static let shared = RemoteControlSecurityNoticeCenter()

    public typealias LocalIdentityProvider = @MainActor () -> RemoteControlSecurityIdentity?
    public typealias DisconnectHandler = @MainActor () -> Void

    @Published public private(set) var currentNotice: RemoteControlSecurityNotice?

    private var approvalContinuations: [UUID: CheckedContinuation<RemoteControlSecurityDecision, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var disconnectHandlers: [UUID: DisconnectHandler] = [:]
    private var localIdentityProvider: LocalIdentityProvider?

    init() {}

    public func setLocalIdentityProvider(_ provider: LocalIdentityProvider?) {
        localIdentityProvider = provider
    }

    public func localIdentitySnapshot() -> RemoteControlSecurityIdentity? {
        let identity = localIdentityProvider?()
        remoteControlSecurityIdentityStorage.store(identity)
        return identity
    }

    public nonisolated static func cachedLocalIdentitySnapshot() -> RemoteControlSecurityIdentity? {
        remoteControlSecurityIdentityStorage.snapshot()
    }

    public func setDisconnectHandler(
        for noticeId: UUID,
        handler: @escaping DisconnectHandler
    ) {
        disconnectHandlers[noticeId] = handler
    }

#if DEBUG || SKYBRIDGE_TESTING
    var disconnectHandlerCountForTesting: Int {
        disconnectHandlers.count
    }
#endif

    public func recordPanelPresentedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase,
        frame: String,
        visibleFrame: String,
        windowLevel: String,
        collectionBehavior: [String],
        buttons: [String],
        topCentered: Bool
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticePanelPresented session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            phase=\(phase.rawValue) \
            frame=\(Self.statusValue(frame)) \
            visibleFrame=\(Self.statusValue(visibleFrame)) \
            level=\(Self.statusValue(windowLevel)) \
            collectionBehavior=\(Self.statusValue(collectionBehavior.joined(separator: ","))) \
            topCentered=\(topCentered ? "1" : "0") \
            buttons=\(Self.statusValue(buttons.joined(separator: ",")))
            """
        )
    }

    public func recordPanelHiddenEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticePanelHidden session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            phase=\(phase.rawValue)
            """
        )
    }

    public func requestApproval(
        _ descriptor: RemoteControlSecurityDescriptor
    ) async -> RemoteControlSecurityDecision {
        if let notice = currentNotice, notice.phase == .active {
            if notice.descriptor.sessionId == descriptor.sessionId,
               notice.descriptor.transportKind == descriptor.transportKind {
                guard Self.securityIdentityMatches(
                    notice.descriptor,
                    descriptor
                ) else {
                    appendIdentityMutationRejectedEvidence(
                        descriptor: descriptor,
                        activeDescriptor: notice.descriptor
                    )
                    cleanupIncomingNoticeState(
                        id: descriptor.id,
                        preservingActiveNoticeId: notice.id
                    )
                    disconnectCurrentNotice()
                    return .rejected
                }
                guard !descriptor.missingRequiredNoticeMetadata.contains("crypto_suite") else {
                    appendInvalidCryptoUpdateEvidence(descriptor: descriptor)
                    cleanupIncomingNoticeState(
                        id: descriptor.id,
                        preservingActiveNoticeId: notice.id
                    )
                    disconnectCurrentNotice()
                    return .rejected
                }
                updateCryptoSuite(
                    descriptor.cryptoSuite,
                    sessionId: descriptor.sessionId,
                    transportKind: descriptor.transportKind
                )
                cleanupIncomingNoticeState(
                    id: descriptor.id,
                    preservingActiveNoticeId: notice.id
                )
                return .approved
            }

            appendConcurrentRequestRejectedEvidence(
                descriptor: descriptor,
                activeDescriptor: notice.descriptor
            )
            clearPeerIdentity(for: descriptor)
            cleanupIncomingNoticeState(
                id: descriptor.id,
                preservingActiveNoticeId: notice.id
            )
            return .rejected
        }

        let missingMetadata = descriptor.missingRequiredNoticeMetadata
        guard missingMetadata.isEmpty else {
            appendMissingMetadataRejectedEvidence(
                descriptor: descriptor,
                missingMetadata: missingMetadata
            )
            clearPeerIdentity(for: descriptor)
            cleanupNoticeState(id: descriptor.id)
            return .rejected
        }

        rejectPendingNoticeIfNeeded()

        let notice = RemoteControlSecurityNotice(
            descriptor: descriptor,
            phase: .awaitingApproval
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    cleanupNoticeState(id: descriptor.id)
                    continuation.resume(returning: .disconnected)
                    return
                }
                approvalContinuations[descriptor.id] = continuation
                timeoutTasks[descriptor.id] = Task { @MainActor [weak self] in
                    let nanoseconds = UInt64(descriptor.approvalTimeoutSeconds * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.resolvePendingNotice(
                        id: descriptor.id,
                        decision: .timedOut
                    )
                }
                currentNotice = notice
                appendEvidence(event: "Shown", descriptor: descriptor)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.approvalContinuations[descriptor.id] != nil else { return }
                self.resolvePendingNotice(
                    id: descriptor.id,
                    decision: .disconnected
                )
            }
        }
    }

    public func approveCurrentNotice() {
        guard let notice = currentNotice, notice.phase == .awaitingApproval else { return }
        currentNotice = notice.updatingPhase(.active, approvedAt: Date())
        appendEvidence(event: "Approved", descriptor: notice.descriptor)
        appendEvidence(event: "Active", descriptor: notice.descriptor)
        resolveContinuation(id: notice.id, decision: .approved)
    }

    /// Approval entry point reserved for the real user-facing panel action.
    ///
    /// Programmatic smoke helpers continue to use `approveCurrentNotice()` and therefore cannot
    /// manufacture the `HumanApproved` evidence required by release acceptance.
    private func approveCurrentNoticeFromUserInteraction() {
        guard let notice = currentNotice, notice.phase == .awaitingApproval else { return }
        appendEvidence(event: "HumanApproved", descriptor: notice.descriptor)
        approveCurrentNotice()
    }

    public func approveNotice(id: UUID) {
        guard currentNotice?.id == id else { return }
        approveCurrentNotice()
    }

    @_spi(RemoteControlSecurityNoticeUI)
    public func approveNoticeFromUserInteraction(id: UUID) {
        guard currentNotice?.id == id else { return }
        approveCurrentNoticeFromUserInteraction()
    }

    public func rejectCurrentNotice() {
        guard let notice = currentNotice else { return }
        resolvePendingNotice(id: notice.id, decision: .rejected)
    }

    public func rejectNotice(id: UUID) {
        guard currentNotice?.id == id else { return }
        rejectCurrentNotice()
    }

    public func closeCurrentNoticeFailClosed() {
        guard let notice = currentNotice else { return }
        switch notice.phase {
        case .awaitingApproval:
            resolvePendingNotice(id: notice.id, decision: .rejected)
        case .active:
            disconnectCurrentNotice()
        }
    }

    public func closeNoticeFailClosed(id: UUID) {
        guard currentNotice?.id == id else { return }
        closeCurrentNoticeFailClosed()
    }

    public func disconnectCurrentNotice() {
        guard let notice = currentNotice else { return }
        let handler = notice.phase == .active ? disconnectHandlers[notice.id] : nil
        appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
        currentNotice = nil
        clearPeerIdentity(for: notice.descriptor)
        if notice.phase == .awaitingApproval {
            resolveContinuation(id: notice.id, decision: .disconnected)
            cleanupNoticeState(id: notice.id)
            return
        }
        cleanupNoticeState(id: notice.id)
        handler?()
    }

    public func disconnectNotice(id: UUID) {
        guard currentNotice?.id == id else { return }
        disconnectCurrentNotice()
    }

    public func endNotice(
        sessionId: String,
        transportKind: RemoteControlTransportKind
    ) {
        guard let notice = currentNotice,
              notice.descriptor.sessionId == sessionId,
              notice.descriptor.transportKind == transportKind else {
            return
        }
        if notice.phase == .awaitingApproval {
            resolvePendingNotice(id: notice.id, decision: .disconnected)
        } else {
            appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
            currentNotice = nil
            clearPeerIdentity(for: notice.descriptor)
            cleanupNoticeState(id: notice.id)
        }
    }

    public func updateCryptoSuite(
        _ cryptoSuite: String,
        sessionId: String,
        transportKind: RemoteControlTransportKind
    ) {
        guard let notice = currentNotice,
              notice.descriptor.sessionId == sessionId,
              notice.descriptor.transportKind == transportKind else {
            return
        }
        let descriptor = notice.descriptor.updatingCryptoSuite(cryptoSuite)
        guard !descriptor.missingRequiredNoticeMetadata.contains("crypto_suite") else {
            appendInvalidCryptoUpdateEvidence(descriptor: descriptor)
            disconnectCurrentNotice()
            return
        }
        currentNotice = notice.updatingDescriptor(descriptor)
        appendEvidence(event: "CryptoUpdated", descriptor: descriptor)
    }

    private func rejectPendingNoticeIfNeeded() {
        guard let notice = currentNotice, notice.phase == .awaitingApproval else { return }
        resolvePendingNotice(id: notice.id, decision: .disconnected)
    }

    private func resolvePendingNotice(
        id: UUID,
        decision: RemoteControlSecurityDecision
    ) {
        guard let notice = currentNotice, notice.id == id else {
            resolveContinuation(id: id, decision: decision)
            cleanupNoticeState(id: id)
            return
        }

        switch decision {
        case .approved:
            currentNotice = notice.updatingPhase(.active, approvedAt: Date())
            appendEvidence(event: "Approved", descriptor: notice.descriptor)
            appendEvidence(event: "Active", descriptor: notice.descriptor)
        case .rejected:
            appendEvidence(event: "Rejected", descriptor: notice.descriptor)
            clearPeerIdentity(for: notice.descriptor)
            currentNotice = nil
        case .timedOut:
            appendEvidence(event: "TimedOut", descriptor: notice.descriptor)
            clearPeerIdentity(for: notice.descriptor)
            currentNotice = nil
        case .disconnected:
            appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
            clearPeerIdentity(for: notice.descriptor)
            currentNotice = nil
        }

        resolveContinuation(id: id, decision: decision)
        if decision != .approved {
            cleanupNoticeState(id: id)
        }
    }

    private func resolveContinuation(
        id: UUID,
        decision: RemoteControlSecurityDecision
    ) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        approvalContinuations.removeValue(forKey: id)?.resume(returning: decision)
    }

    private func cleanupNoticeState(id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        approvalContinuations.removeValue(forKey: id)
        disconnectHandlers.removeValue(forKey: id)
    }

    private func cleanupIncomingNoticeState(
        id: UUID,
        preservingActiveNoticeId: UUID
    ) {
        guard id != preservingActiveNoticeId else { return }
        cleanupNoticeState(id: id)
    }

    private func appendEvidence(
        event: String,
        descriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNotice\(event) session=\(Self.statusValue(descriptor.sessionId)) \
            session_ref=\(descriptor.sessionEvidenceReference ?? "-") \
            transport=\(descriptor.transportKind.evidenceValue) \
            remoteIP=\(Self.statusValue(descriptor.remoteIPAddress)) \
            remoteDeviceId=\(Self.statusValue(descriptor.remoteDeviceId)) \
            remoteAccount=\(Self.maskedStatusValue(descriptor.remoteAccountDisplayName)) \
            remoteNebula=\(Self.maskedStatusValue(descriptor.remoteNebulaId)) \
            localAccount=\(Self.maskedStatusValue(descriptor.localAccountDisplayName)) \
            localNebula=\(Self.maskedStatusValue(descriptor.localNebulaId)) \
            device=\(Self.statusValue(descriptor.remoteDeviceName ?? descriptor.remoteDeviceId)) \
            cryptoSuite=\(Self.statusValue(descriptor.cryptoSuite))
            """
        )
    }

    private func appendConcurrentRequestRejectedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        activeDescriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeConcurrentRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            activeSession=\(Self.statusValue(activeDescriptor.sessionId)) \
            activeTransport=\(activeDescriptor.transportKind.evidenceValue) \
            reason=active_notice_already_visible
            """
        )
    }

    private func appendIdentityMutationRejectedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        activeDescriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeIdentityMutationRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            activeNotice=\(activeDescriptor.id.uuidString) \
            reason=security_identity_changed
            """
        )
    }

    private func appendInvalidCryptoUpdateEvidence(
        descriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeCryptoUpdateRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            reason=invalid_or_non_pqc_suite
            """
        )
    }

    private func appendMissingMetadataRejectedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        missingMetadata: [String]
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            reason=missing_required_notice_metadata \
            missing=\(Self.statusValue(missingMetadata.joined(separator: ",")))
            """
        )
    }

    private func clearPeerIdentity(for descriptor: RemoteControlSecurityDescriptor) {
        RemoteControlSecurityPeerIdentityStore.clear(
            forAliases: [
                descriptor.remoteDeviceId,
                descriptor.sessionId,
                descriptor.remoteIPAddress,
                descriptor.remoteDeviceName
            ].compactMap { $0 }
        )
    }

    private static func securityIdentityMatches(
        _ active: RemoteControlSecurityDescriptor,
        _ candidate: RemoteControlSecurityDescriptor
    ) -> Bool {
        active.remoteIPAddress == candidate.remoteIPAddress
            && active.remoteDeviceId == candidate.remoteDeviceId
            && active.remoteDeviceName == candidate.remoteDeviceName
            && active.remoteAccountDisplayName == candidate.remoteAccountDisplayName
            && active.remoteNebulaId == candidate.remoteNebulaId
            && active.localAccountDisplayName == candidate.localAccountDisplayName
            && active.localNebulaId == candidate.localNebulaId
    }

    private static func statusValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "missing"
        }
        return value
            .map { character in
                if character.isWhitespace || character == "|" || character == "\"" {
                    return "_"
                }
                return character
            }
            .reduce(into: "") { result, character in
                result.append(character)
            }
    }

    private static func maskedStatusValue(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return "missing"
        }
        let characterCount = trimmed.count
        let masked: String
        if characterCount <= 4 {
            masked = String(trimmed.prefix(1)) + "***"
        } else if characterCount <= 8 {
            masked = String(trimmed.prefix(2)) + "***" + String(trimmed.suffix(1))
        } else {
            masked = String(trimmed.prefix(3)) + "***" + String(trimmed.suffix(3))
        }
        return statusValue(masked)
    }
}
