import Foundation
import Combine

/// Protocol defining the interface for CloudKit device operations.
/// This allows decoupling the UI from the concrete CloudKit implementation,
/// enabling the use of mock services for SwiftUI Previews.
@MainActor
public protocol CloudDeviceService: ObservableObject {
 /// The list of discovered devices.
    var devices: [CloudDevice] { get }
    var devicesPublisher: AnyPublisher<[CloudDevice], Never> { get }
    
 /// The current status of the iCloud account.
    var accountStatus: CloudKitAccountStatus { get }
    var accountStatusPublisher: AnyPublisher<CloudKitAccountStatus, Never> { get }
    
 /// Whether a sync operation is currently in progress.
    var isSyncing: Bool { get }
    var isSyncingPublisher: AnyPublisher<Bool, Never> { get }
    
 /// The ID of the current device.
    var currentDeviceId: String { get }
    
 /// Manually triggers a refresh of the device list.
    func refreshDevices() async
    
 /// Checks the current iCloud account status.
    func checkAccountStatus() async
}

/// A platform-agnostic representation of CloudKit account status.
public enum CloudKitAccountStatus: Int, Sendable {
    case couldNotDetermine = 0
    case available = 1
    case restricted = 2
    case noAccount = 3
    case temporarilyUnavailable = 4
}
