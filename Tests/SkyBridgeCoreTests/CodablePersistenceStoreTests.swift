import XCTest
@testable import SkyBridgeCore

private enum PreparedFileProtectionTestError: Error {
    case rejected
}

private final class PreparedFileProtectionFailingFileManager: FileManager, @unchecked Sendable {
    var rejectsPreparedFileProtection = false
    var rejectedProtectionLastPathComponent: String?

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        if (rejectsPreparedFileProtection && lastPathComponent.contains(".prepared-"))
            || lastPathComponent == rejectedProtectionLastPathComponent {
            throw PreparedFileProtectionTestError.rejected
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

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

    func testProtectionFailureCannotReplaceCommittedPrimary() throws {
        let suiteName = "SkyBridgeCoreTests.CodablePersistenceStore.\(UUID().uuidString)"
        let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
        let relativePath = "Tests/atomic-protection.json"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let fileManager = PreparedFileProtectionFailingFileManager()
        let primaryURL = try protectedApplicationSupportURL(
            rootDirectoryName: rootDirectoryName,
            relativePath: relativePath
        )
        let rootURL = primaryURL.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if fileManager.fileExists(atPath: rootURL.path) {
                XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults,
            fileManager: fileManager
        )
        let committed = ["committed"]
        try store.save(committed)
        let committedBytes = try Data(contentsOf: primaryURL)

        fileManager.rejectsPreparedFileProtection = true
        XCTAssertThrowsError(try store.save(["must-not-commit"])) { error in
            XCTAssertTrue(error is PreparedFileProtectionTestError)
        }
        fileManager.rejectsPreparedFileProtection = false

        XCTAssertEqual(try Data(contentsOf: primaryURL), committedBytes)
        XCTAssertEqual(try store.loadOrThrow(), committed)
        let siblingNames = try fileManager.contentsOfDirectory(
            atPath: primaryURL.deletingLastPathComponent().path
        )
        XCTAssertFalse(siblingNames.contains(where: { $0.contains(".prepared-") }))
    }

    func testReplacingExistingPrimaryPreservesPrivatePermissions() throws {
        let suiteName = "SkyBridgeCoreTests.CodablePersistenceStore.\(UUID().uuidString)"
        let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
        let relativePath = "Tests/atomic-replacement.json"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let primaryURL = try protectedApplicationSupportURL(
            rootDirectoryName: rootDirectoryName,
            relativePath: relativePath
        )
        let rootURL = primaryURL.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                XCTAssertNoThrow(try FileManager.default.removeItem(at: rootURL))
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults
        )
        try store.save(["first"])
        try store.save(["second"])

        XCTAssertEqual(try store.loadOrThrow(), ["second"])
        let attributes = try FileManager.default.attributesOfItem(atPath: primaryURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testQuarantineProtectionFailureKeepsPrimaryInPlace() throws {
        let suiteName = "SkyBridgeCoreTests.CodablePersistenceStore.\(UUID().uuidString)"
        let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
        let relativePath = "Tests/quarantine-protection.json"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let fileManager = PreparedFileProtectionFailingFileManager()
        let primaryURL = try protectedApplicationSupportURL(
            rootDirectoryName: rootDirectoryName,
            relativePath: relativePath
        )
        let rootURL = primaryURL.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if fileManager.fileExists(atPath: rootURL.path) {
                XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults,
            fileManager: fileManager
        )
        let committed = ["corrupt-but-preserved"]
        try store.save(committed)
        let committedBytes = try Data(contentsOf: primaryURL)

        fileManager.rejectedProtectionLastPathComponent = primaryURL.lastPathComponent
        XCTAssertThrowsError(try store.quarantineExistingPayload()) { error in
            XCTAssertTrue(error is PreparedFileProtectionTestError)
        }
        fileManager.rejectedProtectionLastPathComponent = nil

        XCTAssertEqual(try Data(contentsOf: primaryURL), committedBytes)
        XCTAssertEqual(try store.loadOrThrow(), committed)
        let siblingNames = try fileManager.contentsOfDirectory(
            atPath: primaryURL.deletingLastPathComponent().path
        )
        XCTAssertFalse(siblingNames.contains(where: { $0.contains(".quarantine.") }))
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
