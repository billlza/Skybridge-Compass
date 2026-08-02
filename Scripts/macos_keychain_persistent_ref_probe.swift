import Foundation
import LocalAuthentication
import Security
import Darwin

#if os(macOS)
private enum ProbeFailure: Error, CustomStringConvertible {
    case security(operation: String, status: OSStatus)
    case malformedResult(operation: String)
    case invariant(String)

    var description: String {
        switch self {
        case .security(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "\(operation) failed with OSStatus \(status): \(detail)"
        case .malformedResult(let operation):
            return "\(operation) returned a malformed Security.framework result"
        case .invariant(let message):
            return message
        }
    }
}

private struct KeychainDomain {
    let name: String
    let usesDataProtectionKeychain: Bool

    func apply(to query: inout [String: Any]) {
        query[kSecUseDataProtectionKeychain as String] =
            usesDataProtectionKeychain
    }
}

private let legacyDomain = KeychainDomain(
    name: "legacy-file-keychain",
    usesDataProtectionKeychain: false
)
private let dataProtectionDomain = KeychainDomain(
    name: "data-protection-keychain",
    usesDataProtectionKeychain: true
)
private let service = "com.skybridge.release-probe.persistent-ref.v1"
private let account = "identity"
private let privateKeyTag = Data(
    "com.skybridge.release-probe.private-key.v1".utf8
)
private let migratedLegacyPrivateKeyTag = Data(
    "com.skybridge.release-probe.migrated.legacy.v1".utf8
)
private let migratedDataProtectionPrivateKeyTag = Data(
    "com.skybridge.release-probe.migrated.dp.v1".utf8
)
private let authorityService =
    "com.skybridge.release-probe.identity-authority.v1"
private let runLockPath = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "com.skybridge.release-probe.persistent-ref.v1.lock",
        isDirectory: false
    )
    .path

private final class ProbeRunLock {
    private let descriptor: Int32

    init() throws {
        let opened = Darwin.open(
            runLockPath,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            throw ProbeFailure.invariant(
                "failed to acquire the exclusive probe run lock: \(String(cString: strerror(errno)))"
            )
        }
        descriptor = opened
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { buffer in
        _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
    }
    data.removeAll(keepingCapacity: false)
}

private func forbidAuthenticationUI(_ query: inout [String: Any]) {
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
}

private func removeUniqueProbeItems(in domain: KeychainDomain) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProbeFailure.security(
            operation: "cleanup \(domain.name) generic-password item",
            status: status
        )
    }
}

private func add(
    _ value: Data,
    in domain: KeychainDomain
) throws -> Data {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
        kSecValueData as String: value,
        kSecReturnPersistentRef as String: true,
    ]
    if domain.usesDataProtectionKeychain {
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    domain.apply(to: &query)

    var result: CFTypeRef?
    let status = SecItemAdd(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "add \(domain.name) item",
            status: status
        )
    }
    guard let persistentReference = result as? Data,
          !persistentReference.isEmpty else {
        throw ProbeFailure.malformedResult(
            operation: "add \(domain.name) item"
        )
    }
    return persistentReference
}

private func loadUniqueProbeValues(
    in domain: KeychainDomain
) throws -> [Data] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
        kSecReturnData as String: true,
        kSecMatchLimit as String: domain.usesDataProtectionKeychain
            ? kSecMatchLimitAll
            : kSecMatchLimitOne,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        if let values = result as? [Data] {
            return values
        }
        if let value = result as? Data {
            return [value]
        }
        throw ProbeFailure.malformedResult(
            operation: "load unique \(domain.name) probe items"
        )
    case errSecItemNotFound:
        return []
    default:
        throw ProbeFailure.security(
            operation: "load unique \(domain.name) probe items",
            status: status
        )
    }
}

