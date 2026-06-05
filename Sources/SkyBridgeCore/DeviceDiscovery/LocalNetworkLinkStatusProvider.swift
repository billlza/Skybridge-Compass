import Foundation
import Network

#if os(macOS)
import CoreWLAN
#endif

enum LocalNetworkLinkStatusProvider {
    static func currentStatus() -> DeviceNetworkLinkStatus? {
        #if os(macOS)
        if let wifiStatus = currentWiFiStatus() {
            return wifiStatus
        }
        #endif

        if !LocalNetworkAdvertisementAddressProvider.routableLANAddresses().isEmpty {
            return DeviceNetworkLinkStatus(kind: .ethernet)
        }
        return nil
    }

    static func attachCurrentStatus(to record: inout NWTXTRecord) {
        guard let status = currentStatus() else { return }
        for (key, value) in status.advertisementFields {
            record[key] = value
        }
    }

    static func attachCurrentStatus(to record: inout [String: Data]) {
        guard let status = currentStatus() else { return }
        for (key, value) in status.advertisementFields {
            record[key] = Data(value.utf8)
        }
    }

    #if os(macOS)
    private static func currentWiFiStatus() -> DeviceNetworkLinkStatus? {
        guard let interface = CWWiFiClient.shared().interface(),
              let ssid = interface.ssid(),
              !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let rssi = interface.rssiValue()
        return DeviceNetworkLinkStatus(kind: .wifi, rssi: rssi)
    }
    #endif
}
