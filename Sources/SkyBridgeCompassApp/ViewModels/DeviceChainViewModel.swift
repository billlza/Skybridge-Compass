import Foundation
import SwiftUI
import Combine
import SkyBridgeCore

@MainActor
final class DeviceChainViewModel: ObservableObject {
    @Published var devices: [iCloudDevice] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let service: any CloudDeviceService

    init(service: any CloudDeviceService = DefaultCloudDeviceService.shared) {
        self.service = service
    }

    func reload() {
        Task { await reloadAsync() }
    }

    private func reloadAsync() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            self.devices = try await service.fetchDevices()
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
