import Foundation
import Network
import SkyBridgeAppleTransport

/// A cable route is distinct from network endpoint candidates. The native Android
/// case carries the exact physical owner's bootstrap channel, never a made-up
/// NWEndpoint or hardware identity. This enum cannot select a LAN fallback.
enum P2PUSBControlRoute: Sendable {
    case apple(udid: String)
    #if os(macOS)
    case android(USBHostBootstrapChannel)
    #endif

    func checkCurrent() throws {
        try Task.checkCancellation()
        #if os(macOS)
        if case .android(let channel) = self { try channel.checkCurrent() }
        #endif
    }
    var appleUDID: String? {
        if case .apple(let udid) = self { return udid }
        return nil
    }
    var description: String {
        switch self {
        case .apple(let udid): return "usb:\(udid)"
        #if os(macOS)
        case .android(let channel): return "usb-android:\(channel.attachmentNonce.uuidString.lowercased())"
        #endif
        }
    }
    func digestMaterial(peerID: String) -> String {
        switch self {
        // Retain the established Apple request digest exactly.
        case .apple(let udid): return "SkyBridge-USB|\(udid)|9527|\(peerID)"
        #if os(macOS)
        case .android(let channel): return "SkyBridge-Android-USB|\(channel.attachmentNonce.uuidString.lowercased())|MAIN|\(peerID)"
        #endif
        }
    }
}
