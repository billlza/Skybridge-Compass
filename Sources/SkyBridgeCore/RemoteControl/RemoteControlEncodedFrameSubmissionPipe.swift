import Foundation

final class RemoteControlEncodedFrameSubmissionPipe: @unchecked Sendable {
    private final class DropTelemetry: @unchecked Sendable {
        private let lock = NSLock()
        private var droppedFrames = 0

        func recordDrop() -> Int? {
            lock.lock()
            droppedFrames += 1
            let count = droppedFrames
            lock.unlock()
            return count == 1 || count.isMultiple(of: 60) ? count : nil
        }
    }

    private static let bufferedFrameLimit = 6

    private let continuation: AsyncStream<ScreenData>.Continuation
    private let drainTask: Task<Void, Never>
    private let dropTelemetry = DropTelemetry()

    init(outboundFramePump: RemoteControlOutboundFramePump) {
        let (stream, continuation) = AsyncStream<ScreenData>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferedFrameLimit)
        )
        self.continuation = continuation
        drainTask = Task(priority: .high) {
            for await frame in stream {
                await outboundFramePump.submitFrame(frame)
            }
        }
    }

    func submit(_ frame: ScreenData) {
        switch continuation.yield(frame) {
        case .enqueued:
            break
        case .dropped:
            if let droppedFrames = dropTelemetry.recordDrop() {
                RemoteControlSmokeStatusWriter.append(
                    "mac-video-submit-pipe result=dropped reason=bounded-newest dropped=\(droppedFrames) capacity=\(Self.bufferedFrameLimit)"
                )
            }
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    func close() {
        continuation.finish()
        drainTask.cancel()
    }

    deinit {
        close()
    }
}
