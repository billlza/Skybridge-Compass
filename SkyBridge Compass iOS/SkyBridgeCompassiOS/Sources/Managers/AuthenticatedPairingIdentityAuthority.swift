import CryptoKit
import Darwin
import Foundation

@available(iOS 17.0, *)
struct ValidatedPairingIdentityAuthority: Sendable, Equatable {
  let declaredDeviceId: String
  let authorizedDeviceIds: [String]
  let protocolSigningAlgorithm: ProtocolSigningAlgorithm
  let protocolPublicKeyFingerprint: String
  let protocolPublicKey: Data

  fileprivate init(
    declaredDeviceId: String,
    authorizedDeviceIds: [String],
    protocolSigningAlgorithm: ProtocolSigningAlgorithm,
    protocolPublicKeyFingerprint: String,
    protocolPublicKey: Data
  ) {
    self.declaredDeviceId = declaredDeviceId
    self.authorizedDeviceIds = authorizedDeviceIds
    self.protocolSigningAlgorithm = protocolSigningAlgorithm
    self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
    self.protocolPublicKey = protocolPublicKey
  }
}

@available(iOS 17.0, *)
struct PIBOperatorApprovalReceipt: Sendable, Equatable {
  let declaredDeviceId: String
  let protocolSigningAlgorithm: ProtocolSigningAlgorithm
  let protocolPublicKeyFingerprint: String
  let protocolPublicKey: Data
  let pinSource: String
}

/// Explicit current-path authority established by a verified QR/connection-code
/// admission. Unlike SOA, this does not claim that the handshake carried a
/// stable device identifier; it is a separate typed proof whose key and device
/// ID must both match the authenticated handshake and pairing payload exactly.
@available(iOS 17.0, *)
struct CurrentPathOperatorApprovalReceipt: Sendable, Equatable {
  let declaredDeviceId: String
  let protocolSigningAlgorithm: ProtocolSigningAlgorithm
  let protocolPublicKeyFingerprint: String
  let protocolPublicKey: Data
}

@available(iOS 17.0, *)
enum PairingIdentityAuthorityValidationError: Error, LocalizedError, Sendable, Equatable {
  case invalidPayload
  case missingSessionAuthority
  case invalidAuthenticatedAuthority
  case payloadAuthorityMismatch
  case soaDeviceIdentifierMismatch
  case missingExactOperatorApproval

  var errorDescription: String? {
    switch self {
    case .invalidPayload:
      return "无效的配对身份交换载荷"
    case .missingSessionAuthority:
      return "当前认证会话没有配对身份 authority"
    case .invalidAuthenticatedAuthority:
      return "当前认证会话的协议身份 authority 无效"
    case .payloadAuthorityMismatch:
      return "配对身份载荷与当前认证协议身份不一致"
    case .soaDeviceIdentifierMismatch:
      return "配对身份设备标识与当前认证 SOA 身份不一致"
    case .missingExactOperatorApproval:
      return "非 SOA 会话缺少该设备标识的有效 PIB-1 人工批准"
    }
  }
}

/// Issues the capability required by every pairing-identity mutation. Neither
/// payload metadata nor transport aliases can construct this token.
@available(iOS 17.0, *)
enum AuthenticatedPairingIdentityAuthorityValidator {
  static let pibOperatorApprovalPinSource = "pib-1-operator-approval"

  static func issue(
    payload: AppMessage.PairingIdentityExchangePayload,
    sessionBinding: AuthenticatedHandshakePeerBinding?,
    sessionDeviceIds: [String],
    operatorApproval: PIBOperatorApprovalReceipt?,
    currentPathApproval: CurrentPathOperatorApprovalReceipt? = nil
  ) throws -> ValidatedPairingIdentityAuthority {
    guard let payload = payload.normalizedBootstrapPayload else {
      throw PairingIdentityAuthorityValidationError.invalidPayload
    }
    guard let sessionBinding else {
      throw PairingIdentityAuthorityValidationError.missingSessionAuthority
    }

    let authority = sessionBinding.authority
    guard
      let algorithm = ProtocolSigningAlgorithm(
        rawValue: authority.protocolSigningAlgorithm.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
      ),
      let authorityPublicKey = authority.protocolPublicKeyBytes,
      !authorityPublicKey.isEmpty
    else {
      throw PairingIdentityAuthorityValidationError.invalidAuthenticatedAuthority
    }

    let authorityFingerprint = authority.protocolPublicKeyFingerprint
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let computedAuthorityFingerprint = ProtocolIdentityPublicKeys(
      protocolPublicKey: authorityPublicKey,
      protocolAlgorithm: algorithm
    ).authoritativeFingerprint.lowercased()
    guard authorityFingerprint.count == 64,
      authorityFingerprint.allSatisfy(\.isHexDigit),
      authorityFingerprint == computedAuthorityFingerprint
    else {
      throw PairingIdentityAuthorityValidationError.invalidAuthenticatedAuthority
    }

    guard
      let payloadKey = (payload.protocolIdentityPublicKeys ?? []).first(where: { candidate in
        candidate.normalizedAlgorithm == algorithm
          && candidate.publicKey == authorityPublicKey
          && candidate.authoritativeFingerprint?.lowercased() == authorityFingerprint
      })
    else {
      throw PairingIdentityAuthorityValidationError.payloadAuthorityMismatch
    }

    let declaredDeviceId = payload.deviceId
    guard isValidDeviceId(declaredDeviceId),
      let persistentDeclaredDeviceId = PeerIdentityAliasResolver.authorityBoundPersistentDeviceId(
        from: declaredDeviceId
      )
    else {
      throw PairingIdentityAuthorityValidationError.invalidPayload
    }

    let authorizedDeviceIds: [String]
    if let authenticatedRemoteSOAPeerId = sessionBinding.authenticatedRemoteSOAPeerId {
      guard authenticatedRemoteSOAPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength,
        authenticatedRemoteSOAPeerId == PeerSessionArbiter.soaPeerId(from: declaredDeviceId)
      else {
        throw PairingIdentityAuthorityValidationError.soaDeviceIdentifierMismatch
      }
      authorizedDeviceIds = deviceIdsBoundToSOA(
        declaredDeviceId: declaredDeviceId,
        sessionDeviceIds: sessionDeviceIds,
        authenticatedRemoteSOAPeerId: authenticatedRemoteSOAPeerId
      )
    } else {
      guard isExactPIBOperatorApproval(
        operatorApproval,
        declaredDeviceId: declaredDeviceId,
        algorithm: algorithm,
        authorityFingerprint: authorityFingerprint,
        authorityPublicKey: authorityPublicKey
      ) || isExactCurrentPathApproval(
        currentPathApproval,
        declaredDeviceId: declaredDeviceId,
        algorithm: algorithm,
        authorityFingerprint: authorityFingerprint,
        authorityPublicKey: authorityPublicKey
      )
      else {
        throw PairingIdentityAuthorityValidationError.missingExactOperatorApproval
      }
      authorizedDeviceIds = [persistentDeclaredDeviceId]
    }

    return ValidatedPairingIdentityAuthority(
      declaredDeviceId: persistentDeclaredDeviceId,
      authorizedDeviceIds: authorizedDeviceIds,
      protocolSigningAlgorithm: algorithm,
      protocolPublicKeyFingerprint: authorityFingerprint,
      protocolPublicKey: payloadKey.publicKey
    )
  }

  /// Testable admission boundary: mutation is not invoked until a capability
  /// token has been issued. Production uses the same helper for all writes.
  @MainActor
  static func performAuthorizedMutation<Result>(
    payload: AppMessage.PairingIdentityExchangePayload,
    sessionBinding: AuthenticatedHandshakePeerBinding?,
    sessionDeviceIds: [String],
    operatorApproval: PIBOperatorApprovalReceipt?,
    currentPathApproval: CurrentPathOperatorApprovalReceipt? = nil,
    mutation: (AppMessage.PairingIdentityExchangePayload, ValidatedPairingIdentityAuthority)
      async throws -> Result
  ) async throws -> Result {
    let normalizedPayload = payload.normalizedBootstrapPayload
    guard let normalizedPayload else {
      throw PairingIdentityAuthorityValidationError.invalidPayload
    }
    let token = try issue(
      payload: normalizedPayload,
      sessionBinding: sessionBinding,
      sessionDeviceIds: sessionDeviceIds,
      operatorApproval: operatorApproval,
      currentPathApproval: currentPathApproval
    )
    return try await mutation(normalizedPayload, token)
  }

  private static func isValidDeviceId(_ raw: String) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0)
    }
  }

  private static func deviceIdsBoundToSOA(
    declaredDeviceId: String,
    sessionDeviceIds: [String],
    authenticatedRemoteSOAPeerId: Data
  ) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in [declaredDeviceId] + sessionDeviceIds {
      let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard isValidDeviceId(candidate),
        let persistentDeviceId = PeerIdentityAliasResolver.authorityBoundPersistentDeviceId(
          from: candidate
        ),
        PeerSessionArbiter.soaPeerId(from: candidate) == authenticatedRemoteSOAPeerId
      else {
        continue
      }
      let dedupeKey = persistentDeviceId.lowercased()
      if seen.insert(dedupeKey).inserted {
        result.append(persistentDeviceId)
      }
    }
    return result
  }

  private static func isExactPIBOperatorApproval(
    _ approval: PIBOperatorApprovalReceipt?,
    declaredDeviceId: String,
    algorithm: ProtocolSigningAlgorithm,
    authorityFingerprint: String,
    authorityPublicKey: Data
  ) -> Bool {
    guard let approval else { return false }
    return approval.declaredDeviceId == declaredDeviceId
      && approval.pinSource == pibOperatorApprovalPinSource
      && approval.protocolSigningAlgorithm == algorithm
      && approval.protocolPublicKeyFingerprint.lowercased() == authorityFingerprint
      && approval.protocolPublicKey == authorityPublicKey
  }

  private static func isExactCurrentPathApproval(
    _ approval: CurrentPathOperatorApprovalReceipt?,
    declaredDeviceId: String,
    algorithm: ProtocolSigningAlgorithm,
    authorityFingerprint: String,
    authorityPublicKey: Data
  ) -> Bool {
    guard let approval else { return false }
    return approval.declaredDeviceId == declaredDeviceId
      && approval.protocolSigningAlgorithm == algorithm
      && approval.protocolPublicKeyFingerprint.lowercased() == authorityFingerprint
      && approval.protocolPublicKey == authorityPublicKey
  }

}

@available(iOS 17.0, *)
struct AuthorityBoundPairingIdentityJournal: Codable, Sendable, Equatable {
  static let currentSchemaVersion = 3
  static let legacySnapshotSchemaVersion = 2

  enum Intent: String, Codable, Sendable {
    case commit
    case rollback
  }

  enum Phase: String, Codable, Sendable {
    case prepared
    case applying
    case committed
  }

