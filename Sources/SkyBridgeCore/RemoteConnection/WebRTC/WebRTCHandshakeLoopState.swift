import Foundation

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCHandshakeLoopState {
    var driver: HandshakeDriver?
    var sessionKeys: SessionKeys?
    var previousSessionKeysBeforeRekey: SessionKeys?
}
