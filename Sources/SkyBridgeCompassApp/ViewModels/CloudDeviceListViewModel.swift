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
            guard let liveDevice = UnifiedOnlineDeviceManager.shared.resolvedOnlineDevice(for: device),
                  liveDevice.connectionStatus != .offline || liveDevice.isConnectable else {
                errorMessage = "没有发现这台设备的本地 P2P/Bonjour 端点，iCloud 自动连接暂不可用。请确认 iPad 与 Mac 在同一局域网、SkyBridge 在前台，并刷新设备。"
                return
            }

            try await OnlineDeviceConnectionCoordinator.connect(to: liveDevice)
            errorMessage = nil
        } catch {
            let localized = HandshakeErrorLocalizer.localizedMessage(for: error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = localized.isEmpty ? error.localizedDescription : localized
            SkyBridgeLogger.discovery.error("iCloud device connect failed: \(device.name, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
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
