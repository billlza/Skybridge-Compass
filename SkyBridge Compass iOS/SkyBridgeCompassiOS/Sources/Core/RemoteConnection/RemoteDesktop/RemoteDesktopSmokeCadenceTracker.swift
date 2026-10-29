//
//  RemoteDesktopSmokeCadenceTracker.swift
//  SkyBridgeCompassiOS
//

import Foundation

final class MetalDisplaySmokeCadenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var displayedFrameCountInCurrentStream = 0
    private var displayedFrameTimesInCurrentStream: [Date] = []
    private var displayedFrameAgeSamplesInCurrentStream: [(displayedAt: Date, frameAgeMs: Int)] = []
    private var lastDisplayedFrameTime: Date?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        displayedFrameCountInCurrentStream = 0
        displayedFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
        displayedFrameAgeSamplesInCurrentStream.removeAll(keepingCapacity: true)
        lastDisplayedFrameTime = nil
    }

    func record(
        displayedFrameCount: Int,
        completedAt: Date,
        windowSeconds: TimeInterval,
        frameAgeMs: Int?
    ) {
        let frameDelta = max(1, displayedFrameCount)
        lock.lock()
        defer { lock.unlock() }
        lastDisplayedFrameTime = completedAt
        displayedFrameCountInCurrentStream += frameDelta
        displayedFrameTimesInCurrentStream.append(contentsOf: Array(repeating: completedAt, count: frameDelta))
        if let frameAgeMs {
            for _ in 0..<frameDelta {
                displayedFrameAgeSamplesInCurrentStream.append((displayedAt: completedAt, frameAgeMs: frameAgeMs))
            }
        }
        trimLocked(at: completedAt, windowSeconds: windowSeconds)
    }

    func snapshot(
        at now: Date,
        windowSeconds: TimeInterval
    ) -> (
        displayedFramesInStream: Int,
        displayedFramesInWindow: Int,
        lastDisplayedFrameTime: Date?,
        frameAgeMaxInWindowMs: Int?
    ) {
        lock.lock()
        defer { lock.unlock() }
        trimLocked(at: now, windowSeconds: windowSeconds)
        return (
            displayedFramesInStream: displayedFrameCountInCurrentStream,
            displayedFramesInWindow: displayedFrameTimesInCurrentStream.count,
            lastDisplayedFrameTime: lastDisplayedFrameTime,
            frameAgeMaxInWindowMs: displayedFrameAgeSamplesInCurrentStream.map { $0.frameAgeMs }.max()
        )
    }

    private func trimLocked(at now: Date, windowSeconds: TimeInterval) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        if let firstLiveIndex = displayedFrameTimesInCurrentStream.firstIndex(where: { $0 >= cutoff }) {
            if firstLiveIndex > 0 {
                displayedFrameTimesInCurrentStream.removeFirst(firstLiveIndex)
            }
        } else {
            displayedFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
        }
        if let firstLiveAgeIndex = displayedFrameAgeSamplesInCurrentStream.firstIndex(where: { $0.displayedAt >= cutoff }) {
            if firstLiveAgeIndex > 0 {
                displayedFrameAgeSamplesInCurrentStream.removeFirst(firstLiveAgeIndex)
            }
        } else {
            displayedFrameAgeSamplesInCurrentStream.removeAll(keepingCapacity: true)
        }
    }
}
