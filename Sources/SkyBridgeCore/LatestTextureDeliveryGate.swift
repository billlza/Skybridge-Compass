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
        let generation: UInt64
    }

    private let lock = NSLock()
    private weak var feed: RemoteTextureFeed?
    private var pendingFrame: PendingFrame?
    private var hasPendingClear = false
    private var deliveryScheduled = false
    private var isAcceptingFrames = true
    private var generation: UInt64 = 0

    init(feed: RemoteTextureFeed) {
        self.feed = feed
    }

    func submit(texture: MTLTexture?, backing: AnyObject? = nil) {
        let shouldSchedule: Bool
        lock.lock()
        guard isAcceptingFrames else {
            lock.unlock()
            return
        }
        pendingFrame = PendingFrame(texture: texture, backing: backing, generation: generation)
        shouldSchedule = markDeliveryScheduledIfNeededLocked()
        lock.unlock()

        scheduleDrainIfNeeded(shouldSchedule)
    }

    /// Clears the current stream while keeping the gate reusable. The clear is
    /// a presentation-epoch barrier, so it must not be emitted by an unrelated
    /// MainActor task that can arrive after a newer frame. Coalescing the
    /// barrier and the latest frame into the same drain preserves the order
    /// `clear -> newer frame` without accumulating one task per frame.
    func clear() {
        let shouldSchedule: Bool
        lock.lock()
        generation &+= 1
        pendingFrame = nil
        hasPendingClear = true
        shouldSchedule = markDeliveryScheduledIfNeededLocked()
        lock.unlock()

        scheduleDrainIfNeeded(shouldSchedule)
    }

    /// Permanently closes this one-session delivery gate. `submit` and
    /// `invalidate` share the same lock, so once this method returns, a decoder
    /// callback that passed an earlier session-state check cannot enqueue a new
    /// frame or retain its backing object.
    func invalidate() {
        let shouldSchedule: Bool
        lock.lock()
        guard isAcceptingFrames else {
            lock.unlock()
            return
        }
        isAcceptingFrames = false
        generation &+= 1
        pendingFrame = nil
        hasPendingClear = true
        shouldSchedule = markDeliveryScheduledIfNeededLocked()
        lock.unlock()

        scheduleDrainIfNeeded(shouldSchedule)
    }

    /// Must only be called while `lock` is held.
    private func markDeliveryScheduledIfNeededLocked() -> Bool {
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    private func scheduleDrainIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingFrames()
        }
    }

    @MainActor
    private func drainPendingFrames() {
        let nextFrame: PendingFrame?
        let shouldClear: Bool
        let currentGeneration: UInt64
        lock.lock()
        nextFrame = pendingFrame
        pendingFrame = nil
        shouldClear = hasPendingClear
        hasPendingClear = false
        currentGeneration = generation
        if nextFrame == nil, !shouldClear {
            deliveryScheduled = false
        }
        lock.unlock()

        guard nextFrame != nil || shouldClear else { return }
        if shouldClear {
            feed?.update(texture: nil, backing: nil)
        }
        if let nextFrame, nextFrame.generation == currentGeneration {
            feed?.update(texture: nextFrame.texture, backing: nextFrame.backing)
        }

        lock.lock()
        let shouldContinue = pendingFrame != nil || hasPendingClear
        if !shouldContinue {
            deliveryScheduled = false
        }
        lock.unlock()

        guard shouldContinue else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.drainPendingFrames()
        }
    }
}
