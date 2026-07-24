import Foundation
import CoreGraphics

#if canImport(WebRTC)
@preconcurrency import WebRTC

@available(iOS 17.0, *)
final class RemoteVideoTrackHeartbeatRenderer: NSObject, RTCVideoRenderer {
    var onFrame: (@Sendable (CGSize) -> Void)?
    var onSize: (@Sendable (CGSize) -> Void)?
    var trackId: String = "-"
    var sessionId: String = "-"
    private var lastKnownSize: CGSize = .zero
    private var loggedFirstFrame = false
    private var loggedFirstSize = false

    func setSize(_ size: CGSize) {
        lastKnownSize = size
        guard size.width > 0, size.height > 0 else { return }
        if !loggedFirstSize {
            loggedFirstSize = true
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-track-renderer-size session=\(sessionId) trackId=\(trackId) size=\(Int(size.width))x\(Int(size.height)) source=heartbeat-renderer"
            )
        }
        let handler = onSize
        DispatchQueue.main.async {
            handler?(size)
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let measuredSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }
        if !loggedFirstFrame {
            loggedFirstFrame = true
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-track-renderer-frame session=\(sessionId) trackId=\(trackId) size=\(Int(measuredSize.width))x\(Int(measuredSize.height)) source=heartbeat-renderer"
            )
        }
        let handler = onFrame
        DispatchQueue.main.async {
            handler?(measuredSize)
        }
    }
}
#endif
