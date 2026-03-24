import XCTest
@testable import SkyBridgeCore

final class CodablePersistenceStoreTests: XCTestCase {
    func testProtectedApplicationSupportStoreMigratesLegacyDefaults() throws {
        let suiteName = "SkyBridgeCoreTests.CodablePersistenceStore.\(UUID().uuidString)"
        let legacyKey = "legacy.codable.persistence"
        let rootDirectoryName = "SkyBridgeStateTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: "Tests/\(UUID().uuidString).json",
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults
        )
        let expected = ["tenant", "approval", "anomaly"]
        defaults.set(try JSONEncoder().encode(expected), forKey: legacyKey)

        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(store.load(), expected)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
