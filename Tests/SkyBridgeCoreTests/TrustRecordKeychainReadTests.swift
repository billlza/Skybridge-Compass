import Foundation
import Security
import XCTest
@testable import SkyBridgeCore

@MainActor
final class TrustRecordKeychainReadTests: XCTestCase {
    func testNativeFileKeychainEnumerationReadsEveryExactItem() throws {
        let service = "com.skybridge.tests.trust-read.\(UUID().uuidString)"
        var createdAccounts: [String] = []
        defer {
            for account in createdAccounts {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                    kSecUseDataProtectionKeychain as String: false
                ]
                XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
            }
        }
        let payloads = ["trust_record_first": Data("public fixture one".utf8),
                        "trust_record_second": Data("public fixture two".utf8)]
        for (account, data) in payloads {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: false,
                kSecValueData as String: data
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            XCTAssertEqual(status, errSecSuccess, "Create only this test's public-data fixture")
            guard status == errSecSuccess else { return }
            createdAccounts.append(account)
        }
        let items = try TrustSyncService.keychainTrustItems(service: service)
        XCTAssertEqual(items.count, payloads.count)
        for item in items {
            let account = try XCTUnwrap(item[kSecAttrAccount as String] as? String)
            XCTAssertEqual(item[kSecAttrService as String] as? String, service)
            XCTAssertEqual(item[kSecValueData as String] as? Data, payloads[account])
        }
    }

    func testInvalidKeychainQueryCannotBecomeAnEmptyAvailableTrustStore() async throws {
        let service = TrustSyncService(initialRecordsForTesting: [])
        do {
            try await service.loadLocalRecordsForTesting(keychainRecords: {
                throw TrustSyncError.keychainError(errSecParam)
            })
            XCTFail("An invalid native query must remain a load failure")
        } catch let error as TrustSyncError {
            guard case .keychainError(let status) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(status, errSecParam)
        }
        XCTAssertFalse(service.isLocalStoreAvailable)
    }
}