  let schemaVersion: Int
  let transactionID: UUID
  let intent: Intent
  let authorizedDeviceIDs: [String]
  let protocolFingerprint: String
  /// Schema-v2 whole-store images. Version 3 deliberately does not require
  /// them for rollback, but keeps the fields decodable so an interrupted v2
  /// transaction can be recovered after an app update.
  let kemBefore: KEMTrustStore.AuthorityBoundSnapshot?
  let kemAfter: KEMTrustStore.AuthorityBoundSnapshot?
  let protocolBefore: ProtocolIdentityTrustStore.AuthorityBoundSnapshot?
  let protocolAfterEachMutation: [ProtocolIdentityTrustStore.AuthorityBoundSnapshot]?
  /// Schema-v3 record-level CAS evidence. An older app cannot interpret these
  /// receipts and rejects schema 3 while leaving the journal quarantined.
  let kemMutationReceipt: KEMTrustStore.AuthorityBoundMutationReceipt?
  let protocolMutationReceipts: [ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt]?
  var phase: Phase
  var kemApplied: Bool
  var appliedProtocolMutationCount: Int
  var kemRolledBack: Bool?
  var rolledBackProtocolMutationCount: Int?

  init(
    schemaVersion: Int,
    transactionID: UUID,
    intent: Intent,
    authorizedDeviceIDs: [String],
    protocolFingerprint: String,
    kemBefore: KEMTrustStore.AuthorityBoundSnapshot? = nil,
    kemAfter: KEMTrustStore.AuthorityBoundSnapshot? = nil,
    protocolBefore: ProtocolIdentityTrustStore.AuthorityBoundSnapshot? = nil,
    protocolAfterEachMutation: [ProtocolIdentityTrustStore.AuthorityBoundSnapshot]? = nil,
    kemMutationReceipt: KEMTrustStore.AuthorityBoundMutationReceipt? = nil,
    protocolMutationReceipts: [ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt]? = nil,
    phase: Phase,
    kemApplied: Bool,
    appliedProtocolMutationCount: Int,
    kemRolledBack: Bool? = nil,
    rolledBackProtocolMutationCount: Int? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.transactionID = transactionID
    self.intent = intent
    self.authorizedDeviceIDs = authorizedDeviceIDs
    self.protocolFingerprint = protocolFingerprint
    self.kemBefore = kemBefore
    self.kemAfter = kemAfter
    self.protocolBefore = protocolBefore
    self.protocolAfterEachMutation = protocolAfterEachMutation
    self.kemMutationReceipt = kemMutationReceipt
    self.protocolMutationReceipts = protocolMutationReceipts
    self.phase = phase
    self.kemApplied = kemApplied
    self.appliedProtocolMutationCount = appliedProtocolMutationCount
    self.kemRolledBack = kemRolledBack
    self.rolledBackProtocolMutationCount = rolledBackProtocolMutationCount
  }
}

@available(iOS 17.0, *)
enum AuthorityBoundPairingIdentityJournalStoreError: Error, LocalizedError, Sendable {
  case applicationSupportUnavailable
  case encodingFailed(String)
  case decodingFailed(String)
  case unsupportedSchemaVersion(Int)
  case payloadTooLarge(Int)
  case writeFailed(String)
  case writeVerificationFailed
  case transactionMismatch
  case removalVerificationFailed

  var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      return "Application Support is unavailable for the pairing identity journal"
    case .encodingFailed(let reason):
      return "Pairing identity journal encoding failed: \(reason)"
    case .decodingFailed(let reason):
      return "Pairing identity journal decoding failed: \(reason)"
    case .unsupportedSchemaVersion(let version):
      return "Unsupported pairing identity journal schema version: \(version)"
    case .payloadTooLarge(let byteCount):
      return "Pairing identity journal exceeds the 16 MiB limit: \(byteCount) bytes"
    case .writeFailed(let reason):
      return "Pairing identity journal protected atomic write failed: \(reason)"
    case .writeVerificationFailed:
      return "Pairing identity journal write could not be verified"
    case .transactionMismatch:
      return "Pairing identity journal transaction changed before removal"
    case .removalVerificationFailed:
      return "Pairing identity journal removal could not be verified"
    }
  }
}

/// Durable write-ahead record shared by the KEM and protocol-identity stores.
/// The file is atomically replaced and receives complete iOS data protection.
@available(iOS 17.0, *)
struct AuthorityBoundPairingIdentityJournalStore: Sendable {
  private static let maximumPayloadBytes = 16 * 1_024 * 1_024
  let journalURL: URL

  static func defaultStore() throws -> Self {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw AuthorityBoundPairingIdentityJournalStoreError.applicationSupportUnavailable
    }
    return Self(
      journalURL: applicationSupport
        .appendingPathComponent("SkyBridge", isDirectory: true)
        .appendingPathComponent("authority-bound-pairing-identity.v1.journal")
    )
  }

  /// A location-resolution failure is itself a quarantine condition. Trust
  /// must never become readable merely because the journal cannot be checked.
  static func defaultJournalExists() -> Bool {
    guard let store = try? defaultStore() else { return true }
    return store.journalExists
  }

  var journalExists: Bool {
    FileManager.default.fileExists(atPath: journalURL.path)
  }

  func load() throws -> AuthorityBoundPairingIdentityJournal? {
    guard let data = try loadProtectedData() else { return nil }
    let journal: AuthorityBoundPairingIdentityJournal
    do {
      journal = try JSONDecoder().decode(
        AuthorityBoundPairingIdentityJournal.self,
        from: data
      )
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.decodingFailed(
        error.localizedDescription
      )
    }
    guard [
      AuthorityBoundPairingIdentityJournal.legacySnapshotSchemaVersion,
      AuthorityBoundPairingIdentityJournal.currentSchemaVersion,
    ].contains(journal.schemaVersion) else {
      throw AuthorityBoundPairingIdentityJournalStoreError.unsupportedSchemaVersion(
        journal.schemaVersion
      )
    }
    return journal
  }

  func loadProtectedData() throws -> Data? {
    guard journalExists else { return nil }
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.decodingFailed(
        error.localizedDescription
      )
    }
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
    guard byteCount <= Self.maximumPayloadBytes else {
      throw AuthorityBoundPairingIdentityJournalStoreError.payloadTooLarge(byteCount)
    }
    let data: Data
    do {
      data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.decodingFailed(
        error.localizedDescription
      )
    }
    guard data.count <= Self.maximumPayloadBytes else {
      throw AuthorityBoundPairingIdentityJournalStoreError.payloadTooLarge(data.count)
    }
    return data
  }

  func write(_ journal: AuthorityBoundPairingIdentityJournal) throws {
    let isUpdate = journalExists
    if isUpdate {
      guard let existing = try load(), existing.transactionID == journal.transactionID else {
        throw AuthorityBoundPairingIdentityJournalStoreError.transactionMismatch
      }
    }
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(journal)
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.encodingFailed(
        error.localizedDescription
      )
    }
    guard data.count <= Self.maximumPayloadBytes else {
      throw AuthorityBoundPairingIdentityJournalStoreError.payloadTooLarge(data.count)
    }

    try installProtectedData(data, replacingExistingJournal: isUpdate)

    guard (try? Data(contentsOf: journalURL)) == data else {
      throw AuthorityBoundPairingIdentityJournalStoreError.writeVerificationFailed
    }
  }

  func remove(expectedTransactionID: UUID) throws {
    guard let current = try load(), current.transactionID == expectedTransactionID else {
      throw AuthorityBoundPairingIdentityJournalStoreError.transactionMismatch
    }
    try removeProtectedData()
  }

  func installProtectedData(
    _ data: Data,
    replacingExistingJournal: Bool
  ) throws {
    let fileManager = FileManager.default
    let parentURL = journalURL.deletingLastPathComponent()
    let temporaryURL = parentURL.appendingPathComponent(
      ".\(journalURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    var temporaryFileExists = false
    defer {
      if temporaryFileExists {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    do {
      try fileManager.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete]
      )
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: parentURL.path
      )
      try data.write(
        to: temporaryURL,
        options: [.completeFileProtection, .withoutOverwriting]
      )
      temporaryFileExists = true
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: temporaryURL.path
      )
      let handle = try FileHandle(forWritingTo: temporaryURL)
      do {
        try handle.synchronize()
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      guard (try Data(contentsOf: temporaryURL)) == data else {
        throw AuthorityBoundPairingIdentityJournalStoreError.writeVerificationFailed
      }

      if replacingExistingJournal {
        guard rename(temporaryURL.path, journalURL.path) == 0 else {
          throw AuthorityBoundPairingIdentityJournalStoreError.writeFailed(
            Self.posixFailure("atomic rename")
          )
        }
        temporaryFileExists = false
      } else {
        do {
          try fileManager.linkItem(at: temporaryURL, to: journalURL)
        } catch {
          if journalExists {
            throw AuthorityBoundPairingIdentityJournalStoreError.transactionMismatch
          }
          throw error
        }
        try fileManager.removeItem(at: temporaryURL)
        temporaryFileExists = false
      }
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: journalURL.path
      )
      try synchronizeDirectory(parentURL)
    } catch let error as AuthorityBoundPairingIdentityJournalStoreError {
      throw error
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.writeFailed(
        error.localizedDescription
      )
    }
  }

  func removeProtectedData() throws {
    do {
      try FileManager.default.removeItem(at: journalURL)
    } catch {
      throw AuthorityBoundPairingIdentityJournalStoreError.removalVerificationFailed
    }
    guard !journalExists else {
      throw AuthorityBoundPairingIdentityJournalStoreError.removalVerificationFailed
    }
    try synchronizeDirectory(journalURL.deletingLastPathComponent())
  }

  private func synchronizeDirectory(_ directoryURL: URL) throws {
    let descriptor = open(directoryURL.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw AuthorityBoundPairingIdentityJournalStoreError.writeFailed(
        Self.posixFailure("open parent directory")
      )
    }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw AuthorityBoundPairingIdentityJournalStoreError.writeFailed(
        Self.posixFailure("fsync parent directory")
      )
    }
  }

  private static func posixFailure(_ operation: String) -> String {
    "\(operation) failed with errno \(errno)"
  }
}

@available(iOS 17.0, *)
struct AuthorityBoundPairingIdentityPersistenceReceipt: Codable, Sendable, Equatable {
  fileprivate let authorizedDeviceIDs: [String]
  fileprivate let protocolFingerprint: String
  fileprivate let kemMutationReceipt: KEMTrustStore.AuthorityBoundMutationReceipt
  fileprivate let protocolMutationReceipts:
    [ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt]
}

@available(iOS 17.0, *)
struct PairingPolicySnapshot: Codable, Sendable, Equatable {
  let valuesByAuthorityID: [String: String]
}

@available(iOS 17.0, *)
struct PreparedPairingPolicyMutation: Sendable {
  let before: PairingPolicySnapshot
  let after: PairingPolicySnapshot
}

@available(iOS 17.0, *)
struct PairingIdentityAuthorityMutationPermit: Sendable, Equatable {
  fileprivate let transactionID: UUID
  fileprivate let ownerNonce: UUID
  fileprivate let journalURL: URL
}

