import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCEncodedScreenFrame: Sendable, Equatable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
    let format: String
    let isSyncFrame: Bool

    var recoveryIdentity: WebRTCEncodedScreenFrameIdentity {
        WebRTCEncodedScreenFrameIdentity(
            width: width,
            height: height,
            timestamp: timestamp,
            format: format,
            isSyncFrame: isSyncFrame,
            payloadBytes: imageData.count
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCEncodedScreenFrameIdentity: Sendable, Equatable {
    let width: Int
    let height: Int
    let timestamp: TimeInterval
    let format: String
    let isSyncFrame: Bool
    let payloadBytes: Int
}

@available(macOS 14.0, iOS 17.0, *)
final class LatestWebRTCEncodedFrameStore: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.skybridge.connection.webrtc.direct-frame-store",
        qos: .userInteractive
    )
    // Keep an unsent sync frame ahead of later predictive frames so refresh requests
    // can actually recover a viewer that is waiting for a keyframe.
    private var pendingSyncFrame: WebRTCEncodedScreenFrame?
    private var latestPredictiveFrame: WebRTCEncodedScreenFrame?

    func store(_ frame: WebRTCEncodedScreenFrame) {
        queue.sync {
            if frame.isSyncFrame {
                pendingSyncFrame = frame
                latestPredictiveFrame = nil
            } else {
                latestPredictiveFrame = frame
            }
        }
    }

    func takeLatest() -> WebRTCEncodedScreenFrame? {
        queue.sync {
            if let pendingSyncFrame {
                self.pendingSyncFrame = nil
                return pendingSyncFrame
            }
            defer { latestPredictiveFrame = nil }
            return latestPredictiveFrame
        }
    }

    func latestAgeMs(now: Date = Date()) -> Int? {
        queue.sync {
            let frame = pendingSyncFrame ?? latestPredictiveFrame
            guard let frame else { return nil }
            return max(
                0,
                Int(((now.timeIntervalSince1970 - frame.timestamp) * 1000).rounded())
            )
        }
    }

    func peekLatest(maxAge: TimeInterval, now: Date = Date()) -> WebRTCEncodedScreenFrame? {
        queue.sync {
            let nowSeconds = now.timeIntervalSince1970
            if let pendingSyncFrame,
               nowSeconds - pendingSyncFrame.timestamp <= maxAge {
                return pendingSyncFrame
            }
            if let latestPredictiveFrame,
               nowSeconds - latestPredictiveFrame.timestamp <= maxAge {
                return latestPredictiveFrame
            }
            return nil
        }
    }

    func takeLatest(maxAge: TimeInterval, now: Date = Date()) -> WebRTCEncodedScreenFrame? {
        queue.sync {
            let nowSeconds = now.timeIntervalSince1970

            if let pendingSyncFrame {
                self.pendingSyncFrame = nil
                if nowSeconds - pendingSyncFrame.timestamp <= maxAge {
                    return pendingSyncFrame
                }
            }

            if let latestPredictiveFrame {
                self.latestPredictiveFrame = nil
                if nowSeconds - latestPredictiveFrame.timestamp <= maxAge {
                    return latestPredictiveFrame
                }
            }

            return nil
        }
    }

    func clear() {
        queue.sync {
            pendingSyncFrame = nil
            latestPredictiveFrame = nil
        }
    }
}
