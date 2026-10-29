import Foundation

/// Access to the macOS online-device aggregator from shared P2P code.
///
/// `UnifiedOnlineDeviceManager` is the macOS-side aggregation of online devices used for
/// presentation. Shared P2P inbound-route resolution reads it as an *additional* naming hint, and
/// notifies it of connect/disconnect for display purposes — it never participates in a protocol or
/// trust decision.
///
/// Other platforms have no such aggregator, so this returns an empty snapshot. That is an explicit
/// "no hint available", not fabricated device data: `resolveInboundPresenceRoute` already has to
/// cope with an empty aggregator on macOS too (before the first scan completes).
///
/// - Note: iOS ships its own aggregation layer; unifying the two is phase 3 of the
///   iOS/SkyBridgeCore deduplication. Tracked in Docs/background-wake-capability-ledger.md.
enum UnifiedOnlineDeviceSnapshotAccess {
    @MainActor
    static func snapshot() -> [OnlineDevice] {
        #if os(macOS)
        UnifiedOnlineDeviceManager.shared.onlineDevices
        #else
        []
        #endif
    }
}