/// Mirrors the production legacy-identity two-phase discovery shape. The broad
/// read returns only attributes and exact persistent references; secret data is
/// then loaded through the selected reference because the legacy file Keychain
/// rejects the combined broad query with `errSecParam`.
private func loadLegacyDiscoveryRows(
    in domain: KeychainDomain
) throws -> Int {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
        kSecReturnAttributes as String: true,
        kSecReturnPersistentRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "load production-shaped \(domain.name) discovery rows",
            status: status
        )
    }
    let rows: [[String: Any]]
    if let values = result as? [[String: Any]] {
        rows = values
    } else if let value = result as? [String: Any] {
        rows = [value]
    } else {
        throw ProbeFailure.malformedResult(
            operation: "load production-shaped \(domain.name) discovery rows"
        )
    }
    for row in rows {
        guard let persistentReference = row[kSecValuePersistentRef as String] as? Data,
              !persistentReference.isEmpty else {
            throw ProbeFailure.malformedResult(
                operation: "load production-shaped \(domain.name) discovery rows"
            )
        }
        if domain.usesDataProtectionKeychain {
            guard let accessGroup = row[kSecAttrAccessGroup as String] as? String,
                  !accessGroup.isEmpty else {
                throw ProbeFailure.malformedResult(
                    operation: "load production-shaped \(domain.name) discovery rows"
                )
            }
        }
        guard try loadGenericPassword(
            persistentReference: persistentReference,
            in: domain
        ) != nil else {
            throw ProbeFailure.invariant(
                "production-shaped \(domain.name) discovery row disappeared"
            )
        }
    }
    return rows.count
}

private func delete(
    persistentReference: Data,
    in domain: KeychainDomain
) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchItemList as String: [persistentReference],
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "delete \(domain.name) item by persistent reference",
            status: status
        )
    }
}

private func loadGenericPassword(
    persistentReference: Data,
    in domain: KeychainDomain
) throws -> Data? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchItemList as String: [persistentReference],
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard let value = result as? Data else {
            throw ProbeFailure.malformedResult(
                operation: "load \(domain.name) password by persistent reference"
            )
        }
        return value
    case errSecItemNotFound:
        return nil
    default:
        throw ProbeFailure.security(
            operation: "load \(domain.name) password by persistent reference",
            status: status
        )
    }
}

private func removeUniqueProbePrivateKey(in domain: KeychainDomain) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: privateKeyTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProbeFailure.security(
            operation: "cleanup \(domain.name) private key",
            status: status
        )
    }
}

private func createPrivateKey(in domain: KeychainDomain) throws {
    var privateAttributes: [String: Any] = [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: privateKeyTag,
    ]
    if domain.usesDataProtectionKeychain {
        privateAttributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        privateAttributes[kSecAttrSynchronizable as String] = false
    }
    var attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: privateAttributes,
    ]
    domain.apply(to: &attributes)

    var error: Unmanaged<CFError>?
    guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
        let detail = error?.takeRetainedValue().localizedDescription
            ?? "unknown Security.framework error"
        throw ProbeFailure.invariant(
            "create \(domain.name) private key failed: \(detail)"
        )
    }
}

private func privateKeyPersistentReference(
    in domain: KeychainDomain
) throws -> Data {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: privateKeyTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecReturnPersistentRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "discover \(domain.name) private-key persistent reference",
            status: status
        )
    }
    guard let persistentReference = result as? Data,
          !persistentReference.isEmpty else {
        throw ProbeFailure.malformedResult(
            operation: "discover \(domain.name) private-key persistent reference"
        )
    }
    return persistentReference
}

private func loadPrivateKey(
    persistentReference: Data,
    in domain: KeychainDomain
) throws -> SecKey? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecMatchItemList as String: [persistentReference],
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw ProbeFailure.malformedResult(
                operation: "load \(domain.name) private key by persistent reference"
            )
        }
        return unsafeDowncast(result, to: SecKey.self)
    case errSecItemNotFound:
        return nil
    default:
        throw ProbeFailure.security(
            operation: "load \(domain.name) private key by persistent reference",
            status: status
        )
    }
}

