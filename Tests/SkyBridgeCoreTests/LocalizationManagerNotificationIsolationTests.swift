import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class LocalizationManagerNotificationIsolationTests: XCTestCase {
    @MainActor
    func testDefaultLookupFallsThroughToSwiftPMModuleResources() {
        let key = "remoteControl.securityNotice.windowTitle"
        let value = LocalizationManager.shared.localizedString(key)

        XCTAssertNotEqual(
            value,
            key,
            "An executable-relative resource miss must continue to Bundle.module instead of exposing the localization key."
        )
        XCTAssertTrue(
            Set([
                "Remote Control Security Notice",
                "リモート制御セキュリティ通知",
                "远程控制安全提示",
            ]).contains(value),
            "The resolved value must come from the checked-in SkyBridgeCore localization resources."
        )
    }

    func testRuntimePreferenceInvalidationRegistersDefaultsAndLocaleNotifications() {
        XCTAssertEqual(
            Set(LocalizationManager.runtimePreferenceInvalidationNotificationNames),
            Set([
                UserDefaults.didChangeNotification,
                NSLocale.currentLocaleDidChangeNotification,
            ])
        )
    }

    @MainActor
    func testRuntimePreferenceInvalidationNotificationMayArriveFromBackgroundQueue() async {
        _ = LocalizationManager.shared

        await Self.postRuntimePreferenceInvalidationNotificationFromBackgroundQueue()

        let missingKey = "__skybridge_missing_localization_key__\(UUID().uuidString)"
        XCTAssertEqual(LocalizationManager.shared.localizedString(missingKey), missingKey)
    }

    @MainActor
    func testWeakFingerprintPersistenceCanInvalidateLocalizationCacheFromBackgroundTask() async {
        _ = LocalizationManager.shared

        let uniqueIdentifier = "localization-notification-test-\(UUID().uuidString)"
        let defaultsKey = "WeakFP.\(uniqueIdentifier)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }

        let device = DiscoveredDevice(
            id: UUID(),
            name: "Localization Notification Test Device",
            ipv4: "192.0.2.42",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: uniqueIdentifier,
            source: .skybridgeBonjour
        )
        let fingerprint = IdentityFingerprint(
            pairedID: nil,
            macAddress: nil,
            usnUUID: nil,
            usbSerial: nil,
            mdnsDeviceID: uniqueIdentifier,
            hostname: device.name,
            model: nil,
            httpServer: nil,
            portSpectrumHash: IdentityResolver.computePortSpectrumHash(from: device.portMap),
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            primaryConnectionType: device.primaryConnectionType.rawValue
        )

        await Task.detached(priority: .utility) {
            await IdentityResolver.WeakFingerprintStore.shared.save(fingerprint, for: device)
        }.value

        XCTAssertNotNil(UserDefaults.standard.data(forKey: defaultsKey))
    }

    private static func postRuntimePreferenceInvalidationNotificationFromBackgroundQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // Both production invalidation subscriptions share the same
                // nonisolated sink. Use the app-owned defaults notification here;
                // broadcasting the process-wide locale notification would also
                // wake unrelated system-framework observers in the XCTest host.
                NotificationCenter.default.post(
                    name: UserDefaults.didChangeNotification,
                    object: UserDefaults.standard
                )
                continuation.resume()
            }
        }
    }
}
