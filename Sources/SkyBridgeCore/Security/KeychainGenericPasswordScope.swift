import Foundation
import os
import Security

/// A typed location for a generic-password Keychain item.
struct KeychainGenericPasswordLocation: Hashable, Sendable {
    let service: String
    let account: String
}

/// The exact Security.framework location returned by an intentionally broad
/// legacy discovery query. Omitting `kSecAttrAccessGroup` is discovery-only;
/// callers must use `persistentReference` for every subsequent mutation so a
/// nil access-group attribute can never become a broad delete.
struct LegacySecItemLocation: Hashable, Sendable {
    let actualAccessGroup: String?
    let usesDataProtectionKeychain: Bool
    let persistentReference: Data

    func applyPersistentReferenceMatch(
        to query: inout [String: Any]
    ) {
        // Callers must also provide the concrete kSecClass and, on macOS, the
        // explicit Data Protection domain selector. Security.framework rejects
        // an otherwise under-specified persistent-reference mutation.
        #if os(macOS)
        query[kSecMatchItemList as String] = [persistentReference]
        #else
        query[kSecValuePersistentRef as String] = persistentReference
        #endif
    }
}

/// The small accessibility subset required by immutable key-pair records.
enum KeychainGenericPasswordAccessibility: Sendable {
    case afterFirstUnlockThisDeviceOnly
}

enum KeychainGenericPasswordScopeError: Error, LocalizedError, Sendable, Equatable {
    case missingSharedIdentityAccessGroupEntitlement
    case invalidExplicitSharedIdentityScope
    case missingAuthoritativeWriteAccessGroup

    var errorDescription: String? {
        switch self {
        case .missingSharedIdentityAccessGroupEntitlement:
            return "The signed process is missing the shared SkyBridge identity Keychain access-group entitlement"
        case .invalidExplicitSharedIdentityScope:
            return "The explicitly injected shared identity Keychain scope is not an isolated shared-group scope"
        case .missingAuthoritativeWriteAccessGroup:
            return "An authoritative shared identity Keychain scope requires a concrete write access group"
        }
    }
}

/// Storage policy for one logical generic-password namespace.
///
/// `writeAccessGroup` selects the authoritative destination. `readAccessGroups`
/// supports a controlled shared-group migration search without making an
/// unscoped item authoritative when a scoped item already exists.
struct KeychainGenericPasswordScope: Sendable {
    static let applicationDefault = KeychainGenericPasswordScope(
        accessibility: .afterFirstUnlockThisDeviceOnly,
        writeAccessGroup: nil,
        readAccessGroups: [nil],
        usesDataProtectionKeychain: false,
        synchronizable: false
    )

    #if DEBUG || SKYBRIDGE_TESTING
    /// Test-only model of an app-private item stored in the modern Data
    /// Protection Keychain. Production shared-scope resolution cannot return
    /// this value because it has no write access group.
    static let unscopedDataProtectionForTesting = KeychainGenericPasswordScope(
        accessibility: .afterFirstUnlockThisDeviceOnly,
        writeAccessGroup: nil,
        readAccessGroups: [nil],
        usesDataProtectionKeychain: true,
        synchronizable: false
    )

    /// Exact shared-identity authority used only by the process-local test
    /// Keychain backend. A concrete synthetic group keeps the same
    /// authoritative-only invariants as production without requiring a test
    /// runner to carry the shipping app's signed entitlement.
    static let inMemorySharedIdentityForTesting = KeychainGenericPasswordScope
        .skyBridgeSharedIdentity(
            accessGroup: "__skybridge_test_shared_identity__"
        )
    #endif

    fileprivate static func skyBridgeSharedIdentity(
        accessGroup: String
    ) -> KeychainGenericPasswordScope {
        return KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
    }

    let accessibility: KeychainGenericPasswordAccessibility
    let writeAccessGroup: String?
    let readAccessGroups: [String?]
    let usesDataProtectionKeychain: Bool
    let synchronizable: Bool