private func privateKeyExists(
    tag: Data,
    in domain: KeychainDomain,
    accessGroup: String? = nil
) throws -> Bool {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
    ]
    if let accessGroup {
        query[kSecAttrAccessGroup as String] = accessGroup
    }
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard result != nil else {
            throw ProbeFailure.malformedResult(
                operation: "inspect \(domain.name) private key"
            )
        }
        return true
    case errSecItemNotFound:
        return false
    default:
        throw ProbeFailure.security(
            operation: "inspect \(domain.name) private key",
            status: status
        )
    }
}

private func deletePrivateKey(
    persistentReference: Data,
    in domain: KeychainDomain
) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecMatchItemList as String: [persistentReference],
    ]
    domain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "delete \(domain.name) private key by persistent reference",
            status: status
        )
    }
}

private func requiredSharedAccessGroup() throws -> String {
    guard let task = SecTaskCreateFromSelf(nil),
          let entitlement = SecTaskCopyValueForEntitlement(
              task,
              "keychain-access-groups" as CFString,
              nil
          ),
          let accessGroups = entitlement as? [String],
          let shared = accessGroups.first(where: {
              $0.hasSuffix(".group.com.skybridge.compass")
          }) else {
        throw ProbeFailure.invariant(
            "signed probe is missing the shared SkyBridge Keychain access group"
        )
    }
    return shared
}

private func removeMigratedPrivateKey(
    tag: Data,
    accessGroup: String
) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrAccessGroup as String: accessGroup,
    ]
    dataProtectionDomain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProbeFailure.security(
            operation: "cleanup migrated shared-group private key",
            status: status
        )
    }
}

private func removeAuthority(
    account: String,
    accessGroup: String
) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: authorityService,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: accessGroup,
        kSecAttrSynchronizable as String: false,
    ]
    dataProtectionDomain.apply(to: &query)
    forbidAuthenticationUI(&query)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProbeFailure.security(
            operation: "cleanup identity authority \(account)",
            status: status
        )
    }
}

private func authorityExists(
    account: String,
    accessGroup: String
) throws -> Bool {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: authorityService,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: accessGroup,
        kSecAttrSynchronizable as String: false,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
    ]
    dataProtectionDomain.apply(to: &query)
    forbidAuthenticationUI(&query)
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard result != nil else {
            throw ProbeFailure.malformedResult(
                operation: "inspect identity authority \(account)"
            )
        }
        return true
    case errSecItemNotFound:
        return false
    default:
        throw ProbeFailure.security(
            operation: "inspect identity authority \(account)",
            status: status
        )
    }
}

private func externalRepresentation(of key: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let representation = SecKeyCopyExternalRepresentation(
        key,
        &error
    ) as Data? else {
        let detail = error?.takeRetainedValue().localizedDescription
            ?? "unknown Security.framework error"
        throw ProbeFailure.invariant(
            "private-key export failed: \(detail)"
        )
    }
    return representation
}

private func publicRepresentation(of privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        throw ProbeFailure.invariant("private key did not expose its public key")
    }
    return try externalRepresentation(of: publicKey)
}

private func insertMigratedPrivateKey(
    representation: Data,
    tag: Data,
    accessGroup: String
) throws {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrIsPermanent as String: true,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrSynchronizable as String: false,
        kSecAttrAccessGroup as String: accessGroup,
        kSecValueData as String: representation,
    ]
    dataProtectionDomain.apply(to: &query)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "insert migrated shared-group private key",
            status: status
        )
    }
}

private func loadMigratedPrivateKey(
    tag: Data,
    accessGroup: String
) throws -> SecKey {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrAccessGroup as String: accessGroup,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    dataProtectionDomain.apply(to: &query)
    forbidAuthenticationUI(&query)

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        throw ProbeFailure.security(
            operation: "reload migrated shared-group private key",
            status: status
        )
    }
    guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
        throw ProbeFailure.malformedResult(
            operation: "reload migrated shared-group private key"
        )
    }
    return unsafeDowncast(result, to: SecKey.self)
}

