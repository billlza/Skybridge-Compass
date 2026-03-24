import Foundation

enum RemoteScreenFrameQueueEnqueueResult: Equatable {
    case enqueued
    case droppedStaleIndependentFrame
    case droppedPredictiveFrameNeedsSyncRefresh
    case droppedPredictiveFrameWaitingForSync
}

struct RemoteScreenFrameSendQueue {
    private(set) var pendingFrames: [ScreenData] = []
    private(set) var waitingForSyncFrame = false

    let maxQueuedFrames: Int

    init(maxQueuedFrames: Int = 3) {
        self.maxQueuedFrames = max(1, maxQueuedFrames)
    }

    @discardableResult
    mutating func enqueue(_ frame: ScreenData) -> RemoteScreenFrameQueueEnqueueResult {
        if frame.isIndependentlyDecodableFrame {
            waitingForSyncFrame = false
            if pendingFrames.count >= maxQueuedFrames {
                pendingFrames.removeFirst(max(1, pendingFrames.count - maxQueuedFrames + 1))
            }
            pendingFrames.append(frame)
            return .enqueued
        }

        if waitingForSyncFrame {
            guard frame.isSyncFrame == true else {
                return .droppedPredictiveFrameWaitingForSync
            }
            pendingFrames.removeAll(keepingCapacity: true)
            pendingFrames.append(frame)
            waitingForSyncFrame = false
            return .enqueued
        }

        guard pendingFrames.count < maxQueuedFrames else {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = true
            return .droppedPredictiveFrameNeedsSyncRefresh
        }

        pendingFrames.append(frame)
        return .enqueued
    }

    mutating func dequeue() -> ScreenData? {
        guard !pendingFrames.isEmpty else { return nil }
        return pendingFrames.removeFirst()
    }

    mutating func clear() {
        pendingFrames.removeAll(keepingCapacity: true)
        waitingForSyncFrame = false
    }
}

extension ScreenData {
    var normalizedFormat: String {
        (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isCompressedPredictiveVideoFrame: Bool {
        switch normalizedFormat {
        case "h264", "hevc":
            return true
        default:
            return false
        }
    }

    var isIndependentlyDecodableFrame: Bool {
        if isCompressedPredictiveVideoFrame {
            return RemoteDesktopScreenFrameWire.containsSyncFrame(
                format: format,
                imageData: imageData,
                advertisedSyncFrame: isSyncFrame
            )
        }
        return true
    }
}