@available(iOS 17.0, *)
struct PairingAcceptanceJournal: Codable, Sendable, Equatable {
  static let currentSchemaVersion = 1

  enum Phase: String, Codable, Sendable {
    case planning
    case prepared
    case applying
    case rollingBack
    case replyMayBeVisible
    case committed
  }

  struct Plan: Codable, Sendable, Equatable {
    let authority: AuthorityBoundPairingIdentityPersistenceReceipt
    let trustedDeviceBefore: TrustedDeviceStore.PairingAcceptanceSnapshot
    let trustedDeviceAfter: TrustedDeviceStore.PairingAcceptanceSnapshot
    let pairingPolicyBefore: PairingPolicySnapshot
    let pairingPolicyAfter: PairingPolicySnapshot
  }

  let schemaVersion: Int
  let transactionID: UUID
  let ownerNonce: UUID
  let canonicalAcceptanceKey: String
  let acceptedMaterialDigest: Data
  var phase: Phase
  var plan: Plan?
  var authorityApplied: Bool
  var trustedDeviceApplied: Bool
  var pairingPolicyApplied: Bool
}

@available(iOS 17.0, *)
enum PairingAcceptanceJournalStoreError: Error, LocalizedError, Sendable {
  case applicationSupportUnavailable
  case encodingFailed(String)
  case decodingFailed(String)
  case unsupportedSchemaVersion(Int)
  case payloadTooLarge(Int)
  case transactionMismatch
  case writeVerificationFailed
  case invalidPermit
  case removalFailed(String)

  var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      return "Application Support is unavailable for the pairing acceptance journal"
    case .encodingFailed(let reason):
      return "Pairing acceptance journal encoding failed: \(reason)"
    case .decodingFailed(let reason):
      return "Pairing acceptance journal decoding failed: \(reason)"
    case .unsupportedSchemaVersion(let version):
      return "Unsupported pairing acceptance journal schema version: \(version)"
    case .payloadTooLarge(let byteCount):
      return "Pairing acceptance journal exceeds the 16 MiB limit: \(byteCount) bytes"
    case .transactionMismatch:
      return "Pairing acceptance journal ownership changed"
    case .writeVerificationFailed:
      return "Pairing acceptance journal write could not be verified"
    case .invalidPermit:
      return "Pairing acceptance mutation permit does not own the durable journal"
    case .removalFailed(let reason):
      return "Pairing acceptance journal removal failed: \(reason)"
    }
  }
}

/// Durable outer write-ahead record for authority, trusted-device and pairing-policy state.
/// It reuses the already exercised protected write primitive, while retaining an independent
/// path and schema from the inner KEM/protocol journal.
@available(iOS 17.0, *)
struct PairingAcceptanceJournalStore: Sendable {
  private static let maximumPayloadBytes = 16 * 1_024 * 1_024
  let journalURL: URL
  private let injectedRemovalFailure: @Sendable () -> String?

  init(
    journalURL: URL,
    injectedRemovalFailure: @escaping @Sendable () -> String? = { nil }
  ) {
    self.journalURL = journalURL
    self.injectedRemovalFailure = injectedRemovalFailure
  }

  static func defaultStore() throws -> Self {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw PairingAcceptanceJournalStoreError.applicationSupportUnavailable
    }
    return Self(
      journalURL: applicationSupport
        .appendingPathComponent("SkyBridge", isDirectory: true)
        .appendingPathComponent("pairing-acceptance.v1.journal")
    )
  }

  static func defaultJournalExists() -> Bool {
    guard let store = try? defaultStore() else { return true }
    return store.journalExists
  }

  static func permitOwnsActiveJournal(
    _ permit: PairingIdentityAuthorityMutationPermit
  ) -> Bool {
    Self(journalURL: permit.journalURL).ownsActiveJournal(permit)
  }

  var journalExists: Bool {
    FileManager.default.fileExists(atPath: journalURL.path)
  }

  func makePermit(transactionID: UUID, ownerNonce: UUID) -> PairingIdentityAuthorityMutationPermit {
    PairingIdentityAuthorityMutationPermit(
      transactionID: transactionID,
      ownerNonce: ownerNonce,
      journalURL: journalURL.standardizedFileURL
    )
  }

  func ownsActiveJournal(_ permit: PairingIdentityAuthorityMutationPermit) -> Bool {
    guard permit.journalURL.standardizedFileURL == journalURL.standardizedFileURL,
      let journal = try? load()
    else {
      return false
    }
    return journal.transactionID == permit.transactionID
      && journal.ownerNonce == permit.ownerNonce
  }

  func load() throws -> PairingAcceptanceJournal? {
    let protectedStore = AuthorityBoundPairingIdentityJournalStore(journalURL: journalURL)
    guard let data = try protectedStore.loadProtectedData() else { return nil }
    guard data.count <= Self.maximumPayloadBytes else {
      throw PairingAcceptanceJournalStoreError.payloadTooLarge(data.count)
    }
    let journal: PairingAcceptanceJournal
    do {
      journal = try JSONDecoder().decode(PairingAcceptanceJournal.self, from: data)
    } catch {
      throw PairingAcceptanceJournalStoreError.decodingFailed(error.localizedDescription)
    }
    guard journal.schemaVersion == PairingAcceptanceJournal.currentSchemaVersion else {
      throw PairingAcceptanceJournalStoreError.unsupportedSchemaVersion(journal.schemaVersion)
    }
    return journal
  }

  func write(_ journal: PairingAcceptanceJournal) throws {
    let isUpdate = journalExists
    if isUpdate {
      guard let existing = try load(),
        existing.transactionID == journal.transactionID,
        existing.ownerNonce == journal.ownerNonce
      else {
        throw PairingAcceptanceJournalStoreError.transactionMismatch
      }
    }

    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(journal)
    } catch {
      throw PairingAcceptanceJournalStoreError.encodingFailed(error.localizedDescription)
    }
    guard data.count <= Self.maximumPayloadBytes else {
      throw PairingAcceptanceJournalStoreError.payloadTooLarge(data.count)
    }

    let protectedStore = AuthorityBoundPairingIdentityJournalStore(journalURL: journalURL)
    do {
      try protectedStore.installProtectedData(data, replacingExistingJournal: isUpdate)
    } catch AuthorityBoundPairingIdentityJournalStoreError.transactionMismatch {
      throw PairingAcceptanceJournalStoreError.transactionMismatch
    }
    guard (try? Data(contentsOf: journalURL)) == data else {
      throw PairingAcceptanceJournalStoreError.writeVerificationFailed
    }
  }

  func remove(permit: PairingIdentityAuthorityMutationPermit) throws {
    guard ownsActiveJournal(permit) else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }
    if let reason = injectedRemovalFailure() {
      throw PairingAcceptanceJournalStoreError.removalFailed(reason)
    }
    try AuthorityBoundPairingIdentityJournalStore(journalURL: journalURL).removeProtectedData()
  }
}

@available(iOS 17.0, *)
@MainActor
enum PairingIdentityAuthorityMutationBarrier {
  private static var activePermit: PairingIdentityAuthorityMutationPermit?

  static func acquire(
    transactionID: UUID,
    ownerNonce: UUID,
    journalStore: PairingAcceptanceJournalStore
  ) throws -> PairingIdentityAuthorityMutationPermit {
    guard activePermit == nil else {
      throw AuthorityBoundPairingIdentityPersistenceError.transactionInProgress
    }
    let permit = journalStore.makePermit(
      transactionID: transactionID,
      ownerNonce: ownerNonce
    )
    activePermit = permit
    return permit
  }

  static func validate(_ permit: PairingIdentityAuthorityMutationPermit) throws {
    guard activePermit == permit else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }
  }

  static func release(_ permit: PairingIdentityAuthorityMutationPermit) {
    if activePermit == permit {
      activePermit = nil
    }
  }
}

@available(iOS 17.0, *)
@MainActor
protocol PairingPolicyAuthorityParticipant: AnyObject {
  func preparePairingPolicyMutation(
    authorityKey: String,
    persistedValue: String?,
    outerPermit: PairingIdentityAuthorityMutationPermit
  ) throws -> PreparedPairingPolicyMutation?

  func applyPreparedPairingPolicyMutation(
    _ prepared: PreparedPairingPolicyMutation,
    outerPermit: PairingIdentityAuthorityMutationPermit
  ) throws

  func pairingPolicySnapshot(
    outerPermit: PairingIdentityAuthorityMutationPermit
  ) throws -> PairingPolicySnapshot

  func restorePairingPolicySnapshot(
    _ snapshot: PairingPolicySnapshot,
    expectedCurrent: [PairingPolicySnapshot],
    outerPermit: PairingIdentityAuthorityMutationPermit
  ) throws

  func pairingPolicySnapshotMatches(
    _ snapshot: PairingPolicySnapshot,
    outerPermit: PairingIdentityAuthorityMutationPermit
  ) throws -> Bool
}

@available(iOS 17.0, *)
@MainActor
struct PairingAcceptancePersistenceStores {
  let trustedDeviceStore: TrustedDeviceStore
  let kemStore: KEMTrustStore
  let protocolStore: ProtocolIdentityTrustStore
  let authorityJournalStore: AuthorityBoundPairingIdentityJournalStore
  let journalStore: PairingAcceptanceJournalStore

  static func defaultStores() throws -> Self {
    Self(
      trustedDeviceStore: .shared,
      kemStore: .shared,
      protocolStore: .shared,
      authorityJournalStore: try AuthorityBoundPairingIdentityJournalStore.defaultStore(),
      journalStore: try PairingAcceptanceJournalStore.defaultStore()
    )
  }
}

@available(iOS 17.0, *)
@MainActor
struct PairingAcceptancePersistenceHandle {
  fileprivate let journalStore: PairingAcceptanceJournalStore
  fileprivate let permit: PairingIdentityAuthorityMutationPermit
  fileprivate let policyParticipant: PairingPolicyAuthorityParticipant
  fileprivate let trustedDeviceStore: TrustedDeviceStore
  fileprivate let kemStore: KEMTrustStore
  fileprivate let protocolStore: ProtocolIdentityTrustStore
  fileprivate let authorityJournalStore: AuthorityBoundPairingIdentityJournalStore
}

@available(iOS 17.0, *)
enum PairingAcceptancePersistenceCrashPoint: Sendable, Equatable {
  case afterPlanningJournalWrite
  case afterPreparedJournalWrite
  case afterApplyingJournalWrite
  case beforeAuthorityWrite
  case afterAuthorityWrite
  case beforeTrustedDeviceWrite
  case afterTrustedDeviceWrite
  case beforePairingPolicyWrite
  case afterPairingPolicyWrite
  case afterApplyingProgressWrite
  case afterReplyMayBeVisibleMarker
  case afterCommittedMarker
}

@available(iOS 17.0, *)
private struct PairingAcceptancePersistenceSimulatedCrash: Error, Sendable {
  let point: PairingAcceptancePersistenceCrashPoint
}

