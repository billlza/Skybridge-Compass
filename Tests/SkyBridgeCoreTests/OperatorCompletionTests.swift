import XCTest
@testable import SkyBridgeCore

final class OperatorCompletionTests: XCTestCase {
    @MainActor
    func testPreferencesUseRealSettingsOwnerWithoutTouchingStandardDefaults() async throws {
        let name = "OperatorCompletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(testingUserDefaults: defaults, existingOnlyIdentityRuntime: true,
            startsProtocolIdentityRestoration: false, qPeriaptRuntimeSupportPreparer: { .alreadyActive },
            qPeriaptEnvironmentPreferenceApplier: { _ in })
        await settings.waitForStartupTasksForTesting()
        XCTAssertEqual(Set(OperatorPreferenceAccess.snapshot(settings).map(\.id)), OperatorPreferenceContract.booleanIDs)
        for (id, value) in [("general.compact_mode", true), ("general.dark_mode", true),
                            ("device.hide_offline", true), ("file.notifications", false),
                            ("monitor.cpu_visible", false), ("advanced.realtime_weather", false)] {
            let request = try CrossnetControlSettingsMutationPolicy.parse(params: .init(["id": .string(id), "value": .bool(value)]))
            try OperatorPreferenceAccess.apply(request, to: settings)
        }
        XCTAssertTrue(settings.compactMode)
        XCTAssertTrue(settings.useDarkMode)
        XCTAssertTrue(settings.hideOfflineDevices)
        XCTAssertFalse(settings.showFileTransferNotifications)
        XCTAssertFalse(settings.showMonitorCPU)
        XCTAssertFalse(settings.enableRealTimeWeather)
        XCTAssertThrowsError(try OperatorPreferenceAccess.apply(.init(id: "general.dark_mode", value: .int(1)), to: settings))
        XCTAssertThrowsError(try OperatorPreferenceAccess.apply(.init(id: "security.verify_certificates", value: .bool(false)), to: settings))
    }

    func testNewPreferencesRejectWrongTypesAndIdentityWrites() throws {
        for id in OperatorPreferenceContract.booleanIDs {
            XCTAssertThrowsError(try CrossnetControlSettingsMutationPolicy.parse(params: .init(["id": .string(id), "value": .int(1)])))
            XCTAssertThrowsError(try CrossnetControlSettingsProjectionPolicy.validate(.init(settings: [
                .init(id: id, valueType: "string", value: .string("true"), mutable: false)
            ])))
        }
        XCTAssertThrowsError(try CrossnetControlSettingsMutationPolicy.parse(params: .init([
            "id": .string("pqc.signature_algorithm"), "value": .string("Ed25519")
        ])))
    }

    func testLegacySnapshotRemainsCompatibleAndExtendedSnapshotIsExplicit() async throws {
        let runtime = CrossnetControlRuntime(hello: { .init(engineVersion: "test", authLoaded: true, tenantBound: true) },
            status: { .init(connectionStatus: "idle", readiness: "idle", sessionPresent: false, sessionRef: nil, suite: nil, signalingHealth: "healthy", authLoaded: true, tenantBound: true) },
            settingsSnapshot: { .init(settings: [
                .init(id: "logging.verbose", valueType: "bool", value: .bool(false), mutable: false),
                .init(id: "general.compact_mode", valueType: "bool", value: .bool(true), mutable: false)
            ]) })
        let router = CrossnetControlRouter(runtime: runtime)
        for (params, expected) in [("{}", 1), (#"{"include_extended":true}"#, 2)] {
            let data = await router.handleLine(Data("{\"v\":1,\"id\":\"preferences\",\"method\":\"crossnet.settings.snapshot\",\"params\":\(params)}".utf8))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            XCTAssertEqual((result["settings"] as? [Any])?.count, expected)
        }
    }

    func testDesktopOperationsRequireBoundReferences() throws {
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .start, params: .init()))
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .stop, params: .init(["session_ref": .string("display-name")])) )
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .status, params: .init(["session_ref": .int(1)])))
        let id = UUID()
        XCTAssertEqual(try OperatorDesktopRequest(action: .start, params: .init(["device_ref": .string(id.uuidString.lowercased())])).reference, id.uuidString)
    }

    @MainActor
    func testWindowRequestDoesNotClaimVisibility() throws {
        let presentation = OperatorDesktopPresentation()
        XCTAssertThrowsError(try presentation.present())
        var requested = false
        presentation.register { requested = true }
        try presentation.present()
        XCTAssertTrue(requested)
        XCTAssertFalse(presentation.isVisible)
        presentation.confirmVisible(true)
        XCTAssertTrue(presentation.isVisible)
        presentation.confirmVisible(false)
        XCTAssertFalse(presentation.isVisible)
    }
}
