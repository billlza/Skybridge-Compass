import Foundation

@available(iOS 17.0, *)
enum RemoteDesktopTransportSelectionPolicy {
    static func shouldUseCrossNetworkTransport(
        for device: DiscoveredDevice,
        crossNetworkState: CrossNetworkWebRTCManager.State,
        remoteDeviceId: String?,
        remoteDeviceName: String?,
        capability: String
    ) -> Bool {
        guard case .connected(let sessionId) = crossNetworkState else { return false }

        if isCrossNetworkDevice(device, capability: capability) {
            return true
        }

        if device.id == "webrtc-\(sessionId)" || device.id.hasPrefix("webrtc-") {
            return true
        }

        if let remoteId = remoteDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !remoteId.isEmpty,
           remoteId == device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return true
        }

        if let remoteDeviceName {
            let normalizedRemoteName = normalizedDeviceName(remoteDeviceName)
            if !normalizedRemoteName.isEmpty,
               normalizedDeviceName(device.name) == normalizedRemoteName,
               device.services.isEmpty,
               device.ipAddress == nil {
                return true
            }
        }

        return false
    }

    static func isCrossNetworkDevice(_ device: DiscoveredDevice, capability: String) -> Bool {
        device.capabilities.contains(capability)
            || device.advertisedCapabilities.contains(capability)
    }

    private static func normalizedDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}
