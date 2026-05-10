import Foundation

public struct SkyBridgeMediaJitterFrame<Payload: Sendable>: Sendable {
    public let sequence: UInt64
    public let timestampSamples: UInt64
    public let insertedAt: TimeInterval
    public let payload: Payload

    public init(sequence: UInt64, timestampSamples: UInt64, insertedAt: TimeInterval, payload: Payload) {
        self.sequence = sequence
        self.timestampSamples = timestampSamples
        self.insertedAt = insertedAt
        self.payload = payload
    }
}

public enum SkyBridgeMediaJitterPopResult<Payload: Sendable>: Sendable {
    case frame(SkyBridgeMediaJitterFrame<Payload>)
    case gap(sequence: UInt64)
    case wait
}

public struct SkyBridgeMediaJitterBuffer<Payload: Sendable>: Sendable {
    public enum InsertResult: Equatable, Sendable {
        case accepted
        case duplicate
        case droppedLate
        case evictedOldest
    }

    public let targetDelayMs: Int
    public let maxDelayMs: Int
    public let packetDurationMs: Int
    public let reorderGraceMs: Int
    private var frames: [UInt64: SkyBridgeMediaJitterFrame<Payload>]
    private var nextExpectedSequence: UInt64?
    private var missingSequenceFirstSeenAt: TimeInterval?

    public init(
        targetDelayMs: Int,
        maxDelayMs: Int,
        packetDurationMs: Int = 20,
        reorderGraceMs: Int? = nil
    ) {
        self.targetDelayMs = max(0, targetDelayMs)
        self.maxDelayMs = max(maxDelayMs, targetDelayMs)
        self.packetDurationMs = max(1, packetDurationMs)
        let defaultReorderGraceMs = min(max(self.packetDurationMs * 2, self.targetDelayMs), self.maxDelayMs)
        self.reorderGraceMs = max(0, min(reorderGraceMs ?? defaultReorderGraceMs, self.maxDelayMs))
        self.frames = [:]
        self.nextExpectedSequence = nil
        self.missingSequenceFirstSeenAt = nil
    }

    public var bufferedFrameCount: Int {
        frames.count
    }

    private var maxFrameCount: Int {
        max(1, maxDelayMs / packetDurationMs)
    }

    public mutating func insert(_ frame: SkyBridgeMediaJitterFrame<Payload>, now: TimeInterval) -> InsertResult {
        if let nextExpectedSequence, frame.sequence < nextExpectedSequence {
            return .droppedLate
        }
        if frames[frame.sequence] != nil {
            return .duplicate
        }
        frames[frame.sequence] = frame
        guard frames.count > maxFrameCount,
              let oldestSequence = frames.keys.min() else {
            return .accepted
        }
        frames.removeValue(forKey: oldestSequence)
        if nextExpectedSequence == nil || oldestSequence >= (nextExpectedSequence ?? 0) {
            nextExpectedSequence = oldestSequence + 1
        }
        return .evictedOldest
    }

    public mutating func popReadyOrGap(now: TimeInterval) -> SkyBridgeMediaJitterPopResult<Payload> {
        guard !frames.isEmpty else { return .wait }
        let minSequence = frames.keys.min()!
        if nextExpectedSequence == nil {
            nextExpectedSequence = minSequence
        }
        guard let expected = nextExpectedSequence else { return .wait }

        if let frame = frames[expected],
           now - frame.insertedAt >= Double(targetDelayMs) / 1_000.0 {
            missingSequenceFirstSeenAt = nil
            guard let popped = pop(sequence: expected) else { return .wait }
            return .frame(popped)
        }

        if let oldest = frames[minSequence],
           oldest.sequence > expected {
            if missingSequenceFirstSeenAt == nil {
                missingSequenceFirstSeenAt = now
            }
            guard let firstSeen = missingSequenceFirstSeenAt,
                  now - firstSeen >= Double(reorderGraceMs) / 1_000.0 else {
                return .wait
            }
            nextExpectedSequence = expected + 1
            missingSequenceFirstSeenAt = nil
            return .gap(sequence: expected)
        }

        guard let oldest = frames[minSequence],
              now - oldest.insertedAt >= Double(maxDelayMs) / 1_000.0 else {
            return .wait
        }
        nextExpectedSequence = minSequence
        guard let popped = pop(sequence: minSequence) else { return .wait }
        return .frame(popped)
    }

    public mutating func popReadyFrame(now: TimeInterval) -> SkyBridgeMediaJitterFrame<Payload>? {
        guard !frames.isEmpty else { return nil }
        let minSequence = frames.keys.min()!
        if nextExpectedSequence == nil {
            nextExpectedSequence = minSequence
        }
        guard let expected = nextExpectedSequence else { return nil }

        if let frame = frames[expected],
           now - frame.insertedAt >= Double(targetDelayMs) / 1_000.0 {
            missingSequenceFirstSeenAt = nil
            return pop(sequence: expected)
        }

        guard let oldest = frames[minSequence],
              oldest.sequence <= expected,
              now - oldest.insertedAt >= Double(maxDelayMs) / 1_000.0 else {
            return nil
        }
        nextExpectedSequence = minSequence
        return pop(sequence: minSequence)
    }

    public mutating func popReady(now: TimeInterval) -> SkyBridgeMediaJitterFrame<Payload>? {
        while true {
            switch popReadyOrGap(now: now) {
            case .frame(let frame):
                return frame
            case .gap:
                continue
            case .wait:
                return nil
            }
        }
    }

    public mutating func reconfigure(targetDelayMs: Int, maxDelayMs: Int) -> SkyBridgeMediaJitterBuffer<Payload> {
        var buffer = SkyBridgeMediaJitterBuffer<Payload>(
            targetDelayMs: targetDelayMs,
            maxDelayMs: maxDelayMs,
            packetDurationMs: packetDurationMs,
            reorderGraceMs: reorderGraceMs
        )
        buffer.frames = frames
        buffer.nextExpectedSequence = nextExpectedSequence
        buffer.missingSequenceFirstSeenAt = missingSequenceFirstSeenAt
        return buffer
    }

    private mutating func pop(sequence: UInt64) -> SkyBridgeMediaJitterFrame<Payload>? {
        guard let frame = frames.removeValue(forKey: sequence) else { return nil }
        nextExpectedSequence = sequence + 1
        return frame
    }

}