@available(iOS 17.0, *)
enum PairingAcceptancePersistenceError: Error, LocalizedError, Sendable {
  case invalidAcceptanceMetadata
  case recoveryRequired
  case invalidJournal(transactionID: UUID?, reason: String)
  case invalidPhase(expected: String, actual: String)
  case stateMismatch(component: String)

  var errorDescription: String? {
    switch self {
    case .invalidAcceptanceMetadata:
      return "Pairing acceptance metadata is incomplete or malformed"
    case .recoveryRequired:
      return "Pairing acceptance persistence must recover before accepting a peer"
    case .invalidJournal(let transactionID, let reason):
      return "Pairing acceptance journal \(transactionID?.uuidString ?? "unknown") is invalid: \(reason)"
    case .invalidPhase(let expected, let actual):
      return "Pairing acceptance journal phase mismatch: expected \(expected), found \(actual)"
    case .stateMismatch(let component):
      return "Pairing acceptance state does not match the durable \(component) plan"
    }
  }
}

@available(iOS 17.0, *)
enum PairingAcceptanceNetworkFailureDisposition: Sendable, Equatable {
  case rollbackBeforeVisibility
  case retainAfterVisibility
  case leaveAfterJournalForRecovery
}

@available(iOS 17.0, *)
enum AuthorityBoundPairingIdentityPersistenceError: Error, LocalizedError, Sendable {
  case transactionInProgress
  case recoveryFailed(transactionID: UUID?, reason: String)

  var errorDescription: String? {
    switch self {
    case .transactionInProgress:
      return "Another pairing identity persistence transaction is already in progress"
    case .recoveryFailed(let transactionID, let reason):
      let reference = transactionID?.uuidString ?? "unknown"
      return "Pairing identity transaction \(reference) remains quarantined: \(reason)"
    }
  }
}

@available(iOS 17.0, *)
enum AuthorityBoundPairingIdentityCrashPoint: Sendable, Equatable {
  case beforeKEMWrite
  case afterKEMWrite
  case afterProtocolWrite(index: Int)
  case beforeCommittedMarker
  case afterCommittedMarker
  case beforeRollbackProtocolWrite
  case afterRollbackProtocolWrite(index: Int)
  case beforeRollbackKEMWrite
  case afterRollbackKEMWrite
  case beforeRollbackCommittedMarker
  case afterRollbackCommittedMarker
}

@available(iOS 17.0, *)
private struct AuthorityBoundPairingIdentitySimulatedCrash: Error, Sendable {
  let point: AuthorityBoundPairingIdentityCrashPoint
}

/// One persistence transaction shared by LAN and WebRTC. UI/presentation state
/// is deliberately outside this boundary and may be published only after this
/// durable authority material commits successfully.
@available(iOS 17.0, *)
@MainActor
enum AuthorityBoundPairingIdentityPersistence {
  private static var activeTransactionID: UUID?