private func claimAuthority(
    record: Data,
    account: String,
    accessGroup: String
) throws {
    var addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: authorityService,
        kSecAttrAccount as String: account,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrSynchronizable as String: false,
        kSecAttrAccessGroup as String: accessGroup,
        kSecValueData as String: record,
    ]
    dataProtectionDomain.apply(to: &addQuery)
    guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
        throw ProbeFailure.invariant("authority add-only CAS did not insert")
    }
    guard SecItemAdd(addQuery as CFDictionary, nil) == errSecDuplicateItem else {
        throw ProbeFailure.invariant("authority add-only CAS replaced its winner")
    }

    var loadQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: authorityService,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: accessGroup,
        kSecAttrSynchronizable as String: false,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    dataProtectionDomain.apply(to: &loadQuery)
    forbidAuthenticationUI(&loadQuery)
    var result: CFTypeRef?
    let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
    guard status == errSecSuccess, result as? Data == record else {
        throw ProbeFailure.security(
            operation: "reload authority CAS winner",
            status: status
        )
    }
}

private func provePrivateKeyMigration(
    sourceReference: Data,
    sourceDomain: KeychainDomain,
    destinationTag: Data,
    authorityAccount: String,
    accessGroup: String
) throws {
    guard let sourceKey = try loadPrivateKey(
        persistentReference: sourceReference,
        in: sourceDomain
    ) else {
        throw ProbeFailure.invariant("legacy migration source disappeared")
    }
    let sourcePublicKey = try publicRepresentation(of: sourceKey)
    var sourcePrivateKey = try externalRepresentation(of: sourceKey)
    defer { wipe(&sourcePrivateKey) }
    try insertMigratedPrivateKey(
        representation: sourcePrivateKey,
        tag: destinationTag,
        accessGroup: accessGroup
    )
    let migratedKey = try loadMigratedPrivateKey(
        tag: destinationTag,
        accessGroup: accessGroup
    )
    try require(
        try publicRepresentation(of: migratedKey) == sourcePublicKey,
        "migrated private key derived a different public identity"
    )
    try claimAuthority(
        record: sourcePublicKey,
        account: authorityAccount,
        accessGroup: accessGroup
    )
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw ProbeFailure.invariant(message)
    }
}

private func describe(_ values: [Data]) -> String {
    values.map { String(data: $0, encoding: .utf8) ?? $0.base64EncodedString() }
        .joined(separator: ",")
}

private func withVerifiedCleanup(
    label: String,
    cleanup: () throws -> Void,
    verifyAbsent: () throws -> Void,
    operation: () throws -> Void
) throws {
    try cleanup()
    try verifyAbsent()
    do {
        try operation()
    } catch {
        do {
            try cleanup()
            try verifyAbsent()
        } catch let cleanupError {
            throw ProbeFailure.invariant(
                "\(label) failed with \(error); cleanup also failed with \(cleanupError)"
            )
        }
        throw error
    }
    try cleanup()
    try verifyAbsent()
}

private func cleanupGenericPasswordArtifacts() throws {
    try removeUniqueProbeItems(in: legacyDomain)
    try removeUniqueProbeItems(in: dataProtectionDomain)
}

private func verifyGenericPasswordArtifactsAbsent() throws {
    try require(
        try loadUniqueProbeValues(in: legacyDomain).isEmpty,
        "legacy generic-password probe artifact remained after cleanup"
    )
    try require(
        try loadUniqueProbeValues(in: dataProtectionDomain).isEmpty,
        "Data Protection generic-password probe artifact remained after cleanup"
    )
}

