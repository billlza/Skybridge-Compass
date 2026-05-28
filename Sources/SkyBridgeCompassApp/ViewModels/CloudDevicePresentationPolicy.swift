import Foundation
import SkyBridgeCore

@MainActor
enum CloudDevicePresentationPolicy {
    static func visibleICloudDevices(
        from devices: [iCloudDevice],
        currentDeviceId: String?
    ) -> [iCloudDevice] {
        var seen = Set<String>()
        return devices.filter { device in
            if let currentDeviceId, device.id == currentDeviceId {
                return false
            }
            if isRepresentedByVisibleUnifiedRow(device) {
                return false
            }
            return seen.insert(presentationKey(for: device)).inserted
        }
    }

    private static func isRepresentedByVisibleUnifiedRow(_ device: iCloudDevice) -> Bool {
        let manager = UnifiedOnlineDeviceManager.shared
        guard let liveDevice = manager.resolvedOnlineDevice(for: device),
              !liveDevice.isLocalDevice,
              (
                liveDevice.connectionStatus == .online ||
                liveDevice.connectionStatus == .connected ||
                liveDevice.isConnectable
              ) else {
            return false
        }
        return manager.onlineDevices.contains { $0.id == liveDevice.id }
    }

    private static func presentationKey(for device: iCloudDevice) -> String {
        if let stableIdentity = normalized(device.stableIdentityDeviceId) {
            return "identity:\(stableIdentity)"
        }
        if let registrationFingerprint = normalized(device.registrationFingerprint) {
            return "registration:\(registrationFingerprint):\(deviceFamily(for: device))"
        }
        if let vendorIdentity = normalized(device.vendorDeviceId) {
            return "vendor:\(vendorIdentity):\(deviceFamily(for: device))"
        }
        if let ipAddress = normalized(device.ipAddress), !ipAddress.isEmpty {
            return "ip:\(ipAddress):\(deviceFamily(for: device))"
        }
        return "icloud:\(normalized(device.id) ?? device.id)"
    }

    private static func deviceFamily(for device: iCloudDevice) -> String {
        let model = device.model.lowercased()
        let name = device.name.lowercased()
        if model.contains("ipad") || name.contains("ipad") {
            return "ipad"
        }
        if model.contains("iphone") || name.contains("iphone") {
            return "iphone"
        }
        if model.contains("mac") || name.contains("mac") {
            return "mac"
        }
        return "unknown"
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