  static func commit(
    payload: AppMessage.PairingIdentityExchangePayload,
    authority: ValidatedPairingIdentityAuthority,
    outerPermit: PairingIdentityAuthorityMutationPermit? = nil,
    beforeFirstStoreWrite: (
      AuthorityBoundPairingIdentityPersistenceReceipt
    ) throws -> Void = { _ in },
    validateCurrentSession: () throws -> Void
  ) async throws -> AuthorityBoundPairingIdentityPersistenceReceipt {
    let journalStore: AuthorityBoundPairingIdentityJournalStore
    do {
      journalStore = try AuthorityBoundPairingIdentityJournalStore.defaultStore()
    } catch {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: error.localizedDescription
      )
    }
    return try await commit(
      payload: payload,
      authority: authority,
      validateCurrentSession: validateCurrentSession,
      kemStore: .shared,
      protocolStore: .shared,
      journalStore: journalStore,
      outerPermit: outerPermit,
      beforeFirstStoreWrite: beforeFirstStoreWrite,
      shouldSimulateCrash: { _ in false }
    )
  }

  static func commit(
    payload: AppMessage.PairingIdentityExchangePayload,
    authority: ValidatedPairingIdentityAuthority,
    validateCurrentSession: () throws -> Void,
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    journalStore: AuthorityBoundPairingIdentityJournalStore,
    outerPermit: PairingIdentityAuthorityMutationPermit? = nil,
    beforeFirstStoreWrite: (
      AuthorityBoundPairingIdentityPersistenceReceipt
    ) throws -> Void = { _ in },
    shouldSimulateCrash: @Sendable (AuthorityBoundPairingIdentityCrashPoint) -> Bool
  ) async throws -> AuthorityBoundPairingIdentityPersistenceReceipt {
    let transactionID = UUID()
    guard activeTransactionID == nil else {
      throw AuthorityBoundPairingIdentityPersistenceError.transactionInProgress
    }
    activeTransactionID = transactionID
    defer {
      if activeTransactionID == transactionID {
        activeTransactionID = nil
      }
    }

    try await recoverIfNeededLocked(
      kemStore: kemStore,
      protocolStore: protocolStore,
      journalStore: journalStore
    )
    try validateCurrentSession()

    let identityKey = AppMessage.ProtocolIdentityPublicKeyInfo(
      protocolSigningAlgorithm: authority.protocolSigningAlgorithm.rawValue,
      publicKey: authority.protocolPublicKey
    )
    let kemMutation = try await kemStore.prepareAuthorityBoundBootstrap(
      deviceIds: authority.authorizedDeviceIds,
      kemPublicKeys: payload.kemPublicKeys,
      verifiedProtocolFingerprint: authority.protocolPublicKeyFingerprint,
      outerPermit: outerPermit
    )
    let protocolMutations = try await protocolStore.prepareAuthorityBoundSequence(
      deviceIds: authority.authorizedDeviceIds,
      protocolIdentityPublicKeys: [identityKey],
      outerPermit: outerPermit
    )
    guard protocolMutations.count == authority.authorizedDeviceIds.count else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: "No exact protocol-identity mutation plan was produced"
      )
    }
    let plannedReceipt = AuthorityBoundPairingIdentityPersistenceReceipt(
      authorizedDeviceIDs: authority.authorizedDeviceIds,
      protocolFingerprint: authority.protocolPublicKeyFingerprint,
      kemMutationReceipt: kemMutation.receipt,
      protocolMutationReceipts: protocolMutations.map(\.receipt)
    )
    try beforeFirstStoreWrite(plannedReceipt)

    var journal = AuthorityBoundPairingIdentityJournal(
      schemaVersion: AuthorityBoundPairingIdentityJournal.currentSchemaVersion,
      transactionID: transactionID,
      intent: .commit,
      authorizedDeviceIDs: authority.authorizedDeviceIds,
      protocolFingerprint: authority.protocolPublicKeyFingerprint,
      kemMutationReceipt: kemMutation.receipt,
      protocolMutationReceipts: protocolMutations.map(\.receipt),
      phase: .prepared,
      kemApplied: false,
      appliedProtocolMutationCount: 0,
      kemRolledBack: false,
      rolledBackProtocolMutationCount: 0
    )

    do {
      // Every later store write now has exact record-level before and committed
      // values available to recovery, including capacity-pruning side effects.
      try journalStore.write(journal)
      try validateCurrentSession()
      journal.phase = .applying
      try journalStore.write(journal)
      try simulateCrashIfRequested(.beforeKEMWrite, using: shouldSimulateCrash)

      try await kemStore.applyPreparedAuthorityBoundMutation(
        kemMutation,
        permitsJournal: true
      )
      try simulateCrashIfRequested(.afterKEMWrite, using: shouldSimulateCrash)
      journal.kemApplied = true
      try journalStore.write(journal)
      try validateCurrentSession()

      for (index, mutation) in protocolMutations.enumerated() {
        try await protocolStore.applyPreparedAuthorityBoundMutation(
          mutation,
          permitsJournal: true
        )
        try simulateCrashIfRequested(
          .afterProtocolWrite(index: index),
          using: shouldSimulateCrash
        )
        journal.appliedProtocolMutationCount = index + 1
        try journalStore.write(journal)
        try validateCurrentSession()
      }

      try simulateCrashIfRequested(.beforeCommittedMarker, using: shouldSimulateCrash)
      guard try await kemStore.authorityBoundMutationMatchesCommittedIgnoringJournal(
        kemMutation.receipt
      ),
        try await protocolMutationReceiptsMatchCommitted(
          protocolMutations.map(\.receipt),
          in: protocolStore
        )
      else {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: transactionID,
          reason: "Final trust-store verification did not match the journal receipts"
        )
      }

      journal.phase = .committed
      try journalStore.write(journal)
      try simulateCrashIfRequested(.afterCommittedMarker, using: shouldSimulateCrash)
      try journalStore.remove(expectedTransactionID: transactionID)
      return plannedReceipt
    } catch let simulatedCrash as AuthorityBoundPairingIdentitySimulatedCrash {
      // This models process death. Catch-path compensation must not erase the
      // durable evidence that a subsequent first-use recovery needs.
      throw simulatedCrash
    } catch {
      guard journalStore.journalExists else { throw error }
      do {
        try await recoverIfNeededLocked(
          kemStore: kemStore,
          protocolStore: protocolStore,
          journalStore: journalStore
        )
      } catch let recoveryError {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: transactionID,
          reason: "Original failure: \(error.localizedDescription); recovery failure: \(recoveryError.localizedDescription)"
        )
      }
      throw error
    }
  }

  static func recoverIfNeeded() async throws {
    let journalStore: AuthorityBoundPairingIdentityJournalStore
    do {
      journalStore = try AuthorityBoundPairingIdentityJournalStore.defaultStore()
    } catch {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: error.localizedDescription
      )
    }
    try await recoverIfNeeded(
      kemStore: .shared,
      protocolStore: .shared,
      journalStore: journalStore
    )
  }

  static func recoverIfNeeded(
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    journalStore: AuthorityBoundPairingIdentityJournalStore
  ) async throws {
    let recoveryOperationID = UUID()
    guard activeTransactionID == nil else {
      throw AuthorityBoundPairingIdentityPersistenceError.transactionInProgress
    }
    activeTransactionID = recoveryOperationID
    defer {
      if activeTransactionID == recoveryOperationID {
        activeTransactionID = nil
      }
    }
    try await recoverIfNeededLocked(
      kemStore: kemStore,
      protocolStore: protocolStore,
      journalStore: journalStore
    )
  }

  static func rollback(
    _ receipt: AuthorityBoundPairingIdentityPersistenceReceipt
  ) async throws {
    let journalStore: AuthorityBoundPairingIdentityJournalStore
    do {
      journalStore = try AuthorityBoundPairingIdentityJournalStore.defaultStore()
    } catch {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: error.localizedDescription
      )
    }
    try await rollback(
      receipt,
      kemStore: .shared,
      protocolStore: .shared,
      journalStore: journalStore,
      shouldSimulateCrash: { _ in false }
    )
  }

  static func receiptMatchesCommitted(
    _ receipt: AuthorityBoundPairingIdentityPersistenceReceipt,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared
  ) async throws -> Bool {
    guard try await kemStore.authorityBoundMutationMatchesCommittedIgnoringJournal(
      receipt.kemMutationReceipt
    ) else {
      return false
    }
    return try await protocolMutationReceiptsMatchCommitted(
      receipt.protocolMutationReceipts,
      in: protocolStore
    )
  }

  static func receiptMatchesRolledBack(
    _ receipt: AuthorityBoundPairingIdentityPersistenceReceipt,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared
  ) async throws -> Bool {
    guard try await kemStore.authorityBoundMutationMatchesRolledBackIgnoringJournal(
      receipt.kemMutationReceipt
    ) else {
      return false
    }
    return try await protocolMutationReceiptsMatchRolledBack(
      receipt.protocolMutationReceipts,
      in: protocolStore
    )
  }

  static func rollForward(
    _ receipt: AuthorityBoundPairingIdentityPersistenceReceipt,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared
  ) async throws {
    try await kemStore.rollForwardAuthorityBoundMutation(
      receipt.kemMutationReceipt,
      permitsJournal: true
    )
    for protocolReceipt in receipt.protocolMutationReceipts {
      try await protocolStore.rollForwardAuthorityBoundMutation(
        protocolReceipt,
        permitsJournal: true
      )
    }
    guard try await receiptMatchesCommitted(
      receipt,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: "Authority roll-forward did not converge to every committed record"
      )
    }
  }

  static func rollback(
    _ receipt: AuthorityBoundPairingIdentityPersistenceReceipt,
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    journalStore: AuthorityBoundPairingIdentityJournalStore,
    shouldSimulateCrash: @Sendable (AuthorityBoundPairingIdentityCrashPoint) -> Bool
  ) async throws {
    let transactionID = UUID()
    guard activeTransactionID == nil else {
      throw AuthorityBoundPairingIdentityPersistenceError.transactionInProgress
    }
    activeTransactionID = transactionID
    defer {
      if activeTransactionID == transactionID {
        activeTransactionID = nil
      }
    }

    try await recoverIfNeededLocked(
      kemStore: kemStore,
      protocolStore: protocolStore,
      journalStore: journalStore
    )
    var journal = AuthorityBoundPairingIdentityJournal(
      schemaVersion: AuthorityBoundPairingIdentityJournal.currentSchemaVersion,
      transactionID: transactionID,
      intent: .rollback,
      authorizedDeviceIDs: receipt.authorizedDeviceIDs,
      protocolFingerprint: receipt.protocolFingerprint,
      kemMutationReceipt: receipt.kemMutationReceipt,
      protocolMutationReceipts: receipt.protocolMutationReceipts,
      phase: .prepared,
      kemApplied: true,
      appliedProtocolMutationCount: receipt.protocolMutationReceipts.count,
      kemRolledBack: false,
      rolledBackProtocolMutationCount: 0
    )

    do {
      try journalStore.write(journal)
      journal.phase = .applying
      try journalStore.write(journal)
      try simulateCrashIfRequested(
        .beforeRollbackProtocolWrite,
        using: shouldSimulateCrash
      )

      for (progressIndex, sourceIndex) in receipt.protocolMutationReceipts.indices
        .reversed().enumerated()
      {
        try await protocolStore.rollbackAuthorityBoundMutation(
          receipt.protocolMutationReceipts[sourceIndex],
          permitsJournal: true
        )
        try simulateCrashIfRequested(
          .afterRollbackProtocolWrite(index: sourceIndex),
          using: shouldSimulateCrash
        )
        journal.rolledBackProtocolMutationCount = progressIndex + 1
        try journalStore.write(journal)
      }

      try simulateCrashIfRequested(.beforeRollbackKEMWrite, using: shouldSimulateCrash)
      try await kemStore.rollbackAuthorityBoundMutation(
        receipt.kemMutationReceipt,
        permitsJournal: true
      )
      try simulateCrashIfRequested(.afterRollbackKEMWrite, using: shouldSimulateCrash)
      journal.kemRolledBack = true
      try journalStore.write(journal)

      guard try await kemStore.authorityBoundMutationMatchesRolledBackIgnoringJournal(
        receipt.kemMutationReceipt
      ),
        try await protocolMutationReceiptsMatchRolledBack(
          receipt.protocolMutationReceipts,
          in: protocolStore
        )
      else {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: transactionID,
          reason: "Rollback verification did not match the journal receipts"
        )
      }
      try simulateCrashIfRequested(
        .beforeRollbackCommittedMarker,
        using: shouldSimulateCrash
      )
      journal.phase = .committed
      try journalStore.write(journal)
      try simulateCrashIfRequested(
        .afterRollbackCommittedMarker,
        using: shouldSimulateCrash
      )
      try journalStore.remove(expectedTransactionID: transactionID)
    } catch let simulatedCrash as AuthorityBoundPairingIdentitySimulatedCrash {
      throw simulatedCrash
    } catch {
      guard journalStore.journalExists else { throw error }
      do {
        try await recoverIfNeededLocked(
          kemStore: kemStore,
          protocolStore: protocolStore,
          journalStore: journalStore
        )
      } catch let recoveryError {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: transactionID,
          reason: "Rollback failure: \(error.localizedDescription); recovery failure: \(recoveryError.localizedDescription)"
        )
      }
      throw error
    }
  }

  private static func recoverIfNeededLocked(
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    journalStore: AuthorityBoundPairingIdentityJournalStore
  ) async throws {
    var journal: AuthorityBoundPairingIdentityJournal
    do {
      guard let loaded = try journalStore.load() else { return }
      journal = loaded
    } catch {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: nil,
        reason: error.localizedDescription
      )
    }

    do {
      try validate(journal)
      if journal.schemaVersion == AuthorityBoundPairingIdentityJournal.legacySnapshotSchemaVersion {
        try await recoverLegacySnapshotJournal(
          journal,
          kemStore: kemStore,
          protocolStore: protocolStore
        )
      } else {
        try await recoverReceiptJournal(
          &journal,
          kemStore: kemStore,
          protocolStore: protocolStore,
          journalStore: journalStore
        )
      }
      try journalStore.remove(expectedTransactionID: journal.transactionID)
    } catch let error as AuthorityBoundPairingIdentityPersistenceError {
      throw error
    } catch {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: error.localizedDescription
      )
    }
  }

  private static func recoverLegacySnapshotJournal(
    _ journal: AuthorityBoundPairingIdentityJournal,
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore
  ) async throws {
    guard let kemBefore = journal.kemBefore,
      let kemAfter = journal.kemAfter,
      let protocolBefore = journal.protocolBefore,
      let protocolAfterEachMutation = journal.protocolAfterEachMutation,
      let finalProtocol = protocolAfterEachMutation.last
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Legacy snapshot journal is missing required store images"
      )
    }

    switch journal.phase {
    case .committed:
      let matchesExpectedState: Bool
      switch journal.intent {
      case .commit:
        let kemMatches = try await kemStore
          .authorityBoundSnapshotMatchesIgnoringJournal(kemAfter)
        let protocolMatches = try await protocolStore
          .authorityBoundSnapshotMatchesIgnoringJournal(finalProtocol)
        matchesExpectedState = kemMatches && protocolMatches
      case .rollback:
        let kemMatches = try await kemStore
          .authorityBoundSnapshotMatchesIgnoringJournal(kemBefore)
        let protocolMatches = try await protocolStore
          .authorityBoundSnapshotMatchesIgnoringJournal(protocolBefore)
        matchesExpectedState = kemMatches && protocolMatches
      }
      guard matchesExpectedState else {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: journal.transactionID,
          reason: "Legacy committed journal does not match its expected store images"
        )
      }
    case .prepared, .applying:
      if try await !protocolStore.authorityBoundSnapshotMatchesIgnoringJournal(protocolBefore) {
        try await protocolStore.restoreAuthorityBoundSnapshotIgnoringJournal(
          protocolBefore,
          expectedCurrent: [protocolBefore] + protocolAfterEachMutation
        )
      }
      if try await !kemStore.authorityBoundSnapshotMatchesIgnoringJournal(kemBefore) {
        try await kemStore.restoreAuthorityBoundSnapshotIgnoringJournal(
          kemBefore,
          expectedCurrent: [kemBefore, kemAfter]
        )
      }
      guard try await kemStore.authorityBoundSnapshotMatchesIgnoringJournal(kemBefore),
        try await protocolStore.authorityBoundSnapshotMatchesIgnoringJournal(protocolBefore)
      else {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: journal.transactionID,
          reason: "Legacy recovery did not match the journal before images"
        )
      }
    }
  }

  private static func recoverReceiptJournal(
    _ journal: inout AuthorityBoundPairingIdentityJournal,
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    journalStore: AuthorityBoundPairingIdentityJournalStore
  ) async throws {
    guard let kemReceipt = journal.kemMutationReceipt,
      let protocolReceipts = journal.protocolMutationReceipts,
      let rolledBackCount = journal.rolledBackProtocolMutationCount,
      let kemRolledBack = journal.kemRolledBack
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Receipt journal is missing record-CAS evidence or rollback progress"
      )
    }

    if journal.phase == .committed {
      let matchesExpectedState: Bool
      switch journal.intent {
      case .commit:
        let kemMatches = try await kemStore
          .authorityBoundMutationMatchesCommittedIgnoringJournal(kemReceipt)
        let protocolMatches = try await protocolMutationReceiptsMatchCommitted(
          protocolReceipts,
          in: protocolStore
        )
        matchesExpectedState = kemMatches && protocolMatches
      case .rollback:
        let kemMatches = try await kemStore
          .authorityBoundMutationMatchesRolledBackIgnoringJournal(kemReceipt)
        let protocolMatches = try await protocolMutationReceiptsMatchRolledBack(
          protocolReceipts,
          in: protocolStore
        )
        matchesExpectedState = kemMatches && protocolMatches
      }
      guard matchesExpectedState else {
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: journal.transactionID,
          reason: "Committed receipt journal does not match its affected trust records"
        )
      }
      return
    }

    if journal.phase == .prepared {
      journal.phase = .applying
      try journalStore.write(journal)
    }

    for progressIndex in rolledBackCount..<protocolReceipts.count {
      let sourceIndex = protocolReceipts.count - progressIndex - 1
      try await protocolStore.rollbackAuthorityBoundMutation(
        protocolReceipts[sourceIndex],
        permitsJournal: true
      )
      journal.rolledBackProtocolMutationCount = progressIndex + 1
      try journalStore.write(journal)
    }
    if !kemRolledBack {
      try await kemStore.rollbackAuthorityBoundMutation(
        kemReceipt,
        permitsJournal: true
      )
      journal.kemRolledBack = true
      try journalStore.write(journal)
    }

    guard try await kemStore.authorityBoundMutationMatchesRolledBackIgnoringJournal(kemReceipt),
      try await protocolMutationReceiptsMatchRolledBack(
        protocolReceipts,
        in: protocolStore
      )
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Receipt recovery did not restore every affected trust record"
      )
    }
  }

  private static func protocolMutationReceiptsMatchCommitted(
    _ receipts: [ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt],
    in store: ProtocolIdentityTrustStore
  ) async throws -> Bool {
    for receipt in receipts {
      if try await !store.authorityBoundMutationMatchesCommittedIgnoringJournal(receipt) {
        return false
      }
    }
    return true
  }

  private static func protocolMutationReceiptsMatchRolledBack(
    _ receipts: [ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt],
    in store: ProtocolIdentityTrustStore
  ) async throws -> Bool {
    for receipt in receipts {
      if try await !store.authorityBoundMutationMatchesRolledBackIgnoringJournal(receipt) {
        return false
      }
    }
    return true
  }

  private static func validate(
    _ journal: AuthorityBoundPairingIdentityJournal
  ) throws {
    let normalizedFingerprint = journal.protocolFingerprint
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !journal.authorizedDeviceIDs.isEmpty,
      normalizedFingerprint.count == 64,
      normalizedFingerprint.allSatisfy(\.isHexDigit)
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Journal metadata is internally inconsistent"
      )
    }

    if journal.schemaVersion == AuthorityBoundPairingIdentityJournal.legacySnapshotSchemaVersion {
      try validateLegacySnapshotJournal(journal)
    } else if journal.schemaVersion == AuthorityBoundPairingIdentityJournal.currentSchemaVersion {
      try validateReceiptJournal(journal)
    } else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Journal schema is not supported by this recovery implementation"
      )
    }
  }

  private static func validateLegacySnapshotJournal(
    _ journal: AuthorityBoundPairingIdentityJournal
  ) throws {
    guard journal.kemBefore != nil,
      journal.kemAfter != nil,
      journal.protocolBefore != nil,
      let protocolAfterEachMutation = journal.protocolAfterEachMutation,
      journal.authorizedDeviceIDs.count == protocolAfterEachMutation.count,
      journal.appliedProtocolMutationCount >= 0,
      journal.appliedProtocolMutationCount <= protocolAfterEachMutation.count
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Legacy journal metadata is internally inconsistent"
      )
    }
    if journal.phase == .prepared,
      (journal.kemApplied || journal.appliedProtocolMutationCount != 0)
    {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Legacy prepared journal contains impossible progress"
      )
    }
    if journal.phase == .committed,
      (!journal.kemApplied
        || journal.appliedProtocolMutationCount != protocolAfterEachMutation.count)
    {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Legacy committed journal is missing completed progress"
      )
    }
  }

  private static func validateReceiptJournal(
    _ journal: AuthorityBoundPairingIdentityJournal
  ) throws {
    guard journal.kemMutationReceipt != nil,
      let protocolReceipts = journal.protocolMutationReceipts,
      let kemRolledBack = journal.kemRolledBack,
      let rolledBackCount = journal.rolledBackProtocolMutationCount,
      journal.authorizedDeviceIDs.count == protocolReceipts.count,
      journal.appliedProtocolMutationCount >= 0,
      journal.appliedProtocolMutationCount <= protocolReceipts.count,
      rolledBackCount >= 0,
      rolledBackCount <= protocolReceipts.count
    else {
      throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
        transactionID: journal.transactionID,
        reason: "Receipt journal metadata is internally inconsistent"
      )
    }

    let allApplied = journal.kemApplied
      && journal.appliedProtocolMutationCount == protocolReceipts.count
    let noneApplied = !journal.kemApplied && journal.appliedProtocolMutationCount == 0
    let allRolledBack = kemRolledBack && rolledBackCount == protocolReceipts.count
    let noneRolledBack = !kemRolledBack && rolledBackCount == 0

    switch (journal.intent, journal.phase) {
    case (.commit, .prepared):
      guard noneApplied, noneRolledBack else {
        throw invalidReceiptProgress(journal)
      }
    case (.commit, .applying):
      guard (!journal.kemApplied && journal.appliedProtocolMutationCount == 0)
        || journal.kemApplied,
        !kemRolledBack || rolledBackCount == protocolReceipts.count
      else {
        throw invalidReceiptProgress(journal)
      }
    case (.commit, .committed):
      guard allApplied, noneRolledBack else {
        throw invalidReceiptProgress(journal)
      }
    case (.rollback, .prepared):
      guard allApplied, noneRolledBack else {
        throw invalidReceiptProgress(journal)
      }
    case (.rollback, .applying):
      guard allApplied,
        !kemRolledBack || rolledBackCount == protocolReceipts.count
      else {
        throw invalidReceiptProgress(journal)
      }
    case (.rollback, .committed):
      guard allApplied, allRolledBack else {
        throw invalidReceiptProgress(journal)
      }
    }
  }

  private static func invalidReceiptProgress(
    _ journal: AuthorityBoundPairingIdentityJournal
  ) -> AuthorityBoundPairingIdentityPersistenceError {
    .recoveryFailed(
      transactionID: journal.transactionID,
      reason: "Receipt journal contains impossible apply or rollback progress"
    )
  }

  private static func simulateCrashIfRequested(
    _ point: AuthorityBoundPairingIdentityCrashPoint,
    using predicate: @Sendable (AuthorityBoundPairingIdentityCrashPoint) -> Bool
  ) throws {
    if predicate(point) {
      throw AuthorityBoundPairingIdentitySimulatedCrash(point: point)
    }
  }
}

