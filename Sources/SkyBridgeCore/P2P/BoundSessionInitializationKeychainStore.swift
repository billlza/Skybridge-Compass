import Foundation
import SkyBridgeBoundSessionRuntime

/// The same authoritative access group as the committed protocol identity.
/// Never searches a legacy/unscoped item or converts a Keychain failure to nil.
/// The shared bridge borrows this synchronous adapter for one native call.
struct BoundSessionInitializationKeychainStore: BoundSessionInitializationStore {
    private let scope: KeychainGenericPasswordScope

    init() throws {
        scope = try SkyBridgeSharedIdentityScopeSource.requiredEntitlement
            .resolve().authoritativeOnly()
    }

    func load(scope peerScope: Data, slot: BoundSessionInitializationSlot) throws -> Data? {
        let account = try BoundSessionInitializationNative.keychainAccount(scope: peerScope, slot: slot)
        let value = try KeychainManager.shared.exportKeyStrict(
            service: BoundSessionInitializationNative.keychainService,
            account: account,
            scope: scope,
            includeLegacyKeychain: false
        )
        if let value { try BoundSessionInitializationNative.validateRecord(value) }
        return value
    }

    func insertIfAbsent(_ value: Data, scope peerScope: Data, slot: BoundSessionInitializationSlot) throws -> Bool {
        try BoundSessionInitializationNative.validateRecord(value)
        let account = try BoundSessionInitializationNative.keychainAccount(scope: peerScope, slot: slot)
        switch try KeychainManager.shared.insertKeyIfAbsent(
            data: value,
            service: BoundSessionInitializationNative.keychainService,
            account: account,
            scope: scope
        ) {
        case .inserted: return true
        case .alreadyExists: return false
        }
    }
}
