import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class SettingsManagerContractTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "com.skybridge.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testFreshDefaultsMatchDeclaredContractWithoutWritingKeys() throws {
        let defaults = try isolatedDefaults()
        let manager = SettingsManager(defaults: defaults)

        XCTAssertTrue(manager.autoReconnect)
        XCTAssertTrue(manager.endToEndEncryption)
        XCTAssertTrue(manager.discoveryEnabled)
        XCTAssertTrue(manager.enableRealTimeWeather)
        XCTAssertTrue(manager.clipboardSyncFileURLs)
        XCTAssertEqual(manager.maxConcurrentConnections, 2)
        XCTAssertEqual(manager.clipboardMaxContentSize, 1 * 1024 * 1024)
        XCTAssertNil(defaults.object(forKey: "auto_reconnect"))
        XCTAssertNil(defaults.object(forKey: "e2e_encryption"))
        XCTAssertNil(defaults.object(forKey: "discovery_enabled"))
    }

    func testExplicitFalseOverridesTrueDefaults() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: "auto_reconnect")
        defaults.set(false, forKey: "e2e_encryption")
        defaults.set(false, forKey: "discovery_enabled")
        defaults.set(false, forKey: "enable_real_time_weather")
        defaults.set(false, forKey: "clipboard_sync_file_urls")

        let manager = SettingsManager(defaults: defaults)

        XCTAssertFalse(manager.autoReconnect)
        XCTAssertFalse(manager.endToEndEncryption)
        XCTAssertFalse(manager.discoveryEnabled)
        XCTAssertFalse(manager.enableRealTimeWeather)
        XCTAssertFalse(manager.clipboardSyncFileURLs)
    }

    func testMutationsPersistToInjectedDefaultsOnly() throws {
        let defaults = try isolatedDefaults()
        let manager = SettingsManager(defaults: defaults)

        manager.autoReconnect = false
        manager.endToEndEncryption = false
        manager.clipboardMaxContentSize = 4096

        XCTAssertEqual(defaults.object(forKey: "auto_reconnect") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "e2e_encryption") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "clipboard_max_content_size") as? Int, 4096)
    }
}
