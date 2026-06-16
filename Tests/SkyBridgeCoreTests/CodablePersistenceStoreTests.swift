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

    func testProtectedApplicationSupportStoreThrowsOnCorruptPrimaryFile() throws {
        let suiteName = "SkyBridgeCoreTests.CodablePersistenceStore.\(UUID().uuidString)"
        let rootDirectoryName = "SkyBridgeStateTests"
        let relativePath = "Tests/\(UUID().uuidString).json"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults
        )
        let url = try protectedApplicationSupportURL(rootDirectoryName: rootDirectoryName, relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(try store.loadOrThrow())
        XCTAssertNil(store.load())

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testProtectedApplicationSupportStoreThrowsOnCorruptLegacyDefaults() throws {
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
        defaults.set(Data("not-json".utf8), forKey: legacyKey)

        XCTAssertThrowsError(try store.loadOrThrow())
        XCTAssertNil(store.load())
        XCTAssertNotNil(defaults.data(forKey: legacyKey))

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func protectedApplicationSupportURL(rootDirectoryName: String, relativePath: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }
}
