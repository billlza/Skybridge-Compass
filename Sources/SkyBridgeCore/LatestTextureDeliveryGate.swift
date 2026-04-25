import Foundation
@preconcurrency import Metal

/// 将高频纹理发布收敛成“只保留最新帧”的单槽投递器。
///
/// 远控/远桌面链路在高帧率下不能为每一帧都排一个 `Task { @MainActor ... }`，
/// 否则主线程一旦短暂落后，就会把大量 `MTLTexture` / `CVPixelBuffer` 级联积压在任务队列里。
/// 这里明确采用 latest-frame-only 语义：UI 永远消费最新一帧，而不是无限排队消费历史帧。
final class LatestTextureDeliveryGate: @unchecked Sendable {
    private struct PendingFrame {
        let texture: MTLTexture?
        let backing: AnyObject?
    }

    private let lock = NSLock()
    private weak var feed: RemoteTextureFeed?
    private var pendingFrame: PendingFrame?
    private var deliveryScheduled = false

    init(feed: RemoteTextureFeed) {
        self.feed = feed
    }

    func submit(texture: MTLTexture?, backing: AnyObject? = nil) {
        let shouldSchedule: Bool
        lock.lock()
        pendingFrame = PendingFrame(texture: texture, backing: backing)
        shouldSchedule = !deliveryScheduled
        if shouldSchedule {
            deliveryScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingFrames()
        }
    }

    func clear() {
        lock.lock()
        pendingFrame = nil
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.feed?.update(texture: nil, backing: nil)
        }
    }

    @MainActor
    private func drainPendingFrames() {
        while true {
            let nextFrame: PendingFrame?
            lock.lock()
            nextFrame = pendingFrame
            pendingFrame = nil
            if nextFrame == nil {
                deliveryScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()

            feed?.update(texture: nextFrame?.texture, backing: nextFrame?.backing)
        }
    }
}