private func cleanupPrivateKeyArtifacts(accessGroup: String) throws {
    try removeUniqueProbePrivateKey(in: legacyDomain)
    try removeUniqueProbePrivateKey(in: dataProtectionDomain)
    try removeMigratedPrivateKey(
        tag: migratedLegacyPrivateKeyTag,
        accessGroup: accessGroup
    )
    try removeMigratedPrivateKey(
        tag: migratedDataProtectionPrivateKeyTag,
        accessGroup: accessGroup
    )
    try removeAuthority(account: "legacy", accessGroup: accessGroup)
    try removeAuthority(account: "data-protection", accessGroup: accessGroup)
}

private func verifyPrivateKeyArtifactsAbsent(accessGroup: String) throws {
    try require(
        try !privateKeyExists(tag: privateKeyTag, in: legacyDomain),
        "legacy source private-key probe artifact remained after cleanup"
    )
    try require(
        try !privateKeyExists(tag: privateKeyTag, in: dataProtectionDomain),
        "Data Protection source private-key probe artifact remained after cleanup"
    )
    try require(
        try !privateKeyExists(
            tag: migratedLegacyPrivateKeyTag,
            in: dataProtectionDomain,
            accessGroup: accessGroup
        ),
        "legacy migrated private-key probe artifact remained after cleanup"
    )
    try require(
        try !privateKeyExists(
            tag: migratedDataProtectionPrivateKeyTag,
            in: dataProtectionDomain,
            accessGroup: accessGroup
        ),
        "Data Protection migrated private-key probe artifact remained after cleanup"
    )
    try require(
        try !authorityExists(account: "legacy", accessGroup: accessGroup),
        "legacy authority probe artifact remained after cleanup"
    )
    try require(
        try !authorityExists(
            account: "data-protection",
            accessGroup: accessGroup
        ),
        "Data Protection authority probe artifact remained after cleanup"
    )
}

private func runGenericPasswordProbeBody() throws {
    let legacyValue = Data("legacy-domain".utf8)
    let dataProtectionValue = Data("data-protection-domain".utf8)

    let legacyReference = try add(legacyValue, in: legacyDomain)
    let legacyValuesBeforeDataProtectionInsert = try loadUniqueProbeValues(
        in: legacyDomain
    )
    try require(
        legacyValuesBeforeDataProtectionInsert == [legacyValue],
        "legacy domain failed before the Data Protection insert: "
            + describe(legacyValuesBeforeDataProtectionInsert)
    )
    let dataProtectionReference = try add(
        dataProtectionValue,
        in: dataProtectionDomain
    )
    try require(
        legacyReference != dataProtectionReference,
        "separate Keychain domains unexpectedly returned the same persistent reference"
    )
    try require(
        try loadGenericPassword(
            persistentReference: legacyReference,
            in: legacyDomain
        ) == legacyValue,
        "legacy item could not be freshly compared by persistent reference"
    )
    try require(
        try loadGenericPassword(
            persistentReference: dataProtectionReference,
            in: dataProtectionDomain
        ) == dataProtectionValue,
        "Data Protection item could not be freshly compared by persistent reference"
    )
    let initialLegacyValues = try loadUniqueProbeValues(in: legacyDomain)
    try require(
        initialLegacyValues == [legacyValue],
        "legacy domain returned unexpected values: \(describe(initialLegacyValues))"
    )
    let initialDataProtectionValues = try loadUniqueProbeValues(
        in: dataProtectionDomain
    )
    try require(
        initialDataProtectionValues == [dataProtectionValue],
        "Data Protection domain returned unexpected values: "
            + describe(initialDataProtectionValues)
    )
    try require(
        try loadLegacyDiscoveryRows(in: legacyDomain) == 1,
        "legacy production-shaped discovery did not return exactly one row"
    )
    try require(
        try loadLegacyDiscoveryRows(in: dataProtectionDomain) == 1,
        "Data Protection production-shaped discovery did not return exactly one row"
    )

    try delete(persistentReference: legacyReference, in: legacyDomain)
    try require(
        try loadUniqueProbeValues(in: legacyDomain).isEmpty,
        "legacy exact delete left the selected item behind"
    )
    try require(
        try loadUniqueProbeValues(in: dataProtectionDomain)
            == [dataProtectionValue],
        "legacy exact delete mutated the Data Protection domain"
    )

    try delete(
        persistentReference: dataProtectionReference,
        in: dataProtectionDomain
    )
    try require(
        try loadUniqueProbeValues(in: dataProtectionDomain).isEmpty,
        "Data Protection exact delete left the selected item behind"
    )
}

