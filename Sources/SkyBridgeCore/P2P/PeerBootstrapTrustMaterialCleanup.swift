import Foundation

@available(macOS 14.0, iOS 17.0, *)
public enum PeerBootstrapTrustMaterialCleanup {
    @discardableResult
    public static func forgetDevice(deviceIds rawDeviceIds: [String]) async -> Bool {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { return false }

        await PeerKEMBootstrapStore.shared.clear(deviceIds: deviceIds)
        let protocolIdentityCacheCleared = await PeerProtocolIdentityBootstrapStore.shared.clear(
            deviceIds: deviceIds
        )
        if !protocolIdentityCacheCleared {
            SkyBridgeLogger.p2p.error(
                "Failed to persist protocol identity bootstrap cache removal while forgetting peer trust"
            )
        }
        return protocolIdentityCacheCleared
    }

    public static func repairP2PTrust(deviceIds rawDeviceIds: [String]) async {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.clear(deviceIds: deviceIds)
    }

    private static func normalizedUniqueIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in rawIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
}
