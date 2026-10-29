import Foundation
@testable import SkyBridgeCore

/// A per-test logical Keychain namespace for PQC identities and backend claims.
///
/// The production code still resolves its signed shared-group entitlement.
/// Tests inject this explicit scope so parallel cases cannot observe or mutate
/// one another's canonical keys or backend authority.
struct PQCKeychainTestContext: Sendable {
    let scope: KeychainGenericPasswordScope
    let scopeSource: SkyBridgeSharedIdentityScopeSource

    init(includeLegacyUnscoped: Bool = false) {
        let accessGroup = "group.com.skybridge.tests.pqc.\(UUID().uuidString)"
        let readAccessGroups: [String?] = includeLegacyUnscoped
            ? [accessGroup, nil]
            : [accessGroup]
        let scope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: readAccessGroups,
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        self.scope = scope
        self.scopeSource = .explicitForTesting(scope)
    }

    var storageScope: PQCKeyPairStoreStorageScope {
        PQCKeyPairStoreStorageScope(
            canonicalLocation: nil,
            keychainScopeSource: scopeSource,
            includeLegacyKeychain: true
        )
    }
}

/// An isolated DeviceIdentityKeyManager fixture backed by a per-test Keychain
/// namespace. Tests must call `reset()` during teardown so neither canonical
/// records nor migration mirrors survive the case that created them.
struct DeviceIdentityKeychainTestContext: Sendable {
    let namespace: String
    let scope: KeychainGenericPasswordScope
    let manager: DeviceIdentityKeyManager

    init(namespace: String = UUID().uuidString) throws {
        let accessGroup = "group.com.skybridge.tests.device-identity.\(namespace)"
        let scope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        self.namespace = namespace
        self.scope = scope
        self.manager = try DeviceIdentityKeyManager(
            testingStorageNamespace: namespace,
            keychainScope: scope
        )
    }

    func reset() throws {
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
    }
}
