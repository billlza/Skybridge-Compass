import Foundation
import Combine
import SkyBridgeCore

@MainActor
public final class CloudDeviceListViewModel: ObservableObject {
    @Published public var devices: [iCloudDevice] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    private let service: any CloudDeviceService

    public init(service: any CloudDeviceService = DefaultCloudDeviceService.shared) {
        self.service = service
    }

 /// 给 SwiftUI 用的入口
    public func load() {
        Task { await loadAsync() }
    }
    
    public var currentDeviceId: String? {
        service.currentDeviceId
    }

    private func loadAsync() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let list = try await service.fetchDevices()
            self.devices = list
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    public func connectToDevice(_ device: iCloudDevice) {
        Task { await connectToDeviceAsync(device) }
    }

    public func connectToDeviceAsync(_ device: iCloudDevice) async {
        do {
            _ = try await CrossNetworkConnectionManager.shared.connectToCloudDevice(Self.mapToCloudDevice(device))
            errorMessage = nil
        } catch {
            let localized = HandshakeErrorLocalizer.localizedMessage(for: error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = localized.isEmpty ? error.localizedDescription : localized
            SkyBridgeLogger.discovery.error("iCloud device connect failed: \(device.name, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func mapToCloudDevice(_ device: iCloudDevice) -> CloudDevice {
        let type: CloudDevice.DeviceType
        if device.model.contains("iPhone") {
            type = .iPhone
        } else if device.model.contains("iPad") {
            type = .iPad
        } else {
            type = .mac
        }

        let mappedCapabilities: [CloudDevice.DeviceCapability] = device.capabilities.compactMap { capability in
            switch capability {
            case .remoteDesktop:
                return .remoteDesktop
            case .fileTransfer:
                return .fileTransfer
            default:
                return nil
            }
        }

        return CloudDevice(
            id: device.id,
            name: device.name,
            type: type,
            lastSeen: device.lastSeen,
            capabilities: mappedCapabilities.isEmpty ? [.remoteDesktop] : mappedCapabilities
        )
    }
    
 // MARK: - Compatibility Properties
    
    public var authorizedDevices: [iCloudDevice] {
        devices
    }
    
    public var accountStatusDescription: String {
        devices.isEmpty ? "未连接" : "已连接 iCloud"
    }
    
    public func refreshDevices() async {
        await loadAsync()
    }
}
