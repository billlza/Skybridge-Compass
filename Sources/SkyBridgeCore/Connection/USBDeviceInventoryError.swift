#if os(macOS)
import Foundation

public enum USBDeviceInventoryError: Error, Sendable {
    case unavailable
    case native(operation: String, code: Int32)
    case malformedProperties
    case enumerationChanged
    case tooManyDevices
    case cleanup(primary: (any Error)?, object: UInt32, code: Int32)
}
#endif
