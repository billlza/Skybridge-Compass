import Foundation
import LocalAuthentication
import Security

/// Data Protection Keychain only. The legacy macOS shim does not provide the
/// required conditional-update semantics. Missing entitlement/locked storage is
/// an error, never a reason to fall back to that backend or an unprotected file.
public struct DataProtectionAccountSessionStorage: ProtectedAccountSessionStorage {
    private let service: String
    private let account: String
    private let accessGroup: String
    private static let maximumEncodedBytes = 256 * 1024

    /// All operations bind one explicit, provisioned group. Omitting this value
    /// from a query would search every group accessible to the host, even though
    /// an insert without it uses only the default group.
    public init(service: String, account: String, accessGroup: String) throws {
        for value in [service, account, accessGroup] {
            guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0"),
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ProtectedAccountSessionError.invalidRecord
            }
        }
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }

    public func load() throws -> ProtectedAccountSessionValue? {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status)
        guard let fields = result as? [String: Any],
              let revisionData = fields[kSecAttrGeneric as String] as? Data,
              let revisionText = String(data: revisionData, encoding: .utf8),
              let revision = UUID(uuidString: revisionText), revision.uuidString == revisionText,
              let data = fields[kSecValueData as String] as? Data,
              fields[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String else {
            throw ProtectedAccountSessionError.invalidRecord
        }
        let value = ProtectedAccountSessionValue(revision: revision, data: data)
        try validate(value)
        return value
    }

    public func insert(_ value: ProtectedAccountSessionValue) throws -> Bool {
        try validate(value)
        var query = query()
        query[kSecAttrGeneric as String] = Data(value.revision.uuidString.utf8)
        query[kSecValueData as String] = value.data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try requireSuccess(status)
        return true
    }

    public func replace(expectedRevision: UUID, with value: ProtectedAccountSessionValue) throws -> Bool {
        try validate(value)
        guard expectedRevision != value.revision else { throw ProtectedAccountSessionError.invalidRecord }
        var query = query()
        query[kSecAttrGeneric as String] = Data(expectedRevision.uuidString.utf8)
        let status = SecItemUpdate(query as CFDictionary, [
            kSecAttrGeneric as String: Data(value.revision.uuidString.utf8),
            kSecValueData as String: value.data,
        ] as CFDictionary)
        if status == errSecItemNotFound { return false }
        try requireSuccess(status)
        return true
    }

    private func query() -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    private func validate(_ value: ProtectedAccountSessionValue) throws {
        guard value.revision != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              !value.data.isEmpty else { throw ProtectedAccountSessionError.invalidRecord }
        guard value.data.count <= Self.maximumEncodedBytes else { throw ProtectedAccountSessionError.capacity }
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ProtectedAccountSessionError.keychainStatus(status) }
    }
}
