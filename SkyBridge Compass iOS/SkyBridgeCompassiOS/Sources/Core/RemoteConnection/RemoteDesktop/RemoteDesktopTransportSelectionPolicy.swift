import Foundation

@available(iOS 17.0, *)
enum RemoteDesktopTransportSelectionPolicy {
    static func decision(
        for device: DiscoveredDevice,
        routeIntent: PeerTransportRouteIntent,
        crossNetworkState: CrossNetworkWebRTCManager.State,
        remoteDeviceIDs: [String?]
    ) -> PeerTransportRouteDecision {
        let activeSessionID: String?
        if case .connected(let sessionID) = crossNetworkState {
            activeSessionID = sessionID
        } else {
            activeSessionID = nil
        }
        return PeerTransportRouteSelectionContract.evaluate(
            targetDeviceID: device.id,
            routeIntent: routeIntent,
            activeCrossNetworkSessionID: activeSessionID,
            activeCrossNetworkRemoteDeviceIDs: remoteDeviceIDs
        )
    }

    static func isCrossNetworkDevice(_ device: DiscoveredDevice, capability: String) -> Bool {
        device.capabilities.contains(capability)
            || device.advertisedCapabilities.contains(capability)
    }

}
