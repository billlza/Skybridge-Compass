import Foundation

/// Length-prefixed WebRTC data-channel frames are accepted only up to this
/// shared ceiling on both platforms. Keeping the value in ProtocolCore prevents
/// a sender from allocating/emitting a frame that the peer's parser must reject.
@available(macOS 14.0, iOS 17.0, *)
public enum WebRTCFramedPayloadPolicy {
    public static let maximumPayloadByteCount = 8_000_000

    public static func isValidPayloadByteCount(_ byteCount: Int) -> Bool {
        (1...maximumPayloadByteCount).contains(byteCount)
    }
}
