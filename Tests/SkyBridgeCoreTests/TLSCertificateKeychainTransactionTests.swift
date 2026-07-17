import Security
@testable import SkyBridgeCore
import XCTest

final class TLSCertificateLifecycleSourceContractTests: XCTestCase {
    func testInvalidDeviceIdFailsBeforeScopeOrKeychainResolution() {
        XCTAssertThrowsError(
            try TLSCertificateKeychainStore().identity(for: " invalid ")
        ) { error in
            XCTAssertEqual(
                error as? TLSCertificateLifecycleError,
                .invalidDeviceId
            )
        }
    }

    func testCertificateLifecycleSourceKeepsCanonicalStorageFailClosed() throws {
        let store = try repositorySource(
            "Sources/SkyBridgeCore/Security/TLSCertificateKeychainStore.swift"
        )
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/Security/TLSSecurityManager.swift"
        )

        XCTAssertTrue(store.contains("OSAllocatedUnfairLock<Void>"))
        XCTAssertTrue(store.contains("withLockUnchecked"))
        XCTAssertFalse(store.contains("@unchecked Sendable"))
        XCTAssertTrue(store.contains("kSecUseDataProtectionKeychain"))
        XCTAssertTrue(store.contains("kSecAttrAccessGroup"))
        XCTAssertTrue(
            store.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")
        )
        XCTAssertTrue(store.contains("kSecAttrSynchronizable as String: false"))
        XCTAssertTrue(store.contains("kSecReturnPersistentRef as String: true"))
        XCTAssertTrue(
            store.contains("query[kSecMatchItemList as String] = [reference]")
        )
        XCTAssertTrue(
            store.contains("query[kSecValueRef as String] = reference")
        )
        XCTAssertTrue(store.contains("SecIdentityCreate(nil, certificate, privateKey)"))
        XCTAssertTrue(store.contains("canonicalIdentityIncomplete"))
        XCTAssertFalse(store.contains("validatedIdentityCache"))

        XCTAssertTrue(manager.contains("kSecImportToMemoryOnly as String"))
        XCTAssertTrue(manager.contains("memoryOnlyPKCS12ImportUnavailable"))
        XCTAssertTrue(manager.contains("issuedCertificateImportUnavailable"))
        XCTAssertFalse(manager.contains("CertificateFingerprint_"))
        XCTAssertFalse(manager.contains("loadStoredFingerprints"))
        XCTAssertFalse(manager.contains("SecItemDelete(addQuery"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/" {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            root.deleteLastPathComponent()
        }
        XCTFail("Could not locate repository source: \(relativePath)")
        return ""
    }
}
