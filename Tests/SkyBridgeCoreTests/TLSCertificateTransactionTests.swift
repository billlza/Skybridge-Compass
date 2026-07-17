import Security
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class TLSCertificateTransactionTests: XCTestCase {
    @MainActor
    func testPKCS12InputBoundsFailBeforeSecurityImport() {
        let manager = TLSSecurityManager()
        for (payload, password) in [
            (Data(), ""),
            (
                Data(
                    repeating: 0,
                    count: TLSCertificateLifecycleLimits.maximumPKCS12Bytes + 1
                ),
                ""
            ),
            (
                Data([0x01]),
                String(
                    repeating: "x",
                    count: TLSCertificateLifecycleLimits
                        .maximumPKCS12PasswordUTF8Bytes + 1
                )
            )
        ] {
            XCTAssertThrowsError(
                try manager.importIdentityFromPKCS12(
                    payload,
                    password: password,
                    for: "bounded-pkcs12-device"
                )
            ) { error in
                guard let lifecycleError = error
                    as? TLSCertificateLifecycleError,
                    case .invalidPKCS12Input = lifecycleError else {
                    return XCTFail("Unexpected PKCS#12 boundary error: \(error)")
                }
            }
        }
    }

    func testMissingPersistentReferenceDeletesInsertedCandidate() {
        var deleteCount = 0

        XCTAssertThrowsError(
            try TLSCertificateRollbackCoordinator.requirePersistentReference(
                nil,
                operation: "add-certificate",
                exactDelete: {
                    deleteCount += 1
                    return errSecSuccess
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? TLSCertificateLifecycleError,
                .persistentReferenceMissing(operation: "add-certificate")
            )
        }
        XCTAssertEqual(deleteCount, 1)
    }

    func testMissingPersistentReferenceSurfacesCleanupFailure() {
        XCTAssertThrowsError(
            try TLSCertificateRollbackCoordinator.requirePersistentReference(
                Data(),
                operation: "add-private-key",
                exactDelete: { errSecInteractionNotAllowed }
            )
        ) { error in
            XCTAssertEqual(
                error as? TLSCertificateLifecycleError,
                .rollbackFailed(
                    primaryContext: "add-private-key:missing-persistent-reference",
                    cleanupFailures: [
                        TLSCertificateCleanupFailure(
                            operation: "add-private-key",
                            status: errSecInteractionNotAllowed
                        )
                    ]
                )
            )
        }
    }

    func testRollbackAttemptsEveryOwnedItemAndAggregatesFailures() {
        let items = [
            TLSCertificateRollbackItem(
                operation: "certificate",
                itemClass: "certificate",
                persistentReference: Data([0x01])
            ),
            TLSCertificateRollbackItem(
                operation: "private-key",
                itemClass: "key",
                persistentReference: Data([0x02])
            )
        ]
        var attemptedOperations: [String] = []

        XCTAssertThrowsError(
            try TLSCertificateRollbackCoordinator.cleanup(
                primaryContext: "reload-validation",
                items: items,
                delete: { item in
                    attemptedOperations.append(item.operation)
                    return item.operation == "certificate"
                        ? errSecInteractionNotAllowed
                        : errSecItemNotFound
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? TLSCertificateLifecycleError,
                .rollbackFailed(
                    primaryContext: "reload-validation",
                    cleanupFailures: [
                        TLSCertificateCleanupFailure(
                            operation: "certificate",
                            status: errSecInteractionNotAllowed
                        )
                    ]
                )
            )
        }
        XCTAssertEqual(attemptedOperations, ["certificate", "private-key"])
    }

    func testRollbackTreatsAlreadyAbsentItemsAsClean() {
        XCTAssertNoThrow(
            try TLSCertificateRollbackCoordinator.cleanup(
                primaryContext: "candidate-add",
                items: [
                    TLSCertificateRollbackItem(
                        operation: "private-key",
                        itemClass: "key",
                        persistentReference: Data([0x03])
                    )
                ],
                delete: { _ in errSecItemNotFound }
            )
        )
    }

    func testProductionStoreUsesOneScopedCreateOnlyKeychainContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/Security/TLSCertificateKeychainStore.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("OSAllocatedUnfairLock<Void>"))
        XCTAssertTrue(source.contains("requiredSharedAccessGroup()"))
        XCTAssertTrue(source.contains("kSecUseDataProtectionKeychain"))
        XCTAssertTrue(
            source.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")
        )
        XCTAssertTrue(source.contains("kSecAttrSynchronizable as String: false"))
        XCTAssertTrue(source.contains("kSecReturnPersistentRef as String: true"))
        XCTAssertTrue(source.contains("kSecMatchItemList as String"))
        XCTAssertTrue(source.contains("kSecValuePersistentRef as String"))
        XCTAssertFalse(source.contains("_ = SecItemAdd"))
        XCTAssertFalse(source.contains("SecItemDelete(add"))
    }
}
