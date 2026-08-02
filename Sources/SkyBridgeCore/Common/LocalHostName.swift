import Foundation

/// Single source for this machine's human-readable name.
///
/// Foundation's `Host` type is macOS-only, so every direct `Host.current()` call site
/// blocked SkyBridgeCore from compiling for iOS. Centralising it also removes the per-call-site
/// fallback strings ("Mac", "SkyBridge设备", "SkyBridge-Device") that had drifted apart.
///
/// - Important: Migration decision point. When iOS adopts SkyBridgeCore's discovery and transfer
///   layers, the non-macOS branch must be switched to the same device-name source the iOS app
///   already uses (`AppleMobileDeviceIdentity`), because this name is published in Bonjour TXT
///   records and shown to peers. Until iOS actually runs these code paths, `hostName` is not
///   user-visible. Tracked in Docs/background-wake-capability-ledger.md.
public enum LocalHostName {
    /// The name as reported by the platform, or `nil` when the platform reports nothing usable.
    ///
    /// Callers that need an optional keep getting an optional: substituting a placeholder here
    /// would hide "the system has no name for this machine" behind a fake value.
    public static var localizedName: String? {
        #if os(macOS)
        let raw: String? = Host.current().localizedName
        #else
        let raw: String? = ProcessInfo.processInfo.hostName
        #endif
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The network (DNS/Bonjour) host name, as opposed to the user-facing localized name.
    ///
    /// Callers use this as a secondary source when `localizedName` is unavailable.
    public static var networkName: String? {
        #if os(macOS)
        let raw: String? = Host.current().name
        #else
        let raw: String? = ProcessInfo.processInfo.hostName
        #endif
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
