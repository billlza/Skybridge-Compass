import Foundation
import SkyBridgeBoundSessionRuntime

/// Uses the exact shared group already resolved by the protocol identity store.
/// Both native record encoding and initialization state remain in shared Rust.
struct BoundSessionInitializationKeychainStore: BoundSessionInitializationStore {
    private let accessGroup: String

    init(identityStore: IOSProtocolIdentityKeychainStore) {
        accessGroup = identityStore.immutableRecordAccessGroup
    }

    func load(scope: Data, slot: BoundSessionInitializationSlot) throws -> Data? {
        let account = try BoundSessionInitializationNative.keychainAccount(scope: scope, slot: slot)
        let value = try KeychainManager.shared.loadImmutableKeyStrict(
            service: BoundSessionInitializationNative.keychainService,
            account: account,
            accessGroup: accessGroup
        )
        if let value { try BoundSessionInitializationNative.validateRecord(value) }
        return value
    }

    func insertIfAbsent(_ value: Data, scope: Data, slot: BoundSessionInitializationSlot) throws -> Bool {
        try BoundSessionInitializationNative.validateRecord(value)
        let account = try BoundSessionInitializationNative.keychainAccount(scope: scope, slot: slot)
        switch try KeychainManager.shared.insertImmutableKeyIfAbsent(
            data: value,
            service: BoundSessionInitializationNative.keychainService,
            account: account,
            accessGroup: accessGroup
        ) {
        case .inserted: return true
        case .alreadyExists: return false
        }
    }
}
