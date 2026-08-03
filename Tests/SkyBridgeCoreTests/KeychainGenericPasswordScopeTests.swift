import Security
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class KeychainGenericPasswordScopeTests: XCTestCase {
    func testPersistentReferenceMatchingUsesTheCorrectKeychainDomainSelector() {
        let reference = Data([0x53, 0x42, 0x50, 0x52])

        var dataProtectionQuery: [String: Any] = [
            kSecMatchItemList as String: [Data([0x00])]
        ]
        LegacySecItemLocation(
            actualAccessGroup: "TEAM.group.com.skybridge.compass",
            usesDataProtectionKeychain: true,
            persistentReference: reference
        ).applyPersistentReferenceMatch(to: &dataProtectionQuery)
        XCTAssertEqual(
            dataProtectionQuery[kSecValuePersistentRef as String] as? Data,
            reference
        )
        XCTAssertNil(dataProtectionQuery[kSecMatchItemList as String])

        var fileKeychainQuery: [String: Any] = [
            kSecValuePersistentRef as String: Data([0x00])
        ]
        LegacySecItemLocation(
            actualAccessGroup: nil,
            usesDataProtectionKeychain: false,
            persistentReference: reference
        ).applyPersistentReferenceMatch(to: &fileKeychainQuery)
        XCTAssertEqual(
            fileKeychainQuery[kSecMatchItemList as String] as? [Data],
            [reference]
        )
        XCTAssertNil(fileKeychainQuery[kSecValuePersistentRef as String])
    }

    func testMissingOrAppOnlyAccessGroupFailsClosed() {
        XCTAssertThrowsError(
            try SkyBridgeKeychainAccessGroupResolver.requiredSharedAccessGroup(from: [])
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .missingSharedIdentityAccessGroupEntitlement
            )
        }
        XCTAssertThrowsError(
            try SkyBridgeKeychainAccessGroupResolver.requiredSharedAccessGroup(
                from: ["TEAMID.com.skybridge.compass.pro"]
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .missingSharedIdentityAccessGroupEntitlement
            )
        }
    }

    func testExplicitInMemorySharedScopeNeverWritesUnscoped() throws {
        let accessGroup = "com.skybridge.tests.shared-identity.\(UUID().uuidString)"
        let injectedScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        let scope = try SkyBridgeSharedIdentityScopeSource
            .explicitForTesting(injectedScope)
            .resolve()
        let service = "com.skybridge.tests.explicit-in-memory-scope"
        let account = UUID().uuidString
        defer {
            XCTAssertNoThrow(
                try KeychainManager.shared.deleteAPIKey(
                    service: service,
                    account: account,
                    scope: scope
                )
            )
        }

        XCTAssertEqual(scope.writeAccessGroup, accessGroup)
        XCTAssertEqual(scope.readAccessGroups.count, 2)
        XCTAssertEqual(scope.readAccessGroups[0], accessGroup)
        XCTAssertNil(scope.readAccessGroups[1])

        XCTAssertEqual(
            try KeychainManager.shared.insertKeyIfAbsent(
                data: Data([0x53, 0x42]),
                service: service,
                account: account,
                scope: scope
            ),
            .inserted
        )
        let discovered = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: false
            )
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered[0].location.actualAccessGroup, accessGroup)
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: service,
                account: account,
                scope: scope
            ),
            Data([0x53, 0x42])
        )
    }

    func testRequiredResolverSelectsOnlyTheNormalizedSharedGroup() throws {
        let resolved = try SkyBridgeKeychainAccessGroupResolver.requiredSharedAccessGroup(
            from: [
                "TEAMID.com.skybridge.compass.pro",
                "  TEAMID.group.com.skybridge.compass  ",
            ]
        )
        XCTAssertEqual(resolved, "TEAMID.group.com.skybridge.compass")
    }

    func testExplicitTestSourceRejectsUnscopedStorage() {
        XCTAssertThrowsError(
            try SkyBridgeSharedIdentityScopeSource
                .explicitForTesting(.applicationDefault)
                .resolve()
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .invalidExplicitSharedIdentityScope
            )
        }
    }

    func testAuthoritativeScopePreservesStoragePolicyAndRemovesLegacyReads() throws {
        let accessGroup = "group.com.skybridge.tests.authoritative.\(UUID().uuidString)"
        let migrationScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )

        let authoritativeScope = try migrationScope.authoritativeOnly()

        XCTAssertEqual(authoritativeScope.writeAccessGroup, accessGroup)
        XCTAssertEqual(authoritativeScope.readAccessGroups.count, 1)
        XCTAssertEqual(authoritativeScope.readAccessGroups[0], accessGroup)
        XCTAssertTrue(authoritativeScope.usesDataProtectionKeychain)
        XCTAssertFalse(authoritativeScope.synchronizable)
    }

    func testUnscopedStorageCannotBecomeAuthoritative() {
        XCTAssertThrowsError(
            try KeychainGenericPasswordScope.applicationDefault.authoritativeOnly()
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .missingAuthoritativeWriteAccessGroup
            )
        }
    }

    func testUnscopedSourceFailsAtAuthorityAndKeyPairStoreBoundaries() {
        let invalidSource = SkyBridgeSharedIdentityScopeSource
            .explicitForTesting(.applicationDefault)
        XCTAssertThrowsError(
            try PQCBackendAuthorityStore.load(
                domain: .testing(UUID().uuidString),
                scopeSource: invalidSource
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .invalidExplicitSharedIdentityScope
            )
        }

        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: UUID().uuidString,
            authority: .staged,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: nil,
                keychainScopeSource: invalidSource,
                includeLegacyKeychain: false
            )
        )
        XCTAssertThrowsError(
            try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: 1,
                privateKeyLength: 1,
                validatePair: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainGenericPasswordScopeError,
                .invalidExplicitSharedIdentityScope
            )
        }
    }

    func testLegacyDiscoveryAndPersistentReferenceDeletionKeepNamespacesIsolated() throws {
        let service = "com.skybridge.tests.legacy-exact.\(UUID().uuidString)"
        let account = "identity"
        let sharedGroup = "group.com.skybridge.tests.legacy-exact.\(UUID().uuidString)"
        let sharedScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: sharedGroup,
            readAccessGroups: [sharedGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        let sharedData = Data([0x11])
        let appPrivateData = Data([0x22])
        let legacyNoGroupData = Data([0x33])
        defer {
            if let remaining = try? KeychainManager.shared
                .legacyGenericPasswordCandidatesStrict(
                    service: service,
                    account: account,
                    includeLegacyKeychain: true
                ) {
                for candidate in remaining {
                    try? KeychainManager.shared
                        .deleteLegacyGenericPasswordCandidate(candidate)
                }
            }
        }

        XCTAssertEqual(
            try KeychainManager.shared.insertKeyIfAbsent(
                data: sharedData,
                service: service,
                account: account,
                scope: sharedScope
            ),
            .inserted
        )
        XCTAssertEqual(
            try KeychainManager.shared.insertKeyIfAbsent(
                data: appPrivateData,
                service: service,
                account: account,
                scope: .unscopedDataProtectionForTesting
            ),
            .inserted
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: legacyNoGroupData,
                service: service,
                account: account
            )
        )

        var discovered = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        XCTAssertEqual(Set(discovered.map(\.data)), [
            sharedData,
            appPrivateData,
            legacyNoGroupData
        ])
        XCTAssertEqual(
            discovered.filter { $0.location.actualAccessGroup == sharedGroup }
                .count,
            1
        )
        XCTAssertEqual(
            discovered.filter {
                $0.location.actualAccessGroup == nil
                    && !$0.location.usesDataProtectionKeychain
            }.count,
            1
        )

        let legacyNoGroup = try XCTUnwrap(
            discovered.first { $0.data == legacyNoGroupData }
        )
        try KeychainManager.shared.deleteLegacyGenericPasswordCandidate(
            legacyNoGroup
        )
        discovered = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        XCTAssertEqual(Set(discovered.map(\.data)), [sharedData, appPrivateData])

        let shared = try XCTUnwrap(discovered.first { $0.data == sharedData })
        try KeychainManager.shared.deleteLegacyGenericPasswordCandidate(shared)
        discovered = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        XCTAssertEqual(discovered.map(\.data), [appPrivateData])
    }

    func testExactLegacyDeleteRejectsAValueChangedAfterDiscovery() throws {
        let service = "com.skybridge.tests.legacy-change.\(UUID().uuidString)"
        let account = "identity"
        let original = Data([0x11, 0x22])
        let replacement = Data([0x33, 0x44])
        defer {
            try? KeychainManager.shared.deleteAPIKey(
                service: service,
                account: account
            )
        }

        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: original,
                service: service,
                account: account
            )
        )
        let candidate = try XCTUnwrap(
            KeychainManager.shared.legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account
            ).first
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: replacement,
                service: service,
                account: account
            )
        )

        XCTAssertThrowsError(
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(candidate)
        ) { error in
            guard case KeychainError.itemChangedDuringReconciliation = error else {
                return XCTFail("Unexpected reconciliation error: \(error)")
            }
        }
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: service,
                account: account
            ),
            replacement
        )
    }
}