/// Coordinates every durable authority mutation that makes an authenticated
/// pairing acceptance observable. The outer journal is installed before any
/// participant writes, and remains the fail-closed owner until the reply
/// visibility decision is durable.
@available(iOS 17.0, *)
@MainActor
enum PairingAcceptancePersistence {
  private static var recoveryCompleted = false

  static var isRecoveryReady: Bool {
    recoveryCompleted
      && !PairingAcceptanceJournalStore.defaultJournalExists()
      && !AuthorityBoundPairingIdentityJournalStore.defaultJournalExists()
  }

  static func recoverIfNeeded(
    policyParticipant: PairingPolicyAuthorityParticipant
  ) async throws {
    do {
      try await recoverIfNeeded(
        policyParticipant: policyParticipant,
        trustedDeviceStore: .shared,
        kemStore: .shared,
        protocolStore: .shared,
        authorityJournalStore: try AuthorityBoundPairingIdentityJournalStore.defaultStore(),
        journalStore: try PairingAcceptanceJournalStore.defaultStore()
      )
    } catch {
      recoveryCompleted = false
      throw PairingAcceptancePersistenceError.invalidJournal(
        transactionID: nil,
        reason: error.localizedDescription
      )
    }
  }

  static func recoverIfNeeded(
    policyParticipant: PairingPolicyAuthorityParticipant,
    trustedDeviceStore: TrustedDeviceStore,
    kemStore: KEMTrustStore,
    protocolStore: ProtocolIdentityTrustStore,
    authorityJournalStore: AuthorityBoundPairingIdentityJournalStore,
    journalStore: PairingAcceptanceJournalStore
  ) async throws {
    guard let journal = try journalStore.load() else {
      do {
        try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
          kemStore: kemStore,
          protocolStore: protocolStore,
          journalStore: authorityJournalStore
        )
        recoveryCompleted = true
        return
      } catch {
        recoveryCompleted = false
        throw error
      }
    }

    let permit = try PairingIdentityAuthorityMutationBarrier.acquire(
      transactionID: journal.transactionID,
      ownerNonce: journal.ownerNonce,
      journalStore: journalStore
    )
    defer { PairingIdentityAuthorityMutationBarrier.release(permit) }

