// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import CoreGraphics
import ScreenCaptureKit

@available(macOS 14.0, *)
actor ScreenCaptureAuthorizationProbe {
    static let shared = ScreenCaptureAuthorizationProbe()

    private var lastPromptAt: Date?
    private let promptCooldown: TimeInterval = 5

    func isAuthorized() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func requestAuthorizationIfNeeded(openSettings: @escaping @Sendable () -> Void) async -> Bool {
        if await isAuthorized() {
            return true
        }

        let now = Date()
        if let lastPromptAt, now.timeIntervalSince(lastPromptAt) < promptCooldown {
            return false
        }
        lastPromptAt = now

        let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
        if granted {
            return true
        }

        if await isAuthorized() {
            return true
        }

        await MainActor.run {
            openSettings()
        }
        return false
    }
}

@available(macOS 14.0, *)
enum ScreenCapturePermissionSettingsOpener {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
#endif
