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
        SkyBridgeLogger.discovery.info("Connecting to device: \(device.name, privacy: .public)")
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