    do {
      try validate(journal)
      try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
        kemStore: kemStore,
        protocolStore: protocolStore,
        journalStore: authorityJournalStore
      )
      switch journal.phase {
      case .planning:
        try journalStore.remove(permit: permit)
      case .prepared, .applying, .rollingBack:
        try await convergeToBefore(
          journalStore: journalStore,
          permit: permit,
          policyParticipant: policyParticipant,
          trustedDeviceStore: trustedDeviceStore,
          kemStore: kemStore,
          protocolStore: protocolStore,
          authorityJournalStore: authorityJournalStore
        )
      case .replyMayBeVisible, .committed:
        try await convergeToAfter(
          journalStore: journalStore,
          permit: permit,
          policyParticipant: policyParticipant,
          trustedDeviceStore: trustedDeviceStore,
          kemStore: kemStore,
          protocolStore: protocolStore,
          authorityJournalStore: authorityJournalStore
        )
      }
      recoveryCompleted = true
    } catch {
      recoveryCompleted = false
      throw PairingAcceptancePersistenceError.invalidJournal(
        transactionID: journal.transactionID,
        reason: error.localizedDescription
      )
    }
  }

  static func begin(
    payload: AppMessage.PairingIdentityExchangePayload,
    authority: ValidatedPairingIdentityAuthority,
    canonicalAcceptanceKey: String,
    acceptedMaterialDigest: Data,
    trustedDevicePreparation: (
      PairingIdentityAuthorityMutationPermit
    ) throws -> TrustedDeviceStore.PreparedTrustMutation?,
    pairingPolicyPersistedValue: String?,
    policyParticipant: PairingPolicyAuthorityParticipant,
    injectedStores: PairingAcceptancePersistenceStores? = nil,
    shouldSimulateCrash: @Sendable (
      PairingAcceptancePersistenceCrashPoint
    ) -> Bool = { _ in false },
    validateCurrentSession: () throws -> Void
  ) async throws -> PairingAcceptancePersistenceHandle {
    let normalizedAcceptanceKey = canonicalAcceptanceKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedAcceptanceKey.isEmpty,
      acceptedMaterialDigest.count == SHA256.byteCount
    else {
      throw PairingAcceptancePersistenceError.invalidAcceptanceMetadata
    }

    let stores: PairingAcceptancePersistenceStores
    if let injectedStores {
      stores = injectedStores
      try await recoverIfNeeded(
        policyParticipant: policyParticipant,
        trustedDeviceStore: stores.trustedDeviceStore,
        kemStore: stores.kemStore,
        protocolStore: stores.protocolStore,
        authorityJournalStore: stores.authorityJournalStore,
        journalStore: stores.journalStore
      )
    } else {
      if !isRecoveryReady {
        try await recoverIfNeeded(policyParticipant: policyParticipant)
      }
      guard isRecoveryReady else {
        throw PairingAcceptancePersistenceError.recoveryRequired
      }
      stores = try PairingAcceptancePersistenceStores.defaultStores()
    }

    let journalStore = stores.journalStore
    let transactionID = UUID()
    let ownerNonce = UUID()
    let permit = try PairingIdentityAuthorityMutationBarrier.acquire(
      transactionID: transactionID,
      ownerNonce: ownerNonce,
      journalStore: journalStore
    )
    var handedOff = false
    defer {
      if !handedOff {
        PairingIdentityAuthorityMutationBarrier.release(permit)
      }
    }

    var journal = PairingAcceptanceJournal(
      schemaVersion: PairingAcceptanceJournal.currentSchemaVersion,
      transactionID: transactionID,
      ownerNonce: ownerNonce,
      canonicalAcceptanceKey: normalizedAcceptanceKey,
      acceptedMaterialDigest: acceptedMaterialDigest,
      phase: .planning,
      plan: nil,
      authorityApplied: false,
      trustedDeviceApplied: false,
      pairingPolicyApplied: false
    )
    try journalStore.write(journal)
    try simulateCrashIfRequested(
      .afterPlanningJournalWrite,
      using: shouldSimulateCrash
    )
    try PairingIdentityAuthorityMutationBarrier.validate(permit)
    guard journalStore.ownsActiveJournal(permit) else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }

    var preparedTrustMutation: TrustedDeviceStore.PreparedTrustMutation?
    var preparedPolicyMutation: PreparedPairingPolicyMutation?

    do {
      let authorityReceipt = try await AuthorityBoundPairingIdentityPersistence.commit(
        payload: payload,
        authority: authority,
        validateCurrentSession: validateCurrentSession,
        kemStore: stores.kemStore,
        protocolStore: stores.protocolStore,
        journalStore: stores.authorityJournalStore,
        outerPermit: permit,
        beforeFirstStoreWrite: { plannedAuthorityReceipt in
          try PairingIdentityAuthorityMutationBarrier.validate(permit)
          guard journalStore.ownsActiveJournal(permit) else {
            throw PairingAcceptanceJournalStoreError.invalidPermit
          }
          try validateCurrentSession()

          let trustedDeviceBefore = try stores.trustedDeviceStore
            .pairingAcceptanceSnapshot(outerPermit: permit)
          preparedTrustMutation = try trustedDevicePreparation(permit)
          if let preparedTrustMutation,
            preparedTrustMutation.before != trustedDeviceBefore
          {
            throw PairingAcceptancePersistenceError.stateMismatch(
              component: "trusted-device preparation"
            )
          }
          let trustedDeviceAfter = preparedTrustMutation?.after
            ?? trustedDeviceBefore

          let pairingPolicyBefore = try policyParticipant.pairingPolicySnapshot(
            outerPermit: permit
          )
          preparedPolicyMutation = try policyParticipant.preparePairingPolicyMutation(
            authorityKey: normalizedAcceptanceKey,
            persistedValue: pairingPolicyPersistedValue,
            outerPermit: permit
          )
          if let preparedPolicyMutation,
            preparedPolicyMutation.before != pairingPolicyBefore
          {
            throw PairingAcceptancePersistenceError.stateMismatch(
              component: "pairing-policy preparation"
            )
          }
          let pairingPolicyAfter = preparedPolicyMutation?.after
            ?? pairingPolicyBefore

          journal.plan = PairingAcceptanceJournal.Plan(
            authority: plannedAuthorityReceipt,
            trustedDeviceBefore: trustedDeviceBefore,
            trustedDeviceAfter: trustedDeviceAfter,
            pairingPolicyBefore: pairingPolicyBefore,
            pairingPolicyAfter: pairingPolicyAfter
          )
          journal.phase = .prepared
          try journalStore.write(journal)
          try simulateCrashIfRequested(
            .afterPreparedJournalWrite,
            using: shouldSimulateCrash
          )
          journal.phase = .applying
          try journalStore.write(journal)
          try simulateCrashIfRequested(
            .afterApplyingJournalWrite,
            using: shouldSimulateCrash
          )
          try simulateCrashIfRequested(
            .beforeAuthorityWrite,
            using: shouldSimulateCrash
          )
        },
        shouldSimulateCrash: { _ in false }
      )

      try simulateCrashIfRequested(
        .afterAuthorityWrite,
        using: shouldSimulateCrash
      )
      guard let plan = journal.plan,
        plan.authority == authorityReceipt
      else {
        throw PairingAcceptancePersistenceError.stateMismatch(
          component: "authority preparation"
        )
      }
      journal.authorityApplied = true
      try journalStore.write(journal)
      try validateCurrentSession()

      try simulateCrashIfRequested(
        .beforeTrustedDeviceWrite,
        using: shouldSimulateCrash
      )
      if let preparedTrustMutation {
        _ = try stores.trustedDeviceStore.applyPreparedTrustMutation(
          preparedTrustMutation,
          outerPermit: permit
        )
      }
      try simulateCrashIfRequested(
        .afterTrustedDeviceWrite,
        using: shouldSimulateCrash
      )
      journal.trustedDeviceApplied = true
      try journalStore.write(journal)
      try validateCurrentSession()

      try simulateCrashIfRequested(
        .beforePairingPolicyWrite,
        using: shouldSimulateCrash
      )
      if let preparedPolicyMutation {
        try policyParticipant.applyPreparedPairingPolicyMutation(
          preparedPolicyMutation,
          outerPermit: permit
        )
      }
      try simulateCrashIfRequested(
        .afterPairingPolicyWrite,
        using: shouldSimulateCrash
      )
      journal.pairingPolicyApplied = true
      try journalStore.write(journal)
      try simulateCrashIfRequested(
        .afterApplyingProgressWrite,
        using: shouldSimulateCrash
      )
      try validateCurrentSession()
      try await verifyAfter(
        plan,
        permit: permit,
        policyParticipant: policyParticipant,
        trustedDeviceStore: stores.trustedDeviceStore,
        kemStore: stores.kemStore,
        protocolStore: stores.protocolStore
      )

      handedOff = true
      return PairingAcceptancePersistenceHandle(
        journalStore: journalStore,
        permit: permit,
        policyParticipant: policyParticipant,
        trustedDeviceStore: stores.trustedDeviceStore,
        kemStore: stores.kemStore,
        protocolStore: stores.protocolStore,
        authorityJournalStore: stores.authorityJournalStore
      )
    } catch let simulatedCrash as PairingAcceptancePersistenceSimulatedCrash {
      recoveryCompleted = false
      throw simulatedCrash
    } catch {
      let originalError = error
      do {
        if journalStore.journalExists {
          try await convergeToBefore(
            journalStore: journalStore,
            permit: permit,
            policyParticipant: policyParticipant,
            trustedDeviceStore: stores.trustedDeviceStore,
            kemStore: stores.kemStore,
            protocolStore: stores.protocolStore,
            authorityJournalStore: stores.authorityJournalStore
          )
        }
      } catch {
        recoveryCompleted = false
        throw AuthorityBoundPairingIdentityPersistenceError.recoveryFailed(
          transactionID: transactionID,
          reason: "Original failure: \(originalError.localizedDescription); outer rollback failure: \(error.localizedDescription)"
        )
      }
      throw originalError
    }
  }

  static func markReplyMayBeVisible(
    _ handle: PairingAcceptancePersistenceHandle,
    validateCurrentSession: () throws -> Void
  ) async throws {
    try await markReplyMayBeVisible(
      handle,
      validateCurrentSession: validateCurrentSession,
      shouldSimulateCrash: { _ in false }
    )
  }

  static func markReplyMayBeVisible(
    _ handle: PairingAcceptancePersistenceHandle,
    validateCurrentSession: () throws -> Void,
    shouldSimulateCrash: @Sendable (
      PairingAcceptancePersistenceCrashPoint
    ) -> Bool
  ) async throws {
    try PairingIdentityAuthorityMutationBarrier.validate(handle.permit)
    var journal = try loadOwnedJournal(handle)
    guard journal.phase == .applying else {
      throw PairingAcceptancePersistenceError.invalidPhase(
        expected: PairingAcceptanceJournal.Phase.applying.rawValue,
        actual: journal.phase.rawValue
      )
    }
    guard let plan = journal.plan,
      journal.authorityApplied,
      journal.trustedDeviceApplied,
      journal.pairingPolicyApplied
    else {
      throw PairingAcceptancePersistenceError.invalidJournal(
        transactionID: journal.transactionID,
        reason: "Reply visibility cannot advance before every participant is applied"
      )
    }
    try validateCurrentSession()
    try await verifyAfter(
      plan,
      permit: handle.permit,
      policyParticipant: handle.policyParticipant,
      trustedDeviceStore: handle.trustedDeviceStore,
      kemStore: handle.kemStore,
      protocolStore: handle.protocolStore
    )
    try validateCurrentSession()
    journal.phase = .replyMayBeVisible
    try handle.journalStore.write(journal)
    do {
      try simulateCrashIfRequested(
        .afterReplyMayBeVisibleMarker,
        using: shouldSimulateCrash
      )
    } catch let simulatedCrash as PairingAcceptancePersistenceSimulatedCrash {
      PairingIdentityAuthorityMutationBarrier.release(handle.permit)
      throw simulatedCrash
    }
  }

  static func completeAfterReplyMayBeVisible(
    _ handle: PairingAcceptancePersistenceHandle,
    policyParticipant: PairingPolicyAuthorityParticipant
  ) async throws {
    try await completeAfterReplyMayBeVisible(
      handle,
      policyParticipant: policyParticipant,
      shouldSimulateCrash: { _ in false }
    )
  }

  static func completeAfterReplyMayBeVisible(
    _ handle: PairingAcceptancePersistenceHandle,
    policyParticipant: PairingPolicyAuthorityParticipant,
    shouldSimulateCrash: @Sendable (
      PairingAcceptancePersistenceCrashPoint
    ) -> Bool
  ) async throws {
    defer { PairingIdentityAuthorityMutationBarrier.release(handle.permit) }
    try PairingIdentityAuthorityMutationBarrier.validate(handle.permit)
    var journal = try loadOwnedJournal(handle)
    guard journal.phase == .replyMayBeVisible || journal.phase == .committed else {
      throw PairingAcceptancePersistenceError.invalidPhase(
        expected: PairingAcceptanceJournal.Phase.replyMayBeVisible.rawValue,
        actual: journal.phase.rawValue
      )
    }
    guard let plan = journal.plan else {
      throw PairingAcceptancePersistenceError.invalidJournal(
        transactionID: journal.transactionID,
        reason: "Reply-visible journal is missing its durable plan"
      )
    }
    try await verifyAfter(
      plan,
      permit: handle.permit,
      policyParticipant: policyParticipant,
      trustedDeviceStore: handle.trustedDeviceStore,
      kemStore: handle.kemStore,
      protocolStore: handle.protocolStore
    )
    if journal.phase != .committed {
      journal.phase = .committed
      try handle.journalStore.write(journal)
    }
    try simulateCrashIfRequested(
      .afterCommittedMarker,
      using: shouldSimulateCrash
    )
    try handle.journalStore.remove(permit: handle.permit)
    recoveryCompleted = true
  }

  static func abortBeforeReplyVisibility(
    _ handle: PairingAcceptancePersistenceHandle,
    policyParticipant: PairingPolicyAuthorityParticipant
  ) async throws {
    defer { PairingIdentityAuthorityMutationBarrier.release(handle.permit) }
    let journal = try loadOwnedJournal(handle)
    guard journal.phase != .replyMayBeVisible, journal.phase != .committed else {
      throw PairingAcceptancePersistenceError.invalidPhase(
        expected: "a phase before reply visibility",
        actual: journal.phase.rawValue
      )
    }
    try await convergeToBefore(
      journalStore: handle.journalStore,
      permit: handle.permit,
      policyParticipant: policyParticipant,
      trustedDeviceStore: handle.trustedDeviceStore,
      kemStore: handle.kemStore,
      protocolStore: handle.protocolStore,
      authorityJournalStore: handle.authorityJournalStore
    )
    recoveryCompleted = true
  }

  static func replyMayBeVisible(
    _ handle: PairingAcceptancePersistenceHandle
  ) -> Bool {
    guard let journal = try? loadOwnedJournal(handle) else { return false }
    return networkFailureDisposition(for: journal.phase) == .retainAfterVisibility
  }

  nonisolated static func networkFailureDisposition(
    for phase: PairingAcceptanceJournal.Phase
  ) -> PairingAcceptanceNetworkFailureDisposition {
    switch phase {
    case .replyMayBeVisible, .committed:
      return .retainAfterVisibility
    case .planning, .prepared, .applying, .rollingBack:
      return .rollbackBeforeVisibility
    }
  }

  nonisolated static func networkFailureDisposition(
    visibilityMarkerDurable: Bool,
    finalizationAttempted: Bool
  ) -> PairingAcceptanceNetworkFailureDisposition {
    if visibilityMarkerDurable, finalizationAttempted {
      return .leaveAfterJournalForRecovery
    }
    return visibilityMarkerDurable
      ? .retainAfterVisibility
      : .rollbackBeforeVisibility
  }

  private static func loadOwnedJournal(
    _ handle: PairingAcceptancePersistenceHandle
  ) throws -> PairingAcceptanceJournal {
    try PairingIdentityAuthorityMutationBarrier.validate(handle.permit)
    guard handle.journalStore.ownsActiveJournal(handle.permit),
      let journal = try handle.journalStore.load()
    else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }
    try validate(journal)
    return journal
  }

  private static func convergeToBefore(
    journalStore: PairingAcceptanceJournalStore,
    permit: PairingIdentityAuthorityMutationPermit,
    policyParticipant: PairingPolicyAuthorityParticipant,
    trustedDeviceStore: TrustedDeviceStore = .shared,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared,
    authorityJournalStore: AuthorityBoundPairingIdentityJournalStore? = nil
  ) async throws {
    let resolvedAuthorityJournalStore: AuthorityBoundPairingIdentityJournalStore
    if let authorityJournalStore {
      resolvedAuthorityJournalStore = authorityJournalStore
    } else {
      resolvedAuthorityJournalStore = try AuthorityBoundPairingIdentityJournalStore.defaultStore()
    }
    try PairingIdentityAuthorityMutationBarrier.validate(permit)
    guard var journal = try journalStore.load(),
      journalStore.ownsActiveJournal(permit)
    else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }
    try validate(journal)
    guard let plan = journal.plan else {
      guard journal.phase == .planning else {
        throw PairingAcceptancePersistenceError.invalidJournal(
          transactionID: journal.transactionID,
          reason: "Only a planning journal may omit its mutation plan"
        )
      }
      try journalStore.remove(permit: permit)
      return
    }

    if journal.phase != .rollingBack {
      journal.phase = .rollingBack
      try journalStore.write(journal)
    }
    try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
      kemStore: kemStore,
      protocolStore: protocolStore,
      journalStore: resolvedAuthorityJournalStore
    )

    if try !policyParticipant.pairingPolicySnapshotMatches(
      plan.pairingPolicyBefore,
      outerPermit: permit
    ) {
      try policyParticipant.restorePairingPolicySnapshot(
        plan.pairingPolicyBefore,
        expectedCurrent: [plan.pairingPolicyBefore, plan.pairingPolicyAfter],
        outerPermit: permit
      )
    }
    if try !trustedDeviceStore.pairingAcceptanceSnapshotMatches(
      plan.trustedDeviceBefore,
      outerPermit: permit
    ) {
      try trustedDeviceStore.restorePairingAcceptanceSnapshot(
        plan.trustedDeviceBefore,
        expectedCurrent: [plan.trustedDeviceBefore, plan.trustedDeviceAfter],
        outerPermit: permit
      )
    }

    if try await AuthorityBoundPairingIdentityPersistence.receiptMatchesCommitted(
      plan.authority,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) {
      try await AuthorityBoundPairingIdentityPersistence.rollback(
        plan.authority,
        kemStore: kemStore,
        protocolStore: protocolStore,
        journalStore: resolvedAuthorityJournalStore,
        shouldSimulateCrash: { _ in false }
      )
    }
    guard try await AuthorityBoundPairingIdentityPersistence.receiptMatchesRolledBack(
      plan.authority,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "authority before image")
    }
    try verifyBefore(
      plan,
      permit: permit,
      policyParticipant: policyParticipant,
      trustedDeviceStore: trustedDeviceStore
    )
    try journalStore.remove(permit: permit)
  }

  private static func convergeToAfter(
    journalStore: PairingAcceptanceJournalStore,
    permit: PairingIdentityAuthorityMutationPermit,
    policyParticipant: PairingPolicyAuthorityParticipant,
    trustedDeviceStore: TrustedDeviceStore = .shared,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared,
    authorityJournalStore: AuthorityBoundPairingIdentityJournalStore? = nil
  ) async throws {
    let resolvedAuthorityJournalStore: AuthorityBoundPairingIdentityJournalStore
    if let authorityJournalStore {
      resolvedAuthorityJournalStore = authorityJournalStore
    } else {
      resolvedAuthorityJournalStore = try AuthorityBoundPairingIdentityJournalStore.defaultStore()
    }
    guard var journal = try journalStore.load(),
      journalStore.ownsActiveJournal(permit),
      let plan = journal.plan
    else {
      throw PairingAcceptanceJournalStoreError.invalidPermit
    }
    try validate(journal)
    try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
      kemStore: kemStore,
      protocolStore: protocolStore,
      journalStore: resolvedAuthorityJournalStore
    )
    if try await !AuthorityBoundPairingIdentityPersistence.receiptMatchesCommitted(
      plan.authority,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) {
      try await AuthorityBoundPairingIdentityPersistence.rollForward(
        plan.authority,
        kemStore: kemStore,
        protocolStore: protocolStore
      )
    }
    guard try await AuthorityBoundPairingIdentityPersistence.receiptMatchesCommitted(
      plan.authority,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "authority after image")
    }
    if try !trustedDeviceStore.pairingAcceptanceSnapshotMatches(
      plan.trustedDeviceAfter,
      outerPermit: permit
    ) {
      try trustedDeviceStore.restorePairingAcceptanceSnapshot(
        plan.trustedDeviceAfter,
        expectedCurrent: [plan.trustedDeviceBefore, plan.trustedDeviceAfter],
        outerPermit: permit
      )
    }
    if try !policyParticipant.pairingPolicySnapshotMatches(
      plan.pairingPolicyAfter,
      outerPermit: permit
    ) {
      try policyParticipant.restorePairingPolicySnapshot(
        plan.pairingPolicyAfter,
        expectedCurrent: [plan.pairingPolicyBefore, plan.pairingPolicyAfter],
        outerPermit: permit
      )
    }
    try await verifyAfter(
      plan,
      permit: permit,
      policyParticipant: policyParticipant,
      trustedDeviceStore: trustedDeviceStore,
      kemStore: kemStore,
      protocolStore: protocolStore
    )
    if journal.phase != .committed {
      journal.phase = .committed
      try journalStore.write(journal)
    }
    try journalStore.remove(permit: permit)
  }

  private static func verifyBefore(
    _ plan: PairingAcceptanceJournal.Plan,
    permit: PairingIdentityAuthorityMutationPermit,
    policyParticipant: PairingPolicyAuthorityParticipant,
    trustedDeviceStore: TrustedDeviceStore = .shared
  ) throws {
    guard try trustedDeviceStore.pairingAcceptanceSnapshotMatches(
      plan.trustedDeviceBefore,
      outerPermit: permit
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "trusted-device before image")
    }
    guard try policyParticipant.pairingPolicySnapshotMatches(
      plan.pairingPolicyBefore,
      outerPermit: permit
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "pairing-policy before image")
    }
  }

  private static func verifyAfter(
    _ plan: PairingAcceptanceJournal.Plan,
    permit: PairingIdentityAuthorityMutationPermit,
    policyParticipant: PairingPolicyAuthorityParticipant,
    trustedDeviceStore: TrustedDeviceStore = .shared,
    kemStore: KEMTrustStore = .shared,
    protocolStore: ProtocolIdentityTrustStore = .shared
  ) async throws {
    guard try await AuthorityBoundPairingIdentityPersistence.receiptMatchesCommitted(
      plan.authority,
      kemStore: kemStore,
      protocolStore: protocolStore
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "authority after image")
    }
    guard try trustedDeviceStore.pairingAcceptanceSnapshotMatches(
      plan.trustedDeviceAfter,
      outerPermit: permit
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "trusted-device after image")
    }
    guard try policyParticipant.pairingPolicySnapshotMatches(
      plan.pairingPolicyAfter,
      outerPermit: permit
    ) else {
      throw PairingAcceptancePersistenceError.stateMismatch(component: "pairing-policy after image")
    }
  }

  private static func simulateCrashIfRequested(
    _ point: PairingAcceptancePersistenceCrashPoint,
    using predicate: @Sendable (PairingAcceptancePersistenceCrashPoint) -> Bool
  ) throws {
    if predicate(point) {
      recoveryCompleted = false
      throw PairingAcceptancePersistenceSimulatedCrash(point: point)
    }
  }

  private static func validate(_ journal: PairingAcceptanceJournal) throws {
    let normalizedKey = journal.canonicalAcceptanceKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard journal.schemaVersion == PairingAcceptanceJournal.currentSchemaVersion,
      !normalizedKey.isEmpty,
      journal.acceptedMaterialDigest.count == SHA256.byteCount
    else {
      throw PairingAcceptancePersistenceError.invalidJournal(
        transactionID: journal.transactionID,
        reason: "Metadata is internally inconsistent"
      )
    }

    switch journal.phase {
    case .planning:
      guard journal.plan == nil,
        !journal.authorityApplied,
        !journal.trustedDeviceApplied,
        !journal.pairingPolicyApplied
      else {
        throw invalidProgress(journal)
      }
    case .prepared:
      guard journal.plan != nil,
        !journal.authorityApplied,
        !journal.trustedDeviceApplied,
        !journal.pairingPolicyApplied
      else {
        throw invalidProgress(journal)
      }
    case .applying, .rollingBack:
      guard journal.plan != nil else { throw invalidProgress(journal) }
    case .replyMayBeVisible, .committed:
      guard journal.plan != nil,
        journal.authorityApplied,
        journal.trustedDeviceApplied,
        journal.pairingPolicyApplied
      else {
        throw invalidProgress(journal)
      }
    }
  }

  private static func invalidProgress(
    _ journal: PairingAcceptanceJournal
  ) -> PairingAcceptancePersistenceError {
    .invalidJournal(
      transactionID: journal.transactionID,
      reason: "Phase and participant progress are inconsistent"
    )
  }
}
