#if os(macOS)
import Foundation
import SkyBridgeAppleTransport

/// Request receipt only. The new AOA registry entry, signed peer and data channel
/// have not yet been resolved merely because these control requests completed.
public struct AndroidUSBPreparedAttachment: Sendable {
    public let source: USBDeviceInfo
    public let locationID: UInt32
    public let attachmentNonce: UUID
    public let receipt: USBHostAccessoryReceipt
}

public struct AndroidUSBPreparationCleanupFailure: Error, Sendable {
    public let primary: any Error
    public let cleanup: any Error
}
#endif