    init(
        accessibility: KeychainGenericPasswordAccessibility,
        writeAccessGroup: String?,
        readAccessGroups: [String?],
        usesDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) {
        precondition(!readAccessGroups.isEmpty, "A Keychain scope requires at least one read access-group search scope")
        self.accessibility = accessibility
        self.writeAccessGroup = writeAccessGroup
        self.readAccessGroups = readAccessGroups
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        self.synchronizable = synchronizable
    }

    /// Restricts a shared storage policy to the one group that owns the
    /// cross-process identity. Authority claims and post-CAS winner reloads
    /// must never accept an unscoped legacy item as authoritative.
    func authoritativeOnly() throws -> KeychainGenericPasswordScope {
        guard let writeAccessGroup = writeAccessGroup?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !writeAccessGroup.isEmpty else {
            throw KeychainGenericPasswordScopeError.missingAuthoritativeWriteAccessGroup
        }
        return KeychainGenericPasswordScope(
            accessibility: accessibility,
            writeAccessGroup: writeAccessGroup,
            readAccessGroups: [writeAccessGroup],
            usesDataProtectionKeychain: usesDataProtectionKeychain,
            synchronizable: synchronizable
        )
    }
}

/// A delayed source for the one app/extension-shared identity scope.
/// Production resolves the signed entitlement; tests inject a concrete,
/// namespaced group without changing process-global state.
enum SkyBridgeSharedIdentityScopeSource: Sendable {
    case requiredEntitlement
    case explicitForTesting(KeychainGenericPasswordScope)

    func resolve() throws -> KeychainGenericPasswordScope {
        switch self {
        case .requiredEntitlement:
            let accessGroup = try SkyBridgeKeychainAccessGroupResolver.requiredSharedAccessGroup()
            return .skyBridgeSharedIdentity(accessGroup: accessGroup)
        case .explicitForTesting(let scope):
            guard let writeAccessGroup = scope.writeAccessGroup?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !writeAccessGroup.isEmpty,
            scope.readAccessGroups.first == writeAccessGroup,
            scope.usesDataProtectionKeychain,
            !scope.synchronizable else {
                throw KeychainGenericPasswordScopeError.invalidExplicitSharedIdentityScope
            }
            return scope
        }
    }
}

/// Resolves the product's app/extension shared Keychain group once per process.
/// The app-only access group is deliberately not accepted because it cannot be
/// the cross-process identity authority.
enum SkyBridgeKeychainAccessGroupResolver {
    private enum ResolutionState: Sendable {
        case unresolved
        case resolved(String?)
    }

    private nonisolated static let state = OSAllocatedUnfairLock(
        initialState: ResolutionState.unresolved
    )

    nonisolated static func preferredAccessGroup() -> String? {
        if case .resolved(let cached) = state.withLock({ $0 }) {
            return cached
        }

        var resolved: String?
        if let task = SecTaskCreateFromSelf(nil),
           let entitlement = SecTaskCopyValueForEntitlement(
               task,
               "keychain-access-groups" as CFString,
               nil
           ),
           let groups = entitlement as? [String] {
            resolved = sharedAccessGroup(from: groups)
        }

        let resolvedAccessGroup = resolved
        return state.withLock { current in
            switch current {
            case .unresolved:
                current = .resolved(resolvedAccessGroup)
                return resolvedAccessGroup
            case .resolved(let cached):
                return cached
            }
        }
    }

    nonisolated static func requiredSharedAccessGroup() throws -> String {
        guard let accessGroup = preferredAccessGroup() else {
            throw KeychainGenericPasswordScopeError.missingSharedIdentityAccessGroupEntitlement
        }
        return accessGroup
    }

    nonisolated static func requiredSharedAccessGroup(
        from signedAccessGroups: [String]
    ) throws -> String {
        guard let accessGroup = sharedAccessGroup(from: signedAccessGroups) else {
            throw KeychainGenericPasswordScopeError.missingSharedIdentityAccessGroupEntitlement
        }
        return accessGroup
    }

    private nonisolated static func sharedAccessGroup(
        from signedAccessGroups: [String]
    ) -> String? {
        signedAccessGroups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.hasSuffix(".group.com.skybridge.compass") }
    }
}