private func runGenericPasswordProbe() throws {
    try withVerifiedCleanup(
        label: "generic-password persistent-reference probe",
        cleanup: cleanupGenericPasswordArtifacts,
        verifyAbsent: verifyGenericPasswordArtifactsAbsent,
        operation: runGenericPasswordProbeBody
    )
}

private func runPrivateKeyProbeBody(accessGroup: String) throws {
    try createPrivateKey(in: legacyDomain)
    let legacyReference = try privateKeyPersistentReference(in: legacyDomain)
    try require(
        try loadPrivateKey(
            persistentReference: legacyReference,
            in: legacyDomain
        ) != nil,
        "legacy private key could not be reloaded by persistent reference"
    )

    try createPrivateKey(in: dataProtectionDomain)
    let dataProtectionReference = try privateKeyPersistentReference(
        in: dataProtectionDomain
    )
    try require(
        legacyReference != dataProtectionReference,
        "separate private-key domains returned the same persistent reference"
    )
    try require(
        try loadPrivateKey(
            persistentReference: dataProtectionReference,
            in: dataProtectionDomain
        ) != nil,
        "Data Protection private key could not be reloaded by persistent reference"
    )

    try provePrivateKeyMigration(
        sourceReference: legacyReference,
        sourceDomain: legacyDomain,
        destinationTag: migratedLegacyPrivateKeyTag,
        authorityAccount: "legacy",
        accessGroup: accessGroup
    )
    try provePrivateKeyMigration(
        sourceReference: dataProtectionReference,
        sourceDomain: dataProtectionDomain,
        destinationTag: migratedDataProtectionPrivateKeyTag,
        authorityAccount: "data-protection",
        accessGroup: accessGroup
    )

    try deletePrivateKey(
        persistentReference: legacyReference,
        in: legacyDomain
    )
    try require(
        try loadPrivateKey(
            persistentReference: legacyReference,
            in: legacyDomain
        ) == nil,
        "legacy private-key exact delete left the selected key behind"
    )
    try require(
        try loadPrivateKey(
            persistentReference: dataProtectionReference,
            in: dataProtectionDomain
        ) != nil,
        "legacy private-key exact delete mutated the Data Protection domain"
    )

    try deletePrivateKey(
        persistentReference: dataProtectionReference,
        in: dataProtectionDomain
    )
    try require(
        try loadPrivateKey(
            persistentReference: dataProtectionReference,
            in: dataProtectionDomain
        ) == nil,
        "Data Protection private-key exact delete left the selected key behind"
    )
}

private func runPrivateKeyProbe() throws {
    let accessGroup = try requiredSharedAccessGroup()
    try withVerifiedCleanup(
        label: "private-key migration probe",
        cleanup: {
            try cleanupPrivateKeyArtifacts(accessGroup: accessGroup)
        },
        verifyAbsent: {
            try verifyPrivateKeyArtifactsAbsent(accessGroup: accessGroup)
        },
        operation: {
            try runPrivateKeyProbeBody(accessGroup: accessGroup)
        }
    )
}

do {
    let runLock = try ProbeRunLock()
    try withExtendedLifetime(runLock) {
        try runGenericPasswordProbe()
        try runPrivateKeyProbe()
    }
    print("[macos-keychain-persistent-ref-probe] passed")
} catch {
    fputs("[macos-keychain-persistent-ref-probe] \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
#else
#error("The persistent-reference integration probe is macOS-only")
#endif
