import Foundation
import Combine

/// A mock implementation of CloudDeviceService for SwiftUI Previews.
@MainActor
public final class PreviewCloudDeviceService: CloudDeviceService {
    @Published public var devices: [CloudDevice] = []
    @Published public var accountStatus: CloudKitAccountStatus = .available
    @Published public var isSyncing: Bool = false
    
 // Protocol Conformance
    public var devicesPublisher: AnyPublisher<[CloudDevice], Never> { $devices.eraseToAnyPublisher() }
    public var accountStatusPublisher: AnyPublisher<CloudKitAccountStatus, Never> { $accountStatus.eraseToAnyPublisher() }
    public var isSyncingPublisher: AnyPublisher<Bool, Never> { $isSyncing.eraseToAnyPublisher() }
    
    public var currentDeviceId: String = "preview-device-id"
    
    public init(devices: [CloudDevice] = []) {
        if devices.isEmpty {
            self.devices = [
                CloudDevice(
                    id: "device-1",
                    name: "Preview Mac Studio",
                    type: .mac,
                    lastSeen: Date(),
                    capabilities: [.remoteDesktop, .fileTransfer]
                ),
                CloudDevice(
                    id: "device-2",
                    name: "Preview iPhone 15 Pro",
                    type: .iPhone,
                    lastSeen: Date().addingTimeInterval(-300),
                    capabilities: [.screenMirroring]
                ),
                CloudDevice(
                    id: "device-3",
                    name: "Preview iPad Pro",
                    type: .iPad,
                    lastSeen: Date().addingTimeInterval(-3600),
                    capabilities: [.fileTransfer]
                )
            ]
        } else {
            self.devices = devices
        }
    }
    
    public func refreshDevices() async {
        isSyncing = true
        try? await Task.sleep(nanoseconds: 1_000_000_000) // Simulate network delay
        isSyncing = false
    }
    
    public func checkAccountStatus() async {
 // Simulate async check
        try? await Task.sleep(nanoseconds: 500_000_000)
        self.accountStatus = .available
    }
}
